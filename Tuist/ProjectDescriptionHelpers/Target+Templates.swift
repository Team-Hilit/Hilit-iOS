import ProjectDescription

// MARK: - TargetFactory

public struct TargetFactory {
    var name: String
    var destinations: Destinations
    var product: Product
    var bundleId: String?
    var deploymentTargets: DeploymentTargets?
    var infoPlist: InfoPlist?
    var entitlements: Entitlements?
    var sources: SourceFilesList?
    var resources: ResourceFileElements?
    var scripts: [TargetScript]
    var dependencies: [TargetDependency]
    var settings: Settings?

    public init(
        name: String = "",
        destinations: Destinations = Project.Environment.destinations,
        product: Product = Project.Environment.productType,
        bundleId: String? = nil,
        deploymentTargets: DeploymentTargets? = Project.Environment.deploymentTarget,
        infoPlist: InfoPlist? = nil,
        entitlements: Entitlements? = nil,
        sources: SourceFilesList? = nil,
        resources: ResourceFileElements? = nil,
        scripts: [TargetScript] = [],
        dependencies: [TargetDependency] = [],
        settings: Settings? = nil
    ) {
        self.name = name
        self.destinations = destinations
        self.product = product
        self.bundleId = bundleId
        self.deploymentTargets = deploymentTargets
        self.infoPlist = infoPlist
        self.entitlements = entitlements
        self.sources = sources
        self.resources = resources
        self.scripts = scripts
        self.dependencies = dependencies
        self.settings = settings
    }
}

// MARK: - Target

public extension Target {

    private static func make(factory: TargetFactory) -> Self {
        .target(
            name: factory.name,
            destinations: factory.destinations,
            product: factory.product,
            bundleId: factory.bundleId
                ?? "\(Project.Environment.bundlePrefix).\(factory.name.lowercased())",
            deploymentTargets: factory.deploymentTargets,
            infoPlist: factory.infoPlist,
            sources: factory.sources,
            resources: factory.resources,
            entitlements: factory.entitlements,
            scripts: factory.scripts,
            dependencies: factory.dependencies,
            settings: factory.settings
        )
    }

    // MARK: App

    /// composition root(App/Example) 공통 링크 설정.
    ///
    /// liveValue 활성화 보장 — 정적 아카이브는 참조된 오브젝트 파일만 링크하는데,
    /// Domain 등의 Implementation 은 extension(DependencyKey conformance)뿐이라 참조가 없어
    /// 통째로 탈락한다(→ 런타임에 testValue 폴백). `-all_load` 로 전 아카이브를 강제 적재한다.
    /// → lat.md architecture.md D4
    private static let compositionRootBase: SettingsDictionary = [
        "OTHER_LDFLAGS": "$(inherited) -all_load"
    ]

