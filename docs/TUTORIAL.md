# Getting Started with cek: A Comprehensive Practical Guide

**Parent Strategy:** [`notes/DOC_STRATEGY.md`](notes/DOC_STRATEGY.md)  
**Corpus Inventory:** [`INDEX.md`](INDEX.md)  
**Design Monograph:** [`notes/CEK_DESIGN.md`](notes/CEK_DESIGN.md)  
**Maintainer Guide:** [`MAINTAINER_GUIDE.md`](MAINTAINER_GUIDE.md)  
**Newbie Orientation:** [`NEWBIE_GUIDE.md`](NEWBIE_GUIDE.md)  

---

## 1. Conceptual Foundations: The CEK Machine in Theory and Practice

In modern programming language implementation, tree-walking recursive evaluators (`eval :: Expr -> Env -> Value`) suffer from two severe structural deficiencies:
1. **Call-Stack Consumption:** Every nested function application or sub-expression evaluation consumes a stack frame on the host runtime system (GHC's execution stack). For deeply nested expressions, folds, or large data schemas, this quickly triggers `StackOverflow`.
2. **Loss of Control Resumption:** Host call stacks are opaque and unmanaged. You cannot pause an evaluation midway, serialize the pending continuation to disk, step through reductions step-by-step for tracing, or implement non-local control operators (like Scheme's `call/cc` or coroutines) without complex monadic transformations.

The **Control-Environment-Continuation (CEK)** abstract machine, introduced by Matthias Felleisen and Daniel P. Friedman (1986, 1987), solves both problems by making the **continuation** an explicit, first-class data structure allocated on the heap or in an unboxed buffer rather than relying on the host language's call stack.

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

### The Three State Registers

1. **$C$ (Control):** The active syntactic expression or value currently being processed. When $C$ is an expression needing reduction (such as an application $e_1 \; e_2$), the machine evaluates subterms; when $C$ reduces to a canonical value (such as an integer literal or a closure $\langle \lambda x. e, E \rangle$), the machine pops frames from $K$ to resume evaluation.
2. **$E$ (Environment):** The lexical context mapping identifiers or de Bruijn indices to evaluated values or closures.
3. **$K$ (Continuation Stack):** An explicit stack of continuation frames representing the "rest of the computation". In a function application $e_1 \; e_2$, evaluating $e_1$ pushes an `ArgFrame(e_2, E)` onto $K$. Once $e_1$ yields a function value, evaluating $e_2$ replaces it with a `FunFrame(v_1)`.

Because state transitions $\langle C, E, K \rangle \Longrightarrow \langle C', E', K' \rangle$ are tail-recursive, the machine executes in a constant host stack frame loop (a **trampoline**).

---

## 2. Installation & Workspace Setup

The `cek` constellation is structured into eight modular Cabal packages:

| Package | Purpose | Category |
| :--- | :--- | :--- |
| **`cek-core`** | Fundamental CEK transition rules, closure algebra, and stepping trampoline | Core Engine |
| **`cek-dhall`** | CEK normalization, record projection, and substitution for Dhall expressions | Language Integration |
| **`cek-pykinos`** | Cache-line conscious environments backed by Roaring bitsets & ART trees | Performance Substrate |
| **`cek-polytropos`** | Structural row-polymorphic records with zero runtime dictionary search | Row Subsystem |
| **`cek-scheme`** | Reference Call-by-Value Scheme with `call/cc` and mutable environments | Demonstrative Interpreter |
| **`cek-mercury`** | WAM relational unification with choice points and trail unbinding | Demonstrative Interpreter |
| **`cek-oneml`** | 1ML first-class modules and functors with `MergeMorph3` existential sealing | Demonstrative Interpreter |
| **`cek-examples`** | Showcase umbrella re-exporting the three demonstrative reference interpreters | Examples Umbrella |

To build all packages and run tests within the workspace:

```bash
# Clone and enter the cek repository
cd ~/src/cek

# Build all eight packages
cabal build all

# Run comprehensive test suites across the suite
cabal test all

# Execute the 5 physical verification quality gates
./bin/cek-verify
```

---

## 3. Hands-on Tutorial: Evaluating Lambda Expressions with `cek-core`

Let us construct and evaluate expressions using `cek-core`.

### Step 1: Importing Core Types

```haskell
module Main where

import Cek.Core
import qualified Data.Map.Strict as Map
```

### Step 2: Defining an AST Expression

Consider the simple lambda term:
\[
  (\lambda x. x + 42) \; 10
\]

In `cek-core`, this expression is constructed using `Term`:

```haskell
-- Define: \x -> x + 42
let body = BinOp Add (Var "x") (LitInt 42)
let fn   = Lam "x" body
let expr = App fn (LitInt 10)
```

### Step 3: Executing with the Stepping Trampoline

To evaluate `expr`, we initialize the CEK state with an empty environment and an empty continuation stack:

```haskell
let initialState = injectExpr expr emptyEnv
let finalValue   = runCek initialState
```

### Step 4: Tracing Machine Transitions Step-by-Step

The machine transitions through the following exact discrete steps:

1. **Focus on Application:**
   \[
     \langle \text{App}(fn, \text{LitInt } 10), \emptyset, [] \rangle
   \]
   The machine pushes an argument continuation frame and focuses on the function $fn$:
   \[
     \Longrightarrow \langle fn, \emptyset, [\text{FrameArg}(\text{LitInt } 10, \emptyset)] \rangle
   \]

2. **Closure Formation:**
   Because $fn$ is a $\lambda$-abstraction, it is already a value. It forms closure $\langle fn, \emptyset \rangle$ and pops the continuation:
   \[
     \Longrightarrow \langle \text{LitInt } 10, \emptyset, [\text{FrameFun}(\langle fn, \emptyset \rangle)] \rangle
   \]

3. **Argument Evaluation:**
   `LitInt 10` is an immediate value. The machine pops `FrameFun` and binds $x \mapsto 10$ in the environment:
   \[
     \Longrightarrow \langle \text{BinOp Add } (\text{Var } "x") (\text{LitInt } 42), [x \mapsto 10], [] \rangle
   \]

4. **Primitive Reduction:**
   Evaluating the binary operation pushes subterm frames, resolves $x \mapsto 10$, and reduces $10 + 42$:
   \[
     \Longrightarrow \langle \text{ValInt } 52, [x \mapsto 10], [] \rangle
   \]
   With an empty continuation stack $[]$, the machine halts with result `52`.

---

## 4. Normalizing Dhall Expressions with `cek-dhall`

`cek-dhall` provides an industrial-grade normalization engine for Dhall expressions. Unlike upstream `dhall-haskell`, which evaluates expressions via recursive AST substitutions that incur high allocation and memory footprints on large records, `cek-dhall` normalizes terms using explicit environments and unboxed frames.

### Example: Normalizing a Configuration Record

```haskell
import Cek.Dhall
import qualified Data.Text as T

let dhallSrc = T.unlines
      [ "let Config = { port : Natural, host : Text }"
      , "let makeConfig = \\(p : Natural) -> { port = p, host = \"localhost\" }"
      , "in (makeConfig 8080).port"
      ]

-- Parse and normalize to weak head normal form (WHNF) or beta-eta normal form:
case parseDhall dhallSrc of
  Left err   -> putStrLn ("Parse error: " ++ show err)
  Right expr -> do
    let normalized = normalizeDhall expr
    print normalized  -- Output: NaturalLit 8080
```

### Key Performance Advantages:
- **No Stack Overflow on Deep ASTs:** Deeply nested `List/fold` or union matches run in flat loops.
- **Minimal Heap Allocations:** Environments share parent scopes structurally without copying maps on every lambda entry.
- **Hermetic In-Memory Execution:** No sub-process spawning or external IPC.

---

## 5. Row-Polymorphic Record Evaluation with `cek-polytropos`

When working with dynamic schemas, extensible records, or effect rows, `cek-polytropos` bridges the CEK machine with `polytropos`'s zero-overhead unboxed records:

```haskell
import Cek.Polytropos
import Polytropos

-- Records evaluate with O(1) slot projections:
-- Projecting field "host" compiles to direct array indexing rather than dictionary searches.
```

---

## 6. High-Density Environments with `cek-pykinos`

In high-throughput interpreter loops, environment lookups dominate execution time. Standard pointer-linked lists or binary search trees cause frequent CPU cache misses.

`cek-pykinos` replaces pointer-heavy environments with contiguous, unboxed representations:
- **Adaptive Radix Trees (`Pykinos.IntMap.ART`):** Cache-conscious 4-tier radix trees that fit nodes into single 64-byte CPU cache lines.
- **Roaring Bitsets (`Pykinos.Bitset.Roaring`):** Unboxed bitmasks tracking variable liveness and free variable sets.

---

## 7. The Three Demonstrative Reference Interpreters

The `cek` repository includes three standalone demonstrative interpreters illustrating how the CEK machine accommodates diverse computational paradigms:

```
                  +--------------------------------+
                  |         cek-examples           |
                  |     (Umbrella Showcase)        |
                  +---------------+----------------+
                                  |
         +------------------------+------------------------+
         |                        |                        |
         v                        v                        v
+------------------+    +------------------+    +------------------+
|    cek-scheme    |    |   cek-mercury    |    |    cek-oneml     |
| (Scheme call/cc) |    |  (WAM Unifying)  |    | (1ML First-Class)|
+------------------+    +------------------+    +------------------+
```

### 1. `cek-scheme` — First-Class Continuations
Demonstrates call-by-value Scheme with first-class continuations (`call/cc`), mutable variables (`set!`), and `Generic1` AST dissection. Capturing a continuation is as simple as reifying the current stack register $K$ into a first-class value `ValCont k`.

### 2. `cek-mercury` — Relational Logic & Backtracking
Demonstrates Warren Abstract Machine (WAM) unification, trailing, and choice points. When a unification branch fails, the machine pops choice points from $K$ and unwinds variable bindings recorded on the trail stack.

### 3. `cek-oneml` — First-Class Modules & Functors
Demonstrates Andreas Rossberg's 1ML calculus, unifying core and module languages. Functor applications and existential structure sealing are evaluated via `MergeMorph3` and dynamic hidden classes.

---

## 8. Summary & Next Steps

You now have a complete mental model and operational understanding of the `cek` ecosystem. For further details:
- Inspect the formal reduction semantics in [`docs/notes/CEK_DESIGN.md`](notes/CEK_DESIGN.md).
- Review maintenance and verification procedures in [`docs/MAINTAINER_GUIDE.md`](MAINTAINER_GUIDE.md).
- Follow the token-conservation reading funnel in [`docs/NEWBIE_GUIDE.md`](NEWBIE_GUIDE.md).
