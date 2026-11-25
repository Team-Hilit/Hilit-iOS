//
//  InterviewSessionFeatureTests.swift
//  FeatureInterviewTests
//
//  Created by 서정원 on 26/07/25.
//

import AVFoundation
import ComposableArchitecture
import DomainInterviewInterface
import DomainRecordingInterface
import DomainSpeechInterface
import Foundation
import Testing

@testable import FeatureInterviewImplementation

// 세션 시계 상태머신(8:00 해금 → 11:50 카운트다운 → 12:00 HARD_CAP 제출)·턴 루프(제출 응답 분기)·
// 종료 경로(제출 경유)·503 백오프를 고정한다 — 화면 렌더링은 순수 UI 라 프리뷰 육안 검증.
@MainActor
struct InterviewSessionFeatureTests {
    @Test("진입 시 프리뷰 핸들을 확보한다 — 준비 화면이 켜 둔 세션의 멱등 승계")
    func onAppearAcquiresPreviewHandle() async {
        let clock = TestClock()
        let handle = CameraPreviewHandle(session: AVCaptureSession())
        let store = TestStore(initialState: .fixture()) {
            InterviewSessionFeature()
        } withDependencies: {
            $0.ignoreHeldSessionSave()
            $0.continuousClock = clock
            $0.recordingClient.startPreview = { handle }
            $0.recordingClient.startRecording = { _, _ in 0 }
            $0.speechClient.startCapture = { AsyncStream { $0.finish() } }
            $0.speechClient.playStream = { _, _ in finishedPlayback() }
            $0.speechClient.startSessionAudioRecording = {}
            $0.speechClient.setSessionAudioMuted = { _ in }
            $0.speechClient.startAnswerRecording = {}
            $0.interviewClient.questionAudioStream = stubAudioStream
        }
        store.exhaustivity = .off   // 세션 시계·재생 전이는 다른 테스트가 고정 — 여기선 핸들 확보만 본다.

        await store.send(.view(.onAppear))
        await store.receive(\.inner.recordingStarted) {
            $0.hasRecording = true
            $0.questionAudioStartedAt = 0
        }
        await store.skipReceivedActions()
        #expect(store.state.previewHandle == handle)
    }

    @Test("진입 시 마이크 캡처 스트림을 구독하고 요약 질문 재생을 시작한다")
    func onAppearStartsMicCaptureAndSummaryPlayback() async {
        let clock = TestClock()
        let captureStarted = LockIsolated(false)
        let played = LockIsolated<Data?>(nil)
        // 요약 질문에 mp3 동봉("bXAz" = "mp3") — 스트림이 아니라 play 로 재생돼야 한다.
        let store = TestStore(initialState: .fixture(summaryAudio: "bXAz")) {
            InterviewSessionFeature()
        } withDependencies: {
            $0.ignoreHeldSessionSave()
            $0.continuousClock = clock
            $0.recordingClient.startPreview = { nil }
            $0.recordingClient.startRecording = { _, _ in 0 }
            $0.speechClient.startCapture = {
                captureStarted.setValue(true)
                return AsyncStream { $0.finish() }
            }
            $0.speechClient.play = { data in
                played.setValue(data)
                return finishedPlayback()
            }
            $0.speechClient.startSessionAudioRecording = {}
            $0.speechClient.setSessionAudioMuted = { _ in }
            $0.speechClient.startAnswerRecording = {}
        }
        store.exhaustivity = .off

        await store.send(.view(.onAppear))
        await store.receive(\.inner.recordingStarted) {
            $0.hasRecording = true
            $0.questionAudioStartedAt = 0
        }
        await store.skipReceivedActions()
        #expect(captureStarted.value)
        #expect(played.value == Data("mp3".utf8))
        #expect(store.state.phase == .answering)   // 재생 완료 → 답변 녹음으로
    }

    @Test("8분 경과 시 종료가 해금되고 안내 토스트가 떴다가 사라진다")
    func exitUnlocksAtEightMinutes() async {
        let clock = TestClock()
        let store = TestStore(initialState: .fixture()) {
            InterviewSessionFeature()
        } withDependencies: {
            $0.ignoreHeldSessionSave()
            $0.continuousClock = clock
            $0.recordingClient.startPreview = { nil }
            $0.recordingClient.startRecording = { _, _ in 0 }
            $0.recordingClient.stopRecording = { _ in .stub }
            $0.speechClient.startCapture = { AsyncStream { $0.finish() } }
            $0.speechClient.playStream = { _, _ in finishedPlayback() }
            $0.speechClient.startSessionAudioRecording = {}
            $0.speechClient.finishSessionAudioRecording = { .stub }
            $0.speechClient.stopCapture = {}
            $0.speechClient.setSessionAudioMuted = { _ in }
            $0.speechClient.startAnswerRecording = {}
            $0.speechClient.answerAudio = { nil }
            $0.interviewClient.questionAudioStream = stubAudioStream
            $0.interviewClient.submitAnswer = { _, _ in .ended(.manualEnd) }
        }
        store.exhaustivity = .off   // 1초 틱 480회를 개별 검증하지 않는다.

        await store.send(.view(.onAppear))
        await store.receive(\.inner.recordingStarted)
        await clock.advance(by: .seconds(480))
        await store.skipReceivedActions()
        #expect(store.state.isExitAvailable)
        #expect(store.state.toast == .exitUnlocked)

        await clock.advance(by: InterviewSessionFeature.exitNoticeHold)
        await store.skipReceivedActions()
        #expect(store.state.toast == nil)

        await store.send(.view(.userTappedFinishInterview))   // MANUAL_END 제출 → 세션 정리
        await store.finish()
    }

