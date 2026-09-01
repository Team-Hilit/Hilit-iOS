//
//  InterviewReadinessView.swift
//  FeatureInterview
//
//  Created by 서정원 on 26/07/25.
//

import ComposableArchitecture
import DomainInterviewInterface
import DomainPermissionInterface
import SharedDesignSystemInterface
import SwiftUI

// Figma «[2] Interview_Readiness»(2479:7569) · «…_Done»(2514:12754) · «…_Guide1»(2514:12799)
// · «…_Guide2»(2529:458) 구현. 전면 카메라 배경 위 오버레이만 phase 로 갈아끼운다.
// @ViewAction 매크로가 send(_:) 를 제공한다 — View 는 store.send(.view(...)) 대신 send(.onAppear) 로만 방출.
@ViewAction(for: InterviewReadinessFeature.self)
public struct InterviewReadinessView: View {
    @Bindable public var store: StoreOf<InterviewReadinessFeature>
    @Environment(\.scenePhase) private var scenePhase

    public init(store: StoreOf<InterviewReadinessFeature>) {
        self.store = store
    }

    private var isGuidePhase: Bool {
        store.phase == .guide1 || store.phase == .guide2
    }

    // 카메라 backdrop 은 InterviewView(코디네이터 뷰) 상주 — 화면 교체 시 프리뷰 레이어 재생성 방지.
    public var body: some View {
        VStack(spacing: 0) {
            titleBox
            Spacer(minLength: 0)
            bottomArea
        }
        // 바닥이 카메라 영상이라 화면 전체가 어두운 판 — 하위 DS 컴포넌트(TitleBox·ButtonLarge)가
        // 여기서 다크 팔레트를 파생한다. 특히 «면접 시작하기» 비활성은 흰 판이 아니라
        // 활성과 같은 b800 판에 g400 라벨로 죽는다 (Figma «…_Guide1» 683:9232).
        .hilitSurface(.dark)
        // 좌상단 뒤로가기 — 면접 흐름 이탈(Figma «[Part2. 면접 녹화]» 전 프레임 공통 `<`).
        // cover 로 올라온 스택 밖 화면이라 present 판, 카메라 영상이 바닥이라 surface: .dark(흰 글리프).
        .hilitPresentedNavigationBar(
            surface: .dark,
            leading: .back,
            onClose: { send(.userTappedBack) }
        )
        // 브래킷은 네비바 inset **밖**에 둔다 — 안에 두면 safeAreaInset 이 콘텐츠를 44 밀어
        // 327 정방형 중심이 22 내려간다. 여기 붙이면 바 도입 전과 같은 영역에서 중앙 정렬된다.
        // 가이드 단계에선 문구를 빼고 브래킷만 — 문구 자체는 화면 카피라 DS 가 아니라 여기 있다.
        .background {
            CameraGuideFrame(text: isGuidePhase ? nil : "얼굴을 여기에 맞춰주세요")
        }
        .animation(.easeInOut(duration: 0.3), value: store.phase)
        .onAppear { send(.onAppear) }
        // 설정에서 권한을 바꾸고 돌아오는 길 — 화면이 그대로 살아 돌아오면 onAppear 가 다시 오지 않는다.
        // 코디네이터 뷰(InterviewView)도 .active 를 보지만 그건 재개 판정용이라 여기서 따로 받는다.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { send(.sceneBecameActive) }
        }
        // 진입 시 카메라·마이크 권한이 미허용이면 뜨는 설정 유도 alert.
        .alert($store.scope(state: \.alert, action: \.alert))
    }

    // MARK: - 타이틀 (component/title-box — 상단 고정 밴드)

    /// Figma title-box: 상태바 아래 51pt 지점(= 화면 y94)부터. 2줄(68pt) 밴드를 고정해 1줄 타이틀(guide2)도
    /// 같은 시각 중심(y≈128)에 온다 (Figma top 94 vs 110 보정).
    /// 네비바(h44)가 safeAreaInset 으로 상태바 아래 43~87 을 차지하므로 남는 값은 7 이다(94 − 87).
    /// DS `TitleBox` 소비 — 다크 판 글자색·마커는 화면 루트의 `.hilitSurface(.dark)` 가 파생한다.
    private var titleBox: some View {
        TitleBox(titleLines, alignment: .center)
            .frame(minHeight: 68)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, .ds(.p20))
            .padding(.top, 7)
    }

    private var titleLines: [TitleBox.Line] {
        switch store.phase {
        case .aligning, .ready:
            [
                "면접을 준비하고 있어요",
                .init("화면 속 내 모습을 확인해주세요", highlight: "내 모습")
            ]
        case .guide1:
            [
                .init("질문은 소리로만 나와요", highlight: "소리"),
                "실제 면접처럼 잘 듣고 대답하면 돼요"
            ]
        case .guide2:
            [.init("면접은 총 10분으로 진행돼요", highlight: "10분")]
        }
    }

    // MARK: - 하단 (티커 ↔ 시작 버튼)

    @ViewBuilder
    private var bottomArea: some View {
        switch store.phase {
        case .aligning, .ready:
            InterviewTicker(
                text: "곧 면접이 시작됩니다",
                isEmphasized: store.phase == .ready
            )
            .padding(.bottom, 94)
        case .guide1, .guide2:
            ButtonLarge("면접 시작하기", .bottom) {
                send(.userTappedStart)
            }
            // 비활성 배색은 판이 정한다 — 화면 루트 `.hilitSurface(.dark)` 로 배경(b800)은 활성과 같고
            // 라벨만 g400 으로 죽는다. 버튼에 상태를 넘기지 않는 DS 규칙 그대로다.
            // 질문 준비 전 로딩 연출은 «협의 가능»(PRD §3.2) — 임시로 비활성만.
            // 권한 미허용도 같은 비활성 — 알림은 진입 시 alert 가 이미 했다.
            .disabled(
                store.phase == .guide1
                    || !store.isQuestionPrepReady
                    || !store.isMediaPermissionGranted
            )
        }
    }
}

