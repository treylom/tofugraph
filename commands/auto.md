---
description: 자동 관리 켜기 — 1시간마다 감시·자가치유 데몬 (해제: uninstall-daemon)
allowed-tools: Bash, Read
---

# /tofugraph:auto — 자동 관리

1시간마다 검색 시스템을 감시하고 스스로 고치는 데몬을 켭니다.

## 실행 절차 (에이전트용)

1. 다음을 실행한다:
   ```bash
   bash scripts/graphrag-ops/tofugraph.sh install-daemon
   ```
2. 해제를 원하면 `uninstall-daemon` 을 안내한다. 켜기 전에 사용자에게 "1시간마다 자동으로 도는 관리 장치"임을 한 줄로 알리고 진행한다.
