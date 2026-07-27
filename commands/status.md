---
description: 검색 시스템 상태 + 최근 24시간 성능 요약
allowed-tools: Bash, Read
---

# /tofugraph:status — 상태 요약

## 실행 절차 (에이전트용)

1. 다음을 실행한다:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/graphrag-ops/tofugraph.sh" status
   ```
2. 출력을 사용자 눈높이로 요약한다 — 정상이면 한 줄, 이상 항목은 처방과 함께.
