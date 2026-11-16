//
//  OnboardingPreloadView.swift
//  FeatureOnboarding
//
//  Created by EunSeo on 26/07/19.
//

import ComposableArchitecture
import SharedDesignSystemInterface
import SwiftUI

// Figma «Onboarding_preload» https://figma.com/design/JL9YPbqBqmaC9Z0I3SzDZS/?node-id=443-9768
//         준비 완료 판 https://figma.com/design/JL9YPbqBqmaC9Z0I3SzDZS/?node-id=443-9881
// 풀스크린 다크(HilitBlack.b800) 프리로드 화면 — 프로그레스 대시·뒤로가기·닫기(X) 없음. 실패는 모달로 알린다.
// 화면 아래쪽은 오른쪽으로 기운 그린 사면이 덮고, 그 위 가운데에 타이틀·서브·분석 체크리스트가 얹힌다.
// 준비가 끝나면 그 사면이 위로 올라와 화면 전체를 덮고(443:9882 전면 그린), 글자는 먼저 사라진 뒤
// 다 덮인 다음에 완료 문구가 올라온다.
// @ViewAction 매크로가 send(_:) 를 제공한다 — View 는 store.send(.view(...)) 대신 send(.onAppear) 로만 방출.
@ViewAction(for: OnboardingPreloadFeature.self)
public struct OnboardingPreloadView: View {
    @Bindable public var store: StoreOf<OnboardingPreloadFeature>

    public init(store: StoreOf<OnboardingPreloadFeature>) {
        self.store = store
    }

