//
//  ButtonLarge.swift
//  SharedDesignSystemInterface
//
//  Created by EunseoKim on 26/07/26.
//

// Figma: «button-large/bottom» https://figma.com/design/JL9YPbqBqmaC9Z0I3SzDZS/?node-id=435-691
//        «button-large/modal»  https://figma.com/design/JL9YPbqBqmaC9Z0I3SzDZS/?node-id=435-711
//        «button-large/login»  https://figma.com/design/JL9YPbqBqmaC9Z0I3SzDZS/?node-id=435-812 (kakao) · 435-809 (apple)
//        가족 전체 한 판: «Hilit_Component_Guide1» node-id=439-10097

import SwiftUI

/// 대형 버튼이 놓이는 자리 — 여백과 안전영역 처리가 갈린다.
public enum ButtonLargeKind: Sendable {
    /// 화면 하단 풀블리드. px24 · 세로 비대칭 · 배경이 하단 안전영역까지 내려간다.
    case bottom
    /// 모달 안. px8 · 세로 대칭 16.
    case modal
    /// 로그인 화면. px8 · 세로 대칭 16 · 로고 24 가 높이를 56 으로 잡는다.
    /// **`ButtonLarge(_:login:)` 이 알아서 넣는다** — 호출부가 직접 넘기지 않는다(단일·2버튼 시안이 없다).
    case login
}

/// 대형 단일 버튼 배색 — Figma `button-large` 시트의 **행 축**(`dark`/`light`).
/// 열 축(default·pressed·disabled)은 파라미터가 아니다 — 아래 `SingleStyle` 이 자동 처리한다.
public enum ButtonLargeTone: Sendable, CaseIterable {
    /// 검정 채움 + 흰 라벨
    case dark
    /// 흰 바탕 + 검정 테두리. **`.bottom` 전용** (모달엔 시안이 없다).
    case light
}

/// 대형 2버튼 배색 — 시트의 `2 button` 행 열 축(`default`/`gray`/`2 color`).
/// 시트의 `1 disabled` 칸은 배색이 아니라 상태라 여기 없다 — 해당 자식에 `.disabled(true)`.
public enum ButtonLargePairTone: Sendable, CaseIterable {
    /// 검정 공유 배경 + 흰 라벨 (시트 `default`)
    case dark
    /// 회색 공유 배경 + 검정 라벨. **`.bottom` 전용**
    case gray
    /// 왼쪽 회색 · 오른쪽 검정 반반 (divider 없음). 컨테이너는 여백 없이 풀블리드 — 반쪽이 각자 여백을 칠한다.
    case twoColor
}

/// 로그인 제공자 — Figma `button-large/login` 의 `domain` 축. 배경·라벨색·로고가 여기서 한 벌로 결정된다.
public enum ButtonLargeLoginProvider: Sendable, CaseIterable {
    /// 카카오 — #FEE500 바탕 + b900 라벨
    case kakao
    /// Apple — b900 바탕 + 흰 라벨
    case apple
}

/// 대형 버튼 — 화면 하단 CTA(`.bottom`) · 모달 확인(`.modal`) · 로그인(`init(_:login:)`).
/// sub7 · 직각 · 가로 꽉 참. 높이는 bottom/modal 55, 로그인 56(로고 24 가 잡는다).
///
/// ```swift
/// ButtonLarge("피드백 시작하기", .bottom) { }
/// ButtonLarge("다시 연습하기", .bottom, tone: .light) { }
/// ButtonLarge(.modal, tone: .twoColor) {
///     Button("취소") { }
/// } trailing: {
///     Button("삭제") { }.disabled(true)     // 한쪽만 비활성 — 자식 modifier 로 표현
/// }
/// ButtonLarge("카카오로 시작하기", login: .kakao) { }
/// ```
///
/// **왜 ButtonStyle 이 아니라 View 인가**: 2버튼 변형이 divider·반반 배경·슬롯 2개를 가져서
/// 버튼 하나를 꾸미는 `ButtonStyle` 로는 표현이 안 된다. 단일만 스타일로 두면 한 Figma 가족이
/// 두 메커니즘으로 쪼개지므로 타입 하나로 합쳤다. 내부 세그먼트는 여전히 `ButtonStyle` 로 눌림을 굴린다.
///
/// 상태는 손대지 않는다 — pressed·disabled 는 자동이고, 로딩은 `.hilitButtonLoading(_:)`.
/// 어두운 화면이면 화면 루트에 `.hilitSurface(.dark)` 하나 — 단일 버튼의 비활성 배색이 거기서 갈린다.
public struct ButtonLarge<Leading: View, Trailing: View>: View {
    // 제네릭 안에 중첩하면 특수화마다 다른 타입이 돼 내부 스타일과 안 맞물린다 — 파일 스코프에 두고 별칭만.
    public typealias Kind = ButtonLargeKind
    public typealias Tone = ButtonLargeTone
    public typealias PairTone = ButtonLargePairTone
    public typealias LoginProvider = ButtonLargeLoginProvider

