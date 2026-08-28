# 네비게이션 — 화면 전환·진행 위치를 다루는 컴포넌트

네비바·탭 줄·단계 인디케이터. 값을 바인딩으로 받아도(예: `TabSelector` 의 `selection`) **화면·영역 전환이 목적이면 여기**다.
**표는 이름 알파벳순으로 유지한다** — 새 행을 끝에 붙이지 말고 제자리에 끼워 넣는다(동시 추가 시 git 자동 병합).

| 컴포넌트 | Figma | API | 용도 |
|---|---|---|---|
| `DashIndicator` | progress bar 435:1575 · dash 435:1572 — on 435:1573 / off 435:1574 | `(count:current:)` | 진행 단계 대시 — **컨테이너가 px20/py4·gap2·h12 를 소유**하고 대시는 **등분(flex-1)** h4(on b800 / off g50). 조각에 그려진 20×4 는 컴포넌트 기본 폭일 뿐 렌더 폭이 아니다(375 폭·5단계에서 65.4). 조각 단독 공개 없음, «몇 번째까지 켜는가» 규칙만 갖는다 |
| `HilitNavigationBar` | Navigationbar — «Component System 3» 439:10241 — icon 439:10394~10397 · text 439:10398~10400 · logo 439:10401/10402 | **부착은 모디파이어만** (View 직접 배치 없음 — 타입은 `Surface`/`Trailing`/`Background` 를 담는 enum 네임스페이스): push `.hilitNavigationBar(_:trailing:surface:background:allowsSwipeBack:leading:onClose:)` · 루트 브랜드 `.hilitLogoNavigationBar(background:onProfile:)` · present `.hilitPresentedNavigationBar(_:trailing:surface:background:leading:onClose:)` · 변형 교체 `.hilitNavigationBar(_ kind:surface:background:allowsSwipeBack:)`. **어느 걸 쓰나 → 아래 «부착 — push vs present» · «상태 따라 변형 갈아끼우기»** | h44 네비바(0729 시안은 py14 로 52~54 지만 «기본 UI 를 토대로» 사용자 결정에 따라 시스템 표준 44 유지, 2026-07-31). **leading 은 3값 슬롯** — `.close`(기본 X) / `.back`(뒤로가기 화살표 `Image.Left`) / `.hidden`(시안 «왼쪽 아이콘 미노출»). 「X 통일, 뒤로는 하단 CTA·스와이프백 몫」이던 규칙은 2026-07-31 사용자 결정으로 뒤집혔다(화살표 필요한 화면 발생) — 기본값은 그대로 X, 액션은 둘 다 `onClose` → «닫기(X) 기본값과 override». 시안 «미노출» 3열은 전부 파라미터다 — 텍스트 `title: nil` · 오른쪽 `trailing: nil` · 왼쪽 `leading: .hidden`. **꺼도 슬롯 폭 40 은 비운 채 유지한다**(타이틀 중앙 보존 — 시안이 빈 박스를 그려둔 이유). 타이틀 sub7 중앙 · trailing 은 plus 아이콘 또는 텍스트 버튼(body5·g400·p8/p4 hug), 없으면 `trailing: nil`(시안 show 토글). `surface` = **바가 앉은 바닥의 톤** — `.filled` 면 바가 칠하는 바닥, `.transparent` 면 뒤 화면이 바닥(어두운 영상 위 흰 아이콘·흰 뒤로가기 = `.dark`). 아이콘 색변형(`default24`/`white24`)·타이틀색·`.filled` 배경색(white/b900 — 다크 화면 루트 채움과 같은 값)·상태바 글자색 네 값을 전부 파생 — 다크 바닥에 검정 X 같은 조합은 표현 불가(«아이콘 색을 축으로» 안 한 이유 — 갈리는 값이 넷인데 원인은 바닥 하나, 2026-08-01). mini 버튼의 `.hilitSurface` 와 같은 축·같은 이름이지만 네비바는 파라미터(빼먹으면 조용히 틀려서 명시가 안전). 다크 trailing 은 시안 없음(DEBUG assert). `background` 기본 `.transparent`(영상 풀블리드 — 콘텐츠 쪽 `.ignoresSafeArea()` 로 바 밑까지 깔림), 콘텐츠가 바 밑을 지나는 스크롤 화면은 `.filled` |
| `TabSelector` | tab 2044:4765 | `(_ items: [Item], selection: Binding<Tag>, layout: .hug/.fill)` · `Item(tag:title:isEnabled:)` | 밑줄 텍스트 탭 줄 — h38·px14/py8, 선택 시 아래 1.5 밑줄(b800). 상태는 **selection 바인딩에서 파생**(선택된 하나만 밑줄), 비활성은 `isEnabled: false`(글자 g500). 탭 조각 단독 공개 없음. 시안에 줄 배치가 없어 항목 간 간격 0 |

## 부착 — push vs present

네비바 룩은 하나인데 **부착 경로가 둘**이다. 시스템 네비바는 `NavigationStack` 이 그리는 물건이라 스택 밖에서는 아무것도 안 그려지기 때문 — 그래서 스택 없는 present 화면만 같은 룩을 손으로 얹는다.

**판별**: 이 화면이 스택 안에 있나. push 됐거나 스택의 루트면 `.hilitNavigationBar`, cover/sheet 로 올라온 **스택 없는 한 장짜리**면 `.hilitPresentedNavigationBar`. cover 안에 스택을 두는 위저드(온보딩)는 그 안의 모든 스텝이 push 쪽이다. 붙였는데 바가 조용히 안 보이면 스택 밖이라는 신호다.

