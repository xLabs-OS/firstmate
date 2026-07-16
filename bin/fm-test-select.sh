#!/usr/bin/env bash
# fm-test-select.sh - fail-closed path-aware Firstmate test selection.
#
# This script is the single owner of the Phase 1 selection policy, execution
# order, snapshot checks, and terminal receipt.  Focused execution is feedback,
# never final-gate authority: gate-shadow always runs the complete suite once,
# whether or not it first shadows an eligible focused plan.
#
# Public commands:
#   fm-test-select.sh local       focus an exact mapped contract change, else full
#   fm-test-select.sh gate-shadow optionally shadow focus, then always run full
#   fm-test-select.sh full        run the complete suite without selecting focus
#   fm-test-select.sh --help      print this help
#
# The caller cannot supply a base, risk, path, test, skip, mapping, or policy.
# The selector fetches origin/main into a restrictive temporary object store so
# it does not update the checkout's refs, index, worktree, or configuration.
#
# Exit status:
#   0   requested tests passed, or local found no change
#   1   one or more requested tests failed, or shadow/full results mismatched
#   64  invalid usage
#   70  repository, trust, tool, base, or inventory failure blocked safe coverage
#   75  the repository or target snapshot changed during execution
set -u
set -o pipefail

export LC_ALL=C
umask 077

POLICY_VERSION=instruction-scout-contract-v1
TARGET_BASE_REF=origin/main
CONTRACT_BASE=54bb9c9d94ac3cc89d7e7d379a9a6eac95b01131
# The backticks are literal Markdown from the one allowed trigger line.
# shellcheck disable=SC2016
TRIGGER_LINE='- `scout-implementation-contract` - load before briefing a scout whose output may scope implementation, and before dispatching or promoting implementation from such a report.'

FOCUS_TESTS=(
  tests/fm-instruction-owners.test.sh
  tests/fm-scout-implementation-contract.test.sh
)

CONTRACT_DEPENDENCIES=(
  .agents/skills/scout-implementation-contract/SKILL.md
  AGENTS.md
  tests/fm-instruction-owners.test.sh
  tests/fm-scout-implementation-contract.test.sh
  tests/lib.sh
)

usage() {
  cat <<'EOF'
usage: fm-test-select.sh {local|gate-shadow|full|--help}

Run fail-closed Firstmate test selection.  Focus is available only for the
exact instruction-scout-contract-v1 mapping; every unknown or unsafe change
falls back to the complete suite.  gate-shadow always runs the complete suite.
EOF
}

if [ "$#" -ne 1 ]; then
  usage >&2
  exit 64
fi

case "$1" in
  local|gate-shadow|full) CONTEXT=$1 ;;
  --help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 64
    ;;
esac

