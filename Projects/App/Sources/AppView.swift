//
//  AppView.swift
//  Hilit
//
//  Created by 서정원 on 26/07/13.
//

import SwiftUI
import ComposableArchitecture
import CoreNetworkInterface
import Feature
import SharedDesignSystemInterface

struct AppView: View {
    @Bindable var store: StoreOf<AppFeature>
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch store.root {
            case .splash:
                // Splash(SP) — 세션 복구 판정 동안 표시. 판정은 AppFeature.onAppear.
                SplashView()
            case .splashFailed:
                // 판정 불가(네트워크·5xx) — 토큰은 살아 있으므로 로그인으로 내보내지 않고 재시도만 받는다.
                SplashView(onRetry: { store.send(.retryLaunchRouting) })
            case .updateRequired:
                // 강제 업데이트 — 세션 판정을 시작하지 않았다. 재시도 버튼 없이 알럿만 얹힌 Splash.
                SplashView()
            case .home:
                // 탭이 하나뿐이라 TabView 를 두지 않는다 — 탭바 자리만 차지하면서 홈 배경 그라디언트가
                // 반투명 바로 새어 나와 하단에 초록 띠로 보였다. 탭이 둘 이상 생기면 그때 TabView 로 되돌린다.
                // 네비바(로고 ↔ X 를 값으로 갈아끼움)는 시스템 바 기반이라 스택 밖에선 조용히 안 그려진다
                // (navigation.md «부착 — push vs present»). 홈 내부 push 는 HomeFeature 의 Path/StackState 로 승격.
                NavigationStack {
                    HomeView(store: store.scope(state: \.home, action: \.home))
                }
                // 온보딩 위저드 — 「면접 시작」의 [시작하기](첫 면접)·[수정하기], dev 진입 버튼이 연다.
                // 홈 위에서만 열리므로 로그인 이후다(온보딩 API 는 토큰 필요).
                .fullScreenCover(
                    item: $store.scope(state: \.onboarding, action: \.onboarding)
                ) { onboardingStore in
                    OnboardingView(store: onboardingStore)
                }
                // 면접 흐름(Part2) — 온보딩 완주가 넘긴 세션으로 열린다. 카메라 프리뷰가 전면을 채우는
                // 몰입 화면이라 네비바까지 덮는 fullScreenCover 다.
                .fullScreenCover(
                    item: $store.scope(state: \.interview, action: \.interview)
                ) { interviewStore in
                    InterviewView(store: interviewStore)
                }
                // 마이페이지(Part5) — 홈 위젯③ 이 연다. 자체 상단 바(`hilitPresentedNavigationBar`)를
                // 얹는 한 장짜리 화면이라 NavigationStack 없이 그대로 덮는다.
                .fullScreenCover(
                    item: $store.scope(state: \.myPage, action: \.myPage)
                ) { myPageStore in
                    MyPageView(store: myPageStore)
                        // 리포트 줄의 [리포트 보기]·[지인 피드백 받기] — 마이페이지를 **덮고** 얹혀,
                        // 닫으면 보던 목록이 그대로 드러난다. 그래서 루트가 아니라 이 뷰에 부착한다
                        // (루트에 두면 이미 떠 있는 마이페이지 cover 에 가려 아무것도 뜨지 않는다).
                        .fullScreenCover(
                            item: $store.scope(state: \.myPageReport, action: \.myPageReport)
                        ) { reportStore in
                            ReportView(store: reportStore)
                        }
                }
                // AI 면접 리포트 — 홈 위젯②의 [레포트 보기] 가 세션 id 로 연다. 자체 NavigationStack 을
                // 갖고 좌상단 X 로 나가는 전면 흐름이라 sheet 가 아니라 cover 다.
                .fullScreenCover(
                    item: $store.scope(state: \.report, action: \.report)
                ) { reportStore in
                    ReportView(store: reportStore)
                }
            case .auth:
                // 로그인 전 + 가입 플로우(약관·온보딩) — 세션 복구가 게이트에 걸린 경우도 여기로 온다.
                AuthView(store: store.scope(state: \.auth, action: \.auth))
            }
        }
        // 게스트 평가(G4) — 공유 딥링크로 열린다. 무인증 플로우라 루트(스플래시·auth·home)와
        // 무관하게 떠야 해서 .home 안쪽이 아니라 루트 Group 에 부착한다. 닫기는 delegate(.dismissed).
        .fullScreenCover(
            item: $store.scope(state: \.guestFeedback, action: \.guestFeedback)
        ) { guestStore in
            GuestFeedbackView(store: guestStore)
        }
        // 강제·권장 업데이트 안내 — 루트가 무엇이든 위에 얹힌다(강제는 root 가 .updateRequired).
        .alert($store.scope(state: \.updateAlert, action: \.updateAlert))
        .onAppear { store.send(.onAppear) }
        // 복귀 시점 보관값 검증 — 동결된 면접은 백그라운드 진입 때 이미 홈으로 나와 있어(cover 없음)
        // «그새 끝난 세션인가» 를 물을 자리가 루트뿐이다. 게이트는 리듀서가 건다.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.send(.sceneBecameActive) }
        }
        // 전역 시스템 로딩 — 모든 API in-flight(NetworkActivity) 동안 입력을 막고 LoadingModal 을 띄운다.
        // 루트 overlay 는 fullScreenCover(온보딩 등) 아래에 깔리므로 최상단 별도 창에 띄운다.
        // 여기서는 창을 설치하고 «얹을 자리인가» 만 흘려 넣는다.
        .onAppear { GlobalLoadingWindow.shared.install() }
        .onChange(of: showsGlobalLoading, initial: true) { _, isEnabled in
            GlobalLoadingWindow.shared.isEnabled = isEnabled
        }
    }

    /// 전역 로딩을 얹을 자리인지 — **Splash 계열 루트와 면접 중에는 끈다**.
    /// Splash 자체가 «기다리는 중» 표시라 그 위에 로딩 판을 또 덮으면 브랜드 화면만 가린다
    /// (세션 복구 판정이 곧 그 화면의 존재 이유다). `.updateRequired` 는 알럿이 떠 있어 딤이 겹치면 안 된다.
    private var showsGlobalLoading: Bool {
        // 면접은 자체 진행 표시(상태 칩·초읽기)로 대기를 말한다 — 답변 제출·질문 스트림마다 전역 딤이
        // 덮이면 면접이 끊겨 보이고, 타이머가 도는 화면을 잠그는 것 자체가 오동작이다.
        guard store.interview == nil else { return false }
        // 게스트 평가도 끈다 — G4 는 자체 loading phase 로 대기를 말하고, 비회원 게스트에게 앱 전역 딤은 과하다.
        guard store.guestFeedback == nil else { return false }
        // 리포트도 같은 이유로 끈다 — 채점 대기 중엔 4초마다 재조회가 나가서(폴링) 전역 딤이 깜빡이고,
        // 그 대기는 리포트 화면이 자체 상태(`loadState`)로 이미 말하고 있다. 마이페이지 위에 얹힌
        // 리포트도 같은 화면이라 함께 본다.
        guard store.report == nil, store.myPageReport == nil else { return false }
        // `default` 를 두지 않는다 — 루트가 늘면 여기서 컴파일이 깨져 판단을 강제한다.
        return switch store.root {
        case .splash, .splashFailed, .updateRequired: false
        case .auth, .home: true
        }
    }
}
