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
	fmt.Println("=== [TP-CEK-002A-scheme Task Runner (Go)] ===")

	// 1. Scaffold directories
	dirs := []string{
		"packages/cek-examples/src/Cek/Examples",
		"packages/cek-examples/test",
	}
	for _, d := range dirs {
		if err := os.MkdirAll(d, 0755); err != nil {
			fmt.Fprintf(os.Stderr, "failed to mkdir %s: %v\n", d, err)
			os.Exit(1)
		}
	}

	// 2. Mount Scheme.hs
	srcScheme := findSeed("TP-CEK-002A-Scheme.hs")
	dstScheme := "packages/cek-examples/src/Cek/Examples/Scheme.hs"
	if err := copyFile(srcScheme, dstScheme); err != nil {
		fmt.Fprintf(os.Stderr, "failed to copy %s -> %s: %v\n", srcScheme, dstScheme, err)
		os.Exit(1)
	}
	fmt.Printf("  [+] Mounted %s\n", dstScheme)

	// 3. Write cek-examples.cabal
	cabalContent := `cabal-version: 3.0
name: cek-examples
version: 0.1.0.0
synopsis: Showcase mini-interpreters for CEK abstract machines
description:
  Showcase mini-interpreters (Scheme, Prolog/Mercury, 1ML) demonstrating
  automatic Generic1 dissection, O(1) continuation capture, and MergeMorph3 sealing.
license: EUPL-1.2
author: Nadia Yvette Chambers
maintainer: nadia.yvette.chambers@ik.me
category: Development
build-type: Simple
tested-with: GHC == 9.14.1

library
  exposed-modules:
    Cek.Examples.Scheme
  hs-source-dirs: src
  default-language: Haskell2010
  ghc-options: -Wall -Wcompat -Wredundant-constraints
  build-depends:
    base >= 4.18 && < 5,
    ghc-prim,
    primitive >= 0.9,
    cek-core,
    cek-pykinos

test-suite tests
  type: exitcode-stdio-1.0
  main-is: Main.hs
  hs-source-dirs: test
  default-language: Haskell2010
  ghc-options: -Wall -Wcompat -Wredundant-constraints -threaded
  build-depends:
    base >= 4.18 && < 5,
    cek-core,
    cek-pykinos,
    cek-examples,
    primitive >= 0.9,
    hspec >= 2.10 && < 2.12
`
	if err := os.WriteFile("packages/cek-examples/cek-examples.cabal", []byte(cabalContent), 0644); err != nil {
		fmt.Fprintf(os.Stderr, "failed to write cek-examples.cabal: %v\n", err)
		os.Exit(1)
	}

	// 4. Write boilerplate files
	copyFile("LICENSE", "packages/cek-examples/LICENSE")
	os.WriteFile("packages/cek-examples/README.md", []byte("# cek-examples\n\nShowcase mini-interpreters for CEK.\n"), 0644)
	os.WriteFile("packages/cek-examples/CHANGELOG.md", []byte("# Changelog for cek-examples\n\n## 0.1.0.0\n* Initial release.\n"), 0644)

	// 5. Write test/Main.hs
	testContent := `{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Main
-- Description : Unit test suite for Cek.Examples.Scheme
-- Copyright   : (c) Nadia Yvette Chambers, 2026
-- License     : EUPL-1.2
module Main (main) where

import Data.Int (Int32)
import Test.Hspec

import Cek.Examples.Scheme

main :: IO ()
main = hspec $ do
  describe "Cek.Examples.Scheme (Call-by-Value with Generic1 Dissection & call/cc)" $ do
    it "evaluates arithmetic expressions via automatic Generic1 Dissection" $ do
      -- (10 + 20) * 2 = 60
      let term = In (SMul (In (SAdd (In (SLit 10)) (In (SLit 20)))) (In (SLit 2)))
      evalScheme 100 term ` + "`shouldBe`" + ` Right (Right (60 :: Int32))

    it "evaluates conditional branches" $ do
      -- if True then 42 else 0
      let term = In (SIf (In (SBool True)) (In (SLit 42)) (In (SLit 0)))
      evalScheme 100 term ` + "`shouldBe`" + ` Right (Right (42 :: Int32))

    it "evaluates lambda abstraction and application" $ do
      -- (\x -> x + 5) 10 = 15
      let lam = In (SLam 1 (In (SAdd (In (SVar 0)) (In (SLit 5)))))
          term = In (SApp lam [In (SLit 10)])
      evalScheme 100 term ` + "`shouldBe`" + ` Right (Right (15 :: Int32))

    it "supports early-exit call/cc escaping from deep inside addition" $ do
      -- 100 + (call/cc (\k -> 10 + k 42)) = 142
      let receiver = In (SLam 1 (In (SAdd (In (SLit 10)) (In (SApp (In (SVar 0)) [In (SLit 42)])))))
          term = In (SAdd (In (SLit 100)) (In (SCallCC receiver)))
      evalScheme 100 term ` + "`shouldBe`" + ` Right (Right (142 :: Int32))

    it "supports mutable lexical variables via set!" $ do
      -- let x = 10 in (set! 0 25 ; x) = 25
      let body = In (SSeq (In (SSet 0 (In (SLit 25)))) (In (SVar 0)))
          term = In (SLet (In (SLit 10)) body)
      evalScheme 100 term ` + "`shouldBe`" + ` Right (Right (25 :: Int32))
`
	if err := os.WriteFile("packages/cek-examples/test/Main.hs", []byte(testContent), 0644); err != nil {
		fmt.Fprintf(os.Stderr, "failed to write packages/cek-examples/test/Main.hs: %v\n", err)
		os.Exit(1)
	}

	fmt.Println("=== [TP-CEK-002A-scheme Task Runner Finished] ===")
}
