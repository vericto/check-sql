#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Vericto S.A.S.
# SPDX-License-Identifier: Apache-2.0

# Runs `vericto check` with the action's inputs and mirrors its verdict.
#
# Online (a credential is configured) it checks against the workspace's rules.
# Offline (`offline: true`, or `offline: auto` with no credential at all) it
# runs `vericto check --offline`: the CLI's embedded engine and its standard
# rules, no account, no request. A configured credential is never replaced by
# offline mode, so an API or auth failure stays a failure (exit 3 or 4).
#
# Every input arrives as an environment variable (VA_*), never interpolated
# into this script, and reaches the CLI as a single quoted argument or an env
# var. The API key is passed to the CLI only through VERICTO_API_KEY, never on
# the command line, and is masked in the log first.
#
# Out (step outputs): exit-code, result, mode, sarif-file, report-file,
# blocked, flagged, monitored, parse-errors, checkout-path. Exits with the
# CLI's code.
set -euo pipefail

here=$(dirname "$0")
# shellcheck source=scripts/lib.sh
. "$here/lib.sh"

# Mask credentials before anything else can print them.
[ -n "${VA_API_KEY:-}" ] && gh_mask "$VA_API_KEY"
[ -n "${VERICTO_API_KEY:-}" ] && gh_mask "$VERICTO_API_KEY"

mode=""
selection=""
cli_version=""
code=""
result=""
blocked="" flagged="" monitored="" parse_errors=""
# online or offline once decided; auto_offline: offline because no credential
# was configured (offline: auto); cli_ran: the CLI was started.
run_mode="" auto_offline=false cli_ran=false engine_version=""

exit_meaning() {
  case "$1" in
    0) echo "nothing at or above fail_on" ;;
    1) echo "a finding at or above fail_on" ;;
    2) echo "usage error" ;;
    3) echo "authentication or plan error" ;;
    4) echo "backend or network error, no verdict" ;;
    *) echo "unexpected exit code" ;;
  esac
}

# Keeps user-controlled text (refs, paths) inert in the Markdown summary.
md_safe() { printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._/@-' '_'; }

write_summary() {
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  local label counts=""
  case "$result" in
    pass) label=PASS ;;
    warn) label=WARN ;;
    *) label=FAIL ;;
  esac
  if [ -n "$blocked" ]; then
    counts="| Blocked / flagged / monitored / parse errors | $blocked / $flagged / $monitored / $parse_errors |"
  fi
  local mode_row=""
  case "$run_mode" in
    online) mode_row="online, your workspace's rules" ;;
    offline)
      mode_row="offline, the standard rules"
      [ -n "$engine_version" ] && mode_row="$mode_row (engine \`$engine_version\`)"
      [ "$auto_offline" = true ] && mode_row="$mode_row; no credential configured"
      ;;
  esac
  {
    echo "### Vericto SQL Check: $label"
    echo
    echo "| | |"
    echo "|---|---|"
    echo "| Result | \`$result\` |"
    echo "| Exit code | \`$code\` ($(exit_meaning "$code")) |"
    [ -n "$mode_row" ] && echo "| Mode | $mode_row |"
    [ -n "$counts" ] && echo "$counts"
    [ -n "$selection" ] && echo "| SQL checked | $selection |"
    [ -n "$cli_version" ] && echo "| CLI | \`$cli_version\` |"
    echo
    if [ "$run_mode" = offline ] && [ "$cli_ran" = true ]; then
      echo "Checked offline with Vericto's standard rules: no account, and no SQL left the runner. A Vericto account adds your custom rules, business policies, sensitive columns, and check history and audit in the dashboard. [Start free](https://vericto.com)"
      echo
    fi
  } >>"$GITHUB_STEP_SUMMARY"
}

# Fails before the CLI runs: 2 for bad inputs, 3 for missing credentials,
# the same meanings the CLI uses.
fail() {
  code=$1
  shift
  result=fail
  gh_error "$*"
  set_output exit-code "$code"
  set_output result "$result"
  [ -n "$run_mode" ] && set_output mode "$run_mode"
  write_summary
  exit "$code"
}

