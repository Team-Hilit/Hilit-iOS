//
//  HomeFeature.swift
//  FeatureHomeImplementation
//
//  Created by 서정원 on 26/07/13.
//

import ComposableArchitecture
import DomainInterviewInterface
import DomainUserInterface
import Foundation

// @lat: [[home]]
/// 홈 — 홈 화면 자체를 `phase` 하나로 관리한다(GuestFeedback 패턴 — 선형 플로우가 아니라 서버 상태의 표시라
/// StackState 를 두지 않는다). phase 는 Figma 프레임 `HomeDefault`·`HomeReport` 와 1:1 이고, 면접 시작은
/// 홈의 상태가 아니라 위로 올라오는 화면이라 `StartInterviewFeature` 를 present 한다.
/// phase 는 서버 판정의 표시일 뿐 — 진실은 탭 시점 게이트(checkStartEligibility) 재검증.
@Reducer
public struct HomeFeature {
    /// 홈 화면 상태 — Figma 프레임 `HomeDefault`·`HomeReport` 와 1:1(docs/work/home-account.md §3).
    public enum Phase: Equatable, Sendable {
        /// HomeDefault — 기본 상태(리포트 없음).
        case `default`
        /// HomeReport — 면접 기록(레포트) 표시 상태.
        case report(ReportVariant)
    }

    /// HomeReport 하위 변형 — 축은 «오랜만이에요 OO님!» 인사말을 띄우는지 하나다.
    /// 리포트 목록·바텀시트는 두 변형이 같다.
    public enum ReportVariant: Equatable, Sendable {
        /// 오랜만에 돌아온 사용자 — 인사말을 띄운다.
        case returning
        /// 최근에 다녀간 사용자 — 인사말을 숨기고 스크롤 안내만 남긴다.
        case recent
    }

    /// 리포트 시트가 앉는 세 자리 — 그래버를 끌어 오간다. `phase`(서버 상태의 표시)와 직교하는
    /// **시트 높이** 축이고, 시안 프레임이 아니라 사용자가 지금 뭘 보고 있는지를 뜻한다.
    ///
    /// 시트가 다 내려가면 뒤에 깔린 면접 시작 화면이 그대로 드러난다 — 그래서 «면접 시작» 은
    /// 별도 present 가 아니라 이 축의 한 자리다(끌던 손을 놓기 전까진 되돌릴 수 있어야 해서).
    public enum SheetDetent: Equatable, Sendable {
        /// 시트가 완전히 내려가 면접 시작 화면이 드러난 자리.
        case startInterview
        /// 기본 — 인사말 그린 판 + 시트(시안 Home_Default·Home_Report).
        case report
        /// 시트가 내비바 밑까지 올라와 리포트 목록만 남은 자리.
        case expanded
    }

    /// 리포트 행 표시 모델 — 위젯② 면접 기록 한 줄. `id` 는 **세션 id** 라 그대로 리포트 상세
    /// (`ReportFeature.State(sessionId:)`) 인자가 된다 — 표시용 UUID 를 따로 만들면 매핑 표가 하나 더 생긴다.
    /// `dateText` 는 이미 포맷된 문자열이다(«7월 11일 월» 포맷은 목록을 만드는 쪽 몫).
    public struct Report: Identifiable, Equatable, Sendable {
        public let id: Int
        public let dateText: String
        public let title: String
        /// 제목 아래 회색 보조 문구 — 지금은 생성 실패 행의 «이용권 횟수는 차감되지 않아요» 하나다.
        public let subtitle: String?
        /// [레포트 보기] 노출 여부 — 생성 실패 세션은 열 상세가 없다
        /// (docs/work/home-account.md §3 위젯② 행 상태 표).
        public let canOpenReport: Bool

        public init(
            id: Int,
            dateText: String,
            title: String,
            subtitle: String? = nil,
            canOpenReport: Bool = true
        ) {
            self.id = id
            self.dateText = dateText
            self.title = title
            self.subtitle = subtitle
            self.canOpenReport = canOpenReport
        }
    }

