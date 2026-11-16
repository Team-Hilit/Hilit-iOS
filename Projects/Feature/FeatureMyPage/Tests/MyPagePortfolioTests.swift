//
//  MyPagePortfolioTests.swift
//  FeatureMyPageTests
//
//  Created by 서정원 on 26/08/08.
//

import ComposableArchitecture
import DomainInterviewInterface
import DomainPortfolioInterface
import DomainUserInterface
import Foundation
import Testing
@testable import FeatureMyPageImplementation

@MainActor
struct MyPagePortfolioTests {
    private static let portfolioId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private static let emptyList = PortfolioList(portfolios: [], replaceAvailable: true)

    private static let profile = UserProfile(
        userId: UUID(),
        name: "재원",
        email: "hilit@kakao.com",
        provider: "KAKAO",
        jobRole: "BACKEND",
        jobRoleLabel: "백엔드",
        careerYears: 3,
        remainingTicketCount: 2
    )

    private func makeStore(_ state: MyPageFeature.State) -> TestStoreOf<MyPageFeature> {
        TestStore(initialState: state) { MyPageFeature() }
    }

    @Test("면접 중이 아니고 삭제 기회가 남았으면 삭제 탭이 확인 모달을 띄운다")
    func deleteTapPresentsConfirmWithReuploadNotice() async {
        var state = MyPageFeature.State(portfolio: .registered(.init(name: "p.pdf")))
        state.availability.replaceAvailable = false
        let store = makeStore(state)

        await store.send(.view(.userTappedRemovePortfolio)) {
            $0.presentedModal = .deleteConfirm
        }
    }

    @Test("면접 중이면 삭제 탭이 차단 모달을 띄운다")
    func deleteTapWhileInterviewPresentsBlocked() async {
        var state = MyPageFeature.State(portfolio: .registered(.init(name: "p.pdf")))
        state.isInterviewInProgress = true
        let store = makeStore(state)

        await store.send(.view(.userTappedRemovePortfolio)) {
            $0.presentedModal = .deleteBlocked(.interviewInProgress)
        }
    }

    @Test("등록 상태에서 업로드 탭 — 교체 가능하면 확인, 소진이면 차단 모달")
    func uploadTapBranchesOnReplaceAvailability() async {
        var state = MyPageFeature.State(portfolio: .registered(.init(name: "p.pdf")))
        state.availability.replaceAvailable = false
        let store = makeStore(state)

        await store.send(.view(.userTappedUploadPortfolio)) {
            $0.presentedModal = .replaceBlocked
        }
    }

    @Test("등록 판 교체 — 교체 기회가 남아도 삭제 기회가 없으면 삭제 한도 차단 모달 (교체 = 삭제 후 등록)")
    func replaceTapWithoutDeleteQuotaPresentsMonthlyLimit() async {
        var state = MyPageFeature.State(portfolio: .registered(.init(name: "p.pdf")))
        state.availability.deleteAvailable = false
        let store = makeStore(state)

        await store.send(.view(.userTappedUploadPortfolio)) {
            $0.presentedModal = .deleteBlocked(.monthlyLimit)
        }
    }

    @Test("등록 판 교체 — 면접 진행 중이면 면접 진행 중 차단 모달")
    func replaceTapWhileInterviewPresentsBlocked() async {
        var state = MyPageFeature.State(portfolio: .registered(.init(name: "p.pdf")))
        state.isInterviewInProgress = true
        let store = makeStore(state)

        await store.send(.view(.userTappedUploadPortfolio)) {
            $0.presentedModal = .deleteBlocked(.interviewInProgress)
        }
    }

    @Test("이번 달 삭제 기회를 썼으면 삭제 탭이 삭제 한도 차단 모달을 띄운다")
    func deleteTapWithoutDeleteQuotaPresentsMonthlyLimit() async {
        var state = MyPageFeature.State(portfolio: .registered(.init(name: "p.pdf")))
        state.availability.deleteAvailable = false
        let store = makeStore(state)

        await store.send(.view(.userTappedRemovePortfolio)) {
            $0.presentedModal = .deleteBlocked(.monthlyLimit)
        }
    }

    @Test("면접 진행 중이 삭제 한도보다 먼저다")
    func interviewBlockWinsOverMonthlyLimit() async {
        var state = MyPageFeature.State(portfolio: .registered(.init(name: "p.pdf")))
        state.isInterviewInProgress = true
        state.availability.deleteAvailable = false
        let store = makeStore(state)

        await store.send(.view(.userTappedRemovePortfolio)) {
            $0.presentedModal = .deleteBlocked(.interviewInProgress)
        }
    }

    @Test("목록 응답의 다음 가능일·삭제 가능 여부를 그대로 상태에 담는다 (HLT-106)")
    func entryLoadedStoresServerAvailability() async {
        let list = PortfolioList(
            portfolios: [],
            replaceAvailable: false,
            nextAvailableAt: Self.nextMonth,
            deleteAvailable: false,
            nextDeleteAvailableAt: Self.nextMonth
        )
        let store = makeStore(MyPageFeature.State())

        await store.send(.inner(.entryLoaded(Self.profile, list, []))) {
            $0.profile = .init(profile: Self.profile)
            $0.availability = .init(
                replaceAvailable: false,
                nextReplaceAvailableAt: Self.nextMonth,
                deleteAvailable: false,
                nextDeleteAvailableAt: Self.nextMonth
            )
        }
    }


