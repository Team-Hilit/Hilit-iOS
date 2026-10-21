import ProjectDescription

/// 모듈별 `Project.swift` 를 glob 으로 통합하는 루트 워크스페이스.
let workspace = Workspace(
    name: "Hilit",
    projects: ["Projects/**"],
    // 생성되는 모든 프로젝트·스킴에 LastUpgradeCheck 를 박아 Xcode 의 "Update to recommended settings" 경고를 끈다.
    // Xcode 에서 그 경고를 눌러 고쳐도 다음 generate 때 사라지므로, 필요한 설정은 `Settings.standard` 에 넣는다.
    // Xcode 를 올리면 이 값도 같이 올린다.
    generationOptions: .options(lastXcodeUpgradeCheck: .init(27, 1, 0))
)
