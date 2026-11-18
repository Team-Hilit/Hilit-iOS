# Architecture — Claude 작업 가이드

SwiftUI + TCA · **Tuist TMA** — `Core / Domain / Feature / Shared` 4 레이어. Domain·Core·Shared 는 `Interface`(계약)/`Implementation`(구현) 분리, Feature 는 단일 모듈. cross-feature 조립은 `AppFeature`(코디네이터) 전담.

## 구조 (현행)

```
Plugins/DependencyPlugin/ … Modules.swift    ← 모듈 레지스트리(ModulePath) — 새 모듈은 여기 먼저
Tuist/                                       ← Project.makeModule + 타겟 팩토리 + scaffold 템플릿
Projects/
├── App/       composition root — AppFeature(화면 코디네이터) · Config/{Dev,QA,Prod}.xcconfig · DocC
├── Core/      Common · Network
├── Domain/    AppVersion · Auth · Common · Consent · Deeplink · FeedbackShare · GuestFeedback · Interview · InterviewReport · JD · Job · Permission · Portfolio · Recording · Speech · User    (모델 + Client)
├── Feature/   Auth · GuestFeedback · Home · Interview · MyPage · Onboarding · Report   (화면 — Interface 없음)
└── Shared/    DesignSystem (토큰 + 공용 컴포넌트)
```

- 의존 방향: `App → Feature(Impl) → Domain(Interface) → Core(Interface)`. `Shared(Interface)` 는 전 레이어 가능.
- 레이어 umbrella(`Projects/{Layer}/Project.swift`, `@_exported` 재노출)·Implementation 은 **App/Example 만** link.

## 절대 규칙

- **Feature → Feature 의존 0** — 전환은 `delegate` 신호만, 조립은 AppFeature.
- 타 모듈은 **Interface 만** 의존: `.domain(interface: .job)` 식. Implementation·umbrella import 금지.
- **Feature 는 Interface 없음 (D3)** — Reducer/View 는 `Sources/` 한 타겟.
- **Repository(외부 IO) = Domain 모듈** — Interface 에 Client struct + DependencyValues 키 + preview/testValue, Implementation 에 liveValue.
- **코드 변경 시 문서 동기화 (필수)** — 바뀐 코드와 같은 작업 안에서 관련 문서 갱신(어긋난 채 끝내지 않음). 대상: 구조(모듈·의존·레이어) → «구조» 섹션 + `docs/adding-module.md`(절차 바뀌면) · 디자인(토큰·컴포넌트) → `.claude/design.md`(+`.claude/design/*.md`) · 도메인 의도·숨은 의존 → `lat.md/` 노드 + `@lat` 라벨(`lat check`). 문서 내부는 «문서 작성법» 따른다.
  - **경로·심볼 추적**: 파일 이름·경로·공개 심볼이 바뀌면 그걸 언급하는 문서를 **전부** 찾아 고친다 — 직접 다룬 문서만이 아니라, 옛 이름으로 `grep -r --include="*.md"` 해서 걸리는 모든 문서(lat.md·docs·스킬 포함).

## TCA 패턴

- 화면 1개 = `XxxFeature.swift`(Reducer) + `XxxView.swift`(View).
- **Action 3분류 (D5)**: `view`(사용자 입력·생명주기 — View `send` 전용) / `inner`(effect 결과 — 리듀서 전용) / `delegate`(부모 통보 — 부모는 이것만 매칭). `async` 카테고리 금지(응답은 inner). binding 은 `View: BindableAction` + `BindingReducer(action: \.view)`. switch 길면 `reduceView`/`reduceInner` 분리.
- `@ObservableState` + `@Bindable var store` + `@ViewAction(for:)` 표준. `WithViewStore` 금지.
- 외부 IO 는 `@Dependency` 주입. `testValue` 는 반드시 unimplemented (빈 클로저 금지).
- 도메인 내부 navigation 은 그 Feature 의 `Path`/`StackState`.

## 새 모듈

`make scaffold-{feature|domain|core|shared} name=X` → ① `Modules.swift` case 등록 ② `Projects/{Layer}/Sources/Source.swift` 에 `@_exported import …Implementation` 추가 ③ `tuist generate`. 상세: `docs/adding-module.md` (단일 소스).

## 빌드 / 실행

- `tuist install && tuist generate` — `.xcworkspace`/`.xcodeproj` 는 생성물, 커밋 안 함.
- **스토어·TestFlight 아카이브는 `TUIST_PRODUCT_TYPE=static-library` 를 앞에 붙여 generate 한 뒤** 뽑는다 — 기본 generate 는 dylib 을 수십 개 임베드해 중복 심볼 경고·느린 실행을 낳고, 정적 모드는 앱 바이너리 한 벌로 합친다.
- 앱 스킴 `Hilit-Dev|QA|Prod`. Feature 단독 실행: `Feature{Name}` 스킴 ⌘R (Example 앱이 실행 타겟).
- 테스트: `make test scheme=FeatureHome` 권장 (시뮬레이터 UDID 자동 해석).
- **umbrella 의존 변경 후 `tuist generate` 필수** — 캐시 그래프 빌드는 "거짓 성공".
- DocC: `ArchitectureDocs` 스킴 → Product → Build Documentation.
- **PR 올리기**: base 는 항상 `dev`(feature→dev). `gh pr create --repo Team-Hilit/Hilit-iOS --base dev --head "$(git branch --show-current)" --title "type: 요약" --body-file <본문.md>` — 본문은 `.github/pull_request_template.md` 형식(관련 이슈 `Close #N`/작업 내역/리뷰 포인트/체크리스트). 상세 `CONTRIBUTING.md`, squash 머지. gh 미인증 시 `gh auth login`.

