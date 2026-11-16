# Auth 도메인 — 소셜 로그인 (DomainAuth · FeatureAuth)

카카오·애플 소셜 로그인(자격증명 획득)과 서버 세션 수명주기(교환·재발급·로그아웃 — [[api#Auth]])를 책임지는 도메인. 토큰 영속화는 Keychain(TokenStore), 만료 시 자동 재발급은 AuthorizedNetworkClient — 둘 다 CoreNetwork 인프라다([[api#토큰 수명주기]]).

## 모듈 구성

공개 seam은 `AuthClient` 파사드 하나 — SDK 접점(configure·handleOpenURL·signIn)과 서버 세션(login·refresh·logout·check·isAuthenticated). → [[architecture]]

소셜 SDK·시스템 프레임워크는 `DomainAuthImplementation`의 provider 클래스(KakaoLoginProvider·AppleLoginProvider)에 격리되고 Interface·Feature·App은 이를 모른다.

signIn은 `SocialCredential`을 반환한다 — provider별 발급물이 달라 enum이다: 카카오는 accessToken(login 교환의 credential)/refreshToken(SDK도 자체 보관), 애플은 identityToken(백엔드 검증용 JWT)/authorizationCode(백엔드가 애플 서버와 교환할 5분 TTL 일회성 코드 — D14 는 이것을 credential 로 받는다). credential은 액션 payload로만 흐르고 State에 보관하지 않는다 — `login(credential)` 교환에 즉시 소비될 값이라, State의 토큰은 소비자 없는 죽은 데이터가 된다.

login 성공 시 토큰 페어는 TokenStore(Keychain)로 들어가고 Feature 는 토큰을 만지지 않는다. 서버 에러는 `AuthError` 로 매핑된다(invalidCredential·sessionExpired·serverUnavailable·networkFailure) — 매핑표는 [[api#Auth]].

## Provider 확장 지점

`SocialProvider` enum과 Implementation 내부 `SocialLoginProvider` protocol이 확장 자리다. 애플 로그인이 이 지점으로 추가됐다 — `case apple` + `AppleLoginProvider` + signIn switch 한 갈래. 카카오 로그인 흐름은 무변경(SocialCredential enum 마이그레이션으로 생성 문법 1곳만 갱신). 다음 provider도 같은 경로로 늘어난다.

## 카카오 로그인 흐름

`KakaoLoginProvider`가 `UserApi.isKakaoTalkLoginAvailable()`로 카카오톡 앱/웹 로그인을 분기한다. SDK의 `SdkError`는 이 파일 안에서만 소비된다 — 취소(`ClientFailed(.Cancelled)`)만 `AuthError.cancelled`로 구분해 얼럿 없이 조용히 복귀하고, 나머지는 `.unexpected`로 정규화된다.

SDK 수명주기 접점(초기화 `configure`·콜백 전달 `handleOpenURL`)도 `AuthClient` 엔드포인트다 — App은 lifecycle 이벤트를 seam에 연결만 하고 KakaoSDK를 직접 import하지 않는다.

알려진 한계: 카카오톡 앱 로그인에서 승인/거부 없이 앱 스위처로 복귀하면 SDK completion이 불리지 않아 로딩이 유지된다 — 유예기간 처리는 다음 마일스톤(백업 브랜치의 lat.md/auth.md 참조).

## 애플 로그인 흐름

`AppleLoginProvider`가 `ASAuthorizationController`를 continuation으로 감싼다. 취소(`ASAuthorizationError.canceled`)만 `AuthError.cancelled`로 구분해 얼럿 없이 복귀하고, 나머지는 `.unexpected`로 정규화된다 — ASAuthorization 타입은 이 파일 밖으로 나가지 않는다.

카카오와 달리 SDK 초기화·콜백 URL이 없어 configure/handleOpenURL은 카카오 전용으로 남는다. name/email 스코프는 요청하지 않는다 — 이 슬라이스엔 소비자가 없고, 최초 승인에만 오는 값이지만 출시 전이라 설정에서 revoke 후 재승인으로 재획득 가능하다. 백엔드 수신 필드가 확정되면 스코프와 payload를 함께 확장한다.

Sign in with Apple entitlement가 App 타겟에 필요하다(`TargetFactory.entitlements` — 시뮬레이터는 entitlement만으로 동작, 실기기는 Apple Developer 포털에서 App ID capability 활성화 필요). Example 앱은 스텁 authClient라 entitlement이 없다.

## 가입 플로우

PRD Part 6·7 확정(2026-07-31)으로 FeatureAuth 가 로그인 단일 화면에서 가입·계정 플로우 전체로 확장됐다. 화면 매핑·미결의 단일 소스는 [home-account](../docs/work/home-account.md) §2 — 여기는 구현 구조만. UI 는 전부 Figma 수령 전 골격이다.

`AuthFeature` 가 플로우 코디네이터다 — 루트 `AuthCreateAccountFeature`(A0 소셜 로그인, 구 AuthFeature 개명) + `path`(StackState)로 가입 경로(terms → naming → job → experience → register)를 push 한다. 수집값(이름·직군·연차)은 코디네이터가 누적하고, **연차 화면 CTA 에서 한 번에 PATCH** 한다(`UserClient.updateProfile` — 셋 다 매 호출 필수라 셋을 모두 쥔 코디네이터만 만들 수 있다, [[api#User]]). 성공해야 등록 완료(register)를 push 하고 `profileRegistered` 가 true 가 된다 — 실패면 연차 화면에 머문 채 알럿, CTA 재탭이 곧 재시도다(수집값은 State 에 남아 있다). 세션 만료·회원 소실만 A0 로 되돌리고, `INVALID_JOB_ROLE` 은 직군 화면으로 pop 해 다시 고르게 한다. 진행 표시는 전역 로딩(NetworkActivity)이 덮어 화면별 스피너·중복 탭 플래그가 없다.

- `AuthTermsFeature`(A1) — **동의 항목은 서버가 준다**(`ConsentClient.pending`, [[api#Consent]]) — 하드코딩 5종 enum 을 걷어냈다. 최초 동의(필수 5종 전체)와 재동의(바뀐 항목만)가 같은 화면이고 차이는 내려온 항목뿐. 진입 시 조회(세션 복구 경로는 판정이 이미 받은 항목을 `State(items:)` 로 주입해 재호출 없음), 제출(`submit`)까지 화면이 마치고 성공만 delegate. 항목 코드 → 시안 카피 매핑은 `ConsentItem.rowTitle`(모르는 코드는 서버 label 로 합성). 전문은 `document` 마크다운 — `Text` 가 인라인 문법만 알아서 ATX 헤딩(`### 제N조`)은 `DocumentBlock` 이 갈라 타이포로 올린다(안 그러면 «###» 이 그대로 보인다). `CONSENT_VERSION_MISMATCH` 면 체크를 비우고 pending 재조회.
- `AuthOnboarding{Naming·Job·Experience·Register}` — `Sources/Onboarding/` 폴더. Job·Experience 는 FeatureOnboarding STEP1·2 의 **복사본**(Feature 간 공유 금지 — 원본은 위저드 정리 시 제거, [[onboarding]]). 넷 다 수집·표시만 하고 외부 IO 가 없다 — 프로필 PATCH 는 코디네이터가 연차 화면 delegate 를 받아 한다(위). 이름 단독 API 는 서버 삭제 예정이라 일괄 PATCH 로 흡수했다([[api#User]]).
- **이름 화면 프리필** — 애플 로그인이 준 이름(`SocialCredential.socialName`)을 코디네이터가 `AuthOnboardingNamingFeature.State(name:)` 에 채워 넣는다. 이미 받은 정보를 다시 묻는 것이 App Review Guideline 4 리젝 사유였다(2026-08-15). **화면 자체는 없애지 않는다** — 애플은 이름을 최초 인가 1회에만 주고 재로그인·세션 복구 경로는 항상 nil 이라, 채울 값이 없을 때 물을 자리가 필요하다. 계약(한글·영문 5자)을 넘는 값은 채우지 않고 빈 칸으로 둔다: 잘라 넣으면 남의 이름을 줄인 값이 되고, 그대로 채우면 CTA 가 잠긴 채 이유를 못 알린다(길이 안내 문구가 시안에 없다).
- `AuthSuspensionFeature`(A4) — 정지 안내. Path 밖 — 진입은 위저드 세션 생성의 403 `ACCOUNT_SUSPENDED`(2026-11-12 배선, HLT-54)라 제시는 AppFeature(cross-feature, 위저드 cover 위). 기획은 «면접 시작 탭 시점» 이지만 서버에 사전 조회 API 가 없다. CS 메일 주소는 placeholder.
- `SplashView` — 판정 결과를 모르는 뷰. `onRetry` 를 받으면 판정 실패 상태(재시도 노출), nil 이면 판정 중. 판정 자체는 AppFeature 몫 → [[app#Splash 세션 복구]].

## 심사용 코드 로그인

App Store 심사자가 카카오·애플을 거치지 않고 데모 계정에 들어오는 대체 경로. 카카오 로그인이 심사 기기에서 막히는 경우(해외 IP 이상 로그인 감지·새 기기 인증 — 앱이 통제할 수 없는 변수)가 2.1 리젝의 실질 위험이라서다.

`AuthClient.loginWithReviewCode(code)` 는 `login` 과 **같은 엔드포인트·같은 `provider=KAKAO`** 를 쓰고 `credential` 만 심사자가 입력한 코드다([[api#Auth]]). 전용 provider 를 두지 않은 것은 서버 계약이 그렇기 때문 — 그래서 **판정 책임이 서버에** 있다: 카카오 핸들러가 카카오 API 를 호출하기 전에 credential 이 심사 코드인지 먼저 본다. 실제 액세스 토큰과 코드가 겹칠 일은 없어 이 순서로 안전하다. 두 진입점은 Implementation 의 `exchange(_:)` 를 공유하므로 토큰 저장·판정값 조립·에러 매핑이 한 곳뿐이다.

앱은 코드도 계정 식별자도 모른다 — 데모 계정 UUID 는 서버에만 있고, 코드는 심사자 입력으로 들어온다.

**코드를 앱에 심지 않는다** — 심사자가 화면에서 입력하므로 바이너리 문자열에 남지 않는다. 서버 측 rate limit 이 브루트포스 방어의 유일한 층이다(클라가 할 수 있는 게 없다).

A0(`AuthCreateAccountFeature`)에서 로고를 `reviewCodeTapThreshold`(5)번 탭하면 입력이 열린다. 숨긴 상대는 사용자고 Apple 에는 App Review 노트로 경로를 공개한다 — 그래서 2.3.1(hidden features)에 걸리지 않는다. 제출은 소셜 경로와 **같은 `inner(.signInFinished)`·`delegate(.authenticated)`** 로 합류해 게이트 2단 체인을 그대로 탄다: 다른 것은 교환 함수 하나뿐이고, 실패 얼럿·재탭 차단(`isAuthenticating`)도 공유한다.

## 게이트 2단 체인

목적지는 **두 값만으로** 정해진다 — ① 동의 `consentStatus` ② 프로필 `profileRegistered`. 순서 고정(동의를 통과해야 프로필 게이트를 본다). 전체 표·시퀀스는 [launch-routing](../docs/work/launch-routing.md).

`NOT_SUBMITTED`(최초)와 `STALE`(재동의)은 **같은 갈래**다 — 화면도 코드도 갈리지 않고, 차이는 `pending` 이 내려주는 항목뿐. 그래서 코디네이터 분기는 `enterGate`(동의) → `passProfileGate`(프로필) 두 함수뿐이고, 로그인 경로와 세션 복구 경로가 판정값 출처만 다른 채 같은 체인을 탄다.

- **로그인 경로** — `AuthCreateAccount.delegate(.authenticated(LoginResult))` 가 판정값을 싣고 온다([[api#Auth]]). 소셜 credential 은 payload 로도 안 남는다 — 이후 분기에 필요한 건 판정값뿐이라서.
- **세션 복구 경로** — AppFeature 가 Splash 에서 판정하고 `State(resuming: Destination)` 으로 넘긴다. A0 를 안 거치므로 **스택 첫 화면이 곧 목적지**(약관 또는 이름 입력)고, 이미 조회한 약관 항목이 함께 주입된다. 두 게이트 모두 통과한 경우는 AppFeature 가 홈으로 보내 여기 오지 않는다.

`profileRegistered` 는 약관 화면을 거치는 동안 코디네이터 State 에 남는다 — 동의 제출 응답엔 이 값이 없어서다. 판정값이 없으면(계약 위반) 미등록으로 읽는다: 온보딩을 한 번 더 보는 쪽이 프로필 없이 홈에 앉는 쪽보다 안전한 실패다.

## AppFeature 통합

Splash 판정 → `State.root`(splash·splashFailed·auth·home)로 분기한다. auth 면 `AuthView`(가입 플로우 스택) 전체화면, home 이면 `NavigationStack` 안의 홈(탭바 없음). → [[app#Splash 세션 복구]]

`AuthFeature`(코디네이터)가 가입 완료 또는 기존 회원 로그인 시 `delegate(.signedIn)`을 올리면 AppFeature 가 수신해 전환한다(cross-feature 조립은 AppFeature에서만).

## 다음 작업

세션 교환(`login`)·자동 재발급·자동 로그인(Splash 세션 복구)·동의 제출·게이트 2단 분기·프로필 일괄 PATCH·가입 플로우 화면 골격은 완료([[auth#가입 플로우]], [[auth#게이트 2단 체인]]). 남은 것:

- **서버 확인 대기 3건**: ① Refresh 7일이 rotation 마다 리셋되는 슬라이딩인지 절대인지 ② `pending.profileRegistered` 배포(현재는 없으면 false 로 읽는 과도기 디코딩) ③ `LOGIN_EXPIRED` 외 4xx 처리.
- **Figma UI 연결**: 가입 플로우 8화면(Splash·CreateAccount·Terms+전문시트·Suspension·이름·직군·연차·등록완료)은 시안 교체 완료(2026-07-31, figma-screen). 남은 것은 A0 실패 alert → 토스트 교체.
- **로그아웃 UX**: 설정 화면(Part 5)에서 `authClient.logout()` 호출 + 게이트 복귀.
