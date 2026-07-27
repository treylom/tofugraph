#!/bin/bash
# tofugraph — GraphRAG ops adapter for Knowledge Manager (optional adapter).
# Verbs: build | search | status | doctor | heal | monitor | install-daemon | uninstall-daemon | guard-set | bench
#
# Best-effort by design: it FIXES what it safely can (stuck/wedged server restart),
# DETECTS-and-REPORTS what needs a human (low disk, semantic-label loss), and stays
# OUT of what it cannot see (OS updates, hardware pressure, corrupted vault content —
# human territory). A stale index gets a build *recommendation*, never an auto-trigger.
# See km-graphrag-ops.md for the full table.
#
# Config resolution: env > auto-detect > default. No paths are hardcoded.
#   GRAPHRAG_ROOT           graphrag home (default: nearest .team-os/graphrag walking up from
#                           cwd; if none found, falls back to this plugin's bundled engine/)
#   GRAPHRAG_API_URL        server base URL (default: http://127.0.0.1:8400)
#   GRAPHRAG_SERVICE_LABEL  launchd label / systemd user unit (default: auto-detect)
#   NTFY_TOPIC              optional push topic for daemon alerts (default: off)
set -uo pipefail

API="${GRAPHRAG_API_URL:-http://127.0.0.1:8400}"

resolve_root() {
  # 환경변수 override 도 실재 검증 후에만 채택한다 — 잘못된 값을 그대로 쓰면
  # "세 곳 모두에 없습니다"가 동봉 engine/ 을 확인도 안 하고 뜨고, 처방(재설치)이
  # 헛다리를 유도한다 (2026-07-28 루돌프 WSL 실측).
  if [ -n "${GRAPHRAG_ROOT:-}" ]; then
    if [ -f "$GRAPHRAG_ROOT/scripts/cli.py" ]; then echo "$GRAPHRAG_ROOT"; return; fi
    echo "[WARN] GRAPHRAG_ROOT='$GRAPHRAG_ROOT' 에 scripts/cli.py 가 없어 이 값을 무시하고 자동 탐색합니다." >&2
  fi
  local d="$PWD"
  while [ "$d" != "/" ]; do
    # 디렉터리 존재가 아니라 cli.py 실재로 판정한다 — build 는 산출물을
    # <cwd>/.team-os/graphrag/index/ 에 떨어뜨리므로, 디렉터리만 보면 build 가
    # *자기 산출물*을 다음 실행에서 "기존 설치본"으로 오인하고 동봉 engine/ 을
    # 못 본다(= 2회차부터 "플러그인 설치가 깨졌습니다" 로 막다른 길).
    # 실측 재현: 2026-07-27 수강생 왕복 검증 [5]→재실행. 우리 봇 환경의
    # .team-os/graphrag 에는 scripts/cli.py 가 실재하므로 우선순위는 그대로다.
    if [ -f "$d/.team-os/graphrag/scripts/cli.py" ]; then echo "$d/.team-os/graphrag"; return; fi
    d=$(dirname "$d")
  done
  # 기존 설치본(.team-os/graphrag)이 없을 때만 — 이 플러그인에 동봉된 engine/ 으로
  # 폴백한다 (수강생 경로; 우리 봇들의 .team-os/graphrag 우선순위는 그대로 유지).
  # 이 스크립트 자신은 <plugin>/scripts/graphrag-ops/tofugraph.sh 에 있으므로
  # 3단계 위(../..)가 플러그인 루트.
  local plugin_root
  plugin_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)
  if [ -n "$plugin_root" ] && [ -f "$plugin_root/engine/scripts/cli.py" ]; then
    echo "$plugin_root/engine"; return
  fi
  echo ""
}

resolve_python() {
  # 기존 설치본(.team-os/graphrag)은 자체 venv 를 갖고 있다 — 있으면 그것을 쓴다.
  # 동봉 engine/ 은 venv 를 담지 않으므로(수강생마다 만들어야 함) 시스템 python3 로.
  if [ -n "$ROOT" ] && [ -x "$ROOT/.venv/bin/python3" ]; then
    echo "$ROOT/.venv/bin/python3"
  else
    echo "python3"
  fi
}
ROOT=$(resolve_root)
LOGS="${ROOT:+$ROOT/logs}"

resolve_service() {
  # Prefer the *server* unit — a graphrag deployment may also run worker/build
  # units (embedding worker, daily rebuild) and restarting those heals nothing.
  if [ -n "${GRAPHRAG_SERVICE_LABEL:-}" ]; then echo "$GRAPHRAG_SERVICE_LABEL"; return; fi
  local all
  if [[ "$OSTYPE" == darwin* ]]; then
    all=$(launchctl list 2>/dev/null | awk '{print $3}' | grep -i graphrag)
  else
    all=$(systemctl --user list-units --type=service --all 2>/dev/null \
      | awk '{print $1}' | grep -i graphrag)
  fi
  echo "$all" | grep -i -E 'serve|server' | head -1 || echo "$all" | head -1
}

restart_server() {
  local label; label=$(resolve_service)
  if [ -z "$label" ]; then
    echo "  → cannot restart: no service registered (auto-heal 은 install-daemon 등록 후에만 동작)"
    server_start_hint
    return 1
  fi
  if [[ "$OSTYPE" == darwin* ]]; then
    launchctl kickstart -k "gui/$(id -u)/$label"
  else
    systemctl --user restart "$label"
  fi
}

wait_ready() {  # up to 60s
  for _ in $(seq 1 12); do
    sleep 5
    if curl -s -m 5 "$API/ready" 2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('ready') else 1)" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

