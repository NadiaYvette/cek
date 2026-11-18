{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Main
Description : Unit test suite for cek-dhall CEK abstract machine
Copyright   : (c) Nadia Yvette Chambers, 2026
License     : EUPL-1.2
Maintainer  : Nadia Chambers <nadia.yvette.chambers@ik.me>
-}
module Main (main) where

import Test.Hspec
import Cek.Dhall

main :: IO ()
main = hspec $ do
  describe "Cek.Dhall (Dhall CEK Abstract Machine)" $ do
    it "evaluates primitive literals" $ do
      evalDhallCEK (DNat 42) `shouldBe` Right (VNat 42)
      evalDhallCEK (DInt (-15)) `shouldBe` Right (VInt (-15))
      evalDhallCEK (DBool True) `shouldBe` Right (VBool True)
      evalDhallCEK (DText "Nadiverse") `shouldBe` Right (VText "Nadiverse")

    it "evaluates natural addition: 10 + 32 == 42" $ do
      evalDhallCEK (DOpPlus (DNat 10) (DNat 32)) `shouldBe` Right (VNat 42)

    it "evaluates text concatenation: 'Nadi' ++ 'verse' == 'Nadiverse'" $ do
      evalDhallCEK (DOpTextAppend (DText "Nadi") (DText "verse")) `shouldBe` Right (VText "Nadiverse")

    it "evaluates record construction and field projection: { x = 42, y = True }.x" $ do
      let recExpr = DRecord [("x", DNat 42), ("y", DBool True)]
      evalDhallCEK (DField recExpr "x") `shouldBe` Right (VNat 42)
      evalDhallCEK (DField recExpr "y") `shouldBe` Right (VBool True)

    it "evaluates let bindings and lambda application" $ do
      -- let double = \n -> n + n in double 21
      let doubleLam = DLam "n" (DOpPlus (DVar "n") (DVar "n"))
      let expr = DLet "double" doubleLam (DApp (DVar "double") (DNat 21))
      evalDhallCEK expr `shouldBe` Right (VNat 42)

    it "detects type errors cleanly" $ do
      evalDhallCEK (DOpPlus (DText "bad") (DNat 1)) `shouldBe`
        Left "Type error: Left operand of + must be a Natural"
      evalDhallCEK (DField (DNat 42) "missing") `shouldBe`
        Left "Type error: Cannot project field from non-record Dhall value"
