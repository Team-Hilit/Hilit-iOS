//
//  FragmentedAudioRecorder.swift
//  DomainSpeechImplementation
//
//  Created by EunseoKim on 26/11/17.
//

import AVFoundation
import DomainSpeechInterface
import OSLog

// @lat: [[interview#음성 캡처]]
/// 세션 전구간 오디오 기록기 — `AVAssetWriter` 로 m4a(AAC)를 **조각(fragment) 단위**로 쓴다(HLT-78).
///
/// `AVAudioFile` 은 m4a 의 머리(moov)를 닫을 때 쓰므로, 기록 중에 앱이 죽으면 파일 전체를 못 연다
/// (2026-11-17 실측 — 강제 종료한 m4a 는 «Cannot Open»). 조각 기록은 주기마다 읽을 수 있는 조각을 덧붙여
/// 죽어도 마지막 조각까지 살고(비디오 `AVCaptureMovieFileOutput` 과 같은 원리), 합성의 passthrough 도 그대로 받는다.
/// 첫 버퍼 시각은 옆 파일(`SessionAudioRecording.startStampURL`)에 바로 남긴다 — 닫지 못하고 죽어도 립싱크 기준이 남는다.
///
/// tap 콜백(오디오 스레드)과 시작/종료(액터)가 만나는 지점이라 락으로 좁게 보호한다 (@unchecked 근거).
final class FragmentedAudioRecorder: @unchecked Sendable {
    /// 조각 주기 — 죽었을 때 잃는 꼬리의 상한이다.
    static let fragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
    private static let logger = Logger(subsystem: "com.hilit.speech", category: "session-audio")

    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var format: AVAudioFormat?
    private var formatDescription: CMAudioFormatDescription?
    private var url: URL?
    /// 첫 버퍼의 호스트시각(초) — 립싱크 오프셋 보정 기준(스펙 §①).
    private var firstBufferHostSeconds: Double?
    /// 지금까지 쓴 프레임 수 — 다음 버퍼의 표시 시각. 끊김 없이 이어 붙여 타임라인 = 벽시계를 지킨다.
    private var writtenFrames: Int64 = 0
    /// AI 발화(질문 TTS·마무리 멘트) 구간 — 입력 대신 같은 길이의 무음을 기록한다. 토글 소유는 세션 리듀서.
    private var isMuted = false
    /// 무음 버퍼 재사용 캐시 — tap 주기마다 할당하지 않으려고 들고 있는다.
    private var silenceBuffer: AVAudioPCMBuffer?

