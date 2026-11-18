import ProjectDescription
import ProjectDescriptionHelpers

let project = Project.makeModule(
    name: "Hilit",
    // 자동 스킴(Run=Dev/Archive=Release 혼합)을 끄고 아래 환경별 스킴만 노출한다 — QA 실행·아카이브 경로 확보.
    options: .options(automaticSchemesOptions: .disabled),
    targets: [
        .app(factory: .init(dependencies: [
            .core, .domain, .feature, .shared,
            .core(interface: .common),           // 첫 실행 판정 — FirstLaunchStore
            .core(interface: .network),          // AppView 전역 로딩 — NetworkActivity 관찰 · 첫 실행 정리 — TokenStore
            .domain(interface: .appVersion),     // Splash 버전 게이트 — 강제·권장 업데이트 판정
            .domain(interface: .auth),
            .domain(interface: .consent),        // Splash 세션 복구 판정 — 게이트 2단(pending)
            .domain(interface: .deeplink),       // 유니버설 링크 수신 — SDK 초기화 + deferred 해석 스트림
            .domain(interface: .feedbackShare),  // onOpenURL 이 링크 도메인을 가릴 때 쓰는 형식 상수
            .domain(interface: .interview),      // 진행 중 면접 두 갈래 — 중단·재개 호출 + held 세션 보관
            .domain(interface: .recording),      // 앱 사망 세션 정리 — 죽은 프로세스가 남긴 녹화 파일 purge
            .shared(interface: .designSystem),   // AppView 전역 로딩 — LoadingModal 표출
            .composableArchitecture
        ])),
        // 전역 DocC 카탈로그 호스트 (코드 없음). Xcode: 스킴 ArchitectureDocs → Product → Build Documentation
        .docs(factory: .init(dependencies: [
            .core, .domain, .feature, .shared,
            .composableArchitecture
        ])),
        // 실기기 XCUITest — 스킴 HilitUITests. → docs/device-qa.md
        .uiTests()
    ],
    schemes: [
        // 환경별 앱 스킴 — Run/Archive 가 같은 계(Configuration)를 가리킨다. → DocC Environments
        .app(name: "Hilit-Dev", configuration: "Dev"),
        .app(name: "Hilit-QA", configuration: "QA"),
        .app(name: "Hilit-Prod", configuration: "Release"),
        .scheme(
            name: "ArchitectureDocs",
            shared: true,
            buildAction: .buildAction(targets: ["ArchitectureDocs"])
        ),
        // Dev 계 앱 + UI 테스트. 실기기: make uitest device=<이름|UDID>
        .scheme(
            name: "HilitUITests",
            shared: true,
            buildAction: .buildAction(targets: ["Hilit", "HilitUITests"]),
            testAction: .targets(["HilitUITests"], configuration: "Dev"),
            runAction: .runAction(configuration: "Dev", executable: "Hilit")
        )
    ]
)
