//
//  OnboardingPortfolioUploadFeatureTests.swift
//  FeatureOnboardingTests
//
//  Created by EunSeo on 26/07/19.
//

import ComposableArchitecture
import DomainPortfolioInterface
import Foundation
import Testing

@testable import FeatureOnboardingImplementation

@MainActor
struct OnboardingPortfolioUploadFeatureTests {
    private static let portfolioId = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!
    private static let fileURL = URL(fileURLWithPath: "/tmp/포트폴리오.pdf")

    @Test("업로드 카드 탭은 파일 선택 시트를 연다")
    func uploadCardOpensFileImporter() async {
        let store = TestStore(initialState: OnboardingPortfolioUploadFeature.State()) {
            OnboardingPortfolioUploadFeature()
        }

        await store.send(.view(.userTappedUploadCard)) {
            $0.isFileImporterPresented = true
        }
    }

    @Test("업로드 중에는 카드 탭이 무시된다")
    func uploadCardIsIgnoredWhileUploading() async {
        var initialState = OnboardingPortfolioUploadFeature.State()
        initialState.upload = .uploading(fileName: "포트폴리오.pdf", portfolioId: nil)
        let store = TestStore(initialState: initialState) {
            OnboardingPortfolioUploadFeature()
        }

        await store.send(.view(.userTappedUploadCard))
    }

    @Test("파일 선택은 등록 접수 후 READY 폴링까지 완료 상태로 이어진다")
    func fileSelectionRegistersAndPollsUntilReady() async {
        let store = TestStore(initialState: OnboardingPortfolioUploadFeature.State()) {
            OnboardingPortfolioUploadFeature()
        } withDependencies: {
            $0.continuousClock = ImmediateClock()
            $0.portfolioFileReader.read = { _ in PortfolioFile(data: Data("pdf".utf8)) }
            $0.portfolioClient.register = { _ in
                PortfolioProcessing(portfolioId: Self.portfolioId, status: .processing, message: nil)
            }
            $0.portfolioClient.status = { id in
                PortfolioProcessing(portfolioId: id, status: .ready, message: nil)
            }
        }

        await store.send(.view(.fileSelected(Self.fileURL))) {
            $0.upload = .uploading(fileName: "포트폴리오.pdf", portfolioId: nil)
        }
        await store.receive(\.inner.uploadAccepted) {
            $0.pollAttempts = 1
            $0.upload = .uploading(fileName: "포트폴리오.pdf", portfolioId: Self.portfolioId)
        }
        await store.receive(\.inner.statusPolled) {
            $0.upload = .uploaded(fileName: "포트폴리오.pdf", portfolioId: Self.portfolioId)
        }
        #expect(store.state.isContinueEnabled)
    }

    @Test("파일 파싱 실패(FAILED_FILE)는 기본 안내 문구의 실패 상태로 전환한다")
    func failedFileTransitionsToFailedState() async {
        let store = TestStore(initialState: OnboardingPortfolioUploadFeature.State()) {
            OnboardingPortfolioUploadFeature()
        } withDependencies: {
            $0.portfolioFileReader.read = { _ in PortfolioFile(data: Data("pdf".utf8)) }
            $0.portfolioClient.register = { _ in
                PortfolioProcessing(portfolioId: Self.portfolioId, status: .failedFile, message: nil)
            }
        }

        await store.send(.view(.fileSelected(Self.fileURL))) {
            $0.upload = .uploading(fileName: "포트폴리오.pdf", portfolioId: nil)
        }
        await store.receive(\.inner.uploadAccepted) {
            $0.upload = .failed(message: OnboardingPortfolioUploadFeature.unreadableFileMessage)
        }
        #expect(!store.state.isContinueEnabled)
    }

