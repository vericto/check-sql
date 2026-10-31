# Vericto SQL Check

A GitHub Action that checks the SQL in your pull requests (migrations, ad-hoc
scripts, generated queries) before it runs anywhere: offline against
[Vericto](https://vericto.com)'s standard rules, with no account, or online
against your Vericto workspace's rules. Findings appear as Code Scanning
annotations on the PR, and a blocked statement fails the job.

The action wraps [`vericto check`](https://github.com/vericto/vericto-cli) from
the Vericto CLI. It downloads a pinned CLI release, verifies its SHA-256 before
extracting it, runs the check and uploads the SARIF report.

- Works on Linux (x64, arm64), macOS (x64, arm64) and Windows (x64, arm64)
  runners.
- Checks only the `*.sql` files a PR changes by default, or the files you list.
- Works without an account: offline, the CLI's built-in engine applies the
  standard rules on the runner, and no SQL leaves it.
- With an account, authenticates with an API key or with GitHub OIDC (no
  stored secret) and applies your workspace's rules.
- Exits with the CLI's code, so a block fails the build and an outage is not
  mistaken for a pass.

## Quick start (no account)

Add `.github/workflows/vericto.yml`:

```yaml
name: Vericto SQL check

on:
  pull_request:
    paths: ["**/*.sql"]

permissions:
  contents: read
  security-events: write # upload SARIF to Code Scanning
  actions: read          # needed by the SARIF upload in private repositories

jobs:
  vericto:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0 # full history, so the PR's changed files can be diffed

      - uses: vericto/check-sql@v1
        with:
          offline: true
```

That is the whole setup: no sign-up, no API key, no secret. The action checks
the `*.sql` files the PR changes with Vericto's standard rules (`dialect`
defaults to postgres), on the runner, and the findings show up on the PR. An
unbounded `DELETE` or `UPDATE` blocks; schema changes (DROP, ALTER, TRUNCATE)
are flagged. See [Offline and online](#offline-and-online) for what an
account adds.

Leaving out `offline: true` works too: with no credential configured, the
action checks offline on its own, with a warning that says so (see
[Which mode a run uses](#which-mode-a-run-uses)).

## Quick start (API key)

Online, the action checks against your workspace's rules: your custom rules
and overrides, business policies and sensitive columns, and every check is
recorded in the dashboard.

1. Create an API key with the `ci_dryrun:execute` scope in the Vericto
   dashboard ([API keys](https://vericto.com/docs/api-keys)).
2. Add it to the repository as a secret named `VERICTO_API_KEY`
   (Settings, Secrets and variables, Actions).
3. In the workflow above, pass the key instead of `offline: true`:

```yaml
      - uses: vericto/check-sql@v1
        with:
          api-key: ${{ secrets.VERICTO_API_KEY }}
```

To make a missing secret fail the job instead of checking offline, add
`offline: false`.

## OIDC (no long-lived secret)

With OIDC, the job proves its identity to Vericto with a short-lived GitHub
token instead of a stored key. The CLI exchanges the token for a key scoped to
`ci_dryrun:execute`, keeps it in memory for the run and never writes it to disk.

1. In the Vericto dashboard, add a trust policy to the workspace: issuer
   `https://token.actions.githubusercontent.com`, audience `vericto` and a
   subject pattern such as `repo:my-org/*`.
2. Give the job `id-token: write` and pass the workspace ID:

```yaml
permissions:
  contents: read
  security-events: write
  actions: read
  id-token: write # mint the OIDC token

jobs:
  vericto:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0
      - uses: vericto/check-sql@v1
        with:
          oidc: true
          workspace: ws_123
```

`workspace` can also come from `workspace_id` in `.vericto.toml`.

## Offline and online

| | Offline (`offline: true`, or no credential) | Online (`api-key` or `oidc`) |
|---|---|---|
| Account, key | none | a Vericto workspace; API key or OIDC |
| Network | none: no SQL leaves the runner | the selected SQL goes to your workspace, sanitized if it says so |
| Rules | the CLI's standard rules (42 in CLI 1.12.0), at their default severities | your workspace's rules: the standard rules with your overrides, plus custom rules |
| Business policies, sensitive columns, masking | no | yes |
| Granularity | one result per file, with its strongest finding, at line 1 | one result per statement, at its line |
| Check history and audit trail in the dashboard | no record anywhere | every check recorded, with the commit, run and actor |
| Baselines | inline `-- vericto:ignore[...]` works; a baseline recorded online (`vericto baseline` needs an account) does not match offline findings | yes |
| Metered | no | counts against the plan's monthly CLI allowance |
| Annotations, job summary, SARIF, outputs | yes | yes |

Offline is a baseline gate ("is this SQL obviously dangerous?"), not your
workspace's policy and not evidence that a check took place. Every offline
result says so: the CLI titles its annotations `Vericto (offline)`, the SARIF
and JSON reports carry `"mode": "offline"` and the engine version, the job
summary has a `Mode` row, and the `mode` output is `offline`. Offline needs
CLI 1.9.0 or later (1.11.0 on Windows runners); the default, 1.12.0, has it.
The CLI's [offline mode](https://github.com/vericto/vericto-cli#offline-mode)
has the details.

### Which mode a run uses

| Credential configured | `offline: auto` (default) | `offline: true` | `offline: false` |
|---|---|---|---|
| none | offline, with a warning annotation | offline | exit 3 |
| `api-key` input | online | exit 2 (set one or the other) | online |
| `VERICTO_API_KEY` on the job only | online | offline; the key is not used (notice) | online |
| `oidc: true` | online | exit 2 (set one or the other) | online |

- **A configured credential never falls back to offline.** A key that is
  rejected is exit 3 and an API that cannot be reached is exit 4, as before,
  so a CI gate never weakens silently.
- **Only "no credential at all" checks offline on its own**, and it says so
  with a warning annotation, the `Mode` row in the job summary and the `mode`
  output. The action cannot tell an empty secret from a secret that was
  never set: `api-key: ${{ secrets.VERICTO_API_KEY }}` with the secret
  missing, or a pull request from a fork (forks get no secrets), checks
  offline too. Set `offline: false` where that must fail the job instead.
- `api-url`, `timeout` and `workspace` are not used offline (a notice says
  so). A `VERICTO_OFFLINE` variable set on the job never chooses the mode:
  with a credential it is ignored, with a warning.

## Inputs

| Input | Default | Description |
|---|---|---|
| `offline` | `auto` | `true`: check offline with the standard rules, no account. `false`: always online; no credential is exit 3. `auto`: online with a credential, offline (with a warning) without one. See [Which mode a run uses](#which-mode-a-run-uses). |
| `api-key` | | Vericto API key (`vtro_...`), from a secret. Not used with `oidc: true` or `offline: true`. Falls back to a `VERICTO_API_KEY` env var set on the job. |
| `oidc` | `false` | Authenticate with GitHub OIDC. Needs `id-token: write`. |
| `workspace` | | Workspace ID for OIDC. Falls back to `VERICTO_WORKSPACE_ID`, then `.vericto.toml`. |
| `files` | | Paths or globs (`*`, `?`, `[...]`, `**`), separated by spaces or newlines, relative to `working-directory`. A directory means every `*.sql` under it. Empty: check changed files. |
| `changed` | `true` when `files` is empty | Check only the `*.sql` files changed against the base (see [Changed files](#changed-files)). |
| `since` | | Base ref for the changed-files diff, e.g. `origin/main`. Implies `changed`. |
| `dialect` | postgres | `postgres`, `mysql`, `oracle` or `mssql`. Empty uses `default_dialect` from `.vericto.toml`, else postgres. |
| `baseline` | | Baseline file to apply (as written by `vericto baseline`, by default `.vericto-baseline.json`). Falls back to `.vericto.toml`. |
| `format` | `sarif` | `sarif`, `json`, `text`, `gitlab-codequality` or `gitlab-sast`. |
| `upload-sarif` | `true` | Upload the SARIF report to Code Scanning (only with `format: sarif`). |
| `api-url` | CLI default | Vericto API base URL (`https://api.vericto.com`). |
| `timeout` | CLI default (30) | Per-request timeout, in seconds. |
| `cli-version` | `1.12.0` | Vericto CLI release to install. Pinned per action release; `latest` is rejected. See [Sanitized mode](#sanitized-mode-needs-cli-182-or-later) before pinning an older one; Windows ARM64 runners need 1.11.0 or later. |
| `working-directory` | `.` | Where the check runs (where `.vericto.toml` lives). With `changed`, it must be the root of the checkout. |

`fail_on` (which severity fails the run) is read from `.vericto.toml`; the
default is to fail only on BLOCKED findings. See the
[CLI's project config](https://github.com/vericto/vericto-cli#project-config-verictotoml).

## Outputs

| Output | Description |
|---|---|
| `exit-code` | The CLI's exit code (table below). |
| `result` | `pass`, `warn` (passed, with findings that don't fail the run) or `fail`. |
| `mode` | `online` (your workspace's rules) or `offline` (the standard rules); empty if the action failed before choosing. |
| `sarif-file` | Path to the SARIF report; empty if none was written. |
| `report-file` | Path to the report for any machine format; empty for `text`. |
| `blocked`, `flagged`, `monitored`, `parse-errors` | Finding counts, for the `sarif` and `json` formats. |

| Exit code | Meaning |
|---|---|
| `0` | Nothing at or above `fail_on`. |
| `1` | A finding at or above `fail_on`. |
| `2` | Usage error: bad input, unreadable file, no base ref for `changed`. |
| `3` | Authentication or plan error: missing (with `offline: false`) or invalid key, OIDC not configured, plan not entitled, monthly allowance used up. Online only. |
| `4` | Backend or network error, including a workspace config that can't be read. No verdict, and no SQL is sent in that case. Online only. |

A non-zero code fails the step, and the job with it, unless you set
`continue-on-error: true` and decide from `exit-code`.

## Permissions

| Permission | Why |
|---|---|
| `contents: read` | Check out the code. |
| `security-events: write` | Upload SARIF to Code Scanning (`upload-sarif: true`). |
| `actions: read` | Required by the SARIF upload in private repositories. |
| `id-token: write` | OIDC only. Offline needs none of the Vericto ones. |

Code Scanning is available on public repositories, and on private ones with
GitHub Advanced Security (GitHub Code Security). Without it, set
`upload-sarif: false`: the check, the log and the job summary still work.

## Examples

### Changed SQL on pull requests and on main

```yaml
on:
  pull_request:
    paths: ["**/*.sql"]
  push:
    branches: [main]
    paths: ["**/*.sql"]
# ...
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0
      - uses: vericto/check-sql@v1
        with:
          api-key: ${{ secrets.VERICTO_API_KEY }}
          dialect: mysql
```

### Explicit files

```yaml
      - uses: vericto/check-sql@v1
        with:
          api-key: ${{ secrets.VERICTO_API_KEY }}
          files: |
            db/migrations/**/*.sql
            reports/monthly.sql
```

`fetch-depth: 0` is not needed when you list files. A pattern that matches no
SQL file fails with exit code 2, so a typo can't turn into a silent pass.

### Adopting Vericto in a repo with existing findings

Record today's findings once, commit the baseline, and only new findings fail:

```bash
vericto baseline db/migrations/*.sql   # writes .vericto-baseline.json
git add .vericto-baseline.json
```

```yaml
      - uses: vericto/check-sql@v1
        with:
          api-key: ${{ secrets.VERICTO_API_KEY }}
          baseline: .vericto-baseline.json
```

Baselined findings are still reported (`result: warn`); they just don't fail
the run. A single statement can also be suppressed inline with
`-- vericto:ignore[VERICTO-001] reason`. `vericto baseline` records online
findings and needs an account; offline, use the inline suppression.

### A subdirectory in a monorepo

```yaml
      - uses: vericto/check-sql@v1
        with:
          api-key: ${{ secrets.VERICTO_API_KEY }}
          working-directory: services/billing
          files: migrations
```

Report paths are rewritten relative to the repository root, so annotations
land on the right files.

### Report only, without failing the build

```yaml
      - id: vericto
        uses: vericto/check-sql@v1
        continue-on-error: true
        with:
          api-key: ${{ secrets.VERICTO_API_KEY }}
      - if: steps.vericto.outputs.result != 'pass'
        run: echo "Vericto: ${{ steps.vericto.outputs.blocked }} blocked, ${{ steps.vericto.outputs.flagged }} flagged"
```

### GitLab and other CI systems

This action is for GitHub Actions. On GitLab CI, run the CLI directly with
`--format gitlab-codequality`; the [CLI README](https://github.com/vericto/vericto-cli#cicd)
has a ready-made job.

## Changed files

With `changed` (the default when `files` is empty), the CLI checks the `*.sql`
files that differ from a base, excluding deleted files. The base is:

1. `since`, when set;
2. on `pull_request`, the PR's base branch (`origin/<base>`);
3. on `merge_group`, the queue's base commit;
4. on `push`, the commit before the push;
5. otherwise, the repository's default branch (`origin/<default>`).

The diff needs the base commit, so check out with `fetch-depth: 0`. When no SQL
changed, the check passes and no SQL is sent.

## Troubleshooting

- **`could not determine a base ref` or `git diff ... failed` (exit 2):** the
  checkout is shallow or lacks the base branch. Use `fetch-depth: 0`, or set
  `since`.
- **`changed must run from the root of the git checkout`:** git reports changed
  paths from the repository root. Run from the root, or list `files`.
- **`No Vericto credential is configured, so this run checks offline`
  (warning):** no `api-key`, no `VERICTO_API_KEY` and no `oidc`, so the
  action checked with the standard rules. Set `offline: true` if that is what
  you want, or check the secret's name and that the event gets secrets (fork
  pull requests don't). `offline: false` makes this case fail with exit 3.
- **Exit 3:** the key is missing (with `offline: false`), invalid or lacks
  `ci_dryrun:execute`; the OIDC trust policy doesn't match the repository; or
  the plan's monthly CLI allowance is used up. `vericto doctor` shows which.
- **`oidc: true needs 'permissions: id-token: write'`:** add the permission to
  the job. Pull requests from forks don't get OIDC tokens or secrets.
- **`VERICTO_OFFLINE is set on the job; ignored here`:** with a credential,
  the action checks online; only its `offline` input chooses offline mode
  (see [Which mode a run uses](#which-mode-a-run-uses)). Set
  `VERICTO_OFFLINE` only on the steps that run the CLI themselves.
- **`offline mode needs cli-version 1.9.0 or later`** (or 1.11.0 on Windows
  runners): the pinned `cli-version` predates offline mode. Leave
  `cli-version` at its default, or pin a newer one.
- **`Windows ARM64 runners need cli-version 1.11.0 or later` (exit 2):** CLI
  releases before 1.11.0 have no Windows ARM64 build. Pin 1.11.0 or later, or
  leave `cli-version` at its default.
- **Exit 4:** the API could not be reached, or the workspace config could not
  be read. Corporate TLS proxies: set `VERICTO_CA_BUNDLE` (a PEM path) in the
  job's `env`.
- **SARIF upload fails with "Advanced Security must be enabled" or "Resource
  not accessible by integration":** Code Scanning is not available on this
  repository, or the job lacks `security-events: write` (fork PRs never have
  it). Set `upload-sarif: false` there.

## Security

- **Checksum verification.** The CLI is downloaded from the
  [vericto-cli](https://github.com/vericto/vericto-cli/releases) release that
  `cli-version` pins, never from `latest`. Its SHA-256 is verified against the
  release's `.sha256` file before the archive is extracted; a mismatch stops
  the action. A cached download is re-verified on every run, and the binary on
  `PATH` is always extracted from the verified archive.
- **Build attestation (advisory).** When the GitHub CLI is available, the
  action also runs `gh attestation verify` against the release's Sigstore
  build provenance. If that can't run (no `gh`, no network to the attestation
  API) or doesn't pass, the action logs a warning and continues: the checksum
  is the gate.
- **No secrets on the command line.** The API key reaches the CLI only through
  the `VERICTO_API_KEY` environment variable, is masked in the log, and the CLI
  never prints it. Pass it from `secrets.*` so the runner masks it from the
  start.
- **No shell injection.** No input is interpolated into a script: each one is
  passed through an environment variable, validated, and handed to the CLI as a
  single argument.
- **Pinned dependencies.** Every action this action uses is pinned by commit
  SHA. You can pin this action the same way:
  `uses: vericto/check-sql@<full commit SHA> # v1.3.0`.

Report vulnerabilities as described in [SECURITY.md](SECURITY.md).

## SQL never leaves your CI unless it is selected for the check

Offline, nothing is sent: the CLI makes no request of any kind, to Vericto or
anyone else, and evaluates on the runner.

Online, checking SQL means sending it to your Vericto workspace, which
evaluates it with your rules. What is sent, per the
[CLI design](https://github.com/vericto/vericto-cli/blob/main/DESIGN.md):

- **Only the files selected for the check** (the changed `*.sql` files, or
  `files`) and their paths, to your workspace's API only, over TLS
  (`https://api.vericto.com` unless you set `api-url`). No other file in the
  repository is sent.
- **Sanitized when your workspace says so.** Before sending any SQL, the CLI
  reads the workspace's telemetry mode. In `sanitized` mode it replaces literal
  values with placeholders (`$1`, `$2`, ...) on the runner, so raw values never
  leave it. Sanitization is a workspace setting, not a per-run flag. It
  needs CLI 1.8.2 or later (see below).
- **Fail closed.** If the workspace config can't be read, the CLI sends no SQL
  and exits with code 4.
- **Run metadata** for the audit trail: commit SHA, ref, CI provider, run URL
  and the actor's username. Never a credential.
- **Not kept by the CLI.** It does not persist the SQL beyond the request. The
  report it writes can quote short previews and suggested fixes, so treat it
  like the SQL itself.

See [Telemetry & privacy](https://vericto.com/docs/telemetry-privacy).

### Sanitized mode needs CLI 1.8.2 or later

Since action 1.0.3 the action installs CLI 1.8.2 by default (1.0.0 to 1.0.2
installed 1.7.1). Before 1.8.2, the CLI's sanitizer replaced only the plain
literals: in some dialect-specific cases (Snowflake and MySQL backslash
escapes, MySQL double-quoted strings, Oracle `q'[...]'` strings, dollar-quoted
strings, comments a dialect reads differently, prefixed literals and numbers,
unterminated quotes) part of a literal was sent as written. In 1.8.2 the
sanitized telemetry no longer leaks literal fragments: the sanitizer ends
every literal where the dialect's own lexer ends it, and replaces whatever it
cannot read with certainty. See the
[CLI changelog for 1.8.2](https://github.com/vericto/vericto-cli/blob/main/CHANGELOG.md#182---2026-10-18).

Nothing changes for a workspace in `raw` mode. If you pin `cli-version`, your
pin still applies; with a `sanitized` workspace, pin `1.8.2` or later. Since
action 1.2.0 the default is CLI 1.12.0.

## Links

- [vericto.com](https://vericto.com)
- [Documentation](https://vericto.com/docs)
- [Vericto CLI](https://github.com/vericto/vericto-cli)
- [Changelog](CHANGELOG.md)

## Versioning

Releases follow [Semantic Versioning](https://semver.org). The major tag
(`v1`) moves to each compatible release, the usual convention for GitHub
Actions; `@v1.3.0` or a commit SHA stays fixed. Each action release pins a
CLI version, and a CLI bump ships as a new action release.

## Tests

The scripts in `scripts/` have offline unit tests (bash 3.2+, `git` and `jq`),
run in CI on Linux and macOS:

```bash
for t in lib resolve verify-checksum install check; do bash "test/$t-test.sh"; done
```

They use local fixtures only: `test/install-test.sh` serves the release
download from `file://` through a `curl` stand-in, and `test/check-test.sh`
runs `check.sh` against a stand-in CLI (`test/fixtures/fake-cli/vericto`). A
case marked `xfail` is a known bug, kept visible until it is fixed.
`test/checksum-test.sh VERSION` checks the same gate against the real release
asset and needs the network.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the checks CI runs, the rules for the
scripts, and how releases are cut.

## License

Open source under the [Apache License 2.0](LICENSE) (SPDX `Apache-2.0`) since
1.1.0. Versions 1.0.3 and earlier were released under the Elastic License 2.0
and remain under it. Copyright 2026 Vericto S.A.S.; see [NOTICE](NOTICE). The
license grants no right to the Vericto name or logo: see
[TRADEMARKS.md](TRADEMARKS.md).

The Vericto CLI that the action downloads and runs is a separate program under
its own license: the Functional Source License (FSL-1.1-ALv2) from CLI 1.10.0,
the Elastic License 2.0 for 1.9.1 and earlier. The default `cli-version`,
1.12.0, is under FSL-1.1-ALv2. See its
[LICENSING.md](https://github.com/vericto/vericto-cli/blob/main/LICENSING.md).
The Vericto service it calls is offered under its own
[terms](https://vericto.com/terms).

---

## En español

**Vericto SQL Check** es una GitHub Action que valida el SQL de sus pull
requests (migraciones, scripts, consultas generadas) contra las reglas de su
espacio de trabajo de [Vericto](https://vericto.com) antes de que se ejecute.
Los hallazgos aparecen como anotaciones de Code Scanning en el PR y una
sentencia bloqueada hace fallar el job.

Uso básico, sin cuenta ni clave de API (modo offline, con las reglas
estándar):

```yaml
permissions:
  contents: read
  security-events: write
  actions: read
steps:
  - uses: actions/checkout@v7
    with:
      fetch-depth: 0
  - uses: vericto/check-sql@v1
    with:
      offline: true
```

Con una cuenta de Vericto, guarde una clave de API en el secreto
`VERICTO_API_KEY` y páselo en lugar de `offline: true`
(`api-key: ${{ secrets.VERICTO_API_KEY }}`) para validar contra las reglas de
su espacio de trabajo.

- Por defecto se revisan solo los archivos `*.sql` que cambian en el PR. Para
  revisar archivos concretos, indíquelos en `files`.
- En modo offline no se envía ningún SQL: el motor incluido en el CLI aplica
  las reglas estándar en el runner. Una cuenta agrega sus reglas
  personalizadas, políticas de negocio, columnas sensibles y el historial y la
  auditoría en el panel. Sin ninguna credencial configurada, la acción valida
  offline con una advertencia; con `offline: false`, falla con código 3. Una
  credencial configurada nunca pasa a offline si la API falla.
- Para no guardar una clave, use OIDC: `oidc: true`, `workspace: ws_...` y el
  permiso `id-token: write`.
- La acción descarga una versión fija del CLI (1.12.0 por defecto) y
  verifica su SHA-256 antes de extraerlo. La clave de API se pasa solo por variable de entorno y nunca
  aparece en la línea de comandos.
- En modo online, el SQL seleccionado se envía a su espacio de trabajo para
  evaluarlo. Si el espacio está en modo `sanitized`, los valores literales se
  reemplazan en el runner antes del envío.

Licencia: código abierto bajo la [Apache License 2.0](LICENSE) desde 1.1.0. Las
versiones 1.0.3 y anteriores se publicaron bajo la Elastic License 2.0 y siguen
bajo ella. La CLI de Vericto que la action descarga tiene su propia licencia
(FSL-1.1-ALv2 desde la CLI 1.10.0, incluida la 1.12.0 que instala por
defecto; Elastic License 2.0 hasta la 1.9.1). La
licencia no otorga derechos sobre la marca Vericto
([TRADEMARKS.md](TRADEMARKS.md)).

La documentación completa está en inglés, más arriba, y en
[vericto.com/docs](https://vericto.com/docs).
