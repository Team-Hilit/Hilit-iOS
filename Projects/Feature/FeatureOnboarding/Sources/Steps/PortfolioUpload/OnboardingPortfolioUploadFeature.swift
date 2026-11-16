//
//  OnboardingPortfolioUploadFeature.swift
//  FeatureOnboarding
//
//  Created by EunSeo on 26/07/19.
//

import ComposableArchitecture
import DomainPortfolioInterface
import Foundation

// Figma «Onboarding_PortfolioUpload» https://figma.com/design/JL9YPbqBqmaC9Z0I3SzDZS/?node-id=443-9568
//        대기 443:9568 · 실패 443:9624 · 업로드 중 443:9662 (완료 프레임은 시안에 없다 — View 주석 참조)
// @lat: [[onboarding#포트폴리오 업로드]]
/// 온보딩 STEP 2/3 — 포트폴리오 업로드. PDF 1개(20MB 이하)를 골라 서버에 등록하고,
/// PROCESSING 폴링이 READY 가 될 때까지 기다린다. 대기/업로드 중/실패/완료는
/// 별도 화면 push 없이 `UploadState` 하위 상태로만 전환한다.
/// 완료 결과는 delegate(.continueRequested(portfolioId:))로 코디네이터에 올린다.
@Reducer
public struct OnboardingPortfolioUploadFeature {
    /// 서버에 이미 등록돼 있어 그대로 쓸 수 있는 포트폴리오 — 확인 모달이 쓰는 최소 값.
    public struct ExistingPortfolio: Equatable, Sendable {
        public let portfolioId: UUID
        public let fileName: String

        public init(portfolioId: UUID, fileName: String) {
            self.portfolioId = portfolioId
            self.fileName = fileName
        }
    }

    /// 이 화면의 모달 표출 자리 — 한 번에 하나만 뜬다.
    /// `.hilitModal` 이 cover 표출이라(#63) 한 화면에 두 번 붙이면 둘째가 조용히 무시된다 — 표출 자리를
    /// 하나로 좁히고 무엇을 띄울지는 `State.presentedModal` 이 정한다.
    public enum PresentedModal: Equatable, Sendable {
        case existingPortfolio(ExistingPortfolio)
        case deleteConfirm
        /// 한 달 1회 규칙 차단 — 삭제 한도·교체 한도. 날짜는 카드가 `State.availability` 에서 읽는다.
        case quotaBlocked(QuotaBlock)
    }

    /// 한 달 1회 규칙(HLT-34)에 막힌 동작 — 서버 계정 단위 가용성 두 축 그대로다.
    public enum QuotaBlock: Equatable, Sendable {
        /// READY 포폴 삭제 기회 소진 (`deleteAvailable == false` · 서버 `DELETE_LIMIT_EXCEEDED`).
        case delete
        /// 삭제 기회는 있지만 교체 기회가 없다 — 지우면 다시 못 올려 필수 스텝에 갇히니 READY 삭제를 막는다.
        case deleteWithoutReupload
        /// 재업로드(교체) 기회 소진 (`replaceAvailable == false` · 서버 `REPLACEMENT_LIMIT_EXCEEDED`).
        case replace
    }

    /// 업로드 진행 하위 상태 — 화면 전환 없이 리스트 영역 렌더만 바꾼다.
    public enum UploadState: Equatable, Sendable {
        /// 대기 — 아직 첨부된 파일 없음 (`FileUpload(.empty)` 점선 판).
        case idle
        /// 업로드·서버 처리 중 — register 접수 전이면 portfolioId 는 nil (`FileUpload(.progressing)`).
        case uploading(fileName: String, portfolioId: UUID?)
        /// 실패 — `InfoField(.error)` 안내 줄 + 빈 점선 판 (Figma 443:9624).
        case failed(message: String)
        /// 완료 — 파일 행 표시, 계속하기 활성.
        case uploaded(fileName: String, portfolioId: UUID)

        /// 업로드·폴링 진행 중 — 이 동안만 스와이프백을 막는다(이탈 = 폴링·서버 파일 버림).
        public var isUploading: Bool {
            if case .uploading = self { true } else { false }
        }

        /// 완료 — 파일 선택 진입 판을 걷는 조건. 2회차 서버 포폴 불러오기도 같은 상태다.
        public var isUploaded: Bool {
            if case .uploaded = self { true } else { false }
        }

