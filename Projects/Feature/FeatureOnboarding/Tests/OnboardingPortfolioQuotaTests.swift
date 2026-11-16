//
//  OnboardingPortfolioQuotaTests.swift
//  FeatureOnboardingTests
//
//  Created by EunSeo on 26/11/16.
//

import ComposableArchitecture
import DomainPortfolioInterface
import Foundation
import Testing

@testable import FeatureOnboardingImplementation

/// 포트폴리오 스텝의 한 달 1회 규칙(HLT-34)·폴링 상한(HLT-35).
@MainActor
struct OnboardingPortfolioQuotaTests {
    private static let portfolioId = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!
    private static let fileURL = URL(fileURLWithPath: "/tmp/포트폴리오.pdf")
    /// 2027-01-01 00:00 KST — 서버 `nextMonthStart()` 모양의 값.
    private static let nextMonth = Date(timeIntervalSince1970: 1_798_729_200)

    private static var uploadedState: OnboardingPortfolioUploadFeature.State {
        var state = OnboardingPortfolioUploadFeature.State()
        state.upload = .uploaded(fileName: "포트폴리오.pdf", portfolioId: portfolioId)
        return state
    }

    // MARK: - HLT-34 한 달 1회

    @Test("진입 조회는 계정 가용성을 먼저 담는다 — 바꿀 수 없는 계정이면 기존 포폴 모달이 잠금 안내를 붙인다")
    func onAppearStoresAvailability() async {
        let ready = Portfolio(
            portfolioId: Self.portfolioId, fileName: "포트폴리오.pdf", fileSize: nil, pageCount: nil,
            status: .ready, uploadedAt: nil
        )
        let store = TestStore(initialState: OnboardingPortfolioUploadFeature.State(checksExisting: true)) {
            OnboardingPortfolioUploadFeature()
        } withDependencies: {
            $0.portfolioClient.list = {
                PortfolioList(portfolios: [ready], replaceAvailable: false, nextAvailableAt: Self.nextMonth)
            }
        }

        await store.send(.view(.onAppear)) {
            $0.checksExisting = false
            $0.hasRequestedAvailability = true
        }
        await store.receive(\.inner.availabilityLoaded) {
            $0.availability = .init(replaceAvailable: false, nextReplaceAvailableAt: Self.nextMonth)
        }
        await store.receive(\.inner.existingPortfolioFound) {
            $0.existingPortfolio = .init(portfolioId: Self.portfolioId, fileName: "포트폴리오.pdf")
        }
        #expect(store.state.isPortfolioChangeLocked)
    }

    @Test("교체 기회를 썼으면 업로드 카드 탭이 피커 대신 교체 차단 모달을 띄운다")
    func uploadCardBlockedWhenReplaceExhausted() async {
        var state = OnboardingPortfolioUploadFeature.State()
        state.availability.replaceAvailable = false
        let store = TestStore(initialState: state) { OnboardingPortfolioUploadFeature() }

        await store.send(.view(.userTappedUploadCard)) {
            $0.quotaBlock = .replace
        }
        #expect(store.state.presentedModal == .quotaBlocked(.replace))
        await store.send(.view(.userTappedQuotaBlockDismiss)) {
            $0.quotaBlock = nil
        }
    }

    @Test("READY 포폴 X — 삭제 기회를 썼으면 삭제 차단, 교체 기회를 썼으면 «지우면 못 올림» 차단, 둘 다 남았으면 확인")
    func removeReadyBranchesOnQuota() async {
        var noDelete = Self.uploadedState
        noDelete.availability.deleteAvailable = false
        let deleteStore = TestStore(initialState: noDelete) { OnboardingPortfolioUploadFeature() }
        await deleteStore.send(.view(.userTappedRemoveFile)) { $0.quotaBlock = .delete }

        var noReplace = Self.uploadedState
        noReplace.availability.replaceAvailable = false
        let replaceStore = TestStore(initialState: noReplace) { OnboardingPortfolioUploadFeature() }
        await replaceStore.send(.view(.userTappedRemoveFile)) { $0.quotaBlock = .deleteWithoutReupload }

        let freeStore = TestStore(initialState: Self.uploadedState) { OnboardingPortfolioUploadFeature() }
        await freeStore.send(.view(.userTappedRemoveFile)) { $0.isDeleteConfirmPresented = true }
    }

