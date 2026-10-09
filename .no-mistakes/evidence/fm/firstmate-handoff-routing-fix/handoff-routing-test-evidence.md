# Handoff routing validation evidence

Validated 2026-10-09 PDT against target `a22f0c1ff388c84d489fad60f3c437daf4947d41`.

- The reconciliation flow kept a `needs-validation` handoff open after `done: shipped` for `no-mistakes`, `direct-PR`, and `local-only` tasks.
  A later canonical `PR ... checks green` delivery cleared each one.
  A bare PR URL and an unverified green claim both left the handoff actionable.
- The supervision-host flow granted routine rows to a branch, appended `needs-validation` during the turn to both a `.status` and a `.turn-ended` task, then acknowledged only the routine row.
  The newly main-owned rows remained in the durable wake queue.
- An isolated replay of the host transition confirmed that a task which turns main-only after branch offer is passed through to main without an engine turn.

Supporting command transcripts:

- `fm-inactive-reconcile.log`
- `fm-pi-branch-extension.log`
- `fm-supervision-host.log`
- `fm-host-transition-isolated.log`

The complete host suite had one timing-dependent failure in its pre-existing Pi-offer compatibility assertion after all handoff checks passed.
The single transition replay passed using the real host, watcher, queue, and offer path.