    @ObservableState
    public struct State: Equatable {
        /// 화면 상태 — 홈 진입 시 로드 결과(잔여·기록)가 결정한다.
        public var phase: Phase = .default
        /// 인사말에 넣는 사용자 이름 — 홈 진입 로드(`UserClient.profile`)가 덮어쓴다.
        /// 기본값은 빈 문자열이다: 사람 이름을 박아 두면 프로필 응답이 늦을 때 **모든 사용자가
        /// 남의 이름을 읽는다**. 비어 있는 동안은 뷰가 이름 없는 인사말로 떨어진다.
        public var userName: String
        /// 리포트 목록 — 최신순. 개수는 여기서 파생한다(`reports.count`), 따로 들지 않는다.
        public var reports: IdentifiedArrayOf<Report>
        /// 펼친 행들 — **여러 행을 동시에 펼쳐 둘 수 있다**(사용자 결정 2026-08-05).
        /// 진입 시엔 시안대로 최신 1개만 펼쳐져 있고, 행을 탭할 때마다 토글된다.
        public var expandedReportIDs: Set<Report.ID>
        /// 목록 갱신 후 남길 펼침 — 사라진 세션은 버리고, 전부 사라졌으면 최신 1개를 펼친다.
        static func expanded(keeping previous: Set<Report.ID>, in reports: [Report]) -> Set<Report.ID> {
            let kept = previous.intersection(reports.map(\.id))
            return kept.isEmpty ? Set(reports.first.map { [$0.id] } ?? []) : kept
        }
        /// 시트가 지금 앉아 있는 자리. 홈에 다시 들어오면 기본으로 돌아온다(`onAppear`).
        public var sheetDetent: SheetDetent = .report
        /// 시트 자리를 옮기며 «면접 시작» 겹의 확인 단계도 함께 접는다 — 겹을 떠났다 돌아왔을 때
        /// 묻지도 않은 «처음부터 시작하시겠어요?» 가 떠 있으면 안 된다. 내비바 X·드래그·재진입이
        /// 전부 이 한 길로 모이므로 자리 대입은 직접 하지 않고 여기를 통한다.
        mutating func settle(_ detent: SheetDetent) {
            sheetDetent = detent
            if detent != .startInterview { startInterview.isConfirmingRestart = false }
        }
        /// 면접 시작 화면 — 시트 **뒤에 늘 깔려 있다**. present 가 아닌 이유는 `SheetDetent` 주석 참조.
        /// 잔여·변형은 홈 진입 로드가 채운다 — 진실은 탭 시점 게이트(`checkStartEligibility`) 재검증이다.
        public var startInterview: StartInterviewFeature.State
        /// dev 데이터 초기화 버튼 노출 여부 — AppFeature 가 dev 빌드에서만 켠다.
        public var showsDevReset: Bool

        public init(
            phase: Phase = .default,
            userName: String = "",
            reports: [Report] = [],
            startVariant: StartInterviewFeature.Variant = .first,
            showsDevReset: Bool = false
        ) {
            self.phase = phase
            self.userName = userName
            self.reports = IdentifiedArray(uniqueElements: reports)
            self.expandedReportIDs = Set(reports.first.map { [$0.id] } ?? [])
            self.startInterview = StartInterviewFeature.State(variant: startVariant, userName: userName)
            self.showsDevReset = showsDevReset
        }
    }

    public enum Action: ViewAction {
        case view(View)
        case inner(Inner)
        case delegate(Delegate)
        case startInterview(StartInterviewFeature.Action)

        /// 사용자 입력·생명주기. View 의 send(...) 로만 방출된다.
        public enum View: Sendable {
            // 홈 진입 로드 — 프로필은 `inner(.entryLoaded)`, 기록 목록은 `inner(.reportsLoaded)`.
            // 진행 중(held) 세션은 로컬 보관값이라 effect 없이 리듀서가 바로 읽는다.
            case onAppear
            /// 시트 드래그가 끝나 자리가 정해졌다 — 판정은 뷰(`HomeSheetDrag`), 확정은 여기.
            case userSettledSheet(SheetDetent)
            /// 내비바 프로필 탭 — 마이페이지 진입 요청.
            case userTappedProfile
            /// 펼친 행의 [레포트 보기](>) 탭 — 리포트 상세 진입 요청. `id` 가 곧 세션 id 다.
            case userTappedReport(id: Report.ID)
            /// 리포트 행 탭 — 펼침 토글(홈 내부 상태, 화면 전환 아님). 펼친 행 본문 탭이면 접힌다.
            case userTappedReportRow(id: Report.ID)
            /// dev 데이터 초기화 탭 — 로컬·세션 데이터를 전부 지우고 앱을 처음부터 다시 태운다.
            case userTappedResetAppData
        }

