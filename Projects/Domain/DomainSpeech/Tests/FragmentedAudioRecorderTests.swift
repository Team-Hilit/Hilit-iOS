//
//  FragmentedAudioRecorderTests.swift
//  DomainSpeechTests
//
//  Created by EunseoKim on 26/11/17.
//

import AVFoundation
import DomainSpeechInterface
import Testing

@testable import DomainSpeechImplementation

// 세션 전구간 오디오 기록기(HLT-78) — 앱이 기록 중에 죽어도 읽히는 것(조각 기록)과 첫 버퍼 시각 스탬프가 핵심이다.
// 무음 길이 보존 규칙은 TapFileRecorder 와 같다(같은 이유 — 파일 길이가 곧 립싱크다).
struct FragmentedAudioRecorderTests {
    private static let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    private static let framesPerBuffer: AVAudioFrameCount = 4_800   // 0.1초

    @Test("닫지 않은 채로도 읽힌다 — 기록 중에 앱이 죽어도 마지막 조각까지 산다", .timeLimit(.minutes(1)))
    func readableBeforeFinish() async throws {
        let url = Self.makeURL()
        let recorder = FragmentedAudioRecorder()
        defer { recorder.discard() }
        recorder.begin(url: url, format: Self.format)
        Self.feed(recorder, buffers: 30)   // 3초

        // 조각은 기록기가 비동기로 덧붙인다 — 닫지 않은 상태에서 읽힐 때까지 잠깐 기다린다.
        var readable: Double?
        for _ in 0..<50 where readable == nil {
            readable = try? await AVURLAsset(url: url).load(.duration).seconds
            if readable.map({ $0 <= 0 }) == true { readable = nil }
            if readable == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect((readable ?? 0) >= 1)
    }

    @Test("첫 버퍼 시각을 곧바로 스탬프 파일에 남긴다 — 닫기 전에 죽어도 립싱크 기준이 남는다")
    func writesStartStampOnFirstBuffer() throws {
        let url = Self.makeURL()
        let recorder = FragmentedAudioRecorder()
        defer { recorder.discard() }
        recorder.begin(url: url, format: Self.format)
        let hostTime = mach_absolute_time()
        recorder.write(Self.tone(), at: AVAudioTime(hostTime: hostTime))
        recorder.write(Self.tone(), at: AVAudioTime(hostTime: hostTime + 1_000_000))

        let raw = try String(contentsOf: SessionAudioRecording.startStampURL(for: url), encoding: .utf8)
        #expect(Double(raw) == AVAudioTime.seconds(forHostTime: hostTime))
    }

    @Test("무음 구간도 같은 길이를 기록한다 — 건너뛰면 이후 오디오가 통째로 앞으로 밀린다", .timeLimit(.minutes(1)))
    func mutedBuffersPreserveTimelineLength() async throws {
        let continuous = try await recordedSeconds(mutingFrom: nil)
        let halfMuted = try await recordedSeconds(mutingFrom: 5)
        #expect(abs(halfMuted - continuous) < 0.001)
        #expect(continuous >= 0.9)
    }

    @Test("버퍼 없이 끝난 기록은 nil 과 함께 파일·스탬프를 지운다", .timeLimit(.minutes(1)))
    func finishWithoutBuffersRemovesFiles() async throws {
        let url = Self.makeURL()
        let recorder = FragmentedAudioRecorder()
        recorder.begin(url: url, format: Self.format)
        #expect(await recorder.finishKeepingFile() == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: SessionAudioRecording.startStampURL(for: url).path))
    }

    @Test("discard 는 기록 중인 파일과 스탬프를 지운다")
    func discardRemovesFiles() {
        let url = Self.makeURL()
        let recorder = FragmentedAudioRecorder()
        recorder.begin(url: url, format: Self.format)
        Self.feed(recorder, buffers: 3)
        recorder.discard()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: SessionAudioRecording.startStampURL(for: url).path))
    }

    // MARK: - 헬퍼

    /// 1초(10 버퍼)를 흘리고 닫은 파일의 길이(초). `mutingFrom` 번째 버퍼부터 무음 — nil 이면 대조군.
    private func recordedSeconds(mutingFrom: Int?) async throws -> Double {
        let url = Self.makeURL()
        let recorder = FragmentedAudioRecorder()
        recorder.begin(url: url, format: Self.format)
        Self.feed(recorder, buffers: 10, mutingFrom: mutingFrom)
        let finished = try #require(await recorder.finishKeepingFile())
        defer {
            try? FileManager.default.removeItem(at: finished.0)
            try? FileManager.default.removeItem(at: SessionAudioRecording.startStampURL(for: finished.0))
        }
        return try await AVURLAsset(url: finished.0).load(.duration).seconds
    }

    /// tap 처럼 간격을 두고 버퍼를 흘린다 — 실시간 입력이라 몰아 넣으면 인코더가 준비 안 됨으로 버린다.
    private static func feed(_ recorder: FragmentedAudioRecorder, buffers: Int, mutingFrom: Int? = nil) {
        for index in 0..<buffers {
            if index == mutingFrom { recorder.setMuted(true) }
            recorder.write(tone(), at: AVAudioTime(hostTime: mach_absolute_time()))
            usleep(10_000)
        }
    }

    private static func makeURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("fragmented-recorder-\(UUID().uuidString).m4a")
    }

    /// 무음과 구분되는 입력 버퍼.
    private static func tone() -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerBuffer)!
        buffer.frameLength = framesPerBuffer
        let samples = buffer.floatChannelData![0]
        for frame in 0..<Int(framesPerBuffer) {
            samples[frame] = sin(Float(frame) * 0.05) * 0.5
        }
        return buffer
    }
}
