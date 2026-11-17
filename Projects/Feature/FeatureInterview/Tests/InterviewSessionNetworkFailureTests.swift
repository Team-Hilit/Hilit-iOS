//
//  InterviewSessionNetworkFailureTests.swift
//  FeatureInterviewTests
//
//  Created by 서정원 on 26/08/06.
//

import ComposableArchitecture
import DomainInterviewInterface
import DomainRecordingInterface
import DomainSpeechInterface
import Foundation
import Testing

@testable import FeatureInterviewImplementation

/// 마감이 끝나 오버레이가 떠 있는 상태 — 재개·중단 테스트의 출발점.
private func pausedState(retry: InterviewSessionFeature.State.PendingRetry) -> InterviewSessionFeature.State {
    var state = InterviewSessionFeature.State.fixture(hasStarted: true)
    state.failure = InterviewFailureFeature.State(kind: .network)
    state.pendingRetry = retry
    state.isCapturePaused = true
    return state
}

// 네트워크 실패 오버레이 상태기계 — 녹화·마이크·시계 마감 후 오버레이(HLT-41)·재개 녹화 후 실패 지점 재시도·
// 제출 없는 중단(스펙 ③, HLT-86 버튼 흐름).
@MainActor
struct InterviewSessionNetworkFailureTests {
    @Test("실패 감지는 세션 오디오 마감 → 세그먼트 마감 → 마이크 정지 → held 갱신 순으로 내린 뒤에야 오버레이를 띄운다")
    func failureSuspendsCaptureBeforeOverlay() async {
        var state = InterviewSessionFeature.State.fixture(hasStarted: true)
        state.hasRecording = true
        state.hasRetriedPlayback = true   // 1회 재시도 이미 소진
        state.elapsedSeconds = 70
        state.isEarlyExitWarningPresented = true
        let calls = LockIsolated<[String]>([])
        let saved = LockIsolated<HeldSession?>(nil)
        let store = TestStore(initialState: state) { InterviewSessionFeature() }
        store.dependencies.speechClient.finishSessionAudioRecording = {
            calls.withValue { $0.append("finish") }
            return SessionAudioRecording(fileURL: URL(fileURLWithPath: "/tmp/a.m4a"), startedAtHostSeconds: 1)
        }
        store.dependencies.recordingClient.suspendRecording = { audio in
            calls.withValue { $0.append("suspend(\(audio == nil ? "무음" : "쌍"))") }
            return 69.6
        }
        store.dependencies.speechClient.stopCapture = { calls.withValue { $0.append("stopCapture") } }
        store.dependencies.heldSessionStore.save = { saved.setValue($0) }

        await store.send(.inner(.questionPlaybackFailed)) {
            $0.isEarlyExitWarningPresented = false
            $0.pendingRetry = .playQuestion
            $0.isCapturePaused = true   // 오버레이는 아직 — 마감 중 재개가 오면 새 세그먼트가 안 선다
        }
        await store.receive(\.inner.capturePaused) {
            $0.failure = InterviewFailureFeature.State(kind: .network)
        }
        await store.finish()   // delegate(.failed) 가 나가면 여기서 잡힌다
        #expect(calls.value == ["finish", "suspend(쌍)", "stopCapture"])
        #expect(saved.value?.recordedSeconds == 70)   // 반올림(69.6 → 70) — 홈 재개 시드
        #expect(saved.value?.sessionId == 7)
    }

    @Test("녹화 없는 세션의 실패는 held 를 건드리지 않고 마이크만 내린다")
    func failureWithoutRecordingKeepsHeld() async {
        var state = InterviewSessionFeature.State.fixture(hasStarted: true)
        state.phase = .processingAnswer
        let submission = AnswerSubmission(questionId: 1, isWrapUp: false)
        let store = TestStore(initialState: state) { InterviewSessionFeature() }
        store.dependencies.speechClient.finishSessionAudioRecording = { nil }
        store.dependencies.recordingClient.suspendRecording = { _ in nil }
        store.dependencies.speechClient.stopCapture = {}
        // heldSessionStore.save 미스텁 — 저장하면 unimplemented 가 잡는다.

        await store.send(.inner(.answerSubmissionFailed(.unexpected, submission))) {
            $0.pendingRetry = .submit(submission)
            $0.isCapturePaused = true
        }
        await store.receive(\.inner.capturePaused) {
            $0.failure = InterviewFailureFeature.State(kind: .network)
        }
    }

