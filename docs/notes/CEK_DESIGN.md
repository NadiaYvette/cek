# CEK Architectural Design Monograph

**Status:** CANONICAL ARCHITECTURAL DESIGN NOTE · November 2026  
**Component:** `cek` (`cek-core`, `cek-dhall`, `cek-pykinos`, `cek-polytropos`, `cek-scheme`, `cek-mercury`, `cek-oneml`, `cek-examples`)  
**Maintainer:** Nadia Yvette Chambers <nadia.yvette.chambers@ik.me>  
**Corpus Inventory:** [`../INDEX.md`](../INDEX.md)  
**Parent Strategy:** [`DOC_STRATEGY.md`](DOC_STRATEGY.md)  
**Tutorial:** [`../TUTORIAL.md`](../TUTORIAL.md)  

---

## 1. Executive Summary & Historical Lineage

The `cek` workspace provides high-performance, tail-recursive abstract machines derived from the classical **Control-Environment-Continuation (CEK)** machine of Matthias Felleisen and Daniel P. Friedman (1986, 1987). It is designed to serve as the evaluation and strong normalization engine across the Cellarius constellation (`plans`, `penelope`, `polytropos`, `pykinos`, `gargamelle`).

### Historical Lineage of Abstract Evaluation Machines

```
  Peter Landin (1964)
  SECD Machine: Stack, Environment, Code, Dump
          │
          │ (Elimination of redundant Stack/Dump registers;
          │  introduction of linear continuation stack)
          ▼
  Matthias Felleisen & Daniel P. Friedman (1986, 1987)
  CEK Machine: Control, Environment, Continuation
          │
          │ (Derivation via Reynolds defunctionalization
          │  and Danvy refocusing of small-step semantics)
          ▼
  Ager, Biernacki, Danvy, & Midtgaard (2003)
  Systematic CEK Derivation from Reduction Semantics
          │
          │ (Zero-allocation unboxed contiguous frames,
          │  blocked ART environments, and literal row evidence)
          ▼
  CEK Suite (Cellarius Constellation, 2026)
  Industrial CEK Engine for Dhall, Scheme, Mercury, and 1ML
```

1. **Landin's SECD Machine (1964):** Peter Landin's SECD machine was the first abstract machine designed for the $\lambda$-calculus. However, SECD maintained four separate registers—Stack, Environment, Code, and Dump—where the Stack and Dump frequently duplicated control information, incurring unnecessary allocation and stack dumping overhead.
2. **The CEK Machine (1986):** Felleisen and Friedman observed that the Stack and Dump could be unified into an explicit linear **continuation stack** ($K$). By decomposing states into $\langle C, E, K \rangle$, every transition step becomes tail-recursive, mapping naturally to register moves in an iterative trampoline.
3. **Defunctionalization & Refocusing (2001, 2003):** Olivier Danvy, Mads Sig Ager, and colleagues proved that the CEK machine is the direct Reynolds defunctionalization of a call-by-value structural operational semantics evaluator with refocusing, establishing firm theoretical guarantees of semantic preservation and progress.

---

## 2. Formal CEK Machine Semantics

{- Note [Felleisen-Friedman CEK Abstract Machine]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
[tag:note-core-architecture]
The classical CEK state is a 3-tuple $\langle C, E, K \rangle$:

* **$C$ (Control):** The current expression or AST term being evaluated. In Dhall,
  this encompasses variables, $\lambda$-abstractions, applications, let-bindings,
  records, unions, field selections, and built-in operators.
* **$E$ (Environment):** An unboxed de Bruijn index or identifier environment mapping
  free variables to values or closures $\langle C', E' \rangle$.
* **$K$ (Continuation):** An explicit stack of continuation frames representing the
  evaluation context / pending reductions (eliminating host call-stack consumption).
-}

### Formal Syntax

\[
\begin{array}{rrcl}
\text{Expressions} & e & ::= & x \mid \lambda x. e \mid e_1 \; e_2 \mid c \mid \text{let } x = e_1 \text{ in } e_2 \mid e_1 \oplus e_2 \\
\text{Values} & v & ::= & c \mid \langle \lambda x. e, E \rangle \\
\text{Environments} & E & ::= & \emptyset \mid E[x \mapsto v] \\
\text{Frames} & F & ::= & \text{FrameArg}(e, E) \mid \text{FrameFun}(v) \mid \text{FrameLet}(x, e, E) \mid \text{FrameOp}_1(\oplus, e, E) \mid \text{FrameOp}_2(\oplus, v) \\
\text{Continuations} & K & ::= & [] \mid F : K
\end{array}
\]

