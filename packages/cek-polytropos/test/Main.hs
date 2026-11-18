{-# LANGUAGE MagicHash #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Main
-- Description : Unit test suite for cek-polytropos Rep dissection
-- Copyright   : (c) Nadia Yvette Chambers, 2026
-- License     : EUPL-1.2
module Main (main) where

import Data.Functor.Identity (Identity(..))
import Data.Primitive.SmallArray (smallArrayFromList)
import GHC.Exts (Any, unsafeCoerce#)
import Test.Hspec

import Cek.Polytropos.Dissect
import Polytropos.Core (Rep(..))

main :: IO ()
main = hspec $ do
  describe "Cek.Polytropos.Dissect (Rep Cursor Dissection)" $ do
    it "steps into and steps through Rep payload slots left-to-right" $ do
      let slot0 = unsafeCoerce# (Identity (10 :: Int)) :: Identity Any
          slot1 = unsafeCoerce# (Identity (20 :: Int)) :: Identity Any
          rep = Rep 0 (smallArrayFromList [slot0, slot1])
      case polyStepIn rep of
        Left _ -> fail "expected Right on 2-slot rep"
        Right (j1, d1) -> do
          let v1 = unsafeCoerce# j1 :: Int
          v1 `shouldBe` 10
          let clown0 = Identity (100 :: Int)
          case polyStepNext clown0 d1 of
            Left _ -> fail "expected Right on second hole"
            Right (j2, d2) -> do
              let v2 = unsafeCoerce# j2 :: Int
              v2 `shouldBe` 20
              let clown1 = Identity (200 :: Int)
              case polyStepNext clown1 d2 of
                Right _ -> fail "expected Left on completed rep"
                Left (Rep t _) -> do
                  t `shouldBe` 0
