{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StrictData #-}

-- |
-- Module      : Cek.Polytropos.Dissect
-- Description : Universal O(1) array cursor dissection over Polytropos.Core.Rep.
--
-- Replaces O(N) nested 'GHC.Generics' sum/product continuation frames with a
-- single flat cursor over 'Polytropos.Core.Rep'.
--
-- === The Problem of Generic Dissection Overhead
--
-- Standard polynomial functor dissection via GHC's 'Generic1' introduces deeply
-- nested tree structures of binary sums (':+:') and binary products (':*:').
-- For a constructor with \(k\) arguments, the generic representation requires
-- \(k\) nested 'Prod2' frame allocations. Each frame allocation costs multiple
-- heap words and pointer traversals.
--
-- === Flat Representation Dissection
--
-- In 'Polytropos.Core', every algebraic data type or record constructor is represented
-- as a single contiguous array ('Rep'):
--
-- @
-- data Rep (f :: Type -> Type) a = Rep {-# UNPACK #-} !Word !(SmallArray Any)
-- @
--
-- 'PolyDissect' exploits this contiguous representation by turning functor dissection
-- into a single integer cursor ('pdCursor') sliding across a 'SmallArray':
--
--   * Slots @[0 .. pdCursor - 1]@: Contain evaluated Clowns (@c@).
--   * Slot @pdCursor@: The active evaluation hole currently being reduced.
--   * Slots @[pdCursor + 1 .. n - 1]@: Contain unevaluated Jokers (@j@).
--
-- This reduces frame allocation to an unboxed cursor increment, achieving $O(1)$
-- stepping with optimal cache locality and zero tree-pointer chasing.
module Cek.Polytropos.Dissect
  ( -- * Flat Dissection Representation
    PolyDissect(..)

    -- * Dissection Stepping Operations
  , polyStepIn
  , polyStepNext
  ) where

import Data.Bifunctor (Bifunctor(..))
import Data.Primitive.SmallArray
  ( SmallArray
  , indexSmallArray
  , runSmallArray
  , sizeofSmallArray
  , thawSmallArray
  , writeSmallArray
  )
import GHC.Exts (Any, unsafeCoerce#)
import Polytropos.Core (Rep(..))

-- | Universal dissection state for any 'Polytropos.Core.Rep' syntax node.
--
-- Invariant: in 'pdSlots', indices @[0 .. pdCursor - 1]@ hold evaluated
-- Clowns @c@, index 'pdCursor' is the active hole, and indices
-- @[pdCursor + 1 .. n - 1]@ hold unevaluated Jokers @j@.
data PolyDissect c j = PolyDissect
  { pdTag    :: {-# UNPACK #-} !Word
    -- ^ The constructor tag index within the source sum/data type.
  , pdCursor :: {-# UNPACK #-} !Int
    -- ^ Zero-based offset of the currently active evaluation hole.
  , pdSlots  :: !(SmallArray Any)
    -- ^ Array of slots partitioned by 'pdCursor' into Clowns and Jokers.
  }

-- | Functor mapping over the unevaluated Jokers to the right of 'pdCursor'.
instance Functor (PolyDissect c) where
  fmap g (PolyDissect tag cur arr) =
    let !n = sizeofSmallArray arr
        !arr' = runSmallArray $ do
          m <- thawSmallArray arr 0 n
          let loop !i
                | i >= n = pure m
                | i <= cur = loop (i + 1)
                | otherwise = do
                    let !j = unsafeCoerce# (indexSmallArray arr i)
                    writeSmallArray m i (unsafeCoerce# (g j))
                    loop (i + 1)
          loop 0
    in PolyDissect tag cur arr'

-- | Bifunctor mapping over both evaluated Clowns and unevaluated Jokers.
instance Bifunctor PolyDissect where
  bimap f g (PolyDissect tag cur arr) =
    let !n = sizeofSmallArray arr
        !arr' = runSmallArray $ do
          m <- thawSmallArray arr 0 n
          let loop !i
                | i >= n = pure m
                | i < cur = do
                    let !c = unsafeCoerce# (indexSmallArray arr i)
                    writeSmallArray m i (unsafeCoerce# (f c))
                    loop (i + 1)
                | i == cur = loop (i + 1)
                | otherwise = do
                    let !j = unsafeCoerce# (indexSmallArray arr i)
                    writeSmallArray m i (unsafeCoerce# (g j))
                    loop (i + 1)
          loop 0
    in PolyDissect tag cur arr'

-- | Step into slot 0 of a 'Polytropos.Core.Rep' syntax node in strictly O(1) time.
--
-- If the constructor has zero payload slots (e.g. nullary constructor or empty record),
-- returns 'Left' immediately with zero heap allocations. Otherwise, initializes
-- 'pdCursor' at 0 and returns 'Right' with the first child term paired with 'PolyDissect'.
{-# INLINE polyStepIn #-}
polyStepIn
  :: Rep f j
  -> Either (Rep g c) (f j, PolyDissect (g c) (f j))
polyStepIn (Rep !tag !arr)
  | sizeofSmallArray arr == 0 =
      Left (Rep tag (unsafeCoerce# arr))
  | otherwise =
      let !firstJoker = unsafeCoerce# (indexSmallArray arr 0)
      in Right (firstJoker, PolyDissect tag 0 (unsafeCoerce# arr))

-- | Plug an evaluated Clown @g c@ into 'pdCursor' and advance to @pdCursor + 1@.
--
-- When @pdCursor + 1 == sizeofSmallArray pdSlots@, all child terms have been evaluated
-- and the complete reconstructed 'Rep' is returned in 'Left'.
-- Otherwise, returns 'Right' with the next Joker subterm and updated 'PolyDissect'.
{-# INLINE polyStepNext #-}
polyStepNext
  :: g c
  -> PolyDissect (g c) (f j)
  -> Either (Rep g c) (f j, PolyDissect (g c) (f j))
polyStepNext !clownVal (PolyDissect !tag !cursor !arr) =
  let !n     = sizeofSmallArray arr
      !nextC = cursor + 1
      !arr'  = runSmallArray $ do
                 m <- thawSmallArray arr 0 n
                 writeSmallArray m cursor (unsafeCoerce# clownVal)
                 pure m
  in if nextC >= n
       then Left (Rep tag (unsafeCoerce# arr'))
       else let !nextJoker = unsafeCoerce# (indexSmallArray arr nextC)
            in Right (nextJoker, PolyDissect tag nextC arr')
