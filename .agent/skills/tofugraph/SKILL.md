---
name: tofugraph
description: GraphRAG 명령 안내 — 기능별 스킬은 $tofugraph-links, $tofugraph-doctor, $tofugraph-build 등으로 분리
---

# $tofugraph (Codex용 래퍼 — 정본 절차는 플러그인의 commands/tofugraph.md)

이 스킬은 Claude Code 명령 `/tofugraph:tofugraph` 의 Codex 판입니다. 절차 본문은 한 곳(정본)만 둡니다:

1. **플러그인 루트 계산**: 이 SKILL.md 가 있는 폴더에서 **세 단계 위**가 플러그인 루트다.
   ```bash
   PLUGIN_ROOT="$(cd "$(dirname '<이 SKILL.md 의 절대경로>')/../../.." && pwd)"
   ```
   (`$PLUGIN_ROOT/commands/tofugraph.md` 와 `$PLUGIN_ROOT/scripts/` 가 실제로 존재하는지 `ls` 로 1회 확인 후 진행.)
2. **정본 절차 실행**: `$PLUGIN_ROOT/commands/tofugraph.md` 를 Read 하고 그 절차를 그대로 따른다. 단 Codex 환경 번역 규칙:
   - 문서 속 `${CLAUDE_PLUGIN_ROOT}` 는 전부 위 `$PLUGIN_ROOT` 로 바꿔 읽는다.
   - 문서 속 `/tofugraph:<x>` 명령 표기는 Codex 에서는 `$tofugraph-<x>` 스킬을 뜻한다.
   - 서브에이전트 스폰 지시는 Codex 의 서브에이전트 기능(collab/spawn)으로 수행하고, 없으면 같은 대화에서 순차 처리한다.