    @Test("서버 4xx 는 응답 message 를 그대로 실패 문구로 쓴다")
    func serverErrorShowsServerMessage() async {
        let serverMessage = "이미 등록된 포트폴리오가 있어요. 기존 포트폴리오를 삭제한 뒤 새로 올려주세요."
        let store = TestStore(initialState: OnboardingPortfolioUploadFeature.State()) {
            OnboardingPortfolioUploadFeature()
        } withDependencies: {
            $0.portfolioFileReader.read = { _ in PortfolioFile(data: Data("pdf".utf8)) }
            $0.portfolioClient.register = { _ in throw PortfolioError.alreadyExists(message: serverMessage) }
        }

        await store.send(.view(.fileSelected(Self.fileURL))) {
            $0.upload = .uploading(fileName: "포트폴리오.pdf", portfolioId: nil)
        }
        await store.receive(\.inner.uploadFailed) {
            $0.upload = .failed(message: serverMessage)
        }
    }

    @Test("서버 message 를 실은 200 FAILED_FILE 은 그 문구로 실패 상태가 된다")
    func failedFileUsesServerMessage() async {
        let serverMessage = "파일이 손상되었거나 암호로 보호되어 있어요. 다시 업로드해 주세요."
        let store = TestStore(initialState: OnboardingPortfolioUploadFeature.State()) {
            OnboardingPortfolioUploadFeature()
        } withDependencies: {
            $0.portfolioFileReader.read = { _ in PortfolioFile(data: Data("pdf".utf8)) }
            $0.portfolioClient.register = { _ in
                PortfolioProcessing(portfolioId: Self.portfolioId, status: .failedFile, message: serverMessage)
            }
        }

        await store.send(.view(.fileSelected(Self.fileURL))) {
            $0.upload = .uploading(fileName: "포트폴리오.pdf", portfolioId: nil)
        }
        await store.receive(\.inner.uploadAccepted) {
            $0.upload = .failed(message: serverMessage)
        }
    }

    @Test("파일 읽기 실패는 일반 실패 문구의 실패 상태로 전환한다")
    func fileReadFailureTransitionsToFailedState() async {
        let store = TestStore(initialState: OnboardingPortfolioUploadFeature.State()) {
            OnboardingPortfolioUploadFeature()
        } withDependencies: {
            $0.portfolioFileReader.read = { _ in throw NSError(domain: "test", code: -1) }
        }

        await store.send(.view(.fileSelected(Self.fileURL))) {
            $0.upload = .uploading(fileName: "포트폴리오.pdf", portfolioId: nil)
        }
        await store.receive(\.inner.uploadFailed) {
            $0.upload = .failed(message: OnboardingPortfolioUploadFeature.genericFailureMessage)
        }
    }

    @Test("20MB 초과 파일은 등록 요청 없이 실패 처리한다")
    func oversizedFileFailsWithoutRegister() async {
        let store = TestStore(initialState: OnboardingPortfolioUploadFeature.State()) {
            OnboardingPortfolioUploadFeature()
        } withDependencies: {
            $0.portfolioFileReader.read = { _ in
                PortfolioFile(data: Data(count: OnboardingPortfolioUploadFeature.maxFileSizeBytes + 1))
            }
        }

        await store.send(.view(.fileSelected(Self.fileURL))) {
            $0.upload = .uploading(fileName: "포트폴리오.pdf", portfolioId: nil)
        }
        await store.receive(\.inner.uploadFailed) {
            $0.upload = .failed(message: OnboardingPortfolioUploadFeature.oversizedFileMessage)
        }
    }

    @Test("암호 걸린 PDF 는 등록 요청 없이 실패 처리한다")
    func encryptedFileFailsWithoutRegister() async {
        let store = TestStore(initialState: OnboardingPortfolioUploadFeature.State()) {
            OnboardingPortfolioUploadFeature()
        } withDependencies: {
            $0.portfolioFileReader.read = { _ in
                PortfolioFile(data: Data("pdf".utf8), pageCount: 3, isEncrypted: true)
            }
        }

        await store.send(.view(.fileSelected(Self.fileURL))) {
            $0.upload = .uploading(fileName: "포트폴리오.pdf", portfolioId: nil)
        }
        await store.receive(\.inner.uploadFailed) {
            $0.upload = .failed(message: OnboardingPortfolioUploadFeature.encryptedFileMessage)
        }
    }

