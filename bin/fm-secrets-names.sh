#!/usr/bin/env bash
# fm-secrets-names.sh - the ONLY sanctioned way to list Infisical secret NAMES.
#
# Incident 2026-07-30: a crewmate listed secret VALUES into its session
# transcript with a raw infisical listing command. bin/fm-vault-pretool-check.sh
# now denies every value-printing infisical form; this wrapper is the sanctioned
# replacement for the one legitimate need those forms served - discovering what
# secrets exist. See docs/vault-guard.md for the full contract.
#
# Contract:
#   - Prints secret NAMES only, one per line, to stdout. Never a value.
#   - Structurally strips, never filters: it fetches machine-readable JSON from
#     the Infisical CLI and emits only the name fields the parser proves are
#     names. It never passes CLI stdout through.
#   - Fail closed: if the CLI fails, jq is missing, or the JSON does not match a
#     known export shape exactly, it prints NOTHING on stdout and exits
#     non-zero. There is no raw-output fallback path.
#   - The CLI's stderr (auth errors, tips) passes through untouched; Infisical
#     writes secret material to stdout only, and stdout is never passed through.
#
# Usage:
#   fm-secrets-names.sh --projectId <id> --env <slug> [--path <folder>]
#
# Both --projectId and --env are required so a listing is always explicit about
# what it lists; --path narrows to a folder (Infisical's default is /).
# Authentication is ambient (infisical login or INFISICAL_TOKEN), exactly as
# for any other infisical invocation.
set -u

usage() {
  sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'
}

PROJECT_ID=""
ENV_SLUG=""
FOLDER=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --projectId)
      [ "$#" -gt 1 ] || { echo "error: --projectId requires a value" >&2; exit 2; }
      PROJECT_ID=$2
      shift 2
      ;;
    --projectId=*)
      PROJECT_ID=${1#--projectId=}
      shift
      ;;
    --env)
      [ "$#" -gt 1 ] || { echo "error: --env requires a value" >&2; exit 2; }
      ENV_SLUG=$2
      shift 2
      ;;
    --env=*)
      ENV_SLUG=${1#--env=}
      shift
      ;;
    --path)
      [ "$#" -gt 1 ] || { echo "error: --path requires a value" >&2; exit 2; }
      FOLDER=$2
      shift 2
      ;;
    --path=*)
      FOLDER=${1#--path=}
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1 (this wrapper lists names only and takes --projectId, --env, --path)" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[ -n "$PROJECT_ID" ] || { echo "error: --projectId is required" >&2; usage >&2; exit 2; }
[ -n "$ENV_SLUG" ] || { echo "error: --env is required" >&2; usage >&2; exit 2; }

command -v infisical >/dev/null 2>&1 || { echo "error: infisical CLI not found on PATH" >&2; exit 3; }
command -v jq >/dev/null 2>&1 || { echo "error: jq not found on PATH; refusing to print anything without a structural parse" >&2; exit 3; }

EXPORT_ARGS=(export --projectId "$PROJECT_ID" --env "$ENV_SLUG" --format json --silent)
[ -z "$FOLDER" ] || EXPORT_ARGS+=(--path "$FOLDER")

# CLI stdout is captured and NEVER printed; only jq-proven name fields are.
if ! RAW=$(infisical "${EXPORT_ARGS[@]}"); then
  echo "error: infisical export failed; nothing printed" >&2
  exit 3
fi

# Accept exactly the two machine shapes infisical export --format json is known
# to emit, and nothing else:
#   - an array of objects that each carry a string .key (name field),
#   - a flat object whose keys are the secret names.
# Any other shape aborts with no stdout at all. jq output is captured first and
# printed only after a fully successful parse, so a mid-stream jq error can
# never leave partial output behind.
if ! NAMES=$(printf '%s' "$RAW" | jq -er '
  if type == "array" then
    if all(.[]; type == "object" and (.key | type == "string")) then .[].key
    else error("unrecognized element shape") end
  elif type == "object" then keys_unsorted[]
  else error("unrecognized document shape") end
' 2>/dev/null); then
  echo "error: infisical export output did not match a known JSON shape; refusing to print anything" >&2
  exit 3
fi

[ -z "$NAMES" ] || printf '%s\n' "$NAMES"
