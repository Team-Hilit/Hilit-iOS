//
//  SegmentLedger.swift
//  DomainRecordingImplementation
//
//  Created by 서정원 on 26/08/08.
//

import DomainRecordingInterface
import Foundation

// @lat: [[interview#프리뷰]]
/// 세그먼트 원장(스펙 ①) — 백그라운드 경계마다 마감된 (비디오, 세션오디오) 쌍을 세션 단위로 쌓는다.
/// actor(CameraSessionManager) 가 소유하고, 기록 시작·마감 직전·마감 뒤마다 매니페스트(JSON)로 디스크에 남겨 **앱이 죽어도**
/// 다음 프로세스가 같은 세션을 이어 녹화한다(HLT-78 — 2026-11-16 이전엔 tmp·인메모리라 재개 불가였다).
/// 파일 IO 는 여기 없다 — 경로 계산·누적·매니페스트 변환만(유닛 테스트 대상), 기록·삭제는 actor 몫.
struct SegmentLedger: Equatable {
    struct Segment: Equatable {
        let videoURL: URL
        let videoStartedAtHostSeconds: Double?
        let videoDurationSeconds: Double
        let audio: RecordingAudioSegment?
    }

    /// 디스크 표현 — 경로 대신 **파일 이름**만 담는다(앱 업데이트로 컨테이너 경로가 바뀌어도 풀리게).
    /// 호스트시각은 세그먼트 «안» 의 오디오−비디오 차로만 쓰여(립싱크) 프로세스가 바뀌어도 유효하다.
    struct Manifest: Codable, Equatable {
        struct Entry: Codable, Equatable {
            let videoFileName: String
            let videoStartedAtHostSeconds: Double?
            /// nil = 열린 세그먼트(기록 중이거나 마감 도중에 프로세스가 죽었다) — 복원 때 파일에서 길이를 잰다.
            let videoDurationSeconds: Double?
            let audioFileName: String?
            let audioStartedAtHostSeconds: Double?
        }

        let sessionId: Int
        let entries: [Entry]
    }

    /// 기록 중인(아직 길이를 모르는) 세그먼트 — 매니페스트에 길이 없이 미리 올려 둔다.
    /// 마감 단계(파일 닫기·길이 로드·오디오 이동)는 수 초 걸리고 그사이 앱이 죽을 수 있어, 원장 기록을
    /// 마감 «뒤» 에만 하면 마감이 끝난 파일조차 다음 프로세스가 모른다(2026-11-17 실기기 — 앱 전환기 킬).
    struct OpenSegment: Equatable {
        let videoURL: URL
        let videoStartedAtHostSeconds: Double?
        /// 세션 오디오를 기록할 보관 경로 — 기록 시작 때 정해 매니페스트에 이름부터 남긴다. 첫 버퍼 시각은
        /// 기록기가 옆 스탬프 파일에 남기므로, 마감 없이 죽어도 복원이 오디오 짝을 찾는다.
        let reservedAudioURL: URL?
        var audio: RecordingAudioSegment?
    }

    private(set) var sessionId: Int?
    private(set) var segments: [Segment] = []
    private(set) var openSegment: OpenSegment?

    /// 지금까지 마감된 세그먼트 길이 합 — startRecording 반환값(시계 시드)·held 갱신의 재료.
    var cumulativeSeconds: Double { segments.reduce(0) { $0 + $1.videoDurationSeconds } }

    /// 새 세그먼트 시작 — 세션이 바뀌면 원장을 리셋한다(이전 세션 잔재가 새 세션에 섞이지 않게).
    /// 반환은 이 세그먼트가 기록할 파일 경로(세션·인덱스 네이밍).
    mutating func begin(sessionId: Int) -> URL {
        if self.sessionId != sessionId {
            self.sessionId = sessionId
            segments = []
        }
        openSegment = nil
        return Self.videoURL(sessionId: sessionId, index: segments.count)
    }

    /// 기록이 실제로 시작된 세그먼트를 «열린» 상태로 올린다 — 길이는 마감 때 채운다.
    mutating func open(videoURL: URL, startedAtHostSeconds: Double?, reservedAudioURL: URL? = nil) {
        openSegment = OpenSegment(
            videoURL: videoURL,
            videoStartedAtHostSeconds: startedAtHostSeconds,
            reservedAudioURL: reservedAudioURL
        )
    }

    /// 열린 세그먼트에 짝 오디오를 붙인다 — 파일을 닫기 «전에» 기록해 두려는 것.
    mutating func attachOpenAudio(_ audio: RecordingAudioSegment) {
        openSegment?.audio = audio
    }

    /// 마감 실패로 열린 세그먼트를 버린다.
    mutating func dropOpenSegment() {
        openSegment = nil
    }

    /// 마감된 세그먼트를 올린다 — 열린 세그먼트는 이걸로 닫힌다.
    mutating func append(_ segment: Segment) {
        segments.append(segment)
        openSegment = nil
    }

    mutating func reset() {
        sessionId = nil
        segments = []
        openSegment = nil
    }

    // MARK: - 매니페스트

