#!/usr/bin/env node
// Semantic policy for the vault-guard: can a shell command print secret VALUES
// from the Infisical vault into the session transcript?
//
// Incident 2026-07-30: a crewmate's first Infisical command listed secret
// values into its session transcript; the brief said names-only, and
// instruction-following failed where enforcement did not exist. This policy is
// the enforcement: it allows only the value-safe infisical forms and denies
// every value-printing or unclassifiable one, fail closed. The harness
// transport lives in bin/fm-vault-pretool-check.sh; the full contract and
// validation record live in docs/vault-guard.md.
//
// Allowed forms (everything else that executes infisical denies):
//   - infisical run ... -- <cmd>, infisical run --command '<cmd>': the
//     injection form - secrets go to a child process env, never to output -
//     EXCEPT when the child is a known env-dump shape (env/printenv/set/
//     export/declare/typeset, an echo/printf carrying a $, or a shell payload
//     that reaches one of those).
//   - infisical login / infisical init / infisical help.
//   - --help, -h, or --version before any `--` terminator.
//   - bin/fm-secrets-names.sh (the sanctioned names-only listing wrapper) is
//     allowed by construction: it never matches the infisical token, so it
//     never reaches a deny path here or in the transport prefilter.
//
// The shell tokenizer, command-position analysis, and execution-sink helpers
// are imported from bin/fm-arm-command-policy.mjs, the sole owner of
// firstmate's shell classification, so this guard never duplicates shell
// lexing. This policy never evaluates, expands, sources, or runs any byte of
// the submitted command; it inspects lexical positions only.
//
// Fail-closed contract (the deliberate difference from the cd-guard): syntax
// this classifier cannot prove safe - a lexer error, unsupported compound
// grammar, an unresolved wrapper option, a dynamic (non-literal) execution
// payload, or a dynamic command word - denies whenever the raw command also
// carries the infisical token, exactly as the watcher-arm guard fails closed
// on unclassifiable protected commands. Opaque dataflow that never carries the
// token (bash -c "$WHOLE_COMMAND" with no infisical bytes anywhere) remains
// out of scope by the same agent-mistake threat model.

import {
  Lexer,
  splitProgram,
  commandPosition,
  shellInvocation,
  evalPayload,
  shellHeredocPayloads,
  shellHereStringPayloads,
} from "./fm-arm-command-policy.mjs";
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

const REASONS = {
  "vault-secret-print":
    "this infisical command can print secret VALUES into the session transcript. Sanctioned paths: bin/fm-secrets-names.sh --projectId <id> --env <slug> lists secret NAMES only; infisical run [flags] -- <cmd> injects secrets into a child process env without printing them.",
  "vault-run-dump":
    "this infisical run child command would dump the injected secret environment into the transcript. Run the real workload command under infisical run instead; list secret NAMES with bin/fm-secrets-names.sh.",
  "unclassifiable-vault-command":
    "unsupported, malformed, or dynamic shell syntax carries an infisical command that cannot be safely classified. Use a plain infisical run [flags] -- <cmd> to inject secrets, or bin/fm-secrets-names.sh --projectId <id> --env <slug> to list secret names.",
};

// Child commands that print the environment they run in. `set`, `export`,
// `declare`, and `typeset` are shell builtins that dump the environment when
// bare, so they matter inside `sh -c` payloads and are matched in direct child
// position too (fail closed - they can never be a real workload binary).
const DUMP_COMMANDS = new Set(["env", "printenv", "set", "export", "declare", "typeset"]);
const ECHO_COMMANDS = new Set(["echo", "printf"]);
// Commands that execute their argument words, which command-position analysis
// alone would treat as data. Denied whenever an argument carries the infisical
// token: the sanctioned forms never need an indirect executor.
const EXEC_FORWARDERS = new Set([
  "xargs",
  "parallel",
  "watch",
  "nice",
  "ionice",
  "stdbuf",
  "setsid",
  "doas",
  "script",
  "caffeinate",
  "chronic",
  "unbuffer",
  "hyperfine",
]);
const UNSUPPORTED_KEYWORDS = new Set([
  "if",
  "then",
  "else",
  "elif",
  "fi",
  "for",
  "while",
  "until",
  "case",
  "esac",
  "do",
  "done",
  "function",
  "time",
  "coproc",
]);
const MAX_DEPTH = 12;

function basename(value) {
  return value.split("/").filter(Boolean).at(-1) || value;
}

// macOS's default filesystem is case-insensitive, so `Infisical secrets`
// executes the real binary; every token match here is therefore
// case-insensitive (the transport prefilter mirrors this).
function isInfisicalName(value) {
  return basename(value).toLowerCase() === "infisical";
}

