//
//  OnboardingPreloadFeatureTests.swift
//  FeatureOnboardingTests
//
//  Created by EunSeo on 26/07/19.
//

import ComposableArchitecture
import DomainInterviewInterface
import DomainJDInterface
import Foundation
import Testing

@testable import FeatureOnboardingImplementation

@MainActor
struct OnboardingPreloadFeatureTests {
    private static let portfolioId = UUID(uuidString: "00000000-0000-0000-0000-0000000000f1")!

    /// 세션 입력을 만들 수 있는 완전한 수집 데이터(포트폴리오만 필수 — 직군·연차는 서버 프로필 스냅샷).
    private func fullData() -> OnboardingData {
        OnboardingData(userName: "재원", portfolioId: Self.portfolioId)
    }

    @Test("READY 가 먼저 와도 가짜 스테이지가 다 지나야 3행이 체크되고 완료로 넘어간다")
    func analysisCreatesSessionAndCompletes() async {
        let clock = TestClock()
        let store = TestStore(initialState: OnboardingPreloadFeature.State(data: fullData())) {
            OnboardingPreloadFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.interviewClient.createSession = { _ in
                InterviewSessionCreated(sessionId: 7, status: "PROCESSING", statusUrl: nil)
            }
            $0.interviewClient.sessionStatus = { _ in
                InterviewSessionStatus(status: .ready, startedAt: nil, summaryQuestion: nil)
            }
        }

        await store.send(.view(.onAppear)) { $0.hasStartedAnalysis = true }
        await store.receive(\.inner.sessionCreated) { $0.sessionId = 7 }
        // READY 선착 — 3행은 아직 체크되지 않는다 (가짜 스테이지 대기).
        await store.receive(\.inner.statusPolled) { $0.isSessionReady = true }
        await clock.advance(by: OnboardingPreloadFeature.stageDuration)
        await store.receive(\.inner.stageAdvanced) { $0.completedStages = 1 }
        // 2행 체크 + READY 기수신 → 같은 리듀스에서 3행까지 체크된다.
        await clock.advance(by: OnboardingPreloadFeature.stageDuration)
        await store.receive(\.inner.stageAdvanced) { $0.completedStages = 3 }
        await clock.advance(by: OnboardingPreloadFeature.finalCheckHold)
        await store.receive(\.inner.finalCheckShown) { $0.phase = .filling }
        // 사면이 올라오는 동안은 글자 없는 구간 — 다 덮인 뒤에야 완료 문구가 나온다.
        await clock.advance(by: .seconds(OnboardingPreloadFeature.fillSeconds))
        await store.receive(\.inner.fillFinished) { $0.phase = .completed }
        await clock.advance(by: OnboardingPreloadFeature.completionHoldDuration)
        await store.receive(\.inner.completionHoldFinished)
        await store.receive(\.delegate.completed, 7)
    }

    @Test("PROCESSING 응답은 폴링 간격 뒤 재조회해 READY 로 완료된다")
    func analysisPollsUntilReady() async {
        let clock = TestClock()
        let statusCalls = LockIsolated(0)
        let store = TestStore(initialState: OnboardingPreloadFeature.State(data: fullData())) {
            OnboardingPreloadFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.interviewClient.createSession = { _ in
                InterviewSessionCreated(sessionId: 7, status: "PROCESSING", statusUrl: nil)
            }
            $0.interviewClient.sessionStatus = { _ in
                statusCalls.withValue { $0 += 1 }
                let ready = statusCalls.value > 1
                return InterviewSessionStatus(status: ready ? .ready : .processing, startedAt: nil, summaryQuestion: nil)
            }
        }

        await store.send(.view(.onAppear)) { $0.hasStartedAnalysis = true }
        await store.receive(\.inner.sessionCreated) { $0.sessionId = 7 }
        await store.receive(\.inner.statusPolled)   // 1회차 PROCESSING — 상태 변화 없음
        // 폴링 간격(3s) 사이에 가짜 스테이지(1.2s·2.4s)가 먼저 지나 1·2행이 체크된다.
        // READY 전이므로 3행은 스피너 유지 — READY 도착 액션에서 비로소 체크된다.
        await clock.advance(by: OnboardingPreloadFeature.pollInterval)
        await store.receive(\.inner.stageAdvanced) { $0.completedStages = 1 }
        await store.receive(\.inner.stageAdvanced) { $0.completedStages = 2 }
        await store.receive(\.inner.statusPolled) {
            $0.isSessionReady = true
            $0.completedStages = 3
        }
        await clock.advance(by: OnboardingPreloadFeature.finalCheckHold)
        await store.receive(\.inner.finalCheckShown) { $0.phase = .filling }
        // 사면이 올라오는 동안은 글자 없는 구간 — 다 덮인 뒤에야 완료 문구가 나온다.
        await clock.advance(by: .seconds(OnboardingPreloadFeature.fillSeconds))
        await store.receive(\.inner.fillFinished) { $0.phase = .completed }
        await clock.advance(by: OnboardingPreloadFeature.completionHoldDuration)
        await store.receive(\.inner.completionHoldFinished)
        await store.receive(\.delegate.completed, 7)
    }