server_start_hint() {
  # 수강생 환경엔 상시 데몬이 없다 — build 는 되는데 search/bench 가 서버 부재로
  # 막히고, doctor→heal 은 "등록된 서비스 없음" 막다른 길이었다(2026-07-27 재경님
  # 적발). 기동 명령은 엔진에 실재(search_server.py 도크스트링)하지만 수강생이
  # 읽는 층에 노출이 없었다 — 그 한 줄을 여기서 표면화한다.
  local py; py=$(resolve_python)
  # 기동 안내의 host/port 는 지금 doctor 가 실제로 탐침한 주소($API)에서 파생한다 —
  # GRAPHRAG_API_URL 을 바꿔 쓴 사용자에게 8400 하드코딩 안내는 헛다리(2026-07-28 손석희 실측).
  local hint_host hint_port hp
  hp="${API#*://}"; hp="${hp%%/*}"
  hint_host="${hp%%:*}"; hint_port="${hp##*:}"
  [ "$hint_host" = "$hint_port" ] && hint_port=8400
  if [ -n "$ROOT" ] && [ -f "$ROOT/scripts/search_server.py" ]; then
    echo "  서버 수동 기동(한 줄, 새 터미널 권장):"
    echo "    cd \"$ROOT/scripts\" && $py -m uvicorn search_server:app --host $hint_host --port $hint_port"
    echo "    (그 터미널을 계속 점유합니다 — 멈추려면 Ctrl+C. uvicorn 이 없다면: $py -m pip install 'uvicorn[standard]' fastapi)"
  else
    echo "  서버 수동 기동: 엔진 scripts/ 폴더에서  python3 -m uvicorn search_server:app --host $hint_host --port $hint_port"
  fi
  case "$API" in
    http://127.0.0.1:8400*|http://localhost:8400*) : ;;
    *) echo "  (지금 점검한 주소 = $API — GRAPHRAG_API_URL 로 바꾼 값입니다. 위 기동 명령도 그 주소에 맞춰 표시했습니다.)" ;;
  esac
}

# ---------------------------------------------------------------- doctor ----
doctor() {
  local fails=0 warns=0
  echo "tofugraph doctor — $(date '+%F %T')"
  echo "api=$API root=${ROOT:-'(not found)'}"
  echo

  # 1. server answering?
  local health
  health=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$API/health" 2>/dev/null || echo ERR)
  if [ "$health" = "200" ]; then
    echo "[OK]   1. server /health 200"
  else
    echo "[FAIL] 1. server /health=$health — server down or hung."
    echo "       주소부터: 지금 보는 주소 = $API (GRAPHRAG_API_URL). 다른 기계·옛 IP 를"
    echo "       가리키면 서버가 멀쩡해도 FAIL 로 보입니다 — 주소가 맞는지 먼저 확인하세요."
    echo "       fix: re-check in 60s (transient hiccups self-recover);"
    echo "            if still down, this tool can restart it: tofugraph.sh heal"
    echo "            상시 데몬을 등록한 적이 없다면(수강생 기본) heal 로는 못 살립니다 —"
    server_start_hint
    fails=$((fails+1))
  fi

  # 2. ready (index loaded)?
  if curl -s -m 5 "$API/ready" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('ready') else 1)" 2>/dev/null; then
    echo "[OK]   2. /ready true (index loaded)"
  else
    echo "[WARN] 2. /ready not true — warming up (normal ~1-2min after restart) or index missing."
    echo "       fix: wait 60s and re-run; if persistent, run: tofugraph.sh build"
    warns=$((warns+1))
  fi

  # 3. real search round-trip (health can be false-green while search is wedged)
  if [ "$health" = "200" ]; then
    local probe
    probe=$(curl -s -m 25 -o /tmp/tofugraph_probe.json -w '%{http_code}' \
      "$API/api/search?q=test&mode=hybrid&top_k=1" 2>/dev/null || echo ERR)
    if [ "$probe" = "200" ] && python3 -c \
      "import json; d=json.load(open('/tmp/tofugraph_probe.json')); assert 'results' in d" 2>/dev/null; then
      echo "[OK]   3. search probe answered (results key present)"
    else
      echo "[FAIL] 3. search probe http=$probe — 'wedge': health OK but search stuck."
      echo "       fix: tofugraph.sh heal  (restarts only after a second confirmation — no false-positive kills)"
      fails=$((fails+1))
    fi
  else
    echo "[SKIP] 3. search probe (server not answering)"
  fi

  # 4. index freshness
  if [ -n "$ROOT" ] && [ -f "$ROOT/index/vault_graph.db" ]; then
    local mtime now age_h
    if [[ "$OSTYPE" == darwin* ]]; then mtime=$(stat -f '%m' "$ROOT/index/vault_graph.db"); else mtime=$(stat -c '%Y' "$ROOT/index/vault_graph.db"); fi
    now=$(date +%s); age_h=$(( (now - mtime) / 3600 ))
    if [ "$age_h" -le 168 ]; then
      echo "[OK]   4. index freshness: updated ${age_h}h ago"
    else
      echo "[WARN] 4. index is ${age_h}h old (>7 days) — new notes are invisible to search."
      echo "       fix: tofugraph.sh build   (or check why the scheduled build stopped)"
      warns=$((warns+1))
    fi
  else
    echo "[WARN] 4. index db not found under \$GRAPHRAG_ROOT — not built yet?  fix: tofugraph.sh build"
    warns=$((warns+1))
  fi

  # 5. disk headroom (builds need transient space; low disk blocks everything)
  local free_gi
  free_gi=$(df "$([[ "$OSTYPE" == darwin* ]] && echo -g || echo -BG)" "${ROOT:-$PWD}" 2>/dev/null | tail -1 | awk '{print $4}' | tr -dc '0-9')
  if [ "${free_gi:-0}" -ge 10 ] 2>/dev/null; then
    echo "[OK]   5. disk ${free_gi}Gi free"
  else
    echo "[WARN] 5. disk ${free_gi:-?}Gi free (<10Gi) — REPORT-ONLY: freeing space / OS updates need a human."
    warns=$((warns+1))
  fi

  # 6. update/worker state (don't fight a running rebuild)
  local upd
  upd=$(curl -s -m 5 "$API/api/index/status" 2>/dev/null | python3 -c \
    "import json,sys
try: d=json.load(sys.stdin); print(('updating:'+d.get('phase','?')) if d.get('update_in_progress') else 'idle')
except Exception: print('unknown')" 2>/dev/null || echo unknown)
  echo "[INFO] 6. index update state: $upd  (while updating, slow probes are expected — do not restart)"

  # 7. service registration (auto mode)
  local label; label=$(resolve_service)
  if [ -n "$label" ]; then
    echo "[OK]   7. service registered: $label (auto-restart possible)"
  else
    echo "[INFO] 7. no service registered — manual mode. For auto-heal: tofugraph.sh install-daemon"
  fi

  # 8. semantic-label guard (a rebuild/merge bug can silently wipe enriched
  #    relationship labels; counting is cheap, losing them is not — the baseline
  #    ratchets up on growth and any drop below it is a hard FAIL)
  local dbf="${ROOT:+$ROOT/index/vault_graph.db}" basef="${ROOT:+$ROOT/index/label-guard.baseline}"
  if [ -n "$ROOT" ] && [ -f "$dbf" ] && command -v sqlite3 >/dev/null 2>&1; then
    local labels
    labels=$(sqlite3 "$dbf" \
      "SELECT COUNT(*) FROM relationships WHERE type NOT IN ('related_to','mentions');" 2>/dev/null)
    if [ -z "$labels" ]; then
      echo "[INFO] 8. semantic-label guard: n/a (no relationships table — older index schema)"
    elif [ ! -f "$basef" ]; then
      echo "$labels" > "$basef"
      echo "[OK]   8. semantic-label guard: $labels labels — baseline recorded"
    else
      local base; base=$(tr -dc '0-9' < "$basef")
      if [ "$labels" -ge "${base:-0}" ] 2>/dev/null; then
        [ "$labels" -gt "${base:-0}" ] && echo "$labels" > "$basef"
        echo "[OK]   8. semantic-label guard: $labels labels (baseline $base) — no loss"
      else
        echo "[FAIL] 8. semantic-label guard: $labels < baseline $base — enriched labels LOST."
        echo "       fix: restore the index from a backup taken before the losing build;"
        echo "            if the drop is intentional (notes deleted), re-baseline: tofugraph.sh guard-set"
        fails=$((fails+1))
      fi
    fi
  else
    echo "[SKIP] 8. semantic-label guard (index db or sqlite3 not available)"
  fi

  echo
  echo "summary: ${fails} fail, ${warns} warn — $( [ $fails -eq 0 ] && echo 'usable' || echo 'needs attention' )"
  return $fails
}

