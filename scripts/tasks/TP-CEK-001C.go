package main

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
)

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	if err := os.MkdirAll(filepath.Dir(dst), 0755); err != nil {
		return err
	}

	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()

	_, err = io.Copy(out, in)
	return err
}

func findSeed(name string) string {
	candidates := []string{
		filepath.Join("seeds", name),
		filepath.Join(os.Getenv("HOME"), "src/plans/seeds", name),
		filepath.Join("..", "seeds", name),
		filepath.Join("/home/nyc/src/plans/seeds", name),
	}
	for _, c := range candidates {
		if _, err := os.Stat(c); err == nil {
			return c
		}
	}
	return filepath.Join("seeds", name)
}

func main() {
	fmt.Println("=== [TP-CEK-001C Task Runner (Go)] ===")

	// 1. Scaffold directories
	dirs := []string{
		"packages/cek-polytropos/src/Cek/Polytropos",
		"packages/cek-polytropos/test",
	}
	for _, d := range dirs {
		if err := os.MkdirAll(d, 0755); err != nil {
			fmt.Fprintf(os.Stderr, "failed to mkdir %s: %v\n", d, err)
			os.Exit(1)
		}
	}

	// 2. Mount Dissect.hs
	srcDissect := findSeed("TP-CEK-001C-Dissect.hs")
	dstDissect := "packages/cek-polytropos/src/Cek/Polytropos/Dissect.hs"
	if err := copyFile(srcDissect, dstDissect); err != nil {
		fmt.Fprintf(os.Stderr, "failed to copy %s -> %s: %v\n", srcDissect, dstDissect, err)
		os.Exit(1)
	}
	fmt.Printf("  [+] Mounted %s\n", dstDissect)

	// 3. Write cek-polytropos.cabal
	cabalContent := `cabal-version: 3.0
name: cek-polytropos
version: 0.1.0.0
synopsis: Universal Polytropos Rep Dissection for CEK abstract machines
description:
  Universal O(1) array cursor dissection over Polytropos.Core.Rep.
license: EUPL-1.2
author: Nadia Yvette Chambers
maintainer: nadia.yvette.chambers@ik.me
category: Development
build-type: Simple
tested-with: GHC == 9.14.1

library
  exposed-modules:
    Cek.Polytropos.Dissect
  hs-source-dirs: src
  default-language: Haskell2010
  ghc-options: -Wall -Wcompat -Wredundant-constraints
  build-depends:
    base >= 4.18 && < 5,
    ghc-prim,
    primitive >= 0.9,
    cek-core,
    polytropos-core

test-suite tests
  type: exitcode-stdio-1.0
  main-is: Main.hs
  hs-source-dirs: test
  default-language: Haskell2010
  ghc-options: -Wall -Wcompat -Wredundant-constraints -threaded
  build-depends:
    base >= 4.18 && < 5,
    cek-core,
    cek-polytropos,
    polytropos-core,
    primitive >= 0.9,
    hspec >= 2.10 && < 2.12
`
	if err := os.WriteFile("packages/cek-polytropos/cek-polytropos.cabal", []byte(cabalContent), 0644); err != nil {
		fmt.Fprintf(os.Stderr, "failed to write cek-polytropos.cabal: %v\n", err)
		os.Exit(1)
	}

	// 4. Write boilerplate files
	copyFile("LICENSE", "packages/cek-polytropos/LICENSE")
	os.WriteFile("packages/cek-polytropos/README.md", []byte("# cek-polytropos\n\nUniversal Polytropos Rep Dissection for CEK.\n"), 0644)
	os.WriteFile("packages/cek-polytropos/CHANGELOG.md", []byte("# Changelog for cek-polytropos\n\n## 0.1.0.0\n* Initial release.\n"), 0644)

	// 5. Write test/Main.hs
	testContent := `{-# LANGUAGE MagicHash #-}
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
          v1 ` + "`shouldBe`" + ` 10
          let clown0 = Identity (100 :: Int)
          case polyStepNext clown0 d1 of
            Left _ -> fail "expected Right on second hole"
            Right (j2, d2) -> do
              let v2 = unsafeCoerce# j2 :: Int
              v2 ` + "`shouldBe`" + ` 20
              let clown1 = Identity (200 :: Int)
              case polyStepNext clown1 d2 of
                Right _ -> fail "expected Left on completed rep"
                Left (Rep t _) -> do
                  t ` + "`shouldBe`" + ` 0
`
	if err := os.WriteFile("packages/cek-polytropos/test/Main.hs", []byte(testContent), 0644); err != nil {
		fmt.Fprintf(os.Stderr, "failed to write packages/cek-polytropos/test/Main.hs: %v\n", err)
		os.Exit(1)
	}

	fmt.Println("=== [TP-CEK-001C Task Runner Finished] ===")
}
