//
//  HeldSessionCleanup.swift
//  DomainInterviewInterface
//
//  Created by 서정원 on 26/08/09.
//

import Foundation

// @lat: [[interview#Client 계약]]
/// 앱 사망 세션 정리 판정(스펙 ④) — 효과(clear·purge, 로컬만 — HLT-42)는 AppFeature 가 싣고, 판정만 여기.
/// **대상은 이제 구버전 저장값뿐이다**(HLT-78, 2026-11-16) — 영구 보관 빌드의 값은 앱이 죽어도 원장이
/// 디스크에 남아 재개 가능하므로(`isResumable`) 지우지 않는다.
/// 옛 값을 재개하지 않는 이유: 디스크 원장이 없어 앞부분 없는 영상에 마킹만 이어진다(스펙 ⑤).
public enum HeldSessionCleanup {
    /// 정리 대상 sessionId — 영구 보관 값·표식 없는 보관분(시작 직후·녹화 열기 전)·현재 프로세스 보관값은 불가침.
    /// 백그라운드를 거치지 않고 죽은 면접(0초로 남는다)도 표식이 갈려 여기 걸린다 — 2026-08-09 수정.
    /// **시작 전 장부(0초·표식 없음)는 대상이 아니다** — 잃을 영상이 없어 프로세스를 넘어 재개 가능하고,
    /// 홈이 그걸 «진행 중» 카드로 그려 [이어서 진행] 이 준비 화면으로 되돌린다([[home#진입 로드]], 2026-08-21).
    ///
    /// 조건을 인라인으로 다시 쓰지 않고 홈 필터와 **같은 술어**(`isResumable`)를 부정한다 —
    /// 두 곳이 갈라지면 «카드는 숨는데 클린업이 줍지도 않는» 보관값이 생겨 영구 고아가 된다(스펙 ④⑤).
    /// 한 술어를 공유하면 그 틈이 구조적으로 불가능하다: 숨긴 것은 반드시 정리 대상이다.
    public static func target(_ held: HeldSession?) -> Int? {
        guard let held, !held.isResumable else { return nil }
        return held.sessionId
    }
}
