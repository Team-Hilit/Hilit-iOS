//
//  SegmentLedgerTests.swift
//  DomainRecordingTests
//
//  Created by 서정원 on 26/08/08.
//

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

    // 재개 가드(스펙 ⑤) — 앱이 죽으면 원장(메모리)이 비어, 모른 채 begin 하면 인덱스 0 경로가
    // 남은 첫 세그먼트를 덮고 시계가 0 으로 돌아간다. 서버가 RESUMABLE 이어도 영상은 이어받을 수 없다.
    @Test("canContinue — 빈 원장(프로세스가 죽었다 살아난 상태)은 진행분이 있는 재개를 이어받지 못한다")
    func emptyLedgerCannotContinueProgress() {
        let ledger = SegmentLedger()
        #expect(!ledger.canContinue(sessionId: 7, fromSeconds: 130))
        // 진행분이 0초로 남은 재개도 마찬가지다 — 0초는 «진행 없음» 이 아니라 «녹화 중 죽어 기록이 없음» 일 수 있다.
        #expect(!ledger.canContinue(sessionId: 7, fromSeconds: 0))
    }

    @Test("canContinue — 그 세션을 들고 누적초가 맞을 때만 이어받는다(held 는 반올림 정수초)")
    func continuesOnlyMatchingSessionAndSeconds() {
        var ledger = SegmentLedger()
        _ = ledger.begin(sessionId: 7)
        ledger.append(segment(duration: 130.4))
        #expect(ledger.canContinue(sessionId: 7, fromSeconds: 130))
        #expect(!ledger.canContinue(sessionId: 8, fromSeconds: 130))   // 다른 세션의 원장
        #expect(!ledger.canContinue(sessionId: 7, fromSeconds: 60))    // 누적초가 다르다 — 어긋난 재개
    }
}
