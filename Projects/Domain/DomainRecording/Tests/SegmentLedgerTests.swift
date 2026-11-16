//
//  SegmentLedgerTests.swift
//  DomainRecordingTests
//
//  Created by 서정원 on 26/08/08.
//

import DomainRecordingInterface
import Foundation
import Testing

@testable import DomainRecordingImplementation

// 세그먼트 원장 순수 로직(스펙 ①) — AVFoundation 없이 누적·네이밍·세션 전환을 고정한다.
struct SegmentLedgerTests {
    private func segment(duration: Double) -> SegmentLedger.Segment {
        SegmentLedger.Segment(
            videoURL: URL(fileURLWithPath: "/tmp/v.mp4"),
            videoStartedAtHostSeconds: 0,
            videoDurationSeconds: duration,
            audio: nil
        )
    }

    @Test("begin 은 세그먼트 인덱스가 붙은 경로를 주고, append 가 누적초를 쌓는다")
    func beginAndAppendAccumulate() {
        var ledger = SegmentLedger()
        let first = ledger.begin(sessionId: 7)
        #expect(first.lastPathComponent == "interview-video-7-0.mp4")
        ledger.append(segment(duration: 60.4))
        #expect(ledger.cumulativeSeconds == 60.4)
        let second = ledger.begin(sessionId: 7)
        #expect(second.lastPathComponent == "interview-video-7-1.mp4")
    }

    @Test("다른 세션으로 begin 하면 원장이 리셋된다 — 이전 세션 세그먼트가 새 세션에 섞이지 않는다")
    func beginWithNewSessionResets() {
        var ledger = SegmentLedger()
        _ = ledger.begin(sessionId: 7)
        ledger.append(segment(duration: 30))
        let url = ledger.begin(sessionId: 8)
        #expect(ledger.segments.isEmpty)
        #expect(ledger.cumulativeSeconds == 0)
        #expect(url.lastPathComponent == "interview-video-8-0.mp4")
    }

    @Test("합성본 경로는 세션 단일 — 업로드 큐 이관 계약과 같은 이름 규칙")
    func mergedURLNaming() {
        #expect(SegmentLedger.mergedURL(sessionId: 7).lastPathComponent == "interview-recording-7.mp4")
    }

    // MARK: - 원장 영속(HLT-78)

    private let directory = URL(fileURLWithPath: "/recordings", isDirectory: true)

    private func persistedSegment(_ index: Int, duration: Double, withAudio: Bool) -> SegmentLedger.Segment {
        SegmentLedger.Segment(
            videoURL: directory.appendingPathComponent("interview-video-7-\(index).mp4"),
            videoStartedAtHostSeconds: 100 + Double(index),
            videoDurationSeconds: duration,
            audio: withAudio
                ? RecordingAudioSegment(
                    fileURL: directory.appendingPathComponent("interview-audio-7-\(index).m4a"),
                    startedAtHostSeconds: 100.2 + Double(index)
                )
                : nil
        )
    }

    @Test("매니페스트로 되살린 원장은 원래 원장과 같다 — 앱이 죽은 뒤 누적초·다음 인덱스가 이어진다")
    func manifestRoundTripRestoresLedger() throws {
        var original = SegmentLedger()
        _ = original.begin(sessionId: 7)
        original.append(persistedSegment(0, duration: 30, withAudio: true))
        original.append(persistedSegment(1, duration: 12.5, withAudio: false))
        let manifest = try #require(original.manifest)
        let decoded = try JSONDecoder().decode(SegmentLedger.Manifest.self, from: JSONEncoder().encode(manifest))

        var restored = SegmentLedger()
        restored.restore(decoded, in: directory) { _ in true }

        #expect(restored == original)
        #expect(restored.cumulativeSeconds == 42.5)
        // 다음 begin 은 같은 세션이라 리셋하지 않고 인덱스 2 를 연다.
        #expect(restored.begin(sessionId: 7).lastPathComponent == "interview-video-7-2.mp4")
    }

    @Test("매니페스트는 경로가 아니라 파일 이름만 담는다 — 컨테이너 경로가 바뀌어도 새 디렉토리 기준으로 풀린다")
    func manifestStoresFileNamesOnly() throws {
        var ledger = SegmentLedger()
        _ = ledger.begin(sessionId: 7)
        ledger.append(persistedSegment(0, duration: 30, withAudio: true))
        let manifest = try #require(ledger.manifest)
        #expect(manifest.entries.first?.videoFileName == "interview-video-7-0.mp4")
        #expect(manifest.entries.first?.audioFileName == "interview-audio-7-0.m4a")

        let moved = URL(fileURLWithPath: "/new-container/recordings", isDirectory: true)
        var restored = SegmentLedger()
        restored.restore(manifest, in: moved) { _ in true }
        #expect(restored.segments.first?.videoURL == moved.appendingPathComponent("interview-video-7-0.mp4"))
    }

