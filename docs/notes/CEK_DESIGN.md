# CEK Architectural Design Monograph

**Status:** ARCHITECTURAL DESIGN NOTE · November 2026  
**Component:** `cek` (`cek-core`, `cek-dhall`)  
**Maintainer:** Nadia Yvette Chambers <nadia.yvette.chambers@ik.me>  
**Index:** [`../INDEX.md`](../INDEX.md)

---

## 1. Executive Summary & Purpose

`cek` provides high-performance, tail-recursive abstract machines derived from the classical **Control-Environment-Continuation (CEK)** machine of Felleisen and Friedman (1986/1987), tailored specifically for:
1. Fast, memory-bounded interpretation and strong normalization ($\beta\eta$-reduction) of typed functional programming languages.
2. High-throughput in-memory evaluation of **Dhall** expressions without process spawning or external toolchain overhead.
3. Hermetic integration with the Nadiverse orchestrator suite (`plans`, `sarutahiko`/`yamaarashi`, `penelope`, `polytropos`).

---

## 2. Theoretical Foundations

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

### State Transitions

1. **Variable Lookup:**
   \[
     \langle x, E, K \rangle \Longrightarrow \langle \text{lookup}(x, E), K \rangle
   \]
2. **Abstraction / Value:**
   \[
     \langle \lambda x. e, E, K \rangle \Longrightarrow \text{applyCont}(K, \langle \lambda x. e, E \rangle)
   \]
3. **Application:**
   \[
     \langle e_1 \; e_2, E, K \rangle \Longrightarrow \langle e_1, E, \text{FrameArg}(e_2, E) : K \rangle
   \]
4. **Continuation Return:**
   \[
     \text{applyCont}(\text{FrameArg}(e_2, E) : K, v_1) \Longrightarrow \langle e_2, E, \text{FrameFun}(v_1) : K \rangle
   \]
   \[
     \text{applyCont}(\text{FrameFun}(\langle \lambda x. e, E' \rangle) : K, v_2) \Longrightarrow \langle e, E'[x \mapsto v_2], K \rangle
   \]

---

## 3. Package Hierarchy

```
cek/
├── packages/
│   ├── cek-core/
│   │   ├── src/Cek/
│   │   │   └── Core.hs       -- Base CEK machine state transitions & closure algebra
│   │   └── test/Main.hs
│   └── cek-dhall/
│       ├── src/Cek/
│       │   └── Dhall.hs      -- Dhall AST normalization & builtin dispatch
│       └── test/Main.hs
```

---

## 4. Design Invariants

- **D1 (Tail-Recursive Trampoline):** Step transitions execute in constant host stack space.
- **D2 (Zero Metered LLM Calls):** Pure deterministic compilation and interpretation under airgapped execution.
- **D3 (Dhall Compliance):** Faithful normalization matching the standard Dhall $\beta\eta$-reduction semantics.
- **D4 (Zero-Hint Cleanliness):** HLint 0-hint policy enforced across all source modules.
