#!/usr/bin/env python3
"""tofugraph viz — GraphRAG 3D 데이터 추출: index/vault_graph.db(read-only) → graph3d-data.json
Ported from the working prototype (agent-faker/graph3d-server/export_data.py). Logic is
unchanged: source_note 경로(p) · 타임라인 시각(t = vault 파일 mtime, 폴백 = 파일명 날짜) ·
BFS 인접(전 관계) — and the two-layer edge design is preserved exactly:
  - displayed links (sem)  = semantic relations only (GENERIC filtered out)
  - traversal adjacency (adj_pairs) = ALL relations, for pathfinding/BFS in the viewer
Do not tune GENERIC here — that's deferred pending a re-index (see plugin README).

Path resolution (3-tier, no path defaults survive from the original prototype):
  --db/--vault/--out CLI args > env (TOFUGRAPH_DB/TOFUGRAPH_VAULT/TOFUGRAPH_OUT) > default
  default db    = <found .team-os/graphrag root, walking up from cwd>/index/vault_graph.db
                  (falls back to ./.team-os/graphrag/index/vault_graph.db if not found)
  default vault = $PWD (best-effort — pass --vault explicitly for real note mtimes/paths)
  default out   = $PWD/graph3d-data.json
"""
import argparse, sqlite3, json, os, re, datetime
from collections import defaultdict

GENERIC = {"related_to", "mentions"}
DATE_RE = re.compile(r"(20\d{2}-\d{2}-\d{2})")


def find_graphrag_root(start=None):
    """Walk up from `start` (default cwd) looking for a .team-os/graphrag dir —
    mirrors scripts/graphrag-ops/tofugraph.sh's resolve_root()."""
    d = os.path.abspath(start or os.getcwd())
    while True:
        candidate = os.path.join(d, ".team-os", "graphrag")
        if os.path.isdir(candidate):
            return candidate
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def resolve_db(cli_val):
    if cli_val:
        return cli_val
    if os.environ.get("TOFUGRAPH_DB"):
        return os.environ["TOFUGRAPH_DB"]
    root = find_graphrag_root()
    if root:
        return os.path.join(root, "index", "vault_graph.db")
    return os.path.join(os.getcwd(), ".team-os", "graphrag", "index", "vault_graph.db")


def resolve_vault(cli_val):
    if cli_val:
        return cli_val
    if os.environ.get("TOFUGRAPH_VAULT"):
        return os.environ["TOFUGRAPH_VAULT"]
    return os.getcwd()


def resolve_out(cli_val):
    if cli_val:
        return cli_val
    if os.environ.get("TOFUGRAPH_OUT"):
        return os.environ["TOFUGRAPH_OUT"]
    return os.path.join(os.getcwd(), "graph3d-data.json")


def build_basename_index(vault):
    idx = {}
    for root, dirs, files in os.walk(vault):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for f in files:
            if f.endswith(".md") and f not in idx:
                idx[f] = os.path.join(root, f)
    return idx


def note_time(source_note, vault, bidx):
    """mtime 우선, 폴백 = 파일명 날짜 prefix, 최후 None"""
    if not source_note:
        return None
    full = os.path.join(vault, source_note)
    if not os.path.isfile(full):
        full = bidx.get(os.path.basename(source_note), "")
    if full and os.path.isfile(full):
        return int(os.path.getmtime(full))
    m = DATE_RE.search(os.path.basename(source_note))
    if m:
        try:
            return int(datetime.datetime.strptime(m.group(1), "%Y-%m-%d").timestamp())
        except ValueError:
            return None
    return None