    @Test("30페이지 초과 PDF 는 등록 요청 없이 실패 처리한다")
    func tooManyPagesFailsWithoutRegister() async {
        let store = TestStore(initialState: OnboardingPortfolioUploadFeature.State()) {
            OnboardingPortfolioUploadFeature()
        } withDependencies: {
            $0.portfolioFileReader.read = { _ in
                PortfolioFile(data: Data("pdf".utf8), pageCount: OnboardingPortfolioUploadFeature.maxPageCount + 1)
            }
        }

        await store.send(.view(.fileSelected(Self.fileURL))) {
            $0.upload = .uploading(fileName: "포트폴리오.pdf", portfolioId: nil)
        }
        await store.receive(\.inner.uploadFailed) {
            $0.upload = .failed(message: OnboardingPortfolioUploadFeature.pageExceededMessage)
        }
    }

    @Test("업로드 중 X 탭은 삭제 확인 모달만 띄우고 파일은 그대로 둔다")
    func removeDuringUploadAsksForConfirmation() async {
        var initialState = OnboardingPortfolioUploadFeature.State()
        initialState.upload = .uploading(fileName: "포트폴리오.pdf", portfolioId: Self.portfolioId)
        let store = TestStore(initialState: initialState) {
            OnboardingPortfolioUploadFeature()
        }

        // delete 는 unimplemented testValue — 호출되면 테스트가 실패한다(«네» 전엔 안 나가야 한다).
        await store.send(.view(.userTappedRemoveFile)) {
            $0.isDeleteConfirmPresented = true
        }
    }

    @Test("삭제 확인 «아니요» 는 모달만 닫는다")
    func deleteCancelKeepsFile() async {
        var initialState = OnboardingPortfolioUploadFeature.State()
        initialState.upload = .uploaded(fileName: "포트폴리오.pdf", portfolioId: Self.portfolioId)
        initialState.isDeleteConfirmPresented = true
        let store = TestStore(initialState: initialState) {
            OnboardingPortfolioUploadFeature()
        }

        await store.send(.view(.userTappedDeleteCancel)) {
            $0.isDeleteConfirmPresented = false
        }
    }

    @Test("삭제 확인 «네» 는 폴링을 멈추고 등록된 파일을 삭제한다")
    func deleteConfirmCancelsAndDeletes() async {
        let deletedId = LockIsolated<UUID?>(nil)
        var initialState = OnboardingPortfolioUploadFeature.State()
        initialState.upload = .uploading(fileName: "포트폴리오.pdf", portfolioId: Self.portfolioId)
        initialState.isDeleteConfirmPresented = true
        let store = TestStore(initialState: initialState) {
            OnboardingPortfolioUploadFeature()
        } withDependencies: {
            $0.portfolioClient.delete = { id in
                deletedId.setValue(id)
                return PortfolioDeletion(portfolioId: id, deletedAt: nil)
            }
        }

        await store.send(.view(.userTappedDeleteConfirm)) {
            $0.isDeleteConfirmPresented = false
            $0.isDeleting = true
        }
        await store.receive(\.inner.portfolioDeleted) {
            $0.isDeleting = false
            $0.upload = .idle
        }
        #expect(deletedId.value == Self.portfolioId)
    }