        /// `FileUpload(.progressing)` 진행 바 비율(0~1) — **측정된 진행률이 아니라 단계 마커**다.
        /// `.uploading` 이 구분할 수 있는 단계는 둘뿐이라 값도 둘이다: register 응답 전
        /// (portfolioId == nil) `registeringProgress`, 접수돼 status 폴링 중(portfolioId != nil)
        /// `pollingProgress`. 그 사이를 한 번 건너뛰고 폴링이 끝날 때까지 그 자리에 머문다.
        /// 완료 판은 `FileUpload(.completed)` 가 스스로 꽉 채우므로 여기서 1.0 이 되는 경로는 없고,
        /// 진행 바를 그리지 않는 하위 상태는 0 이다.
        ///
        /// TODO: 실측 진행률은 업로드 progress 이벤트나 서버가 주는 처리 퍼센트가 있어야 가능하다 —
        /// 지금은 둘 다 없다(register 는 단일 호출, status 는 상태 enum 만 준다). 생기면 이 값을 갈아끼운다.
        public var phaseProgress: Double {
            guard case let .uploading(_, portfolioId) = self else { return 0 }
            return portfolioId == nil ? Self.registeringProgress : Self.pollingProgress
        }

        /// register 요청이 떠 있는 동안의 채움 — 0 이 아니라 «시작은 됐다» 로 읽히게 한다.
        static let registeringProgress: Double = 0.3
        /// 접수 후 status 폴링 구간의 채움 — 한 칸 나아갔지만 아직 안 끝났음을 보인다.
        static let pollingProgress: Double = 0.7
    }

    @ObservableState
    public struct State: Equatable {
        /// 프로그레스 바 분모 — 온보딩 전체 단계 수.
        public let totalSteps: Int
        /// 프로그레스 바 분자 — 이 화면의 단계(1-based).
        public let step: Int
        /// 업로드 하위 상태.
        public var upload: UploadState
        /// 파일 선택 시트(fileImporter) 표시 여부 — View binding 으로 닫힘까지 동기화된다.
        public var isFileImporterPresented = false
        /// 삭제 확인 모달 표시 여부 — 파일 행 X 가 켜고, «네»/«아니요» 가 끈다.
        /// 삭제 API 는 «네» 에서만 나간다(X 만으로는 서버 파일이 그대로다).
        public var isDeleteConfirmPresented = false
        /// delete 요청이 떠 있는 동안 — 응답 전까지 X 재탭을 막는다(같은 id 로 두 번 나가지 않게).
        public var isDeleting = false
        /// 삭제 실패 안내 줄 문구 — 첨부는 그대로 두고 이 줄만 띄운다. 성공·재시도에 비운다.
        public var deleteErrorMessage: String?
        /// 진입 시 서버에 등록된 포트폴리오를 조회할지 — 코디네이터가 **빈 판으로 세우는 진입마다** 켠다
        /// (서버 READY 는 위저드 밖에서도 바뀐다 — [[onboarding#포트폴리오 업로드]]).
        /// 켜진 채 `onAppear` 를 한 번 받으면 스스로 끈다(뷰 `onAppear` 는 여러 번 온다).
        var checksExisting: Bool
        /// 조회로 찾은 기존 READY 포트폴리오 — 확인 모달이 떠 있는 동안만 들고 있다.
        /// nil 이 곧 «모달 없음» 이다(별도 표시 플래그를 두면 둘이 어긋난다).
        var existingPortfolio: ExistingPortfolio?
        /// 계정 단위 교체·삭제 가용성(서버 목록 값) — 진입 조회·거절 뒤 재조회가 채운다. 모르면 막지 않는다.
        public var availability = PortfolioAvailability()
        /// 한 달 1회 규칙 차단 모달 — 삭제·업로드 진입에서 켜고 «확인» 이 끈다.
        public var quotaBlock: QuotaBlock?
        /// 가용성 조회를 이미 보냈는지 — `onAppear` 는 여러 번 오므로 화면 수명당 한 번만 묻는다.
        var hasRequestedAvailability = false
        /// 이번 업로드의 status 폴링 횟수 — `maxPollAttempts` 에 닿으면 실패로 끊는다(HLT-35). 새 파일마다 0.
        var pollAttempts = 0

        public var isContinueEnabled: Bool { upload.isUploaded }

