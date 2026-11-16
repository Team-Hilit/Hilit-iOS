//
//  RecordingClientLive.swift
//  DomainRecordingImplementation
//
//  Created by 서정원 on 26/07/28.
//

import AVFoundation
import ComposableArchitecture
import DomainRecordingInterface
import OSLog
import UIKit

extension RecordingClient: @retroactive DependencyKey {
    /// 단일 CameraSessionManager 를 공유하는 liveValue — 준비·세션 화면이 같은 캡처 세션을 이어 쓴다.
    /// static let: 접근마다 매니저가 새로 만들어지면 멱등 공유가 깨진다.
    public static let liveValue: RecordingClient = {
        let manager = CameraSessionManager()
        return RecordingClient(
            startPreview: { await manager.startPreview() },
            stopPreview: { await manager.stopPreview() },
            startRecording: { try await manager.startRecording(sessionId: $0) },
            sessionAudioURL: { await manager.sessionAudioURL() },
            suspendRecording: { await manager.suspendRecording(audio: $0) },
            stopRecording: { try await manager.stopRecording(finalAudio: $0) },
            discardRecording: { await manager.discardRecording() },
            purgeRecordings: { await manager.purgeRecordings(sessionId: $0) },
            purgeStaleRecordings: { await manager.purgeStaleRecordings(keeping: $0) }
        )
    }()
}

