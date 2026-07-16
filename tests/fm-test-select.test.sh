#!/usr/bin/env bash
# Contract and behavior tests for fail-closed Firstmate test selection.
#
# Each behavior case runs the real selector against an isolated repository with
# a bare origin.  The fixture retains the exact landed scout-contract dependency
# tree while reducing unrelated complete-suite entries to deterministic stubs.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SELECTOR="$ROOT/bin/fm-test-select.sh"
CONTRACT_BASE=54bb9c9d94ac3cc89d7e7d379a9a6eac95b01131
TRIGGER_LINE='- `scout-implementation-contract` - load before briefing a scout whose output may scope implementation, and before dispatching or promoting implementation from such a report.'

TMP=
REMOTE=
WORK=
OUT=
RC=0
trap fm_test_cleanup EXIT

usage() {
  cat <<'EOF'
usage: fm-test-select.test.sh [case-name|--help]

With no case name, run every selector test.  A named case runs only that case.
EOF
}

write_pass_test() {
  local path=$1 label=$2
  cat > "$path" <<EOF
#!/usr/bin/env bash
set -eu
if [ -n "\${FM_SELECTOR_TEST_LOG:-}" ]; then
  printf '%s\n' '$label' >> "\$FM_SELECTOR_TEST_LOG"
fi
printf 'ok - fixture $label\n'
EOF
  chmod +x "$path"
}

write_fail_test() {
  local path=$1 label=$2
  cat > "$path" <<EOF
#!/usr/bin/env bash
set -eu
if [ -n "\${FM_SELECTOR_TEST_LOG:-}" ]; then
  printf '%s\n' '$label' >> "\$FM_SELECTOR_TEST_LOG"
fi
printf 'not ok - fixture $label\n' >&2
exit 1
EOF
  chmod +x "$path"
}

