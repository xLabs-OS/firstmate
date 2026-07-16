---
name: scout-implementation-contract
description: >-
  Agent-only contract for implementation-shaping scout output.
  Use before briefing a scout whose output may scope implementation, and before dispatching or promoting implementation from such a report.
  Owns proportional evidence, readiness, report, implementation-packet, safety, quality, and feedback requirements.
user-invocable: false
metadata:
  internal: true
---

# scout-implementation-contract

Use before briefing a scout whose output may scope implementation, and before dispatching or promoting implementation from such a report.
This skill is the single owner of Firstmate's hardened scout report and implementation-packet contract.
It applies only when a scout may scope, sequence, authorize, or directly brief implementation.
Existing generic scouts remain backward compatible, retain their current lifecycle, and remain eligible for scratch-scout teardown.

## Authority and safety boundary

Firstmate owns intake, proportionality-tier selection, report acceptance, implementation dispatch or promotion, and local feedback capture.
The captain's existing merge authority remains unchanged.
A scout report is evidence and a recommendation, not authority for unapproved implementation or external action.
A precise scout does not make a weak model safe for high-risk work.
Model fit must reflect ambiguity, risk, blast radius, and the selected tier rather than report precision alone.
The inputs and outputs are Markdown instruction contracts, and enforcement in this version is a static shell test rather than a runtime parser or new CLI schema.
Readiness outcomes are report verdicts, so this contract does not alter existing scout lifecycle, promotion, or teardown mechanics.
Instruction-level idempotency and concurrency rely on evidence refresh, exact-head checks, and overlap detection before dispatch.

## Proportionality tiers

Select exactly one tier before gathering evidence, and record why it fits.
The tier controls permitted omissions but never relaxes a hard stop or authority boundary.
An item may be marked N/A only when the selected tier permits it and the report cites evidence proving why it does not apply.

### LEAN

LEAN is limited to one or two tracked files and mechanical or documentation-only behavior.
LEAN requires no security, authority, secret, provider, external mutation, durable-state, migration, concurrency, deployment, production, destructive, irreversible, or other high-risk boundary.
LEAN requires an exact verified reference pattern that resolves implementation choices without semantic inference.
LEAN may mark failure injection N/A only when cited evidence proves that no runtime failure boundary exists.
If every LEAN condition cannot be proven, select STANDARD.

### STANDARD

STANDARD is the bounded default whenever LEAN cannot be proven and CRITICAL is not required.
STANDARD requires the complete report and packet contracts, with evidence-backed N/A entries only where this contract permits them.

### CRITICAL

CRITICAL covers security, authority, secrets, providers, external mutation, durable state, migrations, concurrency, deployment, production, destructive work, or irreversible work.
CRITICAL requires a model capable of the risk and ambiguity or an independent specialist review before implementation dispatch.
A model or reviewer mismatch forces NO-GO.

## Canonical report and snapshot

Write the canonical report to `data/<id>/report.md` and declare `contract_version: firstmate.scout-implementation.v1` at its top.
Keep the existing scratch-scout teardown behavior because this contract changes report quality, not scout worktree ownership.
Record the following snapshot and provenance facts with exact values and evidence links:

- Record the exact base commit SHA and the UTC evidence-freshness timestamp.
- Record whether the checkout is clean or dirty and whether it is on a named branch or detached.
- Record the checkout's relation to the current default branch, including ahead, behind, equal, or divergent state.
- Record the relevant remote and its fetched default-branch SHA.
- Record open pull requests that may overlap the objective, paths, symbols, ownership, or sequencing.
- Record all relevant worktrees and any lease, runner, pipeline, or equivalent exclusive-writer overlap.
- Record every evidence command and source used to establish the snapshot.
- Declare a task-proportional freshness window in UTC.
- Declare invalidation events, including base movement, PR state or diff changes, worktree or lease changes, local dirt, ownership changes, dependency changes, and exact-head changes.

Stale evidence is a hard gate, not a caveat.
Refresh every invalidated item before scoring readiness or dispatching implementation.

## Classified claim ledgers

Keep seven separate ledgers, and give every claim a stable ID that survives implementation feedback.
Each row must include the claim ID, the claim, its evidence or decision link, its freshness or owner, and its implementation consequence.

- VERIFIED claims use stable `V` IDs and cite direct repository, command, test, or authoritative-source evidence.
- EXTERNAL claims use stable `E` IDs and identify facts outside the repository plus their authoritative source and freshness.
- INFERENCE claims use stable `I` IDs and identify the evidence and reasoning that support the inference.
- RECOMMENDATION claims use stable `R` IDs and distinguish a proposed choice from established fact or authority.
- CAPTAIN-DECISION claims use stable `D` IDs and quote or link the decision without substituting the scout's judgment.
- UNRESOLVED claims use stable `U` IDs and state what evidence or decision would resolve them and what they block.
- HARD-BLOCKER claims use stable `B` IDs and identify the failed hard gate and the exact action needed to clear it.

