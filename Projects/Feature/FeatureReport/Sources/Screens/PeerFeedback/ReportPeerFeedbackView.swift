//
//  ReportPeerFeedbackView.swift
//  FeatureReport
//
//  Created by EunSeo on 26/07/25.
//

import ComposableArchitecture
import DomainFeedbackShareInterface
import DomainInterviewReportInterface
import SharedDesignSystemInterface
import SwiftUI

// Figma: «Report_PeerFeedback_RequestItems» https://figma.com/design/JL9YPbqBqmaC9Z0I3SzDZS/?node-id=443-8006
//        링크 생성 완료 팝업이 얹힌 판 443:8082 (인스턴스 443:8121 = DS «modal» 2302:6080)
//        링크 복사 완료 팝업이 얹힌 판 1321:10338 (인스턴스 1321:10451 = DS «home modal» 435:1565).
/// 지인에게 평가받을 태도 항목 선택 — 다크 판 위 «아이콘 + 이름 + 토글» 5줄과 하단 CTA 한 개.
/// CTA 를 누르면 링크가 만들어지고 그 자리에서 완료 팝업이 뜬다(링크 복사만 남는다).
/// 복사하면 복사 완료 팝업으로 바뀌고, 그 판이 2초 뒤 화면을 리포트 메인으로 내보낸다.
@ViewAction(for: ReportPeerFeedbackFeature.self)
public struct ReportPeerFeedbackView: View {
    @Bindable public var store: StoreOf<ReportPeerFeedbackFeature>

    public init(store: StoreOf<ReportPeerFeedbackFeature>) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            titleBox
            axisList
                // @ds(layout): 51 — 머리글↔항목 목록 사이 (시안 절대 배치 217→268, spacing 스케일 밖)
                .padding(.top, 51)
            Spacer(minLength: 0)
            cta
        }
        .background(Color.HilitBlack.b900.ignoresSafeArea())
        .hilitSurface(.dark)
        .overlay(alignment: .bottom) {
            if let toast = store.toast {
                BubbleField(toast)
                    // @ds(layout): 65 — 토스트를 CTA(높이 55) 위 10pt 에 놓는 값 (BubbleField 독스트링의 표준 배치)
                    .padding(.bottom, 65)
            }
        }
        // 팝업 두 판 — 딤·중앙 배치·좌우 여백 24 는 DS 오버레이 몫(443:8082 · 1321:10338).
        // 스스로 닫지 않는다 — 닫는 건 리듀서다(복사 버튼·상단 X·복사 완료 판의 2초).
        .hilitModal(item: store.popup) { popup in
            switch popup {
            case .shareLinkReady:
                shareLinkReadyPopup
            case .linkCopied:
                linkCopiedPopup
            }
        }
        // X = 팝업이 떠 있으면 그 판 닫기, 없으면 화면 나가기 — 판단은 리듀서가 한다.
        // `background: .filled` — 스크롤 화면이라 투명 바로 두면 항목 목록이 X 뒤로 지나간다.
        .hilitNavigationBar(surface: .dark, background: .filled, onClose: { send(.userTappedBack) })
        // 미승격 서버 에러코드 — 토스트로 번역할 문구가 없어 서버 원문을 OS 기본 Alert 로 (임시 노출 규칙).
        .alert($store.scope(state: \.alert, action: \.alert))
        .onAppear { send(.onAppear) }
    }

    /// 하단 CTA. 링크가 이미 있으면(생성 성공·진입 회수) 항목이 잠겨 «생성» 이 남을 자리가 없다 —
    /// 그 자리를 재복사가 받는다(복사하지 못한 채 나갔어도 링크를 다시 손에 넣을 수 있게).
    ///
    /// 비활성(항목 0개)은 화면 루트 `.hilitSurface(.dark)` 를 타 다크 판 배색(b800 판 + g400 라벨)으로
    /// 그려진다 — 이 화면 시안(443:8046)의 g900 판 + 흰 라벨과는 판·라벨색이 조금 다르지만,
    /// 컴포넌트 시트의 `light/dark` 축이 나중에 그린 정본이라 그쪽을 따른다.
    @ViewBuilder
    private var cta: some View {
        if store.isAxisLocked {
            ButtonLarge("링크 복사하기", .bottom) {
                send(.userTappedCopyLink)
            }
        } else {
            ButtonLarge("피드백 링크 생성", .bottom) {
                send(.userTappedCreateLink)
            }
            .hilitButtonLoading(store.isCreating)
            .disabled(store.selectedAxes.isEmpty)
        }
    }

    /// 화면 머리글 — 글자색(다크 판 white/g300)·수직 리듬은 DS `TitleBox` 가 `.hilitSurface(.dark)` 에서 파생.
    private var titleBox: some View {
        TitleBox(
            ["지인에게 어떤 항목을", "평가받을까요?"],
            sub: "지인은 면접 태도를 중심으로 평가합니다.\n평가받고 싶은 항목을 선택해 주세요."
        )
        .padding(.horizontal, .ds(.p20))
        // 시안은 네비바 아래(87)에서 머리글 첫 줄까지 20 — title-box 프레임 앞 10 + 프레임 안 pt10.
        .padding(.top, .ds(.p20))
    }

    /// 태도 항목 5줄 — 순서는 `AttitudeAxisKind.allCases`(시선·표정·자세·손동작·목소리) 고정.
    /// 줄 사이 `HilitDivider` 는 VStack 의 자식이라 위아래로 spacing 24 를 나눠 갖는다 (Figma 실측 pitch 76).
    /// 링크가 이미 있으면 토글을 잠근다 — 항목은 생성 시점에 링크로 굳어 바꿀 수 없다.
    private var axisList: some View {
        VStack(spacing: .ds(.p24)) {
            ForEach(Array(AttitudeAxisKind.allCases.enumerated()), id: \.offset) { index, axis in
                if index > 0 {
                    HilitDivider()
                }
                axisRow(axis)
            }
        }
        .padding(.horizontal, .ds(.p20))
    }

    /// 한 줄 — «28pt 아이콘 + 이름 + 오른쪽 끝 토글» (Figma 443:8053).
    private func axisRow(_ axis: AttitudeAxisKind) -> some View {
        HStack(spacing: .ds(.p8)) {
            // 시안이 `feedback/28px/*` 를 쓴다 — 크기마다 다시 그려진 에셋이라 20pt 판을 늘리지 않는다.
            GuestAttitudeCopy.icon28(for: axis)
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
            Text(GuestAttitudeCopy.name(for: axis))
                .dsTypography(.sub7)
                .foregroundStyle(Color.BlackWhite.white)
            Spacer(minLength: 0)
            // 라벨은 행 왼쪽에 이미 있으니 토글은 스위치만 — `HilitToggleStyle` 은 라벨을 넘기면
            // 스위치 왼쪽에 붙이고 `labelsHidden()` 이 듣지 않는다(커스텀 스타일 한계).
            Toggle(
                isOn: Binding(
                    get: { store.selectedAxes.contains(axis) },
                    set: { send(.userToggledAxis(axis, isOn: $0)) }
                )
            ) {
                EmptyView()
            }
            .toggleStyle(.hilit)
            .disabled(store.isAxisLocked)
            .accessibilityLabel(GuestAttitudeCopy.name(for: axis))
        }
    }

    /// 링크 생성 완료 팝업의 **카드** — 링크 일러스트 74 + 두 줄 타이틀 + «링크 복사하기»(Figma 443:8121).
    /// 딤·폭·표출 전환은 `.hilitModal` 몫이라 여기서 그리지 않는다.
    /// 회수한 기존 링크에도 같은 카드를 쓰지만 «생성 완료» 는 거짓이 되므로 제목만 가른다.
    private var shareLinkReadyPopup: some View {
        Modal(
            store.isLinkRecovered ? Self.recoveredTitle : Self.createdTitle,
            icon: Image.Img.link
        ) {
            ButtonLarge("링크 복사하기", .modal) {
                send(.userTappedCopyLink)
            }
        }
    }

    /// 링크 복사 완료 팝업의 **카드** — 같은 링크 일러스트에 보조문구 + 타이틀, 버튼 없음(Figma 1321:10451).
    /// 시안 인스턴스가 DS «home modal» 이라 `Modal` 이 아니라 `HomeModal` 이다
    /// (보조문구가 타이틀 **위**, 버튼 슬롯 없음 — 두 판의 차이가 그 둘이다).
    /// 사용자가 닫을 버튼이 없는 판이라 수명은 리듀서가 갖는다(2초 뒤 리포트 메인).
    private var linkCopiedPopup: some View {
        HomeModal(
            Self.copiedTitle,
            subTitle: Self.copiedSubTitle,
            icon: Image.Img.link
        )
    }

    /// 방금 만든 링크 — 시안 문구(443:8121).
    static let createdTitle = "링크 생성 완료!\n지인에게 보내보세요."
    /// 서버에서 회수한 기존 링크 — 시안에 없는 판이다.
    // TODO: 카피 확정 대기 — 재복사 모달 문구.
    static let recoveredTitle = "이미 만들어 둔 링크예요.\n지인에게 보내보세요."
    /// 복사 완료 판 문구 — 시안 그대로(1321:10451).
    static let copiedTitle = "링크를 지인에게 보내보세요!"
    static let copiedSubTitle = "링크 복사 완료"
}

