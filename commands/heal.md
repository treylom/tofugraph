---
description: 검색 시스템 1회성 수리 — 이중 확인 후에만 재시작
allowed-tools: Bash, Read
---

# /tofugraph:heal — 1회성 수리

## 실행 절차 (에이전트용)

1. 다음을 실행한다:
   ```bash
   bash scripts/graphrag-ops/tofugraph.sh heal
   ```
2. 재시작이 필요한 경우 도구가 이중 확인을 요구한다 — 사용자에게 그대로 물어보고 확인 후에만 진행한다.
3. ⚠️ 경계: 디스크 부족·OS 업데이트류 [WARN]은 이 도구가 고치지 않는다 — 사용자에게 보고만 한다(자동 삭제·정리 금지). 링크가 깨진 것은 수리 대상이 아니다 — `/tofugraph:links` 의 처방대로 노트를 고친다.
