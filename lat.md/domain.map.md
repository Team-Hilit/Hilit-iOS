# Domain Map

도메인(=모듈) 간 큰 그림. 코드 한 줄 단위 연결은 `@lat` 주석, 전체 협업 그림은 이 문서. 아래 Users↔Profile 등 «예정» 표시 항목은 아직 화면이 없고 이관될 표준 패턴이다.

## 화면 구조
AppFeature 가 각 Feature 를 보유하며 Feature 끼리는 서로를 모른다. 현재 실체는 Home 뿐이고 **탭바는 없다**(탭 하나뿐인 `TabView` 제거 — [[app#화면 구성]]). → [[home]] · [[app]]

## Users ↔ Profile
가장 중요한 cross-feature 흐름이자 import 그래프엔 안 보이는 의존. **둘은 서로 import 하지 않는다** — 전부 delegate + AppFeature 중재. (이관 후 표준 예시)

```
UserDetail  --delegate(.editProfileTapped)-->  Users
Users       --delegate(.editProfile)-->        AppFeature
AppFeature  --presents editProfile sheet-->    Profile
Profile     --delegate(.profileSaved)-->       AppFeature
AppFeature  --.users(.profileUpdated)-->       Users   (list/detail 갱신)
```

- 조립 지점 → [[app#Cross-feature Routing]]
- **검색**: import 추적으론 안 잡히는 이 의존을 `make lat q=profile` 로 한 번에 찾는다.

## Feature ↔ Domain
각 Feature 가 의존하는 Domain(Interface) 매핑. Repository(Client)는 Domain 레이어 모듈이 보유한다. 서버 API Domain 11종(AppVersion·Auth·Consent·Interview·InterviewReport·JD·Job·Portfolio·User·FeedbackShare·GuestFeedback)의 엔드포인트·규약은 [[api]].

| Feature | 의존 Domain (Interface) | Client |
|---|---|---|
| Home (진입 로드 — [[home#진입 로드]]) | DomainPortfolio · DomainUser | PortfolioClient.list · UserClient.profile |
| GuestFeedback (G4 게스트 평가) | DomainGuestFeedback | GuestFeedbackClient · GuestFeedbackLocalStore → [[feedback]] |
| Auth (로그인 게이트 + 가입 온보딩) | DomainAuth · DomainConsent · DomainJob · DomainUser | AuthClient → [[auth]] · ConsentClient · JobClient → [[api#Job]] · UserClient |
| Onboarding (Part 1 위저드 — [[onboarding]] · [ai-interview](../docs/work/ai-interview.md) §5) | DomainJD · DomainPortfolio (분석 스텝 세션 연결 시 + DomainInterview) | JDClient · PortfolioClient (+ InterviewClient) |
| Interview (Part 2 면접 흐름 — [[interview#면접 흐름]]) | DomainInterview · DomainPermission | InterviewClient → [[interview]] · PermissionClient → [[interview#권한]] |
| Portfolio 관리 (예정) | DomainPortfolio | PortfolioClient → [[api#Portfolio]] |
| Users (예정 — 데모 패턴) | DomainUser | UserClient → [[api#User]] |
| App 스플래시 (예정 — 버전 게이트) | DomainAppVersion | AppVersionClient → [[api#AppVersion]] |
| Auth 약관 동의 (예정 — A1 배선) | DomainConsent | ConsentClient → [[api#Consent]] |
| Report (골격 — 화면 4종 자리표시, [[report]] · [ai-interview-report](../docs/work/ai-interview-report.md)) | DomainInterviewReport · DomainFeedbackShare | InterviewReportClient · FeedbackShareClient → [[api#Interview Report]] · GuestFeedbackShareLink(링크 조립) |
| App 딥링크 수신 (유니버설 링크 — [[deeplink]]) | DomainDeeplink · DomainFeedbackShare | DeeplinkClient · GuestFeedbackShareLink(링크 해석) |
| GuestFeedback (예정 — 지인 웹/딥링크 진입) | DomainGuestFeedback | GuestFeedbackClient → [[api#Guest Feedback]] |
| Profile (예정 — 데모 패턴) | DomainProfile | ProfileClient |

Domain `Implementation`(`liveValue`)은 App / Example 만 link. → [[home]]

## 네트워킹 인프라
모든 외부 HTTP IO 는 `CoreNetwork` 의 `NetworkClient` 계약을 거친다. 소비자는 Domain Implementation 뿐 — Feature 는 Domain(Client)만 알고 이 모듈을 모른다. baseURL 은 계별 xcconfig `API_BASE_URL`(→ DocC Environments)을 liveValue 가 읽는다. 첫 소비자 → [[interview#Client 계약]]

실패는 전부 `NetworkError` 로 정규화된다 — `transport(URLError.Code)`(오프라인·타임아웃), `statusCode(코드, body)`(body = 서버 에러 payload, Domain 이 도메인 에러로 매핑), `invalidResponse`, `invalidURL`/`invalidBaseURL`. 취소는 실패가 아니므로 `CancellationError` 로 나간다. 요청 편의는 `NetworkRequest.json(...)`(Content-Type + Encodable body)·`NetworkRequest.multipart(...)`(파일 업로드), Testing 타겟은 `mock(returning:/json:/throwing:)` 을 제공.

예외로 presigned 절대 URL 업로드는 `FileTransferClient`(같은 모듈) 별도 seam 이다 — baseURL 상대경로도 envelope 도 Bearer 도 없고(서명에 인증이 이미 들어 있어 헤더를 얹으면 저장소가 거부), Content-Type 은 발급 응답 값 원문을 그대로 보낸다. 요청 본문은 파일 스트리밍(`upload(for:fromFile:)`)이라 큰 영상도 메모리에 올리지 않는다. 실패 정규화(2xx 가드·transport·취소)는 `NetworkClient` 와 동일.

같은 presigned PUT 이라도 **앱이 사라져도 끝나야 하는** 전송은 `BackgroundTransferClient`(같은 모듈) 다 — `URLSessionConfiguration.background`(고정 식별자·`sessionSendsLaunchEvents`) 라 등록과 결과가 분리된다: `enqueuePut(id:url:contentType:fileURL:)` 은 태스크 등록만 하고 완료·실패는 `completions` 스트림으로 오며(id 는 `taskDescription` 에 새겨 이벤트가 들고 온다 — 등록한 프로세스가 죽어도 도착), 재기동 뒤엔 `reattach()` 로 살아 있는 태스크를 이어받고 시스템 wake 의 completionHandler 는 `attachBackgroundEventsCompletionHandler` 로 넘긴다. 소비처는 하나 — [[interview#업로드 큐]].

D14 공통 규약(성공/실패 envelope·토큰 수명주기)은 그 위에 얹힌다 — envelope 언랩·`ServerError` 승격은 `api(...)` 확장, Bearer 첨부·단일 비행 재발급은 `AuthorizedNetworkClient`, 토큰 보관은 `TokenStore`(Keychain). 인증 필요 엔드포인트의 Domain liveValue 는 `@Dependency(\.authorizedNetworkClient)` 를 쓴다. 상세 → [[api#공통 규약]] · [[api#토큰 수명주기]]

전 API 공통 로딩: in-flight 는 `NetworkActivity`(@MainActor @Observable 카운터, Interface)가 센다 — liveValue 가 `trackingActivity()` 데코레이터 한 겹으로 계측하고(Authorized·재발급도 base 를 지나 전부 잡힘), `GlobalLoadingWindow`(App)가 `isLoading` 을 관찰해 최상단 창에 `LoadingModal` 을 전역 표출한다(얹을 자리 판정은 `AppView.showsGlobalLoading`). Feature 는 이 신호에 관여하지 않는다. **예외 — Splash 계열 루트(`.splash`·`.splashFailed`·`.updateRequired`)에서는 얹지 않는다**: Splash 자체가 대기 표시이고 `.updateRequired` 는 알럿과 딤이 겹친다 → [[app#Splash 세션 복구]]

- **엔드포인트 단위 예외 — `GlobalLoadingSuppression.run { }`** (Interface, 태스크 로컬): 스코프 안 요청은 `begin` 자체를 건너뛴다. 거는 자리는 **Domain Implementation 뿐** — Feature 는 Core 를 모르고, 억제 여부는 «그 엔드포인트를 기다리는 화면이 자기 대기 UI 를 이미 그리는가» 로 갈려 엔드포인트 정의 옆이 판단 근거와 가장 가깝다. 두 부류가 대상이다: **폴링**(3초 재조회 — hop 마다 딤이 깜빡이고, 응답이 100ms 지연보다 빠르면 아예 안 떠서 긴 대기가 무표시가 된다)과 **화면이 designed 대기 UI 를 그리는 구간**(모달이 그 화면과 그 안의 취소 동선을 덮는다). 현재 적용: `PortfolioClient.register`·`.status`, `InterviewClient.createSession`·`.sessionStatus` → [[onboarding#포트폴리오 업로드]] · [[onboarding#프리로드]]
- `isLoading` 은 카운터를 그대로 노출하지 않는다 — **켜기 100ms 지연 + 최소 표출 300ms + 끄기 80ms 유예**. 지연 안에 끝난 요청은 로딩을 아예 안 띄우고(빠른 응답 «반짝» 방지), 한번 뜬 모달은 300ms 는 유지하며(지연 직후 응답 «반짝» 방지), 순차 호출 사이 카운트가 0 을 스치는 틈은 유예가 덮는다(«깜빡» 방지). 두 지연은 체인 전체에서 한 번씩만 든다 — 켜기 예약은 hop 마다 리셋하지 않아 지연이 체인 시작 기준으로 재지고, 끄기 예약은 다음 `begin()` 이 취소한다.
- 입력 차단은 표출과 따로 간다 — `isBlocking`(카운트 > 0 또는 표출 중)은 요청 시작 **즉시** 켜지고, 최상단 별도 창(`GlobalLoadingWindow`, `.alert + 1`)이 그동안 보이며 투명 막으로 터치를 받는다. 루트 뷰 overlay 는 fullScreenCover(온보딩 등) 아래에 깔려 창으로 옮겼다. 모달이 뜨기 전 100ms 틈의 연타가 같은 요청을 두 번 보내지 않게 하려는 것.

## 계획 — AI 면접
YAPP APP 1팀 「AI 면접 연습 앱」을 우리 아키텍처에 녹인 후속 도메인 설계(현재 데모 탭과 별개) — Onboarding(Part1)/Session/Report Feature + Domain 군. Part 1 은 PRD v3 로 `FeatureOnboarding` 구현 중(초안 가칭 InterviewSetup 실현). 서버 연동 Domain 은 [[api]] 미러링으로 실체화됐다.

- 전체 개요·Part 1/2 → [ai-interview](../docs/work/ai-interview.md)
- **홈 & 회원가입·계정 상태 (PRD Part 6·7)** → [home-account](../docs/work/home-account.md) — 홈 위젯 3종·시작 게이트·A0/A1/A4 화면 매핑. Home 진입 로드 2종(프로필·포폴)은 배선 완료, 나머지 2종(기록·held)은 계약 대기 — [[home#진입 로드]].
- 기획 시점 Client 설계와 실 서버의 대응: QuestionClient → **InterviewClient**(질문 생성·턴 진행이 세션 API 로 통합, [[api#Interview]]) · PortfolioClient → 동명([[api#Portfolio]]) · 직군/JD 입력 → **JobClient·JDClient**. SpeechClient(TTS/STT)·RecordingClient 는 디바이스 측 IO 라 별개로 남는다(서버 API 아님) — 같은 축의 PermissionClient 는 DomainPermission ✅([[interview#권한]]), RecordingClient 는 DomainRecording(프리뷰 ✅, [[interview#프리뷰]]), SpeechClient 는 DomainSpeech(마이크 캡처 ✅, [[interview#음성 캡처]])로 실현.
- **Part 3 분석 보고서 & 영상 복기** → [ai-interview-report](../docs/work/ai-interview-report.md). `FeatureInterviewReport`(R0·R1 + V0·V1·V2, 자체 Path). 신규 Domain: DomainPlayback(영상 자산·재생 시간축) · DomainReview(자기평가 영구 저장), DomainScoring 확장(폴링·기준선).
- ⚠️ cross-feature: `Session --finished--> AppFeature --present--> Report`, `Report --requestFriendFeedback--> AppFeature`. 평가 독립성 — 친구에 넘기는 payload 는 챕터 경계만.
