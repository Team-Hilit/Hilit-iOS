# AI 면접 Part 3 — 1차 리포트 개발 정의서

> YAPP APP 1팀 「AI 면접 연습 앱」 기획서 **Part 3 (1차 리포트 & 영상 다시보기)** 를 이 레포 구조(**Tuist TMA + 순수 TCA**)로 옮긴 **개발 착수용 정의서**. 화면별 State/Action·서버 필드 매핑·문구 소유 주체·부족한 계약까지 확정한다.
> 절대 규칙: **Feature→Feature 의존 0 · Repository(Client)는 Domain Interface/Implementation 분리 · cross-feature 조립은 [[app]](AppFeature)에서만.**
> 현재 코드 상태는 [[report]], 서버 계약은 [[api#Interview Report]], 레이어 규칙 [[architecture]], Part1/2 설계 [ai-interview](ai-interview.md).
> **개정 2026-07-25** — 구버전(2026-06-15 PDF 기준) 설계 전량 폐기하고 재작성(§0-3). 이전 판의 R0/V0/V1/V2/R1 화면 코드·자기평가 입력·Client 3모듈 신설 제안은 더 이상 유효하지 않다.

## 0-1. 착수 전 차단 이슈 (🔴 먼저 읽는다)

**개정 2026-08-06 — §9-1 확장이 스웨거에 실렸다(차단 해소).** 실계약: 하이라이트에 `reason`(PROBE_WORTHY/OFF_INTENT/SHALLOW/SUFFICIENT)·`title`·`analysis`·`followUpQuestions`(PROBE_WORTHY 만)·`startSec`·OFF_INTENT 전용 3필드(`answerTopicTitle`·`questionIntentTitle`·`questionIntent`), 카드에 `questionIntentTitle`·`scriptSegments`(면접관/면접자 `role` 혼재 + 카드 대본 문자 오프셋), 최상위에 `script`(세션 전체 타임라인). 레드플래그는 보고서 단위 배열이 없어지고 **카드 `cardRedFlagNotices` 로만** 온다. 시각은 합성 영상(=녹화) 기준으로 확정(§9-1 의 5-1 해소). 옛 이름 `segments`/`words`/`evidenceStartAt` 은 폐기.
**남은 확장 대기는 행동형 키워드 태그 하나**다(시트 볼드 줄은 `span.title` 로 해소).

(이하 2026-07-29 개정 기록 — 역사적 기록으로 유지)
서버가 대본 타임스탬프를 두 해상도로 내려주기로 했었다: 구간 `segments` · 단어 `words`. 이 형태는 위 개정으로 대체됐다.

| PRD 요구 | 현 계약으로 | 막는 것 |
|---|---|---|
| 한 줄 요약·레드플래그 줄·카드·질문 의도·해상도 안내 | ✅ 만들 수 있다 | — |
| 대본 하이라이트 색 구분(잘함/개선) | ✅ 만들 수 있다 | 해결 — 스웨거 enum `GOOD|IMPROVE` |
| 상세 시트 depth 1 진단 (행동형 키워드 태그) | ⚠️ 부분 | 볼드 줄은 `span.title` 해결, 키워드 태그 필드만 없음 |
| 상세 시트 depth 2 다음 대비 (후속 질문) | ✅ 만들 수 있다 | 해결 — `reason` 별 `followUpQuestions` / OFF_INTENT 대조 3필드 |
| `[영상 보러가기]` · STT 오버레이 시간 동기 · 구간 seek | ✅ 만들 수 있다 | 해결 — `card.scriptSegments` + 최상위 `script` |
| 진행바의 **질문(턴) 경계 표시** | ✅ 해소 | 칸 자체가 턴 단위가 되면서(2026-08-07) 경계 표시 문제가 사라졌다 — 칸 하나 = 질문 턴 하나 |
| 레드플래그 타임라인 표시 | ❌ | 레드플래그에 시각이 없다 (§9-1 미요청) |

→ **§9-1 확장 요청을 백엔드와 먼저 잠근다.** 확장 전에도 §11 의 1~5단계(리포트 본문 + 통짜 영상 재생)는 착수 가능하고, 6단계부터가 확장 의존이다.

## 0-2. 범위

`FeatureReport` 는 **화면 3개 + 메인 위 바텀시트 1개**로 구성한다.

| # | 화면 | 이 문서가 정의하는가 |
|---|---|---|
| 1 | 1차 리포트 `ReportMain` (+ 바텀시트 `ReportHighlightDetail`) | ✅ 전량 |
| 2 | 영상 플레이어 `ReportVideoPlayer` | ✅ 전량 |
| 3 | 지인 피드백 `ReportPeerFeedback` | ✅ 시안대로 구현 (443:8006) |

**«최종 보고서» 화면은 만들지 않는다** (2026-08-06 확정, 자리표시 골격 삭제). 지인 피드백이 도착한 뒤 상태는 **메인의 «지인 피드백» 섹션이 이름 탭 + 태도 평가 목록으로 자라서** 보여준다(443:7102) — 별 화면으로 나가지 않는다. 관련 계약: 링크 생성 `DomainFeedbackShare`, 게스트 제출측 `FeatureGuestFeedback`, 평가 데이터 `InterviewReport.guestFeedback`.

**MVP 제외**: 말하기 습관 지표(말속도·군말·침묵) — 측정·저장 자체를 제외한다(PRD §5). 관련 필드를 모델에 만들지 않는다.

**노출 금지(정책을 타입으로 강제)**: 종합점수·채용 판정·천장·항목 점수·레드플래그 원문. 현 `InterviewReport` 에 해당 필드가 애초에 없다 — 추가 요청도 하지 않는다.

## 1. 화면 → 코드 매핑

| 화면 | 코드 심볼 | 현재 상태 | 진입 |
|---|---|---|---|
| 1차 리포트 (첫 화면 = 상세) | `ReportMainFeature` / `ReportMainView` | 골격(빈 State) | 코디네이터 root |
| 하이라이트 상세 시트 | `ReportHighlightDetailFeature` / `…View` | **신규** | 리포트·플레이어 양쪽에서 `.sheet` (화면 아님 — 위에 얹는 바텀시트) |
| 영상 플레이어 | `ReportVideoPlayerFeature` / `…View` | 골격(빈 State) | 메인 `[영상 다시보기]` · 시트 `[이 장면 영상으로 보기]` |
| 지인 피드백 | `ReportPeerFeedbackFeature` / `…View` | 시안대로 구현 | 메인 `[지인에게 면접 영상 보내기]` (피드백 도착 후에도 «1/4» 로 남는다) |

### 1-1. 고쳐야 할 것 — 선형 체인 → 허브

옛 골격은 `메인 →(계속) 영상 →(계속) 피드백 →(계속) 최종` 으로 네 화면을 한 줄로 엮었다. PRD 와 충돌한다: 영상은 리포트의 **종속 화면**이지 지인 피드백의 앞 단계가 아니고, 사용자가 영상을 보지 않고 바로 지인에게 보낼 수 있어야 한다.

**메인이 허브**다. Path 는 두 케이스뿐이고 진입은 메인의 개별 delegate 가 트리거한다.

```
ReportMain ─[영상 다시보기]─────────────→ ReportVideoPlayer
    │      ─[지인에게 면접 영상 보내기]──→ ReportPeerFeedback
    │      ─(하이라이트 탭)─────────────→ .sheet ReportHighlightDetail ─[이 장면 영상으로]→ ReportVideoPlayer
    └──────(지인 피드백 도착)───────────→ 메인 «지인 피드백» 섹션이 자란다 (별 화면 없음)
```

각 화면의 `continueRequested`(다음 화면으로 밀어내는 신호)를 목적별 delegate 로 쪼갠다 — 자리표시가 남긴 "계속하기" 체인이 그대로 굳는 걸 막는다.

## 2. 서버 필드 ↔ 화면 매핑

`InterviewReportClient.report(sessionId: Int) async throws -> InterviewReport` 응답 하나로 전 화면을 그린다. 필드는 전부 `DomainInterviewReportInterface`.

| 필드 | 쓰이는 곳 | 규칙 |
|---|---|---|
| `status: InterviewReportPhase` | 화면 상태 분기 | `.generating` 폴링 · `.ready` 정상 · `.insufficientAnalysis` 분석 부족 · `.failed` §13 미확정 |
| `headline: String?` | 리포트 맨 위 한 줄 요약 | **서버 소유 문구.** 3갈래 분기(정상/분석부족/레드플래그)는 서버가 반영해 내려준다 — 클라는 그대로 표시, nil 이면 §6 폴백 |
| `card.cardRedFlagNotices` (보고서 단위 필드 없음) | «상세 리포트» 제목 옆 느낌표 툴팁 | **보고 있는 질문 카드 것만** — 그 카드 배열을 **줄바꿈으로 전부** 잇는다(건수 상한 없음). `message` 그대로 노출, `type` 은 표시하지 않는다(로깅·분기용) |
| `video.url: String?` | `[영상 다시보기]` | `String` → `URL(string:)` 변환 실패 시 만료와 동일 취급 |
| `video.expired: Bool?` / `expiresAt: Date?` | 버튼 활성/비활성 + 만료 안내 | `expired == true` **또는** `url == nil` → 비활성 + §6 만료 문구. 남은 시간 표시는 `expiresAt` 이 아니라 `videoExpiry`(GET `…/video/expiry`) 값만 쓴다 — 실패면 숨김, 그쪽 `expired == true` 도 비활성(HLT-44) |
| `cards: [InterviewReportCard]?` | 항목 카드 2~4개 | 순서는 서버 배열 순서를 따른다(클라 재정렬 금지) |
| `card.axisOrder` / `depthLevel` | 카드 제목 | 표시 규칙 `"질문 {axisOrder}-{depthLevel}"`. 축 이름은 내부 용어라 노출하지 않는다 |
| `card.questionText: String?` | 카드의 질문 텍스트 | — |
| `card.questionIntent: String?` | 카드의 "질문 분석" | 내부 `probe_text` 를 서버가 사용자 표현으로 번역한 값 |
| `card.transcript: String?` | 답변 대본 | 하이라이트 렌더의 베이스 문자열 |
| `card.highlightSpans: [HighlightSpan]?` | 대본 하이라이트 + 시트 진입점 | `startIndex/endIndex` 는 `transcript` 문자열 인덱스 — §9-2 안전 슬라이싱 필수 |
| `script` · `card.scriptSegments` | 플레이어 진행바 칸·오버레이 문장·시각 폴백은 전부 후자 — `script` 는 화면 사용처 없음(2026-08-07) | 칸 하나 = 카드(질문 턴) 하나. 서버 정렬을 믿지 않고 `startSec` 으로 다시 세운다 — 칸·오버레이는 발화 전체(`timelineSegments`), 시각 폴백은 면접자만(`orderedSegments`) |
| `card.words: [TranscriptWord]?` | (없음 — 계약만 보존) | 단어 강조가 필요해질 때 쓴다. **말속도·군말·침묵 산출에 쓰지 않는다** (§0-2 MVP 제외) |
| `card.resolutionNotice: String?` | 느낌표 툴팁 — 그 카드를 보고 있을 때만 (카드 본문에는 안 세운다) | **서버 소유 문구.** 있으면 해상도 낮음 카드 → 하이라이트가 없어 시트로 진입하지 않는다 |
| `card.cardRedFlagNotices: [RedFlagNotice]?` | 느낌표 툴팁 — 그 카드를 보고 있을 때만 (카드 본문에는 안 세운다) | 해상도와 **독립** — 같은 카드면 해상도 안내와 나란히 툴팁에 선다. 원소는 문구 문자열 또는 `{type, message}` 둘 다 — `RedFlagNotice` 가 양쪽 디코딩 |
| `guestFeedback: GuestFeedbackSection?` | 지인 피드백 섹션 | 4.6 소관 — 이 문서 범위에서는 렌더하지 않는다(§13) |

`span.tone` / `span.analysis` 는 §9-1 확장과 함께 확정한다.

## 3. 코디네이터 (`ReportFeature`) 변경

현 골격에서 바뀌는 것만.

Path 케이스 3개는 유지, **트리거만 §1-1 허브형으로 교체**한다.

```swift
@Reducer public enum Path {
    case videoPlayer(ReportVideoPlayerFeature)
    case peerFeedback(ReportPeerFeedbackFeature)
}

@ObservableState public struct State: Equatable {
    public var main: ReportMainFeature.State       // init 에 sessionId 필수가 됨
    public var path = StackState<Path.State>()
}

@CasePathable public enum Delegate: Equatable, Sendable {
    case closeRequested    // 유지
    // 지인 피드백은 모듈 안에서 push 하므로 부모로 올리지 않는다.
}
```

라우팅

| 신호 | 처리 |
|---|---|
| `main.delegate.videoRequested(startAt:)` | `path.append(.videoPlayer(...))` — `startAt` 은 확장 전 항상 nil |
| `main.delegate.peerFeedbackRequested` | `path.append(.peerFeedback(...))` |
| `highlightDetail.delegate.videoJumpRequested(at:)` | 시트 dismiss 후 `.videoPlayer(startAt:)` push |
| `path…backRequested` | `popLast()` |
| `main.delegate.closeRequested` | 부모로 그대로 전파 |

**평가 독립성**: 지인에게 넘기는 payload 는 영상과 질문 경계만. AI 피드백(하이라이트·진단·다음 대비)은 넘기지 않는다 — `ReportPeerFeedbackFeature` 는 `sessionId` 만 받고 링크 생성은 `FeedbackShareClient`(Domain)로 수행한다.

기존 코디네이터 테스트 `linearFlowPushesFeedbackThenFinal`·`finalContinueDelegatesFinished` 는 선형 체인을 검증하므로 폐기하고 허브 라우팅 테스트로 대체한다.

## 4. 화면 1 — 1차 리포트 (`ReportMainFeature`)

### 4-1. 구성요소 (위 → 아래)

1. 내비게이션 바 (닫기 X)
2. **한 줄 요약** — `headline`
3. **안내 툴팁** — «상세 리포트» 제목 옆 느낌표. **지금 보고 있는 질문 카드**의 `resolutionNotice`·`cardRedFlagNotices` 가 있을 때만, 그 카드 것만 순서대로 전부 (탭을 옮기면 내용도 바뀐다)
4. `[영상 다시보기]` — 영상 유효할 때만 활성
5. **항목 카드 2~4개** — 각 카드: 제목(`질문 n-m`) · 질문 텍스트 · 질문 분석 · 대본+하이라이트 (해상도 안내·카드 레드플래그는 3의 툴팁 몫)
6. `[지인에게 면접 영상 보내기]` — 4.5 진입

### 4-2. State

```swift
@ObservableState public struct State: Equatable {
    public let sessionId: Int
    public var loadState: LoadState = .loading
    public var report: InterviewReport?
    public var pollTickCount: Int = 0
    @Presents public var highlightDetail: ReportHighlightDetailFeature.State?

    public enum LoadState: Equatable, Sendable {
        case loading            // status == .generating 또는 최초 조회 전
        case loaded
        case pollTimedOut       // 폴링 상한 초과 — 수동 재시도 유도
        case failed(InterviewReportError)
    }
}
```

View 표시 분기는 State 를 늘리지 않고 computed 로 파생한다.

```swift
public extension ReportMainFeature.State {
    var visibleRedFlagNotices: [RedFlagNotice] { Array(cards.flatMap { $0.cardRedFlagNotices ?? [] }.prefix(2)) }
    var cards: [InterviewReportCard] { report?.cards ?? [] }
    var playableVideoURL: URL? {                     // 만료·nil·형식오류를 한 곳에서 흡수
        guard !isVideoExpiredByServer else { return nil }   // `video/expiry` 의 만료가 우선 (HLT-44)
        guard report?.video?.expired != true, let raw = report?.video?.url else { return nil }
        return URL(string: raw)
    }
}
```

### 4-3. Action

```swift
public enum Action: ViewAction {
    case view(View)
    case inner(Inner)
    case delegate(Delegate)
    case highlightDetail(PresentationAction<ReportHighlightDetailFeature.Action>)

    public enum View: Equatable, Sendable {
        case onAppear
        case userTappedClose
        case userTappedWatchVideo
        case userTappedHighlight(cardIndex: Int, spanIndex: Int)
        case userTappedPeerFeedback
        case userTappedRetry
    }

    public enum Inner: Equatable, Sendable {
        case reportLoaded(InterviewReport)
        case reportFailed(InterviewReportError)
        case pollTicked
    }

    @CasePathable public enum Delegate: Equatable, Sendable {
        case videoRequested(startAt: TimeInterval?)   // nil = 처음부터
        case peerFeedbackRequested                    // 코디네이터가 push (부모로 안 올라감)
        case closeRequested
    }
}
```

`@Dependency(\.interviewReportClient)` · `@Dependency(\.continuousClock)`. `enum CancelID { case poll }`.

### 4-4. 상태 분기

| 조건 | 화면 |
|---|---|
| `loadState == .loading` | 로딩 — 폴링 진행, 진행 문구만(스켈레톤 없음, §10) |
| `status == .ready` | 정상 — 한 줄 요약 + 카드 전체 |
| `status == .insufficientAnalysis` | **분석 부족** — 한 줄 요약 자리에 분석 부족 문구, 채점된 카드만 노출, `[영상 다시보기]`. 재도전 CTA 는 없다(2026-08-06 제거 — 재도전은 홈 «면접 시작») |
| 보고 있는 카드에 레드플래그 있음 | 위 분기와 **직교** — «상세 리포트» 제목 옆 느낌표 툴팁으로만 알린다(요약 자체는 서버가 중립 문장으로 내려줌) |
| `loadState == .pollTimedOut` | 채점 지연 안내 + 수동 재시도 |
| `.failed(.reportNotFound)` | **폴링 계속** (보고서 미생성 상태 = 에러 코드로 옴, [[api#Interview Report]]) |
| `.failed(.sessionNotFound)` | 복구 불가(세션 없음·타인 소유) — 재시도 버튼 없이 닫기만 |
| `.failed(.networkFailure)` 등 | 재시도 가능한 에러 표시 |
| `status == .failed` | §13 미확정 — PRD 에 UX 없음 |

### 4-5. 폴링

`onAppear` → `report(sessionId)` 조회 → `.generating` 이거나 `.reportNotFound` 면 clock 으로 재조회. `.ready`/`.insufficientAnalysis` 에서 정지.

- 간격 **4초** ([[api#Interview Report]] 의 3~5초 폴링 규약)
- 상한 **75회(≈5분)** → `.pollTimedOut`. PRD 의 "24시간 내 완료"는 서버 SLA 고, 화면이 무한 폴링하면 안 된다. **수치는 §13 미확정(PM 확인)** — 상한 없이 두지 않는다는 것만 확정.
- 화면 이탈 시 effect 자동 취소(`.cancellable(id: CancelID.poll)` + 코디네이터 pop). 취소는 실패가 아니므로 에러 상태로 만들지 않는다.

### 4-6. 하이라이트 탭

`userTappedHighlight(cardIndex:spanIndex:)` → 해당 `card`/`span` 으로 `HighlightContext`(§5) 를 조립해 `highlightDetail` present. 인덱스가 범위를 벗어나면 무시한다(서버 응답 변동 방어). 해상도 낮음 카드는 `highlightSpans` 가 없어 애초에 탭 대상이 없다.

## 5. 화면 2 — 하이라이트 상세 시트 (`ReportHighlightDetailFeature`) 신규

두 진입점(리포트 카드 / 플레이어 대본 오버레이)이 **같은 리듀서를 재사용**한다. 내용 동일, 차이는 `[영상 보러가기]` 버튼 노출 여부 하나.

**플레이어 안에서도 이 버튼을 숨기지 않는다**(초판 결정 폐기). 오버레이 대본은 지나온 문장을 스크롤로 되짚어 다른 장면의 하이라이트도 누를 수 있어서, «이미 그 장면에 멈춰 있다» 는 전제가 성립하지 않는다 — Figma(3165:14925)도 노출한다. 플레이어에서 누르면 시트를 닫고 그 장면으로 이동해 재생을 재개한다.

```swift
@ObservableState public struct State: Equatable {
    public let context: HighlightContext
    public let showsVideoJump: Bool   // 재생할 영상이 있으면 true — 플레이어 안에서도 노출한다
}

public enum Action: ViewAction {
    case view(View)
    case delegate(Delegate)

    public enum View: Equatable, Sendable {
        case onAppear
        case userTappedVideoJump
        case userTappedDismiss
    }
    @CasePathable public enum Delegate: Equatable, Sendable {
        case videoJumpRequested(at: TimeInterval?)   // nil = 근거 시각 모름 → 처음부터
    }
}
```

`HighlightContext` 는 **이 Feature 안에 두는** 화면 조립 타입(§9-2 배치 규칙). `followUpQuestions`/`intentReview` 는 구간 `reason` 이 문지기다(PROBE_WORTHY/OFF_INTENT). `keyword` 만 서버 확장 대기 — **비면 그 줄·블록을 렌더하지 않는다.**

| 블록 | 재료 | 없을 때 |
|---|---|---|
| 하이라이트 문장 | `transcript[start..<end]` | (항상 있음) |
| depth 1 태그 | `span.keyword` 🔴확장 | 태그 숨김, 설명만 |
| depth 1 설명 | `span.analysis` | 블록 숨김 |
| `[영상 보러가기]` | 영상 유효(`showsVideoJump`) — 시각은 `span.startSec` 또는 `scriptSegments` 에서 파생 | 영상 없으면 버튼 숨김. **시각을 몰라도 버튼은 남긴다**(처음부터 재생) |
| depth 2 다음 대비 | `reason` 별 — PROBE_WORTHY `followUpQuestions` / OFF_INTENT 의도 대조 | 그 외 reason 은 depth 2 생략 + PRD 마무리 문구(§6) |

## 6. 사용자 문구 — 소유 주체 (카피 단일 소스)

**대부분의 문구는 서버가 내려준다. 클라가 하드코딩하면 정책 변경 때 어긋난다.**

| 문구 | 소유 | 비고 |
|---|---|---|
| 한 줄 요약 (3갈래 분기 결과) | **서버** `headline` | 클라는 분기 판단을 하지 않는다 |
| 레드플래그 안내 (모순 계열 / 무결점 서사) | **서버** `RedFlagNotice.message` | 클라는 줄바꿈으로 잇기만 (절단 없음) |
| 해상도 낮음 안내 (짧음·얕음 / 딴 답) | **서버** `card.resolutionNotice` | 원인 분기도 서버가 문구로 반영 |
| 진단 설명 · 다음 대비 질문 | **서버** `span.analysis` / 확장 필드 | — |
| 영상 만료 | **클라** | "24시간이 지나서 영상이 사라졌어요. 다음 면접 연습 때는 지인 피드백을 받아보세요. 더 오랫동안 영상을 볼 수 있어요." |
| `headline == nil` 폴백 (분석 부족) | **클라** | "이번 면접의 답변이 충분하지 않아요. 다음 면접 연습 때는 조금 더 충분한 답변을 말씀해주세요." |
| depth 2 생략 — 잘함 소진 | **클라** | "여기는 면접관이 더 캐물 게 없을 만큼 충분히 답하셨어요." |
| depth 2 생략 — 재료 부족 | **클라** | "다음엔 조금 더 자세히 답해보세요." |
| 로딩 / 폴링 지연 | **클라** | 카피 미확정(§13) |

## 7. 금지 규칙 (리뷰 체크리스트)

- 점수·판정·천장·항목 점수·레드플래그 원문을 **어떤 화면에도** 노출하지 않는다.
- 내부 용어(6대 항목 이름, 해상도, 레드플래그 유형명, `axis` 코드)를 사용자에게 보여주지 않는다.
- 인상·추측 표현(자신감·긴장·표정·톤·성격·감정) 문구를 클라에서 만들지 않는다.
- "지어내셨다" 류 단정 표현 금지.
- 완성된 모범답안을 제공하지 않는다 — depth 2 는 질문·방향으로 끝난다.
- 말하기 습관(추임새·반복) 관련 태그·지표를 만들지 않는다(MVP 제외).
- 카드 순서·문구를 클라에서 재가공하지 않는다(절단·nil 폴백만 허용).

## 8. 화면 3 — 영상 플레이어 (`ReportVideoPlayerFeature`)

리포트의 **종속 화면**. `[영상 다시보기]`(처음부터) 또는 `[이 장면 영상으로 보기]`(해당 시각)로 진입.

```swift
@ObservableState public struct State: Equatable {
    public let videoURL: URL
    public let startAt: TimeInterval?            // 진입 시각 (nil = 처음부터)
    public let cards: [InterviewReportCard]      // 대본 오버레이·진행바 재료
    let transcript: VideoTranscript              // 카드 → 시간축 하나로 펼친 파생값
    public var isPlaying = true
    public var currentTime: TimeInterval = 0
    public var duration: TimeInterval = 0
    public var areControlsVisible = true         // 무입력 3초 뒤 숨김
    public var isTranscriptVisible = false
    public var playbackFailureMessage: String?
    public var seekTarget: TimeInterval = 0      // 뷰로 내리는 이동 명령
    public var seekToken = 0                     // 단조 증가 — 같은 시각 재이동도 놓치지 않는다
    public var isSeeking = false                 // 목표에 닿기 전 보고되는 옛 위치를 버린다
    var transcriptPosition: VideoTranscript.Position?  // 재생이 닿은 대본 위치(턴 + 문장)
    @Presents public var highlightDetail: ReportHighlightDetailFeature.State?
}
```

**AVPlayer 는 뷰가, 재생 상태는 리듀서가 갖는다.** 인스턴스는 `GuestVideoPlayerView`([FeatureGuestFeedback](../../Projects/Feature/FeatureGuestFeedback/Sources/View/GuestVideoPlayerView.swift)) 선례대로 View-local `@State` 지만, 재생 여부·현재 시각은 State 에 올린다 — 컨트롤 자동 숨김·진행바 칸 채움·«현재 문장» 이 전부 시각에 딸린 화면 상태다(초판의 "재생 위치를 리듀서에 올리지 않는다"는 커스텀 컨트롤이 없다는 전제였고, Figma 컨트롤이 커스텀이라 성립하지 않는다).

**2단계로 나눴고, 둘 다 구현됐다** (2단계는 대본 발화 타임스탬프 도착으로 해금).

| 단계 | 내용 | 상태 |
|---|---|---|
| 1단계 | 진입 즉시 재생 · 전체화면 · 재생 실패 표시 · 좌상단 X | ✅ |
| 2단계 | 대본 오버레이 토글 · 재생-대본 동기 · 하이라이트 탭 → 정지 + 시트 · 구간 seek · `startAt` 진입 | ✅ |

컨트롤 규약: 무입력 3초 뒤 딤·재생 버튼·하단 바가 사라져 영상만 남는다. **일시정지 중에는 숨기지 않고**(재생 버튼이 사라진다), 대본을 켜 둔 동안은 하단 바를 유지한다(대본의 일부). 좌우 화살표는 진행바 한 칸(질문 턴)씩 움직이고(옛 ±10초 폐기), 끝까지 본 뒤 재생을 누르면 처음으로 되감는다.

진행바는 **칸 하나 = 카드(질문 턴) 하나**(폭 ∝ 길이, 탭 = 그 턴 시작으로 이동)다(2026-08-07 — 옛 «발화 하나당 칸 하나» 는 너무 잘게 쪼개져 폐기). 칸의 시간 범위는 턴 발화 전체(면접관 질문 포함 — 탭하면 질문부터). 서버 발화가 없으면 영상 전체 한 칸으로 대체하고, 이때 탭은 무반응이다(이동할 지점을 모른다). 대본 오버레이는 **현재 턴 하나만, 문장을 재생 시각까지 쌓아** 보여준다(면접관 질문도 시각 순으로 함께, 답변과 같은 모양). 발화가 없으면 대본 토글을 감추고 오버레이도 얹지 않는다 — 규칙·페이드·스냅 상세는 [[report#영상 플레이어]].

시스템 컨트롤을 쓰지 않으므로 SwiftUI `VideoPlayer` 대신 `AVPlayerLayer`(`VideoSurface`)를 직접 얹는다.

**만료 판정은 플레이어 책임이 아니다** — `videoURL` 이 필수값이라 만료·nil·형식 오류는 리포트 화면의 `playableVideoURL`(§4-2)에서 이미 걸러지고, 만료 시 진입 자체가 없다. 플레이어는 재생 실패(네트워크·코덱)만 표시한다.

**아직 없는 것 1개**: 레드플래그 타임라인 표시 — 레드플래그에 시각이 없다(§9-1 미요청). (진행바 턴 경계 구분은 칸 = 턴이 되면서 해소, 2026-08-07.)

## 9. Domain 확장

### 9-1. 서버 계약 확장 요청 (백엔드 전달용)

| # | 요청 | 우선 | 없으면 못 만드는 것 |
|---|---|---|---|
| 1 | `HighlightSpan.evidenceStartAt` / `evidenceEndAt` (초) | ✅ **해결** | `startSec` 으로 내려온다(끝 시각은 안 옴). 없으면 `scriptSegments` 의 면접자 발화에서 문자 오프셋 겹침으로 대체(`evidenceTime(for:)`) |
| 2 | `HighlightSpan.tone` 허용값 확정 (예: `GOOD` / `IMPROVE`) | ✅ **해결** | 스웨거 enum `GOOD|IMPROVE`. 미지 값은 본문 색 그대로(강조 없음) |
| 3 | `HighlightSpan.keyword: String` (행동형 키워드 1개) | 🔴 **유일한 잔여** | 시트 태그 줄. 볼드 한 줄은 `span.title` 로 해소됐다 |
| 4 | `HighlightSpan.followUpQuestions: [String]` (최대 2) | ✅ **해결** | `reason=PROBE_WORTHY` 일 때만 채워진다. OFF_INTENT 는 대신 «질문 의도 ↔ 내 답변» 대조 재료 3필드가 온다 |
| 5 | ~~`card.answerStartAt` / `answerEndAt`~~ | ✅ **해결** | `card.scriptSegments` 의 면접자 발화 첫/마지막에서 파생한다 |
| 5-1 | **발화 위치·기준점 확인** | ✅ **해결** | 카드 `scriptSegments` + 최상위 `script` 두 자리. `startSec` 은 합성 영상(=녹화) 타임라인 기준으로 명시됐다 |
| 6 | `card.resolutionCause` (예: `SHALLOW` / `OFF_TOPIC`) | ✅ **대체 해결** | 해상도 낮음 사유가 하이라이트 `reason` 으로 온다(짧음·얕음 = 빈 배열 / 딴 답 = OFF_INTENT 1개) |
| 7 | 카드 제목 표시 규칙 확정 (`axisOrder`-`depthLevel` 유지 여부) | 🟡 | 현 규칙으로 진행 가능 |
| 8 | `GuestAttitudeRating.axis` 표시명 (또는 코드 목록 고정) | 🟡 | 4.6 소관 |

요청하지 않는 것: 점수·판정·천장·항목 점수(정책상 클라에 내려오면 안 된다), 말하기 습관 지표(MVP 제외).

### 9-2. 클라 파생 타입 — 배치 규칙

**서버 계약을 정규화하는 것은 Domain, 화면을 위해 조립하는 것은 Feature.** 둘 다 외부 IO 는 없지만 소속이 다르다 — Domain 이 화면 구성을 알면 안 된다.

**Domain (`DomainInterviewReportInterface` 추가분)** — 서버 값의 타입을 좁히거나 서버 인덱스를 안전하게 다루는 것.

```swift
public enum HighlightTone: Equatable, Sendable {           // 서버 tone: String? 정규화
    case good, improve, unknown
    public init(rawTone: String?)                          // 미지 값은 .unknown → 강조 없이 평문 렌더
}

public extension InterviewReportCard {
    var displayTitle: String { "질문 \(axisOrder)-\(depthLevel)" }
    var isLowResolution: Bool { resolutionNotice?.isEmpty == false }
    /// startIndex/endIndex 를 String.Index 로 안전 변환 — 범위 밖·역순은 nil (서버 인덱스 불일치 방어)
    func sentence(for span: HighlightSpan) -> String?
}
```

**Feature (`FeatureReport`)** — 시트 화면의 입력 조립물. `showsVideoJump`(§5)와 한 몸이라 Domain 에 두지 않는다.

```swift
struct HighlightContext: Equatable, Sendable {             // 상세 시트 입력 (§5)
    let transcript: String                                 // 문장이 아니라 대본 전체 — 앞뒤 문맥을 흐리게 함께 보여준다
    let span: HighlightSpan                                // 문장·톤·진단은 여기서 파생
    let keyword: String?                                   // 🔴확장 전 nil (유일한 잔여)
    let followUpQuestions: [String]                        // reason=PROBE_WORTHY 만 채워짐
    let intentReview: IntentReview?                        // reason=OFF_INTENT 만 — 질문 의도 ↔ 내 답변 대조
    let evidenceAt: TimeInterval?                          // span.startSec 또는 scriptSegments 파생
}

struct VideoTranscript: Equatable {                        // 플레이어 타임라인 (§8)
    let lines: [Line]                                      // 카드 1장 = 줄 1개, 문장(Sentence) 단위로 쪼갬 — 질문·답변 시각 순 (오버레이)
    let chunks: [Chunk]                                    // 진행바 칸 — 카드(질문 턴) 1:1, 없으면 영상 전체 한 칸
}
```

Domain 추가분에 `TranscriptSegment`·`TranscriptWord`(서버 타임스탬프)와 `card.evidenceTime(for:)`·`card.orderedSegments`·`card.timelineSegments` 가 함께 들어간다 — 서버 값 정규화라 Domain 이 맞다.

`InterviewReportCard`·`HighlightSpan` 에 `id` 가 없다 → `ForEach` 는 `Array.enumerated()` 의 offset 을 `id:` 로 쓴다. 배열 순서가 계약(클라 재정렬 금지, §2)이므로 인덱스가 정당한 식별자다. `(axisOrder, depthLevel)` 조합키는 서버가 중복을 내리면 깨진다. `Identifiable` 을 서버 DTO 에 억지로 붙이지 않는다.

**fixture 는 `DomainInterviewReportTesting`** — 픽스처 타입이 전부 Domain 모델이라 Feature Testing 에 두면 Domain 테스트·Example 이 재사용하지 못한다. 선례 `DomainGuestFeedbackTesting/GuestFeedbackFixtures.swift`, 같은 타깃에 `InterviewReportClientMock` 이 이미 있다. `.ready` + 영상 있음 / `.generating` / `.insufficientAnalysis` / 레드플래그 2건 / 해상도 낮음 카드 5종을 추가한다 — 현 `previewValue` 는 `video.url == nil` 이라 플레이어 경로를 프리뷰로 못 본다.

## 10. DesignSystem 갭

`.claude/design.md` 기준. **없는 것을 만들기 전에 Figma 연결로 확정한다.**

| 필요 | 현황 | 처리 |
|---|---|---|
| 대본 sub-range 하이라이트 | ✅ Feature-local `TranscriptText` — `AttributedString.link` + `openURL` 로 부분 범위 탭 | 메인 카드·시트·플레이어 오버레이 3곳 공용. `baseColor` 만 갈아끼운다(미지 톤은 본문 색을 물려받아 강조 없음) |
| 카드 컨테이너 | ❌ 공용 없음 | Feature-local. 선례 `AxisCommentCard`(FeatureGuestFeedback) |
| 바텀시트 | ❌ 레포 전체에 `.sheet` 사용 0 | SwiftUI `.sheet` + `presentationDetents` 직접. **레포 최초 도입** — 패턴을 이 화면에서 정하고 `[[report]]` 에 기록 |
| 잘함/개선 색 | ✅ Figma 확정(다크) | 잘함 = `Positive.p500`(#00CFEF) — 플레이어 오버레이만 `p800`(#008A9F), 개선 = `Error.e400`(#FF8383). 밴드 배경은 `Gray.g800`(시트·카드) / `g900`(오버레이). 초판이 적었던 라이트 조합(p200/e200)은 다크 개편으로 폐기 |
| radius 토큰 | ❌ 없음(전부 리터럴) | `DSRadius` 신설 제안 🟡 — 도입하면 design.md·design/spacing.md 동시 갱신 |
| 뒤로 아이콘 | ✅ 불필요 | Figma 플레이어는 좌상단 X 하나뿐이고 그게 «뒤로» 다 — 회전 꼼수 TODO 제거 |
| 플레이어 컨트롤 아이콘 | ✅ DS 에 있다 | `Image.SkipL.dark34`·`SkipR.dark34`·`Script.dark20`·`Pause.green34`·`Play.green34`·`Cancel.dark24/20`. 잠시 손으로 그렸던 `play` 는 DS 정식 에셋으로 폐기했다 |
| 질문 배지 «Q» | ✅ `Image.Q.default` | 글자로 그리지 않는다 — 에셋에 사각 배경까지 구워져 있다 |
| 아이콘만 있는 정사각 버튼(44) | ❌ 버튼 카탈로그에 없는 티어 | 플레이어 컨트롤 전용이라 Feature-local. 두 번째 사용처가 생기면 승격 검토 |
| 로딩·스켈레톤 | ❌ 스켈레톤 없음 | `ProgressView` + 문구. 버튼 로딩은 `.hilitButtonLoading(_:)`, `SaveIndicator` 는 용도 다름 |
| CTA 버튼 | ✅ `ButtonLarge` | 하단 도킹 `.bottom` / 카드 안 `.modal`. 보조 액션은 `.buttonStyle(.mini(...))`, 다크 화면은 루트에 `.hilitSurface(.dark)` 한 번 |

토큰만 쓴다: 타이포 `.dsTypography(.head3/.sub7/.body3…)`, 색 `Color.Gray.*`·`HilitBlack.*`, 여백 `.padding(.ds(.p20))`. **Figma raw 수치 하드코딩 금지.**

## 11. 구현 순서

0. **§9-1 확장 협의** — 1~4번 잠그기 전에 6단계를 시작하지 않는다.
1. **Domain 확장** — `HighlightTone`·카드 extension·안전 슬라이싱 + `DomainInterviewReportTesting` fixture 5종(§9-2).
   함께: `FeatureReport/Project.swift` 의 **Tests·Testing·Example 3타깃에 `.domain(interface: .interviewReport)` 명시**(Tests 는 `DomainInterviewReportTesting` 도). 전이 의존에 기대면 따뜻한 DerivedData 에서만 통하는 거짓 성공이 난다 — 선례 `FeatureGuestFeedback/Project.swift`. Example 은 `ReportFeature.State(sessionId:)` 시그니처 변경으로 어차피 깨지므로 같은 단계에서 고친다.
2. **리포트 로드·폴링** — `ReportMainFeature` State/Action + `TestClock` 결정론 테스트. UI 는 문구만.
3. **카드 UI** — 카드 컨테이너·`TranscriptText`·해상도/레드플래그 표기. CTA 는 `ButtonLarge`.
4. **상세 시트** — `ReportHighlightDetailFeature` + `.sheet` 패턴 확립. 확장 전이므로 depth 1 설명까지.
5. **영상 플레이어 1단계** — 통짜 재생 + 재생 실패 표시. 코디네이터 라우팅 허브화(§1-1)와 함께.
6. **[확장 후] 2단계** — ✅ timestamp(`scriptSegments`/`script`) → 구간 seek·대본 오버레이·`[영상 보러가기]`·depth 2(후속 질문/의도 대조). 키워드 태그만 서버 필드 대기라 «비면 렌더 안 함» 상태로 남아 있다.
7. **AppFeature 배선** — ✅ 2026-08-05. 진입은 **홈 위젯② [레포트 보기]** 다: `home(.delegate(.reportDetailRequested(sessionId:)))` → `state.report = ReportFeature.State(sessionId:)` fullScreenCover, `closeRequested` → dismiss. (`retryRequested` → 온보딩 위저드 배선도 함께 깔았으나 2026-08-06 «다시 연습하기» CTA 제거와 함께 회수했다.) `// depends-on: [[report]]` 라벨 붙였다. 리포트 커버 중에는 전역 LoadingModal 을 끈다(폴링마다 딤이 깜빡인다).
   남은 경로: **면접 정상 종료 → r1 직행** 은 여전히 미배선이다 — 면접은 리포트 대기 화면에서 홈으로 돌아가고, 홈 재진입이 목록을 재조회한다.
8. **문서 동기화** — `[[report]]` 노드를 실제 구조로 갱신(현재 "4화면 골격·임시 선형" 서술은 이 정의서 적용 시 거짓이 된다), `@lat` 라벨 재부착, `lat check` 통과.

## 12. 테스트 항목 (TestStore)

- `.generating` → 4초 후 재조회 → `.ready` 전이 (`TestClock`)
- `.reportNotFound` 도 폴링 계속 (에러로 끝내지 않는다)
- 폴링 상한 초과 → `.pollTimedOut`, effect 정지
- 화면 이탈 시 폴링 취소, `CancellationError` 가 에러 상태를 만들지 않음
- `.insufficientAnalysis` → 분석 부족 분기 + 채점된 카드만
- 툴팁은 선택 카드 것만 — 해상도 안내 카드 → 1줄, 레드플래그 3건 카드 → 3줄, 안내 없는 카드 → 느낌표·툴팁 없음
- `video.expired == true` / `url == nil` / 형식 오류 → `playableVideoURL == nil`
- `video/expiry` 첫 조회 실패 → 카운트다운 숨김(재생은 유지), 재조회 실패는 받은 값 유지 · `expired == true` → `playableVideoURL == nil` · 재생할 영상 없으면 조회 안 함
- 하이라이트 탭 → 시트 present, `tone` 매핑(`"GOOD"`→`.good`, 미지값→`.unknown`)
- 범위 밖 `startIndex/endIndex` → 시트 미present (크래시 없음)
- 해상도 낮음 카드 → 탭 대상 없음
- 플레이어 안에서 연 시트 → `showsVideoJump == true` (영상이 있으므로) + 시트가 열리면 재생 정지
- 플레이어: 무입력 3초 → 컨트롤 숨김 / 일시정지 중에는 유지 / 대본 켜면 하단 바 유지
- 플레이어: 좌우 화살표 = 진행바 한 칸(질문 턴), 끝에서 재생 → 0 으로 되감기
- 플레이어: 진행바 칸 탭 → 그 턴 시작으로 이동, 발화 없으면 한 칸 폴백
- 플레이어: 이동 직후 옛 위치 보고 무시(`isSeeking`), 시트 «영상 보러가기» → 닫기 + 이동 + 재생 재개
- 코디네이터: `videoRequested`/`peerFeedbackRequested` → 각 화면 push (체인 아님), `backRequested` → pop, `closeRequested` → 부모 전파

`InterviewReportClient.testValue` 는 `unimplemented` 유지 — 테스트마다 `withDependencies` 로 명시 주입한다.

## 13. 미확정

- **폴링 간격·상한** 수치 (PM) — 상한 존재는 확정, 값은 미정
- **`status == .failed` UX** — PRD 에 분기 없음. 채점 실패 시 화면·재시도 정책 필요
- **STT 부분 실패(30% 미만) 경고** — 별도 「STT 실패 처리 기획서」 대기. PRD §3 상태표의 '경고' 상태
- **radius 토큰** — 여전히 없음(다크 화면은 Figma 가 모서리 0 이라 필요가 없었다). 라이트 화면에서 필요해지면 `DSRadius` 신설
- **지인 평가 판정 문구** — 시안(443:7102)은 표정 1단계를 «밝아요.» 로 쓰는데 코드는 잠정 문구 «좋아요.» 다. 4단계 전체가 시안에 없어 한 칸만 못 바꾼다 — 축별 4단계 문구 확정 필요(`GuestAttitudeCopy`)
- **지인 피드백 도착 후 메인 갱신 트리거** — 링크 복사 후 재조회·푸시 여부 미정(현재는 재진입 시 `onAppear` 재조회에 의존)
- ~~**24시간 보관 안내 문구 위치**~~ — 해결: 플레이어가 아니라 메인의 영상 카드가 남은 시청 시간을 카운트다운으로 보여준다
- **회차 비교("지난 회차 대비")·반복 키워드 습관 안내** — MVP 이후
- **말하기 습관 지표** — MVP 제외(측정·저장 포함). 도입 시 지표 정의·스키마 동시 설계
