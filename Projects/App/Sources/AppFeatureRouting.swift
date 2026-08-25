//
//  AppFeatureRouting.swift
//  Hilit
//
//  Created by 서정원 on 26/08/10.
//

import ComposableArchitecture
import CoreCommonInterface
import DomainAppVersionInterface
import DomainInterviewInterface
import Feature
import Foundation

// @lat: [[app#Cross-feature Routing]]
// AppFeature 의 라우팅 본문 — 타입 선언(AppFeature.swift)에서 갈라낸 별도 파일.
// 한 클로저에 다 넣으면 `body` 결과 빌더가 타입 체크 한계를 넘어(빌드 실패) 자식 갈래마다 함수로 나눴다.
// **분기 하나에 함수 하나** — 갈래 함수의 switch 는 그 자식 Action 을 받으므로 여기 dispatcher 는
// 최상위 case 만 본다(중첩 패턴을 섞지 않아 신규 case 누락을 컴파일러가 잡는다).
extension AppFeature {
    /// 액션 한 갈래를 고른다. 자식 Feature 는 갈래 함수로, 루트 자신의 신호는 여기서 끝낸다.
    func reduceCore(_ state: inout State, _ action: Action) -> Effect<Action> {
        switch action {
        case .onAppear:
            // dev 계에서만 Home 데이터 초기화 버튼을 노출한다.
            state.home.showsDevReset = AppEnvironment.isDev
            return startUpEffects()

        case .sceneBecameActive:
            // 면접 흐름이 떠 있으면 그 흐름이 스스로 판정한다([[interview#코디네이터]]) — 여기선 홈만 본다.
            guard state.interview == nil, state.onboarding == nil, state.root == .home else { return .none }
            return validateHeldSession()

        case .firstLaunchResolved:
            return resolveLaunchRouting()

        case .retryLaunchRouting:
            state.root = .splash
            return resolveLaunchRouting()

        case let .appVersionResolved(policy):
            return presentUpdateNotice(&state, policy)

        case let .updateAlert(action):
            return reduceUpdateAlert(&state, action)

        case .updateAlertReasserted:
            state.updateAlert = .update(isForced: true)
            return .none

        case let .launchRoutingResolved(routing):
            return apply(routing, to: &state)

        case let .deeplinkReceived(url):
            return presentGuestFeedback(&state, url)

        case .interviewAbandonResolved:
            // 버린 자리에서 곧장 새 면접 — 시작 경로는 [시작하기] 와 같은 온보딩 위저드다
            // (사용자 결정 2026-08-08). 홈 변형 갱신은 위저드를 닫고 돌아올 때 온다.
            state.onboarding = OnboardingFeature.State(userName: state.home.userName)
            return .none

        case let .interviewResumeResolved(sessionId, question):
            return presentResumedInterview(&state, sessionId: sessionId, question: question)

        case let .interviewReadinessResumeResolved(sessionId):
            // 시작 전 세션은 «되돌아가기» 다 — 같은 세션 id 로 준비 화면부터 다시 연다(새 세션을
            // 만들지 않는다: 그게 이용권을 한 장 더 잡는 경로였다).
            state.interview = InterviewFeature.State(sessionId: sessionId)
            return .none

        case .appDataCleared:
            return restartFromSplash(&state)

        case let .auth(action):
            return reduceAuth(&state, action)

        case let .guestFeedback(action):
            return reduceGuestFeedback(&state, action)

        case let .home(action):
            return reduceHome(&state, action)

        case let .interview(action):
            return reduceInterview(&state, action)

        case let .myPage(action):
            return reduceMyPage(&state, action)

        case let .myPageReport(action):
            return reduceMyPageReport(&state, action)

        case let .onboarding(action):
            return reduceOnboarding(&state, action)

        case let .report(action):
            return reduceReport(&state, action)

        case .binding:
            return .none
        }
    }

    // MARK: - 루트 자신의 전이

    /// 버전 안내를 세운다. FORCE 는 세션 판정 자체가 멈춘 상태라 루트를 옮겨 Splash 에 갇힌 것과 구분한다.
    private func presentUpdateNotice(_ state: inout State, _ policy: AppVersionPolicy) -> Effect<Action> {
        state.updatePolicy = policy
        let isForced = policy.updateType == .force
        if isForced { state.root = .updateRequired }
        state.updateAlert = .update(isForced: isForced)
        return .none
    }

