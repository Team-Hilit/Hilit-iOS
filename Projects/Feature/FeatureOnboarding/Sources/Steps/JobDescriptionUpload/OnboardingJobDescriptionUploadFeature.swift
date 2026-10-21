//
//  OnboardingJobDescriptionUploadFeature.swift
//  FeatureOnboarding
//
//  Created by EunSeo on 26/07/19.
//

import ComposableArchitecture
import DomainJDInterface
import Foundation

// @lat: [[onboarding#JD 업로드]]
/// 온보딩 STEP 1 — 채용공고(JD) 링크 입력 (선택 스텝, 위저드 스택의 루트).
/// 링크 붙여넣기 / 본문 직접 입력은 같은 화면의 탭(모드) 전환이고,
/// 링크 검증은 «계속하기»(또는 키보드 리턴)를 누를 때만 호출한다 — 성공이면 바로 다음 스텝,
/// 실패면 `LinkValidation.failure` 로 필드 아래 에러를 띄우고 머문다.
/// 수집 결과는 delegate(.continueRequested(JDSubmission?))로 코디네이터에 올린다 — nil 은 스킵.
@Reducer
public struct OnboardingJobDescriptionUploadFeature {
    /// JD 입력 방식 — Figma «링크 붙여넣기»(443:9384) ↔ «직접 입력하기»(443:9424) 탭.
    public enum InputMode: Equatable, Sendable {
        /// 채용공고 링크 붙여넣기 (기본 탭 «링크 붙여넣기»)
        case link
        /// JD 본문 직접 입력 (크롤링 실패 폴백 탭 «직접 입력하기»)
        case directText
    }

    /// 링크 검증(서버 크롤링+정제) 하위 상태 — 실패·성공은 DS «text-field»(`HilitTextField.Status`)의
    /// error/success 변형으로 렌더된다. 새 시안 두 노드엔 기본 상태만 그려져 있어
    /// 상태 변형의 생김새는 컴포넌트가 소유한다.
    public enum LinkValidation: Equatable, Sendable {
        case idle
        /// 분석 중 — **화면엔 안 그린다**(필드는 idle 그대로). 대기 표시는 `validate` in-flight 를
        /// 세는 전역 LoadingModal 몫이라 인라인 스피너를 달면 이중 로딩이 된다.
        /// 이 값은 «계속하기» 중복 탭을 막는 게이트로만 산다.
        case loading
        /// 실패 — 빨간 바 + 서버 message(또는 기본 문구) 서브 줄.
        case failure(message: String)
        /// 성공 — 초록 바. 서버가 JD 를 캐싱한 상태. 성공 즉시 다음 스텝으로 넘어가므로
        /// 이 화면으로 되돌아왔을 때(뒤로가기·draft 복원) 보인다.
        case success
    }

    // 수집 결과 타입 JDSubmission 은 공유 페이로드(OnboardingData.swift) 소속 —
    // 코디네이터가 해체 없이 그대로 저장한다.

    @ObservableState
    public struct State: Equatable, Sendable {
        /// 직접입력 JD 최소 글자 수 — 서버 검증과 동일. 미만이면 질문 재료가 부족하다 (PRD S1 무효-짧음).
        public static let minDirectTextLength = 200
        /// 직접입력 JD 최대 글자 수 — 카운터 분모(시안 «0/3000»). `HilitTextEditor(maxLength:)` 가
        /// 이 값에서 잘라내므로 타이핑으로는 초과가 나지 않는다 — 초과 판정은 복원된 draft 용 방어선이다.
        public static let maxDirectTextLength = 3_000

        /// 프로그레스 바 분모 — 온보딩 전체 단계 수.
        public let totalSteps: Int
        /// 프로그레스 바 분자 — 이 화면의 단계(1-based).
        public let step: Int
        public var mode: InputMode = .link
        /// «링크 붙여넣기» 탭의 링크 입력값.
        public var linkText: String = ""
        /// «직접 입력하기» 탭의 JD 본문 입력값.
        public var directText: String = ""
        public var linkValidation: LinkValidation = .idle
        /// 스킵 툴팁 자동 소멸 여부 — onAppear 후 tooltipDuration(3초)이 지나면 true, 이후 유지.
        public var isTooltipExpired: Bool = false