        /// effect 결과·리듀서 내부 신호. 리듀서만 방출한다.
        /// `@CasePathable` — 테스트가 `\.inner.reportsLoaded` 처럼 케이스 키패스로 받는다
        /// (`@Reducer` 는 `Action` 까지만 붙여 준다 — 그 안의 enum 은 직접 달아야 한다).
        @CasePathable
        public enum Inner: Sendable {
            /// 홈 진입 로드 결과 — 실패면 nil 이다(직전 값을 지우지 않고 그대로 둔다).
            /// 묶음 API(미결 6-1)로 바뀌어도 갈아끼울 자리는 이 한 케이스다.
            case entryLoaded(profile: UserProfile?)
            /// 기록 리스트 로드 결과 — 목록과 phase 를 함께 갱신한다.
            /// nil 은 «모른다»(호출 실패) — 직전 목록을 지우지 않는다. 빈 배열은 «기록이 없다» 로 다르다.
            case reportsLoaded([Report]?)
        }

        /// 부모(AppFeature) 통보. 부모는 이것만 매칭한다 (D1).
        @CasePathable
        public enum Delegate: Sendable {
            /// 마이페이지 진입 요청 — 홈 밖 화면이라 조립은 AppFeature (Feature→Feature 금지).
            case profileRequested
            /// 리포트 상세 진입 요청 — 리포트 뷰는 홈 밖이라 조립은 AppFeature.
            case reportDetailRequested(sessionId: Int)
            /// 면접 시작 요청 — 면접 시작 화면의 [시작하기] 가 발원지. 전환은 AppFeature.
            case interviewStartRequested
            /// 진행 중 면접을 버리고 처음부터 요청 — 확인 단계를 통과한 [처음부터 시작] 이 발원지.
            /// **버릴 세션 id 를 싣는다** — 진행 중 세션 목록 API 가 없어 출처는 로컬 보관값
            /// (`HeldSessionStore`)이고, 홈이 그걸 읽어 실어 준다.
            case interviewRestartRequested(sessionId: Int)
            /// 진행 중 면접 이어서 진행 요청 — [이어서 진행] 이 발원지. 세션 id 출처는 위와 같다.
            case interviewResumeRequested(sessionId: Int)
            /// dev 데이터 초기화 요청 — orchestration(logout API·저장소 삭제·State 리셋·재판정)은 AppFeature.
            case appDataResetRequested
        }
    }

    /// 진입 로드 취소 식별자 — 탭을 빠르게 오갈 때 앞선 응답이 뒤늦게 덮어쓰는 걸 막는다.
    private enum CancelID { case entryLoad }

    @Dependency(\.heldSessionStore) var heldSessionStore
    @Dependency(\.interviewClient) var interviewClient
    @Dependency(\.userClient) var userClient

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .view(.onAppear):
                // 홈 밖에 다녀오면 시트는 기본 자리로 — 남의 화면에서 돌아왔는데 면접 시작이
                // 떠 있거나 목록이 펼쳐진 채면 «홈에 왔다» 는 신호가 사라진다.
                state.settle(.report)
                // 진행 중(held) 판정은 **로컬 보관값 읽기**라 effect 를 두지 않는다 — 화면이 그려지기 전에
                // 정해져야 하고, 비동기로 돌리면 [시작하기] 시안이 한 프레임 스친다.
                state.startInterview.variant = Self.startVariant(
                    heldSession: heldSessionStore.load(),
                    remainingChances: state.startInterview.remainingChances
                )
                // 첫 진입만이 아니라 **매 진입 재조회** — 잔여·기록은 면접이 바꾼다. 캐시하면 무효화
                // 신호를 AppFeature 로 돌려야 하는데(Feature→Feature 금지) 1건짜리 GET 두 번보다 비싸다.
                // 진실은 서버(docs/work/home-account.md §3·§6).
                // 값은 지우지 않고 덮어쓰기만 한다 — 재진입마다 화면이 비면 깜빡인다.
                return .merge(
                    .run { send in
                        await send(.inner(.entryLoaded(profile: try? await userClient.profile())))
                    },
                    // 기록 목록은 별도 effect — 목록이 느려도 인사말·면접 시작 카드는 먼저 그린다.
                    .run { send in
                        let summaries = try? await interviewClient.reportList()
                        // 최신순으로 다시 세운다 — 응답 순서는 계약에 없고, 시안은 맨 위가 최근 면접이다
                        // (펼치는 행도 «최신 1개» 라 순서가 흔들리면 엉뚱한 행이 펼쳐진다).
                        // compactMap — 생성 중 세션은 행을 만들지 않는다(Report.init?(summary:)).
                        await send(.inner(.reportsLoaded(
                            summaries?
                                .sorted { $0.interviewedAt > $1.interviewedAt }
                                .compactMap(Report.init(summary:))
                        )))
                    }
                )
                .cancellable(id: CancelID.entryLoad, cancelInFlight: true)
            case let .view(.userSettledSheet(detent)):
                state.settle(detent)
                return .none
            case .view(.userTappedProfile):
                return .send(.delegate(.profileRequested))
            case let .view(.userTappedReport(id)):
                return .send(.delegate(.reportDetailRequested(sessionId: id)))
            case let .view(.userTappedReportRow(id)):
                // 재탭이면 접는다 — foldable 행은 홈 내부 상태다(docs/work/home-account.md §3 위젯②).
                // 다른 행을 닫지 않는다 — 여러 행을 펼쳐 둔 채 비교할 수 있다(사용자 결정 2026-08-05).
                if state.expandedReportIDs.contains(id) {
                    state.expandedReportIDs.remove(id)
                } else {
                    state.expandedReportIDs.insert(id)
                }
                return .none
            case .view(.userTappedResetAppData):
                return .send(.delegate(.appDataResetRequested))

