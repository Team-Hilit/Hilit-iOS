import ProjectDescription
import ProjectDescriptionHelpers
import DependencyPlugin

let project = Project.makeModule(
    name: "FeatureInterview",
    targets: [
        // D3: Feature 는 Interface 를 두지 않는다 (단일 Implementation). → DocC FeatureInterface / architecture.md D3
        .feature(implements: "Interview", factory: .init(dependencies: [
            .composableArchitecture,
            .domain(interface: .interview),
            .domain(interface: .interviewReport),   // 종료 후 리포트 채점 대기 폴링
            .domain(interface: .permission),
            .domain(interface: .recording),
            .domain(interface: .speech),
            .shared(interface: .designSystem)
        ])),
        .feature(testing: "Interview"),
        // Tests/Example 소스가 직접 import하는 모듈은 전이 의존에 기대지 않고 명시한다 —
        // 누락 시 따뜻한 DerivedData에서만 우연히 빌드되는 거짓 성공이 난다.
        .feature(tests: "Interview", factory: .init(dependencies: [
            .composableArchitecture,
            .domain(interface: .interview),
            .domain(interface: .interviewReport),   // 종료 후 리포트 대기 폴링 스텁
            .domain(interface: .permission),
            .domain(interface: .recording),
            .domain(interface: .speech),
            .project(target: "DomainInterviewReportTesting", path: .domain(.interviewReport))   // 리포트 대기 폴링 fixture
        ])),
        .feature(example: "Interview", factory: .init(
            // 기본 example plist(feature(example:) 팩토리)를 오버라이드하므로 기본 키를 함께 유지한다.
            infoPlist: .extendingDefault(with: [
                "UILaunchScreen": [:],
                "NSAppTransportSecurity": ["NSAllowsArbitraryLoads": true],
                // live 하네스(HILIT_ACCESS_TOKEN)의 실서버 주소 — `NetworkClient.defaultBaseURL` 이
                // Bundle 에서 읽는다. Example 은 계별 xcconfig 를 안 타므로 Dev 서버 고정.
                "API_BASE_URL": "https://dev.hilit.my",
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "CFBundleIconName": "AppIcon",
                // 카메라·마이크는 사용 시점 요청(ai-interview.md §권한) — 목적 문구 없으면 요청 즉시 크래시.
                "NSCameraUsageDescription": "AI 면접에서 얼굴과 답변 영상 녹화를 위해 카메라를 사용합니다.",
                "NSMicrophoneUsageDescription": "AI 면접에서 음성 답변 인식과 녹음을 위해 마이크를 사용합니다.",
                // 진단 탐침(HILIT_STT_PROBE) 전용 — 문구 없으면 인식 권한 요청 즉시 크래시.
                "NSSpeechRecognitionUsageDescription": "마이크에 들어온 소리를 글로 옮겨 점검하기 위해 음성 인식을 사용합니다."
            ]),
            dependencies: [
                .composableArchitecture,
                .core(interface: .network),       // live 하네스 — TokenStore(inMemory)·AuthTokens
                .domain(interface: .interview),
                .domain(interface: .interviewReport),   // 영상 스모크 — expiry·리포트 새 스키마 디코딩
                .domain(interface: .portfolio),   // live 부트스트랩 — 첫 포트폴리오 조회
                .domain(interface: .speech),      // Example 앱 — 프리뷰 모드 speechClient previewValue 주입
                .domain(interface: .user),        // live 부트스트랩 — 프로필·잔여 이용권 진단
                // live 하네스 실 IO — NetworkClient·AuthorizedNetworkClient liveValue 활성화.
                .project(target: "CoreNetworkImplementation", path: .core(.network)),
                // live 하네스 실 IO — InterviewClient liveValue (실서버 세션 생성·턴 루프).
                .project(target: "DomainInterviewImplementation", path: .domain(.interview)),
                // 영상 스모크 실 IO — InterviewReportClient liveValue (expiry·리포트 새 스키마 디코딩).
                .project(target: "DomainInterviewReportImplementation", path: .domain(.interviewReport)),
                // 권한만 실물 IO — 준비 화면의 요청→거부 alert→설정 이동 흐름 검증용 (liveValue 활성화).
                .project(target: "DomainPermissionImplementation", path: .domain(.permission)),
                // live 하네스 실 IO — PortfolioClient liveValue (부트스트랩 목록 조회).
                .project(target: "DomainPortfolioImplementation", path: .domain(.portfolio)),
                // 카메라 프리뷰 실물 IO — 실기기에서 전면 카메라 프리뷰 검증용 (liveValue 활성화).
                .project(target: "DomainRecordingImplementation", path: .domain(.recording)),
                // 마이크 캡처·TTS 재생 실물 IO — 레벨·발화 로그와 질문 재생 검증용 (liveValue 활성화).
                .project(target: "DomainSpeechImplementation", path: .domain(.speech)),
                // live 부트스트랩 실 IO — UserClient liveValue (프로필·이용권 진단).
                .project(target: "DomainUserImplementation", path: .domain(.user))
            ]
        ))
    ]
)
