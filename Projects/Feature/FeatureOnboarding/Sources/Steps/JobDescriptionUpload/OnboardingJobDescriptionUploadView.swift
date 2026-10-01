//
//  OnboardingJobDescriptionUploadView.swift
//  FeatureOnboarding
//
//  Created by EunSeo on 26/07/19.
//

import ComposableArchitecture
import SharedDesignSystemInterface
import SwiftUI

// Figma «Onboarding_JobDescriptionUpload» (443:9384 — «링크 붙여넣기» 탭)
//        https://figma.com/design/JL9YPbqBqmaC9Z0I3SzDZS/?node-id=443-9384
//       «Onboarding_JobDescriptionText»   (443:9424 — «직접 입력하기» 탭)
//        https://figma.com/design/JL9YPbqBqmaC9Z0I3SzDZS/?node-id=443-9424
//
// 두 노드는 같은 화면의 탭 하위 상태다 — 화면 push 없이 State(`mode`)로만 갈라진다.
// 링크 검증의 에러·성공은 두 노드에 다시 그려져 있지 않다(둘 다 기본 상태만) —
// DS «text-field» 컴포넌트(`HilitTextField.Status`)의 변형을 그대로 쓴다.
// 검증 «분석 중» 만 예외로 화면에 안 그린다 — 전역 LoadingModal 이 덮는다(`linkFieldStatus`).
@ViewAction(for: OnboardingJobDescriptionUploadFeature.self)
public struct OnboardingJobDescriptionUploadView: View {
    private typealias InputMode = OnboardingJobDescriptionUploadFeature.InputMode

    @Bindable public var store: StoreOf<OnboardingJobDescriptionUploadFeature>