### State Transition Rules ($\longrightarrow_{CEK}$)

The operational behavior of `cek-core` is governed by seven canonical deterministic transition rules:

1. **Variable Lookup:**
   \[
     \langle x, E, K \rangle \Longrightarrow \langle E(x), E, K \rangle
   \]
   When the control register $C$ encounters a variable $x$, it retrieves the bound value from the lexical environment $E$.

2. **Application (Left Subterm Focus):**
   \[
     \langle e_1 \; e_2, E, K \rangle \Longrightarrow \langle e_1, E, \text{FrameArg}(e_2, E) : K \rangle
   \]
   To evaluate an application, the machine focuses on the function subterm $e_1$, pushing the unevaluated argument $e_2$ and its environment $E$ onto continuation stack $K$.

3. **Function Argument Shift:**
   \[
     \langle v_1, E, \text{FrameArg}(e_2, E') : K \rangle \Longrightarrow \langle e_2, E', \text{FrameFun}(v_1) : K \rangle
   \]
   Once the function term evaluates to canonical value $v_1$, the machine shifts focus to evaluate the argument term $e_2$, recording $v_1$ in a `FrameFun` frame.

4. **Beta-Reduction ($\beta$-Step):**
   \[
     \langle v_2, E'', \text{FrameFun}(\langle \lambda x. e, E' \rangle) : K \rangle \Longrightarrow \langle e, E'[x \mapsto v_2], K \rangle
   \]
   When both function and argument are evaluated, the machine binds parameter $x \mapsto v_2$ in the closure's captured environment $E'$, and focuses on body $e$ under the original continuation $K$.

5. **Let Binding:**
   \[
     \langle \text{let } x = e_1 \text{ in } e_2, E, K \rangle \Longrightarrow \langle e_1, E, \text{FrameLet}(x, e_2, E) : K \rangle
   \]
   \[
     \langle v_1, E', \text{FrameLet}(x, e_2, E) : K \rangle \Longrightarrow \langle e_2, E[x \mapsto v_1], K \rangle
   \]

6. **Primitive Operations:**
   \[
     \langle e_1 \oplus e_2, E, K \rangle \Longrightarrow \langle e_1, E, \text{FrameOp}_1(\oplus, e_2, E) : K \rangle
   \]
   \[
     \langle v_1, E', \text{FrameOp}_1(\oplus, e_2, E) : K \rangle \Longrightarrow \langle e_2, E, \text{FrameOp}_2(\oplus, v_1) : K \rangle
   \]
   \[
     \langle v_2, E'', \text{FrameOp}_2(\oplus, v_1) : K \rangle \Longrightarrow \langle \delta(\oplus, v_1, v_2), E'', K \rangle
   \]

7. **Terminal Halting:**
   \[
     \langle v, E, [] \rangle \Longrightarrow v
   \]
   When the control register holds a canonical value and the continuation stack is empty, evaluation terminates successfully.

---

## 3. High-Throughput Dhall Normalization in `cek-dhall`

Dhall is a programmable configuration language that is total (guaranteed to terminate without infinite loops). However, upstream `dhall-haskell` relies on recursive substitution functions (`subst`) across AST syntax trees:
- **The Alpha-Renaming / Substitution Bottleneck:** Substituting variable occurrences requires recursively traversing whole syntax subtrees, triggering extensive allocations, pointer-chasing, and GC pressure.
- **Record Projection Blowup:** Projecting fields out of large records or traversing nested schema hierarchies repeatedly duplicates intermediate subterms.

### The `cek-dhall` Architectural Solution

1. **Environment-Based Substitution:** In `cek-dhall`, variables are resolved via lexical environments $E$ rather than eager syntactic substitution. Subterms remain shared in memory.
2. **$\beta\eta$-Strong Normalization:** To fully normalize an open expression under binders (normal form rather than weak head normal form), `cek-dhall` employs **symbolic continuation frames**:
   - When evaluating under a binder $\lambda x. e$, the machine extends the environment with a fresh neutral variable $x^\star$, normalizes the body, and re-abstracts $\lambda x. e'$.
3. **Contiguous Frame Allocation:** Continuation stacks are represented using unboxed vectors or compact linked frames that maximize L1/L2 cache locality.

---

## 4. Blocked Memory & Row Polymorphism Integration

The `cek` workspace coordinates closely with two foundational sister projects:

### 1. `cek-pykinos`: Cache-Conscious Environments
Instead of using standard linked lists or boxed Map trees for environments $E$, `cek-pykinos` leverages `pykinos-core`:
- **Adaptive Radix Trees (`Pykinos.IntMap.ART`):** De Bruijn index lookups execute in $O(1)$ depth across cache-aligned nodes (`Node4`, `Node16`, `Node48`, `Node256`).
- **Roaring Bitsets (`Pykinos.Bitset.Roaring`):** Variable liveness and free identifier sets are packed into contiguous 64 KiB chunks, enabling instant bitwise union and intersection during closure capture.

### 2. `cek-polytropos`: Unboxed Row Records
`cek-polytropos` bridges CEK record evaluation with `polytropos`:
- Records are stored in contiguous `SmallArray Any` payloads.
- Record projection (`r.field`) does not perform string dictionary lookups at runtime; `polytropos-plugin` synthesizes literal integer slot offsets during GHC compilation.

---

## 5. The Three Demonstrative Reference Interpreters

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

### 1. `cek-scheme`: First-Class Continuations & Generic1 Dissection
- **Module:** `Cek.Scheme` (aliased as `Cek.Examples.Scheme`)
- **Semantics:** Call-by-Value Scheme (R5RS subset) with first-class continuations (`call/cc`), mutable variables (`set!`), and `Generic1` dissection.
- **Mechanism:** Reifying continuation $K$ into a value `ValCont k` makes non-local jumps and coroutine multitasking trivial.

### 2. `cek-mercury`: Relational Logic & Choice Points
- **Module:** `Cek.Mercury` (aliased as `Cek.Examples.Mercury`)
- **Semantics:** Warren Abstract Machine (WAM) relational unification with conditional trailing and `KontStack` choice points.
- **Mechanism:** When unification fails, the machine pops choice points from $K$ and unwinds variable bindings recorded on the trail.

### 3. `cek-oneml`: First-Class Modules & Functors
- **Module:** `Cek.OneML` (aliased as `Cek.Examples.OneML`)
- **Semantics:** Andreas Rossberg's 1ML calculus, unifying core and module languages.
- **Mechanism:** Functor applications and existential structure sealing are evaluated via `MergeMorph3` and `Pykinos.Schema.HiddenClass`.

---

## 6. Design Invariants & Formal Guarantees

- **D1 (Constant Host Stack Space):** All machine executions run in the tail-recursive trampoline loop with $O(1)$ host stack consumption.
- **D2 (Soundness & Preservation):** For well-typed inputs, if $\langle e, \emptyset, [] \rangle \Longrightarrow^* v$, then $\vdash v : \tau$ whenever $\vdash e : \tau$.
- **D3 (Determinism):** Every machine state matches at most one transition rule.
- **D4 (Zero Metered LLM Calls):** Pure, hermetic, deterministic execution under airgapped conditions.
- **D5 (Hackage & Verification Compliance):** All packages maintain 0 errors/warnings under `cabal check` and pass `./bin/cek-verify`.

---

## 7. Selected References

1. **Felleisen, M., & Friedman, D. P. (1986).** *Control Operators, the SECD-Machine, and the $\lambda$-Calculus.* In Formal Description of Programming Concepts III (pp. 193-217). North-Holland.
2. **Felleisen, M., & Friedman, D. P. (1987).** *A Calculus for Value-Passing Programming Languages.* Research Report No. 219, Indiana University.
3. **Landin, P. J. (1964).** *The Mechanical Evaluation of Expressions.* The Computer Journal, 6(4), 308-320.
4. **Danvy, O., & Nielsen, L. R. (2001).** *Defunctionalization at Work.* In ACM SIGPLAN International Conference on Functional Programming (ICFP) (pp. 162-174).
5. **Ager, M. S., Biernacki, D., Danvy, O., & Midtgaard, J. (2003).** *From Abstract Machines to Abstract Machines: Deriving the CEK Machine from Operational Semantics.* BRICS Report Series, 10(27).
6. **Flanagan, C., Sabry, A., Duba, B. F., & Felleisen, M. (1993).** *The Essence of Compiling with Continuations.* In ACM SIGPLAN Conference on Programming Language Design and Implementation (PLDI) (pp. 237-247).
7. **Plotkin, G. D. (1975).** *Call-by-name, Call-by-value and the $\lambda$-Calculus.* Theoretical Computer Science, 1(2), 125-159.
8. **Rossberg, A. (2018).** *1ML — Core and the Modules United (F-ing First-Class Modules).* Journal of Functional Programming, 28, e12.
9. **Warren, D. H. D. (1983).** *An Abstract Prolog Instruction Set.* Technical Note 309, SRI International.