# cli_at_least MAJOR MINOR: true when the installed CLI ($cli_version, e.g.
# "vericto 1.12.0") is MAJOR.MINOR or later. An unreadable version is not
# refused here: the CLI decides.
cli_at_least() {
  local v=${cli_version##* } major minor
  matches '^[0-9]+\.[0-9]+\.[0-9]+' "$v" || return 0
  major=${v%%.*} minor=${v#*.}
  minor=${minor%%.*}
  [ "$major" -gt "$1" ] || { [ "$major" -eq "$1" ] && [ "$minor" -ge "$2" ]; }
}

# offline_needs: why the installed CLI cannot check offline on this runner,
# or nothing when it can.
offline_needs() {
  if ! cli_at_least 1 9; then
    echo "offline mode needs cli-version 1.9.0 or later (installed: $cli_version)"
  elif is_windows && ! cli_at_least 1 11; then
    echo "offline mode on Windows runners needs cli-version 1.11.0 or later (installed: $cli_version)"
  fi
}

bool_input() { # NAME VALUE VAR: stores true/false in VAR
  case "$2" in
    true | True | TRUE) printf -v "$3" true ;;
    false | False | FALSE) printf -v "$3" false ;;
    *) fail 2 "input '$1' must be true or false (got '$2')" ;;
  esac
}

: "${VA_BIN:?the install step did not provide a binary}"

# ── Validate inputs ──────────────────────────────────────────────────────────
format=${VA_FORMAT:-sarif}
case "$format" in
  sarif) ext=sarif ;;
  json) ext=json ;;
  gitlab-codequality) ext=gl-code-quality.json ;;
  gitlab-sast) ext=gl-sast-report.json ;;
  text) ext="" ;;
  *) fail 2 "input 'format' must be sarif, json, text, gitlab-codequality or gitlab-sast (got '$format')" ;;
esac
oidc=false changed=""
bool_input oidc "${VA_OIDC:-false}" oidc
# upload-sarif drives the upload step in action.yml; validated here so a typo
# fails loudly instead of silently skipping the upload.
case "${VA_UPLOAD_SARIF:-true}" in
  true | True | TRUE | false | False | FALSE) ;;
  *) fail 2 "input 'upload-sarif' must be true or false (got '$VA_UPLOAD_SARIF')" ;;
esac
if [ -n "${VA_CHANGED:-}" ]; then bool_input changed "$VA_CHANGED" changed; fi
case "${VA_OFFLINE:-auto}" in
  auto | Auto | AUTO) offline=auto ;;
  true | True | TRUE) offline=true ;;
  false | False | FALSE) offline=false ;;
  *) fail 2 "input 'offline' must be auto, true or false (got '$VA_OFFLINE')" ;;
esac

dialect=${VA_DIALECT:-}
if [ -n "$dialect" ] && ! matches '^[a-z][a-z0-9_]{0,31}$' "$dialect"; then
  fail 2 "input 'dialect' must be a dialect name such as postgres, mysql, oracle or mssql (got '$dialect')"
fi
timeout=${VA_TIMEOUT:-}
if [ -n "$timeout" ] && ! matches '^[1-9][0-9]{0,4}$' "$timeout"; then
  fail 2 "input 'timeout' must be a whole number of seconds (got '$timeout')"
fi
api_url=${VA_API_URL:-}
if [ -n "$api_url" ]; then
  matches '^https?://[^[:space:]]+$' "$api_url" || fail 2 "input 'api-url' must be an http(s) URL"
fi
workspace=${VA_WORKSPACE:-}
if [ -n "$workspace" ] && ! matches '^[A-Za-z0-9_.:-]{1,128}$' "$workspace"; then
  fail 2 "input 'workspace' must be a workspace ID such as ws_123"
fi
since=${VA_SINCE:-}
if [ -n "$since" ] && ! matches '^[^-[:space:][:cntrl:]][^[:space:][:cntrl:]]*$' "$since"; then
  fail 2 "input 'since' must be a git ref, e.g. origin/main (got '$since')"
