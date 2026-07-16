#!/usr/bin/env bash
# Static contract tests for the hardened scout-to-implementation owner.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILL="$ROOT/.agents/skills/scout-implementation-contract/SKILL.md"
AGENTS="$ROOT/AGENTS.md"

test_metadata_owner_and_trigger() {
  local count load_count
  assert_present "$SKILL" "scout-implementation-contract skill is missing"
  assert_grep "name: scout-implementation-contract" "$SKILL" "skill metadata has the wrong name"
  count=$(grep -Fc -- "user-invocable: false" "$SKILL")
  [ "$count" -eq 1 ] || fail "skill must have exactly one non-user-invocable metadata value, found $count"
  count=$(grep -Fc -- "  internal: true" "$SKILL")
  [ "$count" -eq 1 ] || fail "skill must have exactly one internal metadata value, found $count"
  assert_grep "single owner of Firstmate's hardened scout report and implementation-packet contract" "$SKILL" \
    "skill does not declare single ownership"
  load_count=$(grep -Fc -- "Use before briefing a scout whose output may scope implementation, and before dispatching or promoting implementation from such a report." "$SKILL")
  [ "$load_count" -eq 2 ] || fail "skill description and opening paragraph must both carry the exact load trigger, found $load_count copies"
  count=$(grep -Fc -- '- `scout-implementation-contract` -' "$AGENTS")
  [ "$count" -eq 1 ] || fail "scout-implementation-contract must have exactly one AGENTS.md trigger entry, found $count"
  assert_grep '- `scout-implementation-contract` - load before briefing a scout whose output may scope implementation, and before dispatching or promoting implementation from such a report.' "$AGENTS" \
    "AGENTS.md lost the exact scout-implementation-contract trigger"
  pass "internal owner metadata and the unique precise trigger are protected"
}

test_versions_tiers_readiness_and_ledgers() {
  local phrase
  assert_grep "contract_version: firstmate.scout-implementation.v1" "$SKILL" "v1 report contract version is missing"
  assert_grep "packet_version: firstmate.scout-implementation.v1" "$SKILL" "v1 packet contract version is missing"
  for phrase in LEAN STANDARD CRITICAL; do
    assert_grep "### $phrase" "$SKILL" "tier $phrase is missing"
  done
  for phrase in "GO" "GO WITH EXPLICIT ASSUMPTIONS" "NO-GO"; do
    assert_grep "$phrase" "$SKILL" "readiness value $phrase is missing"
  done
  for phrase in VERIFIED EXTERNAL INFERENCE RECOMMENDATION CAPTAIN-DECISION UNRESOLVED HARD-BLOCKER; do
    assert_grep "$phrase" "$SKILL" "claim ledger $phrase is missing"
  done
  for phrase in S1 S2 S3 S4 S5 S6 S7 S8; do
    assert_grep "\`$phrase\`" "$SKILL" "scoring dimension $phrase is missing"
  done
  assert_grep "The maximum score is 16." "$SKILL" "readiness maximum is missing"
  assert_grep "GO requires a score from 14 through 16" "$SKILL" "GO threshold is missing"
  assert_grep "GO WITH EXPLICIT ASSUMPTIONS requires a score from 12 through 16" "$SKILL" \
    "assumption-qualified threshold is missing"
  assert_grep "An honest NO-GO is a completed scout result" "$SKILL" "NO-GO completion rule is missing"
  pass "tiers, readiness scoring, and classified claim ledgers are protected"
}

test_snapshot_scope_map_and_behavior() {
  local phrase
  for phrase in \
    "exact base commit SHA" \
    "UTC evidence-freshness timestamp" \
    "clean or dirty" \
    "named branch or detached" \
    "relation to the current default branch" \
    "relevant remote" \
    "open pull requests" \
    "relevant worktrees" \
    "lease, runner, pipeline, or equivalent exclusive-writer overlap" \
    "evidence command and source" \
    "freshness window" \
    "invalidation events"; do
    assert_grep "$phrase" "$SKILL" "snapshot contract is missing '$phrase'"
  done
  assert_grep "path-by-path approved write scope" "$SKILL" "approved scope is not path-specific"
  assert_grep "one implementation reason for every path" "$SKILL" "approved paths lack reasons"
  assert_grep "exact symbol or region" "$SKILL" "file and symbol or region map is missing"
  assert_grep "verified reference pattern" "$SKILL" "reference-pattern requirement is missing"
  assert_grep "explicit do-not-change notes" "$SKILL" "do-not-change mapping is missing"
  for phrase in \
    "input and output schemas" \
    "state transitions" \
    "authority and ownership" \
    "failure behavior" \
    "idempotency and retry behavior" \
    "concurrency and atomicity" \
    "security and privacy" \
    "observability and receipts" \
    "compatibility and migration"; do
    assert_grep "$phrase" "$SKILL" "behavioral contract is missing '$phrase'"
  done
  pass "snapshot, approved scope, file mapping, and behavioral dimensions are protected"
}