    public init(store: StoreOf<OnboardingJobDescriptionUploadFeature>) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            DashIndicator(count: store.totalSteps, current: store.step)
                .padding(.top, .ds(.p8))
            ScrollView {
                VStack(alignment: .leading, spacing: .ds(.p24)) {
                    header
                    inputSection
                        // 시안의 입력 섹션(443:9394)이 자체 p20 을 갖는다 — 바깥 gap 24 와 합쳐 44 가 된다.
                        .padding(.vertical, .ds(.p20))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, .ds(.p20))
                .padding(.top, .ds(.p20))
            }
            if store.showsSkipTooltip {
                skipTooltip
            }
            bottomBar
        }
        .background(Color.BlackWhite.white.ignoresSafeArea())
        .dismissesKeyboardOnTap()
        .hilitNavigationBar(
            trailing: .text(Copy.skip) { send(.userTappedSkip) },
            background: .filled,
            onClose: { send(.userTappedClose) }
        )
        .onAppear { send(.onAppear) }
    }

    // MARK: - 헤더 (뱃지 + 타이틀 + 서브)

    /// Figma «title-box» 인스턴스(443:9393). 선택 스텝이라 뱃지는 회색 변형(`.grayGray`) —
    /// `tagStyle` 기본값은 «필수» 검정 판이다.
    private var header: some View {
        TitleBox(
            [
                .init(Copy.titleFirstLine, highlight: Copy.titleHighlight),
                .init(Copy.titleSecondLine)
            ],
            tag: Copy.optionalTag,
            tagStyle: .grayGray,
            sub: Copy.subTitle
        )
    }

    // MARK: - 입력 영역 (탭 + 필드)

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: Metric.tabToFieldGap) {
            modeTabs
            switch store.mode {
            case .link:
                linkField
            case .directText:
                directTextField
            }
        }
    }

    /// Figma «tab» 줄(443:9395) — 두 탭이 화면 폭을 등분한다.
    /// 선택은 바인딩이 아니라 액션으로 보낸다 — «검증 성공 뒤 직접 입력 잠금» 규칙이 리듀서에 있다.
    private var modeTabs: some View {
        TabSelector<InputMode>(
            [
                .init(tag: .link, title: Copy.linkTab),
                .init(tag: .directText, title: Copy.directTextTab, isEnabled: !store.isDirectTextDisabled)
            ],
            selection: modeBinding,
            layout: .fill
        )
    }

    private var modeBinding: Binding<InputMode> {
        Binding(
            get: { store.mode },
            set: { send(.userSelectedMode($0)) }
        )
    }

    // MARK: - 링크 필드 (idle · error · success)

    /// Figma «text-field» 인스턴스(443:9398). 시안엔 기본 상태만 있고
    /// 에러·성공은 컴포넌트 변형이라 `Status` 로 넘긴다(서브 줄도 컴포넌트가 그린다).
    /// 키보드 속성은 환경으로 내부 `TextField` 까지 전파된다.
    private var linkField: some View {
        HilitTextField(
            Copy.linkPlaceholder,
            text: $store.linkText,
            status: linkFieldStatus,
            subText: linkSubText
        )
        .keyboardType(.URL)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .submitLabel(.done)
        .onSubmit { send(.userSubmittedLink) }
    }

    /// 검증 중(`.loading`)에도 필드는 평상시(`idle`) 그대로다 — 인라인 로딩 변형은 안 쓴다.
    /// 대기 표시는 AppView 의 전역 LoadingModal 몫이라(NetworkActivity 가 `validate` in-flight 를 센다)
    /// 여기에 스피너를 되살리면 모달 위에 겹쳐 «이중 로딩» 이 된다.
    private var linkFieldStatus: HilitTextField.Status {
        switch store.linkValidation {
        case .idle, .loading: .idle
        case .failure: .error
        case .success: .success
        }
    }

    /// 필드 아래 서브 줄 — 스타일(회색·빨강·초록)은 `status` 가 정한다.
    /// 검증 중에도 안내 문구를 그대로 둔다 — 필드가 idle 로 보이는데 줄만 빠지면 레이아웃이 덜컥거린다.
    private var linkSubText: String? {
        switch store.linkValidation {
        case .idle, .loading: Copy.idleHelper
        case let .failure(message): message
        case .success: Copy.successHelper
        }
    }

    // MARK: - 직접 입력 필드 (멀티라인 + 카운터)

    /// Figma «text-field» large 인스턴스(443:9434 안, 마스터 435:1597) — 높이 158 · 카운터 «0/3000» 은 컴포넌트가 그린다.
    /// 무효(200자 미만) 안내는 새 시안 두 노드에 그려져 있지 않지만 PRD S1 게이팅이 살아 있어
    /// 링크 탭과 같은 DS 조각(`FieldSubText`)으로 남겼다.
    private var directTextField: some View {
        VStack(alignment: .leading, spacing: .ds(.p8)) {
            HilitTextEditor(
                Copy.directTextPlaceholder,
                text: $store.directText,
                maxLength: OnboardingJobDescriptionUploadFeature.State.maxDirectTextLength
            )
            if let message = store.directTextValidationMessage {
                FieldSubText(message, status: .error)
            }
        }
    }

    // MARK: - 스킵 안내 툴팁

    /// CTA 위 말풍선 «bubble-field»(443:9400) — 꼬리 우하단, CTA 와 16 띄운다.
    /// 시안 주석대로 진입 3초 뒤 사라진다(노출 여부는 State 가 갖는다).
    private var skipTooltip: some View {
        BubbleField(Copy.skipTooltip, .wide(tail: .bottom))
            .padding(.bottom, .ds(.p16))
    }

    // MARK: - 하단 CTA (이전으로 | 계속하기)

    /// 분할 CTA 바 «button-large/bottom»(마스터 435:670) — 네비바 X 와 별개로 여기에 뒤로가기가 있다.
    /// 한쪽만 비활성은 그 자식의 `.disabled` 로 표현한다 (DS 2버튼 규약).
    private var bottomBar: some View {
        ButtonLarge(.bottom, tone: .dark) {
            Button(Copy.back) { send(.userTappedBack) }
        } trailing: {
            Button(Copy.continueTitle) { send(.userTappedContinue) }
                .disabled(!store.isContinueEnabled)
        }
    }

    private enum Metric {
        // @ds(spacing): 34 — 탭 줄 ↔ 입력 필드 사이 (spacing 스케일에 34 가 없다)
        static let tabToFieldGap: CGFloat = 34
    }
}

