//
//  AppFeature.swift
//  Hilit
//
//  Created by 서정원 on 26/07/13.
//

import ComposableArchitecture
import CoreCommonInterface
import DomainAppVersionInterface
import DomainAuthInterface
import DomainConsentInterface
import DomainInterviewInterface
import DomainRecordingInterface
import Feature
import Foundation

// @lat: [[app]]
// depends-on: [[auth]] — 로그인 전/후 루트 게이트. cross-feature 조립은 AppFeature 에서만.
// depends-on: [[deeplink#두 경로]] — 링크 도착이 둘(설치 상태 onOpenURL · deferred 스트림)이라 진입 신호도 둘이다.
//                             같은 링크가 양쪽으로 겹쳐 와도 진행 중 평가는 덮이지 않는다(presentGuestFeedback 가드).
// depends-on: [[feedback#진입로와 닫기]] — 공유 링크(유니버설 링크 https + 개발용 hilit:// 스킴)가 게스트 평가를
// 루트 밖 cover 로 present. 무인증 플로우라 루트(스플래시·auth·home) 무관, delegate(.dismissed)로 닫는다.
// depends-on: [[home]] — Home 을 로그인 후 루트로 임베드(owner). cross-feature delegate 라우팅은 Feature 추가 시 이 자리에서 조립.
// depends-on: [[interview]] — 온보딩 완주 delegate(.finished(sessionId)) 를 받아 면접 흐름을 present. 종료 두 신호(.finished/.closed)는 cover 를 닫고 홈을 다시 태운다.
// depends-on: [[mypage]] — 홈 내비바 프로필 delegate(.profileRequested) 로 present. 완료형 두 신호(.loggedOut/.withdrawn)는 루트를 로그인으로 되돌린다.
//                             리포트 줄 두 버튼(.reportRequested/.feedbackRequested)은 마이페이지를 **덮는** 별도 리포트 커버(`myPageReport`)를 세운다 — 목록이 도착지라서다.
//                             홈의 진행 중 두 갈래(중단·재개)도 여기서 InterviewClient·HeldSessionStore 로 배선한다.
//                             .interrupted(백그라운드 동결 세션의 홈 경유)는 cover 만 닫고 held 를 보존한다 — [[interview#코디네이터]].
// depends-on: [[interview#프리뷰]] — 앱 사망 세션 정리가 RecordingClient.purgeRecordings 로 죽은 프로세스의 잔존 세그먼트를 걷는다.
// depends-on: [[onboarding]] — dev 전용 진입(Home 버튼)으로 온보딩 위저드를 present. 조립은 여기서만 (온보딩 본체 통합 전 임시).
// depends-on: [[report]] — 홈 위젯②의 [레포트 보기] delegate 를 받아 리포트 커버를 세션 id 로 present. 리포트의 두 신호(닫기·다시 연습)도 여기서 받는다.
//                            마이페이지발 진입은 같은 Feature 를 **다른 자리**(`myPageReport`)에 세운다 — 링크 생성 직행은 `entry: .peerFeedback`.
@Reducer
struct AppFeature {
    /// 루트가 지금 무엇을 띄우는가. Bool 조합으로는 «재시도 가능한 판정 실패» 를 표현할 수 없어 값으로 둔다.
    /// 전이는 Splash 판정(`onAppear`) → auth 또는 home 단방향이고, 로그아웃·세션 만료만 되돌린다.
    enum Root: Equatable {
        /// 세션 복구 판정 중 — SplashView.
        case splash
        /// 판정이 네트워크·서버 문제로 실패 — 토큰은 살아 있다. Splash 자리에서 재시도만 받는다.
        case splashFailed
        /// 강제 업데이트(FORCE) — 세션 판정 자체를 하지 않고 진입을 막는다. 재시도로 빠져나올 수 없다.
        case updateRequired
        /// 로그인 전 또는 가입 플로우(약관·온보딩) 진행 중.
        case auth
        /// 두 게이트 모두 통과 — 홈 화면.
        case home
    }