    @Test("삭제가 서버에서 실패하면 첨부를 남기고 서버 문구를 안내 줄에 띄운다")
    func deleteFailureKeepsFileAndShowsServerMessage() async {
        var initialState = OnboardingPortfolioUploadFeature.State()
        initialState.upload = .uploaded(fileName: "포트폴리오.pdf", portfolioId: Self.portfolioId)
        initialState.isDeleteConfirmPresented = true
        let store = TestStore(initialState: initialState) {
            OnboardingPortfolioUploadFeature()
        } withDependencies: {
            $0.portfolioClient.delete = { _ in throw PortfolioError.alreadyExists(message: "삭제할 수 없어요") }
        }

        await store.send(.view(.userTappedDeleteConfirm)) {
            $0.isDeleteConfirmPresented = false
            $0.isDeleting = true
        }
        await store.receive(\.inner.portfolioDeleteFailed) {
            $0.isDeleting = false
            $0.deleteErrorMessage = "삭제할 수 없어요"
        }
        // 첨부는 그대로 — 계속하기도 살아 있다(서버 파일이 남았으니 그 판이 진실이다).
        #expect(store.state.upload == .uploaded(fileName: "포트폴리오.pdf", portfolioId: Self.portfolioId))
        #expect(store.state.errorMessage == "삭제할 수 없어요")
    }

    @Test("서버에 이미 없는(404) 포폴 삭제는 성공으로 닫는다")
    func deleteTreatsNotFoundAsDeleted() async {
        var initialState = OnboardingPortfolioUploadFeature.State()
        initialState.upload = .uploaded(fileName: "포트폴리오.pdf", portfolioId: Self.portfolioId)
        let store = TestStore(initialState: initialState) {
            OnboardingPortfolioUploadFeature()
        } withDependencies: {
            $0.portfolioClient.delete = { _ in throw PortfolioError.notFound(message: "없는 포트폴리오예요") }
            $0.portfolioClient.list = { PortfolioList(portfolios: [], deleteAvailable: true) }
        }

        await store.send(.view(.userTappedDeleteConfirm)) {
            $0.isDeleting = true
        }
        await store.receive(\.inner.portfolioDeleted) {
            $0.isDeleting = false
            $0.availability.deleteAvailable = false
            $0.upload = .idle
        }
        // READY 삭제 뒤엔 가용성을 서버 값으로 다시 맞춘다 — 404 라 기회를 안 썼으면 서버가 true 로 되돌려 준다.
        await store.receive(\.inner.availabilityLoaded) {
            $0.availability.deleteAvailable = true
        }
    }

    @Test("삭제 응답 전 X 재탭은 무시된다")
    func removeIsIgnoredWhileDeleting() async {
        var initialState = OnboardingPortfolioUploadFeature.State()
        initialState.upload = .uploaded(fileName: "포트폴리오.pdf", portfolioId: Self.portfolioId)
        initialState.isDeleting = true
        let store = TestStore(initialState: initialState) {
            OnboardingPortfolioUploadFeature()
        }

        await store.send(.view(.userTappedRemoveFile))
    }

    @Test("계속하기는 업로드 완료 전엔 무시된다")
    func continueIsIgnoredUntilUploaded() async {
        let store = TestStore(initialState: OnboardingPortfolioUploadFeature.State()) {
            OnboardingPortfolioUploadFeature()
        }

        #expect(!store.state.isContinueEnabled)
        await store.send(.view(.userTappedContinue))
    }

    @Test("계속하기는 업로드 완료 상태의 portfolioId 를 delegate 로 올린다")
    func continueEmitsPortfolioIdWhenUploaded() async {
        var initialState = OnboardingPortfolioUploadFeature.State()
        initialState.upload = .uploaded(fileName: "포트폴리오.pdf", portfolioId: Self.portfolioId)
        let store = TestStore(initialState: initialState) {
            OnboardingPortfolioUploadFeature()
        }

        #expect(store.state.isContinueEnabled)
        await store.send(.view(.userTappedContinue))
        await store.receive(\.delegate.continueRequested)   // (portfolioId, fileName) — 완료 상태에서 파생
    }

    @Test("이전으로 탭은 delegate 로 코디네이터에 위임한다")
    func backDelegatesToCoordinator() async {
        let store = TestStore(initialState: OnboardingPortfolioUploadFeature.State()) {
            OnboardingPortfolioUploadFeature()
        }

        await store.send(.view(.userTappedBack))
        await store.receive(\.delegate.backRequested)
    }

