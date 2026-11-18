# cek Documentation Index

Welcome to the `cek` technical documentation corpus.

The `cek` workspace provides high-performance, tail-recursive abstract machines derived from the classical **Control-Environment-Continuation (CEK)** machine of Matthias Felleisen and Daniel P. Friedman (1986, 1987), tailored for fast, memory-bounded interpretation and strong $\beta\eta$-normalization of functional languages and Dhall configurations.

---

## Core Orientation & Reading Paths

- [`README.md`](../README.md) — High-level workspace overview, architecture, and quick start.
- [`AGENTS.md`](../AGENTS.md) — AI coding assistant guidance, rules, and bounded context pointers.
- [`PLAN.md`](../PLAN.md) — Strategic roadmap and phase delivery schedule.
- [`STATE.md`](../STATE.md) — Active operational session frontier and verification ledger.
- [`TUTORIAL.md`](TUTORIAL.md) — Step-by-step tutorial track from basic $\lambda$-calculus to Dhall normalization.
- [`NEWBIE_GUIDE.md`](NEWBIE_GUIDE.md) — Token-conservation funnel, mental model, and common gotchas.
- [`MAINTAINER_GUIDE.md`](MAINTAINER_GUIDE.md) — Maintenance runbook, 5 physical verification gates, and release procedures.

---

## Design Notes (`docs/notes/`)

- [`CEK_DESIGN.md`](notes/CEK_DESIGN.md) — Canonical architectural design monograph: historical lineage, formal state transitions ($\longrightarrow_{CEK}$), Dhall normalization mechanics, and literature bibliography.
- [`DOC_STRATEGY.md`](notes/DOC_STRATEGY.md) — Documentation strategy, 12 canonical documents, and precedence rules.
- [`COMMIT_ATTRIBUTION.md`](notes/COMMIT_ATTRIBUTION.md) — Commit attribution standards and RFC 2822 trailer specification.

---

## Active Package Inventory

The workspace is organized into eight modular Cabal packages across four functional tiers:

### 1. Core Engine
- [`packages/cek-core/`](../packages/cek-core/) — Foundational Felleisen-Friedman Control-Environment-Continuation abstract machine state transitions, closure algebra, and stepping trampoline.

### 2. Language & Environment Integrations
- [`packages/cek-dhall/`](../packages/cek-dhall/) — High-throughput Dhall expression normalization, record projection, and environment-based substitution.
- [`packages/cek-pykinos/`](../packages/cek-pykinos/) — Cache-line aligned blocked environments backed by Roaring bitsets and Adaptive Radix Trees (ART).
- [`packages/cek-polytropos/`](../packages/cek-polytropos/) — Structural extensible records with zero-overhead compile-time literal index synthesis.

### 3. Demonstrative Reference Interpreters
- [`packages/cek-scheme/`](../packages/cek-scheme/) — Call-by-Value Scheme (R5RS) with first-class continuations (`call/cc`), mutable environments (`set!`), and `Generic1` dissection.
- [`packages/cek-mercury/`](../packages/cek-mercury/) — Warren Abstract Machine (WAM) relational unification with conditional trailing and `KontStack` choice points.
- [`packages/cek-oneml/`](../packages/cek-oneml/) — Andreas Rossberg's 1ML first-class modules and functors with `MergeMorph3` existential sealing.

### 4. Showcase Umbrella
- [`packages/cek-examples/`](../packages/cek-examples/) — Umbrella showcase package re-exporting the three reference interpreters with backwards compatibility.