fi
baseline=${VA_BASELINE:-}
is_single_line "$baseline" || fail 2 "input 'baseline' must be a single path"
# Optional: action.yml always sets it, a direct run may not (set -u).
files=${VA_FILES:-}

# ── Credentials and mode ─────────────────────────────────────────────────────
args=(check "--format=$format")
cli_version=$("$VA_BIN" --version | tr -d '\r')
no_creds="no credentials: set 'api-key: \${{ secrets.VERICTO_API_KEY }}', or 'oidc: true' with 'workspace'"
if [ "$offline" = true ]; then
  [ "$oidc" = true ] && fail 2 "set either oidc: true or offline: true, not both"
  [ -n "${VA_API_KEY:-}" ] && fail 2 "set either api-key or offline: true, not both"
  run_mode=offline
  if [ -n "${VERICTO_API_KEY:-}" ]; then
    gh_notice "VERICTO_API_KEY is set on the job; not used here: offline: true checks with the standard rules, without an account."
  fi
elif [ "$oidc" = true ]; then
  [ -n "${VA_API_KEY:-}" ] && fail 2 "set either api-key or oidc: true, not both"
  # A job-level static key must not win over the OIDC login asked for here.
  unset VERICTO_API_KEY
  if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]; then
    fail 3 "oidc: true needs 'permissions: id-token: write' on the job (no OIDC token is available)"
  fi
  run_mode=online
  args+=(--oidc)
  [ -n "$workspace" ] && export VERICTO_WORKSPACE_ID="$workspace"
elif [ -n "${VA_API_KEY:-}" ]; then
  run_mode=online
  export VERICTO_API_KEY="$VA_API_KEY"
elif [ -n "${VERICTO_API_KEY:-}" ]; then
  run_mode=online
elif [ "$offline" = false ]; then
  fail 3 "$no_creds (offline: false requires one)"
else
  # offline: auto and no credential of any kind: check offline rather than
  # fail. Only here: a credential that is configured but rejected, or an API
  # that cannot be reached, keeps failing (exit 3 or 4).
  why=$(offline_needs)
  [ -z "$why" ] || fail 3 "$no_creds. Checking without an account (offline) is not possible here: $why."
  run_mode=offline auto_offline=true
  gh_warning "No Vericto credential is configured, so this run checks offline with the standard rules only. Set 'offline: true' to choose this explicitly, or pass 'api-key' or 'oidc: true' to check against your workspace's rules. If a secret was expected, it is missing (fork pull requests get no secrets)."
fi
unset VA_API_KEY

if [ "$run_mode" = offline ]; then
  why=$(offline_needs)
  [ -z "$why" ] || fail 2 "$why"
  # No credential reaches the CLI in offline mode, not even a job-level one.
  unset VERICTO_API_KEY VERICTO_WORKSPACE_ID
  args+=(--offline)
  unused=""
  [ -n "$api_url" ] && unused="$unused api-url"
  [ -n "$timeout" ] && unused="$unused timeout"
  [ -n "$workspace" ] && unused="$unused workspace"
  if [ -n "$unused" ]; then
    gh_notice "not used offline (no request is made):$unused"
  fi
  api_url="" timeout=""
else
  case "$api_url" in http://*) gh_warning "api-url uses plain http: the API key and the SQL travel unencrypted." ;; esac
fi

# The action's own input chooses the mode. Since CLI 1.9.0, VERICTO_OFFLINE=1
# switches `vericto check` to the standard rules only, and with --oidc it is a
# usage error. A job-level VERICTO_OFFLINE, meant for another step, must not
# quietly weaken an online check: it is ignored here.
if [ -n "${VERICTO_OFFLINE:-}" ] && [ "$run_mode" = online ]; then
  gh_warning "VERICTO_OFFLINE is set on the job; ignored here: with a credential the action checks online against your workspace's rules. Use the action's 'offline: true' input to check offline."
fi
unset VERICTO_OFFLINE

[ -n "$dialect" ] && args+=("--dialect=$dialect")
[ -n "$baseline" ] && args+=("--baseline=$baseline")
[ -n "$timeout" ] && args+=("--timeout=$timeout")
[ -n "$api_url" ] && args+=("--api-url=$api_url")