# ------------------------------------------------------------------ heal ----
heal() {
  # Manual one-shot heal: confirm twice (60s apart) before restarting — the
  # double-check is what prevents false-positive kill loops (measured in prod).
  local h1 probe1
  h1=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$API/health" 2>/dev/null || echo ERR)
  probe1=$(curl -s -m 25 -o /dev/null -w '%{http_code}' "$API/api/search?q=test&mode=hybrid&top_k=1" 2>/dev/null || echo ERR)
  if [ "$h1" = "200" ] && [ "$probe1" = "200" ]; then
    echo "server healthy (health 200, search answers) — nothing to heal"; return 0
  fi
  echo "unhealthy (health=$h1 probe=$probe1) — confirming in 60s (transients self-recover)..."
  sleep 60
  h1=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$API/health" 2>/dev/null || echo ERR)
  probe1=$(curl -s -m 25 -o /dev/null -w '%{http_code}' "$API/api/search?q=test&mode=hybrid&top_k=1" 2>/dev/null || echo ERR)
  if [ "$h1" = "200" ] && [ "$probe1" = "200" ]; then
    echo "recovered on its own — no restart needed"; return 0
  fi
  echo "confirmed stuck → restarting service..."
  if restart_server; then
    if wait_ready; then echo "recovered: restart + /ready GREEN"; return 0
    else echo "partial: restarted but /ready timed out — wait another 1-2min (model warm-up) and run doctor"; return 1; fi
  else
    echo "restart unavailable — 아래 한 줄로 직접 기동한 뒤 doctor 로 확인하세요:"
    server_start_hint
    return 1
  fi
}

# ---------------------------------------------------------------- status ----
status() {
  doctor | head -4
  local qlog="${LOGS:+$LOGS/query-log.jsonl}"
  if [ -n "$qlog" ] && [ -f "$qlog" ]; then
    python3 - "$qlog" << 'PY'
import json, sys, statistics as st, datetime
cut = (datetime.datetime.now().astimezone() - datetime.timedelta(hours=24)).isoformat()
el = []
with open(sys.argv[1]) as f:
    for line in f:
        try: r = json.loads(line)
        except Exception: continue
        if r.get('timestamp_kst','') >= cut and r.get('top_k') != 1:
            el.append(r['elapsed_ms']/1000)
if el:
    el.sort(); n = len(el)
    p90 = el[min(n-1, int(0.9*n))]
    print(f"last 24h: {n} queries | median {st.median(el):.2f}s | p90 {p90:.2f}s | >10s {sum(1 for e in el if e>10)}/{n}")
else:
    print("last 24h: no queries logged")
PY
  else
    echo "query log not found (server logs to \$GRAPHRAG_ROOT/logs/query-log.jsonl)"
  fi
}

