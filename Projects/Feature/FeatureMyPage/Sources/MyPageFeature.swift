//
//  MyPageFeature.swift
//  FeatureMyPage
//
//  Created by 서정원 on 26/08/01.
//

import ComposableArchitecture
import DomainAuthInterface
import DomainInterviewInterface
import DomainPortfolioInterface
import DomainUserInterface
import Foundation

// Figma: «[Part5] 마이페이지» https://figma.com/design/JL9YPbqBqmaC9Z0I3SzDZS/?node-id=435-9709
//
// 조회 3종(프로필·포폴·리포트)·포폴 삭제·업로드/교체·로그아웃·탈퇴가 실서버로 붙어 있다 — 진입은
// fetchEntry() 병렬 3콜 한 방(부분 성공 없음), 실패는 알럿+재시도.
// 진입은 홈 내비바 프로필, 로그아웃·탈퇴 뒤 로그인 복귀까지 AppFeature 가 조립한다.
// 이 파일은 타입 선언만 — 리듀서 본문은 MyPageReducer.swift (GuestFeedback 선례, length 경고 회피).
// @lat: [[mypage#흐름]]
// depends-on: [[app#Cross-feature Routing]] — 리포트 열기·지인 피드백·로그아웃·회원탈퇴는
//             delegate 로만 올린다(import 에 안 보이는 의존).
@Reducer
public struct MyPageFeature {
    @Dependency(\.authClient) var authClient
    @Dependency(\.continuousClock) var clock
    @Dependency(\.portfolioFileReader) var fileReader
    @Dependency(\.interviewClient) var interviewClient
    @Dependency(\.portfolioClient) var portfolioClient
    @Dependency(\.userClient) var userClient
    /// 업로드 중 판이 들고 있을 표시 id — 서버 id 가 아직 없는 구간이라 로컬로 만든다(테스트 결정성).
    @Dependency(\.uuid) var uuid

    // MARK: - 화면이 그리는 값

    /// 프로필 카드 한 장. 표시 문자열을 그대로 나른다 — 포맷·매핑은 MyPageFeature+Mapping 이 만든다(표시 규칙 단일 소스).
    public struct Profile: Equatable, Sendable {
        public var name: String
        public var jobGroup: String
        public var careerLevel: String
        public var remainingTickets: Int
        public var email: String
        /// 소셜 로그인 제공자 원값("KAKAO"/"APPLE") — 계정 줄 로고 분기. nil 이면 카카오 폴백.
        public var provider: String?

        public init(
            name: String,
            jobGroup: String,
            careerLevel: String,
            remainingTickets: Int,
            email: String,
            provider: String? = nil
        ) {
            self.name = name
            self.jobGroup = jobGroup
            self.careerLevel = careerLevel
            self.remainingTickets = remainingTickets
            self.email = email
            self.provider = provider
        }
    }

    /// 포트폴리오 파일 한 개.
    public struct PortfolioFile: Equatable, Sendable {
        /// 서버 포폴 id — 삭제 API 인자.
        public var id: UUID
        public var name: String
        public var date: String?
        public var size: String?

        public init(id: UUID = UUID(), name: String, date: String? = nil, size: String? = nil) {
            self.id = id
            self.name = name
            self.date = date
            self.size = size
        }
    }

    /// «내 포트폴리오» 칸의 상태 — Figma 의 «포트폴리오 case» 프레임들이 그대로 케이스다.
    /// 판의 생김새가 상태마다 통째로 바뀌므로(`FileUpload` 와 같은 사정) Bool 조합이 아니라 enum 이다.
    public enum Portfolio: Equatable, Sendable {
        /// 업로드 전 — 업로드 유도 판 + «아직 첨부된 포트폴리오가 없어요» (MyPage_Portfolio_empty)
        case empty
        case uploading(PortfolioFile, progress: Double)
        case uploaded(PortfolioFile)
        case registered(PortfolioFile)
        case failed(PortfolioFile)
    }