def export(db_path, vault, out_path):
    if not os.path.isfile(db_path):
        raise FileNotFoundError(
            f"GraphRAG index db not found: {db_path}\n"
            f"  fix: pass --db <path>, set TOFUGRAPH_DB, or run from inside a repo with .team-os/graphrag/"
        )
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=10)
    cur = conn.cursor()
    deg = defaultdict(int)
    edges_all = cur.execute("SELECT source_id, target_id, type, confidence FROM relationships").fetchall()
    for s, t, ty, cf in edges_all:
        deg[s] += 1; deg[t] += 1
    ents = {r[0]: (r[1], r[2], r[3], r[4]) for r in cur.execute(
        "SELECT id, name, name_ko, community_id, source_note FROM entities")}
    # pre-flight: FTS drift. A stale entities_fts means /tofugraph search misses notes
    # that the graph itself knows about — measured live on WSL: 14,048 fts rows vs
    # 13,732 entities = 319 ghosts + 3 missing (a plain count diff hides direction:
    # the two errors cancel and show 316). Report the counts, prescribe `sync`.
    n_ent = cur.execute("SELECT COUNT(*) FROM entities").fetchone()[0]
    try:
        n_fts = cur.execute("SELECT COUNT(*) FROM entities_fts").fetchone()[0]
    except sqlite3.OperationalError:
        n_fts = None
    conn.close()

    bidx = build_basename_index(vault)
    # displayed links = semantic relations only (generic filtered out)
    sem = [(s, t, ty, cf) for s, t, ty, cf in edges_all if ty not in GENERIC and s in ents and t in ents]
    b_ids = sorted({s for s, t, _, _ in sem} | {t for s, t, _, _ in sem}, key=lambda n: -deg[n])
    idx = {nid: i for i, nid in enumerate(b_ids)}

    comm = defaultdict(int)
    unassigned = 0
    for nid in b_ids:
        cid = ents[nid][2]
        if cid:
            comm[cid] += 1
        else:
            unassigned += 1
    # NO top-N cap here. The prototype carried `[:40]`, which silently dumped every
    # 41st-and-smaller community into g=0 — and the viewer paints g=0 grey. Measured
    # on the live Mac index: 2,072 / 7,718 nodes (26.9%) were grey with a *fully
    # covered* graph (DB community_id unassigned = 0), because the 41st community
    # still had 64 members — there is no meaningful boundary at 40. Two bots read
    # that grey mass as "GraphRAG community coverage 72.7%"; the coverage was 100%
    # and the ceiling was this line. The viewer has no ceiling of its own: commColor()
    # falls through to golden-angle hsl() past the 13-entry palette, and renderLegend()
    # already slices to 13 chips, so lifting this changes neither colour nor layout.
    cmap = {c: i + 1 for i, c in enumerate([c for c, _ in sorted(comm.items(), key=lambda x: -x[1])])}

    nodes = []
    for nid in b_ids:
        name, name_ko, cid, snote = ents[nid]
        nodes.append({
            "i": idx[nid], "n": (name_ko or name)[:48], "g": cmap.get(cid, 0),
            "d": deg[nid], "p": snote or "", "t": note_time(snote, vault, bidx),
        })
    links = [{"s": idx[s], "t": idx[t], "y": ty, "c": round(cf or .5, 2)} for s, t, ty, cf in sem]

    # traversal adjacency = ALL relations (51K+) among viewB nodes — flat pair array,
    # used by the viewer's BFS pathfinder (kept separate from the displayed `links`)
    adj_pairs = []
    bset = set(b_ids)
    seen = set()
    for s, t, ty, cf in edges_all:
        if s in bset and t in bset:
            key = (idx[s], idx[t]) if idx[s] < idx[t] else (idx[t], idx[s])
            if key not in seen:
                seen.add(key)
                adj_pairs.extend(key)

    # 개념 카드(t 없음) = 이웃 최소 시각 상속 (첫 언급 노트 시점 등장 — 3라운드 전파)
    nbr = defaultdict(list)
    for k in range(0, len(adj_pairs), 2):
        a, b = adj_pairs[k], adj_pairs[k + 1]
        nbr[a].append(b); nbr[b].append(a)
    direct = sum(1 for n in nodes if n["t"])
    for _ in range(3):
        changed = 0
        for n in nodes:
            if not n["t"]:
                ts = [nodes[m]["t"] for m in nbr[n["i"]] if nodes[m]["t"]]
                if ts:
                    n["t"] = min(ts); changed += 1
        if not changed:
            break

    # 마을 라벨 = 그 마을에서 연결 가장 많은 카드 이름 (LLM 요약 부재 — 대표 노드로 정직 라벨)
    best = {}
    for n in nodes:
        g = n["g"]
        if g and (g not in best or n["d"] > best[g][1]):
            best[g] = (n["n"], n["d"])
    comm_labels = {str(g): v[0][:22] for g, v in best.items()}

    t_cov = sum(1 for n in nodes if n["t"])
    out = {
        "nodes": nodes, "links": links, "adj": adj_pairs,
        "meta": {
            "generated_kst": datetime.datetime.now().strftime("%Y-%m-%d %H:%M"),
            "t_coverage": f"{t_cov}/{len(nodes)}", "t_direct": direct,
            # basename of the resolved --vault path, used by the viewer's "Obsidian
            # 에서 열기" deep-link (obsidian://open?vault=<name>). No hardcoded
            # personal vault name survives here — derive from whatever was passed.
            "vault_name": os.path.basename(os.path.normpath(vault)) or vault,
            "comm_labels": comm_labels,
            # diagnostics — every community now gets a colour, so `unassigned` counts
            # only nodes the DB itself left without a community_id (grey in the viewer).
            "comm_total": len(cmap),
            "unassigned": unassigned,
            "fts": {"entities": n_ent, "entities_fts": n_fts},
        },
    }
    tmp = out_path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(out, f, ensure_ascii=False, separators=(",", ":"))
    os.replace(tmp, out_path)
    return out["meta"]


