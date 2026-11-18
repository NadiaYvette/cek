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
	fmt.Println("=== [TP-CEK-002B-mercury Task Runner (Go)] ===")

	// 1. Mount Mercury.hs
	srcMerc := findSeed("TP-CEK-002B-Mercury.hs")
	dstMerc := "packages/cek-examples/src/Cek/Examples/Mercury.hs"
	if err := copyFile(srcMerc, dstMerc); err != nil {
		fmt.Fprintf(os.Stderr, "failed to copy %s -> %s: %v\n", srcMerc, dstMerc, err)
		os.Exit(1)
	}
	fmt.Printf("  [+] Mounted %s\n", dstMerc)

	// 2. Add Cek.Examples.Mercury to cek-examples.cabal exposed-modules
	cabalPath := "packages/cek-examples/cek-examples.cabal"
	cabalBytes, err := os.ReadFile(cabalPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to read %s: %v\n", cabalPath, err)
		os.Exit(1)
	}
	cabalStr := string(cabalBytes)
	if !strings.Contains(cabalStr, "Cek.Examples.Mercury") {
		cabalStr = strings.Replace(
			cabalStr,
			"    Cek.Examples.Scheme",
			"    Cek.Examples.Scheme,\n    Cek.Examples.Mercury",
			1,
		)
		if err := os.WriteFile(cabalPath, []byte(cabalStr), 0644); err != nil {
			fmt.Fprintf(os.Stderr, "failed to update %s: %v\n", cabalPath, err)
			os.Exit(1)
		}
		fmt.Printf("  [+] Exposed Cek.Examples.Mercury in %s\n", cabalPath)
	}

	// 3. Append tests to test/Main.hs
	testPath := "packages/cek-examples/test/Main.hs"
	testBytes, err := os.ReadFile(testPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to read %s: %v\n", testPath, err)
		os.Exit(1)
	}
	testStr := string(testBytes)
	if !strings.Contains(testStr, "Cek.Examples.Mercury") {
		mercuryImport := "import Cek.Examples.Mercury\n"
		testStr = strings.Replace(testStr, "import Cek.Examples.Scheme\n", "import Cek.Examples.Scheme\n"+mercuryImport, 1)

		mercuryTests := `
  describe "Cek.Examples.Mercury (WAM Conditional Trailing & KontStack Choice-Points)" $ do
    it "finds all solutions via nondeterministic disjunction" $ do
      -- q(X) :- X = 1 ; X = 2 ; X = 3
      let goal = GDisj [GUnify (LVar 0) (LLit 1), GUnify (LVar 0) (LLit 2), GUnify (LVar 0) (LLit 3)]
          solutions = solveMercury 10 1 goal
      solutions ` + "`shouldBe`" + ` [[Just 1], [Just 2], [Just 3]]

    it "prunes remaining disjuncts with GOnce (semidet cut)" $ do
      -- q(X) :- once(X = 1 ; X = 2)
      let goal = GOnce (GDisj [GUnify (LVar 0) (LLit 1), GUnify (LVar 0) (LLit 2)])
          solutions = solveMercury 10 1 goal
      solutions ` + "`shouldBe`" + ` [[Just 1]]
`
		// Append right before the last closing line of main
		lastIdx := strings.LastIndex(testStr, "\n")
		if lastIdx != -1 {
			testStr = testStr[:lastIdx] + mercuryTests + "\n"
		}
		if err := os.WriteFile(testPath, []byte(testStr), 0644); err != nil {
			fmt.Fprintf(os.Stderr, "failed to update %s: %v\n", testPath, err)
			os.Exit(1)
		}
		fmt.Printf("  [+] Appended Mercury tests to %s\n", testPath)
	}

	fmt.Println("=== [TP-CEK-002B-mercury Task Runner Finished] ===")
}
