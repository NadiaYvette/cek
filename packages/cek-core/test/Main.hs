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
import Cek.Core.Dissect

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

  describe "Cek.Core.Dissect (McBride Polynomial Functor Dissection)" $ do
    it "dissects variable-arity list spine left-to-right" $ do
      let terms = [10 :: Int, 20, 30]
      case stepIn terms of
        Left _ -> fail "expected Right on non-empty list"
        Right (h1, d1) -> do
          h1 `shouldBe` 10
          let stepN :: Int -> ListDissect Int Int -> Either [Int] (Int, ListDissect Int Int)
              stepN = stepNext
          case stepN 100 d1 of
            Left _ -> fail "expected Right for second hole"
            Right (h2, d2) -> do
              h2 `shouldBe` 20
              case stepN 200 d2 of
                Left _ -> fail "expected Right for third hole"
                Right (h3, d3) -> do
                  h3 `shouldBe` 30
                  case stepN 300 d3 of
                    Right _ -> fail "expected Left on terminal list"
                    Left finalCs -> finalCs `shouldBe` [100, 200, 300]
