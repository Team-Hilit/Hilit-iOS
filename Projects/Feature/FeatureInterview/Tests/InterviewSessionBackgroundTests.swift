//
//  InterviewSessionBackgroundTests.swift
//  FeatureInterviewTests
//
//  Created by 서정원 on 26/08/08.
//

import ComposableArchitecture
import DomainInterviewInterface
import DomainRecordingInterface
import DomainSpeechInterface
import Foundation
import Testing

@testable import FeatureInterviewImplementation

// 백그라운드 동결(스펙 ②) — 마감 순서·시계 정지·입력 잠금·held 갱신·랩업 예외를 고정한다.
@MainActor
struct InterviewSessionBackgroundTests {
    @Test("백그라운드 진입은 마감→suspend(쌍)→stopCapture 순서로 동결하고 held 를 누적초+토큰으로 갱신한다")
    func backgroundFreezesInOrder() async {
        var state = InterviewSessionFeature.State.fixture(hasStarted: true)
        state.hasRecording = true
        // 값 배치가 계약을 가른다: 화면 경과초(60) ≠ 세그먼트 누적초(45.6→46). 같은 수로 두면
        // «elapsedSeconds 를 저장» 하는 구현도, 절삭(Int(45.6)=45)하는 구현도 똑같이 통과해 버린다.
        state.elapsedSeconds = 60
        state.toast = .exitUnlocked
        let calls = LockIsolated<[String]>([])
        let saved = LockIsolated<HeldSession?>(nil)
        let store = TestStore(initialState: state) { InterviewSessionFeature() }
        store.dependencies.speechClient.finishSessionAudioRecording = {
            calls.withValue { $0.append("finish") }
            return SessionAudioRecording(fileURL: URL(fileURLWithPath: "/tmp/a.m4a"), startedAtHostSeconds: 1)
        }
        store.dependencies.recordingClient.suspendRecording = { audio in
            calls.withValue { $0.append("suspend(\(audio == nil ? "무음" : "쌍"))") }
            return 45.6
        }
        store.dependencies.speechClient.stopCapture = { calls.withValue { $0.append("stopCapture") } }
        store.dependencies.heldSessionStore.save = { saved.setValue($0) }

        await store.send(.view(.sceneBackgrounded)) {
            $0.isInterrupted = true
            $0.toast = nil
            $0.isSubmitting = false
        }
        // 이탈 통보는 마감·held 갱신이 **끝난 뒤**에 나간다 — 이걸 받은 상위가 cover 를 닫으며
        // 이 effect 를 취소하기 때문이다(위로 올리면 세그먼트·보관값이 중간에 잘린다).
        await store.receive(\.delegate.interrupted)
        await store.finish()
        #expect(calls.value == ["finish", "suspend(쌍)", "stopCapture"])
        #expect(saved.value == HeldSession(
            sessionId: state.sessionId, recordedSeconds: 46, processToken: HeldSession.currentProcessToken
        ))
    }

    @Test("동결 후엔 시계 tick 도 사용자 입력도 죽는다 — 다음 상태는 코디네이터 라우팅뿐")
    func frozenSessionIgnoresInputs() async {
        var state = InterviewSessionFeature.State.fixture(hasStarted: true)
        state.isInterrupted = true
        let store = TestStore(initialState: state) { InterviewSessionFeature() }

        await store.send(.view(.userTappedClose))        // 상태 무변화 단언 (클로저 없음)
        await store.send(.view(.sceneBackgrounded))      // 이중 동결 없음
        await store.send(.inner(.clockTicked))           // 시계도 죽는다 — 영상 축조차 흐르지 않는다
    }

    @Test("네트워크 오버레이 위에서 백그라운드 — pendingRetry 를 버리고 동결로 승격한다(재개가 재동기화를 흡수)")
    func backgroundSupersedesNetworkOverlay() async {
        var state = InterviewSessionFeature.State.fixture(hasStarted: true)
        state.failure = InterviewFailureFeature.State(kind: .network)
        state.pendingRetry = .playQuestion
        let store = TestStore(initialState: state) { InterviewSessionFeature() }
        store.dependencies.speechClient.finishSessionAudioRecording = { nil }
        store.dependencies.recordingClient.suspendRecording = { _ in nil }
        store.dependencies.speechClient.stopCapture = {}
        // heldSessionStore.save 미스텁 — 녹화가 없던 세션이 보관값을 건드리면 unimplemented 가 잡는다.

        await store.send(.view(.sceneBackgrounded)) {
            $0.isInterrupted = true
            $0.failure = nil
            $0.pendingRetry = nil
            $0.isSubmitting = false
        }
        await store.receive(\.delegate.interrupted)
        await store.finish()
    }

    @Test("랩업(마무리 멘트) 중 백그라운드 — 청취를 포기하고 그 자리에서 span 을 닫아 즉시 마감한다")
    func backgroundDuringWrapUpFinishesImmediately() async {
        var state = InterviewSessionFeature.State.fixture(hasStarted: true)
        state.hasRecording = true
        state.isWrappingUp = true
        state.wrapUpStartedAt = 500
        state.elapsedSeconds = 503
        let ref = RecordingRef(sessionId: state.sessionId, fileURL: URL(fileURLWithPath: "/tmp/m.mp4"), durationSeconds: 503)
        let store = TestStore(initialState: state) { InterviewSessionFeature() }
        store.dependencies.speechClient.finishSessionAudioRecording = { nil }
        store.dependencies.speechClient.stopCapture = {}
        store.dependencies.recordingClient.stopRecording = { _ in ref }

        await store.send(.view(.sceneBackgrounded)) {
            $0.isWrappingUp = false
            $0.wrapUpSpan = InterviewVideoWrapUpSpan(wrapUpStartSec: 500, wrapUpEndSec: 503)
            $0.isFinishing = true
        }
        await store.receive(\.inner.recordingStopped)
        await store.receive(\.delegate.finished)
    }

    @Test("합성 중(isFinishing) 백그라운드는 동결하지 않는다 — 이미 종료 확정 구간")
    func backgroundDuringFinishingIsIgnored() async {
        var state = InterviewSessionFeature.State.fixture(hasStarted: true)
        state.isFinishing = true
        let store = TestStore(initialState: state) { InterviewSessionFeature() }

        await store.send(.view(.sceneBackgrounded))   // 상태 무변화
    }

    // 마이크 취소는 캡처 스트림 종료 → live `stopCapture()` → **진행 중 세션 기록 폐기**로 이어진다.
    // 마감과 나란히(merge) 걸면 순서가 미보장이라 백그라운드마다 세그먼트가 무음이 될 수 있고,
    // 전 세그먼트가 무음이면 합성이 통째로 throw 한다(`RecordingClientLive` 무음 영상 금지 가드).
    @Test("동결도 세션 오디오를 마감한 뒤에야 마이크를 끊는다 — 취소를 마감과 나란히 걸지 않는다", .timeLimit(.minutes(1)))
    func freezeStopsMicOnlyAfterSessionAudioIsFinished() async {
        let calls = AsyncStream<String>.makeStream()
        let store = TestStore(initialState: .fixture()) {
            InterviewSessionFeature()
        } withDependencies: {
            $0.ignoreHeldSessionStamp()
            $0.continuousClock = TestClock()
            $0.recordingClient.startPreview = { nil }
            $0.recordingClient.startRecording = { _ in 0 }
            $0.recordingClient.suspendRecording = { _ in nil }
            // 스스로 끝나지 않는 캡처 스트림 — 취소가 걸리면 onTermination 이 그 시점을 알린다.
            $0.speechClient.startCapture = {
                AsyncStream { continuation in
                    continuation.onTermination = { _ in calls.continuation.yield("micCaptureCancelled") }
                }
            }
            $0.speechClient.startSessionAudioRecording = {}
            $0.speechClient.finishSessionAudioRecording = {
                calls.continuation.yield("sessionAudioFinished")
                return .stub
            }
            $0.speechClient.stopCapture = { calls.continuation.yield("micStopped") }
            $0.speechClient.playStream = { _, _ in finishedPlayback() }
            $0.speechClient.setSessionAudioMuted = { _ in }
            $0.speechClient.startAnswerRecording = {}
            $0.interviewClient.questionAudioStream = { stubAudioStream($0, $1) }
        }
        store.exhaustivity = .off

        await store.send(.view(.onAppear))
        await store.receive(\.inner.recordingStarted)
        await store.send(.view(.sceneBackgrounded))
        var observed: [String] = []
        for await call in calls.stream {
            observed.append(call)
            if observed.count == 2 { break }
        }
        #expect(observed == ["sessionAudioFinished", "micStopped"])
    }

    // 옛 동작은 여기서 BACK_EXIT 를 최선 노력 제출해 서버 세션을 닫았는데, 그러면 `checkResume` 이
    // ENDED 를 돌려줘 재개가 원천 봉쇄된다(2026-08-09 설계 수정). 제출이 되살아나면 `submitAnswer`
    // 미스텁(unimplemented)이 잡는다 — 이 테스트의 핵심 단언이다.
    @Test("8분 전 나가기는 제출 없이 세션을 동결한다 — 서버 세션이 살아 있어야 재개된다")
    func earlyExitFreezesWithoutEndingSession() async {
        let saved = LockIsolated<HeldSession?>(nil)
        var initialState = InterviewSessionFeature.State.fixture(hasStarted: true)
        initialState.hasRecording = true
        initialState.elapsedSeconds = 100
        let store = TestStore(initialState: initialState) {
            InterviewSessionFeature()
        } withDependencies: {
            $0.speechClient.finishSessionAudioRecording = { nil }
            $0.recordingClient.suspendRecording = { _ in 92.4 }
            $0.speechClient.stopCapture = {}
            $0.heldSessionStore.save = { saved.setValue($0) }
        }

        await store.send(.view(.userTappedClose)) {
            $0.isEarlyExitWarningPresented = true
        }
        await store.send(.view(.userTappedLeaveInterview)) {
            $0.isEarlyExitWarningPresented = false
            $0.isInterrupted = true
        }
        await store.receive(\.delegate.interrupted)
        await store.finish()
        // 재개 재료 — 누적초는 화면 경과초(100)가 아니라 세그먼트 실측(92.4→92)이다.
        #expect(saved.value == HeldSession(
            sessionId: initialState.sessionId, recordedSeconds: 92, processToken: HeldSession.currentProcessToken
        ))
    }

    // 백그라운드와 갈리는 유일한 지점 — 그쪽은 시작 전이면 화면을 지키고 복귀를 기다리지만,
    // 사용자가 «나가기» 를 눌렀으면 닫을 세그먼트가 없어도 반드시 나가야 한다.
    @Test("시작 전 나가기도 반드시 이행된다 — 닫을 세그먼트가 없어도 화면을 떠난다")
    func earlyExitBeforeStartStillLeaves() async {
        var initialState = InterviewSessionFeature.State.fixture()   // hasStarted false
        initialState.isEarlyExitWarningPresented = true
        let store = TestStore(initialState: initialState) {
            InterviewSessionFeature()
        } withDependencies: {
            $0.speechClient.finishSessionAudioRecording = { nil }
            $0.recordingClient.suspendRecording = { _ in nil }
            $0.speechClient.stopCapture = {}
            // heldSessionStore.save 미스텁 — 녹화가 없던 세션이 0초 보관값을 덮으면 unimplemented 가 잡는다.
        }

        await store.send(.view(.userTappedLeaveInterview)) {
            $0.isEarlyExitWarningPresented = false
            $0.isInterrupted = true
        }
        await store.receive(\.delegate.interrupted)
        await store.finish()
    }

    // 백그라운드를 거치지 않고 죽은 면접(크래시·메모리 압박·동결 완주 전 강제 종료)을 킬 클린업이
    // 잡으려면 «이 프로세스에서 면접이 시작됐다» 는 표식이 **시작 시점에** 찍혀 있어야 한다. 생성 시점
    // 보관값은 표식이 없어 갓 시작한 보관분과 구분되지 않고, 그래서 서버 세션이 영영 살아남았다
    // (2026-08-09 결함 수정 — 판정 자체는 `HeldSessionTests`·`HeldSessionCleanupTests`).
    @Test("면접 시작이 보관값에 프로세스 표식을 찍는다 — 백그라운드 없이 죽어도 정리 대상이 된다")
    func recordingStartStampsProcessToken() async {
        let saved = LockIsolated<HeldSession?>(nil)
        let store = TestStore(initialState: .fixture()) { InterviewSessionFeature() }
        store.exhaustivity = .off
        store.dependencies.continuousClock = TestClock()   // 시작이 세션 시계를 연다 — 틱은 다른 테스트가 본다
        store.dependencies.recordingClient.startPreview = { nil }
        store.dependencies.recordingClient.startRecording = { _ in 0 }
        store.dependencies.heldSessionStore.save = { saved.setValue($0) }
        store.dependencies.speechClient.startCapture = { AsyncStream { $0.finish() } }
        store.dependencies.speechClient.startSessionAudioRecording = {}
        store.dependencies.speechClient.setSessionAudioMuted = { _ in }
        store.dependencies.speechClient.playStream = { _, _ in finishedPlayback() }
        store.dependencies.speechClient.startAnswerRecording = {}
        store.dependencies.interviewClient.questionAudioStream = stubAudioStream

        await store.send(.view(.onAppear))
        await store.receive(\.inner.recordingStarted)
        #expect(saved.value?.processToken == HeldSession.currentProcessToken)
        #expect(saved.value?.isResumableInCurrentProcess == true)   // 이 프로세스에선 여전히 재개 대상
    }

    @Test("동결 후 도착한 늦은 제출 응답은 무시된다 — 취소와 도착의 레이스를 상태로 닫는다")
    func lateSubmissionResponseAfterFreezeIsDiscarded() async {
        var state = InterviewSessionFeature.State.fixture(hasStarted: true)
        state.isInterrupted = true
        let store = TestStore(initialState: state) { InterviewSessionFeature() }

        // 세션을 끝내는 응답이 뒤늦게 도착해도 endSession 이 돌지 않는다(상태 무변화·effect 없음).
        await store.send(.inner(.answerSubmitted(AnswerResult(
            answerId: 1, nextQuestion: nil, sessionEnded: true, wrapUpMessage: nil, endType: .manualEnd
        ))))
    }
}