    @Test("상한 10초 전(11:50) 최종 카운트다운으로 전환되고 12:00 도달 시 HARD_CAP 을 제출해 종료한다")
    func finalCountdownThenHardCapSubmission() async {
        let clock = TestClock()
        let captured = LockIsolated<AnswerSubmission?>(nil)
        let store = TestStore(initialState: .fixture()) {
            InterviewSessionFeature()
        } withDependencies: {
            $0.ignoreHeldSessionSave()
            $0.continuousClock = clock
            $0.recordingClient.startPreview = { nil }
            $0.recordingClient.startRecording = { _, _ in 0 }
            $0.recordingClient.stopRecording = { _ in .stub }
            $0.speechClient.startCapture = { AsyncStream { $0.finish() } }
            $0.speechClient.playStream = { _, _ in finishedPlayback() }
            $0.speechClient.startSessionAudioRecording = {}
            $0.speechClient.finishSessionAudioRecording = { .stub }
            $0.speechClient.stopCapture = {}
            $0.speechClient.setSessionAudioMuted = { _ in }
            $0.speechClient.startAnswerRecording = {}
            $0.speechClient.answerAudio = { nil }
            $0.interviewClient.questionAudioStream = stubAudioStream
            $0.interviewClient.submitAnswer = { _, submission in
                captured.setValue(submission)
                return .ended(.hardCap)
            }
        }
        store.exhaustivity = .off

        await store.send(.view(.onAppear))
        await store.receive(\.inner.recordingStarted)
        await clock.advance(by: .seconds(710))   // 11:50
        await store.skipReceivedActions()
        #expect(store.state.phase == .finalCountdown)
        #expect(store.state.toast == .timeExpired)
        #expect(store.state.countdownRemaining == 10)

        await clock.advance(by: .seconds(10))    // 12:00 hard cap — 제출 경유 종료
        await store.receive(\.inner.recordingStopped)   // 마무리 멘트 없음 — 즉시 정지+합성
        await store.receive(\.delegate.finished)
        #expect(captured.value?.endType == .hardCap)
        #expect(captured.value?.isWrapUp == true)
        await store.finish()
    }

    @Test("8분 후 X 는 중도 이탈 경고가 아니라 종료 확인 모달로 간다")
    func lateCloseRoutesToExitConfirm() async {
        var initialState = InterviewSessionFeature.State.fixture(hasStarted: true)
        initialState.isExitAvailable = true
        let store = TestStore(initialState: initialState) {
            InterviewSessionFeature()
        }

        await store.send(.view(.userTappedClose)) {
            $0.isExitConfirmPresented = true
        }
    }