    /// dev 데이터 초기화 직후 — 초기 State 로 되돌리고 **Splash 판정부터 다시** 태운다. 지운 게 세션만이
    /// 아니라 로컬 저장소 전부라, 재설치 직후와 같은 자리에서 시작해야 버전·동의·프로필 게이트가 다 돈다.
    private func restartFromSplash(_ state: inout State) -> Effect<Action> {
        state = State()
        state.home.showsDevReset = AppEnvironment.isDev
        return resolveLaunchRouting()
    }

    /// 공유 딥링크로 열리는 게스트 평가 — 무인증이라 루트(스플래시·로그인 전·홈) 무관하게 띄운다.
    /// 면접·온보딩 몰입 중엔 무시(흐름을 끊지 않는다 — 링크 재탭으로 복구되는 드문 엣지).
    /// 이미 게스트 cover 가 떠 있어도 무시 — 진행 중 평가를 다른 토큰으로 갈아치우지 않는다.
    private func presentGuestFeedback(_ state: inout State, _ url: URL) -> Effect<Action> {
        guard let token = GuestFeedbackDeeplink.parse(url),
              state.interview == nil, state.onboarding == nil, state.guestFeedback == nil
        else {
            // 버리는 이유를 남긴다 — 링크를 탭했는데 아무 일도 안 일어날 때, 형식이 틀린 것인지
            // 몰입 중이라 무시한 것인지 화면으로는 구분되지 않는다.
            if LogGate.isVerbose {
                let reason = GuestFeedbackDeeplink.parse(url) == nil ? "형식 불일치" : "다른 흐름 진행 중"
                print("🚧 [DEEPLINK] 진입 안 함(\(reason)) — \(url.absoluteString)")
            }
            return .none
        }
        if LogGate.isVerbose {
            print("🔗 [DEEPLINK] 게스트 평가 진입 — \(url.absoluteString)")
        }
        state.guestFeedback = GuestFeedbackFeature.State(token: token)
        return .none
    }

    /// 재개 진입(스펙 ④) — readiness 생략, confirmResume 의 최신 질문 + 표시용 근사초 시드.
    /// raw 축 확정은 세션 진입의 startRecording 반환(에셋 실측)이 한다. TODO(#69) 해소.
    private func presentResumedInterview(
        _ state: inout State,
        sessionId: Int,
        question: NextQuestion
    ) -> Effect<Action> {
        state.interview = InterviewFeature.State(sessionId: sessionId, resume: InterviewResumeSeed(
            question: question,
            approximateElapsedSeconds: heldSessionStore.load()?.recordedSeconds ?? 0
        ))
        return .none
    }

    // MARK: - 자식 갈래

    private func reduceAuth(_ state: inout State, _ action: AuthFeature.Action) -> Effect<Action> {
        guard case .delegate(.signedIn) = action else { return .none }
        // 새 로그인 = 새 세션. 이전 사용자가 하던 화면·데이터를 전부 버리고 초기 State 에서 시작한다.
        state = State()
        state.root = .home
        state.home.showsDevReset = AppEnvironment.isDev
        return .none
    }

    /// 게스트 평가를 닫는다. **도착지는 로그인 여부가 정한다** (사용자 결정 2026-08-14) —
    /// 로그인돼 있으면 홈, 아니면 소셜 로그인 화면. 둘 다 이미 루트가 들고 있는 상태라
    /// cover 만 걷으면 그 화면이 드러난다(`.home` / `.auth`).
    ///
    /// 손볼 게 남는 건 **판정이 안 끝난 루트**뿐이다 — 게스트는 링크로 들어와 루트 판정과 무관하게
    /// 뜨므로(무인증), 닫는 순간 루트가 아직 Splash 이거나 판정에 실패해 있을 수 있다.
    /// 그대로 걷으면 스플래시에 갇히니 판정을 다시 태워 홈/로그인 중 한쪽으로 내보낸다.
    /// 강제 업데이트(`.updateRequired`)는 그대로 막아 둔다 — 여기서 풀어 주면 차단이 뚫린다.
    private func reduceGuestFeedback(
        _ state: inout State,
        _ action: PresentationAction<GuestFeedbackFeature.Action>
    ) -> Effect<Action> {
        guard case .presented(.delegate(.dismissed)) = action else { return .none }
        state.guestFeedback = nil
        switch state.root {
        case .home, .auth, .updateRequired:
            return .none
        case .splash, .splashFailed:
            state.root = .splash
            return resolveLaunchRouting()
        }
    }

