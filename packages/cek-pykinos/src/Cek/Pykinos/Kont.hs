{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StrictData #-}
{-# OPTIONS_GHC -Wno-pattern-namespace-specifier #-}

-- |
-- Module      : Cek.Pykinos.Kont
-- Description : 32-frame unrolled Structure-of-Arrays continuation stack with O(1) CoW capture.
--
-- Eliminates per-step heap closure allocation by packing 32 continuation frames
-- into a 320-byte (5 cache-line) 'MutableByteArray' paired with two pointer lanes.
--
-- === Structure-of-Arrays Continuation Design
--
-- In conventional CEK and Krivine machine implementations, every evaluation step
-- pushes a frame onto a singly-linked list of heap closures (e.g. @data Frame = ...@).
-- This incurs significant allocation overhead, GC pressure, and cache misses during
-- high-frequency interpreter loops.
--
-- 'KontStack' replaces the linked list of heap frames with an unrolled Structure-of-Arrays
-- (SoA) chain of 32-frame blocks ('KontBlock'):
--
--   * 'kbUnboxed': A 320-byte unboxed 'MutableByteArray' spanning exactly 5 cache lines:
--       * Bytes [  0 ..  31]: Block header (Int32[0] = cursor, Int32[1] = frozenCursor).
--       * Bytes [ 32 ..  63]: Lane 0 — 32 x 1-byte 'FrameTag' opcodes.
--       * Bytes [ 64 .. 191]: Lane 1 — 32 x 4-byte 'Int32' integer fields (@intA@).
--       * Bytes [192 .. 319]: Lane 2 — 32 x 4-byte 'Int32' integer fields (@intB@).
--   * 'kbPtrA': A 32-slot 'SmallMutableArray' holding primary boxed term or record pointers.
--   * 'kbPtrB': A 32-slot 'SmallMutableArray' holding secondary boxed environment or argument pointers.
--
-- === O(1) Copy-on-Write Continuation Capture
--
-- First-class continuation capture (such as Scheme's @call/cc@ and Mercury's choice-point
-- backtracking) is achieved in strictly $O(1)$ time without copying the stack:
--
--   1. 'captureKontSoA' records the current block and cursor in 'CapturedKont' and freezes
--      the block by updating its @frozenCursor@.
--   2. Future pushes onto a frozen block perform a lazy copy-on-write clone of the active
--      prefix ('cloneBlockPrefix') only when modifying frozen slots.
--   3. Unfrozen pushes and pops operate in place with zero heap allocations.
module Cek.Pykinos.Kont
  ( -- * Continuation Frame Opcodes
    FrameTag(..)
  , pattern FT_UpdateWHNF
  , pattern FT_App
  , pattern FT_Proj
  , pattern FT_MergeL
  , pattern FT_MergeR
  , pattern FT_StartQuote
  , pattern FT_UpdateNF
  , pattern FT_QuoteBinder
  , pattern FT_BuildBinder
  , pattern FT_QuoteRecord
  , pattern FT_QuoteSpine
  , pattern FT_BuildElim
  , pattern FT_PureDissect

    -- * Block and Stack Structures
  , KontBlock(..)
  , KontStack(..)
  , CapturedKont(..)

    -- * Stack Lifecycle and Operations
  , newKontStack
  , pushFrameSoA
  , popFrameSoA
  , captureKontSoA
  , restoreKontSoA
  ) where

import Control.Monad (when)
import Control.Monad.ST (ST)
import Data.Int (Int32)
import Data.Primitive.ByteArray
  ( MutableByteArray
  , copyMutableByteArray
  , newByteArray
  , readByteArray
  , writeByteArray
  )
import Data.Primitive.SmallArray
  ( SmallMutableArray
  , copySmallMutableArray
  , newSmallArray
  , readSmallArray
  , writeSmallArray
  )
import Data.Word (Word8)
import GHC.Exts (Any, unsafeCoerce#)

-- | Unboxed 1-byte continuation frame opcode stored in Lane 0 of 'KontBlock'.
newtype FrameTag = FrameTag { unFrameTag :: Word8 }
  deriving (Eq, Ord, Show)

-- | Frame: Overwrite a lazy thunk address in the store with the evaluated WHNF value.
pattern FT_UpdateWHNF  :: FrameTag
pattern FT_UpdateWHNF  = FrameTag 0

-- | Frame: Apply evaluated function to pending unevaluated argument address.
pattern FT_App         :: FrameTag
pattern FT_App         = FrameTag 1

-- | Frame: Project a field from an evaluated record using its slot offset.
pattern FT_Proj        :: FrameTag
pattern FT_Proj        = FrameTag 2

-- | Frame: Merge left operand of a record union (@//@) while waiting on the right operand.
pattern FT_MergeL      :: FrameTag
pattern FT_MergeL      = FrameTag 3

-- | Frame: Merge right operand of a record union (@//@) with evaluated left operand.
pattern FT_MergeR      :: FrameTag
pattern FT_MergeR      = FrameTag 4

-- | Frame: Enter NbE quote phase to read back a value into a normal-form DAG.
pattern FT_StartQuote  :: FrameTag
pattern FT_StartQuote  = FrameTag 5

-- | Frame: Update a thunk's memoized normal form in Lane 1 of the store arena.
pattern FT_UpdateNF    :: FrameTag
pattern FT_UpdateNF    = FrameTag 6

-- | Frame: Read back a function abstraction by extending the neutral environment.
pattern FT_QuoteBinder :: FrameTag
pattern FT_QuoteBinder = FrameTag 7

-- | Frame: Reconstruct a binder term after its body has been normalized.
pattern FT_BuildBinder :: FrameTag
pattern FT_BuildBinder = FrameTag 8

-- | Frame: Normalize fields of a flat record in sequence.
pattern FT_QuoteRecord :: FrameTag
pattern FT_QuoteRecord = FrameTag 9

-- | Frame: Read back arguments in an elimination spine.
pattern FT_QuoteSpine  :: FrameTag
pattern FT_QuoteSpine  = FrameTag 10

-- | Frame: Reconstruct an applied neutral term from normalized arguments.
pattern FT_BuildElim   :: FrameTag
pattern FT_BuildElim   = FrameTag 11

-- | Frame: Generic polynomial dissection frame driving generic AST traversal.
pattern FT_PureDissect :: FrameTag
pattern FT_PureDissect = FrameTag 12

-- | A 32-frame unrolled Structure-of-Arrays block.
--
-- Layout inside the 320-byte 'kbUnboxed' 'MutableByteArray':
--   * Bytes [  0 ..  31]: Header (Int32[0] = cursor, Int32[1] = frozenCursor)
--   * Bytes [ 32 ..  63]: Lane 0 — 32 x Word8  FrameTag opcodes
--   * Bytes [ 64 .. 191]: Lane 1 — 32 x Int32  IntA (Int32 indices 16 .. 47)
--   * Bytes [192 .. 319]: Lane 2 — 32 x Int32  IntB (Int32 indices 48 .. 79)
data KontBlock s = KontBlock
  { kbUnboxed   :: !(MutableByteArray s)
    -- ^ Unboxed memory holding header, frame tags, and auxiliary integer parameters.
  , kbPtrA      :: !(SmallMutableArray s Any)
    -- ^ Primary pointer lane for closures, terms, or environments.
  , kbPtrB      :: !(SmallMutableArray s Any)
    -- ^ Secondary pointer lane for arguments or continuation records.
  , kbParent    :: !(Maybe (KontBlock s))
    -- ^ Previous block in the call stack when stack exceeds 32 frames.
  , kbFreeChild :: !(SmallMutableArray s (Maybe (KontBlock s)))
    -- ^ Cached reusable allocated child block to eliminate malloc churn during push/pop oscillation.
  }

-- | Mutable reference to the active top 'KontBlock' of the continuation stack.
newtype KontStack s = KontStack (SmallMutableArray s (KontBlock s))

-- | First-class O(1) continuation snapshot for @call/cc@ and backtracking choice points.
data CapturedKont s = CapturedKont
  { ckTopBlock :: !(KontBlock s)
    -- ^ Top block at the moment of capture.
  , ckCursor   :: {-# UNPACK #-} !Int
    -- ^ Stack depth within the top block at capture time.
  }

-- | Allocate an empty 32-frame SoA block linked to 'mbParent'.
{-# INLINE allocKontBlock #-}
allocKontBlock :: Maybe (KontBlock s) -> ST s (KontBlock s)
allocKontBlock !mbParent = do
  mba  <- newByteArray 320
  writeByteArray mba 0 (0 :: Int32)
  writeByteArray mba 1 (0 :: Int32)
  ptrA <- newSmallArray 32 (unsafeCoerce# ())
  ptrB <- newSmallArray 32 (unsafeCoerce# ())
  free <- newSmallArray 1 Nothing
  pure (KontBlock mba ptrA ptrB mbParent free)

-- | Create a fresh 'KontStack' with one pre-allocated 32-frame block.
newKontStack :: ST s (KontStack s)
newKontStack = do
  b0  <- allocKontBlock Nothing
  ref <- newSmallArray 1 b0
  pure (KontStack ref)

-- | Copy-on-Write prefix clone of slots @[0 .. copyLen - 1]@ when pushing onto
--   a block that has been frozen by 'captureKontSoA'.
cloneBlockPrefix :: KontBlock s -> Int -> ST s (KontBlock s)
cloneBlockPrefix oldBlock !copyLen = do
  fresh <- allocKontBlock (kbParent oldBlock)
  copyMutableByteArray (kbUnboxed fresh) 0 (kbUnboxed oldBlock) 0 320
  writeByteArray (kbUnboxed fresh) 0 (fromIntegral copyLen :: Int32)
  writeByteArray (kbUnboxed fresh) 1 (0 :: Int32)
  copySmallMutableArray (kbPtrA fresh) 0 (kbPtrA oldBlock) 0 copyLen
  copySmallMutableArray (kbPtrB fresh) 0 (kbPtrB oldBlock) 0 copyLen
  pure fresh

-- | Push a continuation frame onto the stack in O(1) time.
--
-- Encodes tag, two unboxed integers, and two pointer lanes with zero heap allocations.
{-# INLINE pushFrameSoA #-}
pushFrameSoA
  :: KontStack s
  -> FrameTag
  -> Int32
  -> Int32
  -> Any
  -> Any
  -> ST s ()
pushFrameSoA (KontStack ref) !tag !intA !intB !ptrA !ptrB = do
  top <- readSmallArray ref 0
  cur :: Int32 <- readByteArray (kbUnboxed top) 0
  frz :: Int32 <- readByteArray (kbUnboxed top) 1
  if cur < 32
    then do
      top' <- if cur < frz
                then do
                  c <- cloneBlockPrefix top (fromIntegral cur)
                  writeSmallArray ref 0 c
                  pure c
                else pure top
      let !slot = fromIntegral cur :: Int
          !mba  = kbUnboxed top'
      writeByteArray mba (32 + slot) (unFrameTag tag)
      writeByteArray mba (16 + slot) intA
      writeByteArray mba (48 + slot) intB
      writeSmallArray (kbPtrA top') slot ptrA
      writeSmallArray (kbPtrB top') slot ptrB
      writeByteArray mba 0 (cur + 1)
    else do
      mbChild <- readSmallArray (kbFreeChild top) 0
      child <- case mbChild of
        Just c  -> do
          writeSmallArray (kbFreeChild top) 0 Nothing
          writeByteArray (kbUnboxed c) 0 (0 :: Int32)
          writeByteArray (kbUnboxed c) 1 (0 :: Int32)
          pure c
        Nothing -> allocKontBlock (Just top)
      writeSmallArray ref 0 child
      let !mba = kbUnboxed child
      writeByteArray mba 32 (unFrameTag tag)
      writeByteArray mba 16 intA
      writeByteArray mba 48 intB
      writeSmallArray (kbPtrA child) 0 ptrA
      writeSmallArray (kbPtrB child) 0 ptrB
      writeByteArray mba 0 (1 :: Int32)

-- | Pop the topmost continuation frame from the stack in O(1) time.
--
-- Clears pointer lanes on pop to avoid memory leaks across deep recursions.
{-# INLINE popFrameSoA #-}
popFrameSoA
  :: KontStack s
  -> ST s (Maybe (FrameTag, Int32, Int32, Any, Any))
popFrameSoA (KontStack ref) = do
  top <- readSmallArray ref 0
  cur :: Int32 <- readByteArray (kbUnboxed top) 0
  if cur > 0
    then do
      let !slot = fromIntegral (cur - 1) :: Int
      readAndRetract top slot
    else case kbParent top of
      Nothing -> pure Nothing
      Just parent -> do
        writeSmallArray (kbFreeChild parent) 0 (Just top)
        writeSmallArray ref 0 parent
        pCur :: Int32 <- readByteArray (kbUnboxed parent) 0
        if pCur > 0
          then do
            let !slot = fromIntegral (pCur - 1) :: Int
            readAndRetract parent slot
          else pure Nothing
  where
    readAndRetract blk !slot = do
      let !mba = kbUnboxed blk
      writeByteArray mba 0 (fromIntegral slot :: Int32)
      !tag  <- FrameTag <$> readByteArray mba (32 + slot)
      !intA <- readByteArray mba (16 + slot)
      !intB <- readByteArray mba (48 + slot)
      !ptrA <- readSmallArray (kbPtrA blk) slot
      !ptrB <- readSmallArray (kbPtrB blk) slot
      frz :: Int32 <- readByteArray mba 1
      when (fromIntegral slot >= frz) $ do
        writeSmallArray (kbPtrA blk) slot (unsafeCoerce# ())
        writeSmallArray (kbPtrB blk) slot (unsafeCoerce# ())
      pure (Just (tag, intA, intB, ptrA, ptrB))

-- | Capture the current continuation in O(1) by marking the active block chain frozen.
{-# INLINE captureKontSoA #-}
captureKontSoA :: KontStack s -> ST s (CapturedKont s)
captureKontSoA (KontStack ref) = do
  top <- readSmallArray ref 0
  cur :: Int32 <- readByteArray (kbUnboxed top) 0
  freezeChain top (fromIntegral cur)
  pure (CapturedKont top (fromIntegral cur))
  where
    freezeChain !blk !frzCursor = do
      existingFrz :: Int32 <- readByteArray (kbUnboxed blk) 1
      when (fromIntegral frzCursor > existingFrz) $
        writeByteArray (kbUnboxed blk) 1 (fromIntegral frzCursor :: Int32)
      case kbParent blk of
        Nothing -> pure ()
        Just p  -> freezeChain p 32

-- | Restore a previously captured continuation snapshot in O(1) time.
{-# INLINE restoreKontSoA #-}
restoreKontSoA :: KontStack s -> CapturedKont s -> ST s ()
restoreKontSoA (KontStack ref) (CapturedKont top cur) = do
  writeSmallArray ref 0 top
  writeByteArray (kbUnboxed top) 0 (fromIntegral cur :: Int32)
