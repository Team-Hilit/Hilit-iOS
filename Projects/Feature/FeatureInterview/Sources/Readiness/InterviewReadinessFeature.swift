//
//  InterviewReadinessFeature.swift
//  FeatureInterview
//
//  Created by 서정원 on 26/07/25.
//

import ComposableArchitecture
import DomainInterviewInterface
import DomainPermissionInterface
import DomainRecordingInterface

// @lat: [[interview#준비]]
/// Part 2 진입 첫 화면 — 카메라 확인 + 면접 안내 (Figma «[2] Interview_Readiness» 2479:7569 ·
/// «…_Done» 2514:12754 · «…_Guide1» 2514:12799 · «…_Guide2» 2529:458).
/// 진입 시 카메라·마이크 권한을 사용 시점 요청(PRD §8)하고, 하나라도 미허용이면 **그 자리에서** 설정 유도
/// alert 를 띄운다 — 가이드 phase 자체는 그대로 진행하되 «면접 시작하기» 버튼은 계속 비활성이다.
/// 설정에서 허용하고 돌아오는 길은 포그라운드 복귀(`sceneBecameActive`) 재조회가 연다 — 앱이 살아서
/// 돌아오면 진입 판정이 낡은 값이라, 화면 재생성·프로세스 종료에 기대지 않고 그 자리에서 다시 읽는다.
/// 화면 push 없이 단일 카메라 화면 위에서 phase 로만 전환한다:
/// aligning(얼굴 맞춤) → ready(티커 강조) → guide1(질문은 소리로만) → guide2(총 10분 · 시작 버튼 활성).
/// 시작 버튼 탭은 delegate(.startRequested) 로만 올린다 — 세션 화면 전환은 코디네이터 몫.
/// 시작 게이트는 «guide2 + 권한 + 질문 준비 READY» 삼중 — 하나라도 미충족이면 시작 버튼 비활성
/// (질문 준비 중 로딩 연출은 «협의 가능», 임시 비활성만).
/// 재개 진입(`State.isResume`)도 이 화면을 거친다 — 이탈 사이 사용자가 권한을 껐을 수 있어서다. 질문은 홈의
/// `confirmResume` 이 이미 줬으니 질문 준비 폴링·게이트만 뺀 «guide2 + 권한» 이중 게이트가 된다.
@Reducer
public struct InterviewReadinessFeature {
    /// phase 최소 유지 시간 — aligning 은 «최소 유지 + 프리뷰 해소» 이중 게이트(둘 다 충족 시 진행),
    /// ready·guide1 은 시간 연출만. 얼굴 인식 기반 정렬 판정은 범위 밖(작업 B 이후).
    static let aligningHold: Duration = .seconds(3)
    static let readyHold: Duration = .seconds(2)
    static let guide1Hold: Duration = .seconds(3)

    /// 질문 준비 폴링 간격 — 온보딩 분석 스텝과 동일 주기 (서버 가이드 3~5초).
    static let prepPollInterval: Duration = .seconds(3)

    @ObservableState
    public struct State: Equatable {
        /// 화면 하위 상태 — 순서대로만 진행한다 (역방향 없음).
        public enum Phase: Equatable, Sendable {
            /// 얼굴 맞춤 안내 + 하단 티커(dim)
            case aligning
            /// 준비 완료 — 티커 중앙 문구 강조 (Figma Done)
            case ready
            /// 안내 1: 질문은 소리로만 — 시작 버튼 비활성
            case guide1
            /// 안내 2: 총 10분 — 시작 버튼 활성
            case guide2
        }

        /// 질문 준비(preload) 상태 — PRD §3.2 «질문을 준비하고 있어요» 게이트. 서버 3상태만 쓴다.
        /// READY 는 폴링 페이로드(요약 질문 — 첫 턴 TTS)를 동봉한다 — 코디네이터가 세션 화면에 시드.
        public enum QuestionPrep: Equatable, Sendable {
            case preparing
            case ready(SummaryQuestion)
            case failed
        }

        /// 폴링 대상 세션 — 온보딩 분석 스텝이 만든 세션의 id. AppFeature 배선(작업 D) 전까지 Example 이 주입.
        public let sessionId: Int
        /// 재개 진입 — 이미 시작했던 세션을 이어서 연다. 질문은 `confirmResume` 이 줬고(코디네이터가 시드로 쥔다)
        /// 요약 질문은 없으니, 질문 준비 폴링을 걸지 않고 게이트도 «준비됨» 으로 본다.
        public let isResume: Bool

