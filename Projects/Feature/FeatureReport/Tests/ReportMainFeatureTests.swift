//
//  ReportMainFeatureTests.swift
//  FeatureReportTests
//
//  Created by EunSeo on 26/07/25.
//

import ComposableArchitecture
import CoreNetworkInterface
import DomainInterviewReportInterface
import DomainInterviewReportTesting
import Foundation
import Testing

@testable import FeatureReportImplementation

@MainActor
struct ReportMainFeatureTests {
    /// `video/expiry` 를 받은 시각 — 남은 초를 만료 시각으로 바꾸는 기준.
    private nonisolated static let now = Date(timeIntervalSince1970: 1_780_000_000)
    /// 기본 `video/expiry` 응답 — 서버가 다시 계산한 남은 시간 1시간.
    private nonisolated static let expiry = InterviewVideoExpiry(expiresInSeconds: 3600, expired: false)

    private func store(
        report: @escaping @Sendable (Int) async throws -> InterviewReport,
        videoExpiry: @escaping @Sendable (Int) async throws -> InterviewVideoExpiry = { _ in Self.expiry },
        clock: TestClock<Duration>
    ) -> TestStore<ReportMainFeature.State, ReportMainFeature.Action> {
        TestStore(initialState: ReportMainFeature.State(sessionId: 1)) {
            ReportMainFeature()
        } withDependencies: {
            $0.interviewReportClient.report = report
            $0.interviewReportClient.videoExpiry = videoExpiry
            $0.continuousClock = clock
            $0.date = .constant(Self.now)
        }
    }

    /// 재생할 영상이 있는 보고서를 받으면 뒤따르는 `video/expiry` 응답 — 기본값(1시간)을 만료 시각으로 싣는다.
    private func receiveVideoExpiry(
        _ store: TestStore<ReportMainFeature.State, ReportMainFeature.Action>
    ) async {
        await store.receive(\.inner.videoExpiryLoaded) {
            $0.videoExpiresAt = Self.now.addingTimeInterval(3600)
        }
    }

    @Test("채점 중이면 폴링하고 READY 에서 멈춘다")
    func pollsWhileGeneratingThenStops() async {
        let clock = TestClock()
        let responses = LockIsolated([InterviewReportFixtures.generating, InterviewReportFixtures.ready])
        let store = store(
            report: { _ in responses.withValue { $0.removeFirst() } },
            clock: clock
        )

        await store.send(.view(.onAppear))
        await store.receive(\.inner.reportLoaded) {
            $0.report = InterviewReportFixtures.generating
            $0.pollTickCount = 1
        }

        await clock.advance(by: ReportMainFeature.pollInterval)
        await store.receive(\.inner.pollTicked)
        await store.receive(\.inner.reportLoaded) {
            $0.report = InterviewReportFixtures.ready
            $0.loadState = .loaded
        }
        await receiveVideoExpiry(store)
    }

    @Test("보고서 미생성(404)은 에러가 아니라 폴링 대상이다")
    func reportNotFoundKeepsPolling() async {
        let clock = TestClock()
        let store = store(report: { _ in throw InterviewReportError.reportNotFound }, clock: clock)

        await store.send(.view(.onAppear))
        await store.receive(\.inner.reportFailed) {
            $0.pollTickCount = 1
            $0.loadState = .loading
        }

        await store.skipInFlightEffects()
    }

    @Test("폴링 상한을 넘으면 수동 재시도로 넘어가고 effect 가 멈춘다")
    func pollLimitEndsPolling() async {
        let clock = TestClock()
        var state = ReportMainFeature.State(sessionId: 1)
        state.pollTickCount = ReportMainFeature.pollLimit
        let store = TestStore(initialState: state) {
            ReportMainFeature()
        } withDependencies: {
            $0.interviewReportClient.report = { _ in InterviewReportFixtures.generating }
            $0.continuousClock = clock
        }

        await store.send(.view(.onAppear))
        await store.receive(\.inner.reportLoaded) {
            $0.report = InterviewReportFixtures.generating
            $0.loadState = .pollTimedOut
        }
    }