    /// App 앱 타겟.
    ///
    /// 환경 분리(→ DocC Environments): 계별 xcconfig 를 Configuration 에 연결하고
    /// 그 값(APP_ENV·API_BASE_URL·표시 이름·번들 접미사)을 Info.plist / bundleId 로 치환한다.
    /// → Dev(.dev)·QA(.qa)·운영(접미사 없음)이 번들 ID 가 달라 한 기기에 동시 설치된다.
    static func app(factory: TargetFactory = .init()) -> Self {
        var f = factory
        f.name = Project.Environment.appName
        f.product = .app
        f.bundleId = f.bundleId ?? "\(Project.Environment.bundlePrefix)$(BUNDLE_ID_SUFFIX)"
        f.infoPlist = f.infoPlist ?? .extendingDefault(with: [
            // 런치스크린은 storyboard 다 — `UILaunchScreen` dict 는 이미지 크기·위치를 못 잡아 로고가
            // 늘어난다. SplashView 와 같은 로고·좌표를 그려 첫 프레임 전환에 깜빡임이 없게 한다
            // (App/Resources/LaunchScreen.storyboard 주석 참조). 두 키를 같이 두면 dict 가 이긴다.
            "UILaunchStoryboardName": "LaunchScreen",
            // 세로 고정 — Xcode «Deployment Info» 의 Landscape 체크에 해당한다. 생성물(.xcodeproj)에서 끄면
            // 다음 `tuist generate` 가 되살리므로 매니페스트가 단일 소스다. 화면이 전부 세로 기준이고
            // 면접 녹화(전면 카메라 프리뷰)가 회전을 전제하지 않는다.
            "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
            // 64비트 전용 — Tuist 기본값 `armv7` 은 32비트 시절 잔재라 실제 바이너리(arm64)와 어긋난다.
            "UIRequiredDeviceCapabilities": ["arm64"],
            // xcconfig → Info.plist 치환. NetworkClient.defaultBaseURL()(API_BASE_URL)·AppSecrets(카카오 키)가 여기서 읽는다.
            "UIUserInterfaceStyle": "Light",
            "APP_ENV": "$(APP_ENV)",
            "API_BASE_URL": "$(API_BASE_URL)",
            "CFBundleDisplayName": "$(APP_DISPLAY_NAME)",
            // actool 부분 plist 병합에 기대지 않고 명시 — 병합본은 `CFBundleIcons` 안쪽에만 이 키를 넣어
            // 최상위가 비고, ASC 가 아이콘 누락으로 업로드를 거부한다(ITMS-90713). Example 도 같은 이유로 명시.
            "CFBundleIconName": "AppIcon",
            // 버전 단일 소스는 Config/Version.xcconfig — 여기서 빌드 세팅으로 치환된다.
            "CFBundleShortVersionString": "$(MARKETING_VERSION)",
            "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
            // 유니버설 링크(ChottuLink) API 키 — AppSecrets 가 여기서 읽는다. 계 구분 없이 한 벌이다
            // (링크 도메인·대시보드 앱이 하나라서).
            "CHOTTULINK_API_KEY": "$(CHOTTULINK_API_KEY)",
            // 카카오 로그인 — AppSecrets 가 여기서 읽는다.
            "KAKAO_NATIVE_APP_KEY": "$(KAKAO_NATIVE_APP_KEY)",
            "CFBundleURLTypes": [
                [
                    "CFBundleURLSchemes": ["kakao$(KAKAO_NATIVE_APP_KEY)"]
                ],
                // 지인 피드백 공유 딥링크 — hilit://feedback/{token} (GuestFeedbackDeeplink 가 판정).
                [
                    "CFBundleURLSchemes": ["hilit"]
                ]
            ],
            // 앱 카테고리(교육) — Xcode «General → App Category». 스토어 노출 카테고리의 최종 결정은
            // App Store Connect 몫이고, 이 키는 빌드가 신고하는 값이다(둘을 어긋나게 두지 않는다).
            "LSApplicationCategoryType": "public.app-category.education",
            "LSApplicationQueriesSchemes": ["kakaokompassauth", "kakaolink", "kakaotalk"],
            // 카메라·마이크는 사용 시점 요청(docs/work/ai-interview.md §5 권한) — 목적 문구 없으면 요청 즉시 크래시.
            "NSCameraUsageDescription": "AI 면접에서 얼굴과 답변 영상 녹화를 위해 카메라를 사용합니다.",
            "NSMicrophoneUsageDescription": "AI 면접에서 음성 답변 인식과 녹음을 위해 마이크를 사용합니다.",
            // 음성 인식 — 제품 경로는 서버 STT 가 대본을 만들고, 온디바이스 SFSpeechRecognizer 는
            // 진단 탐침(DomainSpeech `MicTranscriptionProbe`, 환경변수 게이트)에서만 쓴다. 그래도 바이너리가
            // Speech 를 참조하면 심사가 목적 문구를 요구한다(ITMS-90683 — «앱이 안 써도 문구는 필요»).
            "NSSpeechRecognitionUsageDescription": "AI 면접에서 답변 음성이 올바르게 입력되는지 확인하기 위해 음성 인식을 사용합니다.",
            // 수출 규정 — 통신은 HTTPS(OS 제공 암호)뿐이고 자체 암호 구현이 없다. false 를 박아 두면
            // 업로드마다 App Store Connect 가 묻는 수출 규정 문항을 건너뛴다.
            // (ATS 예외는 두지 않는다 — 전 계가 https 다 (운영 hilit.my · Dev/QA dev.hilit.my). HTTP 디버깅은 Example 하네스 몫)
            "ITSAppUsesNonExemptEncryption": false
        ])
        // Sign in with Apple — 시뮬레이터는 이 entitlement만으로 동작하고, 실기기는
        // Apple Developer 포털에서 App ID(환경별 번들 접미사 각각)에 capability 활성화가 필요하다.
        //
        // Associated Domains — 지인 피드백 유니버설 링크(https). 도메인 문자열의 단일 소스는
        // `GuestFeedbackShareLink.host` 지만 매니페스트는 앱 코드를 import 할 수 없어 여기 한 번 더 적는다 —
        // 함께 고칠 것. Apple Developer 포털에서도 App ID 3계 각각에 capability 활성화가 필요하다.
        f.entitlements = f.entitlements ?? .dictionary([
            "com.apple.developer.applesignin": ["Default"],
            "com.apple.developer.associated-domains": ["applinks:hilit.chottu.link"]
        ])
        f.sources = f.sources ?? ["Sources/**"]
        f.resources = f.resources ?? ["Resources/**"]   // Assets.xcassets(AppIcon 등) — 누락 시 앱 번들에 에셋이 안 들어간다
        f.scripts = f.scripts + [.kakaoKeyGuard]        // 배포 계(QA/Release)에서 카카오 키 미설정 시 빌드 실패
        f.settings = f.settings ?? .settings(
            base: compositionRootBase,   // -all_load (D4) — settings 를 교체해도 이 base 는 유지할 것
            configurations: [
                .debug(name: "Dev", xcconfig: "Config/Dev.xcconfig"),
                .release(name: "QA", xcconfig: "Config/QA.xcconfig"),
                .release(name: "Release", xcconfig: "Config/Prod.xcconfig")
            ]
        )
        return make(factory: f)
    }

