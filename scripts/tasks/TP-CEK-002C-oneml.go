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
	fmt.Println("=== [TP-CEK-002C-oneml Task Runner (Go)] ===")

	// 1. Mount OneML.hs
	srcOneML := findSeed("TP-CEK-002C-OneML.hs")
	dstOneML := "packages/cek-examples/src/Cek/Examples/OneML.hs"
	if err := copyFile(srcOneML, dstOneML); err != nil {
		fmt.Fprintf(os.Stderr, "failed to copy %s -> %s: %v\n", srcOneML, dstOneML, err)
		os.Exit(1)
	}
	fmt.Printf("  [+] Mounted %s\n", dstOneML)

	// 2. Add Cek.Examples.OneML to exposed-modules and pykinos-core to build-depends
	cabalPath := "packages/cek-examples/cek-examples.cabal"
	cabalBytes, err := os.ReadFile(cabalPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to read %s: %v\n", cabalPath, err)
		os.Exit(1)
	}
	cabalStr := string(cabalBytes)
	if !strings.Contains(cabalStr, "Cek.Examples.OneML") {
		cabalStr = strings.Replace(
			cabalStr,
			"    Cek.Examples.Mercury",
			"    Cek.Examples.Mercury,\n    Cek.Examples.OneML",
			1,
		)
	}
	if !strings.Contains(cabalStr, "pykinos-core") {
		cabalStr = strings.Replace(
			cabalStr,
			"    cek-pykinos",
			"    cek-pykinos,\n    pykinos-core",
			-1,
		)
	}
	if err := os.WriteFile(cabalPath, []byte(cabalStr), 0644); err != nil {
		fmt.Fprintf(os.Stderr, "failed to update %s: %v\n", cabalPath, err)
		os.Exit(1)
	}
	fmt.Printf("  [+] Updated %s\n", cabalPath)

	// 3. Append tests to test/Main.hs
	testPath := "packages/cek-examples/test/Main.hs"
	testBytes, err := os.ReadFile(testPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to read %s: %v\n", testPath, err)
		os.Exit(1)
	}
	testStr := string(testBytes)
	if !strings.Contains(testStr, "Cek.Examples.OneML") {
		onemlImports := "import qualified Data.Primitive.PrimArray as Prim\nimport qualified Data.Primitive.SmallArray as Small\nimport Cek.Examples.OneML\nimport Pykinos.Schema.HiddenClass (FieldId(..), SchemaId(..))\n"
		testStr = strings.Replace(testStr, "import Cek.Examples.Scheme\n", "import Cek.Examples.Scheme\n"+onemlImports, 1)

		onemlTests := `
  describe "Cek.Examples.OneML (1ML First-Class Modules & MergeMorph3 Sealing)" $ do
    it "evaluates module field projection" $ do
      let schemaMap 1 = Prim.primArrayFromList [10, 20]
          schemaMap _ = Prim.primArrayFromList []
          internSchema _ = SchemaId 1
          -- struct { f10 = 42, f20 = 99 } . f10
          structTerm = MStruct (SchemaId 1) (Small.smallArrayFromList [MLit 42, MLit 99])
          projTerm = MProj structTerm (FieldId 10)
      evalOneML schemaMap internSchema projTerm ` + "`shouldBe`" + ` V1Lit 42

    it "evaluates module functor application" $ do
      let schemaMap 1 = Prim.primArrayFromList [10]
          schemaMap _ = Prim.primArrayFromList []
          internSchema _ = SchemaId 1
          -- functor (m : {val x : Int}) -> m.x
          fTerm = MFunctor (MLit 0) (MProj (MVar 0) (FieldId 10))
          argTerm = MStruct (SchemaId 1) (Small.smallArrayFromList [MLit 77])
          appTerm = MApp fTerm argTerm
      evalOneML schemaMap internSchema appTerm ` + "`shouldBe`" + ` V1Lit 77
`
		lastIdx := strings.LastIndex(testStr, "\n")
		if lastIdx != -1 {
			testStr = testStr[:lastIdx] + onemlTests + "\n"
		}
		if err := os.WriteFile(testPath, []byte(testStr), 0644); err != nil {
			fmt.Fprintf(os.Stderr, "failed to update %s: %v\n", testPath, err)
			os.Exit(1)
		}
		fmt.Printf("  [+] Appended OneML tests to %s\n", testPath)
	}

	fmt.Println("=== [TP-CEK-002C-oneml Task Runner Finished] ===")
}