    private enum Content {
        case single(title: String, tone: Tone, action: () -> Void)
        case pair(tone: PairTone)
        case login(title: String, provider: LoginProvider, showsLogo: Bool, action: () -> Void)
    }

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.hilitButtonIsLoading) private var isLoading
    @Environment(\.hilitSurface) private var surface

    private let kind: Kind
    private let content: Content
    private let leading: Leading
    private let trailing: Trailing

    public var body: some View {
        Group {
            switch content {
            case let .single(title, tone, action):
                single(title: title, tone: tone, action: action)
            case let .pair(tone):
                pair(tone: tone)
            case let .login(title, provider, showsLogo, action):
                login(title: title, provider: provider, showsLogo: showsLogo, action: action)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 단일

    private func single(title: String, tone: Tone, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(
                SingleStyle(kind: kind, tone: tone, surface: surface, isEnabled: isEnabled, isLoading: isLoading)
            )
    }

    // MARK: - 2버튼

    private func pair(tone: PairTone) -> some View {
        HStack(spacing: tone.dividerColor == nil ? 0 : .ds(.p8)) {
            leading
                .buttonStyle(SegmentStyle(kind: kind, tone: tone, side: .leading))
            if let dividerColor = tone.dividerColor {
                // @ds(spacing): 1×25 — 두 라벨 사이 구분선 (토큰 없음)
                Rectangle()
                    .fill(dividerColor)
                    .frame(width: 1, height: 25)
            }
            trailing
                .buttonStyle(SegmentStyle(kind: kind, tone: tone, side: .trailing))
        }
        .padding(kind.pairInsets(tone: tone))
        .background {
            if let shared = tone.sharedBackground {
                shared.ignoresSafeArea(edges: kind.safeAreaEdges)
            }
        }
    }

    // MARK: - 로그인

    /// 로고는 제공자가 결정하므로 라벨을 여기서 조립한다 — 호출부가 «kakao 면 어느 에셋» 을 알 필요가 없다.
    private func login(
        title: String,
        provider: LoginProvider,
        showsLogo: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: .ds(.p8)) {
                if showsLogo {
                    provider.logo
                        .resizable()
                        .scaledToFit()
                        .frame(width: LoginProvider.logoSize, height: LoginProvider.logoSize)
                }
                Text(title)
            }
        }
        .buttonStyle(LoginStyle(provider: provider, isEnabled: isEnabled, isLoading: isLoading))
    }
}

// MARK: - init

public extension ButtonLarge where Leading == EmptyView, Trailing == EmptyView {
    /// 단일 버튼. `tone` 은 시트 행(`dark`/`light`) — pressed·disabled 는 넘기지 않는다(자동).
    init(_ title: String, _ kind: Kind, tone: Tone = .dark, action: @escaping () -> Void) {
        #if DEBUG
        assert(!(kind == .modal && tone == .light), "모달에는 light 시안이 없다 — .bottom 을 쓰거나 .dark 로.")
        assert(kind != .login, "로그인 버튼은 배색·로고가 제공자에 묶여 있다 — ButtonLarge(_:login:) 을 쓴다.")
        #endif
        self.kind = kind
        self.content = .single(title: title, tone: tone, action: action)
        self.leading = EmptyView()
        self.trailing = EmptyView()
    }

    /// 로그인 제공자 버튼 — 배경·라벨색·로고가 `provider` 한 벌로 결정된다. h56 · px8/py16 · gap8.
    ///
    /// - Parameters:
    ///   - title: 라벨. sub7(SemiBold 18).
    ///   - provider: `.kakao` / `.apple`.
    ///   - showsLogo: Figma `icon` 축. 끄면 라벨만 남는다.
    init(
        _ title: String,
        login provider: LoginProvider,
        showsLogo: Bool = true,
        action: @escaping () -> Void
    ) {
        self.kind = .login
        self.content = .login(title: title, provider: provider, showsLogo: showsLogo, action: action)
        self.leading = EmptyView()
        self.trailing = EmptyView()
    }
}