# --------------------------------------------------------------- monitor ----
monitor() {
  # One daemon tick: dead-server double-check → wedge double-check → restart+verify.
  # State lives next to the logs so consecutive ticks share the wedge counter.
  [ -z "$ROOT" ] && { echo "monitor needs GRAPHRAG_ROOT"; return 1; }
  mkdir -p "$LOGS"
  local heal_log="$LOGS/auto-heal.log" wedge_state="$LOGS/wedge-consecutive-count.state"
  local ts; ts=$(date '+%F %T')

  local health
  health=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$API/health" 2>/dev/null || echo ERR)
  if [ "$health" != "200" ]; then
    echo "[$ts] health=$health (1st,5s) → recheck in 60s" >> "$heal_log"
    sleep 60
    health=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$API/health" 2>/dev/null || echo ERR)
    if [ "$health" != "200" ]; then
      echo "[$ts] health=$health persists → dead server → restart" >> "$heal_log"
      if restart_server >> "$heal_log" 2>&1 && wait_ready; then
        echo "[$ts] recovered: dead-server restart + /ready GREEN" >> "$heal_log"
      else
        echo "[$ts] UNHEALED: restart failed or /ready timeout — needs a human" >> "$heal_log"
        [ -n "${NTFY_TOPIC:-}" ] && curl -s -H "Title: graphrag auto-heal" -d "$ts unhealed dead server" "ntfy.sh/$NTFY_TOPIC" >/dev/null 2>&1
      fi
      echo 0 > "$wedge_state"; return 0
    fi
    echo "[$ts] health recovered on 2nd check (transient)" >> "$heal_log"
  fi

  # skip probe while a rebuild is running (probing then = self-inflicted wedge alarms)
  local upd
  upd=$(curl -s -m 5 "$API/api/index/status" 2>/dev/null | python3 -c \
    "import json,sys
try: d=json.load(sys.stdin); print('busy' if d.get('update_in_progress') or (d.get('embedding_worker') or {}).get('phase')=='activating' else 'idle')
except Exception: print('idle')" 2>/dev/null || echo idle)
  if [ "$upd" = "busy" ]; then
    echo "[$ts] index update in progress → probe skipped this tick" >> "$heal_log"; return 0
  fi

  local wedge="" probe
  probe=$(curl -s -m 25 -o /tmp/tofugraph_probe.json -w '%{http_code}' \
    "$API/api/search?q=test&mode=hybrid&top_k=1" 2>/dev/null || echo ERR)
  if [ "$probe" != "200" ]; then wedge="probe_http=$probe"
  elif ! python3 -c "import json; d=json.load(open('/tmp/tofugraph_probe.json')); assert 'results' in d" 2>/dev/null; then
    wedge="probe_no_results_key"
  fi

  local count; count=$(cat "$wedge_state" 2>/dev/null || echo 0)
  if [ -n "$wedge" ]; then count=$((count+1)); else count=0; fi
  echo "$count" > "$wedge_state"
  if [ -n "$wedge" ] && [ "$count" -lt 2 ]; then
    echo "[$ts] wedge=$wedge (1st) → hold, need 2 consecutive" >> "$heal_log"; return 0
  fi
  if [ -n "$wedge" ]; then
    echo "[$ts] wedge=$wedge (x$count) → restart" >> "$heal_log"
    if restart_server >> "$heal_log" 2>&1 && wait_ready; then
      echo "[$ts] recovered: wedge restart + /ready GREEN" >> "$heal_log"
    else
      echo "[$ts] UNHEALED wedge — needs a human" >> "$heal_log"
      [ -n "${NTFY_TOPIC:-}" ] && curl -s -H "Title: graphrag auto-heal" -d "$ts unhealed wedge" "ntfy.sh/$NTFY_TOPIC" >/dev/null 2>&1
    fi
  fi
}

# ---------------------------------------------------------- install-daemon --
install_daemon() {
  local self; self=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
  if [[ "$OSTYPE" == darwin* ]]; then
    local plist="$HOME/Library/LaunchAgents/com.km.tofugraph-monitor.plist"
    cat > "$plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.km.tofugraph-monitor</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$self</string><string>monitor</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>GRAPHRAG_ROOT</key><string>${ROOT}</string>
    <key>GRAPHRAG_API_URL</key><string>${API}</string>
  </dict>
  <key>StartInterval</key><integer>3600</integer>
  <key>RunAtLoad</key><false/>
</dict></plist>
EOF
    launchctl unload "$plist" 2>/dev/null; launchctl load "$plist" \
      && echo "installed: hourly monitor (launchd com.km.tofugraph-monitor). uninstall: tofugraph.sh uninstall-daemon"
  else
    local line="0 * * * * GRAPHRAG_ROOT='$ROOT' GRAPHRAG_API_URL='$API' /bin/bash '$self' monitor"
    ( crontab -l 2>/dev/null | grep -v tofugraph ; echo "$line" ) | crontab - \
      && echo "installed: hourly monitor (crontab). uninstall: tofugraph.sh uninstall-daemon"
  fi
}

uninstall_daemon() {
  if [[ "$OSTYPE" == darwin* ]]; then
    local plist="$HOME/Library/LaunchAgents/com.km.tofugraph-monitor.plist"
    launchctl unload "$plist" 2>/dev/null; rm -f "$plist"; echo "removed launchd monitor"
  else
    crontab -l 2>/dev/null | grep -v tofugraph | crontab -; echo "removed crontab monitor"
  fi
}

# -------------------------------------------------------------- guard-set ---
guard_set() {
  # Re-baseline the semantic-label guard after an *intentional* label decrease.
  local dbf="${ROOT:+$ROOT/index/vault_graph.db}" basef="${ROOT:+$ROOT/index/label-guard.baseline}"
  [ -n "$ROOT" ] && [ -f "$dbf" ] || { echo "no index db under \$GRAPHRAG_ROOT — nothing to baseline"; return 1; }
  command -v sqlite3 >/dev/null 2>&1 || { echo "sqlite3 not available"; return 1; }
  local labels
  labels=$(sqlite3 "$dbf" \
    "SELECT COUNT(*) FROM relationships WHERE type NOT IN ('related_to','mentions');" 2>/dev/null)
  [ -n "$labels" ] || { echo "no relationships table — older index schema, guard not applicable"; return 1; }
  echo "$labels" > "$basef" && echo "baseline set: $labels semantic labels ($basef)"
}

# ------------------------------------------------- vault path resolution ----
# cli.py 는 --vault 를 안 받으면 config.yaml 의 vault 섹션을 보고, 그마저 없으면
# 코드에 박힌 남(운영자)의 vault 경로로 조용히 떨어진다 — 수강생 컴퓨터엔 없는
# 경로라 build 가 남의 폴더를 찾다 실패한다. build 전에 "vault 가 뭔지 정해졌나"
# 를 먼저 본다.
find_vault_flag_value() {
  local skip=0 tok
  for tok in "$@"; do
    if [ "$skip" = "1" ]; then echo "$tok"; return 0; fi
    case "$tok" in
      --vault) skip=1 ;;
      --vault=*) echo "${tok#--vault=}"; return 0 ;;
    esac
  done
}

