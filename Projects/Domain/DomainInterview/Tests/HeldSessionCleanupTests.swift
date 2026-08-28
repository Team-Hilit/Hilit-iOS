//
//  HeldSessionCleanupTests.swift
//  DomainInterviewTests
//
//  Created by 서정원 on 26/08/09.
//

import Foundation
import Testing

@testable import DomainInterviewInterface

// 앱 사망 세션 정리 판정(스펙 ④) — App 테스트 타깃이 없어 판정만 순수 함수로 내려 고정한다.
struct HeldSessionCleanupTests {
    @Test("보관값 없음·표식 없는 시작 직후 보관분·현재 프로세스 보관값은 정리 대상이 아니다")
    func nonTargets() {
        #expect(HeldSessionCleanup.target(nil) == nil)
        #expect(HeldSessionCleanup.target(HeldSession(sessionId: 1, recordedSeconds: 0, processToken: nil)) == nil)
        #expect(HeldSessionCleanup.target(
            HeldSession(sessionId: 1, recordedSeconds: 60, processToken: HeldSession.currentProcessToken)
        ) == nil)
    }

    @Test("죽은 프로세스에서 시작된 면접만 정리 대상이다 — 누적초 갱신 전에 죽은 0초도 포함")
    func deadSessionIsTarget() {
        #expect(HeldSessionCleanup.target(HeldSession(sessionId: 7, recordedSeconds: 60, processToken: UUID())) == 7)
        // 백그라운드를 거치지 않고 죽어 누적초가 0 으로 남은 면접 — 원 결함이 여기였다(2026-08-09).
        #expect(HeldSessionCleanup.target(HeldSession(sessionId: 7, recordedSeconds: 0, processToken: UUID())) == 7)
        #expect(HeldSessionCleanup.target(HeldSession(sessionId: 7, recordedSeconds: 60, processToken: nil)) == 7)
    }

    // 홈 필터와 같은 술어를 부정한다는 계약의 나머지 절반 — 홈이 카드로 그리는 장부는 여기 걸리면
    // 안 된다. 걸리면 앱을 껐다 켠 사용자가 잡힌 이용권을 회수 동선 없이 잃는다(2026-08-21).
    @Test("시작 전 장부는 정리 대상이 아니다 — 홈이 그리는 것을 클린업이 뺏지 않는다")
    func unstartedSessionIsNotTarget() {
        #expect(HeldSessionCleanup.target(
            HeldSession(sessionId: 7, recordedSeconds: 0, hasStarted: false, processToken: nil)
        ) == nil)
    }

    @Test("판정 후속 — RESUMABLE 은 USER_EXIT 중단, ENDED 는 로컬 정리뿐(서버가 이미 끝냈다)")
    func followupByVerdict() {
        let resumable = InterviewResumeCheck(resumeState: .resumable, startedAt: nil, elapsedSeconds: 60, status: nil)
        let ended = InterviewResumeCheck(resumeState: .ended, startedAt: nil, elapsedSeconds: nil, status: .abandoned)
        #expect(HeldSessionCleanup.followup(resumable) == .abandonUserExit)
        #expect(HeldSessionCleanup.followup(ended) == .clearAndPurge)
    }
}