public extension ButtonLarge {
    /// 2버튼. 한쪽만 비활성은 해당 자식에 `.disabled(true)`.
    init(
        _ kind: Kind,
        tone: PairTone = .dark,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        #if DEBUG
        assert(!(kind == .modal && tone == .gray), "모달에는 gray 페어 시안이 없다.")
        assert(kind != .login, "로그인 버튼은 2버튼 시안이 없다 — .bottom / .modal 을 쓴다.")
        #endif
        self.kind = kind
        self.content = .pair(tone: tone)
        self.leading = leading()
        self.trailing = trailing()
    }
}

// MARK: - 스펙

private extension ButtonLargeKind {
    /// 라벨 한 판이 갖는 여백 — 단일 버튼과 반반(twoColor) 반쪽이 같은 값을 쓴다.
    /// Figma: bottom 435:691 px24/pt22/pb10 · modal 435:711 px8/py16 · login 435:812 px8/py16.
    var contentInsets: EdgeInsets {
        switch self {
        case .bottom: EdgeInsets(top: .ds(.p22), leading: .ds(.p24), bottom: .ds(.p10), trailing: .ds(.p24))
        case .modal, .login: EdgeInsets(top: .ds(.p16), leading: .ds(.p8), bottom: .ds(.p16), trailing: .ds(.p8))
        }
    }

    /// 2버튼 컨테이너 여백. 반반(twoColor)은 컨테이너가 풀블리드라 0 — 반쪽이 `contentInsets` 를 직접 갖는다
    /// (Figma 435:683 / 435:707 — 반쪽 폭 187.5 = 375/2).
    /// 공유 배경 톤의 위 여백은 20 으로 단일(22)과 다르다 — Figma `filled-2` · `2button-1disabled` 실측.
    func pairInsets(tone: ButtonLargePairTone) -> EdgeInsets {
        guard tone != .twoColor else { return EdgeInsets() }
        switch self {
        case .bottom: return EdgeInsets(top: .ds(.p20), leading: .ds(.p24), bottom: .ds(.p10), trailing: .ds(.p24))
        case .modal, .login: return contentInsets
        }
    }

    /// 하단 CTA 만 배경이 안전영역을 덮는다.
    var safeAreaEdges: Edge.Set {
        switch self {
        case .bottom: .bottom
        case .modal, .login: []
        }
    }
}

private extension ButtonLargePairTone {
    /// 반반(twoColor)은 세그먼트가 각자 칠하므로 공유 배경이 없다.
    var sharedBackground: Color? {
        switch self {
        case .dark: Color.HilitBlack.b800
        case .gray: Color.GrayScale.g50
        case .twoColor: nil
        }
    }

    var dividerColor: Color? {
        switch self {
        case .dark: Color.GrayScale.g800
        case .gray: Color.GrayScale.g200
        case .twoColor: nil
        }
    }
}

private extension ButtonLargeLoginProvider {
    /// @ds(spacing): 24 — 로고 한 변. 크기는 에셋에 구워져 있고(`…WithBg24`) 이 값이 버튼 높이 56(= py16×2 + 24)을 만든다.
    static var logoSize: CGFloat { 24 }

    /// 24pt 로고 — 색이 에셋에 구워져 있어 틴트하지 않는다.
    var logo: Image {
        switch self {
        case .kakao: Image.Logo.kakaoWithBg24
        case .apple: Image.Logo.appleWithBg24
        }
    }

    /// 브랜드 배경 — kakao 는 팔레트 밖 브랜드 색.
    var background: Color {
        switch self {
        case .kakao: Color.Brand.kakao
        case .apple: Color.HilitBlack.b900
        }
    }

    var foreground: Color {
        switch self {
        case .kakao: Color.HilitBlack.b900
        case .apple: Color.BlackWhite.white
        }
    }
}

// MARK: - 내부 스타일

