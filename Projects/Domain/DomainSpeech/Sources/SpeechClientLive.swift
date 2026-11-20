//
//  SpeechClientLive.swift
//  DomainSpeechImplementation
//
//  Created by 서정원 on 26/07/29.
//

import AVFoundation
import ComposableArchitecture
import DomainSpeechInterface

extension SpeechClient: @retroactive DependencyKey {
    /// 단일 매니저(캡처·재생)를 공유하는 liveValue — 세션 화면 재진입에도 같은 매니저를 쓴다.
    public static let liveValue: SpeechClient = {
        let capture = AudioCaptureManager()
        let playback = AudioPlaybackManager()
        return SpeechClient(
            startCapture: { await capture.startCapture() },
            stopCapture: { await capture.stopCapture() },
            play: { await playback.play($0) },
            playStream: { await playback.playStream(url: $0, headers: $1) },
            startSessionAudioRecording: { await capture.startSessionAudioRecording() },
            finishSessionAudioRecording: { await capture.finishSessionAudioRecording() },
            setSessionAudioMuted: { await capture.setSessionAudioMuted($0) },
            startAnswerRecording: { await capture.startAnswerRecording() },
            answerAudio: { await capture.finishAnswerRecording() },
            stopPlayback: { await playback.stop() }
        )
    }()
}

/// 단일 AVAudioEngine 소유자 — start/stop 멱등. 실장치 의존이라 유닛 테스트 제외 — 실기기 로그 검증.
/// 피크 레벨·발화 판정은 tap 콜백(직렬)에서 SpeechActivityDetector 가 수행하고, 이벤트만 스트림으로 흘린다.
/// 같은 tap 이 파일 기록 2계열도 담당한다 — 세션 전구간(합성 입력)·답변 구간(STT 제출).
actor AudioCaptureManager {
    private var engine: AVAudioEngine?
    private var continuation: AsyncStream<SpeechCaptureEvent>.Continuation?
    /// tap 설치 시점의 입력 포맷 — 기록 파일도 반드시 «이 포맷»으로 열어야 한다.
    /// 시작 시점에 inputNode 를 다시 읽으면 라우트 변경(AirPods 연결 등)으로 버퍼 포맷과 갈라져
    /// `AVAudioFile.write` 가 try? 로 못 잡는 NSException 을 던진다.
    private var tapFormat: AVAudioFormat?
    private let sessionRecorder = TapFileRecorder()
    private let answerRecorder = TapFileRecorder()
    /// 현재 엔진의 발화 감지기 — tap 클로저와 같은 인스턴스. 판정 게이트는 답변 구간이 연다.
    private var detector: SpeechActivityDetector?
    /// 진단 탐침(HILIT_STT_PROBE) — 켜졌을 때만 붙는다. 제품 동작에 관여하지 않는다.
    private var transcriptionProbe: MicTranscriptionProbe?

    func startCapture() -> AsyncStream<SpeechCaptureEvent> {
        stopEngine()   // 재호출 = 기존 캡처 정지 후 재시작 (단일 구독자 계약)

        let (stream, continuation) = AsyncStream<SpeechCaptureEvent>.makeStream()
        do {
            let session = AVAudioSession.sharedInstance()
            // .playAndRecord: 질문 TTS 재생과 마이크 캡처가 한 세션을 공유한다.
            // .defaultToSpeaker: 액세서리가 없을 때 리시버 대신 하단 스피커로 — 없으면 거치 상태에서 거의 안 들린다.
            // .allowBluetoothA2DP: 이어폰 출력 허용 — playAndRecord 는 명시해야 켜진다(playback 계열만 자동).
            //   입력은 A2DP 가 출력 전용이라 내장 마이크로 남는다. HFP(.allowBluetoothHFP)는 **같이 켜지 않는다** —
            //   양쪽을 지원하는 기기(AirPods)에서 CoreAudio 가 HFP 를 우선해 면접관 음성이 통화 음질로 떨어지고,
            //   답변 녹음까지 8/16kHz 모노가 되어 서버 STT 정확도와 최종 영상 음질이 같이 내려간다.
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try session.setActive(true)

            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw CaptureSetupError.invalidInputFormat
            }

            let detector = SpeechActivityDetector()
            let sessionRecorder = sessionRecorder
            let answerRecorder = answerRecorder
            // 진단 탐침 — HILIT_STT_PROBE 없으면 nil 이라 제품 경로엔 없는 것과 같다.
            let probe = MicTranscriptionProbe.makeIfEnabled()
            probe?.start()
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, when in
                sessionRecorder.write(buffer, at: when)
                answerRecorder.write(buffer, at: when)
                probe?.append(buffer)
                for event in detector.process(buffer) {
                    continuation.yield(event)
                }
            }
            engine.prepare()
            try engine.start()

            self.engine = engine
            self.tapFormat = format
            self.detector = detector
            self.continuation = continuation
            self.transcriptionProbe = probe
            // 소비자가 for-await 를 취소(effect 취소)해도 엔진이 남지 않게 정지를 건다.
            continuation.onTermination = { _ in
                Task { await self.stopCapture() }
            }
        } catch {
            continuation.yield(.captureFailed(String(describing: error)))
            continuation.finish()
        }
        return stream
    }

    func stopCapture() {
        stopEngine()   // 진행 중이던 기록 폐기(파일 삭제)도 여기서 함께 일어난다
        continuation?.finish()
        continuation = nil
    }

    func startSessionAudioRecording() {
        guard let tapFormat else { return }   // 캡처 미가동 — 조용히 무시(합성 스킵 → 영상 없는 리포트)
        // 파일명은 매번 유일하게 — 산출물이 recorder 손을 떠나 합성(8~10초, 홈 복귀 뒤 화면 수명 밖)에서
        // 읽히는 동안 다음 면접의 begin 이 같은 경로를 지우면 안 된다. 삭제는 합성부·discard 몫(고정명과 동일).
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("interview-session-audio-\(UUID().uuidString).m4a")
        sessionRecorder.begin(url: url, format: tapFormat)
    }

    func finishSessionAudioRecording() -> SessionAudioRecording? {
        guard let (url, startedAt) = sessionRecorder.finishKeepingFile() else { return nil }
        return SessionAudioRecording(fileURL: url, startedAtHostSeconds: startedAt)
    }

    /// AI 발화 구간 무음화 토글 — 세션 기록기에만 건다(답변 기록기는 answering 에만 돌아 무관).
    /// 기록 미시작·캡처 미가동이면 플래그만 남고 아무 일도 없다(write 가 없으니 무해).
    func setSessionAudioMuted(_ muted: Bool) {
        sessionRecorder.setMuted(muted)
    }

    func startAnswerRecording() {
        guard let tapFormat else { return }   // 캡처 미가동 — 조용히 무시(서버 판정 위임)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("interview-answer.m4a")
        answerRecorder.begin(url: url, format: tapFormat)
        // 발화 판정도 «답변 구간» 과 함께 연다 — AI 발화 중 스피커 에코가 사용자 발화로 잡히지 않고,
        // 질문마다 판정 상태가 처음부터 시작한다(이 호출이 곧 answering 진입 신호다).
        detector?.startListening()
    }

    func finishAnswerRecording() -> Data? {
        detector?.stopListening()
        return answerRecorder.finishTakingData()
    }

    private func stopEngine() {
        // 캡처가 사라지는 유일한 길목(정지·재진입 공통) — 진행 중 기록은 쓸모가 없으니 파일까지 폐기한다.
        // 살려두면 재시작 후 옛 파일에 이어 붙고 첫 버퍼 시각도 옛것이라 립싱크가 정지 공백만큼 어긋난다.
        sessionRecorder.discard()
        answerRecorder.discard()
        transcriptionProbe?.stop()
        transcriptionProbe = nil
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        self.tapFormat = nil
        self.detector = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private enum CaptureSetupError: Error {
        case invalidInputFormat
    }
}

