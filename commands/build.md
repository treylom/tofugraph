---
description: GraphRAG 인덱스 구축 — 필요 라이브러리 부족하면 안내 후 정지 (1GB 다운로드는 반드시 사용자 확인)
allowed-tools: Bash, Read
---

# /tofugraph:build — 인덱스 구축

knowledge-manager로 그린 그래프(frontmatter + 위키링크) 위에 GraphRAG 검색 인덱스를 만듭니다.

## 실행 절차 (에이전트용)

1. 다음을 실행한다:
   ```bash
   bash scripts/graphrag-ops/tofugraph.sh build
   ```
2. 라이브러리 부족을 보고하면 — **검색 엔진 자체는 이 플러그인에 동봉돼 있고**, 부족한 건 파이썬 라이브러리다 — 출력된 설치 명령을 사용자에게 그대로 보여주고 **실행 여부를 물어본다**. 특히 `sentence-transformers` 는 약 1GB(라이브러리 + AI 모델)를 내려받으므로 임의로 실행하지 않는다. 그래프 구축만 먼저 하려면 `build --skip-embeddings` 를 안내한다.
3. 출력을 사용자 눈높이로 요약한다. 구축이 성공하면 서버 기동 안내(출력에 표시됨)를 그대로 전달한다.
4. ⚠️ 경계: 디스크 부족·OS 업데이트류 [WARN]은 이 도구가 고치지 않는다 — 사용자에게 보고만 한다(자동 삭제·정리 금지).
