import ProjectDescription
import ProjectDescriptionHelpers
import DependencyPlugin

let project = Project.makeModule(
    name: "FeatureOnboarding",
    targets: [
        // D3: Feature 는 Interface 를 두지 않는다 (단일 Implementation). → DocC FeatureInterface / architecture.md D3
        .feature(implements: "Onboarding", factory: .init(dependencies: [
            .composableArchitecture,
            .domain(interface: .jd),
            .domain(interface: .portfolio),
            .domain(interface: .interview),   // 프리로드: 세션 생성(S0~S3 일괄 수집)
            .shared(interface: .designSystem)
        ])),
        .feature(testing: "Onboarding"),
        // Tests/Example 소스가 직접 import하는 모듈은 전이 의존에 기대지 않고 명시한다 —
        // 누락 시 따뜻한 DerivedData에서만 우연히 빌드되는 거짓 성공이 난다.
        .feature(tests: "Onboarding", factory: .init(dependencies: [
            .composableArchitecture,
            .domain(interface: .jd),
            .domain(interface: .portfolio),
            .domain(interface: .interview)
        ])),
        // Example = 온보딩 단독 데모 앱. 가짜 의존성으로 네트워크 없이 위저드 전체를 돌린다.
        // 번들은 템플릿 규칙으로 com.hilit.app.example.onboarding 이 자동 부여된다 (feature(example:) 팩토리).
        // TestFlight 단독 배포(TMA) 시 이 번들과 일치하는 App Store Connect 앱 레코드 등록이 필요하다.
        .feature(example: "Onboarding", factory: .init(
            infoPlist: .extendingDefault(with: [
                "UILaunchScreen": [:],
                "UIUserInterfaceStyle": "Light",
                "CFBundleDisplayName": "Hilit 온보딩",
                // InfoPlist 를 명시(extendingDefault)하면 asset catalog 기반 CFBundleIconName 자동 주입이
                // 안 되므로 직접 지정한다 (업로드 90713 방지). 값은 ASSETCATALOG_COMPILER_APPICON_NAME 과 일치.
                "CFBundleIconName": "AppIcon",
                // 버전은 Config/Onboarding.xcconfig 의 빌드 세팅에서 치환된다.
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                // 온보딩 데모는 네트워크·암호화 미사용 → TestFlight 업로드 시 수출규정 질문 스킵.
                "ITSAppUsesNonExemptEncryption": false
            ]),
            // 앱 아이콘 — 다른 모듈은 Example/Resources(Example 폴더째 실림)에 두지만 이 모듈만 모듈 루트
            // Resources 를 써서 따로 연결한다.
            buildableFolders: ["Resources"],
            dependencies: [
                .composableArchitecture,
                .domain(interface: .jd),
                .domain(interface: .portfolio),
                .domain(interface: .interview),
                // 실 IO — 데모도 fileImporter 로 진짜 PDF 를 고른다(오버라이드 없음).
                // PortfolioFileReader.liveValue 가 Implementation 소속이라 여기서 link 한다.
                .project(target: "DomainPortfolioImplementation", path: .domain(.portfolio))
            ],
            settings: .settings(
                base: [
                    // -all_load 는 팩토리(compositionRootSettings) 관례 유지 (D4). Example 은 가짜 의존성이라 무해.
                    "OTHER_LDFLAGS": "$(inherited) -all_load",
                    // 버전(MARKETING_VERSION·CURRENT_PROJECT_VERSION)은 Config/Onboarding.xcconfig 에서 관리한다.
                    "CODE_SIGN_STYLE": "Automatic",
                    // asset catalog 의 AppIcon 을 앱 아이콘으로 지정 (CFBundleIconName 자동 생성).
                    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon"
                ],
                // 서명 팀(DEVELOPMENT_TEAM)을 Secrets.xcconfig 에서 주입 — generate 마다 팀이 리셋되는 걸 막는다.
                // Onboarding.xcconfig 가 Secrets 를 옵셔널 include (본체 Hilit 과 동일 방식).
                configurations: [
                    .debug(name: "Dev", xcconfig: "Config/Onboarding.xcconfig"),
                    .release(name: "QA", xcconfig: "Config/Onboarding.xcconfig"),
                    .release(name: "Release", xcconfig: "Config/Onboarding.xcconfig")
                ]
            )
        )),
    ],
    schemes: [
        // 온보딩 데모 TestFlight 배포 스킴 — build/archive 를 Example 앱·Release 로 고정한다.
        // (개발 실행용 자동 스킴 FeatureOnboarding 은 그대로 유지된다.)
        .scheme(
            name: "Hilit-Onboarding",
            shared: true,
            buildAction: .buildAction(targets: ["FeatureOnboardingExample"]),
            runAction: .runAction(configuration: "Release", executable: "FeatureOnboardingExample"),
            archiveAction: .archiveAction(configuration: "Release"),
            profileAction: .profileAction(configuration: "Release", executable: "FeatureOnboardingExample"),
            analyzeAction: .analyzeAction(configuration: "Release")
        )
    ]
)
