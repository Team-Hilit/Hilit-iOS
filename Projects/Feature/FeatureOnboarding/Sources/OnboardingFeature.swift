//
//  OnboardingFeature.swift
//  FeatureOnboarding
//
//  Created by EunSeo on 26/07/18.
//

import ComposableArchitecture
import Foundation

// @lat: [[onboarding#코디네이터]]
/// 온보딩 위저드 코디네이터. STEP 1(JD 업로드)을 루트로 두고, 이후 스텝은 `path`(StackState)로 push 한다.
/// 각 스텝의 delegate 만 매칭해 공유 데이터(OnboardingData)를 누적하고 다음 스텝으로 전환한다 (D5).
/// 스텝 자체 간 직접 의존은 없다 — 조립은 여기서만 (도메인 내 navigation = Path/StackState).
///
/// 직군·연차는 가입 온보딩(FeatureAuth)이 수집해 프로필에 등록하고, 세션 생성은 서버 프로필 스냅샷을
/// 쓰므로 이 위저드는 두 값을 아예 다루지 않는다 — 화면도, 페이로드도 없다.
@Reducer
public struct OnboardingFeature {
    /// 위저드 총 스텝 수 — 수집 스텝 3개(JD·포트폴리오·대표 프로젝트)가 프로그레스 3칸.
    /// 프리로드는 프로그레스 밖의 종결 화면이라 세지 않는다.
    public static let totalSteps = 3

    @Reducer
    public enum Path {
        case mainProject(OnboardingMainProjectFeature)          // STEP 3 대표 프로젝트(선택)
        case portfolioUpload(OnboardingPortfolioUploadFeature)  // STEP 2 포트폴리오
        case preload(OnboardingPreloadFeature)                  // 프리로드 — 수집 데이터 제출·완료 전환
    }

    // @Reducer enum 이 생성하는 Path.State 는 Equatable 을 자동 채택하지 않는다 —
    // StackState<Path.State> 를 담는 코디네이터 State 의 Equatable 합성을 위해 명시한다.

    /// 연관성 4회 실패 시 제시하는 두 선택지 — PRD S3.5.
    public static let relevanceFailureLimit = 4
    /// 연관성 실패(4회 미만) 시 대표 프로젝트에 노출하는 경고 (PRD 확정 문구).
    static let relevanceWarningMessage = "포트폴리오에서 그 내용을 찾지 못했어요.\n포트폴리오에 있는 프로젝트로 다시 적어주세요."
    /// 입력 draft 유효 기간 — PRD §4.4 (14일). 넘으면 폐기하고 새로 시작.
    static let draftTTL: TimeInterval = 60 * 60 * 24 * 14

    @ObservableState
    public struct State: Equatable {
        /// STEP 1 — 루트 화면(JD 업로드).
        public var jobDescriptionUpload: OnboardingJobDescriptionUploadFeature.State
        /// STEP 2+ 네비게이션 스택.
        public var path = StackState<Path.State>()
        /// 스텝을 거치며 누적되는 공유 페이로드.
        public var data: OnboardingData
        /// 대표 프로젝트 연관성 연속 실패 횟수 — PRD S3.5 (4회째 두 선택지 제시).
        public var relevanceFailureCount = 0
        /// 4회째 연관성 실패 시 뜨는 선택지 다이얼로그.
        @Presents public var relevanceChoice: ConfirmationDialogState<Action.RelevanceChoice>?
        /// draft 복원 1회성 가드. 루트 `onAppear` 는 뒤로가기로 루트에 되돌아올 때마다 재발동하는데,
        /// 복원 조건이 `path.isEmpty` 뿐이면 pop 으로 스택을 비운 순간 draft 를 다시 되쌓아 화면이 앞으로 튄다.
        /// 위저드 수명당 복원을 1회로 제한해 이 재복원을 막는다.
        var didAttemptRestore = false
        /// - Parameter userName: 타이틀 등에 쓰는 닉네임 — 부모(AppFeature)가 프로필에서 넘긴다.
        ///   직군·연차는 받지 않는다 — 가입 온보딩(FeatureAuth)이 프로필에 등록해 두고 세션 생성은
        ///   서버 프로필 스냅샷을 쓰므로(payload 에서 제거) 위저드가 들고 다닐 이유가 없다.
        public init(userName: String = "") {
            self.data = OnboardingData(userName: userName)
            self.jobDescriptionUpload = OnboardingJobDescriptionUploadFeature.State(
                step: 1,
                totalSteps: OnboardingFeature.totalSteps
            )
        }
    }

    public enum Action {
        case onAppear
        case jobDescriptionUpload(OnboardingJobDescriptionUploadFeature.Action)
        case path(StackActionOf<Path>)
        case relevanceChoice(PresentationAction<RelevanceChoice>)
        case delegate(Delegate)

