//
//  ReportPeerFeedbackFeatureTests.swift
//  FeatureReportTests
//
//  Created by EunSeo on 26/07/29.
//

import ComposableArchitecture
import CoreNetworkInterface
import DomainFeedbackShareInterface
import DomainInterviewReportInterface
import Foundation
import Testing

@testable import FeatureReportImplementation

@MainActor
struct ReportPeerFeedbackFeatureTests {
    /// 서버에 이미 만들어 둔 활성 링크 — 회수 경로 확인용 응답.
    /// `withDependencies` 클로저(nonisolated)에서 부르므로 격리를 벗긴다.
    private nonisolated static func activeStatus(axes: [String]) -> FeedbackShareStatus {
        FeedbackShareStatus(
            token: "tok",
            status: .active,
            axes: axes,
            submittedCount: 1,
            videoExpiresAt: nil,
            requestedAt: nil
        )
    }

    /// 항목을 전부 끈 상태 — 기본값(전부 ON)에서 켜는 순서·0개 방어를 보려는 출발점.
    private static func noAxesSelected() -> ReportPeerFeedbackFeature.State {
        var state = ReportPeerFeedbackFeature.State(sessionId: 7)
        state.selectedAxes = []
        return state
    }

    @Test("항목은 전부 켠 채로 시작한다")
    func startsWithAllAxesOn() {
        let state = ReportPeerFeedbackFeature.State(sessionId: 7)
        #expect(state.selectedAxes == Set(AttitudeAxisKind.allCases))
    }

    @Test("항목을 켠 순서와 무관하게 화면 순서로 서버에 보낸다")
    func sendsAxesInDisplayOrder() async {
        let sent = LockIsolated<[String]>([])
        let store = TestStore(initialState: Self.noAxesSelected()) {
            ReportPeerFeedbackFeature()
        } withDependencies: {
            $0.feedbackShareClient.create = { _, axes in
                sent.setValue(axes)
                return FeedbackShareCreated(token: "tok")
            }
        }

        // 목소리 → 시선 순으로 켠다.
        await store.send(.view(.userToggledAxis(.voice, isOn: true))) {
            $0.selectedAxes = [.voice]
        }
        await store.send(.view(.userToggledAxis(.gaze, isOn: true))) {
            $0.selectedAxes = [.voice, .gaze]
        }
        await store.send(.view(.userTappedCreateLink)) {
            $0.isCreating = true
        }
        await store.receive(\.inner.shareLinkCreated) {
            $0.isCreating = false
            $0.createdLink = "https://hilit.chottu.link/report?reportId=tok"
            $0.popup = .shareLinkReady
        }

        #expect(sent.value == ["GAZE", "VOICE"])
    }

    @Test("항목을 하나도 안 고르면 요청하지 않는다")
    func emptySelectionDoesNotCallServer() async {
        let store = TestStore(initialState: Self.noAxesSelected()) {
            ReportPeerFeedbackFeature()
        }
        // create 는 testValue(unimplemented) 그대로 — 호출되면 테스트가 실패한다.
        await store.send(.view(.userTappedCreateLink))
    }

    @Test("생성 실패는 사용자 문구로 바뀌고 CTA 가 다시 눌린다")
    func failureSurfacesMessageAndUnlocksCTA() async {
        let clock = TestClock()
        let store = TestStore(initialState: Self.noAxesSelected()) {
            ReportPeerFeedbackFeature()
        } withDependencies: {
            $0.feedbackShareClient.create = { _, _ in throw FeedbackShareError.networkFailure }
            $0.continuousClock = clock
        }

        await store.send(.view(.userToggledAxis(.gaze, isOn: true))) {
            $0.selectedAxes = [.gaze]
        }
        await store.send(.view(.userTappedCreateLink)) {
            $0.isCreating = true
        }
        await store.receive(\.inner.shareLinkFailed) {
            $0.isCreating = false
            $0.toast = "네트워크 연결을 확인해 주세요."
        }
        await clock.advance(by: .seconds(2))
        await store.receive(\.inner.toastDismissed) {
            $0.toast = nil
        }
        #expect(!store.state.isAxisLocked)
    }