// 재개 시드(스펙 ③④) — 동결의 반대쪽 반. readiness 를 생략하고 confirmResume 의 최신 질문·누적초로
// 세션에 직행할 때, 시계 이어가기·질문 출처(스트림)·해금 보완·시작 실패 폴백을 고정한다.
@MainActor
struct InterviewSessionResumeSeedTests {
    /// 재개 진입 시드 — 최신 턴 질문(confirmResume)과 표시용 근사 누적초(held).
    private static func resumeSeed(elapsed: Int = 60) -> InterviewResumeSeed {
        InterviewResumeSeed(
            question: NextQuestion(questionId: 21, isLast: false, turn: TurnInfo(turnLevel: 2, depthLevel: 0)),
            approximateElapsedSeconds: elapsed
        )
    }

    @Test("재개 시드 — 타이머는 누적초에서 이어지고(1:00→1:01) 첫 질문은 스트림으로 재생된다", .timeLimit(.minutes(1)))
    func resumeSeedsClockAndStreamsQuestion() async {
        let clock = TestClock()
        // 스트림 요청은 «신호» 로 기다린다 — 재생 effect 는 receive 반환과 비동기라 플래그 즉시 검사가 레이스다.
        let streamRequested = AsyncStream<Void>.makeStream()
        let store = TestStore(
            initialState: InterviewSessionFeature.State(sessionId: 1, resume: Self.resumeSeed(elapsed: 60))
        ) { InterviewSessionFeature() }
        store.exhaustivity = .off
        store.dependencies.continuousClock = clock
        store.dependencies.recordingClient.startPreview = { nil }
        store.dependencies.recordingClient.startRecording = { _ in 60.4 }
        store.dependencies.ignoreHeldSessionStamp()
        store.dependencies.interviewClient.questionAudioStream = { _, _ in
            streamRequested.continuation.yield(())
            return InterviewAudioStream(url: URL(string: "https://example.com/tts")!, headers: [:])
        }
        store.dependencies.speechClient.setSessionAudioMuted = { _ in }
        store.dependencies.speechClient.playStream = { _, _ in AsyncStream { $0.finish() } }
        store.dependencies.speechClient.startCapture = { AsyncStream { $0.finish() } }
        store.dependencies.speechClient.startSessionAudioRecording = {}
        // speechClient.play 는 스텁하지 않는다 — 요약 mp3 경로로 새면 unimplemented 가 잡는다.

        await store.send(.view(.onAppear))
        await store.receive(\.inner.recordingStarted)
        #expect(store.state.elapsedSeconds == 60)     // 에셋 실측(60.4 반올림)이 시드를 확정
        for await _ in streamRequested.stream { break }   // 요약 mp3 가 아니라 스트림 경로

        await clock.advance(by: .seconds(1))
        await store.receive(\.inner.clockTicked)
        #expect(store.state.effectiveElapsedSeconds == 61)   // 1:01
    }