    @Test("오버레이 동안 늦게 도착한 시계 tick 은 무시된다 — 녹화가 없는 시간은 영상 축도 판정도 아니다")
    func tickDuringOverlayIsIgnored() async {
        var state = pausedState(retry: .playQuestion)
        state.elapsedSeconds = InterviewSessionFeature.exitUnlockSeconds - 1   // 다음 tick 이 해금 경계
        let store = TestStore(initialState: state) { InterviewSessionFeature() }

        await store.send(.inner(.clockTicked))   // 상태 무변화 — 해금·토스트 없음
    }

    @Test("이어서 진행하기(재생 재시도)는 새 세그먼트를 연 뒤 그 누적초로 시계를 잇고 질문을 다시 재생한다")
    func resumeRestartsRecordingThenReplaysQuestion() async {
        var state = pausedState(retry: .playQuestion)
        state.hasRecording = true
        state.elapsedSeconds = 100
        let started = LockIsolated<[Int]>([])
        let audioURL = URL(fileURLWithPath: "/tmp/audio-7-1.m4a")
        let audioStartedAt = LockIsolated<[URL?]>([])
        let saved = LockIsolated<HeldSession?>(nil)
        let store = TestStore(initialState: state) { InterviewSessionFeature() }
        store.dependencies.continuousClock = TestClock()
        store.dependencies.recordingClient.startRecording = { id in started.withValue { $0.append(id) }; return 98.4 }
        store.dependencies.recordingClient.sessionAudioURL = { audioURL }
        store.dependencies.speechClient.startCapture = { AsyncStream { $0.finish() } }
        store.dependencies.speechClient.startSessionAudioRecording = { url in audioStartedAt.withValue { $0.append(url) } }
        store.dependencies.interviewClient.questionAudioStream = { stubAudioStream($0, $1) }
        store.dependencies.speechClient.playStream = { _, _ in finishedPlayback() }
        store.dependencies.speechClient.setSessionAudioMuted = { _ in }
        store.dependencies.speechClient.startAnswerRecording = {}
        store.dependencies.heldSessionStore.save = { saved.setValue($0) }

        await store.send(.failure(.presented(.delegate(.resumeRequested)))) {
            $0.failure = nil
        }
        await store.receive(\.inner.captureResumed) {
            $0.isCapturePaused = false
            $0.pendingRetry = nil
            $0.elapsedSeconds = 98                // 에셋 실측 누적초 — 새 세그먼트의 0점
            $0.questionAudioStartedAt = 98        // 재생 재시작 시점 — 새 축
        }
        await store.receive(\.inner.questionPlaybackFinished) {
            $0.phase = .answering
            $0.questionAudioEndedAt = 98
            $0.answerStartedAt = 98
        }
        await store.skipInFlightEffects()   // 세션 시계
        #expect(started.value == [7])
        #expect(audioStartedAt.value == [audioURL])   // 새 세그먼트의 세션 오디오가 다시 열린다
        #expect(saved.value?.recordedSeconds == 98)
    }

    @Test("재개 녹화가 실패하면 영상 없는 리포트로 수렴한다 — 앞 세그먼트만 합성하면 이후 마킹이 영상 끝을 넘는다")
    func resumeWithFailedRestartDropsRecording() async {
        var state = pausedState(retry: .playQuestion)
        state.hasRecording = true
        state.elapsedSeconds = 100
        let store = TestStore(initialState: state) { InterviewSessionFeature() }
        store.dependencies.continuousClock = TestClock()
        store.dependencies.recordingClient.startRecording = { _ in throw RecordingError.startFailed("테스트") }
        store.dependencies.speechClient.startCapture = { AsyncStream { $0.finish() } }
        // startSessionAudioRecording·heldSessionStore.save 미스텁 — 녹화 없이 부르면 unimplemented 가 잡는다.
        store.dependencies.interviewClient.questionAudioStream = { stubAudioStream($0, $1) }
        store.dependencies.speechClient.playStream = { _, _ in finishedPlayback() }
        store.dependencies.speechClient.setSessionAudioMuted = { _ in }
        store.dependencies.speechClient.startAnswerRecording = {}

        await store.send(.failure(.presented(.delegate(.resumeRequested)))) {
            $0.failure = nil
        }
        await store.receive(\.inner.captureResumed) {
            $0.isCapturePaused = false
            $0.hasRecording = false
            $0.pendingRetry = nil
            $0.questionAudioStartedAt = 100   // 축은 이어 간다
        }
        await store.receive(\.inner.questionPlaybackFinished) {
            $0.phase = .answering
            $0.questionAudioEndedAt = 100
            $0.answerStartedAt = 100
        }
        await store.skipInFlightEffects()
    }

