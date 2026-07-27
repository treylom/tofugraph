# engine/ — 동봉 GraphRAG 엔진 출처

- **원본(source)**: 개발자 로컬의 라이브 운영 GraphRAG 서버 `.team-os/graphrag/scripts/` — 읽기 전용 참조이며 이 리포에서 원본을 수정하지 않는다 (구체 경로는 개인 환경이라 배포본에서 생략).
- **복사 시각(copied at)**: 2026-07-27 01:23:57 KST
- **동봉 파일 수**: **14** (`*.py` 12개 + `requirements.txt` + 이 문서)
  ```
  cli.py                 진입점 — tofugraph.sh 가 유일하게 직접 호출하는 파일
  graphrag_core.py       DB·스키마·FTS
  bootstrap.py           vault 스캔 → 그래프 초기 구축
  entity_extractor.py    노트 → 엔티티/관계 추출
  vault_filter.py        인덱싱 대상 파일 선별
  community_detector.py  커뮤니티 탐지
  embedding_index.py     임베딩 인덱스
  embedding_worker.py    임베딩 백그라운드 워커
  incremental.py         증분 갱신
  frontmatter_sync.py    DB ↔ frontmatter 동기화
  graph_search.py        검색 엔진
  search_server.py       검색 HTTP 서버
  ```
- **의도적 제외 — 벤치·운영 전용 9파일 (113,765B)**: `benchmark_runner.py`·`benchmark_judge.py`·`benchmark_scorer.py`·`batched_bench.py`·`answer_runner.py`·`answer_runner_codex.py`·`answer_judge.py`·`repair_search_quality.py`·`graphrag_maintenance.py`.
  **사유 2가지** — ① `tofugraph.sh` → `cli.py` 경로에서 **도달하지 않는다**(정적 import 분석 + 실제 로드 + build·bench 왕복 실행으로 3중 확인) ② 벤치 골드셋에 **개발자 개인 정보**(실명·개인 vault 노트 제목)가 데이터로 박혀 있어, 경로 중립화로는 지워지지 않는다. 안 쓰는 파일을 고쳐서 담기보다 **안 담는 쪽**이 맞다.
- **원본과 다른 점**: `requirements.txt` 에 `scipy>=1.11` 1줄 추가 — 없으면 `build` [2/5] 커뮤니티 탐지(`community_detector.py` → `networkx.pagerank`)가 `ModuleNotFoundError: scipy` 로 죽는다(실측 확인, 원본 저장소엔 이 의존이 누락돼 있었음 — 운영 환경엔 다른 경로로 이미 깔려 있어 지금까지 드러나지 않았다).
- **배포 대상에서 제외한 것**: `test_*.py`(테스트), `*.sh`(운영 전용 셸 스크립트), `goldset_v2.json`(벤치 데이터), `.gitignore` — 코드 464K 만 담고 인덱스·벤치마크·로그 등 데이터(3.9G)는 담지 않는다.
- 🔴 **의도적 제외 — `scripts/graph3d/**` (3D 뷰어 계열)**: 이 번들은 GraphRAG 엔진(`build`·`search`)만 담는다. `viewer_template.html`·`export_data.py`·`build_viewer.py` 는 **다른 경로**에 있고 여기 포함하지 않는다(실물 확인: `engine/` 안 일치 0건).
  **사유** — 2026-07-27 독립 검토(independent review) 판정: **Graph3D 포함 패키징·복사·배포 = NO-GO / REQUEST CHANGES.**
  ```
  build_viewer.py:65-68        소문자 "</script" 만 치환
                               Chrome 재현: 대문자 "</SCRIPT>" 가 종료 태그로 처리됨
  viewer_template.html         :327,331,353,495,515,550-552 가 DB 유래 문자열을 innerHTML 에
                               Chrome 재현: event-handler payload 실행됨
  라이브 DB 현 표본            엔티티 14,288 · 조회한 실행 관련 패턴 0건 · 꺾쇠 4건
                               조회 범위 = </script>·<script>·<img>·<svg>·단순 on…=
                               표시 무결성은 그 4건에서 이미 깨져 있다
                               ⚠️ "실행형 0" 이 아니다 — 그 밖의 payload 유형은 안 봤고,
                                  이 값은 2026-07-27 02:0x 시점값이다
  ```
  **수리 전제** = inline JSON 의 `<` 안전 인코딩 + 모든 동적 `innerHTML` → DOM API·`textContent` 전환.
  ⇒ **이 번들에 viz 를 추가하려면 먼저 그 수리 diff + 회귀 fixture 를 독립 검토에 올릴 것.** 실물이 0건인 것과 별개로 여기 적어둔다 — **실물 0건은 향후 포함을 기계적으로 차단하지 않는다**(제외가 암묵이면 대조할 문면조차 없다).
  ⚠️ **이 문서도 자동 게이트가 아니다** (독립 검토, 2026-07-27) — **문서화된 검토 조건**일 뿐 향후 포함을 기계적으로 차단하지 않는다. 세 칸 중 두 칸만 찼다:
  ```
  실물 0건      ✅  현재 engine/ 안 일치 0
  문서 명시     ✅  이 항목
  자동 차단     ❌  Graph3D 포함 시 실패시키는 자동 검사는 확인되지 않았다
  ```
  ⚠️ 위 세 칸은 **확인된 상태**만 적는다 — 문서의 예방효과(사람이 이걸 읽고 멈추는가)는 **미측정**이며, 여기에 그 예측을 적지 않는다.
- **근거**: 번들 실현 가능성 실측 조사(개발자 내부 문서 — 번들 부담·막히는 지점 3곳·판단·반영 설계). 배포본에는 경로를 싣지 않는다.

## 갱신 방법

원본(`.team-os/graphrag/scripts/`)이 바뀌면 위 12개 `*.py` + `requirements.txt` 를 다시 복사하고, 아래 3가지를 확인한 뒤 이 파일의 복사 시각을 갱신한다.

1. `requirements.txt` 에 `scipy>=1.11` 줄이 남아있는가
2. **개인 경로·실명이 다시 들어오지 않았는가** — 원본에는 개발자 환경 경로와 검토자 이름이 주석·기본값으로 들어 있다. 복사 후 반드시 재점검한다:
   ```
   grep -rnE '/Users/|/mnt/c/|사람이름|내부문서경로' engine/
   ```
   기본값은 **환경변수·인자로 받게** 바꾸고, 없으면 처방을 출력하며 실패시킨다(침묵 기본값 ❌).
   ⚠️ 단 게이트는 **진입점 `cli.py` 한 곳**에만 둔다 — 라이브러리 모듈에 로드 시점 `raise` 를 박으면 `--vault` 인자가 파싱되기도 전에 죽어서 `build` 전체가 실패한다(실측으로 확인된 함정).
3. 위 **제외 9파일이 다시 딸려오지 않았는가** — 특히 벤치 계열은 개인 정보를 데이터로 갖고 있다.

### 재검증 방법
`build` 는 1회차·2회차를 **모두** 돌려야 한다(2회차에서만 드러나는 회귀가 있다). `bench init` → `bench run` 도 1회. 정적 분석만으로 "도달 안 함"을 판정하지 말 것 — 실행 왕복이 그 위의 증거다.