    /// 업데이트 안내 알럿 — «업데이트» 만 받는다(«나중에» 는 알럿을 닫는 것으로 끝).
    private func reduceUpdateAlert(
        _ state: inout State,
        _ action: PresentationAction<Action.UpdateAlert>
    ) -> Effect<Action> {
        guard case .presented(.userTappedUpdate) = action, let policy = state.updatePolicy else { return .none }
        return openStore(policy)
    }

    private func reduceHome(_ state: inout State, _ action: HomeFeature.Action) -> Effect<Action> {
        switch action {
        case .delegate(.interviewStartRequested):
            // 면접에 필요한 정보(직군·연차·JD·포폴)를 모으는 게 온보딩 위저드다 — 면접은 거기부터다.
            // 면접 화면은 **세션 id 로만** 열리는데(`InterviewFeature.State(sessionId:)`) 그 id 를 만드는
            // 건 위저드의 세션 생성뿐이라, 2회차 이후도 같은 위저드를 태운다(저장된 draft 가 살아 있으면
            // 위저드가 알아서 값을 복원한다 — TTL 14일, [[onboarding#코디네이터]]).
            // 진행 중·소진 시안엔 [시작하기] 가 없어(CTA 가 다르다) 나머지 변형은 도달하지 않는다.
            guard state.home.startInterview.variant == .first else { return .none }
            state.onboarding = OnboardingFeature.State(userName: state.home.userName)
            return .none

        // 진행 중(held) 면접 두 갈래 — 대상 세션 id 는 홈이 로컬 보관값에서 읽어 실어 준다.
        // [처음부터 시작] = 진행분을 **버리고** 새로, [이어서 진행] = 살아 있는 세션으로 복귀.
        case let .delegate(.interviewRestartRequested(sessionId)):
            return abandonHeldSession(sessionId)

        case let .delegate(.interviewResumeRequested(sessionId)):
            return resumeHeldSession(sessionId)

        case .delegate(.profileRequested):
            // 홈 내비바의 프로필 아이콘 — 마이페이지(Part5)를 홈 위에 한 장으로 얹는다.
            state.myPage = MyPageFeature.State()
            return .none

        case let .delegate(.reportDetailRequested(sessionId)):
            // 위젯② [레포트 보기] — 행 id = 세션 id. 채점 미완(404·GENERATING)도 그냥 연다
            // (폴링은 리포트 몫 — [[report#1차 리포트]]).
            state.report = ReportFeature.State(sessionId: sessionId)
            return .none

        case .delegate(.appDataResetRequested):
            // dev 전용 «재설치 흉내» — 서버 로그아웃 · Keychain 전체 · 온보딩 draft ·
            // 앱 UserDefaults 도메인 전체를 지운다. 서버 호출이 실패해도 로컬 정리는 그대로 진행한다.
            // 첫 실행 마커까지 함께 날리는 건 의도다 — 다음 콜드 스타트가 재설치 직후와 같은 자리에서
            // 정리를 한 번 더 돌게 된다(빈 저장소를 지우는 것이라 손해가 없다, [[app#첫 실행 정리]]).
            return resetAppData()

        default:
            return .none
        }
    }

