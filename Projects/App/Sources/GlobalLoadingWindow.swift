//
//  GlobalLoadingWindow.swift
//  Hilit
//
//  Created by EunSeo on 26/09/28.
//

import CoreNetworkInterface
import SharedDesignSystemInterface
import SwiftUI
import UIKit

// @lat: [[domain.map#네트워킹 인프라]]
/// 전역 로딩을 앱 최상단 UIWindow 에 띄운다.
///
/// 루트 뷰 `overlay` 로 얹으면 `fullScreenCover`(온보딩·마이페이지 등) 아래에 깔려 보이지 않는다 —
/// cover 는 루트 위에 새 presentation 층을 올리기 때문. 별도 창은 모든 cover 위에 있다.
///
/// 창은 `isBlocking` 동안만 보인다 — 보이는 동안 투명 막이 모든 터치를 받아 연타를 막고,
/// `isLoading` 이 켜지면 그 위에 딤 + `LoadingModal` 이 뜬다. key window 로 만들지 않으므로
/// 키보드·포커스는 원래 창에 남는다.
@MainActor
final class GlobalLoadingWindow {
    static let shared = GlobalLoadingWindow()

    /// 지금 로딩을 얹을 자리인지 — `AppView.showsGlobalLoading` 을 흘려 넣는다.
    var isEnabled = false {
        didSet { update() }
    }

    private var window: UIWindow?
    private let state = GlobalLoadingState()

    private init() {}

    /// 첫 화면이 뜬 뒤 한 번 부른다 — 그 전엔 붙일 scene 이 없다. 재호출은 무시한다.
    func install() {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes
                  .compactMap({ $0 as? UIWindowScene })
                  .first
        else { return }
        let host = UIHostingController(rootView: GlobalLoadingView(state: state))
        host.view.backgroundColor = .clear
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = true
        self.window = window
        observe()
    }

    /// `NetworkActivity` 변화를 따라간다 — 한 번 바뀔 때마다 추적이 풀리므로 다시 건다.
    private func observe() {
        withObservationTracking {
            update()
        } onChange: {
            Task { @MainActor in self.observe() }
        }
    }

    private func update() {
        // 관찰 값은 **조건 없이 먼저 읽는다** — `isEnabled && activity.isLoading` 처럼 단락 평가 뒤에 두면
        // isEnabled 가 false 인 순간 아무것도 추적되지 않아, 이후 변화 알림이 영영 오지 않는다(로딩이 안 꺼짐).
        let activity = NetworkActivity.shared
        let isLoading = activity.isLoading
        let isBlocking = activity.isBlocking
        state.isPresented = isEnabled && isLoading
        window?.isHidden = !(isEnabled && isBlocking)
    }
}

/// 창 안 SwiftUI 에 모달 표출 여부를 전하는 상자.
@MainActor @Observable
private final class GlobalLoadingState {
    var isPresented = false
}

/// 창 전체를 덮는 투명 막 + 로딩 모달. 창이 보이는 동안 터치는 전부 여기서 끝난다.
private struct GlobalLoadingView: View {
    let state: GlobalLoadingState

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .ignoresSafeArea()
            .hilitModalOverlay(isPresented: state.isPresented) {
                LoadingModal()
            }
    }
}
