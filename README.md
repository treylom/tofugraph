# tofugraph

Obsidian vault 의 지식 그래프(frontmatter + 위키링크) 위에 GraphRAG 검색을 얹고, 그 서버를 구축·운영·수리하는 Claude Code 플러그인입니다.

## 설치

```
/plugin marketplace add treylom/tofukyung-plugins
/plugin install tofugraph@tofukyung-plugins
```

검색 엔진(그래프 구축·검색 코드)이 플러그인에 **함께 들어있어** **엔진을 따로 설치할 필요 없이** 바로 `build` 를 실행하면 됩니다. `build` 실행 시 무엇이 부족한지·어떻게 채울지 그 자리에서 안내합니다.

> **⚠️ 검색까지 쓰시려면 한 가지를 더 설치하세요.**
> 그래프 구축(`build`)은 의미 검색 라이브러리 없이도 할 수 있습니다 — 다만 그냥 `build` 를 실행하면 **일단 멈추고 두 가지 방법을 알려줍니다**(임베딩 없이 진행하는 `build --skip-embeddings`, 또는 아래 설치). 반면 **검색을 실제로 쓰려면 `sentence-transformers` 가 필요합니다** — 서버 자체는 정상적으로 켜지지만, 켜진 뒤 임베딩 모델(문장을 숫자로 바꿔 뜻이 비슷한 글까지 찾게 해주는 부품)을 준비하는 단계에서 멈춰서 **검색 요청이 "준비 중"으로 계속 거절됩니다**. 서버가 켜져 있으니 겉보기엔 정상이라 오히려 더 헷갈리는 상태입니다.
> ```
> pip install sentence-transformers
> ```
> 약 1GB(라이브러리 + AI 모델)를 내려받습니다. 그래프 구축만 하고 검색은 나중에 쓰실 거라면 그때 설치하셔도 됩니다.

## 사용

```
/tofugraph:links [경로]   → 창고 링크 건강검진 (설치·서버 불필요 — 처음이면 여기부터. 깨진 링크·외톨이 노트 등 6종 + 처방)
/tofugraph:doctor        → 검색 시스템 점검 (진단 + 처방 — 검색이 안 될 때)
/tofugraph:build         → 인덱스 구축 (필요 라이브러리 부족하면 안내 후 정지)
/tofugraph:3d            → 3D 그래프 뷰어 생성 (단일 HTML — 서버 불필요, 브라우저로 바로 열기)
/tofugraph:search <질문>  → 검색 1회 (동작 확인)
/tofugraph:status        → 상태 + 최근 24h 성능 요약
/tofugraph:heal          → 1회성 수리 (이중 확인 후에만 재시작)
/tofugraph:auto          → 자동 관리 켜기 (1시간마다 감시·자가치유 데몬)
/tofugraph:bench init    → 검색 시험지 만들기 (질문 5개 + 정답 노트를 직접 채우는 양식)
/tofugraph:bench run     → 시험지로 채점 (정답 노트가 검색 상위 5위 안에 들었는지 — 적중률)
/tofugraph               → 명령 안내판 (무엇이 있는지 보여주기만 합니다)
```

`bench` 는 **내 vault 에서 내 검색이 얼마나 잘 찾는지**를 스스로 재보는 기능입니다. 질문과 정답 노트를 직접 적어 넣으면, 각 질문을 검색해서 정답이 상위 몇 위에 나오는지 표로 보여줍니다. 채점은 AI 가 아니라 정해진 규칙으로 하므로 **외부 API 키가 필요 없고**, 같은 시험지로 다시 돌리면 같은 결과가 나옵니다.

상세 명세는 [skills/km-graphrag-ops.md](skills/km-graphrag-ops.md) 를 참조하세요. 검색 엔진 코드는 이 플러그인에 동봉되어 있으며, 이미 [ThisCode](https://github.com/treylom/ThisCode) 로 GraphRAG 를 설치해 둔 환경이면 그 설치본을 우선 사용합니다.

## License

MIT
