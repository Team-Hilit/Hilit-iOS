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

/// 포트폴리오 스텝의 폴링 상한(HLT-35).
@MainActor
struct OnboardingPortfolioQuotaTests {
    private static let portfolioId = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!
    private static let fileURL = URL(fileURLWithPath: "/tmp/포트폴리오.pdf")
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
