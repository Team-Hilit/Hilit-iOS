import ProjectDescription
import ProjectDescriptionHelpers

// 디자인 토큰(타이포그래피 등)은 상수 계약이라 전부 Interface 에 산다.
// 폰트 리소스(Pretendard otf)도 토큰이 직접 등록하므로 Interface 번들에 싣는다.
let project = Project.makeModule(
    name: "SharedDesignSystem",
    targets: [
        // Interface 만 buildable folder 가 아니라 glob 이다 — 폰트를 폴더로 실으면 Tuist 가 폰트 접근자
        // (…FontConvertible, Pretendard.swift 가 사용)를 합성하지 않고, 폴더 안에 glob 리소스를 섞을 수도 없다.
        // → 이 타겟은 파일 추가 시 `make generate` 필요.
        .shared(interface: "DesignSystem", factory: .init(
            sources: ["Interface/**"],
            resources: ["Interface/Resources/**"]
        )),
        .shared(implements: "DesignSystem"),
        .shared(testing: "DesignSystem"),
        .shared(tests: "DesignSystem")
    ]
)
