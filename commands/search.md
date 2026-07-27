---
description: GraphRAG 검색 1회 — 동작 확인용 (서버가 떠 있어야 합니다)
allowed-tools: Bash, Read
---

# /tofugraph:search — 검색 1회

구축한 검색 엔진에 질문 하나를 던져 동작을 확인합니다.

## 사용

```
/tofugraph:search <질문>
```

## 실행 절차 (에이전트용)

1. 다음을 실행한다:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/graphrag-ops/tofugraph.sh" search "<질문>"
   ```
2. 결과를 사용자 눈높이로 요약한다 — 상위 결과 몇 건과 출처 노트만. 서버가 꺼져 있다는 오류면 `/tofugraph:doctor` 로 안내한다.
