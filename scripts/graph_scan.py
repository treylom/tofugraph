#!/usr/bin/env python3
"""tofugraph tier-0 (engine: obsidian) — vault link-graph scanner.

의존 0: 표준 라이브러리만. GraphRAG 서버·임베딩·Obsidian 설치 불요.
vault 의 md 파일 자체를 그래프(위키링크·백링크·frontmatter aliases)로 읽어
status(통계 요약) / doctor(진단 6종 + 처방) 를 출력한다.

  D1 깨진 링크        [[target]] 해석 실패(파일명·경로·aliases 대조)
  D2 고아 노트        인바운드 링크 0
  D3 데드엔드 노트    아웃바운드 링크 0
  D4 허브 편중        인바운드 분포 top 허브 + 지니계수
  D5 frontmatter 위생 YAML 휴리스틱(비종결 ---, BOM, 탭 들여쓰기, 무콜론 행 등 raw-render 원인)
  D6 참조 변형        [[n#heading]]·[[n^block]] 의 대상 노트 내 섹션/블록 부재

v1 비스코프: 외부 md 링크 [t](url)·태그 그래프·dataview 인라인.
"""
import argparse
import json
import os
import re
import sys
import time
import unicodedata
from collections import defaultdict

# Windows 콘솔(cp949 등) 한글 출력 크래시 방지 — 수령자 환경 호환 (Python 3.7+)
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except (AttributeError, OSError):
    pass

SCHEMA_VERSION = 1
DEFAULT_EXCLUDE_PREFIXES = ("_archive",)
DEFAULT_EXCLUDE_NAMES = {".obsidian", ".trash", "templates"}

FENCE_RE = re.compile(r"^(```|~~~)")
INLINE_CODE_RE = re.compile(r"`[^`]*`")
LINK_RE = re.compile(r"(!?)\[\[([^\[\]\n]+?)\]\]")
HEADING_RE = re.compile(r"^#{1,6}\s+(.*)$")
BLOCK_ID_RE = re.compile(r"\^([A-Za-z0-9-]+)\s*$")
MD_EXTS = {".md"}


def nfc(s):
    return unicodedata.normalize("NFC", s)


def norm_key(s):
    return nfc(s).casefold()


def is_excluded_dir(name, extra_excludes):
    if name.startswith("."):
        return True
    if name in DEFAULT_EXCLUDE_NAMES or name in extra_excludes:
        return True
    return any(name.startswith(p) for p in DEFAULT_EXCLUDE_PREFIXES)


def walk_vault(root, extra_excludes):
    md_files, asset_files = [], []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if not is_excluded_dir(d, extra_excludes)]
        for fn in filenames:
            if fn.startswith("."):
                continue
            rel = os.path.relpath(os.path.join(dirpath, fn), root)
            if os.path.splitext(fn)[1].lower() in MD_EXTS:
                md_files.append(rel)
            else:
                asset_files.append(rel)
    return md_files, asset_files


def split_target(raw):
    """'note#Head^blk|display' → (base, heading, block). base 는 파일 지칭부만."""
    base = raw.split("|", 1)[0].strip()
    heading = block = None
    if "^" in base:
        base, block = base.split("^", 1)
        block = block.strip()
    if "#" in base:
        base, heading = base.split("#", 1)
        heading = heading.strip()
    return base.strip(), heading, block


