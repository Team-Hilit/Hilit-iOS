//
//  ReportMainFeature.swift
//  FeatureReport
//
//  Created by EunSeo on 26/07/25.
//

import ComposableArchitecture
import DomainCommonInterface
import DomainInterviewReportInterface
import Foundation

// @lat: [[report#1차 리포트]]
/// 1차 리포트 — 리포트 플로우의 루트이자 상세 화면. 요약 화면을 따로 두지 않는다(구버전 이탈 이력).
/// `InterviewReportClient.report` 한 번으로 전 화면 데이터를 받고, 채점이 끝나지 않았으면 폴링한다.
/// 사용자 문구는 대부분 서버 소유 — 클라는 절단·nil 폴백만 한다 (정의서 §6).
@Reducer
public struct ReportMainFeature {
    /// 채점 폴링 주기 — [[api#Interview Report]] 의 3~5초 규약 중앙값.
    // TODO: 폴링 정책 PM 확인 대기 — 간격·상한 값은 미확정이라 임의로 바꾸지 않는다(정의서 §13).
    static let pollInterval: Duration = .seconds(4)
    /// 폴링 상한. 서버 SLA 는 24시간이지만 화면이 무한 폴링하면 안 된다 — 넘으면 수동 재시도로 넘긴다.
    static let pollLimit = 75
    /// 지인 피드백 요청 정원. 서버가 정원 필드를 안 내려서 클라 상수로 둔다 —
    /// 응답에 필드가 생기면 이 상수 대신 그 값을 쓴다.
    static let maxGuestCount = 4

    @ObservableState
    public struct State: Equatable {
        public let sessionId: Int
        public var loadState: LoadState = .loading
        public var report: InterviewReport?
        /// 폴링 횟수 — 상한 판정용.
        public var pollTickCount = 0
        /// 상세 리포트에서 보고 있는 카드(질문 탭) 위치.
        public var selectedCardIndex = 0
        /// 레드플래그 툴팁 노출 여부 — 시안(443:7204)이 느낌표와 툴팁을 **함께** 띄우므로 기본 펼침이다.
        /// 한 번 접으면 이 State 가 사는 동안 계속 접힌 채다 — 재진입(뒤로가기 복귀)에도 다시 안 띄운다.
        /// 다시 띄우려면 State 가 새로 만들어져야 한다(화면을 닫고 새로 진입).
        /// 레드플래그가 없으면 이 값과 무관하게 뷰가 둘 다 그리지 않는다.
        public var isRedFlagTooltipVisible = true
        /// 지인 피드백에서 보고 있는 지인(탭) 위치.
        public var selectedGuestIndex = 0
        /// 코멘트를 펼쳐 둔 태도 항목 코드 — 지인을 바꾸면 비운다.
        public var expandedCommentAxes: Set<String> = []
        @Presents public var highlightDetail: ReportHighlightDetailFeature.State?
        /// 미승격 서버 에러 Alert — 도메인이 케이스로 승격하지 않은 코드의 원문 표시(임시 노출 규칙).
        @Presents public var alert: AlertState<Action.Alert>?
        /// 영상으로 넘어가며 접어 둔 상세 시트 — 플레이어 하단 «이전 화면으로 가기» 가 이걸 되살린다.
        /// 시트와 push 를 동시에 띄울 수 없어 잠깐 옆에 둔다. 플레이어 상단 X 로 나오면 코디네이터가 비운다
        /// (X 는 리포트 메인까지, 하단 버튼은 시트까지 — 사용자 결정 2026-08-06).
        public var stashedHighlightDetail: ReportHighlightDetailFeature.State?
        /// 영상 만료 시각 — `GET …/video/expiry` 의 잔여초를 받은 시각에 더해 환산한 값(HLT-44).
        /// 보존 기한은 서버가 사건마다 다시 계산하므로 클라는 세지 않고 이 값만 보여준다.
        /// nil = 아직 못 받았거나 조회 실패 → 카운트다운을 숨긴다(보고서 `video.expiresAt` 으로 대체하지 않는다).
        public var videoExpiresAt: Date?
        /// `video/expiry` 가 만료(`expired == true`)를 알렸다 — 보고서가 아직 살아 있다고 해도 재생 대상에서 뺀다.
        public var isVideoExpiredByServer = false

