//
//  ReportPeerFeedbackFeature.swift
//  FeatureReport
//
//  Created by EunSeo on 26/07/25.
//

import ComposableArchitecture
import DomainCommonInterface
import DomainFeedbackShareInterface
import DomainInterviewReportInterface

// @lat: [[report#지인 피드백]]
/// 지인 피드백 요청 — 리포트 메인의 «지인에게 면접 영상 보내기» 로 진입한다.
/// 지인에게 평가받을 태도 항목을 골라 공유 링크를 만드는 화면 (Figma «Report_PeerFeedback_RequestItems» 443:8006).
///
/// 지인에게 넘기는 payload 는 영상과 질문 경계까지다. AI 피드백(하이라이트·진단·다음 대비)은
/// 넘기지 않는다 — 지인 평가가 AI 평가에 오염되면 4.6 의 «지인 vs AI» 2축 비교가 무의미해진다.
/// 그래서 이 화면이 서버로 보내는 것도 **항목 코드뿐**이다 ([[api#Feedback Share]]).
///
/// 항목은 생성 시점에 링크로 잠긴다 — 만든 뒤 바꿀 수 없고 면접당 활성 링크는 1개다(409 `alreadyExists`).
/// 그래서 생성은 되돌릴 수 없는 사건이고, 화면은 성공 즉시 완료 팝업으로 링크 복사만 남긴다.
///
/// **복사가 이 화면의 끝이다** — 복사하면 생성 완료 판이 복사 완료 판으로 바뀌고, 그 판은 버튼 없이
/// 2초 뒤 스스로 닫히며 리포트 메인으로 나간다(2026-08-07 확정). 시스템 공유 시트는 떼어냈다 —
/// 자동 이탈과 시트가 같은 자리를 다툰다.
///
/// **재생성은 없지만 재복사는 있다** — 링크를 손에 넣지 못한 채 나가면 CTA 재탭이 409 로 막힌다.
/// 그래서 진입 때 `status` 로 활성 링크를 회수하고(있으면 항목을 잠근 채 CTA 를 «링크 복사하기» 로
/// 바꾼다), 생성이 409 로 걸려도 같은 회수로 완료 팝업을 다시 띄운다.
@Reducer
public struct ReportPeerFeedbackFeature {
    /// 화면 위 팝업 — 링크 생성 완료 → 복사 완료 두 판이 이어 뜬다. 동시에 뜨는 판은 없어서
    /// Bool 두 개가 아니라 enum 하나로 둔다(`hilitModal(item:)`).
    public enum Popup: Equatable, Sendable {
        /// 링크 생성 완료 — «링크 복사하기» 하나 (Figma 443:8121). 회수한 링크면 제목만 갈린다.
        case shareLinkReady
        /// 링크 복사 완료 — 버튼 없는 판 (Figma 1321:10451). 2초 뒤 리포트 메인으로 나간다.
        case linkCopied
    }

    @ObservableState
    public struct State: Equatable {
        public let sessionId: Int
        /// 지인에게 평가받을 태도 항목 — 전부 켠 채 시작한다(HLT-70). 서버 계약은 1~5개 —
        /// 0개면 400 이라 CTA 를 `.disabled` 로 막는다.
        public var selectedAxes: Set<AttitudeAxisKind> = Set(AttitudeAxisKind.allCases)
        public var isCreating = false
        /// 공유 링크 — 생성 성공 또는 **진입·409 회수**로 채워지고, 채워진 뒤엔 항상 남는다
        /// (항목이 잠겨 재생성이 없으므로).
        public var createdLink: String?
        /// 이 링크가 방금 만든 것이 아니라 서버에서 회수한 기존 링크인지 — 완료 팝업 문구가 갈린다.
        public var isLinkRecovered = false
        /// 떠 있는 팝업 (Figma 443:8082 · 1321:10338). 없으면 nil.
        public var popup: Popup?
        /// 하단 토스트 문구 — 생성·회수 실패와 잠긴 토글 탭 안내 자리다(복사 완료는 팝업이 받는다).
        public var toast: String?
        /// 미승격 서버 에러 Alert — 도메인이 케이스로 승격하지 않은 코드의 원문 표시(임시 노출 규칙).
        @Presents public var alert: AlertState<Action.Alert>?