        /// 안내 줄(`InfoField(.error)`)에 띄울 문구 — 업로드 실패가 먼저다.
        /// 둘이 겹칠 일은 없다: `failed` 는 첨부가 없는 판이라 삭제를 부를 X 자체가 없다.
        public var errorMessage: String? {
            if case let .failed(message) = upload { return message }
            return deleteErrorMessage
        }

        /// 지금 띄울 모달 — 표출 자리가 하나뿐이라 우선순위를 여기서 정한다.
        /// 기존 포폴 확인이 먼저다: 진입 직후 뜨고, 그 판엔 삭제를 부를 파일 행 X 가 아직 없다.
        public var presentedModal: PresentedModal? {
            if let existingPortfolio { return .existingPortfolio(existingPortfolio) }
            if isDeleteConfirmPresented { return .deleteConfirm }
            if let quotaBlock { return .quotaBlocked(quotaBlock) }
            return nil
        }

        /// 기존 포폴을 이번 달엔 바꿀 수 없다 — 지우면(삭제 한도) 또는 지운 뒤 다시 올리면(교체 한도) 막힌다.
        /// 기존 포폴 확인 모달이 이걸 보고 «그대로 사용» 안내줄을 붙인다.
        public var isPortfolioChangeLocked: Bool {
            !availability.deleteAvailable || !availability.replaceAvailable
        }

        public init(
            step: Int = 2,
            totalSteps: Int = 3,
            upload: UploadState = .idle,
            checksExisting: Bool = false
        ) {
            self.step = step
            self.totalSteps = totalSteps
            self.upload = upload
            self.checksExisting = checksExisting
        }
    }

    public enum Action: ViewAction {
        case view(View)
        case inner(Inner)
        case delegate(Delegate)

        /// 사용자 입력·생명주기. View 의 send(...) 로만 방출된다.
        /// fileImporter 표시 바인딩을 위해 BindableAction 채택 (BindingReducer(action: \.view)).
        @CasePathable
        public enum View: BindableAction, Equatable, Sendable {
            case binding(BindingAction<State>)
            /// 진입 — 위저드 수명당 1회 기존 포트폴리오를 조회한다(`checksExisting`).
            case onAppear
            case userTappedClose
            case userTappedBack
            case userTappedContinue
            case userTappedUploadCard
            /// 파일 행 X — 바로 지우지 않고 삭제 확인 모달을 띄운다.
            case userTappedRemoveFile
            /// 삭제 확인 모달 «네» — 여기서만 폴링 취소 + delete API.
            case userTappedDeleteConfirm
            /// 삭제 확인 모달 «아니요» — 모달만 닫고 파일은 그대로 둔다.
            case userTappedDeleteCancel
            /// 한 달 1회 차단 모달 «확인» — 모달만 닫는다.
            case userTappedQuotaBlockDismiss
            /// 기존 포트폴리오 확인 모달 «취소»/«진행할게요» — 그 포폴을 완료 상태로 앉힌다.
            /// 두 버튼이 같은 액션인 건 결과가 하나뿐이기 때문이다(View 주석 참조).
            case userTappedUseExisting
            /// fileImporter 선택 완료 — security-scoped URL.
            case fileSelected(URL)
            /// fileImporter 자체 실패 (파일 접근 불가 등).
            case fileSelectionFailed
        }

        /// effect 결과·리듀서 내부 신호. 리듀서만 방출한다.
        @CasePathable
        public enum Inner: Equatable, Sendable {
            /// 목록 조회의 계정 단위 가용성 — 진입 조회·한도 거절 뒤 재조회가 보낸다.
            case availabilityLoaded(PortfolioAvailability)
            /// 서버가 한 달 1회 규칙으로 거절했다(`DELETE_LIMIT_EXCEEDED`·`REPLACEMENT_LIMIT_EXCEEDED`) — 차단 모달.
            case quotaRejected(QuotaBlock)
            /// 상한으로 끊은 뒤 정리 직전 확인에서 READY 였다 — 실패 판을 완료 판으로 되돌린다.
            case timedOutUploadBecameReady(fileName: String, portfolioId: UUID)
            /// POST /portfolios 접수 응답 (202 PROCESSING — 드물게 즉시 READY/FAILED).
            case uploadAccepted(PortfolioProcessing)
            /// GET /portfolios/{id}/status 폴링 응답.
            case statusPolled(PortfolioProcessing)
            /// 파일 읽기·용량 초과·네트워크 등 클라이언트 측 실패.
            case uploadFailed(message: String)
            /// 진입 조회에서 READY 포트폴리오를 찾았다 — 확인 모달을 띄운다.
            /// 없거나 조회 실패면 이 액션 자체가 오지 않는다(빈 판 그대로 = 기존 흐름).
            case existingPortfolioFound(ExistingPortfolio)
            /// DELETE 성공(404 = 서버에 이미 없음 포함) — 이때서야 판을 비운다.
            case portfolioDeleted
            /// DELETE 실패 — 첨부는 남기고 안내 줄만 띄운다.
            case portfolioDeleteFailed(message: String)
        }

