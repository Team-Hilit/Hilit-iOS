//
//  InterviewSessionResumeRecordingTests.swift
//  FeatureInterviewTests
//
//  Created by 서정원 on 26/11/23.
//

import ComposableArchitecture
import DomainInterviewInterface
import DomainRecordingInterface
import DomainSpeechInterface
import Foundation
import Testing

@testable import FeatureInterviewImplementation

// 앱이 죽었다 살아난 재개의 녹화 계약([[interview#Client 계약]]) — 재개 가능 여부는 서버가 정하지만 영상은 프로세스
// 메모리의 세그먼트 원장에 있어, 이어받을 수 없으면 영상 없이 진행한다. 그 경계의 두 값(재개 지점·진행 길이)을 고정한다.
@MainActor
struct InterviewSessionResumeRecordingTests {
    private static func resumeSeed(elapsed: Int) -> InterviewResumeSeed {
        InterviewResumeSeed(
            question: NextQuestion(questionId: 21, isLast: false, turn: TurnInfo(turnLevel: 2, depthLevel: 0)),
            approximateElapsedSeconds: elapsed
        )
    }

    // 재개 지점은 원장의 이어받기 판정(`SegmentLedger.canContinue`)의 재료다 — 처음 시작이 값을 실으면 빈 원장이
    // 거절하고, 재개가 nil 이면 앱이 죽어 원장이 비었어도 새 녹화가 열려 앞 영상을 지운다.
    @Test("처음 시작은 이어받을 지점 없이, 재개는 시드한 진행 길이로 녹화를 연다")
    func startRecordingCarriesResumePoint() async {
        let cases: [(InterviewSessionFeature.State, String)] = [
            (.fixture(), "7:nil"),
            (InterviewSessionFeature.State(sessionId: 7, resume: Self.resumeSeed(elapsed: 130)), "7:130")
        ]
        for (initialState, expected) in cases {
            let call = LockIsolated("")
            let store = TestStore(initialState: initialState) { InterviewSessionFeature() }
            store.exhaustivity = .off
            store.dependencies.continuousClock = TestClock()
            store.dependencies.recordingClient.startPreview = { nil }
            store.dependencies.recordingClient.startRecording = { sessionId, point in
                call.setValue("\(sessionId):\(point.map(String.init) ?? "nil")")
                return Double(point ?? 0)
            }
            store.dependencies.ignoreHeldSessionSave()
            store.dependencies.interviewClient.questionAudioStream = { stubAudioStream($0, $1) }
            store.dependencies.speechClient.setSessionAudioMuted = { _ in }
            store.dependencies.speechClient.playStream = { _, _ in AsyncStream { $0.finish() } }
            store.dependencies.speechClient.startCapture = { AsyncStream { $0.finish() } }
            store.dependencies.speechClient.startSessionAudioRecording = {}
            store.dependencies.speechClient.startAnswerRecording = {}

            await store.send(.view(.onAppear))
            await store.receive(\.inner.recordingStarted)
            #expect(call.value == expected)
        }
    }

    // 영상 없이 진행 중인 세션(앱이 죽었다 살아난 재개 포함)도 동결 때 진행 길이를 남겨야 한다 — 안 남기면
    // 다음 재개의 시계 시드가 옛 값이라 8분·12분 상한이 리셋되고, `startRecording` 의 이어받을 지점도 어긋난다.
    @Test("영상 없이 진행 중이던 세션의 동결은 시계 raw 축을 진행 길이로 남긴다")
    func freezeWithoutRecordingSavesClockProgress() async {
        var state = InterviewSessionFeature.State.fixture(hasStarted: true)
        state.hasRecording = false
        state.elapsedSeconds = 75
        let saved = LockIsolated<HeldSession?>(nil)
        let store = TestStore(initialState: state) {
            InterviewSessionFeature()
        } withDependencies: {
            $0.speechClient.finishSessionAudioRecording = { nil }
            $0.recordingClient.suspendRecording = { _ in nil }   // 진행 중인 녹화가 없다
            $0.speechClient.stopCapture = {}
            $0.heldSessionStore.save = { saved.setValue($0) }
        }

        await store.send(.view(.sceneBackgrounded)) {
            $0.isInterrupted = true
        }
        await store.receive(\.delegate.interrupted)
        await store.finish()
        #expect(saved.value == HeldSession(sessionId: state.sessionId, recordedSeconds: 75))
    }

    // 서버는 진행을 답변 제출로만 안다(주기 저장·하트비트 API 가 없다) — 재개는 «최신 턴 질문» 을 처음부터 다시 준다.
    // 녹화 시작·동결 때만 남기면 포그라운드에서 죽은 세션이 옛 값(새 세션이면 0초)으로 재개돼 8분 해금·12분 상한·
    // 8:45 마무리 판정(`isWrapUp` 은 클라 타이머 기준)이 리셋된다. 그래서 다음 질문이 열리는 턴 경계마다 남긴다.
    @Test("다음 질문 응답은 그 시점의 시계 raw 축을 진행 길이로 남긴다 — 포그라운드에서 죽어도 재개 시계가 턴 경계에서 이어진다")
    func nextQuestionSavesProgressAtTurnBoundary() async {
        var state = InterviewSessionFeature.State.fixture(hasStarted: true)
        state.phase = .processingAnswer
        state.isSubmitting = true
        state.elapsedSeconds = 135
        let saved = LockIsolated<HeldSession?>(nil)
        let store = TestStore(initialState: state) {
            InterviewSessionFeature()
        } withDependencies: {
            $0.heldSessionStore.save = { saved.setValue($0) }
            $0.interviewClient.questionAudioStream = stubAudioStream
            $0.speechClient.playStream = { _, _ in finishedPlayback() }
            $0.speechClient.setSessionAudioMuted = { _ in }
            $0.speechClient.startAnswerRecording = {}
        }

        await store.send(.inner(.answerSubmitted(.next(13)))) {
            $0.isSubmitting = false
            $0.phase = .asking
            $0.currentQuestion = InterviewSessionFeature.ActiveQuestion(questionId: 13, turnLevel: 1, isLast: false)
            $0.questionAudioStartedAt = 135
        }
        await store.receive(\.inner.questionPlaybackFinished) {
            $0.phase = .answering
            $0.questionAudioEndedAt = 135
            $0.answerStartedAt = 135
        }
        #expect(saved.value == HeldSession(sessionId: state.sessionId, recordedSeconds: 135))
    }

    @Test("종료 응답은 진행 길이를 남기지 않는다 — 끝난 세션의 장부를 되살리지 않는다")
    func endedAnswerDoesNotSaveProgress() async {
        var state = InterviewSessionFeature.State.fixture(hasStarted: true)
        state.phase = .processingAnswer
        state.isSubmitting = true
        state.elapsedSeconds = 135
        // heldSessionStore 미스텁 — 저장을 시도하면 unimplemented 가 잡는다.
        let store = TestStore(initialState: state) { InterviewSessionFeature() }

        await store.send(.inner(.answerSubmitted(.ended(.backExit)))) {
            $0.isSubmitting = false
        }
        await store.receive(\.delegate.aborted)
    }
}