    @Test("제출 실패는 오디오 포함 submission 을 보관하고, 재개는 answerAudio 재소모 없이 같은 payload 를 재전송한다")
    func submitFailureStoresSubmissionAndResumeResubmits() async {
        var submission = AnswerSubmission(questionId: 1, isWrapUp: false)
        submission.audio = Data("answer".utf8)
        var state = InterviewSessionFeature.State.fixture(hasStarted: true)
        state.phase = .processingAnswer
        let store = TestStore(initialState: state) { InterviewSessionFeature() }
        store.dependencies.continuousClock = TestClock()
        store.dependencies.speechClient.finishSessionAudioRecording = { nil }
        store.dependencies.recordingClient.suspendRecording = { _ in nil }
        store.dependencies.speechClient.stopCapture = {}
        let stored = submission

        await store.send(.inner(.answerSubmissionFailed(.unexpected, stored))) {
            $0.pendingRetry = .submit(stored)
            $0.isCapturePaused = true
        }
        await store.receive(\.inner.capturePaused) {
            $0.failure = InterviewFailureFeature.State(kind: .network)
        }

        // 재개 — speechClient.answerAudio 는 스텁하지 않는다: 재소모하면 unimplemented 가 잡는다(1회 소모성 계약).
        // 녹화 없는 세션이라 startRecording 도 미스텁 — 부르면 unimplemented 가 잡는다.
        let submitted = LockIsolated<[AnswerSubmission]>([])
        store.dependencies.interviewClient.submitAnswer = { _, submission in
            submitted.withValue { $0.append(submission) }
            return .ended(.manualEnd)
        }
        store.dependencies.speechClient.startCapture = { AsyncStream { $0.finish() } }
        store.dependencies.speechClient.play = { _ in finishedPlayback() }
        store.dependencies.speechClient.stopPlayback = {}
        await store.send(.failure(.presented(.delegate(.resumeRequested)))) {
            $0.failure = nil
        }
        await store.receive(\.inner.captureResumed) {
            $0.isCapturePaused = false
            $0.pendingRetry = nil
            $0.isSubmitting = true
        }
        await store.receive(\.inner.answerSubmitted) {
            $0.isSubmitting = false
            $0.isFinishing = true   // 녹화 없는 종료 — 리포트 대기 인디케이터가 여기서 선다
        }
        // 세션 종료 후속(sessionCleanup·finished(nil,nil))은 이 테스트 관심 밖 — 도착만 소화한다.
        await store.receive(\.delegate.finished)
        await store.finish()
        #expect(submitted.value == [stored])   // 같은 payload(오디오 포함) 그대로
    }

    @Test("오버레이 중단하기는 서버 제출 없이 abandon 만 보내고 aborted 를 올린다 — 이용권 미차감 문구 계약")
    func abortFromOverlayNotifiesAbortedWithoutSubmit() async {
        var state = InterviewSessionFeature.State.fixture(hasStarted: true)
        state.failure = InterviewFailureFeature.State(kind: .network)
        state.pendingRetry = .playQuestion
        // interviewClient.submitAnswer 미스텁 — BACK_EXIT 제출이 나가면 unimplemented 가 잡는다.
        // (abandon 은 제출이 아니라 중단 API 라 이 계약을 깨지 않는다.)
        let store = TestStore(initialState: state) { InterviewSessionFeature() }
        store.dependencies.continuousClock = TestClock()   // 안 흘린다 — 즉답 abandon 이 3초 레이스를 먼저 끝낸다
        store.dependencies.interviewClient.abandonSession = { _, _ in .stub }
        store.dependencies.heldSessionStore.clear = {}

        // 오버레이는 남는다 — 이탈이 확정될 때까지가 «진행 중» 이고, 걷어 가는 건 코디네이터의 teardown 이다.
        await store.send(.failure(.presented(.delegate(.closeRequested)))) {
            $0.pendingRetry = nil
            $0.isAbandoning = true
        }
        await store.receive(\.delegate.aborted)
        await store.finish()
    }