    private func reduceInterview(
        _ state: inout State,
        _ action: PresentationAction<InterviewFeature.Action>
    ) -> Effect<Action> {
        switch action {
        // 면접 종료·이탈 모두 cover 를 닫고 홈을 다시 태운다 — 어느 쪽이든 잔여가 줄었고,
        // 리포트도 늘었을 수 있다(BACK_EXIT 이탈도 생성 트리거 — 2026-08-03 서버 계약).
        // 케이스를 합치지 않는 건 곧 갈라지기 때문이다: 정상 종료엔 리포트 상세(r1) 라우팅이 붙는다.
        // TODO: 정상 종료 → r1 직행. 커버(`state.report`)는 이미 있어 `finished` 가 sessionId 만 실어 주면 된다.
        //
        // 정상 종료 = 온보딩이 모은 입력이 제 역할을 다한 지점 — 여기서 온보딩 draft 를 폐기한다(PRD §4.4).
        // 세션 생성 시점에 지우지 않는 이유: 그 사이 앱이 죽거나 면접에서 이탈하면 값이 다시 필요하다.
        case .presented(.delegate(.finished)):
            state.interview = nil
            // 삭제는 effect 가 아니라 본문에서 — .merge(.run{clear}, .send(onAppear)) 로 두면
            // .send 가 먼저 도착해 홈이 지우기 전 보관값을 읽고, 끝난 면접이 [이어서 진행] 으로 뜬다
            // (홈의 held 판정은 onAppear 본문의 동기 load). 둘 다 동기·non-throwing 이라 가능하다.
            draftStore.clear()
            // 완주 = 더는 진행 중이 아니다 — 보관값을 지워 홈의 «진행 중» 판정을 끈다.
            heldSessionStore.clear()
            return .send(.home(.view(.onAppear)))

        // 동결 세션의 홈 경유(스펙 ③④) — cover 만 닫는다. held 는 **보존**(재개 재료 — 홈 재조회가
        // «진행 중» 카드를 그리고, «남은 질문 N개» 환산이 여기서 처음 실값을 받는다).
        // 도달 시점은 **백그라운드 진입 직후**다(2026-08-09 개정) — 사용자가 화면을 보고 있지 않을 때
        // 닫아야 복귀가 곧장 홈이다. 그새 세션이 끝났는지는 복귀 때 `sceneBecameActive` 가 묻는다.
        //
        // 이탈(`closed`)은 draft·보관값을 **둘 다 보존** — 같은 입력으로 다시 시작할 수 있어야 하고,
        // 진행 중인 세션이 그대로라 홈 [이어서 진행] 의 재개 재료다.
        case .presented(.delegate(.interrupted)), .presented(.delegate(.closed)):
            state.interview = nil
            return .send(.home(.view(.onAppear)))

        default:
            return .none
        }
    }

    private func reduceMyPage(
        _ state: inout State,
        _ action: PresentationAction<MyPageFeature.Action>
    ) -> Effect<Action> {
        switch action {
        // 마이페이지를 닫는다 — 그 안에서 포폴을 지우거나 새로 올렸을 수 있어 홈을 다시 태운다.
        // 「면접 시작」 카드와 기록이 그 값에 얹혀 있고, cover 를 닫는 것만으론 홈의 `onAppear` 가
        // 다시 오지 않는다(온보딩 이탈과 같은 이유).
        case .presented(.delegate(.closeRequested)):
            state.myPage = nil
            return .send(.home(.view(.onAppear)))

        // 세션 종료 두 신호 — 마이페이지가 서버 호출과 로컬 토큰 정리까지 끝낸 뒤 통보한다(완료형).
        // 여기서 할 일은 라우팅뿐이다: 이전 사용자의 화면·데이터를 전부 버리고 로그인부터 다시 —
        // 로그인 성공(`.auth` → 초기 State + home)의 대칭이다.
        case .presented(.delegate(.loggedOut)), .presented(.delegate(.withdrawn)):
            state = State()
            state.root = .auth
            return .none

        // 리포트 줄의 두 버튼 — 행 id = 세션 id 라 홈 위젯②와 재료가 같다.
        // 마이페이지는 **닫지 않고 그 위에 얹는다**: 목록에서 들어왔으니 닫으면 목록이 도착지다.
        case let .presented(.delegate(.reportRequested(id))):
            state.myPageReport = ReportFeature.State(sessionId: id)
            return .none

        // [지인 피드백 받기] 는 링크 생성 화면이 목적지다 — 리포트 메인을 거치지 않고 그 위에서 연다.
        case let .presented(.delegate(.feedbackRequested(id))):
            state.myPageReport = ReportFeature.State(sessionId: id, entry: .peerFeedback)
            return .none

        default:
            return .none
        }
    }

    /// 마이페이지 위 리포트의 이탈 — cover 만 걷으면 아래 마이페이지가 그대로 드러난다.
    /// 홈은 다시 태우지 않는다: 리포트를 읽거나 링크를 만드는 동안 잔여·목록이 바뀌지 않는다.
    private func reduceMyPageReport(
        _ state: inout State,
        _ action: PresentationAction<ReportFeature.Action>
    ) -> Effect<Action> {
        guard case .presented(.delegate(.closeRequested)) = action else { return .none }
        state.myPageReport = nil
        return .none
    }