        /// 코디네이터(OnboardingFeature) 통보. 부모는 이것만 매칭한다 (D1).
        @CasePathable
        public enum Delegate: Equatable, Sendable {
            /// 업로드 완료 — 다음 스텝으로. portfolioId 는 서버 등록 결과, fileName 은 draft 복원용.
            case continueRequested(portfolioId: UUID, fileName: String)
            /// 하단 «이전으로» — 코디네이터가 스택을 pop.
            case backRequested
            /// 온보딩 이탈(X) 요청 — dismiss 는 코디네이터 몫.
            case closeRequested
        }
    }

    /// FAILED_FILE 기본 문구 — 서버 message 가 있으면 그것을 우선한다.
    /// 시안(443:9641)의 안내 줄은 «서버에러메세지» 주석이 붙은 자리표시라 문구를 고정하지 않는다.
    static let unreadableFileMessage = "이 PDF에서 글자를 읽지 못했어요.\n글자가 드래그로 선택되는 PDF로 다시 올려주세요."
    /// 파일 읽기·네트워크 등 일반 실패 문구 — 디자인 미정, 임시.
    static let genericFailureMessage = "업로드에 실패했어요.\n잠시 후 다시 시도해 주세요."
    /// 삭제 실패 폴백 문구 — 서버 message 가 있으면 그것을 우선한다(시안 443:9641 «서버에러메세지»).
    static let deleteFailureMessage = "포트폴리오를 삭제하지 못했어요.\n잠시 후 다시 시도해 주세요."
    /// 용량 초과 문구 — 디자인 미정, 임시 (서버 FILE_TOO_LARGE 와 동일 조건).
    static let oversizedFileMessage = "20MB 이하의 PDF 파일만 업로드할 수 있어요."
    /// 페이지 초과 문구 — PRD S2 확정 (서버 PAGE_COUNT_EXCEEDED 와 동일 조건).
    static let pageExceededMessage = "페이지가 너무 많아요.\n30페이지 이하 PDF로 올려주세요."
    /// 암호 PDF 문구 — PRD S2 확정 (열기 암호 걸린 PDF 는 파싱 불가).
    static let encryptedFileMessage = "암호가 걸린 PDF는 열 수 없어요.\n암호를 푼 PDF로 올려주세요."
    /// 서버 목록이 파일명을 안 줄 때의 표시명 — 완료 판은 이름 없이 그릴 수 없다(원본 확장자 추정도 못 한다).
    static let unnamedPortfolioFileName = "포트폴리오"
    /// 업로드 상한 20MB — Figma 443:9584 «1개 파일, 최대 20Mb까지 가능합니다» · 서버 검증 FILE_TOO_LARGE.
    static let maxFileSizeBytes = 20 * 1024 * 1024
    /// 페이지 상한 30p — PRD S2 · 서버 검증 PAGE_COUNT_EXCEEDED. 클라 선검증(서버 실측 재검증).
    static let maxPageCount = 30
    /// 처리 상태 폴링 주기 — PortfolioClient 가이드(3~5초)의 하한.
    static let pollInterval: Duration = .seconds(3)
    /// 폴링 상한 — 3초 × 40회 = 120초(PRD §3.4 · Android `MAX_POLL_ATTEMPTS` 와 같은 값, HLT-35).
    /// 넘으면 실패 판으로 끊는다 — 판이 `Processing...` 에 영영 멈추지 않게. 마이페이지 폴링 상한은 #145 몫.
    static let maxPollAttempts = 40

    private enum CancelID { case upload }

    @Dependency(\.portfolioClient) var portfolioClient
    @Dependency(\.portfolioFileReader) var fileReader
    @Dependency(\.continuousClock) var clock

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer(action: \.view)