    /// 채점 실패 응답 — 픽스처에 없어 여기서 만든다(전 필드 nil 이라 재료가 필요 없다).
    /// 응답 클로저(nonisolated)에서 읽히므로 격리를 벗긴다.
    private nonisolated static var failedReport: InterviewReport {
        InterviewReport(status: .failed, headline: nil, video: nil, cards: nil, guestFeedback: nil)
    }

    @Test("채점 실패(FAILED)는 정상 카드 경로가 아니라 전용 안내로 끝난다")
    func failedReportUsesOwnState() async {
        let clock = TestClock()
        let store = store(report: { _ in Self.failedReport }, clock: clock)

        await store.send(.view(.onAppear))
        // `.loaded` 로 보내면 headline 이 없어 «분석 부족» 폴백 문구가 떠 오표기된다.
        await store.receive(\.inner.reportLoaded) {
            $0.report = Self.failedReport
            $0.loadState = .generationFailed
        }
        // 폴링도 여기서 멈춘다 — 재조회해도 같은 답이라 되살릴 것이 없다.
        await clock.advance(by: ReportMainFeature.pollInterval)
    }

    @Test("복구 불가 에러는 실패 상태로 끝낸다")
    func sessionNotFoundFails() async {
        let clock = TestClock()
        let store = store(report: { _ in throw InterviewReportError.sessionNotFound }, clock: clock)

        await store.send(.view(.onAppear))
        await store.receive(\.inner.reportFailed) {
            $0.loadState = .failed(.sessionNotFound)
        }
    }

    @Test("정의되지 않은 서버 에러코드는 서버 원문을 기본 Alert 로 띄운다")
    func unrecognizedServerCodeShowsAlert() async {
        let clock = TestClock()
        let error = InterviewReportError.server(
            ServerError(code: "REPORT_LOCKED", message: "리포트가 잠겨 있어요.", statusCode: 409)
        )
        let store = store(report: { _ in throw error }, clock: clock)

        await store.send(.view(.onAppear))
        await store.receive(\.inner.reportFailed) {
            $0.alert = AlertState(
                title: { TextState("REPORT_LOCKED(409)") },
                actions: { ButtonState(role: .cancel) { TextState("확인") } },
                message: { TextState("리포트가 잠겨 있어요.") }
            )
            $0.loadState = .failed(error)
        }
    }

    @Test("새로고침 실패는 화면을 지우지 않지만 미승격 서버 에러는 Alert 로 알린다")
    func refreshServerErrorOnlyAlerts() async {
        let clock = TestClock()
        let callCount = LockIsolated(0)
        let store = store(
            report: { _ in
                let isFirst = callCount.withValue { count -> Bool in
                    count += 1
                    return count == 1
                }
                guard isFirst else {
                    throw InterviewReportError.server(
                        ServerError(code: "REPORT_LOCKED", message: "리포트가 잠겨 있어요.", statusCode: 409)
                    )
                }
                return InterviewReportFixtures.ready
            },
            clock: clock
        )

        await store.send(.view(.onAppear))
        await store.receive(\.inner.reportLoaded) {
            $0.report = InterviewReportFixtures.ready
            $0.loadState = .loaded
        }
        await receiveVideoExpiry(store)

        await store.send(.view(.userPulledToRefresh))
        await store.receive(\.inner.reportRefreshFailed) {
            $0.alert = AlertState(
                title: { TextState("REPORT_LOCKED(409)") },
                actions: { ButtonState(role: .cancel) { TextState("확인") } },
                message: { TextState("리포트가 잠겨 있어요.") }
            )
        }
        // 받아 둔 보고서는 그대로다 — 새로고침 실패가 화면을 무너뜨리지 않는다.
        #expect(store.state.loadState == .loaded)
        #expect(store.state.report == InterviewReportFixtures.ready)
    }