    @Test("비디오가 없는 세그먼트에서 복원을 멈춘다 — 건너뛰면 뒤가 당겨져 누적초가 어긋난다")
    func restoreStopsAtMissingVideo() throws {
        var ledger = SegmentLedger()
        _ = ledger.begin(sessionId: 7)
        ledger.append(persistedSegment(0, duration: 30, withAudio: true))
        ledger.append(persistedSegment(1, duration: 20, withAudio: true))
        ledger.append(persistedSegment(2, duration: 10, withAudio: true))
        let manifest = try #require(ledger.manifest)
        let missing = directory.appendingPathComponent("interview-video-7-1.mp4")

        var restored = SegmentLedger()
        restored.restore(manifest, in: directory) { $0 != missing }

        #expect(restored.segments.count == 1)
        #expect(restored.cumulativeSeconds == 30)
    }

    @Test("오디오만 없으면 무음 세그먼트로 살린다")
    func restoreKeepsSegmentWithoutAudio() throws {
        var ledger = SegmentLedger()
        _ = ledger.begin(sessionId: 7)
        ledger.append(persistedSegment(0, duration: 30, withAudio: true))
        let manifest = try #require(ledger.manifest)
        let audio = directory.appendingPathComponent("interview-audio-7-0.m4a")

        var restored = SegmentLedger()
        restored.restore(manifest, in: directory) { $0 != audio }

        #expect(restored.segments.count == 1)
        #expect(restored.segments.first?.audio == nil)
    }

    // MARK: - 열린 세그먼트(마감 도중 앱 킬 — 2026-11-17 실기기)

    /// 세그먼트 0 은 마감 완료, 세그먼트 1 은 열린 채(오디오는 마감 직전 붙음) 프로세스가 죽은 원장.
    private func ledgerKilledWhileFinalizing() -> SegmentLedger {
        var ledger = SegmentLedger()
        _ = ledger.begin(sessionId: 7)
        ledger.append(persistedSegment(0, duration: 30, withAudio: true))
        let video = ledger.begin(sessionId: 7)
        ledger.open(videoURL: video, startedAtHostSeconds: 200)
        ledger.attachOpenAudio(RecordingAudioSegment(
            fileURL: directory.appendingPathComponent("interview-audio-7-1.m4a"),
            startedAtHostSeconds: 200.3
        ))
        return ledger
    }

    @Test("열린 세그먼트는 길이 없는 마지막 항목으로 매니페스트에 오른다 — 마감 전에 이미 디스크에 있다")
    func openSegmentIsPersistedWithoutDuration() throws {
        let manifest = try #require(ledgerKilledWhileFinalizing().manifest)
        #expect(manifest.entries.count == 2)
        let last = try #require(manifest.entries.last)
        #expect(last.videoFileName == "interview-video-7-1.mp4")
        #expect(last.videoDurationSeconds == nil)
        #expect(last.audioFileName == "interview-audio-7-1.m4a")
    }

    @Test("append 가 열린 세그먼트를 닫는다 — 같은 파일이 두 항목으로 남지 않는다")
    func appendClosesOpenSegment() throws {
        var ledger = ledgerKilledWhileFinalizing()
        ledger.append(persistedSegment(1, duration: 8, withAudio: true))
        let manifest = try #require(ledger.manifest)
        #expect(ledger.openSegment == nil)
        #expect(manifest.entries.map(\.videoDurationSeconds) == [30, 8])
    }

    @Test("마감이 끝난 뒤 죽은 열린 항목은 파일에서 잰 길이로 오디오와 함께 살아난다")
    func restoreMeasuresFinalizedOpenSegment() throws {
        let manifest = try #require(ledgerKilledWhileFinalizing().manifest)
        var restored = SegmentLedger()
        restored.restore(manifest, in: directory, fileExists: { _ in true }, measuredDuration: { _ in 12 })

        #expect(restored.segments.count == 2)
        #expect(restored.cumulativeSeconds == 42)
        #expect(restored.segments.last?.audio?.startedAtHostSeconds == 200.3)
        #expect(restored.openSegment == nil)
        #expect(restored.begin(sessionId: 7).lastPathComponent == "interview-video-7-2.mp4")
    }

