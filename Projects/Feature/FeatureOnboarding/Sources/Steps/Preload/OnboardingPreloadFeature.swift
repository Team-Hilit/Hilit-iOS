//
//  OnboardingPreloadFeature.swift
//  FeatureOnboarding
//
//  Created by EunSeo on 26/07/19.
//

import ComposableArchitecture
import DomainInterviewInterface
import DomainJDInterface

// @lat: [[onboarding#프리로드]]
/// 온보딩 마지막 스텝 프리로드 — 분석 중/분석 완료 (Figma «Onboarding_preload» 443:9768).
/// 진행 대시 밖에 있는 종착 화면이라 step/totalSteps 를 받지 않는다.
/// 앞선 스텝들이 채운 OnboardingData 를 InterviewConfig 로 변환해 세션 생성(PRD §3.8 — S0~S3 일괄 수집)을
/// 요청하고, PROCESSING 이면 status 를 폴링해 READY 를 기다린다.
/// 체크리스트 3행은 순차 진행 — 1·2행은 가짜 타이머로 차례로 체크되고, 마지막 행만 실제 세션 READY 에
/// 묶인다(가짜 2행 완료 AND READY). 3행 체크를 잠깐 보여준 뒤 **그린 사면이 위로 올라와 화면을 덮는
/// 전환**(filling)을 거쳐 완료 화면 → 유지 시간 경과 → delegate(.completed(sessionId:))로 세션을
/// 코디네이터에 넘긴다 — dismiss·Part2 진입은 코디네이터 몫. READY 를 받자마자 넘기지 않는 이유가
/// 이 전환이다.
/// 실패는 화면 위 **모달**로 알린다(HLT-36 — Android 와 같은 «확인 → 집중 프로젝트» 복귀). 준비 중 이탈
/// 경로(X)는 두지 않는다 — 모달의 [확인] 이 유일한 출구다.
@Reducer
public struct OnboardingPreloadFeature {
    /// 세션 준비 상태 폴링 주기 — InterviewClient 가이드(3~5초)의 하한.
    static let pollInterval: Duration = .seconds(3)
    /// 완료 화면 노출 유지 시간 — 지나면 자동으로 delegate(.completed)를 올린다.
    static let completionHoldDuration: Duration = .seconds(2)
    /// 가짜 진행 스테이지(1·2행) 각각의 유지 시간 — API 진행률이 없어 연출로 채운다.
    /// 포폴 업로드 진행 바는 이제 연출을 걷고 단계 마커(`UploadState.phaseProgress`)를 쓴다 — 다른 계다.
    /// 여기서 연출이 남는 이유: 이 화면은 «준비 중» 자체가 콘텐츠라 정지하면 화면이 죽는다.
    static let stageDuration: Duration = .milliseconds(1200)
    /// 3행이 체크로 바뀐 상태의 노출 유지 — 지나면 그린 사면 채우기로 넘어간다.
    static let finalCheckHold: Duration = .milliseconds(500)
    /// 그린 사면이 올라와 화면을 덮는 시간. View 의 사면 애니메이션과 **같은 값을 써야** 완료 문구가
    /// 다 덮인 뒤에 나온다 — 그래서 Duration 이 아니라 초(Double)로 두고 양쪽이 공유한다.
    static let fillSeconds: Double = 0.9
    /// 세션 생성/폴링 실패 문구 — 재시도 버튼은 없다(PRD §3.1). [확인] 이 집중 프로젝트로 되돌리고,
    /// 다시 «계속하기» 를 누르면 세션을 새로 만든다.
    static let failureMessage = "잠시 후 다시 시도해 주세요."
    /// 이용권 소진(403 `NO_REMAINING_TICKET`) 문구 — 위저드 안에선 풀 수 없어 [확인] 이 위저드를 닫는다.
    static let noRemainingTicketMessage = "남은 이용권이 없어요."
    /// 수집 데이터가 불완전해 세션 입력을 만들지 못한 경우 — 위저드 순서상 정상 진입이면 발생하지 않는다.
    static let configMissingMessage = "면접 준비에 필요한 정보가 부족해요.\n다시 시도해 주세요."

