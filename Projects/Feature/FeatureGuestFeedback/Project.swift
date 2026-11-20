import ProjectDescription
import ProjectDescriptionHelpers
import DependencyPlugin

let project = Project.makeModule(
    name: "FeatureGuestFeedback",
    targets: [
        // D3: Feature 는 Interface 를 두지 않는다.
        .feature(implements: "GuestFeedback", factory: .init(dependencies: [
            .composableArchitecture,
            // 진입 링크 형식(GuestFeedbackShareLink) — 조립하는 리포트 쪽과 공유하는 단일 소스.
            .domain(interface: .feedbackShare),
            .domain(interface: .guestFeedback),
            .shared(interface: .designSystem)
        ])),
        .feature(testing: "GuestFeedback"),
        // Tests/Example 소스가 직접 import하는 모듈은 전이 의존에 기대지 않고 명시한다.
        .feature(tests: "GuestFeedback", factory: .init(dependencies: [
            .composableArchitecture,
            .domain(interface: .feedbackShare),
            .domain(interface: .guestFeedback),
            .project(target: "DomainGuestFeedbackTesting", path: .domain(.guestFeedback))
        ])),
        .feature(example: "GuestFeedback", factory: .init(
            dependencies: [
            .composableArchitecture,
            .domain(interface: .guestFeedback),
            .shared(interface: .designSystem),
            .project(target: "DomainGuestFeedbackTesting", path: .domain(.guestFeedback)),
            // 실서버 모드 — liveValue 활성화를 위해 Implementation 은 umbrella 로 link (App/Example 만 허용)
            .domain,
            .core
        ]))
    ]
)