    @Test("삭제 확인 — 서버 삭제 후 진입 조회 전체를 다시 탄다")
    func deleteConfirmDeletesAndRefetches() async {
        let deleted = LockIsolated(false)
        var state = MyPageFeature.State(
            portfolio: .registered(.init(id: Self.portfolioId, name: "portfolio.pdf"))
        )
        state.presentedModal = .deleteConfirm
        let store = TestStore(initialState: state) {
            MyPageFeature()
        } withDependencies: {
            $0.portfolioClient.delete = { id in
                #expect(id == Self.portfolioId)
                deleted.setValue(true)
                return PortfolioDeletion(portfolioId: id, deletedAt: nil)
            }
            $0.userClient.profile = { Self.profile }
            $0.portfolioClient.list = { Self.emptyList }
            $0.interviewClient.reportList = { [] }
        }

        await store.send(.view(.userTappedModalConfirm)) {
            $0.presentedModal = nil
        }
        await store.receive(\.inner.portfolioDeleted)
        await store.receive(\.inner.entryLoaded) {
            $0.profile = .init(profile: Self.profile)
            $0.portfolio = .empty
            $0.isInterviewInProgress = false
            $0.reports = []
        }
        #expect(deleted.value)
    }

    @Test("삭제 실패 — 상태를 유지하고 안내 알럿만 띄운다")
    func deleteFailureKeepsStateAndAlerts() async {
        struct StubError: Error {}
        var state = MyPageFeature.State(
            portfolio: .registered(.init(id: Self.portfolioId, name: "portfolio.pdf"))
        )
        state.presentedModal = .deleteConfirm
        let store = TestStore(initialState: state) {
            MyPageFeature()
        } withDependencies: {
            $0.portfolioClient.delete = { _ in throw StubError() }
        }

        await store.send(.view(.userTappedModalConfirm)) {
            $0.presentedModal = nil
        }
        await store.receive(\.inner.portfolioDeleteFailed) {
            $0.alert = .plain(message: "잠시 후 다시 시도해 주세요.")
        }
    }

    @Test("서버가 DELETE_LIMIT_EXCEEDED 로 거절하면 알럿 대신 삭제 한도 차단 모달 + 가용성 재조회 (HLT-107)")
    func serverDeleteLimitPresentsMonthlyLimit() async {
        let list = PortfolioList(
            portfolios: [Portfolio(
                portfolioId: Self.portfolioId, fileName: "portfolio.pdf", fileSize: nil, pageCount: nil,
                status: .ready, uploadedAt: nil, interviewInProgress: false
            )],
            deleteAvailable: false,
            nextDeleteAvailableAt: Self.nextMonth
        )
        var state = MyPageFeature.State(
            portfolio: .registered(.init(id: Self.portfolioId, name: "portfolio.pdf"))
        )
        state.presentedModal = .deleteConfirm
        let store = TestStore(initialState: state) {
            MyPageFeature()
        } withDependencies: {
            $0.portfolioClient.delete = { _ in throw PortfolioError.deleteLimitExceeded(message: "한 달에 한 번") }
            $0.userClient.profile = { Self.profile }
            $0.portfolioClient.list = { list }
            $0.interviewClient.reportList = { [] }
        }

        await store.send(.view(.userTappedModalConfirm)) {
            $0.presentedModal = nil
        }
        await store.receive(\.inner.portfolioDeleteBlocked) {
            $0.availability.deleteAvailable = false
            $0.presentedModal = .deleteBlocked(.monthlyLimit)
        }
        await store.receive(\.inner.entryLoaded) {
            $0.profile = .init(profile: Self.profile)
            $0.portfolio = .registered(.init(portfolio: list.portfolios[0]))
            $0.availability.nextDeleteAvailableAt = Self.nextMonth
        }
    }

    @Test("서버가 면접 진행 중으로 삭제를 거절하면 면접 진행 중 차단 모달")
    func serverInterviewBlockPresentsInterviewInProgress() async {
        var state = MyPageFeature.State(
            portfolio: .registered(.init(id: Self.portfolioId, name: "portfolio.pdf"))
        )
        state.presentedModal = .deleteConfirm
        let store = TestStore(initialState: state) {
            MyPageFeature()
        } withDependencies: {
            $0.portfolioClient.delete = { _ in throw PortfolioError.deleteBlockedByInterview(message: "면접 중") }
            $0.userClient.profile = { Self.profile }
            $0.portfolioClient.list = { Self.emptyList }
            $0.interviewClient.reportList = { [] }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.view(.userTappedModalConfirm))
        await store.receive(\.inner.portfolioDeleteBlocked) {
            $0.isInterviewInProgress = true
            $0.presentedModal = .deleteBlocked(.interviewInProgress)
        }
        await store.receive(\.inner.entryLoaded)
    }

    /// 2027-01-01 00:00 KST — 서버 `nextMonthStart()` 모양의 값.
    private static let nextMonth = Date(timeIntervalSince1970: 1_798_729_200)
}