    @Test("정의되지 않은 서버 에러코드는 토스트 대신 서버 원문 Alert 로 띄운다")
    func unrecognizedServerCodeShowsAlert() async {
        let store = TestStore(initialState: Self.noAxesSelected()) {
            ReportPeerFeedbackFeature()
        } withDependencies: {
            $0.feedbackShareClient.create = { _, _ in
                throw FeedbackShareError.server(
                    ServerError(code: "SHARE_LOCKED", message: "공유가 잠겨 있어요.", statusCode: 423)
                )
            }
        }

        await store.send(.view(.userToggledAxis(.gaze, isOn: true))) {
            $0.selectedAxes = [.gaze]
        }
        await store.send(.view(.userTappedCreateLink)) {
            $0.isCreating = true
        }
        await store.receive(\.inner.shareLinkFailed) {
            $0.isCreating = false
            $0.alert = AlertState(
                title: { TextState("SHARE_LOCKED(423)") },
                actions: { ButtonState(role: .cancel) { TextState("확인") } },
                message: { TextState("공유가 잠겨 있어요.") }
            )
        }
        // 토스트는 뜨지 않는다 — 한 사건을 두 자리에 쓰지 않는다.
        #expect(store.state.toast == nil)
    }

    @Test("409 는 실패로 끝나지 않는다 — 기존 링크를 회수해 완료 팝업을 다시 띄운다")
    func alreadyExistsRecoversLink() async {
        let store = TestStore(initialState: Self.noAxesSelected()) {
            ReportPeerFeedbackFeature()
        } withDependencies: {
            $0.feedbackShareClient.create = { _, _ in throw FeedbackShareError.alreadyExists }
            $0.feedbackShareClient.status = { _ in Self.activeStatus(axes: ["EXPRESSION"]) }
        }

        await store.send(.view(.userToggledAxis(.gaze, isOn: true))) {
            $0.selectedAxes = [.gaze]
        }
        await store.send(.view(.userTappedCreateLink)) {
            $0.isCreating = true
        }
        await store.receive(\.inner.existingShareLoaded) {
            $0.isCreating = false
            // 화면에서 고른 항목이 아니라 **링크에 잠긴** 항목이 남는다.
            $0.selectedAxes = [.expression]
            $0.createdLink = "https://hilit.chottu.link/report?reportId=tok"
            $0.isLinkRecovered = true
            $0.popup = .shareLinkReady
        }
        #expect(store.state.isAxisLocked)
    }

    @Test("409 인데 회수까지 실패하면 안내 토스트로 끝낸다")
    func alreadyExistsWithoutRecoveryFallsBackToToast() async {
        let clock = TestClock()
        let store = TestStore(initialState: Self.noAxesSelected()) {
            ReportPeerFeedbackFeature()
        } withDependencies: {
            $0.feedbackShareClient.create = { _, _ in throw FeedbackShareError.alreadyExists }
            $0.feedbackShareClient.status = { _ in throw FeedbackShareError.networkFailure }
            $0.continuousClock = clock
        }

        await store.send(.view(.userToggledAxis(.gaze, isOn: true))) {
            $0.selectedAxes = [.gaze]
        }
        await store.send(.view(.userTappedCreateLink)) {
            $0.isCreating = true
        }
        await store.receive(\.inner.shareLinkFailed) {
            $0.isCreating = false
            $0.toast = "이미 만들어 둔 링크가 있어요."
        }
        await clock.advance(by: .seconds(2))
        await store.receive(\.inner.toastDismissed) {
            $0.toast = nil
        }
    }

    @Test("진입 때 활성 링크가 있으면 회수해 항목을 잠근다 — 팝업은 스스로 뜨지 않는다")
    func onAppearRecoversActiveLink() async {
        let store = TestStore(initialState: ReportPeerFeedbackFeature.State(sessionId: 7)) {
            ReportPeerFeedbackFeature()
        } withDependencies: {
            $0.feedbackShareClient.status = { _ in Self.activeStatus(axes: ["GAZE", "VOICE", "NEW_AXIS"]) }
        }

        await store.send(.view(.onAppear))
        await store.receive(\.inner.existingShareLoaded) {
            // 서버가 축을 늘려도 모르는 코드는 버린다.
            $0.selectedAxes = [.gaze, .voice]
            $0.createdLink = "https://hilit.chottu.link/report?reportId=tok"
            $0.isLinkRecovered = true
        }
        #expect(store.state.isAxisLocked)
        // 진입만으로 팝업을 띄우지 않는다 — 재복사는 CTA 로 시작한다.
        #expect(store.state.popup == nil)
    }

    @Test("잠긴 토글을 탭하면 항목은 그대로 두고 잠김 안내 토스트를 띄운다")
    func lockedAxisTapShowsToast() async {
        let clock = TestClock()
        var state = ReportPeerFeedbackFeature.State(sessionId: 7)
        state.selectedAxes = [.gaze]
        state.createdLink = "https://hilit.chottu.link/report?reportId=tok"
        let store = TestStore(initialState: state) {
            ReportPeerFeedbackFeature()
        } withDependencies: {
            $0.continuousClock = clock
        }

        await store.send(.view(.userTappedLockedAxis)) {
            $0.toast = "링크 생성 후 조작이 불가능합니다."
        }
        await clock.advance(by: .seconds(2))
        await store.receive(\.inner.toastDismissed) {
            $0.toast = nil
        }
        #expect(store.state.selectedAxes == [.gaze])
    }