    @Test("오버레이 중단하기는 abandon(NETWORK_DISCONNECT) 를 3초 레이스로 시도하고 결과와 무관하게 이탈한다")
    func overlayCloseAbandonsWithNetworkDisconnect() async {
        let clock = TestClock()
        var state = InterviewSessionFeature.State.fixture(hasStarted: true)
        state.failure = InterviewFailureFeature.State(kind: .network)
        state.pendingRetry = .playQuestion
        let abandoned = LockIsolated<AbandonCause?>(nil)
        let cleared = LockIsolated(false)
        let store = TestStore(initialState: state) { InterviewSessionFeature() }
        store.dependencies.continuousClock = clock
        store.dependencies.interviewClient.abandonSession = { _, cause in
            abandoned.setValue(cause)
            // 오프라인 시늉 — 영영 안 끝나는 요청. 3초 레이스가 이탈을 지켜야 한다.
            try await Task.never()
            return .stub   // 도달 불가 — Task.never() 는 취소로만 끝난다(컴파일러가 반환문을 요구할 뿐)
        }
        store.dependencies.heldSessionStore.clear = { cleared.setValue(true) }

        await store.send(.failure(.presented(.delegate(.closeRequested)))) {
            $0.pendingRetry = nil
            $0.isAbandoning = true
        }
        await clock.advance(by: .seconds(3))
        await store.receive(\.delegate.aborted)
        #expect(abandoned.value == .networkDisconnect)
        #expect(cleared.value)
    }

    // 오버레이는 즉시 닫히는데 이탈은 최대 3초 뒤다 — 그 창의 세션 화면은 «살아 있는 것처럼» 보인다.
    // 잠금이 없으면 X→[이탈하기]가 BACK_EXIT 를 제출해 «제출 없이 중단» 계약이 깨지고, 8분 후엔
    // X→[마치기]가 MANUAL_END 로 버린 세션의 영상을 업로드 큐에 넣는다. 백그라운드는 held 를 되살린다.
    @Test("중단 레이스 창(최대 3초) 동안 입력은 전면 잠긴다 — 제출·동결 재발사 없이 이탈만 남는다")
    func inputsAreLockedDuringAbandonRace() async {
        let clock = TestClock()
        var state = InterviewSessionFeature.State.fixture(hasStarted: true)
        state.isExitAvailable = true   // 8분 경과 — X 가 종료 확인 모달을 열 수 있는 조건까지 열어 둔다
        state.failure = InterviewFailureFeature.State(kind: .network)
        state.pendingRetry = .playQuestion
        let store = TestStore(initialState: state) { InterviewSessionFeature() }
        store.dependencies.continuousClock = clock
        // submitAnswer·finishSessionAudioRecording·heldSessionStore.save 미스텁 —
        // 잠금이 뚫려 제출이나 동결이 발사되면 unimplemented 가 잡는다.
        store.dependencies.interviewClient.abandonSession = { _, _ in
            try await Task.never()
            return .stub
        }
        store.dependencies.heldSessionStore.clear = {}

        await store.send(.failure(.presented(.delegate(.closeRequested)))) {
            $0.pendingRetry = nil
            $0.isAbandoning = true
        }
        // 레이스가 도는 동안의 입력·잔광은 전부 죽는다 — 상태 무변화(클로저 없음) + effect 없음.
        await store.send(.view(.userTappedClose))
        await store.send(.view(.userTappedLeaveInterview))
        await store.send(.view(.userTappedFinishInterview))
        await store.send(.view(.sceneBackgrounded))
        await store.send(.inner(.clockTicked))
        // 오버레이가 그대로 떠 있어 [중단하기]도 계속 눌린다 — 재탭은 abandon 재발사 없이 no-op 이다
        // (뚫리면 두 번째 레이스가 뒤늦은 aborted 를 하나 더 올려 아래 receive 가 못 받고 남는다).
        await store.send(.failure(.presented(.delegate(.closeRequested))))

        // 그래도 이탈은 제 시각에 온다 — 잠금이 레이스 effect 자신을 막지 않는다(delegate 는 잠금 밖).
        await clock.advance(by: .seconds(3))
        await store.receive(\.delegate.aborted)
    }

}