find_config_flag_value() {
  local skip=0 tok
  for tok in "$@"; do
    if [ "$skip" = "1" ]; then echo "$tok"; return 0; fi
    case "$tok" in
      --config) skip=1 ;;
      --config=*) echo "${tok#--config=}"; return 0 ;;
    esac
  done
}

config_has_vault_path() {
  # cli.py 의 _load_config() 를 그대로 재사용해서(중복 파싱 회피) vault.{mac_path,
  # wsl_path,path} 중 하나라도 있는지만 본다. 첫 인자=python, 둘째=scripts 디렉터리,
  # 이후 인자=검사할 config 경로 후보들(먼저 있는 걸 채택하는 게 아니라 하나라도
  # vault 를 갖고 있으면 통과).
  local py="$1" scripts_dir="$2"; shift 2
  local cfg_path
  for cfg_path in "$@"; do
    [ -n "$cfg_path" ] || continue
    "$py" -c "
import sys
sys.path.insert(0, '$scripts_dir')
try:
    from cli import _load_config
    cfg = _load_config('$cfg_path')
except Exception:
    cfg = {}
v = (cfg.get('vault') or {})
sys.exit(0 if (v.get('mac_path') or v.get('wsl_path') or v.get('path')) else 1)
" >/dev/null 2>&1 && return 0
  done
  return 1
}

# ------------------------------------------------------ pre-build gate ------
pre_build_gate() {
  # build 는 원래 [1/5]~[4/5] 를 다 돌고 나서야 [5/5] 임베딩에서 죽었다 —
  # 수강생이 몇 분을 기다린 뒤에야 실패를 봤다는 뜻. 여기서 엔진을 부르기
  # *전에* 환경을 검사해 게이트를 앞으로 당긴다.
  # 근거: 실제 수강생 환경 왕복 실측에서 [5/5] 임베딩 단계 실패가 가장 늦게 드러났다.
  local py="$1"; shift

  # 0. vault 경로가 정해졌는가.
  local vault_val; vault_val=$(find_vault_flag_value "$@")
  if [ -n "$vault_val" ]; then
    if [ ! -d "$vault_val" ]; then
      cat << EOF
[안내] 알려주신 폴더가 보이지 않습니다:  $vault_val

경로를 다시 확인해서 알려주세요:  tofugraph.sh build --vault /경로/내-옵시디언-폴더
EOF
      return 1
    fi
  else
    local config_val; config_val=$(find_config_flag_value "$@")
    local config_ok=1
    if [ -n "$config_val" ]; then
      # 사용자가 --config 를 직접 줬으면 그 파일만 본다(그게 cli.py 가 실제로 쓸 값).
      config_has_vault_path "$py" "$ROOT/scripts" "$config_val" && config_ok=0
    else
      # --config 도 안 줬으면 cli.py 의 기본값(CWD 상대)과, 이 설치본의 관례적
      # 위치($ROOT/config.yaml) 둘 다 확인 — 어디서 실행하든 기존 설치본이 있으면
      # 잡히게 한다(예: vault 루트가 아니라 그 하위 폴더에서 실행한 경우도 커버).
      config_has_vault_path "$py" "$ROOT/scripts" \
        "$ROOT/config.yaml" ".team-os/graphrag/config.yaml" && config_ok=0
    fi
    if [ "$config_ok" -ne 0 ]; then
      cat << EOF
[안내] 어느 폴더(Obsidian vault)를 읽을지 아직 정해지지 않았습니다 — 잘못하신 게
아니라 아직 알려주지 않으셔서 그렇습니다.

  알려주는 방법:  tofugraph.sh build --vault /경로/내-옵시디언-폴더

(지정하지 않으면 이 컴퓨터에 없는 경로를 찾다가 실패합니다.)
EOF
      return 1
    fi
  fi

  # build 가 실제로 쓰는 모듈을 전부 본다. scipy 하나만 검사하면, 시스템 파이썬에
  # scipy 만 있는 흔한 환경에서 게이트가 통과한 뒤 [2/5] 커뮤니티 탐지에서
  # python-louvain 부재로 죽는다 — 게이트를 앞으로 당긴 의미가 사라진다.
  # 실측 재현: 2026-07-27 수강생 왕복 검증 v2 [1] (scipy 통과 → [2/5] RuntimeError).
  local missing="" mod label
  for mod in scipy networkx community numpy yaml; do
    if ! "$py" -c "import $mod" >/dev/null 2>&1; then
      case "$mod" in
        community) label="python-louvain" ;;
        yaml)      label="pyyaml" ;;
        *)         label="$mod" ;;
      esac
      missing="$missing $label"
    fi
  done
  if [ -n "$missing" ]; then
    cat << EOF
