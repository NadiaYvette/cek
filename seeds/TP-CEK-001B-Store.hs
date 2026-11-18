{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StrictData #-}
{-# OPTIONS_GHC -Wno-pattern-namespace-specifier #-}

-- |
-- Module      : Cek.Pykinos.Store
-- Description : 4096-cell chunked Structure-of-Arrays Store arena for CESK machines.
--
-- Separates unboxed cell phase tags, memoized normal-form DAG pointers ('NfAddr'),
-- and auxiliary 32-bit integers from boxed payload pointers to minimize GC scanning.
--
-- === Structure-of-Arrays (SoA) Memory Layout
--
-- In traditional pointer-heavy graph reduction engines, every lazy evaluation cell
-- (thunk or indirection) is a heap closure containing an info pointer, mutable fields,
-- and payload pointers. As the heap grows, garbage collection pause times degrade
-- proportionally with the total number of cells.
--
-- 'SoAStore' eliminates per-cell heap headers by grouping cells into 4096-cell
-- contiguous memory chunks ('StoreChunk'):
--
--   * 'scUnboxed': A 36,864-byte unboxed 'MutableByteArray' holding raw bytes and
--     integers in three segregated contiguous lanes:
--       * Lane 0 (Bytes 0..4095): 4096 x 1-byte 'CellTag' values.
--       * Lane 1 (Bytes 4096..20479): 4096 x 4-byte 'Int32' memoized normal-form DAG addresses.
--       * Lane 2 (Bytes 20480..36863): 4096 x 4-byte 'Int32' auxiliary integers (literals, symbols).
--   * 'scPtrA': A 4096-slot 'SmallMutableArray' holding primary boxed payload pointers.
--   * 'scPtrB': A 4096-slot 'SmallMutableArray' holding secondary boxed payload pointers.
--
-- === Cell Lifecycle Transitions
--
-- Cells progress through strict evaluation phases tracked in Lane 0:
--
--   1. 'CT_Thunk': Unevaluated closure @(term, env)@ stored across 'scPtrA' and 'scPtrB'.
--   2. 'CT_Blackhole': Currently under active evaluation. Cycles trigger runtime errors.
--   3. 'CT_WLit': Integer / word literal stored unboxed in Lane 2 with zero heap allocations.
--   4. 'CT_WBinder': Evaluated lambda or function abstraction.
--   5. 'CT_WRecord': Evaluated record with interned 'Pykinos.Schema.HiddenClass.SchemaId'.
--   6. 'CT_WNeu': Neutral application or variable spine pending normalization.
module Cek.Pykinos.Store
  ( -- * Cell Phase Tags
    CellTag(..)
  , pattern CT_Thunk
  , pattern CT_Blackhole
  , pattern CT_WLit
  , pattern CT_WBinder
  , pattern CT_WRecord
  , pattern CT_WNeu
  , pattern CT_Unbound

    -- * Store Arena Structures
  , StoreChunk(..)
  , SoAStore(..)

    -- * Store Allocation and Initialization
  , newSoAStore
  , acquireSlot
  , allocThunkSoA
  , allocWLitSoA
  , allocWNeuSoA

    -- * Cell Phase and Memoization Accessors
  , readCellPhaseSoA
  , readMemoNfSoA
  , writeMemoNfSoA
  ) where

import Control.Monad.ST (ST)
import Data.Bits (shiftR, (.&.))
import Data.Int (Int32)
import Data.Primitive.ByteArray
  ( MutableByteArray
  , newByteArray
  , readByteArray
  , setByteArray
  , writeByteArray
  )
import Data.Primitive.SmallArray
  ( SmallMutableArray
  , newSmallArray
  , readSmallArray
  , writeSmallArray
  )
import Data.Word (Word8)
import GHC.Exts (Any, unsafeCoerce#)

-- | 1-byte cell phase opcode stored in Lane 0 of 'StoreChunk'.
newtype CellTag = CellTag { unCellTag :: Word8 }
  deriving (Eq, Ord, Show)

-- | Unevaluated lazy thunk closure @(term, env)@.
pattern CT_Thunk     :: CellTag
pattern CT_Thunk     = CellTag 0

-- | In-progress evaluation sentinel; detects infinite recursion loops.
pattern CT_Blackhole :: CellTag
pattern CT_Blackhole = CellTag 1

-- | Evaluated unboxed integer/boolean literal.
pattern CT_WLit      :: CellTag
pattern CT_WLit      = CellTag 2

-- | Evaluated lambda abstraction or binder closure.
pattern CT_WBinder   :: CellTag
pattern CT_WBinder   = CellTag 3

-- | Evaluated flat record mapped by a 'SchemaId'.
pattern CT_WRecord   :: CellTag
pattern CT_WRecord   = CellTag 4

-- | Neutral term spine waiting on an unbound variable or argument.
pattern CT_WNeu      :: CellTag
pattern CT_WNeu      = CellTag 5

-- | Unbound / unallocated cell slot marker.
pattern CT_Unbound   :: CellTag
pattern CT_Unbound   = CellTag 6

-- | A 4096-cell Structure-of-Arrays Store chunk.
--
-- Layout of the 36,864-byte 'scUnboxed' 'MutableByteArray':
--   * Bytes [    0 ..  4095]: Lane 0 — 4096 x Word8  CellTag (1 byte per cell)
--   * Bytes [ 4096 .. 20479]: Lane 1 — 4096 x Int32  Memoized NfAddr (4 bytes per cell)
--   * Bytes [20480 .. 36863]: Lane 2 — 4096 x Int32  AuxInt (4 bytes per cell)
data StoreChunk s = StoreChunk
  { scUnboxed :: !(MutableByteArray s)
    -- ^ Unified contiguous unboxed memory holding tags, memoized NF addresses, and literals.
  , scPtrA    :: !(SmallMutableArray s Any)
    -- ^ Lane 3: Primary pointer lane for AST terms, records, or closures.
  , scPtrB    :: !(SmallMutableArray s Any)
    -- ^ Lane 4: Secondary pointer lane for environment lists or capture frames.
  }

-- | Chunked SoA Store arena supporting up to 4,194,304 cells across 1024 chunks.
data SoAStore s = SoAStore
  { ssChunks :: !(SmallMutableArray s (StoreChunk s))
    -- ^ Array of chunk pointers, dynamically allocated as monotonic address space expands.
  , ssState  :: !(MutableByteArray s)
    -- ^ Store control state: Int32[0] = nextAddr counter, Int32[1] = count of allocated chunks.
  }

-- | Allocate and initialize a fresh 4096-cell 'StoreChunk' with Lane 1 set to -1.
--
-- Initializing Lane 1 with -1 ensures that 'readMemoNfSoA' can detect unmemoized cells
-- with a single negative integer check.
allocStoreChunk :: ST s (StoreChunk s)
allocStoreChunk = do
  mba <- newByteArray 36864
  setByteArray mba 4096 16384 (0xFF :: Word8)
  ptrA <- newSmallArray 4096 (unsafeCoerce# ())
  ptrB <- newSmallArray 4096 (unsafeCoerce# ())
  pure (StoreChunk mba ptrA ptrB)

-- | Create a new 'SoAStore' with chunk 0 pre-allocated.
newSoAStore :: ST s (SoAStore s)
newSoAStore = do
  c0     <- allocStoreChunk
  chunks <- newSmallArray 1024 (unsafeCoerce# ())
  writeSmallArray chunks 0 c0
  st     <- newByteArray 8
  writeByteArray st 0 (0 :: Int32)
  writeByteArray st 1 (1 :: Int32)
  pure (SoAStore chunks st)

-- | Acquire the next monotonic cell 'Int32' address, allocating a new chunk on boundary crossings.
--
-- Returns the global address, the enclosing 'StoreChunk', and the local intra-chunk slot index (0..4095).
{-# INLINE acquireSlot #-}
acquireSlot :: SoAStore s -> ST s (Int32, StoreChunk s, Int)
acquireSlot SoAStore{..} = do
  addr :: Int32 <- readByteArray ssState 0
  numC :: Int32 <- readByteArray ssState 1
  writeByteArray ssState 0 (addr + 1)
  let !ix      = fromIntegral addr :: Int
      !chunkIx = ix `shiftR` 12
      !slotIx  = ix .&. 0xFFF
  chunk <- if chunkIx < fromIntegral numC
             then readSmallArray ssChunks chunkIx
             else do
               c <- allocStoreChunk
               writeSmallArray ssChunks chunkIx c
               writeByteArray ssState 1 (numC + 1)
               pure c
  pure (addr, chunk, slotIx)

-- | Allocate a lazy thunk @(term, env)@ cell in the Store.
--
-- Initializes the cell phase to 'CT_Thunk' and saves the term and environment pointers.
{-# INLINE allocThunkSoA #-}
allocThunkSoA :: SoAStore s -> a -> b -> ST s Int32
allocThunkSoA store !term !env = do
  (!addr, StoreChunk{..}, !slot) <- acquireSlot store
  writeByteArray scUnboxed slot (unCellTag CT_Thunk)
  writeSmallArray scPtrA slot (unsafeCoerce# term)
  writeSmallArray scPtrB slot (unsafeCoerce# env)
  pure addr

-- | Allocate an unboxed integer literal cell with zero pointer writes.
--
-- Stores the value directly in Lane 2 of 'scUnboxed', completely bypassing the GC write barrier.
{-# INLINE allocWLitSoA #-}
allocWLitSoA :: SoAStore s -> Int32 -> ST s Int32
allocWLitSoA store !litVal = do
  (!addr, StoreChunk{..}, !slot) <- acquireSlot store
  writeByteArray scUnboxed slot (unCellTag CT_WLit)
  writeByteArray scUnboxed (5120 + slot) litVal
  pure addr

-- | Allocate a fresh neutral binder symbol @WNeu sym []@ in the Store.
--
-- Records the symbol ID in Lane 2 and initializes an empty elimination spine.
{-# INLINE allocWNeuSoA #-}
allocWNeuSoA :: SoAStore s -> Int32 -> ST s Int32
allocWNeuSoA store !symId = do
  (!addr, StoreChunk{..}, !slot) <- acquireSlot store
  writeByteArray scUnboxed slot (unCellTag CT_WNeu)
  writeByteArray scUnboxed (5120 + slot) symId
  writeSmallArray scPtrA slot (unsafeCoerce# ([] :: [Any]))
  pure addr

-- | Check in O(1) whether 'addr' already has a memoized normal-form DAG pointer ('NfAddr' >= 0).
{-# INLINE readMemoNfSoA #-}
readMemoNfSoA :: SoAStore s -> Int32 -> ST s Int32
readMemoNfSoA SoAStore{..} !addr = do
  let !ix = fromIntegral addr :: Int
  StoreChunk{..} <- readSmallArray ssChunks (ix `shiftR` 12)
  readByteArray scUnboxed (1024 + (ix .&. 0xFFF))

-- | Record a memoized normal-form DAG pointer 'nfAddr' for cell 'addr'.
{-# INLINE writeMemoNfSoA #-}
writeMemoNfSoA :: SoAStore s -> Int32 -> Int32 -> ST s ()
writeMemoNfSoA SoAStore{..} !addr !nfAddr = do
  let !ix = fromIntegral addr :: Int
  StoreChunk{..} <- readSmallArray ssChunks (ix `shiftR` 12)
  writeByteArray scUnboxed (1024 + (ix .&. 0xFFF)) nfAddr

-- | Read the unboxed 'CellTag', 'AuxInt', 'StoreChunk', and slot offset for 'addr'.
{-# INLINE readCellPhaseSoA #-}
readCellPhaseSoA :: SoAStore s -> Int32 -> ST s (CellTag, Int32, StoreChunk s, Int)
readCellPhaseSoA SoAStore{..} !addr = do
  let !ix   = fromIntegral addr :: Int
      !slot = ix .&. 0xFFF
  chunk@StoreChunk{..} <- readSmallArray ssChunks (ix `shiftR` 12)
  !rawTag <- readByteArray scUnboxed slot
  !aux    <- readByteArray scUnboxed (5120 + slot)
  pure (CellTag rawTag, aux, chunk, slot)
