{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Main
Description : Unit test suite for cek-core abstract machine
Copyright   : (c) Nadia Yvette Chambers, 2026
License     : EUPL-1.2
Maintainer  : Nadia Chambers <nadia.yvette.chambers@ik.me>
-}
module Main (main) where

import Test.Hspec
import Cek.Core

main :: IO ()
main = hspec $ do
  describe "Cek.Core (Felleisen-Friedman CEK Abstract Machine)" $ do
    it "evaluates literal constants directly" $ do
      evalCEK (Lit (LitNat 42)) `shouldBe` Right (VLit (LitNat 42))
      evalCEK (Lit (LitText "hello")) `shouldBe` Right (VLit (LitText "hello"))

    it "evaluates identity application (\\x -> x) 42" $ do
      let term = App (Lam "x" (Var "x")) (Lit (LitNat 42))
      evalCEK term `shouldBe` Right (VLit (LitNat 42))

    it "evaluates curried application (\\x -> \\y -> x) 1 2" $ do
      let term = App (App (Lam "x" (Lam "y" (Var "x"))) (Lit (LitNat 1))) (Lit (LitNat 2))
      evalCEK term `shouldBe` Right (VLit (LitNat 1))

    it "evaluates let bindings: let x = 10 in x" $ do
      let term = Let "x" (Lit (LitNat 10)) (Var "x")
      evalCEK term `shouldBe` Right (VLit (LitNat 10))

    it "flags unbound variables with Left error" $ do
      evalCEK (Var "unbound") `shouldBe` Left "Unbound variable in CEK environment: unbound"

    it "tracks remaining fuel and interrupts on exhaustion" $ do
      let term = App (Lam "x" (Var "x")) (Lit (LitNat 42))
      let (res, remFuel) = runCEKWithFuel 100 term
      res `shouldBe` Right (VLit (LitNat 42))
      remFuel `shouldSatisfy` (> 0)

      let (resNoFuel, _) = runCEKWithFuel 1 term
      resNoFuel `shouldBe` Left "OutOfFuel: Execution budget exhausted"
