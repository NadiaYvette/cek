{-# LANGUAGE MagicHash #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Main
-- Description : Unit test suite for cek-pykinos KontStack and SoAStore
-- Copyright   : (c) Nadia Yvette Chambers, 2026
-- License     : EUPL-1.2
module Main (main) where

import Control.Monad.ST (runST)
import GHC.Exts (unsafeCoerce#)
import Test.Hspec

import Cek.Pykinos.Kont
import Cek.Pykinos.Store

main :: IO ()
main = hspec $ do
  describe "Cek.Pykinos.Kont (32-frame SoA KontStack)" $ do
    it "pushes and pops continuation frames in LIFO order" $ do
      let res = runST $ do
            stack <- newKontStack
            pushFrameSoA stack FT_App 10 20 (unsafeCoerce# ()) (unsafeCoerce# ())
            pushFrameSoA stack FT_Proj 30 40 (unsafeCoerce# ()) (unsafeCoerce# ())
            f1 <- popFrameSoA stack
            f2 <- popFrameSoA stack
            f3 <- popFrameSoA stack
            pure (f1, f2, f3)
      case res of
        (Just (t1, a1, b1, _, _), Just (t2, a2, b2, _, _), Nothing) -> do
          t1 `shouldBe` FT_Proj
          a1 `shouldBe` 30
          b1 `shouldBe` 40
          t2 `shouldBe` FT_App
          a2 `shouldBe` 10
          b2 `shouldBe` 20
        _ -> fail "Unexpected pop sequence"

  describe "Cek.Pykinos.Store (4096-cell SoA Store Arena)" $ do
    it "allocates unboxed literal cells and reads phase tags" $ do
      let (addr, tag, aux, memo) = runST $ do
            store <- newSoAStore
            a <- allocWLitSoA store 42
            (t, val, _, _) <- readCellPhaseSoA store a
            writeMemoNfSoA store a 99
            m <- readMemoNfSoA store a
            pure (a, t, val, m)
      addr `shouldBe` 0
      tag `shouldBe` CT_WLit
      aux `shouldBe` 42
      memo `shouldBe` 99
