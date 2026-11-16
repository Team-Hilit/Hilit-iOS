//
//  MyPageUploadTests.swift
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

private struct StubError: Error {}

/// 업로드 흐름 픽스처 — 스위트 밖(파일 스코프)에 둬 본문엔 시나리오만 남긴다.
/// 취소 스위트(MyPageUploadCancelTests)도 같은 값을 물고 가므로 파일 밖에서 보이게 열어 뒀다.
/// 스텁 클로저(비격리)에서 부르므로 스위트의 @MainActor 밖이어야 한다.
enum UploadFixture {
    /// register 가 발급하는 서버 포폴 id — 폴링·재조회가 같은 값을 물고 간다.
    static let serverID = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!
    /// 교체 전 이미 등록돼 있던 포폴 id — delete 인자로 확인한다.
    static let existingID = UUID(uuidString: "00000000-0000-0000-0000-0000000000b2")!
    /// 피커가 돌려주는 URL — fileReader 를 스텁하므로 실제 파일은 열리지 않는다.
    static let pickedURL = URL(fileURLWithPath: "/tmp/portfolio.pdf")
    static let fileName = "portfolio.pdf"

    /// 업로드 중·실패 판이 그리는 표시 파일 — id 는 `$0.uuid = .incrementing` 의 첫 값.
    static let pendingFile = MyPageFeature.PortfolioFile(id: UUID(0), name: fileName)

    static let profile = UserProfile(
        userId: UUID(uuidString: "00000000-0000-0000-0000-0000000000c3")!,
        name: "재원",
        email: "hilit@kakao.com",
        provider: "KAKAO",
        jobRole: "BACKEND",
        jobRoleLabel: "백엔드",
        careerYears: 3,
        remainingTicketCount: 2
    )

    /// 업로드 성공 후의 재조회 응답 — 교체 카운터가 소진된(replaceAvailable false) 목록.
    static let readyList = list(status: .ready, replaceAvailable: false)
    /// 서버가 아직 처리 중이라고 답하는 목록 — 타 화면에서 시작된 업로드를 이어받는 진입 픽스처.
    static let processingList = list(status: .processing, replaceAvailable: true)
    /// 취소 후 재조회 응답 — 서버에도 남은 게 없다.
    static let emptyList = PortfolioList(portfolios: [], replaceAvailable: true)

    /// 선검증을 통과하는 작은 PDF 스텁.
    static func readableFile(
        byteCount: Int = 1024,
        pageCount: Int? = 3,
        isEncrypted: Bool = false
    ) -> DomainPortfolioInterface.PortfolioFile {
        .init(data: Data(repeating: 0x25, count: byteCount), pageCount: pageCount, isEncrypted: isEncrypted)
    }

    /// 서버 목록 한 건 — 처리 상태와 교체 가용성만 갈아 끼운다.
    private static func list(status: PortfolioProcessingStatus, replaceAvailable: Bool) -> PortfolioList {
        let portfolio = Portfolio(
            portfolioId: serverID, fileName: fileName, fileSize: 1024, pageCount: 3, status: status,
            uploadedAt: Date(timeIntervalSince1970: 1_783_728_000), interviewInProgress: false
        )
        return PortfolioList(portfolios: [portfolio], replaceAvailable: replaceAvailable)
    }
}

@MainActor
struct MyPageUploadTests {
    // MARK: - ① 피커 진입

    @Test("업로드 진입 3곳 — 빈 판·실패 판·교체 확인 모두 화면 안에서 파일 피커를 연다")
    func uploadEntriesPresentFilePicker() async {
        let empty = TestStore(initialState: MyPageFeature.State()) { MyPageFeature() }
        await empty.send(.view(.userTappedUploadPortfolio)) {
            $0.isFilePickerPresented = true
        }

        let failed = TestStore(initialState: MyPageFeature.State(portfolio: .failed(.init(name: "p.pdf")))) {
            MyPageFeature()
        }
        await failed.send(.view(.userTappedUploadPortfolio)) {
            $0.isFilePickerPresented = true
        }

        var replacing = MyPageFeature.State(portfolio: .registered(.init(id: UploadFixture.existingID, name: "old.pdf")))
        replacing.presentedModal = .replaceConfirm
        let replace = TestStore(initialState: replacing) { MyPageFeature() }
        await replace.send(.view(.userTappedModalConfirm)) {
            $0.presentedModal = nil
            $0.isFilePickerPresented = true
        }
    }

    // MARK: - ② 선검증

