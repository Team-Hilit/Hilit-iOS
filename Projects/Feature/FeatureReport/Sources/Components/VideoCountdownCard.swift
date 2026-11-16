//
//  VideoCountdownCard.swift
//  FeatureReport
//
//  Created by EunSeo on 26/07/29.
//

import SharedDesignSystemInterface
import SwiftUI

/// 면접 영상 진입 카드 — 그림은 DS `CountdownCard`(Figma «countdown-card») 가 그리고,
/// 이 타입은 «만료 시각 → 남은 시간·상태» 파생과 1초 갱신, 탭만 소유한다.
///
/// 갱신을 `TimelineView` 로 뷰 안에서 처리하는 이유: 남은 시간은 서버 `video/expiry` 값에서 파생되는 표시값이라
/// State 에 둘 필요가 없다. 리듀서에 1초 틱 effect 를 넣으면 폴링과 무관한 액션이 매초 흘러
/// 테스트·디버깅만 시끄러워진다.
struct VideoCountdownCard: View {
    /// 시청 만료 시각(`video/expiry` 환산) — nil 이면 서버 값을 못 받은 것이라 카운트다운을 감춘다.
    let expiresAt: Date?
    /// 재생 불가(만료·주소 없음) — 회색 변형으로 낮추고 탭을 막는다.
    let isExpired: Bool
    let onTap: () -> Void

    var body: some View {
        // 셀 것이 남았을 때만 매초 다시 그린다 — 만료됐거나 기한을 모르면 정적으로 한 번만 그린다.
        if let expiresAt, !isExpired {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, expiresAt.timeIntervalSince(context.date))
                button(remaining: remaining, isEnded: remaining == 0)
            }
        } else {
            button(remaining: isExpired ? 0 : nil, isEnded: isExpired)
        }
    }

    private func button(remaining: TimeInterval?, isEnded: Bool) -> some View {
        // DS CountdownCard 는 탭을 갖지 않는다(목적지가 화면마다 달라서) — 호출부인 여기가 감싼다.
        Button(action: onTap) {
            CountdownCard(
                title: Self.title,
                subtitle: isEnded ? Self.expiredMessage : Self.activeMessage,
                // 기한을 모르면(nil) 시간 표기를 비운다 — 카운트다운 없는 정적 카드.
                time: remaining.map(Self.formatted) ?? "",
                status: isEnded ? .ended : .active
            )
        }
        .buttonStyle(.plain)
        .disabled(isExpired)
    }

    /// HH:MM:SS — 하루를 넘겨도 시(hour) 자리로 이어 붙인다(00:00:00 자리수 고정).
    static func formatted(_ remaining: TimeInterval) -> String {
        let total = Int(remaining.rounded(.down))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    static let title = "면접 영상 다시보기"
    static let activeMessage = "이 시간이 지나면\n면접 영상을 볼 수 없어요."
    static let expiredMessage = "면접 영상의 시청 기간이 만료되었어요."
}

#Preview("영상 카드") {
    VStack(spacing: .ds(.p16)) {
        VideoCountdownCard(
            expiresAt: Date().addingTimeInterval(3725),
            isExpired: false,
            onTap: {}
        )
        VideoCountdownCard(expiresAt: nil, isExpired: true, onTap: {})
    }
    .padding(.ds(.p20))
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.HilitBlack.b900)
}
