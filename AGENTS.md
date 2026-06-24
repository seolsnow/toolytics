# toolytics — 클로드코드 사용량 대시보드

## 목적
내 Claude Code 세션 트랜스크립트에서 스킬·툴 사용량을 집계해 필터링 가능한 대시보드로 보여준다. (모든 프로젝트 통합, 최근 N일)

## 작업 방식 / 컨텍스트
- **데이터 소스**: `~/.claude/projects/**/*.jsonl` (전체 재귀). Claude Code가 모든 대화를 줄단위 JSON으로 남긴 로그. 줄별 `timestamp` 필드로 윈도우 필터.
- **두 레이어 구분** — 핵심:
  - `main` = 메인 세션에서 내가 직접 호출 (≈4.6k건)
  - `agent` = 내가 띄운 서브에이전트/워크플로가 대신 호출. 경로에 `/subagents/` 포함. 리서치 위임이라 Read·WebFetch·WebSearch 위주. **전체의 약 2/3** (≈8.7k건) — 빠뜨리기 쉬움.
- **tidy 테이블 스키마**: `date, triggered_by(main|agent), project, tool, count`. Skill 호출은 `tool` 에 `skill:<이름>` 으로, MCP 는 `mcp__server__method` 원문 유지.
- **재현/빌드**: `./build.sh [VIEW_DAYS]` (기본 30) → 전체 스캔 → 누적 DB 갱신 → 대시보드 빌드 → 브라우저 자동 오픈.
  - 출력 위치: `~/.toolytics/` (env `TOOLYTICS_HOME` 으로 변경). `history.csv`(누적 DB) + `dashboard.html`(데이터 인라인 self-contained).
  - 테스트 시 `TOOLYTICS_OPEN=0` 으로 브라우저 오픈 스킵.
  - 대시보드 템플릿은 이 폴더 `dashboard.template.html`, `/*__DATA__*/` 자리에 JSON 주입.
- **누적 전략 (핵심)**: 스캔은 시간 윈도우 없이 디스크에 있는 모든 jsonl 을 읽음. 세 누적 DB(`history.csv`/`tokens.csv`/`injects.csv`) 전부 **날짜 단위 replace** 로 병합 — 스캔이 커버한 날짜는 행 통째 교체(=재실행해도 안 불어남, idempotent), 스캔이 못 본 옛 날짜는 보존. 그래서 로그가 로테이션/삭제돼도 과거 집계가 남고 계속 쌓임. 대시보드 기본 뷰만 최근 `VIEW_DAYS` 로 잘라 보여주고 데이터엔 전 기간 들어있음(`default_from` 주입).
- **자동 수집 데몬 (cleanup 방어)**: `build.sh`는 실행할 때만 도니까 30일 넘게 대시보드를 안 열면 Claude Code 트랜스크립트 cleanup(기본 `cleanupPeriodDays` 30일)이 원본 jsonl을 지워 그 구간이 누적 CSV에 박히기도 전에 영영 유실됨(누적 전략은 "스캔이 한 번이라도 그 날짜를 잡았을 때"만 보존). → `install-daemon.sh`가 OS별 사용자 스케줄러로 매일 1회 `TOOLYTICS_OPEN=0 build.sh`를 돌려 cleanup 전 수집을 보장: macOS=launchd LaunchAgent, Linux=systemd `--user` 타이머(`Persistent=true`), systemd 없으면 cron. **plist/유닛은 설치 시점에 생성** — 빌드경로·PATH·홈 전부 `$HOME`·`command -v python3`·스크립트 자기 위치에서 derived(박힌 문자열 0, inject attribution과 같은 self-configuring 철학). 멱등이라 재실행=bootout→bootstrap refresh; `ensure` 서브커맨드는 이미 깔렸으면 no-op(self-heal). 플러그인이 이걸 SessionStart 훅에서 `install-daemon.sh ensure`로 호출 → 설치 후 첫 세션 1회 등록, 이후 데몬이 Claude Code와 무관하게 자율 실행. macOS는 라이브 검증(exit 0), **Linux 분기는 표준 패턴이나 이 머신에선 미검증**. 로그 `~/.toolytics/scheduler.log`.
- **재스캔 시간**: 전체 콜드 스캔 ~3s (현재 ~1700 파일). ponytail 주석대로 느려지면 mtime 증분으로 전환.
- **스킬 로스터**: 디스크 인벤토리(`~/.claude/skills`+`plugins`) ∪ 전체 히스토리에서 쓴 스킬 → 0회 스킬도 항상 표시(`DATA.skill_inv`). 클라에서 `SKILL_UNIVERSE`로 고정, 카운트만 필터창에서. user/plugin 토글(콜론 유무, 맨이름은 user 우선).
- **토큰·비용**(`DATA.tokens`, `tokens.csv`): 줄별 `message.usage`(input/output/cache_read/cache_creation의 5m·1h)를 `(date,by,project,model)` 로 집계. 모델은 정규화(`claude-opus-4-8`→`opus-4-8` 등). 비용 = 토큰 × 리스트가(입력/출력 + 캐시읽기 0.1× / 캐시쓰기 5m 1.25× · 1h 2×). **가격표는 `build.sh` 의 `PRICE` dict에 박혀있음(2026-06 기준) — Anthropic이 바꾸면 거기 한 줄 고친다**(ponytail 캘리브레이션 노브). 미등록 모델(`<synthetic>` 등)은 비용 0, 토큰은 그대로 표시. `build.sh` 가 누적 후 추정 API value 합계를 echo. (대시보드 Spend 섹션은 제거됨 — 토큰 수집·`tokens.csv`·비용 집계는 유지.)
- **자동주입 실측**(`DATA.injects`): 트랜스크립트 `attachment.type=hook_success` + `hookEvent=SessionStart` 만 셈(superpowers는 `hook_additional_context` 중복도 찍지만 그건 스킵 → 1발동 1행). 빈 출력 훅은 애초에 안 찍혀 security-guidance처럼 안 도는 건 자동 제외. → Skills 최상단에 핀(자체 스케일).
  - **attribution이 portable의 핵심**: 로그의 `command` 는 `${CLAUDE_PLUGIN_ROOT}` **미확장**으로 찍히고, 훅에 `statusMessage` 가 있으면 command 대신 그 문자열이 찍힘 — 둘 다 플러그인명을 안 담음. 그래서 **하드코딩 금지**, 매 빌드 디스크에서 역매핑: `~/.claude/plugins/**/hooks.json`(플러그인명=경로) + `~/.claude/settings*.json`(SessionStart 훅의 command·statusMessage)를 스캔해 `{로그 command 문자열 → 라벨}` 맵을 만들고 로그 command를 **정확매칭**, 미매칭은 cleaned 폴백. → 남 환경 어떤 플러그인이든 self-configuring (검증: superpowers/watch/ponytail/karpathy-skills 전부 클린 해석). `inject`/`status` 구분은 portable 못해 폐기(전부 inject).
  - injects는 이제 `injects.csv` 에 **history.csv와 같은 날짜-replace 누적** → 로그 로테이션돼도 과거 inject 보존.