        public enum LoadState: Equatable, Sendable {
            /// 최초 조회 전 또는 채점 진행 중
            case loading
            case loaded
            /// 서버가 채점을 포기한 상태(FAILED) — 카드도 요약도 없어 정상 화면을 그릴 수 없고,
            /// 재조회해도 같은 답이라 재시도 버튼을 주지 않는다.
            case generationFailed
            /// 폴링 상한 초과 — 수동 재시도 유도
            case pollTimedOut
            case failed(InterviewReportError)
        }

        public init(sessionId: Int) {
            self.sessionId = sessionId
        }
    }

    public enum Action: ViewAction {
        case view(View)
        case inner(Inner)
        case delegate(Delegate)
        case highlightDetail(PresentationAction<ReportHighlightDetailFeature.Action>)
        case alert(PresentationAction<Alert>)

        /// 확인 버튼만 있는 Alert — 누를 액션이 없다.
        public enum Alert: Equatable {}

        public enum View: Equatable, Sendable {
            case onAppear
            /// 당겨서 새로고침 — 늦게 도착한 지인 피드백을 받아오는 **단발** 재조회다(폴링 재개가 아니다).
            // TODO(prd-외): PRD 미정 자리(«복사 후 메인 갱신 흐름 스펙 대기»)를 관례로 메운 재량 구현 — 스펙 확정 시 재검토.
            case userPulledToRefresh
            /// 폴링 상한 초과·재시도 가능 에러의 수동 재시도 (정의서 §4-4).
            case userTappedReload
            case userTappedClose
            case userTappedWatchVideo
            case userTappedQuestionTab(Int)
            /// 느낌표 탭 — 툴팁 펼침/접힘.
            case userTappedRedFlagInfo
            /// 툴팁 자체를 탭 — 접기 전용(느낌표와 달리 다시 펼치지 않는다).
            case userTappedRedFlagTooltip
            case userTappedHighlight(cardIndex: Int, spanIndex: Int)
            case userTappedGuestTab(Int)
            /// 태도 코멘트 펼치기/접기 (항목 코드).
            case userTappedAttitudeComment(axisCode: String)
            case userTappedPeerFeedback
        }

        @CasePathable
        public enum Inner: Equatable, Sendable {
            case reportLoaded(InterviewReport)
            case reportFailed(InterviewReportError)
            /// 당겨서 새로고침 응답 — 재료만 갈아 끼운다(`loadState`·폴링은 건드리지 않는다).
            case reportRefreshed(InterviewReport)
            /// 당겨서 새로고침 실패 — 화면은 그대로 두고 미승격 서버 에러만 Alert 로 알린다.
            case reportRefreshFailed(InterviewReportError)
            /// 폴링 주기 경과 — 재조회 시점.
            case pollTicked
            /// `video/expiry` 응답 — 서버가 다시 계산한 남은 시간.
            case videoExpiryLoaded(InterviewVideoExpiry)
            /// `video/expiry` 실패 — 받은 값이 없으면 카운트다운을 숨긴 채 둔다(재생 가능 여부는 보고서 판정 그대로).
            case videoExpiryFailed
        }

        /// 코디네이터 통보. 화면 push 여부는 코디네이터가 판단한다 (D1).
        @CasePathable
        public enum Delegate: Equatable, Sendable {
            /// 영상 보기 — nil 이면 처음부터.
            /// 영상 플레이어 요청 — `entry` 는 «어디서 눌렀는가»(플레이어 하단 버튼 유무를 가른다).
            case videoRequested(startAt: TimeInterval?, entry: ReportVideoPlayerFeature.Entry)
            case peerFeedbackRequested
            case closeRequested
        }
    }

    private enum CancelID { case poll, videoExpiry }

    @Dependency(\.interviewReportClient) var interviewReportClient
    @Dependency(\.continuousClock) var clock
    @Dependency(\.date.now) var now

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case let .view(action):
                return reduceView(&state, action)

            case let .inner(action):
                return reduceInner(&state, action)

            // 시트가 «이 장면 영상으로 보기» 를 올리면 닫고 영상 요청으로 번역한다.
            // 닫되 버리지 않는다 — 플레이어 하단 버튼이 이 시트로 되돌아온다.
            case let .highlightDetail(.presented(.delegate(.videoJumpRequested(at)))):
                state.stashedHighlightDetail = state.highlightDetail
                state.highlightDetail = nil
                return .send(.delegate(.videoRequested(startAt: at, entry: .highlightSheet)))

            case .highlightDetail:
                return .none

            case .alert:
                return .none

