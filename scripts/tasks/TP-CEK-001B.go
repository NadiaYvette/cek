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
	fmt.Println("=== [TP-CEK-001B Task Runner (Go)] ===")

	// 1. Scaffold packages/cek-pykinos directories
	dirs := []string{
		"packages/cek-pykinos/src/Cek/Pykinos",
		"packages/cek-pykinos/test",
	}
	for _, d := range dirs {
		if err := os.MkdirAll(d, 0755); err != nil {
			fmt.Fprintf(os.Stderr, "failed to mkdir %s: %v\n", d, err)
			os.Exit(1)
		}
	}

	// 2. Mount Kont.hs and Store.hs
	srcKont := findSeed("TP-CEK-001B-Kont.hs")
	dstKont := "packages/cek-pykinos/src/Cek/Pykinos/Kont.hs"
	if err := copyFile(srcKont, dstKont); err != nil {
		fmt.Fprintf(os.Stderr, "failed to copy %s -> %s: %v\n", srcKont, dstKont, err)
		os.Exit(1)
	}

	srcStore := findSeed("TP-CEK-001B-Store.hs")
	dstStore := "packages/cek-pykinos/src/Cek/Pykinos/Store.hs"
	if err := copyFile(srcStore, dstStore); err != nil {
		fmt.Fprintf(os.Stderr, "failed to copy %s -> %s: %v\n", srcStore, dstStore, err)
		os.Exit(1)
	}
	fmt.Printf("  [+] Mounted %s and %s\n", dstKont, dstStore)

	// 3. Write cek-pykinos.cabal
	cabalContent := `cabal-version: 3.0
name: cek-pykinos
version: 0.1.0.0
synopsis: Unrolled 32-frame SoA KontStack and 4096-cell chunked Store arena for CEK
description:
  High-performance unboxed continuation stack and Store arena for CEK abstract machines.
license: EUPL-1.2
author: Nadia Yvette Chambers
maintainer: nadia.yvette.chambers@ik.me
category: Development
build-type: Simple
tested-with: GHC == 9.14.1

library
  exposed-modules:
    Cek.Pykinos.Kont
    Cek.Pykinos.Store
  hs-source-dirs: src
  default-language: Haskell2010
  ghc-options: -Wall -Wcompat -Wredundant-constraints
  build-depends:
    base >= 4.18 && < 5,
    ghc-prim,
    primitive >= 0.9,
    cek-core,
    pykinos-core

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
    primitive >= 0.9,
    hspec >= 2.10 && < 2.12
`
	if err := os.WriteFile("packages/cek-pykinos/cek-pykinos.cabal", []byte(cabalContent), 0644); err != nil {
		fmt.Fprintf(os.Stderr, "failed to write cek-pykinos.cabal: %v\n", err)
		os.Exit(1)
	}

	// 4. Write boilerplate files: LICENSE, README.md, CHANGELOG.md
	copyFile("LICENSE", "packages/cek-pykinos/LICENSE")
	os.WriteFile("packages/cek-pykinos/README.md", []byte("# cek-pykinos\n\nUnrolled 32-frame SoA KontStack and 4096-cell chunked Store arena.\n"), 0644)
	os.WriteFile("packages/cek-pykinos/CHANGELOG.md", []byte("# Changelog for cek-pykinos\n\n## 0.1.0.0\n* Initial release.\n"), 0644)

	// 5. Write test/Main.hs
	testContent := `{-# LANGUAGE MagicHash #-}
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
          t1 ` + "`shouldBe`" + ` FT_Proj
          a1 ` + "`shouldBe`" + ` 30
          b1 ` + "`shouldBe`" + ` 40
          t2 ` + "`shouldBe`" + ` FT_App
          a2 ` + "`shouldBe`" + ` 10
          b2 ` + "`shouldBe`" + ` 20
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
      addr ` + "`shouldBe`" + ` 0
      tag ` + "`shouldBe`" + ` CT_WLit
      aux ` + "`shouldBe`" + ` 42
      memo ` + "`shouldBe`" + ` 99
`
	if err := os.WriteFile("packages/cek-pykinos/test/Main.hs", []byte(testContent), 0644); err != nil {
		fmt.Fprintf(os.Stderr, "failed to write packages/cek-pykinos/test/Main.hs: %v\n", err)
		os.Exit(1)
	}

	fmt.Println("=== [TP-CEK-001B Task Runner Finished] ===")
}