    // MARK: Docs

    /// 프로젝트 전역 DocC 카탈로그(Architecture.docc) 전용 호스트 타겟. 실행 코드 없음.
    /// 카탈로그의 심볼 링크 해석을 위해 문서가 참조하는 모듈(레이어 umbrella)을 의존으로 받는다.
    static func docs(factory: TargetFactory = .init()) -> Self {
        var f = factory
        f.name = "ArchitectureDocs"
        f.product = .framework
        f.bundleId = "\(Project.Environment.bundlePrefix).docs"
        f.sources = f.sources ?? ["Documentation/Sources/**"]
        f.resources = f.resources ?? ["Documentation/Architecture.docc/**"]
        return make(factory: f)
    }

    // MARK: Layer Umbrellas
    //
    // 역할 파라미터 없이 레이어 함수를 호출하면 어그리게이터 타겟이 생성된다.
    // factory.dependencies 에 하위 서브모듈 Implementation 들을 넘긴다.

    static func core(factory: TargetFactory = .init()) -> Self {
        var f = factory
        f.name = "Core"
        f.sources = f.sources ?? ["Sources/**"]
        return make(factory: f)
    }

    static func domain(factory: TargetFactory = .init()) -> Self {
        var f = factory
        f.name = "Domain"
        f.sources = f.sources ?? ["Sources/**"]
        return make(factory: f)
    }

    static func feature(factory: TargetFactory = .init()) -> Self {
        var f = factory
        f.name = "Feature"
        f.sources = f.sources ?? ["Sources/**"]
        return make(factory: f)
    }

    static func shared(factory: TargetFactory = .init()) -> Self {
        var f = factory
        f.name = "Shared"
        f.sources = f.sources ?? ["Sources/**"]
        return make(factory: f)
    }

