# Vault-guard PreToolUse seatbelt

This document is the authoritative human-readable contract for the vault-guard PreToolUse seatbelt.
`bin/fm-vault-command-policy.mjs` is the single owner of the block/allow decision; it reuses the shell classifier owned by `bin/fm-arm-command-policy.mjs`.
`bin/fm-vault-pretool-check.sh` is the stable harness transport and output renderer.
`bin/fm-secrets-names.sh` is the sanctioned names-only listing wrapper; its header owns its exact flag and parse contract.

## Incident and purpose

2026-07-30: a crewmate's first Infisical command listed secret VALUES into its local session transcript - the listing flag printed both names and values.
The brief said names-only; instruction-following failed where enforcement did not exist, and the remedy was secret rotation.
This seatbelt makes that failure structurally impossible: every value-printing infisical form is denied mechanically before it executes, in every crewmate, scout, secondmate, and primary session, so rotation is never again the remedy for an agent printing a secret.

## Policy

The policy is fail-closed: only provably value-safe forms are allowed, and shell the classifier cannot prove safe denies whenever the infisical token is present.

| Command shape | Decision | Reason code |
| --- | --- | --- |
| `infisical run [flags] -- <cmd>` / `--command '<cmd>'` (injection form) | allow | |
| `infisical login`, `infisical init`, `infisical help` | allow | |
| `--help`, `-h`, or `--version` before any `--` terminator | allow | |
| `command -v infisical` / `command -V infisical` (existence query, the cd-guard's carve-out) | allow | |
| `bin/fm-secrets-names.sh ...` (names-only wrapper) | allow (by construction: it never matches the infisical token) | |
| Any other subcommand (`secrets`, `export`, `get`, ...), bare `infisical`, or a flags-only invocation | deny | `vault-secret-print` |
| A `run` child that dumps the injected env: `env`/`printenv`/`set`/`export`/`declare`/`typeset` (through `env`/`sudo`/`timeout`-style wrappers and `xargs`-style forwarders too), an `echo`/`printf` carrying a `$`, or a shell/`eval` payload reaching one of those | deny | `vault-run-dump` |
| Executed infisical inside substitutions, subshells, literal `sh -c`/`eval` payloads, or heredocs fed to a stdin-mode shell | classified recursively, same rules as above | |
| Unclassifiable with the token present: lexer errors, unsupported compound grammar (`if`/`for`/`while`/`case`/`time`/...), dynamic (non-literal) payloads or command words, unresolved wrapper options, or an indirect executor (`xargs`, `watch`, `nice`, ...) whose arguments carry the token | deny | `unclassifiable-vault-command` |

Token matching is case-insensitive end to end (prefilter and policy), because macOS's default case-insensitive filesystem executes `Infisical secrets` as the real binary.
The run-child dump check also resolves cobra's glued short form (`-cprintenv`, `-c=x`) and skips `builtin` prefixes, so `sh -c 'builtin export'` under `run` still denies.
Data mentions stay data: quoted arguments (`echo "infisical secrets"`), grep patterns, comments, and heredoc bodies fed to non-shell commands never make the outer command relevant.
Any `--command` string payload of `run` is itself classified as a program running with the injected environment, where ALL unclassifiable syntax denies (no token-gating - the environment it runs in is already the protected material).
The deny reasons name the two sanctioned paths so the denied agent can self-correct: `bin/fm-secrets-names.sh --projectId <id> --env <slug>` for names, `infisical run [flags] -- <cmd>` for injection.

Out of scope, by the same agent-mistake threat model as the arm and cd guards: opaque dynamic dataflow that never carries the token (`bash -c "$WHOLE_COMMAND"`), value dumping by an arbitrary workload binary the child runs (`node -e 'console.log(process.env)'`), and deliberate byte-level obfuscation beyond the classifier's static quote decoding.
The transport prefilter and its quoting-decoder markers mirror the cd-guard's strict-superset contract; both scripts' headers own the exact transport and fail-open rules.

## Transport and fail-open vs fail-closed

`bin/fm-vault-pretool-check.sh` accepts the same entry forms as the sibling guards: stdin JSON at `.tool_input.command` (Claude/Codex) or `.toolInput.command` (Grok), `--command <exact string>` (OpenCode/Pi), and `--claude` for Claude's stderr-only deny requirement.
Transport failure - malformed or empty stdin, missing `jq`, missing Node or the policy file - fails open, exactly like the arm guard, so a broken hook never denies every shell command.
Semantic failure - malformed, unsupported, or dynamic shell that carries the infisical token - fails closed inside the policy owner, exactly like the arm guard's `unclassifiable-protected-command`.
Unlike the cd-guard there is no environment scoping: the guard fires wherever it is installed, because printing a secret is wrong everywhere.

## The names-only wrapper

`bin/fm-secrets-names.sh --projectId <id> --env <slug> [--path <folder>]` is the only sanctioned listing tool.
It invokes `infisical export --format json --silent`, captures stdout, and structurally strips to name fields: an array of `{key: ...}` objects yields each `.key`, a flat object yields its keys, and ANY other shape aborts with nothing printed and a non-zero exit.
There is no raw-output fallback path; a parse failure prints nothing.
Secret values transit the wrapper's internal pipe (the CLI has no names-only fetch) but never its output.

## Install matrix (who gets the guard, and how)

Primary firstmate and every secondmate home run from this repo, so the tracked adapter configs cover them; crewmate/scout worktrees are project repos, so `bin/fm-spawn.sh` installs a per-task hook with the absolute checker path baked in, alongside each harness's turn-end hook.

| Harness | Primary + secondmate home (tracked) | Crewmate/scout worktree (spawn-written) |
| --- | --- | --- |
| Claude | `.claude/settings.json` PreToolUse entry | `.claude/settings.local.json` gains a PreToolUse entry next to the Stop hook |
| Codex | `.codex/hooks.json` self-verifying PreToolUse entry | `.codex/hooks.json` written into the worktree (git-excluded); the crewmate launch template adds `--dangerously-bypass-hook-trust` so it loads without a trust dialog |
| Grok | `.grok/hooks/fm-primary-vault-check.json` project hook (loads under the home's existing folder trust) | firstmate-owned GLOBAL hook `~/.grok/hooks/fm-vault-guard.{sh,json}`, inert unless the workspace holds the `.fm-grok-turnend` crewmate pointer |
| OpenCode | `.opencode/plugins/fm-primary-vault-check.js` | `.opencode/plugins/fm-vault-guard.js` written into the worktree (git-excluded) |
| Pi | `.pi/extensions/fm-primary-turnend-guard.ts` runs the vault check in its `tool_call` handler | the spawn-written `state/<id>.pi-ext.ts` gains a `tool_call` handler next to the turn-end handler |

Grok quirk (owned by `docs/arm-pretool-check.md`): every shell variable in a grok hook command carries an inline default such as `${GROK_WORKSPACE_ROOT:-}`.
The grok global vault hook needs no token registry, unlike the turn-end hook: it writes nothing pointer-derived, only classifies the stdin payload through the checker path baked in by the last spawning firstmate home, and fails open if that path is gone.

### Known gaps

- Codex crewmates: a project that tracks its own `.codex/hooks.json` is left untouched (overwriting a tracked file would dirty the worktree); `fm-spawn` warns loudly and that one task runs unguarded on the hook layer.
- Codex crewmates: the spawn-shaped worktree `hooks.json` plus `--dangerously-bypass-hook-trust` is validated in `codex exec` mode (this document's record below); interactive-TUI hook loading rides the same general CLI flag but has not itself been observed live, so treat it as wired-but-unverified until a live codex crewmate exercises it.
- Codex secondmate launches do not pass the hook-trust bypass flag; the tracked hooks.json entry loads under whatever hook trust the home already has, exactly like the pre-existing arm and cd entries there.
- Grok crewmates on a machine whose last-spawning firstmate home was deleted: the baked checker path dies and the global hook exits 0 (fail open) until the next grok spawn rewrites it.
- The wrapper's `infisical export --format json` shapes were pinned against infisical 0.43.84; an upstream format change makes the wrapper abort (fail closed), never pass values through.

## Automated validation

`tests/fm-vault-guard.test.sh` owns the acceptance matrix: deny/allow rows through Codex-, Claude-, Grok-, OpenCode-, and Pi-shaped entry forms, fail-open transport behavior, the prefilter fast path, policy CLI contract, wrapper output-shape rows (names only, nothing on parse failure), spawn-install rows per harness against a fake tmux backend, and tracked-config wiring rows.

Run:

```sh
bash -n bin/fm-vault-pretool-check.sh bin/fm-secrets-names.sh
node --check bin/fm-vault-command-policy.mjs
tests/fm-vault-guard.test.sh
bin/fm-lint.sh
```

## Live validation record, 2026-07-30

Validation ran in a git-initialized scratch project (crewmate-worktree shape) under this task's implementation worktree, with Claude Code 2.1.220 and infisical 0.43.84.
The scratch `.claude/settings.local.json` carried exactly the hook fm-spawn writes - the absolute checker path plus `--claude`:

```json
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"'<task-worktree>/bin/fm-vault-pretool-check.sh' --claude"}]}]}}
```

The harness launch was `claude -p "$PROMPT" --dangerously-skip-permissions --output-format text`, with the prompt instructing two exact shell commands as separate Bash tool calls:

```sh
infisical --version
infisical secrets; touch deny-executed.sentinel
```

Observed: the first command executed and printed `infisical version 0.43.84` (real allow).
The second was blocked before execution; the session reported this exact hook error:

```text
PreToolUse:Bash hook error: ['<task-worktree>/bin/fm-vault-pretool-check.sh' --claude]: {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"[vault-secret-print] this infisical command can print secret VALUES into the session transcript. Sanctioned paths: bin/fm-secrets-names.sh --projectId <id> --env <slug> lists secret NAMES only; infisical run [flags] -- <cmd> injects secrets into a child process env without printing them."}
```

The session's final line was `RESULT: cmd1=ran cmd2=blocked`, and `deny-executed.sentinel` did not exist afterward: the deny stopped the entire compound line, so the chained `touch` never ran.
The tracked primary wiring was additionally observed live during implementation: the implementing agent's own claude session, running in a firstmate worktree with the updated `.claude/settings.json`, had a compound command carrying the infisical token in a quoted payload plus a `"$VAR"/...` dynamic command word denied with `[unclassifiable-vault-command]` - the fail-closed dynamic rule firing through the real tracked-config path.

The same scratch shape was repeated for codex (codex-cli 0.144.4) with a worktree `.codex/hooks.json` generated by the exact fm-spawn code path, launched as `codex exec --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check "$PROMPT"` with the same two commands.
Observed: `hook: PreToolUse Completed` then `infisical version 0.43.84` for the first command; `hook: PreToolUse Blocked` for the second with `Command blocked by PreToolUse hook:` carrying the same `[vault-secret-print]` deny object; the final line was `RESULT: cmd1=ran cmd2=blocked` and the sentinel did not exist.
