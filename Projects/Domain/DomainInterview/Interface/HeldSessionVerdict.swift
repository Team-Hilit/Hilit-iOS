//
//  HeldSessionVerdict.swift
//  DomainInterviewInterface
//
//  Created by 서정원 on 26/11/23.
//

import Foundation

// @lat: [[interview#Client 계약]]
/// 보관값 서버 검증의 판정(스펙 ③④) — **재개 가능 여부는 서버가 정한다.** 효과(GET·clear·purge·홈 재조회)는
/// AppFeature 가 싣고 판정만 여기 둔다(App 테스트 타깃이 없어 결정표를 유닛으로 고정한다).
///
/// 보관값을 걷는 쪽은 «서버에 이어갈 세션이 없다» 가 **확실할 때뿐**이다. 오프라인·미로그인·5xx 같은
/// «판정 불가» 가 보관값을 지우면, 네트워크가 끊긴 순간 진행 중이던 세션을 되찾을 길이 사라진다.
public enum HeldSessionVerdict: Equatable, Sendable {
    /// RESUMABLE 이거나 판정 불가 — 보관값을 남긴다(다음 실행·복귀·카드 탭이 다시 묻는다).
    case keep
    /// 서버에 이어갈 세션이 없다 — 보관값과 세그먼트를 걷는다.
    case clear

    /// 서버가 답했다 — RESUMABLE 만 남기고 ENDED(이미 끝난 세션·hold 만료 포함)는 걷는다.
    public static func of(_ check: InterviewResumeCheck) -> Self {
        check.isResumable ? .keep : .clear
    }

    /// 서버가 못 답했다 — «이 세션은 이어갈 수 없다» 고 서버가 확정한 코드(404 내 세션 아님 — 계정 전환 등 ·
    /// 409 이미 끝남 · 409 프리로드 실패)만 걷고, 그 밖(네트워크·인증·서버 장애)은 판정 불가라 남긴다.
    public static func of(failure error: any Error) -> Self {
        switch error as? InterviewError {
        case .sessionNotFound?, .sessionAlreadyEnded?, .sessionPreloadFailed?: .clear
        default: .keep
        }
    }
}