    /// 현재 원장의 디스크 표현 — 세션이 없으면 nil. 열린 세그먼트는 길이 없는 마지막 항목으로 들어간다.
    var manifest: Manifest? {
        guard let sessionId else { return nil }
        var entries = segments.map { segment in
            Manifest.Entry(
                videoFileName: segment.videoURL.lastPathComponent,
                videoStartedAtHostSeconds: segment.videoStartedAtHostSeconds,
                videoDurationSeconds: segment.videoDurationSeconds,
                audioFileName: segment.audio?.fileURL.lastPathComponent,
                audioStartedAtHostSeconds: segment.audio?.startedAtHostSeconds
            )
        }
        if let openSegment {
            entries.append(Manifest.Entry(
                videoFileName: openSegment.videoURL.lastPathComponent,
                videoStartedAtHostSeconds: openSegment.videoStartedAtHostSeconds,
                videoDurationSeconds: nil,
                audioFileName: (openSegment.audio?.fileURL ?? openSegment.reservedAudioURL)?.lastPathComponent,
                audioStartedAtHostSeconds: openSegment.audio?.startedAtHostSeconds
            ))
        }
        return Manifest(sessionId: sessionId, entries: entries)
    }

    /// 다른 프로세스가 남긴 매니페스트로 원장을 되살린다. `fileExists`·`measuredDuration` 은 파일 판정(테스트 주입용).
    ///
    /// 비디오가 없는 세그먼트를 만나면 **거기서 멈춘다** — 중간을 건너뛰면 뒤 세그먼트가 앞으로 당겨져
    /// 누적초(시계 시드)와 서버 마킹이 어긋난다. 오디오만 없으면 무음 세그먼트로 살린다(합성이 허용한다).
    /// 길이 없는(열린) 항목은 `measuredDuration` 으로 잰다 — 마감이 끝난 뒤 죽었으면 온전한 세그먼트로 살고,
    /// 기록 중에 죽어 파일을 못 읽으면(nil·0 이하) 거기서 멈춘다(다음 begin 이 그 인덱스를 지우고 덮는다).
    /// 시각 없는 오디오(열린 항목에 이름만 남은 것)는 `recoveredAudioStart` 로 기준 시각을 얻는다 — 스탬프가 있고
    /// 파일이 읽힐 때만 값이 온다(호출부 판정). 없으면 무음 세그먼트로 산다.
    mutating func restore(
        _ manifest: Manifest,
        in directory: URL,
        fileExists: (URL) -> Bool,
        measuredDuration: (URL) -> Double? = { _ in nil },
        recoveredAudioStart: (URL) -> Double? = { _ in nil }
    ) {
        sessionId = manifest.sessionId
        segments = []
        openSegment = nil
        for entry in manifest.entries {
            let videoURL = directory.appendingPathComponent(entry.videoFileName)
            guard fileExists(videoURL) else { break }
            let duration: Double
            if let recorded = entry.videoDurationSeconds {
                duration = recorded
            } else {
                guard let measured = measuredDuration(videoURL), measured.isFinite, measured > 0 else { break }
                duration = measured
            }
            let audio = entry.audioFileName.flatMap { name -> RecordingAudioSegment? in
                let url = directory.appendingPathComponent(name)
                guard fileExists(url),
                      let startedAt = entry.audioStartedAtHostSeconds ?? recoveredAudioStart(url)
                else { return nil }
                return RecordingAudioSegment(fileURL: url, startedAtHostSeconds: startedAt)
            }
            segments.append(Segment(
                videoURL: videoURL,
                videoStartedAtHostSeconds: entry.videoStartedAtHostSeconds,
                videoDurationSeconds: duration,
                audio: audio
            ))
        }
    }

    // MARK: - 경로

    /// 녹화 보관 디렉토리 — Application Support(앱 종료·재실행에도 남는다). tmp 는 OS 가 앱이 안 도는 사이
    /// 비울 수 있어 재개 재료를 둘 수 없다. 정리는 합성 성공·폐기·킬 클린업·실행 시점 잔존 정리가 맡는다.
    static let directory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("InterviewRecordings", isDirectory: true)

    static func videoURL(sessionId: Int, index: Int) -> URL {
        directory.appendingPathComponent("interview-video-\(sessionId)-\(index).mp4")
    }

    /// 마감된 세션 오디오의 보관 경로 — Speech 는 tmp 에 쓰므로 원장에 올릴 때 이리로 옮긴다.
    static func audioURL(sessionId: Int, index: Int) -> URL {
        directory.appendingPathComponent("interview-audio-\(sessionId)-\(index).m4a")
    }

    /// 합성본 경로 — 세션당 하나(기존 네이밍 유지 — 업로드 큐 이관·정리 규칙이 이 이름을 안다).
    static func mergedURL(sessionId: Int) -> URL {
        directory.appendingPathComponent("interview-recording-\(sessionId).mp4")
    }

    /// 세션 오디오 첫 버퍼 시각 스탬프 — `<오디오>.start`. 기록기(DomainSpeech `SessionAudioRecording.startStampURL`)와
    /// 같은 규칙이다(모듈 의존 없이 규칙만 공유). 이름이 `interview-audio-` 로 시작해 정리 규칙에도 함께 걸린다.
    static func audioStartStampURL(for audioURL: URL) -> URL {
        audioURL.appendingPathExtension("start")
    }

    static func manifestURL(sessionId: Int) -> URL {
        directory.appendingPathComponent("interview-ledger-\(sessionId).json")
    }

    /// 보관 파일 이름 → 소속 sessionId. 위 네 가지 이름 규칙이 아니면 nil(남의 파일은 건드리지 않는다).
    static func sessionId(ofFileName name: String) -> Int? {
        let prefixes = ["interview-video-", "interview-audio-", "interview-recording-", "interview-ledger-"]
        guard let prefix = prefixes.first(where: name.hasPrefix) else { return nil }
        let digits = name.dropFirst(prefix.count).prefix { $0.isNumber }
        return Int(digits)
    }
}