    @ObservableState
    struct State: Equatable {
        var auth = AuthFeature.State()
        /// 게스트 평가(G4) — 공유 딥링크로 열린다. 무인증이라 루트 무관 cover.
        @Presents var guestFeedback: GuestFeedbackFeature.State?
        /// 루트가 무엇을 띄우는지 — 초기값은 Splash(판정 전).
        var root: Root = .splash
        var home = HomeFeature.State()
        /// 면접 흐름(Part2) — 온보딩 완주가 넘긴 sessionId 로 연다. 전면 몰입이라 fullScreenCover.
        @Presents var interview: InterviewFeature.State?
        /// 마이페이지(Part5) — 홈 위젯③ 이 연다. 탭이 아니라 한 장짜리 present 화면이다.
        @Presents var myPage: MyPageFeature.State?
        /// 마이페이지 리포트 줄이 연 리포트 — 홈 경로의 `report` 와 **자리를 나눠 갖는다**.
        /// 하나로 합치면 두 cover(루트·마이페이지 위)가 같은 값을 동시에 present 하려 들어 화면이 깨진다.
        /// 마이페이지를 닫지 않고 그 위에 얹는 건 도착지 때문이다 — 목록에서 왔으니 닫으면 목록이다.
        @Presents var myPageReport: ReportFeature.State?
        /// 온보딩 위저드 — 「면접 시작」의 [시작하기]·[처음부터 시작](중단 후) 이 present 한다.
        @Presents var onboarding: OnboardingFeature.State?
        /// AI 면접 리포트 — 홈 위젯②의 [레포트 보기] 가 세션 id 로 연다. 자체 NavigationStack 을 가진 전면 흐름이라 cover.
        @Presents var report: ReportFeature.State?
        /// 업데이트 안내(강제·권장)의 근거 — «업데이트» 가 열 `storeUrl` 과 강제 여부를 여기서 읽는다.
        var updatePolicy: AppVersionPolicy?
        @Presents var updateAlert: AlertState<Action.UpdateAlert>?
    }

    enum Action: BindableAction {
        case onAppear
        /// 포그라운드 복귀 — 홈에 남은 보관값이 아직 살아 있는 세션인지 확인한다.
        case sceneBecameActive
        /// 첫 실행 정리가 끝났다 — 이제 세션 복구 판정을 시작해도 된다.
        case firstLaunchResolved
        /// Splash 판정 실패 후 재시도.
        case retryLaunchRouting
        /// 버전 게이트 판정 결과 — 안내가 필요한 FORCE·OPTIONAL 만 도달한다.
        case appVersionResolved(AppVersionPolicy)
        /// 강제 업데이트에서 스토어를 다녀온 뒤 — 차단을 유지하려 같은 알럿을 다시 세운다.
        case updateAlertReasserted
        case updateAlert(PresentationAction<UpdateAlert>)
        /// 세션 복구 판정 결과 — 목적지 또는 실패 종류.
        case launchRoutingResolved(LaunchRouting)
        /// 외부 링크 수신 — 커스텀 스킴(`hilit://`)과 유니버설 링크(https) 둘 다 여기로 온다.
        /// 현재 아는 형식은 게스트 평가 하나뿐이고, 나머지는 파서가 걸러 조용히 버린다.
        case deeplinkReceived(URL)
        case auth(AuthFeature.Action)
        case guestFeedback(PresentationAction<GuestFeedbackFeature.Action>)
        case home(HomeFeature.Action)
        /// 진행 중 세션 중단(abandon) 처리 완료 — 이미 중단된 세션(409)도 여기로 온다.
        /// 보관값까지 지운 뒤라 남은 일은 새 면접을 시작하는 것뿐이다.
        case interviewAbandonResolved
        /// 재개 확정 완료 — 이 세션으로 면접 화면을 연다. 최신 질문은 확정 응답이 실어 준 것 그대로다
        /// (재개 진입은 readiness 를 생략해 질문을 다시 물을 자리가 없다).
        case interviewResumeResolved(sessionId: Int, question: NextQuestion)
        /// **시작 전** 세션의 [이어서 진행] — 준비 화면부터 다시 태운다. 재개 확정(`confirmResume`)을
        /// 거치지 않는다: 아직 아무 질문도 오가지 않아 «이어서 물을 것» 이 없고, 사용자는 카메라 확인·
        /// 가이드를 아직 보지 않았다. 곧장 세션으로 넣으면 안내 없이 면접이 시작된다.
        case interviewReadinessResumeResolved(sessionId: Int)
        case interview(PresentationAction<InterviewFeature.Action>)
        case myPage(PresentationAction<MyPageFeature.Action>)
        case myPageReport(PresentationAction<ReportFeature.Action>)
        case onboarding(PresentationAction<OnboardingFeature.Action>)
        case report(PresentationAction<ReportFeature.Action>)
        /// dev 데이터 초기화 완료 — 초기 State 로 리셋하고 Splash 판정부터 다시 태운다.
        case appDataCleared
        case binding(BindingAction<State>)