            case let .inner(.entryLoaded(profile)):
                if let profile {
                    // 이름은 온보딩 전이면 비어 올 수 있다 — 그때는 앞서 그리던 값을 유지한다.
                    if let name = profile.name, !name.isEmpty {
                        state.userName = name
                        state.startInterview.userName = name
                    }
                    state.startInterview.remainingChances = profile.remainingTicketCount
                }
                state.startInterview.variant = Self.startVariant(
                    // 보관값을 **다시** 읽는다 — 프로필 응답이 진행 중 판정을 «처음»·«소진» 으로 덮어쓰면
                    // 진행 중 세션을 두고 [시작하기] 가 떠 버린다.
                    heldSession: heldSessionStore.load(),
                    remainingChances: state.startInterview.remainingChances
                )
                return .none

            case let .inner(.reportsLoaded(loaded)):
                // 실패(nil)면 아무것도 건드리지 않는다 — 목록을 비우면 «기록이 없어졌다» 로 읽힌다.
                guard let reports = loaded else { return .none }
                state.reports = IdentifiedArray(uniqueElements: reports)
                // 재조회로 사라진 세션의 펼침만 버린다 — 남은 펼침은 그대로 둔다(깜빡임 방지).
                state.expandedReportIDs = State.expanded(keeping: state.expandedReportIDs, in: reports)
                // 기록이 있으면 **인사말을 띄운다**(`returning`) — «오랜만/최근» 을 가를 재료(마지막 방문 시각)가
                // 서버에도 목록에도 없는데 `recent` 로 두면 인사말이 영원히 안 보인다(사용자 결정 2026-08-04).
                // TODO: 마지막 방문·면접 시각 계약이 생기면 그때 `recent` 판정을 되살린다(미결 6-1).
                if reports.isEmpty {
                    state.phase = .default
                    // 펼칠 목록이 사라졌으면 확장 자리도 성립하지 않는다.
                    if state.sheetDetent == .expanded { state.sheetDetent = .report }
                } else {
                    state.phase = .report(.returning)
                }
                return .none

            case .startInterview(.delegate(.backToHomeRequested)):
                state.settle(.report)
                return .none
            case .startInterview(.delegate(.startRequested)):
                // 면접 플로우는 다른 Feature 라 AppFeature 가 조립한다(Feature→Feature 금지).
                return .send(.delegate(.interviewStartRequested))
            // 진행 중 면접의 두 갈래도 홈이 처리할 수 없는 전환이라 그대로 위로 올린다 — 대상 세션은
            // 판정에 쓴 것과 같은 로컬 보관값에서 읽어 싣는다.
            case .startInterview(.delegate(.restartRequested)):
                // 진행 중 변형인데 보관값이 없으면(비정상) 버릴 세션을 특정할 수 없어 신호를 삼킨다.
                guard let held = heldSessionStore.load() else { return .none }
                return .send(.delegate(.interviewRestartRequested(sessionId: held.sessionId)))
            case .startInterview(.delegate(.resumeRequested)):
                // 이어갈 세션을 특정할 수 없으면 보낼 게 없다 — 위와 같은 비정상 경로다.
                guard let held = heldSessionStore.load() else { return .none }
                return .send(.delegate(.interviewResumeRequested(sessionId: held.sessionId)))
            case .startInterview:
                return .none