// 녹화를 내리고 다시 여는 창의 경계 — 해금 재시드·입력 잠금·미룬 이탈·무음 재적용(HLT-41 리뷰 반영).
@MainActor
struct InterviewSessionNetworkTransitionTests {
    @Test("재개 재시드가 8분 경계를 건너뛰면 토스트 없이 종료를 연다 — 등호 tick 이 다시 오지 않는다")
    func resumeSeedPastUnlockOpensExit() async {
        var state = pausedState(retry: .playQuestion)
        state.hasRecording = true
        state.elapsedSeconds = InterviewSessionFeature.exitUnlockSeconds - 1
        let store = TestStore(initialState: state) { InterviewSessionFeature() }
        store.dependencies.continuousClock = TestClock()
        store.dependencies.recordingClient.startRecording = { _ in Double(InterviewSessionFeature.exitUnlockSeconds) + 0.4 }
        store.dependencies.recordingClient.sessionAudioURL = { nil }
        store.dependencies.speechClient.startCapture = { AsyncStream { $0.finish() } }
        store.dependencies.speechClient.startSessionAudioRecording = { _ in }
        store.dependencies.interviewClient.questionAudioStream = { stubAudioStream($0, $1) }
        store.dependencies.speechClient.playStream = { _, _ in AsyncStream { _ in } }   // 재생은 이 테스트 관심 밖
        store.dependencies.speechClient.setSessionAudioMuted = { _ in }
        store.dependencies.ignoreHeldSessionStamp()

        await store.send(.failure(.presented(.delegate(.resumeRequested)))) {
            $0.failure = nil
        }
        await store.receive(\.inner.captureResumed) {
            $0.isCapturePaused = false
            $0.pendingRetry = nil
            $0.elapsedSeconds = InterviewSessionFeature.exitUnlockSeconds
            $0.questionAudioStartedAt = InterviewSessionFeature.exitUnlockSeconds
            $0.isExitAvailable = true   // 토스트(exitUnlocked)는 없다
        }
        await store.skipInFlightEffects()
    }

    @Test("이미 해금된 세션이 재시드로 경계 아래에서 다시 480 을 지나도 해금 토스트를 다시 띄우지 않는다")
    func unlockToastIsNotRepeated() async {
        var state = InterviewSessionFeature.State.fixture(hasStarted: true)
        state.isExitAvailable = true
        state.elapsedSeconds = InterviewSessionFeature.exitUnlockSeconds - 1
        let store = TestStore(initialState: state) { InterviewSessionFeature() }

        await store.send(.inner(.clockTicked)) {
            $0.elapsedSeconds = InterviewSessionFeature.exitUnlockSeconds
        }
    }

    @Test("녹화를 내리고 다시 여는 창에선 종료·답변 입력이 닫힌다 — 마감 중 종료 제출이 오버레이와 겹치지 않는다")
    func endingInputsAreLockedWhileCapturePaused() async {
        var state = InterviewSessionFeature.State.fixture(hasStarted: true)
        state.isCapturePaused = true   // 마감 중(오버레이 전)
        state.isExitAvailable = true
        state.phase = .answering
        let store = TestStore(initialState: state) { InterviewSessionFeature() }
        // submitAnswer·answerAudio 미스텁 — 제출이 나가면 unimplemented 가 잡는다.

        await store.send(.view(.userTappedClose))
        await store.send(.view(.userTappedExit))
        await store.send(.view(.userTappedFinishInterview))
        await store.send(.view(.userTappedAnswerComplete))
    }