    @Test("닫기 탭은 delegate 로 코디네이터에 위임한다")
    func closeDelegatesToCoordinator() async {
        let store = TestStore(initialState: OnboardingPortfolioUploadFeature.State()) {
            OnboardingPortfolioUploadFeature()
        }

        await store.send(.view(.userTappedClose))
        await store.receive(\.delegate.closeRequested)
    }

    // MARK: - 기존 포트폴리오 (2회차 이상)

    @Test("진입 조회가 READY 포폴을 찾으면 확인 모달을 띄운다")
    func onAppearFindsExistingReadyPortfolio() async {
        let store = TestStore(
            initialState: OnboardingPortfolioUploadFeature.State(checksExisting: true)
        ) {
            OnboardingPortfolioUploadFeature()
        } withDependencies: {
            $0.portfolioClient.list = { PortfolioList(portfolios: [Self.readyPortfolio]) }
        }

        await store.send(.view(.onAppear)) {
            $0.checksExisting = false
            $0.hasRequestedAvailability = true
        }
        await store.receive(\.inner.availabilityLoaded)
        await store.receive(\.inner.existingPortfolioFound) {
            $0.existingPortfolio = .init(portfolioId: Self.portfolioId, fileName: "포트폴리오.pdf")
        }
    }

    @Test("READY 가 아닌 포폴만 있으면 모달 없이 빈 판 그대로다")
    func onAppearIgnoresNonReadyPortfolio() async {
        let processing = Portfolio(
            portfolioId: Self.portfolioId,
            fileName: "포트폴리오.pdf",
            fileSize: nil,
            pageCount: nil,
            status: .processing,
            uploadedAt: nil
        )
        let store = TestStore(
            initialState: OnboardingPortfolioUploadFeature.State(checksExisting: true)
        ) {
            OnboardingPortfolioUploadFeature()
        } withDependencies: {
            $0.portfolioClient.list = { PortfolioList(portfolios: [processing]) }
        }

        await store.send(.view(.onAppear)) {
            $0.checksExisting = false
            $0.hasRequestedAvailability = true
        }
        await store.receive(\.inner.availabilityLoaded)
    }

    @Test("조회가 꺼져 있으면 onAppear 는 기존 포폴 모달 없이 가용성만 한 번 받는다")
    func onAppearSkipsWhenCheckDisabled() async {
        let store = TestStore(initialState: OnboardingPortfolioUploadFeature.State()) {
            OnboardingPortfolioUploadFeature()
        } withDependencies: {
            $0.portfolioClient.list = {
                PortfolioList(portfolios: [Self.readyPortfolio], replaceAvailable: false)
            }
        }

        await store.send(.view(.onAppear)) {
            $0.hasRequestedAvailability = true
        }
        await store.receive(\.inner.availabilityLoaded) {
            $0.availability.replaceAvailable = false
        }
        // 두 번째 onAppear 는 다시 묻지 않는다.
        await store.send(.view(.onAppear))
    }

    @Test("확인 모달 두 버튼(«취소»/«진행할게요») 은 기존 포폴을 완료 상태로 앉힌다")
    func useExistingMovesToUploaded() async {
        var initialState = OnboardingPortfolioUploadFeature.State()
        initialState.existingPortfolio = .init(portfolioId: Self.portfolioId, fileName: "포트폴리오.pdf")
        let store = TestStore(initialState: initialState) {
            OnboardingPortfolioUploadFeature()
        }

        await store.send(.view(.userTappedUseExisting)) {
            $0.existingPortfolio = nil
            $0.upload = .uploaded(fileName: "포트폴리오.pdf", portfolioId: Self.portfolioId)
        }
    }

    private static let readyPortfolio = Portfolio(
        portfolioId: portfolioId,
        fileName: "포트폴리오.pdf",
        fileSize: nil,
        pageCount: nil,
        status: .ready,
        uploadedAt: nil
    )
}