        Reduce { state, action in
            switch action {
            case let .view(action):
                return reduceView(&state, action)
            case let .inner(action):
                return reduceInner(&state, action)
            case .delegate:
                return .none
            }
        }
    }

    private func reduceView(_ state: inout State, _ action: Action.View) -> Effect<Action> {
        switch action {
        case .binding:
            return .none

        // 2회차 이상(= 재사용할 READY 포폴 보유 — docs/work/home-account.md §3 «회차 분기 판정 키») 진입.
        // 빈 판 진입마다 켜지고(서버 READY 는 위저드 밖에서 바뀐다), 이미 첨부된 판(복원 포함)에는
        // 끼어들지 않는다. 조회는 진입당 1회 — 이 자리에서 플래그를 끈다.
        case .onAppear:
            // 가용성은 진입 판과 무관하게 한 번은 받는다 — draft 로 복원된 완료 판도 X 게이트가 서버 값을 봐야 한다
            // (교체 소진 계정이 READY 를 지우면 서버는 막지 않고, 다시 못 올려 필수 스텝에 갇힌다).
            guard state.checksExisting, case .idle = state.upload else {
                guard !state.hasRequestedAvailability else { return .none }
                state.hasRequestedAvailability = true
                return refreshAvailability()
            }
            state.checksExisting = false
            state.hasRequestedAvailability = true
            return .run { send in
                // 실패·부재는 조용히 넘긴다 — 못 찾으면 그냥 평소의 빈 판이라 알릴 게 없다(가용성도 «모름» = 막지 않음).
                guard let list = try? await portfolioClient.list() else { return }
                // 가용성 먼저 — 기존 포폴 모달이 뜰 때 이미 «바꿀 수 없음» 여부를 알고 있어야 한다.
                await send(.inner(.availabilityLoaded(list.availability)))
                guard let existing = list.portfolios.first(where: { $0.status == .ready }) else { return }
                await send(.inner(.existingPortfolioFound(ExistingPortfolio(
                    portfolioId: existing.portfolioId,
                    fileName: existing.fileName ?? Self.unnamedPortfolioFileName
                ))))
            }

        case .userTappedUseExisting:
            guard let existing = state.existingPortfolio else { return .none }
            state.existingPortfolio = nil
            // 방금 서버에서 READY 를 확인한 건이라 재등록·폴링 없이 곧장 완료 판이다.
            state.upload = .uploaded(fileName: existing.fileName, portfolioId: existing.portfolioId)
            return .none

        case .userTappedClose:
            return .send(.delegate(.closeRequested))

        case .userTappedBack:
            return .send(.delegate(.backRequested))

        case .userTappedContinue:
            guard case let .uploaded(fileName, portfolioId) = state.upload else { return .none }
            return .send(.delegate(.continueRequested(portfolioId: portfolioId, fileName: fileName)))

        case .userTappedUploadCard:
            // 계정당 1개 제한(PORTFOLIO_ALREADY_EXISTS) — 업로드 중·완료엔 재선택을 막는다.
            // 교체는 파일 행의 X 로 제거한 뒤 다시 업로드하는 UX.
            switch state.upload {
            case .idle, .failed:
                // 이번 달 교체 기회를 썼으면 피커를 열지 않고 차단 모달(HLT-34 · 마이페이지 HLT-113 과 같은 규칙).
                // 가용성은 계정 단위라 빈 판이어도 막힌다 — 판이 비어 있는 건 이번 달 이미 바꿨다는 뜻일 수 있다.
                guard state.availability.replaceAvailable else {
                    state.quotaBlock = .replace
                    return .none
                }
                state.isFileImporterPresented = true
                return .none
            case .uploading, .uploaded:
                return .none
            }

        case let .fileSelected(url):
            let fileName = url.lastPathComponent
            state.deleteErrorMessage = nil
            state.pollAttempts = 0
            state.upload = .uploading(fileName: fileName, portfolioId: nil)
            return register(url: url, fileName: fileName)

        case .fileSelectionFailed:
            state.upload = .failed(message: Self.genericFailureMessage)
            return .none

        // 파일 행 X·삭제 확인·한 달 1회 차단 모달 — 삭제 동선 한 덩어리라 한 함수에서 읽는다.
        case .userTappedRemoveFile, .userTappedDeleteConfirm, .userTappedDeleteCancel, .userTappedQuotaBlockDismiss:
            return reduceRemoval(&state, action)
        }
    }

    private func reduceInner(_ state: inout State, _ action: Action.Inner) -> Effect<Action> {
        switch action {
        case .uploadAccepted(let processing), .statusPolled(let processing):
            return applyProcessing(&state, processing)

        case let .uploadFailed(message):
            state.upload = .failed(message: message)
            return .none

        case let .existingPortfolioFound(existing):
            state.existingPortfolio = existing
            return .none

        case let .timedOutUploadBecameReady(fileName, portfolioId):
            // 그 사이 사용자가 새 파일을 골랐으면(업로드 중·완료 판) 끼어들지 않는다.
            guard case .failed = state.upload else { return .none }
            state.upload = .uploaded(fileName: fileName, portfolioId: portfolioId)
            return .none

        case let .availabilityLoaded(availability):
            state.availability = availability
            return .none

        case let .quotaRejected(block):
            // 목록 값이 낡았던 것 — 거절 사실을 바로 반영하고 다시 가능한 날짜는 재조회로 채운다.
            state.isDeleting = false
            switch block {
            case .delete:
                state.availability.deleteAvailable = false
                state.quotaBlock = block
                // 업로드 중 «네» 가 폴링을 끊었는데 그 사이 READY 가 돼 삭제가 거절된 경우 — 폴링을 다시 잇는다
                // (안 이으면 `Processing...` 에 멈춘다 — `portfolioDeleteFailed` 와 같은 처리).
                if case let .uploading(_, portfolioId?) = state.upload {
                    return .merge(refreshAvailability(), pollStatus(portfolioId))
                }
                return refreshAvailability()
            case .deleteWithoutReupload:
                break
            case .replace:
                state.availability.replaceAvailable = false
                // 등록 거절 — 첨부 없는 빈 판으로 되돌린다(실패 판 문구 대신 모달이 사유를 말한다).
                if state.upload.isUploading { state.upload = .idle }
            }
            state.quotaBlock = block
            return refreshAvailability()

        case .portfolioDeleted:
            state.isDeleting = false
            state.deleteErrorMessage = nil
            // READY 삭제는 이번 달 삭제 기회를 쓴다(서버 스키마) — 같은 화면에서 또 지우려 하면 미리 막고,
            // 다시 가능한 날짜는 재조회로 채운다(업로드 중 취소는 기회와 무관이라 그대로).
            guard state.upload.isUploaded else {
                state.upload = .idle
                return .none
            }
            state.availability.deleteAvailable = false
            state.upload = .idle
            return refreshAvailability()

        case let .portfolioDeleteFailed(message):
            state.isDeleting = false
            state.deleteErrorMessage = message
            // 업로드 중이던 건이면 «네» 에서 폴링을 이미 끊었다 — 서버 파일이 남았으니 폴링을 다시 잇는다
            // (안 이으면 판이 Processing... 에 멈춘 채 READY 로 못 넘어간다).
            guard case let .uploading(_, portfolioId) = state.upload, let portfolioId else { return .none }
            return pollStatus(portfolioId)
        }
    }
}