/// 버퍼 → 레벨·발화 이벤트 변환기. 판정 기준은 dBFS 가 아니라 **진폭 비율**(풀스케일 1.0 대비 피크)이다.
/// tap 콜백(오디오 스레드)과 `startListening`/`stopListening`(액터)이 만나므로 락으로 좁게 보호한다 (@unchecked 근거).
/// 임계·주기 상수는 실기기 튜닝 여지 — [[interview#음성 캡처]].
final class SpeechActivityDetector: @unchecked Sendable {
    /// 레벨 로그 주기.
    static let levelInterval: TimeInterval = 1.0
    /// 발화 시작 임계 — 피크가 풀스케일의 8%(≈ −21.9 dBFS) 이상인 버퍼를 «시끄러운 구간» 으로 센다.
    static let speechStartAmplitude: Float = 0.08
    /// 발화 시작 확정에 필요한 «연속» 시끄러운 버퍼 수 — 중간에 한 버퍼라도 임계 미만이면 처음부터 센다.
    static let speechStartConsecutiveBuffers = 2
    /// 침묵 임계 — 피크가 풀스케일의 3%(≈ −30.5 dBFS) 미만이면 침묵이고, speechEndHold 지속되면 speechEnded (히스테리시스).
    static let silenceAmplitude: Float = 0.03
    static let speechEndHold: TimeInterval = 1.0
    /// 무음 바닥값 — log10(0) 방지 겸 dBFS 하한 (level 로그 전용).
    static let silenceFloor: Float = -160

