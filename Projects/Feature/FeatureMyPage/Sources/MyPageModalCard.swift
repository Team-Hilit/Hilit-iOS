//
//  MyPageModalCard.swift
//  FeatureMyPage
//
//  Created by 서정원 on 26/08/01.
//

// Figma: «[Part5] 마이페이지 / 모달을 모아봤어요»
//        https://figma.com/design/JL9YPbqBqmaC9Z0I3SzDZS/?node-id=435-9709
//        삭제 확인 435:8892 · 삭제 불가 435:8893(안내줄 없음)·435:8894 ·
//        업로드 불가 435:8895 · 업로드 확인 435:8896 · 로딩 435:8897

import SharedDesignSystemInterface
import SwiftUI

/// 마이페이지 모달의 **카드 층**. 딤·중앙 배치·표시 전환은 `.hilitModal` 오버레이 몫이라 여기선 카드만 그린다.
///
/// 시안의 버튼 라벨이 «버튼1 / 버튼2» 플레이스홀더라 **카피는 임시**다 — 확정되면 이 파일만 고친다.
struct MyPageModalCard: View {
    let modal: MyPageFeature.Modal
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        switch modal {
        case let .deleteConfirm(canReupload):
            Modal(
                "포트폴리오를 삭제하시겠어요?",
                subText: "포트폴리오 파일이 삭제되어도 지난 면접 리포트는 그대로 남아요.",
                info: Self.reuploadNotice(canReupload)
            ) {
                buttons(cancel: "취소", confirm: "삭제하기")
            }

        case let .deleteBlocked(canReupload):
            Modal(
                "포트폴리오를 삭제할 수 없어요",
                subText: "현재 면접이 진행되고 있어요. 면접이 끝나면 다시 삭제를 시도해주세요.",
                info: canReupload.map(Self.reuploadNotice)
            ) {
                buttons(cancel: "취소", confirm: "확인")
            }

        case let .replaceConfirm(remaining):
            // @ds(component): 안내줄 아이콘 coupon/16px — Modal 의 info 는 InfoField(.gray)(원 안 i) 고정이라
            //                 시안의 티켓 아이콘이 안 나온다
            Modal(
                "포트폴리오를\n새로 업로드하시겠어요?",
                subText: "한 달에 한 번만 포트폴리오를\n새로 업로드할 수 있어요.",
                info: "이번 달 남은 기회 \(remaining)번"
            ) {
                buttons(cancel: "취소", confirm: "업로드하기")
            }

        case let .replaceBlocked(remaining):
            Modal(
                "포트폴리오를\n새로 업로드할 수 없어요.",
                subText: "한 달에 한 번만 포트폴리오를 업로드할 수 있어요.",
                info: "이번 달 남은 기회 \(remaining)번",
                infoStyle: .error
            ) {
                buttons(cancel: "취소", confirm: "확인")
            }

        case .loading:
            LoadingModal()
        }
    }

    private func buttons(cancel: String, confirm: String) -> some View {
        ButtonLarge(.modal, tone: .twoColor) {
            Button(cancel, action: onCancel)
        } trailing: {
            Button(confirm, action: onConfirm)
        }
    }

    /// 삭제 계열 안내줄 — «삭제 후 이번 달 재업로드 가능 여부» 고지(PRD 3.2-⑤). 카피 확정 시 이 함수만 고친다.
    private static func reuploadNotice(_ canReupload: Bool) -> String {
        canReupload ? "이번 달 안에 다시 올릴 수 있어요" : "다음 달 1일부터 다시 올릴 수 있어요"
    }
}

#Preview("삭제 확인") {
    Color.GrayScale.g50
        .hilitModal(isPresented: true) {
            MyPageModalCard(modal: .deleteConfirm(canReupload: true), onCancel: {}, onConfirm: {})
        }
}

#Preview("삭제 불가 — 안내줄 없음") {
    Color.GrayScale.g50
        .hilitModal(isPresented: true) {
            MyPageModalCard(modal: .deleteBlocked(canReupload: nil), onCancel: {}, onConfirm: {})
        }
}

#Preview("업로드 확인") {
    Color.GrayScale.g50
        .hilitModal(isPresented: true) {
            MyPageModalCard(modal: .replaceConfirm(remaining: 1), onCancel: {}, onConfirm: {})
        }
}

#Preview("로딩") {
    Color.GrayScale.g50
        .hilitModal(isPresented: true) {
            MyPageModalCard(modal: .loading, onCancel: {}, onConfirm: {})
        }
}
