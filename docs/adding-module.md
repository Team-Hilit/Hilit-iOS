# 새 모듈 추가 가이드

Tuist 기반 TMA(The Modular Architecture) 4레이어 구조에서 새 모듈을 추가하는 방법을 설명한다.

## 전체 구조 요약

```
Projects/
├── Core/       {Name}/   CoreCommon, CoreNetwork, ...
├── Domain/     {Name}/   DomainCommon, DomainInterview, ...
├── Feature/    {Name}/   FeatureHome, FeatureInterview, ...
└── Shared/     {Name}/   SharedDesignSystem, ...
```

각 서브모듈은 아래 타겟 세트를 가진다.

| 타겟 | 역할 | 소스 경로 |
|---|---|---|
| `{Layer}{Name}Interface` | 외부에 노출할 프로토콜·타입 선언 | `Interface/` |
| `{Layer}{Name}Implementation` | 실제 구현체 (Interface를 import) | `Sources/` |
| `{Layer}{Name}Testing` | 테스트용 Mock/Stub (Interface를 import) | `Testing/` |
| `{Layer}{Name}Tests` | 단위 테스트 (Implementation + Testing import) | `Tests/` |
| `Feature{Name}Example` | 독립 실행 앱 (Feature만 있음) | `Example/` |

의존 방향: **App → Feature → Domain Interface → Core Interface**  
구현체(Implementation)는 App과 Example 앱만 링크한다.

---

## 모듈 추가 시 수정해야 하는 파일

### 1. `Plugins/DependencyPlugin/ProjectDescriptionHelpers/Modules.swift`

**모든 모듈 추가의 시작점.** 해당 레이어 enum에 case를 등록한다.  
등록하지 않으면 `Project.swift`에서 참조할 수 없어 컴파일 에러가 발생한다.

```swift
// Feature 모듈 추가 예시
public enum Feature: String, CaseIterable {
    case common = "Common"
    case interviewSetup = "InterviewSetup"   // ← 추가
    case interviewSession = "InterviewSession"
}

// Domain 모듈 추가 예시
public enum Domain: String, CaseIterable {
    case common = "Common"
    case interview = "Interview"   // ← 추가
}
```

> rawValue는 실제 디렉토리 이름과 동일해야 한다.  
> ex) `case interviewSetup = "InterviewSetup"` → `Projects/Feature/FeatureInterviewSetup/`

---

### 2. `Projects/{Layer}/{Layer}{Name}/Project.swift` 신규 생성

레이어별 팩토리 함수를 호출하는 ~10줄짜리 파일이다.

#### Feature 모듈 예시

```swift
import ProjectDescription
import ProjectDescriptionHelpers

let project = Project.makeModule(
    name: "FeatureInterviewSetup",
    targets: [
        // Feature 는 interface 없음 (D3 = Feature Interface 폐기) — implements 부터 시작
        .feature(implements: "InterviewSetup", factory: .init(dependencies: [
            .domain(interface: .interview),   // 의존하는 Domain 모듈 Interface
            .composableArchitecture,
        ])),
        .feature(testing: "InterviewSetup"),
        .feature(tests: "InterviewSetup"),
        .feature(example: "InterviewSetup"),
    ]
)
```

#### Domain 모듈 예시

```swift
import ProjectDescription
import ProjectDescriptionHelpers

let project = Project.makeModule(
    name: "DomainInterview",
    targets: [
        .domain(interface: "Interview", factory: .init(dependencies: [
            .composableArchitecture,      // Client 계약이 TestDependencyKey/DependencyValues 를 사용
        ])),
        .domain(implements: "Interview", factory: .init(dependencies: [
            .composableArchitecture,      // liveValue(DependencyKey) 구현
            .core(interface: .network),   // 의존하는 Core 모듈 Interface
        ])),
        .domain(testing: "Interview"),
        .domain(tests: "Interview"),
    ]
)
```

> ⚠️ Domain 의 Interface/Implementation 은 Client 패턴(TCA `TestDependencyKey`/`DependencyKey`)을 쓰므로 `.composableArchitecture` 의존이 **필수**다. 빠뜨려도 로컬에선 이전 빌드가 남긴 산출물 덕에 우연히 컴파일될 수 있지만, 클린 환경(CI·새 clone)에선 `Unable to find module dependency: 'ComposableArchitecture'` 로 실패한다.

#### Core 모듈 예시

```swift
import ProjectDescription
import ProjectDescriptionHelpers

let project = Project.makeModule(
    name: "CoreNetwork",
    targets: [
        .core(interface: "Network"),
        .core(implements: "Network"),
        .core(testing: "Network"),
        .core(tests: "Network"),
    ]
)
```

