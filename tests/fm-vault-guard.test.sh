#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for the vault-guard PreToolUse seatbelt (docs/vault-guard.md).
#
# bin/fm-vault-command-policy.mjs is the single owner of the block/allow
# decision; it reuses the shell classifier owned by bin/fm-arm-command-policy.mjs.
# bin/fm-vault-pretool-check.sh is the stable transport driving all five harness
# entry forms; bin/fm-secrets-names.sh is the sanctioned names-only wrapper.
# This suite proves the decision matrix with per-row reason codes, the
# harness-output shaping, the fail-open transport behavior, the prefilter fast
# path, the wrapper's structural names-only output contract, the per-task spawn
# installation for every verified harness against a fake tmux backend, and the
# tracked primary/secondmate-home wiring. No harness is spawned; live claude
# evidence lives in docs/vault-guard.md.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-vault-guard)

CHECK="$ROOT/bin/fm-vault-pretool-check.sh"
POLICY="$ROOT/bin/fm-vault-command-policy.mjs"
WRAPPER="$ROOT/bin/fm-secrets-names.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"

# --- full cross-harness acceptance matrix ----------------------------------

MATRIX_IDS=()
MATRIX_EXPECTED=()
MATRIX_COMMANDS=()

matrix_case() {
  MATRIX_IDS+=("$1")
  MATRIX_EXPECTED+=("$2")
  MATRIX_COMMANDS+=("$3")
}

# DENY vault-secret-print: value-printing infisical forms.
matrix_case P01 vault-secret-print 'infisical secrets'
matrix_case P02 vault-secret-print 'infisical export --env=prod'
matrix_case P03 vault-secret-print 'infisical secrets get DB_URL --plain'
matrix_case P04 vault-secret-print 'infisical'
matrix_case P05 vault-secret-print 'sudo infisical secrets'
matrix_case P06 vault-secret-print '/opt/homebrew/bin/infisical secrets'
matrix_case P07 vault-secret-print 'X=$(infisical secrets get A)'
matrix_case P08 vault-secret-print 'sh -c "infisical export"'
matrix_case P09 vault-secret-print 'eval "infisical secrets"'
matrix_case P10 vault-secret-print '(infisical export) > /tmp/x'
matrix_case P11 vault-secret-print 'infisical run -- infisical secrets'
matrix_case P12 vault-secret-print 'echo before; infisical secrets | tee out'
matrix_case P13 vault-secret-print 'infisical secrets --env dev'

# DENY vault-run-dump: an allowed run whose child dumps the injected env.
matrix_case R01 vault-run-dump 'infisical run -- env'
matrix_case R02 vault-run-dump 'infisical run -- printenv'
matrix_case R03 vault-run-dump 'infisical run -- set'
matrix_case R04 vault-run-dump 'infisical run --env dev -- printenv'
matrix_case R05 vault-run-dump 'infisical run -- sudo env'
matrix_case R06 vault-run-dump 'infisical run -- xargs env'
matrix_case R07 vault-run-dump "infisical run -- sh -c 'echo \$DATABASE_URL'"
matrix_case R08 vault-run-dump "infisical run -- sh -c 'export'"
matrix_case R09 vault-run-dump 'infisical run --command "printenv"'
matrix_case R10 vault-run-dump 'infisical run -- echo $HOME'
matrix_case R11 vault-run-dump "infisical run -- echo '\$FOO'"
matrix_case R12 vault-run-dump "infisical run --command 'sh -c \"printenv\"'"
matrix_case R13 vault-run-dump 'infisical run -cprintenv'
matrix_case R14 vault-run-dump 'infisical run -- builtin export'
matrix_case R15 vault-run-dump 'infisical run -- sh -c "builtin export"'
matrix_case R16 vault-run-dump 'infisical run -- nice -n 1 printenv'
matrix_case R17 vault-run-dump 'infisical run -- nice -n 1 env FOO=1 printenv'
matrix_case R18 vault-run-dump 'infisical run -- stdbuf -oL printenv'
matrix_case R19 vault-run-dump 'infisical run -- xargs -I {} printenv'