```swift
// ① push — 스택은 코디네이터가 소유, 화면은 모디파이어만 붙인다
public var body: some View {
    content
        .hilitNavigationBar(
            "커리어 입력",                            // 타이틀 없으면 첫 인자 생략
            trailing: .text("건너뛰기") { send(.userTappedSkip) },
            background: .filled,                     // 콘텐츠가 바 밑을 지나면 filled
            allowsSwipeBack: !store.isSubmitting,    // 나가기 전 되물을 화면만 차단
            onClose: { send(.userTappedClose) }      // 생략 = X 가 자동 pop
        )
}

// ② present — 부모가 `.fullScreenCover { SettingsView(store:) }` 로 스택 없이 올린 화면
public var body: some View {
    content
        .hilitPresentedNavigationBar(
            "설정",
            background: .filled,
            onClose: { send(.userTappedClose) }      // 생략 = X 가 자동 dismiss
        )
}
```

present 경로가 push 와 다른 점 셋 — `allowsSwipeBack` 없음(스택 밖은 스와이프백 개념 자체가 없다) · 상태바 글자색은 화면 몫(다크 화면이면 `.preferredColorScheme(.dark)` 를 화면이 직접) · 좌우 여백이 시안값 px20(push 는 시스템 마진이라 수 pt 다르다 — «기본 UI 를 토대로» 결정에 따라 수용).

present `.filled` 의 채움은 상태바 자리까지 올라간다(`ignoresSafeArea(edges: .top)`) — `safeAreaInset` 은 세이프에어리어 **아래**에 앉아서, 바 44 만 칠하면 그 위 띠로 스크롤 콘텐츠가 그대로 비친다(마이페이지 2026-08-27).

배관 소유는 모디파이어다. push 는 타이틀 인라인·`navigationBarBackButtonHidden`·`toolbarBackground`·스와이프백 delegate 를, present 는 `safeAreaInset` 배치를 각각 감춘다. 슬롯 룩(아이콘 버튼·텍스트 버튼)은 `HilitNavigationBarSlot` 한 곳에서 공유하므로 스타일 변경은 거기만 고친다 — 두 경로가 갈라지지 않게 하는 지점.

`navigationBarBackButtonHidden` 이 끄는 엣지 스와이프백은 `Interaction/UINavigationController+SwipeBack.swift` 의 `SwipeBackPolicy` 가 **화면이 보이는 동안만 delegate 를 점유하고 반환**해 되살린다(전역 패치 아님 — 시스템 피커 오염 방지). 스와이프 pop 은 리듀서에 `popFrom(id:)` 로 도착한다(`backRequested` 아님).

## 상태 따라 변형 갈아끼우기

한 화면이 상태에 따라 **로고 바 ↔ X 바**로 갈려야 하면 `if/else` 로 모디파이어를 나누지 말고 변형을 **값**(`HilitNavigationBar.Kind`)으로 넘긴다. 모디파이어가 갈리면 SwiftUI 가 다른 뷰로 보고 화면을 통째로 새로 만들어 — 붙어 있던 `@State` 와 진행 중 애니메이션이 끊긴다.

```swift
.hilitNavigationBar(barKind, background: .filled)   // barKind: HilitNavigationBar.Kind

private var barKind: HilitNavigationBar.Kind {
    store.sheetDetent == .startInterview
        ? .standard(onClose: { send(.userSettledSheet(.report)) })
        : .logo(onProfile: { send(.userTappedProfile) })
}
```

변형이 고정인 화면(대부분)은 이걸 쓰지 말고 `.hilitNavigationBar(_:trailing:…)` / `.hilitLogoNavigationBar(…)` 를 그대로 쓴다 — 읽기 쉽고 인자 기본값이 붙는다. 실사용: `FeatureHome/Sources/Home/HomeView.swift`.

## 닫기(X) 기본값과 override

`onClose` 는 **leading 슬롯의 액션**이다 — `.close`(X)든 `.back`(←)이든 같은 자리, 같은 클로저를 쓴다(이름은 기본값 X 에서 왔다). 기본 동작은 «이 화면 나가기» — 생략하면 네비바가 `@Environment(\.dismiss)` 를 부른다(스택에 있으면 pop, present 됐으면 dismiss — SwiftUI 가 자동 분기). 어느 쪽이든 리듀서에는 `popFrom(id:)`/`PresentationAction.dismiss` 액션으로 도착하므로 상태를 우회하지 않는다.

**X 냐 ← 냐**: 플로우를 벗어나면 `.close`, 한 단계 되돌아가면 `.back`. 글리프만 다르고 배관은 같다.

**override** — 닫기 의미가 다르거나(플로우 전체 종료) 닫기 전에 되물어야 하는 화면은 클로저를 넘겨 리듀서가 소유한다. TCA 에서 가로채기 지점은 메서드 재정의가 아니라 리듀서 switch 다:

```swift
// ① 플로우 종료 override — 온보딩 스텝 (X = 위저드 전체 종료, delegate 로 코디네이터가 dismiss)
.hilitNavigationBar(background: .filled, onClose: { send(.userTappedClose) })

// ② 확인 팝업 override — 닫기 전 되묻기 (팝업 시안 생기면 이 패턴대로)
case .view(.userTappedClose):
    state.exitConfirm = ConfirmationDialogState { TextState("작성 중인 내용이 사라져요") … }
    return .none
case .exitConfirm(.presented(.confirmExit)):
    return .run { _ in await dismiss() }        // @Dependency(\.dismiss) — 자기 present 형태에 맞게 pop/dismiss
```

스와이프백도 같은 원리의 «나가기» 경로지만 override 가 불가능하다(제스처 시작을 되물을 수 없음) — 그래서 확인이 필요한 화면은 `allowsSwipeBack: false` 로 경로 자체를 끊고 X 만 남긴다.