    @Test("네트워크 실패는 열린 모달을 닫고 질문 재생만 끊는다 — 시계·마이크는 살고 유효시간만 멈춘다")
    func networkFailureKeepsSessionAliveUnderOverlay() async {
        let clock = TestClock()
        var initialState = InterviewSessionFeature.State.fixture()
        initialState.isExitConfirmPresented = true
        let store = TestStore(initialState: initialState) {
            InterviewSessionFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.recordingClient.startPreview = { nil }
            $0.recordingClient.startRecording = { _, _ in 0 }
            $0.speechClient.startCapture = { AsyncStream { $0.finish() } }
            // 5초 뒤에야 완료되는 질문 재생 — 오버레이가 재생 effect 를 끊지 않으면 그 완료가 도착해
            // answering 으로 넘어간다. 아래 «재생 취소» 단언이 이걸로 취소를 *시점째* 못 박는다
            // (사용자 관점: 실패 화면 뒤에서 AI 질문 음성이 계속 들리는 상태).
            $0.speechClient.playStream = { _, _ in
                AsyncStream { continuation in
                    Task {
                        try await clock.sleep(for: .seconds(5))
                        continuation.yield(.finished)
                        continuation.finish()
                    }
                }
            }
            $0.speechClient.startSessionAudioRecording = {}
            $0.speechClient.setSessionAudioMuted = { _ in }
            $0.interviewClient.questionAudioStream = stubAudioStream
            // «중단하기» 는 이제 abandon(NETWORK_DISCONNECT)+held clear 를 앞세운다 — 여기선 통과만 시킨다
            // (사유·레이스 계약은 InterviewSessionNetworkFailureTests 가 고정).
            $0.interviewClient.abandonSession = { _, _ in .stub }
            $0.heldSessionStore.clear = {}
            $0.ignoreHeldSessionSave()
        }
        store.exhaustivity = .off   // 시계 틱은 기존 테스트가 고정 — 여기선 오버레이 전후 생존만 본다.

        await store.send(.view(.onAppear))
        await store.receive(\.inner.recordingStarted)
        await clock.advance(by: .seconds(1))   // 세션 시계·재생 effect 가 실제로 돌고 있는 상태를 만든다.
        await store.skipReceivedActions()

        await store.send(.inner(.networkFailureDetected(.playQuestion)))
        #expect(store.state.failure == InterviewFailureFeature.State(kind: .network))
        #expect(store.state.pendingRetry == .playQuestion)
        #expect(store.state.isExitConfirmPresented == false)

        // ① 재생은 감지 시점에 끊긴다 — 원래 재생이 끝났을 시각을 지나도 asking 에 머문다.
        //    취소가 빠지면 지연된 .finished 가 questionPlaybackFinished 를 쏴 phase·마킹이 밀리고,
        //    답변 기록 시작(startAnswerRecording — 미스텁)까지 불려 unimplemented 로도 잡힌다.
        await clock.advance(by: .seconds(5))
        await store.skipReceivedActions()
        #expect(store.state.phase == .asking)
        #expect(store.state.questionAudioEndedAt == nil)

        // ② 세션을 살린 채 덮는 게 이 경로의 계약이다(스펙 ③) — 시계 effect 는 계속 tick 을 보내고,
        //    그 tick 은 영상 축(elapsed)만 밀며 유효시간은 정지 구간(suspended)으로 접힌다.
        #expect(store.state.elapsedSeconds == 6)
        #expect(store.state.suspendedSeconds == 5)
        #expect(store.state.effectiveElapsedSeconds == 1)

        // ③ 나머지 정리(시계·마이크)는 오버레이의 «중단하기» 몫으로 옮겨졌다 — 남으면 finish 가 잡는다.
        await store.send(.failure(.presented(.delegate(.closeRequested))))
        await store.receive(\.delegate.aborted)
        await store.finish()
    }
}

// 답변 제출·턴 루프(응답 분기·503 백오프·종료 제출 경유)를 고정한다 — 세션 시계·진입·정리는 위 스위트.
@MainActor
struct InterviewSessionSubmissionTests {
    @Test("답변 완료는 제출을 거쳐 다음 질문 asking 으로 복귀하고 시간 마킹을 싣는다")
    func answerCompleteSubmitsThenAsksNextQuestion() async {
        let captured = LockIsolated<AnswerSubmission?>(nil)
        var initialState = InterviewSessionFeature.State.fixture(hasStarted: true)
        initialState.phase = .answering
        initialState.elapsedSeconds = 45
        initialState.questionAudioStartedAt = 20
        initialState.questionAudioEndedAt = 30
        initialState.answerStartedAt = 30
        let store = TestStore(initialState: initialState) {
            InterviewSessionFeature()
        } withDependencies: {
            $0.ignoreHeldSessionSave()
            $0.speechClient.answerAudio = { Data("answer".utf8) }
            $0.speechClient.playStream = { _, _ in finishedPlayback() }
            $0.speechClient.setSessionAudioMuted = { _ in }
            $0.speechClient.startAnswerRecording = {}
            $0.interviewClient.questionAudioStream = stubAudioStream
            $0.interviewClient.submitAnswer = { _, submission in
                captured.setValue(submission)
                return .next(13)
            }
        }

        await store.send(.view(.userTappedAnswerComplete)) {
            $0.phase = .processingAnswer
            $0.isSubmitting = true
        }
        await store.receive(\.inner.answerSubmitted) {
            $0.isSubmitting = false
            $0.phase = .asking
            $0.currentQuestion = InterviewSessionFeature.ActiveQuestion(questionId: 13, turnLevel: 1, isLast: false)
            $0.questionAudioStartedAt = 45
            $0.questionAudioEndedAt = nil
            $0.answerStartedAt = nil
        }
        await store.receive(\.inner.questionPlaybackFinished) {
            $0.phase = .answering
            $0.questionAudioEndedAt = 45
            $0.answerStartedAt = 45
        }

        let submission = captured.value
        #expect(submission?.questionId == 1)
        #expect(submission?.audio == Data("answer".utf8))
        #expect(submission?.questionAudioStartAt == 20)
        #expect(submission?.questionAudioEndAt == 30)
        #expect(submission?.answerStartAt == 30)
        #expect(submission?.answerEndAt == 45)
        #expect(submission?.answerDuration == 15)
        #expect(submission?.isWrapUp == false)
        #expect(submission?.endType == nil)
    }