// Preview 컨텍스트는 `previewValue` 를 자동으로 쓴다 — 링크 생성·복사 모두 주입 없이 돈다.
#Preview("항목 선택") {
    ReportPeerFeedbackView(
        store: Store(initialState: ReportPeerFeedbackFeature.State(sessionId: 1)) {
            ReportPeerFeedbackFeature()
        } withDependencies: {
            // `previewValue.status` 는 ACTIVE 링크를 주므로 진입 회수가 걸려 항목이 잠긴다 —
            // 고르는 화면을 보려면 «링크 없음» 으로 둔다(회수 판은 아래 프리뷰).
            $0.feedbackShareClient.status = { _ in throw FeedbackShareError.shareNotFound }
        }
    )
}

#Preview("이미 만들어 둔 링크 회수 — 항목 잠김") {
    ReportPeerFeedbackView(
        store: Store(initialState: ReportPeerFeedbackFeature.State(sessionId: 1)) {
            ReportPeerFeedbackFeature()
        }
    )
}

#Preview("링크 생성 완료") {
    ReportPeerFeedbackView(
        store: Store(initialState: previewState(popup: .shareLinkReady)) {
            ReportPeerFeedbackFeature()
        }
    )
}

#Preview("링크 복사 완료 — 2초 뒤 나간다") {
    ReportPeerFeedbackView(
        store: Store(initialState: previewState(popup: .linkCopied)) {
            ReportPeerFeedbackFeature()
        }
    )
}

/// 팝업 판 프리뷰용 — 링크가 이미 있는(항목 잠긴) 상태.
private func previewState(popup: ReportPeerFeedbackFeature.Popup) -> ReportPeerFeedbackFeature.State {
    var state = ReportPeerFeedbackFeature.State(sessionId: 1)
    state.selectedAxes = [.gaze, .voice]
    state.createdLink = "https://hilit.chottu.link/report?reportId=preview-token"
    state.popup = popup
    return state
}