# DENY unclassifiable-vault-command: fail closed around the token.
matrix_case U01 unclassifiable-vault-command 'xargs infisical secrets'
matrix_case U02 unclassifiable-vault-command 'for f in 1; do infisical secrets; done'
matrix_case U03 unclassifiable-vault-command 'infisical secrets "unclosed'
matrix_case U04 unclassifiable-vault-command 'VAR="infisical secrets"; bash -c "$VAR"'
matrix_case U05 unclassifiable-vault-command 'watch infisical secrets'
matrix_case U06 unclassifiable-vault-command 'nice infisical export'
matrix_case U07 unclassifiable-vault-command 'infisical $SUB'
matrix_case U08 unclassifiable-vault-command 'infisical run --command "$CMD"'
matrix_case U09 unclassifiable-vault-command 'time infisical secrets'
matrix_case U10 unclassifiable-vault-command 'infisical run -- SH -c "printenv"'
matrix_case U11 unclassifiable-vault-command 'infisical run -- nice --unknown printenv'

# DENY, case variance: macOS's default filesystem executes these for real.
matrix_case C01 vault-secret-print 'Infisical secrets'
matrix_case C02 vault-secret-print 'INFISICAL export'

# ALLOW: the injection form, setup forms, the wrapper, and data mentions.
matrix_case A01 allow 'infisical run --env=dev -- npm run dev'
matrix_case A02 allow 'infisical run --env dev -- node server.js'
matrix_case A03 allow 'infisical run -c "npm start"'
matrix_case A04 allow 'infisical run --command "npm install && npm test"'
matrix_case A05 allow 'infisical run -- env node server.js'
matrix_case A06 allow 'infisical run -- echo hello'
matrix_case A07 allow 'infisical login'
matrix_case A08 allow 'infisical init'
matrix_case A09 allow 'infisical --help'
matrix_case A10 allow 'infisical --version'
matrix_case A11 allow 'infisical secrets --help'
matrix_case A12 allow 'bin/fm-secrets-names.sh --projectId x --env dev'
matrix_case A13 allow 'echo "infisical secrets"'
matrix_case A14 allow 'grep -rn infisical docs/'
matrix_case A15 allow 'bash -c "infisical run -- npm start"'
matrix_case A16 allow 'git status'
matrix_case A17 allow 'npm install infisical-sdk'
matrix_case A18 allow 'infisical run --watch -- npm run dev'
matrix_case A19 allow 'command -v infisical'
matrix_case A20 allow 'Infisical run -- npm start'
matrix_case A21 allow 'infisical run -- watch -n 5 npm test'

MATRIX_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-vault-policy-matrix.XXXXXX")
FM_TEST_CLEANUP_DIRS+=("$MATRIX_TMP")

run_matrix_entry() {
  local id=$1 expected=$2 entry=$3 cmd=$4 payload out_file err_file rc
  out_file="$MATRIX_TMP/$id-$entry.out"
  err_file="$MATRIX_TMP/$id-$entry.err"

  case "$entry" in
    codex)
      payload=$(jq -cn --arg command "$cmd" '{tool_name:"Bash",tool_input:{command:$command}}')
      printf '%s' "$payload" | "$CHECK" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    claude)
      payload=$(jq -cn --arg command "$cmd" '{tool_name:"Bash",tool_input:{command:$command}}')
      printf '%s' "$payload" | "$CHECK" --claude >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    grok)
      payload=$(jq -cn --arg command "$cmd" '{toolName:"run_terminal_command",toolInput:{command:$command}}')
      printf '%s' "$payload" | "$CHECK" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    opencode|pi)
      "$CHECK" --command "$cmd" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    *)
      fail "unknown matrix entry form: $entry"
      ;;
  esac

  if [ "$expected" = allow ]; then
    [ "$rc" -eq 0 ] || fail "$id via $entry must allow, got exit $rc: $(cat "$err_file")"
    [ ! -s "$out_file" ] || fail "$id via $entry allow must leave stdout empty: $(cat "$out_file")"
    [ ! -s "$err_file" ] || fail "$id via $entry allow must leave stderr empty: $(cat "$err_file")"
    return
  fi

  [ "$rc" -eq 2 ] || fail "$id via $entry must deny, got exit $rc"
  jq -e --arg code "$expected" '.hookSpecificOutput.permissionDecision == "deny" and (.systemMessage | test("\\[" + $code + "\\]"))' "$err_file" >/dev/null 2>&1 \
    || fail "$id via $entry deny must carry the $expected reason code on stderr: $(cat "$err_file")"
  if [ "$entry" = claude ]; then
    [ ! -s "$out_file" ] || fail "$id via claude deny must leave stdout empty: $(cat "$out_file")"
  elif [ "$entry" = grok ]; then
    jq -e '.decision == "deny"' "$out_file" >/dev/null 2>&1 \
      || fail "$id via grok deny must carry decision=deny on stdout: $(cat "$out_file")"
  fi
}