/// 단일 AVCaptureSession 소유자 — start/stop 멱등. actor 라 세션 구성·startRunning(블로킹)이
/// 메인 스레드 밖에서 수행된다. 실장치 의존이라 유닛 테스트 제외 — 실기기 육안 검증.
actor CameraSessionManager {
    private static let logger = Logger(subsystem: "com.hilit.recording", category: "camera-session")

    private var handle: CameraPreviewHandle?
    private var recording: ActiveRecording?
    /// 진행 중·직전 산출 파일들(비디오·오디오·합성본) — stop 이후에도 discard 가 지울 수 있게 유지한다.
    /// 갈아끼우지 않고 누적한다 — 새 녹화가 배열을 덮어쓰면 직전 합성본이 추적에서 사라져 누수된다.
    private var lastFileURLs: [URL] = []
    /// start/suspend/stop 은 await 을 품는다 — 액터가 그 사이 다른 호출을 들여보내므로 «구간» 을 플래그로 잠근다.
    private var isStarting = false
    private var isStopping = false
    /// 세그먼트 마감 «구간» — 이걸 안 잡으면 마감 중 들어온 startRecording 이 아직 append 되지 않은 원장을 보고
    /// «같은 인덱스» 경로를 받아, 마감 중인 파일을 removeItem 으로 지운다(세그먼트 통째 유실).
    private var isSuspending = false
    /// 시작 «구간» 의 기록 파일 — 아직 `recording` 에 서지 않았어도 폐기 대상에서 제외해야 한다.
    private var startingFileURL: URL?
    /// 정지·시작 중 들어온 폐기 요청 — 그때 지워도 진행 중인 작업이 산출물을 다시 만든다. 그 작업이 끝날 때 처리한다.
    private var discardRequested = false
    /// 세션의 마감된 세그먼트 원장 — 화면이 dismiss 돼도 액터가 살아 있는 한 유지되고, 기록 시작·마감 직전·마감 뒤마다 매니페스트로
    /// 디스크에 남아 앱이 죽어도 다음 프로세스의 startRecording 이 되살린다(재개의 근거 — HLT-78).
    private var ledger = SegmentLedger()

    private struct ActiveRecording {
        let output: AVCaptureMovieFileOutput
        let delegate: MovieRecordingDelegate
        let url: URL
        let sessionId: Int
    }

    func startPreview() -> CameraPreviewHandle? {
        if let handle { return handle }
        guard
            // 준비 화면 게이트와 별개로 계약(권한 미허용 → nil)을 여기서도 강제 — notDetermined 로
            // 세션을 구성하면 검은 프레임 + 시스템 권한 프롬프트가 엉뚱한 시점에 뜬다.
            AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
            let input = try? AVCaptureDeviceInput(device: device)
        else { return nil }   // 권한 미허용·시뮬레이터·장치 없음 — 호출부가 placeholder 로 진행

        let session = AVCaptureSession()
        session.beginConfiguration()
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            return nil
        }
        session.addInput(input)
        session.commitConfiguration()
        session.startRunning()

        let handle = CameraPreviewHandle(session: session)
        self.handle = handle
        return handle
    }

    func stopPreview() {
        handle?.session.stopRunning()
        handle = nil
    }

    /// A안-2(스펙 §①) — 프리뷰 세션에 **비디오 전용** 무비 출력을 더해 «세그먼트» 를 기록한다(마이크는 엔진 소유 — 넣지 않는다).
    /// didStartRecordingTo 후 반환 — 반환값은 이전까지 누적 녹화초로, 호출부가 세션 시계 시드로 삼는다(타임라인 정렬).
    func startRecording(sessionId: Int) async throws -> Double {
        // 멱등 — `recording` 세팅은 아래 await 뒤라, 플래그로 시작 «구간» 까지 가드를 넓힌다.
        // (넓히지 않으면 동시 호출이 둘 다 통과해 무비 출력 두 개가 같은 파일에 기록된다.)
        // 마감 «구간»(isSuspending)도 막는다 — 그때 시작하면 아직 원장에 오르지 않은 세그먼트와 같은 인덱스
        // 경로를 받아 마감 중인 파일을 지운다. background→foreground 왕복이 정상 흐름이라 실제로 겹친다.
        guard recording == nil, !isStarting, !isSuspending else { return ledger.cumulativeSeconds }
        isStarting = true
        defer {
            isStarting = false
            startingFileURL = nil
        }
        guard let session = handle?.session else {
            throw RecordingError.startFailed("프리뷰 세션 없음")
        }
        // 백그라운드를 다녀온 캡처세션은 정지돼 있을 수 있다 — 재가동은 멱등이라 늘 확인한다(스펙 ②).
        if !session.isRunning { session.startRunning() }
        let output = try attachMovieOutput(to: session)

        // 이 프로세스가 처음 보는 세션이면 앞 프로세스가 남긴 원장부터 되살린다 — 앱이 죽은 뒤 재개(HLT-78).
        // 매니페스트가 없으면(새 세션) no-op 이고, 아래 begin 이 세션 전환으로 보고 원장을 새로 연다.
        await restoreLedgerIfNeeded(sessionId: sessionId)
        ensureStorageDirectory()
        // 앞 프로세스가 기록 중에 죽었으면 이 인덱스에 마감 안 된(moov 없는) 파일이 남아 있다 — 아래에서 지우고 덮는다.
        let videoURL = ledger.begin(sessionId: sessionId)   // 세션이 바뀌면 원장 리셋 + 인덱스 경로
        try? FileManager.default.removeItem(at: videoURL)
        // 이 세그먼트의 세션 오디오 자리 — 앞 프로세스가 같은 인덱스에 남긴 것(복원에서 빠진 것)은 비운다.
        let audioURL = SegmentLedger.audioURL(sessionId: sessionId, index: ledger.segments.count)
        let audioStampURL = SegmentLedger.audioStartStampURL(for: audioURL)
        try? FileManager.default.removeItem(at: audioURL)
        try? FileManager.default.removeItem(at: audioStampURL)
        startingFileURL = videoURL   // 아직 추적 배열에 없다 — 진행 중 폐기의 삭제 대상에서 제외하기 위한 표시.

        let delegate = MovieRecordingDelegate()
        output.startRecording(to: videoURL, recordingDelegate: delegate)
        do {
            try await delegate.waitUntilStarted()
        } catch {
            detachOutput(output)
            throw RecordingError.startFailed(String(describing: error))
        }
        recording = ActiveRecording(output: output, delegate: delegate, url: videoURL, sessionId: sessionId)
        track(videoURL)
        // 시작을 기다리는 동안 폐기 요청이 도착했으면 방금 선 기록을 즉시 되돌린다.
        // 남겨 두면 고아 ActiveRecording 이 되어 이후 startRecording 이 전부 no-op 이 되고,
        // stopRecording 은 폐기된 세션의 ref 를 돌려준다(엉뚱한 세션에 업로드).
        if discardRequested {
            await rollbackStart(videoURL: videoURL)
            throw RecordingError.startFailed("녹화 폐기됨")
        }
        // 기록이 섰으면 곧바로 원장에 «열린» 세그먼트로 남긴다 — 마감 도중에 앱이 죽어도 다음 프로세스가
        // 이 파일을 안다(HLT-78, 2026-11-17 실기기: 마감 뒤에만 기록하면 닫힌 파일까지 잃었다).
        // 오디오 자리도 함께 — 세션 화면이 `sessionAudioURL()` 로 받아 거기에 기록한다(첫 버퍼 시각은 스탬프 파일).
        ledger.open(videoURL: videoURL, startedAtHostSeconds: delegate.startedAtHostSeconds, reservedAudioURL: audioURL)
        track(audioURL, audioStampURL)
        persistManifest()
        return ledger.cumulativeSeconds
    }

    /// 프리뷰 세션에 비디오 전용 무비 출력을 붙인다 — 비트레이트 캡 포함.
    private func attachMovieOutput(to session: AVCaptureSession) throws -> AVCaptureMovieFileOutput {
        // 캡처 세션이 오디오 세션을 재구성해 엔진 tap 을 끊는 것을 막는다 (스파이크 1차 실패 교훈 — 마이크 공유 금지).
        session.automaticallyConfiguresApplicationAudioSession = false

        session.beginConfiguration()
        // 480p — 720p 의 16:9 와 달리 4:3 이라 프레임 비율이 바뀐다(프리뷰는 resizeAspectFill 이 흡수).
        if session.canSetSessionPreset(.vga640x480) {
            session.sessionPreset = .vga640x480
        }
        let output = AVCaptureMovieFileOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw RecordingError.startFailed("무비 출력 추가 실패")
        }
        session.addOutput(output)
        if let connection = output.connection(with: .video),
           output.availableVideoCodecTypes.contains(.h264) {
            output.setOutputSettings([
                AVVideoCodecKey: AVVideoCodecType.h264,
                // 상반신 고정 화면이라 2Mbps 로 충분 — 12분 ≈ 180MB (기본 ~8-10Mbps 는 700MB+, 업로드 병목).
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000]
            ], for: connection)
        }
        session.commitConfiguration()
        return output
    }

    /// 시작 대기 중 도착한 폐기 요청 처리 — 방금 선 기록을 정지·삭제한다.
    private func rollbackStart(videoURL: URL) async {
        startingFileURL = nil   // 이 기록이 폐기 대상 — 제외 목록에서 뺀다.
        await teardownRecording()
        if isStopping {
            // 정지·합성이 아직 도는 중 — 이 파일만 지우고, 나머지 폐기는 그쪽 defer 몫으로 남긴다.
            removeTracked(videoURL)
        } else {
            discardRequested = false
            purgeTrackedFiles()
            // 파일을 지웠으니 원장·매니페스트도 비운다 — 남기면 다음 begin·재실행 복원이 없는 파일을 이어받는다.
            resetLedger()
        }
    }

    /// 진행 중 세그먼트의 세션 오디오 기록 경로 — 녹화가 없으면 nil(호출부는 tmp 로 기록한다).
    func sessionAudioURL() -> URL? {
        let url = recording == nil ? nil : ledger.openSegment?.reservedAudioURL
        if url == nil {
            Self.logger.error("세션 오디오 경로 없음 — recording \(self.recording == nil ? "nil" : "있음"), open \(self.ledger.openSegment == nil ? "nil" : "있음")")
        }
        return url
    }

    /// 현 세그먼트 마감 — 파일을 닫고 실측 길이로 원장에 올린다(스펙 ①). suspend·stop 공용.
    private func finalizeCurrentSegment(audio: RecordingAudioSegment?) async throws -> Double {
        // 어느 실패 경로로 빠지든 12분치 m4a 가 남지 않도록 «가드보다 먼저» 추적에 편입한다
        // (suspend 경로는 여기가 유일한 track 지점이라, 아래로 내려가면 마감 실패 시 오디오가 영영 안 지워진다).
        track(audio?.fileURL)
        guard let recording else { throw RecordingError.stopFailed("진행 중인 녹화 없음") }
        // 오디오는 파일을 닫기 «전에» 보관 폴더로 옮기고 원장에 기록한다 — 아래 마감(파일 닫기·길이 로드)은
        // 수 초 걸려 그사이 앱이 죽을 수 있다. 원장에 짝이 남아 있으면 다음 프로세스가 길이를 재서 온전히 살린다.
        let adopted = audio.map { adoptAudio($0, sessionId: recording.sessionId, index: ledger.segments.count) }
        let reservedAudioURL = ledger.openSegment?.reservedAudioURL
        if let adopted {
            ledger.attachOpenAudio(adopted)
            persistManifest()
        }
        recording.output.stopRecording()
        self.recording = nil
        let finished: Result<Void, Error>
        do {
            try await recording.delegate.waitUntilFinished()
            finished = .success(())
        } catch {
            finished = .failure(error)
        }
        detachOutput(recording.output)
        let duration: Double
        do {
            try finished.get()
            guard FileManager.default.fileExists(atPath: recording.url.path) else {
                throw RecordingError.stopFailed("비디오 파일 없음")
            }
            duration = try await AVURLAsset(url: recording.url).load(.duration).seconds
        } catch {
            // 못 쓰는 세그먼트 — 열린 항목을 원장에서 내린다(남기면 재실행 복원이 깨진 파일을 다시 잰다).
            ledger.dropOpenSegment()
            persistManifest()
            throw RecordingError.stopFailed(String(describing: error))
        }
        // 오디오 인자가 없는 마감(세션 오디오 마무리 실패·코디네이터의 `suspendRecording(nil)` 등)이어도, 이 세그먼트의
        // 예약 경로에 기록된 오디오가 읽히고 스탬프가 있으면 짝으로 붙인다 — 마감 경로마다 오디오를 잃지 않게 한 곳에서 막는다.
        var segmentAudio = adopted
        if segmentAudio == nil, let reservedAudioURL {
            segmentAudio = await Self.recoverAudio(at: reservedAudioURL)
            Self.logger.notice("마감에 오디오 인자 없음 — 예약 경로 회수 \(segmentAudio == nil ? "실패" : "성공")")
        }
        ledger.append(SegmentLedger.Segment(
            videoURL: recording.url,
            videoStartedAtHostSeconds: recording.delegate.startedAtHostSeconds,
            videoDurationSeconds: duration.isFinite ? duration : 0,
            audio: segmentAudio
        ))
        persistManifest()
        return ledger.cumulativeSeconds
    }

    /// 백그라운드 마감(스펙 ②) — OS 유예(~5초) 안에 파일을 닫으려 background task 로 감싼다.
    /// 비던짐: 실패는 그 세그먼트 유실(로그)이고 면접은 계속된다(스펙 ⑥).
    func suspendRecording(audio: RecordingAudioSegment?) async -> Double? {
        guard recording != nil else { return nil }
        // 마감 «구간» 잠금 — 첫 await(MainActor hop) 앞에서 세운다. 이 뒤로 startRecording·discardRecording 은
        // 곧바로 손대지 못하고, 폐기 요청은 아래 defer 가 받아 처리한다(stop 의 defer 와 같은 규약).
        isSuspending = true
        let taskID = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: "InterviewSegmentSuspend")
        }
        defer {
            Task { @MainActor in UIApplication.shared.endBackgroundTask(taskID) }
            isSuspending = false
            if discardRequested {
                // 그 사이 시작된 «새» 녹화 소속 파일은 제외 — 기록 중인 mp4 를 지우면 그 녹화가 깨진다.
                purgeTrackedFiles(excluding: activeRecordingFileURLs)
                // 파일을 지웠으니 원장도 비운다 — 남기면 다음 begin 이 없는 파일을 이어받아 합성이 깨진다.
                resetLedger()
                // 시작 중인 녹화가 있으면 요청은 그 꼬리(startRecording)가 마저 처리한다.
                if !isStarting { discardRequested = false }
            }
        }
        do {
            return try await finalizeCurrentSegment(audio: audio)
        } catch {
            Self.logger.error("세그먼트 마감 실패: \(String(describing: error))")
            return nil
        }
    }

    /// 정지 + 합성(스펙 ①) — 마지막 세그먼트를 마감하고 원장의 전 세그먼트를 이어 붙인다.
    /// 세그먼트 없음·전 세그먼트 무음·합성 실패는 throw — 무음 영상을 만들지 않는다(종착은 영상 없는 리포트).
    func stopRecording(finalAudio: RecordingAudioSegment?) async throws -> RecordingRef {
        // 어느 실패 경로로 빠지든 12분치 m4a 가 남지 않도록 «가드보다 먼저» 추적에 편입한다.
        track(finalAudio?.fileURL)
        guard let sessionId = ledger.sessionId ?? recording?.sessionId else {
            throw RecordingError.stopFailed("진행 중인 녹화 없음")
        }
        isStopping = true
        // 랩업(마감+합성)은 백그라운드로 밀려도 완주시킨다 — 스펙 ② 동결의 예외.
        let taskID = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: "InterviewComposeFinish")
        }
        defer {
            Task { @MainActor in UIApplication.shared.endBackgroundTask(taskID) }
            isStopping = false
            // 정지·합성 중 들어온 폐기 요청은 여기서 처리 — 산출물이 다 만들어진 뒤라야 실제로 지워진다.
            if discardRequested {
                // 그 사이 시작된 «새» 녹화 소속 파일은 제외 — 기록 중인 mp4 를 지우면 그 녹화가 깨진다.
                purgeTrackedFiles(excluding: activeRecordingFileURLs)
                // 합성이 실패해 원장이 아직 이 세션 것이면 매니페스트와 함께 비운다 — 남기면 이 프로세스에선
                // 원장이 세션을 계속 소유해 `purgeRecordings` 가 no-op 이 된다. 새 세션 원장은 건드리지 않는다.
                if ledger.sessionId == sessionId { resetLedger() }
                // 시작 중인 녹화가 있으면 요청은 그 꼬리(startRecording)가 마저 처리한다.
                if !isStarting { discardRequested = false }
            }
        }
        if recording != nil {
            _ = try await finalizeCurrentSegment(audio: finalAudio)
        }
        // 오디오 파일이 사라진 세그먼트는 무음으로 합성한다 — 예약 경로 회수로 붙인 오디오는 세션 쪽 폐기가 나중에
        // 지울 수 있고, 없는 파일을 넘기면 합성이 통째로 실패해 영상 전체를 잃는다.
        let segments = ledger.segments.map { segment in
            guard let audio = segment.audio, !FileManager.default.fileExists(atPath: audio.fileURL.path) else { return segment }
            return SegmentLedger.Segment(
                videoURL: segment.videoURL,
                videoStartedAtHostSeconds: segment.videoStartedAtHostSeconds,
                videoDurationSeconds: segment.videoDurationSeconds,
                audio: nil
            )
        }
        guard !segments.isEmpty else { throw RecordingError.stopFailed("세그먼트 없음") }
        // 전 세그먼트 무음이면 기존 계약대로 throw — 무음 영상을 만들지 않는다(일부 무음 세그먼트는 허용).
        guard segments.contains(where: { $0.audio != nil }) else {
            throw RecordingError.stopFailed("세션 오디오 없음")
        }
        let mergedURL = SegmentLedger.mergedURL(sessionId: sessionId)
        track(mergedURL)
        // 합성(8~10초) 앞에서 카메라를 놓아준다 — 자리가 «파일 마감 뒤·합성 앞» 인 건 moov 가 캡처세션이 도는
        // 동안 써지기 때문이다. 핸들은 남긴다(해제는 코디네이터 `stopPreview()`). 근거 → [[interview#프리뷰]]
        handle?.session.stopRunning()
        let duration = try await compose(segments: segments, to: mergedURL)
        // 원본 임시 파일은 합성 성공 후에만 정리 — 합성본만 남긴다.
        for segment in segments {
            removeTracked(segment.videoURL)
            if let audio = segment.audio {
                removeTracked(audio.fileURL, SegmentLedger.audioStartStampURL(for: audio.fileURL))
            }
        }
        // 합성(8~10초) 중 «새» 세션이 시작됐으면 원장은 이미 그 세션 것이다 — 그때 비우면 새 세션이
        // 마감된 세그먼트 0 을 잃고(다음 begin 이 세션 전환으로 오판해 파일을 덮어쓴다) 누적초도 0 으로 돌아간다.
        // 매니페스트는 세션별 파일이라 어느 쪽이든 이 세션 것만 지운다 — 남기면 재실행 복원이 지운 세그먼트를 찾는다.
        try? FileManager.default.removeItem(at: SegmentLedger.manifestURL(sessionId: sessionId))
        if ledger.sessionId == sessionId { ledger.reset() }
        // 합성 중 폐기를 요청받았으면 산출물은 곧 defer 가 지운다 — 지워질 파일을 참조로 돌려주지 않는다.
        guard !discardRequested else { throw RecordingError.stopFailed("녹화 폐기됨") }
        return RecordingRef(sessionId: sessionId, fileURL: mergedURL, durationSeconds: duration)
    }

    func discardRecording() async {
        // 정지·시작·마감이 도는 중이면 표시만 — 지금 지워도 그 작업이 산출물을 다시 만든다.
        // 요청은 진행 중인 작업의 꼬리(stop·suspend 의 defer / start 의 tail)가 받아 처리한다.
        guard !isStopping, !isStarting, !isSuspending else {
            discardRequested = true
            return
        }
        await teardownRecording()
        discardRequested = false
        purgeTrackedFiles()
        // 원장까지 비운다 — 남겨 두면 다음 세션 시작이 폐기된 세그먼트를 누적초·합성 재료로 이어받는다.
        resetLedger()
    }

    /// 진행 중인 기록을 즉시 정지·해제 — 파일 정리 범위는 경우마다 달라 호출부 몫으로 둔다.
    private func teardownRecording() async {
        guard let recording else { return }
        recording.output.stopRecording()
        self.recording = nil
        try? await recording.delegate.waitUntilFinished()
        detachOutput(recording.output)
    }

    /// 진행 중·시작 중인 녹화 소속 파일 — 폐기 대상에서 제외한다(기록 중인 mp4 를 지우면 그 녹화가 깨진다).
    private var activeRecordingFileURLs: [URL] {
        [recording?.url, startingFileURL].compactMap { $0 }
    }

    /// 산출 파일 추적 편입 — 중복 없이 누적한다(덮어쓰면 직전 산출물이 추적에서 사라져 누수).
    private func track(_ urls: URL?...) {
        for case let url? in urls where !lastFileURLs.contains(url) {
            lastFileURLs.append(url)
        }
    }

    /// 삭제 + 추적 해제 — 합성 성공 후 원본 정리처럼 «지웠으니 추적에서도 뺀다» 용도.
    private func removeTracked(_ urls: URL...) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
            lastFileURLs.removeAll { $0 == url }
        }
    }

    /// 추적 중인 산출 파일 삭제 — 폐기의 실체. `excluding` 은 삭제도 추적 해제도 하지 않는다.
    private func purgeTrackedFiles(excluding kept: [URL] = []) {
        for url in lastFileURLs where !kept.contains(url) {
            try? FileManager.default.removeItem(at: url)
        }
        lastFileURLs = lastFileURLs.filter { kept.contains($0) }
    }

    /// 세그먼트 이어붙임 합성(스펙 ①) — 커서를 옮기며 순차 insert, export 는 종료 시 1회다.
    /// 립싱크 오프셋은 세그먼트 «안»의 (오디오 시작 − 비디오 시작) 호스트시각 차 — 세그먼트끼리는
    /// 커서가 정렬을 만든다(백그라운드 공백은 영상에 없다 — raw 축도 함께 멈추는 이유, 스펙 «결정 요약»).
    private func compose(segments: [SegmentLedger.Segment], to mergedURL: URL) async throws -> Double {
        try? FileManager.default.removeItem(at: mergedURL)
        let composition = AVMutableComposition()
        guard let compositionVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let compositionAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw RecordingError.stopFailed("합성 트랙 생성 실패") }

        var cursor = CMTime.zero
        for (index, segment) in segments.enumerated() {
            let videoAsset = AVURLAsset(url: segment.videoURL)
            guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first else {
                throw RecordingError.stopFailed("세그먼트 \(index) 비디오 트랙 없음")
            }
            let videoDuration = try await videoAsset.load(.duration)
            try compositionVideo.insertTimeRange(
                CMTimeRange(start: .zero, duration: videoDuration), of: videoTrack, at: cursor
            )
            if index == 0 {
                // 전면 카메라 회전 승계 — 없으면 합성본이 눕는다 (스파이크 2차 교훈).
                compositionVideo.preferredTransform = try await videoTrack.load(.preferredTransform)
            }
            if let audio = segment.audio {
                let audioAsset = AVURLAsset(url: audio.fileURL)
                if let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first {
                    let audioDuration = try await audioAsset.load(.duration)
                    // 립싱크 오프셋(스펙 ①): 오디오는 비디오보다 늦게 시작한다 — 그 차만큼 뒤에 insert.
                    // 음수(오디오가 먼저)면 그만큼 오디오 머리를 잘라 커서 자리에 insert.
                    let offset = audio.startedAtHostSeconds - (segment.videoStartedAtHostSeconds ?? audio.startedAtHostSeconds)
                    if offset >= 0 {
                        try compositionAudio.insertTimeRange(
                            CMTimeRange(start: .zero, duration: audioDuration),
                            of: audioTrack,
                            at: cursor + CMTime(seconds: offset, preferredTimescale: 600)
                        )
                    } else {
                        let head = CMTime(seconds: -offset, preferredTimescale: 600)
                        try compositionAudio.insertTimeRange(
                            CMTimeRange(start: head, duration: audioDuration - head),
                            of: audioTrack,
                            at: cursor
                        )
                    }
                }
            }
            cursor = CMTimeAdd(cursor, videoDuration)
        }

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw RecordingError.stopFailed("export 세션 생성 실패")
        }
        // 8~10초 걸린다 — 대부분이 `.waiting`(자원 획득)이고 영상 길이와 무관한 고정 비용이다 → [[interview#세션]]
        Self.logger.notice("합성 시작 — \(composition.duration.seconds, privacy: .public)s, 세그먼트 \(segments.count)개")
        if #available(iOS 18, *) {
            try await export.export(to: mergedURL, as: .mp4)
        } else {
            export.outputURL = mergedURL
            export.outputFileType = .mp4
            await withCheckedContinuation { continuation in
                export.exportAsynchronously { continuation.resume() }
            }
            // status 로 판정 — 실패인데 error 가 비어 오는 경우가 있다 (스파이크 검증 구조).
            guard export.status == .completed else {
                throw RecordingError.stopFailed(String(describing: export.error))
            }
        }
        return cursor.seconds.isFinite ? cursor.seconds : 0
    }

    /// 녹화 종료 후 무비 출력을 세션에서 제거 — 프리뷰는 계속 돈다(정지는 코디네이터 몫이라 여기선 안 건든다).
    private func detachOutput(_ output: AVCaptureMovieFileOutput) {
        guard let session = handle?.session else { return }
        session.beginConfiguration()
        session.removeOutput(output)
        session.commitConfiguration()
    }
}