    @Test("선검증 실패(20MB 초과) — register 로 나가지 않고 실패 판 + 툴팁")
    func oversizedFileFailsBeforeRegister() async {
        let store = TestStore(initialState: MyPageFeature.State()) {
            MyPageFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.portfolioFileReader.read = { _ in
                UploadFixture.readableFile(byteCount: MyPageFeature.maxFileSizeBytes + 1)
            }
            $0.portfolioClient.register = { _ in
                Issue.record("선검증에서 막힌 파일은 register 로 나가지 않는다")
                return PortfolioProcessing(portfolioId: UploadFixture.serverID, status: .processing, message: nil)
            }
        }

        await store.send(.view(.fileSelected(UploadFixture.pickedURL))) {
            $0.portfolio = .uploading(UploadFixture.pendingFile, progress: 0.3)
        }
        await store.receive(\.inner.uploadFailed) {
            $0.portfolio = .failed(UploadFixture.pendingFile)
            $0.isPortfolioTooltipPresented = true
        }
    }

    // MARK: - ③ 성공 경로

    @Test("업로드 성공 — 접수 후 폴링, READY 는 낙관 전이 없이 진입 조회를 다시 태운다")
    func uploadPollsUntilReadyThenRefetches() async {
        let clock = TestClock()
        let store = TestStore(initialState: MyPageFeature.State()) {
            MyPageFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.uuid = .incrementing
            $0.portfolioFileReader.read = { _ in UploadFixture.readableFile() }
            $0.portfolioClient.register = { upload in
                #expect(upload.fileName == UploadFixture.fileName)
                #expect(upload.pageCount == 3)
                #expect(upload.fileSize == 1024)
                return PortfolioProcessing(portfolioId: UploadFixture.serverID, status: .processing, message: nil)
            }
            $0.portfolioClient.status = { id in
                #expect(id == UploadFixture.serverID)
                return PortfolioProcessing(portfolioId: id, status: .ready, message: nil)
            }
            $0.userClient.profile = { UploadFixture.profile }
            $0.portfolioClient.list = { UploadFixture.readyList }
            $0.interviewClient.reportList = { [] }
        }

        await store.send(.view(.fileSelected(UploadFixture.pickedURL))) {
            $0.portfolio = .uploading(UploadFixture.pendingFile, progress: 0.3)
        }
        await store.receive(\.inner.uploadAccepted) {
            $0.uploadServerID = UploadFixture.serverID
            $0.portfolio = .uploading(UploadFixture.pendingFile, progress: 0.7)
        }

        await clock.advance(by: .seconds(3))
        await store.receive(\.inner.uploadStatusPolled)
        await store.receive(\.inner.entryLoaded) {
            $0.profile = .init(profile: UploadFixture.profile)
            $0.portfolio = .init(list: UploadFixture.readyList)
            // 업로드가 끝난 판이라 접수 id 는 남지 않는다 — 다음 취소가 남의 포폴을 지우지 않게.
            $0.uploadServerID = nil
            $0.availability.replaceAvailable = false
            $0.isInterviewInProgress = false
            $0.reports = []
        }
    }

    // MARK: - ④ 교체 순서

    @Test("교체 — 새 파일이 확정된 뒤에야 기존 포폴을 지운다(delete 가 register 보다 먼저)")
    func replaceDeletesExistingBeforeRegister() async {
        let calls = LockIsolated<[String]>([])
        let initial = MyPageFeature.State(portfolio: .registered(.init(id: UploadFixture.existingID, name: "old.pdf")))
        let store = TestStore(initialState: initial) {
            MyPageFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.portfolioFileReader.read = { _ in
                calls.withValue { $0.append("read") }
                return UploadFixture.readableFile()
            }
            $0.portfolioClient.delete = { id in
                #expect(id == UploadFixture.existingID)
                calls.withValue { $0.append("delete") }
                return PortfolioDeletion(portfolioId: id, deletedAt: nil)
            }
            $0.portfolioClient.register = { _ in
                calls.withValue { $0.append("register") }
                return PortfolioProcessing(portfolioId: UploadFixture.serverID, status: .ready, message: nil)
            }
            $0.userClient.profile = { UploadFixture.profile }
            $0.portfolioClient.list = { UploadFixture.readyList }
            $0.interviewClient.reportList = { [] }
        }

        await store.send(.view(.fileSelected(UploadFixture.pickedURL))) {
            // 지우려는 기존 id 를 점유 후보로 들고 간다 — 실패해도 남아 다음 재시도가 정리 삭제를 선행한다.
            $0.uploadServerID = UploadFixture.existingID
            $0.portfolio = .uploading(UploadFixture.pendingFile, progress: 0.3)
        }
        await store.receive(\.inner.uploadAccepted) {
            $0.uploadServerID = UploadFixture.serverID
        }
        await store.receive(\.inner.entryLoaded) {
            $0.profile = .init(profile: UploadFixture.profile)
            $0.portfolio = .init(list: UploadFixture.readyList)
            $0.uploadServerID = nil
            $0.availability.replaceAvailable = false
            $0.isInterviewInProgress = false
            $0.reports = []
        }

        #expect(calls.value == ["read", "delete", "register"])
    }

    // MARK: - ⑤ 등록 실패

