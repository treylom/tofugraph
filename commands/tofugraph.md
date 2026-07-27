---
description: GraphRAG 명령 안내 — 기능별 명령은 /tofugraph:links, /tofugraph:doctor, /tofugraph:build 등으로 분리
allowed-tools: Bash, Read
---

# /tofugraph — 명령 안내

knowledge-manager로 그린 그래프(frontmatter + 위키링크) 위에 GraphRAG 검색을 얹고, 그 서버를 관리·수리하는 플러그인입니다. **기능은 각각의 명령으로 나뉘어 있습니다** — 이 명령은 안내판입니다. 상세 명세: [skills/km-graphrag-ops.md](../skills/km-graphrag-ops.md).

> ⚠️ **점검이 두 종류입니다 — 헷갈리기 쉬우니 먼저 구분하세요.**
> · `/tofugraph:links` = **창고(vault) 링크 건강검진** — 노트끼리 잘 연결됐나. 설치·서버 없이 몇 초. **처음이면 여기부터.**
> · `/tofugraph:doctor` = **검색 시스템 점검** — 검색 엔진이 살아있나. 서버가 떠 있어야 의미가 있습니다. **검색이 안 될 때.**

```
/tofugraph:links [경로]   → 창고 링크 건강검진 (설치·서버 불필요 — 깨진 링크·외톨이 노트 등 6종)
/tofugraph:doctor        → 검색 시스템 점검 (진단 + 처방 — 검색이 안 될 때 여기부터)
/tofugraph:build         → 인덱스 구축 (필요 라이브러리 부족하면 안내 후 정지)
/tofugraph:3d            → 3D 그래프 뷰어 생성 (단일 HTML — 서버 불필요, 브라우저로 바로 열기)
/tofugraph:search <질문>  → 검색 1회 (동작 확인)
/tofugraph:status        → 상태 + 최근 24h 성능 요약
/tofugraph:heal          → 1회성 수리 (이중 확인 후에만 재시작)
/tofugraph:auto          → 자동 관리 켜기 (1시간마다 감시·자가치유 데몬, 해제: uninstall-daemon)
/tofugraph:bench init    → 검색 시험지 만들기 (질문 5개 + 정답 노트를 직접 채우는 양식)
/tofugraph:bench run     → 시험지로 채점 (검색 상위 k 안에 정답 노트가 들었는지 — 적중률)
```

## 실행 절차 (에이전트용)

1. **인자 없이 호출되면 아무것도 실행하지 않는다** — 위 명령 목록을 사용자 눈높이로 보여주고, 처음이면 `/tofugraph:links` 부터 안내한다.
2. **하위호환**: `/tofugraph <동사>` 형태(구 표기)로 인자가 들어오면 해당 기능의 명령 문서(commands/<동사>.md — `viz`는 `3d`, `guard-set`은 아래 3)와 동일하게 실행해 준다. 단 응답 끝에 "다음부터는 `/tofugraph:<동사>` 로 부르시면 됩니다" 한 줄을 덧붙인다.
3. `guard-set`(의미 라벨 가드 기준선 재설정 — 노트 삭제 등 의도적 감소 후에만)은 `bash scripts/graphrag-ops/tofugraph.sh guard-set` 으로 위임한다.