SELECTOR_SOURCE=${BASH_SOURCE[0]}
case "$SELECTOR_SOURCE" in
  /*) ;;
  *) SELECTOR_SOURCE="$(pwd -P)/$SELECTOR_SOURCE" ;;
esac

# Receipt fields default to documented unavailable/skipped values so failures
# never imply that an observation or a test run occurred.
TARGET_BASE_TIP=unavailable
MERGE_BASE=unavailable
HEAD_SHA=unavailable
WORKTREE_STATE=unavailable
DIFF_DIGEST=unavailable
DIFF_COUNT=unavailable
CLASSIFICATION=complete
REASON=unavailable
LOCAL_PLAN=full
GATE_PLAN=full
ORDERED_TESTS=none
FOCUS_EXECUTION=skipped
FOCUS_RESULTS=unavailable
FULL_EXECUTION=skipped
FULL_RESULTS=unavailable
COMPARISON=not-applicable
SNAPSHOT_STABILITY=unavailable
RESULT=error
RECEIPT_EMITTED=false

emit_receipt() {
  if "$RECEIPT_EMITTED"; then
    return 0
  fi
  RECEIPT_EMITTED=true
  printf '%s\n' \
    "firstmate.test-selection.v1 policy_version=$POLICY_VERSION context=$CONTEXT target_base_ref=$TARGET_BASE_REF target_base_tip=$TARGET_BASE_TIP merge_base=$MERGE_BASE head=$HEAD_SHA worktree_state=$WORKTREE_STATE diff_digest=$DIFF_DIGEST diff_count=$DIFF_COUNT classification=$CLASSIFICATION reason=$REASON local_plan=$LOCAL_PLAN gate_plan=$GATE_PLAN ordered_tests=$ORDERED_TESTS focus_execution=$FOCUS_EXECUTION focus_results=$FOCUS_RESULTS full_execution=$FULL_EXECUTION full_results=$FULL_RESULTS comparison=$COMPARISON snapshot_stability=$SNAPSHOT_STABILITY result=$RESULT"
}

# shellcheck disable=SC2329 # Invoked by the signal trap below.
handle_signal() {
  trap - HUP INT TERM
  REASON=terminated-by-signal
  RESULT=error
  SNAPSHOT_STABILITY=unavailable
  if [ "$FOCUS_EXECUTION" = running ]; then
    FOCUS_EXECUTION=interrupted
    FOCUS_RESULTS=unavailable
  fi
  if [ "$FULL_EXECUTION" = running ]; then
    FULL_EXECUTION=interrupted
    FULL_RESULTS=unavailable
  fi
  emit_receipt
  exit 70
}

trap handle_signal HUP INT TERM

coverage_error() {
  REASON=$1
  printf 'fm-test-select: %s\n' "$2" >&2
  RESULT=error
  emit_receipt
  exit 70
}

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
  REASON=repository-unavailable
  printf 'fm-test-select: a Git worktree is required\n' >&2
  emit_receipt
  exit 70
}
cd "$ROOT" 2>/dev/null || {
  REASON=repository-unavailable
  printf 'fm-test-select: the Git worktree is unavailable\n' >&2
  emit_receipt
  exit 70
}

HEAD_SHA=$(git rev-parse --verify 'HEAD^{commit}' 2>/dev/null) \
  || coverage_error repository-head-unavailable "HEAD does not resolve to a commit"

STATUS_OUTPUT=$(git status --porcelain=v1 --untracked-files=all 2>/dev/null) \
  || coverage_error repository-status-unavailable "cannot inspect repository status"
if [ -n "$STATUS_OUTPUT" ]; then
  WORKTREE_STATE=dirty
else
  WORKTREE_STATE=clean
fi

if [ "$CONTEXT" = gate-shadow ] && [ "$WORKTREE_STATE" != clean ]; then
  coverage_error gate-checkout-dirty "gate-shadow requires a clean committed checkout"
fi

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-select.XXXXXX") \
  || coverage_error temporary-storage-unavailable "cannot create restrictive temporary storage"
chmod 700 "$TMP_ROOT" 2>/dev/null || {
  rm -rf "$TMP_ROOT"
  coverage_error temporary-storage-unavailable "cannot restrict temporary storage"
}
# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
cleanup_selector() {
  rm -rf -- "$TMP_ROOT"
}
trap cleanup_selector EXIT

hash_file() {
  git hash-object --stdin < "$1" 2>/dev/null
}

safe_path() {
  local candidate=$1
  [ -n "$candidate" ] || return 1
  case "$candidate" in
    /*|../*|*/../*|*/..|..|*$'\n'*|*$'\r'*|*$'\t'*)
      return 1
      ;;
  esac
  if printf '%s' "$candidate" | grep -q '[[:cntrl:]]'; then
    return 1
  fi
  return 0
}