        public var phase: Phase = .aligning
        /// onAppear 재진입 가드 — phase 타이머·권한 요청 effect 중복 실행 방지.
        public var hasStarted = false
        public var questionPrep: QuestionPrep = .preparing
        /// 진입 요청으로 해소된 카메라·마이크 권한 — 둘 다 허용일 때만 true. 해소 전엔 false(시작 버튼 비활성).
        public var isMediaPermissionGranted = false
        /// 프리뷰 핸들 — 있으면 backdrop 이 실카메라, 없으면 placeholder.
        public var previewHandle: CameraPreviewHandle?
        /// aligning→ready 이중 게이트 플래그 — 최소 유지 시간 경과.
        public var isAligningHoldElapsed = false
        /// aligning→ready 이중 게이트 플래그 — 프리뷰 해소(성공·실패 무관).
        public var isPreviewResolved = false
        /// 진입 시 권한이 미허용이면 띄우는 설정 유도 alert.
        @Presents public var alert: AlertState<Action.Alert>?

        /// 시작 게이트 판정용 — READY 페이로드 유무만 본다(질문 자체는 코디네이터가 세션에 시드).
        /// 재개 진입은 질문이 이미 있어 항상 true — 이 게이트를 서버 상태에 물리지 않는다.
        public var isQuestionPrepReady: Bool {
            if isResume { return true }
            if case .ready = questionPrep { return true }
            return false
        }

        public init(sessionId: Int, isResume: Bool = false) {
            self.sessionId = sessionId
            self.isResume = isResume
        }
    }

    public enum Action: ViewAction {
        case view(View)
        case inner(Inner)
        case alert(PresentationAction<Alert>)
        case delegate(Delegate)

        /// 사용자 입력·생명주기. View 의 send(...) 로만 방출된다.
        public enum View: Equatable, Sendable {
            case onAppear
            /// 포그라운드 복귀 — 설정에서 권한을 바꾸고 돌아왔을 수 있어 다시 읽는다.
            /// 코디네이터 뷰(InterviewView)도 같은 전이를 보지만 그건 재개 판정(checkResume)용이라 별개다.
            case sceneBecameActive
            /// 좌상단 뒤로가기 — 면접 흐름을 벗어난다(모달 없이 즉시, 아직 면접 전이라 되물을 게 없다).
            case userTappedBack
            case userTappedStart
        }

        /// effect 결과·리듀서 내부 신호. 리듀서만 방출한다.
        @CasePathable
        public enum Inner: Equatable, Sendable {
            /// phase 유지 시간 경과 — 다음 phase 로 진행할 시점.
            case phaseHoldFinished
            /// 질문 준비 폴링 해소 — READY 또는 FAILED (PROCESSING 은 계속 돈다).
            case questionPrepResolved(State.QuestionPrep)
            /// 진입 권한 요청 해소 — 카메라·마이크 **둘 다** 허용이면 true.
            case permissionsResolved(Bool)
            /// 프리뷰 해소 — 성공이면 핸들, 실패(권한 거부·장치 없음)면 nil. 실패여도 화면은 진행한다.
            case previewResolved(CameraPreviewHandle?)
        }

        /// 권한 미허용 alert 버튼.
        @CasePathable
        public enum Alert: Equatable, Sendable {
            /// 설정으로 이동 — 앱 권한 설정 화면을 연다.
            case openSettings
            /// 닫기 — alert 만 닫고 화면 유지. 시작 버튼은 설정에서 허용하고 돌아올 때까지 비활성이다.
            case close
        }

        /// 부모(코디네이터) 통보. 부모는 이것만 매칭한다 (D1).
        @CasePathable
        public enum Delegate: Equatable, Sendable {
            /// 뒤로가기 탭 — 면접 흐름 이탈. 캡처 정지·상위 통보는 코디네이터가 처리한다.
            case backRequested
            /// 면접 시작하기 탭(게이트 삼중 통과) — 세션 화면 전환은 코디네이터가 처리.
            case startRequested
            /// 질문 준비 최종 실패(서버 FAILED) — 실패 화면 전환은 코디네이터가 처리. 재시도 버튼 없음(PRD §3.2).
            case prepFailed
        }
    }