            case .delegate:
                return .none
            }
        }
        .ifLet(\.$highlightDetail, action: \.highlightDetail) {
            ReportHighlightDetailFeature()
        }
        .ifLet(\.$alert, action: \.alert)
    }

    private func reduceView(_ state: inout State, _ action: Action.View) -> Effect<Action> {
        switch action {
        case .onAppear:
            // 툴팁은 State 초기값으로 한 번 띄운다 — 접으면 이 State 가 사는 동안 다시 안 띄운다.
            // 재진입(뒤로가기 복귀)에는 이미 받아둔 보고서를 그대로 쓴다.
            // 남은 시간만은 다시 묻는다 — 지인 링크 생성(+48h) 같은 사건이 그사이 기한을 늘렸을 수 있다.
            guard state.report == nil else { return fetchVideoExpiry(state) }
            return fetch(sessionId: state.sessionId)

        case .userPulledToRefresh:
            // 지인 제출은 화면이 열려 있는 동안에도 도착한다 — `onAppear` 는 이미 받아 둔 보고서를
            // 그대로 쓰므로(위) 재조회할 길이 여기밖에 없다. 폴링은 되살리지 않고 한 번만 묻는다.
            // 카드 선택·시트·툴팁 상태는 그대로 둔다 — 새로고침은 재료만 갱신하는 동작이다.
            return .run { [sessionId = state.sessionId] send in
                await send(.inner(.reportRefreshed(try await interviewReportClient.report(sessionId))))
            } catch: { error, send in
                // 새로고침 실패는 보고 있는 화면을 무너뜨리지 않는다 — 이미 받아 둔 보고서를 지우지 않는다.
                // 다만 미승격 서버 에러는 조용히 삼키면 원인이 사라져 Alert 로만 알린다.
                guard !(error is CancellationError) else { return }
                await send(.inner(.reportRefreshFailed(error as? InterviewReportError ?? .unexpected)))
            }

        case .userTappedReload:
            // 폴링 상한을 소진했던 화면이므로 카운터부터 되돌린다 — 안 그러면 첫 응답이 곧바로 다시 타임아웃.
            state.pollTickCount = 0
            state.loadState = .loading
            return fetch(sessionId: state.sessionId)

        case .userTappedClose:
            return .send(.delegate(.closeRequested))

        case .userTappedWatchVideo:
            return .send(.delegate(.videoRequested(startAt: nil, entry: .reportMain)))

        case let .userTappedQuestionTab(index):
            guard state.cards.indices.contains(index) else { return .none }
            state.selectedCardIndex = index
            return .none

        case .userTappedRedFlagInfo:
            state.isRedFlagTooltipVisible.toggle()
            return .none

        case .userTappedRedFlagTooltip:
            state.isRedFlagTooltipVisible = false
            return .none

        case let .userTappedHighlight(cardIndex, spanIndex):
            return presentHighlightDetail(&state, cardIndex: cardIndex, spanIndex: spanIndex)

        case let .userTappedGuestTab(index):
            guard state.guests.indices.contains(index) else { return .none }
            state.selectedGuestIndex = index
            // 지인이 바뀌면 펼쳐 둔 코멘트는 다른 사람 것이라 접는다.
            state.expandedCommentAxes = []
            return .none

        case let .userTappedAttitudeComment(axisCode):
            if state.expandedCommentAxes.contains(axisCode) {
                state.expandedCommentAxes.remove(axisCode)
            } else {
                state.expandedCommentAxes.insert(axisCode)
            }
            return .none

        case .userTappedPeerFeedback:
            return .send(.delegate(.peerFeedbackRequested))
        }
    }

    private func reduceInner(_ state: inout State, _ action: Action.Inner) -> Effect<Action> {
        switch action {
        case let .reportLoaded(report):
            apply(report, to: &state)
            switch report.status {
            case .generating:
                return schedulePoll(&state)
            // 채점 실패는 «정상 카드 없음» 이 아니라 별 상태다 — 정상 경로로 보내면 headline 이 비어
            // «분석 부족» 폴백 문구가 떠 오표기된다.
            case .failed:
                state.loadState = .generationFailed
                return .cancel(id: CancelID.poll)
            case .ready, .insufficientAnalysis:
                state.loadState = .loaded
                return .merge(.cancel(id: CancelID.poll), fetchVideoExpiry(state))
            }

        case let .reportRefreshed(report):
            // 단발 재조회 결과 — `loadState` 도 폴링도 건드리지 않는다.
            // 이미 받아 둔 보고서가 GENERATING 응답으로 되돌아가면 화면이 비므로 그 응답만 버린다.
            guard report.status != .generating else { return .none }
            apply(report, to: &state)
            return fetchVideoExpiry(state)

        case let .reportRefreshFailed(error):
            // 화면은 그대로 둔다 — 알릴 것은 번역 못 하는 미승격 서버 에러뿐이다.
            state.alert = error.serverAlertState()
            return .none

        case let .reportFailed(error):
            // 도메인이 케이스로 승격하지 않은 에러코드는 화면 문구로 번역할 수 없다 —
            // 서버 원문을 공통 Alert 로 띄운다(승격된 에러면 nil, [[api#공통 규약]]).
            state.alert = error.serverAlertState()
            // 보고서 미생성(404)은 실패가 아니라 «아직» — 폴링을 이어간다.
            guard error == .reportNotFound else {
                state.loadState = .failed(error)
                return .cancel(id: CancelID.poll)
            }
            return schedulePoll(&state)

        case .pollTicked:
            return fetch(sessionId: state.sessionId)

        case let .videoExpiryLoaded(expiry):
            // 잔여초를 지금 시각에 더해 만료 시각으로 바꿔 둔다 — 1초 갱신은 뷰의 TimelineView 몫이다.
            state.isVideoExpiredByServer = expiry.expired
            state.videoExpiresAt = expiry.expired ? nil : now.addingTimeInterval(TimeInterval(expiry.expiresInSeconds))
            return .none

        case .videoExpiryFailed:
            // 서버 값이 없으면 클라가 지어낼 기한도 없다 — 처음부터 못 받았으면 카운트다운은 숨겨진 채다(HLT-44).
            // 재진입·새로고침의 재조회 실패는 이미 받은 서버 값을 지우지 않는다 — 기한은 늘기만 해서(PRD Part 4 §5)
            // 옛 값은 틀린 방향이 아닌 하한이다.
            return .none
        }
    }

    /// 새 응답을 State 에 싣고 선택 위치를 보정한다 — 폴링·`loadState` 판정은 호출부 몫이다.
    /// 폴링과 당겨서 새로고침이 같은 보정을 쓴다(둘 다 카드·지인 수가 바뀔 수 있다).
    private func apply(_ report: InterviewReport, to state: inout State) {
        state.report = report
        // 폴링 중 카드 수가 줄어들 수 있다(분석 부족 확정) — 선택 위치가 범위를 벗어나면 처음으로 되돌린다.
        if !state.cards.indices.contains(state.selectedCardIndex) {
            state.selectedCardIndex = 0
        }
        // 지인은 반대로 늘어난다(피드백이 하나씩 도착) — 보고 있던 사람이 사라지는 경우만 되돌린다.
        if !state.guests.indices.contains(state.selectedGuestIndex) {
            state.selectedGuestIndex = 0
            state.expandedCommentAxes = []
        }
        // 영상이 재생 대상에서 빠졌으면 남은 시간도 의미가 없다.
        if state.playableVideoURL == nil {
            state.videoExpiresAt = nil
        }
    }

    /// 영상 남은 시간 조회 — 재생할 영상이 있을 때만 묻는다(만료·영상 없음이면 셀 것이 없다).
    /// 보고서 폴링과 수명을 따로 둔다: 폴링 취소가 이 조회까지 끊으면 카운트다운이 영영 안 뜬다.
    private func fetchVideoExpiry(_ state: State) -> Effect<Action> {
        // 영상이 빠졌으면 진행 중인 조회도 끊는다 — 늦게 온 옛 응답이 비워 둔 남은 시간을 되살리지 않게.
        guard state.playableVideoURL != nil else { return .cancel(id: CancelID.videoExpiry) }
        return .run { [sessionId = state.sessionId] send in
            await send(.inner(.videoExpiryLoaded(try await interviewReportClient.videoExpiry(sessionId))))
        } catch: { error, send in
            guard !(error is CancellationError) else { return }
            await send(.inner(.videoExpiryFailed))
        }
        .cancellable(id: CancelID.videoExpiry, cancelInFlight: true)
    }

    /// 채점이 끝나지 않았을 때 다음 조회를 예약한다. 상한을 넘으면 수동 재시도로 넘긴다.
    private func schedulePoll(_ state: inout State) -> Effect<Action> {
        guard state.pollTickCount < Self.pollLimit else {
            state.loadState = .pollTimedOut
            return .cancel(id: CancelID.poll)
        }
        state.pollTickCount += 1
        state.loadState = .loading
        return .run { send in
            try await clock.sleep(for: Self.pollInterval)
            await send(.inner(.pollTicked))
        }
        .cancellable(id: CancelID.poll)
    }

    private func fetch(sessionId: Int) -> Effect<Action> {
        .run { send in
            await send(.inner(.reportLoaded(try await interviewReportClient.report(sessionId))))
        } catch: { error, send in
            // 취소는 실패가 아니다 — 화면 이탈로 effect 가 끊긴 것뿐이라 에러 상태로 만들지 않는다.
            guard !(error is CancellationError) else { return }
            await send(.inner(.reportFailed(error as? InterviewReportError ?? .unexpected)))
        }
        .cancellable(id: CancelID.poll)
    }

    /// 하이라이트 탭 → 상세 시트. 인덱스가 서버 응답과 어긋나면 조용히 무시한다.
    private func presentHighlightDetail(
        _ state: inout State,
        cardIndex: Int,
        spanIndex: Int
    ) -> Effect<Action> {
        let cards = state.cards
        guard cards.indices.contains(cardIndex) else { return .none }
        let card = cards[cardIndex]
        guard let spans = card.highlightSpans, spans.indices.contains(spanIndex) else { return .none }
        guard let context = HighlightContext(card: card, span: spans[spanIndex]) else { return .none }
        state.highlightDetail = ReportHighlightDetailFeature.State(
            context: context,
            showsVideoJump: state.playableVideoURL != nil
        )
        return .none
    }
}