    @Test("마감 중 백그라운드는 마감이 끝날 때까지 미뤘다가 오버레이 대신 동결한다 — 두 경로가 같은 세그먼트를 닫지 않는다")
    func backgroundDuringSuspendDefersFreeze() async {
        var state = InterviewSessionFeature.State.fixture(hasStarted: true)
        state.hasRecording = true
        state.isCapturePaused = true   // 마감 effect 비행 중(오버레이 전)
        state.pendingRetry = .playQuestion
        let store = TestStore(initialState: state) { InterviewSessionFeature() }

        // finishSessionAudioRecording·suspendRecording 미스텁 — 미루지 않고 바로 동결하면 unimplemented 가 잡는다.
        await store.send(.view(.sceneBackgrounded)) {
            $0.isLeavePending = true
        }
        await store.send(.view(.userTappedLeaveInterview))   // 미룬 동안의 입력은 무시

        let calls = LockIsolated<[String]>([])
        store.dependencies.speechClient.finishSessionAudioRecording = { calls.withValue { $0.append("finish") }; return nil }
        store.dependencies.recordingClient.suspendRecording = { _ in calls.withValue { $0.append("suspend") }; return nil }
        store.dependencies.speechClient.stopCapture = { calls.withValue { $0.append("stopCapture") } }
        await store.send(.inner(.capturePaused)) {
            $0.isLeavePending = false
            $0.isInterrupted = true
            $0.pendingRetry = nil   // 오버레이는 뜨지 않는다
        }
        await store.receive(\.delegate.interrupted)
        #expect(calls.value == ["finish", "suspend", "stopCapture"])
    }

    @Test("재개 녹화가 서는 동안 나가기는 녹화가 선 뒤 그 세그먼트를 동결로 닫는다 — 늦게 선 녹화가 고아로 남지 않는다")
    func leaveDuringResumeFreezesNewSegment() async {
        var state = InterviewSessionFeature.State.fixture(hasStarted: true)
        state.hasRecording = true
        state.isCapturePaused = true   // 재개 startRecording 비행 중(오버레이는 이미 걷힘)
        state.pendingRetry = .playQuestion
        let saved = LockIsolated<HeldSession?>(nil)
        let store = TestStore(initialState: state) { InterviewSessionFeature() }
        store.dependencies.speechClient.finishSessionAudioRecording = { nil }
        store.dependencies.recordingClient.suspendRecording = { _ in 64.2 }
        store.dependencies.speechClient.stopCapture = {}
        store.dependencies.heldSessionStore.save = { saved.setValue($0) }

        await store.send(.view(.userTappedLeaveInterview)) {
            $0.isLeavePending = true
        }
        // 마이크·시계·재생 미스텁 — 재개를 이어 가면 unimplemented 가 잡는다.
        await store.send(.inner(.captureResumed(cumulativeSeconds: 60))) {
            $0.isCapturePaused = false
            $0.isLeavePending = false
            $0.isInterrupted = true
            $0.pendingRetry = nil
        }
        await store.receive(\.delegate.interrupted)
        #expect(saved.value?.recordedSeconds == 64)
    }

    @Test("질문 재생으로 재개할 땐 마이크 엔진을 세운 뒤 세션 오디오 무음을 다시 건다 — 엔진 재시작이 무음을 풀어도 TTS 가 섞이지 않는다")
    func resumeReappliesMuteAfterCaptureStart() async {
        var state = pausedState(retry: .playQuestion)
        state.hasRecording = true
        let calls = LockIsolated<[String]>([])
        let store = TestStore(initialState: state) { InterviewSessionFeature() }
        store.dependencies.continuousClock = TestClock()
        store.dependencies.recordingClient.startRecording = { _ in 10 }
        store.dependencies.recordingClient.sessionAudioURL = { nil }
        store.dependencies.speechClient.startCapture = {
            calls.withValue { $0.append("startCapture") }
            return AsyncStream { _ in }
        }
        store.dependencies.speechClient.startSessionAudioRecording = { _ in calls.withValue { $0.append("startSessionAudio") } }
        store.dependencies.speechClient.setSessionAudioMuted = { muted in calls.withValue { $0.append("mute(\(muted))") } }
        store.dependencies.interviewClient.questionAudioStream = { stubAudioStream($0, $1) }
        store.dependencies.speechClient.playStream = { _, _ in AsyncStream { _ in } }
        store.dependencies.ignoreHeldSessionStamp()

        await store.send(.failure(.presented(.delegate(.resumeRequested)))) { $0.failure = nil }
        await store.receive(\.inner.captureResumed) {
            $0.isCapturePaused = false
            $0.pendingRetry = nil
            $0.elapsedSeconds = 10
            $0.questionAudioStartedAt = 10
        }
        await Task.megaYield()
        await store.skipInFlightEffects()
        let mic = calls.value
        let startIndex = mic.firstIndex(of: "startSessionAudio")
        #expect(startIndex != nil)
        #expect(mic.lastIndex(of: "mute(true)").map { $0 > startIndex! } == true)   // 엔진·기록 시작 «뒤» 무음
    }
}