    // 녹화 없는(hasRecording == false) 세션의 NORMAL_END — 영상 없는 리포트라 멘트를 기다리지 않는다.
    // 녹화가 있는 경우의 «멘트 재생 완료 후 정지» 는 InterviewSessionRecordingTests 가 고정한다.
    @Test("녹화 없는 NORMAL_END 응답은 마무리 멘트 재생을 걸어두기만 하고 즉시 종료를 통보한다")
    func normalEndPlaysWrapUpFireAndForget() async {
        let played = LockIsolated<Data?>(nil)
        var initialState = InterviewSessionFeature.State.fixture(hasStarted: true)
        initialState.phase = .answering
        let store = TestStore(initialState: initialState) {
            InterviewSessionFeature()
        } withDependencies: {
            $0.ignoreHeldSessionSave()
            $0.speechClient.answerAudio = { nil }
            $0.speechClient.play = { data in
                played.setValue(data)
                return AsyncStream { _ in }   // 끝나지 않는 재생 — 종료 통보가 완료를 기다리면 테스트가 멈춘다
            }
            $0.interviewClient.submitAnswer = { _, _ in .ended(.normalEnd, wrapUp: "bXAz") }
        }

        await store.send(.view(.userTappedAnswerComplete)) {
            $0.phase = .processingAnswer
            $0.isSubmitting = true
        }
        await store.receive(\.inner.answerSubmitted) {
            $0.isSubmitting = false
            $0.isFinishing = true   // 녹화 없는 종료 — 리포트 대기 인디케이터가 여기서 선다
        }
        await store.receive(\.delegate.finished)
        await store.finish()   // fire-and-forget 이라 재생 완료 없이도 effect 가 남지 않는다
        #expect(played.value == Data("mp3".utf8))
    }

    @Test("STT_RESET 응답은 음성 인식 실패를 통보한다 — 서버 판정(이용권 환불·리포트 없음)")
    func sttResetNotifiesSpeechRecognitionFailure() async {
        var initialState = InterviewSessionFeature.State.fixture(hasStarted: true)
        initialState.phase = .answering
        let store = TestStore(initialState: initialState) {
            InterviewSessionFeature()
        } withDependencies: {
            $0.ignoreHeldSessionSave()
            $0.speechClient.answerAudio = { nil }
            $0.interviewClient.submitAnswer = { _, _ in .ended(.sttReset) }
        }

        await store.send(.view(.userTappedAnswerComplete)) {
            $0.phase = .processingAnswer
            $0.isSubmitting = true
        }
        await store.receive(\.inner.answerSubmitted) {
            $0.isSubmitting = false
        }
        await store.receive(\.delegate.failed, .speechRecognition)
    }

    @Test("503 은 1초·3초 백오프로 같은 제출을 재시도하고 성공하면 이어간다")
    func serverBusyRetriesWithBackoff() async {
        let clock = TestClock()
        let attempts = LockIsolated(0)
        var initialState = InterviewSessionFeature.State.fixture(hasStarted: true)
        initialState.phase = .answering
        let store = TestStore(initialState: initialState) {
            InterviewSessionFeature()
        } withDependencies: {
            $0.ignoreHeldSessionSave()
            $0.continuousClock = clock
            $0.speechClient.answerAudio = { nil }
            $0.interviewClient.submitAnswer = { _, _ in
                let attempt = attempts.withValue { $0 += 1; return $0 }
                guard attempt >= 3 else { throw InterviewError.aiTemporarilyUnavailable }
                return .ended(.normalEnd)
            }
        }

        await store.send(.view(.userTappedAnswerComplete)) {
            $0.phase = .processingAnswer
            $0.isSubmitting = true
        }
        await clock.advance(by: .seconds(1))   // 1차 백오프
        await clock.advance(by: .seconds(3))   // 2차 백오프
        await store.receive(\.inner.answerSubmitted) {
            $0.isSubmitting = false
            $0.isFinishing = true   // 녹화 없는 종료 — 리포트 대기 인디케이터가 여기서 선다
        }
        await store.receive(\.delegate.finished)
        #expect(attempts.value == 3)
    }

    @Test("503 재시도가 소진되면 네트워크 오버레이로 넘어가고 실패한 제출을 그대로 보관한다")
    func serverBusyRetryExhaustionPresentsOverlay() async {
        let clock = TestClock()
        let attempts = LockIsolated(0)
        var initialState = InterviewSessionFeature.State.fixture(hasStarted: true)
        initialState.phase = .answering
        let store = TestStore(initialState: initialState) {
            InterviewSessionFeature()
        } withDependencies: {
            $0.ignoreHeldSessionSave()
            $0.continuousClock = clock
            $0.speechClient.answerAudio = { nil }
            $0.interviewClient.submitAnswer = { _, _ in
                attempts.withValue { $0 += 1 }
                throw InterviewError.aiTemporarilyUnavailable
            }
        }

        await store.send(.view(.userTappedAnswerComplete)) {
            $0.phase = .processingAnswer
            $0.isSubmitting = true
        }
        await clock.advance(by: .seconds(1))
        await clock.advance(by: .seconds(3))
        await store.receive(\.inner.answerSubmissionFailed) {
            $0.isSubmitting = false
            // 소진은 delegate 승격이 아니라 세션 소유 오버레이다 — 실패한 payload 를 그대로 들고 재개를 기다린다.
            $0.failure = InterviewFailureFeature.State(kind: .network)
            $0.pendingRetry = .submit(AnswerSubmission(questionId: 1, isWrapUp: false))
        }
        #expect(attempts.value == 3)
    }