// MARK: - 카피

/// 화면 문구 — Figma 컴포넌트 기본 문구가 남아 있는 곳은 TODO 로 표시 (확정 카피 대기).
private enum Copy {
    static let optionalTag = "선택"
    /// «채용공고 링크» 부분에 그린 마커가 깔린다 (highlighted-text).
    static let titleFirstLine = "채용공고 링크를"
    static let titleHighlight = "채용공고 링크"
    static let titleSecondLine = "업로드해 주세요."
    static let subTitle = "채용 페이지에 직접 올라온 공고 링크를 넣어주세요."
    static let linkTab = "링크 붙여넣기"
    static let directTextTab = "직접 입력하기"
    /// Figma 리터럴 그대로 (443:9398 text-field placeholder).
    static let linkPlaceholder = "https://www.hilit.com/"
    /// Figma 리터럴 그대로 (435:1600).
    static let directTextPlaceholder = "텍스트를 입력해주세요"
    /// Figma 는 필러 문구(«서브 텍스트를 입력해주세요») — 임시 초안.
    static let idleHelper = "채용 사이트의 공고 링크를 넣고 계속하기를 누르면 분석해요." // TODO: 확정 카피 반영
    /// Figma 는 필러 문구 — 임시 초안.
    static let successHelper = "채용공고를 확인했어요." // TODO: 확정 카피 반영
    static let skipTooltip = "링크 입력을 원하지 않으면 넘어가도 괜찮아요."
    static let skip = "건너뛰기"
    static let back = "이전으로"
    static let continueTitle = "계속하기"
}

// MARK: - Previews

/// 이 화면은 위저드 스택의 **루트**라 네비바(X · 건너뛰기)가 `NavigationStack` 안에서만 그려진다 —
/// 스택 없이 띄우면 바가 조용히 사라진다(사고 사례 11번).
private func previewScreen(_ state: OnboardingJobDescriptionUploadFeature.State) -> some View {
    NavigationStack {
        OnboardingJobDescriptionUploadView(
            store: Store(initialState: state) {
                OnboardingJobDescriptionUploadFeature()
            }
        )
    }
}

#Preview("링크 입력 — 기본(툴팁)") {
    previewScreen(.init())
}

#Preview("링크 입력 — 툴팁 소멸 후") {
    var state = OnboardingJobDescriptionUploadFeature.State()
    state.isTooltipExpired = true
    return previewScreen(state)
}

// «링크 분석 중» 프리뷰는 없다 — `.loading` 은 이제 idle 과 똑같이 그려져 볼 게 없다
// (대기 표시는 AppView 의 전역 LoadingModal 이고, 그건 이 화면 프리뷰에 안 실린다).

#Preview("링크 에러") {
    var state = OnboardingJobDescriptionUploadFeature.State()
    state.linkText = "https://recruit.hilit.dev/jobs/123"
    state.linkValidation = .failure(message: "링크를 분석하지 못했어요. 링크를 확인해 주세요.")
    return previewScreen(state)
}

#Preview("링크 성공 — 직접 입력 탭 잠김") {
    var state = OnboardingJobDescriptionUploadFeature.State()
    state.linkText = "https://recruit.hilit.dev/jobs/123"
    state.linkValidation = .success
    return previewScreen(state)
}

#Preview("직접 입력 — 빈 값(스킵)") {
    var state = OnboardingJobDescriptionUploadFeature.State()
    state.mode = .directText
    return previewScreen(state)
}

#Preview("직접 입력 — 200자 미만") {
    var state = OnboardingJobDescriptionUploadFeature.State()
    state.mode = .directText
    state.directText = String(repeating: "가", count: 40)
    return previewScreen(state)
}
