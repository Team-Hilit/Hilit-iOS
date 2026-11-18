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

## 시나리오 나누기 (브랜치 간 충돌 방지)

이슈 브랜치 여러 개가 동시에 시나리오를 늘려도 서로 같은 줄을 건드리지 않게 나눈다.

- **파일**: 자기 이슈 폴더에만 추가한다 — `Projects/App/UITests/Issue<번호>/`. 클래스는 `Issue<번호>UITests` 하나 — 파일을 나누려면 `extension` 으로 붙인다(`only=` 가 클래스 이름 정확히 일치로 고른다).
- **공용 코드**: `UITests/Support/`(`DeviceActions`·`UIQuery`·`SystemAlert`) 는 dev 에서만 고친다. 필요한 헬퍼는 자기 폴더에 `private` 로 두거나 dev 에 먼저 넣고 머지해 받는다.
- **식별자**: `accessibilityIdentifier` 는 자기 Feature 화면에만 단다. 값은 `<feature>.<화면>.<요소>` (예: `interview.overlay.resume`). DesignSystem 공용 컴포넌트에는 달지 않는다.
- **실행**: `make uitest device=<이름> only=Issue160UITests` — 자기 것만 돌린다. 케이스 하나만은 `only=Issue160UITests/testXxx`. 이슈마다 클래스가 달라 dev 에 다 모여도 그대로 쓴다.
- 새 파일을 추가한 뒤에는 `tuist generate` 를 다시 돌린다.
