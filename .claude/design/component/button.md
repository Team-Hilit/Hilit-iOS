# 버튼 — 탭하면 액션이 실행되는 컴포넌트

`ButtonLarge`(View) + ButtonStyle 4종 + 환경 모디파이어. 값을 바인딩으로 주고받는 위젯은 여기 아니라 `input.md`.
**경계 규칙: 레이아웃·슬롯을 소유하면 View, `Button` 하나를 스킨하면 ButtonStyle.**

전 티어 공통 — 모서리 0(캡슐 아님) · 색은 팔레트 23색 안(**로그인 버튼의 브랜드 색만 예외** — `Color.Brand`, `design/color.md`) · 아이콘은 축이 아니라 **라벨 구성**(호출부가 조립).
**상태는 넘기지 않는다** — pressed·disabled 는 `configuration.isPressed`/`@Environment(\.isEnabled)` 가 자동 처리하고, disabled 는 배색(tone)이 무엇이든 같은 룩으로 수렴한다. 다만 **판(`.hilitSurface`)은 disabled 를 가른다** — 어두운 판에서 밝은 disabled 판을 쓰면 오히려 활성처럼 튀어서다.

## 티어 카탈로그

Figma 버튼 7종을 옮긴 체계. (이 표만 알파벳순이 아니다 — 크기 티어 순서(large→medium→mini→sub→tag)가 정보라서. 닫힌 카탈로그라 행이 늘 일도 거의 없다.)

| 대상 | Figma | API | 비고 |
|---|---|---|---|
| `ButtonLarge` 단일 | button-large/bottom 435:691 · /modal 435:711 | `ButtonLarge(_ title:, _ kind: .bottom/.modal, tone: .dark/.light, action:)` | h55·sub7. 시트 행 축이 `dark`(검정 채움)/`light`(흰 바탕 + b800 테두리 `outline-sb`)라 파라미터도 그 이름. 열 축 pressed·disabled 는 파라미터가 아니다(위 공통 규칙대로 자동 — pressed 는 dark g900/light g100). disabled 는 **판**이 가른다: 밝은 판은 판까지 죽어 g50(tone `.light` 는 흰 판) + g300 라벨, 어두운 판(`.hilitSurface(.dark)`)은 **배경·테두리가 활성 그대로**고 라벨만 g400 (시트 `light/dark` 축 dark·disabled 2117:10194). bottom = px24·pt22/pb10·배경이 안전영역까지 / modal = px8·py16. `.light` 는 bottom 전용(DEBUG assert) |
| `ButtonLarge` 2버튼 | bottom/filled-2 · modal/dubble | `ButtonLarge(_ kind:, tone: .dark/.gray/.twoColor) { } trailing: { }` | divider 1×25. 시트 `default`=`.dark` · `gray` · `2 color`=`.twoColor`. **시트 `1 disabled` 칸은 배색이 아니라 상태 — 그 자식에 `.disabled(true)`** 로 표현하고 별도 변형을 두지 않는다. `.gray` 는 bottom 전용. **`.twoColor` 는 full-bleed** — 컨테이너 패딩 0 이고 반쪽이 각자 배경+여백(bottom pt22/pb10)을 가져 375 폭에서 반쪽이 정확히 187.5. 공유 배경 톤(`filled-2`·`2button-1disabled`)만 컨테이너가 pt20/pb10 을 갖는다(단일 22 와 다르다) |
| `ButtonLarge` 로그인 | button-large/login 435:812(kakao) · 435:809(apple) | `ButtonLarge(_ title:, login: .kakao/.apple, showsLogo: Bool = true, action:)` | h56·px8/py16·gap8·로고 24(높이를 56 으로 잡는 값). kakao = `Color.Brand.kakao` 바탕 + b900 라벨 / apple = b900 바탕 + 흰 라벨 — 배경·라벨색·로고가 제공자 한 벌. `showsLogo` 가 Figma `icon` 축. 시안엔 default 만 있어 pressed(불투명도)·disabled(g50+g300)·loading 은 가족 규칙으로 수렴. `.login` kind 는 이 init 이 알아서 넣는다(직접 넘기면 DEBUG assert — 단일·2버튼 시안이 없다) |
| `.medium(_:layout:)` | button-medium | `.buttonStyle(.medium(.green))` · `.medium(.blue, layout: .fill)` | h45·py12. 시트는 **status 행 × color 열**이지만 **행이 색에서 파생**된다 — outlined 행 = default·gray(흰 판)·green·blue·red(옅은 색 판), filled 행 = black 하나(테두리 없음). 같은 색이 두 행에 걸치는 칸이 없어 `Style` 은 파라미터가 아니라 `Tone.style` 파생값이다(mini 와 다른 점 — 거기선 black 이 두 칸을 가져 진짜 축). 한 색이 두 행을 갖게 되면 그때 파라미터로 승격. disabled 열은 색 무관 한 룩(g50·g300)으로 수렴. blue·red 만 SemiBold. `layout` — `.hug` px24(기본) / `.fill` 등폭(가로패딩 0, 넘치면 축소) → HStack 에 나란히 놓아 **N지선다 척도 칩** |
| `.mini(_:style:layout:typography:)` | button-mini 435:739 · with-icon 439:10204(light)·439:10205(dark) | `.buttonStyle(.mini(.gray, layout: .withIcon))` · `.mini(.black, style: .outlined)` | h34·py8·hug. 시트가 **color 행 × status 열** 두 축이라 파라미터도 둘 — `tone` 4종(black·filled·gray·green) × `style`(`.default`/`.outlined`). 시트의 pressed·disabled 열은 파라미터가 아니다(위 공통 규칙대로 자동). `.outlined` 는 시안상 **black 행 전용**(DEBUG assert). 가로 여백은 `layout` — textOnly px12 / withIcon px8. **`.gray` 팔레트만 `layout` 에 걸린다** — 시트가 gray 를 두 곳에 그려서다: 본체 `gray` 행은 라이트 시트 위에서도 **어두운 판 고정**(g900+g300, 판 무관), `with icon` 행만 light(g100+b800)/dark(g900+흰 라벨, 439:10205) 두 칸이라 `.hilitSurface` 를 탄다. disabled 도 시트가 두 칸을 다르게 그린다 — black 은 밝은 판(g50+g300), gray 는 제 어두운 판(g800+g500) 유지. 글자 크기는 `typography`(기본 `.body5`) — 같은 배색·같은 여백에 **16pt 로 그려진 인스턴스**가 있어서다(리포트 상세 질문 탭 443:7284 — 선택 `.body2` / 미선택 `.body3`). 티어를 새로 만들지 않고 이 축만 열었다 |
| `.miniSub(_:)` | button-mini 의 `sub` 행 | `.buttonStyle(.miniSub(.white))` | h26·px8/py4·테두리 1.0. 색 3종 black/white/none. 이 행만 status 축이 없어 타입도 `Tone` 하나다(mini 본체와 다른 점) |
| `.tag(_:)` | ButtonTag 1941:6762 | `.buttonStyle(.tag(.selected))` | h29·px12/py4. 3상태 default/selected/completed — selected 는 Bold, completed 는 opacity 20% |
| `.hilitSurface(_:)` | `light/dark` 축 | `VStack { … }.hilitSurface(.dark)` | 화면이 한 번 선언 → 하위 `.mini` 팔레트와 `ButtonLarge` 단일 **disabled** 배색 전환. 버튼 속성이 아니라 화면 속성이라 Environment |
| `.hilitButtonLoading(_:)` | **시안에 없음** | `ButtonLarge(…).hilitButtonLoading(true)` | 라벨을 감추고 스피너를 얹어 폭 유지 + 탭 차단. 앱 사정이라 Figma 에서 찾지 말 것 — 화면에서 만들 수 없어(밖에서 `.opacity` 를 걸면 배경까지 사라짐) DS 에 둔다. **`LoadingModal`(435:1543)과 혼동 금지** — 그쪽은 시안에 실재하는 화면 전체 로딩 모달이고, 이건 버튼 스코프 오버레이다 (`component/display.md`) |

