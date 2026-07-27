---
description: 내 검색 품질 채점 — bench init(시험지 만들기) / bench run(적중률 채점, API 키 불필요)
allowed-tools: Bash, Read
---

# /tofugraph:bench — 검색 품질 채점

**내 창고에서 내 검색이 얼마나 잘 찾는지**를 스스로 재보는 기능입니다. 검색 품질을 **적중률(hit@k — 정답 노트가 검색 상위 k 안에 들었나)** 로 재며, LLM 채점이 아니라 결정적 채점이라 **외부 API 키가 필요 없습니다.**

## 사용

```
/tofugraph:bench init              → 검색 시험지 만들기 (질문 5개 + 정답 노트를 직접 채우는 양식)
/tofugraph:bench run [파일] [--top-k N] → 시험지로 채점 (적중률 표)
```

## 실행 절차 (에이전트용)

1. `bench init` / `bench run [파일] [--top-k N]` 을 그대로 위임한다:
   ```bash
   bash scripts/graphrag-ops/tofugraph.sh bench <init|run> [args]
   ```
2. `bench run` 은 `search` 와 같은 API 경로를 쓰므로 서버가 떠 있어야 하고, 꺼져 있으면 `/tofugraph:doctor` · `/tofugraph:heal` 로 유도하는 안내가 나온다 — 그대로 전달한다.
3. 결과 표는 질문별 적중 순위와 전체 적중률만 눈높이로 요약한다.
