#!/usr/bin/env bash
# Stable PreToolUse transport for the vault-guard command policy.
#
# Incident 2026-07-30: a crewmate's first Infisical command printed secret
# VALUES into its session transcript. This seatbelt makes that structurally
# impossible: it denies every value-printing infisical form before it runs, in
# every crewmate, scout, secondmate, and primary session it is installed into.
# bin/fm-vault-command-policy.mjs is the sole owner of the block/allow
# decision; it reuses the shell classifier owned by
# bin/fm-arm-command-policy.mjs. This wrapper only acquires the harness
# payload, invokes that policy, and renders the established harness-specific
# responses. It never executes, sources, evaluates, or expands the command.
# See docs/vault-guard.md for the complete contract, the per-harness install
# mechanism, and the validation record.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-vault-pretool-check.sh
#   bin/fm-vault-pretool-check.sh --command '<cmd>' [--claude]
#
# Stdin mode extracts .toolInput.command for Grok or .tool_input.command for
# Claude and Codex. CLI mode is used by OpenCode and Pi after their adapters
# extract the exact command string.
#
# Exit/output contract (identical shape to bin/fm-arm-pretool-check.sh):
#   ALLOW - exit 0 and no output.
#   DENY - exit 2, a Claude-shaped deny object on stderr, and a Grok-shaped
#          deny object on stdout unless --claude was supplied.
#   FAIL OPEN - malformed or empty stdin, missing jq for stdin transport,
#               missing Node or policy owner, or an invalid policy response.
#
# Unlike the cd-guard there is no environment scoping: printing a secret is
# wrong everywhere this guard is installed, so the guard fires in any
# directory. Semantic fail-closed behavior (malformed or dynamic shell around
# the infisical token denies) is the policy owner's, not this transport's.
#
# Claude requires stdout to remain empty on deny.
# Codex blocks on exit 2 and displays stderr.
# Grok consumes the stdout decision object.
# OpenCode and Pi consume exit 2 plus stderr.
set -u

CMD=""
CMD_SET=0
CLAUDE_MODE=0

usage() {
  cat <<'EOF'
Usage: fm-vault-pretool-check.sh [--command <cmd>] [--claude]

With no --command, reads a PreToolUse-style JSON payload on stdin (Grok
toolInput.command, or Claude/Codex tool_input.command).
Exits 0 to allow and 2 to deny a value-printing infisical command.
The deny reason is written to stderr, with a Grok decision object on stdout
unless --claude is supplied.
Malformed transport and an unavailable classifier runtime fail open; malformed
shell around the infisical token fails closed inside the policy owner.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }
      CMD=$2
      CMD_SET=1
      shift 2
      ;;
    --command=*)
      CMD=${1#--command=}
      CMD_SET=1
      shift
      ;;
    --claude)
      CLAUDE_MODE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$CMD_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.toolInput.command // .tool_input.command // empty)' 2>/dev/null) || exit 0
fi

[ -n "$CMD" ] || exit 0

# Strict-superset prefilter (transport only; owns zero classification
# semantics). Strip syntax bytes that the classifier joins within a shell word
# before looking for the infisical token, so ordinary quoted or escaped
# fragments cannot hide a deniable vault command from the policy owner. A
# quoting-decoder marker - a $ immediately followed by a single quote (ANSI-C
# $'...') or a double quote (bash locale $"...") - delegates too, because the
# classifier decodes those and can reconstruct the token from bytes this
# substring test cannot see. This marker set is COUPLED to the classifier's
# decoder set in bin/fm-arm-command-policy.mjs: adding any new quote/expansion
# form the classifier decodes REQUIRES extending it here in the same change, or
# the prefilter stops being a strict superset. Deliberate deeper obfuscation is
# out of scope by the same agent-mistake threat model the policy uses.
PREFILTER=$CMD
PREFILTER=${PREFILTER//\\/}
PREFILTER=${PREFILTER//\"/}
PREFILTER=${PREFILTER//\'/}
PREFILTER=${PREFILTER//$'\n'/}
PREFILTER=${PREFILTER//$'\r'/}
# The bracket pattern is the case-insensitive form of *infisical*: macOS's
# default filesystem resolves `Infisical` to the real binary, and the policy
# owner matches the token case-insensitively, so the prefilter must too (a
# lowercase-only test would fast-allow a capitalized invocation past the
# policy). Pure-bash pattern, no fork, macOS bash 3.2 compatible.
case "$CMD" in
  *"\$'"*|*'$"'*) ;;
  *)
    case "$PREFILTER" in
      *[Ii][Nn][Ff][Ii][Ss][Ii][Cc][Aa][Ll]*) ;;
      *) exit 0 ;;
    esac
    ;;
esac

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || exit 0

POLICY="$FM_ROOT/bin/fm-vault-command-policy.mjs"
command -v node >/dev/null 2>&1 || exit 0
[ -f "$POLICY" ] || exit 0

POLICY_OUTPUT=$(node "$POLICY" --command "$CMD" 2>/dev/null) || exit 0
[ -n "$POLICY_OUTPUT" ] || exit 0

TAB=$(printf '\t')
DECISION=${POLICY_OUTPUT%%"$TAB"*}
[ "$DECISION" = "deny" ] || exit 0
REST=${POLICY_OUTPUT#*"$TAB"}
[ "$REST" != "$POLICY_OUTPUT" ] || exit 0
CODE=${REST%%"$TAB"*}
REASON=${REST#*"$TAB"}
[ -n "$CODE" ] && [ -n "$REASON" ] && [ "$REASON" != "$REST" ] || exit 0

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

DETAIL="[$CODE] $REASON"
ESCAPED=$(json_escape "$DETAIL")
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
[ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$ESCAPED"
exit 2