work=$(make_temp_dir check)
trap 'rm -rf "$work"' EXIT

in_git=false
git rev-parse --is-inside-work-tree >/dev/null 2>&1 && in_git=true

# ── What to check ────────────────────────────────────────────────────────────
# Converts a glob to an anchored extended regex: `**/` is zero or more
# directories, `**` anything, `*` and `?` stay within one path segment, and
# `[...]` is a bracket expression (`[!...]` negated).
glob_to_ere() {
  local g=$1 out="" c i=0 j n=${#1}
  while [ "$i" -lt "$n" ]; do
    c=${g:$i:1}
    case "$c" in
      '*')
        if [ "${g:$i:3}" = '**/' ]; then
          out="$out(.*/)?"
          i=$((i + 3))
          continue
        elif [ "${g:$i:2}" = '**' ]; then
          out="$out.*"
          i=$((i + 2))
          continue
        fi
        out="${out}[^/]*"
        ;;
      '?') out="${out}[^/]" ;;
      '[')
        j=$((i + 1))
        [ "${g:$j:1}" = '!' ] && j=$((j + 1))
        [ "${g:$j:1}" = ']' ] && j=$((j + 1))
        while [ "$j" -lt "$n" ] && [ "${g:$j:1}" != ']' ]; do j=$((j + 1)); done
        if [ "$j" -ge "$n" ]; then
          out="$out\\["
        else
          c=${g:$((i + 1)):$((j - i - 1))}
          case "$c" in '!'*) c="^${c#!}" ;; esac
          out="${out}[$c]"
          i=$j
        fi
        ;;
      '.' | '+' | '(' | ')' | '{' | '}' | '|' | '^' | '$' | \\) out="$out\\$c" ;;
      *) out="$out$c" ;;
    esac
    i=$((i + 1))
  done
  printf '^%s$' "$out"
}

# Lists the files a `**` pattern matches. Like the shell's globbing, it skips
# hidden files and directories below the pattern's literal base.
expand_globstar() { # PATTERN
  local pat=$1 base="" seg rest re p rel
  rest=$pat
  while :; do
    case "$rest" in
      */*) seg=${rest%%/*} ;;
      *) break ;;
    esac
    case "$seg" in *'*'* | *'?'* | *'['*) break ;; esac
    base="$base$seg/"
    rest=${rest#*/}
  done
  base=${base%/}
  re=$(glob_to_ere "$pat")
  [ -d "${base:-.}" ] || return 0
  while IFS= read -r p; do
    p=${p#./}
    rel=${p#"$base"/}
    case "/$rel" in */.*) continue ;; esac
    [[ $p =~ $re ]] && printf '%s\n' "$p"
  done < <(find "${base:-.}" -type f | LC_ALL=C sort)
}