// MARK: - 효과·헬퍼 (타입 본문 길이 한도 — 리듀서 본문 밖으로 뺀다)

extension OnboardingPortfolioUploadFeature {
    /// 삭제 동선 — 파일 행 X → (한 달 1회 게이트) → 확인 모달 → delete. 나머지 View 액션은 reduceView 몫.
    private func reduceRemoval(_ state: inout State, _ action: Action.View) -> Effect<Action> {
        switch action {
        case .userTappedRemoveFile:
            // 첨부된 파일이 있을 때만 확인 모달 — 삭제는 «네» 를 받고서 한다.
            guard !state.isDeleting else { return .none }
            switch state.upload {
            case .uploading:
                // 업로드 중 취소는 한 달 1회 기회를 쓰지 않는다(서버 스키마) — 게이트 없이 확인만.
                state.isDeleteConfirmPresented = true
                return .none
            case .uploaded:
                // READY 삭제는 한 달 1회 규칙에 걸린다(HLT-34). 지울 수는 있어도 다시 못 올리면 위저드가
                // 필수 스텝에서 막히므로 교체 한도도 같이 본다 — 둘 중 하나라도 소진이면 그 사유로 막는다.
                if !state.availability.deleteAvailable {
                    state.quotaBlock = .delete
                } else if !state.availability.replaceAvailable {
                    state.quotaBlock = .deleteWithoutReupload
                } else {
                    state.isDeleteConfirmPresented = true
                }
                return .none
            case .idle, .failed:
                return .none
            }

        case .userTappedDeleteConfirm:
            state.isDeleteConfirmPresented = false
            state.deleteErrorMessage = nil
            switch state.upload {
            case let .uploading(_, portfolioId):
                // register 접수 전이면 서버에 지울 게 없다 — 폴링만 끊고 빈 판으로.
                guard let portfolioId else {
                    state.upload = .idle
                    return .cancel(id: CancelID.upload)
                }
                state.isDeleting = true
                return .merge(.cancel(id: CancelID.upload), delete(portfolioId))
            case let .uploaded(_, portfolioId):
                state.isDeleting = true
                return delete(portfolioId)
            case .idle, .failed:
                return .none
            }

        case .userTappedDeleteCancel:
            state.isDeleteConfirmPresented = false
            return .none

        case .userTappedQuotaBlockDismiss:
            state.quotaBlock = nil
            return .none

        case .binding, .fileSelected, .fileSelectionFailed, .onAppear, .userTappedBack, .userTappedClose,
             .userTappedContinue, .userTappedUploadCard, .userTappedUseExisting:
            return .none
        }
    }