    @Test("register 실패 — 실패 판 + 툴팁으로 닫는다")
    func registerFailurePresentsFailedCard() async {
        let store = TestStore(initialState: MyPageFeature.State()) {
            MyPageFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.portfolioFileReader.read = { _ in UploadFixture.readableFile() }
            $0.portfolioClient.register = { _ in throw StubError() }
        }

        await store.send(.view(.fileSelected(UploadFixture.pickedURL))) {
            $0.portfolio = .uploading(UploadFixture.pendingFile, progress: 0.3)
        }
        await store.receive(\.inner.uploadFailed) {
            $0.portfolio = .failed(UploadFixture.pendingFile)
            $0.isPortfolioTooltipPresented = true
        }
    }

    // MARK: - ⑩·⑪ 점유 id 보존 · 실패 후 재시도

    @Test("교체 시작 — 기존 포폴 id 를 점유 후보로 들고 가고, 실패로 닫혀도 지우지 않는다")
    func replaceKeepsExistingIDAsOccupancyCandidate() async {
        let initial = MyPageFeature.State(portfolio: .registered(.init(id: UploadFixture.existingID, name: "old.pdf")))
        let store = TestStore(initialState: initial) {
            MyPageFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            // 파일 읽기에서 멈춰 세운다 — 선택 직후·실패 직후의 상태만 본다(삭제·등록 순서는 ④·⑩ 담당).
            $0.portfolioFileReader.read = { _ in throw StubError() }
        }

        await store.send(.view(.fileSelected(UploadFixture.pickedURL))) {
            $0.uploadServerID = UploadFixture.existingID
            $0.portfolio = .uploading(UploadFixture.pendingFile, progress: 0.3)
        }
        // 실패 판으로 닫혀도 uploadServerID 는 그대로 — 서버엔 기존 포폴이 남아 있다.
        await store.receive(\.inner.uploadFailed) {
            $0.portfolio = .failed(UploadFixture.pendingFile)
            $0.isPortfolioTooltipPresented = true
        }
    }

    @Test("교체 중 선검증 실패 후 다시 올리기 — 점유 중인 기존 포폴을 먼저 지우고 등록한다(409 루프 차단)")
    func retryAfterFailedReplaceDeletesOccupyingPortfolioFirst() async {
        let calls = LockIsolated<[String]>([])
        let reads = LockIsolated(0)
        let initial = MyPageFeature.State(portfolio: .registered(.init(id: UploadFixture.existingID, name: "old.pdf")))
        let store = TestStore(initialState: initial) {
            MyPageFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            // 첫 선택은 21MB(선검증 탈락), 재시도는 정상 파일.
            $0.portfolioFileReader.read = { _ in
                calls.withValue { $0.append("read") }
                let isFirst = reads.withValue { $0 += 1; return $0 == 1 }
                return UploadFixture.readableFile(byteCount: isFirst ? MyPageFeature.maxFileSizeBytes + 1 : 1024)
            }
            $0.portfolioClient.delete = { id in
                calls.withValue { $0.append(id == UploadFixture.existingID ? "delete(idA)" : "delete(\(id))") }
                return PortfolioDeletion(portfolioId: id, deletedAt: nil)
            }
            $0.portfolioClient.register = { _ in
                calls.withValue { $0.append("register") }
                return PortfolioProcessing(portfolioId: UploadFixture.serverID, status: .ready, message: nil)
            }
            $0.userClient.profile = { UploadFixture.profile }
            $0.portfolioClient.list = { UploadFixture.readyList }
            $0.interviewClient.reportList = { [] }
        }

        await store.send(.view(.fileSelected(UploadFixture.pickedURL))) {
            $0.uploadServerID = UploadFixture.existingID
            $0.portfolio = .uploading(UploadFixture.pendingFile, progress: 0.3)
        }
        await store.receive(\.inner.uploadFailed) {
            $0.portfolio = .failed(UploadFixture.pendingFile)
            $0.isPortfolioTooltipPresented = true
        }

        calls.setValue([])  // 재시도 구간만 본다.
        await store.send(.view(.fileSelected(UploadFixture.pickedURL))) {
            $0.portfolio = .uploading(.init(id: UUID(1), name: UploadFixture.fileName), progress: 0.3)
        }
        await store.receive(\.inner.uploadAccepted) {
            $0.uploadServerID = UploadFixture.serverID
        }
        await store.receive(\.inner.entryLoaded) {
            $0.profile = .init(profile: UploadFixture.profile)
            $0.portfolio = .init(list: UploadFixture.readyList)
            $0.uploadServerID = nil
            $0.availability.replaceAvailable = false
            $0.reports = []
        }

        // 실패 판에서 재시도해도 delete 가 앞선다 — 없으면 서버가 PORTFOLIO_ALREADY_EXISTS 로 되받아친다.
        #expect(calls.value == ["read", "delete(idA)", "register"])
    }
}
