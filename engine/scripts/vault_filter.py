"""Vault file filter — central exclude rule for archive/duplicate dirs.

Single source of truth for `vault.rglob("*.md")` filtering across the
GraphRAG ingest pipeline. Edit `EXCLUDE_DIRS` / `EXCLUDE_PREFIXES` here
to change actual ingest behavior in every script.

Why centralized:
- bootstrap.py / entity_extractor.py / embedding_index.py /
  frontmatter_sync.py / incremental.py / repair_search_quality.py all
  walked the vault separately; some had drift (frontmatter_sync,
  incremental had no exclude rule at all). Drift caused archive
  duplicates in the entity index.
- 개발 과정의 vault path 중복 정리 사이클에서 도출된 규칙이다.
"""
from __future__ import annotations

import os
from pathlib import Path
from typing import Iterable

# Exact directory names to exclude (any depth).
# 여기 있는 것은 **어느 vault 에서나 노트가 아닌 것**만이다 — 앱 설정·휴지통·클라우드
# 임시파일·패키지 정크. 사용자의 실제 노트 폴더 이름은 절대 넣지 않는다.
EXCLUDE_DIRS = {
    ".obsidian",                # Obsidian app config
    ".trash",
    ".tmp.drivedownload",       # 클라우드 동기화 임시파일
    ".tmp.driveupload",
    # build/venv 정크 (어디 depth든) — venv LICENSE/패키지 md 가 노트로 오색인되던 노이즈 차단
    ".venv",
    "node_modules",
    "site-packages",
}

# 내 vault 에만 있는 중복 사본·미러 폴더를 추가로 빼고 싶을 때 지정한다(쉼표 구분).
#   예) export GRAPHRAG_EXCLUDE_DIRS="Archive-old,vault-backup"
# ⚠️ 개발자 환경 전용 폴더 이름을 이 파일에 직접 박지 말 것 — 같은 이름을 실제 노트
#    폴더로 쓰는 사용자의 노트가 아무 경고 없이 인덱스에서 사라진다.
EXCLUDE_DIRS |= {
    d.strip() for d in os.environ.get("GRAPHRAG_EXCLUDE_DIRS", "").split(",") if d.strip()
}

# Directory name prefixes to exclude (e.g. "_archive-2026-04",
# "_archive_per_session_20260412_002123", "_attachments")
EXCLUDE_PREFIXES = (
    "_archive",
    "_attachments",
)


def is_excluded_path(rel_parts: Iterable[str]) -> bool:
    """True if any path part matches an exclude rule (set or prefix)."""
    for part in rel_parts:
        if part in EXCLUDE_DIRS:
            return True
        if any(part.startswith(prefix) for prefix in EXCLUDE_PREFIXES):
            return True
    return False


def filter_md_files(md_files: Iterable[Path], vault: Path) -> list[Path]:
    """Filter list of .md Path objects, excluding archive/duplicate dirs
    and unresolvable entries (broken symlinks)."""
    out: list[Path] = []
    for f in md_files:
        try:
            rel = f.relative_to(vault)
        except ValueError:
            continue
        if is_excluded_path(rel.parts):
            continue
        # The vault is a symlink farm (Obsidian /search exposure); rglob yields
        # dangling symlinks by name. Skip anything that doesn't resolve so a
        # single broken link can't abort a consumer's whole index build.
        try:
            if not f.exists():
                continue
        except OSError:
            continue
        out.append(f)
    return out


# Filename substrings marking a content-duplicate copy. Pair-safe: dropped ONLY
# when the canonical twin (same name without the marker) is also present.
DUP_FILENAME_MARKERS = (" (zet-version)",)


def _drop_dup_twins(files: list[Path], vault: Path) -> list[Path]:
    """Set-based dedup pass applied AFTER dir/prefix filtering.

    두 규칙 모두 safe-by-construction — 고유한 노트는 절대 떨어뜨리지 않는다:
      (a) "(zet-version)" 파일명 사본은 마커 없는 쌍둥이가 남아있을 때만 제외.
      (b) 미러 폴더 사본은 바깥에 같은 상대경로 노트가 있을 때만 제외.
          미러 폴더 안에만 있는 노트는 그대로 남는다.

    (b)는 기본 비활성이다. vault 안에 다른 폴더를 통째로 복사한 미러가 있어서
    같은 노트가 두 번 색인될 때만 그 폴더 이름을 지정한다:
        export GRAPHRAG_MIRROR_DIR="MyMirrorFolder"
    ⚠️ 개발자 vault 의 폴더 이름을 여기 박아두면, 같은 이름을 쓰는 사용자의 노트가
       조용히 사라진다. 그래서 상수가 아니라 설정으로 받는다.
    """
    mirror = os.environ.get("GRAPHRAG_MIRROR_DIR", "").strip().strip("/")
    rel = {str(f.relative_to(vault)): f for f in files}
    relset = set(rel)
    out: list[Path] = []
    for r, f in rel.items():
        # (a) zet-version pair-safe drop
        if any(m in r and r.replace(m, "") in relset for m in DUP_FILENAME_MARKERS):
            continue
        # (b) 미러 폴더 사본 제외 — 바깥에 쌍둥이가 있을 때만
        if mirror and r.startswith(mirror + "/") and r[len(mirror) + 1:] in relset:
            continue
        out.append(f)
    return out


def walk_vault_md(vault: Path) -> list[Path]:
    """Walk vault for .md files with exclude rule applied. Most common entry point."""
    return _drop_dup_twins(filter_md_files(vault.rglob("*.md"), vault), vault)