    // 근사 시드(30) ≠ 실측(63.6→64) 으로 값을 벌려 둔다 — 같은 수로 두면 «반환값을 버리는» 구현도
    // 통과해 버려 raw 축의 진실이 무엇인지 테스트가 말하지 못한다.
    @Test("raw 축을 확정하는 건 에셋 실측이다 — 재개 시드의 근사 누적초를 덮는다")
    func measuredCumulativeSecondsOverwritesApproximateSeed() async {
        let store = TestStore(
            initialState: InterviewSessionFeature.State(sessionId: 1, resume: Self.resumeSeed(elapsed: 30))
        ) { InterviewSessionFeature() }
        store.exhaustivity = .off
        store.dependencies.continuousClock = TestClock()
        store.dependencies.recordingClient.startPreview = { nil }
        store.dependencies.recordingClient.startRecording = { _ in 63.6 }
        store.dependencies.ignoreHeldSessionStamp()
        store.dependencies.interviewClient.questionAudioStream = { stubAudioStream($0, $1) }
        store.dependencies.speechClient.setSessionAudioMuted = { _ in }
        store.dependencies.speechClient.playStream = { _, _ in AsyncStream { $0.finish() } }
        store.dependencies.speechClient.startCapture = { AsyncStream { $0.finish() } }
        store.dependencies.speechClient.startSessionAudioRecording = {}

        await store.send(.view(.onAppear))
        await store.receive(\.inner.recordingStarted)
        #expect(store.state.elapsedSeconds == 64)
        // 시간 마킹도 확정된 raw 축으로 찍힌다 — 서버가 이 값으로 영상과 정렬한다.
        #expect(store.state.questionAudioStartedAt == 64)
    }

