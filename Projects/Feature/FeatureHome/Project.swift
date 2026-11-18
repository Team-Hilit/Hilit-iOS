import ProjectDescription
import ProjectDescriptionHelpers
import DependencyPlugin

let project = Project.makeModule(
    name: "FeatureHome",
    targets: [
        // D3: Feature 는 Interface 를 두지 않는다 (단일 Implementation). → DocC FeatureInterface / architecture.md D3
        .feature(implements: "Home", factory: .init(dependencies: [
            .composableArchitecture,
            .domain(interface: .interview),   // 홈 진입 로드: 면접 기록(레포트) 목록
            .domain(interface: .user),        // 홈 진입 로드: 이름·잔여 이용권
            .shared(interface: .designSystem)
        ])),
        .feature(testing: "Home"),
        // Tests/Example 소스가 직접 import하는 모듈은 전이 의존에 기대지 않고 명시한다 —
        // 누락 시 따뜻한 DerivedData에서만 우연히 빌드되는 거짓 성공이 난다.
        .feature(tests: "Home", factory: .init(dependencies: [
            .composableArchitecture,
            .domain(interface: .interview),
            .domain(interface: .user)
        ])),
        .feature(example: "Home", factory: .init(
            dependencies: [
                .composableArchitecture,
                .domain(interface: .interview),
                .domain(interface: .user)
            ]
        ))
    ]
)
