# cek-oneml

> **Important Notice:** This package is an educational and demonstrative reference implementation showcasing Andreas Rossberg's 1ML first-class module system over the CEK abstract machine with `MergeMorph3` existential sealing and `Pykinos` hidden classes. It is provided primarily as an executable architectural example within the `cek` ecosystem documentation.

## Overview

`cek-oneml` implements the core of Andreas Rossberg's *"1ML — Core and the Modules in the Same Language"* (ICFP 2015), executing first-class structures, signatures, and functors directly over unboxed data structures:

1. **Flat Structural Layouts:** Structures and signatures are flat arrays of lazy cells indexed by `FieldId` and mapped to `SchemaId` identifiers in `Pykinos.Schema.HiddenClass`.
2. **Existential Sealing (`Mod :> Sig`):** Computes a domain restriction (`OpRestrict`) in $O(|Sig|)$ time. For every abstract type field (`SpecAbstract`), the evaluator mints a fresh skolem constant (`CT_WNeu`) in `SoAStore`, concealing the underlying concrete type without dynamic wrapper closures.
3. **Module Functors:** Functors are ordinary first-class functions parameterized over module records.

## Module Structure

- `Cek.OneML`: Primary reference evaluator and AST definitions.
- `Cek.Examples.OneML`: Backward-compatibility re-export module.

## Building and Testing

```bash
cabal build cek-oneml
cabal test cek-oneml:tests
```

## License

EUPL-1.2.