    private let lock = NSLock()
    /// 발화 판정 게이트 — 닫혀 있으면 speechStarted·speechEnded 를 내지 않는다(level 로그는 항상 흐른다).
    /// 답변 구간(`startAnswerRecording` ~ `answerAudio`)에만 연다 — 질문 TTS 가 스피커로 나오는 동안
    /// 마이크에 섞인 에코가 «사용자 발화» 로 잡히지 않게 하려는 것이다.
    private var isListening = false
    private var isSpeaking = false
    private var loudStreak = 0
    private var silenceElapsed: TimeInterval = 0
    private var windowElapsed: TimeInterval = 0
    private var windowPeak: Float = 0

    /// 발화 판정 시작 — 이전 판정 상태(발화 중·연속 카운트)를 비우고 처음부터 센다.
    func startListening() {
        lock.lock()
        defer { lock.unlock() }
        isListening = true
        resetSpeechState()
    }

    /// 발화 판정 정지 — 멱등.
    func stopListening() {
        lock.lock()
        defer { lock.unlock() }
        isListening = false
        resetSpeechState()
    }

    /// tap 버퍼 한 개 = 한 구간. 전 채널의 최대 절댓값이 그 구간의 피크다.
    func process(_ buffer: AVAudioPCMBuffer) -> [SpeechCaptureEvent] {
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0,
              buffer.format.sampleRate > 0
        else { return [] }

        let frameCount = Int(buffer.frameLength)
        var peak: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = channelData[channel]
            for index in 0..<frameCount {
                peak = max(peak, abs(samples[index]))
            }
        }
        return process(peak: peak, duration: Double(frameCount) / buffer.format.sampleRate)
    }

    /// 구간 하나의 피크(0…1)와 길이로 판정한다 — 버퍼 없이도 호출할 수 있어 유닛 테스트가 쓴다.
    func process(peak: Float, duration: TimeInterval) -> [SpeechCaptureEvent] {
        lock.lock()
        defer { lock.unlock() }
        var events: [SpeechCaptureEvent] = []

        if isListening {
            if !isSpeaking {
                // 시작 — 시끄러운 구간이 «연속» 으로 이어져야 한다. 끊기면 카운트를 비운다.
                loudStreak = peak >= Self.speechStartAmplitude ? loudStreak + 1 : 0
                if loudStreak >= Self.speechStartConsecutiveBuffers {
                    isSpeaking = true
                    loudStreak = 0
                    silenceElapsed = 0
                    events.append(.speechStarted)
                }
            } else if peak < Self.silenceAmplitude {
                // 종료 — 침묵 임계 미만이 speechEndHold 지속돼야 한다. 한 구간이라도 넘으면 처음부터 잰다.
                silenceElapsed += duration
                if silenceElapsed >= Self.speechEndHold {
                    isSpeaking = false
                    silenceElapsed = 0
                    events.append(.speechEnded)
                }
            } else {
                silenceElapsed = 0
            }
        }

        // 레벨 로그 — 1초 윈도의 피크를 dBFS 로 방출 (짧은 발화도 로그에 드러나게, 임계와 같은 피크 기준).
        windowPeak = max(windowPeak, peak)
        windowElapsed += duration
        if windowElapsed >= Self.levelInterval {
            events.append(.level(Self.decibels(fromAmplitude: windowPeak)))
            windowElapsed = 0
            windowPeak = 0
        }

        return events
    }

    /// 진폭(0…1) → dBFS. 0 은 `silenceFloor` 로 받는다.
    static func decibels(fromAmplitude amplitude: Float) -> Float {
        max(20 * log10(max(amplitude, .leastNonzeroMagnitude)), silenceFloor)
    }

    private func resetSpeechState() {
        isSpeaking = false
        loudStreak = 0
        silenceElapsed = 0
    }
}