Do not hide assumptions in prose.
Classify every implementation-relevant assumption as an INFERENCE or UNRESOLVED claim and copy any permitted remaining assumption into the implementation packet.

## Readiness scoring and outcome

Score each dimension from 0 to 2 and record evidence for the score.
The maximum score is 16.

1. `S1` is snapshot and provenance.
2. `S2` is classification and decisions.
3. `S3` is objective, scope, and dependencies.
4. `S4` is file, symbol, and reference-pattern mapping.
5. `S5` is the behavioral contract.
6. `S6` is tests and validation.
7. `S7` is delivery, authority, and stops.
8. `S8` is packet independence, quality, and feedback.

Select exactly one readiness outcome: GO, GO WITH EXPLICIT ASSUMPTIONS, or NO-GO.
GO requires a score from 14 through 16, no dimension scored 0, every hard gate passing, and no load-bearing unresolved assumption.
GO WITH EXPLICIT ASSUMPTIONS requires a score from 12 through 16, no dimension scored 0, every hard gate passing, and every remaining non-critical assumption copied into the packet with an invalidation stop.
NO-GO applies after any hard-gate failure, any dimension scored 0, a score below 12, a stale base, an unresolved owner decision, a narrative-dependent packet, a critical semantic assumption, or a model or reviewer mismatch.
An honest NO-GO is a completed scout result rather than a failed scout.

## Objective, boundaries, and approved scope

State the exact objective and every required behavior in testable terms.
State exclusions and non-goals explicitly enough to detect an intersection with the approved scope.
Map the dependency graph, required ordering, serialization boundaries, and parallel-safe boundaries.
List the path-by-path approved write scope, and give one implementation reason for every path.
An approved directory or vague subsystem is not a substitute for exact paths when exact paths can be known.
Any necessary path outside the approved list is a scope-widening stop.

## File and symbol or region map

For every approved path, name the exact symbol or region, the required action, the verified reference pattern, and explicit do-not-change notes.
Use direct file and line, symbol, command, test, or authoritative-document links for every verified pattern.
Mark a path as new when no symbol exists, and cite the neighboring pattern that governs its shape.
Do not invent a symbol, schema, provider behavior, authority rule, or ownership boundary to fill a map gap.

## Behavioral contract

Cover every behavioral dimension below, even when the selected tier permits an evidence-backed N/A entry.

- Define input and output schemas, including required fields, validation, and error representation.
- Define state transitions, including allowed starting, intermediate, terminal, and invalid states.
- Define authority and ownership for decisions, writes, approvals, and durable truth.
- Define failure behavior, including fail-closed boundaries and recoverable versus terminal failures.
- Define idempotency and retry behavior, including duplicate work, partial completion, and safe convergence.
- Define concurrency and atomicity, including overlap detection, serialization, parallel safety, and partial-write prevention.
- Define security and privacy, including secrets, credentials, sensitive data, and trust boundaries.
- Define observability and receipts, including logs, evidence, durable outcomes, and attribution.
- Define compatibility and migration, including existing callers, data, lifecycle behavior, rollout, and rollback.

Missing hard gates fail closed to NO-GO, and the contract must never encourage guessing.

## Test and validation matrix

Provide positive, negative, boundary, regression, and failure-injection coverage.
Every test row must name the setup or input, the exact command, the expected success signal, and the expected failure signal.
Name fixtures, environment assumptions, and cleanup when they affect reproducibility.
Do not accept a command without both expected outcomes.
LEAN may use the evidence-backed failure-injection exception defined in its tier and no other tier may inherit that exception automatically.

## Delivery choreography

Determine whether the target repository requires a tracked work order.
If it does, name the work-order owner and exact path, and require a work-order-only first commit when that repository's contract requires one.
If the repository has no work-order mechanism, record that fact with evidence and do not invent one.
Record the exact refreshed base SHA, feature branch, dependency order, local validation commands, pipeline owner, and PR-ready criteria.
Require implementation to stop when the exact base or exact implementation head changes in a way that invalidates evidence or validation.
Record merge authority explicitly and preserve the captain's authority unless an existing approved posture says otherwise.
Record teardown ownership and the conditions proving the work is landed or the scout scratch report is preserved.

## Hard stops

Stop implementation dispatch or promotion for any of the following conditions:

