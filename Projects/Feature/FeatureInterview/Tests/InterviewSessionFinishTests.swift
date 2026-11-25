//
//  InterviewSessionFinishTests.swift
//  FeatureInterviewTests
//
//  Created by 서정원 on 26/08/07.
//

import ComposableArchitecture
import DomainInterviewInterface
import DomainRecordingInterface
import DomainSpeechInterface
import Foundation
import Testing

@testable import FeatureInterviewImplementation

// 종료가 확정된 뒤(마무리 계측 ~ 정지+합성)의 잠금과 순서를 고정한다 — 여기서 새면 delegate 가 두 번 나가거나
// 세션 오디오가 폐기돼 영상이 조용히 사라지고, 순서가 뒤집히면 합성이 도는 8~10초 동안 마이크·카메라가
// 켜진 채로 남는다. 픽스처는 InterviewSessionTestFixtures.swift 공용,
// 세션 시계·턴 루프·녹화 배선은 InterviewSessionFeatureTests.swift.
@MainActor
struct InterviewSessionFinishTests {
    @Test("마무리 멘트 계측 중엔 종료·이탈 입력이 먹지 않는다 — 종료가 두 번 통보되지 않게")
    func wrappingUpIgnoresExitInputs() async {
        var initialState = InterviewSessionFeature.State.fixture(hasStarted: true)
        initialState.hasRecording = true
        initialState.isWrappingUp = true
        initialState.isExitAvailable = true
        initialState.phase = .processingAnswer
        // 제출·정지 스텁 없음 — 입력이 하나라도 새면 unimplemented 가 잡는다.
        let store = TestStore(initialState: initialState) {
            InterviewSessionFeature()
        }

        // 넷 다 상태 무변화·effect 없음(모달조차 열리지 않는다).
        await store.send(.view(.userTappedClose))
        await store.send(.view(.userTappedExit))
        await store.send(.view(.userTappedFinishInterview))
        await store.send(.view(.userTappedLeaveInterview))
    }

    // 마이크 취소는 스트림 종료 → live 의 `stopCapture()` → **진행 중 세션 기록 폐기**로 이어진다.
    // 마감보다 먼저 도착하면 산출물이 통째로 날아가므로 순서를 여기서 못 박는다(정상 종료마다 도는 경로).
    @Test("정지 경로는 세션 오디오를 마감한 뒤에야 마이크를 끊는다", .timeLimit(.minutes(1)))
    func micCaptureStopsOnlyAfterSessionAudioIsFinished() async {
        let calls = AsyncStream<String>.makeStream()
        let store = TestStore(initialState: .fixture()) {
            InterviewSessionFeature()
        } withDependencies: {
            $0.ignoreHeldSessionSave()
            $0.continuousClock = TestClock()
            $0.recordingClient.startPreview = { nil }
            $0.recordingClient.startRecording = { _, _ in 0 }
            $0.recordingClient.stopRecording = { _ in .stub }
            // 스스로 끝나지 않는 캡처 스트림 — 종료는 effect 취소뿐이라 onTermination 이 곧 stopCapture 시점이다.
            $0.speechClient.startCapture = {
                AsyncStream { continuation in
                    continuation.onTermination = { _ in calls.continuation.yield("micCaptureStopped") }
                }
            }
            $0.speechClient.startSessionAudioRecording = {}
            $0.speechClient.finishSessionAudioRecording = {
                calls.continuation.yield("sessionAudioFinished")
                return .stub
            }
            $0.speechClient.stopCapture = {}
            $0.speechClient.playStream = { _, _ in finishedPlayback() }
            $0.speechClient.setSessionAudioMuted = { _ in }
            $0.speechClient.startAnswerRecording = {}
            $0.speechClient.answerAudio = { nil }
            $0.interviewClient.questionAudioStream = stubAudioStream
            $0.interviewClient.submitAnswer = { _, _ in .ended(.normalEnd) }
        }
        store.exhaustivity = .off

        await store.send(.view(.onAppear))
        await store.receive(\.inner.recordingStarted)
        await store.receive(\.inner.questionPlaybackFinished)
        await store.send(.view(.userTappedAnswerComplete))
        var observed: [String] = []
        for await call in calls.stream {
            observed.append(call)
            if observed.count == 2 { break }
        }
        #expect(observed == ["sessionAudioFinished", "micCaptureStopped"])
    }

