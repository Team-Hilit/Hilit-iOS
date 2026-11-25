//
//  InterviewSessionAudioMuteTests.swift
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

// AI 발화(질문 TTS·마무리 멘트) 구간의 세션 오디오 무음 토글을 고정한다 — 서버가 그 구간에 자체 TTS 를
// 합성하므로 스피커 에코가 남으면 이중 음성이 된다. 무음이 «재생 개시 이전» 에 걸리는 순서가 핵심이라
// 호출 순서를 배열로 못 박는다. 픽스처는 InterviewSessionTestFixtures.swift 공용,
// 세션 시계·턴 루프·녹화 배선은 InterviewSessionFeatureTests.swift.
@MainActor
struct InterviewSessionAudioMuteTests {
    @Test("질문 재생은 무음으로 열고 answering 진입에서 되살린다 — 다음 질문마다 반복")
    func questionPlaybackIsMutedAndAnsweringUnmutes() async {
        let calls = LockIsolated<[String]>([])
        let store = TestStore(initialState: .fixture()) {
            InterviewSessionFeature()
        } withDependencies: {
            $0.ignoreHeldSessionSave()
            $0.continuousClock = TestClock()
            $0.recordingClient.startPreview = { nil }
            $0.recordingClient.startRecording = { _, _ in 0 }
            $0.speechClient.startCapture = { AsyncStream { $0.finish() } }
            $0.speechClient.startSessionAudioRecording = {}
            $0.speechClient.setSessionAudioMuted = { muted in
                calls.withValue { $0.append(muted ? "mute" : "unmute") }
            }
            $0.speechClient.playStream = { _, _ in
                calls.withValue { $0.append("playStream") }
                return finishedPlayback()
            }
            $0.speechClient.startAnswerRecording = { calls.withValue { $0.append("startAnswerRecording") } }
            $0.speechClient.answerAudio = { nil }
            $0.interviewClient.questionAudioStream = stubAudioStream
            $0.interviewClient.submitAnswer = { _, _ in .next(13) }
        }
        store.exhaustivity = .off

        await store.send(.view(.onAppear))
        await store.receive(\.inner.recordingStarted)
        await store.receive(\.inner.questionPlaybackFinished)
        await store.send(.view(.userTappedAnswerComplete))
        await store.receive(\.inner.answerSubmitted)
        await store.receive(\.inner.questionPlaybackFinished)   // 두 번째 질문까지 재생됐다

        // 재생보다 mute 가, 답변 기록보다 unmute 가 먼저다 — 뒤집히면 그만큼 스피커 소리가 파일에 남는다.
        // 두 번째 answering 진입(unmute·기록)은 마지막 수신 이후라 앞 6개까지가 결정적으로 관찰된다.
        #expect(
            Array(calls.value.prefix(6))
                == ["mute", "playStream", "unmute", "startAnswerRecording", "mute", "playStream"]
        )
    }

    @Test("마무리 멘트도 무음 구간이다 — 재생 개시 전에 세션 오디오를 덮는다")
    func wrapUpPlaybackIsMuted() async {
        let calls = LockIsolated<[String]>([])
        var initialState = InterviewSessionFeature.State.fixture(hasStarted: true)
        initialState.hasRecording = true
        initialState.phase = .answering
        let store = TestStore(initialState: initialState) {
            InterviewSessionFeature()
        } withDependencies: {
            $0.ignoreHeldSessionSave()
            $0.continuousClock = TestClock()
            $0.recordingClient.stopRecording = { _ in .stub }
            $0.speechClient.setSessionAudioMuted = { muted in
                calls.withValue { $0.append(muted ? "mute" : "unmute") }
            }
            $0.speechClient.play = { _ in
                calls.withValue { $0.append("play") }
                return finishedPlayback()
            }
            $0.speechClient.finishSessionAudioRecording = { .stub }
            $0.speechClient.stopCapture = {}
            $0.speechClient.answerAudio = { nil }
            $0.interviewClient.submitAnswer = { _, _ in .ended(.normalEnd, wrapUp: "bXAz") }
        }
        store.exhaustivity = .off

        // 무음인 채로 재생이 끝나고 마감으로 이어진다 — 이후엔 기록 자체가 없어 해제할 것도 없다.
        await store.send(.view(.userTappedAnswerComplete))
        await store.receive(\.inner.wrapUpPlaybackFinished)
        await store.receive(\.inner.recordingStopped)
        await store.receive(\.delegate.finished)
        #expect(calls.value == ["mute", "play"])
    }
}