// Raw-byte token test used only to gate the fail-closed fallbacks; it mirrors
// the transport prefilter's cheap byte strip so an escape- or quote-split
// token (infi\sical, in"fisical") still counts as a mention. Positive
// classification of executed positions works on cooked words and does not use
// this.
function mentionsInfisical(text) {
  return /infisical/i.test(String(text).replace(/[\\'"\r\n]/g, ""));
}

function dynamicWord(word) {
  return Boolean(word) && (!word.literal || word.subs.length > 0);
}

// `command -v infisical` is an existence query, not an execution (the same
// carve-out the cd-guard makes for `command -v cd`).
function hasCommandQueryPrefix(position) {
  let commandPrefix = false;
  for (const word of position.words.slice(position.prefixAssignments, position.index)) {
    if (word.value === "command") {
      commandPrefix = true;
      continue;
    }
    if (commandPrefix && /^-[^-]*[vV]/.test(word.value)) return true;
  }
  return false;
}

function deny(code) {
  return { deny: code };
}

function combine(target, nested, source) {
  if (nested.deny) {
    target.deny = target.deny || nested.deny;
    return;
  }
  // Nested trouble matters only when the nested source can actually carry an
  // infisical command (the same gating the arm guard applies to nested
  // payload errors).
  if ((nested.unsupported || nested.dynamic) && mentionsInfisical(source)) {
    target.unsupported = true;
  }
}

// --- infisical invocation classification ------------------------------------

function classifyInfisical(position, tokens, depth) {
  const args = position.words.slice(position.index + 1);
  const terminator = args.findIndex((word) => word.value === "--");
  const pre = terminator === -1 ? args : args.slice(0, terminator);
  if (pre.some((word) => word.value === "--help" || word.value === "-h" || word.value === "--version")) {
    return {};
  }
  const subIndex = pre.findIndex((word) => !word.value.startsWith("-"));
  if (subIndex === -1) return deny("vault-secret-print");
  const sub = pre[subIndex];
  if (dynamicWord(sub)) return deny("unclassifiable-vault-command");
  if (sub.value === "login" || sub.value === "init" || sub.value === "help") return {};
  if (sub.value !== "run") return deny("vault-secret-print");
  return classifyRun(position, tokens, args, subIndex, terminator, depth);
}

function classifyRun(position, tokens, args, subIndex, terminator, depth) {
  const result = {};
  // --command payloads are full shell command strings executed with the
  // injected environment; classify each literal payload as a dump-context
  // program, and fail closed on a dynamic one.
  const pre = terminator === -1 ? args : args.slice(0, terminator);
  for (let i = subIndex + 1; i < pre.length; i += 1) {
    const word = pre[i];
    let payloadWord = null;
    let inlinePrefix = 0;
    if (word.value === "--command" || word.value === "-c") {
      payloadWord = pre[i + 1] || null;
      i += 1;
    } else if (word.value.startsWith("--command=")) {
      payloadWord = word;
      inlinePrefix = "--command=".length;
    } else if (word.value.startsWith("-c") && word.value.length > 2 && !word.value.startsWith("--")) {
      // Cobra accepts the glued short form: -c'printenv' cooks to -cprintenv,
      // and -c=x means the same payload.
      payloadWord = word;
      inlinePrefix = word.value.startsWith("-c=") ? 3 : 2;
    }
    if (!payloadWord) continue;
    if (dynamicWord(payloadWord)) return deny("unclassifiable-vault-command");
    const payload = payloadWord.value.slice(inlinePrefix);
    const nested = classifyDumpProgram(payload, depth + 1);
    if (nested.deny) return nested;
    combine(result, nested, payload);
  }
  let childWords = [];
  if (terminator !== -1) {
    childWords = args.slice(terminator + 1);
  } else {
    // Bare-word child form (infisical run <cmd...>): the first non-flag word
    // after `run` starts the child. A separate-value flag (--env dev) misreads
    // its value as the child; that costs at worst a conservative deny, never a
    // missed dump.
    for (let i = subIndex + 1; i < args.length; i += 1) {
      if (!args[i].value.startsWith("-")) {
        childWords = args.slice(i);
        break;
      }
    }
  }
  if (childWords.length > 0) {
    const nested = classifyChild(childWords, tokens, depth);
    if (nested.deny) return nested;
    combine(result, nested, childWords.map((word) => word.value).join(" "));
  }
  if (result.unsupported && !result.deny) return deny("unclassifiable-vault-command");
  return result;
}

// Classify the command a `infisical run` child position executes. `tokens` is
// the enclosing node's token list so a heredoc feeding a stdin-mode shell
// child is still visible.
function classifyChild(childWords, tokens, depth) {
  if (depth > MAX_DEPTH) return deny("unclassifiable-vault-command");
  const position = commandPosition(childWords);
  if (position.unresolvedWrapperOption) return deny("unclassifiable-vault-command");
  const result = {};
  for (const payload of position.wrapperPayloads) {
    const nested = classifyDumpProgram(payload, depth + 1);
    if (nested.deny) return nested;
    combine(result, nested, payload);
  }
  let command = position.command;
  let commandIndex = position.index;
  if (!command) {
    // commandPosition consumes `env` as a wrapper; with no command after it,
    // bare `env` (or `env FOO=1`) prints the whole injected environment.
    if (position.wrappers.includes("env")) return deny("vault-run-dump");
    return result;
  }
  // `builtin` is not a commandPosition wrapper; skip it so `builtin export`
  // inside a shell payload still hits the dump check.
  while (command && basename(command.value) === "builtin") {
    commandIndex += 1;
    command = position.words[commandIndex];
  }
  if (!command) return result;
  if (dynamicWord(command)) return deny("unclassifiable-vault-command");
  const name = basename(command.value).toLowerCase();
  if (DUMP_COMMANDS.has(name)) return deny("vault-run-dump");
  if (ECHO_COMMANDS.has(name)) {
    const echoed = position.words.slice(commandIndex + 1);
    if (echoed.some((word) => dynamicWord(word) || word.value.includes("$"))) {
      return deny("vault-run-dump");
    }
    return result;
  }
  if (name === "infisical") {
    if (hasCommandQueryPrefix(position)) return result;
    const nested = classifyInfisical(position, tokens, depth + 1);
    if (nested.deny) return nested;
    combine(result, nested, position.words.map((word) => word.value).join(" "));
    return result;
  }
  if (name === "sh" || name === "bash" || name === "zsh") {
    const shell = shellInvocation(position);
    // A case-variant shell name (SH) or a builtin-prefixed one defeats the
    // case-sensitive shared shellInvocation; in dump context that is
    // unclassifiable, so fail closed.
    if (!shell) return deny("unclassifiable-vault-command");
    if (shell.kind === "command") {
      if (!shell.payload) return result;
      if (dynamicWord(shell.payload)) return deny("unclassifiable-vault-command");
      const nested = classifyDumpProgram(shell.payload.value, depth + 1);
      if (nested.deny) return nested;
      combine(result, nested, shell.payload.value);
      return result;
    }
    if (shell.kind === "script") {
      // An opaque script file cannot be classified; fail closed only when its
      // name carries the token, otherwise it is the workload's own business.
      if (shell.payload && mentionsInfisical(shell.payload.value)) return deny("unclassifiable-vault-command");
      return result;
    }
    for (const body of [...shellHeredocPayloads(tokens, position), ...shellHereStringPayloads(tokens, position)]) {
      const nested = classifyDumpProgram(body, depth + 1);
      if (nested.deny) return nested;
      combine(result, nested, body);
    }
    return result;
  }
  if (name === "eval") {
    const payload = evalPayload(position);
    if (payload === null) return deny("unclassifiable-vault-command");
    const nested = classifyDumpProgram(payload, depth + 1);
    if (nested.deny) return nested;
    combine(result, nested, payload);
    return result;
  }
  if (EXEC_FORWARDERS.has(name)) {
    // Resolve the forwarder like a wrapper: the first non-flag word after it
    // starts the real child.
    for (let i = position.index + 1; i < position.words.length; i += 1) {
      if (!position.words[i].value.startsWith("-")) {
        return classifyChild(position.words.slice(i), tokens, depth + 1);
      }
    }
    return result;
  }
  return result;
}

// A program that runs WITH secrets injected into its environment (an
// `infisical run --command` payload, a shell child's -c payload, a heredoc fed
// to a stdin-mode shell child). Inside this context there is no
// mention-gating: anything unclassifiable denies, because the environment it
// runs in is already the protected material.
function classifyDumpProgram(source, depth) {
  if (depth > MAX_DEPTH) return deny("unclassifiable-vault-command");
  const lexed = new Lexer(source).tokenize();
  if (lexed.error) return deny("unclassifiable-vault-command");
  const { nodes } = splitProgram(lexed.tokens);
  for (const tokens of nodes) {
    const position = commandPosition(tokens);
    const firstName = basename(position.words[0]?.value || "");
    if (UNSUPPORTED_KEYWORDS.has(firstName)) return deny("unclassifiable-vault-command");
    for (const token of tokens) {
      if (token.type === "group") {
        const nested = classifyDumpProgram(token.content, depth + 1);
        if (nested.deny) return nested;
      }
      if (token.type === "word") {
        for (const substitution of token.subs) {
          const nested = classifyDumpProgram(substitution.content, depth + 1);
          if (nested.deny) return nested;
        }
      }
    }
    const nested = classifyChild(position.words, tokens, depth + 1);
    if (nested.deny) return nested;
    if (nested.unsupported || nested.dynamic) return deny("unclassifiable-vault-command");
  }
  return {};
}

// --- top-level program classification ---------------------------------------

function classifyProgram(source, depth) {
  const result = {};
  if (depth > MAX_DEPTH) {
    result.unsupported = true;
    return result;
  }
  const lexed = new Lexer(source).tokenize();
  if (lexed.error) {
    result.unsupported = true;
    return result;
  }
  const { nodes } = splitProgram(lexed.tokens);
  for (const tokens of nodes) {
    const position = commandPosition(tokens);
    const firstName = basename(position.words[0]?.value || "");
    if (UNSUPPORTED_KEYWORDS.has(firstName)) result.unsupported = true;
    if (position.unresolvedWrapperOption) result.unsupported = true;
    for (const payload of position.wrapperPayloads) {
      combine(result, classifyProgram(payload, depth + 1), payload);
      if (result.deny) return result;
    }
    for (const token of tokens) {
      if (token.type === "group") {
        combine(result, classifyProgram(token.content, depth + 1), token.content);
        if (result.deny) return result;
      }
      if (token.type === "word") {
        for (const substitution of token.subs) {
          combine(result, classifyProgram(substitution.content, depth + 1), substitution.content);
          if (result.deny) return result;
        }
      }
    }
    const command = position.command;
    if (!command) continue;
    const name = basename(command.value).toLowerCase();
    if (name === "sh" || name === "bash" || name === "zsh") {
      const shell = shellInvocation(position);
      if (!shell) {
        // A case-variant shell name (SH) defeats the case-sensitive shared
        // shellInvocation; treat as unsupported so a token-carrying command
        // still fails closed.
        result.unsupported = true;
      } else if (shell.kind === "command" && shell.payload) {
        if (dynamicWord(shell.payload)) {
          result.dynamic = true;
        } else {
          combine(result, classifyProgram(shell.payload.value, depth + 1), shell.payload.value);
          if (result.deny) return result;
        }
      } else if (shell.kind === "script") {
        if (shell.payload && mentionsInfisical(shell.payload.value)) result.unsupported = true;
      } else if (shell.kind === "stdin") {
        for (const body of [...shellHeredocPayloads(tokens, position), ...shellHereStringPayloads(tokens, position)]) {
          combine(result, classifyProgram(body, depth + 1), body);
          if (result.deny) return result;
        }
      }
    } else if (name === "eval") {
      const payload = evalPayload(position);
      if (payload === null) {
        result.dynamic = true;
      } else {
        combine(result, classifyProgram(payload, depth + 1), payload);
        if (result.deny) return result;
      }
    } else if (isInfisicalName(command.value)) {
      if (!hasCommandQueryPrefix(position)) {
        const nested = classifyInfisical(position, tokens, depth);
        if (nested.deny) {
          result.deny = nested.deny;
          return result;
        }
        if (nested.unsupported) result.unsupported = true;
      }
    } else if (EXEC_FORWARDERS.has(name)) {
      if (position.words.some((word) => mentionsInfisical(word.value))) {
        result.deny = "unclassifiable-vault-command";
        return result;
      }
    } else if (dynamicWord(command)) {
      // A command word this classifier cannot resolve ($X, $(pick-tool));
      // matters only when the raw command also carries the token.
      result.dynamic = true;
    }
  }
  return result;
}

function decision(command) {
  const result = classifyProgram(command, 0);
  if (result.deny) {
    return { decision: "deny", code: result.deny, reason: REASONS[result.deny] };
  }
  if ((result.unsupported || result.dynamic) && mentionsInfisical(command)) {
    return {
      decision: "deny",
      code: "unclassifiable-vault-command",
      reason: REASONS["unclassifiable-vault-command"],
    };
  }
  return { decision: "allow" };
}

function parseArguments(argv) {
  const result = { command: "", commandSet: false };
  for (let i = 0; i < argv.length; i += 1) {
    const name = argv[i];
    if (name === "--command") {
      if (i + 1 >= argv.length) throw new Error("--command requires a value");
      result.command = argv[i + 1];
      result.commandSet = true;
      i += 1;
      continue;
    }
    if (name.startsWith("--command=")) {
      result.command = name.slice("--command=".length);
      result.commandSet = true;
      continue;
    }
    throw new Error(`unknown argument: ${name}`);
  }
  return result;
}

function invokedDirectly() {
  const entry = process.argv[1];
  if (!entry) return false;
  const self = fileURLToPath(import.meta.url);
  try {
    return realpathSync(entry) === realpathSync(self);
  } catch {
    return entry === self;
  }
}

if (invokedDirectly()) {
  try {
    const args = parseArguments(process.argv.slice(2));
    if (!args.commandSet || !args.command) {
      process.stdout.write("allow\n");
    } else {
      const result = decision(args.command);
      if (result.decision === "allow") {
        process.stdout.write("allow\n");
      } else {
        process.stdout.write(`deny\t${result.code}\t${result.reason}\n`);
      }
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}

export { decision };