// MARK: - 표시 파생값

public extension ReportMainFeature.State {
    /// «상세 리포트» 제목 옆 툴팁에 서는 안내 줄 — **지금 보고 있는 질문 카드 것만** 세운다.
    /// 안내는 카드 소유라 탭을 바꾸면 툴팁 내용도 바뀐다. 한 카드 안에서는
    /// `resolutionNotice`(최대 1건) → `cardRedFlagNotices`(전부) 순으로 잇고,
    /// 빈 문자열은 줄만 차지하므로 버린다. 둘 다 없으면 비고, 그때 뷰가 느낌표·툴팁을 함께 감춘다.
    var detailReportNotices: [String] {
        guard let card = selectedCard else { return [] }
        let redFlags = (card.cardRedFlagNotices ?? []).map(\.message)
        let notices = card.resolutionNotice.map { [$0] + redFlags } ?? redFlags
        return notices.filter { !$0.isEmpty }
    }

    var cards: [InterviewReportCard] { report?.cards ?? [] }

    /// 상세 리포트에서 지금 펼쳐 보고 있는 카드.
    var selectedCard: InterviewReportCard? {
        cards.indices.contains(selectedCardIndex) ? cards[selectedCardIndex] : nil
    }

    /// 안내 유무 — 섹션 제목 옆 느낌표·툴팁의 노출 조건 (정의서 §2-4).
    var hasDetailReportNotices: Bool { !detailReportNotices.isEmpty }

