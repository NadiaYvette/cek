{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Main
-- Description : Unit test suite for Cek.Mercury
-- Copyright   : (c) Nadia Yvette Chambers, 2026
-- License     : EUPL-1.2
module Main (main) where

import Test.Hspec

import Cek.Mercury

main :: IO ()
main = hspec $ do
  describe "Cek.Mercury (WAM Conditional Trailing & KontStack Choice-Points)" $ do
    it "finds all solutions via nondeterministic disjunction" $ do
      -- q(X) :- X = 1 ; X = 2 ; X = 3
      let goal = GDisj [GUnify (LVar 0) (LLit 1), GUnify (LVar 0) (LLit 2), GUnify (LVar 0) (LLit 3)]
          solutions = solveMercury 10 1 goal
      solutions `shouldBe` [[Just 1], [Just 2], [Just 3]]

    it "prunes remaining disjuncts with GOnce (semidet cut)" $ do
      -- q(X) :- once(X = 1 ; X = 2)
      let goal = GOnce (GDisj [GUnify (LVar 0) (LLit 1), GUnify (LVar 0) (LLit 2)])
          solutions = solveMercury 10 1 goal
      solutions `shouldBe` [[Just 1]]
