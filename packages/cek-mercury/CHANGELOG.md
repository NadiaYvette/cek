# Changelog for `cek-mercury`

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to the [Haskell Package Versioning Policy (PVP)](https://pvp.haskell.org/).

## [0.1.0.0] - 2026-11-18

### Added
- Extracted `cek-mercury` as an independent example package from `cek-examples`.
- Implemented Warren Abstract Machine (WAM) relational unification engine.
- Conditional trailing on monotonic `SoAStore` cell allocations.
- Delimited choice points and nondeterministic search over unrolled `KontStack`.
- Support for `semidet` deterministic cut / commit (`GOnce`).
- Full Hspec test suite and Hackage-compliant package manifest.
