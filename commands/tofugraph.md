---
description: GraphRAG 구축·검색·상태·수리 — knowledge-manager 그래프 위에 얹는 검색 엔진 운영
allowed-tools: Bash, Read
---

# /tofugraph — GraphRAG 구축·운영·수리

knowledge-manager로 그린 그래프(frontmatter + 위키링크) 위에 GraphRAG 검색을 얹고, 그 서버를 관리·수리합니다. 상세 명세: [skills/km-graphrag-ops.md](../skills/km-graphrag-ops.md).

## 사용

```
/tofugraph              → doctor (진단 + 처방 — 첫 실행이면 여기부터)
/tofugraph build        → 인덱스 구축 (필요 라이브러리 부족하면 안내 후 정지)
/tofugraph viz          → 3D 그래프 뷰어 생성 (단일 HTML — 서버 불필요, 브라우저로 바로 열기)
/tofugraph search <질문> → 검색 1회 (동작 확인)
/tofugraph status       → 상태 + 최근 24h 성능 요약
/tofugraph heal         → 1회성 수리 (이중 확인 후에만 재시작)
/tofugraph auto         → 자동 관리 켜기 (1시간마다 감시·자가치유 데몬, 해제: uninstall-daemon)
/tofugraph guard-set    → 의미 라벨 가드 기준선 재설정 (노트 삭제 등 의도적 감소 후에만)
/tofugraph bench init   → 검색 시험지 만들기 (질문 5개 + 정답 노트를 직접 채우는 양식)
/tofugraph bench run    → 시험지로 채점 (검색 상위 k 안에 정답 노트가 들었는지 — 적중률)
```

## 실행 절차 (에이전트용)

1. 인자를 파싱한다. 없으면 `doctor`.
2. `auto`는 `install-daemon`으로, `viz`는 아래 3D 뷰어 생성(별도 스크립트)으로, 나머지는 동사 그대로 매핑:
   ```bash
   bash scripts/graphrag-ops/tofugraph.sh <verb> [args]
   ```
   - `viz`: `python3 scripts/graph3d/export_data.py` 로 데이터를 추출하고 → `python3 scripts/graph3d/build_viewer.py` 로 단일 HTML(라이브러리·데이터 전부 내장 — 서버·네트워크 불필요)로 조립한 뒤, 생성된 파일 경로를 알려주고 더블클릭하거나 브라우저로 열도록 안내한다.
   - `bench`: `bench init` / `bench run [파일] [--top-k N]` 을 그대로 위임한다(다른 동사와 동일 패턴). 검색 품질을 **적중률(hit@k — 정답 노트가 검색 상위 k 안에 들었나)** 로 재는 기능이며, LLM 채점이 아니라 결정적 채점이라 외부 API 키가 필요 없다. `bench run` 은 `search` 와 같은 API 경로를 쓰므로 서버가 떠 있어야 하고, 꺼져 있으면 doctor·heal 로 유도하는 안내가 나온다.
3. 출력을 **사용자 눈높이로 요약**한다 — doctor의 [FAIL]/[WARN] 항목은 처방(fix: 줄)을 그대로 전달하고, 전부 [OK]면 "검색 시스템 정상" 한 줄이면 충분. (`viz`는 생성된 HTML 경로 + 여는 법 한 줄이면 충분.)
4. `build`가 라이브러리 부족을 보고하면 — **검색 엔진 자체는 이 플러그인에 동봉돼 있고**, 부족한 건 파이썬 라이브러리다 — 출력된 설치 명령을 사용자에게 그대로 보여주고 **실행 여부를 물어본다**. 특히 `sentence-transformers` 는 약 1GB(라이브러리 + AI 모델)를 내려받으므로 임의로 실행하지 않는다. 그래프 구축만 먼저 하려면 `build --skip-embeddings` 를 안내한다.
5. ⚠️ 경계: 디스크 부족·OS 업데이트류 [WARN]은 이 도구가 고치지 않는다 — 사용자에게 보고만 한다(자동 삭제·정리 금지).