def main():
    ap = argparse.ArgumentParser(description="tofugraph viz — export GraphRAG data for the 3D viewer")
    ap.add_argument("--db", default=None, help="path to vault_graph.db (default: env TOFUGRAPH_DB, else auto-detect)")
    ap.add_argument("--vault", default=None, help="Obsidian vault root, for note mtimes/paths (default: env TOFUGRAPH_VAULT, else $PWD)")
    ap.add_argument("--out", default=None, help="output json path (default: env TOFUGRAPH_OUT, else ./graph3d-data.json)")
    args = ap.parse_args()

    db_path = resolve_db(args.db)
    vault = resolve_vault(args.vault)
    out_path = resolve_out(args.out)

    meta = export(db_path, vault, out_path)

    # pre-flight advisories → stderr, so stdout stays a clean single JSON line.
    # These describe the *index*, not the export: the export no longer truncates.
    import sys
    n_nodes = int(meta["t_coverage"].split("/")[1])
    if meta["unassigned"] == n_nodes:
        print(f"[tofugraph viz] 경고: {n_nodes}개 노드 전부 마을 미배정 — 그리면 전면 회색입니다.\n"
              f"  원인: 마을 탐지(community detection)가 아직 안 돌았습니다.\n"
              f"  처방: /tofugraph build  (bootstrap 만으로는 부족 — communities 단계까지 필요)",
              file=sys.stderr)
    elif meta["unassigned"]:
        pct = 100.0 * meta["unassigned"] / n_nodes
        print(f"[tofugraph viz] 참고: {meta['unassigned']}/{n_nodes} ({pct:.1f}%) 노드가 마을 미배정 → 회색으로 그려집니다.",
              file=sys.stderr)
    f = meta["fts"]
    if f["entities_fts"] is None:
        print("[tofugraph viz] 참고: entities_fts 테이블이 없습니다 — 검색이 안 될 수 있습니다 (/tofugraph doctor).",
              file=sys.stderr)
    elif f["entities_fts"] != f["entities"]:
        print(f"[tofugraph viz] 경고: 검색 색인이 그래프와 어긋납니다 — entities {f['entities']} vs entities_fts {f['entities_fts']}.\n"
              f"  3D 그리기에는 지장 없지만 /tofugraph search 가 일부 노트를 못 찾습니다.\n"
              f"  처방: /tofugraph heal  (또는 인덱스 sync 단계 재실행)", file=sys.stderr)

    print(json.dumps({"out": out_path, "db": db_path, "vault": vault, **meta}, ensure_ascii=False))


if __name__ == "__main__":
    main()
