//
//  InterviewSessionAnswerButtonTests.swift
//  FeatureInterviewTests
//
//  Created by 서정원 on 26/11/19.
//

import ComposableArchitecture
import DomainInterviewInterface
import DomainRecordingInterface
import DomainSpeechInterface
import Foundation
import Testing

@testable import FeatureInterviewImplementation

// «답변 완료하기» 노출 게이팅을 고정한다 — 질문 TTS 가 끝났다고 바로 나오지 않고, 이번 답변 턴에서 사용자
// 발화가 감지돼야(진폭 8% 이상 연속 2버퍼 — 판정 자체는 DomainSpeech `SpeechActivityDetectorTests`) 나타난다.
// 마이크가 죽어 감지가 불가능하면 상시 노출로 돌린다(갇힘 방지). 버튼의 실제 렌더링은 순수 UI 라 프리뷰 육안 검증.
// 픽스처는 InterviewSessionTestFixtures.swift 공용.
@MainActor
struct InterviewSessionAnswerButtonTests {
    @Test("진입 직후엔 감지된 발화가 없어 버튼 조건이 꺼져 있다")
    func buttonIsHiddenBeforeAnySpeech() {
        #expect(!InterviewSessionFeature.State.fixture().canCompleteAnswer)
    }

    @Test("답변 중 발화가 감지되면 버튼 조건이 켜진다")
    func speechDetectedWhileAnsweringEnablesButton() async {
        var initialState = InterviewSessionFeature.State.fixture(hasStarted: true)
        initialState.phase = .answering
        let store = TestStore(initialState: initialState) {
            InterviewSessionFeature()
        }

        await store.send(.inner(.speechDetected)) {
            $0.hasDetectedSpeech = true
        }
        #expect(store.state.canCompleteAnswer)
    }

    @Test("질문 듣는 중(asking)에 도착한 발화 감지는 무시한다 — 답변 구간 밖 잔광")
    func speechDetectedWhileAskingIsIgnored() async {
        let store = TestStore(initialState: .fixture(hasStarted: true)) {
            InterviewSessionFeature()
        }

        await store.send(.inner(.speechDetected))   // 상태 무변화
        #expect(!store.state.canCompleteAnswer)
    }

    @Test("답변 진입(질문 재생 완료)마다 감지 상태를 비운다 — 다음 질문 버튼은 그 턴 발화가 있어야 나온다")
    func answeringEntryResetsDetectedSpeech() async {
        var initialState = InterviewSessionFeature.State.fixture(hasStarted: true)
        initialState.hasDetectedSpeech = true   // 직전 턴에서 켜진 채 남은 값
        let store = TestStore(initialState: initialState) {
            InterviewSessionFeature()
        } withDependencies: {
            $0.speechClient.setSessionAudioMuted = { _ in }
            $0.speechClient.startAnswerRecording = {}
        }
        store.exhaustivity = .off   // 시간 마킹은 다른 테스트가 고정 — 여기선 리셋만 본다.

        await store.send(.inner(.questionPlaybackFinished))
        #expect(store.state.phase == .answering)
        #expect(!store.state.hasDetectedSpeech)
        #expect(!store.state.canCompleteAnswer)
    }

    @Test("마이크 캡처 시작 실패면 발화를 못 잡으니 버튼을 상시 노출한다 — 답변 진입이 되돌리지 않는다")
    func micCaptureFailureKeepsButtonAvailable() async {
        var initialState = InterviewSessionFeature.State.fixture(hasStarted: true)
        initialState.phase = .asking
        let store = TestStore(initialState: initialState) {
            InterviewSessionFeature()
        } withDependencies: {
            $0.speechClient.setSessionAudioMuted = { _ in }
            $0.speechClient.startAnswerRecording = {}
        }

        await store.send(.inner(.micCaptureFailed)) {
            $0.isMicCaptureFailed = true
        }
        #expect(store.state.canCompleteAnswer)

        store.exhaustivity = .off
        await store.send(.inner(.questionPlaybackFinished))
        #expect(store.state.canCompleteAnswer)   // hasDetectedSpeech 는 리셋돼도 폴백은 세션 수명 유지
    }

    @Test("캡처 스트림의 speechStarted 가 speechDetected 로 올라와 버튼 조건을 켠다")
    func captureStreamSpeechStartedReachesReducer() async {
        // answering 으로 시드 — 요약 질문 재생이 끝나도 questionPlaybackFinished 는 asking 에서만 받아 리셋이 없다.
        var initialState = InterviewSessionFeature.State.fixture()
        initialState.phase = .answering
        let store = TestStore(initialState: initialState) {
            InterviewSessionFeature()
        } withDependencies: {
            $0.ignoreHeldSessionSave()
            $0.continuousClock = TestClock()
            $0.recordingClient.startPreview = { nil }
            $0.recordingClient.startRecording = { _, _ in 0 }
            $0.speechClient.startCapture = {
                AsyncStream {
                    $0.yield(.speechStarted)
                    $0.finish()
                }
            }
            $0.speechClient.startSessionAudioRecording = {}
            $0.speechClient.setSessionAudioMuted = { _ in }
            $0.speechClient.playStream = { _, _ in finishedPlayback() }
            $0.interviewClient.questionAudioStream = stubAudioStream
        }
        store.exhaustivity = .off

        await store.send(.view(.onAppear))
        await store.receive(\.inner.recordingStarted)
        await store.receive(\.inner.speechDetected)
        #expect(store.state.hasDetectedSpeech)
    }

    @Test("캡처 스트림의 captureFailed 가 micCaptureFailed 로 올라온다")
    func captureStreamFailureReachesReducer() async {
        let store = TestStore(initialState: .fixture()) {
            InterviewSessionFeature()
        } withDependencies: {
            $0.ignoreHeldSessionSave()
            $0.continuousClock = TestClock()
            $0.recordingClient.startPreview = { nil }
            $0.recordingClient.startRecording = { _, _ in 0 }
            $0.speechClient.startCapture = {
                AsyncStream {
                    $0.yield(.captureFailed("권한 거부"))
                    $0.finish()
                }
            }
            $0.speechClient.startSessionAudioRecording = {}
            $0.speechClient.setSessionAudioMuted = { _ in }
            $0.speechClient.playStream = { _, _ in finishedPlayback() }
            $0.speechClient.startAnswerRecording = {}
            $0.interviewClient.questionAudioStream = stubAudioStream
        }
        store.exhaustivity = .off

        await store.send(.view(.onAppear))
        await store.receive(\.inner.recordingStarted)
        await store.receive(\.inner.micCaptureFailed)
        #expect(store.state.isMicCaptureFailed)
        #expect(store.state.canCompleteAnswer)
    }
}
