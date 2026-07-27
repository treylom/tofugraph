#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""label_tool — /tofugraph:label 의 결정적 절반.

서브에이전트(LLM)가 판단을 맡고, 이 도구는 그 앞뒤의 결정적 작업만 한다:
  pending : 아직 의미 이름표가 없는 관계(related_to/mentions)를 배치로 내보낸다
  apply   : 서브에이전트가 채운 JSONL(id,type[,confidence])을 검증 후 DB 에 기록한다
  status  : 이름표 분포(타입별 개수)를 보여준다

표준 라이브러리만 사용. DB 는 절대 새로 만들지 않는다(없으면 안내 후 종료).
쓰기는 baseline(related_to/mentions) 행만 대상 — 이미 붙은 의미 이름표는 덮지 않는다.
"""
import argparse, json, os, sqlite3, sys

# 엔진 TBox(graphrag_core.py DEFAULT_TBOX relation_types)와 동일해야 한다.
BASELINE = {"related_to", "mentions"}
SEMANTIC = {
    "belongs_to", "parent", "contains", "part_of", "references",
    "sourced_from", "derived_from", "supported_by", "aligns_with",
    "next", "prev", "supersedes", "co_occurs",
}
ALLOWED = BASELINE | SEMANTIC


def find_db(root: str | None) -> str:
    cands = []
    if root:
        cands.append(os.path.join(root, "index", "vault_graph.db"))
        cands.append(root)  # db 파일을 직접 준 경우
    d = os.getcwd()
    while True:
        cands.append(os.path.join(d, ".team-os", "graphrag", "index", "vault_graph.db"))
        nd = os.path.dirname(d)
        if nd == d:
            break
        d = nd
    for c in cands:
        if os.path.isfile(c) and c.endswith(".db"):
            return c
    sys.exit("[ERR] vault_graph.db 를 찾지 못했습니다 — 먼저 /tofugraph:build 로 인덱스를 만들거나 --root 로 경로를 지정하세요.")


def cmd_pending(db: str, limit: int, offset: int, as_json: bool) -> None:
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    rows = con.execute(
        """
        SELECT r.id, se.name, te.name, COALESCE(r.evidence_text,''), COALESCE(r.source_note,''), r.type
        FROM relationships r
        JOIN entities se ON se.id = r.source_id
        JOIN entities te ON te.id = r.target_id
        WHERE r.type IN ('related_to','mentions')
        ORDER BY r.id LIMIT ? OFFSET ?
        """,
        (limit, offset),
    ).fetchall()
    total = con.execute(
        "SELECT COUNT(*) FROM relationships WHERE type IN ('related_to','mentions')"
    ).fetchone()[0]
    con.close()
    out = [
        {"id": i, "source": s, "target": t, "evidence": ev[:300], "note": sn, "current": ty}
        for (i, s, t, ev, sn, ty) in rows
    ]
    if as_json:
        print(json.dumps({"total_pending": total, "offset": offset, "batch": out}, ensure_ascii=False, indent=1))
    else:
        print(f"# 이름표 대기 관계 {total}건 중 {offset}~{offset+len(out)}")
        for o in out:
            print(f"{o['id']}\t{o['source']} → {o['target']}\t[{o['current']}]\t{o['evidence'][:80]}")


def cmd_apply(db: str, path: str, dry: bool) -> None:
    rows = []
    with open(path, encoding="utf-8") as fh:
        for ln, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                sys.exit(f"[ERR] {path}:{ln} JSON 파싱 실패 — 한 줄에 하나의 JSON 객체(id,type)여야 합니다.")
            if d.get("type") not in ALLOWED:
                sys.exit(f"[ERR] {path}:{ln} 허용되지 않은 이름표 '{d.get('type')}' — 허용: {sorted(ALLOWED)}")
            rows.append((d["type"], float(d.get("confidence", 0.8)), d["id"]))
    if not rows:
        sys.exit("[ERR] 적용할 행이 없습니다.")
    con = sqlite3.connect(db)
    before = con.execute(
        "SELECT COUNT(*) FROM relationships WHERE type NOT IN ('related_to','mentions')"
    ).fetchone()[0]
    applied = skipped = 0
    for typ, conf, rid in rows:
        if typ in BASELINE:
            skipped += 1
            continue
        cur = con.execute(
            "UPDATE relationships SET type=?, confidence=? WHERE id=? AND type IN ('related_to','mentions')",
            (typ, conf, rid),
        )
        applied += cur.rowcount
        skipped += 0 if cur.rowcount else 1
    after = con.execute(
        "SELECT COUNT(*) FROM relationships WHERE type NOT IN ('related_to','mentions')"
    ).fetchone()[0]
    if dry:
        con.rollback()
    else:
        con.commit()
    con.close()
    mode = "DRY-RUN(미기록)" if dry else "기록 완료"
    print(f"[OK] {mode} — 적용 {applied} · 건너뜀 {skipped} · 의미 이름표 {before} → {after}")
    if not dry:
        print("     다음: /tofugraph:3d 로 이름표 붙은 그래프를 눈으로 확인하세요.")


def cmd_status(db: str) -> None:
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    total = con.execute("SELECT COUNT(*) FROM relationships").fetchone()[0]
    print(f"# 관계 총 {total}건 — 타입별 분포")
    for typ, n in con.execute(
        "SELECT type, COUNT(*) FROM relationships GROUP BY type ORDER BY COUNT(*) DESC"
    ):
        tag = "(기본)" if typ in BASELINE else "(의미)"
        print(f"  {typ:<14} {tag} {n}")
    con.close()


def main() -> None:
    ap = argparse.ArgumentParser(description="tofugraph 의미 이름표 도구")
    ap.add_argument("--root", help="graphrag 홈 또는 vault_graph.db 경로 (기본: 상위로 .team-os/graphrag 탐색)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("pending", help="이름표 대기 관계 배치 출력")
    p.add_argument("--limit", type=int, default=40)
    p.add_argument("--offset", type=int, default=0)
    p.add_argument("--json", action="store_true")
    a = sub.add_parser("apply", help="서브에이전트 산출 JSONL 적용")
    a.add_argument("file")
    a.add_argument("--dry-run", action="store_true")
    sub.add_parser("status", help="이름표 분포")
    args = ap.parse_args()
    db = find_db(args.root)
    if args.cmd == "pending":
        cmd_pending(db, args.limit, args.offset, args.json)
    elif args.cmd == "apply":
        cmd_apply(db, args.file, args.dry_run)
    else:
        cmd_status(db)


if __name__ == "__main__":
    main()