        /// 연관성 4회 실패 다이얼로그의 선택지.
        public enum RelevanceChoice: Equatable, Sendable {
            /// 대표 프로젝트 없이 진행 — freeText 를 비우고 재분석한다.
            case proceedWithoutFocus
            /// 포트폴리오 다시 올리기 — STEP 2 로 되돌린다.
            case reuploadPortfolio
        }

        @CasePathable
        public enum Delegate: Equatable, Sendable {
            /// 중도 이탈 — X, 또는 루트(STEP 1)의 «이전으로». dismiss 는 부모(AppFeature)가 처리한다.
            case dismiss
            /// 온보딩 완료(프리로드까지 끝) — 준비된 세션 id 를 넘긴다. 부모가 Part2 진입 등으로 전환한다.
            case finished(sessionId: Int)
        }
    }

    @Dependency(\.onboardingDraftStore) var draftStore
    @Dependency(\.date) var date

    public init() {}

    public var body: some ReducerOf<Self> {
        Scope(state: \.jobDescriptionUpload, action: \.jobDescriptionUpload) {
            OnboardingJobDescriptionUploadFeature()
        }

        Reduce { state, action in
            switch action {
            // 진입 — 저장된 draft 가 있고 TTL 안이면 값·위저드 위치를 복원한다 (PRD §4.4).
            // 복원은 위저드 수명당 1회뿐 — 루트 onAppear 가 뒤로가기 복귀마다 재발동해도 재복원하지 않는다.
            case .onAppear:
                guard !state.didAttemptRestore else { return .none }
                state.didAttemptRestore = true
                guard state.path.isEmpty, let draft = draftStore.load() else { return .none }
                guard date.now.timeIntervalSince(draft.savedAt) < Self.draftTTL else {
                    return .run { [draftStore] _ in draftStore.clear() }
                }
                restore(&state, from: draft)
                return .none

            // STEP 1 JD(nil = 스킵) → 포트폴리오 push.
            case let .jobDescriptionUpload(.delegate(action)):
                switch action {
                case let .continueRequested(submission):
                    state.data.jd = submission
                    let step = portfolioStep()
                    state.path.append(step)
                    return persist(state)
                // 루트의 «이전으로» — 위저드 앞이 없으니 이탈과 같다. 어디로 돌아갈지는 부모가 정한다.
                case .backRequested, .closeRequested:
                    return .send(.delegate(.dismiss))
                }

            case .jobDescriptionUpload:
                return .none

            // STEP 2 포트폴리오 → 대표 프로젝트 push.
            case let .path(.element(id: _, action: .portfolioUpload(.delegate(action)))):
                switch action {
                case let .continueRequested(portfolioId, fileName):
                    state.data.portfolioId = portfolioId
                    state.data.portfolioFileName = fileName
                    state.path.append(.mainProject(.init(step: 3, totalSteps: Self.totalSteps)))
                    return persist(state)
                case .backRequested:
                    _ = state.path.popLast()
                    return .none
                case .closeRequested:
                    return .send(.delegate(.dismiss))
                }

            // STEP 3 대표 프로젝트(마지막 수집 스텝) → 누적 데이터를 들고 프리로드 push.
            case let .path(.element(id: _, action: .mainProject(.delegate(action)))):
                switch action {
                case let .continueRequested(freeText):
                    state.data.freeText = freeText
                    state.path.append(.preload(.init(data: state.data)))
                    return persist(state)
                case .backRequested:
                    _ = state.path.popLast()
                    return .none
                case .closeRequested:
                    return .send(.delegate(.dismiss))
                }

            // 프리로드 — 완료면 세션 id 를 들고 위저드 종료, 연관성 실패·실패 모달 [확인] 이면 대표 프로젝트로
            // 되돌림, 이용권 소진 [확인] 이면 이탈.
            case let .path(.element(id: _, action: .preload(.delegate(action)))):
                switch action {
                case let .completed(sessionId):
                    // draft 는 여기서 지우지 않는다 — 세션 생성은 면접의 시작일 뿐이고, 그 면접이 끝나기
                    // 전에 앱이 죽거나 이탈하면 다시 값이 필요하다. 폐기는 인터뷰 세션 완료 시점(AppFeature).
                    return .send(.delegate(.finished(sessionId: sessionId)))
                case .relevanceCheckFailed:
                    // PRD S3.5 — 연관성 부족 시 프리로드를 pop 하고 대표 프로젝트로 되돌린다.
                    state.relevanceFailureCount += 1
                    _ = state.path.popLast()
                    if state.relevanceFailureCount >= Self.relevanceFailureLimit {
                        // 4회째 — [포폴 다시 올리기 / 대표 프로젝트 없이 진행] 두 선택지.
                        state.relevanceChoice = Self.relevanceChoiceDialog()
                    } else {
                        // 그 전까지는 경고 문구와 함께 재입력을 유도한다.
                        setMainProjectWarning(&state, Self.relevanceWarningMessage)
                    }
                    return .none
                case .retryRequested:
                    // HLT-36 — 실패 모달 [확인] 은 집중 프로젝트로 돌아간다(Android 와 동일). 거기서 다시
                    // «계속하기» 를 누르면 새 프리로드가 세션을 새로 만든다. 연관성 카운트는 건드리지 않는다.
                    _ = state.path.popLast()
                    return .none
                case .closeRequested:
                    return .send(.delegate(.dismiss))
                }

            // 4회 실패 다이얼로그 — 포폴 재업로드(STEP2 복귀) / 대표 프로젝트 없이 재분석.
            case .relevanceChoice(.presented(.reuploadPortfolio)):
                state.relevanceFailureCount = 0
                _ = state.path.popLast()   // 대표 프로젝트도 pop → 포트폴리오 업로드(STEP2)
                return .none

            case .relevanceChoice(.presented(.proceedWithoutFocus)):
                state.relevanceFailureCount = 0
                state.data.freeText = nil
                state.path.append(.preload(.init(data: state.data)))
                return persist(state)

            case .relevanceChoice:
                return .none

            case .path:
                return .none

            case .delegate:
                return .none
            }
        }
        .forEach(\.path, action: \.path)
        .ifLet(\.$relevanceChoice, action: \.relevanceChoice)
    }