    @Test("연관성 부족(FREETEXT_NOT_RELEVANT)은 relevanceCheckFailed 를 delegate 로 올린다")
    func relevanceFailureDelegates() async {
        let store = TestStore(initialState: OnboardingPreloadFeature.State(data: fullData())) {
            OnboardingPreloadFeature()
        } withDependencies: {
            $0.continuousClock = TestClock()   // 가짜 스테이지 타이머용 — 실패 시 취소된다.
            $0.interviewClient.createSession = { _ in throw InterviewError.freeTextNotRelevant }
        }

        await store.send(.view(.onAppear)) { $0.hasStartedAnalysis = true }
        await store.receive(\.inner.relevanceCheckFailed)
        await store.receive(\.delegate.relevanceCheckFailed)
    }

    @Test("세션 생성 실패는 실패 모달로 전환한다 (재시도 없음)")
    func analysisFailsOnCreateError() async {
        let store = TestStore(initialState: OnboardingPreloadFeature.State(data: fullData())) {
            OnboardingPreloadFeature()
        } withDependencies: {
            $0.continuousClock = TestClock()   // 가짜 스테이지 타이머용 — 실패 시 취소된다.
            $0.interviewClient.createSession = { _ in throw NSError(domain: "test", code: -1) }
        }

        await store.send(.view(.onAppear)) { $0.hasStartedAnalysis = true }
        await store.receive(\.inner.analysisFailed) {
            $0.phase = .failed(.retry(message: OnboardingPreloadFeature.failureMessage))
        }
    }

    @Test("수집 데이터가 불완전하면 세션 생성 없이 실패한다")
    func analysisFailsWhenConfigIncomplete() async {
        // portfolioId 누락 → interviewConfig() 가 nil → createSession 호출 안 됨.
        let store = TestStore(
            initialState: OnboardingPreloadFeature.State(data: OnboardingData(userName: "재원"))
        ) {
            OnboardingPreloadFeature()
        }

        await store.send(.view(.onAppear)) { $0.hasStartedAnalysis = true }
        await store.receive(\.inner.analysisFailed) {
            $0.phase = .failed(.retry(message: OnboardingPreloadFeature.configMissingMessage))
        }
    }

