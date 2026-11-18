{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StrictData #-}
{-# OPTIONS_GHC -Wno-pattern-namespace-specifier #-}

-- |
-- Module      : Cek.Examples.Mercury
-- Description : Prolog/Mercury relational unification and backtracking engine on KontStack.
--
-- Demonstrates how 'KontStack' (O(1) copy-on-write continuation capture) and
-- 'SoAStore' (monotonic cell allocation with WAM conditional trailing) support
-- nondeterministic relational search, deep term unification, and @semidet@ commits.
--
-- === Architecture: WAM Relational Search on SoA Structures
--
-- The Warren Abstract Machine (WAM) achieves high-speed execution of Prolog and Mercury
-- by pairing three distinct memory areas:
--
--   1. An allocation heap for terms: mapped onto the 4096-cell chunked 'SoAStore'.
--   2. A continuation stack for clause dispatch: mapped onto the unrolled 32-frame 'KontStack'.
--   3. An undo trail for unbinding variables during backtracking: stored in an unboxed
--      'MutableByteArray' ('leTrail').
--
-- === WAM Conditional Trailing Invariant
--
-- When binding an unbound logic variable at cell @varAddr@ to a target term at @targetAddr@:
--
--   * If @varAddr < heapWatermark@ (where @heapWatermark@ is the store allocation cursor at
--     the most recent choice point), the variable was allocated /before/ the choice point
--     and must be recorded on the trail ('leTrail') so it can be reset to 'CT_Unbound'
--     upon failure.
--   * If @varAddr >= heapWatermark@, the variable was created /within/ the current alternative.
--     Backtracking simply resets the store allocation pointer, so trailing is bypassed.
--
-- === Delimited Commits and Choice-Point Pruning
--
-- Mercury's @semidet@ deterministic commits (or Prolog cuts @!@) prune choice points.
-- In 'solveMercury', cuts simply reset the choice point counter @cpCursor@ to the saved
-- watermark, instantly reclaiming all intermediate choice point states.
module Cek.Examples.Mercury
  ( -- * Relational AST and Goals
    LogicTerm(..)
  , Goal(..)

    -- * WAM Engine State
  , LogicEngine(..)

    -- * Continuation Frame Tags
  , pattern FT_ConjR
  , pattern FT_CommitCut
  , pattern FT_UnifyArgs

    -- * Engine Lifecycle and Solver
  , newLogicEngine
  , solveMercury
  ) where

import Control.Monad (when)
import Control.Monad.ST (ST, runST)
import Data.Bits (shiftR, (.&.))
import Data.Int (Int32)
import Data.Primitive.ByteArray
  ( MutableByteArray
  , newByteArray
  , readByteArray
  , writeByteArray
  )
import Data.Primitive.SmallArray
  ( SmallArray
  , SmallMutableArray
  , indexSmallArray
  , newSmallArray
  , readSmallArray
  , sizeofSmallArray
  , smallArrayFromList
  , writeSmallArray
  )
import Data.Word (Word32)
import GHC.Exts (unsafeCoerce#)

import Cek.Pykinos.Kont
  ( CapturedKont(..)
  , FrameTag(..)
  , KontBlock
  , KontStack
  , captureKontSoA
  , newKontStack
  , popFrameSoA
  , pushFrameSoA
  , restoreKontSoA
  )
import Cek.Pykinos.Store
  ( CellTag(..)
  , SoAStore(..)
  , StoreChunk(..)
  , acquireSlot
  , allocWLitSoA
  , newSoAStore
  , pattern CT_Thunk
  , pattern CT_Unbound
  , pattern CT_WLit
  , pattern CT_WRecord
  , readCellPhaseSoA
  , unCellTag
  )

-- | Frame tag for evaluating the right-hand conjunct @g2@ after @g1@ succeeds.
pattern FT_ConjR     :: FrameTag
pattern FT_ConjR     = FrameTag 20

-- | Frame tag for committing a @once@ / cut block by pruning choice points.
pattern FT_CommitCut :: FrameTag
pattern FT_CommitCut = FrameTag 21

-- | Frame tag for continuing deep unification of remaining compound functor arguments.
pattern FT_UnifyArgs :: FrameTag
pattern FT_UnifyArgs = FrameTag 22

-- | First-order logic terms (variables, unboxed integer constants, and compound functors).
data LogicTerm
  = LVar !Int
    -- ^ Logic variable reference resolved through the local lexical environment.
  | LLit !Int32
    -- ^ 32-bit signed integer literal constant.
  | LFun !Word32 !(SmallArray LogicTerm)
    -- ^ Compound functor term @f(t0, t1, ...)@ with symbol ID and argument array.
  deriving (Eq, Show)

-- | Relational goal calculus supporting conjunction, disjunction, fresh variables, and commits.
data Goal
  = GSuccess
    -- ^ Trivial success goal (@true@ in Prolog).
  | GFail
    -- ^ Trivial failure goal that immediately triggers backtracking.
  | GUnify !LogicTerm !LogicTerm
    -- ^ Bidirectional Robinson unification between two terms @t1 = t2@.
  | GFresh !Goal
    -- ^ Fresh logic variable binder introducing a new unbound cell in 'SoAStore'.
  | GConj  !Goal !Goal
    -- ^ Logical conjunction @(g1 , g2)@ evaluated left-to-right.
  | GDisj  ![Goal]
    -- ^ Nondeterministic disjunction @(g1 ; g2 ; ...)@ creating a choice point.
  | GOnce  !Goal
    -- ^ Prune choice points created within @g@ upon first successful solution (@once/1@).
  deriving (Eq, Show)

-- | Mutable WAM execution state combining 'SoAStore', 'KontStack', an unboxed trail,
--   and an unboxed choice-point watermark stack.
data LogicEngine s = LogicEngine
  { leStore     :: !(SoAStore s)
    -- ^ Term and variable allocation arena.
  , leKont      :: !(KontStack s)
    -- ^ Small-step goal continuation stack.
  , leTrail     :: !(MutableByteArray s)
    -- ^ Unboxed array of trailed variable addresses to be reset on backtrack.
  , leCpUnboxed :: !(MutableByteArray s)
    -- ^ Unboxed choice-point table (kCur, storeNext, trailCur).
  , leCpKontBlk :: !(SmallMutableArray s (KontBlock s))
    -- ^ Saved top continuation blocks for frozen choice points.
  , leCpAlts    :: !(SmallMutableArray s ([Goal], [Int32]))
    -- ^ Remaining alternative goals and environment frames per choice point.
  , leCounters  :: !(MutableByteArray s)
    -- ^ Engine registers: Int32[0] = trailCursor, Int32[1] = cpCursor, Int32[2] = heapWatermark
  }

-- | Initialize a fresh 'LogicEngine' with pre-allocated trail and choice-point slabs.
newLogicEngine :: ST s (LogicEngine s)
newLogicEngine = do
  leStore     <- newSoAStore
  leKont      <- newKontStack
  leTrail     <- newByteArray (16384 * 4)
  leCpUnboxed <- newByteArray (1024 * 16)
  leCpKontBlk <- newSmallArray 1024 (unsafeCoerce# ())
  leCpAlts    <- newSmallArray 1024 ([], [])
  leCounters  <- newByteArray 12
  writeByteArray leCounters 0 (0 :: Int32)
  writeByteArray leCounters 1 (0 :: Int32)
  writeByteArray leCounters 2 (0 :: Int32)
  pure LogicEngine{..}

-- | Allocate an unbound unification variable ('CT_Unbound') in 'SoAStore' with 0 pointer writes.
{-# INLINE allocUnboundVar #-}
allocUnboundVar :: SoAStore s -> ST s Int32
allocUnboundVar store = do
  (!addr, StoreChunk{..}, !slot) <- acquireSlot store
  writeByteArray scUnboxed slot (unCellTag CT_Unbound)
  pure addr

-- | Dereference variable indirection chains ('CT_Thunk' -> targetAddr) in 'SoAStore'.
{-# INLINE derefLogicAddr #-}
derefLogicAddr :: SoAStore s -> Int32 -> ST s (Int32, CellTag, Int32, StoreChunk s, Int)
derefLogicAddr store !addr0 = go addr0
  where
    go !addr = do
      (!tag, !aux, !chunk, !slot) <- readCellPhaseSoA store addr
      if tag == CT_Thunk
        then go aux
        else pure (addr, tag, aux, chunk, slot)

-- | Bind an unbound logic variable at 'varAddr' to 'targetAddr' using WAM conditional trailing.
{-# INLINE bindLogicVar #-}
bindLogicVar :: LogicEngine s -> Int32 -> Int32 -> ST s ()
bindLogicVar LogicEngine{..} !varAddr !targetAddr
  | varAddr == targetAddr = pure ()
  | otherwise = do
      let !ix   = fromIntegral varAddr :: Int
          !slot = ix .&. 0xFFF
      StoreChunk{..} <- readSmallArray (ssChunks leStore) (ix `shiftR` 12)
      writeByteArray scUnboxed slot (unCellTag CT_Thunk)
      writeByteArray scUnboxed (5120 + slot) targetAddr
      watermark :: Int32 <- readByteArray leCounters 2
      when (varAddr < watermark) $ do
        tCur :: Int32 <- readByteArray leCounters 0
        writeByteArray leTrail (fromIntegral tCur) varAddr
        writeByteArray leCounters 0 (tCur + 1)

-- | Materialize a syntax 'LogicTerm' into a 'SoAStore' cell address.
instantiateTerm :: LogicEngine s -> [Int32] -> LogicTerm -> ST s Int32
instantiateTerm eng@LogicEngine{..} env = \case
  LVar ix        -> pure (env !! ix)
  LLit n         -> allocWLitSoA leStore n
  LFun fSym args -> do
    let !n = sizeofSmallArray args
    argAddrs <- mapM (\i -> instantiateTerm eng env (indexSmallArray args i)) [0 .. n - 1]
    (!addr, StoreChunk{..}, !slot) <- acquireSlot leStore
    writeByteArray scUnboxed slot (unCellTag CT_WRecord)
    writeByteArray scUnboxed (5120 + slot) (fromIntegral fSym :: Int32)
    writeSmallArray scPtrA slot (unsafeCoerce# (smallArrayFromList argAddrs))
    pure addr

-- | Execute a relational 'Goal' over @numQueryVars@ root variables and collect up to
--   @maxSolutions@ integer bindings per query variable across backtracking branches.
solveMercury :: Int -> Int -> Goal -> [[Maybe Int32]]
solveMercury !maxSolutions !numQueryVars rootGoal = runST $ do
  eng@LogicEngine{..} <- newLogicEngine
  queryAddrs <- mapM (\_ -> allocUnboundVar leStore) [1 .. numQueryVars]
  let readQueryBinding !qAddr = do
        (!_a, !tag, !aux, !_chk, !_slot) <- derefLogicAddr leStore qAddr
        if tag == CT_WLit
          then pure (Just aux)
          else pure Nothing

      evalGoal !goal !env !accSols
        | length accSols >= maxSolutions = pure (reverse accSols)
        | otherwise = case goal of
            -- Success: proceed to the next pending continuation frame in KontStack
            GSuccess -> continueSuccess accSols
            -- Failure: trigger choice-point restoration and trail unwinding
            GFail    -> backtrack accSols

            -- Allocate fresh unbound unification variable and extend lexical scope
            GFresh body -> do
              vAddr <- allocUnboundVar leStore
              evalGoal body (vAddr : env) accSols

            -- Conjunction: push right goal onto KontStack and evaluate left goal
            GConj g1 g2 -> do
              pushFrameSoA leKont FT_ConjR 0 0 (unsafeCoerce# g2) (unsafeCoerce# env)
              evalGoal g1 env accSols

            -- Once / Cut: save current choice point watermark and commit on success
            GOnce g -> do
              cpCur :: Int32 <- readByteArray leCounters 1
              pushFrameSoA leKont FT_CommitCut cpCur 0 (unsafeCoerce# ()) (unsafeCoerce# ())
              evalGoal g env accSols

            -- Empty disjunction: no alternatives left; initiate backtrack
            GDisj []       -> backtrack accSols
            -- Single disjunct: deterministic execution without creating a choice point
            GDisj [single] -> evalGoal single env accSols
            -- Multiple disjuncts: freeze KontStack, record trail and store cursors
            GDisj (firstAlt : restAlts) -> do
              CapturedKont topBlk kCur <- captureKontSoA leKont
              storeNext :: Int32 <- readByteArray (ssState leStore) 0
              trailCur  :: Int32 <- readByteArray leCounters 0
              cpCur     :: Int32 <- readByteArray leCounters 1
              let !cpIx = fromIntegral cpCur :: Int
                  !base = cpIx * 4
              -- Save choice point registers into unboxed table:
              writeByteArray leCpUnboxed (base + 0) (fromIntegral kCur :: Int32)
              writeByteArray leCpUnboxed (base + 1) storeNext
              writeByteArray leCpUnboxed (base + 2) trailCur
              -- Save frozen continuation block and remaining alternatives:
              writeSmallArray leCpKontBlk cpIx topBlk
              writeSmallArray leCpAlts    cpIx (restAlts, env)
              writeByteArray leCounters 1 (cpCur + 1)
              writeByteArray leCounters 2 storeNext
              evalGoal firstAlt env accSols

            -- Robinson first-order unification between instantiated terms
            GUnify t1 t2 -> do
              a1 <- instantiateTerm eng env t1
              a2 <- instantiateTerm eng env t2
              unifyAddrs a1 a2 accSols

      unifyAddrs !u1 !u2 !accSols = do
        (!a1, !tag1, !aux1, !chk1, !slot1) <- derefLogicAddr leStore u1
        (!a2, !tag2, !aux2, !chk2, !slot2) <- derefLogicAddr leStore u2
        -- Identical cell addresses unify trivially without memory writes
        if a1 == a2
          then continueSuccess accSols
          else case (tag1, tag2) of
            -- Unbound variable on left: bind to right address with trailing
            (CT_Unbound, _) -> bindLogicVar eng a1 a2 >> continueSuccess accSols
            -- Unbound variable on right: bind to left address with trailing
            (_, CT_Unbound) -> bindLogicVar eng a2 a1 >> continueSuccess accSols
            -- Primitive integer literals: test equality of unboxed AuxInt values
            (CT_WLit, CT_WLit)
              | aux1 == aux2 -> continueSuccess accSols
              | otherwise    -> backtrack accSols
            -- Compound record/functor structures: compare symbol IDs and unify arguments
            (CT_WRecord, CT_WRecord)
              | aux1 == aux2 -> do
                  arr1 :: SmallArray Int32 <- unsafeCoerce# <$> readSmallArray (scPtrA chk1) slot1
                  arr2 :: SmallArray Int32 <- unsafeCoerce# <$> readSmallArray (scPtrA chk2) slot2
                  let !n1 = sizeofSmallArray arr1
                      !n2 = sizeofSmallArray arr2
                  if n1 /= n2
                    then backtrack accSols
                    else if n1 == 0
                      then continueSuccess accSols
                      else do
                        -- Push remaining arguments onto KontStack for incremental verification:
                        when (n1 > 1) $
                          pushFrameSoA leKont FT_UnifyArgs 1 (fromIntegral n1)
                            (unsafeCoerce# arr1) (unsafeCoerce# arr2)
                        unifyAddrs (indexSmallArray arr1 0) (indexSmallArray arr2 0) accSols
            _ -> backtrack accSols

      continueSuccess !accSols = do
        mbFrame <- popFrameSoA leKont
        case mbFrame of
          -- No more frames on KontStack: an entire relational solution was derived
          Nothing -> do
            sol <- mapM readQueryBinding queryAddrs
            let !accSols' = sol : accSols
            if length accSols' >= maxSolutions
              then pure (reverse accSols')
              else backtrack accSols'

          Just (ft, intA, intB, ptrA, ptrB)
            -- Resume right-hand conjunct
            | ft == FT_ConjR -> do
                let !g2  = unsafeCoerce# ptrA :: Goal
                    !env = unsafeCoerce# ptrB :: [Int32]
                evalGoal g2 env accSols
            -- Commit cut: prune choice points older than the cut watermark
            | ft == FT_CommitCut -> do
                writeByteArray leCounters 1 intA
                if intA > 0
                  then do
                    prevWm :: Int32 <- readByteArray leCpUnboxed (fromIntegral (intA - 1) * 4 + 1)
                    writeByteArray leCounters 2 prevWm
                  else writeByteArray leCounters 2 (0 :: Int32)
                continueSuccess accSols
            -- Resume argument unification
            | ft == FT_UnifyArgs -> do
                let !cur  = fromIntegral intA :: Int
                    !len  = fromIntegral intB :: Int
                    !arr1 = unsafeCoerce# ptrA :: SmallArray Int32
                    !arr2 = unsafeCoerce# ptrB :: SmallArray Int32
                when (cur + 1 < len) $
                  pushFrameSoA leKont FT_UnifyArgs (intA + 1) intB ptrA ptrB
                unifyAddrs (indexSmallArray arr1 cur) (indexSmallArray arr2 cur) accSols
            | otherwise -> pure (reverse accSols)

      backtrack !accSols = do
        cpCur :: Int32 <- readByteArray leCounters 1
        -- If no choice points remain, all search branches have been exhausted
        if cpCur <= 0
          then pure (reverse accSols)
          else do
            let !cpIx = fromIntegral (cpCur - 1) :: Int
                !base = cpIx * 4
            !savedKCur      :: Int32 <- readByteArray leCpUnboxed (base + 0)
            !savedStoreNext :: Int32 <- readByteArray leCpUnboxed (base + 1)
            !savedTrailCur  :: Int32 <- readByteArray leCpUnboxed (base + 2)
            !savedKBlk      <- readSmallArray leCpKontBlk cpIx
            (!alts, !env)   <- readSmallArray leCpAlts cpIx

            -- 1. Unwind trailed variable bindings back to CT_Unbound
            curTrail :: Int32 <- readByteArray leCounters 0
            let unwindTrail !t
                  | t <= savedTrailCur = pure ()
                  | otherwise = do
                      !trailedAddr :: Int32 <- readByteArray leTrail (fromIntegral (t - 1))
                      let !ix   = fromIntegral trailedAddr :: Int
                          !slot = ix .&. 0xFFF
                      StoreChunk{..} <- readSmallArray (ssChunks leStore) (ix `shiftR` 12)
                      writeByteArray scUnboxed slot (unCellTag CT_Unbound)
                      unwindTrail (t - 1)
            unwindTrail curTrail
            writeByteArray leCounters 0 savedTrailCur

            -- 2. Reclaim all speculative SoAStore allocations in O(1)
            writeByteArray (ssState leStore) 0 savedStoreNext

            -- 3. Restore the 32-frame SoA KontStack in O(1)
            restoreKontSoA leKont (CapturedKont savedKBlk (fromIntegral savedKCur))

            -- 4. Advance or pop choice point
            case alts of
              [] -> do
                writeByteArray leCounters 1 (cpCur - 1)
                backtrack accSols
              [lastAlt] -> do
                writeByteArray leCounters 1 (cpCur - 1)
                if cpCur - 1 > 0
                  then do
                    prevWm :: Int32 <- readByteArray leCpUnboxed (fromIntegral (cpCur - 2) * 4 + 1)
                    writeByteArray leCounters 2 prevWm
                  else writeByteArray leCounters 2 (0 :: Int32)
                evalGoal lastAlt env accSols
              (nextAlt : moreAlts) -> do
                writeSmallArray leCpAlts cpIx (moreAlts, env)
                evalGoal nextAlt env accSols

  evalGoal rootGoal queryAddrs []