    // 합성(AVAssetExportSession)은 실기기에서 8~10초 걸린다(2026-08-07 실측 — 대기 시간이 영상 길이와
    // 무관한 고정 비용이라 짧은 세션도 같다). 그동안 마이크가 켜져 있으면 사용자는 «종료했는데 계속 듣고
    // 있다» 를 본다. 마감(finishSessionAudioRecording) 직후엔 기록기 url 이 비어 있어 stopCapture 가
    // 산출물을 지우지 않으므로(SpeechClientLive `finishKeepingFile` 의 defer), 합성 앞에서 끊는다.
    @Test("정지 경로는 세션 오디오 마감 직후·합성 전에 마이크를 끊는다", .timeLimit(.minutes(1)))
    func micStopsBeforeCompositionStarts() async {
        let calls = AsyncStream<String>.makeStream()
        var initialState = InterviewSessionFeature.State.fixture(hasStarted: true)
        initialState.phase = .answering
        initialState.hasRecording = true
        let store = TestStore(initialState: initialState) {
            InterviewSessionFeature()
        } withDependencies: {
            $0.ignoreHeldSessionSave()
            $0.speechClient.finishSessionAudioRecording = {
                calls.continuation.yield("sessionAudioFinished")
                return .stub
            }
            $0.speechClient.stopCapture = { calls.continuation.yield("micStopped") }
            $0.recordingClient.stopRecording = { _ in
                calls.continuation.yield("compositionStarted")
                return .stub
            }
            $0.speechClient.answerAudio = { nil }
            $0.interviewClient.submitAnswer = { _, _ in .ended(.normalEnd) }
        }
        store.exhaustivity = .off

        await store.send(.view(.userTappedAnswerComplete))
        var observed: [String] = []
        for await call in calls.stream {
            observed.append(call)
            if observed.count == 3 { break }
        }
        #expect(observed == ["sessionAudioFinished", "micStopped", "compositionStarted"])
    }

    @Test("이미 종료된 세션(409)이어도 녹화가 있으면 정지·합성을 거쳐 ref 와 함께 통보한다")
    func sessionAlreadyEndedStillStopsRecording() async {
        let ref = RecordingRef(sessionId: 7, fileURL: URL(fileURLWithPath: "/tmp/v.mp4"), durationSeconds: 42)
        var initialState = InterviewSessionFeature.State.fixture(hasStarted: true)
        initialState.phase = .answering
        initialState.hasRecording = true
        let store = TestStore(initialState: initialState) {
            InterviewSessionFeature()
        } withDependencies: {
            $0.ignoreHeldSessionSave()
            $0.recordingClient.stopRecording = { _ in ref }
            $0.speechClient.answerAudio = { nil }
            $0.speechClient.finishSessionAudioRecording = { .stub }
            $0.speechClient.stopCapture = {}
            $0.interviewClient.submitAnswer = { _, _ in throw InterviewError.sessionAlreadyEnded }
        }

        await store.send(.view(.userTappedAnswerComplete)) {
            $0.phase = .processingAnswer
            $0.isSubmitting = true
        }
        await store.receive(\.inner.answerSubmissionFailed) {
            $0.isSubmitting = false
            $0.isFinishing = true
        }
        await store.receive(\.inner.recordingStopped)
        await store.receive({ action in
            guard case let .delegate(.finished(stoppedRef, wrapUp)) = action else { return false }
            return stoppedRef == ref && wrapUp == nil   // 멘트 없이 끝난 세션이라 span 은 없다
        })
    }

    @Test("정지+합성이 이미 걸렸으면 두 번째 종료 신호는 아무 일도 하지 않는다 — 재진입 가드")
    func stopRecordingIsNotReentered() async {
        var initialState = InterviewSessionFeature.State.fixture(hasStarted: true)
        initialState.hasRecording = true
        initialState.isFinishing = true
        // 마감·정지 스텁 없음 — 재진입하면 unimplemented 가 잡는다.
        // (두 번째 stopRecording 은 액터에 recording 이 없어 즉시 throw → 빈 결과가 진짜를 앞지른다.)
        let store = TestStore(initialState: initialState) {
            InterviewSessionFeature()
        }

        await store.send(.inner(.answerSubmissionFailed(.sessionAlreadyEnded, AnswerSubmission(questionId: 1, isWrapUp: false))))
    }

    @Test("정지+합성 구간에도 종료·이탈 입력이 먹지 않는다")
    func finishingIgnoresExitInputs() async {
        var initialState = InterviewSessionFeature.State.fixture(hasStarted: true)
        initialState.hasRecording = true
        initialState.isFinishing = true
        initialState.isExitAvailable = true
        initialState.phase = .processingAnswer
        // 제출·정지 스텁 없음 — 입력이 하나라도 새면 unimplemented 가 잡는다.
        let store = TestStore(initialState: initialState) {
            InterviewSessionFeature()
        }

        await store.send(.view(.userTappedClose))
        await store.send(.view(.userTappedExit))
        await store.send(.view(.userTappedFinishInterview))
        await store.send(.view(.userTappedLeaveInterview))
    }

    @Test("마무리 계측 중 tick 은 시간만 흘리고 상한 마감을 다시 걸지 않는다")
    func wrappingUpTickDoesNotRetriggerHardCap() async {
        var initialState = InterviewSessionFeature.State.fixture(hasStarted: true)
        initialState.hasRecording = true
        initialState.isWrappingUp = true
        initialState.wrapUpStartedAt = InterviewSessionFeature.hardCapSeconds - 1
        initialState.elapsedSeconds = InterviewSessionFeature.hardCapSeconds - 1
        // 제출·재생 스텁 없음 — 상한 마감이 다시 걸리면 unimplemented 가 잡는다.
        let store = TestStore(initialState: initialState) {
            InterviewSessionFeature()
        }

        await store.send(.inner(.clockTicked)) {
            $0.elapsedSeconds = InterviewSessionFeature.hardCapSeconds
        }
    }
}