// MARK: - InterviewTicker

/// Figma «loading/text»(2479:7556) — gray-800 풀폭 스트립에 같은 문구 3연속(간격 6).
/// 중앙만 상태에 따라 밝아진다: 대기 gray-600 → 준비 완료 gray-50. 양옆은 gray-700 고정.
private struct InterviewTicker: View {
    var text: String
    var isEmphasized: Bool

    var body: some View {
        // 3연속 문구는 화면보다 넓다 — **overlay 로 얹어 부모 폭에 영향을 주지 않게** 한다.
        // `.fixedSize().frame(maxWidth: .infinity)` 로 두면 넘친 이상적 폭이 부모(VStack)로 새어
        // 화면 좌표계 자체가 넓어진다. `.clipped()` 는 그림만 자를 뿐 레이아웃은 못 되돌린다 —
        // 그 결과 상단 네비바가 왼쪽으로 밀려 뒤로가기가 화면 가장자리에 붙었다(2026-08-03).
        // 높이·배경은 문구 «한 벌»이 잡는다(항상 화면보다 좁아 넘치지 않는다).
        Text(text)
            .dsTypography(.sub7)
            .lineLimit(1)
            .hidden()
            .frame(maxWidth: .infinity)
            .overlay {
                HStack(spacing: 6) {
                    sideText
                    Text(text)
                        .dsTypography(.sub7)
                        .foregroundStyle(isEmphasized ? Color.GrayScale.g50 : Color.GrayScale.g600)
                    sideText
                }
                .lineLimit(1)
                .fixedSize()
            }
            .background(Color.GrayScale.g800)
            .clipped()
    }

    private var sideText: some View {
        Text(text)
            .dsTypography(.sub7)
            .foregroundStyle(Color.GrayScale.g700)
    }
}

// MARK: - Previews

/// backdrop 은 실앱에선 InterviewView 상주 — 단독 프리뷰는 여기서 대신 깔아 화면 구도를 유지한다.
private func withBackdrop(_ content: some View) -> some View {
    ZStack {
        InterviewCameraBackdrop()
        content
    }
}

#Preview("얼굴 맞춤 (aligning)") {
    var state = InterviewReadinessFeature.State(sessionId: 1)
    state.hasStarted = true   // onAppear 의 phase 타이머·질문 준비 폴링을 막고 이 상태만 본다.
    return withBackdrop(InterviewReadinessView(
        store: Store(initialState: state) {
            InterviewReadinessFeature()
        }
    ))
}

#Preview("준비 완료 (ready)") {
    var state = InterviewReadinessFeature.State(sessionId: 1)
    state.phase = .ready
    state.hasStarted = true
    return withBackdrop(InterviewReadinessView(
        store: Store(initialState: state) {
            InterviewReadinessFeature()
        }
    ))
}

#Preview("가이드 1 — 버튼 비활성") {
    var state = InterviewReadinessFeature.State(sessionId: 1)
    state.phase = .guide1
    state.hasStarted = true
    return withBackdrop(InterviewReadinessView(
        store: Store(initialState: state) {
            InterviewReadinessFeature()
        }
    ))
}

#Preview("가이드 2 — 버튼 활성") {
    var state = InterviewReadinessFeature.State(sessionId: 1)
    state.phase = .guide2
    state.hasStarted = true
    state.isMediaPermissionGranted = true
    state.questionPrep = .ready(   // 질문 준비 완료라야 시작 버튼이 활성이다.
        SummaryQuestion(questionId: 1, ttsAudio: nil, turn: TurnInfo(turnLevel: 0, depthLevel: 0))
    )
    return withBackdrop(InterviewReadinessView(
        store: Store(initialState: state) {
            InterviewReadinessFeature()
        }
    ))
}

#Preview("권한 미허용 — 진입 시 설정 유도 alert · 시작 버튼 비활성") {
    // 진입 권한 요청이 미허용으로 해소된 상황 — alert 가 떠 있고 뒤의 시작 버튼은 비활성이다.
    var state = InterviewReadinessFeature.State(sessionId: 1)
    state.phase = .guide2
    state.hasStarted = true
    state.questionPrep = .ready(
        SummaryQuestion(questionId: 1, ttsAudio: nil, turn: TurnInfo(turnLevel: 0, depthLevel: 0))
    )
    state.alert = InterviewReadinessFeature.permissionDeniedAlert()
    return withBackdrop(InterviewReadinessView(
        store: Store(initialState: state) {
            InterviewReadinessFeature()
        } withDependencies: {
            $0.permissionClient = PermissionClient(
                status: { _ in .denied },
                request: { _ in false },
                openSettings: {}
            )
        }
    ))
}
