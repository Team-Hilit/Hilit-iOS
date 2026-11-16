//
//  FeatureOnboardingTests.swift
//  FeatureOnboardingTests
//
//  Created by EunSeo on 26/07/18.
//

import ComposableArchitecture
import Foundation
import Testing

@testable import FeatureOnboardingImplementation

@MainActor
struct OnboardingCoordinatorTests {
    /// 위저드 총 스텝 수 — 프로덕션 상수를 그대로 써서 스텝 수가 바뀌면 테스트도 따라간다.
    private let total = OnboardingFeature.totalSteps

    /// draft 영속을 no-op 으로, date 를 고정으로 스텁한 코디네이터 스토어 (persist/clear·TTL 판정용).
    /// 직군·연차는 가입 온보딩(FeatureAuth) 소관이라 여기선 주입값으로만 들어온다.
    private func makeStore(_ state: OnboardingFeature.State) -> TestStoreOf<OnboardingFeature> {
        TestStore(initialState: state) {
            OnboardingFeature()
        } withDependencies: {
            $0.onboardingDraftStore = OnboardingDraftStore(load: { nil }, save: { _ in }, clear: {})
            $0.date = .constant(Date(timeIntervalSince1970: 1_782_000_000))
        }
    }

    private func initialState() -> OnboardingFeature.State {
        OnboardingFeature.State(userName: "재원")
    }

    @Test("JD 스킵(nil)은 jd 필드를 비운 채 포트폴리오 스텝을 push 한다")
    func jobDescriptionSkipPushesPortfolioUpload() async {
        let store = makeStore(initialState())

        await store.send(.jobDescriptionUpload(.delegate(.continueRequested(nil)))) {
            $0.path.append(.portfolioUpload(.init(step: 2, totalSteps: self.total, checksExisting: true)))
        }
    }

    @Test("JD 제출은 JDSubmission 을 해체 없이 jd 에 저장한다")
    func jobDescriptionSubmissionStoredIntact() async {
        let store = makeStore(initialState())

        await store.send(.jobDescriptionUpload(.delegate(.continueRequested(.link("https://job.com/1"))))) {
            $0.data.jd = .link("https://job.com/1")
            $0.path.append(.portfolioUpload(.init(step: 2, totalSteps: self.total, checksExisting: true)))
        }
    }

    /// 서버 READY 는 위저드 밖에서도 바뀌므로(마이페이지 업로드·삭제) 재진입마다 다시 물어야 한다 —
    /// 조회를 위저드 수명당 1회로 묶으면 두 번째 진입에서 재사용 대상을 놓치고 register 가 409 로 떨어진다.
    @Test("빈 판으로 STEP2 를 다시 세울 때도 기존 포폴 조회를 켠다")
    func portfolioStepRearmsExistingCheckOnReentry() async {
        let store = makeStore(initialState())

        await store.send(.jobDescriptionUpload(.delegate(.continueRequested(nil)))) {
            $0.path.append(.portfolioUpload(.init(step: 2, totalSteps: self.total, checksExisting: true)))
        }

        let id = store.state.path.ids[0]
        await store.send(.path(.element(id: id, action: .portfolioUpload(.delegate(.backRequested))))) {
            $0.path.removeAll()
        }

        await store.send(.jobDescriptionUpload(.delegate(.continueRequested(nil)))) {
            $0.path.append(.portfolioUpload(.init(step: 2, totalSteps: self.total, checksExisting: true)))
        }
    }

    @Test("루트(STEP 1)의 이전으로는 위저드 앞이 없어 이탈(dismiss)로 올린다")
    func rootBackDismissesOnboarding() async {
        let store = makeStore(initialState())

        await store.send(.jobDescriptionUpload(.delegate(.backRequested)))
        await store.receive(\.delegate.dismiss)
    }

    @Test("루트 닫기는 온보딩 종료(dismiss)로 올린다")
    func rootCloseDismissesOnboarding() async {
        let store = makeStore(initialState())

        await store.send(.jobDescriptionUpload(.delegate(.closeRequested)))
        await store.receive(\.delegate.dismiss)
    }

    @Test("스텝 뒤로가기는 스택을 pop 한다")
    func stepBackPopsStack() async {
        var state = initialState()
        state.path.append(.portfolioUpload(.init(step: 2, totalSteps: total)))
        let store = makeStore(state)

        let id = store.state.path.ids[0]
        await store.send(.path(.element(id: id, action: .portfolioUpload(.delegate(.backRequested))))) {
            $0.path.removeAll()
        }
    }

    @Test("포트폴리오 완료는 id·파일명을 저장하고 대표 프로젝트 스텝을 push 한다")
    func portfolioContinuePushesMainProject() async {
        var state = initialState()
        state.path.append(.portfolioUpload(.init(step: 2, totalSteps: total)))
        let store = makeStore(state)

        let portfolioId = UUID(uuidString: "00000000-0000-0000-0000-0000000000f1")!
        let id = store.state.path.ids[0]
        await store.send(
            .path(.element(
                id: id,
                action: .portfolioUpload(.delegate(.continueRequested(portfolioId: portfolioId, fileName: "포폴.pdf")))
            ))
        ) {
            $0.data.portfolioId = portfolioId
            $0.data.portfolioFileName = "포폴.pdf"
            $0.path.append(.mainProject(.init(step: 3, totalSteps: self.total)))
        }
    }

