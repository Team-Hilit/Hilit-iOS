import ProjectDescription
import ProjectDescriptionHelpers
import DependencyPlugin

let project = Project.makeModule(
    name: "FeatureAuth",
    targets: [
        // D3: Feature 는 Interface 를 두지 않는다.
        .feature(implements: "Auth", factory: .init(dependencies: [
            .composableArchitecture,
            .domain(interface: .auth),
            .domain(interface: .common),       // 미승격 서버 에러 공통 Alert(serverAlertState)
            .domain(interface: .consent),      // A1 약관 — pending 항목 렌더·submit (게이트 ①)
            .domain(interface: .job),          // 가입 온보딩 직군 선택(AuthOnboardingJob)
            .domain(interface: .user),         // 가입 온보딩 프로필 일괄 PATCH(AuthFeature)
            .shared(interface: .designSystem)
        ])),
        .feature(testing: "Auth"),
        // Tests/Example 소스가 직접 import하는 모듈은 전이 의존에 기대지 않고 명시한다 —
        // 누락 시 따뜻한 DerivedData에서만 우연히 빌드되는 거짓 성공이 난다.
        .feature(tests: "Auth", factory: .init(dependencies: [
            .composableArchitecture,
            .domain(interface: .auth),
            .domain(interface: .consent)
        ])),
        .feature(example: "Auth", factory: .init(
            dependencies: [
                .composableArchitecture,
                .domain(interface: .auth),
                .domain(interface: .consent),
                .domain(interface: .job),
                .domain(interface: .user)
            ]
        ))
    ]
)