    /// 고른 PDF 등록 — 클라 선검증 → register. 교체 한도 거절(HLT-34)은 실패 판 대신 차단 모달로 보낸다.
    private func register(url: URL, fileName: String) -> Effect<Action> {
        .run { send in
            // 클라 선검증 = UX 용 빠른 차단. 최종 판정은 서버 실측 재검증(글자 수·암호 최종 판별은 서버).
            let file = try await fileReader.read(url)
            guard file.data.count <= Self.maxFileSizeBytes else {
                await send(.inner(.uploadFailed(message: Self.oversizedFileMessage)))
                return
            }
            guard !file.isEncrypted else {
                await send(.inner(.uploadFailed(message: Self.encryptedFileMessage)))
                return
            }
            if let pageCount = file.pageCount, pageCount > Self.maxPageCount {
                await send(.inner(.uploadFailed(message: Self.pageExceededMessage)))
                return
            }
            let upload = PortfolioUpload(
                fileName: fileName,
                fileSize: file.data.count,
                pageCount: file.pageCount,
                data: file.data
            )
            await send(.inner(.uploadAccepted(try await portfolioClient.register(upload))))
        } catch: { error, send in
            if case .replacementLimitExceeded? = error as? PortfolioError {
                await send(.inner(.quotaRejected(.replace)))
            } else {
                await send(.inner(.uploadFailed(message: Self.failureMessage(for: error))))
            }
        }
        .cancellable(id: CancelID.upload, cancelInFlight: true)
    }

    /// 등록·폴링 공통 응답 반영 — PROCESSING 이면 폴링을 잇고, READY/FAILED 면 하위 상태를 확정한다.
    private func applyProcessing(_ state: inout State, _ processing: PortfolioProcessing) -> Effect<Action> {
        // X(제거) 등으로 업로드 흐름이 이미 끊겼으면 늦게 도착한 응답을 무시한다.
        guard case let .uploading(fileName, _) = state.upload else { return .none }

        switch processing.status {
        case .processing:
            // 상한(HLT-35) — 넘으면 실패 판으로 끊어 판이 멈춘 채 남지 않게 한다. 실패 판은 스와이프백·재선택이
            // 다시 열리는 판이라 화면 이탈 출구도 같이 돌아온다(X·«이전으로» 는 업로드 중에도 열려 있다).
            guard state.pollAttempts < Self.maxPollAttempts else {
                state.upload = .failed(message: Self.genericFailureMessage)
                return abandonTimedOutUpload(processing.portfolioId, fileName: fileName)
            }
            state.pollAttempts += 1
            state.upload = .uploading(fileName: fileName, portfolioId: processing.portfolioId)
            return pollStatus(processing.portfolioId)

        case .ready:
            state.upload = .uploaded(fileName: fileName, portfolioId: processing.portfolioId)
            return .none

        // TODO: 200 + FAILED_* 문구 정책 PRD 미정 — 서버 message 우선, 없을 때만 클라 문구. 확정되면 재확인.
        case .failedFile:
            state.upload = .failed(message: processing.message ?? Self.unreadableFileMessage)
            return .none

        case .failedSystem:
            state.upload = .failed(message: processing.message ?? Self.genericFailureMessage)
            return .none

        // CANCELLED 는 마이페이지 삭제 계열 상태라 온보딩 업로드 폴링엔 오지 않는다 — 와도 진행 불가라 실패로 닫는다.
        case .cancelled:
            state.upload = .failed(message: processing.message ?? Self.genericFailureMessage)
            return .none
        }
    }