// MARK: - 보관 파일 정리·원장 영속(HLT-78)

// 같은 파일 extension — actor 본문 길이 상한(type_body_length) 때문에 갈랐다. private 상태는 파일 범위라 그대로 닿는다.
extension CameraSessionManager {
    /// 그 세션의 보관 파일(세그먼트·오디오·합성본·매니페스트)을 걷어낸다 — 이 프로세스의 원장이 모르는
    /// 세션(앞 프로세스가 남긴 것)을 끝낼 때 쓴다. 현재 원장의 세션이면 무시(그쪽은 `discardRecording` 몫).
    /// 구버전이 tmp 에 남긴 같은 세션 파일도 함께 지운다.
    func purgeRecordings(sessionId: Int) {
        guard sessionId != ledger.sessionId else { return }
        removeStoredFiles { $0 == sessionId }
        let tmp = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        for name in names where name.hasPrefix("interview-video-\(sessionId)-") || name == "interview-recording-\(sessionId).mp4" {
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent(name))
        }
    }

    /// 실행 시점 잔존 정리 — 보관 디렉토리에서 `keeping`(장부의 세션)·현재 원장 세션이 **아닌** 파일을 지운다.
    /// 영구 보관이라 어느 정리 경로가 빠져도(앱이 정리 도중 죽는 등) 쌓이기만 한다 — 그 누수를 실행마다 회수한다.
    func purgeStaleRecordings(keeping sessionId: Int?) {
        let owned = ledger.sessionId
        removeStoredFiles { $0 != sessionId && $0 != owned }
    }

    /// 보관 디렉토리에서 이름 규칙상 소속 세션이 `shouldRemove` 를 만족하는 파일 삭제 — 추적 배열에서도 뺀다.
    private func removeStoredFiles(where shouldRemove: (Int) -> Bool) {
        let directory = SegmentLedger.directory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names {
            guard let owner = SegmentLedger.sessionId(ofFileName: name), shouldRemove(owner) else { continue }
            removeTracked(directory.appendingPathComponent(name))
        }
    }

    /// 이 프로세스가 처음 보는 세션이면 디스크 매니페스트로 원장을 되살리고, 복원한 파일을 폐기 추적에 편입한다.
    /// 길이 없는(열린) 항목은 파일에서 길이를 잰다 — 마감까지 끝나고 죽었으면 읽히고, 기록 중에 죽었으면 못 읽는다.
    private func restoreLedgerIfNeeded(sessionId: Int) async {
        guard ledger.sessionId != sessionId,
              let data = try? Data(contentsOf: SegmentLedger.manifestURL(sessionId: sessionId)),
              let manifest = try? JSONDecoder().decode(SegmentLedger.Manifest.self, from: data),
              manifest.sessionId == sessionId
        else { return }
        var measured: [URL: Double] = [:]
        var recoveredAudioStarts: [URL: Double] = [:]
        for entry in manifest.entries where entry.videoDurationSeconds == nil {
            let url = SegmentLedger.directory.appendingPathComponent(entry.videoFileName)
            measured[url] = await Self.readableDuration(of: url)
        }
        // 마감 없이 죽은 세그먼트의 오디오 — 스탬프(첫 버퍼 시각)가 있고 파일이 읽힐 때만 짝으로 살린다.
        // 못 읽는 오디오를 넘기면 합성이 통째로 실패해 영상 전체를 잃는다(무음 세그먼트가 낫다).
        for entry in manifest.entries where entry.audioStartedAtHostSeconds == nil {
            guard let name = entry.audioFileName else { continue }
            let url = SegmentLedger.directory.appendingPathComponent(name)
            recoveredAudioStarts[url] = await Self.recoverAudio(at: url)?.startedAtHostSeconds
        }
        ledger.restore(
            manifest,
            in: SegmentLedger.directory,
            fileExists: { FileManager.default.fileExists(atPath: $0.path) },
            measuredDuration: { measured[$0] },
            recoveredAudioStart: { recoveredAudioStarts[$0] }
        )
        for segment in ledger.segments {
            track(segment.videoURL, segment.audio?.fileURL, segment.audio.map { SegmentLedger.audioStartStampURL(for: $0.fileURL) })
        }
        Self.logger.notice("원장 복원 — session \(sessionId), 세그먼트 \(self.ledger.segments.count)개, \(self.ledger.cumulativeSeconds)s")
    }

    /// 예약 경로의 세션 오디오를 짝으로 되살린다 — 스탬프(첫 버퍼 시각)가 있고 파일이 읽힐 때만.
    private static func recoverAudio(at url: URL) async -> RecordingAudioSegment? {
        guard let raw = try? String(contentsOf: SegmentLedger.audioStartStampURL(for: url), encoding: .utf8),
              let startedAt = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              await readableDuration(of: url) != nil
        else { return nil }
        return RecordingAudioSegment(fileURL: url, startedAtHostSeconds: startedAt)
    }

    /// 읽을 수 있는 미디어 길이(초) — 못 열거나 0 이하·비유한이면 nil. 마감 없이 죽은 파일 판정용.
    private static func readableDuration(of url: URL) async -> Double? {
        guard let seconds = try? await AVURLAsset(url: url).load(.duration).seconds, seconds.isFinite, seconds > 0
        else { return nil }
        return seconds
    }

    /// 보관 디렉토리 준비 — iCloud 백업 제외(수백 MB 임시 산출물).
    private func ensureStorageDirectory() {
        var directory = SegmentLedger.directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
    }

    /// 세션 오디오(Speech 가 tmp 에 쓴 것)를 보관 디렉토리로 옮겨 원장 소유로 만든다 — tmp 에 두면 앱이 안 도는
    /// 사이 OS 가 지울 수 있다. 옮기기 실패면 원래 자리 그대로 쓴다(이 프로세스 안의 합성엔 지장 없다).
    private func adoptAudio(_ audio: RecordingAudioSegment, sessionId: Int, index: Int) -> RecordingAudioSegment {
        let destination = SegmentLedger.audioURL(sessionId: sessionId, index: index)
        guard audio.fileURL != destination else { return audio }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: audio.fileURL, to: destination)
        } catch {
            Self.logger.error("세션 오디오 이동 실패: \(String(describing: error))")
            return audio
        }
        lastFileURLs.removeAll { $0 == audio.fileURL }
        track(destination)
        return RecordingAudioSegment(fileURL: destination, startedAtHostSeconds: audio.startedAtHostSeconds)
    }

    /// 원장을 매니페스트로 기록 — 기록 시작·마감 직전·마감 뒤. 실패는 로그만(재실행 재개만 잃고 이 프로세스 흐름은 그대로다).
    private func persistManifest() {
        guard let manifest = ledger.manifest else { return }
        do {
            ensureStorageDirectory()
            try JSONEncoder().encode(manifest)
                .write(to: SegmentLedger.manifestURL(sessionId: manifest.sessionId), options: .atomic)
        } catch {
            Self.logger.error("원장 기록 실패: \(String(describing: error))")
        }
    }

    /// 원장 리셋 + 그 세션 매니페스트 삭제 — 파일을 지운 뒤의 리셋은 전부 이걸 쓴다.
    private func resetLedger() {
        if let sessionId = ledger.sessionId {
            try? FileManager.default.removeItem(at: SegmentLedger.manifestURL(sessionId: sessionId))
        }
        ledger.reset()
    }
}