    /// «내 면접 리포트» 목록 한 줄. 접힘 요약(`FoldableCard`)과 펼침 상세(`FoldableCardDetail`)가 한 값에서 나온다.
    public struct Report: Equatable, Identifiable, Sendable {
        public let id: Int
        /// 접힘 제목 — 면접명 또는 포트폴리오 파일명.
        public var title: String
        public var date: String
        public var time: String
        /// 제목 아래 회색 메모 태그 («삭제된 포트폴리오»). nil 이면 숨김.
        public var note: String?
        /// 오른쪽 빨간 상태 태그 («생성 실패»). nil 이면 숨김.
        public var status: String?
        /// 상세 «직군 · 연차» 값.
        public var jobLevel: String
        /// 상세 «포트폴리오» 값.
        public var portfolioName: String
        /// 상세 «JD» 값. 링크·«직접 입력함»·«-» 가 다 들어온다.
        public var jobDescription: String
        /// 상세 맨 아래 오류 띠. nil 이면 숨김.
        public var detailError: String?
        /// «리포트 보기» 노출 — 생성 실패만 막는다(홈과 같은 규칙, 포폴이 삭제돼도 열린다).
        public var canOpenReport: Bool
        /// «지인 피드백 받기» 노출 — 열람 가능 + 서버 feedbackAvailable.
        public var canRequestFeedback: Bool

        public init(
            id: Int,
            title: String,
            date: String,
            time: String,
            note: String? = nil,
            status: String? = nil,
            jobLevel: String,
            portfolioName: String,
            jobDescription: String,
            detailError: String? = nil,
            canOpenReport: Bool = false,
            canRequestFeedback: Bool = false
        ) {
            self.id = id
            self.title = title
            self.date = date
            self.time = time
            self.note = note
            self.status = status
            self.jobLevel = jobLevel
            self.portfolioName = portfolioName
            self.jobDescription = jobDescription
            self.detailError = detailError
            self.canOpenReport = canOpenReport
            self.canRequestFeedback = canRequestFeedback
        }
    }

    /// 이 화면이 띄우는 모달 — 동시 표출을 타입으로 막는다(`.hilitModal(item:)` 규칙).
    /// Figma «모달을 모아봤어요» 6개 인스턴스가 5케이스로 접힌다 — 삭제 불가 두 판은
    /// 안내줄 유무만 다르므로 `canReupload` 의 nil 로 표현한다.
    public enum Modal: Equatable, Sendable {
        /// 포트폴리오를 삭제하시겠어요? (435:8892) — 안내줄은 «삭제 후 이번 달 재업로드 가능 여부» 고지(PRD 3.2-⑤).
        case deleteConfirm(canReupload: Bool)
        /// 포트폴리오를 삭제할 수 없어요 — 면접 진행 중 (435:8893 안내줄 없음 / 435:8894 있음, nil 로 접는다)
        case deleteBlocked(canReupload: Bool?)
        /// 포트폴리오를 새로 업로드하시겠어요? (435:8896)
        case replaceConfirm(remaining: Int)
        /// 포트폴리오를 새로 업로드할 수 없어요 — 이번 달 기회 소진 (435:8895)
        case replaceBlocked(remaining: Int)
        /// 처리 중 (435:8897 modal/loading)
        case loading
    }

    // MARK: - State

    @ObservableState
    public struct State: Equatable {
        public var profile: Profile
        public var portfolio: Portfolio
        public var reports: IdentifiedArrayOf<Report>
        /// 이번 달 포폴 교체(재업로드) 가능 여부 — 삭제·교체 모달 안내가 전부 이 값에서 나온다. 모르면 막지 않는다(nil → true).
        public var replaceAvailable: Bool
        /// 지금 면접이 진행 중인가 — 삭제를 막는 조건(모달 «삭제할 수 없어요»).
        public var isInterviewInProgress: Bool
        /// 펼쳐진 리포트들 — **여러 행을 동시에 펼쳐 둘 수 있다**(홈 위젯②와 같은 규칙).
        /// 진입 시엔 전부 접혀 있고(시안 MyPage_Main), 행을 탭할 때마다 그 행만 토글된다.
        public var expandedReportIDs: Set<Report.ID>
        /// 업로드 실패 카드 위 말풍선 노출 여부.
        public var isPortfolioTooltipPresented: Bool
        /// 파일 선택기(fileImporter) 표시 여부 — View binding 으로 닫힘까지 동기화된다.
        public var isFilePickerPresented = false
        /// 서버에 존재하는 «업로드 중» 포폴 id — register 응답·진입 조회로 확인한다. 취소가 지울 대상이자
        /// 폴링 인자다. nil 이면 아직 접수 전이거나(지울 게 없다) 이미 끝난 판.
        /// 실패 후에도 남는다 — 서버 점유 후보라 다음 재시도가 이 id 로 정리 삭제를 선행한다(409 루프 차단).
        public var uploadServerID: UUID?
        public var presentedModal: Modal?
        /// PDF 열람 시트 — 값이 있으면 뜬다. presigned URL 은 10분짜리라 들고 있지 않고 열 때마다 새로 받는다.
        public var portfolioPreview: PortfolioPreview?
        @Presents public var alert: AlertState<Alert>?