encode_path() {
  local value=$1
  value=${value//'%'/'%25'}
  value=${value//' '/'%20'}
  value=${value//','/'%2C'}
  value=${value//';'/'%3B'}
  value=${value//'='/'%3D'}
  value=${value//'['/'%5B'}
  value=${value//']'/'%5D'}
  printf '%s' "$value"
}

join_encoded_tests() {
  local joined='' test encoded
  for test in "$@"; do
    encoded=$(encode_path "$test")
    if [ -n "$joined" ]; then
      joined="$joined,$encoded"
    else
      joined=$encoded
    fi
  done
  printf '%s' "$joined"
}

# Fetch target main into a temporary bare repository.  An alternate points at
# the checkout's existing object store, while the checkout later points at the
# temporary store for any newly fetched objects.  No checkout ref is updated.
ORIGIN_URL=
TARGET_GIT="$TMP_ROOT/target.git"
TARGET_FETCHED=false
fetch_target() {
  local object_dir
  ORIGIN_URL=$(git remote get-url origin 2>/dev/null) || return 1
  [ -n "$ORIGIN_URL" ] || return 1
  git init --bare -q "$TARGET_GIT" >/dev/null 2>&1 || return 1
  object_dir=$(git rev-parse --path-format=absolute --git-path objects 2>/dev/null) \
    || return 1
  mkdir -p "$TARGET_GIT/objects/info" || return 1
  printf '%s\n' "$object_dir" > "$TARGET_GIT/objects/info/alternates" || return 1
  git -C "$TARGET_GIT" fetch --quiet --no-tags "$ORIGIN_URL" \
    '+refs/heads/main:refs/heads/main' >/dev/null 2>&1 || return 1
  TARGET_BASE_TIP=$(git -C "$TARGET_GIT" rev-parse --verify \
    'refs/heads/main^{commit}' 2>/dev/null) || return 1
  case "$TARGET_BASE_TIP" in
    *[!0-9a-f]*|'') return 1 ;;
  esac
  if [ -n "${GIT_ALTERNATE_OBJECT_DIRECTORIES:-}" ]; then
    export GIT_ALTERNATE_OBJECT_DIRECTORIES="$TARGET_GIT/objects:$GIT_ALTERNATE_OBJECT_DIRECTORIES"
  else
    export GIT_ALTERNATE_OBJECT_DIRECTORIES="$TARGET_GIT/objects"
  fi
  TARGET_FETCHED=true
  return 0
}

if ! fetch_target; then
  TARGET_BASE_TIP=unavailable
  REASON='target-fetch-unavailable'
fi

verify_gate_selector_identity() {
  local target_selector="$TMP_ROOT/target-selector" running_hash target_hash
  [ "$CONTEXT" = gate-shadow ] || return 0
  "$TARGET_FETCHED" \
    || coverage_error trusted-selector-unavailable "gate-shadow cannot verify target-main selector identity"
  [ -f "$SELECTOR_SOURCE" ] && [ ! -L "$SELECTOR_SOURCE" ] \
    || coverage_error trusted-selector-unavailable "the running gate selector is not a regular file"
  git -C "$TARGET_GIT" show \
    "$TARGET_BASE_TIP:bin/fm-test-select.sh" > "$target_selector" 2>/dev/null \
    || coverage_error trusted-selector-unavailable "target main does not contain the trusted selector"
  running_hash=$(git hash-object --stdin < "$SELECTOR_SOURCE" 2>/dev/null) \
    || coverage_error trusted-selector-unavailable "cannot hash the running gate selector"
  target_hash=$(git hash-object --stdin < "$target_selector" 2>/dev/null) \
    || coverage_error trusted-selector-unavailable "cannot hash the target-main selector"
  if [ "$running_hash" != "$target_hash" ]; then
    coverage_error trusted-selector-mismatch "the running gate selector does not match target main"
  fi
}

verify_gate_selector_identity

# Inventory is the lexical filesystem set, not a caller-provided list.  Every
# member must be a safe regular non-symlink before complete execution is safe.
TESTS=()
TEST_INVENTORY_DIGEST=unavailable
load_test_inventory() {
  local test file_digest manifest="$TMP_ROOT/test-inventory"
  TESTS=()
  : > "$manifest"
  shopt -s nullglob
  TESTS=(tests/*.test.sh)
  shopt -u nullglob
  [ "${#TESTS[@]}" -gt 0 ] || return 1
  for test in "${TESTS[@]}"; do
    safe_path "$test" || return 1
    [ -f "$test" ] && [ ! -L "$test" ] || return 1
    file_digest=$(git hash-object --stdin < "$test" 2>/dev/null) || return 1
    printf '%s\0%s\n' "$test" "$file_digest" >> "$manifest" || return 1
  done
  TEST_INVENTORY_DIGEST=$(hash_file "$manifest") || return 1
  case "$TEST_INVENTORY_DIGEST" in
    *[!0-9a-f]*|'') return 1 ;;
  esac
  return 0
}

load_test_inventory \
  || coverage_error unsafe-full-inventory "tests/*.test.sh must be a nonempty safe regular non-symlink inventory"

FULL_TEST_LIST=$(join_encoded_tests "${TESTS[@]}")

# Snapshot untracked names, types, and content without ever logging a path.
untracked_manifest() {
  local output=$1 list="$TMP_ROOT/untracked-list" path digest target
  git ls-files --others --exclude-standard -z -- > "$list" 2>/dev/null || return 1
  : > "$output"
  while IFS= read -r -d '' path; do
    printf '%s\0' "$path" >> "$output" || return 1
    if [ -L "$path" ]; then
      target=$(readlink "$path" 2>/dev/null) || return 1
      digest=$(printf '%s' "$target" | git hash-object --stdin 2>/dev/null) || return 1
      printf 'symlink\0%s\n' "$digest" >> "$output" || return 1
    elif [ -f "$path" ]; then
      digest=$(git hash-object --stdin < "$path" 2>/dev/null) || return 1
      printf 'regular\0%s\n' "$digest" >> "$output" || return 1
    else
      printf 'other\0unavailable\n' >> "$output" || return 1
    fi
  done < "$list"
  return 0
}

snapshot_signature() {
  local output=$1 index_file worktree_file untracked_file tests_file
  local index_digest worktree_digest untracked_digest tests_digest snapshot_head
  index_file="$TMP_ROOT/snapshot-index"
  worktree_file="$TMP_ROOT/snapshot-worktree"
  untracked_file="$TMP_ROOT/snapshot-untracked"
  tests_file="$TMP_ROOT/snapshot-tests"

  snapshot_head=$(git rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || return 1
  {
    git ls-files --stage -z --
    git diff --cached --binary --full-index --no-ext-diff HEAD --
  } > "$index_file" 2>/dev/null || return 1
  git diff --binary --full-index --no-ext-diff -- > "$worktree_file" 2>/dev/null \
    || return 1
  untracked_manifest "$untracked_file" || return 1

  : > "$tests_file"
  local test file_digest
  local -a current_tests
  shopt -s nullglob
  current_tests=(tests/*.test.sh)
  shopt -u nullglob
  [ "${#current_tests[@]}" -gt 0 ] || return 1
  for test in "${current_tests[@]}"; do
    safe_path "$test" || return 1
    [ -f "$test" ] && [ ! -L "$test" ] || return 1
    file_digest=$(git hash-object --stdin < "$test" 2>/dev/null) || return 1
    printf '%s\0%s\n' "$test" "$file_digest" >> "$tests_file" || return 1
  done

  index_digest=$(hash_file "$index_file") || return 1
  worktree_digest=$(hash_file "$worktree_file") || return 1
  untracked_digest=$(hash_file "$untracked_file") || return 1
  tests_digest=$(hash_file "$tests_file") || return 1
  printf '%s\n' \
    "head=$snapshot_head" \
    "index=$index_digest" \
    "worktree=$worktree_digest" \
    "untracked=$untracked_digest" \
    "tests=$tests_digest" > "$output" || return 1
  return 0
}

INITIAL_SNAPSHOT="$TMP_ROOT/initial-snapshot"
snapshot_signature "$INITIAL_SNAPSHOT" \
  || coverage_error snapshot-unavailable "cannot capture a safe repository snapshot"
INITIAL_TEST_DIGEST=$(hash_file "$TMP_ROOT/snapshot-tests") \
  || coverage_error snapshot-unavailable "cannot verify the test inventory snapshot"
SNAPSHOT_HEAD=$(awk -F= '/^head=/ { print $2; exit }' "$INITIAL_SNAPSHOT")
SNAPSHOT_STATUS=$(git status --porcelain=v1 --untracked-files=all 2>/dev/null) \
  || coverage_error repository-status-unavailable "cannot recheck repository status"
if [ -n "$SNAPSHOT_STATUS" ]; then
  SNAPSHOT_WORKTREE_STATE=dirty
else
  SNAPSHOT_WORKTREE_STATE=clean
fi
if [ "$INITIAL_TEST_DIGEST" != "$TEST_INVENTORY_DIGEST" ] \
  || [ "$SNAPSHOT_HEAD" != "$HEAD_SHA" ] \
  || { [ "$CONTEXT" = gate-shadow ] && [ "$SNAPSHOT_WORKTREE_STATE" != clean ]; }; then
  SNAPSHOT_STABILITY=changed
  REASON=concurrent-snapshot-change
  RESULT=error
  emit_receipt
  exit 75
fi
WORKTREE_STATE=$SNAPSHOT_WORKTREE_STATE

# Focus trust requires the fixed contract commit (or a successor with the exact
# dependency tree), the target base as an ancestor of HEAD, and no shallow or
# parser uncertainty.  Any failure simply selects complete coverage.
FOCUS_TRUSTED=false
if "$TARGET_FETCHED"; then
  if git -C "$TARGET_GIT" cat-file -e "$CONTRACT_BASE^{commit}" 2>/dev/null \
    && git -C "$TARGET_GIT" merge-base --is-ancestor \
      "$CONTRACT_BASE" "$TARGET_BASE_TIP" >/dev/null 2>&1 \
    && git -C "$TARGET_GIT" diff --quiet "$CONTRACT_BASE" "$TARGET_BASE_TIP" \
      -- "${CONTRACT_DEPENDENCIES[@]}" >/dev/null 2>&1 \
    && git -C "$TARGET_GIT" merge-base --is-ancestor \
      "$TARGET_BASE_TIP" "$HEAD_SHA" >/dev/null 2>&1; then
    MERGE_BASE=$(git -C "$TARGET_GIT" merge-base "$TARGET_BASE_TIP" "$HEAD_SHA" 2>/dev/null) \
      || MERGE_BASE=unavailable
    if [ "$MERGE_BASE" = "$TARGET_BASE_TIP" ]; then
      FOCUS_TRUSTED=true
    else
      REASON='target-ancestry-unproven'
    fi
  else
    REASON='target-contract-unproven'
  fi
fi

RAW_COMMITTED="$TMP_ROOT/diff-committed"
RAW_INDEX="$TMP_ROOT/diff-index"
RAW_WORKTREE="$TMP_ROOT/diff-worktree"
UNTRACKED_LIST="$TMP_ROOT/diff-untracked"
DIFF_BYTES="$TMP_ROOT/diff-bytes"
DIFF_AVAILABLE=false
if "$TARGET_FETCHED" \
  && git diff --raw -z --find-renames --no-ext-diff \
    "$TARGET_BASE_TIP" "$HEAD_SHA" -- > "$RAW_COMMITTED" 2>/dev/null \
  && git diff --cached --raw -z --find-renames --no-ext-diff \
    "$HEAD_SHA" -- > "$RAW_INDEX" 2>/dev/null \
  && git diff --raw -z --find-renames --no-ext-diff -- \
    > "$RAW_WORKTREE" 2>/dev/null \
  && git ls-files --others --exclude-standard -z -- \
    > "$UNTRACKED_LIST" 2>/dev/null; then
  {
    printf 'committed\0'
    command cat "$RAW_COMMITTED"
    printf 'index\0'
    command cat "$RAW_INDEX"
    printf 'worktree\0'
    command cat "$RAW_WORKTREE"
    printf 'untracked\0'
    command cat "$UNTRACKED_LIST"
  } > "$DIFF_BYTES"
  DIFF_DIGEST=$(hash_file "$DIFF_BYTES") || DIFF_DIGEST=unavailable
  DIFF_AVAILABLE=true
fi

CHANGE_PATHS=()
CHANGE_STATUSES=()
CHANGE_OLD_MODES=()
CHANGE_NEW_MODES=()
PARSE_UNSAFE=false
PARSE_STRUCTURAL=false
DIFF_PARSED=false

parse_raw_file() {
  local raw_file=$1 meta first newmode status oldmode path oldpath
  while IFS= read -r -d '' meta <&3; do
    IFS=' ' read -r first newmode _ _ status <<EOF
$meta
EOF
    oldmode=${first#:}
    [ -n "$oldmode" ] && [ -n "$newmode" ] && [ -n "$status" ] || return 1
    case "$status" in
      R*|C*)
        IFS= read -r -d '' oldpath <&3 || return 1
        IFS= read -r -d '' path <&3 || return 1
        safe_path "$oldpath" || PARSE_UNSAFE=true
        PARSE_STRUCTURAL=true
        ;;
      *)
        IFS= read -r -d '' path <&3 || return 1
        ;;
    esac
    safe_path "$path" || PARSE_UNSAFE=true
    CHANGE_PATHS+=("$path")
    CHANGE_STATUSES+=("$status")
    CHANGE_OLD_MODES+=("$oldmode")
    CHANGE_NEW_MODES+=("$newmode")
    DIFF_COUNT=$((DIFF_COUNT + 1))
  done 3< "$raw_file"
  return 0
}

parse_diff() {
  local path
  DIFF_COUNT=0
  parse_raw_file "$RAW_COMMITTED" || return 1
  parse_raw_file "$RAW_INDEX" || return 1
  parse_raw_file "$RAW_WORKTREE" || return 1

  while IFS= read -r -d '' path; do
    safe_path "$path" || PARSE_UNSAFE=true
    CHANGE_PATHS+=("$path")
    CHANGE_STATUSES+=("?")
    CHANGE_OLD_MODES+=("000000")
    CHANGE_NEW_MODES+=("untracked")
    DIFF_COUNT=$((DIFF_COUNT + 1))
  done < "$UNTRACKED_LIST"
  return 0
}

agents_trigger_only() {
  local base_file="$TMP_ROOT/agents-base" base_without="$TMP_ROOT/agents-base-without"
  local state_file state_without line count base_lines state_lines
  local head_file="$TMP_ROOT/agents-head" index_file="$TMP_ROOT/agents-index"
  local worktree_file="$TMP_ROOT/agents-worktree"
  git -C "$TARGET_GIT" show "$TARGET_BASE_TIP:AGENTS.md" > "$base_file" 2>/dev/null \
    || return 1
  count=$(grep -Fxc -- "$TRIGGER_LINE" "$base_file" 2>/dev/null) || count=0
  [ "$count" -eq 1 ] || return 1
  line=$(grep -Fnx -- "$TRIGGER_LINE" "$base_file" | cut -d: -f1)
  base_lines=$(wc -l < "$base_file" | tr -d ' ')
  awk -v line="$line" 'NR != line { print }' "$base_file" > "$base_without" || return 1
  git show "$HEAD_SHA:AGENTS.md" > "$head_file" 2>/dev/null || return 1
  git show :AGENTS.md > "$index_file" 2>/dev/null || return 1
  command cp AGENTS.md "$worktree_file" || return 1
  for state_file in "$head_file" "$index_file" "$worktree_file"; do
    state_lines=$(wc -l < "$state_file" | tr -d ' ')
    [ "$base_lines" = "$state_lines" ] || return 1
    state_without="$state_file.without"
    awk -v line="$line" 'NR != line { print }' "$state_file" > "$state_without" \
      || return 1
    cmp -s "$base_without" "$state_without" || return 1
  done
  return 0
}

classify_diff() {
  local i path status oldmode newmode allowed_count=0 skill_seen=false
  local agents_seen=false test_seen=false disallowed_reason=
  if ! "$DIFF_AVAILABLE"; then
    REASON=diff-unavailable
    return 1
  fi
  if ! "$DIFF_PARSED"; then
    REASON=diff-parse-uncertain
    return 1
  fi
  if "$PARSE_UNSAFE"; then
    REASON=invalid-path
    return 1
  fi
  if "$PARSE_STRUCTURAL"; then
    REASON=structural-change
    return 1
  fi
  if [ "$DIFF_COUNT" -eq 0 ]; then
    CLASSIFICATION=no-change
    REASON=no-change
    LOCAL_PLAN=no-change
    return 0
  fi

  i=0
  while [ "$i" -lt "${#CHANGE_PATHS[@]}" ]; do
    path=${CHANGE_PATHS[$i]}
    status=${CHANGE_STATUSES[$i]}
    oldmode=${CHANGE_OLD_MODES[$i]}
    newmode=${CHANGE_NEW_MODES[$i]}
    case "$path" in
      .agents/skills/scout-implementation-contract/SKILL.md)
        if [ "$status" = M ] && [ "$oldmode" = 100644 ] \
          && [ "$newmode" = 100644 ] && [ -f "$path" ] && [ ! -L "$path" ] \
          && [ ! -x "$path" ]; then
          skill_seen=true
          allowed_count=$((allowed_count + 1))
        else
          disallowed_reason=structural-change
        fi
        ;;
      AGENTS.md)
        if [ "$status" = M ] && [ "$oldmode" = 100644 ] \
          && [ "$newmode" = 100644 ] && [ -f "$path" ] && [ ! -L "$path" ] \
          && [ ! -x "$path" ] && agents_trigger_only; then
          agents_seen=true
          allowed_count=$((allowed_count + 1))
        else
          disallowed_reason=agents-outside-trigger-region
        fi
        ;;
      tests/fm-scout-implementation-contract.test.sh)
        if { [ "$status" = M ] || [ "$status" = A ] || [ "$status" = '?' ]; } \
          && { [ "$oldmode" = 100755 ] || [ "$oldmode" = 000000 ]; } \
          && { [ "$newmode" = 100755 ] || [ "$newmode" = untracked ]; } \
          && [ -f "$path" ] && [ ! -L "$path" ] && [ -x "$path" ]; then
          test_seen=true
          allowed_count=$((allowed_count + 1))
        else
          disallowed_reason=structural-change
        fi
        ;;
      bin/fm-test-select.sh|tests/fm-test-select.test.sh)
        disallowed_reason=selector-self-change
        ;;
      tests/lib.sh|tests/*-helpers.sh|tests/*-helper.sh)
        disallowed_reason=shared-test-infra-change
        ;;
      .agents/*|CLAUDE.md|CONTRIBUTING.md|README.md|docs/*|skills/*)
        disallowed_reason=unknown-instruction-change
        ;;
      bin/backends/*|bin/fm-backend.sh|bin/fm-spawn.sh|bin/fm-watch.sh|bin/fm-teardown.sh|state/*|config/*)
        disallowed_reason=mixed-runtime-change
        ;;
      *)
        disallowed_reason=unmapped-change
        ;;
    esac
    i=$((i + 1))
  done

  if [ -n "$disallowed_reason" ] || [ "$allowed_count" -ne "$DIFF_COUNT" ]; then
    REASON=${disallowed_reason:-mixed-change}
    return 1
  fi
  if "$test_seen" && [ "$CONTEXT" = gate-shadow ]; then
    REASON=gate-mapped-test-change
    return 1
  fi

  CLASSIFICATION=instruction-scout-contract-v1
  LOCAL_PLAN=focus
  if "$skill_seen" && ! "$agents_seen" && ! "$test_seen"; then
    REASON=eligible-skill
  elif "$agents_seen" && ! "$skill_seen" && ! "$test_seen"; then
    REASON=eligible-trigger
  elif "$test_seen" && ! "$skill_seen" && ! "$agents_seen"; then
    REASON=eligible-test-edit
  else
    REASON=eligible-contract-bundle
  fi
  return 0
}

if "$DIFF_AVAILABLE" && parse_diff; then
  DIFF_PARSED=true
else
  DIFF_COUNT=unavailable
fi

verify_final_stability() {
  local final_snapshot="$TMP_ROOT/final-snapshot" target_recheck="$TMP_ROOT/target-recheck"
  local latest_target='' latest_ref='' extra='' line_count=0
  local row_target row_ref row_extra
  if ! snapshot_signature "$final_snapshot" \
    || ! cmp -s "$INITIAL_SNAPSHOT" "$final_snapshot"; then
    SNAPSHOT_STABILITY=changed
    RESULT=error
    REASON=concurrent-snapshot-change
    emit_receipt
    exit 75
  fi
  if "$TARGET_FETCHED"; then
    if ! git ls-remote --heads "$ORIGIN_URL" refs/heads/main \
      > "$target_recheck" 2>/dev/null; then
      SNAPSHOT_STABILITY=unavailable
      RESULT=error
      REASON='target-recheck-unavailable'
      emit_receipt
      exit 70
    fi
    while IFS=$'\t' read -r row_target row_ref row_extra; do
      line_count=$((line_count + 1))
      latest_target=$row_target
      latest_ref=$row_ref
      extra=$row_extra
    done < "$target_recheck"
    if [ "$line_count" -eq 0 ]; then
      SNAPSHOT_STABILITY=changed
      RESULT=error
      REASON=concurrent-snapshot-change
      emit_receipt
      exit 75
    fi
    if [ "$latest_ref" != refs/heads/main ] || [ -n "$extra" ] \
      || [ "$line_count" -ne 1 ]; then
      SNAPSHOT_STABILITY=unavailable
      RESULT=error
      REASON='target-recheck-unavailable'
      emit_receipt
      exit 70
    fi
    case "$latest_target" in
      *[!0-9a-f]*|'')
        SNAPSHOT_STABILITY=unavailable
        RESULT=error
        REASON='target-recheck-unavailable'
        emit_receipt
        exit 70
        ;;
    esac
    if [ "$latest_target" != "$TARGET_BASE_TIP" ]; then
      SNAPSHOT_STABILITY=changed
      RESULT=error
      REASON=concurrent-snapshot-change
      emit_receipt
      exit 75
    fi
  fi
  SNAPSHOT_STABILITY=stable
}

if [ "$CONTEXT" = full ]; then
  CLASSIFICATION=complete
  REASON=explicit-full
  LOCAL_PLAN=full
elif ! "$FOCUS_TRUSTED"; then
  CLASSIFICATION=complete
  LOCAL_PLAN=full
  [ "$REASON" != unavailable ] || REASON='target-trust-unavailable'
else
  classify_diff || {
    CLASSIFICATION=complete
    LOCAL_PLAN=full
  }
fi

if [ "$CONTEXT" = local ] && [ "$CLASSIFICATION" = no-change ]; then
  ORDERED_TESTS=none
  verify_final_stability
  RESULT=no-change
  emit_receipt
  exit 0
fi

FOCUS_CODES=
FULL_FOCUS_CODES=
FOCUS_FAILED=0
FULL_FAILED=0
FULL_PASSED=0

run_focus() {
  local test rc
  FOCUS_CODES=
  FOCUS_FAILED=0
  FOCUS_EXECUTION=running
  if ! command -v bash >/dev/null 2>&1; then
    FOCUS_EXECUTION=blocked
    FOCUS_RESULTS=unavailable
    FOCUS_FAILED=${#FOCUS_TESTS[@]}
    return 70
  fi
  for test in "${FOCUS_TESTS[@]}"; do
    if [ ! -f "$test" ] || [ -L "$test" ]; then
      rc=70
    else
      printf '== %s ==\n' "$test"
      rc=0
      bash "$test" || rc=$?
    fi
    if [ -n "$FOCUS_CODES" ]; then
      FOCUS_CODES="$FOCUS_CODES,$rc"
    else
      FOCUS_CODES=$rc
    fi
    [ "$rc" -eq 0 ] || FOCUS_FAILED=$((FOCUS_FAILED + 1))
  done
  FOCUS_RESULTS=$FOCUS_CODES
  if [ "$FOCUS_FAILED" -eq 0 ]; then
    FOCUS_EXECUTION=pass
  else
    FOCUS_EXECUTION=fail
  fi
}

run_full() {
  local test rc
  FULL_FAILED=0
  FULL_PASSED=0
  FULL_FOCUS_CODES=
  FULL_EXECUTION=running
  if ! command -v bash >/dev/null 2>&1 || ! command -v tmux >/dev/null 2>&1; then
    FULL_EXECUTION=blocked
    FULL_RESULTS=unavailable
    return 70
  fi
  tmux -V || {
    FULL_EXECUTION=blocked
    FULL_RESULTS=unavailable
    return 70
  }
  for test in "${TESTS[@]}"; do
    printf '== %s ==\n' "$test"
    rc=0
    bash "$test" || rc=$?
    if [ "$rc" -eq 0 ]; then
      FULL_PASSED=$((FULL_PASSED + 1))
    else
      FULL_FAILED=$((FULL_FAILED + 1))
    fi
    case "$test" in
      tests/fm-instruction-owners.test.sh|tests/fm-scout-implementation-contract.test.sh)
        if [ -n "$FULL_FOCUS_CODES" ]; then
          FULL_FOCUS_CODES="$FULL_FOCUS_CODES,$rc"
        else
          FULL_FOCUS_CODES=$rc
        fi
        ;;
    esac
  done
  FULL_RESULTS="passed:$FULL_PASSED,failed:$FULL_FAILED"
  if [ "$FULL_FAILED" -eq 0 ]; then
    FULL_EXECUTION=pass
    return 0
  fi
  FULL_EXECUTION=fail
  return 1
}

TEST_EXIT=0
if [ "$CLASSIFICATION" = instruction-scout-contract-v1 ]; then
  focus_rc=0
  run_focus || focus_rc=$?
  ORDERED_TESTS="focus[$(join_encoded_tests "${FOCUS_TESTS[@]}")]"
  if [ "$focus_rc" -eq 70 ]; then
    TEST_EXIT=70
    REASON=bash-unavailable
  elif [ "$FOCUS_FAILED" -ne 0 ]; then
    TEST_EXIT=1
  fi
fi

if [ "$CONTEXT" = gate-shadow ] || [ "$LOCAL_PLAN" = full ] || [ "$CONTEXT" = full ]; then
  if [ "$ORDERED_TESTS" = none ]; then
    ORDERED_TESTS="full[$FULL_TEST_LIST]"
  else
    ORDERED_TESTS="$ORDERED_TESTS;full[$FULL_TEST_LIST]"
  fi
  full_rc=0
  run_full || full_rc=$?
  if [ "$full_rc" -eq 70 ]; then
    TEST_EXIT=70
    REASON=complete-tools-unavailable
  elif [ "$full_rc" -ne 0 ]; then
    TEST_EXIT=1
  fi
fi

if [ "$CONTEXT" = gate-shadow ] && [ "$FOCUS_EXECUTION" != skipped ]; then
  if [ "$FOCUS_CODES" = "$FULL_FOCUS_CODES" ]; then
    COMPARISON=match
  else
    COMPARISON=mismatch
    TEST_EXIT=1
  fi
fi

verify_final_stability

case "$TEST_EXIT" in
  0)
    RESULT=pass
    emit_receipt
    exit 0
    ;;
  1)
    RESULT=fail
    emit_receipt
    exit 1
    ;;
  70)
    RESULT=error
    emit_receipt
    exit 70
    ;;
  *)
    RESULT=error
    REASON=execution-error
    emit_receipt
    exit 70
    ;;
esac