test_full_acceptance_matrix() {
  local i entry
  for ((i = 0; i < ${#MATRIX_IDS[@]}; i++)); do
    for entry in codex claude grok opencode pi; do
      run_matrix_entry "${MATRIX_IDS[$i]}" "${MATRIX_EXPECTED[$i]}" "$entry" "${MATRIX_COMMANDS[$i]}"
    done
  done
  pass "vault-guard acceptance matrix: ${#MATRIX_IDS[@]} cases x 5 harness entry forms, block/allow and reason codes all correct"
}

# --- fail-open transport behavior ------------------------------------------

test_fail_open_empty_stdin() {
  local out rc
  out=$("$CHECK" < /dev/null 2>&1); rc=$?
  expect_code 0 "$rc" "transport must exit 0 on empty stdin"
  [ -z "$out" ] || fail "transport produced output on empty stdin: $out"
  pass "vault-guard: fails open on empty stdin"
}

test_fail_open_unparseable_json() {
  local out rc
  out=$(printf 'not json at all' | "$CHECK" 2>&1); rc=$?
  expect_code 0 "$rc" "transport must exit 0 on unparseable stdin JSON"
  [ -z "$out" ] || fail "transport produced output on unparseable JSON: $out"
  pass "vault-guard: fails open on unparseable stdin JSON"
}

test_fail_open_missing_node() {
  local fakebin tool tool_path out rc
  fakebin=$(fm_fakebin "$TMP_ROOT/nonode")
  for tool in bash sh dirname cat printf sed tr jq; do
    tool_path=$(command -v "$tool") || continue
    ln -s "$tool_path" "$fakebin/$tool"
  done
  # node deliberately absent from this PATH.
  out=$(PATH="$fakebin" "$CHECK" --command 'infisical secrets' 2>&1); rc=$?
  expect_code 0 "$rc" "transport must fail open when node is unavailable"
  [ -z "$out" ] || fail "transport produced output without node: $out"
  pass "vault-guard: fails open (never blocks) when node is missing"
}

test_fail_open_missing_jq_on_stdin() {
  local fakebin tool tool_path out rc
  fakebin=$(fm_fakebin "$TMP_ROOT/nojq")
  for tool in bash sh dirname cat printf sed tr node; do
    tool_path=$(command -v "$tool") || continue
    ln -s "$tool_path" "$fakebin/$tool"
  done
  # jq deliberately absent: the stdin transport cannot extract the command.
  out=$(printf '{"tool_input":{"command":"infisical secrets"}}' | PATH="$fakebin" "$CHECK" 2>&1); rc=$?
  expect_code 0 "$rc" "stdin transport must fail open when jq is unavailable"
  [ -z "$out" ] || fail "transport produced output without jq on the stdin path: $out"
  pass "vault-guard: fails open on the stdin path when jq is missing"
}

# --- prefilter fast path ----------------------------------------------------

test_prefilter_skips_node_without_infisical_substring() {
  local fakebin marker tool tool_path out rc
  fakebin=$(fm_fakebin "$TMP_ROOT/prefilter-fake")
  marker="$TMP_ROOT/prefilter-node-called"
  for tool in bash sh dirname cat printf sed tr jq; do
    tool_path=$(command -v "$tool") || continue
    ln -s "$tool_path" "$fakebin/$tool"
  done
  cat > "$fakebin/node" <<EOF
#!/usr/bin/env bash
: > "$marker"
exit 0
EOF
  chmod +x "$fakebin/node"
  # No infisical substring: the prefilter must fast-allow before the policy
  # runtime is ever consulted.
  out=$(PATH="$fakebin" "$CHECK" --command 'bin/fm-secrets-names.sh --projectId x --env dev' 2>&1); rc=$?
  expect_code 0 "$rc" "prefilter must fast-allow a command with no infisical substring"
  [ -z "$out" ] || fail "prefilter fast-allow produced output: $out"
  [ ! -e "$marker" ] || fail "prefilter fast-allow still invoked the node policy owner"
  pass "vault-guard: prefilter fast-allows (skips node) when no infisical substring is present"
}

test_prefilter_delegates_quote_split_token() {
  local out rc
  out=$("$CHECK" --command 'in"fisical" secrets' 2>&1); rc=$?
  expect_code 2 "$rc" "a quote-split infisical token must still reach the policy and deny"
  assert_contains "$out" '[vault-secret-print]' "quote-split deny must carry the reason code"
  pass "vault-guard: prefilter strict superset delegates quote-split tokens"
}

# --- policy CLI contract ----------------------------------------------------

test_policy_cli_direct() {
  [ "$(node "$POLICY" --command 'infisical secrets' | cut -f1)" = deny ] \
    || fail "policy CLI must deny a bare infisical secrets"
  [ "$(node "$POLICY" --command 'infisical run -- npm start')" = allow ] \
    || fail "policy CLI must allow the injection form"
  [ "$(node "$POLICY" --command 'infisical run -- env' | cut -f2)" = vault-run-dump ] \
    || fail "policy CLI must code a run env dump as vault-run-dump"
  [ "$(node "$POLICY")" = allow ] \
    || fail "policy CLI must allow when no command is supplied"
  pass "vault-guard: fm-vault-command-policy.mjs CLI honors the deny/allow output contract"
}

# --- names-only wrapper -----------------------------------------------------

make_wrapper_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/infisical" <<'EOF'
#!/usr/bin/env bash
case "${FAKE_SHAPE:-array}" in
  array) printf '[{"key":"DB_URL","value":"postgres://secret-value-1"},{"key":"API_KEY","value":"sk-secret-value-2"}]' ;;
  object) printf '{"DB_URL":"postgres://secret-value-1","API_KEY":"sk-secret-value-2"}' ;;
  empty-array) printf '[]' ;;
  empty-object) printf '{}' ;;
  mixed) printf '[{"key":"GOOD","value":"v"},{"noKey":true}]' ;;
  nested) printf '{"secrets":[{"key":"DB_URL","value":"secret-value-1"}],"meta":{}}' ;;
  array-value) printf '{"DB_URL":[]}' ;;
  object-value) printf '{"DB_URL":{}}' ;;
  number-value) printf '{"DB_URL":1}' ;;
  null-value) printf '{"DB_URL":null}' ;;
  garbage) printf 'DB_URL=secret-value-1\nAPI_KEY=secret-value-2\n' ;;
  fail) echo "auth error" >&2; exit 1 ;;