    private enum CancelID { case phaseTimer, prepPolling }

    @Dependency(\.continuousClock) var clock
    @Dependency(\.interviewClient) var interviewClient
    @Dependency(\.permissionClient) var permissionClient
    @Dependency(\.recordingClient) var recordingClient

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .view(.onAppear):
                guard !state.hasStarted else { return .none }
                state.hasStarted = true
                return .merge(
                    requestPermissionsAndStartPreview(),
                    // 재개는 질문이 이미 있다 — 준비 상태를 물을 이유가 없고, 시작 게이트도 이 폴링에 걸리지 않는다.
                    state.isResume ? .none : pollQuestionPrep(sessionId: state.sessionId),
                    scheduleAdvance(after: Self.aligningHold)
                )

            case .view(.sceneBecameActive):
                // 설정 왕복 복귀 — 진입 때 굳은 판정을 새 status 로 덮는다. 이미 허용이면 읽을 이유가 없고,
                // 아직 요청 전(onAppear 전)이면 그 요청이 판정을 세운다.
                guard state.hasStarted, !state.isMediaPermissionGranted else { return .none }
                // 거부는 앱이 다시 물을 수 없어 요청이 아니라 조회다 — 동기 status 로 충분(다이얼로그 없음).
                let allGranted = [MediaPermission.camera, .microphone]
                    .allSatisfy { permissionClient.status($0) == .granted }
                // 여전히 미허용이면 그대로 둔다 — 복귀할 때마다 alert 를 다시 띄우지는 않는다.
                guard allGranted else { return .none }
                state.isMediaPermissionGranted = true
                state.alert = nil   // 설정에서 허용하고 돌아왔다 — 안내가 소임을 다했다
                // 카메라가 거부인 동안 backdrop 이 placeholder 로 남아 있다 — 이제 실카메라로 바꾼다
                // (startPreview 는 멱등이라 이미 켜져 있으면 같은 핸들이 온다).
                guard state.previewHandle == nil else { return .none }
                return .run { send in
                    await send(.inner(.previewResolved(recordingClient.startPreview())))
                }

            case .view(.userTappedBack):
                // 아직 면접이 시작되지 않았다(질문 재생 전·답변 0개) — 되묻는 모달 없이 바로 흐름을 나간다.
                // 진행 중인 phase 타이머·질문 준비 폴링은 여기서 끊는다(코디네이터는 장치만 정지한다).
                return .merge(
                    .cancel(id: CancelID.phaseTimer),
                    .cancel(id: CancelID.prepPolling),
                    .send(.delegate(.backRequested))
                )

            case .view(.userTappedStart):
                guard state.phase == .guide2 else { return .none }
                // 질문 준비 전·권한 미허용이면 버튼이 비활성(뷰) — 여기 도달했다면 레이스뿐이라 조용히 무시.
                guard state.isQuestionPrepReady, state.isMediaPermissionGranted else { return .none }
                return .send(.delegate(.startRequested))

            case .inner(.phaseHoldFinished):
                if state.phase == .aligning {
                    state.isAligningHoldElapsed = true
                    return advanceFromAligningIfReady(&state)
                }
                return advancePhase(&state)

            case let .inner(.permissionsResolved(isGranted)):
                state.isMediaPermissionGranted = isGranted
                // 미허용은 진입 즉시 알린다 — 시작 버튼이 비활성이라 탭으로는 알릴 기회가 없다.
                if !isGranted { state.alert = Self.permissionDeniedAlert() }
                return .none

            case let .inner(.previewResolved(handle)):
                state.previewHandle = handle
                state.isPreviewResolved = true
                return advanceFromAligningIfReady(&state)

            case let .inner(.questionPrepResolved(result)):
                state.questionPrep = result
                return result == .failed ? .send(.delegate(.prepFailed)) : .none

            case .alert(.presented(.openSettings)):
                return .run { _ in await permissionClient.openSettings() }

            case .alert:
                // 닫기 포함 — alert 만 닫고 화면 유지(ifLet 이 dismiss 처리).
                // 재시도 지점은 설정 왕복 뒤의 복귀 재조회다(sceneBecameActive).
                return .none

