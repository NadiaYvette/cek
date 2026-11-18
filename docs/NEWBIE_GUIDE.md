# cek Newbie Quickstart & Token-Conservation Guide

**Parent Strategy:** [`notes/DOC_STRATEGY.md`](notes/DOC_STRATEGY.md)  
**Corpus Inventory:** [`INDEX.md`](INDEX.md)  
**Tutorial:** [`TUTORIAL.md`](TUTORIAL.md)  
**Design Monograph:** [`notes/CEK_DESIGN.md`](notes/CEK_DESIGN.md)  
**Maintainer Guide:** [`MAINTAINER_GUIDE.md`](MAINTAINER_GUIDE.md)  

---

## 1. The Core Mental Model: The CEK Machine vs. Tree-Walking Evaluators

If you are accustomed to writing language interpreters using simple tree-walking functions like:

```haskell
-- Naive tree-walking evaluator (AVOID in high-performance runtimes)
eval :: Expr -> Env -> Value
eval (Var x) env = lookupEnv x env
eval (App e1 e2) env =
  let v1 = eval e1 env
      v2 = eval e2 env
  in applyVal v1 v2
```

you will encounter critical bottlenecks when scaling:
1. **Host Stack Overflow:** Every recursive call to `eval` consumes a frame on GHC's call stack. Large recursive computations, folds over lists of thousands of elements, or deeply nested let-bindings trigger `StackOverflow`.
2. **Hidden Control Flow:** The state of pending evaluations is trapped inside GHC's native runtime call stack. You cannot pause the computation, step through it backwards, inspect remaining reductions, or implement non-local jumps.

The **Control-Environment-Continuation (CEK)** abstract machine models computation as explicit state transitions over three registers:

$$\langle C, E, K \rangle \Longrightarrow \langle C', E', K' \rangle$$

- **$C$ (Control):** What is currently under focus (either an unevaluated expression term or a fully computed value).
- **$E$ (Environment):** The lexical bindings of variables in scope.
- **$K$ (Continuation Stack):** An explicit, heap-allocated stack of pending reduction frames.

Because every transition is tail-recursive, evaluation runs in a **trampoline**—a tight loop consuming constant $O(1)$ host stack space.

---

## 2. Progressive Disclosure Funnel: Conserving LLM Tokens and Attention

To prevent token waste and cognitive overload when exploring or modifying the `cek` repository, always follow the four-stage Progressive Disclosure Funnel:

```
[Level 0: Global Navigation]  --> docs/INDEX.md & README.md
              │
              ▼
[Level 1: Package Inventory]  --> packages/*/README.md & cabal files
              │
              ▼
[Level 2: Module Interfaces]  --> Exposed module headers & types
              │
              ▼
[Level 3: Surgical AST Slices]--> Specific transition cases in Cek.Core / Cek.Dhall
```

- **Level 0 (Global Navigation):** Read [`docs/INDEX.md`](INDEX.md) to discover canonical document locations.
- **Level 1 (Package Selection):** Determine which package owns the behavior:
  - Base transition rules $\rightarrow$ `cek-core`
  - Dhall normalization $\rightarrow$ `cek-dhall`
  - Unboxed/blocked environments $\rightarrow$ `cek-pykinos`
  - Row polymorphism & record projections $\rightarrow$ `cek-polytropos`
  - Demonstrative reference language interpreters $\rightarrow$ `cek-scheme`, `cek-mercury`, `cek-oneml`, `cek-examples`
- **Level 2 (Module Signature):** Read only the module exports and top-level type signatures. Never dump whole 2,000-line implementation files.
- **Level 3 (Surgical Slices):** Use `ast-grep` or ripgrep (`rg`) to inspect only the specific transition branch under review.

---

## 3. The 8 Packages at a Glance

```
cek/
├── packages/
│   ├── cek-core/         # Foundational CEK machine transitions, closures, stepping loop
│   ├── cek-dhall/        # Dhall AST normalization, beta-eta reduction, record projection
│   ├── cek-pykinos/      # Blocked unboxed environments (Roaring Bitsets & ART IntMap)
│   ├── cek-polytropos/   # Structural extensible records with O(1) literal indexing
│   ├── cek-scheme/       # Demonstrative: Scheme R5RS call/cc & mutable environment
│   ├── cek-mercury/      # Demonstrative: WAM relational logic unification & choice points
│   ├── cek-oneml/        # Demonstrative: 1ML first-class modules, functors & sealing
│   └── cek-examples/     # Demonstrative: Showcase umbrella re-exporting the three reference interpreters
```

---

## 4. Hands-on Stepping in the REPL

You can step through CEK evaluation interactively in GHCi:

```bash
cabal repl cek-core
```

At the GHCi prompt:

```haskell
ghci> import Cek.Core
ghci> let e = App (Lam "x" (BinOp Add (Var "x") (LitInt 1))) (LitInt 41)
ghci> let s0 = injectExpr e emptyEnv
ghci> s0
State { control = App ..., env = [], kont = [] }

-- Execute a single transition step:
ghci> let s1 = stepCek s0
ghci> s1
State { control = Lam "x" ..., env = [], kont = [FrameArg (LitInt 41) []] }

-- Run until canonical value:
ghci> runCek s0
ValInt 42
```

---

## 5. Common Gotchas and Architectural Invariants

1. **Host Recursion is Banned in Step Logic:**
   - Invariant: `stepCek :: State -> StepResult` must be a pure, flat case analysis. Never recursively invoke `stepCek` inside `stepCek`; recursive stepping is the exclusive job of the trampoline (`runCek`).
2. **Environment Immutability & Sharing:**
   - Environments are structurally shared trees or unboxed radix maps. Avoid eager deep-cloning of entire environment maps on lambda closures.
3. **Continuation Frame Matching:**
   - Every `FrameArg` must eventually pair with a `FrameFun` or return value. Unmatched frames indicate an incomplete transition relation.
4. **Physical Gate Compliance:**
   - Before submitting changes, always run `./bin/cek-verify`. All 5 gates (HLint, Cabal tests, Tagref, Linkcheck, and CLOC comment density $\ge 50\%$) must pass with zero errors.