- Evidence is stale or an invalidation event has not been refreshed.
- The required change widens approved path, behavior, authority, or dependency scope.
- A schema, provider semantic, ownership rule, or authority rule would need to be invented.
- The scout would substitute its judgment for an owner or captain decision.
- An explicit assumption becomes false, critical, load-bearing, or unbounded.
- A test lacks an exact command, expected success, or expected failure signal.
- The implementation packet depends on another narrative for any requirement.
- A quality gate, readiness gate, overlap gate, exact-head gate, or model-fit gate fails.
- A destructive, irreversible, security-sensitive, provider-live, deployment, or production action lacks explicit approval.

## Fixed report schema

Use these fixed sections in this order, and replace every template marker before accepting the report.

```markdown
contract_version: firstmate.scout-implementation.v1

# Bounded summary

# Snapshot and provenance

# Classified ledgers

## VERIFIED

## EXTERNAL

## INFERENCE

## RECOMMENDATION

## CAPTAIN-DECISION

## UNRESOLVED

## HARD-BLOCKER

# Readiness

# Objective and boundaries

# Approved scope

# File and symbol or region map

# Behavioral contract

# Test matrix

# Delivery choreography

# Stop conditions

# Copy-paste implementation packet

# Post-implementation feedback

# Quality gate
```

The bounded summary states the tier, readiness outcome, score, objective, approved paths, assumptions, blockers, and recommendation without replacing the detailed sections.

## Copy-paste implementation packet

The packet is a self-contained work order for the implementation worker.
Copy every implementation requirement, decision, boundary, test signal, and permitted assumption into it.
Do not require the worker to consult another narrative, chat transcript, or unstated source for a requirement.
The packet must preserve the selected model-fit boundary and the exact weak-model safety statement from this contract.

### Packet template

```markdown
packet_version: firstmate.scout-implementation.v1
source_scout_id: <stable scout ID>
source_base: <remote and exact SHA>
source_freshness_utc: <UTC timestamp>
tier: <LEAN, STANDARD, or CRITICAL>
verdict_at_handoff: <GO or GO WITH EXPLICIT ASSUMPTIONS>

# Authority and model-fit boundary

State implementation authorization, merge authority, selected model or reviewer fit, and this sentence: A precise scout does not make a weak model safe for high-risk work.

# Objective

State the exact implementation objective.

# Complete requirements

Copy every required behavior and acceptance criterion.

# Exact write scope and reasons

List every approved path with one reason.

# File and symbol or region map

List every action, verified reference pattern, and do-not-change note.

# Behavioral contract

Copy all input and output, state, authority, failure, retry, concurrency, security, observability, compatibility, and migration requirements.

# Dependencies and ordering

State the dependency graph, serialization order, and parallel-safe work.

# Tests with signals

Copy every setup or input, exact command, expected success signal, and expected failure signal.

# Exclusions and non-goals

Copy every forbidden or intentionally unchanged behavior and path.

# Explicit assumptions

List every permitted assumption with its claim ID and invalidation stop.

# Hard stops

Copy every applicable hard stop, including stale evidence, scope widening, invented semantics or authority, invalid assumptions, incomplete tests, unapproved high-risk actions, failed gates, and model mismatch.

# Delivery and done conditions

State work-order applicability, exact base and branch, commit order, local validation, pipeline ownership, exact-head invalidation, PR-ready criteria, merge authority, teardown, and done reporting.

# Feedback owed

Require claim-ID-keyed feedback with status, evidence, impact, and general lesson.
```

Do not issue an implementation packet for NO-GO.
Do not use an implementation packet with unresolved template markers.

## Post-implementation feedback

Firstmate records feedback at local `data/<scout-id>/feedback.md` after implementation evidence is available.
Key every feedback row to a stable scout claim ID.
Each row records the claim ID, one status from confirmed or wrong or incomplete, implementation evidence, implementation impact, and a general lesson.
Keep project-specific facts in that local feedback file or the project's existing durable knowledge home.
Shared instructions may receive only generalized lessons through a separate reviewed pull request.

## Quality gate and self-audit

Fail the report or packet quality gate when any required section is missing.
Fail when any unresolved template marker or the literal placeholders `TBD`, `TODO`, or `???` remains in a completed artifact.
Fail when evidence is stale, approved scope intersects an exclusion, or an assumption is unclassified.
Fail when any test command lacks an expected success or expected failure signal.
Fail when the packet depends on another narrative or omits a report requirement needed for implementation.
Fail when any hard gate fails or the selected model or reviewer does not fit the tier.
Fail when the report declares more than one readiness outcome or no readiness outcome.
Accept the report only after the self-audit records every check as passing and the score supports the declared outcome.