    @Test("이미 종료된 세션(409) 제출은 실패가 아니라 정상 종료로 넘어간다")
    func sessionAlreadyEndedRoutesToFinished() async {
        var initialState = InterviewSessionFeature.State.fixture(hasStarted: true)
        initialState.phase = .answering
        let store = TestStore(initialState: initialState) {
            InterviewSessionFeature()
        } withDependencies: {
            $0.ignoreHeldSessionSave()
            $0.speechClient.answerAudio = { nil }
            $0.interviewClient.submitAnswer = { _, _ in throw InterviewError.sessionAlreadyEnded }
        }

        await store.send(.view(.userTappedAnswerComplete)) {
            $0.phase = .processingAnswer
            $0.isSubmitting = true
        }
        await store.receive(\.inner.answerSubmissionFailed) {
            $0.isSubmitting = false
            $0.isFinishing = true   // 녹화 없는 종료 — 리포트 대기 인디케이터가 여기서 선다
        }
        await store.receive(\.delegate.finished)
    }

    @Test("8:45 경과 후 제출은 isWrapUp=true 를 싣는다")
    func wrapUpFlagAfterThreshold() async {
        let captured = LockIsolated<AnswerSubmission?>(nil)
        var initialState = InterviewSessionFeature.State.fixture(hasStarted: true)
        initialState.phase = .answering
        initialState.elapsedSeconds = InterviewSessionFeature.wrapUpThresholdSeconds + 1
        let store = TestStore(initialState: initialState) {
            InterviewSessionFeature()
        } withDependencies: {
            $0.ignoreHeldSessionSave()
            $0.speechClient.answerAudio = { nil }
            $0.interviewClient.submitAnswer = { _, submission in
                captured.setValue(submission)
                return .ended(.normalEnd)
            }
        }

        await store.send(.view(.userTappedAnswerComplete)) {
            $0.phase = .processingAnswer
            $0.isSubmitting = true
        }
        await store.receive(\.inner.answerSubmitted) {
            $0.isSubmitting = false
            $0.isFinishing = true   // 녹화 없는 종료 — 리포트 대기 인디케이터가 여기서 선다
        }
        await store.receive(\.delegate.finished)
        #expect(captured.value?.isWrapUp == true)
    }

    @Test("제출 중 답변 완료 재탭은 무시된다 — 중복 제출 가드")
    func duplicateAnswerCompleteIgnoredWhileSubmitting() async {
        var initialState = InterviewSessionFeature.State.fixture(hasStarted: true)
        initialState.phase = .answering
        initialState.isSubmitting = true
        let store = TestStore(initialState: initialState) {
            InterviewSessionFeature()
        }

        await store.send(.view(.userTappedAnswerComplete))   // 상태 무변화·effect 없음
    }

    @Test("마치기는 확인 모달을 닫고 MANUAL_END 를 제출해 응답으로 종료한다")
    func finishConfirmationSubmitsManualEnd() async {
        let captured = LockIsolated<AnswerSubmission?>(nil)
        var initialState = InterviewSessionFeature.State.fixture(hasStarted: true)
        initialState.phase = .answering
        initialState.isExitAvailable = true
        initialState.isExitConfirmPresented = true
        initialState.elapsedSeconds = 500
        initialState.answerStartedAt = 490
        let store = TestStore(initialState: initialState) {
            InterviewSessionFeature()
        } withDependencies: {
            $0.ignoreHeldSessionSave()
            $0.speechClient.answerAudio = { nil }
            $0.interviewClient.submitAnswer = { _, submission in
                captured.setValue(submission)
                return .ended(.manualEnd)
            }
        }

        await store.send(.view(.userTappedFinishInterview)) {
            $0.isExitConfirmPresented = false
            $0.phase = .processingAnswer
            $0.isSubmitting = true
        }
        await store.receive(\.inner.answerSubmitted) {
            $0.isSubmitting = false
            $0.isFinishing = true   // 녹화 없는 종료 — 리포트 대기 인디케이터가 여기서 선다
        }
        await store.receive(\.delegate.finished)
        #expect(captured.value?.endType == .manualEnd)
    }