[안내] 그래프 구축(build)에 필요한 파이썬 라이브러리가 아직 없습니다:$missing

  아래 두 줄을 그대로 복사해 실행하세요 — 이 도구 전용 파이썬 자리를 만듭니다:

    python3 -m venv $ROOT/.venv
    $ROOT/.venv/bin/python3 -m pip install -r $ROOT/scripts/requirements.txt

  ⓘ 요즘 macOS·리눅스는 시스템 파이썬에 바로 설치하는 것을 막습니다
    (externally-managed-environment 오류). 위처럼 전용 자리를 만들면 그 문제를
    피하고, 이 도구가 다음 실행부터 그 자리를 자동으로 씁니다.
EOF
    # Ubuntu·Debian 계열은 python3-venv 패키지가 따로 있다. 그게 없으면 위 첫 줄은
    # "성공"하지만 만들어진 자리에 설치 도구(pip)가 안 들어가서, 둘째 줄이
    # "No module named pip" 로 죽는다 — 첫 줄이 조용히 성공해서 원인을 찾기 어렵다.
    # 그래서 처방을 주기 전에 여기서 미리 잡는다.
    if ! python3 -c "import ensurepip" >/dev/null 2>&1; then
      cat << 'EOF'

  ⚠️ 다만 이 시스템은 위 첫 줄만으로는 부족합니다 — 전용 자리는 만들어지는데
    그 안에 설치 도구(pip)가 들어가지 않습니다. 아래 중 하나를 **먼저** 하세요:

      sudo apt install python3-venv          (Ubuntu·Debian 계열)
      brew install uv  →  uv venv <전용 자리 경로>/.venv   (uv 를 쓰신다면)
EOF
    # quoted heredoc 안이라 $ROOT 가 안 펼쳐진다 — 실제 경로는 별도 줄로 찍어준다
    # (2026-07-28 루돌프 실측: 그 줄만 복붙하면 빈 경로가 됨).
    echo "      (전용 자리 경로 = $ROOT)"
    fi
    cat << EOF

설치가 끝나면 다시 실행하세요:  tofugraph.sh build
EOF
    return 1
  fi
  local has_skip=0 a
  for a in "$@"; do [ "$a" = "--skip-embeddings" ] && has_skip=1; done
  if [ "$has_skip" -eq 0 ] && ! "$py" -c "import sentence_transformers" >/dev/null 2>&1; then
    cat << EOF
[안내] 의미 검색(임베딩 — 문장을 숫자 벡터로 바꿔서 뜻이 비슷한 글까지 찾아주는 기능)에
쓰는 'sentence-transformers' 라이브러리가 아직 없습니다. 둘 중 하나를 고르세요.

  A) 임베딩 없이 진행 (즉시, 추천)
     tofugraph.sh build --skip-embeddings
     → 그래프 검색·키워드 검색은 정상 동작합니다.

  B) 임베딩까지 켜기 (준비 필요)
     $py -m pip install sentence-transformers
     → 약 1GB 를 내려받습니다 (라이브러리 511MB + AI 모델 458MB).
     설치가 끝나면:  tofugraph.sh build
EOF
    return 1
  fi
  return 0
}

