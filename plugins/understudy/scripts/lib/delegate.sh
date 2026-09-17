#!/usr/bin/env bash
# understudy — shared delegation plumbing.
#
# Runs one stateless turn of a cheap Claude model through the Claude Code CLI in
# headless mode (`claude -p`). There is no external service and no API key: the
# call is billed to whatever authentication the local CLI already uses, so the
# delegate costs what a Haiku turn costs and nothing more.
#
# The delegate runs deliberately naked:
#   --system-prompt <mode>    replaces the default system prompt outright, so
#                             the worker carries no agent scaffolding
#   --tools ""                no tool access; the corpus is already in the
#                             prompt, and a worker that cannot act cannot
#                             surprise the caller
#   --safe-mode               no CLAUDE.md, no plugins, no hooks, no MCP — this
#                             is also what stops the Read hook from firing
#                             inside the delegate and recursing
#   --no-session-persistence  no session file per delegation
#
# The prompt travels on stdin, so there is no ARG_MAX ceiling. The only limit
# is the delegate's context window, guarded by UNDERSTUDY_MAX_INPUT_TOKENS.
#
# Every call is one shot. Nothing is stored, and a follow-up would mean
# replaying the corpus — which is the exact cost this plugin exists to avoid.
# Ask again with the same paths instead: the files go to the worker, never into
# the caller's context, so re-sending them is free where it matters.

UNDERSTUDY_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
UNDERSTUDY_ROOT=$(cd "$UNDERSTUDY_LIB_DIR/../.." && pwd)

UNDERSTUDY_MODEL="${UNDERSTUDY_MODEL:-claude-haiku-4-5-20251001}"
UNDERSTUDY_CLAUDE_BIN="${UNDERSTUDY_CLAUDE_BIN:-claude}"
UNDERSTUDY_TIMEOUT_SECONDS="${UNDERSTUDY_TIMEOUT_SECONDS:-180}"
UNDERSTUDY_MAX_INPUT_TOKENS="${UNDERSTUDY_MAX_INPUT_TOKENS:-150000}"

understudy_warn() { printf '%s\n' "$*" >&2; }
understudy_err()  { printf 'Error: %s\n' "$*" >&2; }