        /// 업데이트 알럿 버튼. 강제(FORCE)일 땐 «나중에» 를 만들지 않아 도달하지 않는다.
        @CasePathable
        enum UpdateAlert: Equatable, Sendable {
            case userTappedUpdate
            case userTappedLater
        }
    }

    /// Splash 판정의 결과. 게이트 2단 체인의 목적지 + 두 실패 종류다 (docs/work/launch-routing.md).
    enum LaunchRouting: Equatable, Sendable {
        /// 토큰 없음 또는 refresh 가 만료로 거부됨(토큰 폐기 완료) — 소셜 로그인부터.
        case login
        /// 게이트 미통과 — 가입 플로우가 이어받는다(약관 또는 온보딩).
        case resume(AuthFeature.Destination)
        /// 두 게이트 통과 — 홈 직행.
        case home
        /// 판정 불가(네트워크·5xx·계약 불일치) — 토큰은 유지된다. 재시도 대상.
        ///
        /// 도메인 에러 매핑이 원인을 `unexpected` 하나로 뭉개므로 **어느 단계에서 무엇으로** 실패했는지를
        /// 함께 싣는다 — 이게 없으면 스플래시에 갇혔을 때 refresh 인지 pending 인지조차 알 수 없다.
        /// 에러를 그대로 싣지 않고 설명 문자열로 옮기는 건 `any Error` 가 Sendable 이 아니라서다.
        case failed(step: String, reason: String)
    }

    @Dependency(\.appVersionClient) var appVersionClient
    @Dependency(\.authClient) var authClient
    @Dependency(\.consentClient) var consentClient
    @Dependency(\.deeplinkClient) var deeplinkClient
    @Dependency(\.firstLaunchStore) var firstLaunchStore
    @Dependency(\.heldSessionStore) var heldSessionStore
    @Dependency(\.interviewClient) var interviewClient
    @Dependency(\.interviewVideoUploadQueue) var uploadQueue
    @Dependency(\.onboardingDraftStore) var draftStore
    @Dependency(\.openURL) var openURL
    @Dependency(\.recordingClient) var recordingClient

    var body: some ReducerOf<Self> {
        BindingReducer()
        Scope(state: \.auth, action: \.auth) {
            AuthFeature()
        }
        Scope(state: \.home, action: \.home) {
            HomeFeature()
        }
        // 라우팅 본문은 AppFeatureRouting.swift — 한 클로저에 다 넣으면 이 결과 빌더가
        // 타입 체크 한계를 넘어 빌드가 깨진다.
        Reduce { state, action in
            reduceCore(&state, action)
        }
        .ifLet(\.$guestFeedback, action: \.guestFeedback) {
            GuestFeedbackFeature()
        }
        .ifLet(\.$interview, action: \.interview) {
            InterviewFeature()
        }
        .ifLet(\.$myPage, action: \.myPage) {
            MyPageFeature()
        }
        .ifLet(\.$myPageReport, action: \.myPageReport) {
            ReportFeature()
        }
        .ifLet(\.$onboarding, action: \.onboarding) {
            OnboardingFeature()
        }
        .ifLet(\.$report, action: \.report) {
            ReportFeature()
        }
        .ifLet(\.$updateAlert, action: \.updateAlert)
    }
}
