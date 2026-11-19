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

import DomainPortfolioInterface
import Foundation
import SharedDesignSystemInterface
import SwiftUI

/// 마이페이지 모달의 **카드 층**. 딤·중앙 배치·표시 전환은 `.hilitModal` 오버레이 몫이라 여기선 카드만 그린다.
///
/// 시안의 버튼 라벨이 «버튼1 / 버튼2» 플레이스홀더라 **카피는 임시**다 — 확정되면 이 파일만 고친다.
/// 가능 여부·다시 가능한 날짜는 케이스가 아니라 `availability`(서버 목록 값)에서 읽는다 — 날짜를 지어내지 않는다(HLT-106).
struct MyPageModalCard: View {
    let modal: MyPageFeature.Modal
    let availability: PortfolioAvailability
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        switch modal {
        case .deleteConfirm:
            Modal(
                "포트폴리오를 삭제하시겠어요?",
                subText: "포트폴리오 파일이 삭제되어도 지난 면접 리포트는 그대로 남아요.",
                info: reuploadNotice
            ) {
                buttons(cancel: "취소", confirm: "삭제하기")
            }

        case .deleteBlocked(.interviewInProgress):
            Modal(
                "포트폴리오를 삭제할 수 없어요",
                subText: "현재 면접이 진행되고 있어요. 면접이 끝나면 다시 삭제를 시도해주세요.",
                info: reuploadNotice
            ) {
                buttons(cancel: "취소", confirm: "확인")
            }

        // 시안 없음 — 면접 진행 중 판(435:8893)과 같은 틀에 사유·날짜만 바꿔 끼운다. 카피 임시.
        case .deleteBlocked(.monthlyLimit):
            Modal(
                "포트폴리오를 삭제할 수 없어요",
                subText: "포트폴리오 삭제는 한 달에 한 번만 할 수 있어요.",
                info: availability.nextDeleteAvailableAt
                    .map { "\(PortfolioAvailability.dayText($0))부터 다시 삭제할 수 있어요" }
                    ?? "이번 달 남은 삭제 기회 0번",
                infoStyle: .error
            ) {
                buttons(cancel: "취소", confirm: "확인")
            }

        case .replaceConfirm:
            // @ds(component): 안내줄 아이콘 coupon/16px — Modal 의 info 는 InfoField(.gray)(원 안 i) 고정이라
            //                 시안의 티켓 아이콘이 안 나온다
            Modal(
                "포트폴리오를\n새로 업로드하시겠어요?",
                subText: "한 달에 한 번만 포트폴리오를\n새로 업로드할 수 있어요.",
                info: "이번 달 남은 기회 \(availability.replaceAvailable ? 1 : 0)번"
            ) {
                buttons(cancel: "취소", confirm: "업로드하기")
            }

        // HLT-113 문구 — «이번 달은 더 이상 교체할 수 없어요. 다음 가능일: N일». 날짜는 서버 `nextAvailableAt`.
        case .replaceBlocked:
            Modal(
                "포트폴리오를\n새로 업로드할 수 없어요.",
                subText: "이번 달은 더 이상 교체할 수 없어요.",
                info: availability.nextReplaceAvailableAt
                    .map { "다음 가능일: \(PortfolioAvailability.dayText($0))" }
                    ?? "이번 달 남은 기회 0번",
                infoStyle: .error
            ) {
                buttons(cancel: "취소", confirm: "확인")
            }

        case .loading:
            LoadingModal()

        case .logoutConfirm:
            // 카피는 안드로이드 빌드 캡처 기준 — Figma 모달 모음에 없는 모달이라 시안 노드가 없다.
            Modal("로그아웃하시겠어요?", subText: "언제든 다시 로그인할 수 있어요.") {
                buttons(cancel: "취소", confirm: "로그아웃")
            }
        }
    }

    private func buttons(cancel: String, confirm: String) -> some View {
        ButtonLarge(.modal, tone: .twoColor) {
            Button(cancel, action: onCancel)
        } trailing: {
            Button(confirm, action: onConfirm)
        }
    }

    /// 삭제 계열 안내줄 — «삭제 후 이번 달 재업로드 가능 여부» 고지(PRD 3.2-⑤). 카피 확정 시 이 프로퍼티만 고친다.
    /// 막혀 있으면 서버가 준 다시 가능한 날짜를 쓰고(HLT-106 — «다음 달 1일» 하드코딩 제거), 날짜가 없으면 날짜 없이 알린다.
    private var reuploadNotice: String {
        guard !availability.replaceAvailable else { return "이번 달 안에 다시 올릴 수 있어요" }
        return availability.nextReplaceAvailableAt
            .map { "\(PortfolioAvailability.dayText($0))부터 다시 올릴 수 있어요" }
            ?? "이번 달에는 다시 올릴 수 없어요"
    }
}

private let previewNextMonth = Date(timeIntervalSince1970: 1_798_729_200) // 2027-01-01 00:00 KST

#Preview("삭제 확인") {
    Color.GrayScale.g50
        .hilitModal(isPresented: true) {
            MyPageModalCard(modal: .deleteConfirm, availability: .init(), onCancel: {}, onConfirm: {})
        }
}

#Preview("삭제 확인 — 재업로드 소진") {
    Color.GrayScale.g50
        .hilitModal(isPresented: true) {
            MyPageModalCard(
                modal: .deleteConfirm,
                availability: .init(replaceAvailable: false, nextReplaceAvailableAt: previewNextMonth),
                onCancel: {},
                onConfirm: {}
            )
        }
}

#Preview("삭제 불가 — 면접 진행 중") {
    Color.GrayScale.g50
        .hilitModal(isPresented: true) {
            MyPageModalCard(modal: .deleteBlocked(.interviewInProgress), availability: .init(), onCancel: {}, onConfirm: {})
        }
}

#Preview("삭제 불가 — 이번 달 삭제 한도") {
    Color.GrayScale.g50
        .hilitModal(isPresented: true) {
            MyPageModalCard(
                modal: .deleteBlocked(.monthlyLimit),
                availability: .init(deleteAvailable: false, nextDeleteAvailableAt: previewNextMonth),
                onCancel: {},
                onConfirm: {}
            )
        }
}

#Preview("업로드 확인") {
    Color.GrayScale.g50
        .hilitModal(isPresented: true) {
            MyPageModalCard(modal: .replaceConfirm, availability: .init(), onCancel: {}, onConfirm: {})
        }
}

#Preview("업로드 불가") {
    Color.GrayScale.g50
        .hilitModal(isPresented: true) {
            MyPageModalCard(
                modal: .replaceBlocked,
                availability: .init(replaceAvailable: false, nextReplaceAvailableAt: previewNextMonth),
                onCancel: {},
                onConfirm: {}
            )
        }
}

#Preview("로그아웃 확인") {
    Color.GrayScale.g50
        .hilitModal(isPresented: true) {
            MyPageModalCard(modal: .logoutConfirm, availability: .init(), onCancel: {}, onConfirm: {})
        }
}

#Preview("로딩") {
    Color.GrayScale.g50
        .hilitModal(isPresented: true) {
            MyPageModalCard(modal: .loading, availability: .init(), onCancel: {}, onConfirm: {})
        }
}