/// 단일 버튼 — 배경·테두리·눌림·비활성·로딩을 전부 여기서 굴린다.
/// 시트의 한 칸을 고르는 순서: **열(disabled → pressed)이 행(tone)을 이긴다.**
/// 판(`light/dark`)은 disabled 칸에서만 갈라진다 — 나머지 칸은 판이 무엇이든 같다.
private struct SingleStyle: ButtonStyle {
    let kind: ButtonLargeKind
    let tone: ButtonLargeTone
    let surface: HilitSurface
    let isEnabled: Bool
    let isLoading: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .dsTypography(.sub7)
            .opacity(isLoading ? 0 : 1)
            .overlay { if isLoading { ProgressView().tint(foreground) } }
            .frame(maxWidth: .infinity, minHeight: DSTypography.sub7.lineHeight)
            .padding(kind.contentInsets)
            .foregroundStyle(foreground)
            .background(background(pressed: configuration.isPressed).ignoresSafeArea(edges: kind.safeAreaEdges))
            .overlay {
                if tone == .light {
                    Rectangle().strokeBorder(borderColor, lineWidth: .ds(.semiBold))
                }
            }
            .contentShape(Rectangle())
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }

    /// disabled 라벨은 행(tone)과 무관하게 한 색으로 수렴하되, **판(light/dark)에 따라 갈린다** —
    /// 밝은 판 g300, 어두운 판 g400 (Figma `button-large/bottom` 의 `light/dark` 축, dark·disabled 2117:10194).
    private var foreground: Color {
        guard isEnabled else {
            return surface == .light ? Color.GrayScale.g300 : Color.GrayScale.g400
        }
        return tone == .dark ? Color.BlackWhite.white : Color.HilitBlack.b800
    }

    private func background(pressed: Bool) -> Color {
        guard isEnabled else {
            // 어두운 판에서는 **배경이 활성과 같다** — 죽는 건 라벨뿐이다.
            // 밝은 판용 g50 을 그대로 쓰면 어두운 화면 아래 흰 띠가 튀어 오히려 활성처럼 읽힌다.
            guard surface == .light else { return restingBackground }
            return tone == .dark ? Color.GrayScale.g50 : Color.BlackWhite.white
        }
        guard pressed else { return restingBackground }
        return tone == .dark ? Color.GrayScale.g900 : Color.GrayScale.g100
    }

    /// 눌리지 않은 기본 배경 — 어두운 판의 disabled 가 이 색을 그대로 물려받는다.
    private var restingBackground: Color {
        tone == .dark ? Color.HilitBlack.b800 : Color.BlackWhite.white
    }

    /// `.light` 톤 테두리. 배경과 같은 규칙 — 어두운 판 disabled 는 테두리도 죽이지 않는다.
    private var borderColor: Color {
        isEnabled || surface == .dark ? Color.HilitBlack.b800 : Color.GrayScale.g300
    }
}

/// 2버튼 한쪽 — 공유 배경 톤에서는 배경·divider·여백이 전부 컨테이너 몫이라 라벨색만 맡고,
/// 반반(twoColor)에서는 배경과 여백까지 반쪽이 갖는다(컨테이너가 풀블리드라 여백을 주지 않는다).
private struct SegmentStyle: ButtonStyle {
    enum Side { case leading, trailing }

    @Environment(\.isEnabled) private var isEnabled

    let kind: ButtonLargeKind
    let tone: ButtonLargePairTone
    let side: Side

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .dsTypography(.sub7)
            .frame(maxWidth: .infinity, minHeight: DSTypography.sub7.lineHeight)
            .padding(tone == .twoColor ? kind.contentInsets : EdgeInsets())
            .foregroundStyle(foreground)
            .background {
                if let ownBackground {
                    ownBackground.ignoresSafeArea(edges: kind.safeAreaEdges)
                }
            }
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }

    private var foreground: Color {
        guard isEnabled else {
            // Figma 2button-1disabled 실측 — 어두운 판은 g400, 밝은 판은 g300.
            // 반반은 왼쪽만 밝은 판(g50)이라 좌우가 갈린다(시안엔 2color disabled 가 없어 위 규칙을 그대로 적용).
            switch tone {
            case .gray: return Color.GrayScale.g300
            case .dark: return Color.GrayScale.g400
            case .twoColor: return side == .leading ? Color.GrayScale.g300 : Color.GrayScale.g400
            }
        }
        switch tone {
        case .dark: return Color.BlackWhite.white
        case .gray: return Color.HilitBlack.b800
        case .twoColor: return side == .leading ? Color.GrayScale.g700 : Color.BlackWhite.white
        }
    }

    /// 반반일 때만 세그먼트가 자기 배경을 칠한다.
    private var ownBackground: Color? {
        guard tone == .twoColor else { return nil }
        return side == .leading ? Color.GrayScale.g50 : Color.HilitBlack.b800
    }
}

/// 로그인 버튼 — 배경·라벨색이 제공자에 묶여 있다. 로고는 라벨이 들고 온다.
/// 시안엔 default 만 있어(435:809 · 435:812) pressed·disabled·loading 은 가족 공통 규칙으로 수렴시킨다:
/// 눌림은 불투명도(반반 세그먼트와 동일), 비활성은 g50 바탕 + g300 라벨(단일 filled 와 동일).
private struct LoginStyle: ButtonStyle {
    let provider: ButtonLargeLoginProvider
    let isEnabled: Bool
    let isLoading: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .dsTypography(.sub7)
            .opacity(isLoading ? 0 : 1)
            .overlay { if isLoading { ProgressView().tint(foreground) } }
            .frame(maxWidth: .infinity, minHeight: ButtonLargeLoginProvider.logoSize)
            .padding(ButtonLargeKind.login.contentInsets)
            .foregroundStyle(foreground)
            .background(background)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }

    private var foreground: Color {
        isEnabled ? provider.foreground : Color.GrayScale.g300
    }

    private var background: Color {
        isEnabled ? provider.background : Color.GrayScale.g50
    }
}