        /// 검증 성공 후에는 «직접 입력하기» 탭을 잠근다 — `TabSelector.Item(isEnabled:)` 로 내려간다.
        /// (분석 중 인라인 필드 잠금은 없다 — 화면은 전역 LoadingModal 이 덮고, 그 사이 입력이
        /// 들어와도 `onChange(of: \.linkText)` 가 in-flight 검증을 취소한다.)
        public var isDirectTextDisabled: Bool { linkValidation == .success }

        /// 직접입력 글자 수 — 카운터 분자(카운터 자체는 `HilitTextEditor` 가 그린다).
        public var directTextCount: Int { directText.count }
        /// 상한 초과 — 복원된 draft 로만 도달한다(입력은 컴포넌트가 잘라낸다).
        public var isDirectTextOverLimit: Bool { directTextCount > Self.maxDirectTextLength }
        /// 직접입력이 서버 전송 가능한 유효 길이(200~3,000자)인가.
        public var isDirectTextValid: Bool {
            (Self.minDirectTextLength...Self.maxDirectTextLength).contains(directTextCount)
        }
        /// 직접입력 검증 안내 — 빈 입력(공백만 포함)·유효 길이면 nil (PRD S1 확정 문구).
        public var directTextValidationMessage: String? {
            guard !directText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            if directTextCount < Self.minDirectTextLength {
                return "공고 내용이 너무 짧아요. 200자 이상으로 넣어주세요."
            }
            if directTextCount > Self.maxDirectTextLength {
                return "공고 내용은 3000자 미만으로 입력해주세요."
            }
            return nil
        }
        /// 링크 입력이 (공백만 포함해) 비어 있는가 — 빈 링크는 스킵 경로다.
        public var isLinkEmpty: Bool {
            linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        /// 링크가 클라이언트 1차 형식 검사(http(s) + 호스트)를 통과하는가.
        public var isLinkFormatValid: Bool {
            OnboardingJobDescriptionUploadFeature.isValidLinkFormat(
                linkText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        /// «계속하기» 활성 조건 — 두 탭 모두 «빈 입력(스킵) 또는 유효한 입력» 일 때만 열린다.
        /// 링크 탭은 형식 검사를 통과하면 열린다 — 서버 검증은 이 버튼이 부른다(실패 후 재탭 = 재시도).
        /// 분석 중엔 잠가 중복 호출을 막는다. 빈 입력은 스킵 경로라 열어 둔다(툴팁 안내와 일치).
        /// 직접입력 탭은 빈 입력(스킵)이거나 유효 길이(200~3,000자)일 때 (PRD S1 무효 입력 시 다음 꺼짐).
        public var isContinueEnabled: Bool {
            switch mode {
            case .link:
                return isLinkEmpty || (isLinkFormatValid && linkValidation != .loading)
            case .directText:
                return directText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isDirectTextValid
            }
        }
        /// 스킵 안내 툴팁 «bubble-field»(443:9400) — 현재 탭의 입력이 비어 있는 동안만,
        /// 진입 후 3초까지 노출(시안 주석 «3초 후 사라짐»).
        /// 직접 입력 노드(443:9424)엔 말풍선이 안 그려져 있지만 3초 뒤 프레임으로 보고 두 탭 공통으로 둔다.
        public var showsSkipTooltip: Bool {
            guard !isTooltipExpired else { return false }
            switch mode {
            case .link: return linkValidation == .idle && linkText.isEmpty
            case .directText: return directText.isEmpty
            }
        }

        public init(step: Int = 1, totalSteps: Int = 3) {
            self.step = step
            self.totalSteps = totalSteps
        }

        /// draft 복원용 — 저장된 JD(.link/.text)를 탭·입력값·검증상태로 되살린다.
        public init(step: Int = 1, totalSteps: Int = 3, restoring jd: JDSubmission?) {
            self.step = step
            self.totalSteps = totalSteps
            switch jd {
            case let .link(url):
                self.mode = .link
                self.linkText = url
                self.linkValidation = .success   // 세션에 실린 링크는 검증 통과분이다.
            case let .text(text):
                self.mode = .directText
                self.directText = text
            case nil:
                break
            }
        }
    }

    public enum Action: ViewAction {
        case view(View)
        case inner(Inner)
        case delegate(Delegate)

        /// 사용자 입력·생명주기. View 의 send(...) 로만 방출된다.
        @CasePathable
        public enum View: BindableAction, Equatable, Sendable {
            case binding(BindingAction<State>)
            case onAppear
            case userSelectedMode(InputMode)
            /// 키보드 리턴 — «계속하기» 와 같은 경로. 형식이 틀리면 형식 에러를 띄운다.
            case userSubmittedLink
            /// 링크 지우기 — 화면의 클리어 버튼은 `HilitTextField` 안에 있어 바인딩으로 도착하지만,
            /// «지우면 검증 결과도 버린다» 규칙은 리듀서 쪽 진입점으로 남겨 둔다.
            case userTappedClearLink
            case userTappedBack
            case userTappedClose
            case userTappedContinue
            /// 네비바 오른쪽 «건너뛰기» — 선택 스텝이라 입력 없이 다음으로 넘어간다.
            case userTappedSkip
        }

        /// effect 결과·리듀서 내부 신호. 리듀서만 방출한다.
        @CasePathable
        public enum Inner: Equatable, Sendable {
            case linkValidated(JDValidation)
            case linkValidationFailed
            /// 스킵 툴팁 노출 시간(3초) 경과 — 툴팁을 감춘다.
            case tooltipExpired
        }

        /// 코디네이터(OnboardingFeature) 통보. 부모는 이것만 매칭한다 (D1).
        @CasePathable
        public enum Delegate: Equatable, Sendable {
            /// 스텝 완료 — 수집한 JD. 선택 스텝이므로 nil(스킵) 가능 — 네비바 «건너뛰기» 도 이 경로다.
            case continueRequested(JDSubmission?)
            /// 뒤로(하단 «이전으로») — 이 화면이 위저드 루트라 코디네이터는 온보딩 이탈로 해석한다.
            case backRequested
            /// 온보딩 이탈(X) 요청 — dismiss 는 코디네이터 몫.
            case closeRequested
        }
    }

    /// 네트워크 오류 등 서버 message 가 없을 때의 기본 에러 문구.
    static let fallbackErrorMessage = "링크를 분석하지 못했어요. 링크를 확인해 주세요." // TODO: 확정 카피 반영
    /// 클라이언트 1차 형식 검사 실패 문구 — 서버 왕복 전에 걸러진 경우.
    static let invalidFormatMessage = "올바른 링크 형식이 아니에요. 링크를 확인해 주세요." // TODO: 확정 카피 반영
    /// 스킵 툴팁 자동 소멸까지의 시간 — 진입 후 이만큼 지나면 툴팁을 감춘다.
    static let tooltipDuration: Duration = .seconds(3)

    private enum CancelID { case validate, tooltip }

    @Dependency(\.jdClient) var jdClient
    @Dependency(\.continuousClock) var clock

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer(action: \.view)
            // 링크가 **실제로 바뀐 때만** 이전 검증 결과(에러·성공)를 버리고 진행 중 검증도 취소한다.
            // `.binding(\.linkText)` 로 받으면 안 된다 — TextField 는 포커스가 풀릴 때 같은 값으로도
            // 바인딩을 다시 쓰는데, 그걸 입력으로 보고 에러를 지우면 포커스 해제만으로 에러가 사라진다.
            .onChange(of: \.linkText) { _, _ in
                Reduce { state, _ in
                    state.linkValidation = .idle
                    return .cancel(id: CancelID.validate)
                }
            }

        Reduce { state, action in
            switch action {
            case let .view(action):
                return reduceView(&state, action)
            case let .inner(action):
                return reduceInner(&state, action)
            case .delegate:
                return .none
            }
        }
    }

    private func reduceView(_ state: inout State, _ action: Action.View) -> Effect<Action> {
        switch action {
        case .onAppear:
            // 진입 후 3초 뒤 스킵 툴팁 소멸 — 이미 소멸했으면(뒤로가기 재진입 등) 재예약하지 않는다.
            guard !state.isTooltipExpired else { return .none }
            return .run { send in
                try await clock.sleep(for: Self.tooltipDuration)
                await send(.inner(.tooltipExpired))
            }
            .cancellable(id: CancelID.tooltip, cancelInFlight: true)

        case .binding:
            return .none

        case let .userSelectedMode(mode):
            guard !(mode == .directText && state.isDirectTextDisabled) else { return .none }
            state.mode = mode
            return .none

        case .userSubmittedLink:
            // 빈 링크의 리턴은 스킵으로 넘기지 않는다 — 스킵은 버튼으로만.
            guard !trimmedLink(state).isEmpty else { return .none }
            return submitLink(&state)

        case .userTappedClearLink:
            // 바인딩을 거치지 않는 경로라 `onChange(of: \.linkText)`(BindingReducer 에만 걸림)가 안 돈다 — 직접 초기화한다.
            state.linkText = ""
            state.linkValidation = .idle
            return .cancel(id: CancelID.validate)

        case .userTappedBack:
            return .send(.delegate(.backRequested))

        case .userTappedClose:
            return .send(.delegate(.closeRequested))

        case .userTappedContinue:
            return submit(&state)

        case .userTappedSkip:
            // 진행 중인 검증은 버린다 — 스킵한 뒤 늦게 도착한 성공이 다음 스텝을 한 번 더 push 하면 안 된다.
            return .merge(
                .cancel(id: CancelID.validate),
                .send(.delegate(.continueRequested(nil)))
            )
        }
    }

    /// 하단 «계속하기» — 현재 탭의 입력을 delegate 페이로드로 옮긴다. 선택 스텝이라 nil(스킵)도 정상 경로다.
    private func submit(_ state: inout State) -> Effect<Action> {
        switch state.mode {
        case .link:
            // 빈 링크는 스킵(nil) — 툴팁 안내와 일치.
            guard !trimmedLink(state).isEmpty else { return .send(.delegate(.continueRequested(nil))) }
            return submitLink(&state)
        case .directText:
            let text = state.directText.trimmingCharacters(in: .whitespacesAndNewlines)
            // 빈 입력은 스킵(nil). 길이 무효는 «계속하기» 가 꺼져 있어 도달하지 않지만 방어적으로 막는다.
            guard !text.isEmpty else { return .send(.delegate(.continueRequested(nil))) }
            guard state.isDirectTextValid else { return .none }
            return .send(.delegate(.continueRequested(.text(text))))
        }
    }

    /// 비어 있지 않은 링크 제출 — 검증을 부르고, 성공 응답이 오면 다음 스텝으로 넘긴다.
    private func submitLink(_ state: inout State) -> Effect<Action> {
        let url = trimmedLink(state)
        switch state.linkValidation {
        case .loading:
            // 이미 분석 중 — 중복 호출하지 않는다.
            return .none
        case .success:
            // 이미 검증된 링크(뒤로가기 재진입·draft 복원) — 다시 부르지 않고 넘긴다.
            return .send(.delegate(.continueRequested(.link(url))))
        case .idle, .failure:
            break
        }
        // 클라이언트 1차 형식 검사 — 불일치는 서버 왕복 없이 즉시 에러. 버튼은 형식 불일치면 꺼져 있어
        // 여기엔 키보드 리턴으로만 도달한다.
        guard Self.isValidLinkFormat(url) else {
            state.linkValidation = .failure(message: Self.invalidFormatMessage)
            return .none
        }
        state.linkValidation = .loading
        return .run { send in
            await send(.inner(.linkValidated(try await jdClient.validate(url))))
        } catch: { _, send in
            await send(.inner(.linkValidationFailed))
        }
        .cancellable(id: CancelID.validate, cancelInFlight: true)
    }

    private func reduceInner(_ state: inout State, _ action: Action.Inner) -> Effect<Action> {
        switch action {
        case let .linkValidated(validation):
            // HTTP 200 이어도 valid 로 성공을 판단한다 (JDClient 계약).
            guard validation.valid else {
                state.linkValidation = .failure(message: validation.message ?? Self.fallbackErrorMessage)
                return .none
            }
            // 성공이면 바로 다음 스텝 — 입력이 바뀌면 in-flight 가 취소되므로 지금 링크가 검증된 그 링크다.
            state.linkValidation = .success
            return .send(.delegate(.continueRequested(.link(trimmedLink(state)))))

        case .linkValidationFailed:
            state.linkValidation = .failure(message: Self.fallbackErrorMessage)
            return .none

        case .tooltipExpired:
            state.isTooltipExpired = true
            return .none
        }
    }

    private func trimmedLink(_ state: State) -> String {
        state.linkText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 클라이언트 1차 형식 검사 — http(s) 스킴 + 호스트를 갖춘 URL 인지.
    /// 공고 본문을 통째로 붙여넣는 실수(공백·한글 포함) 등을 서버 왕복 없이 거른다.
    static func isValidLinkFormat(_ raw: String) -> Bool {
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return false }
        return true
    }
}
