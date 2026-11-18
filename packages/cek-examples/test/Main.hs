{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Main
-- Description : Unit test suite for Cek.Examples.Scheme
-- Copyright   : (c) Nadia Yvette Chambers, 2026
-- License     : EUPL-1.2
module Main (main) where

import Data.Int (Int32)
import Test.Hspec

import Cek.Examples.Scheme
import qualified Data.Primitive.PrimArray as Prim
import qualified Data.Primitive.SmallArray as Small
import Cek.Examples.OneML
import Pykinos.Schema.HiddenClass (FieldId(..), SchemaId(..))
import Cek.Examples.Mercury

main :: IO ()
main = hspec $ do
  describe "Cek.Examples.Scheme (Call-by-Value with Generic1 Dissection & call/cc)" $ do
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
  describe "Cek.Examples.Mercury (WAM Conditional Trailing & KontStack Choice-Points)" $ do
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

  describe "Cek.Examples.OneML (1ML First-Class Modules & MergeMorph3 Sealing)" $ do
    it "evaluates module field projection" $ do
      let schemaMap (SchemaId 1) = Prim.primArrayFromList [10, 20]
          schemaMap _ = Prim.primArrayFromList []
          internSchema _ = SchemaId 1
          -- struct { f10 = 42, f20 = 99 } . f10
          structTerm = MStruct (SchemaId 1) (Small.smallArrayFromList [MLit 42, MLit 99])
          projTerm = MProj structTerm (FieldId 10)
      evalOneML schemaMap internSchema projTerm `shouldBe` V1Lit 42

    it "evaluates module functor application" $ do
      let schemaMap (SchemaId 1) = Prim.primArrayFromList [10]
          schemaMap _ = Prim.primArrayFromList []
          internSchema _ = SchemaId 1
          -- functor (m : {val x : Int}) -> m.x
          fTerm = MFunctor (MLit 0) (MProj (MVar 0) (FieldId 10))
          argTerm = MStruct (SchemaId 1) (Small.smallArrayFromList [MLit 77])
          appTerm = MApp fTerm argTerm
      evalOneML schemaMap internSchema appTerm `shouldBe` V1Lit 77