    /// 업로드·폴링 실패 문구 — 서버 4xx 는 원문 message 를 그대로 싣는다.
    /// TODO: 서버 문구 그대로 노출은 임시 규칙(ServerError.alertMessage 와 같은 계). 코드별 클라 카피 확정 시 교체.
    /// TODO: PORTFOLIO_ALREADY_EXISTS 복구 — 1개 제한의 주 방어선은 진입 시 사전 확인 모달이고(자동 교체 금지는 그대로),
    ///       그게 못 막는 창구(PROCESSING 포폴·조회 경합·draft 복원)로 들어온 409 만 아직 배너 문구뿐이다.
    static func failureMessage(for error: any Error) -> String {
        (error as? PortfolioError)?.userMessage ?? genericFailureMessage
    }

    /// 처리 상태 폴링 한 바퀴 — 한 주기 쉬고 status 를 물어 `statusPolled` 로 되돌린다.
    private func pollStatus(_ portfolioId: UUID) -> Effect<Action> {
        .run { send in
            try await clock.sleep(for: Self.pollInterval)
            await send(.inner(.statusPolled(try await portfolioClient.status(portfolioId))))
        } catch: { error, send in
            await send(.inner(.uploadFailed(message: Self.failureMessage(for: error))))
        }
        .cancellable(id: CancelID.upload, cancelInFlight: true)
    }

    /// 상한을 넘긴 PROCESSING 포폴 정리 — 서버에 남겨 두면 다음 업로드가 `PORTFOLIO_UPLOAD_IN_PROGRESS`(409)로 막힌다.
    /// 지우기 전에 상태를 한 번 더 본다 — 그 사이 READY 가 됐으면 지우지 않고 완료 판으로 받는다(READY 삭제는
    /// 이번 달 삭제 기회를 써 버린다). PROCESSING 취소는 기회와 무관(서버 스키마). 삭제 결과는 기다리지 않는다 —
    /// 실패해도 다시 고를 때 서버가 막아 줄 뿐이다. 새 업로드가 접어 버리지 않게 upload 줄기 밖에 둔다.
    private func abandonTimedOutUpload(_ portfolioId: UUID, fileName: String) -> Effect<Action> {
        .run { send in
            if let latest = try? await portfolioClient.status(portfolioId), latest.status == .ready {
                await send(.inner(.timedOutUploadBecameReady(fileName: fileName, portfolioId: portfolioId)))
                return
            }
            _ = try? await portfolioClient.delete(portfolioId)
        }
    }

    /// 계정 가용성 재조회 — 한도 거절 뒤 다시 가능한 날짜를 서버 값으로 채운다. 실패는 날짜 없는 문구로 남긴다.
    private func refreshAvailability() -> Effect<Action> {
        .run { send in
            guard let list = try? await portfolioClient.list() else { return }
            await send(.inner(.availabilityLoaded(list.availability)))
        }
    }

    /// 서버에 이미 등록된 파일 제거 — 계정당 1개 제한이라 지워야 재업로드가 가능하다.
    /// **낙관 갱신 금지** — 응답을 보고서야 판을 비운다(마이페이지 삭제와 같은 규칙).
    /// 먼저 비우면 실패해도 사용자 눈엔 지워진 걸로 보이고, 서버엔 남아 다음 업로드가 409 로 막힌다.
    private func delete(_ portfolioId: UUID) -> Effect<Action> {
        .run { send in
            _ = try await portfolioClient.delete(portfolioId)
            await send(.inner(.portfolioDeleted))
        } catch: { error, send in
            // 404 = 서버에 이미 없다 — 지운 것과 결과가 같으니 성공으로 닫는다.
            if case .notFound? = error as? PortfolioError {
                await send(.inner(.portfolioDeleted))
            } else if case .deleteLimitExceeded? = error as? PortfolioError {
                // 목록 값을 못 받았거나 낡았을 때(draft 복원 판 등) 서버가 마지막으로 막는다 — 배너 대신 차단 모달.
                await send(.inner(.quotaRejected(.delete)))
            } else {
                await send(.inner(.portfolioDeleteFailed(
                    message: (error as? PortfolioError)?.userMessage ?? Self.deleteFailureMessage
                )))
            }
        }
    }
}