# ---------------------------------------------------------- build / search --
delegate_engine() {
  # 엔진 탐색 우선순위 (resolve_root, 위):
  #   1) GRAPHRAG_ROOT 환경변수         (명시 지정)
  #   2) 기존 설치본 .team-os/graphrag  (우리 봇들 — 그대로 우선, 변경 없음)
  #   3) 이 플러그인에 동봉된 engine/   (수강생 — 1·2가 없을 때만)
  # 예전엔 "이 어댑터는 엔진 사본을 두 번 담지 않는다(single-source principle)"
  # 였으나, D1 후속 조사(2026-07-27)로 확정: 수강생 환경엔 별도 설치본이 없어
  # "엔진 부재"가 1순위 이탈점이었다 — 그래서 코드 464K(데이터 3.9G는 제외)만 담는다.
  local verb="$1"; shift
  if [ -n "$ROOT" ] && [ -f "$ROOT/scripts/cli.py" ]; then
    local py; py=$(resolve_python)
    if [ "$verb" = "build" ]; then
      pre_build_gate "$py" "$@" || return 1
    fi
    # cli.py 의 --config/--db/--vault 는 부모(전역) 파서 옵션이라 서브커맨드
    # *앞*에서만 인식된다 — 뒤에 붙이면 argparse 가 "unrecognized arguments" 로
    # 죽는다. 여기서 그 셋만 앞으로 재배치하고 나머지(--skip-embeddings 등)는
    # 그대로 verb 뒤에 둔다.
    # bash 3.2(macOS 기본 /bin/bash) 호환: 빈 배열 확장은
    # ${arr[@]+"${arr[@]}"} 로 가드(그냥 "${arr[@]}"는 set -u 에서 빈 배열일 때
    # "unbound variable" 로 죽는다 — 실측 확인).
    local global_args=() verb_args=() skip_next=0 tok
    for tok in "$@"; do
      if [ "$skip_next" = "1" ]; then
        global_args+=("$tok"); skip_next=0; continue
      fi
      case "$tok" in
        --vault|--db|--config) global_args+=("$tok"); skip_next=1 ;;
        --vault=*|--db=*|--config=*) global_args+=("$tok") ;;
        *) verb_args+=("$tok") ;;
      esac
    done
    "$py" "$ROOT/scripts/cli.py" \
      "${global_args[@]+"${global_args[@]}"}" "$verb" "${verb_args[@]+"${verb_args[@]}"}"
    local rc=$?
    if [ "$verb" = "build" ] && [ "$rc" = "0" ]; then
      # build 성공 ≠ 검색 가능 — search/bench 는 검색 서버가 떠 있어야 한다.
      # 서버가 이미 살아 있으면(우리 봇 환경 등) 이 안내는 생략한다.
      local h; h=$(curl -s -m 3 -o /dev/null -w '%{http_code}' "$API/health" 2>/dev/null || echo ERR)
      if [ "$h" != "200" ]; then
        echo
        echo "다음 단계: 검색 서버 기동 — search·bench 는 서버가 떠 있어야 동작합니다."
        server_start_hint
        echo "  기동 후 확인:  tofugraph.sh doctor"
      fi
    fi
    return $rc
  fi
  if [ -n "$ROOT" ] && [ -d "$ROOT/scripts" ]; then
    echo "engine found at $ROOT/scripts — run its documented build entry (see ThisCode docs/06-graphrag-setup.md)."
    return 0
  fi
  # 여기까지 왔다는 건 세 곳(GRAPHRAG_ROOT · 기존 설치본 · 동봉 engine/) 다 없다는
  # 뜻이다 — 정상 배포라면 engine/scripts/cli.py 가 있어야 하므로, 이건 "엔진을
  # 안 담았다"가 아니라 "플러그인 설치가 깨졌거나 engine/ 이 빠진 배포"다.
  cat << 'EOF'
[안내] GraphRAG 엔진을 찾지 못했습니다 — 아래 세 곳 모두에 없습니다.
  1) GRAPHRAG_ROOT 환경변수로 지정한 경로
  2) 기존 설치본(.team-os/graphrag)
  3) 이 플러그인에 동봉된 엔진(engine/scripts/cli.py)

정상 설치라면 이 플러그인 폴더 안에 engine/scripts/cli.py 가 있어야 합니다. 지금
없다는 건 플러그인 설치가 깨졌거나, engine/ 폴더가 빠진 채로 배포됐을 가능성이 큽니다.

  처방:  /plugin uninstall tofugraph
        /plugin install tofugraph@tofukyung-plugins

이미 다른 곳에 GraphRAG 를 설치해 두셨다면, 환경변수로 직접 알려주는 방법도 있습니다:

  GRAPHRAG_ROOT=/그-경로 tofugraph.sh build
EOF
  return 1
}

# ------------------------------------------------------------------ bench ---
# 강의 4.6 클립("나만의 벤치마크") 실습 재료. 결정적 hit@k 채점만 한다 — LLM 채점
# (RAGAS 류)은 넣지 않는다: hit@k 는 교육용으로 충분하고, LLM 채점은 API 키를
# 요구해 수강생 환경 전제가 무거워진다.

bench_init() {
  local out="${1:-./tofugraph-bench.json}"
  if [ -e "$out" ]; then
    cat << EOF
[안내] 이미 파일이 있습니다: $out

덮어쓰지 않았습니다 — 기존 파일을 계속 쓰거나, 다른 경로로 새로 만드세요:
  tofugraph.sh bench init 다른이름.json
EOF
    return 1
  fi
  cat > "$out" << 'JSON'
{
  "schema_version": "bench-v1",
  "proof_class": "student-local",
  "guide": [
    "각 문항의 \"query\"에 실제로 검색해볼 질문을, \"gold_notes\"에 그 질문의 정답이라고 생각하는 노트 제목을 적어주세요 (확장자·경로 없이, 예: \"GraphRAG-Theory-MOC\").",
    "query 를 비워두면(기본값) bench run 실행 시 그 문항은 자동으로 건너뜁니다 — 5개를 다 채우지 않아도 됩니다."
  ],
  "items": {
    "Q01": {"qid": "Q01", "query": "", "gold_notes": []},
    "Q02": {"qid": "Q02", "query": "", "gold_notes": []},
    "Q03": {"qid": "Q03", "query": "", "gold_notes": []},
    "Q04": {"qid": "Q04", "query": "", "gold_notes": []},
    "Q05": {"qid": "Q05", "query": "", "gold_notes": []}
  }
}
JSON
  echo "생성 완료: $out"
  echo
  echo "다음 순서로 진행하세요:"
  echo "  1) $out 파일을 열어 query 와 gold_notes 를 채운다"
  echo "  2) tofugraph.sh bench run $out"
}

bench_run() {
  local goldset="" top_k=5 skip_next=0 a
  for a in "$@"; do
    if [ "$skip_next" = "1" ]; then top_k="$a"; skip_next=0; continue; fi
    case "$a" in
      --top-k) skip_next=1 ;;
      --top-k=*) top_k="${a#--top-k=}" ;;
      *) [ -z "$goldset" ] && goldset="$a" ;;
    esac
  done
  [ -z "$goldset" ] && goldset="./tofugraph-bench.json"

  if [ ! -f "$goldset" ]; then
    cat << EOF
[안내] 골드셋 파일을 찾을 수 없습니다: $goldset

먼저 템플릿을 만들고 채워주세요:
  tofugraph.sh bench init
  (파일을 열어 query 와 gold_notes 를 채운 뒤)
  tofugraph.sh bench run