    public var body: some View {
        // 사면을 콘텐츠와 **형제로 두지 않는다** — ZStack 은 가장 큰 자식에 맞춰 커지므로, 화면보다
        // 큰 사면을 형제로 넣으면 스택이 부풀어 사면이 아래로 밀리고(오른쪽 위에 검은 삼각형) 글자도
        // 함께 처졌다. 배경 레이어는 부모 크기에 영향을 주지 않아 둘 다 사라진다.
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(alignment: .bottom) { greenSlope }
            .background(Color.HilitBlack.b800)
            // 시안 좌표가 상태바·홈 인디케이터를 포함한 375×812 프레임 기준이라 풀블리드로 놓고 잰다 —
            // 그린 사면이 화면 바닥까지 닿아야 하고, 콘텐츠 중앙도 «프레임 중앙» 기준이다.
            .ignoresSafeArea()
            .hilitNavigationBar(
                surface: store.phase.isFullyGreen ? .light : .dark,
                background: .transparent,
                allowsSwipeBack: false,   // 제출 중 이탈 = 세션 생성 버림
                // 슬롯을 비운다(사용자 결정 2026-08-04) — 기다리는 것 말곤 할 게 없는 화면.
                // 실패도 X 가 아니라 모달 [확인] 이 출구다(HLT-36).
                leading: .hidden
            )
            // 슬롯을 비우는 것만으론 부족해 바 자체를 감춘다 — 빈 leading 슬롯에도 iOS 26 이 글래스
            // 캡슐을 그려 좌상단에 흐린 원이 남는다.
            .toolbar(.hidden, for: .navigationBar)
            // 실패 모달 — 분석 판(다크·사면)을 그대로 깔고 그 위에 띄운다. 재시도 버튼은 없다(PRD §3.1).
            .hilitModal(item: store.phase.failure) { failure in
                failureModal(failure)
            }
            .animation(.easeInOut(duration: 0.3), value: store.phase)
            .onAppear { send(.onAppear) }
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            switch store.phase {
            case .analyzing, .failed:
                // 실패해도 분석 판을 남긴다 — 모달이 그 위에 뜬다.
                analyzingContent
            case .filling:
                // 채우는 중엔 글자가 없다 — 분석 텍스트는 사라지고 완료 문구는 아직 이르다.
                EmptyView()
            case .completed:
                completedContent
            }
        }
        .padding(.horizontal, .ds(.p20))
        // @ds(layout): top calc(50% - 29.5) 분석 중(443:9773) · calc(50% - 26.5) 완료(443:9885) —
        // 두 판의 블록 높이가 달라 시안이 중앙 오프셋을 따로 준다.
        .offset(y: store.phase.isFullyGreen ? -26.5 : -29.5)
    }

    // MARK: - 분석 중 (443:9773)

    private var analyzingContent: some View {
        // @ds(spacing): 32 — 헤더 ↔ 체크리스트 (DSSpacing 에 32 없음)
        VStack(spacing: 32) {
            header(
                title: "최적의 면접 환경을\n준비하고 있어요",
                subtitle: "잠시만 기다려주세요"
            )
            checklist
        }
    }

    /// 순차 진행 체크리스트 — completedStages 앞은 체크, 그 자리는 스피너, 뒤는 대기 링.
    /// 블록 자체는 가운데 정렬이고 행 안만 왼쪽 정렬이다 (Figma 443:9778 — 335 폭에서 좌우 여백이 같다).
    private var checklist: some View {
        VStack(alignment: .leading, spacing: .ds(.p8)) {
            analysisRow("기본정보 분석 중", index: 0)
            analysisRow("채용 정보 분석 중", index: 1)
            analysisRow("나의 포폴 분석 중", index: 2)
        }
        .animation(.easeInOut(duration: 0.25), value: store.completedStages)
    }

    private func analysisRow(_ title: String, index: Int) -> some View {
        HStack(spacing: .ds(.p10)) {
            stageIndicator(index: index)
            // @ds(typography): m16 · 행간 140% · 자간 -2% → body3(130% · -2.5%) — 체크리스트 행 라벨.
            // 시안이 텍스트 스타일 변수를 안 물린 raw 값이라 현행 토큰으로 흡수한다 (사고 사례 18번).
            Text(title)
                .dsTypography(.body3)
                .foregroundStyle(Color.BlackWhite.white)
        }
    }

    /// 행 앞 인디케이터 — 완료는 그린 체크, 진행 중은 스피너, 대기는 트랙 링. 전부 색이 구워진 DS 에셋이다.
    /// 슬롯을 16 으로 고정하되 `resizable` 은 걸지 않는다 — `loading/*/16px` 에셋의 캔버스가 17 이라
    /// 리사이즈하면 획이 얇아진다(사고 사례 2번). 프레임은 자리만 잡고 글리프는 원래 크기로 그린다.
    private func stageIndicator(index: Int) -> some View {
        Group {
            if index < store.completedStages {
                Image.Success.green16
                    .transition(.scale.combined(with: .opacity))
            } else if index == store.completedStages {
                PreloadSpinner()
            } else {
                Image.Loading.waitBlack16
            }
        }
        .frame(width: 16, height: 16)
    }

    // MARK: - 그린 사면 (443:9769 → 올라와 덮으면 443:9882)

    // @ds(layout): 284.5 — 왼쪽 변 기준 사면 높이 (375×812 시안, 화면 바닥 기준)
    /// 분석 중 사면 높이 — 여기서 시작해 위로 올라온다.
    private static let baseSlopeHeight: CGFloat = 284.5

    /// 화면 아래를 덮는 그린 사면 — 시안은 6.31° 기운 980×318 사각형이지만, 375 폭에서 보이는 것은
    /// «왼쪽 변이 바닥에서 284.5pt 인 빗변 아래 전부» 다. 회전 사각형을 그대로 옮기지 않고 폭에 맞춰
    /// 다시 그리는 Shape 로 두어 기기 폭이 달라져도 기울기·바닥 여백이 유지된다.
    ///
    /// 준비가 끝나면 **판을 갈아끼우지 않고 높이만 키운다** — 완료 시안(443:9882)도 같은 두 색
    /// 그라데이션이라, 그라데이션이 판과 함께 늘어나면 색이 튀는 지점 없이 이어진다.
    private var greenSlope: some View {
        GeometryReader { proxy in
            PreloadSlope()
                .fill(Self.slopeGradient)
                .frame(height: slopeHeight(in: proxy.size))
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        // 루트의 0.3 교차보다 길게 — 글자가 먼저 사라지고 초록이 뒤따라 올라온다.
        // 리듀서가 같은 fillSeconds 를 세고 나서 완료 문구를 띄운다.
        .animation(.easeInOut(duration: OnboardingPreloadFeature.fillSeconds), value: store.phase)
    }

    /// 사면 높이 — 분석 중·실패는 시안 사면, 채우는 중·완료는 화면을 넉넉히 넘긴다.
    ///
    /// 1.5배로 넘기는 이유: 빗변이 상단 **밖으로** 완전히 빠져야 오른쪽 위 모서리까지 초록이다
    /// (딱 화면 높이면 왼쪽 위만 닿고 오른쪽 위엔 검은 삼각형이 남는다). 배경 레이어라 넘친 만큼이
    /// 레이아웃을 밀지 않으므로 넉넉히 줘도 부작용이 없다 — 완료 시안도 화면보다 큰 판(979×938)이다.
    private func slopeHeight(in size: CGSize) -> CGFloat {
        switch store.phase {
        case .analyzing, .failed:
            return Self.baseSlopeHeight
        case .filling, .completed:
            return size.height * 1.5
        }
    }

    /// 시안의 189.47° 그라데이션에 사각형 회전 6.31° 를 더해 화면 좌표로 되돌린 것.
    /// 정지점(23.2% · 70.4%)이 실제로 놓이는 지점을 시안 좌표에서 계산해 UnitPoint 로 옮겼다 —
    /// 그래서 색 배열은 정지점 없이 두 색만 둔다.
    private static let slopeGradient = LinearGradient(
        colors: [.preloadSlopeHead, .preloadSlopeTail],
        startPoint: UnitPoint(x: 0.728, y: 0.224),
        endPoint: UnitPoint(x: 0.566, y: 0.981)
    )

    // MARK: - 준비 완료 (443:9885)

    /// 전면 그린 위 완료 문구 — 바닥이 밝아 두 줄 다 b800 이다(시안은 서브까지 같은 색).
    /// 분석 중 헤더와 규격이 달라(간격 12·색 반전·한 줄 타이틀) `header(...)` 를 재사용하지 않는다.
    private var completedContent: some View {
        VStack(spacing: .ds(.p12)) {
            Text("면접 환경을 준비했어요!")
                .dsTypography(.head3)
            Text("이제부터 시작해볼까요?")
                .dsTypography(.sub8)
        }
        .foregroundStyle(Color.HilitBlack.b800)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    // MARK: - 실패 모달 (세션 생성·폴링 실패 — 시안 미출, DS Modal 로 근사)

    /// 단일 [확인] — 일반 실패는 집중 프로젝트로, 이용권 소진은 위저드 밖으로 나간다(리듀서가 가른다).
    private func failureModal(_ failure: OnboardingPreloadFeature.State.Failure) -> some View {
        Modal("면접 준비에 실패했어요", subText: failure.message) {
            ButtonLarge("확인", .modal) { send(.userTappedFailureConfirm) }
        }
    }

    // MARK: - 공통

    private func header(title: String, subtitle: String) -> some View {
        VStack(spacing: .ds(.p8)) {
            Text(title)
                .dsTypography(.head3)
                .foregroundStyle(Color.BlackWhite.white)
            Text(subtitle)
                .dsTypography(.sub8)
                .foregroundStyle(Color.GrayScale.g300)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 사면 Shape

// @ds(component): 화면 바닥을 덮는 사선 판 — 공용 컴포넌트 없음. `Parallelogram` 은 텍스트 마커용이라
// 기울기가 «높이와 무관한 고정 오프셋 4pt» 로 고정이고, 여기 필요한 «각도 고정» 빗변과 성질이 다르다.
/// 그린 사면 — 왼쪽 위 꼭짓점에서 오른쪽으로 `angle` 만큼 내려가는 빗변 아래를 채운다.
private struct PreloadSlope: Shape {
    /// Figma 443:9769 사각형의 회전각. 375 폭에서 좌우 변 높이차 41.5pt.
    static let angle = Angle.degrees(6.31)

    func path(in rect: CGRect) -> Path {
        let drop = rect.width * CGFloat(tan(Self.angle.radians))
        return Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + drop))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

// MARK: - PreloadSpinner

/// 진행 중 행의 스피너 — DS 에셋 `loading/ing/16px/black`(`Image.Loading.ingBlack16`)을 무한 회전시킨다.
/// 트랙(gray-700)·아크(green-500) 색이 에셋에 구워져 있어 틴트는 통하지 않는다 (사고 사례 1번).
/// `SaveIndicator.Spinner` 와 같은 패턴 — `@State` 를 별도 뷰에 묶어 두면 행이 체크로 바뀌며 사라졌다가
/// 되돌아와도 `onAppear` 가 애니메이션을 되살린다.
private struct PreloadSpinner: View {
    @State private var isSpinning = false

    var body: some View {
        Image.Loading.ingBlack16
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: isSpinning)
            .onAppear { isSpinning = true }
    }
}

// MARK: - 표시용 파생

private extension OnboardingPreloadFeature.State.Phase {
    /// 사면이 화면을 다 덮은 뒤인가 — 네비바 톤·완료 문구 위치가 이걸로 갈린다.
    /// 채우는 중(`filling`)은 아직 상단이 어두워 false 다.
    var isFullyGreen: Bool {
        switch self {
        case .completed:
            return true
        case .analyzing, .filling, .failed:
            return false
        }
    }

    /// 실패 모달 표출 값 — 실패 판에서만 값이 있다(`.hilitModal(item:)` 입력).
    var failure: OnboardingPreloadFeature.State.Failure? {
        guard case let .failed(failure) = self else { return nil }
        return failure
    }
}

private extension Color {
    // @ds(color): #89E377 — 그린 사면 시작색. Figma 변수 미바인딩 raw 값이라 토큰화 보류 (color.md 규칙).
    static let preloadSlopeHead = Color(red: 137 / 255, green: 227 / 255, blue: 119 / 255)
    // @ds(color): #60D549 — 그린 사면 끝색. 같은 이유로 보류.
    static let preloadSlopeTail = Color(red: 96 / 255, green: 213 / 255, blue: 73 / 255)
}

// MARK: - Previews

private let previewData = OnboardingData(
    userName: "재원",
    portfolioId: UUID(uuidString: "00000000-0000-0000-0000-0000000000f1")!
)

#Preview("분석 중") {
    var state = OnboardingPreloadFeature.State(data: previewData)
    state.hasStartedAnalysis = true   // onAppear 의 실제 세션 호출을 막고 분석 화면만 본다.
    return OnboardingPreloadView(
        store: Store(initialState: state) {
            OnboardingPreloadFeature()
        }
    )
}

#Preview("분석 중 — 2행 진행") {
    var state = OnboardingPreloadFeature.State(data: previewData)
    state.hasStartedAnalysis = true
    state.completedStages = 1   // 1행 체크 · 2행 스피너 · 3행 대기 링
    return OnboardingPreloadView(
        store: Store(initialState: state) {
            OnboardingPreloadFeature()
        }
    )
}

#Preview("채우는 중") {
    var state = OnboardingPreloadFeature.State(data: previewData)
    state.phase = .filling
    state.hasStartedAnalysis = true
    state.completedStages = 3
    return OnboardingPreloadView(
        store: Store(initialState: state) {
            OnboardingPreloadFeature()
        }
    )
}

#Preview("준비 완료") {
    var state = OnboardingPreloadFeature.State(data: previewData)
    state.phase = .completed
    state.hasStartedAnalysis = true
    return OnboardingPreloadView(
        store: Store(initialState: state) {
            OnboardingPreloadFeature()
        }
    )
}

#Preview("분석 실패") {
    var state = OnboardingPreloadFeature.State(data: previewData)
    state.phase = .failed(.retry(message: OnboardingPreloadFeature.failureMessage))
    state.hasStartedAnalysis = true
    return OnboardingPreloadView(
        store: Store(initialState: state) {
            OnboardingPreloadFeature()
        }
    )
}