expand_files() { # OUT
  local out=$1 pat m n f i
  local -a pats found
  shopt -s nullglob
  read -r -d '' -a pats <<<"$files" || true
  [ "${#pats[@]}" -gt 0 ] || fail 2 "input 'files' holds no patterns"
  # From here on, expand globs without word splitting.
  local IFS=''
  : >"$out.raw"
  for pat in "${pats[@]}"; do
    case "$pat" in -*) fail 2 "file pattern '$pat' must not start with '-'" ;; esac
    pat=${pat#./}
    found=()
    case "$pat" in
      *'**'*)
        # bash 3.2 (the macOS runners' bash) has no globstar: match with find.
        while IFS= read -r f; do found[${#found[@]}]=$f; done < <(expand_globstar "$pat")
        ;;
      *)
        # Intentional: expand the glob (IFS is empty, so nothing is split).
        # shellcheck disable=SC2206
        found=($pat)
        ;;
    esac
    n=0 i=0
    # An index loop: bash 3.2 joins "${found[@]}" when IFS is empty.
    while [ "$i" -lt "${#found[@]}" ]; do
      m=${found[$i]}
      i=$((i + 1))
      is_single_line "$m" || fail 2 "file names with line breaks are not supported"
      m=${m#./}
      if [ -d "$m" ]; then
        while IFS= read -r f; do
          printf '%s\n' "${f#./}" >>"$out.raw"
          n=$((n + 1))
        done < <(find "$m" -type f -name '*.sql' | LC_ALL=C sort)
      elif [ -f "$m" ]; then
        printf '%s\n' "$m" >>"$out.raw"
        n=$((n + 1))
      fi
    done
    [ "$n" -gt 0 ] || fail 2 "no SQL files match '$pat' (relative to $(md_safe "$(pwd)"))"
  done
  awk '!seen[$0]++' "$out.raw" >"$out"
}

if [ -n "${files//[[:space:]]/}" ]; then
  [ "$changed" = true ] && fail 2 "set either files or changed: true, not both"
  [ -n "$since" ] && fail 2 "set either files or since, not both"
  mode=files
  list="$work/files.txt"
  expand_files "$list"
  count=$(wc -l <"$list" | tr -d ' ')
  selection="$count file(s) from \`files\`"
  args+=(--stdin-file-list)
else
  [ "$changed" = false ] && fail 2 "nothing to check: set files, or leave changed on"
  mode=changed
  [ "$in_git" = true ] || fail 2 "changed needs a git checkout: use actions/checkout with fetch-depth: 0"
  if [ -n "$(git rev-parse --show-prefix)" ]; then
    fail 2 "changed must run from the root of the git checkout (git reports paths from there); set working-directory to it, or use files"
  fi
  if [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then
    gh_warning "shallow clone: the base commit may be missing. Use actions/checkout with fetch-depth: 0."
  fi
  is_commit() { matches '^([0-9a-f]{40}|[0-9a-f]{64})$' "$1" && git cat-file -e "$1^{commit}" 2>/dev/null; }
  if [ -z "$since" ] && [ -z "${GITHUB_BASE_REF:-}" ]; then
    # Not a pull request: pick the base the CLI cannot infer on its own.
    if [ "${VA_EVENT_NAME:-}" = merge_group ] && is_commit "${VA_MERGE_GROUP_BASE:-}"; then
      since=$VA_MERGE_GROUP_BASE
    elif [ "${VA_EVENT_NAME:-}" = push ] && is_commit "${VA_EVENT_BEFORE:-}"; then
      since=$VA_EVENT_BEFORE
    elif [ -n "${VA_DEFAULT_BRANCH:-}" ] && git rev-parse -q --verify "refs/remotes/origin/$VA_DEFAULT_BRANCH" >/dev/null; then
      since="origin/$VA_DEFAULT_BRANCH"
    fi
  fi
  if [ -n "$since" ]; then
    args+=("--since=$since")
    selection="*.sql changed since \`$(md_safe "$since")\`"
  else
    args+=(--changed)
    selection="*.sql changed vs \`origin/$(md_safe "${GITHUB_BASE_REF:-HEAD}")\`"
  fi
fi

report=""
if [ -n "$ext" ]; then
  report_dir=$(make_temp_dir report)
  report="$report_dir/vericto.$ext"
  args+=("--output=$(native_path "$report")")
fi

# ── Run ──────────────────────────────────────────────────────────────────────
echo "Running: vericto ${args[*]}"
cli_ran=true
set +e
if [ "$mode" = files ]; then
  "$VA_BIN" "${args[@]}" <"$list"
else
  "$VA_BIN" "${args[@]}" </dev/null
fi
code=$?
set -e

# ── Results ──────────────────────────────────────────────────────────────────
prefix=""
if [ "$in_git" = true ]; then
  set_output checkout-path "$(native_path "$(git rev-parse --show-toplevel)")"
  prefix=$(git rev-parse --show-prefix)
fi

have_jq=false
command -v jq >/dev/null 2>&1 && have_jq=true

if [ -n "$report" ] && [ -f "$report" ]; then
  set_output report-file "$(native_path "$report")"
  if [ "$format" = sarif ]; then
    # Files mode reports paths relative to working-directory; Code Scanning
    # wants them relative to the repository root.
    if [ "$mode" = files ] && [ -n "$prefix" ]; then
      if [ "$have_jq" = true ]; then
        jq --arg p "$prefix" '(.runs[]?.results[]?.locations[]?.physicalLocation.artifactLocation.uri)
          |= (if type == "string" and (test("^([A-Za-z][A-Za-z0-9+.-]*:|/|<)") | not) then $p + . else . end)' \
          "$report" >"$report.tmp" && mv "$report.tmp" "$report"
      else
        gh_warning "jq not found: SARIF paths stay relative to working-directory, so annotations may not attach to files."
      fi
    fi
    set_output sarif-file "$(native_path "$report")"
  fi
  if [ "$have_jq" = true ]; then
    counts=""
    case "$format" in
      sarif)
        counts=$(jq -r '[.runs[]?.results[]?.message.text // ""]
          | [(map(select(test("\\[BLOCKED\\]"))) | length),
             (map(select(test("\\[FLAGGED\\]"))) | length),
             (map(select(test("\\[MONITORED\\]"))) | length),
             (map(select(startswith("Could not parse"))) | length)] | @tsv' "$report" 2>/dev/null) || counts=""
        ;;
      json)
        counts=$(jq -r '.summary | [.blocked, .flagged, .monitored, .parse_errors] | map(. // 0) | @tsv' "$report" 2>/dev/null) || counts=""
        ;;
    esac
    counts=$(printf '%s' "$counts" | tr -d '\r')
    if [ "$run_mode" = offline ]; then
      # Offline reports name the embedded engine (SARIF run properties, JSON).
      case "$format" in
        sarif) engine_version=$(jq -r '.runs[0].properties.engine_version // empty' "$report" 2>/dev/null) || engine_version="" ;;
        json) engine_version=$(jq -r '.engine_version // empty' "$report" 2>/dev/null) || engine_version="" ;;
      esac
      engine_version=$(printf '%s' "$engine_version" | tr -d '\r')
      matches '^[0-9A-Za-z.+-]{1,32}$' "$engine_version" || engine_version=""
    fi
    tab=$'\t'
    if matches "^[0-9]+${tab}[0-9]+${tab}[0-9]+${tab}[0-9]+\$" "$counts"; then
      IFS=$'\t' read -r blocked flagged monitored parse_errors <<<"$counts"
    fi
  fi