def parse_frontmatter(text):
    """휴리스틱 YAML 위생 점검 + aliases 추출. 반환 (aliases, issues).

    표준 라이브러리엔 YAML 파서가 없어 완전 파싱 대신 Obsidian raw-render 를
    일으키는 실측 원인 패턴을 점검한다(설계 §1 D5 — 정직한 근사, 완전성 주장 ❌).
    """
    issues, aliases = [], []
    if text.startswith("﻿"):
        if text.lstrip("﻿").startswith("---"):
            issues.append("BOM before frontmatter (raw-render cause)")
        text = text.lstrip("﻿")
    lines = text.split("\n")
    if not lines or not lines[0].startswith("---"):
        return aliases, issues
    if lines[0].rstrip() != "---" or lines[0] != lines[0].rstrip():
        issues.append("opening delimiter not exactly '---' (trailing chars/space)")
    close = None
    for i in range(1, len(lines)):
        if lines[i].strip() in ("---", "..."):
            close = i
            break
    if close is None:
        issues.append("unclosed frontmatter (no closing '---')")
        return aliases, issues
    fm = lines[1:close]
    in_aliases = False
    for ln in fm:
        if ln.startswith("\t"):
            issues.append("tab indentation in YAML")
        stripped = ln.strip()
        if not stripped or stripped.startswith("#"):
            in_aliases = False
            continue
        top_level = not ln.startswith((" ", "\t"))
        if top_level:
            in_aliases = False
            if ":" not in stripped and not stripped.startswith("- "):
                issues.append(f"invalid YAML line (no key): {stripped[:48]}")
                continue
            key = stripped.split(":", 1)[0].strip().lower()
            if key in ("aliases", "alias"):
                rest = stripped.split(":", 1)[1].strip()
                if rest.startswith("[") and rest.endswith("]"):
                    aliases += [a.strip().strip("'\"") for a in rest[1:-1].split(",") if a.strip()]
                elif rest:
                    aliases.append(rest.strip("'\""))
                else:
                    in_aliases = True
        elif in_aliases and stripped.startswith("- "):
            aliases.append(stripped[2:].strip().strip("'\""))
    return [a for a in aliases if a], issues


def strip_code(text):
    out, fenced = [], False
    for ln in text.split("\n"):
        if FENCE_RE.match(ln.strip()):
            fenced = not fenced
            out.append("")
            continue
        out.append("" if fenced else INLINE_CODE_RE.sub("", ln))
    return "\n".join(out)


def gini(values):
    vals = sorted(v for v in values if v >= 0)
    n, total = len(vals), sum(vals)
    if n == 0 or total == 0:
        return 0.0
    cum = sum((2 * (i + 1) - n - 1) * v for i, v in enumerate(vals))
    return round(cum / (n * total), 3)


