# Getting Started with cek: A Comprehensive Practical Guide

**Parent Strategy:** [`notes/DOC_STRATEGY.md`](notes/DOC_STRATEGY.md)  
**Corpus Inventory:** [`INDEX.md`](INDEX.md)  
**Design Monograph:** [`notes/CEK_DESIGN.md`](notes/CEK_DESIGN.md)  
**Maintainer Guide:** [`MAINTAINER_GUIDE.md`](MAINTAINER_GUIDE.md)  
**Newbie Orientation:** [`NEWBIE_GUIDE.md`](NEWBIE_GUIDE.md)  

---

## 1. Conceptual Foundations: The CEK Abstract Machine in Theory and Practice

In programming language implementation, tree-walking recursive evaluators (`eval :: Expr -> Env -> Value`) suffer from two severe structural deficiencies:

1. **Host Call-Stack Exhaustion:** Every nested function application, sub-expression reduction, or loop iteration allocates an execution frame on the host language's call stack (GHC's execution stack). For deeply nested expressions, folds, or large data schemas, this quickly triggers `StackOverflow`.
2. **Loss of Control Resumption:** Host language call stacks are opaque, unmanaged black boxes. You cannot pause an evaluation midway, serialize the pending continuation to disk, step deterministically through discrete reduction transitions for debugging or tracing, or implement non-local control operators (like Scheme's `call/cc`, coroutines, or backtracking search) without wrapping the evaluator in complex monadic transformers.

The **Control-Environment-Continuation (CEK)** abstract machine, introduced by Matthias Felleisen and Daniel P. Friedman (1986, 1987) as a successor to Peter Landin's SECD machine (1964) and Gordon Plotkin's call-by-value ISWIM calculus (1975), solves both problems by making the **continuation** an explicit, first-class data structure allocated on the heap or in an unboxed buffer rather than relying on the host language's execution stack.

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
       |       Constant host stack space: O(1) stack frames    |
       +-------------------------------------------------------+
```

### The Three State Registers

The CEK machine state is a 3-tuple $\langle C, E, K \rangle$:

1. **$C$ (Control):** The active syntactic expression or value currently under focus. When $C$ is an expression requiring reduction (such as an application $e_1 \; e_2$ or a let-binding), the machine evaluates subterms; when $C$ reduces to a canonical value (such as a literal or closure $\langle \lambda x. e, E \rangle$), the machine transitions to a return state and pops frames from $K$ to resume the surrounding computation.
2. **$E$ (Environment):** The lexical context mapping identifiers or de Bruijn indices to evaluated values or closures.
3. **$K$ (Continuation Stack):** An explicit stack of continuation frames representing the "rest of the computation". In a function application $e_1 \; e_2$, evaluating $e_1$ pushes an `FrameArg(e_2, E)` onto $K$. Once $e_1$ yields a closure, evaluating $e_2$ replaces that frame with a `FrameFun(closure)`.

Because each state transition $\langle C, E, K \rangle \Longrightarrow \langle C', E', K' \rangle$ is a tail-call, the machine executes in a constant host stack frame loop—a **trampoline**.

---

## 2. Installation & Constellation Architecture

The `cek` constellation is organized into eight modular Cabal packages meeting Hackage and Cellarius quality standards:

| Package | Purpose | Category |
| :--- | :--- | :--- |
| **`cek-core`** | Foundational CEK transition rules, closure algebra, and stepping trampoline | Core Engine |
| **`cek-dhall`** | High-throughput CEK normalization, record projection, and substitution for Dhall | Language Integration |
| **`cek-pykinos`** | Cache-line conscious environments backed by Roaring bitsets & ART trees | Performance Substrate |
| **`cek-polytropos`** | Structural row-polymorphic records with zero runtime dictionary search | Row Subsystem |
| **`cek-scheme`** | Reference Call-by-Value Scheme with $O(1)$ CoW `call/cc` and mutable lexical scope | Demonstrative Interpreter |
| **`cek-mercury`** | Reference WAM relational unification with conditional trailing and choice points | Demonstrative Interpreter |
| **`cek-oneml`** | Reference 1ML first-class modules and functors with `MergeMorph3` existential sealing | Demonstrative Interpreter |
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

## 3. Hands-on Tutorial: Evaluating Expressions with `cek-core`

Let us construct and evaluate functional terms using `cek-core`.

### Step 1: Importing the Core Engine

```haskell
module Main where

import Cek.Core
import Data.Text (Text)
import qualified Data.Text as T
```

### Step 2: Abstract Syntax and Values

The core abstract syntax in `Cek.Core` represents terms with explicit variable identifiers, lambda abstractions, applications, embedded literals, and let-bindings:

```haskell
-- | Core functional term syntax
data Term
  = Var !Text             -- ^ Variable identifier
  | Lam !Text !Term       -- ^ Anonymous lambda abstraction (\x -> e)
  | App !Term !Term       -- ^ Function application (e1 e2)
  | Lit !Literal          -- ^ Embedded literal constant
  | Let !Text !Term !Term -- ^ Let-binding (let x = e1 in e2)

-- | Primitive literal values
data Literal
  = LitNat  !Word64
  | LitInt  !Integer
  | LitBool !Bool
  | LitText !Text

-- | Evaluated runtime values
data Value
  = VClosure !Text !Term !Env -- ^ Lexical closure <x, e, E>
  | VLit !Literal             -- ^ Primitive literal value
```

### Step 3: Constructing a Lambda Term

Consider the expression:
\[
  (\lambda x. x) \; 42
\]

Constructing this term in Haskell:

```haskell
let identityFn = Lam "x" (Var "x")
let term       = App identityFn (Lit (LitInt 42))
```

Now consider a let-binding evaluating a nested computation:
\[
  \text{let } id = (\lambda y. y) \text{ in } id \; 100
\]

```haskell
let letTerm = Let "id" (Lam "y" (Var "y")) (App (Var "id") (Lit (LitInt 100)))
```

### Step 4: Stepping and Full Evaluation

To evaluate a term to canonical normal form:

```haskell
-- One-shot complete evaluation:
case evalCEK term of
  Right (VLit (LitInt val)) -> putStrLn ("Evaluated to: " ++ show val) -- 42
  Right other               -> putStrLn ("Evaluated to value: " ++ show other)
  Left err                  -> putStrLn ("Evaluation error: " ++ T.unpack err)
```

For deterministic tracing or bounded execution under resource budgets, use `runCEKWithFuel`:

```haskell
let initialState = StateEval term emptyEnv emptyCont
case runCEKWithFuel 1000 initialState of
  Right val -> print val -- VLit (LitInt 42)
  Left err  -> putStrLn ("Exceeded fuel or failed: " ++ T.unpack err)
```

### Step 5: Tracing State Transitions Step-by-Step

The machine transitions deterministically through discrete `CEKState` values (`StateEval` $\Longleftrightarrow$ `StateReturn`):

1. **Initial Evaluation State:**
   \[
     \text{StateEval } (\text{App } (\text{Lam } "x" \dots) (\text{Lit } 42)) \; \emptyset \; []
   \]
   Focusing on application pushes argument continuation frame `FrameArg (Lit 42) emptyEnv` and focuses on the function term:
   \[
     \Longrightarrow \text{StateEval } (\text{Lam } "x" (\text{Var } "x")) \; \emptyset \; [\text{FrameArg } (\text{Lit } 42) \; \emptyset]
   \]

2. **Closure Formation:**
   Because $\lambda x. x$ is an abstraction, it reduces immediately to a value `VClosure "x" (Var "x") emptyEnv` and enters return mode:
   \[
     \Longrightarrow \text{StateReturn } (\text{VClosure } "x" \dots) \; [\text{FrameArg } (\text{Lit } 42) \; \emptyset]
   \]

3. **Popping `FrameArg` to `FrameFun`:**
   Returning a value into `FrameArg` pops the frame, pushes `FrameFun (VClosure "x" ...)`, and focuses on the argument:
   \[
     \Longrightarrow \text{StateEval } (\text{Lit } 42) \; \emptyset \; [\text{FrameFun } (\text{VClosure } "x" \dots)]
   \]

4. **Literal Return & Application:**
   `Lit 42` evaluates to `VLit (LitInt 42)`. Returning into `FrameFun` binds $x \mapsto 42$ into the closure's captured environment and focuses on the body `Var "x"`:
   \[
     \Longrightarrow \text{StateEval } (\text{Var } "x") \; [("x", \text{VLit } 42)] \; []
   \]

5. **Variable Lookup & Halting:**
   Looking up $"x"$ yields `VLit (LitInt 42)`. With an empty continuation stack $[]$, the machine halts with result `VLit (LitInt 42)`.

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

> **Important Architectural Note:** Packages `cek-scheme`, `cek-mercury`, and `cek-oneml` are educational and demonstrative reference implementations. They showcase how higher-order control flow (`call/cc`), relational backtracking, and typed first-class modules compile onto unboxed CEK data structures. They are provided primarily as executable architectural examples within the `cek` ecosystem documentation.

### 7.1 `cek-scheme` — First-Class Continuations and Generic1 Dissection

`cek-scheme` demonstrates how a Call-by-Value language combines automatic polynomial functor dissection (`Dissectable` derived via GHC's `Generic1`) for left-to-right expression evaluation with explicit control effects (`SCallCC`) and mutable lexical variables (`SSet`):

1. **Pure Syntactic Spines:** Arithmetic operations (`SAdd`, `SSub`, `SMul`), relational comparisons (`SEq`), and sequencing (`SSeq`) require zero manual frame management; they are evaluated automatically by GHC's derived `Generic1` dissection.
2. **First-Class Continuations (`call/cc`):** Continuations capture the unrolled 32-frame `KontStack` in strictly $O(1)$ time via Copy-on-Write (`captureKontSoA`). Invoking a captured continuation reinstates execution context immediately with zero stack unwinding.
3. **Mutable Lexical Scope (`set!`):** Lexical variables occupy mutable cells allocated in the unboxed `SoAStore`.

#### Worked Example: Early-Exit `call/cc`

Consider escaping early from deep within an addition chain:
\[
  100 + (\text{call/cc} \; (\lambda k. 10 + k \; 42)) = 142
\]

```haskell
import Cek.Scheme
import Data.Int (Int32)

-- Define the receiver lambda: \k -> 10 + (k 42)
-- Var 0 references the captured continuation k
let receiver = In (SLam 1 (In (SAdd (In (SLit 10)) (In (SApp (In (SVar 0)) [In (SLit 42)])))))
let term     = In (SAdd (In (SLit 100)) (In (SCallCC receiver)))

-- Evaluate with 100 fuel steps:
case evalScheme 100 term of
  Right (Right val) -> print (val :: Int32) -- Output: 142
  Right (Left err)  -> putStrLn ("Evaluation error: " ++ show err)
  Left err          -> putStrLn ("Runtime fault: " ++ show err)
```

#### Worked Example: Mutable State with `set!`

```haskell
-- let x = 10 in (set! 0 25 ; x) = 25
let body = In (SSeq (In (SSet 0 (In (SLit 25)))) (In (SVar 0)))
let term = In (SLet (In (SLit 10)) body)

-- Evaluates to 25:
evalScheme 100 term -- Right (Right 25)
```

---

### 7.2 `cek-mercury` — Relational Logic, WAM Trailing, and Choice Points

`cek-mercury` implements a relational unification and search engine inspired by the Warren Abstract Machine (WAM) and Mercury's deterministic execution models, executing entirely over unboxed CEK data structures:

1. **Term Allocation Heap:** Mapped onto the 4096-cell chunked `SoAStore`.
2. **Clause Dispatch Stack:** Mapped onto the unrolled 32-frame `KontStack`.
3. **WAM Conditional Trailing:** Bound variables allocate trail entries only if their address precedes the most recent choice point watermark (`heapWatermark`), bypassing trail overhead for transient intra-clause bindings.
4. **Delimited Commits (`semidet`):** Mercury's deterministic commits (`GOnce`) prune intermediate choice points instantaneously by resetting the choice point watermark.

#### Worked Example: Nondeterministic Disjunction and Pruning

```haskell
import Cek.Mercury

-- Goal: q(X) :- X = 1 ; X = 2 ; X = 3
let goal = GDisj [GUnify (LVar 0) (LLit 1), GUnify (LVar 0) (LLit 2), GUnify (LVar 0) (LLit 3)]

-- Find all solutions with 10 fuel steps and 1 variable:
let solutions = solveMercury 10 1 goal
print solutions -- [[Just 1], [Just 2], [Just 3]]

-- Pruning disjunctions with GOnce (semidet cut):
let cutGoal = GOnce (GDisj [GUnify (LVar 0) (LLit 1), GUnify (LVar 0) (LLit 2)])
print (solveMercury 10 1 cutGoal) -- [[Just 1]]
```

---

### 7.3 `cek-oneml` — First-Class Modules, Functors, and Existential Sealing

`cek-oneml` implements the core of Andreas Rossberg's *"1ML — Core and the Modules in the Same Language"* (ICFP 2015), executing first-class structures, signatures, and functors directly over unboxed data structures:

1. **Flat Structural Layouts:** Structures and signatures are flat arrays of lazy cells indexed by `FieldId` and mapped to `SchemaId` identifiers in `Pykinos.Schema.HiddenClass`.
2. **Existential Sealing (`Mod :> Sig`):** Computes a domain restriction (`OpRestrict`) in $O(|Sig|)$ time. For every abstract type field (`SpecAbstract`), the evaluator mints a fresh skolem constant (`CT_WNeu`) in `SoAStore`, concealing the underlying concrete type without dynamic wrapper closures.
3. **Module Functors:** Functors are ordinary first-class functions parameterized over module records.

#### Worked Example: Module Projection and Functor Application

```haskell
import Cek.OneML
import qualified Data.Primitive.PrimArray as Prim
import qualified Data.Primitive.SmallArray as Small
import Pykinos.Schema.HiddenClass (FieldId(..), SchemaId(..))

-- Define schema mapping field 10 to offset 0
let schemaMap (SchemaId 1) = Prim.primArrayFromList [10]
    schemaMap _            = Prim.primArrayFromList []
    internSchema _         = SchemaId 1

-- Functor: \(m : {val x : Int}) -> m.x
let fTerm   = MFunctor (MLit 0) (MProj (MVar 0) (FieldId 10))
let argTerm = MStruct (SchemaId 1) (Small.smallArrayFromList [MLit 77])
let appTerm = MApp fTerm argTerm

-- Evaluates to V1Lit 77:
print (evalOneML schemaMap internSchema appTerm) -- V1Lit 77
```

---

## 8. Summary & Theoretical Roadmap

You now have a complete mental model and operational understanding of the `cek` ecosystem. For further details:

- Inspect the formal reduction semantics in [`docs/notes/CEK_DESIGN.md`](notes/CEK_DESIGN.md).
- Review maintenance and verification procedures in [`docs/MAINTAINER_GUIDE.md`](MAINTAINER_GUIDE.md).
- Follow the token-conservation reading funnel in [`docs/NEWBIE_GUIDE.md`](NEWBIE_GUIDE.md).
- Verify all physical gates with `./bin/cek-verify`.
