# Changelog

All notable changes to `managoat_sandbox` are documented here. Format:
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/). Pre-1.0, a minor bump (`0.x` to `0.y`) may
include breaking changes and says so; patch releases are always safe to take.

Merging a version bump to `main` publishes it to hex; a PR that changes what
the package ships without a bump fails the release gate.

## [Unreleased]

## [0.2.1] - 2026-09-03

### Changed

- Raised the library coverage gate from 85% to 97% after adding deterministic
  behavioral coverage for adapter lifecycle failures, command-stream edge
  cases, session attachment, provider error normalization, and the shipped
  in-memory Fake adapter.

## [0.2.0] - 2026-09-03

### Changed

- **Breaking (frame contract).** A command stream that closes without an exit
  frame is now `{:error, %{ref: ref}, :closed_before_exit}`. It used to be
  `{:exit, %{ref: ref}, 0}`, so a command whose transport went away read as a
  clean, successful run — the failure mode that made every one of the 533 exit
  codes Fountain had recorded a synthetic zero (BinaryBourbon/fountain#880).
  `Managoat.Sandbox`, the conformance suite and the `Fake` all say the new
  thing; a consumer that matched `{:exit, _, 0}` on a dropped connection now
  gets the error frame, and `exec/4` returns
  `{:error, {:unavailable, :closed_before_exit}}` instead of the partial
  output it had collected. The reason is transient under
  `Managoat.Sandbox.Retry.transient?/1`.
- The Sprites client moves to hex `0.2.2`, which is where the close-frame
  change comes from; the pin stays exact
  (BinaryBourbon/fountain#1363).
- The E2B adapter follows the same rule for a Connect stream that ends with
  no `end` event. In `:attach` mode the shim's exit file outlives the stream,
  so a readable one still yields the real `{:exit, _, code}`; only an absent
  or unreadable file is an unknown fate.

## [0.1.1] - 2026-09-03

### Changed

- Raised the library's own-suite coverage gate to 85% after adding deterministic
  coverage for the E2B and Daytona adapters, HTTP clients, error taxonomies, and
  provider-neutral facade.

## [0.1.0] - 2026-09-02

### Added

- Extracted from Fountain (BinaryBourbon/fountain#1360).
