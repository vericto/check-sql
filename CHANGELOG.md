# Changelog

All notable changes to the Vericto SQL Check action are documented here. The
format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.3.0] - 2026-10-30

**Check SQL without an account.** A new `offline` input runs
`vericto check --offline`: the engine built into the CLI applies Vericto's
standard rules on the runner, with no API key, no account and no request.
`uses: vericto/check-sql@v1` moves to 1.3.0. Workflows with a credential are
unchanged: they check online, as before.

### Added
- **`offline` input** (`auto`, `true` or `false`; default `auto`).
  - `true`: always offline. Combined with `api-key` or `oidc: true` it is a
    usage error (exit 2); a job-level `VERICTO_API_KEY` is not used (a notice
    says so). `api-url`, `timeout` and `workspace` are not used offline.
  - `auto`: online when `api-key`, a job-level `VERICTO_API_KEY` or
    `oidc: true` is set; **offline when none is**, with a warning annotation
    (in 1.2.0 that was exit 3). See "Changed" below.
  - `false`: always online; no credential is exit 3, as in 1.2.0.
  - Offline needs CLI 1.9.0 or later (1.11.0 on Windows runners). With an
    older pinned `cli-version`, `offline: true` is exit 2 and `auto` without
    a credential stays exit 3, each saying why.
- **`mode` output**: `online` or `offline`.
- **Offline in the job summary**: a `Mode` row (with the engine version read
  from the SARIF or JSON report) and one line on what an account adds
  (custom rules, business policies, sensitive columns, check history and
  audit in the dashboard). Annotations, the SARIF upload, the finding counts
  and the other outputs work offline as online.