        public init(sessionId: Int) {
            self.sessionId = sessionId
        }
    }

    public enum Action: ViewAction {
        case view(View)
        case inner(Inner)
        case delegate(Delegate)
        case alert(PresentationAction<Alert>)

        /// 확인 버튼만 있는 Alert — 누를 액션이 없다.
        public enum Alert: Equatable {}

        public enum View: BindableAction, Equatable, Sendable {
            case binding(BindingAction<State>)
            case onAppear
            case userTappedBack
            case userToggledAxis(AttitudeAxisKind, isOn: Bool)
            /// 링크가 생긴 뒤 잠긴 토글을 탭했다 — 값은 그대로 두고 잠긴 이유만 토스트로 알린다.
            case userTappedLockedAxis
            case userTappedCreateLink
            case userTappedCopyLink
        }

        /// @CasePathable — `receive(\.inner.shareLinkCreated)` 케이스 패스 매칭용
        /// (@Reducer 는 Action 에만 자동 부착 — 중첩 enum 은 수동, MyPage·GuestFeedback 선례).
        @CasePathable
        public enum Inner: Equatable, Sendable {
            /// 서버에 이미 있던 활성 링크 회수 — 진입 조회(`presentsPopup: false`)와 생성 409
            /// (`presentsPopup: true`)가 같은 재료를 쓰고 뒷처리만 다르다.
            case existingShareLoaded(token: String, axes: [String], presentsPopup: Bool)
            /// 복사 완료 판이 제 수명을 다 썼다 — 판을 내리고 리포트 메인으로 나간다.
            case linkCopiedPopupElapsed
            case shareLinkCreated(token: String)
            /// 링크 생성 실패 — 승격된 에러는 토스트 문구로, 미승격 서버 에러는 원문 Alert 로 갈린다.
            case shareLinkFailed(FeedbackShareError)
            case toastDismissed
        }

        @CasePathable
        public enum Delegate: Equatable, Sendable {
            /// 뒤로 — 코디네이터가 스택을 pop.
            case backRequested
        }
    }

    private enum CancelID { case popup, share, toast }

    /// 복사 완료 판이 떠 있는 시간 — 이 뒤에 화면이 스스로 리포트 메인으로 나간다.
    private static let linkCopiedPopupDuration: Duration = .seconds(2)

    /// 잠긴 토글 탭 안내 — 기획 HLT-70 문구 그대로.
    static let axisLockedMessage = "링크 생성 후 조작이 불가능합니다."

    /// 토스트가 떠 있는 시간.
    private static let toastDuration: Duration = .seconds(2)

    @Dependency(\.feedbackShareClient) var feedbackShareClient
    @Dependency(\.pasteboard) var pasteboard
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

            case .alert:
                return .none

