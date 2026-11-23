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
}