    @Test("제출 비행 중 12:00 도달은 응답의 새 질문을 열지 않고 HARD_CAP 으로 마감한다")
    func hardCapDuringInFlightSubmissionFinalizes() async {
        let captured = LockIsolated<AnswerSubmission?>(nil)
        var initialState = InterviewSessionFeature.State.fixture(hasStarted: true)
        initialState.phase = .processingAnswer
        initialState.isSubmitting = true
        initialState.elapsedSeconds = InterviewSessionFeature.hardCapSeconds - 1
        let store = TestStore(initialState: initialState) {
            InterviewSessionFeature()
        } withDependencies: {
            $0.ignoreHeldSessionSave()
            $0.speechClient.answerAudio = { nil }
            $0.interviewClient.submitAnswer = { _, submission in
                captured.setValue(submission)
                return .ended(.hardCap)
            }
        }

        await store.send(.inner(.clockTicked)) {
            $0.elapsedSeconds = InterviewSessionFeature.hardCapSeconds
            $0.hardCapReachedWhileSubmitting = true
        }
        // 비행 중이던 제출이 다음 질문으로 풀렸다 — 초읽기 상황이라 재생 대신 즉시 마감한다.
        await store.send(.inner(.answerSubmitted(.next(13)))) {
            $0.currentQuestion = InterviewSessionFeature.ActiveQuestion(questionId: 13, turnLevel: 1, isLast: false)
        }
        await store.receive(\.inner.answerSubmitted) {
            $0.isSubmitting = false
            $0.isFinishing = true   // 녹화 없는 종료 — 리포트 대기 인디케이터가 여기서 선다
        }
        await store.receive(\.delegate.finished)
        #expect(captured.value?.endType == .hardCap)
        #expect(captured.value?.questionId == 13)
    }

    @Test("중도 이탈 경고를 띄운 채 8분을 넘기면 경고가 닫히고 해금 안내로 대체된다")
    func earlyExitWarningClosesAtExitUnlock() async {
        let clock = TestClock()
        let store = TestStore(initialState: .fixture()) {
            InterviewSessionFeature()
        } withDependencies: {
            $0.ignoreHeldSessionSave()
            $0.continuousClock = clock
            $0.recordingClient.startPreview = { nil }
            $0.recordingClient.startRecording = { _, _ in 0 }
            $0.recordingClient.stopRecording = { _ in .stub }
            $0.speechClient.startCapture = { AsyncStream { $0.finish() } }
            $0.speechClient.playStream = { _, _ in finishedPlayback() }
            $0.speechClient.startSessionAudioRecording = {}
            $0.speechClient.finishSessionAudioRecording = { .stub }
            $0.speechClient.stopCapture = {}
            $0.speechClient.setSessionAudioMuted = { _ in }
            $0.speechClient.startAnswerRecording = {}
            $0.speechClient.answerAudio = { nil }
            $0.interviewClient.questionAudioStream = stubAudioStream
            $0.interviewClient.submitAnswer = { _, _ in .ended(.manualEnd) }
        }
        store.exhaustivity = .off

        await store.send(.view(.onAppear))
        await store.receive(\.inner.recordingStarted)
        await clock.advance(by: .seconds(479))   // 7:59
        await store.skipReceivedActions()

        await store.send(.view(.userTappedClose))
        #expect(store.state.isEarlyExitWarningPresented)

        await clock.advance(by: .seconds(1))     // 8:00 해금
        await store.skipReceivedActions()
        #expect(store.state.isExitAvailable)
        #expect(!store.state.isEarlyExitWarningPresented)   // 차감 경고 문구가 거짓이 되는 시점
        #expect(store.state.toast == .exitUnlocked)

        await store.send(.view(.userTappedFinishInterview))   // MANUAL_END 제출 → 세션 정리
        await store.finish()
    }
}

// 실녹화 시작 배선을 고정한다 — 타임라인 0점, 시작 실패 폴백(영상 없는 리포트), 마무리 멘트 구간 계측.
@MainActor
struct InterviewSessionRecordingTests {
    @Test("녹화 시작 실패면 영상 없이 진행되고 종료 delegate 에 ref 가 없다")
    func recordingStartFailureProceedsWithoutVideo() async {
        let store = TestStore(initialState: .fixture()) {
            InterviewSessionFeature()
        } withDependencies: {
            $0.ignoreHeldSessionSave()
            $0.continuousClock = TestClock()
            $0.recordingClient.startPreview = { nil }
            $0.recordingClient.startRecording = { _, _ in throw RecordingError.startFailed("스텁") }
            $0.speechClient.startCapture = { AsyncStream { $0.finish() } }
            $0.speechClient.playStream = { _, _ in finishedPlayback() }
            $0.speechClient.setSessionAudioMuted = { _ in }
            $0.speechClient.startAnswerRecording = {}
            $0.speechClient.answerAudio = { nil }
            $0.interviewClient.questionAudioStream = stubAudioStream
            $0.interviewClient.submitAnswer = { _, _ in .ended(.normalEnd) }
        }
        // 세션 오디오 기록·정지+합성은 스텁하지 않는다 — 불리면 unimplemented 가 잡는다.
        store.exhaustivity = .off

        await store.send(.view(.onAppear))
        await store.receive(\.inner.recordingStarted) {
            $0.hasRecording = false
            $0.questionAudioStartedAt = 0
        }
        await store.receive(\.inner.questionPlaybackFinished)
        await store.send(.view(.userTappedAnswerComplete))
        await store.receive({ action in
            guard case let .delegate(.finished(ref, wrapUp)) = action else { return false }
            return ref == nil && wrapUp == nil
        })
    }