# --- temp files -------------------------------------------------------------
# One EXIT trap for the whole script; every temp file registers into the list.
UNDERSTUDY_TMPFILES=()
understudy_cleanup() { [ ${#UNDERSTUDY_TMPFILES[@]} -gt 0 ] && rm -f "${UNDERSTUDY_TMPFILES[@]}"; return 0; }
understudy_tmpfile() {
  local f
  f=$(mktemp "${TMPDIR:-/tmp}/understudy.XXXXXX") || return 1
  UNDERSTUDY_TMPFILES+=("$f")
  trap understudy_cleanup EXIT
  printf -v "$1" '%s' "$f"
}

# --- preflight --------------------------------------------------------------
understudy_preflight() {
  local missing=""
  command -v "$UNDERSTUDY_CLAUDE_BIN" >/dev/null 2>&1 || missing="$missing $UNDERSTUDY_CLAUDE_BIN"
  command -v jq >/dev/null 2>&1 || missing="$missing jq"

  if [ -n "$missing" ]; then
    understudy_err "missing required command(s):$missing"
    understudy_warn "  claude — https://claude.com/claude-code, or set UNDERSTUDY_CLAUDE_BIN"
    understudy_warn "  jq     — brew install jq"
    return 1
  fi
  return 0
}

# --- modes ------------------------------------------------------------------
# A mode is a system prompt on disk. Local overrides win over the bundled ones,
# so a project can retune a worker without forking the plugin.
understudy_mode_prompt_file() {
  local mode="$1" dir
  for dir in \
    "${UNDERSTUDY_MODES_DIR:-}" \
    "${XDG_CONFIG_HOME:-$HOME/.config}/understudy/modes" \
    "$UNDERSTUDY_ROOT/modes"
  do
    [ -n "$dir" ] || continue
    if [ -f "$dir/$mode.md" ]; then
      printf '%s\n' "$dir/$mode.md"
      return 0
    fi
  done
  understudy_err "no prompt found for mode \"$mode\" (looked in UNDERSTUDY_MODES_DIR, ~/.config/understudy/modes, $UNDERSTUDY_ROOT/modes)"
  return 1
}

# Per-mode model override: UNDERSTUDY_BULK_READER_MODEL, UNDERSTUDY_CODE_WRITER_MODEL, ...
understudy_model_for() {
  local mode="$1" var
  var="UNDERSTUDY_$(printf '%s' "$mode" | tr '[:lower:]-' '[:upper:]_')_MODEL"
  printf '%s\n' "${!var:-$UNDERSTUDY_MODEL}"
}

# --- invocation -------------------------------------------------------------
# understudy_invoke <mode> <prompt-file>
# Prints the worker's answer on stdout; accounting and errors on stderr.
understudy_invoke() {
  local mode="$1" prompt_file="$2"
  local system_file model bytes est_tokens out err rc pid dog
  local is_error result in_tok out_tok cost dur

  system_file=$(understudy_mode_prompt_file "$mode") || return 1
  model=$(understudy_model_for "$mode")

  bytes=$(wc -c <"$prompt_file" | tr -d ' ')
  est_tokens=$((bytes / 4))
  if [ "$est_tokens" -gt "$UNDERSTUDY_MAX_INPUT_TOKENS" ]; then
    understudy_err "request is ~$est_tokens tokens, over the $UNDERSTUDY_MAX_INPUT_TOKENS token budget."
    understudy_warn "Send fewer or smaller files, or raise UNDERSTUDY_MAX_INPUT_TOKENS if the model's"
    understudy_warn "context window has room (Haiku 4.5: 200K)."
    return 1
  fi

  understudy_tmpfile out || return 1
  understudy_tmpfile err || return 1

  # The prompt goes in on stdin, never on the command line: no ARG_MAX ceiling.
  UNDERSTUDY_ACTIVE=1 "$UNDERSTUDY_CLAUDE_BIN" -p \
    --model "$model" \
    --system-prompt "$(cat "$system_file")" \
    --tools "" \
    --safe-mode \
    --strict-mcp-config \
    --no-session-persistence \
    --output-format json \
    <"$prompt_file" >"$out" 2>"$err" &
  pid=$!

  # macOS ships no timeout(1), so the watchdog is hand-rolled: TERM, then KILL.
  ( sleep "$UNDERSTUDY_TIMEOUT_SECONDS"
    kill -TERM "$pid" 2>/dev/null
    sleep 5
    kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  dog=$!

  wait "$pid"; rc=$?
  kill "$dog" 2>/dev/null
  wait "$dog" 2>/dev/null

  if [ "$rc" -ge 128 ]; then
    understudy_err "the \"$mode\" delegation exceeded ${UNDERSTUDY_TIMEOUT_SECONDS}s and was killed."
    understudy_warn "Raise UNDERSTUDY_TIMEOUT_SECONDS, or split the work into smaller calls."
    return 1
  fi

  # The CLI keeps stdout to pure JSON and puts diagnostics on stderr, so an
  # unparseable stdout is a transport problem, not a model problem.
  if ! jq -e . >/dev/null 2>&1 <"$out"; then
    understudy_err "\"$mode\" delegation returned unparseable output (exit $rc)."
    [ -s "$err" ] && head -c 2000 "$err" >&2
    [ -s "$out" ] && head -c 2000 "$out" >&2
    return 1
  fi

  is_error=$(jq -r '.is_error // false' <"$out")
  result=$(jq -r '.result // empty' <"$out")

  if [ "$rc" -ne 0 ] || [ "$is_error" = "true" ]; then
    understudy_err "\"$mode\" delegation failed: ${result:-unknown error}"
    case "$(jq -r '.api_error_status // empty' <"$out")" in
      401|403) understudy_warn "  The Claude CLI is not authenticated. Run: claude auth login" ;;
      404)     understudy_warn "  Model \"$model\" is not available to this account. Set UNDERSTUDY_MODEL to one that is." ;;
      429)     understudy_warn "  Rate limited. Retry shortly, or lower the delegation rate." ;;
    esac
    return 1
  fi

  if [ -z "$result" ]; then
    understudy_err "\"$mode\" delegation returned no text."
    return 1
  fi

  printf '%s\n' "$result"

  # Claude Code caches large prompts, and a cached prompt reports almost all of
  # its input under the cache counters. Summing them is the only honest total.
  in_tok=$(jq -r '((.usage.input_tokens // 0) + (.usage.cache_creation_input_tokens // 0) + (.usage.cache_read_input_tokens // 0))' <"$out")
  out_tok=$(jq -r '.usage.output_tokens // 0' <"$out")
  cost=$(jq -r '.total_cost_usd // 0' <"$out")
  dur=$(jq -r '((.duration_ms // 0) / 1000 * 10 | round) / 10' <"$out")
  understudy_warn "[understudy: $mode · $model · in ${in_tok} → out ${out_tok} tok · \$${cost} · ${dur}s]"

  if [ -n "${UNDERSTUDY_LOG:-}" ]; then
    jq -nc \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg mode "$mode" --arg model "$model" \
      --argjson in "$in_tok" --argjson out "$out_tok" \
      --argjson cost "$cost" --argjson bytes "$bytes" \
      '{ts:$ts,mode:$mode,model:$model,input_tokens:$in,output_tokens:$out,cost_usd:$cost,payload_bytes:$bytes}' \
      >>"$UNDERSTUDY_LOG" 2>/dev/null || true
  fi

  return 0
}

# --- corpus helpers ---------------------------------------------------------
# A path that does not exist, or that is binary, would reach the worker as an
# empty block and come back as a confident answer about nothing. Fail loudly.
understudy_check_readable() {
  local path="$1"
  if [ ! -f "$path" ] || [ ! -r "$path" ]; then
    understudy_err "file not found or unreadable: $path"
    return 1
  fi
  if ! grep -Iq . "$path" 2>/dev/null; then
    understudy_err "file looks binary, refusing to send it: $path"
    return 1
  fi
  return 0
}

# understudy_append_file <dest> <path> <numbered:0|1>
# XML tags give the worker unambiguous file boundaries; line numbers let it
# cite locations the caller can then verify with a targeted read.
understudy_append_file() {
  local dest="$1" path="$2" numbered="$3" lines
  lines=$(wc -l <"$path" | tr -d ' ')
  {
    printf '<file path="%s" lines="%s">\n' "$path" "$lines"
    if [ "$numbered" = "1" ]; then
      awk '{ printf "%6d\t%s\n", NR, $0 }' "$path"
    else
      cat "$path"
    fi
    printf '\n</file>\n\n'
  } >>"$dest"
}
