package main

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
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
	fmt.Println("=== [TP-CEK-001A Task Runner (Go)] ===")

	// 1. Copy Dissect.hs
	srcDissect := findSeed("TP-CEK-001A-Dissect.hs")
	dstDissect := "packages/cek-core/src/Cek/Core/Dissect.hs"
	if err := copyFile(srcDissect, dstDissect); err != nil {
		fmt.Fprintf(os.Stderr, "failed to copy %s -> %s: %v\n", srcDissect, dstDissect, err)
		os.Exit(1)
	}
	fmt.Printf("  [+] Mounted %s\n", dstDissect)

	// 2. Update cek-core.cabal
	cabalPath := "packages/cek-core/cek-core.cabal"
	cabalBytes, err := os.ReadFile(cabalPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to read %s: %v\n", cabalPath, err)
		os.Exit(1)
	}
	cabalStr := string(cabalBytes)
	if !strings.Contains(cabalStr, "Cek.Core.Dissect") {
		cabalStr = strings.Replace(cabalStr, "    Cek.Core\n", "    Cek.Core\n    Cek.Core.Dissect\n", 1)
		if err := os.WriteFile(cabalPath, []byte(cabalStr), 0644); err != nil {
			fmt.Fprintf(os.Stderr, "failed to write %s: %v\n", cabalPath, err)
			os.Exit(1)
		}
		fmt.Printf("  [+] Updated %s (exposed Cek.Core.Dissect)\n", cabalPath)
	}

	// 3. Update packages/cek-core/test/Main.hs with Dissection tests
	testMainPath := "packages/cek-core/test/Main.hs"
	testBytes, err := os.ReadFile(testMainPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to read %s: %v\n", testMainPath, err)
		os.Exit(1)
	}
	testStr := string(testBytes)
	if !strings.Contains(testStr, "Cek.Core.Dissect (McBride Polynomial Functor Dissection)") {
		if !strings.Contains(testStr, "import Cek.Core.Dissect") {
			testStr = strings.Replace(testStr, "import Cek.Core\n", "import Cek.Core\nimport Cek.Core.Dissect\n", 1)
		}
		dissectTestSnippet := `
  describe "Cek.Core.Dissect (McBride Polynomial Functor Dissection)" $ do
    it "dissects variable-arity list spine left-to-right" $ do
      let terms = [10 :: Int, 20, 30]
      case stepIn terms of
        Left _ -> fail "expected Right on non-empty list"
        Right (h1, d1) -> do
          h1 ` + "`shouldBe`" + ` 10
          case stepNext (100 :: Int) d1 of
            Left _ -> fail "expected Right for second hole"
            Right (h2, d2) -> do
              h2 ` + "`shouldBe`" + ` 20
              case stepNext (200 :: Int) d2 of
                Left _ -> fail "expected Right for third hole"
                Right (h3, d3) -> do
                  h3 ` + "`shouldBe`" + ` 30
                  case stepNext (300 :: Int) d3 of
                    Right _ -> fail "expected Left on terminal list"
                    Left finalCs -> finalCs ` + "`shouldBe`" + ` [100, 200, 300]
`
		// Append before end of hspec block
		testStr = strings.TrimRight(testStr, " \n\t") + "\n" + dissectTestSnippet
		if err := os.WriteFile(testMainPath, []byte(testStr), 0644); err != nil {
			fmt.Fprintf(os.Stderr, "failed to write %s: %v\n", testMainPath, err)
			os.Exit(1)
		}
		fmt.Printf("  [+] Updated %s (added Dissect tests)\n", testMainPath)
	}

	fmt.Println("=== [TP-CEK-001A Task Runner Finished] ===")
}