    @Test("무효화·비공개 링크는 회수 대상이 아니다 — 복사해도 지인이 못 연다")
    func onAppearIgnoresInactiveLink() async {
        let store = TestStore(initialState: ReportPeerFeedbackFeature.State(sessionId: 7)) {
            ReportPeerFeedbackFeature()
        } withDependencies: {
            $0.feedbackShareClient.status = { _ in
                FeedbackShareStatus(
                    token: "tok",
                    status: .private,
                    axes: ["GAZE"],
                    submittedCount: nil,
                    videoExpiresAt: nil,
                    requestedAt: nil
                )
            }
        }

        await store.send(.view(.onAppear))
        #expect(store.state.createdLink == nil)
        #expect(!store.state.isAxisLocked)
    }

    /// 링크가 이미 만들어져 팝업이 떠 있는 상태 — 복사 동선 테스트의 출발점.
    private static func popupState(
        _ popup: ReportPeerFeedbackFeature.Popup
    ) -> ReportPeerFeedbackFeature.State {
        var state = ReportPeerFeedbackFeature.State(sessionId: 7)
        state.createdLink = "https://hilit.chottu.link/report?reportId=tok"
        state.popup = popup
        return state
    }

    @Test("복사하면 클립보드에 담기고 복사 완료 판으로 바뀐 뒤 2초 만에 리포트 메인으로 나간다")
    func copyPutsLinkOnPasteboardThenLeavesAfterNotice() async {
        let clock = TestClock()
        let copied = LockIsolated<String?>(nil)
        let store = TestStore(initialState: Self.popupState(.shareLinkReady)) {
            ReportPeerFeedbackFeature()
        } withDependencies: {
            $0.pasteboard = PasteboardClient { copied.setValue($0) }
            $0.continuousClock = clock
        }

        await store.send(.view(.userTappedCopyLink)) {
            $0.popup = .linkCopied
        }
        #expect(copied.value == "https://hilit.chottu.link/report?reportId=tok")

        await clock.advance(by: .seconds(2))
        await store.receive(\.inner.linkCopiedPopupElapsed) {
            $0.popup = nil
        }
        // 나가기는 코디네이터 몫 — 화면은 신호만 올린다.
        await store.receive(\.delegate.backRequested)
    }

    @Test("팝업이 떠 있는 동안 상단 X 는 그 판만 닫는다 — 화면은 남는다")
    func closeDismissesPopupOnly() async {
        let store = TestStore(initialState: Self.popupState(.shareLinkReady)) {
            ReportPeerFeedbackFeature()
        }

        await store.send(.view(.userTappedBack)) {
            $0.popup = nil
        }
        // 링크는 그대로 손에 있고 항목도 잠긴 채다 — CTA 로 다시 복사할 수 있다.
        #expect(store.state.isAxisLocked)
    }

    @Test("복사 완료 판의 X 는 2초를 기다리지 않고 바로 나간다 — 예정된 이탈은 끊긴다")
    func closeOnCopyNoticeLeavesImmediately() async {
        let clock = TestClock()
        let store = TestStore(initialState: Self.popupState(.shareLinkReady)) {
            ReportPeerFeedbackFeature()
        } withDependencies: {
            $0.pasteboard = PasteboardClient { _ in }
            $0.continuousClock = clock
        }

        await store.send(.view(.userTappedCopyLink)) {
            $0.popup = .linkCopied
        }
        await clock.advance(by: .seconds(1))
        await store.send(.view(.userTappedBack)) {
            $0.popup = nil
        }
        await store.receive(\.delegate.backRequested)
        // 남은 1초가 흘러도 두 번째 신호가 없다 — 자동 이탈 effect 가 끊겼다.
        await clock.advance(by: .seconds(1))
    }

    @Test("팝업이 없을 때 상단 X 는 화면을 나간다")
    func closeWithoutPopupLeavesScreen() async {
        var initialState = ReportPeerFeedbackFeature.State(sessionId: 7)
        initialState.selectedAxes = [.gaze]
        let store = TestStore(initialState: initialState) {
            ReportPeerFeedbackFeature()
        }

        await store.send(.view(.userTappedBack))
        await store.receive(\.delegate.backRequested)
    }
}