EOF
    return 1
  fi

  # 문항을 순회하는 중간에 서버가 죽으면 부분 결과라 헷갈리므로, 먼저 한 번 확인한다
  # (기존 search 서브커맨드와 같은 health 체크 — doctor 항목 1과 동일 패턴).
  local health
  health=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$API/health" 2>/dev/null || echo ERR)
  if [ "$health" != "200" ]; then
    cat << EOF
[안내] 검색 서버에 연결할 수 없습니다 (health=$health, 주소=$API).

  1) 서버가 켜져 있는지 확인:  tofugraph.sh doctor
  2) 꺼져 있다면 켜보세요:     tofugraph.sh heal
  3) 그래도 안 되면 GRAPHRAG_API_URL 환경변수가 올바른 주소를 가리키는지 확인하세요.
EOF
    return 1
  fi

  # 채점 로직 전체(호출·판정·표 출력)를 여기 담는다 — bash 만으로 JSON 파싱/표 정렬은
  # 무리라 python3(표준 라이브러리만) 사용. API 호출 경로는 위 search 서브커맨드와
  # 완전히 동일: $API/api/search?q=<질문>&mode=hybrid&top_k=<k>.
  # 노트 식별 키 = "entity"(실측: /api/search 응답의 results[].entity 가 노트/엔티티
  # 제목 그대로 — 2026-07-27 격리 서버[port 8420, 사본 index]로 GraphRAG 질의 실행해
  # "GraphRAG-Theory-MOC" 문항으로 직접 확인). source_note(있으면 "<경로>/제목.md")의
  # 파일명도 보조로 대조 — entity 가 alias 라 note 제목과 다를 수 있는 경우 대비.
  python3 - "$goldset" "$API" "$top_k" << 'PY'
import json
import sys
import urllib.error
import urllib.parse
import urllib.request

goldset_path, api, top_k_raw = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    top_k = int(top_k_raw)
except ValueError:
    top_k = 5

with open(goldset_path, encoding="utf-8") as f:
    data = json.load(f)

items = data.get("items", {})
if isinstance(items, list):
    items = {it.get("qid", f"Q{i+1:02d}"): it for i, it in enumerate(items)}


def norm(s):
    return (s or "").strip().casefold()


rows = []
hits = 0
scored = 0
for qid in sorted(items.keys()):
    item = items[qid] or {}
    query = (item.get("query") or "").strip()
    gold_notes = item.get("gold_notes") or []
    if not query:
        rows.append((qid, "(비어있음 — 건너뜀)", "-", "-"))
        continue
    scored += 1
    gold_norm = {norm(g) for g in gold_notes if isinstance(g, str) and g.strip()}
    display_q = query if len(query) <= 24 else query[:23] + "…"
    url = f"{api}/api/search?q={urllib.parse.quote(query)}&mode=hybrid&top_k={top_k}"
    try:
        with urllib.request.urlopen(url, timeout=30) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
    except Exception as exc:
        rows.append((qid, display_q, "?", f"오류: {exc}"))
        continue
    results = payload.get("results") or []
    hit_rank = None
    for rank, r in enumerate(results, start=1):
        candidates = set()
        entity = norm(r.get("entity"))
        if entity:
            candidates.add(entity)
        source_note = r.get("source_note")
        if source_note:
            stem = source_note.rsplit("/", 1)[-1]
            if stem.endswith(".md"):
                stem = stem[:-3]
            candidates.add(norm(stem))
        if candidates & gold_norm:
            hit_rank = rank
            break
    if hit_rank is not None:
        hits += 1
        rows.append((qid, display_q, "O", str(hit_rank)))
    else:
        rows.append((qid, display_q, "X", "-"))

headers = ("문항", "질문", "적중", "몇 위")
table = [headers] + rows
widths = [max(len(str(row[i])) for row in table) for i in range(4)]


def fmt(row):
    return " | ".join(str(c).ljust(w) for c, w in zip(row, widths))


print(fmt(headers))
print("-+-".join("-" * w for w in widths))
for row in rows:
    print(fmt(row))
print()
if scored:
    pct = round(100 * hits / scored, 1)
    print(f"hit@{top_k}: {hits}/{scored} = {pct}%")
else:
    print("채점 가능한 문항이 없습니다 — bench init 으로 만든 파일의 query 를 먼저 채워주세요.")
PY
}

case "${1:-help}" in
  doctor)  doctor ;;
  status)  status ;;
  heal)    heal ;;
  monitor) monitor ;;
  install-daemon)   install_daemon ;;
  uninstall-daemon) uninstall_daemon ;;
  guard-set) guard_set ;;
  build)   shift; delegate_engine build "$@" ;;
  search)  shift; q="${1:-}"; [ -z "$q" ] && { echo "usage: tofugraph.sh search <query>"; exit 1; }
           curl -s -m 30 "$API/api/search?q=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$q")&mode=hybrid&top_k=5" \
             | python3 -m json.tool ;;
  bench)
    shift
    case "${1:-}" in
      init) shift; bench_init "$@" ;;
      run)  shift; bench_run "$@" ;;
      *) echo "usage: tofugraph.sh bench {init [출력경로]|run [골드셋경로] [--top-k N]}"; exit 1 ;;
    esac
    ;;
  *) echo "tofugraph — GraphRAG ops adapter"
     echo "usage: tofugraph.sh {doctor|status|heal|monitor|install-daemon|uninstall-daemon|guard-set|build|search <q>|bench {init|run}}"
     echo "env: GRAPHRAG_ROOT, GRAPHRAG_API_URL, GRAPHRAG_SERVICE_LABEL, NTFY_TOPIC" ;;
esac