    @Test("8분 이후 재개 시드는 해금을 토스트 없이 즉시 켠다 — 등호 tick 이 다시 오지 않는다")
    func resumeSeedBeyondUnlockEnablesExitSilently() {
        let state = InterviewSessionFeature.State(sessionId: 1, resume: Self.resumeSeed(elapsed: 500))
        #expect(state.isExitAvailable)
        #expect(state.toast == nil)
    }

    // 근사 시드는 경계 «아래»(400)인데 실측이 «위»(500)인 경우 — 해금 보완의 나머지 절반이다.
    // init 만 판정하고 말면 확정 elapsed 가 이미 480 을 지나 등호 tick 이 영영 안 오고,
    // 그 세션 내내 «면접 종료하기» 가 안 보인다(조용하고 치명적).
    @Test("실측이 경계를 넘긴 재개도 해금을 토스트 없이 켠다 — 근사 시드만으로는 판정이 모자란다")
    func measuredSecondsBeyondUnlockEnablesExitSilently() async {
        let store = TestStore(
            initialState: InterviewSessionFeature.State(sessionId: 1, resume: Self.resumeSeed(elapsed: 400))
        ) { InterviewSessionFeature() }
        store.exhaustivity = .off
        store.dependencies.continuousClock = TestClock()
        store.dependencies.recordingClient.startPreview = { nil }
        store.dependencies.recordingClient.startRecording = { _ in 500.0 }
        store.dependencies.ignoreHeldSessionStamp()
        store.dependencies.interviewClient.questionAudioStream = { stubAudioStream($0, $1) }
        store.dependencies.speechClient.setSessionAudioMuted = { _ in }
        store.dependencies.speechClient.playStream = { _, _ in AsyncStream { $0.finish() } }
        store.dependencies.speechClient.startCapture = { AsyncStream { $0.finish() } }
        store.dependencies.speechClient.startSessionAudioRecording = {}

        #expect(!store.state.isExitAvailable)   // init 판정으로는 아직 잠겨 있다
        await store.send(.view(.onAppear))
        await store.receive(\.inner.recordingStarted)
        #expect(store.state.isExitAvailable)
        #expect(store.state.toast == nil)       // 재개엔 해금 안내를 다시 띄우지 않는다
    }

