//
//  HeldSessionCleanup.swift
//  DomainInterviewInterface
//
//  Created by 서정원 on 26/08/09.
//

import Foundation

// @lat: [[interview#Client 계약]]
/// 앱 사망 세션 정리 판정(스펙 ④) — 효과(GET·abandon·clear·purge)는 AppFeature 가 싣고, 판정만 여기.
/// 재개하지 않는 이유: 세그먼트(tmp·프로세스 수명)가 사라져 앞부분 없는 영상에 마킹만 이어진다(스펙 ⑤).
public enum HeldSessionCleanup {
    /// 정리 대상 sessionId — 표식 없는 보관분(시작 직후·녹화 열기 전)과 현재 프로세스 보관값(살아 있는 재개 재료)은 불가침.
    /// 백그라운드를 거치지 않고 죽은 면접(0초로 남는다)도 표식이 갈려 여기 걸린다 — 2026-08-09 수정.
    /// **시작 전 장부(0초·표식 없음)는 대상이 아니다** — 잃을 영상이 없어 프로세스를 넘어 재개 가능하고,
    /// 홈이 그걸 «진행 중» 카드로 그려 사용자가 이용권을 회수한다([[home#진입 로드]], 2026-08-21).
    /// 여기서 닫아 버리면 앱을 한 번 껐다 켠 사용자가 잡힌 이용권을 잃는다.
    ///
    /// 조건을 인라인으로 다시 쓰지 않고 홈 필터와 **같은 술어**(`isResumableInCurrentProcess`)를 부정한다 —
    /// 두 곳이 갈라지면 «카드는 숨는데 클린업이 줍지도 않는» 보관값이 생겨 영구 고아가 된다(스펙 ④⑤).
    /// 한 술어를 공유하면 그 틈이 구조적으로 불가능하다: 숨긴 것은 반드시 정리 대상이다.
    public static func target(_ held: HeldSession?) -> Int? {
        guard let held, !held.isResumableInCurrentProcess else { return nil }
        return held.sessionId
    }

    public enum Followup: Equatable, Sendable {
        /// 서버가 이미 끝낸 세션(hold 만료 환불 포함 — GET 안에서 처리) — 로컬 정리만.
        case clearAndPurge
        /// 아직 RESUMABLE — 재개하지 않기로 했으므로(사용자 확정) USER_EXIT 로 닫아
        /// 진행분 리포트 생성을 트리거한다(BACK_EXIT·[처음부터 시작] 과 같은 계열).
        case abandonUserExit
    }

    public static func followup(_ check: InterviewResumeCheck) -> Followup {
        check.isResumable ? .abandonUserExit : .clearAndPurge
    }
}
