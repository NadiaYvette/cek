{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Main
-- Description : Unit test suite for Cek.OneML
-- Copyright   : (c) Nadia Yvette Chambers, 2026
-- License     : EUPL-1.2
module Main (main) where

import Test.Hspec
import qualified Data.Primitive.PrimArray as Prim
import qualified Data.Primitive.SmallArray as Small
import Pykinos.Schema.HiddenClass (FieldId(..), SchemaId(..))

import Cek.OneML

main :: IO ()
main = hspec $ do
  describe "Cek.OneML (1ML First-Class Modules & MergeMorph3 Sealing)" $ do
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
