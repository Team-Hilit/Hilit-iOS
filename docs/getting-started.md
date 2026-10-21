# 첫 빌드 세팅 가이드

clone 직후 **처음 빌드까지** 그대로 따라 하면 되는 문서. (아키텍처 설명은 [`README.md`](../README.md), 팀 규칙은 [`CONTRIBUTING.md`](../CONTRIBUTING.md), 도메인 지식은 [`lat.md/`](../lat.md) 참고)

> 핵심: `.xcworkspace`/`.xcodeproj` 는 **커밋되지 않습니다.** Tuist 생성물이라 clone 후 직접 만들어야 합니다.

---

## 0. 전제 (한 번만)

| 도구 | 용도 | 설치 |
|---|---|---|
| Xcode 26+ (iOS 26 SDK 이상) | iOS 17.0+ | App Store |
| Homebrew | 패키지 매니저 | https://brew.sh |
| **Tuist 4.x** | 프로젝트 생성 (필수) | `mise install` (권장 — 루트 `.mise.toml` 의 버전 핀 사용) 또는 `brew install --cask tuist` (핀보다 낮은 버전이면 `brew upgrade --cask tuist`) |
| **SwiftLint** | 빌드 시 자동 린트 (없으면 경고만, 빌드는 됨) | `brew install swiftlint` |
| ripgrep | `make lat` 검색 가속 (선택) | `brew install ripgrep` |

```bash
brew install --cask tuist
brew install swiftlint
brew install ripgrep        # 선택
```

---

## 1. 최초 셋업 (clone 직후)

```bash
git clone https://github.com/YAPP-Github/28th-App-Team-1-iOS.git
cd 28th-App-Team-1-iOS

# 1) 외부 의존(SPM) 해석 — ComposableArchitecture 등
tuist install

# 2) Xcode 워크스페이스/프로젝트 생성
tuist generate
```

`make generate` 한 줄로 위 두 명령을 한 번에 돌릴 수도 있습니다.

생성이 끝나면 `Hilit.xcworkspace` 가 만들어지고 자동으로 Xcode 가 열립니다. (안 열리면 `open Hilit.xcworkspace`)

### 카카오 로그인 키 설정 (로그인 화면을 실제로 띄우려면 필수)

```bash
cp Projects/App/Config/Secrets.xcconfig.template Projects/App/Config/Secrets.xcconfig
```

카카오 개발자 콘솔(https://developers.kakao.com) > 내 애플리케이션 > 앱 키 > **Native 앱 키**를 발급받아 `Secrets.xcconfig`의 `KAKAO_NATIVE_APP_KEY =` 뒤에 채워 넣습니다. (`Secrets.xcconfig`는 gitignore 대상 — 커밋되지 않습니다)

키가 비어있으면 **Dev 는 빌드 경고**만 내고(카카오 로그인 시도 시 `AppSecrets` 의 `assertionFailure`), **QA/Release 는 빌드가 실패**합니다 — `KakaoKeyGuard` 빌드 페이즈가 빈 키로 배포 빌드가 나가는 걸 차단합니다.

같은 파일의 `CHOTTULINK_API_KEY` 는 유니버설 링크(지인 피드백)용이며 **비워둬도 됩니다** — 없으면 deferred 진입(재설치 후 첫 실행)과 클릭 통계만 빠지고, 설치 상태의 링크 진입은 Associated Domains 로 OS 가 직접 처리합니다.

---

## 2. 첫 빌드 & 실행

**Xcode 에서:**
1. 스킴 선택 → **`Hilit-Dev`**
2. 시뮬레이터(iPhone 16 등) 선택 → **⌘R**

**터미널에서:**
```bash
xcodebuild -workspace Hilit.xcworkspace -scheme Hilit-Dev \
  -destination 'generic/platform=iOS Simulator' build
```

> ⏱️ **첫 빌드는 수 분 걸립니다.** ComposableArchitecture 가 의존하는 **swift-syntax 매크로 컴파일**이 처음에 통째로 돌기 때문이고, 정상입니다. 두 번째부터는 캐시되어 빠릅니다.

### 화면(Feature) 단독 실행
각 Feature 는 단독 실행용 **Example 앱**이 있습니다: `Feature{Name}` 스킴(현재 골격에선 `FeatureHome`)을 선택 후 ⌘R — 그 스킴의 실행 타겟이 Example 앱입니다.

### 개발계 / QA / 운영계
빌드 Configuration `Dev` / `QA` / `Release` 로 나뉩니다 (`Dev` 에만 `DEV` 컴파일 조건, QA/Release 는 release 타입). **환경별 스킴 `Hilit-Dev` / `Hilit-QA` / `Hilit-Prod` 로 전환합니다** — 각 스킴의 Run/Archive 가 같은 Configuration 을 가리킵니다. 동작 원리·값이 읽히는 seam(`NetworkClient.defaultBaseURL()`·`AppSecrets`)·확장법은 DocC `Environments` 아티클 (`ArchitectureDocs` 스킴 → Build Documentation) 참고.

---

## 3. 자주 겪는 문제

| 증상 | 원인 / 해결 |
|---|---|
| `Hilit.xcworkspace` 가 없다 | `tuist generate` 안 함. → 1번 실행 |
| 빌드 중 `SwiftLint 미설치` 경고 | `brew install swiftlint` (없어도 빌드는 됨 — 경고만) |
| 첫 빌드가 너무 오래 걸림 | 정상 (swift-syntax 매크로 첫 컴파일). 기다리면 됨 |
| 의존성/모듈을 못 찾음 | `tuist install` 다시 → `tuist generate`. 그래도면 `tuist clean` 후 재시도 |
| 새 모듈을 추가했는데 빌드에 안 잡힘 | `Modules.swift` 등록 + 레이어 umbrella 에 Implementation 추가했는지 확인 → `tuist generate` 재실행 |
| umbrella 를 고쳤는데 반영 안 됨 | 캐시된 그래프로 빌드된 것. **`tuist generate` 를 반드시 다시** 돌린다 |
| 파일 추가했는데 Xcode 에 안 보임 | Tuist 는 글롭으로 소스를 잡음. `tuist generate` 다시 실행 |

---

## 4. 자주 쓰는 명령 (Makefile)

```bash
make generate                        # tuist install + generate
make test scheme=FeatureHome         # 특정 모듈 테스트 (시뮬레이터 UDID 자동 해석)
make lint                            # 전 모듈 SwiftLint
make lint-fix                        # 자동 수정 + 린트
make lat q=home                      # home 도메인과 엮인 코드 검색 (lat.md)
make lat-deps q=home                 # home 을 바꾸면 영향받는 곳
make install-snippets                # Xcode 코드 스니펫 설치 (tcapreview / tcapreviews — TCA 프리뷰)
```

---

## 5. 다음 단계

- 아키텍처/의존 규칙 → [`README.md`](../README.md)
- 새 모듈 추가 → [`docs/adding-module.md`](adding-module.md)
- 팀 컨벤션(브랜치·커밋·PR·배포) → [`CONTRIBUTING.md`](../CONTRIBUTING.md)
- 도메인 지식·흐름·의존 인덱스 → [`lat.md/`](../lat.md) (+ `make lat`)
- Claude Code 스킬: `/tca-preview 화면이름` — 리듀서를 분석해 시나리오별 `#Preview` 탭 생성 (`.claude/skills/`)
- 개념 아티클 문서 → Xcode 에서 `ArchitectureDocs` 스킴 → **Product → Build Documentation** (⌃⇧⌘D)