    @Test("onAppear 재진입은 세션 생성을 중복하지 않는다")
    func onAppearIsIdempotent() async {
        let clock = TestClock()
        let createCalls = LockIsolated(0)
        let store = TestStore(initialState: OnboardingPreloadFeature.State(data: fullData())) {
            OnboardingPreloadFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.interviewClient.createSession = { _ in
                createCalls.withValue { $0 += 1 }
                return InterviewSessionCreated(sessionId: 7, status: "PROCESSING", statusUrl: nil)
            }
            $0.interviewClient.sessionStatus = { _ in
                InterviewSessionStatus(status: .ready, startedAt: nil, summaryQuestion: nil)
            }
        }

        await store.send(.view(.onAppear)) { $0.hasStartedAnalysis = true }
        await store.receive(\.inner.sessionCreated) { $0.sessionId = 7 }
        await store.receive(\.inner.statusPolled) { $0.isSessionReady = true }
        // 분석 진행 중 재진입 — 이미 시작됐으므로 상태 변화도, 새 세션 생성도 없어야 한다.
        await store.send(.view(.onAppear))
        await clock.advance(by: OnboardingPreloadFeature.stageDuration)
        await store.receive(\.inner.stageAdvanced) { $0.completedStages = 1 }
        await clock.advance(by: OnboardingPreloadFeature.stageDuration)
        await store.receive(\.inner.stageAdvanced) { $0.completedStages = 3 }
        await clock.advance(by: OnboardingPreloadFeature.finalCheckHold)
        await store.receive(\.inner.finalCheckShown) { $0.phase = .filling }
        // 사면이 올라오는 동안은 글자 없는 구간 — 다 덮인 뒤에야 완료 문구가 나온다.
        await clock.advance(by: .seconds(OnboardingPreloadFeature.fillSeconds))
        await store.receive(\.inner.fillFinished) { $0.phase = .completed }
        await clock.advance(by: OnboardingPreloadFeature.completionHoldDuration)
        await store.receive(\.inner.completionHoldFinished)
        await store.receive(\.delegate.completed, 7)
        #expect(createCalls.value == 1)
    }

    @Test("JD 검증 만료(JD_NOT_VALIDATED)는 링크 재검증 후 세션 생성을 재시도한다")
    func jdValidationExpiredRevalidatesAndRetries() async {
        let clock = TestClock()
        let createCalls = LockIsolated(0)
        let validateCalls = LockIsolated(0)
        var data = fullData()
        data.jd = .link("https://job.com/1")
        let store = TestStore(initialState: OnboardingPreloadFeature.State(data: data)) {
            OnboardingPreloadFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.interviewClient.createSession = { _ in
                createCalls.withValue { $0 += 1 }
                if createCalls.value == 1 { throw InterviewError.jdNotValidated }   // 서버 JD 캐시 만료
                return InterviewSessionCreated(sessionId: 7, status: "PROCESSING", statusUrl: nil)
            }
            $0.interviewClient.sessionStatus = { _ in
                InterviewSessionStatus(status: .ready, startedAt: nil, summaryQuestion: nil)
            }
            $0.jdClient.validate = { _ in
                validateCalls.withValue { $0 += 1 }
                return JDValidation(valid: true, reason: nil, message: nil)
            }
        }

        await store.send(.view(.onAppear)) { $0.hasStartedAnalysis = true }
        // 1차 createSession → JD_NOT_VALIDATED → 재검증 트리거(1회 가드 셋)
        await store.receive(\.inner.jdValidationExpired) { $0.didRetryJDValidation = true }
        // 재검증 valid → 세션 생성 재시도 → 성공
        await store.receive(\.inner.sessionRetryRequested)
        await store.receive(\.inner.sessionCreated) { $0.sessionId = 7 }
        await store.receive(\.inner.statusPolled) { $0.isSessionReady = true }
        // 이후 완료 흐름은 정상 경로와 동일.
        await clock.advance(by: OnboardingPreloadFeature.stageDuration)
        await store.receive(\.inner.stageAdvanced) { $0.completedStages = 1 }
        await clock.advance(by: OnboardingPreloadFeature.stageDuration)
        await store.receive(\.inner.stageAdvanced) { $0.completedStages = 3 }
        await clock.advance(by: OnboardingPreloadFeature.finalCheckHold)
        await store.receive(\.inner.finalCheckShown) { $0.phase = .filling }
        // 사면이 올라오는 동안은 글자 없는 구간 — 다 덮인 뒤에야 완료 문구가 나온다.
        await clock.advance(by: .seconds(OnboardingPreloadFeature.fillSeconds))
        await store.receive(\.inner.fillFinished) { $0.phase = .completed }
        await clock.advance(by: OnboardingPreloadFeature.completionHoldDuration)
        await store.receive(\.inner.completionHoldFinished)
        await store.receive(\.delegate.completed, 7)
        #expect(validateCalls.value == 1)
        #expect(createCalls.value == 2)   // 최초 + 재검증 후 재시도
    }

