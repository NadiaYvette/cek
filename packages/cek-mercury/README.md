# cek-mercury

> **Important Notice:** This package is an educational and demonstrative reference implementation showcasing relational unification, Warren Abstract Machine (WAM) conditional trailing, and nondeterministic search over `KontStack` choice points. It is provided primarily as an executable architectural example within the `cek` ecosystem documentation.

## Overview

`cek-mercury` implements a high-performance relational unification and search engine inspired by the Warren Abstract Machine (WAM) and Mercury's deterministic execution models, executing entirely over unboxed CEK data structures:

1. **Term Allocation Heap:** Mapped onto the 4096-cell chunked `SoAStore`.
2. **Clause Dispatch Stack:** Mapped onto the unrolled 32-frame `KontStack`.
3. **WAM Conditional Trailing:** Bound variables allocate trail entries only if their address precedes the most recent choice point watermark (`heapWatermark`), bypassing trail overhead for transient intra-clause bindings.
4. **Delimited Commits (`semidet`):** Mercury's deterministic commits (`GOnce`) prune intermediate choice points instantaneously by resetting the choice point watermark.

## Module Structure

- `Cek.Mercury`: Primary reference engine and AST definitions.
- `Cek.Examples.Mercury`: Backward-compatibility re-export module.

## Building and Testing

```bash
cabal build cek-mercury
cabal test cek-mercury:tests
```

## License

EUPL-1.2.