    @Test("툴팁은 보고 있는 질문 카드의 안내만 세운다 — 탭을 바꾸면 내용도 바뀐다")
    func tooltipShowsSelectedCardNoticesOnly() {
        var state = ReportMainFeature.State(sessionId: 1)
        state.report = InterviewReport(
            status: .ready,
            headline: nil,
            video: nil,
            cards: [
                InterviewReportFixtures.lowResolutionCard,
                InterviewReportFixtures.strongCard,
                InterviewReportFixtures.redFlaggedCard,
            ],
            guestFeedback: nil
        )

        let lowResolution = [InterviewReportFixtures.lowResolutionCard.resolutionNotice].compactMap { $0 }
        #expect(state.detailReportNotices == lowResolution)
        #expect(state.detailReportTooltipMessage == lowResolution.joined(separator: "\n"))

        // 안내가 없는 카드로 옮기면 느낌표·툴팁이 함께 사라진다.
        state.selectedCardIndex = 1
        #expect(state.detailReportNotices.isEmpty)
        #expect(!state.hasDetailReportNotices)

        // 레드플래그 카드에서는 그 카드의 배열만, 순서대로 전부.
        state.selectedCardIndex = 2
        let redFlags = (InterviewReportFixtures.redFlaggedCard.cardRedFlagNotices ?? []).map(\.message)
        #expect(state.detailReportNotices == redFlags)
        #expect(state.detailReportTooltipMessage == redFlags.joined(separator: "\n"))
    }

    @Test("안내가 둘 다 없으면 느낌표·툴팁을 그리지 않는다")
    func noNoticesHidesRedFlagTooltip() {
        var state = ReportMainFeature.State(sessionId: 1)
        state.report = InterviewReportFixtures.ready

        #expect(state.detailReportNotices.isEmpty)
        #expect(!state.hasDetailReportNotices)
    }

    @Test("한쪽만 오면 그 한 건만 툴팁에 선다")
    func singleNoticeShowsAlone() {
        var state = ReportMainFeature.State(sessionId: 1)

        state.report = InterviewReportFixtures.lowResolutionOnly
        #expect(
            state.detailReportNotices
                == [InterviewReportFixtures.lowResolutionCard.resolutionNotice].compactMap { $0 }
        )

