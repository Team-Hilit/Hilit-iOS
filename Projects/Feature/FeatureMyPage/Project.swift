import ProjectDescription
import ProjectDescriptionHelpers
import DependencyPlugin

let project = Project.makeModule(
    name: "FeatureMyPage",
    targets: [
        // D3: Feature 는 Interface 를 두지 않는다 (단일 Implementation). → DocC FeatureInterface / architecture.md D3
        .feature(implements: "MyPage", factory: .init(dependencies: [
            .composableArchitecture,
            .domain(interface: .auth),
            .domain(interface: .interview),
            .domain(interface: .portfolio),
            .domain(interface: .user),
            .shared(interface: .designSystem)
        ])),
        .feature(testing: "MyPage"),
        // Tests/Example 소스가 직접 import하는 모듈은 전이 의존에 기대지 않고 명시한다 —
        // 누락 시 따뜻한 DerivedData에서만 우연히 빌드되는 거짓 성공이 난다.
        .feature(tests: "MyPage", factory: .init(dependencies: [
            .composableArchitecture,
            .domain(interface: .auth),
            .domain(interface: .interview),
            .domain(interface: .portfolio),
            .domain(interface: .user)
        ])),
        .feature(example: "MyPage", factory: .init(
            // 기본 example plist(feature(example:) 팩토리)를 오버라이드하므로 기본 키를 함께 유지한다.
            infoPlist: .extendingDefault(with: [
                "UILaunchScreen": [:],
                "NSAppTransportSecurity": ["NSAllowsArbitraryLoads": true],
                // live 하네스(HILIT_ACCESS_TOKEN)의 실서버 주소 — `NetworkClient.defaultBaseURL` 이
                // Bundle 에서 읽는다. Example 은 계별 xcconfig 를 안 타므로 Dev 서버 고정.
                "API_BASE_URL": "https://dev.hilit.my",
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "ITSAppUsesNonExemptEncryption": false,
                "CFBundleIconName": "AppIcon"
            ]),
            // 앱 아이콘 — feature(example:) 는 기본 리소스가 없어 명시 안 하면 아이콘 누락(업로드 90713·90022).
            resources: ["Example/Resources/**"],
            dependencies: [
                .composableArchitecture,
                .core(interface: .network),       // live 하네스 — TokenStore(Keychain)·AuthTokens
                .domain(interface: .auth),
                .domain(interface: .interview),
                .domain(interface: .portfolio),
                .domain(interface: .user),
                .shared(interface: .designSystem),
                // live 하네스 실 IO — NetworkClient·AuthorizedNetworkClient liveValue 활성화.
                .project(target: "CoreNetworkImplementation", path: .core(.network)),
                // live 하네스 실 IO — reportList·포폴 list/delete/register/status·파일 읽기·profile
                // liveValue (로그아웃·탈퇴는 스텁 유지).
                .project(target: "DomainInterviewImplementation", path: .domain(.interview)),
                .project(target: "DomainPortfolioImplementation", path: .domain(.portfolio)),
                .project(target: "DomainUserImplementation", path: .domain(.user))
            ]
        ))
    ]
)
