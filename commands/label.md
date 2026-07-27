---
description: 의미 이름표 실습 — 서브에이전트를 여러 개 스폰해 창고의 관계 전체에 의미 이름표(belongs_to·part_of 등 13종)를 붙입니다
allowed-tools: Bash, Read, Task
---

# /tofugraph:label — 서브에이전트로 의미 이름표 붙이기

`/tofugraph:build` 가 만든 그래프의 연결선(관계)은 처음엔 대부분 "관련 있음(related_to)·언급함(mentions)"이라는 **밋밋한 기본 이름표**만 달고 있습니다. 이 명령은 **AI 서브에이전트 여러 개를 동시에 스폰**해 각 연결이 실제로 어떤 관계인지 읽고 **의미 이름표 13종** 중 하나를 붙입니다 — 실제 운영 그래프를 만들 때 쓰는 방식 그대로입니다.

허용 이름표(엔진 내장 규격과 동일 — 이 밖의 이름표는 도구가 거부합니다):
`belongs_to`(소속) · `parent`(상위) · `contains`(포함) · `part_of`(부분) · `references`(참조) · `sourced_from`(출처) · `derived_from`(파생) · `supported_by`(근거) · `aligns_with`(궤 같음) · `next`/`prev`(순서) · `supersedes`(대체) · `co_occurs`(동시 등장)

## 실행 절차 (에이전트용)

1. **대기 물량 확인**: `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/label_tool.py" status` → `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/label_tool.py" pending --json --limit 40` 으로 이름표 대기 관계를 확인한다. 대기 0건이면 "이미 전부 붙어 있습니다" 로 종료. DB 가 없으면 `/tofugraph:build` 먼저 안내.
2. **배치 분할 + 서브에이전트 스폰**: 대기 관계를 배치(기본 40건)로 나눠 **배치당 서브에이전트 1개**를 병렬 스폰한다(총 대기가 많으면 사용자에게 규모·예상 시간을 먼저 알리고 진행 여부를 묻는다 — 수백 건이면 몇 분 걸린다). **⚠️ 스폰 전 서브에이전트 모델을 가벼운 모델로 지정한다** — 이름표 분류는 큰 모델이 필요 없는 작업이라, 기본(비싼) 모델 그대로 돌리면 토큰만 낭비된다: Claude 계열이면 **Sonnet**, GPT/Codex 계열이면 **luna(xhigh) 급 경량 모델**. 단 **지정은 폴백 사다리로, 중단 사유가 아니다** — 지금 환경의 서브에이전트 설정에 그 별칭이 없으면 ① 그 환경이 제공하는 다른 경량 모델 → ② 그것도 없으면 기본 모델 그대로 진행한다(품질은 무관, 비용만 차이 — 모델 별칭이 없다고 label 실행을 멈추지 말 것). 각 서브에이전트에게 배치 JSON(출발 노트·도착 노트·근거 문장)을 주고 다음을 지시한다:
   - 각 관계마다 근거 문장(evidence)과 두 노트 이름을 읽고 위 13종 중 가장 맞는 이름표 하나를 고른다. 확신이 없으면(0.5 미만) 그 행은 건너뛴다 — 억지로 붙이지 않는다.
   - 산출 = JSONL 한 줄에 `{"id": "...", "type": "...", "confidence": 0.0~1.0}`.
3. **검증 후 기록**: 서브에이전트 산출을 한 파일로 모아 `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/label_tool.py" apply <파일> --dry-run` 으로 먼저 검증(허용 밖 이름표는 여기서 걸린다)하고, 통과하면 `--dry-run` 없이 실제 기록한다. 도구가 "의미 이름표 N → M" 전후 수치를 보여준다.
4. **눈으로 확인**: 끝나면 `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/label_tool.py" status` 분포를 요약해 주고, `/tofugraph:3d` 를 실행해 이름표 붙은 그래프를 바로 띄워 보여준다.
5. ⚠️ 경계: 이 명령은 관계의 **이름표만** 바꾼다 — 노트 본문·frontmatter 는 건드리지 않는다. 이미 붙은 의미 이름표는 덮어쓰지 않는다(도구가 차단).
