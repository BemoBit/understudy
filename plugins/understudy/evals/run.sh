#!/usr/bin/env bash
# Offline test suite. Makes no network calls and spends nothing: the hooks are
# fed synthetic tool-call JSON, and the delegation transport runs against a stub
# `claude` on PATH.
#
#   bash evals/run.sh

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/understudy-evals.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    printf '  ✓ %s\n' "$1"; pass=$((pass + 1))
  else
    printf '  ✗ %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; fail=$((fail + 1))
  fi
}

awk 'BEGIN { for (i = 1; i <= 500; i++) print "line " i }' >"$WORK/big.txt"
awk 'BEGIN { for (i = 1; i <= 10; i++) print "line " i }'  >"$WORK/small.txt"
printf 'binary\000payload\n' >"$WORK/blob.bin"

# Returns "deny" or "allow" for one hook invocation.
run_hook() { # run_hook <hook> <json>
  local out
  out=$(printf '%s' "$2" | env CLAUDE_PLUGIN_ROOT="$ROOT" "$ROOT/hooks/$1" 2>/dev/null)
  case "$out" in
    *'"permissionDecision":"deny"'*) echo deny ;;
    '')                              echo allow ;;
    *)                               echo "unexpected: $out" ;;
  esac
}

read_json() { printf '{"tool_name":"Read","tool_input":{"file_path":"%s"%s}}' "$1" "${2:-}"; }
bash_json() { jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'; }

printf '\nRead hook\n'
check "large file is denied"            deny  "$(run_hook check-file-size "$(read_json "$WORK/big.txt")")"
check "small file passes"               allow "$(run_hook check-file-size "$(read_json "$WORK/small.txt")")"
check "offset read passes"              allow "$(run_hook check-file-size "$(read_json "$WORK/big.txt" ',"offset":10')")"
check "limit read passes"               allow "$(run_hook check-file-size "$(read_json "$WORK/big.txt" ',"limit":50')")"
check "missing file passes"             allow "$(run_hook check-file-size "$(read_json "$WORK/nope.txt")")"
check "binary file passes"              allow "$(run_hook check-file-size "$(read_json "$WORK/blob.bin")")"
check "no file_path passes"             allow "$(run_hook check-file-size '{"tool_name":"Read","tool_input":{}}')"
check "path with spaces is denied"      deny  "$(cp "$WORK/big.txt" "$WORK/a b.txt"; run_hook check-file-size "$(read_json "$WORK/a b.txt")")"
check "UNDERSTUDY_DISABLE passes"          allow "$(UNDERSTUDY_DISABLE=1 run_hook check-file-size "$(read_json "$WORK/big.txt")")"
check "inside a delegation passes"      allow "$(UNDERSTUDY_ACTIVE=1 run_hook check-file-size "$(read_json "$WORK/big.txt")")"
check "raised threshold passes"         allow "$(UNDERSTUDY_MIN_LINES=1000 run_hook check-file-size "$(read_json "$WORK/big.txt")")"
check "lowered threshold denies"        deny  "$(UNDERSTUDY_MIN_LINES=5 run_hook check-file-size "$(read_json "$WORK/small.txt")")"
check "no claude on PATH passes"        allow "$(UNDERSTUDY_CLAUDE_BIN=definitely-not-installed run_hook check-file-size "$(read_json "$WORK/big.txt")")"

printf '\nBash hook\n'
check "cat on large file denied"        deny  "$(run_hook check-bash-read "$(bash_json "cat $WORK/big.txt")")"
check "cat on small file passes"        allow "$(run_hook check-bash-read "$(bash_json "cat $WORK/small.txt")")"
check "piped cat passes"                allow "$(run_hook check-bash-read "$(bash_json "cat $WORK/big.txt | grep line")")"
check "redirected cat passes"           allow "$(run_hook check-bash-read "$(bash_json "cat $WORK/big.txt > /tmp/out")")"
check "head passes"                     allow "$(run_hook check-bash-read "$(bash_json "head -n 20 $WORK/big.txt")")"
check "tail passes"                     allow "$(run_hook check-bash-read "$(bash_json "tail $WORK/big.txt")")"
check "less on large file denied"       deny  "$(run_hook check-bash-read "$(bash_json "less $WORK/big.txt")")"
check "git status passes"               allow "$(run_hook check-bash-read "$(bash_json 'git status')")"
check "grep on large file passes"       allow "$(run_hook check-bash-read "$(bash_json "grep foo $WORK/big.txt")")"
check "chained cat is caught"           deny  "$(run_hook check-bash-read "$(bash_json "cd /tmp && cat $WORK/big.txt")")"
check "second file in cat is caught"    deny  "$(run_hook check-bash-read "$(bash_json "cat $WORK/small.txt $WORK/big.txt")")"
check "env-prefixed cat is caught"      deny  "$(run_hook check-bash-read "$(bash_json "FOO=1 cat $WORK/big.txt")")"
check "cat with flag still caught"      deny  "$(run_hook check-bash-read "$(bash_json "cat -n $WORK/big.txt")")"
check "binary cat passes"               allow "$(run_hook check-bash-read "$(bash_json "cat $WORK/blob.bin")")"
check "empty command passes"            allow "$(run_hook check-bash-read '{"tool_name":"Bash","tool_input":{}}')"

# --- transport --------------------------------------------------------------
# A stub `claude` lets the real delegate.sh run end to end with no network.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/claude" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null                                   # drain the prompt from stdin
case "${STUB_BEHAVIOUR:-ok}" in
  ok)        printf '{"is_error":false,"result":"• delegated answer","usage":{"input_tokens":120,"output_tokens":8},"total_cost_usd":0.0001,"duration_ms":1234}\n'; exit 0 ;;
  api_error) printf '{"is_error":true,"result":"model not found","api_error_status":404,"usage":{},"total_cost_usd":0}\n'; exit 1 ;;
  garbage)   printf 'not json at all\n'; exit 0 ;;
  fenced)    printf '{"is_error":false,"result":"```java\\nclass A {}\\n```","usage":{"input_tokens":1,"output_tokens":1},"total_cost_usd":0,"duration_ms":1}\n'; exit 0 ;;
  refuse)    printf '{"is_error":false,"result":"ERROR: no reference for the target type","usage":{"input_tokens":1,"output_tokens":1},"total_cost_usd":0,"duration_ms":1}\n'; exit 0 ;;
  hang)      sleep 30; exit 0 ;;