class VaultGraph:
    def __init__(self, root, extra_excludes=()):
        self.root = os.path.abspath(root)
        self.extra_excludes = set(extra_excludes)
        self.notes = {}          # rel → {'aliases','fm_issues','links','headings','blocks'}
        self.name_index = defaultdict(list)   # basename key → [rel]
        self.path_index = {}                  # relpath-no-ext key → rel
        self.alias_index = {}                 # alias key → rel
        self.asset_index = defaultdict(list)  # asset basename key → [rel]
        self.inbound = defaultdict(set)
        self.scan_seconds = 0.0

    def build(self):
        t0 = time.time()
        md_files, asset_files = walk_vault(self.root, self.extra_excludes)
        for rel in asset_files:
            self.asset_index[norm_key(os.path.basename(rel))].append(rel)
        for rel in md_files:
            try:
                with open(os.path.join(self.root, rel), encoding="utf-8", errors="replace") as f:
                    text = f.read()
            except OSError as e:
                self.notes[nfc(rel)] = {"aliases": [], "fm_issues": [f"unreadable: {e}"],
                                        "links": [], "headings": set(), "blocks": set()}
                continue
            aliases, fm_issues = parse_frontmatter(text)
            body = strip_code(text)
            links = []
            for m in LINK_RE.finditer(body):
                base, heading, block = split_target(m.group(2))
                links.append({"embed": m.group(1) == "!", "base": base,
                              "heading": heading, "block": block, "raw": m.group(2)})
            headings = {norm_key(h.group(1).strip()) for ln in body.split("\n") if (h := HEADING_RE.match(ln))}
            blocks = {b for ln in text.split("\n") if (bm := BLOCK_ID_RE.search(ln)) for b in [bm.group(1)]}
            rel_n = nfc(rel)
            self.notes[rel_n] = {"aliases": aliases, "fm_issues": fm_issues,
                                 "links": links, "headings": headings, "blocks": blocks}
            noext = os.path.splitext(rel_n)[0]
            self.name_index[norm_key(os.path.basename(noext))].append(rel_n)
            self.path_index[norm_key(noext)] = rel_n
            for a in aliases:
                self.alias_index.setdefault(norm_key(a), rel_n)
        self._resolve()
        self.scan_seconds = round(time.time() - t0, 2)

    def _resolve(self):
        for rel, note in self.notes.items():
            for link in note["links"]:
                base = link["base"]
                if not base:  # [[#heading]] 자기 참조
                    link["resolved"] = rel
                    continue
                target = self._lookup(base)
                link["resolved"] = target
                if target and target != rel:
                    self.inbound[target].add(rel)

    def _lookup(self, base):
        # 노트 해석 우선 — 파일명 속 점('GPT-5.2-…')을 확장자로 오인하지 않도록
        # splitext 선판정 ❌. 노트 실패 시에만 에셋(embed) fallback.
        key = norm_key(base)
        if key.endswith(".md"):
            key = key[:-3]
        if key in self.path_index:
            return self.path_index[key]
        hits = self.name_index.get(norm_key(os.path.basename(key)))
        if hits:
            return hits[0]
        if key in self.alias_index:
            return self.alias_index[key]
        if "." in os.path.basename(base):  # 에셋 embed (img.png 등)
            hits = self.asset_index.get(norm_key(os.path.basename(base)))
            return hits[0] if hits else None
        return None

    # ── 진단 6종 ──────────────────────────────────────────────
    def diagnostics(self):
        d1, d6 = [], []
        for rel, note in self.notes.items():
            for link in note["links"]:
                if link["base"] and link["resolved"] is None:
                    d1.append({"note": rel, "target": link["raw"]})
                    continue
                tgt = link["resolved"]
                if tgt and tgt in self.notes:
                    if link["heading"] and norm_key(link["heading"]) not in self.notes[tgt]["headings"]:
                        d6.append({"note": rel, "target": link["raw"], "kind": "heading"})
                    if link["block"] and link["block"] not in self.notes[tgt]["blocks"]:
                        d6.append({"note": rel, "target": link["raw"], "kind": "block"})
        d2 = sorted(r for r in self.notes if not self.inbound.get(r))
        d3 = sorted(r for r, n in self.notes.items()
                    if not any(l["resolved"] and l["resolved"] != r for l in n["links"]))
        deg = {r: len(self.inbound.get(r, ())) for r in self.notes}
        top = sorted(deg.items(), key=lambda kv: -kv[1])[:10]
        d4 = {"gini_inbound": gini(deg.values()),
              "top_hubs": [{"note": r, "inbound": c} for r, c in top if c > 0]}
        d5 = [{"note": r, "issues": n["fm_issues"]} for r, n in sorted(self.notes.items()) if n["fm_issues"]]
        return {"d1_broken_links": d1, "d2_orphans": d2, "d3_deadends": d3,
                "d4_hub_concentration": d4, "d5_frontmatter": d5, "d6_ref_variants": d6}

    def stats(self):
        total_links = sum(len(n["links"]) for n in self.notes.values())
        resolved = sum(1 for n in self.notes.values() for l in n["links"] if l["resolved"])
        deg = [len(self.inbound.get(r, ())) for r in self.notes]
        n_notes = len(self.notes) or 1
        return {"notes": len(self.notes),
                "assets": sum(len(v) for v in self.asset_index.values()),
                "links_total": total_links, "links_resolved": resolved,
                "links_broken": total_links - resolved
                                - sum(1 for n in self.notes.values() for l in n["links"] if not l["base"] and not l["resolved"]),
                "avg_inbound": round(sum(deg) / n_notes, 2),
                "orphan_ratio": round(sum(1 for d in deg if d == 0) / n_notes, 3),
                "scan_seconds": self.scan_seconds}


