# cek — The Felleisen-Friedman Abstract Machine Suite

```
       +-------------------------------------------------------+
       |                  CEK Machine State                    |
       |             State = < C , E , K >                     |
       +-------------------------------------------------------+
       |  C (Control)      : AST Term or Value under focus     |
       |  E (Environment)  : Lexical binding map (x -> Val)    |
       |  K (Continuation) : Stack of pending reduction frames |
       +-------------------------------------------------------+
                                   |
                         [Step: C -> C', K -> K']
                                   v
       +-------------------------------------------------------+
       |                 Tail-Call Trampoline                  |
       |       Constant host stack space: O(1) stack frames     |
       +-------------------------------------------------------+
```

`cek` provides high-performance, tail-recursive abstract machines derived from the classical **Control-Environment-Continuation (CEK)** machine of Matthias Felleisen and Daniel P. Friedman (1986, 1987). It delivers fast, memory-bounded interpretation and strong $\beta\eta$-normalization for typed functional languages and Dhall configuration architectures.

While sister project **pykinos** draws upon the **classical Greek literature** for cache-compact unboxed structures (*τὸ πυκνόν*), `cek` draws upon the formal **computer science literature** (Landin 1964, Plotkin 1975, Felleisen & Friedman 1986, Danvy & Nielsen 2001, Ager et al. 2003, Rossberg 2018) to replace recursive tree-walking evaluators with constant-stack abstract machine trampolines.

---

## Key Features

1. **Constant Host Stack Space:** Eliminates GHC call-stack consumption and prevents `StackOverflow` on deep ASTs or large schema folds.
2. **High-Throughput Dhall Normalization (`cek-dhall`):** Normalizes Dhall expressions in memory without invoking external toolchains, avoiding the quadratic substitution blowups of naive tree recursion.
3. **Cache-Conscious Environments (`cek-pykinos`):** Backs lexical environments with unboxed Roaring bitsets and 4-tier Adaptive Radix Trees (`Node4`, `Node16`, `Node48`, `Node256`).
4. **Row Polymorphic Records (`cek-polytropos`):** Evaluates extensible records with compile-time literal slot indexing ($O(1)$ access).
5. **Demonstrative Reference Interpreters:**
   - **`cek-scheme`:** Call-by-Value Scheme with first-class continuations (`call/cc`), mutable variables (`set!`), and `Generic1` dissection.
   - **`cek-mercury`:** Warren Abstract Machine (WAM) relational unification with conditional trailing and `KontStack` choice points.
   - **`cek-oneml`:** Andreas Rossberg's 1ML first-class modules and functors with `MergeMorph3` existential sealing.
   - **`cek-examples`:** Umbrella showcase re-exporting the three reference interpreters.

---

## Architecture & Package Hierarchy

```
cek/
├── packages/
│   ├── cek-core/         -- Base CEK machine state transitions & closure algebra
│   ├── cek-dhall/        -- Dhall AST normalization & builtin dispatch
│   ├── cek-pykinos/      -- Blocked unboxed environments via Roaring bitsets & ART
│   ├── cek-polytropos/   -- Structural row-polymorphic record evaluation
│   ├── cek-scheme/       -- Demonstrative: Scheme R5RS call/cc & mutable environment
│   ├── cek-mercury/      -- Demonstrative: WAM relational logic unification & choice points
│   ├── cek-oneml/        -- Demonstrative: 1ML first-class modules, functors & sealing
│   └── cek-examples/     -- Demonstrative: Showcase umbrella re-exporting reference interpreters
```

---

## Quick Start

### Building and Testing

```bash
# Build all 8 packages
cabal build all

# Run full test suite across all packages
cabal test all

# Run physical verification gates (HLint, tests, Tagref, Linkcheck, CLOC)
./bin/cek-verify
```

### Worked Example: Evaluating Lambda Terms

```haskell
import Cek.Core

-- Construct: (\x -> x + 42) 10
let body = BinOp Add (Var "x") (LitInt 42)
let expr = App (Lam "x" body) (LitInt 10)

-- Evaluate via the CEK trampoline:
let val  = runCek (injectExpr expr emptyEnv)
print val  -- Output: ValInt 52
```

---

## Documentation Corpus

- [`docs/INDEX.md`](docs/INDEX.md) — Comprehensive documentation index and reading trajectories.
- [`docs/TUTORIAL.md`](docs/TUTORIAL.md) — Practical step-by-step tutorial track.
- [`docs/NEWBIE_GUIDE.md`](docs/NEWBIE_GUIDE.md) — Token-conservation funnel, mental model, and common gotchas.
- [`docs/MAINTAINER_GUIDE.md`](docs/MAINTAINER_GUIDE.md) — Maintenance runbook, 5 physical verification gates, and release procedures.
- [`docs/notes/CEK_DESIGN.md`](docs/notes/CEK_DESIGN.md) — Formal reduction semantics ($\longrightarrow_{CEK}$), literature bibliography, and architectural design.
- [`docs/notes/DOC_STRATEGY.md`](docs/notes/DOC_STRATEGY.md) — Canonical documentation policy and precedence rules.
- [`docs/notes/COMMIT_ATTRIBUTION.md`](docs/notes/COMMIT_ATTRIBUTION.md) — RFC 2822 commit attribution standards.

---

## License & Attribution

- **License:** EUPL-1.2
- **Author:** Nadia Yvette Chambers <nadia.yvette.chambers@ik.me>
