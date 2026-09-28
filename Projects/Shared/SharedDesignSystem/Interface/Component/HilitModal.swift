//
//  HilitModal.swift
//  SharedDesignSystemInterface
//
//  Created by EunseoKim on 26/07/31.
//

// Figma: «modal» 딤 — https://figma.com/design/JL9YPbqBqmaC9Z0I3SzDZS/?node-id=2302-6080

import SwiftUI

public extension View {
    /// 모달 오버레이 — 딤(블랙 60%) 위에 카드를 중앙 표출한다.
    /// 카드는 아무 뷰 — 시안의 세 모달 계열 `Modal`·`HomeModal`·`LoadingModal` 이 전부 이걸로 올라온다.
    ///
    /// ```swift
    /// .hilitModal(isPresented: store.isExitConfirmPresented) {
    ///     Modal("정말 나가시겠어요?") { ButtonLarge("확인", .modal) { send(.userTappedConfirm) } }
    /// }
    /// ```
    ///
    /// **값 기반·읽기 전용** — 스스로 닫지 않는다. 닫힘은 카드 버튼 클로저가 리듀서 액션으로 보내
    /// 상태를 내리는 것(딤 탭 dismiss 없음 — 시안·현행 UX 에 없어서. 생기면 리듀서 액션 클로저로 추가).
    /// Binding 을 받지 않는 이유: 쓰기 경로가 없는데 Binding 을 받으면 API 가 거짓말을 한다.
    ///
    /// 카드 좌우 여백 px24 를 여기서 준다(시안 327 = 화면 375 − 24×2) — 카드는 폭을 정하지 않는다.
    /// 시안의 backdrop blur 40 은 미포함 — 필요하면 호출부가 배경 콘텐츠 블러로 근사한다(InterviewSession 참조).
    ///
    /// 표출은 `fullScreenCover` 다 — 네비바(시스템 UIKit 바)까지 덮으려면 뷰 계층 안 `overlay` 로는
    /// 안 되기 때문. 그래서 **한 화면에 두 번 붙이면 안 된다**(둘째 cover 가 조용히 무시됨) —
    /// 모달 2개↑ 는 `hilitModal(item:)`. 앱 루트는 `hilitModalOverlay` 를 쓴다(아래 참조).
    /// 상세 이유는 `HilitModalPresenter` 주석.
    func hilitModal<Content: View>(
        isPresented: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        modifier(HilitModalPresenter(card: isPresented ? content() : nil))
    }

    /// `hilitModal(isPresented:content:)` 의 분기 변형 — 한 화면에 모달이 2개 이상일 때
    /// Bool 여러 개 대신 enum 하나를 물려 동시 표출을 타입으로 차단한다.
    ///
    /// ```swift
    /// .hilitModal(item: presentedModal) { modal in
    ///     switch modal { case .exitConfirm: …; case .earlyExitWarning: … }
    /// }
    /// ```
    func hilitModal<Item: Equatable, Content: View>(
        item: Item?,
        @ViewBuilder content: (Item) -> Content
    ) -> some View {
        modifier(HilitModalPresenter(card: item.map { content($0) }))
    }

