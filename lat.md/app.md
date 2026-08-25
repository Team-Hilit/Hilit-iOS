# App 도메인 — 코디네이터 (AppFeature)

앱 최상위 Reducer 겸 **화면 코디네이터**. 각 Feature 의 State 를 보유하고, **Feature 간(cross-feature) 전환은 여기서만** 조립한다. 각 Feature 는 서로를 모르고 `delegate` 로만 신호를 올린다. (현재 #6 은 스켈레톤 — AppFeature 는 골격이고 화면은 이관되며 채워진다.)

## 화면 구성
`Scope` 로 각 Feature 를 상시 임베드한다. App 은 `.feature` umbrella 를 link 하므로 자식 reducer 를 구체 타입으로 안다. Feature 끼리는 서로를 모른다.
- 현재 실 Feature 는 Home 뿐이고 **탭바가 없다** — 탭이 하나뿐인 `TabView` 는 바 자리만 차지하며 홈 배경 그라디언트가 반투명 바로 새어 나와 하단 초록 띠로 보였다(2026-08-05 제거). 홈은 `AppView` 가 `NavigationStack` 으로만 감싼다. 둘째 탭이 생기면 `TabView` + `Tab` enum + `selectedTab` 을 되살린다. → [[home]]
- 각 Feature 의 **도메인 내부** navigation 은 그 Feature 가 자체 처리(`Path`/`StackState`). AppFeature 는 관여하지 않는다.

## Cross-feature Routing
다른 Feature 로 넘어가는 전환의 **유일한 조립 지점**. leaf 가 직접 못 하고 코디네이터를 경유하는 이유 → DocC `FeatureInterface`, [[architecture]] D1·D3.

대표 흐름 — **Users 상세 → 프로필 편집** (둘은 서로 import 하지 않는다):
1. `UsersFeature` 가 `delegate(.editProfile(id))` 방출 → AppFeature 수신
2. 앱 레벨 sheet 로 Profile 제시: `state.editProfile = ProfileFeature.State(profileId: id)` (`@Presents` + `.ifLet`)
3. 저장 완료 `editProfile(.presented(.delegate(.profileSaved(profile))))` → sheet 닫고 `users(.profileUpdated(profile))` 로 결과 통보

대표 흐름 — **로그인 완료 → 홈 전환**:
1. `AuthFeature`(가입 플로우 코디네이터)가 기존 회원 로그인 또는 가입 온보딩 완료 시 `delegate(.signedIn)` 방출 (→ [[auth#가입 플로우]])
2. AppFeature가 수신해 `state = State()`로 초기화 후 `root = .home` — 새 로그인은 새 세션이므로 이전 사용자의 in-memory State(화면·선택값)를 버린다

대표 흐름 — **온보딩 완주 → 면접 → 홈 복귀** (2026-08-03):
1. `OnboardingFeature` 가 분석까지 끝내고 `delegate(.finished(sessionId))` 방출 → 위저드를 닫고 `state.interview = InterviewFeature.State(sessionId:)` 로 fullScreenCover 제시 (`.dismiss` 는 위저드만 닫고 홈 재조회 — «온보딩 위저드 진입» 4)
2. 면접 종료 두 신호 모두 `state.interview = nil` + 홈 재조회(`.home(.view(.onAppear))`) — 어느 쪽이든 잔여가 줄었을 수 있다(중도 이탈은 2026-08-09 부터 세션을 끝내지 않아 잔여가 그대로다 — [[interview#세션]]). 케이스를 합치지 않는 건 정상 종료에 리포트 상세(r1) 라우팅이 붙을 자리라서다 → [[interview#코디네이터]]
3. **면접 커버 중에는 전역 LoadingModal 을 끈다**(`AppView.showsGlobalLoading`) — 답변 제출·질문 스트림마다 전역 딤이 덮이면 면접이 끊겨 보이고, 타이머가 도는 화면을 잠그는 것 자체가 오동작이다. 면접은 자체 진행 표시(상태 칩·초읽기)로 대기를 말한다.

대표 흐름 — **홈 위젯② → 리포트 상세** (2026-08-05):
1. `HomeFeature` 가 [레포트 보기] 를 `delegate(.reportDetailRequested(sessionId:))` 로 올린다 — 목록 행의 id 가 곧 세션 id 다(→ [[home#진입 로드]])
2. AppFeature 가 `state.report = ReportFeature.State(sessionId:)` 로 fullScreenCover 제시 (`@Presents` + `.ifLet` + `AppView`). 리포트는 자체 NavigationStack 을 갖는 전면 흐름이라 sheet 가 아니다
3. **채점 상태로 진입을 막지 않는다** — 미생성(404)·GENERATING 은 리포트 화면이 스스로 폴링해 채운다(→ [[report#1차 리포트]]). 홈이 걸러 내면 같은 판정이 두 곳에 생긴다
4. 되돌아오는 신호는 `closeRequested` 하나 — 커버만 닫는다(리포트를 읽는 동안 잔여·목록이 바뀌지 않아 홈 재조회가 없다). 분석 부족의 «다시 연습하기» CTA 는 2026-08-06 에 제거됐다(재도전은 홈에서 «면접 시작» 으로 간다)
5. **리포트 커버 중에도 전역 LoadingModal 을 끈다** — 채점 대기 중 4초 폴링마다 전역 딤이 깜빡이고, 그 대기는 리포트 화면이 `loadState` 로 이미 말한다

대표 흐름 — **공유 딥링크 → 게스트 평가** (2026-08-07):
1. `HilitApp.onOpenURL` 이 `hilit` 스킴만 `deeplinkReceived(url)` 로 보낸다(그 외는 카카오 SDK 콜백). `GuestFeedbackDeeplink.parse` 성공 시 `state.guestFeedback = GuestFeedbackFeature.State(token:)` — cover 는 **루트 Group 밖**이라 스플래시·로그인 전에도 뜬다(무인증 플로우, → [[feedback#진입로와 닫기]])
2. 면접·온보딩 진행 중이거나 이미 게스트 cover 가 떠 있으면 무시 — 몰입을 끊지 않고, 진행 중 평가를 다른 토큰으로 갈아치우지 않는다
3. `guestFeedback(.presented(.delegate(.dismissed)))` → cover 를 닫고 **로그인 여부가 도착지를 정한다**(2026-08-14): 로그인 상태면 홈, 아니면 소셜 로그인 화면 — 둘 다 루트가 이미 들고 있어 cover 만 걷으면 드러난다. 손볼 건 판정이 안 끝난 루트뿐이라 `.splash`·`.splashFailed` 면 `resolveLaunchRouting()` 을 다시 태워 한쪽으로 내보낸다(게스트는 루트 판정과 무관하게 링크로 들어오므로 닫을 때 스플래시에 갇힐 수 있다). `.updateRequired` 는 풀지 않는다 — 여기서 풀면 강제 업데이트 차단이 뚫린다. 홈 재조회는 없다 — 게스트 평가는 사용자 데이터를 바꾸지 않는다. 게스트 cover 중에도 전역 LoadingModal 을 끈다 — G4 는 자체 loading phase 로 대기를 말한다

대표 흐름 — **마이페이지 → 세션 종료** (2026-08-08):
1. 홈 내비바 프로필이 `delegate(.profileRequested)` 방출 → `state.myPage = MyPageFeature.State()` 로 fullScreenCover 제시. 자체 상단 바를 얹는 한 장짜리 화면이라 NavigationStack 없이 덮는다
2. 닫기(`closeRequested`)는 cover 를 닫고 **홈을 다시 태운다** — 마이페이지에서 포폴을 지우거나 새로 올렸을 수 있고 「면접 시작」 카드가 그 값에 얹혀 있다(온보딩 이탈과 같은 이유)
3. 로그아웃·탈퇴는 마이페이지가 서버 호출과 로컬 토큰 정리까지 끝낸 뒤 **완료형**(`loggedOut`/`withdrawn`)으로 통보한다 — AppFeature 는 라우팅만 한다: `state = State()` + `root = .auth`(로그인 성공의 대칭) → [[mypage#주의사항]]

대표 흐름 — **마이페이지 리포트 줄 → 리포트·링크 생성** (2026-08-10):
1. 리포트 줄 두 버튼이 `delegate(.reportRequested(id:))`·`delegate(.feedbackRequested(id:))` 로 올라온다 — 행 id 가 곧 세션 id 라 홈 위젯②와 재료가 같다(→ [[mypage#주의사항]])
2. **마이페이지를 닫지 않고 그 위에 얹는다** — 목록에서 들어왔으니 닫으면 목록이 도착지다. 그래서 커버도 루트가 아니라 `MyPageView` 에 부착한다(루트에 두면 이미 떠 있는 마이페이지 커버에 가려 아무것도 뜨지 않는다)
3. 그 자리는 홈 경로의 `report` 와 **별도 State**(`myPageReport`)다 — 하나로 합치면 두 커버가 같은 값을 동시에 present 하려 들어 화면이 깨진다. 리듀서는 `ReportFeature` 하나를 두 자리에 각각 `.ifLet` 한다
4. [지인 피드백 받기] 는 링크 생성 화면이 목적지라 `entry: .peerFeedback` 으로 연다 — 메인을 거치지 않고 그 위에서 시작하고, 그 화면을 닫으면 메인이 아니라 흐름째 닫혀 목록으로 돌아온다(→ [[report#코디네이터]])
5. 되돌아오는 신호는 `closeRequested` 하나 — 커버만 걷으면 아래 마이페이지가 그대로 드러난다. 홈 재조회는 없다(리포트를 읽거나 링크를 만드는 동안 잔여·목록이 바뀌지 않는다)

## 첫 실행 정리

앱을 삭제해도 iOS 는 Keychain 을 지우지 않는다 — 재설치하면 토큰만 살아남아 Splash 가 «기존 세션» 으로 판정하고, 방금 새로 설치한 사용자가 로그인 상태로 들어온다. UserDefaults 쪽(온보딩 draft)은 앱과 함께 사라지므로 로컬끼리도 어긋난다. 그래서 판정을 시작하기 전에 «이 설치의 첫 실행인가» 를 묻고, 첫 실행이면 잔존 로컬 데이터를 지운다.

- **판정 근거는 «앱과 함께 사라지는 저장소에 찍은 마커»** — `FirstLaunchStore`(CoreCommon)가 UserDefaults 에 마커를 두고 `isFirstLaunch()`/`markLaunched()` 만 노출한다. 마커가 없다 = 이 설치에서 아직 실행 안 됨. 마커를 Keychain 에 두면 재설치 후에도 남아 첫 실행을 영원히 놓친다.
- **무엇을 지울지는 마커가 모른다** — 정리 대상 선택은 코디네이터(`AppFeature.clearLocalData()`)의 판단이고, 스토어 계약은 판정만 맡는다. 대상은 **Keychain 전체**(`KeychainWipe.wipeAll()` — 아이템 클래스 5종)와 온보딩 draft.
- **Keychain 은 `tokenStore.clear()` 가 아니라 전체를 지운다** — 그건 `account: "auth-tokens"` 한 항목만 지우는데, 여기 목적은 «앱이 남긴 것 전부» 라 항목이 늘면 조용히 새는 쪽이 된다. 전체 폐기를 `TokenStore` 계약에 넣지 않은 건 토큰 스토어의 책임이 자기 항목이기 때문이고, 앱 전체를 비우는 판단은 composition root(App 타겟 `KeychainWipe`) 몫이다.
- **UserDefaults 는 도메인째 지우지 않는다** — 첫 실행 마커가 거기 있어 통째로 날리면 다음 실행이 다시 첫 실행으로 판정된다. 지우는 건 draft 처럼 대상을 아는 항목뿐. dev 데이터 초기화 버튼만 예외로 도메인째 지운다 — 그쪽은 재설치 흉내가 목적이라 마커가 날아가는 게 맞다.
- **마커는 정리를 마친 뒤 찍는다** — 사이에서 앱이 죽으면 다음 실행이 다시 첫 실행으로 판정돼 정리를 끝내는데, 먼저 찍으면 지우다 만 상태로 굳는다.
- **정리가 세션 판정보다 먼저** — `onAppear` 가 정리 effect 를 돌리고 `firstLaunchResolved` 로 갈라 그때 판정을 시작한다. 같은 effect 안에서 이으면 순서가 코드 배치에 묻힌다. 같은 `merge` 에 나란히 걸리는 나머지 둘(미완 업로드 재개 — [[interview#업로드 큐]] · 앱 사망 세션 정리 — [[app#Cross-feature Routing]])은 그 순서에 얽히지 않아 함께 뿌린다.
- 정리 함수는 **dev 데이터 초기화 버튼과 공유**한다 — 지울 로컬 목록이 두 곳에서 갈라지면 한쪽만 늘어난다.

## Splash 세션 복구

앱 진입 판정은 `firstLaunchResolved` 의 effect 하나다 (그 앞에 [[app#첫 실행 정리]]가 선다) — 버전 게이트 → 토큰 유무 → `pending` **한 콜**로 `State.root` 를 정한다. refresh 를 먼저 부르지 않는다 — Access 는 3시간이라 대부분 살아 있고, 만료면 이 콜의 403 을 AuthorizedNetworkClient 가 재발급·재시도로 흡수한다([[api#토큰 수명주기]]).

목적지 표·시퀀스는 [launch-routing](../docs/work/launch-routing.md), 게이트 규칙은 [[auth#게이트 2단 체인]].

런치스크린은 **storyboard 로 SplashView 를 흉내낸다** — `App/Resources/LaunchScreen.storyboard` 가 같은 로고(171×72, 화면 중심 -50)를 흰 판 위에 그려, 시스템 런치 화면 → 앱 첫 프레임 사이에 빈 흰 판이 스치지 않는다. `UILaunchScreen` dict 는 이미지 크기·위치를 못 잡아(늘어난다) 쓰지 않고 `UILaunchStoryboardName` 으로 간다 — 두 키가 함께 있으면 dict 가 이기므로 dict 는 두지 않는다. 로고 SVG 는 App 에셋 카탈로그에 **복사본**을 둔다: 런치스크린은 앱 코드가 돌기 전 메인 번들에서 읽어 DesignSystem 번들 에셋에 닿지 못한다. 값 3개(로고 크기·오프셋·배경)는 SplashView 상수와 짝이고 자동 동기화가 없다 — 한쪽을 바꾸면 다른 쪽 제약도 고친다.

`root` 가 Bool 2개가 아니라 **enum**(`splash`·`splashFailed`·`updateRequired`·`auth`·`home`)인 이유: 「판정 실패라 재시도해야 하는 상태」를 Bool 조합으로는 못 만든다.

- **버전 게이트가 세션 판정보다 먼저** — FORCE 를 뒤에 두면 이미 홈에 들어간 뒤에 막게 된다. 무인증 API 라 토큰과 무관하게 돌릴 수 있고, 실패는 **fail-open**(버전 정책 서버 장애가 앱 실행을 막지 않는다) → [[api#AppVersion]].
- **FORCE 는 `root = .updateRequired`** — 세션 판정을 시작하지 않는다. 알럿에 «나중에» 버튼을 만들지 않고, 스토어를 다녀와도 알럿을 다시 세워 차단을 유지한다. OPTIONAL 은 안내만 얹고 판정을 계속한다.

- **판정 실패는 두 갈래** — `ConsentError.sessionExpired`(자동 재발급까지 실패, 토큰은 인터셉터가 이미 폐기)는 재로그인, 네트워크·5xx 는 **판정 불가**라 토큰을 살린 채 `splashFailed`. 뭉뚱그리면 오프라인에서 앱을 켠 사용자가 로그아웃당한다.
- **`splashFailed` 에서 로그인 화면으로 내보내지 않는다** — 토큰이 살아 있으므로 `SplashView(onRetry:)` 자리에 머문다.
- **판정 결과는 `AuthFeature.State(resuming:)` 로 넘긴다** — 게이트 분기 코드는 코디네이터 한 곳에만 있고, AppFeature 는 목적지(login·resume·home·failed)만 고른다. 조회한 약관 항목도 함께 넘겨 화면이 `pending` 을 다시 부르지 않는다.
- 판정은 `consentClient`·`appVersionClient` 도 쓴다 — cross-feature 조립 자리라 Domain 의존이 여기 모인다(authClient 와 같은 이유).
- **Splash 계열 루트에서는 전역 로딩(`LoadingModal`)을 얹지 않는다** — 판정 API 가 도는 동안이 곧 Splash 가 떠 있는 이유라 로딩 판을 덮으면 브랜드 화면만 가리고, `.updateRequired` 는 알럿과 딤이 겹친다. `AppView.showsGlobalLoading` 이 `default` 없는 switch 라 루트가 늘면 컴파일이 깨져 판단을 강제한다 → [[domain.map#네트워킹 인프라]].

대표 흐름 — **dev 데이터 초기화** (Home 임시 버튼, 2026-08-03 로 통합 — 이전의 온보딩 진입·디버그 로그아웃 두 버튼을 대체):
1. dev 계에서만 `AppFeature.onAppear` 가 `home.showsDevReset` 을 켜고, Home 버튼이 `delegate(.appDataResetRequested)` 방출
2. AppFeature 수신 → effect 에서 `authClient.logout()`(서버 로그아웃) → `clearLocalData()`(Keychain 전체·온보딩 draft — [[app#첫 실행 정리]]와 공유) → `UserDefaults.removePersistentDomain`(앱 도메인 전체). 순서가 중요하다 — 로그아웃은 토큰이 있어야 서버에 닿으므로 Keychain 삭제보다 먼저다. 서버 실패해도 로컬 정리는 진행(`try?`). 도메인째 지워 **첫 실행 마커까지 날리는 건 의도** — 이 버튼만은 재설치 흉내가 목적이라 다음 콜드 스타트가 첫 실행 정리를 한 번 더 돌아도 지울 게 없어 손해가 없다(정리 쪽이 마커를 보존하는 이유와 반대 방향이다)
3. `appDataCleared` 로 `state = State()` 리셋 후 **`resolveLaunchRouting()` 재실행** — 로그아웃과 달리 `root = .auth` 로 확정하지 않고 Splash 판정부터 다시 태운다. 지운 게 세션만이 아니라 로컬 저장소 전부라 재설치 직후와 같은 자리여야 버전·동의·프로필 게이트가 모두 다시 돈다. cross-feature 조립이라 authClient 의존은 코디네이터인 여기서만 가진다 → [[home]]

대표 흐름 — **온보딩 위저드 진입**:
1. 발원지 2곳 — 「면접 시작」의 [시작하기](`interviewStartRequested`)·확인 단계를 통과한 [처음부터 시작](abandon 성공 후 `interviewAbandonResolved`). 어느 쪽이든 **위저드부터**다: 면접 화면이 `sessionId` 로만 열리는데 그 id 를 만드는 건 위저드의 세션 생성뿐이라서다(포폴 재사용 분기는 2026-08-08 폐기 — [[home#진입 로드]])
2. AppFeature 수신 → `state.onboarding = OnboardingFeature.State(userName:)` (`@Presents` + `.ifLet`) → `AppView` 가 `fullScreenCover` 로 위저드 제시. 분기 재료(`variant`)는 홈이 진입 로드로 이미 정해 둔 값을 읽는다
3. 온보딩 `delegate(.finished(sessionId:))` = **세션 준비 완료** → 위저드 cover 를 닫고 그 자리에서 `state.interview = InterviewFeature.State(sessionId:)` 로 면접 cover 를 연다. **진행 중 보관을 여기서 연다**(2026-08-21 복원) — `HeldSessionStore.save(sessionId, 0초, hasStarted: false, 표식 없음)`. 서버 세션이 생기고 **이용권이 잡히는** 바로 그 순간이라 여기여야 한다: 회수 경로의 입구가 전부 `load()` 라, 장부가 비어 있는 구간에서 이탈하면 그 이용권을 되찾을 동선이 사라지고 [시작하기] 는 세션을 하나 더 만든다(2026-08-18~21 의 #130 이 그 구간을 만들었다). 표식을 **안 찍는** 게 핵심이다 — 찍으면 앱을 껐다 켠 순간 죽은 프로세스 값이 되어 킬 클린업이 세션을 닫는다. 시작 전 세션도 홈 카드가 되고([[home#진입 로드]]), `hasStarted` 는 그 카드의 [이어서 진행] 목적지만 가른다. 플래그는 시작하기 탭이 올리고, 누적초는 백그라운드 마감마다 찍는다([[interview#코디네이터]]·[[interview#세션]]) → [[interview]]
4. 중도 이탈 `.dismiss` → cover 만 닫고 **`.home(.view(.onAppear))` 를 명시로 보내 홈을 다시 태운다** — cover 를 닫는 것만으론 홈 `onAppear` 가 다시 오지 않는다. 홈 위에서만 열리므로 **로그인 이후**라 토큰을 보유한다(온보딩 API 는 인증 필요) → [[onboarding]]
5. 면접 `delegate(.finished)`(리포트 대기 → 홈)·`.closed`(중단·실패 닫기) → 둘 다 cover 닫고 홈 재조회 — 어느 쪽이든 잔여가 줄었다. 정상 종료의 리포트 상세(r1) 연결은 `InterviewReportFeature` 통합 후(TODO)
6. 정상 종료(`.finished`)에서만 `onboardingDraftStore.clear()` + **`HeldSessionStore.clear()`**(완주 = 더는 진행 중이 아니다) — 온보딩 입력 draft 가 제 역할을 다한 지점이 여기다([[onboarding#입력 draft]]). **삭제가 홈 재조회보다 먼저**여야 해서 effect 가 아니라 리듀서 본문 동기 호출이다 — `.merge(.run{clear}, .send(onAppear))` 로 두면 `.send` 가 먼저 도착해 홈 held 판정(onAppear 본문의 동기 load)이 옛 보관값을 읽고 끝난 면접을 [이어서 진행] 으로 그린다. 이탈(`.closed`)은 둘 다 보존 — draft 는 같은 입력으로 다시 시작할 재료, 보관값은 홈 [이어서 진행] 의 재개 재료다. **준비 화면 이탈(시작 전)도 마찬가지로 보존한다**(2026-08-21): 그 세션이 이용권을 잡고 있어 서버에서 닫아 버리면 사용자가 되찾을 길이 없다 — 버릴지 이어갈지는 홈 카드의 두 갈래가 묻는다

**진행 중(held) 면접 두 갈래** (2026-08-08 배선 — 발원은 [[home]] 의 `interviewRestartRequested(sessionId:)`·`interviewResumeRequested(sessionId:)`, id 는 홈이 로컬 보관값에서 읽어 싣는다):
- [처음부터 시작] → `abandonSession(sessionId, .userExit)`(진행분 리포트 트리거 — 시안 «이용권이 하나 차감됩니다.» 의 근거) → 성공 또는 409 `sessionAlreadyEnded`(이미 중단 완료로 간주) → 보관값 clear + `discardRecording()`(끝난 세션의 세그먼트는 재개 재료가 아니다 — 안 걷으면 프로세스가 사는 동안 tmp 에 남는다. 원장이 그 세션을 아직 소유해 `purgeRecordings` 는 no-op 이라 discard 가 맞다) → `interviewAbandonResolved` 가 [시작하기] 와 같은 위저드를 연다(사용자 결정 2026-08-08). 그 외 실패는 보관값·세그먼트 유지 + 화면 유지(세션이 서버에 살아 있다 — 안내 토스트 미도안 TODO).
- [이어서 진행] → `checkResume` → RESUMABLE 이고 **장부가 `hasStarted false`(시작 전)면 `confirmResume` 을 건너뛰고** `interviewReadinessResumeResolved(sessionId:)` 로 같은 세션의 **준비 화면**을 다시 연다(2026-08-21) — 확정할 다음 턴이 없고 사용자는 카메라 확인·가이드를 아직 보지 않았다. 새 세션을 만들지 않는 게 요점이다(그게 이용권을 한 장 더 잡던 경로다). 시작 후면 `confirmResume` → `interviewResumeResolved(sessionId:question:)` 가 그 최신 질문과 보관값의 **근사** 누적초를 `InterviewResumeSeed` 로 실어 면접 cover 를 연다 — `State(sessionId:resume:)` 라 readiness 를 생략하고 세션으로 직행한다(TODO #69 해소, 2026-08-08). raw 축 확정은 세션 진입의 `startRecording` 반환(에셋 실측) 몫이다 → [[interview#세션]]. ENDED·`sessionEnded` 레이스·`nextQuestion` 부재는 셋 다 «끝난 세션» 으로 접어 보관값 clear + `discardRecording()` + 홈 재조회로 변형을 되돌린다(세그먼트를 함께 걷는 건 위 [처음부터 시작] 과 같은 이유다 — `.interrupted` 만이 세그먼트를 남기는 이탈이다)(홈 경로의 INVALID → SttFailure 화면은 여전히 TODO — 준비 화면 복귀 쪽엔 있다, [[interview#코디네이터]]).

⚠️ **네 갈래 모두 «await 뒤 장부 재검증» 이 필수다**(2026-08-21 리뷰): `load()` → 네트워크 왕복 → `clear()`·`discardRecording()`·라우팅 순서라, 왕복 사이에 다른 액션이 장부를 지우거나(완주·중단) 새 세션을 저장하면(온보딩 완주) 뒤따르는 정리가 **남의 장부·남의 세그먼트**에 꽂히고 [이어서 진행] 은 B 의 `hasStarted` 로 A 를 라우팅한다. 재검증은 store 계약 두 연산으로 모았다 — **삭제는 `clearIfHolding(sessionId) -> Bool`**(확인+삭제가 한 연산, live 는 네 연산을 한 락으로 세운다: `load()` 확인 뒤 `clear()` 를 부르면 그 사이가 열려 있다), **라우팅 재료 읽기는 `load(matching:)`**. 세그먼트 폐기·홈 재조회는 `clearIfHolding` 이 true 를 준 쪽에만 딸려간다 — 어긋나면 그 effect 는 그냥 멈춘다(장부를 바꾼 쪽이 자기 후속을 이미 들고 있다).

**끊긴 면접 되돌리기 3건** (2026-08-08 — 설계 [interview-resume](../docs/superpowers/specs/2026-08-08-interview-resume-design.md)):
- 면접 `delegate(.interrupted)`(백그라운드 진입으로 동결된 세션 — [[interview#코디네이터]]) → cover 만 닫고 홈 재조회. 종료 두 신호와 달리 **보관값을 보존**한다: 그게 재접속 카드의 재료이고, 카드의 «남은 질문 N개» 환산이 여기서 처음 실값(백그라운드 마감이 갱신한 누적초)을 받는다 → [[home#진입 로드]]. 도달 시점이 **백그라운드 진입 직후**인 게 핵심이다(2026-08-09 개정) — 사용자가 화면을 안 보는 사이에 닫아야 복귀가 곧장 홈이다. 복귀 판정을 기다렸다 닫던 옛 순서는 그 GET 왕복 동안 면접 화면을 깜빡였다.
- **복귀 시점 보관값 검증** — `AppView` 가 `scenePhase == .active` 를 `sceneBecameActive` 로 올리면, 면접·온보딩 cover 가 없는 홈에서만(그 위라면 그 흐름이 스스로 판정한다) 살아 있는 프로세스의 보관값에 `checkResume` 을 건다. ENDED 면 보관값 clear + `discardRecording()` + 홈 재조회 — 20분 넘긴 백그라운드가 «카드 없이 홈» 으로 돌아오는 근거다(스펙 ③). 위 즉시 이탈로 면접 흐름이 사라진 뒤라 판정할 자리가 루트뿐이라서 여기 있다. 대상 술어는 킬 클린업의 정확한 **반대**(`isResumableInCurrentProcess`)라 둘이 겹치지 않는다. 실패(오프라인)는 삼킨다 — 보관값을 남겨 다음 복귀나 카드 탭이 다시 묻는다. INVALID 도 카드를 걷는 것까지다(띄울 면접 흐름이 없다).
- **앱 사망 세션 정리(킬 클린업)** — `onAppear` 의 세 번째 effect 다(실행 시점 훅이 유일한 회복 수단이라 첫 실행 정리·업로드 재개와 나란히 건다 — [[app#첫 실행 정리]]). «무엇을 정리할지» 판정은 순수 함수 `HeldSessionCleanup`([[interview#Client 계약]])이 내리고 여기선 효과만 싣는다: 대상(죽은 프로세스의 진행분)이 있으면 `checkResume` → RESUMABLE 이면 `abandon(USER_EXIT)`(진행분 리포트 생성) → 보관값 clear → `purgeRecordings(sessionId:)`. 409 `sessionAlreadyEnded` 는 성공 취급, 404 는 내 세션이 아니니 로컬만 걷고, 그 밖의 실패(오프라인·미로그인)는 **보관값을 유지**해 다음 실행이 재시도한다 — 그동안 홈 카드는 프로세스 토큰 필터가 막아 준다. clear 를 purge 보다 먼저 해 홈이 먼저 그려져도 죽은 카드가 뜨지 않는다. 파일 정리를 위해 App 이 `.domain(interface: .recording)` 을 의존한다 → [[interview#프리뷰]]

`State(userName:)` 만 넘긴다 — 직군·연차는 위저드가 다루지 않는다(세션 생성이 서버 프로필 스냅샷을 쓴다, 2026-08-04). 예전엔 두 값을 주입받아야 프리로드가 세션을 만들 수 있었고 배선이 없어 항상 실패했다 → [[onboarding#프리로드]]

→ 큰 그림은 [[domain.map]].

## 주의사항
코디네이터 패턴을 유지하기 위한 규칙.
- **Feature → Feature 의존 0.** 새 cross-feature 전환이 생기면 leaf Feature 엔 `delegate` case 만 추가하고, 조립(State 생성·제시·결과 통보)은 전부 여기서 한다. 직접 import/push 금지.
- 다른 Feature 의 reducer/State 를 구체 타입으로 참조해도 되는 **유일한 자리**(owner/코디네이터). leaf 끼리는 금지.
- 새 화면은 `State` + body `Scope` 를 추가하고 `AppView` 에서 제시한다. 탭바를 되살리는 경우(둘째 탭)만 `Tab` enum·`selectedTab`·`TabView` 를 함께 복원. → DocC `AddingFeature`
