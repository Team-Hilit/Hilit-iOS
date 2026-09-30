# AI 면접 — 작업 문서 (기획서 → 우리 아키텍처 매핑)

> YAPP APP 1팀 「AI 면접 연습 앱」 기획서(Part 1 질문 생성 / Part 2 10분 음성 면접)를
> 이 레포의 **Tuist TMA + 순수 TCA** 규칙에 녹인 설계 작업 문서.
> 절대 규칙: **Feature→Feature 의존 0 · Repository(Client)는 Domain 모듈 Interface/Implementation 분리 · cross-feature 조립은 [[app]](AppFeature)에서만.**
> 시스템 전체 그림/결정 근거·Client 분리(D3)는 [[architecture]], 도메인 큰 그림은 [[domain.map]] 참고.
> 출처: Confluence 「Part1. 면접 질문 생성」 / 「Part2. AI와 10분 면접」 (기준일 2026-06-09)
> · **「[PRD] AI 면접 Part 1 — 면접 전 입력 & 포트폴리오 등록」 v3** (2026-07 확정 — §5 전면 반영, 변경 이력 17건은 PRD 1장)
> · **「[PRD] Part 2 — 면접 진행·질문 생성·채점 엔진」 v3** (2026-07-27 확정 — §6 «PRD v3 정합 현황» 반영)

## 0. 제품 → 레이어 매핑

| 기획 | Feature 모듈 | 도메인 내 navigation |
|---|---|---|
| Part 1 면접 전 입력 & 포폴 등록(위저드) | `OnboardingFeature` (FeatureOnboarding — **구현 중**) | 루트(STEP1) + 자체 `StackState` 3스텝 + 프리로드 → §5 · [[onboarding]] |
| Part 2 10분 음성 면접 | `InterviewSessionFeature` ★ (FeatureInterview — **화면 상태머신 구현**, 음성 배선 전) | 단일 화면 + 턴 **상태머신** · 준비/실패/리포트 대기 화면 전환은 모듈 내 `InterviewFeature` 코디네이터 |
| 포트폴리오 관리(설정) | `PortfolioFeature` | — |
| Part 3 보고서/영상 복기 | `InterviewReportFeature` (R0·R1 + V0·V1·V2) | 자체 `Path` (R0→V0→V1→V2→R1) → [ai-interview-report](ai-interview-report.md) |
| Part 4 사람 평가(유료) | (후속, 별도) | — |

★ = 엔지니어링 리스크 집중 지점.
PRD v3 가 화면명을 `Onboarding_*` 로 확정하면서 설계 초안의 가칭 `InterviewSetupFeature` 는 `FeatureOnboarding` 으로 실현됐다. **S0(직군·연차)은 이 위저드에 없다** — 가입 온보딩(`FeatureAuth`)이 받아 프로필에 등록하고, 세션 생성은 서버 프로필 스냅샷을 읽는다(2026-08-04). 위저드가 모으는 건 JD·포폴·대표 프로젝트 셋뿐이다.

## 1. 모듈 의존 그래프

```
App  (composition root — 레이어 umbrella link → liveValue 활성화)
└── AppFeature  (코디네이터: 루트 화면 + Setup→Session→Report 라우팅)
    ├── OnboardingFeature (Part 1) ─┬ DomainJDInterface
    │     STEP1 jobDescriptionUpload ├ DomainPortfolioInterface
    │     STEP2 portfolioUpload      ├ DomainInterviewInterface ✅ (프리로드 세션 생성)
    │     STEP3 mainProject          └ SharedDesignSystem
    │           preload (S3.5+S4)
    ├── InterviewSessionFeature ┬ DomainInterviewInterface
    │   (턴 상태머신)            ├ DomainSpeechInterface     (TTS + STT)
    │                           ├ DomainRecordingInterface  (A/V 캡처·보존)
    │                           ├ DomainPermissionInterface ✅ (준비 화면 권한 게이트)
    │                           └ SharedDesignSystem
    ├── PortfolioFeature ─────── DomainPortfolioInterface · SharedDesignSystem
    └── InterviewReportFeature ─ DomainScoringInterface · SharedDesignSystem
```

STEP1 은 코디네이터 루트에 붙은 스코프 자식이고 STEP2·STEP3·프리로드가 `StackState` 다. `DomainJob` 은 여기 없다 — 직군 선택지는 가입 온보딩(FeatureAuth)이 읽는다.

단방향 DAG. `Onboarding`은 `Session`을, `Session`은 `Report`를 **import하지 않는다** — 기존 Users→App→Profile 핸드오프 패턴([[domain.map]])과 동일.

## 2. Cross-feature 라우팅 (delegate → AppFeature)

```
Onboarding --delegate(.finished(sessionId))--▶ AppFeature --fullScreenCover--▶ Interview ✅ (2026-08-03)
Onboarding --delegate(.dismiss)--------------▶ AppFeature --중도 이탈 (draft 보존, §5)
Session --delegate(.finished)----------------▶ 코디네이터 --업로드 큐 접수--▶ delegate(.finished) --▶ AppFeature --dismiss ✅ (2026-08-06: 리포트 대기 화면 없이 홈 직행)
Session --delegate(.aborted)-----------------▶ 코디네이터 --delegate(.closed)--▶ AppFeature --dismiss ✅ (턴은 서버가 보존 — 차감 D1, PRD §3.7)
설정 Portfolio --delegate(.emptied)----------▶ AppFeature --다음 연습 진입 시 S2 강제 라우팅
```

