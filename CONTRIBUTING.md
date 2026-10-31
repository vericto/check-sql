# Contributing to Vericto SQL Check

Thanks for your interest in improving the Vericto SQL Check action. This guide
covers the composite action in this repository (`uses: vericto/check-sql@v1`),
which is open source under the [Apache License 2.0](LICENSE).

## Code of Conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). Be
respectful, constructive, and technically precise.

## What belongs here

The action installs a pinned [vericto-cli](https://github.com/vericto/vericto-cli)
release, verifies its SHA-256, runs `vericto check` and uploads the report.
Contributions that fit here:

- **Inputs and outputs** — `action.yml` and the scripts behind it
  (`scripts/resolve.sh`, `install.sh`, `verify-checksum.sh`, `check.sh`, and
  the shared validators in `scripts/lib.sh`).
- **Installation and verification** — the download, the checksum gate, the
  advisory build-attestation check, the cache.
- **Runner support** — Linux, macOS and Windows runners, GNU and BSD userlands,
  bash 3.2 and 5.x.
- **The pinned CLI version** — a CLI bump ships as a new action release.
- **Documentation** — `README.md`, and the MCP Registry entry in
  `mcp-registry/`.

Contributions that belong elsewhere:

- How `vericto check` behaves (flags, report formats, exit codes) →
  [vericto-cli](https://github.com/vericto/vericto-cli).
- A statement that got the wrong verdict, a new rule, SQL parsing →
  [vericto-engine](https://github.com/vericto/vericto-engine).

## Getting started

```bash
git clone https://github.com/<you>/check-sql.git
cd check-sql
for t in lib resolve verify-checksum install check; do bash "test/$t-test.sh"; done
```

The unit tests need bash 3.2+, `git` and `jq`. They use local fixtures only:
`test/install-test.sh` serves the release download from `file://` through a
`curl` stand-in, and `test/check-test.sh` runs `check.sh` against a stand-in CLI
(`test/fixtures/fake-cli/vericto`). Nothing reaches the network or the Vericto
API.

## Development workflow

1. Fork the repo and create a branch: `feat/working-directory` or
   `fix/windows-paths`.
2. Make your change with tests.
3. Run the checks CI runs before opening a PR:
   - The unit tests, as above. CI runs them on `ubuntu-latest` and
     `macos-latest`.
   - **actionlint** and **shellcheck**, with the images CI pins (Docker):
     ```bash
     docker run --rm -v "$PWD:/repo" -w /repo \
       rhysd/actionlint@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667 -color
     docker run --rm -v "$PWD:/mnt" -w /mnt \
       koalaman/shellcheck@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d \
       -x scripts/lib.sh scripts/resolve.sh scripts/install.sh scripts/verify-checksum.sh scripts/check.sh \
       test/checksum-test.sh test/harness.sh test/lib-test.sh test/resolve-test.sh \
       test/verify-checksum-test.sh test/install-test.sh test/check-test.sh test/fixtures/fake-cli/vericto
     ```
     A new script goes on the shellcheck list in `.github/workflows/ci.yml`.
   - **Pins**: every `uses:` in `action.yml` and `.github/workflows/*.yml` is
     pinned by full commit SHA with a version comment
     (`uses: owner/repo@<40-hex SHA> # v1.2.3`), or by image digest for
     `docker://`. The `Lint` job rejects anything else.
   - **The checksum gate** against the real release asset (needs the network):
     ```bash
     bash test/checksum-test.sh "$(bash test/pinned-version.sh | cut -d= -f2)"
     ```
4. Open a PR using the template. Keep PRs focused and under ~500 lines.

CI also runs the action itself (`uses: ./`) on `ubuntu-latest`,
`ubuntu-24.04-arm`, `macos-latest`, `windows-latest` and `windows-11-arm`:
without credentials and `offline: false` (exit 3), without credentials and
`offline` left at `auto` (an offline verdict from the real CLI), with
`offline: true`, against an unreachable API with a key (exit 4, never an
offline fallback; with `VERICTO_OFFLINE=1` on the step, which the action must
ignore), with OIDC but no `id-token` permission, and with hostile inputs. The live check against the Vericto API runs only where the
`VERICTO_API_KEY` secret is available, so not on pull requests from forks.

### Rules for the scripts

- Never interpolate `${{ inputs.* }}` into a `run:` script. Pass each input
  through an environment variable, validate it with the helpers in
  `scripts/lib.sh`, and hand it to the CLI as a single argument.
- The API key reaches the CLI only through `VERICTO_API_KEY`; never put it on a
  command line or in a log.
- Keep the scripts working on bash 3.2 (the macOS runners) and on the BSD and
  GNU versions of `tar`, `sed`, `mktemp` and `sha256sum`/`shasum`.

### Coverage

CI does not gate on coverage. Line coverage of `scripts/` was measured with
[kcov](https://github.com/SimonKagstrom/kcov) at 97% when the unit tests were
added (`test/harness.sh` keeps the variables kcov's bash tracing needs). Keep
new script code covered by the offline unit tests. A case marked `xfail` is a
known bug, kept visible until it is fixed.

## Commit convention

We use [Conventional Commits](https://www.conventionalcommits.org/):

```
feat: Vericto SQL Check composite action
fix: match ** patterns with find, for the bash 3.2 on macOS runners
test: offline unit tests for every script, run in CI on Linux and macOS
ci: lint, checksum gate and self-tests on four runners
```

**Write in English** — commit subjects and bodies, code comments, test names,
identifiers, `CHANGELOG.md` entries and pull request descriptions.

## Changelog

`CHANGELOG.md` follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Add an entry under `## [Unreleased]` for any change a workflow using the action
can see (an input, an output, an exit code, the pinned CLI version, a runner),
in the section that fits (`Added`, `Changed`, `Fixed`, `Security`). Changes to
repository files that do not affect the action (CI, templates, this guide) need
no entry. Maintainers move the entries into a version section when they cut a
release.

## Pull request acceptance criteria

- ✅ Required checks pass: `Lint (actionlint, shellcheck, pins)`,
  `Unit tests, offline (ubuntu-latest)`, `Unit tests, offline (macos-latest)`,
  `Self-test (ubuntu-latest)` and
  `Checksum gate (tampered checksum and archive must fail)`. The other
  self-test runners and CodeQL run too and should be green.
- ✅ New behavior has tests, including rejected and hostile inputs.
- ✅ `CHANGELOG.md` updated under `[Unreleased]` when a workflow can see the
  change.
- ✅ New or changed inputs and outputs documented in `README.md` and
  `action.yml`.
- ✅ At least one maintainer review (CODEOWNERS requests it).

Pull requests are merged with a merge commit; squash and rebase merges are
disabled.

## Releases

Releases are cut by the maintainers:

1. Turn `## [Unreleased]` into `## [X.Y.Z] - YYYY-MM-DD` in `CHANGELOG.md`, in
   a pull request. A CLI bump changes the `# pinned-cli-version` default of
   `cli-version` in `action.yml` and the Inputs table in `README.md`.
2. After it is merged, tag the merge commit `vX.Y.Z` and push the tag.
3. The tag starts `release.yml`: it checks that `CHANGELOG.md` has the
   `## [X.Y.Z] - YYYY-MM-DD` entry and that the commit is on `main`, then moves
   the major tag (`v1`) to it, so `uses: vericto/check-sql@v1` picks up the
   release. A tag that is not a final `vX.Y.Z` does not move `v1`.
4. The GitHub release and the Marketplace listing are created by hand, with
   the `CHANGELOG.md` section as the notes.

Release tags (`v*.*.*`) are protected: once pushed, they cannot be moved or
deleted. The major tags (`v1`, `v2`, `v3`) can be moved but not deleted.

## Reporting security issues

Do **not** open a public issue for vulnerabilities. See [SECURITY.md](SECURITY.md)
or email [security@vericto.com](mailto:security@vericto.com).

## License

Vericto SQL Check is open source under the [Apache License 2.0](LICENSE) since
1.1.0 (versions 1.0.3 and earlier remain under the Elastic License 2.0). Unless
you state otherwise, a contribution you submit for inclusion is under the
Apache License 2.0, as its section 5 says, without additional terms or
conditions; no contributor agreement is needed. Add the
`SPDX-FileCopyrightText` and `SPDX-License-Identifier: Apache-2.0` header to new
scripts. For questions about licensing a contribution, write to
[legal@vericto.com](mailto:legal@vericto.com) before opening the pull request.
