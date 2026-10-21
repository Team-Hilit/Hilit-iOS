# 환경 분리 (Dev / QA / Release)

빌드 Configuration 기반으로 개발계(dev)·QA·운영계(release)를 나누는 방법.

## Overview

환경 분기는 **composition root(App)와 Domain `Implementation`(`liveValue`)만의 관심사**다. Feature 는 환경을 전혀 모른다 — Domain 의 `Interface` 계약만 의존하기 때문이다(<doc:ModularArchitecture> 의 두 번째 분리 규칙). 그래서 계를 추가해도 Feature·다른 레이어 코드는 한 줄도 바뀌지 않는다.

환경값 읽기는 **seam 한 곳**에 모은다 — 계별 값은 xcconfig → Info.plist 로 치환되고, 그 값을 읽는 코드는 소비 지점당 하나뿐이다. `#if DEBUG` 를 코드 곳곳에 뿌리지 않는다.

```text
App/Config/Dev.xcconfig · QA.xcconfig · Prod.xcconfig   (계별 값)
        │  빌드 시 치환
        ▼
App Info.plist  ($(APP_ENV), $(API_BASE_URL), $(KAKAO_NATIVE_APP_KEY), …)
        │
        ├─ NetworkClient.defaultBaseURL()  (CoreNetwork liveValue — baseURL)
        └─ AppSecrets                      (App — 카카오 키)
        ✗
   Feature·Domain 은 안 본다 (Domain 은 상대 path 만 조립 — 환경 무관)
```

> **현재 상태**: **3개 빌드 Configuration(Dev/QA/Release)** + 계별 xcconfig 연결 + Info.plist 치환(`APP_ENV`·`API_BASE_URL`·표시 이름·버전)·번들 접미사 + **계별 스킴(`Hilit-Dev`/`Hilit-QA`/`Hilit-Prod`)** — Dev(.dev)·QA(.qa)·운영이 번들 ID 가 달라 한 기기에 동시 설치된다. `API_BASE_URL` 은 `NetworkClient` 의 liveValue 가 읽는다(아래 «구현 형태»). 전 계가 https(운영 `https://hilit.my`, Dev·QA `https://dev.hilit.my`)라 앱 타겟엔 ATS 예외가 없다 — HTTP(IP 직결) 디버깅은 Example 하네스 몫이다.

## 지금 실재하는 것 — 3 Configuration + xcconfig 연결

Tuist 는 워크스페이스 내 모든 프로젝트가 **같은 Configuration 집합**을 갖길 요구한다. 그래서 이름은 `Tuist/ProjectDescriptionHelpers/Project+Templates.swift` 의 `Settings.standard` **한 곳**에서 정의해 전 모듈이 공유한다.

| Configuration | 타입 | 컴파일 조건 | 스킴 | 용도 |
|---|---|---|---|---|
| `Dev` | debug | `+ DEV` | `Hilit-Dev` | 개발계 — 디버그 표면 노출 |
| `QA` | release | — | `Hilit-QA` | 테스터 배포 — 실사용과 같은 최적화(-O), 디버그 메뉴 없음 |
| `Release` | release | — | `Hilit-Prod` | 운영계 |

계별 스킴은 Run/Archive/Profile 이 전부 **같은 Configuration** 을 가리킨다(`Scheme.app` 팩토리). Tuist 자동 스킴은 Run=Dev/Archive=Release 로 섞여 QA 를 빌드할 경로가 없어서, App 프로젝트는 자동 스킴을 끄고(`automaticSchemesOptions: .disabled`) 스킴을 명시 선언한다. 앱 버전은 `Config/Version.xcconfig`(`MARKETING_VERSION`·`CURRENT_PROJECT_VERSION`) 단일 소스에서 세 계로 흘러든다. 배포 계(QA/Release)는 `KakaoKeyGuard` 빌드 페이즈가 `KAKAO_NATIVE_APP_KEY` 미설정 시 빌드를 실패시킨다 — Release 에서 assertionFailure 가 침묵해 빈 키로 출시되는 사고를 막는다.

`Dev` 에만 `SWIFT_ACTIVE_COMPILATION_CONDITIONS` 에 `DEV` 가 들어간다. 디버그 전용 코드는 `#if DEV` 로 감싸 **QA·Release 바이너리엔 코드 자체가 존재하지 않게** 한다(런타임 플래그가 아니라 컴파일 타임 제거 → 운영 빌드에 디버그 표면이 새지 않음).

계별 값의 연결은 App 타겟 팩토리(`Target+Templates.swift` 의 `.app()`) 한 곳에서 한다 — Configuration 마다 `Config/*.xcconfig` 를 연결하고, 그 값을 `bundleId` 접미사와 Info.plist 치환으로 흘린다.

## 구현 형태 — 값이 코드로 들어오는 seam

