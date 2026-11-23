//
//  InterviewFeatureResumeRoutingTests.swift
//  FeatureInterviewTests
//
//  Created by 서정원 on 26/08/09.
//

import ComposableArchitecture
import DomainInterviewInterface
import DomainRecordingInterface
import DomainSpeechInterface
import Foundation
import Testing

@testable import FeatureInterviewImplementation

// 복귀 라우팅(스펙 ③, 2026-08-09 개정) — 동결 세션은 **백그라운드 진입 때** 홈으로 나가고(복귀를
// 기다렸다 닫으면 그 왕복 동안 면접 화면이 보인다), 복귀 체크는 **준비 화면 전용**으로 남는다.
@MainActor
struct InterviewFeatureResumeRoutingTests {
    /// 재개 시드 — 홈이 confirmResume 으로 받아 코디네이터에 실어 주는 것과 같은 모양.
    static let resumeSeed = InterviewResumeSeed(
        question: NextQuestion(questionId: 21, isLast: false, turn: TurnInfo(turnLevel: 2, depthLevel: 0)),
        approximateElapsedSeconds: 60
    )

    /// 동결된(= 백그라운드로 얼린) 세션 — 이탈 통보를 올리기 직전의 상태.
    /// 재개 진입은 준비 화면부터 열려서(`State(sessionId:resume:)`), 시작 탭을 거친 뒤의 세션 화면을 직접 세운다.
    private static func frozenSessionState() -> InterviewFeature.State {
        var state = InterviewFeature.State(sessionId: 1, resume: resumeSeed)
        var session = InterviewSessionFeature.State(sessionId: 1, resume: resumeSeed)
        session.isInterrupted = true
        state.screen = .session(session)
        return state
    }

    // 이 매칭이 빠져도 컴파일러는 조용하다 — 기존 `case .screen, .delegate` catch-all 이 흡수해
    // 백그라운드를 다녀와도 면접 화면이 그대로 남는다. 그래서 테스트로 고정한다.
    @Test("동결 통보 즉시 이탈 — 판정을 기다리지 않고 장치를 놓고 interrupted 로 홈 경유를 위임한다")
    func interruptedLeavesImmediately() async {
        let calls = LockIsolated<[String]>([])
        let store = TestStore(initialState: Self.frozenSessionState()) { InterviewFeature() }
        // checkResume 미스텁 — 이탈 판단에 네트워크를 끼우면(옛 동작) unimplemented 가 잡는다.
        // 고아 세그먼트 마감 — 파일 마감(moov)은 캡처세션이 도는 동안 써져야 해 stopPreview 앞이다.
        store.dependencies.recordingClient.suspendRecording = { _ in
            calls.withValue { $0.append("suspend") }
            return nil
        }
        store.dependencies.recordingClient.stopPreview = { calls.withValue { $0.append("stopPreview") } }
        store.dependencies.speechClient.stopCapture = { calls.withValue { $0.append("stopCapture") } }
        // discardRecording·heldSessionStore.clear 미스텁 — 재개 재료(세그먼트·보관값)를 지우면 unimplemented 가 잡는다.

        await store.send(.screen(.session(.delegate(.interrupted)))) { $0.isClosing = true }
        await store.receive(\.delegate.interrupted)
        await store.finish()
        #expect(calls.value == ["suspend", "stopPreview", "stopCapture"])
    }

    @Test("종료 확정(isClosing) 뒤 도착한 동결 통보는 무시된다 — 늦은 이탈이 산출물을 찢지 않는다")
    func interruptedAfterClosingIsIgnored() async {
        var state = Self.frozenSessionState()
        state.isClosing = true
        let store = TestStore(initialState: state) { InterviewFeature() }
        // 장치 정지 미스텁 — 두 번째 이탈이 돌면 unimplemented 가 잡는다.

        await store.send(.screen(.session(.delegate(.interrupted))))
    }

    @Test("동결 세션의 .active 는 체크하지 않는다 — 백그라운드 진입 때 이미 홈으로 나갔다")
    func activeOnFrozenSessionIsIgnored() async {
        let store = TestStore(initialState: Self.frozenSessionState()) { InterviewFeature() }
        // checkResume 미스텁 — 세션 화면에서 판정이 돌면 unimplemented 가 잡는다.
        await store.send(.view(.sceneBecameActive))
    }