→ `@lat`: [[app#Cross-feature Routing]] · import에 안 보이는 의존이므로 변경 시 이 표 기준으로 영향 추적.

## 3. Client 설계 (외부 IO — Domain 모듈 Interface/Implementation 분리, [[architecture]] D3)

| Client (모듈) | 책임 | 핵심 시그니처(요지) | 소비처 | 상태 |
|---|---|---|---|---|
| **JobClient** (DomainJob) | 직무 목록 — 서버가 6종 관리(백/프론트/iOS/AOS/데이터/인프라·SRE), 클라는 조회만 | `jobs()→[Job]` | S0a | ✅ |
| **JDClient** (DomainJD) | JD 링크 크롤링·정제·**서버 캐싱** (S1은 캐싱만 — 분석은 세션 생성 시, PRD §3.1) | `validate(url)→JDValidation` — reason: `CRAWLING_FAILED`·`CONTENT_TOO_SHORT`·`EXTRACTION_FAILED` | S1 | ✅ |
| **PortfolioClient** (DomainPortfolio) | PDF 등록(202)·상태 폴링·목록(재설치 복구)·삭제 | `register(PortfolioUpload)→PortfolioProcessing` · `status(id)` · `list()→[Portfolio]` · `delete(id)` | S2·설정 | ✅ |
| **InterviewClient** (DomainInterview) | 세션 생성(= S0~S3 **일괄 수집** + 연관성 검사, PRD §3.8 — 직군·연차는 프로필 스냅샷)·준비 폴링·답변 제출(턴 루프)·질문 오디오·레포트 목록 | `createSession(InterviewConfig)→202` · `sessionStatus(id)` · `submitAnswer` · `questionAudioStream` · `reportList()→[InterviewReportSummary]` | S3.5/S4·Part2·마이페이지 | ✅ 신스펙 정합(2026-08-02) |
| **SpeechClient** (DomainSpeech) | 음성 입출력 | `startCapture()→AsyncStream<SpeechCaptureEvent>` · `stopCapture()` · `play(Data)` / `playStream(url:headers:)→AsyncStream<PlaybackEvent>` · `startSessionAudioRecording()`/`finishSessionAudioRecording()→SessionAudioRecording?` · `startAnswerRecording()`/`answerAudio()→Data?` · `stopPlayback()` — 예정: `transcribe()` (STT 30% 판정은 서버 `STT_RESET` 로 이관 — confidence 집계 폐기) | Part2 | 마이크 캡처 ✅ · 서버 TTS 재생 ✅(2026-08-02) · 세션·답변 m4a 실녹음 ✅(2026-08-05, 작업B 슬라이스1) · 발화 감지 기반 게이팅·STT 는 작업B 슬라이스a 예정 |
| **PermissionClient** (DomainPermission) | 카메라·마이크 권한 — **iOS 는 사용 시점 요청**(PRD §8, 심사 리젝 방지) + 설정 유도 | `status(MediaPermission)` · `request(MediaPermission)→Bool` · `openSettings()` | 준비 화면(P0) | ✅ |
| **RecordingClient** (DomainRecording) | 전면 카메라 프리뷰 + 비디오 전용 캡처·백그라운드 경계마다 세그먼트 분할·정지 시 세션 오디오 사후 합성(A안-2, 30일 보존) | `startPreview()→CameraPreviewHandle?` · `stopPreview()` · `startRecording(sessionId)→Double`(이전까지 누적 녹화초) · `suspendRecording(RecordingAudioSegment?)→Double?`(현 세그먼트 마감, 반환은 누적초) · `stopRecording(finalAudio:)→RecordingRef`(전 세그먼트 합성) · `discardRecording()` · `purgeRecordings(sessionId:)`(킬 클린업 전용) | P0·P1·P4 | 프리뷰 ✅ · 녹화·합성 ✅(2026-08-05, 작업B 슬라이스1) · 세그먼트 분할·재개 ✅(2026-08-09, 면접 재개) |
| **ScoringClient** | 세션 제출·보고서 → [ai-interview-report](ai-interview-report.md) | `submit(session)` · `report(id)→Report` | P4·Part3 | 예정 |

초안의 `QuestionClient`·`PortfolioClient.processOCR/checkRelevance` 는 **서버 내재화로 소멸** — OCR(파싱)·임베딩은 `register` 후 폴링 안에서 서버가 처리하고, 연관성 검사는 `createSession` 이 수행해 실패를 `FREETEXT_NOT_RELEVANT` 에러로 돌려준다. 질문 생성도 세션 API 에 흡수(질문 별도 조회 없음).
규칙: 각 Client 는 **Domain 모듈**, `testValue`는 전부 `unimplemented`(빈 클로저 금지).
SpeechClient는 책임이 커지면 `TextToSpeechClient` / `SpeechRecognitionClient`로 분리 가능하게 시그니처를 나눠 둔다.

## 4. 도메인 모델 (각 Domain 모듈 Interface)

구현 완료 — 각 Interface 파일이 진실. 요지만:

```swift
// DomainJob — 직군은 클라 enum 이 아니라 서버 데이터 (초안의 JobRole enum 소멸)
struct Job { jobId: Int; jobRole: String /* 서버 enum "BACKEND" */; label: String }

// DomainInterview — 세션 생성 입력 = 위저드 산출물 (PRD §3.8: jd·freeText nullable, 나머지 필수)
struct InterviewConfig { portfolioId: UUID   /* 직군·연차 미전송 — 서버 프로필 스냅샷 */
                         jobDescription: JobDescriptionInput?; freeText: String? /* 10~300자 */ }
enum JobDescriptionInput { case url(String) /* validate 선검증 필수 — JD_NOT_VALIDATED */
                           case text(String) /* 200~3,000자 */ }

// DomainPortfolio — status 5종 (PRD §3.3 의 4종 + 서버 스펙의 CANCELLED. EXPIRED/ACTIVE/DELETING 미제공)
enum PortfolioProcessingStatus { PROCESSING · READY · FAILED_FILE · FAILED_SYSTEM · CANCELLED }
struct Portfolio { portfolioId: UUID; fileName?; fileSize?; pageCount?; status?; uploadedAt?; interviewInProgress? }
struct PortfolioUpload { fileName; fileSize?; pageCount?; contentType; data }   // meta 는 클라 전달, 서버 실측 재검증
struct PortfolioProcessing { portfolioId; status; message? }                    // 202·폴링 공통 응답

// DomainJD
struct JDValidation { valid: Bool; reason: String?; message: String? }
```

세션 진행 응답 모델(`InterviewSessionStatus`·`SummaryQuestion`·`NextQuestion`·`TurnInfo`·`AnswerSubmission`·`AnswerResult`)도 DomainInterview Interface 에 구현됨. 초안의 `RelevanceResult` 는 소멸 — 연관성 실패는 `createSession` 에러(`FREETEXT_NOT_RELEVANT`)로 온다.
모듈 경계 넘는 타입은 전부 `public`(+`init`), `Equatable`/`Sendable` 기본.

## 5. Part 1 — `OnboardingFeature` (위저드, PRD v3)

S1→S3.5는 **도메인 내부** navigation → 규칙대로 자체 `Path` + `StackState`(STEP1 은 루트 스코프 자식). 코디네이터가 누적 `OnboardingData`(JD·portfolioId·portfolioFileName·freeText + 표시용 userName)를 들고, 각 스텝은 delegate 로만 위로 신호. **직군·연차는 여기 없다** — 가입 온보딩이 프로필에 등록해 두고 세션 생성이 서버 스냅샷을 쓴다. 구현 세부·현재 TODO 는 [[onboarding]] 이 진실 — 여기는 PRD ↔ 구현 매핑과 남은 개발 포인트만.

`totalSteps = 3` — 프로그레스 바가 세는 건 STEP1~3 이고 프리로드는 스텝 밖 전환 화면이다.

| PRD | 스텝 (구현) | 필수 | 상태 |
|---|---|---|---|
| S0 직무·연차 | — 가입 온보딩(`FeatureAuth`)으로 이관 | 필수 | ✅ 프로필 등록 → 세션 생성은 서버 스냅샷 |
| S1 JD | STEP1 JobDescriptionUpload — 링크/직접입력 탭 (상호배타) | 선택 — 스킵 상시 | ✅ 직접입력 200~3,000자 검증 완료 (링크 5회 제한·CONTENT_TOO_SHORT 문구 TODO) |
| S2 포트폴리오 | STEP2 PortfolioUpload — 202+폴링 | 필수 | ✅ 페이지30·암호 선검증 + 기존 포폴 확인 모달 완료 (폴링 상한·409 복구 TODO) |
| S3 집중 프로젝트 | STEP3 MainProject — 자유입력 | 선택 — 스킵 상시 | ✅ 상단 문구 PRD 확정본 반영 |
| S3.5 연관성 + S4 진입 | Preload — **세션 생성 지점** | — | ✅ 세션 생성·폴링·연관성 실패 루프(경고·4회 다이얼로그)·완료 전환 완료 |

### PRD v3 핵심 확정 → 클라 영향

- **재시도·멱등성 키 전면 제외** (PRD §3.1·§3.5) — 클라 재시도 버튼·키 생성 전부 없음. 실패 = FAILED 표시 후 "처음부터 재업로드". 3불변식(실패는 status 로 / READY 는 맨 마지막에만 / lazy 정리)은 서버 책임이라 클라는 status 만 신뢰하면 됨.
- **비동기+폴링 확정** (동기 재검토 단서 삭제) — 202 후 statusUrl 3~5초 폴링, 진행률 미표시(무한 스피너 + 철학 회전 문구). 처리 짧아져도 첫 폴링에 READY 로 동작.
- **JD 는 S1 에서 캐싱만** — 분석은 세션 생성 시. 캐시 만료 경계(Part1↔2)는 서버 확인 항목.
- **개별 저장 API 없음** — S1~S3 입력은 `createSession` 이 일괄 수집. `InterviewConfig` 필수는 **포트폴리오(READY) 하나**고 jd·freeText 는 nullable. 직무·연차는 payload 에서 빠졌다(가입 온보딩이 프로필에 등록 → 서버 스냅샷, 2026-08-04).
- **직군 6종·화이트리스트** — 드롭다운 외 직군 fallback UI·안내 불필요.
- **태블릿 제외**, 최소 OS 버전만.

### 스텝별 개발 포인트

- **직군·연차 (S0) — 이 위저드 밖** ✅: 가입 온보딩(`FeatureAuth` — `AuthOnboardingJob`·`AuthOnboardingCareer`)이 받아 `UserClient.updateProfile` 로 프로필에 올린다. `createSession` payload 에는 두 필드가 없고 서버가 프로필 스냅샷을 읽는다(2026-08-04) — 위저드도 `OnboardingData` 도 두 값을 들고 다니지 않는다 → [[api#Job]]·[[api#Interview]].
  - 직군: 서버 직무 API(`JobClient.jobs`) ✅ — 서버 Enum 값(예: BACKEND)을 그대로 올려 클라 Enum 중복 정의 없음.
  - 연차: 정수 피커 확정(사용자 결정 2026-07-20). `CareerOption { years: Int }` 0~10년(10="10년 이상"). 레벨(주니어/미들/시니어)은 서버가 0-2/3-7/8+ 파생 — 클라 미관여. 휠 라벨: 신입 / N년 이상 / 10년 이상 (최종 시안 3632:14460 표기, 2026-07-31 — 07-20 결정 당시 「N년차」에서 표기만 변경. 값 계약은 그대로 정수).
  - 2회차부터 직무·연차 skip 은 서버 준비 완료 — 반복 연습이 MVP 제외라 클라는 후속.
- **STEP1 JD** — 링크 검증(계속하기 탭 → `validate`, 성공 시 바로 다음 스텝) ✅ · 성공 시 직접입력 탭 잠금 ✅ · **링크 탭 계속하기는 빈 입력(스킵)/형식 통과 링크만 활성** — 분석 중 비활성 ✅ · **스킵 시 입력 있어도 검증·저장 없이 통과**(jd=nil) ✅ · ① 직접입력 **200~3,000자** 검증(유효 길이만 계속하기 활성, 무효 시 카운터·red 보더·안내 문구, 초과 클램프 안 함) ✅. TODO: ② 링크 본문 <200자 = `CONTENT_TOO_SHORT` 문구 노출 ③ **링크 검증 1일 5회 제한** 초과 에러 노출(서버 에러 코드 확인).
- **STEP2 포트폴리오** — 클라 선검증은 UX 용 빠른 차단, **최종 판정은 서버 실측**(PRD §7 분담): PDF 타입·20MB ✅ / **페이지 ≤30**(PDFKit `pageCount`) ✅ / **암호 PDF**(`PDFDocument.isEncrypted`) ✅ — `PortfolioFileReader` 가 data+pageCount+isEncrypted 반환, register 전 차단, pageCount 는 서버에 전달. 글자 수 ≥30 은 서버 전용(Tika) → FAILED_FILE 문구만. 폴링 3초 ✅. **1개 제한은 사후 에러가 아니라 사전 확인으로 처리한다** ✅ — 빈 판 진입마다 `PortfolioClient.list` 로 READY 를 찾아 «기존에 있는 포트폴리오로 진행할까요?» 모달을 띄우고 재등록 없이 완료 판으로 앉힌다(자동 교체 금지는 그대로 — 바꾸려면 X → 삭제 확인). TODO: **폴링 상한**(전체 처리 타임아웃 → FAILED_SYSTEM 취급 문구, 초기값 tentative) · `PORTFOLIO_ALREADY_EXISTS`(409) 복구 — 확인 모달이 못 막는 창구가 남아 있다(§[[onboarding#포트폴리오 업로드]]) · 셀룰러 20MB 경고(후속).
- **STEP3 집중 프로젝트(대표 프로젝트)** — 10~300자 · 상한 300 클램프 · 빈 입력 = 스킵(nil) · **하한 10자 클라 선검증** ✅(입력 있고 <10자면 continue 차단+경고, PRD §7 분담 — 연관성 등 최종 판정은 서버) · 상단 고정 문구 교체 확정본("입력하면 그 부분을 집중 검증해요. 건너뛰면 포트폴리오 전체에서 질문해요.") 반영 ✅.
- **프리로드 = S3.5 + S4** — Phase A ✅ / Phase B 🟠:
  1. ✅ `OnboardingData.interviewConfig()` → `InterviewClient.createSession` + `sessionStatus` 폴링(3초). `.domain(interface: .interview)` 의존 추가 + `tuist generate`. PROCESSING→폴링 / READY→completed / 실패·config 불완전→failed 화면(재시도 없음, PRD §3.1). config 불완전 = `portfolioId` 부재뿐 — 직군·연차는 payload 에서 빠져(서버 프로필 스냅샷) 검사도 제거했다(2026-08-04).
  4. ✅ READY → `delegate(.completed(sessionId:))` → 코디네이터 `delegate(.finished(sessionId:))` → **AppFeature 가 cover 를 닫고 그 id 로 면접을 연다**(`InterviewFeature.State(sessionId:)` — 2026-08-04 배선). 요약 질문 등 payload 확장은 후속. READY 즉시 넘기지 않고 **그린 사면이 올라와 화면을 덮는 전환(0.9초) + 완료 문구**를 거친다(시안 443:9881) — 상세 [[onboarding#프리로드]].
  2. ✅ 연관성(코사인 ≥0.6 tentative)은 **freeText 있을 때만** 서버 검사. `FREETEXT_NOT_RELEVANT`(Core `ServerError`)를 DomainInterview 가 `InterviewError.freeTextNotRelevant` 로 매핑(레이어 준수) → 분석이 `delegate(.relevanceCheckFailed)` → 코디네이터가 집중 프로젝트로 pop-back + `relevanceFailureCount++`.
  3. ✅ 4회 미만 실패 → 집중 프로젝트에 경고 문구(PRD 확정) 주입 + 재입력. **연속 4회째** → `ConfirmationDialogState` 2선택지: [포폴 다시 올리기 → STEP4 pop] / [집중 프로젝트 없이 진행 → freeText=nil 로 재분석]. 카운트 `relevanceFailureCount`, 편집 시 경고 해제.

### 입력 draft (PRD §4.4) ✅

S1~S3 입력을 로컬 draft 로 자동 저장 — **앱 진짜 종료(kill/크래시) 대비**. **재개식**(사용자 결정 2026-07-20): 값 + 위저드 위치를 복원해 이어서 시작.
- `OnboardingDraftStore` seam(UserDefaults JSON, PortfolioFileReader 와 같은 로컬 IO 선상) — load/save/clear. `OnboardingData` 는 Codable, `portfolioFileName` 추가(완료 행 복원용).
- 저장: 각 스텝 완료(continue)마다 `persist`(data + furthestStep = path.count+1 + savedAt).
- 폐기: **면접 정상 종료 시** — `AppFeature` 가 `interview(.delegate(.finished))` 에서 clear 한다. 세션 생성 성공 시점이 아닌 이유: 그 사이 앱이 죽거나 면접에서 이탈하면 값이 다시 필요하고, 홈의 «이전 정보 재사용»·[수정하기] 도 draft 복원에 얹혀 있다. 면접 이탈(`closed`)은 보존. 그 외 clear 경로는 dev 재설치 흉내·TTL 만료 둘뿐이다 → [[app]].
- 복원(코디네이터 onAppear): `path` 비었을 때만 **위저드 수명당 1회**(`didAttemptRestore`), TTL **14일** 안이면 data 복원 + 위저드 되쌓기(프리로드는 제외, STEP3 까지). JD 는 `restoring:` init 으로 탭·검증상태 복원.
- 잔여(TODO): **포폴 삭제 시 clear** — 지금은 마이페이지에서 포폴을 지워도 draft 의 `portfolioId` 가 남고, 복원이 그걸 `.uploaded` 로 앉히면 STEP2 진입 조회가 안 켜져 죽은 id 로 프리로드까지 간다(§[[onboarding#포트폴리오 업로드]]).

### 재진입 분기 (PRD §8)

- 업로드 중 백그라운드 → 복귀: 폴링 재개로 충분(Foreground Service 급 장치 미채택 결정과 동일 노선). 🍎 background URLSession 도입·완료 푸시 제공 여부는 미결.
- 앱 종료 후 재진입: **입력 draft** 가 값·위저드 위치를 복원한다(위 §입력 draft). 
- 🟡 잔여 refinement: 폴링 중 강제종료 시 draft 는 포폴 스텝(미완료)으로 복원 → `PortfolioClient.list` 로 status 재조회해 **그새 READY 면 STEP5 로 건너뛰기**. draft 와 겹쳐 우선순위 낮음.
- 포폴 0개(삭제됨): 다음 연습 진입 시 S2 강제 라우팅 — AppFeature 몫(§2 표).

### 권한·문구·측정

- 카메라·마이크 권한: **iOS = 사용 시점 요청**(온보딩 강제 시 심사 리젝 — AOS 만 온보딩 획득). ✅ 준비 화면(Readiness)이 진입 시 요청만 하고(거부여도 가이드 조용히 진행), 게이트는 «시작하기» 탭 — 미허용이면 설정 유도 alert([설정으로 이동]/[닫기=화면 유지, 재시도는 재탭]) — [[interview#준비]]. alert 문구는 임시(PM 확정본 대기, `permissionDeniedAlert()` 한 곳만 교체).
  - 앱 타겟·Example 둘 다 Info.plist 목적 문구 보유(`Target+Templates.swift` .app 팩토리 / FeatureInterview Project.swift). Example 의 실행 직후 `AVCaptureDevice.requestAccess` 임시 배선은 제거(2026-07-27) — DomainPermissionImplementation link 로 대체.
- 문구는 PM 확정본(PRD §6 표) — 서버 응답 `message` 우선, 클라 fallback 하드코딩. 노출 컴포넌트(toast/modal/dialog) 공통 규칙은 디자인 후속.
- 측정(PRD §7: 글자 수 분포·연관성 실패/오판율·처리 시간·FAILED_FILE/SYSTEM 비율)은 애널리틱스 도입 시 이벤트 설계로 이월.

## 6. Part 2 — `InterviewSessionFeature` ★ 핵심 난이도

**겹치는 타이머 + 실시간 오디오 스트림 + 인터럽트**가 한 reducer에 모인다. TCA 정석 레시피:

### (a) 턴 phase = 명시적 enum 상태머신
현행 구현(`InterviewSessionFeature.State.Phase`) — View 가 그리는 상태 칩 3종(PRD §3.5)에 1:1 대응한다:
```swift
enum Phase {
    case asking            // 질문 TTS 재생 — 칩 «질문 듣는 중»
    case answering         // 답변 녹음 — 칩 «답변 녹음 중» + «답변 완료하기»
    case processingAnswer  // 답변 확정 직후 — 칩 «답변을 정리하고 있어요» (되돌리지 않는다)
    case finalCountdown    // 11:50~ 빨간 «N초» 초읽기 — 상태 칩 없음
}
```
- P0 권한·질문 준비 대기는 **준비 화면(Readiness) 게이트**로 실현([[interview#준비]]) — 세션 phase 가 아니다.
- 구 기획서의 `thinking(5초)`·`fillerTransition`·`wrappingUp`·`finished(EndStatus)` 는 phase 로 두지 않는다: **침묵 판정·발화 감지·사고 5초·필러/마무리 멘트는 SpeechClient(작업 B)** 가, **랩업 8:45·자연 종료는 서버 신호(작업 C)** 가 결정한다. 종료는 phase 가 아니라 `delegate(.finished/.aborted)`.
- 하단 토스트는 2종(`exitUnlocked` 8분 해금 · `timeExpired` 상한 도달)뿐 — «답변이 기록 됐어요» 토스트는 칩 3종 확정으로 소멸.

### (b) 질문 텍스트는 State에만, View엔 노출 X
디자인 방향성 = **TTS-only**. View 는 상태 칩(질문 듣는 중 / 답변 녹음 중 / 답변을 정리하고 있어요)과 카운트다운만 그린다.

### (c) 모든 타이머·스트림은 취소 가능 effect, CancelID로 관리
현행은 `enum CancelID { case clock, toast, submission, micCapture, playback }` — 음성 배선(작업 B) 때 `silence`·`stt` 가 붙는다.
```swift
@Dependency(\.continuousClock) var clock
@Dependency(\.speechClient) var speech   // 작업 B
```
- **세션 시계**(현행 1초 tick — 표기가 m:ss): 누적 시간 → `8:00 수동종료 해금`(+해금 토스트 3초) · `11:50 finalCountdown`(10초 초읽기) · `12:00 hard cap 강제종료`. 8:45 랩업(새 질문 금지)은 클라 임계가 아니라 **서버 신호**(작업 C). ✅ 구현 — `hardCapSeconds = 12*60`(PRD §3.6). 「10:00 종료」는 구 기획 수치로 소멸.
- **타이머 표기**: 10분을 넘어도 m:ss 상승 표기를 그대로 유지하고, «12분» 숫자는 어떤 화면·문구에도 노출하지 않는다(§3.10 — 사용자에게는 «약 10분»).
- **TTS**: 서버 오디오 재생(`play`=base64 요약 질문 / `playStream`=chunked 질문) `.finished` → answering ✅(2026-08-02) — 사고 5초 카운트다운은 작업 B.
- **5초 생각**: 카운트다운, 먼저 말하면(STT partial 수신) 즉시 `answering` 점프.
- **STT**: `transcribe()` partial마다 `lastSpeechAt` 갱신 + `silence` 타이머 리셋.
- **종료 판정**: 발화 후 **10초 침묵** → 답변 확정(`processingAnswer`). ~~무발화 15초 → "질문 다시?"~~ 는 **PRD v3 로 소멸** — 무응답 재질의는 서버 몫이고 5회 재질의 종료 규칙은 §3.4(화면·멘트 미확정, §10). 사용자가 «답변 완료하기» 를 누르면 침묵 판정을 기다리지 않고 그 즉시 확정한다 ✅.
- **답변 완료 버튼 게이팅**(발화 시작 후에만 노출)·**필러/마무리 멘트**는 STT partial 신호 의존 — 작업 B.

### (d) 세션 무결성 — P2 중단 = 이탈 신호(기록은 서버 보존)
`scenePhase` + `AVAudioSession` interruption(전화·백그라운드·네트워크) 구독 → 모든 CancelID cancel + `.delegate(.aborted)`. (논의 N: 전화 차단 기술적 불가하면 이 경로 확정.)
⚠️ `aborted` 는 **기록 폐기가 아니다** — PRD §3.7 상 그때까지의 턴은 서버가 보존한다. 남은 `aborted` 소비처는 네트워크 오버레이 «중단하기» 하나다(2026-08-09).
⚠️ **8분 전 중도 이탈은 2026-08-09 부터 세션을 끝내지 않는다** — BACK_EXIT 제출을 걷어내고 백그라운드 동결과 같은 경로로 홈에 내보내, 홈 «진행 중» 카드가 `sessionId` 로 재개한다. 차감 확정은 홈 [처음부터 시작](USER_EXIT) 으로 밀렸다. 경고 모달 문구(«지금 나가면 방금 쓴 이용권 한장이 사라져요»)는 아직 옛 동작 기준 — 디자이너 확정 대기.

### (e) STT 30% 실패(P3) — 서버 판정으로 확정 (2026-08-02)
~~`Transcript.confidence` 턴별 집계~~ **폐기** — 판정은 서버 책임으로 확정됐다. `submitAnswer` 응답 `endType=STT_RESET`(이용권 환불·리포트 없음)으로 통보되고, 클라는 `failed(.speechRecognition)` 전환만 한다. 논의 H/I 는 종결.

### 꼬리질문 depth (기획서 §3)
0~4년차 = 한 프로젝트 3단계 / 5년차+ = 5단계. 10분 최대 10질문. STAR 5단계(의사결정 맥락 → 트레이드오프 → 실패·모호함 → 성공지표 모호함 → 응용) 위임은 `InterviewClient.submitAnswer` 가 담당 — 직전 답변을 제출하면 서버가 depth 를 판단해 `AnswerResult.nextQuestion`(`TurnInfo` 의 turnLevel/depthLevel 포함)으로 다음 질문을 돌려준다. 클라는 별도 질문 조회 없이 이 응답 루프만 돈다.

### PRD v3(Part 2) 정합 현황 — 2026-07-27

「[PRD] Part 2 — 면접 진행·질문 생성·채점 엔진」 v3 대비 **서버·미디어 없이 맞출 수 있는 화면·타이밍·문구·종료 경로**를 정합시켰다. 근거·차이표는 [스펙](../superpowers/specs/2026-07-27-interview-part2-prd-alignment-design.md), 실행 단위는 [플랜](../superpowers/plans/2026-07-27-interview-part2-prd-alignment.md).

- ✅ **타이밍**(§3.6) hard cap 12:00 · 11:50 초읽기 · 8:00 해금 · «12분» 미노출(§3.10)
- ✅ **상태 칩 3종**(§3.5) asking/answering/processingAnswer — «답변이 기록 됐어요» 토스트 제거
- ✅ **질문 준비 게이트**(§3.2) 준비 화면 `sessionStatus` 3초 폴링, 시작 게이트 = guide2 + 권한 + READY 삼중, 클라 타임아웃 없음
- ✅ **실패 화면 3종**(§3.2·§3.7·§3.9 → 2026-08-06 시안 갱신) questionPrep(처음으로만·재시도 없음) / network(«이어서 진행하기»|«중단하기» — 세션 위 오버레이) / speechRecognition(«중단하기» 단일 — 재시작 소멸)
- ✅ **종료 경로**(§3.7·§3.8) 8분 전 중도 이탈 경고 → 동결·`interrupted`(2026-08-09 — 세션 유지, 재개 가능) / 8분 후·상한·마치기 → 업로드 큐 접수 후 `finished`(2026-08-06: 리포트 대기 화면 소멸, 홈 직행). 확정 문구는 부록 C
- ✅ **실녹화·업로드(작업B 슬라이스1)** — 2026-08-05: 비디오 전용 캡처 + 세션 오디오 사후 합성(A안-2) · `answerAudio` 실구현(m4a) · 조용한 업로드. 스펙 [2026-08-04-interview-recording-upload-design](../superpowers/specs/2026-08-04-interview-recording-upload-design.md) (§④·§⑤ 는 아래 개편이 대체)
- ✅ **이탈·백그라운드 업로드 개편** — 2026-08-06: 종료 즉시 홈 직행 · `InterviewVideoUploadQueue`(저널 + background URLSession, 앱 재실행 재개·72h 폐기) · 네트워크 실패는 세션 오버레이(재개 가능). 스펙 [2026-08-06-interview-exit-background-upload-design](../superpowers/specs/2026-08-06-interview-exit-background-upload-design.md), 상세 [[interview#업로드 큐]]·[[interview#세션]](lat.md/interview.md)
- 🔴 **Speech/Recording 배선(작업B 슬라이스a)** — 발화 감지 기반 «답변 완료하기» 게이팅 · 침묵 10초 확정 · 사고 5초 카운트다운 · 필러 멘트(PRD 수치 확정 후 별도 스펙). 질문 TTS·마무리 멘트 재생은 ✅(2026-08-02)
- ✅ **서버 턴 루프(작업 C)** — 2026-08-02: `submitAnswer` 실배선(2초 mock 소멸) · 응답 endType 5종 분기 · 랩업 8:45 `isWrapUp` · 503 백오프(1s·3s×2) · 종료 경로 제출 경유(MANUAL_END/HARD_CAP/BACK_EXIT — 구 EARLY_EXIT, 2026-08-03 서버 개명) · Example 실서버 하네스(`HILIT_ACCESS_TOKEN`). 스펙 [2026-08-02-interview-api-design](../superpowers/specs/2026-08-02-interview-api-design.md)
- ✅ **AppFeature 배선(작업 D)** — 2026-08-03: 온보딩 `finished(sessionId)` → 면접 fullScreenCover, 종료 두 신호(`finished`/`closed`)가 cover 를 닫고 홈 재조회 · 면접 중 전역 LoadingModal 억제. 스펙 [2026-08-03-interview-exit-to-home-design](../superpowers/specs/2026-08-03-interview-exit-to-home-design.md). 잔여: 홈 «면접 시작» 직접 진입(이용권 게이트 — home-account §4 미결 6-1)
- 🟡 **범위 제외** — 8:00 이후 잔여 시간 인디케이터(디자인 미확정) · 5회 재질의 종료(§3.4 — PRD §10 미확정)

## 7. 기획서 "논의할 문제" → 아키텍처 영향도

빌드 전 **반드시 잠가야 하는(load-bearing)** 것:

| 항목 | 영향 | 잠그는 시점 |
|---|---|---|
| **TTS-only** (Part2 디자인방향성·P1#9) | SpeechClient에 TTS 필수 + 5/15초 타이밍이 TTS *완료* 기준 | 🔴 Session 착수 전 |
| **E** 10질문 vs 3·5단계 배분 / **F** 복수 프로젝트 지정 | `followUp` depth·예산 로직, 턴 루프 종료 조건 | 🔴 Session 착수 전 |
| **N** 전화 수신 차단 가능? | P2 abort 경로(구독 vs 차단) | 🔴 Session 착수 전 |
| **H/I** STT 30% 측정·귀책 | SpeechRecognition confidence 제공 여부 | 🟠 인터페이스 확정 시 |
| **A** 정상완료 vs 포기 구분 | `EndStatus` + Scoring 트리거 | 🟠 P4 착수 전 |
| **J** Scoring 시점(Part2/3 경계) | Session→Report delegate 계약 | 🟠 P4 착수 전 |
| ~~**연차 선택지 세트**~~ → 정수 0~10년 확정(2026-07-20) | `CareerOption{years}` → `updateProfile` 로 프로필 등록(세션 payload 아님) | ✅ 완료 |
| **연관성 4회 실패 카운트** 임계 (PRD tentative) | Analysis State 카운터 + 2선택지 분기 | 🟠 분석 API 연결 시 |
| ~~**입력 draft** TTL 14일 (PRD §4.4)~~ → 재개식 구현 ✅ | `OnboardingDraftStore`(UserDefaults) | ✅ 완료 |
| **세션 생성 payload** (Part1↔2 경계, PRD §3.8 부록) | Onboarding→AppFeature→Session delegate 계약 | 🔴 분석 API 연결 시 (서버 정합) |
| #5 PDF 상한(20MB/30p) / 암호·페이지 클라 선검증 | PortfolioClient 선검증 seam | 🟡 STEP4 (일부 구현) |
| 카운트다운·상태 인디케이터·토스트 | SharedDesignSystem 컴포넌트 추가 | 🟡 병행 |

v3 로 **닫힌** 논의(초안 미결 → 해소): 재시도/멱등성(전면 제외), 동기vs비동기(비동기+폴링 확정), status 개수(4개 확정), 검증 분담(클라 선검증+서버 실측), 채점 엣지(Part2 §9 천장 규칙 흡수). 연관성 LLM 병행은 MVP 제외로 종결(오판 신고율 감시 후 재검토).

## 8. 빌드 순서 (CLAUDE.md "새 모듈 추가 흐름"에 정렬)

1. ~~**Domain 모델 + SharedDesignSystem**~~ ✅ Job·JD·Portfolio·Interview Interface + DS 토큰 구현
2. ~~**Domain Clients = Interface 먼저**~~ ✅ Job·JD·Portfolio·Interview (Speech·Permission·Recording·Scoring 은 Part2/3 착수 시). liveValue 는 Implementation stub
3. ~~**OnboardingFeature (Part 1)**~~ ✅ — STEP1 JD·STEP2 포폴·STEP3 대표 프로젝트 + 프리로드 세션 생성·입력 draft·홈 진입 배선까지. 직군·연차는 가입 온보딩(`FeatureAuth`) 몫. 잔여는 §5 개발 포인트의 TODO 들(폴링 상한·409 복구·문구)
4. **InterviewSessionFeature** ★ — mock SpeechClient(스크립트 AsyncStream) + `TestClock`로 상태머신 결정론 검증. 디바이스 의존 전에 Example 앱 + 단위테스트로 격리.
   **화면 골격 ✅ (2026-07-25, FeatureInterview 모듈)** — 준비(카메라 확인·가이드)→세션(시계·8분 해금·최종 카운트다운·종료 확인)→실패 화면 상태머신 + 코디네이터, 세션 시계는 TestClock 테스트 고정.
   권한(Permission) 준비 화면 게이트 ✅(2026-07-27) · **PRD v3 화면 정합 ✅(2026-07-27)** — 타이밍 12:00·상태 칩 3종·질문 준비 폴링 게이트·실패 3종·중도 이탈 경고(§6 «PRD v3 정합 현황»).
   카메라 프리뷰 ✅ (2026-07-28, DomainRecording) — 준비·세션 화면 실동작, aligning→ready 는 «최소 유지+프리뷰 해소» 이중 게이트, 이탈 시 코디네이터가 정지. backdrop 은 InterviewView 상주(2026-07-29 — 화면 교체 시 프리뷰 레이어 재생성으로 끊겨 보이던 문제 해소). 상세 [[interview#프리뷰]](lat.md/interview.md).
   마이크 캡처 ✅ (2026-07-29, DomainSpeech) — 세션 전구간 레벨(1초)·발화 감지 로그로 마이크 동작 검증, STT 는 Implementation 교체 seam 만 마련. 상세 [[interview#음성 캡처]](lat.md/interview.md).
   서버 턴 루프 ✅ (2026-08-02, 작업 C) — `submitAnswer` 실배선·endType 5종 분기·503 백오프·종료 경로 제출 경유 + 질문 TTS/마무리 멘트 재생(SpeechClient play/playStream) + Example 실서버 하네스(`HILIT_ACCESS_TOKEN`).
   AppFeature 배선 ✅ (2026-08-03, 작업 D) — 온보딩 완주 → 면접 fullScreenCover → 종료 시 홈 복귀(재조회) 왕복 성립, 면접 커버 중 전역 LoadingModal 억제.
   실녹화·업로드 ✅ (2026-08-05, 작업B 슬라이스1) — `RecordingClient.startRecording`/`stopRecording`(합성)·`answerAudio` 실구현·조용한 업로드. 상세 [[interview#프리뷰]]·[[interview#음성 캡처]](lat.md/interview.md)
   이탈·백그라운드 업로드 개편 ✅ (2026-08-06) — 정상 종료는 리포트 대기 화면 없이 홈 직행, 산출물은 `InterviewVideoUploadQueue`(저널+background URLSession)가 앱 수명과 무관하게 완주시킨다. 네트워크 실패는 세션 오버레이로 재개 가능. 상세 [[interview#업로드 큐]]·[[interview#실패]](lat.md/interview.md)
   잔여 🔴: 발화 감지·침묵 10초·사고 5초·필러 멘트(작업B 슬라이스a). 상세 [[interview#면접 흐름]](lat.md/interview.md)
5. **PortfolioFeature**(설정 관리) — `list`/`delete` 재사용
6. **AppFeature 배선** ✅ Onboarding delegate(.finished(sessionId)/.dismiss) 수신 + 면접 fullScreenCover. 홈 «면접 시작» 직접 진입은 이용권 게이트 미결(home-account §4)
7. **InterviewReportFeature** stub → Part 3 본격화

온보딩 마감 잔여(Part 2 무관): 입력 draft(§4.4) · 재진입 분기(§8) · AppFeature 배선(finished(sessionId) 수신·Part2 진입·포폴 0개→S2 강제). 완료: STEP2 정수 피커 ✅ · 분석 세션 연결 ✅ · 연관성 루프 ✅ · JD/포폴 검증 ✅.

## 9. 미정/후속

- ~~Part 3 Scoring 입출력 스키마 (보고서 항목) — 별도 기획 필요~~ → 기획서 나옴, 설계 완료 [ai-interview-report](ai-interview-report.md) (ScoringClient 확장 + PlaybackClient·ReviewClient 신규)
- Part 4 사람 평가 연계 + 유료 게이팅(논의 L)
- 탭 구성(연습/기록/설정) — 제품 IA 확정 시 [[domain.map]] 갱신

### PM·디자인 회신 대기 (Part 2, 2026-07-27 기준)

- **사고 5초 · 침묵 10초 수치 기술 검토 회신**(PRD §3.6 «클라 회신 대기») — 작업 B(SpeechClient) 착수 전에 잠가야 하는 값. 확정 전까진 상수 미배선.
- **신규 화면 2종 시안 미출** — 질문 준비 실패(`Interview_QuestionPrepFailure`) · 중도 이탈 경고(`Interview_EarlyExitWarning`). 기존 레이아웃·DS 토큰 재사용으로 임시 구현했고(배지는 network error 임시 전용), 시안 확정 시 교체. 리포트 대기(`Interview_ReportPending`)는 2026-08-06 개편으로 화면 자체가 사라져 대기 목록에서 뺐다.
- **상태 칩 «답변을 정리하고 있어요» 시안 미출** — 현재 answering 칩 스타일 1:1 재사용(문구만 PRD 확정본).
- **8분 이후 잔여 시간 인디케이터**(§3.6) — 시각 표현 미확정이라 미구현. 디자인 나오면 세션 상단 칩과 함께 재설계.
- **«답변이 기록 됐어요» 토스트 제거 확인** — PRD 칩 3종이 확정 표기라 제거했으나 Figma 구 시안에는 남아 있다. 디자인 확인 필요.
- 준비 화면 권한 미허용 alert 문구 — PM 확정본 대기(`permissionDeniedAlert()` 한 곳만 교체, §5 권한).