        public init(
            profile: Profile = .init(name: "", jobGroup: "", careerLevel: "", remainingTickets: 0, email: "-"),
            portfolio: Portfolio = .empty,
            reports: IdentifiedArrayOf<Report> = [],
            replaceAvailable: Bool = true,
            isInterviewInProgress: Bool = false,
            expandedReportIDs: Set<Report.ID> = [],
            isPortfolioTooltipPresented: Bool = false,
            presentedModal: Modal? = nil
        ) {
            self.profile = profile
            self.portfolio = portfolio
            self.reports = reports
            self.replaceAvailable = replaceAvailable
            self.isInterviewInProgress = isInterviewInProgress
            self.expandedReportIDs = expandedReportIDs
            self.isPortfolioTooltipPresented = isPortfolioTooltipPresented
            self.presentedModal = presentedModal
        }
    }

    /// PDF 열람 시트의 대상. 발급받은 presigned URL 자체가 신원이라 별도 id 를 두지 않는다.
    public struct PortfolioPreview: Identifiable, Equatable, Sendable {
        public let url: URL
        public var id: URL { url }

        public init(url: URL) {
            self.url = url
        }
    }

    // MARK: - Action

    public enum Alert: Equatable, Sendable {
        case confirmWithdraw
        case retryEntry
    }

    public enum Action: ViewAction {
        case view(View)
        case inner(Inner)
        case delegate(Delegate)
        // TCA 구조적 액션 — 3분류 밖의 presentation 전용 케이스.
        case alert(PresentationAction<Alert>)

        /// 사용자 입력·생명주기. View 의 send(...) 로만 방출된다.
        /// 파일 선택기 표시 바인딩을 위해 BindableAction 채택 (BindingReducer(action: \.view)).
        @CasePathable
        public enum View: BindableAction, Sendable {
            case binding(BindingAction<State>)
            case onAppear
            case userTappedClose
            case userTappedEditProfile
            /// 티켓 안내 — 사용자 UI 정리로 View 참조 0 인 휴면 케이스. 안내 시안이 생기면 재배선한다(스펙 ⑩ 계열).
            case userTappedTicketInfo
            case userTappedLogout
            case userTappedWithdraw
            /// 업로드 판(`.empty`) 또는 «다시 올리기» — 파일 선택기 진입.
            case userTappedUploadPortfolio
            /// 파일 선택기 선택 완료 — security-scoped URL.
            case fileSelected(URL)
            /// 파일 선택기 자체 실패 (파일 접근 불가 등).
            case fileSelectionFailed
            case userTappedCancelUpload
            /// 등록된 파일 카드 탭 — PDF 열람 URL 을 발급받아 시트로 연다.
            case userTappedPortfolioFile
            case userTappedRemovePortfolio
            /// 실패 카드 위 말풍선 탭 — 닫는다.
            case userTappedPortfolioTooltip
            /// 리포트 줄 탭 — 펼침·접힘 토글.
            case userTappedReport(id: Report.ID)
            case userTappedOpenReport(id: Report.ID)
            case userTappedRequestFeedback(id: Report.ID)
            /// 모달 왼쪽 버튼(취소·닫기).
            case userTappedModalCancel
            /// 모달 오른쪽 버튼(삭제·업로드·확인).
            case userTappedModalConfirm
        }

