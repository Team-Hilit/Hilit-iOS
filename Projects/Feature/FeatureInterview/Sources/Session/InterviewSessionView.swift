//
//  InterviewSessionView.swift
//  FeatureInterview
//
//  Created by 서정원 on 26/07/25.
//

import ComposableArchitecture
import DomainInterviewInterface
import SharedDesignSystemInterface
import SwiftUI

@ViewAction(for: InterviewSessionFeature.self)
public struct InterviewSessionView: View {
    @Bindable public var store: StoreOf<InterviewSessionFeature>
    @Environment(\.scenePhase) private var scenePhase
    /// 모바일 데이터 업로드 확인 알럿(HLT-87) — 상태는 코디네이터 소유, 표출만 여기서 한다.
    /// 알럿이 뜨는 때는 항상 마무리 로딩 모달(cover)이 떠 있다(산출물은 정지+합성 경로에서만 나온다).
    /// 루트에서 띄우면 cover 와 presentation 자리를 다퉈 시스템이 알럿을 곧바로 내린다 — 그래서 cover 안에 붙인다.
    private let cellularUploadAlert: Binding<Store<
        AlertState<InterviewFeature.Action.CellularUploadAlert>, InterviewFeature.Action.CellularUploadAlert
    >?>

    public init(store: StoreOf<InterviewSessionFeature>) {
        self.init(store: store, cellularUploadAlert: .constant(nil))
    }

    init(
        store: StoreOf<InterviewSessionFeature>,
        cellularUploadAlert: Binding<Store<
            AlertState<InterviewFeature.Action.CellularUploadAlert>, InterviewFeature.Action.CellularUploadAlert
        >?>
    ) {
        self.store = store
        self.cellularUploadAlert = cellularUploadAlert
    }