esac
STUB
chmod +x "$WORK/bin/claude"
export PATH="$WORK/bin:$PATH"

printf '\nTransport\n'
out=$("$ROOT/scripts/bulk-read" --question q --paths "$WORK/small.txt" 2>/dev/null)
check "bulk-read returns the answer" "• delegated answer" "$out"

"$ROOT/scripts/bulk-read" --question q --paths "$WORK/nope.txt" >/dev/null 2>&1
check "missing path fails"              1 $?

"$ROOT/scripts/bulk-read" --question q --paths "$WORK/blob.bin" >/dev/null 2>&1
check "binary path fails"               1 $?

"$ROOT/scripts/bulk-read" --paths "$WORK/small.txt" >/dev/null 2>&1
check "missing --question fails"        2 $?

STUB_BEHAVIOUR=api_error "$ROOT/scripts/bulk-read" --question q --paths "$WORK/small.txt" >/dev/null 2>&1
check "api error surfaces as failure"   1 $?

STUB_BEHAVIOUR=garbage "$ROOT/scripts/bulk-read" --question q --paths "$WORK/small.txt" >/dev/null 2>&1
check "unparseable output fails"        1 $?

STUB_BEHAVIOUR=hang UNDERSTUDY_TIMEOUT_SECONDS=2 "$ROOT/scripts/bulk-read" --question q --paths "$WORK/small.txt" >/dev/null 2>&1
check "timeout is enforced"             1 $?

UNDERSTUDY_MAX_INPUT_TOKENS=1 "$ROOT/scripts/bulk-read" --question q --paths "$WORK/small.txt" >/dev/null 2>&1
check "oversized request is refused"    1 $?

"$ROOT/scripts/code-write" --spec s >/dev/null 2>&1
check "code-write needs a reference"    2 $?

STUB_BEHAVIOUR=fenced "$ROOT/scripts/code-write" --spec s --reference "$WORK/small.txt" --target "$WORK/gen.java" >/dev/null 2>&1
check "markdown fence is stripped"      "class A {}" "$(cat "$WORK/gen.java" 2>/dev/null)"

STUB_BEHAVIOUR=fenced "$ROOT/scripts/code-write" --spec s --reference "$WORK/small.txt" --target "$WORK/gen.java" >/dev/null 2>&1
check "existing target is protected"    1 $?

STUB_BEHAVIOUR=refuse "$ROOT/scripts/code-write" --spec s --reference "$WORK/small.txt" --target "$WORK/refused.java" >/dev/null 2>&1
check "worker refusal is not written"   "no" "$([ -e "$WORK/refused.java" ] && echo yes || echo no)"

printf '\n%s passed, %s failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