            case .delegate:
                return .none
            }
        }
        .ifLet(\.$alert, action: \.alert)
    }

    /// 권한 미허용 시 설정 유도 alert(진입 시점). ⚠️ 문구는 임시 — PRD/PM 확정본 나오면 여기만 교체.
    static func permissionDeniedAlert() -> AlertState<Action.Alert> {
        AlertState {
            TextState("카메라·마이크 권한이 필요해요")
        } actions: {
            ButtonState(action: .openSettings) {
                TextState("설정으로 이동")
            }
            ButtonState(role: .cancel, action: .close) {
                TextState("닫기")
            }
        } message: {
            TextState("면접을 진행하려면 카메라와 마이크 권한이 모두 필요해요.\n설정에서 권한을 허용해주세요.")
        }
    }

    /// 진입 시 사용 시점 요청(PRD §8) — notDetermined 만 시스템 다이얼로그가 뜬다.
    /// 하나가 거부여도 나머지도 끝까지 요청한다 — 요청해야 설정 앱에 토글이 노출된다.
    /// 요청이 다 끝난 뒤 둘 다 허용인지 해소해 올린다 — 미허용이면 리듀서가 진입 alert 를 띄운다.
    /// 이어서 카메라 허용이면 프리뷰를 시작한다 — 거부·실패는 nil 해소로 placeholder 진행.
    private func requestPermissionsAndStartPreview() -> Effect<Action> {
        .run { send in
            for permission in [MediaPermission.camera, .microphone]
            where permissionClient.status(permission) == .notDetermined {
                _ = await permissionClient.request(permission)
            }
            let allGranted = [MediaPermission.camera, .microphone]
                .allSatisfy { permissionClient.status($0) == .granted }
            await send(.inner(.permissionsResolved(allGranted)))
            guard permissionClient.status(.camera) == .granted else {
                return await send(.inner(.previewResolved(nil)))
            }
            await send(.inner(.previewResolved(recordingClient.startPreview())))
        }
    }

    /// 질문 준비 폴링 (PRD §3.2) — 사용자 재시도 버튼 없이 «시스템이 알아서 다시 시도» = 폴링 지속.
    /// 네트워크 에러도 다음 틱 재시도로 흡수하고, 최종 실패 판정은 서버 FAILED 만 신뢰한다(클라 타임아웃 없음).
    /// READY 는 요약 질문을 동봉해 해소한다 — 페이로드 없는 READY 는 계약 위반이라 다음 틱을 계속 돈다.
    private func pollQuestionPrep(sessionId: Int) -> Effect<Action> {
        .run { send in
            while true {
                if let status = try? await interviewClient.sessionStatus(sessionId) {
                    if status.status == .ready, let summaryQuestion = status.summaryQuestion {
                        return await send(.inner(.questionPrepResolved(.ready(summaryQuestion))))
                    }
                    if status.status == .failed {
                        return await send(.inner(.questionPrepResolved(.failed)))
                    }
                }
                try await clock.sleep(for: Self.prepPollInterval)
            }
        }
        .cancellable(id: CancelID.prepPolling)
    }

    /// aligning→ready 이중 게이트 — 최소 유지 시간과 프리뷰 해소 중 늦게 온 신호가 전환을 트리거한다.
    private func advanceFromAligningIfReady(_ state: inout State) -> Effect<Action> {
        guard state.phase == .aligning, state.isAligningHoldElapsed, state.isPreviewResolved
        else { return .none }
        state.phase = .ready
        return scheduleAdvance(after: Self.readyHold)
    }

    /// ready → guide1 → guide2 한 칸 진행. guide2 는 종점 — 사용자 탭만 기다린다.
    private func advancePhase(_ state: inout State) -> Effect<Action> {
        switch state.phase {
        case .ready:
            state.phase = .guide1
            return scheduleAdvance(after: Self.guide1Hold)
        case .guide1:
            state.phase = .guide2
            return .none
        case .aligning, .guide2:
            // aligning 은 이중 게이트(advanceFromAligningIfReady)가 처리 — 여기 도달하지 않는다.
            return .none
        }
    }

    private func scheduleAdvance(after duration: Duration) -> Effect<Action> {
        .run { send in
            try await clock.sleep(for: duration)
            await send(.inner(.phaseHoldFinished))
        }
        .cancellable(id: CancelID.phaseTimer, cancelInFlight: true)
    }
}
