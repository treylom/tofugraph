#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""tofugraph viz — 3D 그래프 뷰어 localhost 서버 모드.

우리 운영 탐색기처럼 `http://127.0.0.1:<port>/` 에 상시 떠 있고, **브라우저
새로고침 때마다 DB(vault_graph.db) mtime 을 확인해 바뀌었으면 데이터를 다시
추출·조립**해서 준다 — 창고가 자라면 새로고침 한 번으로 반영된다.

표준 라이브러리만 사용(uvicorn·flask 불필요). 산출 파일을 디스크에 남기지
않고 메모리에서 조립해 서빙한다(공개 레포에 데이터 파일이 남는 사고 차단 —
2026-07-28 vault 데이터 유출 인시던트 교훈).

사용:
  python3 serve_viewer.py [--port 8401] [--db <vault_graph.db>] [--vault <창고>]
  (경로 해석은 export_data.py 와 동일한 3단: CLI > env > .team-os 상향 탐색)

서버 실패(포트 점유 등) 시의 폴백 = 기존 단일 파일 경로(export_data.py +
build_viewer.py) — commands/3d.md 가 안내한다.
"""
import argparse
import http.server
import os
import socketserver
import sys
import tempfile
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import build_viewer  # noqa: E402
import export_data  # noqa: E402


class ViewerState:
    """DB mtime 기준 캐시 — 바뀌었을 때만 재추출·재조립."""

    def __init__(self, db, vault):
        self.db = db
        self.vault = vault
        self._lock = threading.Lock()
        self._html = None
        self._built_mtime = None

    def html(self):
        try:
            mtime = os.path.getmtime(self.db)
        except OSError:
            return None  # DB 부재 — 핸들러가 안내문 응답
        with self._lock:
            if self._html is None or mtime != self._built_mtime:
                with tempfile.TemporaryDirectory() as td:
                    data_path = os.path.join(td, "graph3d-data.json")
                    out_path = os.path.join(td, "graph3d.html")
                    export_data.export(self.db, self.vault, data_path)
                    build_viewer.build(data_path, out_path)
                    with open(out_path, encoding="utf-8") as f:
                        self._html = f.read()
                self._built_mtime = mtime
        return self._html


def make_handler(state):
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802 (http.server 규약)
            html = state.html()
            if html is None:
                body = (
                    "vault_graph.db 를 찾지 못했습니다 — 먼저 /tofugraph:build 로 "
                    "인덱스를 만들거나 --db 로 경로를 지정한 뒤 새로고침하세요."
                ).encode("utf-8")
                self.send_response(503)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            body = html.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")  # 새로고침 = 항상 최신 판정
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, fmt, *args):
            sys.stderr.write("[serve_viewer] %s\n" % (fmt % args))

    return Handler


def main():
    ap = argparse.ArgumentParser(description="tofugraph 3D 뷰어 localhost 서버")
    ap.add_argument("--port", type=int, default=int(os.environ.get("TOFUGRAPH_VIZ_PORT", "8401")))
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--db", help="vault_graph.db 경로 (기본: export_data 와 동일 탐색)")
    ap.add_argument("--vault", help="창고(vault) 경로 (기본: 현재 폴더)")
    args = ap.parse_args()

    db = export_data.resolve_db(args.db)
    vault = export_data.resolve_vault(args.vault)
    state = ViewerState(db, vault)

    # 기동 시 1회 선조립 — 첫 접속이 느리지 않게 + DB 문제를 기동 시점에 드러냄
    warm = state.html()
    if warm is None:
        print(f"[WARN] DB 없음: {db} — 서버는 띄우되, /tofugraph:build 후 새로고침하면 뜹니다.")

    socketserver.TCPServer.allow_reuse_address = True
    try:
        httpd = socketserver.ThreadingTCPServer((args.host, args.port), make_handler(state))
    except OSError as e:
        sys.exit(
            f"[ERR] {args.host}:{args.port} 를 못 잡았습니다({e}) — 다른 포트로 재시도: "
            f"--port {args.port + 1}  (또는 단일 파일 폴백: export_data.py + build_viewer.py)"
        )
    url = f"http://{args.host}:{args.port}/"
    print(f"[OK] tofugraph 3D 뷰어 서버 기동 — {url}")
    print("     창고가 바뀌면 브라우저 새로고침만 하면 됩니다(요청마다 DB 변경 감지).")
    print("     멈추려면 Ctrl+C. (이 터미널을 계속 점유합니다)")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n[OK] 종료")


if __name__ == "__main__":
    main()