elif [ "$code" -eq 0 ] && [ -n "$ext" ]; then
  # Exit 0 without a report: nothing matched (e.g. no changed SQL).
  blocked=0 flagged=0 monitored=0 parse_errors=0
fi

if [ "$code" -ne 0 ]; then
  result=fail
elif [ -n "$blocked" ] && [ $((blocked + flagged + monitored + parse_errors)) -gt 0 ]; then
  result=warn
else
  result=pass
fi

set_output exit-code "$code"
set_output result "$result"
set_output mode "$run_mode"
set_output blocked "$blocked"
set_output flagged "$flagged"
set_output monitored "$monitored"
set_output parse-errors "$parse_errors"
write_summary

case "$code" in
  0) ;;
  1)
    if [ "$run_mode" = offline ]; then
      gh_error "Vericto's standard rules (offline) found SQL at or above fail_on in this change. See the annotations above and in Code Scanning."
    else
      gh_error "Vericto found SQL at or above fail_on in this change. See the annotations above and in Code Scanning."
    fi
    ;;
  2)
    msg="vericto check failed with a usage error (exit 2); see the log above."
    if [ "$mode" = changed ] && [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then
      msg="$msg The checkout is shallow: use actions/checkout with fetch-depth: 0."
    fi
    gh_error "$msg"
    ;;
  3) gh_error "Vericto rejected the credentials (exit 3): check the API key or the OIDC trust policy, its scope (ci_dryrun:execute) and the plan's monthly CLI allowance." ;;
  4) gh_error "The Vericto API was unreachable or returned an error (exit 4). No verdict was given and no result is assumed." ;;
  *) gh_error "vericto check exited with $code." ;;
esac
exit "$code"
