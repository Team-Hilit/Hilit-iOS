//
//  MyPageAccountTests.swift
//  FeatureMyPageTests
//
//  Created by 서정원 on 26/08/08.
//

import ComposableArchitecture
import Testing
@testable import FeatureMyPageImplementation

@MainActor
struct MyPageAccountTests {
    @Test("로그아웃 탭 — 바로 끊지 않고 확인 모달만 띄운다")
    func logoutTapPresentsConfirmModal() async {
        let loggedOut = LockIsolated(false)
        let store = TestStore(initialState: MyPageFeature.State()) {
            MyPageFeature()
        } withDependencies: {
            $0.authClient.logout = { loggedOut.setValue(true) }
        }

        await store.send(.view(.userTappedLogout)) {
            $0.presentedModal = .logoutConfirm
        }
        #expect(!loggedOut.value)
    }

    @Test("로그아웃 확인 — 로컬 세션을 지우고 완료형 delegate 를 올린다")
    func logoutConfirmClearsSessionAndNotifies() async {
        let loggedOut = LockIsolated(false)
        var state = MyPageFeature.State()
        state.presentedModal = .logoutConfirm
        let store = TestStore(initialState: state) {
            MyPageFeature()
        } withDependencies: {
            $0.authClient.logout = { loggedOut.setValue(true) }
        }

        await store.send(.view(.userTappedModalConfirm)) {
            $0.presentedModal = nil
        }
        await store.receive(\.delegate.loggedOut)
        #expect(loggedOut.value)
    }

    @Test("로그아웃 확인에서 취소 — 모달만 닫고 세션은 그대로다")
    func logoutCancelKeepsSession() async {
        let loggedOut = LockIsolated(false)
        var state = MyPageFeature.State()
        state.presentedModal = .logoutConfirm
        let store = TestStore(initialState: state) {
            MyPageFeature()
        } withDependencies: {
            $0.authClient.logout = { loggedOut.setValue(true) }
        }

        await store.send(.view(.userTappedModalCancel)) {
            $0.presentedModal = nil
        }
        #expect(!loggedOut.value)
    }

    @Test("면접 진행 중 탈퇴 시도 — 차단 안내만 띄운다")
    func withdrawWhileInterviewIsBlocked() async {
        var state = MyPageFeature.State()
        state.isInterviewInProgress = true
        let store = TestStore(initialState: state) { MyPageFeature() }

        await store.send(.view(.userTappedWithdraw)) {
            $0.alert = .plain(message: "면접이 진행 중이에요. 면접이 끝나면 다시 시도해주세요.")
        }
    }

    @Test("탈퇴 확인 — 서버 탈퇴·로컬 세션 정리 후 완료형 delegate 를 올린다")
    func withdrawConfirmDeletesAccountAndNotifies() async {
        let withdrawn = LockIsolated(false)
        let loggedOut = LockIsolated(false)
        let store = TestStore(initialState: MyPageFeature.State()) {
            MyPageFeature()
        } withDependencies: {
            $0.userClient.withdraw = { withdrawn.setValue(true) }
            $0.authClient.logout = { loggedOut.setValue(true) }
        }

        await store.send(.view(.userTappedWithdraw)) {
            $0.alert = .withdrawConfirm
        }
        await store.send(.alert(.presented(.confirmWithdraw))) {
            $0.alert = nil
        }
        await store.receive(\.delegate.withdrawn)
        #expect(withdrawn.value)
        #expect(loggedOut.value)
    }

    @Test("탈퇴 실패 — 계정은 그대로, 안내 알럿만 띄운다")
    func withdrawFailureAlerts() async {
        struct StubError: Error {}
        let store = TestStore(initialState: MyPageFeature.State()) {
            MyPageFeature()
        } withDependencies: {
            $0.userClient.withdraw = { throw StubError() }
        }

        await store.send(.view(.userTappedWithdraw)) {
            $0.alert = .withdrawConfirm
        }
        await store.send(.alert(.presented(.confirmWithdraw))) {
            $0.alert = nil
        }
        await store.receive(\.inner.withdrawFailed) {
            $0.alert = .plain(message: "잠시 후 다시 시도해 주세요.")
        }
    }

    @Test("탈퇴 확인에서 취소 — 아무 일도 일어나지 않는다")
    func withdrawCancelKeepsAccount() async {
        let store = TestStore(initialState: MyPageFeature.State()) { MyPageFeature() }

        await store.send(.view(.userTappedWithdraw)) {
            $0.alert = .withdrawConfirm
        }
        await store.send(.alert(.dismiss)) {
            $0.alert = nil
        }
    }
}