    /// **앱 루트 전용** 표출 — 같은 딤·카드 층을 `overlay` 로 얹는다(presentation 을 새로 열지 않음).
    /// 루트는 이미 NavigationStack 밖이라 overlay 만으로도 네비바 위에 깔린다.
    ///
    /// 화면에서 쓰면 안 된다 — 화면 안쪽 overlay 는 네비바 밑에 깔린다(그래서 `hilitModal` 은 cover).
    /// 루트가 cover 를 쓰면 화면 모달과 presentation 자리를 다투므로 여기만 overlay 로 남긴다
    /// (전역 로딩 = 앱 최상단 창 `GlobalLoadingWindow` 의 루트). 루트 뷰에 얹으면 화면 모달·cover 가
    /// 떠 있는 동안 그 아래로 가려지므로, 모든 cover 위에 떠야 하는 전역 로딩은 별도 창의 루트에 얹는다.
    func hilitModalOverlay<Content: View>(
        isPresented: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        overlay {
            if isPresented {
                HilitModalLayer { content() }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isPresented)
    }
}

/// 딤 검정 — 색 팔레트에 대응 토큰이 없어(`BlackWhite` 는 white 뿐) 리터럴은 여기 한 곳만.
/// **모달과 시트가 값이 다르다** — 한 상수로 묶었다가 시트가 시안보다 옅게 나갔다(2026-08-07).
enum HilitDim {
    /// 모달 — Figma 실측 블랙 60%(modal 2302:6080). 디자인 변수로 정의돼 있지 않아 실측값이다.
    static let modal = Color.black.opacity(0.6)
    /// 바텀시트 — Figma 변수 «hilit opacity/dark/65%»(전문 시트 477:6308).
    static let sheet = Color.black.opacity(0.65)
}

/// 표출 배관 — 두 변형이 공유한다. 카드가 `nil` 이면 안 뜬다.
///
/// **`overlay` 가 아니라 `fullScreenCover` 인 이유** — 네비바는 시스템 UIKit 바(`.toolbar`,
/// `HilitNavigationBar`)라 SwiftUI 뷰 계층 **밖**에 그려진다. 뷰 안쪽 `overlay` 로는 딤이 바 밑에
/// 깔려 X 만 환하게 남는다. 시스템 alert 이 바까지 덮는 건 별도 presentation 에 올라가기 때문이고,
/// 이 모달도 같은 층을 쓴다(`.presentationBackground(.clear)` 로 cover 자체 배경만 지운다).
///
/// cover 의 기본 슬라이드업은 끄고(`disablesAnimations`) 전환은 딤·카드의 opacity 가 맡는다 —
/// 전면 딤이 아래에서 밀려 올라오면 시안(2302:6080)의 페이드와 다른 물건이 된다.
/// 그 트랜잭션은 **빈 호스트에만** 걸어 화면 콘텐츠 애니메이션(업로드 진행 바 등)에 번지지 않게 한다.
/// 닫힘은 즉시다 — cover 해제에는 opacity 를 태울 자리가 없다(표출만 페이드 0.2).
///
/// 한 화면에 이 모디파이어를 **두 번 붙이면 안 된다** — 동시 표출 시 두 번째 cover 가 조용히 무시된다.
/// 모달이 2개 이상인 화면은 `hilitModal(item:)` 에 enum 하나를 물린다.
private struct HilitModalPresenter<Card: View>: ViewModifier {
    let card: Card?

    func body(content: Content) -> some View {
        content.overlay {
            Color.clear
                .allowsHitTesting(false)
                .fullScreenCover(isPresented: .init(get: { card != nil }, set: { _ in })) {
                    HilitModalLayer { card }
                        .presentationBackground(.clear)
                }
                .transaction { $0.disablesAnimations = true }
        }
    }
}

/// 딤 + 중앙 카드 열 — cover 안에서 그려진다.
private struct HilitModalLayer<Card: View>: View {
    @ViewBuilder var card: Card

    /// 표출 페이드용 — cover 자체 전환을 껐으므로 여기서 0.2 를 만든다.
    @State private var isVisible = false

    var body: some View {
        ZStack {
            HilitDim.modal
                .ignoresSafeArea()
            card
                .padding(.horizontal, .ds(.p24))
        }
        .opacity(isVisible ? 1 : 0)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.2)) { isVisible = true }
        }
    }
}

// MARK: - Previews

#Preview("Bool — Modal 카드") {
    @Previewable @State var isPresented = true
    Button("모달 열기") { isPresented = true }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .hilitModal(isPresented: isPresented) {
            Modal("정말 나가시겠어요?") {
                ButtonLarge(.modal, tone: .twoColor) {
                    Button("취소") { isPresented = false }
                } trailing: {
                    Button("나가기") { isPresented = false }
                }
            }
        }
}

#Preview("Bool — HomeModal 카드") {
    Color.GrayScale.g50
        .ignoresSafeArea()
        .hilitModal(isPresented: true) {
            HomeModal(
                "title",
                subTitle: "sub-title",
                icon: Image.Img.oppO,
                info: "텍스트를 입력해주세요"
            )
        }
}

#Preview("Bool — LoadingModal 카드") {
    Color.GrayScale.g50
        .ignoresSafeArea()
        .hilitModal(isPresented: true) {
            LoadingModal()
        }
}

/// 분기 프리뷰용 — result builder 안에선 타입 선언이 안 돼 파일 스코프에 둔다.
private enum PreviewModal: Equatable {
    case exitConfirm
    case earlyExitWarning
}

#Preview("Item — 팝업 2개 분기") {
    @Previewable @State var presented: PreviewModal? = .exitConfirm
    VStack(spacing: 12) {
        Button("종료 확인") { presented = .exitConfirm }
        Button("이탈 경고") { presented = .earlyExitWarning }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .hilitModal(item: presented) { modal in
        switch modal {
        case .exitConfirm:
            Modal("면접을 마칠까요?") {
                ButtonLarge("계속하기", .modal) { presented = nil }
            }
        case .earlyExitWarning:
            Modal("지금 나가면 이용권 1회가 차감돼요") {
                ButtonLarge("나가기", .modal) { presented = nil }
            }
        }
    }
}
