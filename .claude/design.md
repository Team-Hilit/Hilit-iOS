# Design System — UI 작업 인덱스

UI 코드를 작성·수정하기 전에 읽는 진입점. 여기엔 **규칙과 영역별 요약만** 두고, 상세는 각 영역 문서 포인터를 따라간다 (CLAUDE.md → design.md 패턴의 재귀 적용). 단일 소스는 `Shared/SharedDesignSystem` 모듈 코드 — 문서와 어긋나면 코드가 우선.

## 사용 규칙 (필수)

- **토큰 우선, 하드코딩 금지** — `Color.blue`, `16`, `.font(.system(size:))` 같은 리터럴 대신 항상 토큰을 쓴다.
- 의존은 `.shared(interface: .designSystem)` — 모든 레이어에서 가능. Implementation 은 App/Example 만 link.

## 영역별 인덱스

| 영역 | 진입 API | 상세 |
|---|---|---|
| 타이포그래피 | `.dsTypography(.head1)` — Pretendard, 행간·자간 내장 | **`.claude/design/typography.md`** |
| 색상 | `Color.<패밀리>.<단계>` — 패밀리 enum 팔레트 (에셋명 = HEX). 생김새→토큰 역매핑 표 있음 | **`.claude/design/color.md`** |
| 이미지 | `Image.<패밀리>.<변형>` — 아이콘, 일러스트는 `Image.Img.*`. 틴트 금지(색은 에셋에 구움). 생김새→패밀리 역매핑 표 있음 | **`.claude/design/image.md`** |
| Spacing | `.padding(.ds(.p20))` · 테두리 `.ds(.medium)` | **`.claude/design/spacing.md`** |
| 컴포넌트 | 버튼은 `ButtonLarge`(View) + ButtonStyle 체계 — **상태(pressed·disabled)는 넘기지 않는다**. **커스텀 만들기 전에 먼저 검토** | **`.claude/design/component.md`** (인덱스 → 영역별 `.claude/design/component/*.md`) |
| 인터랙션 | `.dismissesKeyboardOnTap()` — 입력 필드 있는 화면 루트에 부착 | 인라인 (Interface/Interaction) |
| 카탈로그 | 토큰·컴포넌트 전부를 한 화면에서 훑기 — `SharedDesignSystem/Testing/Catalog/DesignSystemCatalog.swift` 의 `#Preview` (Testing 타겟이라 릴리즈에 안 실린다) | 인라인 |
| 사고 사례 | 같은 실수 반복 방지 — 새 규칙이 생기면 여기 먼저 | **`.claude/design/lessons.md`** |

> **이 표는 «어디로 가면 되는지»만 말한다.** 토큰 개수·컴포넌트 이름 같은 목록을 여기 적지 않는다 — 뭔가 추가될 때마다 같은 줄이 바뀌어 협업 시 충돌하기 때문. 열거는 상세 문서 몫이다.

상세 문서 분리 기준: **구현이 실체를 갖는 시점**에 `.claude/design/<영역>.md` 로 뺀다. 몇 줄짜리 예정 항목까지 미리 쪼개지 않는다 (파일 하나당 Read 비용).

## 에셋 로드 규칙 (새 색·이미지 추가 시)

1. `SharedDesignSystem/Interface/Resources/Colors.xcassets`(색상, colorset 명 = HEX 예 `Color636777`) · `App/Resources/Assets.xcassets`(앱 에셋) 에 에셋 추가
2. `tuist generate` → Tuist 가 카탈로그를 스캔해 `Derived/Sources/TuistAssets+…` 접근자를 만든다. 화면에서 이걸 직접 쓰지 않고 **패밀리 enum 으로 감싸 노출**한다 — 생성 이름은 파일명 기계 변환(`color636777`·`icCancelMini`)이라 의미가 없다. 에셋을 지우거나 이름을 바꾸면 감싸는 층에서 **컴파일이 깨진다**(런타임 검출이 아님)
3. 이미지 토큰은 Figma 아이콘 패밀리별 enum(`Image.Cancel`·`Image.Plus`…) / 일러스트는 `Image.Img` — 멤버는 «색변형+크기»(`dark24`), 크기는 패밀리에 복수일 때만. 상세 규칙 `.claude/design/image.md`