    @Test("JD 재검증도 실패하면 재시도 없이 실패 화면으로 간다")
    func jdRevalidationFailureStopsRetry() async {
        let createCalls = LockIsolated(0)
        var data = fullData()
        data.jd = .link("https://job.com/1")
        let store = TestStore(initialState: OnboardingPreloadFeature.State(data: data)) {
            OnboardingPreloadFeature()
        } withDependencies: {
            $0.continuousClock = TestClock()   // 가짜 스테이지 타이머용 — 실패 시 취소된다.
            $0.interviewClient.createSession = { _ in
                createCalls.withValue { $0 += 1 }
                throw InterviewError.jdNotValidated
            }
            $0.jdClient.validate = { _ in JDValidation(valid: false, reason: "CRAWLING_FAILED", message: nil) }
        }

        await store.send(.view(.onAppear)) { $0.hasStartedAnalysis = true }
        await store.receive(\.inner.jdValidationExpired) { $0.didRetryJDValidation = true }
        // 재검증 valid=false → 재시도하지 않고 실패.
        await store.receive(\.inner.analysisFailed) {
            $0.phase = .failed(.retry(message: OnboardingPreloadFeature.failureMessage))
        }
        #expect(createCalls.value == 1)   // 재시도 안 함
    }

    @Test("일반 실패 모달의 [확인] 은 집중 프로젝트 복귀(retryRequested)를 올린다")
    func failureConfirmRequestsRetry() async {
        var state = OnboardingPreloadFeature.State(data: fullData())
        state.phase = .failed(.retry(message: OnboardingPreloadFeature.failureMessage))
        let store = TestStore(initialState: state) {
            OnboardingPreloadFeature()
        }

        await store.send(.view(.userTappedFailureConfirm))
        await store.receive(\.delegate.retryRequested)
    }

    @Test("이용권 소진(403)은 소진 모달이 되고 [확인] 은 위저드 이탈을 올린다")
    func noRemainingTicketClosesWizard() async {
        let store = TestStore(initialState: OnboardingPreloadFeature.State(data: fullData())) {
            OnboardingPreloadFeature()
        } withDependencies: {
            $0.continuousClock = TestClock()
            $0.interviewClient.createSession = { _ in throw InterviewError.noRemainingTicket }
        }

        await store.send(.view(.onAppear)) { $0.hasStartedAnalysis = true }
        await store.receive(\.inner.analysisFailed) {
            $0.phase = .failed(.noRemainingTicket)
        }
        await store.send(.view(.userTappedFailureConfirm))
        await store.receive(\.delegate.closeRequested)
    }

    @Test("계정 정지(403)는 화면 상태 없이 코디네이터로 올린다")
    func accountSuspendedDelegatesUp() async {
        let store = TestStore(initialState: OnboardingPreloadFeature.State(data: fullData())) {
            OnboardingPreloadFeature()
        } withDependencies: {
            $0.continuousClock = TestClock()
            $0.interviewClient.createSession = { _ in throw InterviewError.accountSuspended }
        }

        await store.send(.view(.onAppear)) { $0.hasStartedAnalysis = true }
        await store.receive(\.inner.accountSuspended)
        await store.receive(\.delegate.accountSuspended)
    }

    @Test("실패가 아닐 때 [확인] 은 무시한다")
    func failureConfirmIgnoredOutsideFailure() async {
        let store = TestStore(initialState: OnboardingPreloadFeature.State(data: fullData())) {
            OnboardingPreloadFeature()
        }

        await store.send(.view(.userTappedFailureConfirm))
    }

    @Test("주입된 OnboardingData 를 상태로 보존한다")
    func keepsInjectedOnboardingData() async {
        let data = fullData()
        let store = TestStore(initialState: OnboardingPreloadFeature.State(data: data)) {
            OnboardingPreloadFeature()
        }

        #expect(store.state.data == data)
        #expect(store.state.phase == .analyzing)
    }
}
