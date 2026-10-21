// swift-tools-version: 5.10
import PackageDescription

#if TUIST
    import ProjectDescription

    /// 1차 모듈 산출물 타입과 같은 스위치를 본다 (→ `Project.Environment.productType`).
    /// 두 값이 어긋나면 정적 산출물이 여러 이미지에 복제된다 — 아래 `productTypes` 주석 참조.
    let isStaticRelease: Bool = {
        if case let .string(value) = ProjectDescription.Environment.productType {
            return value == "static-library"
        }
        return false
    }()

    let packageSettings = PackageSettings(
        // 정적 SPM 산출물은 **자기를 link 한 이미지마다 사본**이 박힌다. 로컬 generate 는 1차 모듈이 동적이라
        // 여러 모듈이 함께 쓰는 TCA·Dependencies·카카오를 정적으로 두면 프레임워크마다 복제돼
        // `objc: Class … is implemented in both …` 경고 + 전역 상태(DependencyValues 등) 분열이 난다 → 동적으로 승격.
        // 릴리스(TUIST_PRODUCT_TYPE=static-library)는 1차 모듈이 정적이라 반대다 — 전부 앱 바이너리 한 벌로 합쳐야
        // 복제가 0 이므로 오버라이드를 걷어 Tuist 기본값(정적)에 맡긴다.
        // ChottuLinkSDK 는 여기 없다 — binaryTarget(XCFramework)이라 이 스위치가 닿지 않는다.
        // 배포물 자체가 동적 프레임워크라 두 모드 모두 «앱에 한 벌 임베드» 로 같게 끝난다.
        productTypes: isStaticRelease ? [:] : [
            "ComposableArchitecture": .framework,
            "Dependencies": .framework,
            "KakaoSDKAuth": .framework,
            "KakaoSDKCommon": .framework,
            "KakaoSDKUser": .framework
        ],
        // 외부 SPM 의존도 워크스페이스와 동일한 3단계 Configuration 으로 생성한다.
        // (없으면 Debug/Release 로 생성돼 Dev/QA 빌드에서 구성 불일치 경고·폴백이 난다)
        baseSettings: .settings(
            configurations: [
                .debug(name: "Dev"),
                .release(name: "QA"),   // 워크스페이스와 동일하게 QA 도 release 타입
                .release(name: "Release")
            ]
        )
    )
#endif

let package = Package(
    name: "App",
    dependencies: [
        // 유니버설 링크(FDL 대체) — 링크 도메인·AASA·deferred 를 SaaS 가 맡는다. 수신 전용으로만 쓴다.
        .package(url: "https://github.com/ConnectingDotsInfotech/chottulink-ios-sdk.git", from: "1.1.2"),
        .package(url: "https://github.com/kakao/kakao-ios-sdk", from: "2.22.0"),
        // 1.26.0+ 부터 Xcode 27 에서 컴파일된다 (NavigationStack init 의 main actor key path 에러 수정).
        // 1.26.2 는 swift-tools-version 6.4 라 Xcode 27 전용 — Package.resolved 는 Xcode 26 과도 맞는 1.26.1 에 둔다.
        // 전이 의존 swift-sharing 도 2.9.0+ 여야 Swift 6.4 링크 에러(`SharedReader.__generation` 미정의)가 안 난다 — Package.resolved 핀.
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.26.1")
    ]
)
