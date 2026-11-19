# Changelog for `cek-oneml`

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to the [Haskell Package Versioning Policy (PVP)](https://pvp.haskell.org/).

## [0.1.0.2] - 2026-11-19

### Changed
- Bump package version to 0.1.0.2 to synchronize forge releases, CI, and Hackage upload artifacts.
- Dual-license package under EUPL-1.2 OR Apache-2.0.
- Elaborate documentation corpus to Cellarius standards.

## [0.1.0.0] - 2026-11-18

### Added
- Extracted `cek-oneml` as an independent example package from `cek-examples`.
- Implemented Andreas Rossberg's 1ML first-class module system over CEK.
- Flat `SchemaId`-indexed structures backed by `Pykinos.Schema.HiddenClass`.
- Existential sealing (`Mod :> Sig`) via `MergeMorph3` restriction plans (`OpRestrict`).
- First-class module functors and projections without dynamic wrapper closures.
- Full Hspec test suite and Hackage-compliant package manifest.