    @ObservableState
    public struct State: Equatable {
        /// 화면 하위 상태 — 분석 중 → 채우기 → 완료 / 실패. 별도 화면 push 없이 이 값으로 전환한다.
        public enum Phase: Equatable, Sendable {
            case analyzing
            /// 그린 사면이 올라와 화면을 덮는 구간 — 분석 텍스트는 사라지고 완료 문구는 아직 없다.
            case filling
            case completed
            /// 세션 생성·폴링 실패 — 분석 판 위에 실패 모달을 띄운다. [확인] 의 갈래는 `Failure` 가 정한다.
            case failed(Failure)
        }

        /// 실패 종류 — 모달 문구와 [확인] 의 목적지가 함께 갈린다.
        public enum Failure: Equatable, Sendable {
            /// 일반 실패 — [확인] 이 집중 프로젝트로 되돌린다(거기서 «계속하기» = 새 세션 생성).
            case retry(message: String)
            /// 이용권 소진 — 위저드 안에선 풀 수 없어 [확인] 이 위저드를 닫는다(홈이 소진 안내를 그린다).
            case noRemainingTicket

            /// 모달 서브 문구.
            public var message: String {
                switch self {
                case let .retry(message): message
                case .noRemainingTicket: OnboardingPreloadFeature.noRemainingTicketMessage
                }
            }
        }

        /// 앞선 스텝들이 수집한 공유 페이로드 — 세션 생성 입력. 코디네이터가 주입한다.
        public var data: OnboardingData
        public var phase: Phase = .analyzing
        /// 생성된 세션 id — READY 후 delegate 로 코디네이터에 넘긴다.
        public var sessionId: Int?
        /// onAppear 재진입 가드 — 분석 effect 중복 실행 방지.
        public var hasStartedAnalysis = false
        /// JD 검증 만료 복구 1회성 가드 — 서버 JD 캐시 만료(JD_NOT_VALIDATED) 시 재검증 후 세션 생성을
        /// 딱 한 번만 재시도한다(재검증해도 또 거부되면 무한 루프 대신 실패 처리).
        public var didRetryJDValidation = false
        /// 체크로 바뀐 체크리스트 행 수(0~3). 1·2행은 가짜 타이머가, 3행은 세션 READY 가 채운다.
        public var completedStages = 0
        /// 세션 READY 도달 여부 — 가짜 스테이지와 독립 기록. 둘 다 끝나야 3행이 체크된다.
        public var isSessionReady = false

        public init(data: OnboardingData) {
            self.data = data
        }
    }

    public enum Action: ViewAction {
        case view(View)
        case inner(Inner)
        case delegate(Delegate)

        /// 사용자 입력·생명주기. View 의 send(...) 로만 방출된다.
        public enum View: Equatable, Sendable {
            case onAppear
            /// 실패 모달 [확인] — 실패 종류에 따라 집중 프로젝트 복귀 또는 위저드 이탈.
            case userTappedFailureConfirm
        }

        /// effect 결과·리듀서 내부 신호. 리듀서만 방출한다.
        @CasePathable
        public enum Inner: Equatable, Sendable {
            /// POST /interview/sessions 접수 응답 (202 PROCESSING).
            case sessionCreated(InterviewSessionCreated)
            /// GET /interview/sessions/{id}/status 폴링 응답.
            case statusPolled(InterviewSessionStatus)
            /// 세션 생성·폴링 실패 — 실패 모달로 전환.
            case analysisFailed(State.Failure)
            /// 집중 프로젝트 연관성 부족(FREETEXT_NOT_RELEVANT) — 코디네이터가 집중 프로젝트로 되돌린다.
            case relevanceCheckFailed
            /// 서버 JD 검증 캐시 만료(JD_NOT_VALIDATED) — 저장된 링크로 재검증 복구를 시도한다.
            case jdValidationExpired
            /// JD 재검증 성공 — 세션 생성을 재시도한다.
            case sessionRetryRequested
            /// 가짜 진행 타이머 틱 — 1·2행을 차례로 체크로 바꾼다.
            case stageAdvanced
            /// 3행 체크 노출 유지 경과 — 그린 사면 채우기를 시작할 시점.
            case finalCheckShown
            /// 사면이 화면을 다 덮은 시점 — 완료 문구를 띄운다.
            case fillFinished
            /// 완료 화면 유지 시간 경과 — 온보딩 완료 신호를 올릴 시점.
            case completionHoldFinished
        }

