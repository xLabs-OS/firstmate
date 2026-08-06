#!/usr/bin/env bash
# Regression tests for fm-spawn.sh's worktree recording (the treehouse block
# for non-secondmate, non-orca spawns).
#
# The recorded worktree= must come from the allocator, never from the pane.
# fm-spawn.sh asks `treehouse get --lease` for the allocated path, cds the
# pane into it, and uses the backend's current-path probe only to CONFIRM
# arrival before launch. The old flow inferred the worktree by polling the
# probe for the first path that left the project, which raced treehouse's own
# candidate probing: backends can report a real, distinct checkout that
# treehouse never allocated (live: herdr's foreground_cwd member scan
# reporting treehouse's git probes inside a wedged pool slot), and that value
# passes both the "differs from the project" check and validate_spawn_worktree
# (it IS a real git checkout, just the wrong one). These tests simulate a
# probe that reports such a stale path - transiently and persistently - with
# a fake tmux, and assert the recorded worktree is always the leased path,
# with the spawn refusing to launch (and releasing the lease) when the pane
# never confirms inside it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)

# make_settle_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS
# calls, then FM_FAKE_PANE_PATH forever after - reproducing a pane probe that
# reports a stale path before (or instead of) the pane's real location.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_treehouse "$fakebin"
  printf '%s\n' "$fakebin"
}

# make_settle_case <name> <id> <stale_reads> builds a home, a primary project
# with a real worktree (the leased path), and a separate real git repo
# standing in for the stale path (a real checkout of something else entirely,
# distinct from both the project and the worktree - mirroring the live
# incidents where the stale read was another real checkout or pool slot).
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_worktree "$case_dir/stale-repo" "$stale" "stale-$name"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

read_settle_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    FM_FAKE_LEASE_PATH="$WT_DIR" FM_FAKE_TREEHOUSE_LOG="$CASE_DIR/treehouse.log" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# The core regression for the live misrecord: a probe that reports a stale
# path on enough consecutive reads to satisfy any settle heuristic must not
# decide the record. The recorded worktree must be the allocator's answer.
test_recorded_worktree_comes_from_allocator_not_probe() {
  local rec id out status
  id=settle-authority-z3
  rec=$(make_settle_case settle-authority "$id" 2)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane confirms in the leased worktree"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta recorded the probe's stale path instead of the allocation"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the leased worktree"
  assert_grep "get --lease" "$CASE_DIR/treehouse.log" \
    "spawn did not take the worktree from treehouse get --lease"
  pass "the recorded worktree comes from the allocator, not the probe"
}

# A pane that is never observed inside the leased worktree must fail the
# spawn instead of launching with a record the pane's location contradicts,
# and the abort must release the lease so the slot is not stranded.
test_persistently_wrong_probe_fails_spawn_and_releases_lease() {
  local rec id out status
  id=settle-neverconfirm-z4
  rec=$(make_settle_case settle-neverconfirm "$id" 999)
  read_settle_record "$rec"

  out=$(FM_SPAWN_WORKTREE_CONFIRM_POLLS=3 FM_SPAWN_WORKTREE_CONFIRM_INTERVAL=0 \
    run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn must fail when the pane never confirms inside the leased worktree; output: $out"
  assert_contains "$out" "$WT_DIR" "the failure did not name the leased worktree"
  if [ -f "$HOME_DIR/state/$id.meta" ]; then
    assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
      "meta recorded the probe's stale path on a failed spawn"
  fi
  assert_grep "return --force $WT_DIR" "$CASE_DIR/treehouse.log" \
    "the aborted spawn did not release its worktree lease"
  pass "an unconfirmed pane fails the spawn and releases the lease"
}

# A single stale first read (the original incident shape) is ignored by the
# confirmation wait: the spawn settles on the leased worktree.
test_single_stale_first_read_is_not_accepted() {
  local rec id out status
  id=settle-single-stale-z1
  rec=$(make_settle_case settle-single "$id" 1)
  read_settle_record "$rec"

  out=$(FM_SPAWN_WORKTREE_CONFIRM_INTERVAL=0 run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  pass "a single transient stale pane_current_path read is not accepted as the worktree"
}

# A pane already observed at the leased worktree confirms on the first read:
# equality with the known allocation is arrival, so no extra settle cycles.
test_already_settled_pane_confirms_immediately() {
  local rec id out status start end elapsed
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  start=$(date +%s)
  out=$(run_settle_spawn "$id")
  status=$?
  end=$(date +%s)
  elapsed=$((end - start))
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  [ "$elapsed" -le 5 ] || fail "already-settled pane took ${elapsed}s to confirm - expected an immediate first-read confirmation"
  pass "an already-settled pane confirms on the first probe read"
}

test_recorded_worktree_comes_from_allocator_not_probe
test_persistently_wrong_probe_fails_spawn_and_releases_lease
test_single_stale_first_read_is_not_accepted
test_already_settled_pane_confirms_immediately

echo "# all fm-spawn-worktree-settle tests passed"
