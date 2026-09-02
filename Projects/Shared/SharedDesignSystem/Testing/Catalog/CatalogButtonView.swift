//
//  CatalogButtonView.swift
//  SharedDesignSystemTesting
//
//  Created by EunseoKim on 26/07/29.
//

import SharedDesignSystemInterface
import SwiftUI

/// 버튼 체계 — `ButtonLarge`(View) + ButtonStyle 4종(medium·mini·miniSub·tag).
/// 상태(pressed·disabled)는 넘기는 축이 아니라 SwiftUI 가 주는 것이라, disabled 는 `.disabled(true)` 로만 보여준다.
/// `mini`·`tag` 는 판(light/dark)에 따라 팔레트가 바뀌어 어두운 판 묶음을 따로 둔다.
struct CatalogButtonView: View {
    /// 페이지가 주는 좌우 여백 — 풀블리드(반반) 버튼은 이만큼 되돌려 화면 폭 그대로 눕힌다.
    private static let pageInset: CGFloat = .ds(.p20)

    var body: some View {
        CatalogPage("버튼") {
            largeSingle
            largePair
            largeLogin
            medium
            mini
            miniSub
            darkSurface
        }
    }

    private var largeSingle: some View {
        CatalogGroup("ButtonLarge 단일 — .bottom / .modal · tone .dark / .light") {
            VStack(spacing: .ds(.p8)) {
                ButtonLarge("피드백 시작하기", .bottom) {}
                ButtonLarge("다시 연습하기", .bottom, tone: .light) {}
                ButtonLarge("확인", .modal) {}
                ButtonLarge("비활성", .bottom) {}.disabled(true)
                ButtonLarge("전송 중", .bottom) {}.hilitButtonLoading(true)
            }
        }
    }

    private var largePair: some View {
        CatalogGroup("ButtonLarge 2버튼 — tone .dark / .gray / .twoColor(풀블리드 — 페이지 여백을 되돌린다)") {
            VStack(spacing: .ds(.p8)) {
                ButtonLarge(.bottom, tone: .dark) {
                    Button("아니오") {}
                } trailing: {
                    Button("네") {}
                }
                ButtonLarge(.bottom, tone: .gray) {
                    Button("취소") {}
                } trailing: {
                    Button("확인") {}
                }
                // 반반은 컨테이너 여백이 0 이라 좌우 끝까지 붙어야 반쪽 경계가 화면 중앙에 온다.
                ButtonLarge(.bottom, tone: .twoColor) {
                    Button("나중에") {}
                } trailing: {
                    Button("계속하기") {}
                }
                .padding(.horizontal, -Self.pageInset)
                ButtonLarge(.modal, tone: .twoColor) {
                    Button("취소") {}
                } trailing: {
                    Button("삭제") {}
                }
                .padding(.horizontal, -Self.pageInset)
                ButtonLarge(.modal, tone: .dark) {
                    Button("닫기") {}
                } trailing: {
                    Button("저장") {}.disabled(true)   // 한쪽만 비활성 = 그 자식에 .disabled
                }
            }
        }
    }

    private var largeLogin: some View {
        CatalogGroup("ButtonLarge 로그인 — login: .kakao / .apple · showsLogo") {
            VStack(spacing: .ds(.p8)) {
                ButtonLarge("카카오로 시작하기", login: .kakao) {}
                ButtonLarge("Apple로 시작하기", login: .apple) {}
                ButtonLarge("로고 없이", login: .kakao, showsLogo: false) {}
                ButtonLarge("비활성", login: .kakao) {}.disabled(true)
                ButtonLarge("로그인 중", login: .apple) {}.hilitButtonLoading(true)
            }
        }
    }

    private var medium: some View {
        CatalogGroup(".medium(_:layout:) — 색 6종 · .hug / .fill") {
            VStack(alignment: .leading, spacing: .ds(.p8)) {
                ForEach(MediumButtonStyle.Tone.allCases, id: \.self) { tone in
                    Button(String(describing: tone)) {}
                        .buttonStyle(.medium(tone))
                }
                Button("비활성") {}.buttonStyle(.medium()).disabled(true)
                HStack(spacing: .ds(.p8)) {
                    Button("아쉬웠어요") {}.buttonStyle(.medium(.red, layout: .fill))
                    Button("좋았어요") {}.buttonStyle(.medium(.blue, layout: .fill))
                }
            }
        }
    }

    private var mini: some View {
        CatalogGroup(".mini(_:style:layout:) — 밝은 판") {
            VStack(alignment: .leading, spacing: .ds(.p8)) {
                ForEach(MiniButtonStyle.Tone.allCases, id: \.self) { tone in
                    Button(String(describing: tone)) {}
                        .buttonStyle(.mini(tone))
                }
                // status 축 — outlined 는 시안상 black 행 전용.
                Button("outlined") {}.buttonStyle(.mini(.black, style: .outlined))
                Button {
                } label: {
                    HStack(spacing: .ds(.p8)) {
                        Image.Video.default16
                        Text("영상 다시보기")
                    }
                }
                .buttonStyle(.mini(.gray, layout: .withIcon))
                Button("비활성") {}.buttonStyle(.mini()).disabled(true)
            }
        }
    }

    private var miniSub: some View {
        CatalogGroup(".miniSub(_:) — white / black / none") {
            HStack(spacing: .ds(.p8)) {
                ForEach(MiniSubButtonStyle.Tone.allCases, id: \.self) { tone in
                    Button(String(describing: tone)) {}
                        .buttonStyle(.miniSub(tone))
                }
            }
        }
    }

    /// `.hilitSurface(.dark)` 는 화면이 한 번 선언하면 하위 mini·tag 팔레트와
    /// `ButtonLarge` 단일 비활성 배색이 따라 바뀐다.
    private var darkSurface: some View {
        CatalogGroup(".hilitSurface(.dark) — ButtonLarge 비활성 · mini · tag(다크 판 전용)") {
            VStack(alignment: .leading, spacing: .ds(.p12)) {
                ForEach(MiniButtonStyle.Tone.allCases, id: \.self) { tone in
                    Button(String(describing: tone)) {}
                        .buttonStyle(.mini(tone))
                }
                Button("비활성") {}.buttonStyle(.mini()).disabled(true)
                HStack(spacing: .ds(.p8)) {
                    ForEach(TagButtonStyle.Phase.allCases, id: \.self) { phase in
                        Button("지인피드백") {}.buttonStyle(.tag(phase))
                    }
                }
                // 활성과 나란히 — 어두운 판에서는 배경이 그대로고 라벨만 g400 으로 죽는다.
                ButtonLarge("면접 시작하기", .bottom) {}
                ButtonLarge("면접 시작하기", .bottom) {}.disabled(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.ds(.p16))
            .background(Color.HilitBlack.b900)
            .hilitSurface(.dark)
        }
    }
}

#Preview {
    NavigationStack { CatalogButtonView() }
}