            case .delegate:
                return .none
            }
        }
        .ifLet(\.$alert, action: \.alert)
    }

    private func reduceView(_ state: inout State, _ action: Action.View) -> Effect<Action> {
        switch action {
        case .binding:
            return .none

        case .onAppear:
            // 이미 만들어 둔 활성 링크가 있으면 회수한다 — 복사하지 못한 채 나가 링크를 잃어버린
            // 사용자가 다시 들어오는 경로다. 항목은 그때 잠긴 값이라 화면은 재복사만 남는다.
            guard state.createdLink == nil else { return .none }
            return recoverExistingShare(sessionId: state.sessionId, presentsPopup: false)

        case .userTappedBack:
            // 상단 X 는 팝업 판의 X 다 — 팝업이 떠 있으면 그 판만 닫고 화면은 남는다(2026-08-07 확정).
            guard let popup = state.popup else { return .send(.delegate(.backRequested)) }
            state.popup = nil
            // 복사 완료 판은 어차피 2초 뒤 나가는 자리라 X 는 그 기다림만 건너뛴다.
            guard popup == .linkCopied else { return .none }
            return .merge(
                .cancel(id: CancelID.popup),
                .send(.delegate(.backRequested))
            )

        case let .userToggledAxis(axis, isOn):
            if isOn {
                state.selectedAxes.insert(axis)
            } else {
                state.selectedAxes.remove(axis)
            }
            return .none

        case .userTappedLockedAxis:
            return showToast(Self.axisLockedMessage, &state)

        case .userTappedCreateLink:
            // 항목 0개는 View 가 `.disabled` 로 막는다 — 여기 도달하면 방어만.
            guard !state.isCreating, !state.selectedAxes.isEmpty else { return .none }
            state.isCreating = true
            return createShareLink(sessionId: state.sessionId, axes: state.selectedAxes)

        case .userTappedCopyLink:
            guard let link = state.createdLink else { return .none }
            // 생성 완료 판을 복사 완료 판으로 바꿔 끼운다 — 그 판이 화면의 끝이고, 스스로 나간다.
            state.popup = .linkCopied
            return .merge(
                .run { _ in pasteboard.copy(link) },
                .run { send in
                    try await clock.sleep(for: Self.linkCopiedPopupDuration)
                    await send(.inner(.linkCopiedPopupElapsed))
                }
                .cancellable(id: CancelID.popup, cancelInFlight: true)
            )
        }
    }

    private func reduceInner(_ state: inout State, _ action: Action.Inner) -> Effect<Action> {
        switch action {
        case let .existingShareLoaded(token, axes, presentsPopup):
            state.isCreating = false
            state.createdLink = Self.shareLink(token: token)
            state.isLinkRecovered = true
            // 항목은 생성 시점에 잠긴 값이라 서버가 답이다 — 모르는 코드는 버린다.
            state.selectedAxes = Set(axes.compactMap { AttitudeAxisKind(rawCode: $0) })
            // 진입 회수(presentsPopup: false)는 떠 있는 판을 건드리지 않는다.
            if presentsPopup {
                state.popup = .shareLinkReady
            }
            return .none

        case .linkCopiedPopupElapsed:
            state.popup = nil
            return .send(.delegate(.backRequested))

        case let .shareLinkCreated(token):
            state.isCreating = false
            state.createdLink = Self.shareLink(token: token)
            state.popup = .shareLinkReady
            return .none

        case let .shareLinkFailed(error):
            state.isCreating = false
            // 도메인이 케이스로 승격하지 않은 에러코드는 토스트 문구로 번역할 수 없다 —
            // 서버 원문을 공통 Alert 로 띄운다([[api#공통 규약]]).
            guard let alert: AlertState<Action.Alert> = error.serverAlertState() else {
                return showToast(Self.failureMessage(for: error), &state)
            }
            state.alert = alert
            return .none

        case .toastDismissed:
            state.toast = nil
            return .none
        }
    }

    /// 링크 생성. 서버로 나가는 항목 순서는 화면 순서(시선·표정·자세·손동작·목소리)로 고정한다 —
    /// `Set` 의 순회 순서는 실행마다 달라서 게스트 화면의 항목 순서가 흔들린다.
    /// 409(활성 링크 존재)는 실패로 끝내지 않는다 — 재생성은 없지만 **재복사** 는 있어야 한다.
    private func createShareLink(sessionId: Int, axes selected: Set<AttitudeAxisKind>) -> Effect<Action> {
        let axes = AttitudeAxisKind.allCases.filter(selected.contains).map(\.rawValue)
        return .run { send in
            let created = try await feedbackShareClient.create(sessionId, axes)
            await send(.inner(.shareLinkCreated(token: created.token)))
        } catch: { error, send in
            guard (error as? FeedbackShareError) == .alreadyExists,
                  let status = try? await feedbackShareClient.status(sessionId),
                  status.status == .active
            else {
                await send(.inner(.shareLinkFailed(error as? FeedbackShareError ?? .unexpected)))
                return
            }
            await send(.inner(.existingShareLoaded(
                token: status.token,
                axes: status.axes ?? [],
                presentsPopup: true
            )))
        }
        // 진입 회수와 같은 ID — 회수가 나는 동안 생성을 탭하면 회수를 끊고 생성이 이어받는다
        // (링크가 실존하면 409 → 위 catch 가 다시 회수하므로 결과는 같고, 요청만 단일 비행이 된다).
        .cancellable(id: CancelID.share, cancelInFlight: true)
    }

    /// 서버에 이미 있는 활성 링크를 회수한다 — 링크 미생성(404)이 정상 경로라 조회 실패로 화면을 막지 않고,
    /// ACTIVE 가 아닌 링크(무효화·비공개)는 복사해도 지인이 못 열어 회수 대상이 아니다.
    // TODO(prd-외): 재복사 동선 전체(진입 회수·409 회수·CTA 잠금)가 PRD 에 없는 재량 구현 —
    //               «복사 못 한 채 이탈 = 링크 유실» 막다른 길을 관례로 메웠다. 스펙 확정 시 재검토.
    private func recoverExistingShare(sessionId: Int, presentsPopup: Bool) -> Effect<Action> {
        .run { send in
            let status = try await feedbackShareClient.status(sessionId)
            guard status.status == .active else { return }
            await send(.inner(.existingShareLoaded(
                token: status.token,
                axes: status.axes ?? [],
                presentsPopup: presentsPopup
            )))
        } catch: { _, _ in
            // 생성 시 409 로 다시 걸리므로 여기서 사용자에게 알릴 것이 없다.
        }
        .cancellable(id: CancelID.share, cancelInFlight: true)
    }

    /// 토스트를 띄우고 정해진 시간 뒤 스스로 내린다. 연달아 뜨면 뒤엣것만 남는다(`cancelInFlight`).
    private func showToast(_ message: String, _ state: inout State) -> Effect<Action> {
        state.toast = message
        return .run { send in
            try await clock.sleep(for: Self.toastDuration)
            await send(.inner(.toastDismissed))
        }
        .cancellable(id: CancelID.toast, cancelInFlight: true)
    }

    /// 토큰 → 지인이 열 링크. 조립은 클라이언트 책임이다 ([[api#Feedback Share]]).
    /// 형식의 단일 소스는 `GuestFeedbackShareLink` — 링크를 **해석하는** 게스트 쪽과 같은 사실을 본다.
    private static func shareLink(token: String) -> String {
        GuestFeedbackShareLink.url(token: token).absoluteString
    }

    /// 실패 안내 문구. 서버가 준 `message` 가 있는 항목 검증 실패만 그대로 노출하고,
    /// 409(활성 링크 존재)는 회수 경로가 먼저 가로채므로 회수까지 실패했을 때만 여기 온다.
    /// 나머지는 사용자가 할 수 있는 행동으로 번역한다 — 미승격 서버 에러(`server`)는 여기 오지 않는다(Alert 몫).
    private static func failureMessage(for error: FeedbackShareError) -> String {
        switch error {
        case .alreadyExists:
            "이미 만들어 둔 링크가 있어요."
        case let .invalidAxes(message):
            message
        case .shareNotFound, .sessionNotFound:
            "면접 정보를 찾을 수 없어요."
        case .sessionExpired:
            "다시 로그인해 주세요."
        case .networkFailure:
            "네트워크 연결을 확인해 주세요."
        default:
            "링크를 만들지 못했어요. 잠시 후 다시 시도해 주세요."
        }
    }
}

// MARK: - 표시 파생값

public extension ReportPeerFeedbackFeature.State {
    /// 항목 잠김 — 활성 링크가 있으면(방금 만들었든 회수했든) 항목을 바꿀 수 없다.
    /// 그 상태의 화면은 «생성» 이 아니라 «재복사» 다.
    var isAxisLocked: Bool { createdLink != nil }
}