    // MARK: Feature
    //
    // D3: Feature 는 Interface 를 두지 않는다 — 단일 Implementation 모듈(+Testing/Tests/Example).
    // 근거: `@Reducer` + `some` 정적 합성이 구체 타입을 강제해 Interface 로 못 가림.
    // → DocC `FeatureInterface` / lat.md architecture.md D3. (Core/Domain/Shared 와 달리 interface 팩토리 없음)

    static func feature(implements name: String, factory: TargetFactory = .init()) -> Self {
        var f = factory
        f.name = "Feature\(name)Implementation"
        f.sources = f.sources ?? ["Sources/**"]
        f.scripts = [.swiftLint]
        return make(factory: f)
    }

    static func feature(testing name: String, factory: TargetFactory = .init()) -> Self {
        var f = factory
        f.name = "Feature\(name)Testing"
        f.sources = f.sources ?? ["Testing/**"]
        f.dependencies = [.target(name: "Feature\(name)Implementation")] + f.dependencies
        return make(factory: f)
    }

    static func feature(tests name: String, factory: TargetFactory = .init()) -> Self {
        var f = factory
        f.name = "Feature\(name)Tests"
        f.product = .unitTests
        f.sources = f.sources ?? ["Tests/**"]
        f.dependencies = [
            .target(name: "Feature\(name)Implementation"),
            .target(name: "Feature\(name)Testing")
        ] + f.dependencies
        return make(factory: f)
    }

    static func feature(example name: String, factory: TargetFactory = .init()) -> Self {
        var f = factory
        f.name = "Feature\(name)Example"
        f.product = .app
        // Example 앱 전용 번들 네임스페이스 `com.hilit.app.example.<feature>` — 본체(com.hilit.app.dev/qa/prod)와
        // 분리해 기능별로 자동 부여한다. TestFlight 배포 시 이 번들과 일치하는 App Store Connect 앱 레코드가 필요하다.
        f.bundleId = f.bundleId ?? "\(Project.Environment.bundlePrefix).example.\(name.lowercased())"
        f.infoPlist = f.infoPlist ?? .extendingDefault(with: [
            "UILaunchScreen": [:],
            // D14 개발 서버(HTTP + IP)로 직접 API 를 칠 수 있도록 앱 타겟과 동일한 ATS 예외 (위 .app() 주석 참조)
            "NSAppTransportSecurity": ["NSAllowsArbitraryLoads": true],
            // Example 도 TestFlight 배포 대상이 될 수 있다(G4 단독 검증 등) — 버전 키가 비면 ASC 업로드가 거부된다.
            // 단일 소스는 앱과 동일한 Config/Version.xcconfig (아래 settings 에서 연결).
            "CFBundleShortVersionString": "$(MARKETING_VERSION)",
            "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
            // actool 부분 plist 병합에 기대지 않고 명시 — 없으면 ASC 가 아이콘 누락으로 거부한다.
            // 모듈이 Example/Resources/Assets.xcassets 에 AppIcon 을 두면 이 이름으로 컴파일된다.
            "CFBundleIconName": "AppIcon"
        ])
        f.sources = f.sources ?? ["Example/**"]
        f.dependencies = [.target(name: "Feature\(name)Implementation")] + f.dependencies
        // base 의 -all_load: Domain Implementation(liveValue) link 시에도 활성화 보장 (D4)
        f.settings = f.settings ?? .settings(
            // AppIcon 컴파일 지정 — 모듈이 Example/Resources 에 에셋을 두면 CFBundleIconName 이 자동 주입된다(ASC 필수).
            base: compositionRootBase.merging(["ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon"]) { _, new in new },
            configurations: [
                .debug(name: "Dev", xcconfig: "../../App/Config/Version.xcconfig"),
                .release(name: "QA", xcconfig: "../../App/Config/Version.xcconfig"),
                .release(name: "Release", xcconfig: "../../App/Config/Version.xcconfig")
            ]
        )
        return make(factory: f)
    }

    // MARK: Core

    static func core(interface name: String, factory: TargetFactory = .init()) -> Self {
        var f = factory
        f.name = "Core\(name)Interface"
        f.sources = f.sources ?? ["Interface/**"]
        f.scripts = [.swiftLint]
        return make(factory: f)
    }

