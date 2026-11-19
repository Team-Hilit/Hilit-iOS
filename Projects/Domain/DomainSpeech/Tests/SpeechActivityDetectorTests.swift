//
//  SpeechActivityDetectorTests.swift
//  DomainSpeechTests
//
//  Created by 서정원 on 26/11/19.
//

import AVFoundation
import DomainSpeechInterface
import Testing

@testable import DomainSpeechImplementation

// «답변 완료하기» 노출은 마이크 피크가 풀스케일의 8% 이상인 구간이 «연속 2번» 감지돼야 한다는 계약이다.
// 임계는 dBFS 가 아니라 진폭 비율이라 버퍼 없이 피크 값만으로 판정을 고정한다 — 실제 tap 은 같은 경로를 탄다.
// 마이크 하드웨어·AVAudioEngine 은 실기기 몫이고 여기선 순수 판정만 닫는다.
struct SpeechActivityDetectorTests {
    /// 0.125 = 2⁻³ — 이진 부동소수로 «정확히» 표현돼 8번 더하면 딱 1.0 이다(0.1 은 10번 더해도 0.9999… 라 1초 경계가 어긋난다).
    private static let bufferDuration: TimeInterval = 0.125
    private static let buffersPerSecond = 8

    @Test("8% 이상 구간이 연속 2번이어야 발화 시작이다 — 한 번만으로는 나오지 않는다")
    func speechStartsOnlyAfterTwoConsecutiveLoudBuffers() {
        let detector = listeningDetector()

        #expect(feed(detector, [0.5]).isEmpty)
        #expect(feed(detector, [0.5]) == [.speechStarted])
    }

    @Test("중간에 8% 미만 구간이 끼면 연속 카운트를 처음부터 센다")
    func quietBufferBreaksTheStreak() {
        let detector = listeningDetector()

        #expect(feed(detector, [0.5, 0.01, 0.5]).isEmpty)
        #expect(feed(detector, [0.5]) == [.speechStarted])
    }

    @Test("경계 — 피크가 정확히 8% 면 시끄러운 구간이고, 그 아래는 아니다")
    func eightPercentBoundaryIsInclusive() {
        #expect(feed(listeningDetector(), [0.08, 0.08]) == [.speechStarted])
        #expect(feed(listeningDetector(), [0.0799, 0.0799]).isEmpty)
    }

    @Test("판정 게이트가 닫혀 있으면 아무리 시끄러워도 발화 이벤트가 없다 — AI 발화 에코 차단")
    func closedGateEmitsNoSpeechEvents() {
        let detector = SpeechActivityDetector()

        #expect(feed(detector, [0.9, 0.9, 0.9]).isEmpty)
    }

    @Test("게이트를 다시 열면 직전 연속 카운트·발화 상태가 비워진다 — 질문마다 처음부터")
    func startListeningResetsState() {
        let detector = listeningDetector()
        _ = feed(detector, [0.5])   // 연속 1회까지 쌓음

        detector.startListening()

        #expect(feed(detector, [0.5]).isEmpty)   // 쌓아 둔 1회가 이어 붙지 않는다
        #expect(feed(detector, [0.5]) == [.speechStarted])
    }

    @Test("발화 중 게이트를 닫았다 열면 발화가 다시 시작된다 — 이전 질문의 발화 상태를 끌고 가지 않는다")
    func reopeningGateAllowsSpeechStartedAgain() {
        let detector = listeningDetector()
        #expect(feed(detector, [0.5, 0.5]) == [.speechStarted])

        detector.stopListening()
        detector.startListening()

        #expect(feed(detector, [0.5, 0.5]) == [.speechStarted])
    }

    @Test("발화 중 피크가 3% 미만으로 1초 지속되면 발화 종료다")
    func speechEndsAfterOneSecondBelowSilenceAmplitude() {
        let detector = listeningDetector()
        _ = feed(detector, [0.5, 0.5])

        // 0.125초 × 7 = 0.875초 — 아직 종료가 아니다.
        #expect(feed(detector, Array(repeating: 0.01, count: Self.buffersPerSecond - 1)).isEmpty)
        #expect(feed(detector, [0.01]) == [.speechEnded])
    }

