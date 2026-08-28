//
//  MyPageProfileSection.swift
//  FeatureMyPage
//
//  Created by 서정원 on 26/08/21.
//

import SharedDesignSystemInterface
import SwiftUI

/// 마이페이지 맨 위 흰 판 — 이름·직군·연차·티켓 카드와 계정 카드 (시안 1858:6912).
/// 화면에서 떼어 낸 건 길이 때문만이 아니다 — 이 판은 조회값을 그리기만 해서 store 없이
/// 값 하나로 닫힌다(밖으로 나가는 건 로그아웃 하나).
struct MyPageProfileSection: View {
    let profile: MyPageFeature.Profile
    let onLogout: () -> Void

    var body: some View {
        VStack(spacing: .ds(.p8)) {
            profileCard
            accountCard
        }
        .padding(.horizontal, .ds(.p20))
        .padding(.vertical, .ds(.p12))
        .frame(maxWidth: .infinity)
        .background(Color.BlackWhite.white)
    }

    private var profileCard: some View {
        VStack(spacing: .ds(.p12)) {
            nameRow
            ticketRow
        }
        .padding(.horizontal, .ds(.p14))
        .padding(.vertical, .ds(.p10))
        .background(Color.BlackWhite.white)
        .overlay { cardBorder }
    }

    /// 이름 · 직군 · 연차 한 줄 (시안 1858:6914). 직군·연차는 `TagLabel` 이 아니다 — 시안의
    /// «iOS 2년차» 는 판도 좌우 여백도 없는 맨 텍스트라, 태그를 쓰면 px12 만큼 벌어진다.
    private var nameRow: some View {
        // @ds(spacing): 6 — 이름과 «직군 · 연차» 사이 (spacing 스케일에 6 이 없다)
        HStack(spacing: 6) {
            // 이름은 중괄호로 감싼다 — HILIT 이 사람 이름을 부를 때 쓰는 표기다(시안 «{재원}»,
            // 게스트 피드백 «{이름}님,» 과 같은 규칙). 조회 전 빈 값이 «{}» 로 보이지 않게 그때는 비운다.
            Text(profile.name.isEmpty ? "" : "{\(profile.name)}")
                .dsTypography(.body1)
                .foregroundStyle(Color.HilitBlack.b800)
            HStack(spacing: .ds(.p4)) {
                Text(profile.jobGroup)
                Text(profile.careerLevel)
            }
            .dsTypography(.body7)
            .foregroundStyle(Color.GrayScale.g500)
            Spacer(minLength: 0)
        }
    }

    private var ticketRow: some View {
        HStack(spacing: 0) {
            HStack(spacing: .ds(.p4)) {
                icon(Image.Coupon.default)
                Text("남은 면접 티켓")
                    .dsTypography(.body6)
                    .foregroundStyle(Color.GrayScale.g500)
            }
            Spacer(minLength: .ds(.p8))
            TagLabel("\(profile.remainingTickets)회", style: .greenGreen)
        }
        .padding(.horizontal, .ds(.p14))
        .padding(.vertical, .ds(.p8))
        .background(Color.GrayScale.g50)
    }

    /// 소셜 계정 줄. 시안은 프레임마다 로그아웃 버튼 유무가 갈리는데(로그인 상태에서 늘 필요한 동선이라)
    /// max 케이스(MyPage_Main)를 따라 항상 노출한다.
    private var accountCard: some View {
        HStack(spacing: .ds(.p12)) {
            icon(profile.provider == "APPLE" ? Image.Logo.appleWithBg : Image.Logo.kakaoWithBg)
            Text(profile.email)
                .dsTypography(.body7)
                .foregroundStyle(Color.GrayScale.g500)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("로그아웃", action: onLogout)
                .buttonStyle(.miniSub(.none))
        }
        .padding(.horizontal, .ds(.p14))
        .padding(.vertical, .ds(.p10))
        .background(Color.BlackWhite.white)
        .overlay { cardBorder }
    }

    /// 카드 테두리 — g100 1.5(`outline-sb`), 모서리 0.
    private var cardBorder: some View {
        Rectangle().strokeBorder(Color.GrayScale.g100, lineWidth: .ds(.semiBold))
    }

    private func icon(_ image: Image) -> some View {
        image
            .resizable()
            .scaledToFit()
            .frame(width: Metric.iconSide, height: Metric.iconSide)
    }

    private enum Metric {
        /// 프로필 영역 아이콘 한 변 16 — Figma `edit/16px`·`coupon/16px`·`info/16px`·`logo/kakao`.
        static let iconSide: CGFloat = 16
    }
}