    @Test("업로드 중 취소는 한도와 무관하게 확인 모달이다 — 기회를 쓰지 않는다")
    func removeUploadingIgnoresQuota() async {
        var state = OnboardingPortfolioUploadFeature.State()
        state.upload = .uploading(fileName: "포트폴리오.pdf", portfolioId: Self.portfolioId)
        state.availability = .init(replaceAvailable: false, deleteAvailable: false)
        let store = TestStore(initialState: state) { OnboardingPortfolioUploadFeature() }

        await store.send(.view(.userTappedRemoveFile)) { $0.isDeleteConfirmPresented = true }
    }

    @Test("서버가 DELETE_LIMIT_EXCEEDED 로 거절하면 배너 대신 삭제 차단 모달 + 가용성 재조회")
    func serverDeleteLimitPresentsQuotaBlock() async {
        var state = Self.uploadedState
        state.isDeleteConfirmPresented = true
        let store = TestStore(initialState: state) {
            OnboardingPortfolioUploadFeature()
        } withDependencies: {
            $0.portfolioClient.delete = { _ in throw PortfolioError.deleteLimitExceeded(message: "한 달에 한 번") }
            $0.portfolioClient.list = {
                PortfolioList(portfolios: [], deleteAvailable: false, nextDeleteAvailableAt: Self.nextMonth)
            }
        }

        await store.send(.view(.userTappedDeleteConfirm)) {
            $0.isDeleteConfirmPresented = false
            $0.isDeleting = true
        }
        await store.receive(\.inner.quotaRejected) {
            $0.isDeleting = false
            $0.availability.deleteAvailable = false
            $0.quotaBlock = .delete
        }
        await store.receive(\.inner.availabilityLoaded) {
            $0.availability.nextDeleteAvailableAt = Self.nextMonth
        }
        // 첨부는 그대로 — 서버에 남아 있다.
        #expect(store.state.upload.isUploaded)
        #expect(store.state.deleteErrorMessage == nil)
    }

    @Test("서버가 REPLACEMENT_LIMIT_EXCEEDED 로 등록을 거절하면 실패 판 대신 빈 판 + 교체 차단 모달")
    func serverReplacementLimitPresentsQuotaBlock() async {
        let store = TestStore(initialState: OnboardingPortfolioUploadFeature.State()) {
            OnboardingPortfolioUploadFeature()
        } withDependencies: {
            $0.portfolioFileReader.read = { _ in PortfolioFile(data: Data("pdf".utf8)) }
            $0.portfolioClient.register = { _ in
                throw PortfolioError.replacementLimitExceeded(message: "한 달에 한 번")
            }
            $0.portfolioClient.list = {
                PortfolioList(portfolios: [], replaceAvailable: false, nextAvailableAt: Self.nextMonth)
            }
        }

        await store.send(.view(.fileSelected(Self.fileURL))) {
            $0.upload = .uploading(fileName: "포트폴리오.pdf", portfolioId: nil)
        }
        await store.receive(\.inner.quotaRejected) {
            $0.availability.replaceAvailable = false
            $0.upload = .idle
            $0.quotaBlock = .replace
        }
        await store.receive(\.inner.availabilityLoaded) {
            $0.availability.nextReplaceAvailableAt = Self.nextMonth
        }
    }

    @Test("업로드 중 삭제가 DELETE_LIMIT_EXCEEDED 로 거절되면(그 사이 READY) 끊었던 폴링을 다시 잇는다")
    func uploadingDeleteRejectionResumesPolling() async {
        var state = OnboardingPortfolioUploadFeature.State()
        state.upload = .uploading(fileName: "포트폴리오.pdf", portfolioId: Self.portfolioId)
        state.isDeleteConfirmPresented = true
        let store = TestStore(initialState: state) {
            OnboardingPortfolioUploadFeature()
        } withDependencies: {
            $0.continuousClock = ImmediateClock()
            $0.portfolioClient.delete = { _ in throw PortfolioError.deleteLimitExceeded(message: "한 달에 한 번") }
            $0.portfolioClient.list = { PortfolioList(portfolios: [], deleteAvailable: false) }
            $0.portfolioClient.status = { id in PortfolioProcessing(portfolioId: id, status: .ready, message: nil) }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.view(.userTappedDeleteConfirm))
        await store.finish()
        await store.skipReceivedActions()

        #expect(store.state.upload == .uploaded(fileName: "포트폴리오.pdf", portfolioId: Self.portfolioId))
        #expect(store.state.quotaBlock == .delete)
    }