    @Test("대표 프로젝트 완료는 누적 데이터를 들고 프리로드 스텝을 push 한다")
    func mainProjectContinuePushesPreloadWithData() async {
        var state = initialState()
        state.path.append(.mainProject(.init(step: 3, totalSteps: total)))
        let store = makeStore(state)

        var expectedData = state.data
        expectedData.freeText = "결제 시스템 리팩토링"

        let id = store.state.path.ids[0]
        await store.send(
            .path(.element(id: id, action: .mainProject(.delegate(.continueRequested(freeText: "결제 시스템 리팩토링")))))
        ) {
            $0.data.freeText = "결제 시스템 리팩토링"
            $0.path.append(.preload(.init(data: expectedData)))
        }
    }

    @Test("프리로드 완료는 세션 id 를 들고 온보딩 완료(finished)로 올린다")
    func preloadCompletedFinishesOnboarding() async {
        var state = initialState()
        state.path.append(.preload(.init(data: state.data)))
        let store = makeStore(state)

        let id = store.state.path.ids[0]
        await store.send(.path(.element(id: id, action: .preload(.delegate(.completed(sessionId: 42))))))
        await store.receive(\.delegate.finished, 42)
        await store.finish()
    }

    @Test("프리로드 실패 모달 [확인] 은 집중 프로젝트로 되돌린다 — 연관성 카운트는 그대로")
    func preloadRetryPopsBackToMainProject() async {
        var state = initialState()
        state.path.append(.mainProject(.init(step: 3, totalSteps: total)))
        state.path.append(.preload(.init(data: state.data)))
        let store = makeStore(state)

        let preloadId = store.state.path.ids[1]
        await store.send(.path(.element(id: preloadId, action: .preload(.delegate(.retryRequested))))) {
            $0.path.pop(from: preloadId)
        }
        #expect(store.state.relevanceFailureCount == 0)
        await store.finish()
    }

    @Test("프리로드 계정 정지는 위저드 delegate 로 올린다")
    func preloadAccountSuspendedDelegatesUp() async {
        var state = initialState()
        state.path.append(.preload(.init(data: state.data)))
        let store = makeStore(state)

        let id = store.state.path.ids[0]
        await store.send(.path(.element(id: id, action: .preload(.delegate(.accountSuspended)))))
        await store.receive(\.delegate.accountSuspended)
        await store.finish()
    }

    @Test("연관성 실패(4회 미만)는 대표 프로젝트로 되돌리고 경고를 주입한다")
    func relevanceFailurePopsBackToMainProject() async {
        var state = initialState()
        state.path.append(.mainProject(.init(step: 3, totalSteps: total)))
        state.path.append(.preload(.init(data: state.data)))
        let store = makeStore(state)

        let mainProjectId = store.state.path.ids[0]
        let preloadId = store.state.path.ids[1]
        await store.send(.path(.element(id: preloadId, action: .preload(.delegate(.relevanceCheckFailed))))) {
            $0.relevanceFailureCount = 1
            $0.path.removeLast()   // 프리로드만 pop — 대표 프로젝트는 남는다.
            $0.path[id: mainProjectId] = .mainProject(
                .init(step: 3, totalSteps: self.total, inputWarning: OnboardingFeature.relevanceWarningMessage)
            )
        }
    }

    @Test("연관성 4회째 실패는 두 선택지 다이얼로그를 띄운다")
    func fourthRelevanceFailureShowsDialog() async {
        var state = initialState()
        state.relevanceFailureCount = 3   // 직전까지 3회
        state.path.append(.mainProject(.init(step: 3, totalSteps: total)))
        state.path.append(.preload(.init(data: state.data)))
        let store = makeStore(state)

        let preloadId = store.state.path.ids[1]
        await store.send(.path(.element(id: preloadId, action: .preload(.delegate(.relevanceCheckFailed))))) {
            $0.relevanceFailureCount = 4
            $0.path.removeLast()
            $0.relevanceChoice = OnboardingFeature.relevanceChoiceDialog()
        }
    }

    @Test("다이얼로그 '포폴 다시 올리기'는 포트폴리오 스텝으로 되돌리고 카운트를 리셋한다")
    func reuploadChoicePopsToPortfolio() async {
        var state = initialState()
        state.relevanceFailureCount = 4
        state.path.append(.portfolioUpload(.init(step: 2, totalSteps: total)))
        state.path.append(.mainProject(.init(step: 3, totalSteps: total)))
        state.relevanceChoice = OnboardingFeature.relevanceChoiceDialog()
        let store = makeStore(state)

        await store.send(.relevanceChoice(.presented(.reuploadPortfolio))) {
            $0.relevanceFailureCount = 0
            $0.relevanceChoice = nil
            $0.path.removeLast()   // 대표 프로젝트 pop → 포트폴리오 업로드 남음
        }
    }

    @Test("다이얼로그 '대표 프로젝트 없이 진행'은 freeText 를 비우고 재분석한다")
    func proceedWithoutFocusRestartsPreload() async {
        var state = initialState()
        state.data.freeText = "무관한 내용"
        state.relevanceFailureCount = 4
        state.path.append(.mainProject(.init(step: 3, totalSteps: total)))
        state.relevanceChoice = OnboardingFeature.relevanceChoiceDialog()
        let store = makeStore(state)

        var expectedData = state.data
        expectedData.freeText = nil
        await store.send(.relevanceChoice(.presented(.proceedWithoutFocus))) {
            $0.relevanceFailureCount = 0
            $0.data.freeText = nil
            $0.relevanceChoice = nil
            $0.path.append(.preload(.init(data: expectedData)))
        }
    }
}
