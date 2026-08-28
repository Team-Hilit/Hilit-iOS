//
//  Modal.swift
//  SharedDesignSystemInterface
//
//  Created by EunseoKim on 26/07/30.
//

// Figma: «modal» https://figma.com/design/JL9YPbqBqmaC9Z0I3SzDZS/?node-id=2302-6080
// 케이스 매트릭스(Component System 3, 439:10241): 439:10403 max · 439:10404 인포-박스 미노출 ·
// 439:10405 그래픽 미노출 · 439:10406 아이콘·인포박스 미노출.

import SwiftUI

/// 모달 **카드 층** — 확인·경고 팝업의 흰 판(아이콘·제목·서브텍스트·안내줄) + 하단 `ButtonLarge(.modal)`.
/// 단독으로 화면에 놓지 않는다 — 항상 `.hilitModal` 오버레이에 얹는다(딤·중앙 배치·표시 전환은 그쪽 몫).
/// 카드 세 계열(확인 `Modal` / 홈 안내 `HomeModal` / 로딩 `LoadingModal`)의 선택 기준·표준 레시피는
/// `design/component/display.md` «모달 — 두 층 조립».
///
/// ```swift
/// .hilitModal(isPresented: store.isConfirmPresented) {
///     Modal("텍스트를 입력해주세요",
///           subText: "서브텍스트를 입력해주세요",
///           icon: Image.Img.book,
///           info: "텍스트를 입력해주세요") {
///         ButtonLarge("버튼1", .modal) { send(.userTappedConfirm) }
///     }
/// }
/// ```
///
/// Figma 의 `showIcon`·`showSubText`·`showInfoField` 축은 각 파라미터의 nil 로 표현한다 —
/// 시안 4케이스가 그대로 나온다: max(전부) · 인포박스 미노출(`info` nil) ·
/// 그래픽 미노출(`icon` nil) · 아이콘·인포박스 미노출(둘 다 nil).
/// 텍스트 순서는 «제목 → 서브텍스트» 다 — 홈 모달(`HomeModal`)은 순서가 뒤집혀 있어 별 타입이다.
/// 아이콘은 instance-swap 슬롯이라 열어뒀다(`InfoField` 와 반대 — 모달마다 다른 일러스트가 실재).
/// 일러스트는 디자인된 크기 그대로 그린다 — `.frame` 으로 늘리지 않는다(`design/image.md`).
/// 버튼 슬롯엔 `ButtonLarge(.modal, …)` 단일/2버튼을 그대로 넣는다 — 배색·눌림은 그쪽 몫.
/// 폭은 고정하지 않는다 — 시안 327 은 화면 375 에서 좌우 여백 24 를 뺀 값이라 오버레이 몫.
/// 딤 배경·표시 전환·좌우 여백은 `.hilitModal` 오버레이가 준다 — 이 타입은 카드만 그린다.
public struct Modal<Buttons: View>: View {
    private let text: String
    private let subText: String?
    private let icon: Image?
    private let info: String?
    private let infoStyle: InfoField.Style
    private let buttons: Buttons

    /// - Parameters:
    ///   - text: 제목. 폭이 모자라면 여러 줄 중앙 정렬로 흐른다.
    ///   - subText: 보조 설명. nil 이면 숨김 (Figma `showSubText=false`).
    ///   - icon: 상단 일러스트(`Image.Img.*`). nil 이면 숨김 (Figma `showIcon=false`).
    ///   - info: 안내줄 문구 — `InfoField` 로 그린다. nil 이면 숨김 (Figma `showInfoField=false`).
    ///   - infoStyle: 안내줄 판 색 (Figma 인스턴스의 `color` 축) — 기본 `.gray`,
    ///     경고 모달은 `.error`(빨간 판). `info` 가 nil 이면 무시된다.
    ///   - buttons: 하단 버튼 — `ButtonLarge(.modal, …)`.
    public init(
        _ text: String,
        subText: String? = nil,
        icon: Image? = nil,
        info: String? = nil,
        infoStyle: InfoField.Style = .gray,
        @ViewBuilder buttons: () -> Buttons
    ) {
        self.text = text
        self.subText = subText
        self.icon = icon
        self.info = info
        self.infoStyle = infoStyle
        self.buttons = buttons()
    }

    public var body: some View {
        VStack(spacing: 0) {
            content
            buttons
        }
    }

    private var content: some View {
        VStack(spacing: .ds(.p20)) {
            if let icon {
                icon
            }
            textBlock
            if let info {
                InfoField(info, style: infoStyle)
            }
        }
        .padding(.horizontal, .ds(.p24))
        .padding(.vertical, .ds(.p40))
        .frame(maxWidth: .infinity)
        .background(Color.BlackWhite.white)
    }

    private var textBlock: some View {
        VStack(spacing: .ds(.p4)) {
            // @ds(color): #262A30 → GrayScale.g900 — 모달 제목. 시안 변수명은 «Gray scale/800»(값 #262A30)인데
            // Color Guide 의 800 은 #31333B 라 이름으론 안 맞는다. 값이 g900(#27282F)에 붙어 그쪽으로 맞췄다.
            Text(text)
                .dsTypography(.sub4)
                .foregroundStyle(Color.GrayScale.g900)
            if let subText {
                Text(subText)
                    .dsTypography(.body6)
                    .foregroundStyle(Color.GrayScale.g500)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Previews

/// 시안 프레임 327 = 화면 375 − 좌우 24. 실사용 폭은 `.hilitModal` 이 정한다.
private let previewCardWidth: CGFloat = 327

#Preview("max case — 439:10403") {
    Modal(
        "텍스트를 입력해주세요",
        subText: "서브텍스트를 입력해주세요",
        icon: Image.Img.book,
        info: "텍스트를 입력해주세요"
    ) {
        ButtonLarge("버튼1", .modal) {}
    }
    .frame(width: previewCardWidth)
    .background(Color.HilitBlack.b900.opacity(0.5))
}

#Preview("인포-박스 미노출 — 439:10404") {
    Modal(
        "텍스트를 입력해주세요",
        subText: "서브텍스트를 입력해주세요",
        icon: Image.Img.book
    ) {
        ButtonLarge("버튼1", .modal) {}
    }
    .frame(width: previewCardWidth)
}

#Preview("그래픽 미노출 — 439:10405") {
    Modal(
        "텍스트를 입력해주세요",
        subText: "서브텍스트를 입력해주세요",
        info: "텍스트를 입력해주세요"
    ) {
        ButtonLarge("버튼1", .modal) {}
    }
    .frame(width: previewCardWidth)
}

#Preview("빨간 안내줄 — 435:8895") {
    Modal(
        "포트폴리오를\n새로 업로드할 수 없어요.",
        subText: "한 달에 한 번만 포트폴리오를 업로드할 수 있어요.",
        info: "이번 달 남은 기회 0번",
        infoStyle: .error
    ) {
        ButtonLarge(.modal, tone: .twoColor) {
            Button("버튼1") {}
        } trailing: {
            Button("버튼2") {}
        }
    }
    .frame(width: previewCardWidth)
}

#Preview("아이콘·인포박스 미노출 — 439:10406") {
    Modal("텍스트를 입력해주세요", subText: "서브텍스트를 입력해주세요") {
        ButtonLarge("버튼1", .modal) {}
    }
    .frame(width: previewCardWidth)
}

#Preview("텍스트만 + 2버튼") {
    Modal("정말 나가시겠어요?") {
        ButtonLarge(.modal, tone: .twoColor) {
            Button("취소") {}
        } trailing: {
            Button("나가기") {}
        }
    }
    .frame(width: previewCardWidth)
}