    /// STEP 2 스텝 State 를 만든다 — 빈 판으로 세울 때는 **매번** 기존 포트폴리오 조회를 켠다.
    /// 서버 READY 는 위저드 밖에서도 바뀐다(마이페이지 업로드·삭제, PROCESSING 승격) — 위저드 수명당
    /// 1회로 묶으면 두 번째 진입에서 재사용 가능한 포폴을 놓치고 register 가 409 로 떨어진다.
    /// 조회 자체의 중복 방지는 스텝 State 의 `checksExisting`(진입 1회) 가 담당한다.
    /// 이미 첨부된 판(draft 복원)으로 세울 땐 켜지 않는다: 물어볼 게 없다.
    private func portfolioStep(
        upload: OnboardingPortfolioUploadFeature.UploadState = .idle
    ) -> Path.State {
        let checksExisting = upload == .idle
        return .portfolioUpload(.init(
            step: 2,
            totalSteps: Self.totalSteps,
            upload: upload,
            checksExisting: checksExisting
        ))
    }

    /// 현재 data·위저드 위치를 draft 로 저장한다 — furthestStep 은 최상단 스텝(루트=1, path.count+1).
    private func persist(_ state: State) -> Effect<Action> {
        let draft = OnboardingDraft(
            data: state.data,
            furthestStep: state.path.count + 1,
            savedAt: date.now
        )
        return .run { [draftStore] _ in draftStore.save(draft) }
    }

    /// draft 로 data·위저드 위치를 복원한다 — 프리로드(4)는 복원하지 않고 대표 프로젝트(3)까지만 되쌓는다.
    private func restore(_ state: inout State, from draft: OnboardingDraft) {
        state.data = draft.data
        state.jobDescriptionUpload = OnboardingJobDescriptionUploadFeature.State(
            step: 1,
            totalSteps: Self.totalSteps,
            restoring: draft.data.jd
        )
        let total = Self.totalSteps
        let top = min(draft.furthestStep, total)
        if top >= 2 {
            let upload: OnboardingPortfolioUploadFeature.UploadState
            if let id = draft.data.portfolioId, let name = draft.data.portfolioFileName {
                upload = .uploaded(fileName: name, portfolioId: id)
            } else {
                upload = .idle
            }
            let step = portfolioStep(upload: upload)
            state.path.append(step)
        }
        if top >= 3 {
            state.path.append(.mainProject(.init(
                step: 3, totalSteps: total,
                projectDescription: draft.data.freeText ?? ""
            )))
        }
    }

    /// 스택 최상단(대표 프로젝트) 스텝에 연관성 경고 문구를 주입한다.
    private func setMainProjectWarning(_ state: inout State, _ message: String) {
        guard let lastId = state.path.ids.last,
              case var .mainProject(mainProject)? = state.path[id: lastId] else { return }
        mainProject.inputWarning = message
        state.path[id: lastId] = .mainProject(mainProject)
    }

    /// 연관성 4회 실패 다이얼로그 (PRD S3.5 확정 문구).
    static func relevanceChoiceDialog() -> ConfirmationDialogState<Action.RelevanceChoice> {
        ConfirmationDialogState {
            TextState("포트폴리오에서 그 내용을 계속 찾지 못했어요")
        } actions: {
            ButtonState(action: .reuploadPortfolio) { TextState("포트폴리오 다시 올리기") }
            ButtonState(action: .proceedWithoutFocus) { TextState("대표 프로젝트 없이 진행") }
            ButtonState(role: .cancel) { TextState("닫기") }
        } message: {
            TextState("포트폴리오를 다시 업로드하거나, 대표 프로젝트 없이 진행할 수 있어요.")
        }
    }
}

// Path.State(=@Reducer enum 생성물)에 Equatable 합성 — 모든 스텝 State 가 Equatable 이므로 성립.
extension OnboardingFeature.Path.State: Equatable {}