    static func core(implements name: String, factory: TargetFactory = .init()) -> Self {
        var f = factory
        f.name = "Core\(name)Implementation"
        f.sources = f.sources ?? ["Sources/**"]
        f.scripts = [.swiftLint]
        f.dependencies = [.target(name: "Core\(name)Interface")] + f.dependencies
        return make(factory: f)
    }

    static func core(testing name: String, factory: TargetFactory = .init()) -> Self {
        var f = factory
        f.name = "Core\(name)Testing"
        f.sources = f.sources ?? ["Testing/**"]
        f.dependencies = [.target(name: "Core\(name)Interface")] + f.dependencies
        return make(factory: f)
    }

    static func core(tests name: String, factory: TargetFactory = .init()) -> Self {
        var f = factory
        f.name = "Core\(name)Tests"
        f.product = .unitTests
        f.sources = f.sources ?? ["Tests/**"]
        f.dependencies = [
            .target(name: "Core\(name)Implementation"),
            .target(name: "Core\(name)Testing")
        ] + f.dependencies
        return make(factory: f)
    }

    // MARK: Domain

    static func domain(interface name: String, factory: TargetFactory = .init()) -> Self {
        var f = factory
        f.name = "Domain\(name)Interface"
        f.sources = f.sources ?? ["Interface/**"]
        f.scripts = [.swiftLint]
        return make(factory: f)
    }

    static func domain(implements name: String, factory: TargetFactory = .init()) -> Self {
        var f = factory
        f.name = "Domain\(name)Implementation"
        f.sources = f.sources ?? ["Sources/**"]
        f.scripts = [.swiftLint]
        f.dependencies = [.target(name: "Domain\(name)Interface")] + f.dependencies
        return make(factory: f)
    }

    static func domain(testing name: String, factory: TargetFactory = .init()) -> Self {
        var f = factory
        f.name = "Domain\(name)Testing"
        f.sources = f.sources ?? ["Testing/**"]
        f.dependencies = [.target(name: "Domain\(name)Interface")] + f.dependencies
        return make(factory: f)
    }

    static func domain(tests name: String, factory: TargetFactory = .init()) -> Self {
        var f = factory
        f.name = "Domain\(name)Tests"
        f.product = .unitTests
        f.sources = f.sources ?? ["Tests/**"]
        f.dependencies = [
            .target(name: "Domain\(name)Implementation"),
            .target(name: "Domain\(name)Testing")
        ] + f.dependencies
        return make(factory: f)
    }

    // MARK: Shared

    static func shared(interface name: String, factory: TargetFactory = .init()) -> Self {
        var f = factory
        f.name = "Shared\(name)Interface"
        f.sources = f.sources ?? ["Interface/**"]
        f.scripts = [.swiftLint]
        return make(factory: f)
    }

    static func shared(implements name: String, factory: TargetFactory = .init()) -> Self {
        var f = factory
        f.name = "Shared\(name)Implementation"
        f.sources = f.sources ?? ["Sources/**"]
        f.scripts = [.swiftLint]
        f.dependencies = [.target(name: "Shared\(name)Interface")] + f.dependencies
        return make(factory: f)
    }

    static func shared(testing name: String, factory: TargetFactory = .init()) -> Self {
        var f = factory
        f.name = "Shared\(name)Testing"
        f.sources = f.sources ?? ["Testing/**"]
        f.dependencies = [.target(name: "Shared\(name)Interface")] + f.dependencies
        return make(factory: f)
    }

    static func shared(tests name: String, factory: TargetFactory = .init()) -> Self {
        var f = factory
        f.name = "Shared\(name)Tests"
        f.product = .unitTests
        f.sources = f.sources ?? ["Tests/**"]
        f.dependencies = [
            .target(name: "Shared\(name)Implementation"),
            .target(name: "Shared\(name)Testing")
        ] + f.dependencies
        return make(factory: f)
    }
}