esac
EOF
  chmod +x "$fakebin/infisical"
  printf '%s\n' "$fakebin"
}

test_wrapper_names_only_array_shape() {
  local fakebin out rc
  fakebin=$(make_wrapper_fakebin "$TMP_ROOT/wrapper-array")
  out=$(PATH="$fakebin:$PATH" "$WRAPPER" --projectId p1 --env dev 2>/dev/null); rc=$?
  expect_code 0 "$rc" "wrapper must succeed on the array export shape"
  [ "$out" = 'DB_URL
API_KEY' ] || fail "wrapper array output must be names only, got: $out"
  case "$out" in *secret-value*) fail "wrapper array output leaked a value" ;; esac
  pass "fm-secrets-names.sh: array shape yields names only"
}

test_wrapper_names_only_object_shape() {
  local fakebin out rc
  fakebin=$(make_wrapper_fakebin "$TMP_ROOT/wrapper-object")
  out=$(FAKE_SHAPE=object PATH="$fakebin:$PATH" "$WRAPPER" --projectId p1 --env dev 2>/dev/null); rc=$?
  expect_code 0 "$rc" "wrapper must succeed on the flat object export shape"
  [ "$out" = 'DB_URL
API_KEY' ] || fail "wrapper object output must be names only, got: $out"
  case "$out" in *secret-value*) fail "wrapper object output leaked a value" ;; esac
  pass "fm-secrets-names.sh: flat object shape yields names only"
}