#Preview("bottom 단일 — 시트 매트릭스(tone × status)") {
    // Figma button-large 시트 그대로: 행 = tone(dark·light), 열 = default / disabled.
    // pressed 열은 파라미터가 없어 프리뷰로 못 만든다 — 실기기에서 눌러 확인한다.
    VStack(spacing: .ds(.p16)) {
        ForEach(ButtonLargeTone.allCases, id: \.self) { tone in
            VStack(alignment: .leading, spacing: .ds(.p8)) {
                Text(String(describing: tone)).dsTypography(.body6)
                ButtonLarge("버튼", .bottom, tone: tone) {}
                ButtonLarge("버튼", .bottom, tone: tone) {}.disabled(true)
            }
        }
        ButtonLarge("전송 중", .bottom) {}.hilitButtonLoading(true)
    }
    .frame(width: 375)
    .background(Color.BlackWhite.white)
}

#Preview("bottom 단일 — 어두운 판(disabled 는 배경 유지·라벨만 g400)") {
    // Figma button-large/bottom 의 `light/dark` 축 dark 칸(2117:10194). 활성과 나란히 놓아
    // «배경은 그대로, 글자만 죽는다» 를 눈으로 비교한다.
    VStack(spacing: .ds(.p16)) {
        ButtonLarge("면접 시작하기", .bottom) {}
        ButtonLarge("면접 시작하기", .bottom) {}.disabled(true)
    }
    .padding(.vertical, .ds(.p24))
    .frame(width: 375)
    .background(Color.HilitBlack.b900)
    .hilitSurface(.dark)
}

#Preview("bottom 2버튼 — 시트 순서(default·gray·2color·1disabled)") {
    VStack(spacing: .ds(.p16)) {
        ButtonLarge(.bottom, tone: .dark) {
            Button("버튼") {}
        } trailing: {
            Button("버튼2") {}
        }
        ButtonLarge(.bottom, tone: .gray) {
            Button("버튼") {}
        } trailing: {
            Button("버튼2") {}
        }
        // 반반은 컨테이너 여백이 0 — 375 폭에서 반쪽이 정확히 187.5 여야 한다.
        ButtonLarge(.bottom, tone: .twoColor) {
            Button("버튼") {}
        } trailing: {
            Button("버튼2") {}
        }
        // 시트 `1 disabled` — 배색 변형이 아니라 한쪽 자식의 상태다.
        ButtonLarge(.bottom, tone: .dark) {
            Button("버튼") {}
        } trailing: {
            Button("버튼2") {}.disabled(true)
        }
        ButtonLarge(.bottom, tone: .twoColor) {
            Button("버튼") {}
        } trailing: {
            Button("버튼2") {}.disabled(true)
        }
    }
    .frame(width: 375)
    .background(Color.BlackWhite.white)
}

#Preview("modal — 1버튼(default·disabled) · 2버튼(1color·2color)") {
    VStack(spacing: 0) {
        Color.BlackWhite.white.frame(height: 80)
        ButtonLarge("버튼1", .modal) {}
        ButtonLarge("버튼1", .modal) {}.disabled(true)
        ButtonLarge(.modal, tone: .dark) {
            Button("버튼1") {}
        } trailing: {
            Button("버튼2") {}
        }
        ButtonLarge(.modal, tone: .twoColor) {
            Button("버튼1") {}
        } trailing: {
            Button("버튼2") {}
        }
    }
    .frame(width: 335)
}

#Preview("login") {
    // 로그인 화면이 좌우 20 을 갖고 버튼은 335 로 눕는다(375 화면 기준).
    VStack(spacing: .ds(.p12)) {
        ButtonLarge("카카오로 시작하기", login: .kakao) {}
        ButtonLarge("Apple로 시작하기", login: .apple) {}
        ButtonLarge("로고 없이", login: .kakao, showsLogo: false) {}
        ButtonLarge("비활성", login: .kakao) {}.disabled(true)
        ButtonLarge("로그인 중", login: .apple) {}.hilitButtonLoading(true)
    }
    .padding(.horizontal, .ds(.p20))
    .frame(width: 375)
    .background(Color.BlackWhite.white)
}