    @Test("침묵이 1초 차기 전에 3% 이상이 한 번이라도 오면 침묵 시간을 처음부터 잰다")
    func louderBufferRestartsSilenceHold() {
        let detector = listeningDetector()
        _ = feed(detector, [0.5, 0.5])
        _ = feed(detector, Array(repeating: 0.01, count: Self.buffersPerSecond - 1))

        #expect(feed(detector, [0.03]).isEmpty)   // 3% «이상» 은 침묵이 아니다 — 카운트 리셋
        #expect(feed(detector, Array(repeating: 0.01, count: Self.buffersPerSecond - 1)).isEmpty)
        #expect(feed(detector, [0.01]) == [.speechEnded])
    }

    @Test("발화 종료 뒤 다시 연속 2번 시끄러우면 발화 시작이 또 나온다")
    func speechCanStartAgainAfterEnding() {
        let detector = listeningDetector()
        _ = feed(detector, [0.5, 0.5])
        #expect(feed(detector, Array(repeating: 0.0, count: Self.buffersPerSecond)) == [.speechEnded])

        #expect(feed(detector, [0.5, 0.5]) == [.speechStarted])
    }

    @Test("레벨은 1초 윈도의 피크를 dBFS 로 방출한다 — 임계와 같은 피크 기준이라 로그로 바로 비교된다")
    func levelEventCarriesWindowPeakInDecibels() throws {
        let detector = SpeechActivityDetector()   // 게이트가 닫혀도 레벨 로그는 흐른다

        let events = [0.0, 0.5, 0.1, 0.0, 0.0, 0.0, 0.0, 0.0].flatMap {
            detector.process(peak: Float($0), duration: Self.bufferDuration)
        }

        let level = try #require(events.compactMap { event -> Float? in
            if case let .level(decibels) = event { return decibels }
            return nil
        }.first)
        #expect(abs(level - (-6.0206)) < 0.01)   // 20·log10(0.5)
    }

    @Test("임계의 dBFS 환산 — 8% ≈ −21.9, 3% ≈ −30.5")
    func thresholdsMatchTheirDecibelEquivalents() {
        let start = SpeechActivityDetector.decibels(fromAmplitude: SpeechActivityDetector.speechStartAmplitude)
        let silence = SpeechActivityDetector.decibels(fromAmplitude: SpeechActivityDetector.silenceAmplitude)

        #expect(abs(start - (-21.9)) < 0.1)
        #expect(abs(silence - (-30.5)) < 0.1)
        #expect(SpeechActivityDetector.decibels(fromAmplitude: 0) == SpeechActivityDetector.silenceFloor)
    }

    @Test("버퍼에서 피크를 뽑는다 — 전 채널의 최대 «절댓값» (음수 샘플 포함)")
    func peakIsMaxAbsoluteSampleAcrossChannels() throws {
        let detector = listeningDetector()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))

        // 채널 0 은 조용(0.02), 채널 1 에 음수 큰 샘플(−0.5) — 채널 0 만 보거나 부호를 보면 놓친다.
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        buffer.frameLength = 4_800
        let channels = try #require(buffer.floatChannelData)
        for index in 0..<4_800 {
            channels[0][index] = 0.02
            channels[1][index] = 0.02
        }
        channels[1][100] = -0.5

        #expect(detector.process(buffer).isEmpty)
        #expect(detector.process(buffer) == [.speechStarted])
    }

    // MARK: - Helpers

    private func listeningDetector() -> SpeechActivityDetector {
        let detector = SpeechActivityDetector()
        detector.startListening()
        return detector
    }

    /// 같은 길이(0.125초)의 구간을 피크 값 순서대로 흘려 보내고, 나온 «발화» 이벤트를 이어 붙여 돌려준다.
    /// 1초마다 끼는 level 로그는 거른다 — 발화 판정 단언이 로그 주기에 흔들리지 않게(level 은 전용 테스트가 본다).
    private func feed(_ detector: SpeechActivityDetector, _ peaks: [Float]) -> [SpeechCaptureEvent] {
        peaks.flatMap { detector.process(peak: $0, duration: Self.bufferDuration) }
            .filter { if case .level = $0 { false } else { true } }
    }
}