        /// effect 결과·리듀서 내부 신호. 리듀서만 방출한다.
        /// Equatable — TestStore receive 용. @CasePathable — `receive(\.inner.entryLoaded)` 케이스 패스 매칭용
        /// (@Reducer 는 Action 에만 자동 부착 — 중첩 enum 은 수동, GuestFeedback View enum 선례).
        @CasePathable
        public enum Inner: Equatable, Sendable {
            case entryFailed
            case entryLoaded(UserProfile, PortfolioList, [InterviewReportSummary])
            /// 진입 조회를 다시 태워 달라 — 효과 클로저 안에서는 fetchEntry 를 못 불러 inner 로 돌아온다.
            case entryRefetchRequested
            case portfolioDeleteFailed
            case portfolioDeleted
            /// PDF 열람 URL 발급 실패 — 만료·비 READY·네트워크가 한 자리로 모인다.
            case portfolioFileURLFailed
            /// PDF 열람 URL 발급 성공 — 시트가 이 URL 로 열린다.
            case portfolioFileURLLoaded(URL)
            /// POST /portfolios 접수 응답 (202 PROCESSING — 드물게 즉시 READY/FAILED).
            case uploadAccepted(PortfolioProcessing)
            /// 파일 읽기·선검증·삭제·등록·폴링 중 어디서든 난 실패 — 판이 고정 안내를 그려 사유는 나르지 않는다.
            case uploadFailed
            /// GET /portfolios/{id}/status 폴링 응답.
            case uploadStatusPolled(PortfolioProcessing)
            case withdrawFailed
        }

        /// 부모(AppFeature) 통보. 부모는 이것만 매칭한다 (D1).
        @CasePathable
        public enum Delegate: Sendable {
            /// 화면 닫기 요청.
            case closeRequested
            /// 로그아웃 완료 — API·로컬 세션 정리까지 끝낸 뒤 통보한다(부모는 라우팅만).
            case loggedOut
            /// 탈퇴 완료 — 계정 삭제·로컬 세션 정리까지 끝낸 뒤 통보한다.
            case withdrawn
            /// 면접 리포트 화면으로 (Part3).
            case reportRequested(id: Report.ID)
            /// 지인 피드백 화면으로 (Part4).
            case feedbackRequested(id: Report.ID)
        }
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer(action: \.view)

        Reduce { state, action in
            switch action {
            case let .view(action):
                return reduceView(&state, action)

            case let .inner(action):
                return reduceInner(&state, action)

            case .alert(.presented(.retryEntry)):
                return fetchEntry()

            case .alert(.presented(.confirmWithdraw)):
                return .run { send in
                    try await userClient.withdraw()
                    try? await authClient.logout()
                    await send(.delegate(.withdrawn))
                } catch: { _, send in
                    await send(.inner(.withdrawFailed))
                }

            case .alert:
                return .none

            case .delegate:
                return .none
            }
        }
        .ifLet(\.$alert, action: \.alert)
    }
}

// MARK: - 알럿 (GuestFeedback 선례 — 문구는 표현 관심사라 Feature 가 소유한다)

extension AlertState where Action == MyPageFeature.Alert {
    /// 진입 조회 실패 — 재시도 또는 닫기(기존 값 유지).
    static var entryFailed: Self {
        AlertState {
            TextState("불러오지 못했어요")
        } actions: {
            ButtonState(action: .retryEntry) { TextState("다시 시도") }
            ButtonState(role: .cancel) { TextState("닫기") }
        } message: {
            TextState("잠시 후 다시 시도해 주세요.")
        }
    }

    /// 확인 버튼만 있는 단순 안내.
    static func plain(message: String) -> Self {
        AlertState { TextState(message) }
    }

    /// 탈퇴 최종 확인 — 주의사항 문구는 PRD 3.3. 시안 수령 시 주의사항 화면 + dialog 2단계로 교체 예정(스펙 ⑩).
    static var withdrawConfirm: Self {
        AlertState {
            TextState("정말 탈퇴하시겠어요?")
        } actions: {
            ButtonState(role: .destructive, action: .confirmWithdraw) { TextState("탈퇴하기") }
            ButtonState(role: .cancel) { TextState("취소") }
        } message: {
            TextState("탈퇴하면 포트폴리오, 지금까지의 모든 면접 리포트, 지인 피드백 기록이 영구적으로 삭제되고 복구할 수 없어요.")
        }
    }
}