    @Test("기록 중에 죽어 길이를 못 재는 열린 항목에서 멈춘다 — 다음 begin 이 그 인덱스를 다시 쓴다")
    func restoreStopsAtUnreadableOpenSegment() throws {
        let manifest = try #require(ledgerKilledWhileFinalizing().manifest)
        for unreadable: Double? in [nil, 0, .nan] {
            var restored = SegmentLedger()
            restored.restore(manifest, in: directory, fileExists: { _ in true }, measuredDuration: { _ in unreadable })
            #expect(restored.segments.count == 1)
            #expect(restored.begin(sessionId: 7).lastPathComponent == "interview-video-7-1.mp4")
        }
    }

    /// 마감 없이(앱 전환기 킬) 죽은 원장 — 열린 항목엔 오디오 «이름» 만 있고 시각은 스탬프 파일에 있다.
    private func ledgerKilledWithoutFinalize() -> SegmentLedger {
        var ledger = SegmentLedger()
        let video = ledger.begin(sessionId: 7)
        ledger.open(
            videoURL: video,
            startedAtHostSeconds: 200,
            reservedAudioURL: directory.appendingPathComponent("interview-audio-7-0.m4a")
        )
        return ledger
    }

    @Test("기록 시작 때 정한 오디오 자리는 시각 없이 이름부터 매니페스트에 오른다")
    func reservedAudioIsPersistedByName() throws {
        let entry = try #require(ledgerKilledWithoutFinalize().manifest?.entries.first)
        #expect(entry.audioFileName == "interview-audio-7-0.m4a")
        #expect(entry.audioStartedAtHostSeconds == nil)
        #expect(entry.videoDurationSeconds == nil)
    }

    @Test("마감 없이 죽은 세그먼트는 스탬프 시각으로 오디오 짝까지 살아난다 — 크래시 전 답변이 무음이 되지 않는다")
    func restoreRecoversAudioFromStamp() throws {
        let manifest = try #require(ledgerKilledWithoutFinalize().manifest)
        let audioURL = directory.appendingPathComponent("interview-audio-7-0.m4a")
        var restored = SegmentLedger()
        restored.restore(
            manifest, in: directory,
            fileExists: { _ in true },
            measuredDuration: { _ in 46.3 },
            recoveredAudioStart: { $0 == audioURL ? 200.15 : nil }
        )
        let segment = try #require(restored.segments.first)
        #expect(segment.videoDurationSeconds == 46.3)
        #expect(segment.audio == RecordingAudioSegment(fileURL: audioURL, startedAtHostSeconds: 200.15))
    }

    @Test("스탬프가 없거나 오디오를 못 읽으면(호출부가 nil) 무음 세그먼트로 산다 — 합성 실패보다 낫다")
    func restoreWithoutRecoverableAudioKeepsSilentSegment() throws {
        let manifest = try #require(ledgerKilledWithoutFinalize().manifest)
        var restored = SegmentLedger()
        restored.restore(manifest, in: directory, fileExists: { _ in true }, measuredDuration: { _ in 46.3 })
        #expect(restored.segments.count == 1)
        #expect(restored.segments.first?.audio == nil)
    }

    @Test("스탬프 파일은 오디오 이름 뒤 .start — 정리 규칙(interview-audio- 접두)에 함께 걸린다")
    func audioStartStampNaming() {
        let stamp = SegmentLedger.audioStartStampURL(for: directory.appendingPathComponent("interview-audio-7-0.m4a"))
        #expect(stamp.lastPathComponent == "interview-audio-7-0.m4a.start")
        #expect(SegmentLedger.sessionId(ofFileName: stamp.lastPathComponent) == 7)
    }

    @Test("dropOpenSegment 는 마감 실패한 열린 항목을 매니페스트에서 내린다")
    func dropOpenSegmentRemovesEntry() throws {
        var ledger = ledgerKilledWhileFinalizing()
        ledger.dropOpenSegment()
        let manifest = try #require(ledger.manifest)
        #expect(manifest.entries.count == 1)
    }

    @Test("보관 파일 이름에서 소속 세션을 읽는다 — 규칙 밖 이름은 nil(남의 파일은 건드리지 않는다)")
    func sessionIdFromFileName() {
        #expect(SegmentLedger.sessionId(ofFileName: "interview-video-12-3.mp4") == 12)
        #expect(SegmentLedger.sessionId(ofFileName: "interview-audio-12-0.m4a") == 12)
        #expect(SegmentLedger.sessionId(ofFileName: "interview-recording-12.mp4") == 12)
        #expect(SegmentLedger.sessionId(ofFileName: "interview-ledger-12.json") == 12)
        #expect(SegmentLedger.sessionId(ofFileName: "journal.json") == nil)
        #expect(SegmentLedger.sessionId(ofFileName: "interview-video-x.mp4") == nil)
    }
}