#### Shared 모듈 예시

```swift
import ProjectDescription
import ProjectDescriptionHelpers

let project = Project.makeModule(
    name: "SharedDesignSystem",
    targets: [
        .shared(interface: "DesignSystem"),
        .shared(implements: "DesignSystem"),
        .shared(testing: "DesignSystem"),
        .shared(tests: "DesignSystem"),
    ]
)
```

---

### 3. umbrella 재노출 — `Projects/{Layer}/Sources/Source.swift`

레이어 umbrella 타겟은 하위 서브모듈의 Implementation을 모아서 App에게 노출한다. **umbrella `Project.swift` 의 dependencies 는 `ModulePath.{Layer}.allCases` 를 순회해 자동 생성**되므로, 1번의 case 등록만으로 링크는 끝난다 — `Project.swift` 는 손댈 필요 없다.

```swift
// Projects/Feature/Project.swift — allCases 순회, 손댈 필요 없음
.feature(factory: .init(dependencies: ModulePath.Feature.allCases.map {
    .project(target: "Feature\($0.rawValue)Implementation", path: .feature($0))
}))
```

남은 건 재노출 한 줄. **`Projects/{Layer}/Sources/Source.swift`** 에 `@_exported import` 를 추가해야 `import Feature` 한 줄로 새 모듈이 재노출된다.

```swift
// Projects/Feature/Sources/Source.swift
@_exported import FeatureHomeImplementation
@_exported import FeatureInterviewSetupImplementation   // ← 추가
```

---

### 4. 소스 디렉토리 생성

`Project.swift`가 참조하는 소스 경로(`Interface/`, `Sources/`, `Testing/`, `Tests/`, `Example/`)에  
Swift 파일이 하나 이상 있어야 Tuist가 타겟을 생성한다.

각 경로는 **buildable folder**(Xcode 동기화 폴더)로 연결된다 — 이후 그 안의 파일 추가·삭제는 `tuist generate` 없이 반영된다.
리소스도 같은 폴더째 실리므로 Example 앱 아이콘은 `Example/Resources/Assets.xcassets` 에 두기만 하면 된다(`resources:` 지정 불필요).

```
Projects/Feature/FeatureInterviewSetup/   # Feature 는 Interface 없음 (D3)
├── Project.swift
├── Sources/
│   ├── InterviewSetupFeature.swift      ← Reducer 구현
│   └── InterviewSetupView.swift         ← View
├── Testing/
│   └── InterviewSetupStub.swift         ← Mock
├── Tests/
│   └── InterviewSetupTests.swift        ← 단위 테스트
└── Example/
    └── InterviewSetupApp.swift          ← @main 독립 실행 앱
```

> Domain/Core/Shared 는 여기에 `Interface/` 가 추가된다 (계약 선언). Feature 만 Interface 를 두지 않는다.

---

## `TargetDependency` 액세서 사용 규칙

### Interface 전용 (Feature/Domain 서브모듈에서 사용)

```swift
// Feature Implementation이 Domain Interface에 의존할 때
.domain(interface: .interview)

// Domain Implementation이 Core Interface에 의존할 때
.core(interface: .network)

// 어느 레이어에서든 Shared Interface에 의존할 때
.shared(interface: .designSystem)
```

### Umbrella (App과 Example 앱에서만 사용)

```swift
// App(Projects/App/Project.swift)에서 전체 레이어 링크
.core, .domain, .feature, .shared

// FeatureXxxExample 은 자기 Implementation + 필요한 Domain 구현만 link (팩토리가 자동 추가)
.project(target: "DomainXxxImplementation", path: .domain(.xxx))
```

> **주의**: Feature나 Domain `Project.swift`에서 `.domain`(umbrella)을 쓰면 구현체까지 링크되어  
> Clean Architecture의 Dependency Inversion이 깨진다. 반드시 `.domain(interface:)`를 사용할 것.

---

## 완료 체크리스트

- [ ] `Plugins/DependencyPlugin/ProjectDescriptionHelpers/Modules.swift`에 case 추가
- [ ] `Projects/{Layer}/{Layer}{Name}/` 디렉토리 생성
- [ ] `Projects/{Layer}/{Layer}{Name}/Project.swift` 작성
- [ ] 각 타겟 소스 경로에 Swift 파일 최소 1개 (Domain/Core/Shared: `Interface/`+`Sources/`+…, Feature: `Sources/`+… — Interface 없음)
- [ ] `Projects/{Layer}/Sources/Source.swift` 에 `@_exported import …Implementation` 추가 (umbrella `Project.swift` 는 case 등록으로 자동 — 손댈 필요 없음)
- [ ] `tuist generate` 실행 → 에러 없이 완료 확인
