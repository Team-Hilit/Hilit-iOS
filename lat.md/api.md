# API — D14 서버 연동

YAPP APP 1팀 백엔드(D14 API v1)와의 연동 지식. 서버 태그(AppVersion·Auth·Consent·Interview·Interview Report·JD·Job·Portfolio·User·Feedback Share·Guest Feedback)를 Domain 모듈로 1:1 미러링하고, 공통 규약(envelope·토큰)은 CoreNetwork 가 흡수한다. 인프라 계약은 [[domain.map#네트워킹 인프라]], 레이어 규칙은 [[architecture]].

- Swagger: `https://hilit.my/swagger-ui/index.html` (운영) · `https://dev.hilit.my/swagger-ui/index.html` (개발)
- 스펙 원문: `GET /v3/api-docs` (OpenAPI 3.1)

## 서버와 환경

운영 서버는 `https://hilit.my` (같은 인스턴스에 `http://43.202.34.84:8080` 로 IP 직결도 가능), 개발 서버는 `https://dev.hilit.my`. Dev·QA 는 개발 서버, Prod 는 운영 서버를 본다. baseURL 은 계별 xcconfig `API_BASE_URL` → Info.plist → `NetworkClient.defaultBaseURL()` 로 흐른다 (→ DocC Environments).

- **도메인은 반드시 https** — `http://hilit.my` 로 붙으면 Caddy 가 308 로 https 에 넘기는데, scheme 이 바뀌어 origin 이 달라지므로 URLSession 이 `Authorization` 헤더를 떼고 재요청한다 → 전 API 403(익명 취급). body 로 자격증명을 싣는 재발급만 살아남아 «토큰은 멀쩡한데 전부 403» 로 보인다.
- ATS 전면 허용(`NSAllowsArbitraryLoads`)은 앱 타겟에서 뺐다 — 전 계가 https 라 예외가 필요 없고, 남겨 두면 App Store 심사가 사유를 요구한다. IP 직결(HTTP) 디버깅이 필요한 `feature(example:)` 하네스에만 남아 있다.
- **상세 로그는 계로 끊는다(컴파일 조건 아님)** — 요청/응답·디코딩 실패·부팅 라우팅 로그의 스위치는 `LogGate.isVerbose`(CoreCommonInterface). 예전엔 `#if DEBUG` 라 release 구성인 **QA 에서도 안 보였다**. 판정은 **허용 목록**(`APP_ENV ∈ {dev, qa}`, DEBUG 은 계 무관하게 켬)이고, «prod 가 아니면 켠다» 로 쓰지 않는다 — 키 누락·오타·새 계 이름이 전부 «켜라» 로 읽혀 실수 한 번이 운영 유출이 된다. **허용 목록 밖은 디버거가 붙었을 때만 열린다**(`P_TRACED` — Xcode/lldb 세션 전용): Prod 로만 재현되는 문제를 볼 길이 필요하지만, 스토어에서 받아 탭한 앱은 추적자가 없어 참이 될 수 없다. 실행 인자(`-verboseLog`)·숨은 토글은 **켜진 채 남을 수 있는 스위치**라 두지 않는다.
- **찍히는 값은 가리지 않는다** — 헤더·바디가 원문 그대로 나간다(access·refresh 토큰, `Authorization`, 소셜 credential 포함). 마스킹 층(`LogRedaction`)은 2026-08-12 삭제했다 — 로그인 실패 진단에서 «비었나·모양이 틀렸나» 를 볼 수 없게 만드는 값이 방어 이득보다 컸다. 방어선은 `LogGate` 하나뿐이므로 **새 로거도 반드시 그 게이트 안에서만** 찍는다. QA 는 release 구성이라 기기 로그로 읽히는 것을 전제한다(Prod 는 게이트가 닫혀 안 찍힌다).

## 공통 규약

모든 응답은 envelope — 성공 `{ success, data }` / 실패 `{ success: false, code, message }`. `NetworkClient.api(...)`/`AuthorizedNetworkClient.api(...)` 가 벗겨서 실패를 `ServerError(code·message·statusCode)` 로 승격한다. `message` 는 그대로 사용자 노출 가능한 한국어 문구다.

- Swagger 스키마 일부는 envelope 없이 표기돼 있다(annotation 누락) → `ServerEnvelope.unwrap` 이 직접 디코드 폴백을 가진다.
- 날짜는 ISO8601 과 LocalDateTime(타임존 표기 없음)이 혼재 → `JSONDecoder.api` 가 KST 가정으로 파싱. 백엔드와 타임존 계약 확정 필요.
- 서버 에러 body 는 **두 포맷**(2026-08-02 확인) — 정의된 코드 `{success:false, code, message}` / 미정의(Spring 기본) `{timestamp, status, error, path}`. `ServerError.decode` 가 둘 다 읽는다(후자는 `code:""` + `message:error원문`).
- Domain 은 `ServerError.code` 로 도메인 에러를 매핑한다 — 서버 정의 에러 코드가 있는 모든 도메인이 자체 에러 enum 을 갖는다(AppVersionError·AuthError·ConsentError·InterviewError·InterviewReportError·JDError·PortfolioError·UserError·FeedbackShareError·GuestFeedbackError). 케이스는 State 가 다르게 반응할 경우의 수만큼만. 매핑 공통부(토큰 만료 3코드 → sessionExpired, 미인식 5xx → serverUnavailable, transport → networkFailure, 취소 통과)는 `DomainCommonInterface` 의 `DomainAPIError` 프로토콜이 수행하고, 각 도메인 enum 은 고유 코드 매핑 `init?(serverCode:message:)` 만 구현한다 (Auth·Consent·FeedbackShare·Interview·InterviewReport 는 미승격 4xx 폴백을 `server(…)` 케이스로 재정의해 원문을 화면까지 흘린다, 무인증 GuestFeedback·AppVersion 은 `sessionExpired` 를 unexpected 별칭으로 충족). Implementation 은 `XxxError.mapping { }` 래퍼로 감싼다. 에러 코드가 없는 도메인(Job)만 ServerError/NetworkError 를 그대로 던진다.
- **미승격 에러 임시 노출 규칙(2026-08-02)** — 도메인 핸들링 확정 전까지 OS 기본 Alert 에 `ServerError.alertTitle/alertMessage` 로 노출: 정의 코드는 title «CODE(status)»·message 서버 문구, Spring 포맷은 title 상태코드·message `error` 원문. 도메인별 핸들링이 정해지면 전용 케이스 승격이 우선. Alert 조립은 `DomainAPIError.serverAlertState()` 한 곳이 한다(각 enum 은 원문을 꺼내는 `unrecognizedServerError` 만 구현, 기본 nil) — Feature 마다 같은 AlertState 를 짜지 않고 CoreNetwork 타입도 화면으로 새지 않는다. 적용은 Report·Auth 뿐이고 나머지 Feature 는 미적용이다 — 그 화면을 만질 때 붙인다.
- multipart(파일 업로드)는 `NetworkRequest.multipart(...)` 빌더 — 기존 NetworkRequest 계약(헤더+body) 위의 편의일 뿐이다.

## 토큰 수명주기

JWT — Access 3시간 / Refresh 7일, Rotation(재발급 시 페어가 통째로 교체). 보관은 Keychain(`TokenStore`). Feature 는 토큰의 존재를 모른다.

- 인증 필요 요청은 전부 `AuthorizedNetworkClient` 를 쓴다 — Bearer 첨부 후 만료 감지 시 **단일 비행** 재발급 → 원요청 1회 재시도. (Rotation 이라 중복 재발급 = 로그아웃 사고 → actor 직렬화)
- 만료 판정 2중: **HTTP 403 이면 body 와 무관하게 만료**(서버 계약 2026-08-02 — 모든 API 공통) + `TOKEN_EXPIRED`/`INVALID_TOKEN` 코드(403 이 아닌 상태로 오는 케이스 방어).
- `LOGIN_EXPIRED` = Refresh 도 만료 → 토큰 폐기 후 전파. 앱 레벨 재로그인 라우팅 신호.
- 로컬 토큰이 아예 없으면 요청 전에 `NotAuthenticatedError` — 로그인 화면 유도.
- 저장(로그인)·삭제(로그아웃)는 [[api#Auth]] 의 AuthClient 책임.

## AppVersion

`DomainAppVersion` — `AppVersionClient.check`. 스플래시에서 현재 마케팅 버전을 보내 강제(FORCE)/권장(OPTIONAL)/최신(NONE) 판정을 받는다. 버전 비교 규칙은 전부 서버 책임 — 클라이언트는 `updateType` 만 따르고, 응답의 `storeUrl` 로 스토어를 연다. 무인증(로그인 전 호출)이라 `NetworkClient` 를 직접 쓴다.

| 메서드 | 엔드포인트 | 비고 |
|---|---|---|
| `check` | GET `/api/v1/app-versions/check` | query `platform=IOS`·`version=x.x.x` (마케팅 버전) |

에러는 `AppVersionError` — 고유 코드(INVALID_PLATFORM·INVALID_VERSION_FORMAT·APP_VERSION_POLICY_NOT_FOUND)는 정상 클라이언트에서 나올 수 없어 케이스 승격 없이 unexpected 폴백. 스플래시는 실패 시 fail-open(게이트 없이 진입)이 기본이라 공통 3케이스(networkFailure·serverUnavailable·unexpected)만 둔다.

호출은 `AppFeature` 진입 판정의 첫 단계다 — 세션 판정보다 **앞**(FORCE 를 뒤에 두면 홈 진입 후에 막게 된다), 실패·버전 키 부재는 `nil` 로 삼켜 통과 → [[app#Splash 세션 복구]].

## Auth

`DomainAuth` — `AuthClient` 파사드에 서버 세션 수명주기가 얹혔다: `login`(자격증명 교환)·`refresh`·`logout`·`check`·`isAuthenticated`. 소셜 SDK 획득부(signIn)와 서버 교환부(login)는 분리된 엔드포인트 — 흐름은 [[auth]].

| 메서드 | 엔드포인트 | 비고 |
|---|---|---|
| `login` | POST `/api/v1/auth/social/login` | KAKAO=액세스 토큰 / APPLE=authorization code 를 credential 로 전송. 성공 시 토큰 저장 + `LoginResult`(consentStatus·profileRegistered — 진입 게이트 판정값, [launch-routing](../docs/work/launch-routing.md)) 반환. 응답의 `newUser`·`userInfo` 는 소비자가 없어 디코딩하지 않는다 |
| `loginWithReviewCode` | POST `/api/v1/auth/social/login` | 같은 엔드포인트·같은 `provider=KAKAO` 에 credential 만 스토어 심사용 코드. 전용 provider 가 없어 **서버가 credential 값으로** 코드와 카카오 액세스 토큰을 갈라내고(코드면 카카오 API 호출 없이 지정 데모 계정 토큰 발급, rate limit 은 서버 몫), 응답 스키마·후처리는 `login` 과 동일 — 흐름은 [[auth#심사용 코드 로그인]] |
| `refresh` | POST `/api/v1/auth/token/refresh` | 명시적 재발급 (자동은 AuthorizedNetworkClient) |
| `logout` | DELETE `/api/v1/auth/logout` | 204. 로컬 토큰은 서버 응답과 무관하게 삭제 |
| `check` | GET `/api/v1/auth/check` | 인증 동작 확인(테스트용) |

실패는 `AuthError` 로 매핑된다 — INVALID_CREDENTIAL/SOCIAL_LOGIN_FAILED → invalidCredential, LOGIN_EXPIRED·TOKEN_EXPIRED·INVALID_TOKEN → sessionExpired, transport → networkFailure, 5xx → serverUnavailable, 미승격 4xx → server(원문 동봉 — 임시 노출 규칙, [[api#공통 규약]]).

## Consent

`DomainConsent` — `ConsentClient`. 온보딩 최초 동의와 약관 개정 재동의를 한 흐름으로 처리한다. `pending` 의 `consentStatus` 하나로 최초(NOT_SUBMITTED)/재동의(STALE)/최신(UP_TO_DATE)을 구분하고, 제출은 pending 이 내려준 `version` 을 그대로 보낸다. 첫 성공 제출 시 서버가 무료 이용권 3회를 부여한다.

| 메서드 | 엔드포인트 | 비고 |
|---|---|---|
| `pending` | GET `/api/v1/consents/pending` | 신규 유저는 필수 5종 전체, 구버전 동의 유저는 바뀐 항목만. `profileRegistered`(게이트 ② 판정값)도 내려준다 — 세션 복구(Splash)가 login 응답 없이 분기하기 위함(2026-08-01 합의, 2026-08-02 배포 확인). 상태 키는 `consentStatus` |
| `document` | GET `/api/v1/consents/{item}/versions/{version}` | 본문(마크다운) — 항목 탭 시 바텀시트. `hasDocument: false` 면 숨김 |
| `submit` | POST `/api/v1/consents` | 필수 항목은 agreed: true 만, 선택 항목은 거부도 정상 제출 |

에러는 `ConsentError` 로 매핑된다 — CONSENT_VERSION_MISMATCH → versionMismatch(400, 제출 중 개정 → pending 재조회 후 재시도), VALIDATION_ERROR 는 서버 문구를 실은 invalid(message:). REQUIRED_CONSENT_MISSING·INVALID_CONSENT_ITEM 은 UI 가 막는 클라이언트 결함이라 케이스 승격 없이 server 폴백(원문 Alert — 임시 노출 규칙, [[api#공통 규약]]).

## Interview

`DomainInterview` — `InterviewClient`. 세션 생성은 회원 프로필 스냅샷을 쓴다(직군·연차는 body 에서 제거, 미등록이면 `USER_PROFILE_NOT_REGISTERED`). 준비는 서버 비동기 — 202 후 `sessionStatus` 3~5초 폴링, READY 에 `startedAt`·요약 질문(base64 TTS) 동봉. FAILED 면 이용권 자동 환불. 계약 상세는 [[interview]].

| 메서드 | 엔드포인트 | 비고 |
|---|---|---|
| `createSession` | POST `/api/v1/interview/sessions` | 이용권 무료 3회, `jdUrl`/`jdText` 상호 배타, 직군·연차는 프로필 스냅샷 |
| `sessionStatus` | GET `/api/v1/interview/sessions/{id}/status` | 3~5초 폴링 |
| `submitAnswer` | POST `/api/v1/interview/sessions/{id}/answers` | 메타=query + 오디오=multipart(`answer.m4a`/`audio/mp4` — iOS mp3 인코딩 미지원, 2026-08-05 작업B 슬라이스1). 503(`AI_TEMPORARILY_UNAVAILABLE`)은 같은 요청 재시도 계약 |
| `questionAudioStream` | GET `.../questions/{qid}/audio/stream` | 아래 스트리밍 규약 |
| `videoUploadURL` | POST `.../video/upload-url` | S3 presigned PUT 발급 — PUT 의 Content-Type 은 응답 `contentType` 그대로(서명 포함). `expiresInSeconds` 안에만 유효, 세션당 저장 1곳(재업로드=덮어쓰기) |
| `completeVideoUpload` | POST `.../video/complete` | S3 PUT 성공 후 호출(호출처 책임)·멱등. `wrapUp`(마무리 멘트 구간, 녹화 타임라인 초) nil 이면 바디 생략 |
| `uploadInterviewVideo` | (엔드포인트 아님 — 클라 오케스트레이션) | `videoUploadURL`→PUT([[domain.map#네트워킹 인프라]] `FileTransferClient`)→`completeVideoUpload` 3단을 1시도로 응집 — 재시도는 호출처 몫. **실 면접 경로는 이걸 쓰지 않는다**(이유·현행 사용처 → [[interview#Client 계약]]) |
| `reportList` | GET `/api/v1/interview/sessions` | 내 레포트 목록(홈 위젯②·마이페이지) — envelope `{reports}` 는 liveValue 가 벗김. `title`(답변 한 줄 요약)은 2026-08-07 추가라 과거 세션엔 없다. **진행중·준비중 세션 제외** — held 판정은 로컬 보관([[home#진입 로드]]) |
| `checkResume` | GET `.../sessions/{id}/resume` | 재개 가능 조회(순수) — RESUMABLE(IN_PROGRESS+hold 20분 이내)/ENDED. hold 만료의 ABANDONED 전환·환불은 서버가 이 호출 안에서 처리 |
| `confirmResume` | POST `.../sessions/{id}/resume` | 재개 확정 — 응답은 `submitAnswer` 와 같은 `AnswerResult`(최신 턴 질문). 레이스는 409 아닌 200+`sessionEnded` |
| `abandonSession` | POST `.../sessions/{id}/abandon` | 중단 — USER_EXIT(진행분 리포트 트리거·차감은 리포트 성공 시)/NETWORK_DISCONNECT(환불). 중복 409 는 «이미 중단 완료» |


질문 음성 스트리밍 규약: `audio/mpeg` + `Transfer-Encoding: chunked` (Content-Length 없음). 전부 받고 재생하지 말고 `AVURLAsset(url:options:[헤더])` → `AVPlayer` 점진 재생 — 그래서 계약이 Data 가 아니라 `InterviewAudioStream(url·headers)` 다. 중간 실패는 HTTP 로 안 잡힌다 — 재생 에러 콜백으로 감지하고 같은 questionId 로 재호출(TTS 처음부터 재생성).

`endType` 은 요청·응답이 다른 집합이다. 요청(`AnswerEndType`): nil=정상 / SKIP(오디오 없음) / MANUAL_END(8:00 후 수동 종료) / HARD_CAP(12:00 강제) / BACK_EXIT(8:00 전 뒤로가기 이탈 — 구 EARLY_EXIT, 2026-08-03 서버 개명·오디오 선택. **클라는 2026-08-09 부터 보내지 않는다** — 중도 이탈이 세션을 살려 두고 재개에 맡기게 바뀌었다, [[interview#세션]]). 응답(`SessionEndType`): MANUAL_END·HARD_CAP·BACK_EXIT + NORMAL_END(자연 종료) + **STT_RESET**(STT 30% 실패 — 판정은 서버, 이용권 환불·리포트 없음). ⚠️ 2026-08-03 스웨거부터 BACK_EXIT 도 리포트 생성을 트리거한다(이용권 HELD → 리포트 성공 시 차감 확정) — 클라가 그 제출을 걷어낸 지금(위) 진행분 리포트를 만드는 건 홈 [처음부터 시작] 의 `abandon(USER_EXIT)` 뿐이고, 이탈 후 20분 안에 안 돌아오면 hold 만료로 리포트 없이 환불된다. 차감 시점이 «이탈 즉시» 에서 «포기 선택 시» 로 밀린 셈이라 PM 확인 대상. 종료 응답은 `sessionEnded`·`wrapUpMessage{ttsAudio}`(base64 mp3 마무리 멘트)를 동봉하고 `reportId` 는 삭제됐다. `isWrapUp` 은 8:45 경과 여부(required — 항상 전송) — 타이머 상태머신은 [ai-interview](../docs/work/ai-interview.md) §6.

에러는 `InterviewError` 로 매핑된다 — NO_REMAINING_TICKET → noRemainingTicket(403), PORTFOLIO_NOT_FOUND / PORTFOLIO_PROCESSING / PORTFOLIO_UPLOAD_FAILED / JD_NOT_VALIDATED / FREETEXT_NOT_RELEVANT / USER_PROFILE_NOT_REGISTERED (세션 생성 400·404), INTERVIEW_SESSION_NOT_FOUND / QUESTION_NOT_FOUND (404), ANSWER_ALREADY_SUBMITTED / SESSION_ALREADY_ENDED / SESSION_NOT_STARTED / SESSION_PRELOAD_FAILED (409 — 뒤 둘은 checkResume 없이 confirmResume 을 직행한 비정상 경우), AI_TEMPORARILY_UNAVAILABLE → aiTemporarilyUnavailable(503 — 코드 매핑이 5xx 판정보다 먼저라 serverUnavailable 에 선점되지 않음, 같은 요청 재시도), 입력 검증군(VALIDATION_ERROR·INVALID_* — INVALID_ABANDON_CAUSE 포함)은 서버 문구를 실은 invalid(message:), 미승격 코드(4xx)는 server(code·message) 로 동봉 — 분기가 필요해지면 전용 케이스로 승격. `AnswerResult` 는 resume 계약 합류로 `status`·`abandonCause`·`endedAt` 옵셔널이 붙었다(레이스 판별 재료).

## Interview Report

`DomainInterviewReport` — `InterviewReportClient`. 채점 파이프라인 결과를 사용자용 리포트(한 줄 요약 + 턴별 카드 + 전체 대본 타임라인 + 영상 메타 + 지인 피드백)로 조회한다. 점수·판정 원값은 안 내려온다. 지인 피드백 제출측은 [[api#Feedback Share]]·[[api#Guest Feedback]].

| 메서드 | 엔드포인트 | 비고 |
|---|---|---|
| `report` | GET `/api/v1/interview/sessions/{id}/report` | 보고서 미생성이면 404 가 아니라 `status=GENERATING` 응답 |
| `videoExpiry` | GET `.../video/expiry` | 만료 카운트다운 폴링 — `video.expiresAt` 과 같은 시각의 초 단위 재계산. 만료면 `0/true`, 최대 보관 30일 |

- `status` 는 채점 진행 상태만 — GENERATING(전 필드 nil — script 포함, 폴링 지속) / READY / INSUFFICIENT_ANALYSIS(채점된 카드만) / FAILED.
- 레드플래그는 보고서 단위 배열이 없다 — 걸린 카드의 `cardRedFlagNotices` 로만 온다. 저장 5종 중 노출 3종(지어냄·모순·무결점 서사)만 중립 문구. READY + 심각 레드플래그면 headline 이 중립 사실 요약으로 대체. 원소는 **문구 문자열** 또는 `{type, message}` 둘 다로 오므로 `RedFlagNotice` 가 양쪽을 받는다(문자열이면 `type` 은 nil).
- 카드는 질문/답변 턴당 1장 — 같은 축이면 `axisOrder` 동일, `depthLevel` 로 구분 (표시: "질문 {axisOrder}-{depthLevel}"). 카드마다 `questionIntentTitle`(의도 한 줄 명사구)이 붙는다.
- `highlightSpans` 는 톤(GOOD/IMPROVE)에 더해 `reason`(PROBE_WORTHY/OFF_INTENT/SHALLOW/SUFFICIENT)·`title`·`startSec` 을 갖는다. `followUpQuestions` 는 PROBE_WORTHY 만, `answerTopicTitle`·`questionIntentTitle`·`questionIntent`(카드 값 복사) 는 OFF_INTENT 만 채워진다 — 그 외 reason 에선 셋 다 null/빈 배열.
- `resolutionNotice` 가 있으면 해상도 낮음 — 능력 판단 보류. 사유가 짧음·얕음이면 `highlightSpans` 빈 배열, 딴 답이면 OFF_INTENT 하이라이트 1개.
- 영상 만료 시 `video.url` 만 nil — 대본·하이라이트는 유지. `guestFeedback` 은 지인 0명이어도 `participantCount=0, guests=[]` 로 온다(GENERATING 때만 nil).
- 대본 발화는 두 자리에 온다 — 카드 `scriptSegments`(그 턴의 문장들, 면접관/면접자 `role` 혼재, 문자 오프셋 동봉 — **면접자 행만 카드 `transcript` 기준**이고 면접관 행은 질문 문자열 기준이라 답변 대본에 대고 자르면 안 된다)와 최상위 `script`(첫 멘트부터 마무리까지 세션 전체를 `startSec` 오름차순 한 배열, 오프셋 없음). `startSec`/`endSec` 은 합성 영상(=녹화) 타임라인 기준이라 진행바·재생 강조가 그대로 쓴다. 플레이어 진행바 칸(= 질문 턴)·오버레이 문장(질문 포함)·하이라이트 시각 폴백은 전부 카드 `scriptSegments` — 최상위 `script` 는 화면 사용처가 없다(진행바 칸이 턴 단위가 되면서 폐기, 2026-08-07).

에러는 `InterviewReportError` 로 매핑된다 — INTERVIEW_SESSION_NOT_FOUND → sessionNotFound(404), INTERVIEW_VIDEO_NOT_FOUND → videoNotFound(404 — 세션은 있으나 영상 레코드 없음, 업로드 완료 전), INTERVIEW_REPORT_NOT_FOUND → reportNotFound(현행 스웨거에서 빠짐 — 미생성은 GENERATING 응답. 매핑은 방어 유지), 미승격 4xx 는 server(원문 동봉 — 임시 노출 규칙, [[api#공통 규약]]).

## JD

`DomainJD` — `JDClient.validate`. JD URL 크롤링 + AI 정제 + 서버 캐싱. HTTP 200 이어도 `valid=false` 가 온다(CRAWLING_FAILED·CONTENT_TOO_SHORT·EXTRACTION_FAILED) — 이때 UX 는 본문 직접 입력(jdText) 폴백이 필수.

- POST `/api/v1/jd/validate`
- `createSession` 의 `.url` 입력은 **사전에 이 검증을 통과**해야 한다 (`JD_NOT_VALIDATED`).
- 에러는 `JDError` 로 매핑된다 — INVALID_JD_URL → invalidURL(400), JD_VALIDATION_LIMIT_EXCEEDED → dailyLimitExceeded(429, 1일 5회 초과 → jdText 폴백 유도).

## Job

`DomainJob` — `JobClient.jobs`. 가입 온보딩(`AuthOnboardingJob`)의 직군 선택지. 고른 `jobRole`(서버 Enum 값, 예: BACKEND)의 소비자는 **`UserClient.updateProfile`** 하나다.

프로필에 올려 두면 이후 세션 생성은 그 **서버 프로필 스냅샷**을 읽는다(`InterviewConfig` 에 직군·연차 필드가 없다 → `## Interview`). 서버 Enum 값을 그대로 실어 보내므로 클라이언트에 직군 Enum 을 중복 정의하지 않는다.

- GET `/api/v1/jobs`

## Portfolio

`DomainPortfolio` — `PortfolioClient`. PDF 업로드(20MB·30p 이하, 계정당 1개). 등록(202 PROCESSING) 후 `status` 를 3~5초 폴링 — READY 가 돼야 세션 생성에 쓸 수 있다(`PORTFOLIO_PROCESSING` 방지). 재등록은 `PORTFOLIO_ALREADY_EXISTS` → 삭제 후 등록 UX.

| 메서드 | 엔드포인트 | 비고 |
|---|---|---|
| `list` | GET `/api/v1/portfolios` | `PortfolioList` — MVP 1건이지만 `portfolios` 는 배열 + 가용성 4종 |
| `register` | POST `/api/v1/portfolios` | 메타=query + PDF=multipart `file` |
| `status` | GET `/api/v1/portfolios/{id}/status` | 3~5초 폴링 |
| `delete` | DELETE `/api/v1/portfolios/{id}` | 재등록 전 필수 (1개 제한) |
| `fileURL` | GET `/api/v1/portfolios/{id}/file-url` | PDF 열람용 S3 presigned GET URL. **10분 유효·READY 상태만** — 캐시하지 않고 열 때마다 발급 |

`list` 응답의 `replaceAvailable`·`nextAvailableAt`·`deleteAvailable`·`nextDeleteAvailableAt` 는 **계정 단위 쿨다운**이라 `portfolios` 항목 안이 아니라 `data` 레벨에 온다 — `PortfolioList` 가 그대로 담는다. 전부 옵셔널이라 서버가 빼도 목록만으로 디코딩된다. 읽는 화면은 마이페이지의 `replaceAvailable` 하나뿐이고(삭제·교체 모달 안내 — [[mypage#포트폴리오 한 달 한 번 규칙]]), 나머지 셋은 아직 미소비다(온보딩 S2 삭제 문구는 1 고정 — `OnboardingPortfolioUploadView` TODO).

에러는 `PortfolioError` 로 매핑된다 — 업로드 검증군 INVALID_FILE_TYPE / FILE_TOO_LARGE / PAGE_COUNT_EXCEEDED / INVALID_PDF_FILE (400), PORTFOLIO_ALREADY_EXISTS → alreadyExists(409), PORTFOLIO_NOT_FOUND → notFound(404). 이 4xx 케이스들은 서버 한국어 `message` 를 associated value 로 보존한다(`userMessage`) — 클라 카피가 확정되지 않아 화면이 원문을 그대로 노출하기 때문(인프라 실패는 nil → 클라 폴백 문구).

## User

`DomainUser` — `UserClient`. 회원 프로필 조회/등록·수정과 회원 탈퇴. 조회(profile)와 수정(updateProfile)은 다른 화면(마이페이지 표시 vs 온보딩·프로필 편집)에서 따로 쓰는 전제로 읽기/쓰기 모델을 분리했다(UserProfile vs UserProfileUpdate). 수정값은 이후 새로 생성하는 면접 세션부터 반영된다(과거 세션 스냅샷 불변) — 클라이언트가 이 조회값으로 세션 설정을 프리필한다.

| 메서드 | 엔드포인트 | 비고 |
|---|---|---|
| `profile` | GET `/api/v1/users/me/profile` | 이름·이메일·제공자(KAKAO/APPLE)·직무·연차·잔여 이용권 |
| `updateProfile` | PATCH `/api/v1/users/me/profile` | 온보딩 최초 등록과 재수정 공용. 이름(한글·영문 최대 5자)·직군·연차 매 호출 필수 |
| `withdraw` | DELETE `/api/v1/users/me` | 204. 서버가 소셜 unlink/revoke 까지 수행, 성공 시 클라이언트 토큰도 삭제 |

이름 단독 등록(PATCH `/users/me/name`)은 서버에서 삭제 예정(프로필 API 로 통일), 이름 중복 확인(GET `/users/name/check`)은 스펙에서 제거됨 — 클라이언트에서 걷어냈다(이름은 더 이상 유일하지 않다).

에러는 `UserError` 로 매핑된다 — USER_NOT_FOUND → userNotFound(404), INVALID_JOB_ROLE → invalidJobRole(400), SOCIAL_RECONNECT_REQUIRED → socialReconnectRequired(409, 재로그인 후 탈퇴 재시도), VALIDATION_ERROR·CONSTRAINT_VIOLATION 은 서버 문구를 실은 invalid(message:). 탈퇴 중 소셜 해제 실패(SOCIAL_UNLINK_FAILED, 502)는 5xx 공통 규칙으로 serverUnavailable.

## Feedback Share

`DomainFeedbackShare` — `FeedbackShareClient`. R1 리포트에서 지인에게 면접 영상을 공유하는 링크(토큰)의 사용자측 수명주기: 생성(태도 항목 1~5개 지정, 생성 후 잠김) → 참여 현황 조회 → 비공개 전환(불가역). 면접당 활성 링크 1개. 게스트측 진입/제출은 [[api#Guest Feedback]].

| 메서드 | 엔드포인트 | 비고 |
|---|---|---|
| `status` | GET `/api/v1/feedback/sessions/{id}/share` | ACTIVE/INVALIDATED/PRIVATE + 제출 수(최대 4) |
| `create` | POST `/api/v1/feedback/sessions/{id}/share` | 최초 생성 = 피드백 요청 사건, 영상 삭제 +48h 연장 |
| `makePrivate` | PATCH `/api/v1/feedback/sessions/{id}/share` | 기제출 피드백·영상 삭제 시각은 유지 |

토큰으로 공유 딥링크를 조립하는 것은 클라이언트 책임이다. 에러는 `FeedbackShareError` 로 매핑된다 — FEEDBACK_SHARE_NOT_FOUND → shareNotFound(404), INTERVIEW_SESSION_NOT_FOUND → sessionNotFound(404), FEEDBACK_SHARE_ALREADY_EXISTS → alreadyExists(409, 재생성 미지원), 항목 검증군(EMPTY_ATTITUDE_AXES·TOO_MANY_ATTITUDE_AXES·INVALID_ATTITUDE_AXIS)은 invalidAxes(message:), INVALID_SHARE_STATUS → invalidStatusTransition(400), 미승격 4xx 는 server(원문 동봉 — 임시 노출 규칙, [[api#공통 규약]]).

## Guest Feedback

`DomainGuestFeedback` — `GuestFeedbackClient`. 지인(게스트)이 공유 링크로 진입해 태도 항목을 4단계 척도로 평가·제출하는 **무인증** API. 식별은 공유 토큰 + `Device-Id` 헤더(클라이언트 생성·로컬 보관, 중복 제출 방지) — 그래서 `AuthorizedNetworkClient` 가 아니라 `NetworkClient` 를 직접 쓴다.

| 메서드 | 엔드포인트 | 비고 |
|---|---|---|
| `entry` | GET `/api/v1/feedback/guest/{token}` | 게이트 판정 + 영상·지정 항목. 최초 조회 시 영상 삭제 +7일 연장. **질문 경계는 현 스키마에 없다**(2026-08-13 라이브 스펙 재확인 — 응답은 gate·requesterName·axes·videoUrl·submissionOpen 뿐) — `QuestionBoundary` 는 미리 깔아 둔 계약이라 늘 비어 오고, 그래서 게스트 진행바가 «영상 전체 한 칸» 으로 폴백한다. 추가 요청문 `docs/work/guest-feedback-question-boundaries.md` |
| `submit` | POST `/api/v1/feedback/guest/{token}/submissions` | 지정 항목 전부 필수, 제출 확정(수정 불가). 첫 제출 시 +30일 연장 |

게이트: OPEN / PRIVATE(비공개·무효) / EXPIRED(영상 만료) / FULL(정원 4명) / ALREADY_SUBMITTED(이 기기 제출 완료) — 진입 화면 분기의 전부다. 에러는 `GuestFeedbackError` 로 매핑된다 — FEEDBACK_SHARE_TOKEN_NOT_FOUND → tokenNotFound(404), FEEDBACK_SHARE_CLOSED / FEEDBACK_CAPACITY_FULL / FEEDBACK_ALREADY_SUBMITTED → shareClosed/capacityFull/alreadySubmitted(409, 진입 후 상태 변화 경합), 제출 검증군(INCOMPLETE_RATINGS·INVALID_RATING_LEVEL·MISSING_DEVICE_ID)은 invalid(message:).

공유 링크는 `https://hilit.chottu.link/report?reportId={token}` — 토큰으로 링크를 조립·판정하는 것은 클라이언트(`GuestFeedbackShareLink`·`GuestFeedbackDeeplink`) 책임이다([[feedback#진입로와 닫기]]). 서버는 토큰만 발급하고 링크 형식을 모른다 — 쿼리 이름이 `token` 이 아닌 것도 그래서다(Android 와 맞춘 값).