    @Test("재개 진입에서 녹화 시작이 실패해도 근사 시드를 지킨다 — 0 으로 리셋하지 않는다")
    func resumeKeepsApproximateSeedOnRecordingFailure() async {
        let store = TestStore(
            initialState: InterviewSessionFeature.State(sessionId: 1, resume: Self.resumeSeed(elapsed: 60))
        ) { InterviewSessionFeature() }
        store.exhaustivity = .off
        store.dependencies.continuousClock = TestClock()
        store.dependencies.recordingClient.startPreview = { nil }
        store.dependencies.recordingClient.startRecording = { _ in throw RecordingError.startFailed("테스트") }
        store.dependencies.ignoreHeldSessionStamp()
        store.dependencies.interviewClient.questionAudioStream = { stubAudioStream($0, $1) }
        store.dependencies.speechClient.setSessionAudioMuted = { _ in }
        store.dependencies.speechClient.playStream = { _, _ in AsyncStream { $0.finish() } }
        // 녹화 실패여도 캡처 구독(observeMicCapture)은 돈다 — startSessionAudioRecording 만 꺼진다(미스텁이 감시).
        store.dependencies.speechClient.startCapture = { AsyncStream { $0.finish() } }

        await store.send(.view(.onAppear))
        await store.receive(\.inner.recordingStarted)
        #expect(store.state.elapsedSeconds == 60)
        #expect(!store.state.hasRecording)
    }
}
