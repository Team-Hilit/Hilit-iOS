//
//  MyPageUploadCancelTests.swift
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

/// 취소·재개·경합 — 업로드 줄기를 **끊는** 쪽 케이스 묶음(등록 성공 경로는 MyPageUploadTests).
/// 픽스처는 그 파일의 `UploadFixture` 공유 — 한 파일에 두면 length 한도(400줄)를 넘어 갈랐다.
@MainActor
struct MyPageUploadCancelTests {
    // MARK: - ⑥ 취소

    @Test("접수 후 취소 — 폴링을 끊고 서버 접수분까지 지운 뒤 다시 조회한다")
    func cancelAfterAcceptedDeletesServerCopy() async {
        let clock = TestClock()
        let deletedIDs = LockIsolated<[UUID]>([])
        let store = TestStore(initialState: MyPageFeature.State()) {
            MyPageFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.uuid = .incrementing
            $0.portfolioFileReader.read = { _ in UploadFixture.readableFile() }
            $0.portfolioClient.register = { _ in
                PortfolioProcessing(portfolioId: UploadFixture.serverID, status: .processing, message: nil)
            }
            $0.portfolioClient.status = { id in
                Issue.record("취소한 업로드는 더 이상 폴링하지 않는다")
                return PortfolioProcessing(portfolioId: id, status: .ready, message: nil)
            }
            $0.portfolioClient.delete = { id in
                deletedIDs.withValue { $0.append(id) }
                return PortfolioDeletion(portfolioId: id, deletedAt: nil)
            }
            $0.userClient.profile = { UploadFixture.profile }
            $0.portfolioClient.list = { UploadFixture.emptyList }
            $0.interviewClient.reportList = { [] }
        }

        await store.send(.view(.fileSelected(UploadFixture.pickedURL))) {
            $0.portfolio = .uploading(UploadFixture.pendingFile, progress: 0.3)
        }
        await store.receive(\.inner.uploadAccepted) {
            $0.uploadServerID = UploadFixture.serverID
            $0.portfolio = .uploading(UploadFixture.pendingFile, progress: 0.7)
        }

        await store.send(.view(.userTappedCancelUpload)) {
            $0.uploadServerID = nil
            $0.portfolio = .empty
        }
        await store.receive(\.inner.entryRefetchRequested)
        // 빈 목록이라 판·가용성은 기본값 그대로 — 프로필만 새로 앉는다.
        await store.receive(\.inner.entryLoaded) {
            $0.profile = .init(profile: UploadFixture.profile)
        }

        #expect(deletedIDs.value == [UploadFixture.serverID])
        // 폴링이 살아 있었다면 여기서 status 가 불린다 — 위 Issue.record 가 잡는다.
        await clock.advance(by: .seconds(3))
    }

    @Test("접수 전 취소 — 서버엔 아직 아무것도 없으니 지우지 않고 재조회만 한다")
    func cancelBeforeAcceptedSkipsDelete() async {
        let deleteCalled = LockIsolated(false)
        let initial = MyPageFeature.State(portfolio: .uploading(UploadFixture.pendingFile, progress: 0.3))
        let store = TestStore(initialState: initial) {
            MyPageFeature()
        } withDependencies: {
            $0.portfolioClient.delete = { id in
                deleteCalled.setValue(true)
                return PortfolioDeletion(portfolioId: id, deletedAt: nil)
            }
            $0.userClient.profile = { UploadFixture.profile }
            $0.portfolioClient.list = { UploadFixture.emptyList }
            $0.interviewClient.reportList = { [] }
        }

        await store.send(.view(.userTappedCancelUpload)) {
            $0.portfolio = .empty
        }
        await store.receive(\.inner.entryRefetchRequested)
        await store.receive(\.inner.entryLoaded) {
            $0.profile = .init(profile: UploadFixture.profile)
        }

        #expect(deleteCalled.value == false)
    }

    // MARK: - ⑦ 서버발 PROCESSING

    @Test("조회가 PROCESSING 을 주면 — 타 화면에서 시작된 업로드를 이어 폴링해 완료까지 따라간다")
    func processingFromEntryResumesPolling() async {
        let clock = TestClock()
        let listCalls = LockIsolated(0)
        let store = TestStore(initialState: MyPageFeature.State()) {
            MyPageFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.userClient.profile = { UploadFixture.profile }
            // 첫 조회는 처리 중, 폴링이 READY 를 본 뒤의 재조회는 완료본.
            $0.portfolioClient.list = {
                listCalls.withValue { $0 += 1 }
                return listCalls.value == 1 ? UploadFixture.processingList : UploadFixture.readyList
            }
            $0.portfolioClient.status = { id in
                #expect(id == UploadFixture.serverID)
                return PortfolioProcessing(portfolioId: id, status: .ready, message: nil)
            }
            $0.interviewClient.reportList = { [] }
        }

        await store.send(.view(.onAppear))
        await store.receive(\.inner.entryLoaded) {
            $0.profile = .init(profile: UploadFixture.profile)
            $0.portfolio = .init(list: UploadFixture.processingList)
            $0.uploadServerID = UploadFixture.serverID
        }

        await clock.advance(by: .seconds(3))
        await store.receive(\.inner.uploadStatusPolled)
        await store.receive(\.inner.entryLoaded) {
            $0.portfolio = .init(list: UploadFixture.readyList)
            $0.uploadServerID = nil
            $0.availability.replaceAvailable = false
        }
    }

    // MARK: - ⑧ 피커 실패

    @Test("피커 자체 실패 — 아직 어떤 전이도 없어 등록 판을 그대로 둔다")
    func fileSelectionFailureKeepsRegisteredCard() async {
        // delete 스텁을 일부러 주지 않는다 — 지우러 나가면 unimplemented 로 즉시 실패한다.
        let initial = MyPageFeature.State(portfolio: .registered(.init(id: UploadFixture.existingID, name: "old.pdf")))
        let store = TestStore(initialState: initial) { MyPageFeature() }

        await store.send(.view(.fileSelectionFailed))
    }

    // MARK: - ⑨ 조회 경합

    @Test("파일 선택 — 진행 중이던 진입 조회를 끊어 늦은 응답이 새 업로드 판을 덮지 못하게 한다")
    func fileSelectionCancelsInFlightEntryFetch() async {
        let store = TestStore(initialState: MyPageFeature.State()) {
            MyPageFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            // 진입 조회를 영원히 붙잡아 «늦은 응답» 을 만든다 — 끊기지 않으면 미완료 effect 로 테스트가 깨진다.
            $0.userClient.profile = { try await Task.never() }
            $0.portfolioClient.list = { UploadFixture.emptyList }
            $0.interviewClient.reportList = { [] }
            $0.portfolioFileReader.read = { _ in UploadFixture.readableFile() }
            // 서버 거절로 끝내 폴링·재조회가 뒤따르지 않게 한다 — 남는 effect 는 진입 조회뿐이라 취소 여부만 남는다.
            $0.portfolioClient.register = { _ in
                PortfolioProcessing(portfolioId: UploadFixture.serverID, status: .failedFile, message: nil)
            }
        }

        await store.send(.view(.onAppear))
        await store.send(.view(.fileSelected(UploadFixture.pickedURL))) {
            $0.portfolio = .uploading(UploadFixture.pendingFile, progress: 0.3)
        }
        await store.receive(\.inner.uploadAccepted) {
            $0.uploadServerID = UploadFixture.serverID
            $0.portfolio = .failed(UploadFixture.pendingFile)
            $0.isPortfolioTooltipPresented = true
        }
    }
}
