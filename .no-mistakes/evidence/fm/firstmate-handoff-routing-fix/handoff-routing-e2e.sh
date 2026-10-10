#!/usr/bin/env bash
# Creates a disposable home under the no-mistakes evidence directory and
# exercises the public worker status, local reconciliation, and parent relay
# interfaces used by the stable handoff identity change.
set -euo pipefail

ROOT=/Users/eli/.no-mistakes/worktrees/e4f4fb783e8f/01M4KX46E1WBNV1SQB1KGSZDQY
EVIDENCE_DIR=/Users/eli/.no-mistakes/evidence/01M4KX46E1WBNV1SQB1KGSZDQY
WORLD=$(mktemp -d "$EVIDENCE_DIR/handoff-routing-world.XXXXXX")
trap 'rm -rf "$WORLD"' EXIT

make_fake_tools() {
  mkdir -p "$WORLD/fakebin"
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'EOF'
#!/usr/bin/env bash
printf 'state: working · source: fixture\n'
EOF
  cat > "$WORLD/fakebin/tmux" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'idle\n> \n' ;;
esac
EOF
  for tool in gh gh-axi curl; do
    cat > "$WORLD/fakebin/$tool" <<'EOF'
#!/usr/bin/env bash
exit 97
EOF
  done
  chmod +x "$WORLD/fakebin"/*
}

run_reconcile() {
  local home=$1
  PATH="$WORLD/fakebin:$PATH" \
    FM_ROOT_OVERRIDE="$WORLD/root" \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    FM_INACTIVE_RECONCILE_SECS=60 \
    FM_INACTIVE_RECONCILE_NOW=1700000300 \
    FM_HANDOFF_IDLE_SECS=180 \
    FM_INACTIVE_CREW_STATE_BIN="$WORLD/fakebin/fm-crew-state.sh" \
    "$ROOT/bin/fm-inactive-reconcile.sh" scan
}

write_meta() {
  local path=$1 worktree=$2 spawn=$3 mode=$4 pr_head=${5:-}
  {
    printf 'window=firstmate:fm-intake\n'
    printf 'worktree=%s\n' "$worktree"
    printf 'project=%s\n' "$worktree"
    printf 'harness=codex\nkind=ship\n'
    printf 'mode=%s\nyolo=off\nspawn_gen=%s\n' "$mode" "$spawn"
    [ -z "$pr_head" ] || printf 'pr_head=%s\n' "$pr_head"
  } > "$path"
}

make_fake_tools
mkdir -p "$WORLD/root" "$WORLD/main"/{state,data,config,projects/intake}

first='needs-validation [at=1700000000] [event=11111111111111111111111111111111]: committed c118078, 706 tests'
second='needs-validation [at=1700000000] [event=22222222222222222222222222222222]: committed c118078, 706 tests'
third='needs-validation [at=1700000000] [event=33333333333333333333333333333333]: committed c118078, 706 tests'
write_meta "$WORLD/main/state/intake.meta" "$WORLD/main/projects/intake" incarnation-demo no-mistakes
printf '%s\n%s\n' "$first" "$second" > "$WORLD/main/state/intake.status"
: > "$WORLD/main/state/intake.turn-ended"
run_reconcile "$WORLD/main"
printf '%s\n' "$second" > "$WORLD/main/state/intake.status"
run_reconcile "$WORLD/main"
printf '%s\n' "$third" >> "$WORLD/main/state/intake.status"
run_reconcile "$WORLD/main"

printf '%s\n' 'Stable completion identities after status-log compaction'
for record in "$WORLD/main/state/handoff-continuations"/*.record; do
  event=$(sed -n 's/^completion_event_id=//p' "$record")
  fingerprint=$(basename "$record" .record)
  printf '  event=%s record=%s\n' "$event" "${fingerprint:0:12}"
done | sort
printf '  durable_records=%s queued_idle_checks=%s open_marker=%s\n' \
  "$(find "$WORLD/main/state/handoff-continuations" -name '*.record' -type f | wc -l | tr -d ' ')" \
  "$(grep -c 'handoff-idle-intake-' "$WORLD/main/state/.wake-queue")" \
  "$(cut -c1-12 "$WORLD/main/state/handoff-continuations/intake.open")"

BRIEF_HOME="$WORLD/brief-home"
mkdir -p "$BRIEF_HOME/data" "$BRIEF_HOME/state"
FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" validation-demo firstmate --mode no-mistakes >/dev/null
brief="$BRIEF_HOME/data/validation-demo/brief.md"
append=$(sed -n '/`event_id=/s/.*`\(event_id=.*\)`.*/\1/p' "$brief")
now=1700000400
append=${append//\{state\}/needs-validation}
append=${append//\{one short line\}/implementation committed}
append=${append//<epoch>/$now}
bash -c "$append"
printf '%s\n' 'Worker-visible generated status command result'
printf '  %s\n' "$(cat "$BRIEF_HOME/state/validation-demo.status")"

mkdir -p "$WORLD/mate"/{state,data,config,projects/direct} "$WORLD/main/state"
printf 'mate\n' > "$WORLD/mate/.fm-secondmate-home"
cat > "$WORLD/mate/.fm-secondmate-parent" <<EOF
schema=fm-secondmate-parent.v1
route=local
parent_home=$WORLD/main
EOF
git -C "$WORLD/mate/projects/direct" init -q
git -C "$WORLD/mate/projects/direct" -c user.name=fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m init
head_sha=$(git -C "$WORLD/mate/projects/direct" rev-parse HEAD)
git -C "$WORLD/mate/projects/direct" update-ref refs/remotes/origin/main "$head_sha"
write_meta "$WORLD/mate/state/direct.meta" "$WORLD/mate/projects/direct" incarnation-direct direct-PR "$head_sha"
printf '%s\n' 'done [at=1700000500] [event=abcdefabcdefabcdefabcdefabcdefab]: PR https://example.test/owner/repo/pull/71 checks green' > "$WORLD/mate/state/direct.status"
: > "$WORLD/mate/state/direct.turn-ended"
run_reconcile "$WORLD/mate"
printf '%s\n' 'Parent relay for an event-tagged direct-PR completion'
sed -n '/child direct done:/p' "$WORLD/main/state/mate.status" | sed -E 's/ \[at=[0-9]+\]//' | sed 's/^/  /'
