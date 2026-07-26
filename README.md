# tofugraph

Obsidian vault 의 지식 그래프(frontmatter + 위키링크) 위에 GraphRAG 검색을 얹고, 그 서버를 구축·운영·수리하는 Claude Code 플러그인입니다.

## 설치

```
/plugin marketplace add treylom/tofukyung-plugins
/plugin install tofugraph@tofukyung-plugins
```

## 사용

```
/tofugraph              → doctor (진단 + 처방 — 첫 실행이면 여기부터)
/tofugraph build        → 인덱스 구축 (엔진 미설치면 설치 안내)
/tofugraph search <질문> → 검색 1회 (동작 확인)
/tofugraph status       → 상태 + 최근 24h 성능 요약
/tofugraph heal         → 1회성 수리 (이중 확인 후에만 재시작)
/tofugraph auto         → 자동 관리 켜기 (1시간마다 감시·자가치유 데몬)
```

상세 명세는 [skills/km-graphrag-ops.md](skills/km-graphrag-ops.md) 를 참조하세요. 검색 엔진 본체는 [ThisCode](https://github.com/treylom/ThisCode) 의 GraphRAG 설치 스크립트를 사용합니다 (플러그인이 안내합니다).

## License

MIT