## 규칙을 가진 래퍼

**설탕 래퍼를 두지 않는다.** 스타일을 그대로 쓴다 — 인자만 옮겨 담는 래퍼는 이름만 하나 더 외우게 한다.
감싸는 타입은 **«규칙»을 가질 때만** 만든다. 외형만 바꾸는 건 스타일 파라미터로 충분하다.
**이 표는 이름 알파벳순으로 유지한다** — 새 행을 끝에 붙이지 말고 제자리에 끼워 넣는다(동시 추가 시 git 자동 병합).

| 컴포넌트 | Figma | API | 갖는 규칙 |
|---|---|---|---|
| `ChoiceChip` | button-medium 2150:7297 | `(_ label:, isSelected:, tone: .positive/.negative, layout: .fill/.hug, action:)` | N지선다 척도 칩 — HStack 에 나란히. 외형은 `.medium(layout:)` 이 그리고, 이 타입은 **«선택 상태 → 톤»** 규칙만 갖는다. `layout` 기본 `.fill`(등폭), 라벨이 길어 가로 스크롤로 흘릴 땐 `.hug` |
| `VideoControl` | video-control 435:830(play) · 435:837(pause) | `(isPlaying:, onSkipBackward:, onPlayPauseToggle:, onSkipForward:)` | 영상 컨트롤 한 줄 254×74 — 스킵은 44 히트박스 안 34 글리프, gap 46, 중앙은 74 정사각 g500 판(34 글리프 + p20, 모서리 0). **«상태 → 글리프»** 규칙을 갖는다: `isPlaying` 이면 ⏸(누르면 멈춤). 시안 변형 이름과 글리프가 뒤집혀 있어 이름이 아니라 글리프로 매핑했다(사고 사례 8·17번). 시안 backdrop blur 11.563 은 판이 불투명해 뺐다. 폭·위치는 호출부 몫 |

## 아직 DS 아님 — 인라인 유지

Figma 에 이름이 붙어 있지만 사용처가 하나뿐이라 승격하지 않은 버튼. 두 번째 사용처가 생기면 `component.md` 승격 규칙대로 올린다.

| Figma | 지금 사는 곳 | 값 |
|---|---|---|
| button-optional 439:10206 (라벨 2227:4460) | `GuestEvaluationView.emptyCommentLabel` (FeatureGuestFeedback) | p12 균일 · gap8 · `plus/16px/default` · `body6` g900 라벨 · 회색 `TagLabel` · dashed g100 `outline-m` · 모서리 0 |

## Figma 원본 불일치 — 디자이너 확인 대기

① `bottom/filled-2/gray` 라벨은 b800 인데 `2color` 왼쪽 라벨은 g700(같은 g50 배경) ② `modal/dubble-button/1color` 세로 padding 15(나머지 modal 전부 16 — 오타로 보고 16 구현) ③ `Medium/black` 은 `status=outlined` 인데 테두리 없음. 셋 다 시안대로 구현했다. ④ 지인 피드백 화면의 다크 CTA 비활성(443:8046)은 g900 판 + 흰 라벨인데 컴포넌트 시트 `dark/disabled`(2117:10194)는 b800 판 + g400 라벨 — 나중에 그려진 시트를 정본으로 삼아 그 화면도 시트를 따른다.
