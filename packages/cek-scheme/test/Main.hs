{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Main
-- Description : Unit test suite for Cek.Scheme
-- Copyright   : (c) Nadia Yvette Chambers, 2026
-- License     : EUPL-1.2
module Main (main) where

import Data.Int (Int32)
import Test.Hspec

import Cek.Scheme

main :: IO ()
main = hspec $ do
  describe "Cek.Scheme (Call-by-Value with Generic1 Dissection & call/cc)" $ do
    it "evaluates arithmetic expressions via automatic Generic1 Dissection" $ do
      -- (10 + 20) * 2 = 60
      let term = In (SMul (In (SAdd (In (SLit 10)) (In (SLit 20)))) (In (SLit 2)))
      evalScheme 100 term `shouldBe` Right (Right (60 :: Int32))

    it "evaluates conditional branches" $ do
      -- if True then 42 else 0
      let term = In (SIf (In (SBool True)) (In (SLit 42)) (In (SLit 0)))
      evalScheme 100 term `shouldBe` Right (Right (42 :: Int32))

    it "evaluates lambda abstraction and application" $ do
      -- (\x -> x + 5) 10 = 15
      let lam = In (SLam 1 (In (SAdd (In (SVar 0)) (In (SLit 5)))))
          term = In (SApp lam [In (SLit 10)])
      evalScheme 100 term `shouldBe` Right (Right (15 :: Int32))

    it "supports early-exit call/cc escaping from deep inside addition" $ do
      -- 100 + (call/cc (\k -> 10 + k 42)) = 142
      let receiver = In (SLam 1 (In (SAdd (In (SLit 10)) (In (SApp (In (SVar 0)) [In (SLit 42)])))))
          term = In (SAdd (In (SLit 100)) (In (SCallCC receiver)))
      evalScheme 100 term `shouldBe` Right (Right (142 :: Int32))

    it "supports mutable lexical variables via set!" $ do
      -- let x = 10 in (set! 0 25 ; x) = 25
      let body = In (SSeq (In (SSet 0 (In (SLit 25)))) (In (SVar 0)))
          term = In (SLet (In (SLit 10)) body)
      evalScheme 100 term `shouldBe` Right (Right (25 :: Int32))
