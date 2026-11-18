# cek-scheme

> **Important Notice:** This package is an educational and demonstrative reference implementation showcasing CEK machine execution with first-class continuations (`call/cc`), mutable lexical environments (`set!`), and automatic GHC `Generic1` polynomial functor dissection. It is provided primarily as an executable example and architectural pattern within the `cek` ecosystem documentation.

## Overview

`cek-scheme` implements a Call-by-Value mini-Scheme interpreter demonstrating how higher-order control flow and mutable state are cleanly evaluated on top of the `cek` abstract machine infrastructure:

1. **Pure Syntactic Spines:** Arithmetic operations (`SAdd`, `SSub`, `SMul`), relational comparisons, and sequencing (`SSeq`) are evaluated without manual frame plumbing via automatic `Generic1` dissection (`Dissectable`).
2. **First-Class Continuations (`call/cc`):** Continuations capture the unrolled 32-frame `KontStack` in strictly $O(1)$ time via Copy-on-Write (`captureKontSoA`). Reinstating a captured continuation (`restoreKontSoA`) resumes execution with zero stack unwinding.
3. **Mutable Lexical Scope (`set!`):** Lexical variables occupy mutable cells allocated in the unboxed `SoAStore`.

## Module Structure

- `Cek.Scheme`: Primary reference evaluator and AST definitions.
- `Cek.Examples.Scheme`: Backward-compatibility re-export module.

## Building and Testing

```bash
cabal build cek-scheme
cabal test cek-scheme:tests
```

## License

EUPL-1.2.