/// AVCaptureFileOutputRecordingDelegate 를 async 로 브릿지 — 시작·종료 콜백을 continuation 으로 전달.
/// 콜백 스레드와 액터가 만나는 지점이라 락으로 좁게 보호한다 (@unchecked 근거).
final class MovieRecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var didStart = false
    private var finishResult: Result<Void, Error>?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var finishContinuation: CheckedContinuation<Void, Error>?
    private var startedAt: Double?

    /// 비디오 기록 시작 호스트시각(초) — 합성 시 오디오 오프셋 보정 기준 (스펙 §①). 읽기도 락으로 보호.
    var startedAtHostSeconds: Double? {
        lock.lock()
        defer { lock.unlock() }
        return startedAt
    }

    func waitUntilStarted() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            defer { lock.unlock() }
            if didStart { return continuation.resume() }
            // 시작 콜백 없이 이미 끝났으면 기록은 서지 않은 것 — 성공 플래그여도 대기하지 않는다(콜백 경로와 대칭).
            switch finishResult {
            case .none: startContinuation = continuation
            case .success: continuation.resume(throwing: RecordingError.startFailed("기록 시작 전 종료"))
            case let .failure(error): continuation.resume(throwing: error)
            }
        }
    }

    func waitUntilFinished() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            defer { lock.unlock() }
            if let finishResult { return continuation.resume(with: finishResult) }
            finishContinuation = continuation
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        lock.lock()
        defer { lock.unlock() }
        didStart = true
        startedAt = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        startContinuation?.resume()
        startContinuation = nil
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        lock.lock()
        defer { lock.unlock() }
        // 정상 정지도 error 에 성공 플래그를 실어 오는 경우가 있다 — 플래그가 진실.
        let succeeded = ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) ?? (error == nil)
        let result: Result<Void, Error> = succeeded ? .success(()) : .failure(error ?? RecordingError.stopFailed("원인 미상"))
        finishResult = result
        startContinuation?.resume(throwing: error ?? RecordingError.startFailed("기록 시작 전 종료"))
        startContinuation = nil
        finishContinuation?.resume(with: result)
        finishContinuation = nil
    }
}