    @Test("마무리 멘트 재생 구간을 계측해 정지 후 ref 와 함께 통보한다")
    func wrapUpSpanMeasuredThenStops() async {
        let clock = TestClock()
        let ref = RecordingRef(sessionId: 7, fileURL: URL(fileURLWithPath: "/tmp/v.mp4"), durationSeconds: 60)
        let sessionAudio = SessionAudioRecording(fileURL: URL(fileURLWithPath: "/tmp/s.m4a"), startedAtHostSeconds: 12.5)
        let stopArgs = LockIsolated<(URL?, Double?)?>(nil)
        // 재생 종료 시점을 테스트가 쥔다 — 그 사이 흐른 시계가 곧 계측 구간이 된다.
        let wrapUpPlayback = AsyncStream<PlaybackEvent>.makeStream()
        let store = TestStore(initialState: .fixture()) {
            InterviewSessionFeature()
        } withDependencies: {
            $0.ignoreHeldSessionSave()
            $0.continuousClock = clock
            $0.recordingClient.startPreview = { nil }
            $0.recordingClient.startRecording = { _, _ in 0 }
            $0.recordingClient.stopRecording = { audio in
                stopArgs.setValue((audio?.fileURL, audio?.startedAtHostSeconds))
                return ref
            }
            $0.speechClient.startCapture = { AsyncStream { $0.finish() } }
            $0.speechClient.playStream = { _, _ in finishedPlayback() }
            $0.speechClient.play = { _ in wrapUpPlayback.stream }
            $0.speechClient.startSessionAudioRecording = {}
            $0.speechClient.finishSessionAudioRecording = { sessionAudio }
            $0.speechClient.stopCapture = {}
            $0.speechClient.setSessionAudioMuted = { _ in }
            $0.speechClient.startAnswerRecording = {}
            $0.speechClient.answerAudio = { nil }
            $0.interviewClient.questionAudioStream = stubAudioStream
            $0.interviewClient.submitAnswer = { _, _ in .ended(.normalEnd, wrapUp: "bXAz") }
        }
        store.exhaustivity = .off

        await store.send(.view(.onAppear))
        await store.receive(\.inner.recordingStarted)
        await store.receive(\.inner.questionPlaybackFinished)
        await store.send(.view(.userTappedAnswerComplete))
        await store.receive(\.inner.answerSubmitted) {
            $0.isWrappingUp = true
            $0.wrapUpStartedAt = 0
        }
        // 멘트가 3초 재생되는 동안 시계는 계측용으로 계속 돈다 — 구간 끝은 그때의 세션 시계다.
        await clock.advance(by: .seconds(3))
        await store.skipReceivedActions()
        #expect(store.state.elapsedSeconds == 3)

        wrapUpPlayback.continuation.yield(.finished)
        await store.receive(\.inner.wrapUpPlaybackFinished) {
            $0.isWrappingUp = false
            $0.wrapUpSpan = InterviewVideoWrapUpSpan(wrapUpStartSec: 0, wrapUpEndSec: 3)
        }
        await store.receive({ action in
            guard case let .delegate(.finished(stoppedRef, wrapUp)) = action else { return false }
            return stoppedRef == ref && wrapUp == InterviewVideoWrapUpSpan(wrapUpStartSec: 0, wrapUpEndSec: 3)
        })
        // 세션 오디오 마감 산출물이 그대로 합성 입력으로 넘어간다(립싱크 오프셋 포함).
        #expect(stopArgs.value?.0 == sessionAudio.fileURL)
        #expect(stopArgs.value?.1 == sessionAudio.startedAtHostSeconds)
        await store.finish()
    }

