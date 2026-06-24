# toolytics

Claude Code 세션 트랜스크립트(`~/.claude/projects/**/*.jsonl`)에서 스킬·툴·토큰 사용량을 집계해
필터 가능한 self-contained 대시보드로 보여준다. 모든 프로젝트 통합, main 직접호출 vs 위임(agent) 구분.

## 빠른 시작
```sh
./build.sh               # 전체 스캔 → 누적 DB 갱신 → 대시보드 빌드 → 브라우저 오픈
./build.sh 7             # 기본 뷰를 최근 7일로 (데이터엔 전 기간 보존)
./build.sh --selfcheck   # 누적 병합·attribution 로직 회귀 가드
```
출력: `~/.toolytics/` (`TOOLYTICS_HOME`으로 변경). `history.csv`/`tokens.csv`/`injects.csv`(누적 DB) + `dashboard.html`.

## 플러그인으로 설치
```
/plugin marketplace add <레포경로>
/plugin install toolytics@toolytics
```
설치하면 `/toolytics`로 대시보드 빌드, SessionStart 훅이 매일 자동 수집 데몬을 self-install
(macOS launchd / Linux systemd·cron). 트랜스크립트 cleanup(기본 30일) 전에 모아둬 과거 집계를 지킨다.

## 환경변수
- `TOOLYTICS_HOME` — 출력 디렉터리 (기본 `~/.toolytics`)
- `TOOLYTICS_OPEN=0` — 브라우저 자동 오픈 스킵
- `TOOLYTICS_TRIM="a,b"` — 프로젝트 라벨에서 선두 경로 세그먼트 제거 (장식용)

자세한 설계·근거는 [AGENTS.md](AGENTS.md).
