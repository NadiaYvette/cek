# Changelog for `cek-scheme`

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to the [Haskell Package Versioning Policy (PVP)](https://pvp.haskell.org/).

## [0.1.0.0] - 2026-11-18

### Added
- Extracted `cek-scheme` as an independent example package from `cek-examples`.
- Implemented R5RS/R7RS Call-by-Value mini-interpreter with `Generic1` dissection.
- O(1) Copy-on-Write continuation capture and restoration via `captureKontSoA` and `restoreKontSoA` (`call/cc`).
- Unboxed mutable lexical environment cells (`set!`) backed by `SoAStore`.
- Full Hspec unit test suite and Hackage-compliant package manifest.