- **scanned_dates 의미**: "디스크에 그 날짜의 줄이 하나라도 있으면" 스캔이 그 날짜에 대해 authoritative(=tool/token/inject 3테이블 모두 그 날짜 행 통째 교체). 전엔 "assistant content 있는 날"로 잘못 게이팅 → tool_use 0인 날의 과거 history가 조용히 지워질 수 있었음(수정함). 타임스탬프 있는 모든 줄에서 `scanned_dates.add(d)`.
- **self-check**: `./build.sh --selfcheck` — replace-by-date 병합(idempotent·로테이션 보존·커버한 빈 날짜 클리어)과 inject 역매핑(command·statusMessage 정확매칭)을 assert로 검증(5건). 비자명 로직의 회귀 가드.
- **프로젝트 라벨**: 기본은 홈 상대경로(`hsc/rain/foo`). 개인 관습 하드코딩(`hsc/` trim) 제거 → 배포 안전. 줄이고 싶으면 `TOOLYTICS_TRIM="hsc,work"`(콤마구분 선두 세그먼트) env로만. 충돌 우려도 이걸로 사라짐.
- **남은 미수정(저영향, 의도적 보류)**: 스킬 leaf basename 충돌(동명 user/plugin 카운트 합쳐짐) — 드물고 잘 고치려면 fiddly해서 보류.
- **대시보드 UI**: 전 섹션 20개/페이지 페이지네이션(다중페이지일 때만 20행 패딩), 막대 heat-ramp, `text-transform:uppercase` 절대 금지(케이스 원본 유지 — [[feedback_no_forced_case]]).
- **대시보드 필터**: triggered_by(All/Direct/Delegated) · project · 날짜범위(native date input) · tool 검색. 전부 클라이언트 JS 재집계. heat-ramp 막대(값 클수록 hot orange).
- 아티팩트 URL: https://claude.ai/code/artifact/f680d4ec-5c2c-4590-8ee5-6fb5af7cd0fa

## 산출물
- `build.sh` — 스캔→누적→빌드→오픈 파이프라인 (재사용).
- `dashboard.template.html` — 대시보드 템플릿 (데이터 자리 비어있음, 소스)
- `install-daemon.sh` — OS별 매일 수집 스케줄러 설치기 (macOS launchd / Linux systemd·cron, 동적 생성·멱등; `install` | `ensure` | `--remove`).
- `.claude-plugin/plugin.json` — `toolytics` 플러그인 매니페스트.
- `.claude-plugin/marketplace.json` — 로컬 설치용 마켓플레이스 (이 레포 자체가 플러그인, `source: "./"`). 설치: `/plugin marketplace add <레포경로>` → `toolytics@toolytics`.
- `hooks/hooks.json` — SessionStart self-install 가드 (`install-daemon.sh ensure` 호출 → 데몬 자동 등록).
- (생성물, `~/.toolytics/`) `history.csv` — 툴 누적 DB (date,triggered_by,project,tool,count)
- (생성물, `~/.toolytics/`) `tokens.csv` — 토큰 누적 DB (date,triggered_by,project,model,input,output,cache_read,cw5m,cw1h)
- (생성물, `~/.toolytics/`) `injects.csv` — 자동주입 누적 DB (date,triggered_by,project,source,count)
- (생성물, `~/.toolytics/`) `dashboard.html` — 데이터 인라인 self-contained 대시보드
- (생성물, `~/.toolytics/`) `scheduler.log` — 자동 수집 데몬 실행 로그