test_wrapper_allows_empty_known_shapes() {
  local fakebin out rc shape
  for shape in empty-array empty-object; do
    fakebin=$(make_wrapper_fakebin "$TMP_ROOT/wrapper-$shape")
    out=$(FAKE_SHAPE=$shape PATH="$fakebin:$PATH" "$WRAPPER" --projectId p1 --env dev 2>/dev/null); rc=$?
    expect_code 0 "$rc" "wrapper must accept the empty $shape export shape"
    [ -z "$out" ] || fail "wrapper empty $shape output must be empty, got: $out"
  done
  pass "fm-secrets-names.sh: empty known shapes succeed without output"
}

test_wrapper_fails_closed_on_unknown_shape() {
  local fakebin out rc shape
  for shape in mixed nested array-value object-value number-value null-value garbage; do
    fakebin=$(make_wrapper_fakebin "$TMP_ROOT/wrapper-$shape")
    out=$(FAKE_SHAPE=$shape PATH="$fakebin:$PATH" "$WRAPPER" --projectId p1 --env dev 2>/dev/null); rc=$?
    [ "$rc" -ne 0 ] || fail "wrapper must exit non-zero on the $shape shape"
    [ -z "$out" ] || fail "wrapper must print NOTHING on the $shape shape, got: $out"
  done
  pass "fm-secrets-names.sh: unrecognized shapes print nothing and exit non-zero (no raw fallback)"
}

test_wrapper_fails_closed_on_cli_failure() {
  local fakebin out rc
  fakebin=$(make_wrapper_fakebin "$TMP_ROOT/wrapper-fail")
  out=$(FAKE_SHAPE=fail PATH="$fakebin:$PATH" "$WRAPPER" --projectId p1 --env dev 2>/dev/null); rc=$?
  [ "$rc" -ne 0 ] || fail "wrapper must exit non-zero when infisical fails"
  [ -z "$out" ] || fail "wrapper must print nothing on stdout when infisical fails, got: $out"
  pass "fm-secrets-names.sh: CLI failure prints nothing and exits non-zero"
}

test_wrapper_requires_project_and_env() {
  local out rc
  out=$("$WRAPPER" --projectId p1 2>&1); rc=$?
  expect_code 2 "$rc" "wrapper must refuse a missing --env"
  assert_contains "$out" '--env is required' "wrapper must name the missing flag"
  out=$("$WRAPPER" --env dev 2>&1); rc=$?
  expect_code 2 "$rc" "wrapper must refuse a missing --projectId"
  out=$("$WRAPPER" --projectId p1 --env dev --plain 2>&1); rc=$?
  expect_code 2 "$rc" "wrapper must refuse unknown arguments"
  assert_contains "$out" 'unknown argument' "wrapper must reject value-ish flags it does not own"
  pass "fm-secrets-names.sh: requires --projectId and --env, rejects unknown flags"
}

# --- spawn installation per harness -----------------------------------------

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 harness=$2 id=$3 case_dir home proj wt fakebin launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  # Every case here is a ship spawn, and fm-spawn requires an explicit --mode
  # and --yolo for those. The values are irrelevant to vault-guard installation
  # (the guard is unconditional across delivery posture); they only satisfy the
  # intake contract so the spawn reaches the hook-install step under test.
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" --mode no-mistakes --yolo off 2>&1
}