계별 값은 그 값을 소비하는 모듈의 **liveValue(구현부)** 가 Info.plist 에서 직접 읽는다. 별도 AppConfig 모듈 없이 seam 두 곳으로 충분한 규모다:

- `Core/CoreNetwork` — 순정 `URLSession` transport(`NetworkClient`). `NetworkRequest` 계약은 **상대 path 만** 담고, liveValue 의 `defaultBaseURL()` 이 Info.plist 의 `API_BASE_URL` 을 읽어 얹는다. → Domain·Feature 는 baseURL(=계)의 존재 자체를 모른다.
- `App/AppSecrets` — 카카오 네이티브 앱 키 등 앱 전용 시크릿을 읽는 단일 seam.
- 인증 요청·토큰(TokenStore·AuthorizedNetworkClient)은 환경과 무관하게 같은 transport 위에 얹힌다 — lat.md `api#토큰 수명주기` 참조.

```swift
// Domain Implementation 의 liveValue — 상대 path 만 조립, Interface·Feature 는 환경 무관
@Dependency(\.authorizedNetworkClient) var network
return JobClient(
    jobs: {
        let payload: JobListPayload = try await network.api(NetworkRequest(path: "/api/v1/jobs"))
        return payload.jobs
    }
)
```

> Important: `.core(interface: .network)` 는 **Domain Implementation 에만** 넣는다. Feature 나 Interface 에 넣으면 "Feature 는 환경 무관" 규칙이 깨진다.

> Note: 계별 값이 늘어나 여러 레이어가 읽게 되면 그때 `@Dependency(\.appConfig)` 주입 모듈로 승격을 검토한다 — 현재 소비자는 transport(baseURL)와 App(시크릿)뿐이라 모듈 하나가 과하다.

## 값 추가하기

1. `Projects/App/Config/Dev.xcconfig` · `QA.xcconfig` · `Prod.xcconfig` 에 키 추가 (`SOME_KEY = …`)
2. `Target+Templates.swift` 의 `.app()` 팩토리 `infoPlist` 에 `"SOME_KEY": "$(SOME_KEY)"` 치환 추가
3. 값을 읽는 seam 을 **소비 모듈의 구현부**에 둔다 — 네트워크 값이면 `NetworkClientLive`(`defaultBaseURL()` 방식), 앱 전용 값이면 `AppSecrets` 방식
4. `tuist generate`

> Tip: xcconfig 값에 URL 처럼 `//` 가 들어가면 주석으로 먹힌다. `https:/$()/host` 처럼 빈 변수 `$()` 를 끼워 회피한다.

## 테스트·프리뷰에서 환경 주입

환경이 스며드는 지점이 transport 하나뿐이라, 테스트는 계를 흉내낼 필요 없이 **그 seam 만** 갈아끼운다.

```swift
// transport 자체 테스트 — 스텁 세션·baseURL 을 팩토리로 주입 (NetworkClientLiveTests)
NetworkClient.live(session: stubSession, baseURL: { URL(string: "https://qa.example.com")! })

// Domain liveValue 테스트 — 계약만 스텁, URLSession·계 무관 (XxxClientLiveTests)
withDependencies {
    $0.authorizedNetworkClient = AuthorizedNetworkClient(request: { _ in stubJSON }, authorizedResource: …)
} operation: { JobClient.liveValue }
```

Example 앱은 반대로 `.domain`·`.core` umbrella 를 link 해 Domain `liveValue` 를 실구동한다(`GuestFeedbackExampleApp`) — 경로·디코딩 코드가 실제로 돈다. 실서버 하네스(`LiveMyPageBootstrap`·`LiveInterviewBootstrap`)는 토큰만 주입하고 나머지 조회를 그대로 태운다.

## 관련 파일

- `Tuist/ProjectDescriptionHelpers/Project+Templates.swift` — `Settings.standard` (워크스페이스 전역 3 Configuration)
- `Projects/App/Config/{Dev,QA,Prod}.xcconfig` — 계별 값 · `Version.xcconfig` — 버전 단일 소스
- `Tuist/ProjectDescriptionHelpers/Target+Templates.swift` — `.app()` 팩토리 (xcconfig 연결 + Info.plist 치환 + 번들 접미사)
- `Tuist/ProjectDescriptionHelpers/Scheme+Templates.swift` — `Scheme.app` (계별 스킴 팩토리, App `Project.swift` 가 선언)
- `Tuist/ProjectDescriptionHelpers/TargetScript+SecretsGuard.swift` — `KakaoKeyGuard` (배포 계 시크릿 빌드 게이트)
- `Projects/Core/CoreNetwork/Sources/NetworkClientLive.swift` — `defaultBaseURL()` (Info.plist `API_BASE_URL` 을 읽는 seam)
- `Projects/App/Sources/AppSecrets.swift` — 앱 전용 시크릿 seam (`KAKAO_NATIVE_APP_KEY`)

## See Also

- <doc:ModularArchitecture>
- <doc:AddingFeature>