        state.report = InterviewReportFixtures.withRedFlags
        #expect(
            state.detailReportNotices
                == (InterviewReportFixtures.redFlaggedCard.cardRedFlagNotices ?? []).map(\.message)
        )
    }

    @Test("만료·nil·형식오류 영상은 재생 대상이 아니다")
    func expiredVideoIsNotPlayable() {
        var state = ReportMainFeature.State(sessionId: 1)

        state.report = InterviewReportFixtures.insufficientAnalysis   // expired == true
        #expect(state.playableVideoURL == nil)

        state.report = InterviewReportFixtures.lowResolutionOnly      // video == nil
        #expect(state.playableVideoURL == nil)

        state.report = InterviewReportFixtures.ready
        #expect(state.playableVideoURL != nil)
    }

    @Test("하이라이트 탭은 시트를 올리고 톤을 타입으로 좁힌다")
    func highlightTapPresentsSheet() async {
        let clock = TestClock()
        let store = store(report: { _ in InterviewReportFixtures.ready }, clock: clock)

        await store.send(.view(.onAppear))
        await store.receive(\.inner.reportLoaded) {
            $0.report = InterviewReportFixtures.ready
            $0.loadState = .loaded
        }
        await receiveVideoExpiry(store)

        await store.send(.view(.userTappedHighlight(cardIndex: 0, spanIndex: 0))) {
            $0.highlightDetail = ReportHighlightDetailFeature.State(
                context: HighlightContext(
                    card: InterviewReportFixtures.strongCard,
                    span: InterviewReportFixtures.strongCard.highlightSpans![0]
                )!,
                showsVideoJump: true
            )
        }
        #expect(store.state.highlightDetail?.context.tone == .good)
    }

    @Test("범위를 벗어난 인덱스는 시트를 올리지 않는다")
    func outOfRangeHighlightIsIgnored() async {
        let clock = TestClock()
        let store = store(report: { _ in InterviewReportFixtures.ready }, clock: clock)

        await store.send(.view(.onAppear))
        await store.receive(\.inner.reportLoaded) {
            $0.report = InterviewReportFixtures.ready
            $0.loadState = .loaded
        }
        await receiveVideoExpiry(store)

        await store.send(.view(.userTappedHighlight(cardIndex: 99, spanIndex: 0)))
        await store.send(.view(.userTappedHighlight(cardIndex: 0, spanIndex: 99)))
    }

    @Test("해상도 낮음 카드는 탭 대상이 없다")
    func lowResolutionCardHasNoHighlight() async {
        let clock = TestClock()
        let store = store(report: { _ in InterviewReportFixtures.lowResolutionOnly }, clock: clock)

        await store.send(.view(.onAppear))
        await store.receive(\.inner.reportLoaded) {
            $0.report = InterviewReportFixtures.lowResolutionOnly
            $0.loadState = .loaded
        }

        await store.send(.view(.userTappedHighlight(cardIndex: 0, spanIndex: 0)))
        #expect(store.state.cards[0].isLowResolution)
    }

    @Test("시트의 장면 이동 요청은 시트를 닫고 영상 요청으로 번역된다")
    func videoJumpClosesSheetAndRequestsVideo() async {
        var state = ReportMainFeature.State(sessionId: 1)
        state.report = InterviewReportFixtures.ready
        state.loadState = .loaded
        state.highlightDetail = ReportHighlightDetailFeature.State(
            context: HighlightContext(
                transcript: "문장",
                span: HighlightSpan(startIndex: 0, endIndex: 2, tone: "GOOD", analysis: nil),
                evidenceAt: 12
            ),
            showsVideoJump: true
        )
        let store = TestStore(initialState: state) { ReportMainFeature() }

        await store.send(.highlightDetail(.presented(.view(.userTappedVideoJump))))
        await store.receive(\.highlightDetail.presented.delegate.videoJumpRequested) {
            // 시트는 닫되 버리지 않는다 — 플레이어 하단 «이전 화면으로 가기» 가 되살릴 재료다.
            $0.stashedHighlightDetail = $0.highlightDetail
            $0.highlightDetail = nil
        }
        await store.receive(\.delegate.videoRequested)
    }

    @Test("질문 탭은 선택 위치만 바꾸고, 범위를 벗어난 탭은 무시한다")
    func questionTabSelectsCard() async {
        let clock = TestClock()
        let store = store(report: { _ in InterviewReportFixtures.ready }, clock: clock)

        await store.send(.view(.onAppear))
        await store.receive(\.inner.reportLoaded) {
            $0.report = InterviewReportFixtures.ready
            $0.loadState = .loaded
        }
        await receiveVideoExpiry(store)

        await store.send(.view(.userTappedQuestionTab(1))) {
            $0.selectedCardIndex = 1
        }
        await store.send(.view(.userTappedQuestionTab(99)))
        #expect(store.state.selectedCard == InterviewReportFixtures.improveCard)
    }

    @Test("카드가 줄면 선택 위치를 처음으로 되돌린다")
    func selectionResetsWhenCardsShrink() async {
        let clock = TestClock()
        let responses = LockIsolated([InterviewReportFixtures.ready, InterviewReportFixtures.lowResolutionOnly])
        let store = store(report: { _ in responses.withValue { $0.removeFirst() } }, clock: clock)

        await store.send(.view(.onAppear))
        await store.receive(\.inner.reportLoaded) {
            $0.report = InterviewReportFixtures.ready
            $0.loadState = .loaded
        }
        await receiveVideoExpiry(store)
        await store.send(.view(.userTappedQuestionTab(1))) {
            $0.selectedCardIndex = 1
        }

        // 카드가 1장뿐인 응답이 다시 들어오면 선택 위치가 범위를 벗어난다.
        await store.send(.inner(.reportLoaded(InterviewReportFixtures.lowResolutionOnly))) {
            $0.report = InterviewReportFixtures.lowResolutionOnly
            $0.selectedCardIndex = 0
            // 영상이 사라진 응답이라 남은 시간도 함께 비운다.
            $0.videoExpiresAt = nil
        }
    }

    @Test("레드플래그 느낌표는 툴팁을 토글한다")
    func redFlagInfoTogglesTooltip() async {
        let clock = TestClock()
        let store = store(report: { _ in InterviewReportFixtures.withRedFlags }, clock: clock)

        await store.send(.view(.onAppear))
        await store.receive(\.inner.reportLoaded) {
            $0.report = InterviewReportFixtures.withRedFlags
            $0.loadState = .loaded
        }
        await receiveVideoExpiry(store)
        #expect(store.state.hasDetailReportNotices)

        // 시안이 느낌표·툴팁을 함께 띄우므로 기본이 펼침이다 — 첫 탭이 접는 쪽이고,
        // 이 단정이 통과하는 것 자체가 기본값이 true 임을 확인한다.
        await store.send(.view(.userTappedRedFlagInfo)) { $0.isRedFlagTooltipVisible = false }
        await store.send(.view(.userTappedRedFlagInfo)) { $0.isRedFlagTooltipVisible = true }
    }

    @Test("툴팁을 누르면 접히고, 화면에 다시 들어와도 도로 펼치지 않는다")
    func tooltipStaysClosedOnReentry() async {
        let clock = TestClock()
        let store = store(report: { _ in InterviewReportFixtures.withRedFlags }, clock: clock)

        await store.send(.view(.onAppear))
        await store.receive(\.inner.reportLoaded) {
            $0.report = InterviewReportFixtures.withRedFlags
            $0.loadState = .loaded
        }
        await receiveVideoExpiry(store)

        await store.send(.view(.userTappedRedFlagTooltip)) { $0.isRedFlagTooltipVisible = false }
        // 재진입 — 보고서도 툴팁도 그대로다. 툴팁은 State 가 새로 만들어질 때만 다시 뜬다.
        await store.send(.view(.onAppear))
        // 남은 시간만 다시 묻는다(같은 값이라 State 는 그대로).
        await store.receive(\.inner.videoExpiryLoaded)
        #expect(!store.state.isRedFlagTooltipVisible)
    }

    @Test("지인을 바꾸면 펼쳐 둔 코멘트를 접는다")
    func guestTabResetsExpandedComments() async {
        let clock = TestClock()
        let store = store(report: { _ in InterviewReportFixtures.withGuestFeedback }, clock: clock)

        await store.send(.view(.onAppear))
        await store.receive(\.inner.reportLoaded) {
            $0.report = InterviewReportFixtures.withGuestFeedback
            $0.loadState = .loaded
        }
        await receiveVideoExpiry(store)
        #expect(store.state.hasGuestFeedback)

        await store.send(.view(.userTappedAttitudeComment(axisCode: "EXPRESSION"))) {
            $0.expandedCommentAxes = ["EXPRESSION"]
        }
        await store.send(.view(.userTappedGuestTab(1))) {
            $0.selectedGuestIndex = 1
            $0.expandedCommentAxes = []
        }
        // 범위 밖 탭은 무시한다.
        await store.send(.view(.userTappedGuestTab(99)))
        #expect(store.state.selectedGuest == InterviewReportFixtures.secondGuest)
    }

    @Test("태도 코멘트는 항목별로 펼치고 접는다")
    func attitudeCommentToggles() async {
        let clock = TestClock()
        let store = store(report: { _ in InterviewReportFixtures.withGuestFeedback }, clock: clock)

        await store.send(.view(.onAppear))
        await store.receive(\.inner.reportLoaded) {
            $0.report = InterviewReportFixtures.withGuestFeedback
            $0.loadState = .loaded
        }
        await receiveVideoExpiry(store)

        await store.send(.view(.userTappedAttitudeComment(axisCode: "GAZE"))) {
            $0.expandedCommentAxes = ["GAZE"]
        }
        await store.send(.view(.userTappedAttitudeComment(axisCode: "VOICE"))) {
            $0.expandedCommentAxes = ["GAZE", "VOICE"]
        }
        await store.send(.view(.userTappedAttitudeComment(axisCode: "GAZE"))) {
            $0.expandedCommentAxes = ["VOICE"]
        }
    }

    @Test("폴링 타임아웃 후 수동 재시도가 폴링을 되살린다")
    func reloadRestartsAfterPollTimeout() async {
        let clock = TestClock()
        let responses = LockIsolated([InterviewReportFixtures.generating, InterviewReportFixtures.ready])
        // 상한을 소진한 상태에서 시작한다.
        var state = ReportMainFeature.State(sessionId: 1)
        state.pollTickCount = ReportMainFeature.pollLimit
        state.loadState = .pollTimedOut
        let store = TestStore(initialState: state) {
            ReportMainFeature()
        } withDependencies: {
            $0.interviewReportClient.report = { _ in responses.withValue { $0.removeFirst() } }
            $0.interviewReportClient.videoExpiry = { _ in Self.expiry }
            $0.continuousClock = clock
            $0.date = .constant(Self.now)
        }

        await store.send(.view(.userTappedReload)) {
            $0.pollTickCount = 0
            $0.loadState = .loading
        }
        await store.receive(\.inner.reportLoaded) {
            $0.report = InterviewReportFixtures.generating
            $0.pollTickCount = 1
        }

        await clock.advance(by: ReportMainFeature.pollInterval)
        await store.receive(\.inner.pollTicked)
        await store.receive(\.inner.reportLoaded) {
            $0.report = InterviewReportFixtures.ready
            $0.loadState = .loaded
        }
        await receiveVideoExpiry(store)
    }

    @Test("당겨서 새로고침은 한 번만 재조회하고 보던 상태를 지키며 폴링을 되살리지 않는다")
    func pullToRefreshFetchesOnce() async {
        let clock = TestClock()
        let responses = LockIsolated([InterviewReportFixtures.ready, InterviewReportFixtures.withGuestFeedback])
        // 그사이 지인 링크 생성(+48h)으로 서버가 기한을 다시 계산했다.
        let expiries = LockIsolated([Self.expiry, InterviewVideoExpiry(expiresInSeconds: 3600 + 172_800, expired: false)])
        let store = store(
            report: { _ in responses.withValue { $0.removeFirst() } },
            videoExpiry: { _ in expiries.withValue { $0.removeFirst() } },
            clock: clock
        )

        await store.send(.view(.onAppear))
        await store.receive(\.inner.reportLoaded) {
            $0.report = InterviewReportFixtures.ready
            $0.loadState = .loaded
        }
        await receiveVideoExpiry(store)
        await store.send(.view(.userTappedQuestionTab(1))) { $0.selectedCardIndex = 1 }
        await store.send(.view(.userTappedRedFlagTooltip)) { $0.isRedFlagTooltipVisible = false }

        // 늦게 도착한 지인 피드백이 들어온다 — `onAppear` 는 이미 받아 둔 보고서를 다시 묻지 않는다.
        await store.send(.view(.userPulledToRefresh))
        await store.receive(\.inner.reportRefreshed) {
            $0.report = InterviewReportFixtures.withGuestFeedback
        }
        // 새로고침은 남은 시간도 다시 묻는다 — 늘어난 기한이 카운트다운에 반영된다.
        await store.receive(\.inner.videoExpiryLoaded) {
            $0.videoExpiresAt = Self.now.addingTimeInterval(3600 + 172_800)
        }
        // 보던 카드와 접어 둔 툴팁은 그대로다 — 새로고침은 `onAppear` 가 아니다.
        #expect(store.state.selectedCardIndex == 1)
        #expect(!store.state.isRedFlagTooltipVisible)
        // 받아 둔 보고서를 GENERATING 으로 덮으면 화면이 빈다 — 그 응답만 버린다.
        await store.send(.inner(.reportRefreshed(InterviewReportFixtures.generating)))
        #expect(store.state.report == InterviewReportFixtures.withGuestFeedback)
        // 폴링은 되살아나지 않는다 — 시간이 흘러도 재조회 액션이 없다.
        await clock.advance(by: ReportMainFeature.pollInterval)
    }

    @Test("영상 남은 시간 조회가 실패하면 카운트다운을 숨기고 재생은 막지 않는다")
    func videoExpiryFailureHidesCountdown() async {
        let clock = TestClock()
        let store = store(
            report: { _ in InterviewReportFixtures.ready },
            videoExpiry: { _ in throw InterviewReportError.videoNotFound },
            clock: clock
        )

        await store.send(.view(.onAppear))
        await store.receive(\.inner.reportLoaded) {
            $0.report = InterviewReportFixtures.ready
            $0.loadState = .loaded
        }
        // 보고서의 `video.expiresAt` 으로 대신 세지 않는다 — 서버 값이 없으면 숨긴다(HLT-44).
        await store.receive(\.inner.videoExpiryFailed)
        #expect(store.state.videoExpiresAt == nil)
        #expect(store.state.playableVideoURL != nil)
    }

    @Test("재진입 때 남은 시간 재조회가 실패해도 이미 받은 서버 값은 지우지 않는다")
    func videoExpiryRefetchFailureKeepsValue() async {
        let clock = TestClock()
        let calls = LockIsolated(0)
        let store = store(
            report: { _ in InterviewReportFixtures.ready },
            videoExpiry: { _ in
                let isFirst = calls.withValue { count -> Bool in
                    count += 1
                    return count == 1
                }
                guard isFirst else { throw InterviewReportError.networkFailure }
                return Self.expiry
            },
            clock: clock
        )

        await store.send(.view(.onAppear))
        await store.receive(\.inner.reportLoaded) {
            $0.report = InterviewReportFixtures.ready
            $0.loadState = .loaded
        }
        await receiveVideoExpiry(store)

        // 기한은 늘기만 한다 — 옛 값은 하한이라 숨기지 않고 둔다.
        await store.send(.view(.onAppear))
        await store.receive(\.inner.videoExpiryFailed)
        #expect(store.state.videoExpiresAt == Self.now.addingTimeInterval(3600))
    }

    @Test("영상 남은 시간 조회가 만료를 알리면 보고서가 살아 있어도 재생 대상에서 뺀다")
    func videoExpiryExpiredBlocksPlayback() async {
        let clock = TestClock()
        let store = store(
            report: { _ in InterviewReportFixtures.ready },
            videoExpiry: { _ in InterviewVideoExpiry(expiresInSeconds: 0, expired: true) },
            clock: clock
        )

        await store.send(.view(.onAppear))
        await store.receive(\.inner.reportLoaded) {
            $0.report = InterviewReportFixtures.ready
            $0.loadState = .loaded
        }
        await store.receive(\.inner.videoExpiryLoaded) {
            $0.isVideoExpiredByServer = true
        }
        #expect(store.state.playableVideoURL == nil)
        // 만료된 영상은 다시 묻지 않는다 — 재진입에도 조회 effect 가 없다.
        await store.send(.view(.onAppear))
    }

    @Test("재생할 영상이 없으면 남은 시간을 묻지 않는다")
    func noPlayableVideoSkipsExpiry() async {
        let clock = TestClock()
        // 기본 store 의 videoExpiry 를 unimplemented 로 덮는다 — 불리면 테스트가 실패한다.
        let store = store(
            report: { _ in InterviewReportFixtures.insufficientAnalysis },
            videoExpiry: unimplemented("InterviewReportClient.videoExpiry"),
            clock: clock
        )

        await store.send(.view(.onAppear))
        await store.receive(\.inner.reportLoaded) {
            $0.report = InterviewReportFixtures.insufficientAnalysis
            $0.loadState = .loaded
        }
    }

    @Test("지인 피드백이 없으면 요청 카드를 보여준다")
    func noGuestFeedbackShowsRequestCard() {
        var state = ReportMainFeature.State(sessionId: 1)
        state.report = InterviewReportFixtures.ready   // guestFeedback == nil

        #expect(!state.hasGuestFeedback)
        #expect(state.guestParticipantCount == 0)
        #expect(state.selectedGuest == nil)
    }
}