    /// 새 기록 시작 — 이전 기록이 남아 있으면 버린다. 실패하면 기록 없음(산출물 nil → 합성 스킵 폴백).
    func begin(url: URL, format: AVAudioFormat) {
        lock.lock()
        defer { lock.unlock() }
        writer?.cancelWriting()
        reset()
        Self.removeFiles(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .m4a) else { return }
        writer.movieFragmentInterval = Self.fragmentInterval
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount
        ])
        input.expectsMediaDataInRealTime = true
        var description: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: format.streamDescription, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description
        )
        guard let description, writer.canAdd(input) else { return }
        writer.add(input)
        guard writer.startWriting() else { return }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        self.input = input
        self.format = format
        self.formatDescription = description
        self.url = url
    }

    /// 무음 구간 토글 — 진행 중 기록에 즉시 반영된다. 기록 미시작이어도 플래그만 남고 무해하다.
    func setMuted(_ muted: Bool) {
        lock.lock()
        defer { lock.unlock() }
        isMuted = muted
    }

    func write(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime) {
        lock.lock()
        defer { lock.unlock() }
        guard let input, let format, let url, buffer.format == format else { return }
        // 스탬프는 소리 유무가 아니라 «타임라인이 언제 열렸나» 라서 무음 구간에서도 찍는다.
        if firstBufferHostSeconds == nil {
            let seconds = AVAudioTime.seconds(forHostTime: when.hostTime)
            firstBufferHostSeconds = seconds
            // 닫기 전에 죽어도 립싱크 기준이 남도록 즉시 쓴다 — 기록당 한 번, 수십 바이트.
            try? String(seconds).write(to: SessionAudioRecording.startStampURL(for: url), atomically: true, encoding: .utf8)
        }
        // 무음도 «같은 길이»를 기록한다 — 건너뛰면 파일이 벽시계보다 짧아져 이후 오디오가 통째로 앞으로 밀린다.
        let source = isMuted ? silence(frameLength: buffer.frameLength, format: format) : buffer
        let frames = Int64(buffer.frameLength)
        defer { writtenFrames += frames }
        // 준비 안 됨(인코더 밀림)이면 이 버퍼만 버린다 — 표시 시각은 그래도 전진해 뒤 오디오가 당겨지지 않는다.
        guard let source, input.isReadyForMoreMediaData, let sample = sampleBuffer(from: source) else { return }
        input.append(sample)
    }

    /// 기록을 닫고 (파일 URL, 첫 버퍼 시각) 반환 — 파일은 유지(합성부가 삭제). 기록 없음·실패는 nil(파일도 지운다).
    func finishKeepingFile() async -> (URL, Double)? {
        lock.lock()
        let writer = writer
        let input = input
        let url = url
        let startedAt = firstBufferHostSeconds
        reset()
        lock.unlock()
        guard let writer, let url else { return nil }
        guard let startedAt else {
            // 버퍼를 한 번도 못 받은 기록 — 넘길 산출물이 없으니 여기서 지운다(밖에선 URL 을 모른다).
            writer.cancelWriting()
            Self.removeFiles(at: url)
            return nil
        }
        input?.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            // 백그라운드 진입과 겹치면 마무리가 중단 오류로 실패할 수 있다 — 조각 기록이라 그때까지 쓴 부분은
            // 읽힌다. 지우면 그 구간이 통째로 무음이 되니, 읽히면 산출물로 넘기고 못 읽을 때만 지운다.
            Self.logger.error("세션 오디오 마무리 실패: status \(writer.status.rawValue), \(String(describing: writer.error))")
            guard let seconds = try? await AVURLAsset(url: url).load(.duration).seconds, seconds.isFinite, seconds > 0 else {
                Self.removeFiles(at: url)
                return nil
            }
            return (url, startedAt)
        }
        return (url, startedAt)
    }

    /// 진행 중 기록 폐기 — 파일·스탬프 삭제(멱등). stopCapture 정리 경로.
    func discard() {
        lock.lock()
        defer { lock.unlock() }
        writer?.cancelWriting()
        if let url { Self.removeFiles(at: url) }
        reset()
        // 매니저는 앱 수명 인스턴스다 — 마무리 멘트 무음(해제 없음)으로 끝난 세션의 true 가 다음 면접까지
        // 남지 않게 여기서 되돌린다. (기록 «시작» 시 리셋은 하지 않는다 — 토글 소유는 세션 리듀서)
        isMuted = false
    }

    // MARK: - 내부

    /// 락 안에서만 부른다.
    private func reset() {
        writer = nil
        input = nil
        format = nil
        formatDescription = nil
        url = nil
        firstBufferHostSeconds = nil
        writtenFrames = 0
    }

    private static func removeFiles(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: SessionAudioRecording.startStampURL(for: url))
    }

    /// PCM 버퍼 → 표시 시각이 붙은 CMSampleBuffer(데이터 복사). 락 안에서만 부른다.
    private func sampleBuffer(from buffer: AVAudioPCMBuffer) -> CMSampleBuffer? {
        guard let formatDescription, let format else { return nil }
        let timescale = CMTimeScale(format.sampleRate)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: timescale),
            presentationTimeStamp: CMTime(value: writtenFrames, timescale: timescale),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: formatDescription, sampleCount: CMItemCount(buffer.frameLength),
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sample, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0,
            bufferList: buffer.audioBufferList
        ) == noErr else { return nil }
        return sample
    }

    /// 길이를 맞춘 무음 버퍼 — 캐시를 재사용하되 매번 전량을 0 으로 덮는다(`TapFileRecorder.silence` 와 같은 규칙).
    private func silence(frameLength: AVAudioFrameCount, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let buffer: AVAudioPCMBuffer
        if let cached = silenceBuffer, cached.format == format, cached.frameCapacity >= frameLength {
            buffer = cached
        } else {
            guard let allocated = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
            silenceBuffer = allocated
            buffer = allocated
        }
        buffer.frameLength = frameLength
        for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            memset(audioBuffer.mData, 0, Int(audioBuffer.mDataByteSize))
        }
        return buffer
    }
}