test_spawn_installs_claude_vault_hook() {
  local rec id out status settings
  id=vault-claude-z1
  rec=$(make_spawn_case vault-claude claude "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn should succeed: $out"
  settings="$WT_DIR/.claude/settings.local.json"
  assert_present "$settings" "claude spawn must write settings.local.json"
  jq -e '.hooks.PreToolUse[0].matcher == "Bash"' "$settings" >/dev/null \
    || fail "claude settings.local.json must carry a PreToolUse Bash matcher"
  jq -e --arg c "$ROOT/bin/fm-vault-pretool-check.sh" '[.hooks.PreToolUse[0].hooks[].command | select(contains($c) and contains("--claude"))] | length == 1' "$settings" >/dev/null \
    || fail "claude vault hook must invoke the absolute checker path with --claude: $(cat "$settings")"
  jq -e '[.hooks.Stop[0].hooks[].command | select(contains("turn-ended"))] | length == 1' "$settings" >/dev/null \
    || fail "claude vault hook must not displace the turn-end Stop hook"
  pass "fm-spawn: claude crewmate gets the vault PreToolUse hook alongside the Stop hook"
}

test_spawn_installs_codex_vault_hook() {
  local rec id out status hooks launch
  id=vault-codex-z2
  rec=$(make_spawn_case vault-codex codex "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "codex spawn should succeed: $out"
  hooks="$WT_DIR/.codex/hooks.json"
  assert_present "$hooks" "codex spawn must write a worktree hooks.json"
  jq -e --arg c "$ROOT/bin/fm-vault-pretool-check.sh" '[.hooks.PreToolUse[0].hooks[].command | select(contains($c))] | length == 1' "$hooks" >/dev/null \
    || fail "codex worktree hooks.json must invoke the absolute checker path: $(cat "$hooks")"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" '--dangerously-bypass-hook-trust' \
    "codex crewmate launch must bypass hook trust so the worktree hook loads"
  git -C "$WT_DIR" check-ignore -q .codex/hooks.json \
    || fail "codex worktree hooks.json must be excluded from git's view"
  pass "fm-spawn: codex crewmate gets a worktree vault hooks.json plus the hook-trust launch flag"
}

test_spawn_skips_codex_hook_when_project_tracks_one() {
  local rec id out status
  id=vault-codex-skip-z3
  rec=$(make_spawn_case vault-codex-skip codex "$id")
  read_case_record "$rec"
  mkdir -p "$WT_DIR/.codex"
  printf '{"hooks":{}}\n' > "$WT_DIR/.codex/hooks.json"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "codex spawn should still succeed when hooks.json pre-exists: $out"
  assert_contains "$out" 'vault guard NOT installed' "pre-existing hooks.json must be warned loudly"
  [ "$(cat "$WT_DIR/.codex/hooks.json")" = '{"hooks":{}}' ] \
    || fail "a pre-existing (project-tracked) hooks.json must be left untouched"
  pass "fm-spawn: codex crewmate never clobbers a pre-existing hooks.json and warns about the gap"
}

test_spawn_installs_opencode_vault_plugin() {
  local rec id out status plugin
  id=vault-opencode-z4
  rec=$(make_spawn_case vault-opencode opencode "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "opencode spawn should succeed: $out"
  plugin="$WT_DIR/.opencode/plugins/fm-vault-guard.js"
  assert_present "$plugin" "opencode spawn must write the vault plugin"
  assert_contains "$(cat "$plugin")" 'tool.execute.before' "opencode vault plugin must run before tool execution"
  assert_contains "$(cat "$plugin")" "$ROOT/bin/fm-vault-pretool-check.sh" "opencode vault plugin must bake the absolute checker path"
  assert_contains "$(cat "$plugin")" 'throw new Error' "opencode vault plugin must block by throwing"
  node --check "$plugin" 2>/dev/null || fail "opencode vault plugin must be valid JS"
  assert_present "$WT_DIR/.opencode/plugins/fm-busy-state.js" "the busy-state/turn-end plugin must still be written"
  pass "fm-spawn: opencode crewmate gets the vault plugin alongside the turn-end plugin"
}

test_spawn_installs_pi_vault_handler() {
  local rec id out status ext
  id=vault-pi-z5
  rec=$(make_spawn_case vault-pi pi "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "pi spawn should succeed: $out"
  ext="$HOME_DIR/state/$id.pi-ext.ts"
  assert_present "$ext" "pi spawn must write the state extension"
  assert_contains "$(cat "$ext")" 'tool_call' "pi extension must handle tool_call"
  assert_contains "$(cat "$ext")" "$ROOT/bin/fm-vault-pretool-check.sh" "pi extension must bake the absolute checker path"
  assert_contains "$(cat "$ext")" 'block: true' "pi extension must block on a checker exit 2"
  assert_contains "$(cat "$ext")" 'turn_end' "pi extension must keep the turn-end handler"
  pass "fm-spawn: pi crewmate extension gains the vault tool_call handler next to turn-end"
}

test_spawn_installs_grok_vault_hook() {
  local rec id out status hook config deny_payload rc workspace
  id=vault-grok-z6
  rec=$(make_spawn_case vault-grok grok "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "grok spawn should succeed: $out"
  hook="$HOME_DIR/grok-home/hooks/fm-vault-guard.sh"
  config="$HOME_DIR/grok-home/hooks/fm-vault-guard.json"
  assert_present "$hook" "grok spawn must write the global vault hook script"
  assert_present "$config" "grok spawn must write the global vault hook config"
  jq -e '.hooks.PreToolUse[0].hooks[0].command | contains("fm-vault-guard.sh")' "$config" >/dev/null \
    || fail "grok vault hook config must invoke the global hook script"
  assert_contains "$(cat "$hook")" '.fm-grok-turnend' "grok vault hook must gate on the crewmate pointer"
  deny_payload='{"toolInput":{"command":"infisical secrets"}}'
  # Without the pointer the hook must be inert even for a deniable payload.
  workspace="$CASE_DIR/grok-nonfm"
  mkdir -p "$workspace"
  out=$(printf '%s' "$deny_payload" | GROK_WORKSPACE_ROOT="$workspace" bash "$hook" 2>&1); rc=$?
  expect_code 0 "$rc" "grok vault hook must be inert without the crewmate pointer"
  [ -z "$out" ] || fail "grok vault hook produced output outside a crewmate workspace: $out"
  # With the pointer (the spawned worktree) the same payload must deny.
  out=$(printf '%s' "$deny_payload" | GROK_WORKSPACE_ROOT="$WT_DIR" bash "$hook" 2>/dev/null); rc=$?
  expect_code 2 "$rc" "grok vault hook must deny a secrets listing inside a crewmate workspace"
  printf '%s' "$out" | jq -e '.decision == "deny"' >/dev/null \
    || fail "grok vault hook deny must carry the grok stdout decision object: $out"
  pass "fm-spawn: grok crewmate gets the pointer-gated global vault hook (inert elsewhere, denies in-workspace)"
}

# --- tracked primary/secondmate-home wiring ---------------------------------

test_claude_wiring() {
  local settings
  settings="$ROOT/.claude/settings.json"
  jq -e '[.hooks.PreToolUse[0].hooks[].command | select(contains("fm-vault-pretool-check.sh") and contains("--claude") and contains("CLAUDE_PROJECT_DIR"))] | length == 1' "$settings" >/dev/null \
    || fail "claude PreToolUse must invoke fm-vault-pretool-check.sh with CLAUDE_PROJECT_DIR and --claude"
  jq -e '[.hooks.PreToolUse[0].hooks[].command | select(contains("fm-arm-pretool-check.sh"))] | length == 1' "$settings" >/dev/null \
    || fail "claude vault hook must not displace the watcher-arm hook"
  jq -e '[.hooks.PreToolUse[0].hooks[].command | select(contains("fm-cd-pretool-check.sh"))] | length == 1' "$settings" >/dev/null \
    || fail "claude vault hook must not displace the cd-guard hook"
  pass ".claude/settings.json: PreToolUse invokes the vault guard alongside the arm and cd guards"
}

test_codex_wiring() {
  local settings command
  settings="$ROOT/.codex/hooks.json"
  command=$(jq -r '[.hooks.PreToolUse[0].hooks[].command | select(contains("fm-vault-pretool-check.sh"))][0] // empty' "$settings")
  [ -n "$command" ] || fail "codex PreToolUse must invoke fm-vault-pretool-check.sh"
  assert_contains "$command" 'pwd -P' "codex vault hook must anchor from the hook process working directory"
  jq -e '[.hooks.PreToolUse[0].hooks[].command | select(contains("fm-arm-pretool-check.sh"))] | length == 1' "$settings" >/dev/null \
    || fail "codex vault hook must not displace the watcher-arm hook"
  pass ".codex/hooks.json: PreToolUse invokes the vault guard alongside the arm and cd guards"
}

test_grok_wiring() {
  local settings command
  settings="$ROOT/.grok/hooks/fm-primary-vault-check.json"
  [ -f "$settings" ] || fail "tracked grok vault hook config is missing"
  command=$(jq -r '.hooks.PreToolUse[0].hooks[0].command // empty' "$settings")
  [ -n "$command" ] || fail "grok vault hook command is missing"
  assert_contains "$command" 'fm-vault-pretool-check.sh' "grok vault hook must invoke the vault guard"
  assert_contains "$command" '${GROK_WORKSPACE_ROOT:-}' "grok vault hook must default-guard the workspace var"
  pass ".grok primary vault hook: PreToolUse invokes the vault guard"
}

test_opencode_wiring() {
  local plugin content
  plugin="$ROOT/.opencode/plugins/fm-primary-vault-check.js"
  [ -f "$plugin" ] || fail "tracked OpenCode vault plugin is missing"
  content=$(cat "$plugin")
  assert_contains "$content" 'tool.execute.before' "OpenCode vault plugin must run before tool execution"
  assert_contains "$content" 'fm-vault-pretool-check.sh' "OpenCode vault plugin must invoke the vault guard"
  assert_contains "$content" 'throw new Error' "OpenCode vault plugin must block by throwing"
  pass ".opencode vault plugin: tool.execute.before invokes the vault guard and blocks by throwing"
}

test_pi_wiring() {
  local ext content
  ext="$ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
  content=$(cat "$ext")
  assert_contains "$content" 'runVaultCheck(command)' "pi extension must run the vault check in tool_call"
  assert_contains "$content" 'fm-vault-pretool-check.sh' "pi extension must invoke the vault-guard owner"
  assert_contains "$content" 'runPretoolCheck(command)' "pi extension must keep running the watcher-arm check"
  assert_contains "$content" 'runCdCheck(command)' "pi extension must keep running the cd check"
  pass ".pi primary extension: tool_call runs the vault guard alongside the arm and cd checks"
}

test_scripts_are_shellcheck_clean() {
  shellcheck "$ROOT/bin/fm-vault-pretool-check.sh" "$ROOT/bin/fm-secrets-names.sh" >/dev/null 2>&1 \
    || fail "vault-guard bin scripts are not shellcheck-clean"
  pass "bin/fm-vault-pretool-check.sh and bin/fm-secrets-names.sh are shellcheck-clean"
}

test_full_acceptance_matrix
test_fail_open_empty_stdin
test_fail_open_unparseable_json
test_fail_open_missing_node
test_fail_open_missing_jq_on_stdin
test_prefilter_skips_node_without_infisical_substring
test_prefilter_delegates_quote_split_token
test_policy_cli_direct
test_wrapper_names_only_array_shape
test_wrapper_names_only_object_shape
test_wrapper_allows_empty_known_shapes
test_wrapper_fails_closed_on_unknown_shape
test_wrapper_fails_closed_on_cli_failure
test_wrapper_requires_project_and_env
test_spawn_installs_claude_vault_hook
test_spawn_installs_codex_vault_hook
test_spawn_skips_codex_hook_when_project_tracks_one
test_spawn_installs_opencode_vault_plugin
test_spawn_installs_pi_vault_handler
test_spawn_installs_grok_vault_hook
test_claude_wiring
test_codex_wiring
test_grok_wiring
test_opencode_wiring
test_pi_wiring
test_scripts_are_shellcheck_clean