    // 카메라 backdrop 은 InterviewView(코디네이터 뷰) 상주 — 화면 교체 시 프리뷰 레이어 재생성 방지.
    // 모달 딤의 배경(카메라) 블러도 InterviewView 가 세션 상태를 읽어 함께 건다.
    public var body: some View {
        VStack(spacing: 0) {
            timerChip
                // 시간 칩은 Figma y94 — 네비바(h44)가 43~87 을 먹으므로 남는 값 7 (94 − 87).
                .padding(.top, 7)
            Spacer(minLength: 0)
            bottomBand
        }
        // 좌상단 뒤로가기 — 글리프만 X 에서 `<` 로 바뀌고 배관은 그대로다(Figma «[Part2. 면접 녹화]»
        // 전 프레임 공통, ExitConfirm·이탈 경고 모달은 시안에 살아 있다). 8:00 전이면 이탈 경고,
        // 8:00 후면 종료 확인 모달로 갈리는 판정은 그대로 리듀서(`userTappedClose`)가 소유한다.
        .hilitPresentedNavigationBar(
            surface: .dark,
            leading: .back,
            onClose: { send(.userTappedClose) }
        )
        // 브래킷은 네비바 inset 밖 — 안에 두면 콘텐츠가 44 밀려 327 정방형 중심이 22 내려간다.
        .background {
            CameraGuideFrame()
        }
        // 카메라 위 다크 판 — 하위 `.mini` 버튼 팔레트가 이 선언을 따라 전환된다 (design/component.md).
        .hilitSurface(.dark)
        // Figma ExitConfirm 딤: black 60%(.hilitModal 몫) + backdrop blur — 배경 콘텐츠를 블러해 근사한다.
        .blur(radius: presentedModal != nil ? 20 : 0)
        // 블러 전환은 여기서 직접 몬다 — 모달 페이드(0.2)는 `.hilitModal` 이 cover 안쪽에서 처리하므로
        // 배경 블러까지 끌고 오지 않는다. 값·시간을 모달 쪽과 같게 맞춰 한 동작으로 보이게 한다.
        .animation(.easeInOut(duration: 0.2), value: presentedModal)
        .hilitModal(item: presentedModal) { modal in
            switch modal {
            case .finishing: LoadingModal().alert(cellularUploadAlert)
            case .exitConfirm: exitConfirmModal
            case .earlyExitWarning: earlyExitWarningModal
            }
        }
        .animation(.easeInOut(duration: 0.3), value: store.phase)
        .animation(.easeInOut(duration: 0.3), value: store.toast)
        // 네트워크 실패 오버레이 — 세션 상태·녹화를 살린 채 전체 화면으로 덮는다(스펙 ③).
        // 시안(2638:17018)이 독립 풀스크린이라 ZStack 대신 cover — 세션 네비바·브래킷과 레이아웃 간섭이 없다.
        .fullScreenCover(item: $store.scope(state: \.failure, action: \.failure)) { store in
            InterviewFailureView(store: store)
        }
        .onAppear { send(.onAppear) }
        // 백그라운드 진입 = 세그먼트 경계(스펙 ②). 복귀(.active) 관측은 코디네이터 뷰(InterviewView) 몫.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { send(.sceneBackgrounded) }
        }
    }

    // MARK: - 상단 시간 칩 (Figma top 94 = 상태바 43 + 51)
    private var timerChip: some View {
        InterviewTimerChip(
            variant: store.phase == .finalCountdown
                ? .countdown(remaining: store.countdownRemaining)
                : .elapsed(seconds: store.elapsedSeconds)
        )
    }

    // MARK: - 하단 밴드 (상태 칩·토스트 + 미니 버튼)
    private var bottomBand: some View {
        VStack(spacing: 0) {
            if let toast = store.toast {
                toastView(toast)
            } else {
                statusArea
            }
            miniButtonStack
                .padding(.top, .ds(.p10))
                .padding(.bottom, .ds(.p10))
                .padding(.horizontal, .ds(.p20))
        }
    }

    @ViewBuilder
    private var statusArea: some View {
        switch store.phase {
        case .asking:
            VStack(spacing: .ds(.p4)) {
                HighlightedText("질문 듣는 중", typography: .body2)
                    .hilightColor(.green)
                Text("끝까지 듣고 대답해 주세요")
                    .dsTypography(.sub7)
                    .foregroundStyle(Color.BlackWhite.white)
            }
        case .answering:
            HighlightedText("답변 녹음 중", typography: .body2)
                .hilightColor(.black)
        case .processingAnswer:
            // 임시 — answering 칩과 동일 스타일. 상태 칩 시안 확정 시 교체 (PRD §3.5 «답변을 정리하고 있어요» 는 확정 문구).
            HighlightedText("답변을 정리하고 있어요", typography: .body2)
                .hilightColor(.black)
        case .finalCountdown:
            // 카운트다운 중 상태 칩 없음 — 상단 빨간 칩 + 상시 토스트만 (Figma 683:9302). 하단 버튼도 없다(아래 스택).
            EmptyView()
        }
    }

    private func toastView(_ toast: InterviewSessionFeature.State.Toast) -> some View {
        // 꼬리가 아래 «면접 종료하기» 버튼을 가리킨다 (Figma BubbleField status=bottom).
        BubbleField(toast.message, .wide(tail: toast.hasTail ? .bottom : .none))
    }

    /// 8:00 해금 뒤엔 버튼이 **둘**이고 세로로 쌓인다 — «면접 종료하기» 가 위, «답변 완료하기» 가 아래
    /// (Figma «Interview_InProgress_ExitButtonShown» 683:9280 — 종료 top688 · 완료 top734, 둘 다 h34 라 간격 12).
    /// 해금돼도 답변 완료 자리는 그대로다: 나란히 놓지 않으니 아래 칸이 밀리지 않는다.
    private var miniButtonStack: some View {
        VStack(alignment: .trailing, spacing: .ds(.p12)) {
            // 최종 카운트다운엔 버튼이 없다 (Figma «InProgress_FinalCountdown» 683:9302 — 빨간 칩 + 토스트뿐).
            // 남은 10초는 상한이 알아서 끝내므로 고를 것이 없고, 여기서 종료 확인 모달을 띄우면
            // 답하는 사이 HARD_CAP 이 떨어진다.
            if store.isExitAvailable, store.phase != .finalCountdown {
                Button("면접 종료하기") {
                    send(.userTappedExit)
                }
                .buttonStyle(.mini(.filled))
            }
            // answering 이 아닐 땐 감추되 **자리는 지킨다** — 빼면 위 «면접 종료하기» 와 상태 칩이
            // 턴마다 46(=34+12) 내려앉는다. 해금 전에도, 버튼이 사라지는 카운트다운에도 이 칸이
            // 밴드 높이(34)를 잡는다 — 시안의 카운트다운 토스트도 그만큼 내려와 있다(671 vs 해금 625).
            Button("답변 완료하기") {
                send(.userTappedAnswerComplete)
            }
            .buttonStyle(.mini(.green))
            .opacity(store.phase == .answering ? 1 : 0)
            .disabled(store.phase != .answering)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // MARK: - 마무리·종료 확인·이탈 경고 모달 (DS LoadingModal/Modal + .hilitModal)

    /// 리듀서의 표출 Bool 3개를 뷰에서 enum 으로 접는다 — `.hilitModal(item:)` 규약(동시 표출 차단).
    private enum PresentedModal: Equatable {
        case finishing
        case exitConfirm
        case earlyExitWarning
    }

    /// `finishing` 이 먼저다 — 정지+합성 구간엔 종료·이탈 입력이 이미 잠겨 있어(리듀서 `reduceView` 가드)
    /// 확인 모달을 띄워도 답할 수 없다. 이 구간은 실기기에서 8~10초 걸리므로(합성 고정 대기, 2026-08-07 실측)
    /// 아무것도 안 띄우면 «앱이 멈췄다» 로 읽힌다.
    private var presentedModal: PresentedModal? {
        if store.isFinishing {
            .finishing
        } else if store.isExitConfirmPresented {
            .exitConfirm
        } else if store.isEarlyExitWarningPresented {
            .earlyExitWarning
        } else {
            nil
        }
    }

    /// 면접 종료 확인 — Figma «modal»(2555:7739) 1:1, 아이콘은 «finish/74px»(3951:210), 문구는 부록 C 확정.
    private var exitConfirmModal: some View {
        Modal(
            "면접을 마칠까요?",
            subText: "마치기를 클릭하는 즉시 면접이 종료됩니다.\n지금까지 답변으로 분석을 시작해요.",
            icon: Image.Img.finish
        ) {
            ButtonLarge(.modal, tone: .twoColor) {
                Button("계속하기") { send(.userTappedContinueInterview) }
            } trailing: {
                Button("마치기") { send(.userTappedFinishInterview) }
            }
        }
    }

    /// 8분 전 중도 이탈 경고 — Figma «modal»(3907:890): 아이콘 없음, «면접 계속하기»가 강조(검정) 쪽.
    /// 차감 사실만, 리포트 언급 금지 (PRD §3.7).
    private var earlyExitWarningModal: some View {
        Modal(
            "다음에 면접을 다시 진행할까요?",
            subText: "지금 나가면 방금 쓴 이용권 한장이 사라져요."
        ) {
            ButtonLarge(.modal, tone: .twoColor) {
                Button("그대로 나가기") { send(.userTappedLeaveInterview) }
            } trailing: {
                Button("면접 계속하기") { send(.userTappedContinueInterview) }
            }
        }
    }
}

// MARK: - Previews

/// backdrop 은 실앱에선 InterviewView 상주 — 단독 프리뷰는 여기서 대신 깔아 화면 구도를 유지한다.
private func sessionPreview(
    _ mutate: (inout InterviewSessionFeature.State) -> Void = { _ in }
) -> some View {
    var state = InterviewSessionFeature.State(
        sessionId: 1,
        summaryQuestion: SummaryQuestion(questionId: 1, ttsAudio: nil, turn: TurnInfo(turnLevel: 0, depthLevel: 0))
    )
    state.hasStarted = true   // onAppear 의 세션 시계를 막고 상태만 본다.
    mutate(&state)
    return ZStack {
        InterviewCameraBackdrop(showsTopScrim: false)
        InterviewSessionView(store: Store(initialState: state) { InterviewSessionFeature() })
    }
}

#Preview("질문 듣는 중") {
    sessionPreview { $0.elapsedSeconds = 1 }
}

