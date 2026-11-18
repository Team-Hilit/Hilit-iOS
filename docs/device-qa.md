# 실기기 QA

시뮬레이터로 못 보는 흐름(강제 종료·백그라운드·실녹화·컨테이너 확인)을 실기기에서 확인하는 도구 두 가지.

| 도구 | 하는 일 | 실행 |
|---|---|---|
| `Tools/DeviceQA/device-qa.sh` | 테스트 프로세스 밖 조작 — 설치·실행·SIGKILL·스크린샷·앱 컨테이너 수집 | `make device-qa cmd=<명령>` |
| `HilitUITests` (`Projects/App/UITests/`) | 앱 안 조작 — XCUITest 시나리오. 공용 동작은 `Support/DeviceActions.swift` | `make uitest device='<기기 이름>'` |

결과는 `.device-qa/<시각>/` (gitignore). UI 테스트 스크린샷은 xcresult 첨부.

## device-qa.sh 명령

`DEVICE=<udid|이름>` 를 안 주면 연결된 실기기 하나를 고른다. 시뮬레이터는 UDID 로 준다. 기본 번들은 `com.hilit.app.dev` (`BUNDLE=` 로 변경).

- `devices` · `install <app>` · `launch` · `kill` · `shot [이름]`
- `pull [이름]` — tmp·Application Support·Preferences 수집 후 `interview-*` 파일·원장·held 세션 요약
- `force-kill` — 녹화 중 강제 종료 → 수집 → 재실행·재개 → 수집 (HLT-78). 면접 조작은 사람이 한다
- `lock` · `unlock [--force]` · `status` — 기기 잠금 (아래)

## 기기 잠금

기기 하나를 여러 세션(worktree)이 동시에 쓰면 같은 번들을 서로 덮어 설치하고 컨테이너·로그인 상태가 섞인다. 그래서 실기기는 한 번에 한 브랜치만 쓴다.

- 기기를 쓰는 명령과 `make uitest`(실기기)가 잠금을 자동으로 잡는다. 주인은 현재 브랜치다.
- 다른 브랜치가 쥐고 있으면 `기기 사용 중: <브랜치>` 로 멈춘다.
- 끝나면 `make device-qa cmd=unlock` 으로 반납한다. 주인이 사라진 잠금만 `unlock --force` 로 푼다.
- 잠금 위치는 `/tmp/hilit-device-qa.lock` (`DEVICE_QA_LOCK` 로 변경). 시뮬레이터는 잠그지 않는다.