setup_fixture() {
  local test_file
  if [ -n "$TMP" ]; then
    rm -rf "$TMP"
  fi
  TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-select.XXXXXX")
  FM_TEST_CLEANUP_DIRS=("$TMP")
  REMOTE="$TMP/origin.git"
  WORK="$TMP/work"

  git clone --quiet --bare "$ROOT" "$REMOTE"
  git --git-dir="$REMOTE" update-ref refs/heads/main "$CONTRACT_BASE"
  git --git-dir="$REMOTE" symbolic-ref HEAD refs/heads/main
  git clone --quiet --branch main "$REMOTE" "$WORK"
  fm_git_identity 'Selector Tests' 'selector@example.invalid'

  for test_file in "$WORK"/tests/*.test.sh; do
    case "${test_file#"$WORK"/}" in
      tests/fm-instruction-owners.test.sh|tests/fm-scout-implementation-contract.test.sh) ;;
      *) git -C "$WORK" rm -q "${test_file#"$WORK"/}" ;;
    esac
  done
  write_pass_test "$WORK/tests/a-pass.test.sh" a-pass
  write_pass_test "$WORK/tests/z-pass.test.sh" z-pass
  command cp "$SELECTOR" "$WORK/bin/fm-test-select.sh"
  chmod +x "$WORK/bin/fm-test-select.sh"
  git -C "$WORK" add tests bin/fm-test-select.sh
  git -C "$WORK" commit -qm 'test: slim selector fixture inventory'
  git -C "$WORK" push -q origin main
  git -C "$WORK" checkout -qb feature
}

commit_all() {
  git -C "$WORK" add -A
  git -C "$WORK" commit -qm "${1:-test change}"
}

run_selector() {
  local mode=$1
  shift
  RC=0
  OUT=$(cd "$WORK" && env "$@" "$SELECTOR" "$mode" 2>&1) || RC=$?
}

receipt() {
  printf '%s\n' "$OUT" | grep '^firstmate\.test-selection\.v1 ' | tail -1
}

assert_one_terminal_receipt() {
  local count last
  count=$(printf '%s\n' "$OUT" | grep -c '^firstmate\.test-selection\.v1 ')
  [ "$count" -eq 1 ] || fail "expected one selector receipt, found $count"$'\n'"$OUT"
  last=$(printf '%s\n' "$OUT" | tail -1)
  case "$last" in
    firstmate.test-selection.v1\ *) ;;
    *) fail "selector receipt is not terminal"$'\n'"$OUT" ;;
  esac
}

assert_receipt_field() {
  local field=$1 value=$2 line
  line=$(receipt)
  case " $line " in
    *" $field=$value "*) ;;
    *) fail "receipt missing $field=$value"$'\n'"$OUT" ;;
  esac
}

replace_trigger_line() {
  local input="$WORK/AGENTS.md" output="$WORK/AGENTS.md.new"
  awk -v trigger="$TRIGGER_LINE" '
    $0 == trigger { print trigger " changed"; next }
    { print }
  ' "$input" > "$output"
  mv "$output" "$input"
}

advance_target_with_full_failure() {
  git -C "$WORK" checkout -q main
  write_fail_test "$WORK/tests/a-pass.test.sh" a-pass
  git -C "$WORK" add tests/a-pass.test.sh
  git -C "$WORK" commit -qm 'test: target full failure'
  git -C "$WORK" push -q origin main
  git -C "$WORK" checkout -qB feature main
}

advance_target_with_concurrent_test() {
  git -C "$WORK" checkout -q main
  cat > "$WORK/tests/z-pass.test.sh" <<'SH'
#!/usr/bin/env bash
set -eu
printf 'concurrent mutation\n' >> README.md
printf 'ok - fixture concurrent mutation\n'
SH
  chmod +x "$WORK/tests/z-pass.test.sh"
  git -C "$WORK" add tests/z-pass.test.sh
  git -C "$WORK" commit -qm 'test: target concurrent mutation fixture'
  git -C "$WORK" push -q origin main
  git -C "$WORK" checkout -qB feature main
}

advance_target_selector_identity() {
  git -C "$WORK" checkout -q main
  printf '\n# changed target selector identity\n' >> "$WORK/bin/fm-test-select.sh"
  git -C "$WORK" add bin/fm-test-select.sh
  git -C "$WORK" commit -qm 'test: change target selector identity'
  git -C "$WORK" push -q origin main
  git -C "$WORK" checkout -qB feature main
}

advance_target_with_final_marker() {
  git -C "$WORK" checkout -q main
  cat > "$WORK/tests/z-pass.test.sh" <<'SH'
#!/usr/bin/env bash
set -eu
: > "${FM_SELECTOR_FINAL_MARKER:?}"
printf 'ok - fixture final snapshot marker\n'
SH
  chmod +x "$WORK/tests/z-pass.test.sh"
  git -C "$WORK" add tests/z-pass.test.sh
  git -C "$WORK" commit -qm 'test: add final snapshot marker'
  git -C "$WORK" push -q origin main
  git -C "$WORK" checkout -qB feature main
}

advance_target_with_signal_test() {
  git -C "$WORK" checkout -q main
  cat > "$WORK/tests/00-signal.test.sh" <<'SH'
#!/usr/bin/env bash
set -eu
kill -TERM "$PPID"
sleep 1
SH
  chmod +x "$WORK/tests/00-signal.test.sh"
  git -C "$WORK" add tests/00-signal.test.sh
  git -C "$WORK" commit -qm 'test: add selector signal fixture'
  git -C "$WORK" push -q origin main
  git -C "$WORK" checkout -qB feature main
}

test_eligible_skill() {
  setup_fixture
  printf '\n<!-- selector fixture -->\n' >> "$WORK/.agents/skills/scout-implementation-contract/SKILL.md"
  run_selector local
  expect_code 0 "$RC" eligible-skill
  assert_one_terminal_receipt
  assert_receipt_field classification instruction-scout-contract-v1
  assert_receipt_field reason eligible-skill
  assert_receipt_field local_plan focus
  assert_receipt_field focus_execution pass
  assert_receipt_field full_execution skipped
  pass "eligible-skill"
}

test_eligible_trigger() {
  setup_fixture
  replace_trigger_line
  run_selector local
  expect_code 0 "$RC" eligible-trigger
  assert_one_terminal_receipt
  assert_receipt_field classification instruction-scout-contract-v1
  assert_receipt_field reason eligible-trigger
  assert_receipt_field focus_execution pass
  assert_receipt_field full_execution skipped
  pass "eligible-trigger"
}

test_eligible_test_edit() {
  setup_fixture
  printf '\n# harmless selector fixture\n' >> "$WORK/tests/fm-scout-implementation-contract.test.sh"
  run_selector local
  expect_code 0 "$RC" eligible-test-edit-local
  assert_receipt_field reason eligible-test-edit
  assert_receipt_field focus_execution pass
  commit_all 'test: edit mapped contract test'
  run_selector gate-shadow
  expect_code 0 "$RC" eligible-test-edit-gate
  assert_receipt_field classification complete
  assert_receipt_field reason gate-mapped-test-change
  assert_receipt_field focus_execution skipped
  assert_receipt_field full_execution pass
  pass "eligible-test-edit"
}

test_gate_shadow_match() {
  setup_fixture
  printf '\n<!-- selector fixture -->\n' >> "$WORK/.agents/skills/scout-implementation-contract/SKILL.md"
  commit_all 'test: eligible skill change'
  run_selector gate-shadow
  expect_code 0 "$RC" gate-shadow-match
  assert_one_terminal_receipt
  assert_receipt_field focus_execution pass
  assert_receipt_field full_execution pass
  assert_receipt_field comparison match
  assert_receipt_field gate_plan full
  pass "gate-shadow-match"
}

test_explicit_full() {
  setup_fixture
  run_selector full
  expect_code 0 "$RC" explicit-full
  assert_one_terminal_receipt
  assert_receipt_field classification complete
  assert_receipt_field reason explicit-full
  assert_receipt_field focus_execution skipped
  assert_receipt_field full_execution pass
  assert_contains "$OUT" "tmux " "explicit full did not print tmux -V"
  pass "explicit-full"
}

test_empty_diff() {
  setup_fixture
  run_selector local
  expect_code 0 "$RC" empty-diff
  assert_one_terminal_receipt
  assert_receipt_field classification no-change
  assert_receipt_field local_plan no-change
  assert_receipt_field result no-change
  assert_receipt_field focus_execution skipped
  assert_receipt_field full_execution skipped
  pass "empty-diff"
}

test_local_dirty_inventory() {
  setup_fixture
  printf '\n<!-- selector fixture -->\n' >> "$WORK/.agents/skills/scout-implementation-contract/SKILL.md"
  commit_all 'test: committed delta'
  printf '\nselector staged\n' >> "$WORK/README.md"
  git -C "$WORK" add README.md
  git -C "$WORK" show HEAD:README.md > "$WORK/README.md"
  printf '\nselector worktree\n' >> "$WORK/CONTRIBUTING.md"
  printf 'selector untracked\n' > "$WORK/local-note.txt"
  run_selector local
  expect_code 0 "$RC" local-dirty-inventory
  assert_receipt_field worktree_state dirty
  assert_receipt_field classification complete
  assert_receipt_field full_execution pass
  pass "local-dirty-inventory"
}

test_stale_ancestry() {
  local sibling tree
  setup_fixture
  tree=$(git -C "$WORK" rev-parse 'origin/main^{tree}')
  sibling=$(printf 'sibling\n' | git -C "$WORK" commit-tree "$tree" -p "$CONTRACT_BASE")
  git -C "$WORK" checkout -q --detach "$sibling"
  run_selector local
  expect_code 0 "$RC" stale-ancestry
  assert_receipt_field classification complete
  assert_receipt_field reason target-contract-unproven
  assert_receipt_field full_execution pass
  pass "stale-ancestry"
}

test_unusual_safe_path() {
  setup_fixture
  printf 'safe unusual path\n' > "$WORK/unusual safe name.txt"
  run_selector local
  expect_code 0 "$RC" unusual-safe-path
  assert_receipt_field classification complete
  assert_receipt_field reason unmapped-change
  assert_receipt_field full_execution pass
  pass "unusual-safe-path"
}

test_reject_caller_policy() {
  local out rc
  setup_fixture
  rc=0
  out=$(cd "$WORK" && "$SELECTOR" local --base HEAD 2>&1) || rc=$?
  expect_code 64 "$rc" reject-caller-base
  assert_contains "$out" "usage:" "caller base input was not rejected with usage"
  rc=0
  out=$(cd "$WORK" && "$SELECTOR" --test tests/a-pass.test.sh 2>&1) || rc=$?
  expect_code 64 "$rc" reject-caller-test
  rc=0
  out=$(cd "$WORK" && "$SELECTOR" -h 2>&1) || rc=$?
  expect_code 64 "$rc" reject-undocumented-help-alias
  pass "reject-caller-policy"
}

test_agents_outside_region() {
  setup_fixture
  printf '\nOutside the one allowed trigger region.\n' >> "$WORK/AGENTS.md"
  run_selector local
  expect_code 0 "$RC" agents-outside-region
  assert_receipt_field classification complete
  assert_receipt_field reason agents-outside-trigger-region
  assert_receipt_field full_execution pass
  pass "agents-outside-region"
}

test_mixed_runtime() {
  setup_fixture
  printf '\n<!-- selector fixture -->\n' >> "$WORK/.agents/skills/scout-implementation-contract/SKILL.md"
  printf '\n# selector runtime fixture\n' >> "$WORK/bin/fm-backend.sh"
  run_selector local
  expect_code 0 "$RC" mixed-runtime
  assert_receipt_field classification complete
  assert_receipt_field reason mixed-runtime-change
  assert_receipt_field full_execution pass
  pass "mixed-runtime"
}

test_unknown_instruction() {
  setup_fixture
  printf '\nUnknown instruction change.\n' >> "$WORK/README.md"
  run_selector local
  expect_code 0 "$RC" unknown-instruction
  assert_receipt_field classification complete
  assert_receipt_field reason unknown-instruction-change
  pass "unknown-instruction"
}

test_shared_test_infra() {
  setup_fixture
  printf '\n# selector shared helper fixture\n' >> "$WORK/tests/lib.sh"
  run_selector local
  expect_code 0 "$RC" shared-test-infra
  assert_receipt_field classification complete
  assert_receipt_field reason shared-test-infra-change
  assert_receipt_field full_execution pass
  pass "shared-test-infra"
}

test_selector_self_change() {
  setup_fixture
  printf '\n# selector self-change fixture\n' >> "$WORK/bin/fm-test-select.sh"
  run_selector local
  expect_code 0 "$RC" selector-self-change
  assert_receipt_field classification complete
  assert_receipt_field reason selector-self-change
  assert_receipt_field full_execution pass
  pass "selector-self-change"
}

test_structural_changes() {
  setup_fixture
  chmod -x "$WORK/tests/fm-scout-implementation-contract.test.sh"
  run_selector local
  expect_code 0 "$RC" structural-changes
  assert_receipt_field classification complete
  assert_receipt_field reason structural-change
  assert_receipt_field full_execution pass
  pass "structural-changes"
}

test_invalid_paths() {
  local invalid
  setup_fixture
  invalid=$'invalid\npath.txt'
  printf 'invalid path fixture\n' > "$WORK/$invalid"
  run_selector local
  expect_code 0 "$RC" invalid-paths
  assert_receipt_field classification complete
  assert_receipt_field reason invalid-path
  assert_receipt_field full_execution pass
  assert_not_contains "$OUT" "invalid path.txt" "unsafe raw path leaked into output"
  pass "invalid-paths"
}

test_inventory_coverage() {
  local log a_line b_line z_line count
  setup_fixture
  log="$TMP/order.log"
  write_pass_test "$WORK/tests/b extra.test.sh" b-extra
  run_selector local FM_SELECTOR_TEST_LOG="$log"
  expect_code 0 "$RC" inventory-coverage
  assert_receipt_field classification complete
  assert_receipt_field full_execution pass
  assert_contains "$(receipt)" 'tests/b%20extra.test.sh' "receipt did not encode the unusual safe test path"
  count=$(wc -l < "$log" | tr -d ' ')
  [ "$count" -eq 3 ] || fail "expected three logging fixture tests exactly once, got $count"
  a_line=$(grep -n '^a-pass$' "$log" | cut -d: -f1)
  b_line=$(grep -n '^b-extra$' "$log" | cut -d: -f1)
  z_line=$(grep -n '^z-pass$' "$log" | cut -d: -f1)
  [ "$a_line" -lt "$b_line" ] && [ "$b_line" -lt "$z_line" ] \
    || fail "complete inventory was not lexical"$'\n'"$(cat "$log")"
  pass "inventory-coverage"
}

test_gate_owner() {
  local config="$ROOT/.no-mistakes.yaml"
  assert_grep "disable_project_settings: true" "$config" "gate owner lost project-settings refusal"
  assert_grep "lint: 'bin/fm-lint.sh'" "$config" "gate owner lost lint owner"
  assert_grep "store_in_repo: false" "$config" "gate owner enabled repository evidence"
  assert_grep "https://github.com/xLabs-OS/firstmate" "$config" "gate owner does not fetch authoritative target main"
  assert_grep "show HEAD:bin/fm-test-select.sh" "$config" "gate owner does not read trusted selector content"
  assert_grep 'bash "$tmp_dir/selector" gate-shadow' "$config" "gate owner does not invoke gate-shadow"
  assert_no_grep "allow_repo_commands" "$config" "gate owner enabled branch repository commands"
  pass "gate-owner"
}

test_local_owner() {
  local contributing="$ROOT/CONTRIBUTING.md"
  assert_grep "bin/fm-test-select.sh local" "$contributing" "local guidance does not invoke selector"
  assert_grep "Focused selection is local feedback" "$contributing" "local guidance overstates focused authority"
  assert_grep "no-mistakes still runs the complete suite" "$contributing" "local guidance lost the complete gate backstop"
  pass "local-owner"
}

test_receipt_schema() {
  local line field
  setup_fixture
  run_selector full
  expect_code 0 "$RC" receipt-schema
  assert_one_terminal_receipt
  line=$(receipt)
  for field in policy_version context target_base_ref target_base_tip merge_base head \
    worktree_state diff_digest diff_count classification reason local_plan gate_plan \
    ordered_tests focus_execution focus_results full_execution full_results comparison \
    snapshot_stability result; do
    case " $line " in
      *" $field="*) ;;
      *) fail "receipt schema is missing $field"$'\n'"$line" ;;
    esac
  done
  printf '%s\n' "$line" | grep -Eq ' target_base_tip=([0-9a-f]{40,64}|unavailable) ' \
    || fail "target base tip is not lowercase hex or unavailable"
  printf '%s\n' "$line" | grep -Eq ' diff_digest=([0-9a-f]{40,64}|unavailable) ' \
    || fail "diff digest is not lowercase hex or unavailable"
  assert_receipt_field snapshot_stability stable
  assert_receipt_field result pass
  pass "receipt-schema"
}

test_idempotent() {
  local first second
  setup_fixture
  run_selector full
  expect_code 0 "$RC" idempotent-first
  first=$(receipt)
  run_selector full
  expect_code 0 "$RC" idempotent-second
  second=$(receipt)
  [ "$first" = "$second" ] || fail "same snapshot produced different receipts"$'\n'"$first"$'\n'"$second"
  pass "idempotent"
}

test_full_order_and_aggregate() {
  local log a_line z_line
  setup_fixture
  log="$TMP/order.log"
  write_fail_test "$WORK/tests/a-pass.test.sh" a-pass
  run_selector full FM_SELECTOR_TEST_LOG="$log"
  expect_code 1 "$RC" full-order-and-aggregate
  assert_receipt_field full_execution fail
  assert_receipt_field result fail
  assert_grep "a-pass" "$log" "failing first test did not run"
  assert_grep "z-pass" "$log" "suite stopped before the later test"
  a_line=$(grep -n '^a-pass$' "$log" | cut -d: -f1)
  z_line=$(grep -n '^z-pass$' "$log" | cut -d: -f1)
  [ "$a_line" -lt "$z_line" ] || fail "complete suite order was not lexical"
  pass "full-order-and-aggregate"
}

test_tmux_required_for_full() {
  setup_fixture
  run_selector full PATH=/usr/bin:/bin
  expect_code 70 "$RC" tmux-required-for-full
  assert_receipt_field full_execution blocked
  assert_receipt_field reason complete-tools-unavailable
  assert_receipt_field result error
  pass "tmux-required-for-full"
}

test_unsafe_full_inventory() {
  setup_fixture
  ln -s a-pass.test.sh "$WORK/tests/unsafe.test.sh"
  run_selector full
  expect_code 70 "$RC" unsafe-full-inventory
  assert_receipt_field reason unsafe-full-inventory
  assert_receipt_field full_execution skipped
  pass "unsafe-full-inventory"
}

test_fetch_failure() {
  setup_fixture
  git -C "$WORK" remote set-url origin "$TMP/missing-origin.git"
  run_selector local
  expect_code 0 "$RC" fetch-failure
  assert_receipt_field target_base_tip unavailable
  assert_receipt_field classification complete
  assert_receipt_field reason target-fetch-unavailable
  assert_receipt_field full_execution pass
  pass "fetch-failure"
}

test_shallow_no_base() {
  local orphan tree
  setup_fixture
  tree=$(git -C "$WORK" rev-parse 'origin/main^{tree}')
  orphan=$(printf 'orphan target\n' | git -C "$WORK" commit-tree "$tree")
  git -C "$WORK" push -q --force origin "$orphan:refs/heads/main"
  run_selector local
  expect_code 0 "$RC" shallow-no-base
  assert_receipt_field classification complete
  assert_receipt_field reason target-contract-unproven
  assert_receipt_field full_execution pass
  pass "shallow-no-base"
}

test_trusted_selector_missing() {
  local config="$ROOT/.no-mistakes.yaml"
  assert_grep 'git -C "$tmp_dir/target" show HEAD:bin/fm-test-select.sh > "$tmp_dir/selector"' "$config" \
    "trusted loader does not fail when target main lacks the selector"
  assert_no_grep 'git show HEAD:bin/fm-test-select.sh' "$config" \
    "trusted loader can fall back to branch selector content"
  pass "trusted-selector-missing"
}

test_shadow_full_fails() {
  setup_fixture
  advance_target_with_full_failure
  printf '\n<!-- selector fixture -->\n' >> "$WORK/.agents/skills/scout-implementation-contract/SKILL.md"
  commit_all 'test: eligible skill over failing target full suite'
  run_selector gate-shadow
  expect_code 1 "$RC" shadow-full-fails
  assert_receipt_field focus_execution pass
  assert_receipt_field full_execution fail
  assert_receipt_field comparison match
  assert_receipt_field result fail
  pass "shadow-full-fails"
}

test_shadow_focus_fails() {
  setup_fixture
  awk '!/single owner of Firstmate.s hardened scout report and implementation-packet contract/' \
    "$WORK/.agents/skills/scout-implementation-contract/SKILL.md" \
    > "$WORK/.agents/skills/scout-implementation-contract/SKILL.md.new"
  mv "$WORK/.agents/skills/scout-implementation-contract/SKILL.md.new" \
    "$WORK/.agents/skills/scout-implementation-contract/SKILL.md"
  commit_all 'test: eligible failing skill change'
  run_selector gate-shadow
  expect_code 1 "$RC" shadow-focus-fails
  assert_receipt_field focus_execution fail
  assert_receipt_field full_execution fail
  assert_receipt_field comparison match
  assert_receipt_field result fail
  pass "shadow-focus-fails"
}

test_concurrent_change() {
  setup_fixture
  advance_target_with_concurrent_test
  run_selector full
  expect_code 75 "$RC" concurrent-change
  assert_one_terminal_receipt
  assert_receipt_field snapshot_stability changed
  assert_receipt_field reason concurrent-snapshot-change
  assert_receipt_field result error
  pass "concurrent-change"
}

test_gate_selector_identity() {
  setup_fixture
  advance_target_selector_identity
  printf '\n<!-- eligible stale-selector fixture -->\n' \
    >> "$WORK/.agents/skills/scout-implementation-contract/SKILL.md"
  commit_all 'test: eligible change over new target selector'
  run_selector gate-shadow
  expect_code 70 "$RC" gate-selector-identity
  assert_one_terminal_receipt
  assert_receipt_field reason trusted-selector-mismatch
  assert_receipt_field focus_execution skipped
  assert_receipt_field full_execution skipped
  assert_receipt_field result error
  pass "gate-selector-identity"
}

test_target_moves_during_final_snapshot() {
  local marker moved target_tip tree mover_pid mover_rc=0 current i=1
  setup_fixture
  advance_target_with_final_marker
  mkdir -p "$WORK/bulk-final-snapshot"
  while [ "$i" -le 400 ]; do
    printf 'final snapshot inventory %04d\n' "$i" \
      > "$WORK/bulk-final-snapshot/item-$i.txt"
    i=$((i + 1))
  done
  target_tip=$(git -C "$WORK" rev-parse main)
  tree=$(git -C "$WORK" rev-parse 'main^{tree}')
  moved=$(printf 'moved target\n' | git -C "$WORK" commit-tree "$tree" -p "$target_tip")
  git -C "$WORK" push -q origin "$moved:refs/heads/selector-moved"
  marker="$TMP/final-snapshot.marker"
  (
    attempts=0
    while [ ! -e "$marker" ] && [ "$attempts" -lt 500 ]; do
      sleep 0.01
      attempts=$((attempts + 1))
    done
    [ -e "$marker" ] || exit 1
    sleep 0.1
    git --git-dir="$REMOTE" update-ref refs/heads/main "$moved"
  ) &
  mover_pid=$!
  run_selector full FM_SELECTOR_FINAL_MARKER="$marker"
  wait "$mover_pid" || mover_rc=$?
  [ "$mover_rc" -eq 0 ] || fail "target mover did not complete"
  current=$(git --git-dir="$REMOTE" rev-parse refs/heads/main)
  [ "$current" = "$moved" ] || fail "target main did not move during the fixture"
  expect_code 75 "$RC" target-moves-during-final-snapshot
  assert_one_terminal_receipt
  assert_receipt_field snapshot_stability changed
  assert_receipt_field reason concurrent-snapshot-change
  assert_receipt_field result error
  assert_not_contains "$(receipt)" "result=pass" "target movement emitted a pass receipt"
  pass "target-moves-during-final-snapshot"
}

test_signal_receipt_cleanup() {
  local selector_tmp remaining
  setup_fixture
  advance_target_with_signal_test
  selector_tmp="$TMP/selector temp [safe]"
  mkdir -p "$selector_tmp"
  run_selector full TMPDIR="$selector_tmp"
  expect_code 70 "$RC" signal-receipt-cleanup
  assert_one_terminal_receipt
  assert_receipt_field reason terminated-by-signal
  assert_receipt_field full_execution interrupted
  assert_receipt_field snapshot_stability unavailable
  assert_receipt_field result error
  remaining=$(find "$selector_tmp" -mindepth 1 -print -quit)
  [ -z "$remaining" ] || fail "signal exit left selector temporary state behind"
  pass "signal-receipt-cleanup"
}

test_explicit_full_dirty_count() {
  setup_fixture
  printf '\n<!-- explicit full committed fixture -->\n' \
    >> "$WORK/.agents/skills/scout-implementation-contract/SKILL.md"
  commit_all 'test: explicit full committed layer'
  printf '\nexplicit full index layer\n' >> "$WORK/README.md"
  git -C "$WORK" add README.md
  printf '\nexplicit full worktree layer\n' >> "$WORK/CONTRIBUTING.md"
  printf 'explicit full untracked layer\n' > "$WORK/explicit-full-untracked.txt"
  run_selector full
  expect_code 0 "$RC" explicit-full-dirty-count
  assert_one_terminal_receipt
  assert_receipt_field worktree_state dirty
  assert_receipt_field classification complete
  assert_receipt_field reason explicit-full
  assert_receipt_field diff_count 4
  assert_receipt_field full_execution pass
  assert_receipt_field result pass
  pass "explicit-full-dirty-count"
}

test_loader_cleanup_safety() {
  local config="$ROOT/.no-mistakes.yaml" loader fakebin loader_root keep rc=0 remaining
  setup_fixture
  assert_grep 'cleanup() { rm -rf -- "$tmp_dir"; }' "$config" \
    "trusted loader cleanup is not a quoted static function"
  assert_grep 'trap cleanup EXIT' "$config" "trusted loader does not install the static cleanup trap"
  assert_no_grep 'trap "rm -rf' "$config" "trusted loader reparses an expanded cleanup path"
  loader=$(sed -n "s/^  test: '\(.*\)'$/\1/p" "$config")
  [ -n "$loader" ] || fail "could not extract trusted loader command"
  fakebin="$TMP/loader-fakebin"
  loader_root="$TMP/nontrivial safe [loader root]"
  keep="$TMP/keep me"
  mkdir -p "$fakebin" "$loader_root" "$keep"
  cat > "$fakebin/git" <<'SH'
#!/bin/bash
set -eu
case "${1:-}" in
  clone)
    last=
    for arg in "$@"; do
      last=$arg
    done
    mkdir -p "$last"
    ;;
  -C)
    [ "${3:-}" = show ] || exit 2
    printf '#!/usr/bin/env bash\nexit 0\n'
    ;;
  *) exit 2 ;;
esac
SH
  cat > "$fakebin/bash" <<'SH'
#!/bin/bash
exit 17
SH
  chmod +x "$fakebin/git" "$fakebin/bash"
  PATH="$fakebin:$PATH" TMPDIR="$loader_root" /bin/sh -c "$loader" || rc=$?
  expect_code 17 "$rc" loader-child-status
  assert_present "$keep" "trusted loader cleanup removed a sibling path"
  remaining=$(find "$loader_root" -mindepth 1 -print -quit)
  [ -z "$remaining" ] || fail "trusted loader did not remove only its created directory"
  pass "loader-cleanup-safety"
}

CASES=(
  eligible-skill
  eligible-trigger
  eligible-test-edit
  gate-shadow-match
  explicit-full
  empty-diff
  local-dirty-inventory
  stale-ancestry
  unusual-safe-path
  reject-caller-policy
  agents-outside-region
  mixed-runtime
  unknown-instruction
  shared-test-infra
  selector-self-change
  structural-changes
  invalid-paths
  inventory-coverage
  gate-owner
  local-owner
  receipt-schema
  idempotent
  full-order-and-aggregate
  tmux-required-for-full
  unsafe-full-inventory
  fetch-failure
  shallow-no-base
  trusted-selector-missing
  shadow-full-fails
  shadow-focus-fails
  concurrent-change
  gate-selector-identity
  target-moves-during-final-snapshot
  signal-receipt-cleanup
  explicit-full-dirty-count
  loader-cleanup-safety
)

run_case() {
  case "$1" in
    eligible-skill) test_eligible_skill ;;
    eligible-trigger) test_eligible_trigger ;;
    eligible-test-edit) test_eligible_test_edit ;;
    gate-shadow-match) test_gate_shadow_match ;;
    explicit-full) test_explicit_full ;;
    empty-diff) test_empty_diff ;;
    local-dirty-inventory) test_local_dirty_inventory ;;
    stale-ancestry) test_stale_ancestry ;;
    unusual-safe-path) test_unusual_safe_path ;;
    reject-caller-policy) test_reject_caller_policy ;;
    agents-outside-region) test_agents_outside_region ;;
    mixed-runtime) test_mixed_runtime ;;
    unknown-instruction) test_unknown_instruction ;;
    shared-test-infra) test_shared_test_infra ;;
    selector-self-change) test_selector_self_change ;;
    structural-changes) test_structural_changes ;;
    invalid-paths) test_invalid_paths ;;
    inventory-coverage) test_inventory_coverage ;;
    gate-owner) test_gate_owner ;;
    local-owner) test_local_owner ;;
    receipt-schema) test_receipt_schema ;;
    idempotent) test_idempotent ;;
    full-order-and-aggregate) test_full_order_and_aggregate ;;
    tmux-required-for-full) test_tmux_required_for_full ;;
    unsafe-full-inventory) test_unsafe_full_inventory ;;
    fetch-failure) test_fetch_failure ;;
    shallow-no-base) test_shallow_no_base ;;
    trusted-selector-missing) test_trusted_selector_missing ;;
    shadow-full-fails) test_shadow_full_fails ;;
    shadow-focus-fails) test_shadow_focus_fails ;;
    concurrent-change) test_concurrent_change ;;
    gate-selector-identity) test_gate_selector_identity ;;
    target-moves-during-final-snapshot) test_target_moves_during_final_snapshot ;;
    signal-receipt-cleanup) test_signal_receipt_cleanup ;;
    explicit-full-dirty-count) test_explicit_full_dirty_count ;;
    loader-cleanup-safety) test_loader_cleanup_safety ;;
    *) fail "unknown selector test case: $1" ;;
  esac
}

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  usage
  exit 0
fi
if [ "$#" -gt 1 ]; then
  usage >&2
  exit 64
fi
if [ "$#" -eq 1 ]; then
  run_case "$1"
  exit 0
fi

for case_name in "${CASES[@]}"; do
  run_case "$case_name"
done