## lat.md 지식 그래프

- 작업 전 `lat search "<할 일>"` 로 설계 의도 파악, 작업 후 **`lat check` 통과 전엔 미완료** (노드 갱신 의무 → «코드 변경 시 문서 동기화»).
- Reducer 위 `// @lat: [[node#Section]]`, cross-feature delegate 의존은 `// depends-on: [[…]]` 로 **반드시** 명시 (import 에 안 보여서).
- 섹션 헤딩 = ID (데코레이션 금지), 모든 섹션은 ≤250자 선행 문단으로 시작. 상세: `docs/lat-labeling.md`.

## 컨벤션

- **나열은 알파벳순**: 항목을 늘어놓는 자리는 **전부** 알파벳순을 유지하고, 새 항목은 끝에 붙이지 말고 **제자리에 끼워 넣는다** (모듈 나열·`Modules.swift` case·`Project.swift` dependencies·문서 표 …). 끝에 붙이면 두 브랜치가 같은 줄을 건드려 머지 충돌이 나고, 제자리면 서로 다른 줄이라 git 이 자동 병합한다.
- **커밋**: 제목 1 줄 한국어. `type: 설명_부연` 형식. 본문은 필요할 때만 2-3 줄. 말투는 사람이 쓴 메모처럼 짧게 — 설명체 장문·홍보 형용사·도구 서명 금지 (상세 `CONTRIBUTING.md` 1.2).
- **네이밍**: Swift API Design Guidelines — 변수·함수 lowerCamelCase, 타입 UpperCamelCase, 식별자 언더스코어·한글 금지. 외부 명칭(Figma `head1_sb_32` 등)은 Swift 식별자로 변환, 원본은 매핑 프로퍼티 보존(`DSTypography.figmaName`). 테스트 함수도 camelCase, 한글 설명은 `@Test("설명")` 표시명.
- **public 키워드**: 모듈 경계 넘는 타입/함수에 필수.
- **Action 네이밍**: 3분류(view/inner/delegate — «패턴» 참조) 안에서 — 사용자 입력 `userTapped...`(View), 응답 `...Loaded`/`...Saved`(Inner), 생명주기 `onAppear`/`onDisappear`(View), 부모 통보 `delegate(Delegate)`.
- **DesignSystem 토큰 우선**: 색·타이포·spacing·컴포넌트는 하드코딩 리터럴 대신 토큰. 목록·API·상세 → `.claude/design.md`.

## 디자인 시스템

UI 코드(View·컴포넌트·에셋) 작성·수정 **전에 `.claude/design.md` 읽는다** — 토큰·표준 컴포넌트·에셋 로드 규칙 참조. **Figma MCP(`get_design_context` 등)로 화면 옮길 때도 raw 수치(색·크기·폰트) 박지 말고 `.claude/design.md` 토큰·컴포넌트로 매핑.** 모듈 `Shared/SharedDesignSystem`(토큰 전 영역 + 공용 컴포넌트 — 목록·승격 규칙은 `.claude/design/component.md` 인덱스, API 는 그 아래 `.claude/design/component/*.md`), 의존 `.shared(interface: .designSystem)`. **허브 문서에 토큰 개수·컴포넌트 이름을 열거하지 않는다** — 추가할 때마다 같은 줄이 바뀌어 충돌한다. 열거는 상세 문서 몫.

## 참고

- 패턴/개념: DocC `Projects/App/Documentation/Architecture.docc/` · 환경분리: DocC `Environments` 아티클
- 세팅 `docs/getting-started.md` · 모듈 추가 `docs/adding-module.md` · 커밋/PR `CONTRIBUTING.md` · lat 방법론 `docs/lat-methodology.md`
- 문서 배치: 심볼·개념 = **DocC**, 검증되는 도메인 지식 = **`lat.md/`**, 코드 밖 독립 산문 = **`docs/`**.
- **문서 작성법 (허브 → 상세)**: 공통(허브) 문서엔 **규칙·요약만**, 상세는 별도 문서로 빼 **경로 링크만** (`CLAUDE.md → design.md`, `design.md → design/*.md`). 추가할 땐 **항상 가장 간결·명확한 짧은 문장으로** — 허브 부풀리지 않기. 한 사실은 한 곳에만, 문서 간 중복·충돌 금지.

## superpowers 서브에이전트 모델 (오버라이드)

`superpowers:subagent-driven-development`(및 이를 위임하는 `executing-plans`)로 구현을 진행할 때, **코드를 작성하는 implementer 서브에이전트는 항상 Opus 4.8 로 디스패치**한다 (Agent 호출 시 `model: opus`). 그 스킬 `SKILL.md` 의 «Model Selection» 섹션이 스펙 명확한 구현 태스크에 싼 티어(Sonnet/Haiku)를 고르라고 지시해도, **implementer 에 한해 이 지시가 우선**한다.

- **대상**: 코드를 작성하는 implementer 서브에이전트만.
- **그대로 둠**: `task-reviewer`·최종 whole-branch 리뷰 등 리뷰 서브에이전트는 스킬 기본값(diff 크기·복잡도·리스크에 맞춘 티어)을 유지 — 손대지 않는다.
- **이미 Opus**: 계획(`brainstorming`·`writing-plans`)은 서브에이전트 없이 인라인이라 세션 모델(Opus 4.8)로 돈다 — 변경 없음.