        /// 코디네이터(OnboardingFeature) 통보. 부모는 이것만 매칭한다 (D1).
        @CasePathable
        public enum Delegate: Equatable, Sendable {
            /// 온보딩 전체 완료 — 준비된 세션 id 를 넘긴다. 화면 전환(Part2 진입)은 코디네이터가 처리.
            case completed(sessionId: Int)
            /// 집중 프로젝트 연관성 부족 — 코디네이터가 집중 프로젝트 스텝으로 pop-back 한다 (PRD S3.5).
            case relevanceCheckFailed
            /// 실패 모달 [확인](일반 실패) — 코디네이터가 집중 프로젝트로 pop-back 한다(HLT-36).
            case retryRequested
            /// 이용권 소진 모달 [확인] — 위저드 이탈. dismiss 는 코디네이터 몫.
            case closeRequested
        }
    }

    private enum CancelID { case session, stageTimer }

    @Dependency(\.interviewClient) var interviewClient
    @Dependency(\.jdClient) var jdClient
    @Dependency(\.continuousClock) var clock

    public init() {}

    public var body: some ReducerOf<Self> {
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
        case .onAppear:
            guard !state.hasStartedAnalysis else { return .none }
            state.hasStartedAnalysis = true
            guard let config = state.data.interviewConfig() else {
                return .send(.inner(.analysisFailed(.retry(message: Self.configMissingMessage))))
            }
            return .merge(
                startSession(config: config),
                // 가짜 진행 — 1·2행을 stageDuration 간격으로 체크. 3행은 세션 READY 가 채운다.
                .run { send in
                    for _ in 0..<2 {
                        try await clock.sleep(for: Self.stageDuration)
                        await send(.inner(.stageAdvanced))
                    }
                }
                .cancellable(id: CancelID.stageTimer)
            )

        case .userTappedFailureConfirm:
            guard case let .failed(failure) = state.phase else { return .none }
            switch failure {
            case .retry:
                return .send(.delegate(.retryRequested))
            case .noRemainingTicket:
                return .send(.delegate(.closeRequested))
            }
        }
    }

    private func reduceInner(_ state: inout State, _ action: Action.Inner) -> Effect<Action> {
        switch action {
        case let .sessionCreated(created):
            state.sessionId = created.sessionId
            return pollStatus(sessionId: created.sessionId)

        case let .statusPolled(status):
            return reduceStatus(&state, status)

        case let .analysisFailed(failure):
            state.phase = .failed(failure)
            return .cancel(id: CancelID.stageTimer)

        case .relevanceCheckFailed:
            // 화면 상태는 두지 않는다 — 코디네이터가 집중 프로젝트로 즉시 pop-back 한다.
            return .merge(
                .send(.delegate(.relevanceCheckFailed)),
                .cancel(id: CancelID.stageTimer)
            )

        case .jdValidationExpired:
            return recoverFromJDExpiry(&state)

        case .sessionRetryRequested:
            guard let config = state.data.interviewConfig() else {
                return .send(.inner(.analysisFailed(.retry(message: Self.configMissingMessage))))
            }
            return startSession(config: config)

        case .stageAdvanced:
            guard state.phase == .analyzing else { return .none }
            state.completedStages = min(state.completedStages + 1, 2)
            return completeFinalStageIfReady(&state)

        case .finalCheckShown:
            state.phase = .filling
            return .run { send in
                try await clock.sleep(for: .seconds(Self.fillSeconds))
                await send(.inner(.fillFinished))
            }
            .cancellable(id: CancelID.session)

        case .fillFinished:
            state.phase = .completed
            return .run { send in
                try await clock.sleep(for: Self.completionHoldDuration)
                await send(.inner(.completionHoldFinished))
            }
            .cancellable(id: CancelID.session)

        case .completionHoldFinished:
            guard let sessionId = state.sessionId else { return .none }
            return .send(.delegate(.completed(sessionId: sessionId)))
        }
    }

    /// 가짜 스테이지(1·2행)와 세션 READY 가 모두 끝났을 때만 3행을 체크로 바꾼다 —
    /// 어느 쪽이 먼저 끝나든 나중에 끝나는 쪽의 액션에서 이 조건이 성립한다.
    private func completeFinalStageIfReady(_ state: inout State) -> Effect<Action> {
        guard state.isSessionReady, state.completedStages == 2 else { return .none }
        state.completedStages = 3
        return .run { send in
            try await clock.sleep(for: Self.finalCheckHold)
            await send(.inner(.finalCheckShown))
        }
        .cancellable(id: CancelID.session)
    }

    /// 세션 준비 상태 응답 처리 — READY 는 3행 완료 판정, PROCESSING 은 폴링 지속, FAILED 는 실패 화면.
    private func reduceStatus(_ state: inout State, _ status: InterviewSessionStatus) -> Effect<Action> {
        switch status.status {
        case .ready:
            state.isSessionReady = true
            return completeFinalStageIfReady(&state)
        case .processing:
            guard let sessionId = state.sessionId else { return .none }
            return .run { send in
                try await clock.sleep(for: Self.pollInterval)
                await send(.inner(.statusPolled(try await interviewClient.sessionStatus(sessionId))))
            } catch: { _, send in
                await send(.inner(.analysisFailed(.retry(message: Self.failureMessage))))
            }
            .cancellable(id: CancelID.session)
        case .failed:
            state.phase = .failed(.retry(message: Self.failureMessage))
            return .cancel(id: CancelID.stageTimer)
        }
    }

    /// 서버 JD 검증 캐시 만료(JD_NOT_VALIDATED) 복구 — 저장된 링크로 1회 재검증해 세션 생성을 재시도한다.
    /// draft 는 jd 를 영구 유효로 착각하므로 서버 부작용 직전에 서버와 화해한다(draft=재개 힌트, 서버=진실).
    /// 재검증해도 invalid 이거나 링크가 아니면(직접 입력·스킵) 복구 불가 — 실패 처리.
    private func recoverFromJDExpiry(_ state: inout State) -> Effect<Action> {
        guard !state.didRetryJDValidation else {
            return .send(.inner(.analysisFailed(.retry(message: Self.failureMessage))))
        }
        state.didRetryJDValidation = true
        guard case let .link(jdURL) = state.data.jd else {
            return .send(.inner(.analysisFailed(.retry(message: Self.failureMessage))))
        }
        return .run { send in
            let validation = try await jdClient.validate(jdURL)
            await send(.inner(validation.valid
                ? .sessionRetryRequested
                : .analysisFailed(.retry(message: Self.failureMessage))))
        } catch: { _, send in
            await send(.inner(.analysisFailed(.retry(message: Self.failureMessage))))
        }
        .cancellable(id: CancelID.session)
    }

    /// 세션 생성 요청 — onAppear 최초 시도와 JD 재검증 후 재시도가 공유한다.
    /// 에러는 종류별로 분기한다: 연관성 부족 → 코디네이터 pop-back, JD 검증 만료 → 재검증 복구,
    /// 이용권 소진 → 위저드 이탈 모달, 그 외 → 실패 모달.
    private func startSession(config: InterviewConfig) -> Effect<Action> {
        .run { send in
            await send(.inner(.sessionCreated(try await interviewClient.createSession(config))))
        } catch: { error, send in
            switch error as? InterviewError {
            case .freeTextNotRelevant?:
                await send(.inner(.relevanceCheckFailed))
            case .jdNotValidated?:
                await send(.inner(.jdValidationExpired))
            case .noRemainingTicket?:
                await send(.inner(.analysisFailed(.noRemainingTicket)))
            default:
                await send(.inner(.analysisFailed(.retry(message: Self.failureMessage))))
            }
        }
        .cancellable(id: CancelID.session)
    }

    /// 접수(sessionCreated) 후 첫 상태 조회 — PROCESSING 이면 이후 statusPolled 가 폴링을 잇는다.
    private func pollStatus(sessionId: Int) -> Effect<Action> {
        .run { send in
            await send(.inner(.statusPolled(try await interviewClient.sessionStatus(sessionId))))
        } catch: { _, send in
            await send(.inner(.analysisFailed(.retry(message: Self.failureMessage))))
        }
        .cancellable(id: CancelID.session)
    }
}