PRESCRIPTIONS = {
    "d1_broken_links": "대상 노트를 생성하거나 링크 철자를 고치세요(파일명·aliases 대조 실패).",
    "d2_orphans": "MOC/관련 노트에서 이 노트로 링크를 걸어주세요(권장 인바운드 1+).",
    "d3_deadends": "본문에 관련 노트 위키링크를 추가하세요(아웃바운드 0 = 그래프 막다른 길).",
    "d4_hub_concentration": "허브 1개 과집중이면 중간 MOC 분할을 검토하세요(임계는 참고용 기본값).",
    "d5_frontmatter": "해당 파일의 frontmatter 를 고치세요 — Obsidian 에서 속성이 raw 텍스트로 보이는 원인입니다.",
    "d6_ref_variants": "대상 노트는 있으나 그 섹션/블록이 없습니다 — 헤딩 개명 잔재를 갱신하세요.",
}


def render_report(vault, stats, diags, doctor):
    out = [f"# tofugraph tier-0 {'doctor' if doctor else 'status'} — {vault}", ""]
    out.append(f"- 노트 {stats['notes']} · 에셋 {stats['assets']} · 링크 {stats['links_total']}"
               f" (해석 {stats['links_resolved']} / 깨짐 {stats['links_broken']})")
    out.append(f"- 평균 인바운드 {stats['avg_inbound']} · 고아 비율 {stats['orphan_ratio']:.1%}"
               f" · 지니(인바운드) {diags['d4_hub_concentration']['gini_inbound']}"
               f" · 스캔 {stats['scan_seconds']}s")
    hubs = diags["d4_hub_concentration"]["top_hubs"][:5]
    if hubs:
        out.append("- top 허브: " + ", ".join(f"{h['note']}({h['inbound']})" for h in hubs))
    if not doctor:
        return "\n".join(out)
    out.append("")
    labels = {"d1_broken_links": "D1 깨진 링크", "d2_orphans": "D2 고아 노트",
              "d3_deadends": "D3 데드엔드", "d5_frontmatter": "D5 frontmatter 위생",
              "d6_ref_variants": "D6 참조 변형"}
    for key, label in labels.items():
        items = diags[key]
        out.append(f"## {label} — {len(items)}건")
        if items:
            out.append(f"> 처방: {PRESCRIPTIONS[key]}")
            for it in items[:10]:
                if isinstance(it, str):
                    out.append(f"- {it}")
                elif key == "d5_frontmatter":
                    out.append(f"- {it['note']}: {'; '.join(it['issues'])}")
                else:
                    out.append(f"- {it['note']} → [[{it['target']}]]" + (f" ({it['kind']})" if "kind" in it else ""))
            if len(items) > 10:
                out.append(f"- … 외 {len(items) - 10}건 (--json 으로 전체)")
        out.append("")
    d4 = diags["d4_hub_concentration"]
    out.append(f"## D4 허브 편중 — 지니 {d4['gini_inbound']}")
    out.append(f"> 처방: {PRESCRIPTIONS['d4_hub_concentration']}")
    return "\n".join(out)


def main(argv=None):
    ap = argparse.ArgumentParser(description="tofugraph tier-0 vault graph scanner (의존 0)")
    ap.add_argument("command", choices=["status", "doctor"])
    ap.add_argument("vault", help="vault 루트 경로")
    ap.add_argument("--json", action="store_true", help="기계용 JSON 출력")
    ap.add_argument("--exclude", action="append", default=[], help="추가 제외 폴더명(반복 가능)")
    ap.add_argument("--proof-class", default="live-scan", help="산출 proof_class 라벨")
    args = ap.parse_args(argv)
    if not os.path.isdir(args.vault):
        print(f"error: vault 경로 아님: {args.vault}", file=sys.stderr)
        return 2
    g = VaultGraph(args.vault, args.exclude)
    g.build()
    stats, diags = g.stats(), g.diagnostics()
    if args.json:
        payload = {"schema_version": SCHEMA_VERSION, "proof_class": args.proof_class,
                   "command": args.command, "vault": os.path.abspath(args.vault),
                   "stats": stats}
        if args.command == "doctor":
            payload["diagnostics"] = diags
        else:
            payload["d4_hub_concentration"] = diags["d4_hub_concentration"]
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(render_report(args.vault, stats, diags, args.command == "doctor"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