- Self-tests on every runner with the real CLI: no account (`auto`, exit 1 on
  the fixtures' DELETE, `mode: offline`) and `offline: true` (exit 0).

### Changed
- **No credential at all now checks offline instead of failing with exit
  3**, unless `offline: false` is set. The action cannot tell an empty secret
  from a missing one, so `api-key: ${{ secrets.VERICTO_API_KEY }}` with the
  secret unset, or a pull request from a fork, now gets an offline check (and
  a warning) instead of a failure. Set `offline: false` where a missing
  credential must fail the job, as in 1.2.0.
- **A configured credential never falls back to offline.** A rejected key or
  OIDC login is still exit 3, and an unreachable API still exit 4, so a gate
  never weakens silently.
- A job-level `VERICTO_OFFLINE` still never chooses the mode: with a
  credential it is ignored, with a warning that points to `offline: true`.
- The plain-http `api-url` warning is only shown when the check runs online.
- The action's description (Marketplace) says no account is needed.
- README: a no-account quick start first, then the API key and OIDC; an
  "Offline and online" comparison and a mode table replace "Offline mode is
  not used".

## [1.2.0] - 2026-10-25

**The default CLI moves to 1.12.0, and Windows ARM64 runners are supported.**
`uses: vericto/check-sql@v1` moves to 1.2.0. Workflows that pin `cli-version`
keep the version they pin. Inputs, outputs and exit codes are unchanged.

### Security
- The default `cli-version` is now **1.12.0** (was 1.8.2). Among the CLI
  changes since 1.8.2 that reach this action: 1.12.0 updates rustls-webpki and
  webpki-roots (RUSTSEC-2026-0382, RUSTSEC-2026-0381), so the TLS connection
  to the Vericto API no longer trusts distrusted intermediates; 1.11.0 checks
  SQL files saved with a UTF-8 byte-order mark instead of letting them through
  as a parse error, and reads UTF-16 files with a BOM. See the
  [CLI changelog](https://github.com/vericto/vericto-cli/blob/main/CHANGELOG.md#1120---2026-10-22).
  The download is verified as before, against the release's `.sha256` file
  before extraction; the 1.12.0 assets were checked against `sha256.sum` and
  their Sigstore build attestations before this release.
- **A job-level `VERICTO_OFFLINE` is ignored.** CLI 1.9.0 added an offline
  mode (`--offline` or `VERICTO_OFFLINE=1`) that checks with the embedded
  engine's standard rules only, without the workspace's custom rules,
  overrides, sensitive columns or audit trail. With the variable set on the
  job, the action would have checked offline with an `api-key`, or failed with
  exit 2 with `oidc: true`. `check.sh` now unsets it before running the CLI and
  logs a warning when it was set, so the action always checks online. The
  rest of the 1.9.0 change does not affect the action: in CI a missing
  credential is still exit 3 (the action fails with 3 before the CLI runs),
  and an unreachable API is still exit 4, never an offline verdict.

### Added
- **Windows ARM64 runners** (`windows-11-arm`), with CLI 1.11.0 or later,
  which publishes a native `vericto-cli-aarch64-pc-windows-msvc.zip`. With an
  older `cli-version` on Windows ARM64, the action stops with exit 2 and says
  so instead of failing on a missing download.

### Changed
- Reports from CLI 1.9.0 and later carry the check mode: JSON has top-level
  `mode` and `engine_version`, SARIF a run `properties` bag. The action's
  outputs (`blocked`, `flagged`, `monitored`, `parse-errors`, `result`) are
  read from the same fields as before and are unchanged.
- CLI 1.11.0 reports Windows paths with `/` in SARIF and annotations, so on
  Windows runners Code Scanning annotations attach to files like on Linux.
- The test fixtures (the stand-in CLI, the `file://` release in
  `test/install-test.sh`, the versions in `test/resolve-test.sh`) and the
  example in the `cli-version` error message use 1.12.0. The CI self-test runs
  on `windows-11-arm` too, and its unreachable-API case sets
  `VERICTO_OFFLINE=1` on the step to prove it is ignored.

### Fixed
- The README and the 1.1.0 notes said the Vericto CLI was under the Elastic
  License 2.0 "up to 1.9.0". Per the CLI's `LICENSING.md`, versions 1.9.1 and
  earlier are under the Elastic License 2.0 and 1.10.0 and later under
  FSL-1.1-ALv2. The README (English and Spanish) now says so; the default CLI,
  1.12.0, is under FSL-1.1-ALv2.

## [1.1.0] - 2026-10-18

**Now open source under the Apache License 2.0.** From this version on, the
action is licensed under the Apache License, Version 2.0 (SPDX `Apache-2.0`)
instead of the Elastic License 2.0. **All previously released versions, 1.0.3
and earlier, remain under the Elastic License 2.0.** No change in behavior:
the inputs, outputs and the default `cli-version` (1.8.2) are those of 1.0.3.
`uses: vericto/check-sql@v1` moves to 1.1.0.

### Changed
- **License: Apache-2.0.** `LICENSE` is the Apache License 2.0 text from
  apache.org, verbatim, which GitHub and the Marketplace detect as
  `Apache-2.0`. New `NOTICE` (product name and copyright, Vericto S.A.S.) and
  `TRADEMARKS.md`: the license grants no right to the Vericto name or logo.
- The Vericto CLI that the action installs keeps its own license (the
  Functional Source License from CLI 1.10.0, the Elastic License 2.0 up to
  1.9.0); the README says so.
- Every script, including the test stand-in CLI, starts with
  `SPDX-FileCopyrightText` and `SPDX-License-Identifier: Apache-2.0` lines (the
  REUSE convention).
- README (License section, in English and Spanish) and CONTRIBUTING name the
  new license. Contributions are accepted under the Apache License 2.0
  (inbound = outbound, its section 5); no contributor agreement is needed.

## [1.0.3] - 2026-10-18

### Security
- The default `cli-version` is now **1.8.2** (was 1.7.1). vericto-cli 1.8.2
  fixes leaks in sanitized mode: in some dialect-specific cases (Snowflake
  and MySQL backslash escapes, MySQL double-quoted strings, Oracle
  quote-delimited strings, dollar-quoted strings, comments, prefixed literals
  and numbers, unterminated quotes) part of a literal was sent as written. In
  1.8.2 the sanitized telemetry no longer leaks literal fragments. See the
  [CLI changelog](https://github.com/vericto/vericto-cli/blob/main/CHANGELOG.md#182---2026-10-18).
  Workflows that pin `cli-version` are unaffected and keep the version they
  pin; with a `sanitized` workspace, pin 1.8.2 or later. Nothing changes for a
  workspace in `raw` mode.

### Changed
- The test fixtures (the stand-in CLI, the `file://` release in
  `test/install-test.sh`, the versions in `test/resolve-test.sh`) and the
  example in the `cli-version` error message use 1.8.2. The CI self-tests and
  the checksum gate read the version from `action.yml`, so they run against
  1.8.2.

## [1.0.2] - 2026-10-18

### Fixed
- Multi-line inputs no longer pass validation. The validators matched with
  `grep`, which works line by line, so a `cli-version`, `dialect`, `timeout`,
  `api-url`, `workspace` or `since` with a line break passed as long as one of
  its lines was valid; `check.sh` then handed the CLI one argument with a
  newline in it (not a shell injection, but validation was defeated), and
  `resolve.sh` stopped with exit 1 at `set_output` instead of the input error.
  A value containing a line feed or a carriage return, including a trailing
  one, is now an input error (exit 2) with the input's usual message. All
  validators share one whole-value helper, `matches` in `scripts/lib.sh`
  (bash `=~`, bash 3.2 and 5.x). If a workflow passes one of these inputs as a
  YAML block scalar (`dialect: |`), which adds a trailing newline, write it on
  one line instead.
- `check.sh` no longer aborts with "VA_FILES: unbound variable" (exit 1) on
  bash 4+ when `VA_FILES` is unset. Only direct runs of the script were
  affected; `action.yml` always sets it.

### Added
- Offline unit tests for every script (`test/lib-test.sh`,
  `test/resolve-test.sh`, `test/verify-checksum-test.sh`,
  `test/install-test.sh`, `test/check-test.sh`), with a stand-in CLI and a
  `file://` release fixture, run in CI on Linux and macOS and covered by
  shellcheck. Line coverage of `scripts/` measured with kcov: 21% to 97%. No
  behaviour change.

## [1.0.1] - 2026-10-12

### Changed
- Shorter `description` in `action.yml` (under 125 characters), as the GitHub
  Marketplace requires. No behaviour change.

## [1.0.0] - 2026-10-12

### Added
- Composite action wrapping `vericto check` from the Vericto CLI, pinned to
  CLI **1.7.1**, on Linux (x64, arm64), macOS (x64, arm64) and Windows (x64)
  runners.
- Install step that downloads the release asset for the runner, verifies its
  SHA-256 against the release's `.sha256` before extracting it, runs
  `gh attestation verify` when it can (advisory), and caches the verified
  download with `actions/cache`.
- Inputs: `api-key`, `oidc`, `workspace`, `files`, `changed`, `since`,
  `dialect`, `baseline`, `format`, `upload-sarif`, `api-url`, `timeout`,
  `cli-version` and `working-directory`.
- Outputs: `exit-code`, `result`, `sarif-file`, `report-file` and the finding
  counts `blocked`, `flagged`, `monitored` and `parse-errors`.
- Changed-files base for `pull_request`, `merge_group`, `push` and other
  events; glob patterns (including `**`) and directories in `files`.
- SARIF upload to Code Scanning, with paths made relative to the repository
  root, and a job summary.

[Unreleased]: https://github.com/vericto/check-sql/compare/v1.3.0...HEAD
[1.3.0]: https://github.com/vericto/check-sql/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/vericto/check-sql/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/vericto/check-sql/compare/v1.0.3...v1.1.0
[1.0.3]: https://github.com/vericto/check-sql/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/vericto/check-sql/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/vericto/check-sql/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/vericto/check-sql/releases/tag/v1.0.0