test_tests_delivery_stops_and_safety() {
  local phrase
  for phrase in positive negative boundary regression failure-injection; do
    assert_grep "$phrase" "$SKILL" "test class $phrase is missing"
  done
  for phrase in "setup or input" "exact command" "expected success signal" "expected failure signal"; do
    assert_grep "$phrase" "$SKILL" "test matrix is missing '$phrase'"
  done
  assert_grep "failure injection N/A only when cited evidence proves" "$SKILL" \
    "LEAN failure-injection exception is missing"
  assert_grep "whether the target repository requires a tracked work order" "$SKILL" \
    "work-order applicability is missing"
  assert_grep "do not invent one" "$SKILL" "work-order invention stop is missing"
  assert_grep "work-order-only first commit" "$SKILL" "work-order first-commit rule is missing"
  assert_grep "exact implementation head changes" "$SKILL" "exact-head invalidation is missing"
  for phrase in \
    "Evidence is stale" \
    "widens approved path" \
    "schema, provider semantic, ownership rule, or authority rule" \
    "substitute its judgment" \
    "assumption becomes false" \
    "test lacks an exact command" \
    "packet depends on another narrative" \
    "model-fit gate fails" \
    "destructive, irreversible, security-sensitive, provider-live, deployment, or production action"; do
    assert_grep "$phrase" "$SKILL" "hard-stop contract is missing '$phrase'"
  done
  assert_grep "A precise scout does not make a weak model safe for high-risk work." "$SKILL" \
    "weak-model safety statement is missing"
  assert_grep "Existing generic scouts remain backward compatible" "$SKILL" \
    "generic-scout compatibility boundary is missing"
  pass "test classes, delivery choreography, hard stops, and safety are protected"
}

test_packet_report_quality_and_feedback() {
  local packet phrase
  for phrase in \
    "# Bounded summary" \
    "# Snapshot and provenance" \
    "# Classified ledgers" \
    "# Readiness" \
    "# Objective and boundaries" \
    "# Approved scope" \
    "# File and symbol or region map" \
    "# Behavioral contract" \
    "# Test matrix" \
    "# Delivery choreography" \
    "# Stop conditions" \
    "# Copy-paste implementation packet" \
    "# Post-implementation feedback" \
    "# Quality gate"; do
    assert_grep "$phrase" "$SKILL" "fixed report schema is missing '$phrase'"
  done
  packet=$(awk '
    /^### Packet template$/ { found = 1 }
    found && /^## Post-implementation feedback$/ { exit }
    found { print }
  ' "$SKILL")
  for phrase in \
    "packet_version:" \
    "source_scout_id:" \
    "source_base:" \
    "source_freshness_utc:" \
    "tier:" \
    "verdict_at_handoff:" \
    "# Authority and model-fit boundary" \
    "# Complete requirements" \
    "# Exact write scope and reasons" \
    "# Dependencies and ordering" \
    "# Tests with signals" \
    "# Exclusions and non-goals" \
    "# Explicit assumptions" \
    "# Hard stops" \
    "# Delivery and done conditions" \
    "# Feedback owed"; do
    assert_contains "$packet" "$phrase" "implementation packet is missing '$phrase'"
  done
  if printf '%s\n' "$packet" | grep -Eqi 'see[[:space:]]+report|read[[:space:]]+the[[:space:]]+(narrative[[:space:]]+)?report'; then
    fail "implementation packet must be independent of the narrative report"
  fi
  assert_grep 'literal placeholders `TBD`, `TODO`, or `???`' "$SKILL" \
    "quality gate does not reject unresolved placeholders"
  assert_grep "packet depends on another narrative" "$SKILL" \
    "quality gate does not reject narrative-dependent packets"
  assert_grep 'data/<scout-id>/feedback.md' "$SKILL" "feedback destination is missing"
  for phrase in "claim ID" "confirmed or wrong or incomplete" "implementation evidence" "implementation impact" "general lesson"; do
    assert_grep "$phrase" "$SKILL" "feedback schema is missing '$phrase'"
  done
  assert_grep "separate reviewed pull request" "$SKILL" "generalized-lesson PR boundary is missing"
  assert_no_grep "firstmate.scout-implementation.v1" "$AGENTS" \
    "AGENTS.md must not duplicate the full contract schema version"
  assert_no_grep "maximum score is 16" "$AGENTS" "AGENTS.md must not duplicate the scoring rubric"
  pass "report schema, independent packet, quality gate, and feedback are protected"
}

test_metadata_owner_and_trigger
test_versions_tiers_readiness_and_ledgers
test_snapshot_scope_map_and_behavior
test_tests_delivery_stops_and_safety
test_packet_report_quality_and_feedback