    @Test("HARD_CAP 마감의 마무리 멘트도 구간이 계측된다 — 취소됐던 시계를 계측용으로 되돌린다")
    func hardCapWrapUpRestartsClockForMeasurement() async {
        let clock = TestClock()
        let wrapUpPlayback = AsyncStream<PlaybackEvent>.makeStream()
        var initialState = InterviewSessionFeature.State.fixture(hasStarted: true)
        initialState.hasRecording = true
        initialState.phase = .answering
        initialState.elapsedSeconds = InterviewSessionFeature.hardCapSeconds - 1
        let store = TestStore(initialState: initialState) {
            InterviewSessionFeature()
        } withDependencies: {
            $0.ignoreHeldSessionSave()
            $0.continuousClock = clock
            $0.recordingClient.stopRecording = { _ in .stub }
            $0.speechClient.setSessionAudioMuted = { _ in }
            $0.speechClient.play = { _ in wrapUpPlayback.stream }
            $0.speechClient.finishSessionAudioRecording = { .stub }
            $0.speechClient.stopCapture = {}
            $0.speechClient.answerAudio = { nil }
            $0.interviewClient.submitAnswer = { _, _ in .ended(.hardCap, wrapUp: "bXAz") }
        }
        store.exhaustivity = .off

        await store.send(.inner(.clockTicked))   // 12:00 — 시계를 끊고 HARD_CAP 을 제출한다
        await store.receive(\.inner.answerSubmitted) {
            $0.isWrappingUp = true
            $0.wrapUpStartedAt = InterviewSessionFeature.hardCapSeconds
        }
        // 되살아난 시계가 계측만 한다 — 상한 로직이 다시 걸리면 제출이 반복돼 잡힌다.
        await clock.advance(by: .seconds(3))
        await store.skipReceivedActions()
        #expect(store.state.elapsedSeconds == InterviewSessionFeature.hardCapSeconds + 3)

        wrapUpPlayback.continuation.yield(.finished)
        await store.receive(\.inner.wrapUpPlaybackFinished) {
            $0.isWrappingUp = false
            $0.wrapUpSpan = InterviewVideoWrapUpSpan(
                wrapUpStartSec: Double(InterviewSessionFeature.hardCapSeconds),
                wrapUpEndSec: Double(InterviewSessionFeature.hardCapSeconds + 3)
            )
        }
        await store.receive(\.inner.recordingStopped)
        await store.receive(\.delegate.finished)
        await store.finish()
    }

    // 세션 오디오 기록은 캡처 엔진이 세팅하는 tap 포맷을 전제로 한다 — 먼저 열리면 조용히 무시돼
    // finish 가 늘 nil 이 되고 모든 세션이 «영상 없는 리포트» 로 수렴한다. 순서를 코드가 아니라 여기서 못 박는다.
    @Test("세션 오디오 기록은 마이크 캡처가 선 다음에 열린다", .timeLimit(.minutes(1)))
    func sessionAudioOpensAfterCaptureEngine() async {
        let calls = AsyncStream<String>.makeStream()
        let store = TestStore(initialState: .fixture()) {
            InterviewSessionFeature()
        } withDependencies: {
            $0.ignoreHeldSessionSave()
            $0.continuousClock = TestClock()
            $0.recordingClient.startPreview = { nil }
            $0.recordingClient.startRecording = { _, _ in 0 }
            $0.speechClient.startCapture = {
                calls.continuation.yield("startCapture")
                return AsyncStream { $0.finish() }
            }
            $0.speechClient.startSessionAudioRecording = { calls.continuation.yield("startSessionAudioRecording") }
            $0.speechClient.playStream = { _, _ in finishedPlayback() }
            $0.speechClient.setSessionAudioMuted = { _ in }
            $0.speechClient.startAnswerRecording = {}
            $0.interviewClient.questionAudioStream = stubAudioStream
        }
        store.exhaustivity = .off

        await store.send(.view(.onAppear))
        await store.receive(\.inner.recordingStarted)
        var observed: [String] = []
        for await call in calls.stream {
            observed.append(call)
            if observed.count == 2 { break }
        }
        #expect(observed == ["startCapture", "startSessionAudioRecording"])
    }

    @Test("녹화 시작 실패면 세션 오디오도 열지 않는다 — 합성 입력 없이 기록만 남기지 않는다")
    func sessionAudioStaysClosedWhenRecordingFails() async {
        let sessionAudioOpened = LockIsolated(false)
        let store = TestStore(initialState: .fixture()) {
            InterviewSessionFeature()
        } withDependencies: {
            $0.ignoreHeldSessionSave()
            $0.continuousClock = TestClock()
            $0.recordingClient.startPreview = { nil }
            $0.recordingClient.startRecording = { _, _ in throw RecordingError.startFailed("스텁") }
            $0.speechClient.startCapture = { AsyncStream { $0.finish() } }
            $0.speechClient.startSessionAudioRecording = { sessionAudioOpened.setValue(true) }
            $0.speechClient.playStream = { _, _ in finishedPlayback() }
            $0.speechClient.setSessionAudioMuted = { _ in }
            $0.speechClient.startAnswerRecording = {}
            $0.interviewClient.questionAudioStream = stubAudioStream
        }
        store.exhaustivity = .off

        await store.send(.view(.onAppear))
        await store.receive(\.inner.recordingStarted)
        await store.receive(\.inner.questionPlaybackFinished)
        #expect(sessionAudioOpened.value == false)
    }
}