    @Test("동결 안 된 세션의 .active 는 무시 — inactive 바운스가 산 세션을 찢지 않는다")
    func activeBounceOnLiveSessionIsIgnored() async {
        var state = InterviewFeature.State(sessionId: 7)
        state.screen = .session(.fixture(hasStarted: true))
        let store = TestStore(initialState: state) { InterviewFeature() }
        // checkResume 스텁 없음(testValue = unimplemented) — 호출되면 즉시 실패한다.
        await store.send(.view(.sceneBecameActive))
    }

    @Test("종료 확정(isClosing) 후의 .active 는 체크하지 않는다 — enqueue 중인 산출물을 찢지 않는다")
    func activeAfterClosingIsIgnored() async {
        var state = InterviewFeature.State(sessionId: 1)
        state.isClosing = true
        let store = TestStore(initialState: state) { InterviewFeature() }
        // checkResume 미스텁 — 호출되면 unimplemented 가 잡는다.
        await store.send(.view(.sceneBecameActive))
    }

    @Test("준비 화면의 복귀는 체크는 돌되 RESUMABLE 이면 그 자리를 지킨다 — 잃을 게 없다")
    func readinessStaysOnResumable() async {
        let store = TestStore(initialState: InterviewFeature.State(sessionId: 1)) { InterviewFeature() }
        store.dependencies.interviewClient.checkResume = { _ in
            InterviewResumeCheck(resumeState: .resumable, startedAt: nil, elapsedSeconds: 0, status: nil)
        }
        // 장치 정지·폐기 미스텁 — 준비 화면을 건드리면 unimplemented 가 잡는다.

        await store.send(.view(.sceneBecameActive))
        await store.receive(\.resumeChecked)
    }

    @Test("준비 화면 ENDED·INVALID — held 를 지우고 STT 실패 화면으로 교체한다")
    func endedInvalidSwapsToSttFailure() async {
        let cleared = LockIsolated(false)
        let store = TestStore(initialState: InterviewFeature.State(sessionId: 1)) { InterviewFeature() }
        store.dependencies.interviewClient.checkResume = { _ in
            InterviewResumeCheck(resumeState: .ended, startedAt: nil, elapsedSeconds: nil, status: .invalid)
        }
        store.dependencies.heldSessionStore.clear = { cleared.setValue(true) }
        store.dependencies.recordingClient.discardRecording = {}
        store.dependencies.recordingClient.stopPreview = {}
        store.dependencies.speechClient.stopCapture = {}
        store.dependencies.speechClient.stopPlayback = {}

        await store.send(.view(.sceneBecameActive))
        await store.receive(\.resumeChecked) {
            $0.screen = .failure(InterviewFailureFeature.State(kind: .speechRecognition))
        }
        await store.finish()
        #expect(cleared.value)
    }

    @Test("준비 화면 ENDED·기타 — held 를 지우고 폐기·정지 후 closed 로 나간다(환불은 서버가 GET 안에서 완료)")
    func endedOtherClosesFlow() async {
        let cleared = LockIsolated(false)
        let store = TestStore(initialState: InterviewFeature.State(sessionId: 1)) { InterviewFeature() }
        store.dependencies.interviewClient.checkResume = { _ in
            InterviewResumeCheck(resumeState: .ended, startedAt: nil, elapsedSeconds: nil, status: .abandoned)
        }
        store.dependencies.heldSessionStore.clear = { cleared.setValue(true) }
        store.dependencies.recordingClient.discardRecording = {}
        store.dependencies.recordingClient.stopPreview = {}
        store.dependencies.speechClient.stopCapture = {}
        store.dependencies.speechClient.stopPlayback = {}

        await store.send(.view(.sceneBecameActive))
        await store.receive(\.resumeChecked) { $0.isClosing = true }
        await store.receive(\.delegate.closed)
        await store.finish()
        #expect(cleared.value)
    }

    @Test("준비 화면의 체크 실패(오프라인 복귀)는 삼킨다 — 그 자리를 지키고 다음 복귀가 다시 묻는다")
    func readinessSwallowsCheckFailure() async {
        let store = TestStore(initialState: InterviewFeature.State(sessionId: 1)) { InterviewFeature() }
        store.dependencies.interviewClient.checkResume = { _ in throw InterviewError.networkFailure }

        await store.send(.view(.sceneBecameActive))
        await store.finish()
    }
}
