//
//  HeldSessionVerdictTests.swift
//  DomainInterviewTests
//
//  Created by 서정원 on 26/11/23.
//

import Foundation
import Testing

@testable import DomainInterviewInterface

// 보관값 서버 검증의 결정표 — 재개 가능 여부는 서버가 정하고, 걷는 건 «이어갈 세션이 없다» 가 확실할 때뿐이다.
struct HeldSessionVerdictTests {
    private func check(_ state: InterviewResumeState, status: InterviewEndedStatus? = nil) -> InterviewResumeCheck {
        InterviewResumeCheck(resumeState: state, startedAt: nil, elapsedSeconds: nil, status: status)
    }

    @Test("RESUMABLE 은 남긴다 — 앱이 죽었다 살아나도 서버가 이어가라 하면 이어간다")
    func resumableIsKept() {
        #expect(HeldSessionVerdict.of(check(.resumable)) == .keep)
    }

    @Test("ENDED 는 걷는다 — 이미 끝난 세션·hold 만료(서버가 GET 안에서 환불까지 마쳤다)")
    func endedIsCleared() {
        for status in [InterviewEndedStatus.completed, .abandoned, .invalid, .preloadFailed] {
            #expect(HeldSessionVerdict.of(check(.ended, status: status)) == .clear)
        }
    }

    @Test("서버가 «이어갈 수 없다» 고 확정한 실패는 걷는다 — 404 내 세션 아님·409 이미 끝남·프리로드 실패")
    func definitiveFailuresAreCleared() {
        // 안 걷으면 계정 전환 뒤 남은 카드가 탭해도 아무 일이 없는 영구 유령이 된다.
        let failures: [InterviewError] = [.sessionNotFound, .sessionAlreadyEnded, .sessionPreloadFailed]
        for failure in failures {
            #expect(HeldSessionVerdict.of(failure: failure) == .clear)
        }
    }

    // 판정 불가를 «끝났다» 로 읽으면 네트워크가 끊긴 순간 진행 중이던 세션을 되찾을 길이 사라진다.
    @Test("그 밖의 실패(네트워크·서버 장애)는 남긴다 — 판정 불가다")
    func indeterminateFailuresAreKept() {
        let failures: [any Error] = [
            URLError(.notConnectedToInternet),
            InterviewError.aiTemporarilyUnavailable,
            InterviewError.sessionNotStarted
        ]
        for failure in failures {
            #expect(HeldSessionVerdict.of(failure: failure) == .keep)
        }
    }
}