    private func reduceOnboarding(
        _ state: inout State,
        _ action: PresentationAction<OnboardingFeature.Action>
    ) -> Effect<Action> {
        switch action {
        // 온보딩 완주 = 분석까지 끝나 세션이 준비된 상태 — 위저드를 닫고 그 세션으로 면접을 연다.
        // 홈은 안 태운다 — 어차피 면접에 가려지고, 갱신 시점은 면접이 끝나 돌아올 때다.
        //
        // 진행 중 보관을 **여기서** 연다(2026-08-21 복원) — 서버 세션이 생긴 바로 그 순간이다.
        // 2026-08-18(#130)엔 이걸 시작하기 탭으로 미뤘는데, 그 사이 준비 화면에서 이탈하면 서버엔
        // IN_PROGRESS 가 남고 로컬엔 흔적이 없어 회수 경로(입구가 전부 `load()`)가 통째로 죽었다.
        // 카드가 뜨던 문제는 여는 시점이 아니라 `hasStarted` 로 가린다 — 홈은 그 술어를 본다.
        //
        // effect 가 아니라 본문에서 저장한다 — `.dismiss` 의 clear 와 같은 이유로 순서가 걸린다.
        case let .presented(.delegate(.finished(sessionId))):
            state.onboarding = nil
            state.interview = InterviewFeature.State(sessionId: sessionId)
            heldSessionStore.save(HeldSession(
                sessionId: sessionId,
                recordedSeconds: 0,
                // 아직 [시작하기] 전 — [이어서 진행] 을 준비 화면으로 되돌릴지 가르는 재료다.
                hasStarted: false,
                // 표식은 **찍지 않는다** — 표식의 뜻은 «이 프로세스가 세그먼트를 들고 있다» 이고,
                // 시작 전엔 세그먼트가 없어 잃을 것이 없다. 찍으면 앱을 껐다 켠 순간 킬 클린업이
                // 죽은 프로세스 값으로 보고 세션을 닫아, 잡힌 이용권이 회수 동선 없이 사라진다.
                processToken: nil
            ))
            return .none

        // 중도 이탈 — 위저드만 닫고 홈을 다시 태운다. cover 를 닫는 것만으론 홈의
        // `onAppear` 가 다시 오지 않아 여기서 명시로 보낸다(겸사겸사 시트도 기본 자리로 —
        // 위저드를 다녀온 뒤 면접 시작 겹에 그대로 서 있지 않는다).
        case .presented(.delegate(.dismiss)):
            state.onboarding = nil
            return .send(.home(.view(.onAppear)))

        default:
            return .none
        }
    }

    /// 홈에서 연 리포트가 올리는 신호는 이탈(X) 하나 — 커버만 닫는다(리포트를 읽는 동안
    /// 잔여·목록이 바뀌지 않아 홈 재조회가 없다).
    private func reduceReport(
        _ state: inout State,
        _ action: PresentationAction<ReportFeature.Action>
    ) -> Effect<Action> {
        guard case .presented(.delegate(.closeRequested)) = action else { return .none }
        state.report = nil
        return .none
    }
}

// MARK: - 업데이트 안내

// TODO: 시안 수령 시 OS 기본 Alert → 전용 화면/시트로 교체. 문구도 그때 확정한다.
private extension AlertState where Action == AppFeature.Action.UpdateAlert {
    /// 강제면 «나중에» 를 만들지 않는다 — 버튼이 하나뿐이라 알럿을 닫고 앱을 쓸 길이 없다.
    static func update(isForced: Bool) -> Self {
        AlertState {
            TextState(isForced ? "업데이트가 필요해요" : "새 버전이 나왔어요")
        } actions: {
            ButtonState(action: .userTappedUpdate) { TextState("업데이트") }
            if !isForced {
                ButtonState(role: .cancel, action: .userTappedLater) { TextState("나중에") }
            }
        } message: {
            TextState(
                isForced
                    ? "계속 사용하려면 최신 버전으로 업데이트해주세요."
                    : "더 편해진 기능을 쓰려면 업데이트해주세요."
            )
        }
    }
}