    // MARK: - HLT-35 폴링 상한

    @Test("PROCESSING 이 40회 이어지면 실패 판으로 끊고 서버의 처리 중 포폴을 정리 삭제한다")
    func pollingStopsAtCapAndCleansUp() async {
        let statusCalls = LockIsolated(0)
        let deletedId = LockIsolated<UUID?>(nil)
        let store = TestStore(initialState: OnboardingPortfolioUploadFeature.State()) {
            OnboardingPortfolioUploadFeature()
        } withDependencies: {
            $0.continuousClock = ImmediateClock()
            $0.portfolioFileReader.read = { _ in PortfolioFile(data: Data("pdf".utf8)) }
            $0.portfolioClient.register = { _ in
                PortfolioProcessing(portfolioId: Self.portfolioId, status: .processing, message: nil)
            }
            $0.portfolioClient.status = { id in
                statusCalls.withValue { $0 += 1 }
                return PortfolioProcessing(portfolioId: id, status: .processing, message: nil)
            }
            $0.portfolioClient.delete = { id in
                deletedId.setValue(id)
                return PortfolioDeletion(portfolioId: id, deletedAt: nil)
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.view(.fileSelected(Self.fileURL)))
        await store.finish()
        await store.skipReceivedActions()

        // 폴링 40회 + 정리 직전 확인 1회.
        #expect(statusCalls.value == OnboardingPortfolioUploadFeature.maxPollAttempts + 1)
        #expect(store.state.upload == .failed(message: OnboardingPortfolioUploadFeature.genericFailureMessage))
        #expect(deletedId.value == Self.portfolioId)
        // 실패 판 = 스와이프백·재선택이 다시 열리는 판(화면 이탈 출구).
        #expect(!store.state.upload.isUploading)
    }

    @Test("상한으로 끊은 뒤 정리 직전 확인에서 READY 면 지우지 않고 완료 판으로 받는다")
    func timedOutUploadBecomingReadyIsKept() async {
        let deleted = LockIsolated(false)
        var state = OnboardingPortfolioUploadFeature.State()
        state.upload = .uploading(fileName: "포트폴리오.pdf", portfolioId: Self.portfolioId)
        state.pollAttempts = OnboardingPortfolioUploadFeature.maxPollAttempts
        let store = TestStore(initialState: state) {
            OnboardingPortfolioUploadFeature()
        } withDependencies: {
            $0.portfolioClient.status = { id in PortfolioProcessing(portfolioId: id, status: .ready, message: nil) }
            $0.portfolioClient.delete = { id in
                deleted.setValue(true)
                return PortfolioDeletion(portfolioId: id, deletedAt: nil)
            }
        }

        await store.send(.inner(.statusPolled(
            PortfolioProcessing(portfolioId: Self.portfolioId, status: .processing, message: nil)
        ))) {
            $0.upload = .failed(message: OnboardingPortfolioUploadFeature.genericFailureMessage)
        }
        await store.receive(\.inner.timedOutUploadBecameReady) {
            $0.upload = .uploaded(fileName: "포트폴리오.pdf", portfolioId: Self.portfolioId)
        }
        #expect(!deleted.value)
    }

    @Test("새 파일을 고르면 폴링 횟수가 0 부터 다시 센다")
    func pollAttemptsResetOnNewFile() async {
        var state = OnboardingPortfolioUploadFeature.State()
        state.upload = .failed(message: "실패")
        state.pollAttempts = 40
        let store = TestStore(initialState: state) {
            OnboardingPortfolioUploadFeature()
        } withDependencies: {
            $0.portfolioFileReader.read = { _ in throw CancellationError() }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.view(.fileSelected(Self.fileURL))) {
            $0.pollAttempts = 0
            $0.upload = .uploading(fileName: "포트폴리오.pdf", portfolioId: nil)
        }
    }
}
