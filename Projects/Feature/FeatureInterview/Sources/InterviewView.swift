//
//  InterviewView.swift
//  FeatureInterview
//
//  Created by 서정원 on 26/07/25.
//

import ComposableArchitecture
import DomainRecordingInterface
import SwiftUI

// 면접 흐름 루트 — 코디네이터의 screen 상태에 따라 하위 화면을 전면 교체한다.
// 카메라 backdrop 은 교체 대상 밖(여기)에 상주한다 — 화면과 함께 갈아끼우면 프리뷰 레이어가
// 파괴·재생성되며 카메라가 끊겨 보이기 때문. 핸들·스크림은 현재 화면 상태에서 파생만 한다.
@ViewAction(for: InterviewFeature.self)
public struct InterviewView: View {
    @Bindable public var store: StoreOf<InterviewFeature>
    @Environment(\.scenePhase) private var scenePhase

    public init(store: StoreOf<InterviewFeature>) {
        self.store = store
    }

    public var body: some View {
        ZStack {
            if let backdrop {
                InterviewCameraBackdrop(
                    showsTopScrim: backdrop.showsTopScrim,
                    previewHandle: backdrop.previewHandle
                )
                // 세션 모달(종료 확인·이탈 경고)의 배경 블러 — 세션 화면 콘텐츠의 blur 와 함께 걸린다.
                .blur(radius: isBackdropBlurred ? 20 : 0)
                .animation(.easeInOut(duration: 0.2), value: isBackdropBlurred)
                .animation(.easeInOut(duration: 0.3), value: screenCaseID)
            }

            Group {
                if let store = store.scope(state: \.screen.readiness, action: \.screen.readiness) {
                    InterviewReadinessView(store: store)
                } else if let store = store.scope(state: \.screen.session, action: \.screen.session) {
                    // 셀룰러 업로드 확인 알럿(HLT-87)은 세션의 마무리 로딩 모달 안에서 띄운다 — 그 init 주석.
                    InterviewSessionView(
                        store: store,
                        cellularUploadAlert: $store.scope(state: \.cellularUploadAlert, action: \.cellularUploadAlert)
                    )
                } else if let store = store.scope(state: \.screen.failure, action: \.screen.failure) {
                    InterviewFailureView(store: store)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: screenCaseID)
        }
        // 복귀 관측(스펙 ③) — 판정·라우팅은 코디네이터 리듀서가 게이트로 거른다. 백그라운드 관측은
        // 세션 View 몫(세그먼트 마감이 세션 소유라서 — InterviewSessionView).
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { send(.sceneBecameActive) }
        }
    }

    /// 카메라 화면(준비·세션)에서만 backdrop 을 그린다 — 핸들은 화면 State 가 계속 소유한다.
    private var backdrop: (showsTopScrim: Bool, previewHandle: CameraPreviewHandle?)? {
        switch store.screen {
        case let .readiness(state): (showsTopScrim: true, previewHandle: state.previewHandle)
        case let .session(state): (showsTopScrim: false, previewHandle: state.previewHandle)
        case .failure: nil
        }
    }

    private var isBackdropBlurred: Bool {
        guard case let .session(session) = store.screen else { return false }
        return session.isExitConfirmPresented || session.isEarlyExitWarningPresented
    }

    /// 화면 전환 애니메이션 트리거 — 케이스가 바뀔 때만 발화하도록 식별자로 축약.
    private var screenCaseID: Int {
        switch store.screen {
        case .readiness: 0
        case .session: 1
        case .failure: 2
        }
    }
}

#Preview {
    InterviewView(
        store: Store(initialState: InterviewFeature.State(sessionId: 1)) {
            InterviewFeature()
        }
    )
}