#Preview("답변 녹음 중") {
    sessionPreview {
        $0.phase = .answering
        $0.elapsedSeconds = 80
    }
}

#Preview("답변 정리 중") {
    sessionPreview {
        $0.phase = .processingAnswer
        $0.elapsedSeconds = 82
    }
}

#Preview("8분 — 종료 해금(버튼 2개)") {
    sessionPreview {
        $0.phase = .answering
        $0.elapsedSeconds = 480
        $0.isExitAvailable = true
        $0.toast = .exitUnlocked
    }
}

/// 해금 뒤 답변 정리 중 — «면접 종료하기» 가 위 자리를 그대로 지키는지(내려앉지 않는지) 보는 컷.
#Preview("8분 후 — 답변 정리 중") {
    sessionPreview {
        $0.phase = .processingAnswer
        $0.elapsedSeconds = 520
        $0.isExitAvailable = true
    }
}

#Preview("최종 카운트다운") {
    sessionPreview {
        $0.phase = .finalCountdown
        $0.elapsedSeconds = 710
        $0.isExitAvailable = true
        $0.toast = .timeExpired
    }
}

#Preview("종료 확인 모달") {
    sessionPreview {
        $0.phase = .answering
        $0.elapsedSeconds = 480
        $0.isExitAvailable = true
        $0.isExitConfirmPresented = true
    }
}

#Preview("중도 이탈 경고 — 8분 전") {
    sessionPreview {
        $0.phase = .answering
        $0.elapsedSeconds = 200
        $0.isEarlyExitWarningPresented = true
    }
}

#Preview("네트워크 실패 오버레이") {
    sessionPreview {
        $0.phase = .processingAnswer
        $0.elapsedSeconds = 300
        $0.failure = InterviewFailureFeature.State(kind: .network)
        $0.pendingRetry = .playQuestion
    }
}