    /// 툴팁 문구 — 안내가 여러 건이면 줄바꿈으로 잇는다(건수 상한 없음).
    var detailReportTooltipMessage: String {
        detailReportNotices.joined(separator: "\n")
    }

    /// 피드백을 제출한 지인 수 — 섹션이 통째로 nil 이면 0명.
    var guestParticipantCount: Int { report?.guestFeedback?.participantCount ?? 0 }

    /// 피드백을 남긴 지인들. 아무도 제출하지 않았으면 빈 배열.
    var guests: [GuestReview] { report?.guestFeedback?.guests ?? [] }

    /// 지인 피드백 섹션이 «요청 카드» 대신 «평가 목록» 을 보여줄 조건.
    var hasGuestFeedback: Bool { !guests.isEmpty }

    /// 지인 피드백에서 펼쳐 보고 있는 지인.
    var selectedGuest: GuestReview? {
        guests.indices.contains(selectedGuestIndex) ? guests[selectedGuestIndex] : nil
    }

    /// 재생 가능한 영상 주소. 만료·nil·형식 오류를 한 곳에서 흡수해
    /// 플레이어가 만료를 알 필요 없게 한다 (정의서 §8).
    /// `video/expiry` 가 만료를 알렸으면 보고서 판정보다 우선한다(서버가 더 최근에 다시 계산한 값).
    var playableVideoURL: URL? {
        guard !isVideoExpiredByServer else { return nil }
        guard let video = report?.video, video.expired != true, let raw = video.url else { return nil }
        return URL(string: raw)
    }
}
