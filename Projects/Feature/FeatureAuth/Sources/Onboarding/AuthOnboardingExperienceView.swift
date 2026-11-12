//
//  AuthOnboardingExperienceView.swift
//  FeatureAuthImplementation
//
//  Created by EunSeo on 26/07/31.
//

// Figma: «Onboarding_ExperienceSelection» https://figma.com/design/ZG7FUxWCvITmnvzZi7fpTS/?node-id=3632-14460

import ComposableArchitecture
import SharedDesignSystemInterface
import SwiftUI

/// 가입 온보딩 연차 선택 — 상단(내비바 · 진행 대시 · title-box)은 앞 화면 «Onboarding_JobSelection»
/// 과 동일하고 진행 단계 값만 다르다. 본문은 문장형 휠 «내 경력은 [연차] 이다».
@ViewAction(for: AuthOnboardingExperienceFeature.self)
public struct AuthOnboardingExperienceView: View {
    @Bindable public var store: StoreOf<AuthOnboardingExperienceFeature>

    public init(store: StoreOf<AuthOnboardingExperienceFeature>) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            progressBar
            titleBox
            // @ds(layout): 101 — title-box 하단(y231) ↔ 휠 상단(y332). 좁은 화면에선 줄어든다
            Spacer(minLength: 0)
                .frame(maxHeight: 101)
            experienceSentence
            Spacer(minLength: 0)
            bottomBar
        }
        .background(Color.BlackWhite.white.ignoresSafeArea())
        .hilitNavigationBar(
            background: .filled,
            onClose: { send(.userTappedClose) }
        )
    }

    // MARK: - 상단

    /// 진행 대시 — 시안 progress bar 3877:11601 은 화면 폭을 균등 분할. 여백 px20/py4 는 컴포넌트가 갖는다.
    private var progressBar: some View {
        DashIndicator(count: store.totalSteps, current: store.step)
            .padding(.top, .ds(.p8))
    }

    /// 뱃지 «필수» + 그린 마커 타이틀 + 서브 — 좌우 여백은 호출부(=여기) 몫이다.
    private var titleBox: some View {
        TitleBox(
            [.init("연차를 입력해 주세요", highlight: "연차")],
            tag: "필수",
            sub: "지금까지 근무한 모든 기간의 합\n(정규직·계약직·프리랜서 포함, 인턴)입니다."
        )
        .padding(.horizontal, .ds(.p20))
        .padding(.top, .ds(.p20))
    }

    // MARK: - 문장형 연차 휠

    /// «내 경력은 [휠] 이다» — 앞뒤 텍스트가 휠의 선택 행(중앙)과 같은 줄에 놓인다.
    // @ds(spacing): 29 — 문장 텍스트 ↔ 휠 좌우 간격 (시안 x 119→148 · 252→281. spacing 토큰은 4~24)
    private var experienceSentence: some View {
        HStack(spacing: 29) {
            Text("내 경력은")
                .dsTypography(.sub4)
                .foregroundStyle(Color.HilitBlack.b800)
            experienceWheel
            Text("이다")
                .dsTypography(.sub4)
                .foregroundStyle(Color.HilitBlack.b800)
        }
    }

    /// 연차 휠 — 세로 스크롤 + viewAligned 스냅으로 중앙 행이 선택값이 된다 (iOS 17 API).
    // @ds(component): wheel-picker 3632:14474 — 스냅 휠 + 상·하 페이드. 공용 컴포넌트 없음
    private var experienceWheel: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                ForEach(store.options) { option in
                    wheelRow(option)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: wheelSelection, anchor: .center)
        .contentMargins(.vertical, WheelMetric.verticalInset, for: .scrollContent)
        .scrollIndicators(.hidden)
        .frame(width: WheelMetric.width, height: WheelMetric.height)
        // 하이라이트 판정 기준계 — 내장 `.scrollView` 는 쓰지 않는다. 그쪽 원점은 `contentMargins` 상단
        // 인셋만큼 밀려 있어 중앙 기준이 인셋(=2행)만큼 어긋난다. 뷰포트에 직접 이름을 붙여 고정한다.
        .coordinateSpace(.named(WheelMetric.space))
        .overlay { wheelFade.allowsHitTesting(false) }
    }

    /// 휠 한 행 — 중앙 행만 그린 마커가 깔리고, 나머지는 회색 평문이다. 선택 상태(`selectedExperience`)가
    /// 아니라 **기하**로 판정한다 — 스냅 확정은 스크롤이 멈춰야 오므로, 그걸 기준 삼으면 드래그 내내
    /// 직전 선택만 강조된 채로 남는다. 두 표기를 겹쳐 두고 `visualEffect` 로 반대 불투명도를 줘
    /// 스크롤 중 상태 갱신 없이 하이라이트가 중앙 행을 따라간다.
    private func wheelRow(_ option: ExperienceOption) -> some View {
        ZStack {
            Text(option.label)
                .dsTypography(.sub4)
                .foregroundStyle(Color.GrayScale.g400)
                .visualEffect { content, proxy in
                    content.opacity(1 - WheelMetric.centeredness(proxy))
                }
            HighlightedText(option.label, typography: .sub4, alignment: .center)
                .visualEffect { content, proxy in
                    content.opacity(WheelMetric.centeredness(proxy))
                }
        }
        .frame(width: WheelMetric.width, height: WheelMetric.rowHeight)
    }

    /// 휠 스크롤 위치 ↔ 상태 연결 — 스냅 결과만 view 액션으로 올리고, 상태가 바뀌면 휠도 따라 스크롤된다.
    /// 바인딩 타입은 행 identity(`ForEach` 가 쓰는 `ExperienceOption.id` = `Int`)와 같아야 한다 —
    /// `ExperienceOption?` 로 두면 타입이 안 맞아 스냅해도 setter 가 불리지 않고 선택이 0 에 고정된다.
    private var wheelSelection: Binding<Int?> {
        Binding(
            get: { store.selectedExperience.id },
            set: { years in
                guard let years, years != store.selectedExperience.years else { return }
                send(.userSelectedExperience(ExperienceOption(years: years)))
            }
        )
    }

    /// 중앙 선택 행만 또렷하게 남기는 페이드 — 시안은 상·하 73pt 흰 그라데이션 두 장(3632:14500/14501).
    private var wheelFade: some View {
        LinearGradient(
            stops: [
                .init(color: Color.BlackWhite.white, location: 0),
                .init(color: Color.BlackWhite.white.opacity(0), location: WheelMetric.fadeRatio),
                .init(color: Color.BlackWhite.white.opacity(0), location: 1 - WheelMetric.fadeRatio),
                .init(color: Color.BlackWhite.white, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - 하단 바

    /// 하단 «이전으로 | 계속하기» 바 — 배경·구분선·등폭 배치·눌림은 `ButtonLarge(.bottom, tone: .dark)` 가 소유.
    /// 휠은 항상 선택값을 가지므로 «계속하기» 는 상시 활성이다.
    private var bottomBar: some View {
        ButtonLarge(.bottom, tone: .dark) {
            Button("이전으로") { send(.userTappedBack) }
        } trailing: {
            Button("계속하기") { send(.userTappedContinue) }
        }
    }
}

// MARK: - WheelMetric

/// Figma «wheel-picker» 3632:14474 치수 — 프레임 104×171, 5행이 들어가 행 높이 34, 상·하 페이드 73.
// @ds(layout): 104×171 · 행 34 · 페이드 73 — 휠 치수 (DS 에 휠 규격 없음)
private enum WheelMetric {
    static let width: CGFloat = 104
    static let height: CGFloat = 171
    static let rowHeight: CGFloat = 34
    static let fadeHeight: CGFloat = 73
    /// 첫/마지막 항목도 중앙 정렬이 가능하도록 하는 스크롤 상하 여백.
    static let verticalInset: CGFloat = (height - rowHeight) / 2
    /// 페이드가 투명해지는 지점 (프레임 높이 비율).
    static let fadeRatio: CGFloat = fadeHeight / height

    /// 휠 뷰포트 좌표계 이름 — 행 위치를 «스크롤 안 하는 창» 기준으로 재기 위한 것.
    static let space = "experience-wheel"

    /// 이 행이 뷰포트 중앙 밴드(±행높이/2)에 들어왔는지 — 1 이면 선택 행이다.
    /// 경계에서 딱 끊는다 — 사이 값을 주면 두 표기가 반투명하게 겹쳐 글자가 굵어 보인다.
    /// 밴드는 반열림 구간(-h/2, +h/2] 이다 — 양끝을 다 열면 정확히 경계에 선 순간 아무 행도 강조되지
    /// 않고, 다 닫으면 위아래 두 행이 동시에 강조된다.
    static func centeredness(_ proxy: GeometryProxy) -> Double {
        let delta = proxy.frame(in: .named(space)).midY - height / 2
        return (delta > -rowHeight / 2 && delta <= rowHeight / 2) ? 1 : 0
    }
}

// MARK: - Previews

#Preview("연차 선택 — 기본(신입)") {
    AuthOnboardingExperienceView(
        store: Store(initialState: AuthOnboardingExperienceFeature.State()) {
            AuthOnboardingExperienceFeature()
        }
    )
}

#Preview("연차 선택 — 3년 이상") {
    AuthOnboardingExperienceView(
        store: Store(
            initialState: AuthOnboardingExperienceFeature.State(
                selectedExperience: ExperienceOption(years: 3)
            )
        ) {
            AuthOnboardingExperienceFeature()
        }
    )
}