/// tap 버퍼 → m4a(AAC) 파일 기록기 — iOS 는 mp3 인코딩 미지원이라 AAC(스펙 결정, 스웨거 m4a 명시).
/// 세션 전구간(finishKeepingFile — 합성 입력)과 답변 구간(finishTakingData — STT 제출) 겸용.
/// tap 콜백(오디오 스레드)과 시작/종료(액터)가 만나는 지점이라 락으로 좁게 보호한다 (@unchecked 근거).
final class TapFileRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var url: URL?
    /// 첫 버퍼의 호스트시각(초) — 립싱크 오프셋 보정 기준(스펙 §①).
    private var firstBufferHostSeconds: Double?
    /// AI 발화(질문 TTS·마무리 멘트) 구간 — 입력 대신 같은 길이의 무음을 기록한다. 토글 소유는 세션 리듀서.
    private var isMuted = false
    /// 무음 버퍼 재사용 캐시 — tap 주기마다 할당하지 않으려고 들고 있는다(포맷·용량이 어긋나면 재할당).
    private var silenceBuffer: AVAudioPCMBuffer?

    /// 새 기록 시작 — 이전 기록이 남아 있으면 버린다.
    func begin(url: URL, format: AVAudioFormat) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
        // AVAudioFile 이 PCM 버퍼를 AAC 로 인코딩해 쓴다.
        file = try? AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount
        ], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        self.url = file == nil ? nil : url
        firstBufferHostSeconds = nil
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
        guard let file else { return }
        // 포맷이 어긋나면 write 는 Swift error 가 아니라 NSException 을 던져 try? 로도 못 막는다 —
        // 이 경우 기록을 포기(스탬프도 안 찍음 → 산출물 nil, 서버 판정·합성 스킵 폴백)한다.
        guard buffer.format == file.processingFormat else { return }
        // 스탬프는 소리 유무가 아니라 «타임라인이 언제 열렸나» 라서 무음 구간에서도 찍는다.
        if firstBufferHostSeconds == nil {
            firstBufferHostSeconds = AVAudioTime.seconds(forHostTime: when.hostTime)
        }
        guard isMuted else {
            try? file.write(from: buffer)
            return
        }
        // 무음도 «같은 길이»를 기록한다 — 건너뛰면 m4a 가 벽시계보다 짧아져 이후 오디오가 통째로
        // 앞으로 밀리고 립싱크·startSec 정렬이 무너진다. 원본 버퍼는 뒤이어 감지기·탐침이 읽으므로 손대지 않는다.
        if let silence = silence(frameLength: buffer.frameLength, format: file.processingFormat) {
            try? file.write(from: silence)
        }
    }

    /// 길이를 맞춘 무음 버퍼 — 캐시를 재사용하되 매번 명시적으로 0 을 채운다
    /// (AVAudioPCMBuffer 메모리는 0 이 보장되지 않고, 재사용분엔 직전 프레임이 남아 있다).
    /// 할당 실패(사실상 없음)면 nil — 그 한 버퍼만 건너뛴다(에코를 남기는 쪽보다 낫다).
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
        // `mutableAudioBufferList` 의 mDataByteSize 는 frameLength 가 아니라 **frameCapacity** 기준이라
        // (AVAudioBuffer.h) 매번 전량을 0 으로 덮는다 — frameLength 만큼만 지우는 «최적화» 는 캐시에
        // 남은 직전 프레임을 되살릴 수 있다.
        for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            memset(audioBuffer.mData, 0, Int(audioBuffer.mDataByteSize))
        }
        return buffer
    }

    /// 기록을 닫고 (파일 URL, 첫 버퍼 시각) 반환 — 파일은 유지(합성부가 삭제). 기록 없음·실패는 nil.
    func finishKeepingFile() -> (URL, Double)? {
        lock.lock()
        defer { lock.unlock() }
        file = nil   // AVAudioFile 은 해제 시점에 닫힌다
        defer { url = nil; firstBufferHostSeconds = nil }
        guard let url else { return nil }
        guard let firstBufferHostSeconds else {
            // 버퍼를 한 번도 못 받은 기록 — 넘길 산출물이 없으니 파일도 여기서 지운다. 밖에선 URL 을 모르고,
            // 유일 파일명이라 다음 begin 의 덮어쓰기도 없어 안 지우면 그대로 샌다.
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return (url, firstBufferHostSeconds)
    }

    /// 기록을 닫고 내용을 돌려준 뒤 파일 즉시 삭제 — 기록 없음·실패는 nil.
    func finishTakingData() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        file = nil
        let data = url.flatMap { try? Data(contentsOf: $0) }
        if let url { try? FileManager.default.removeItem(at: url) }
        url = nil
        firstBufferHostSeconds = nil
        return data
    }

    /// 진행 중 기록 폐기 — 파일 삭제(멱등). stopCapture 정리 경로.
    func discard() {
        lock.lock()
        defer { lock.unlock() }
        file = nil
        if let url { try? FileManager.default.removeItem(at: url) }
        url = nil
        firstBufferHostSeconds = nil
        // 매니저는 앱 수명 인스턴스다 — 마무리 멘트 무음(해제 없음)으로 끝난 세션의 true 가 다음 면접까지
        // 남지 않게 여기서 되돌린다. (기록 «시작» 시 리셋은 하지 않는다 — 토글 소유는 세션 리듀서)
        isMuted = false
    }
}
