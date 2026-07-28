#!/usr/bin/env bash
# Regression: doctor checks 4/8 must resolve the DB the running server actually
# uses — 3-tier: GRAPHRAG_DB_PATH (env) > /ready's db_path (server-reported)
# > $GRAPHRAG_ROOT/index default — and WARN only when all three miss.
#
# Provenance: extended from a local WSL patch's doctor_runtime_db_test.sh
# (2026-07-28, uncommitted working-tree fix that independently reached the same
# design as 0.4.4; port-0 mock server kept as-is). Extensions close three
# false-green holes found in review: (1) assertions pin the *source* of the
# resolved path ("via ..."), so a stray $ROOT/index DB in the environment can't
# satisfy the runtime-DB branch; (2) every branch explicitly clears
# GRAPHRAG_DB_PATH unless it is the variable under test; (3) matching uses
# space-tolerant regex instead of exact-padding grep -F.
set -euo pipefail

PLUGIN_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$PLUGIN_ROOT/scripts/graphrag-ops/tofugraph.sh"
TMPDIR=$(mktemp -d)
PORT_FILE="$TMPDIR/port"
RUNTIME_DB="$TMPDIR/runtime-vault_graph.db"
ENV_DB="$TMPDIR/env-vault_graph.db"
SERVER_PID=''
FAILS=0

cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true   # reap quietly — no "Terminated" noise
  fi
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

touch "$RUNTIME_DB" "$ENV_DB"

# fake engine roots: one with an index DB (branch C), one without (branch D) —
# both carry scripts/cli.py so resolve_root accepts them deterministically,
# instead of falling back to whatever tree the test happens to run in.
mkdir -p "$TMPDIR/root-with-db/scripts" "$TMPDIR/root-with-db/index" \
         "$TMPDIR/root-empty/scripts"
touch "$TMPDIR/root-with-db/scripts/cli.py" \
      "$TMPDIR/root-with-db/index/vault_graph.db" \
      "$TMPDIR/root-empty/scripts/cli.py"

python3 - "$RUNTIME_DB" "$PORT_FILE" <<'PY' &
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

db_path, port_file = sys.argv[1:]

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        payload = {
            "/health": {},
            "/ready": {"ready": True, "db_path": db_path},
            "/api/search": {"results": []},
            "/api/index/status": {"update_in_progress": False, "phase": "idle"},
        }.get(self.path.split("?", 1)[0])
        if payload is None:
            self.send_error(404)
            return
        body = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass

server = HTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w", encoding="utf-8") as f:
    f.write(str(server.server_port))
server.serve_forever()
PY
SERVER_PID=$!

for _ in $(seq 1 50); do
  [ -s "$PORT_FILE" ] && break
  sleep 0.1
done
[ -s "$PORT_FILE" ] || { echo "test server did not start" >&2; exit 1; }
LIVE_API="http://127.0.0.1:$(<"$PORT_FILE")"
DEAD_API="http://127.0.0.1:1"   # nothing listens on port 1 — deterministic down

check() {  # check <name> <output> <must-match-regex> [<must-not-match-regex>]
  local name=$1 out=$2 want=$3 nowant=${4:-}
  if ! grep -Eq "$want" <<<"$out"; then
    echo "FAIL [$name]: missing /$want/" >&2; FAILS=$((FAILS+1)); return
  fi
  if [ -n "$nowant" ] && grep -Eq "$nowant" <<<"$out"; then
    echo "FAIL [$name]: unexpected /$nowant/" >&2; FAILS=$((FAILS+1)); return
  fi
  echo "PASS [$name]"
}

# A. server-reported: no env DB, live server → check 4 must use /ready's db_path
OUT=$(cd "$TMPDIR" && env -u GRAPHRAG_DB_PATH \
  GRAPHRAG_ROOT="$TMPDIR/root-empty" GRAPHRAG_API_URL="$LIVE_API" \
  bash "$SCRIPT" doctor) || true
check "A ready-db"  "$OUT" "\[OK\] +4\. index freshness:.*$RUNTIME_DB.*via /ready db_path" "index db not found"

# B. env priority: GRAPHRAG_DB_PATH must outrank the server-reported path
OUT=$(cd "$TMPDIR" && env GRAPHRAG_DB_PATH="$ENV_DB" \
  GRAPHRAG_ROOT="$TMPDIR/root-empty" GRAPHRAG_API_URL="$LIVE_API" \
  bash "$SCRIPT" doctor) || true
check "B env-first" "$OUT" "\[OK\] +4\. index freshness:.*$ENV_DB.*via GRAPHRAG_DB_PATH" "via /ready db_path"

# C. ROOT default: server down, DB present under $GRAPHRAG_ROOT/index
OUT=$(cd "$TMPDIR" && env -u GRAPHRAG_DB_PATH \
  GRAPHRAG_ROOT="$TMPDIR/root-with-db" GRAPHRAG_API_URL="$DEAD_API" \
  bash "$SCRIPT" doctor) || true
check "C root-default" "$OUT" "\[OK\] +4\. index freshness:.*via GRAPHRAG_ROOT default"

# D. triple miss: server down, no env, ROOT has no index → WARN, not OK
OUT=$(cd "$TMPDIR" && env -u GRAPHRAG_DB_PATH \
  GRAPHRAG_ROOT="$TMPDIR/root-empty" GRAPHRAG_API_URL="$DEAD_API" \
  bash "$SCRIPT" doctor) || true
check "D triple-miss" "$OUT" "\[WARN\] +4\. index db not found" "\[OK\] +4\."

if [ "$FAILS" -gt 0 ]; then echo "$FAILS branch(es) failed" >&2; exit 1; fi
echo "all 4 branches passed"
