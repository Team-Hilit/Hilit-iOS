//
//  InterviewSessionTestFixtures.swift
//  FeatureInterviewTests
//
//  Created by 서정원 on 26/08/06.
//

import ComposableArchitecture
import DomainInterviewInterface
import DomainRecordingInterface
import DomainSpeechInterface
import Foundation

@testable import FeatureInterviewImplementation

// 세션 리듀서 테스트 공용 픽스처 — 세션 스위트가 여러 파일로 나뉘어(파일당 1000행 SwiftLint 한계)
// 같은 스텁이 사본으로 갈라지지 않게 여기 한 곳에 둔다. 소비처: InterviewSessionAudioMuteTests.swift ·
// InterviewSessionFeatureTests.swift · InterviewSessionNetworkFailureTests.swift.

extension DependencyValues {
    /// 세션 시작(`recordingStarted`)이 보관값에 진행 길이를 저장하는 실배선을 삼킨다.
    /// 진행 길이 **자체**를 검증하는 테스트는 이걸 쓰지 않고 `save` 를 직접 잡는다.
    mutating func ignoreHeldSessionSave() {
        heldSessionStore.save = { _ in }
    }
}

extension InterviewSessionFeature.State {
    /// 표준 시작 상태 — sessionId 7, 요약 질문(questionId 1). summaryAudio 는 base64 mp3(없으면 스트림 폴백).
    static func fixture(hasStarted: Bool = false, summaryAudio: String? = nil) -> Self {
        var state = InterviewSessionFeature.State(
            sessionId: 7,
            summaryQuestion: SummaryQuestion(
                questionId: 1,
                ttsAudio: summaryAudio,
                turn: TurnInfo(turnLevel: 0, depthLevel: 0)
            )
        )
        state.hasStarted = hasStarted
        return state
    }
}

extension AbandonResult {
    /// 중단 응답 스텁 — 네트워크 단절 중단(이용권 환급). 값 자체를 검증하지 않는 테스트가
    /// 오버레이 «중단하기» 경로를 통과시키는 용도 (리듀서는 결과를 읽지 않는다 — 결과 무관 이탈).
    static let stub = AbandonResult(
        status: .abandoned,
        abandonCause: .networkDisconnect,
        ticketOutcome: .released,
        reportGenerating: false,
        endedAt: nil
    )
}

extension AnswerResult {
    /// 다음 질문 응답 — 세션 계속.
    static func next(_ questionId: Int) -> Self {
        AnswerResult(
            answerId: 1,
            nextQuestion: NextQuestion(questionId: questionId, isLast: false, turn: TurnInfo(turnLevel: 1, depthLevel: 1)),
            sessionEnded: false,
            wrapUpMessage: nil,
            endType: nil
        )
    }

    /// 세션 종료 응답 — endType 별 분기 검증용.
    static func ended(_ type: SessionEndType, wrapUp: String? = nil) -> Self {
        AnswerResult(
            answerId: nil,
            nextQuestion: nil,
            sessionEnded: true,
            wrapUpMessage: wrapUp.map(WrapUpMessage.init(ttsAudio:)),
            endType: type
        )
    }
}

extension RecordingRef {
    /// 합성 산출물 스텁 — 값 자체를 검증하지 않는 테스트가 정지 경로를 통과시키는 용도.
    static let stub = RecordingRef(
        sessionId: 7, fileURL: URL(fileURLWithPath: "/tmp/stub.mp4"), durationSeconds: 0
    )
}

extension SessionAudioRecording {
    /// 세션 오디오 마감 스텁 — 합성 입력이 있는 경로를 통과시키는 용도.
    static let stub = SessionAudioRecording(
        fileURL: URL(fileURLWithPath: "/tmp/stub.m4a"), startedAtHostSeconds: 0
    )
}

/// 즉시 완료되는 재생 스트림 — 재생 자체는 다른 계층(AudioPlaybackManager) 몫이라 이벤트만 흘린다.
func finishedPlayback() -> AsyncStream<PlaybackEvent> {
    AsyncStream {
        $0.yield(.finished)
        $0.finish()
    }
}

/// questionAudioStream 스텁 — 경로 조립만 흉내 낸다. (전역 함수는 캡처가 없어 @Sendable 로 승격된다)
func stubAudioStream(_ sessionId: Int, _ questionId: Int) -> InterviewAudioStream {
    InterviewAudioStream(url: URL(string: "stub://\(sessionId)/\(questionId)")!, headers: [:])
}
