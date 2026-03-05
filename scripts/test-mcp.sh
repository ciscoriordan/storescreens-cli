#!/usr/bin/env bash
# Smoke test for storescreens-mcp over stdio (JSON-RPC 2.0 / MCP protocol).
# Usage: ./scripts/test-mcp.sh [path/to/storescreens-mcp]
#
# Sends initialize → initialized → tools/list → tools/call(check) and
# prints each response. Exits 0 if all responses arrive, 1 otherwise.
#
# Requires: bash (any version), python3 (for JSON parsing), mktemp

set -euo pipefail

BIN="${1:-.build/debug/storescreens-mcp}"

if [[ ! -x "$BIN" ]]; then
  echo "ERROR: binary not found at $BIN" >&2
  echo "Run 'swift build' first, or pass the path as the first argument." >&2
  exit 1
fi

# ── named pipes for bidirectional stdio ───────────────────────────────────────

TMPDIR_PIPES=$(mktemp -d)
IN_PIPE="$TMPDIR_PIPES/in"
OUT_PIPE="$TMPDIR_PIPES/out"
mkfifo "$IN_PIPE" "$OUT_PIPE"

cleanup() {
  kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$TMPDIR_PIPES"
}
trap cleanup EXIT

# Launch server: reads from IN_PIPE, writes to OUT_PIPE
"$BIN" <"$IN_PIPE" >"$OUT_PIPE" &
SERVER_PID=$!

# Open write end of IN_PIPE so it doesn't EOF on first write
exec 3>"$IN_PIPE"

# ── helpers ──────────────────────────────────────────────────────────────────

send() { printf '%s\n' "$1" >&3; }

recv() {
  local line
  if IFS= read -r -t 8 line <"$OUT_PIPE"; then
    echo "$line"
  else
    echo "ERROR: timed out waiting for response" >&2
    exit 1
  fi
}

pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }

# ── run ───────────────────────────────────────────────────────────────────────

echo "storescreens-mcp smoke test"
echo "Binary: $BIN"
echo ""

# 1. initialize
send '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke-test","version":"0.1"}}}'
resp=$(recv)
if echo "$resp" | grep -q '"result"'; then
  pass "initialize → got result"
else
  fail "initialize → unexpected: $resp"
fi

# 2. initialized notification (no response)
send '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'
pass "initialized notification sent"

# 3. tools/list
send '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
resp=$(recv)
if echo "$resp" | grep -q '"tools"'; then
  tool_count=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d['result']['tools']))" 2>/dev/null || echo "?")
  pass "tools/list → $tool_count tools registered"
else
  fail "tools/list → unexpected: $resp"
fi

# 4. tools/call check (may error if no project in cwd — both are valid)
send '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"check","arguments":{"directory":"."}}}'
resp=$(recv)
if echo "$resp" | grep -q '"result"'; then
  pass "tools/call(check) → got result"
elif echo "$resp" | grep -q '"error"'; then
  msg=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error',{}).get('message',''))" 2>/dev/null || echo "")
  pass "tools/call(check) → got error (expected outside project): $msg"
else
  fail "tools/call(check) → unexpected: $resp"
fi

echo ""
echo "All checks passed."