            case .delegate:
                return .none
            }
        }
        Scope(state: \.startInterview, action: \.startInterview) {
            StartInterviewFeature()
        }
    }
}

// MARK: - 진입 로드 → 표시값

private extension HomeFeature {
    /// 면접 시작 카드 변형 — 진행 중 세션이 있으면 진행 중, 없고 잔여 0 이면 소진, 아니면 `first` 다.
    /// 서버 판정의 표시일 뿐이다 — 시작 가능 여부의 진실은 탭 시점 게이트다.
    ///
    /// **진행 중(held) 세션이 잔여보다 먼저다** — 진행 중이면 [이어서 진행] 이 유일한 정상 경로라서,
    /// 잔여가 0 으로 잡혀도(진행 중 세션이 이용권 하나를 예약해 둔 상태) 소진 안내를 띄우지 않는다.
    ///
    /// **회차를 묻지 않는다** — 포폴 보유로 «2회차» 를 가르던 분기는 걷어냈다(제품 결정 2026-08-08).
    /// 홈은 포폴을 조회하지 않고, 필요한 정보 수집은 시작 경로(온보딩 위저드)가 알아서 한다.
    ///
    /// **잔여를 모르면(nil) 소진이 아니다** — 프로필이 죽었을 뿐인데 «무료 횟수를 모두 사용했어요»
    /// 를 띄우면 시작 경로가 [홈으로] 하나로 막힌다. 모를 땐 `first` 로 둔다.
    ///
    /// **[시작하기] 전이라도 카드를 그린다**(2026-08-21 제품 결정) — 세션은 온보딩 분석이 끝난 순간
    /// 서버에 생기고 이용권도 그때 잡힌다. 시작 버튼을 누르지 않았다고 카드를 숨기면 잡힌 이용권을
    /// 되찾을 길이 사라지고([이어서 진행]·[처음부터 시작] 이 그 유일한 동선이다), [시작하기] 는 세션을
    /// 하나 더 만든다. #130 이 이걸 «유령 카드» 로 보고 숨겼던 것을 되돌린 자리다.
    ///
    /// 필터는 `isResumableInCurrentProcess` 하나 — 클린업이 이 술어의 **정확한 부정**을 쓴다
    /// ([[interview#Client 계약]]). 시작 전 장부는 0초·표식 없음이라 여기서 참이고(잃을 영상이 없어
    /// 프로세스를 넘어 살아남는다), 그래서 클린업도 건드리지 않는다 — 두 곳이 자동으로 맞물린다.
    static func startVariant(
        heldSession: HeldSession?,
        remainingChances: Int?
    ) -> StartInterviewFeature.Variant {
        if let heldSession, heldSession.isResumableInCurrentProcess {
            return .inProgress(
                remainingQuestionCount: remainingQuestionCount(recordedSeconds: heldSession.recordedSeconds)
            )
        }
        if let remainingChances, remainingChances <= 0 { return .exhausted }
        return .first
    }

    /// 최대 면접 길이 — 남은 시간 환산의 기준값(8분).
    static let maxInterviewSeconds = 480

    /// 진행 중 시안의 «남은 질문 N개» — 서버가 주지 않아 녹화 길이로 환산한다(사용자 정의 2026-08-08).
    ///
    /// 남은 시간(= 8분 − 녹화분)을 구간에 얹는다: 3분 미만 1개 / 3~5분 2개 / 5~7분 3개 / 7분 초과 4개.
    /// 경계 420초(정확히 7:00)는 구간 표기(5:00~7:00)를 우선해 **3개**로 처리하고,
    /// 갓 시작한 세션(0초 녹화)은 480초가 남아 4개다.
    static func remainingQuestionCount(recordedSeconds: Int) -> Int {
        // 녹화가 최대 길이를 넘겨 들어와도 음수 시간으로 새지 않게 0 에서 막는다.
        switch max(0, maxInterviewSeconds - recordedSeconds) {
        case ..<180: return 1
        case ..<300: return 2
        case ...420: return 3
        default: return 4
        }
    }
}
