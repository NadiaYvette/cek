# cek Maintainer Guide

**Corpus Inventory:** [`INDEX.md`](INDEX.md)  
**Design Monograph:** [`notes/CEK_DESIGN.md`](notes/CEK_DESIGN.md)  
**Attribution Standards:** [`notes/COMMIT_ATTRIBUTION.md`](notes/COMMIT_ATTRIBUTION.md)  
**Documentation Policy:** [`notes/DOC_STRATEGY.md`](notes/DOC_STRATEGY.md)  
**Tutorial Track:** [`TUTORIAL.md`](TUTORIAL.md)  

---

## 1. Scope & Maintainer Invariants

As a maintainer of `cek`, you are responsible for preserving the integrity, performance, and documentation standards of the eight-package suite:
1. **Zero Host Stack Degradation:** All core reduction loops must remain strictly tail-recursive trampolines. No tree-walking evaluations may be merged into `cek-core` or `cek-dhall`.
2. **Deterministic Airgapped Operation:** No network calls, telemetry, or external compiler invocations during runtime evaluation.
3. **Hackage Distribution Readiness:** Every package in the suite must maintain 100% Hackage compliance with zero `cabal check` warnings or errors.
4. **Physical Verification Gates:** Every commit must pass all five verification gates enforced by `./bin/cek-verify`.

---

## 2. The Five Physical Verification Gates

The repository root provides the automated verification harness [`./bin/cek-verify`](../bin/cek-verify). It executes five non-negotiable gates:

```
[1/5] HLint Static Analysis Gate (0 hints)
  │
  ▼
[2/5] Full Cabal Test Suites (all 8 packages: 100% PASS)
  │
  ▼
[3/5] Tagref Cross-Reference Integrity Gate (0 dead refs)
  │
  ▼
[4/5] Markdown Link & Anchor Integrity Gate (0 broken links)
  │
  ▼
[5/5] CLOC Comment Density Gate (>= 50.0% in production code)
```

### Running the Full Verification Gate

```bash
./bin/cek-verify
```

### Running Individual Gates During Development

- **HLint Analysis:**
  ```bash
  hlint packages/*/src
  ```
- **Targeted Test Suites:**
  ```bash
  cabal test cek-core cek-dhall cek-scheme cek-mercury cek-oneml
  ```
- **Tagref Cross-References:**
  ```bash
  ./bin/cek-tagref
  ```
- **Markdown Link Integrity:**
  ```bash
  ./bin/cek-linkcheck --quiet
  ```
- **Comment Density Audit:**
  ```bash
  ./bin/cek-cloc --quiet --check
  ```

---

## 3. Hackage Readiness & PVP Governance

Every package in the `cek` workspace must conform to strict Package Versioning Policy (PVP) rules:

1. **Dependency Upper & Lower Bounds:**
   - Every external dependency in `build-depends` must declare both lower and upper bounds:
     `containers >= 0.6 && < 0.9`, `text >= 2.0 && < 2.2`.
   - Internal inter-package dependencies must declare exact PVP bounds:
     `cek-core >= 0.1.0.0 && < 0.2`.
2. **Metadata Fields:**
   - `synopsis`, `description`, `category`, `maintainer`, `homepage`, `bug-reports`, and `source-repository head` (with `subdir`) are strictly required.
   - `extra-doc-files` must include both `README.md` and `CHANGELOG.md`.
3. **Auditing with Cabal Check:**
   ```bash
   for pkg in packages/*; do
     (cd "$pkg" && cabal check)
   done
   ```
   Output must show `No errors or warnings; this package complies with Hackage standards.`

---

## 4. Benchmarking & Dhall Performance Profiling

A primary objective of `cek` is solving the Dhall interpretation performance and memory footprint scaling bottlenecks (e.g. issue #1385).

### Performance Test Harness

Maintainers must verify performance before merging optimizations to normalization rules:
1. **Heap Allocation Profiling:**
   ```bash
   cabal build cek-dhall --enable-profiling
   cabal run cek-dhall:bench -- +RTS -p -hc -RTS
   hp2ps -c bench.hp && ps2pdf bench.ps
   ```
2. **Continuation Stack Bounding:**
   - Ensure the max continuation stack depth scales linearly $O(D)$ with AST expression depth, and that resolved values trigger immediate frame collapse without garbage retention.

---

## 5. Commit Attribution & The Two-File Loop

- **Attribution Trailers:** All commits generated with AI pair programming assistance must include an RFC 2822 compliant trailer:
  ```
  Assisted-by: Antigravity (Google DeepMind / Gemini 3.8 Flash)
  ```
- **The Two-File Loop:** Update [`PLAN.md`](../PLAN.md) and [`STATE.md`](../STATE.md) at the end of each session to record the active operational frontier, resolved decisions, and test results.
