//
//  HeldSessionTests.swift
//  DomainInterviewTests
//
//  Created by 서정원 on 26/08/08.
//

import Foundation
import Testing

@testable import DomainInterviewInterface

// 프로세스 토큰 판정(스펙 ⑤) — 다른 프로세스에서 **시작된** 면접의 보관값은 재개 제안 대상이 아니다.
struct HeldSessionTests {
    @Test("토큰이 현재 프로세스면 재개 가능")
    func inProcessSessionIsResumable() {
        let held = HeldSession(sessionId: 1, recordedSeconds: 60, processToken: HeldSession.currentProcessToken)
        #expect(held.isResumableInCurrentProcess)
    }

    @Test("토큰이 다르면(죽은 프로세스) 재개 불가")
    func foreignSessionIsNotResumable() {
        let held = HeldSession(sessionId: 1, recordedSeconds: 60, processToken: UUID())
        #expect(!held.isResumableInCurrentProcess)
    }

    // 이 케이스가 «0초는 무조건 재개 가능» 이던 옛 규칙의 구멍이었다 — `recordedSeconds` 는 백그라운드
    // 마감에서만 갱신돼, 백그라운드를 거치지 않고 죽은 면접(크래시·메모리 압박)이 0초로 남는다.
    // 그걸 시작 직후 보관분(표식 없음)으로 오인하면 킬 클린업이 대상으로 잡지 못해 서버 세션이 영영 살아남는다.
    @Test("0초라도 토큰이 다르면 재개 불가 — 백그라운드 없이 죽은 면접이 0초로 남는다")
    func foreignZeroProgressSessionIsNotResumable() {
        #expect(!HeldSession(sessionId: 1, recordedSeconds: 0, processToken: UUID()).isResumableInCurrentProcess)
    }

    @Test("표식 없는 보관값은 시작 직후(녹화 열기 전) — 잃을 영상이 없어 프로세스를 넘어 재개 가능")
    func unstampedSessionIsResumable() {
        #expect(HeldSession(sessionId: 1, recordedSeconds: 0, processToken: nil).isResumableInCurrentProcess)
    }

    @Test("토큰 없는 구버전 저장값도 디코딩된다 — 옵셔널 하위호환")
    func legacyStoredValueDecodesWithoutToken() throws {
        let legacy = Data(#"{"sessionId":7,"recordedSeconds":42}"#.utf8)
        let held = try JSONDecoder().decode(HeldSession.self, from: legacy)
        #expect(held.sessionId == 7)
        #expect(held.processToken == nil)
        #expect(!held.isResumableInCurrentProcess)   // 진행분 있음 + 토큰 없음 = 죽은 프로세스 취급
        // 옛 장부는 [시작하기] 탭에서만 심었다 — 없는 필드를 false 로 읽으면 업그레이드 순간
        // 진행 중이던 면접의 카드가 사라지고 킬 클린업이 그 세션을 닫아 버린다.
        #expect(held.hasStarted)
    }

    // MARK: - 시작 전 장부 (2026-08-21 제품 결정 — 이용권이 잡힌 세션은 카드가 된다)

    // 표식을 찍지 않는 게 핵심이다 — 찍으면 앱을 껐다 켠 순간 죽은 프로세스 값이 되어 킬 클린업이
    // 세션을 닫고, 잡힌 이용권이 회수 동선 없이 사라진다.
    @Test("시작 전 장부는 표식이 없어 프로세스를 넘어 살아남는다 — 카드도 남는다")
    func unstartedSessionSurvivesRelaunch() {
        let held = HeldSession(sessionId: 1, recordedSeconds: 0, hasStarted: false, processToken: nil)
        #expect(held.isResumableInCurrentProcess)
        #expect(!held.hasStarted)   // 카드는 뜨되 [이어서 진행] 은 준비 화면으로 되돌아간다
    }

    @Test("hasStarted 는 저장·복원을 왕복한다 — false 가 true 로 되살아나면 카드가 유령으로 뜬다")
    func hasStartedSurvivesRoundTrip() throws {
        let held = HeldSession(sessionId: 3, recordedSeconds: 0, hasStarted: false, processToken: nil)
        let decoded = try JSONDecoder().decode(HeldSession.self, from: JSONEncoder().encode(held))
        #expect(decoded == held)
        #expect(!decoded.hasStarted)
    }

    // 회수 경로의 «await 뒤 재검증» seam — 왕복 사이에 새 세션이 저장되면 뒤따르는 clear·세그먼트
    // 폐기가 남의 장부에 꽂힌다([[app#Cross-feature Routing]]).
    @Test("load(matching:) 은 다른 세션으로 바뀐 장부를 돌려주지 않는다")
    func loadMatchingRejectsSwappedRecord() {
        let store = HeldSessionStore.inMemory(initial: HeldSession(sessionId: 1, recordedSeconds: 0))
        #expect(store.load(matching: 1)?.sessionId == 1)
        store.save(HeldSession(sessionId: 2, recordedSeconds: 0, hasStarted: false))
        #expect(store.load(matching: 1) == nil)
        store.clear()
        #expect(store.load(matching: 2) == nil)
    }

    // 회수 경로의 삭제 seam — «확인 → 삭제» 를 한 연산으로 묶지 않으면 그 사이에 저장된 새 장부를
    // 지워 회수 동선이 사라진다([[app#Cross-feature Routing]]).
    @Test("clearIfHolding 은 다른 세션으로 바뀐 장부를 지우지 않는다")
    func clearIfHoldingSpareSwappedRecord() {
        let store = HeldSessionStore.inMemory(initial: HeldSession(sessionId: 1, recordedSeconds: 0))
        store.save(HeldSession(sessionId: 2, recordedSeconds: 0, hasStarted: false))
        #expect(!store.clearIfHolding(1))
        #expect(store.load()?.sessionId == 2)   // 새 장부는 살아 있다 — 이용권 회수 동선이 유지된다
    }

    @Test("clearIfHolding 은 그 세션일 때만 지우고, 지운 쪽에만 true 를 준다")
    func clearIfHoldingClearsOwnRecordOnce() {
        let store = HeldSessionStore.inMemory(initial: HeldSession(sessionId: 1, recordedSeconds: 0))
        #expect(store.clearIfHolding(1))
        #expect(store.load() == nil)
        // 뒤처리(세그먼트 폐기·홈 재조회)가 반환값에 걸리므로 두 번째 호출은 false 여야 한다.
        #expect(!store.clearIfHolding(1))
    }

    @Test("프리뷰 보관값은 재개 가능하다 — 홈 프리뷰의 «진행 중» 변형이 필터에 걸려 사라지면 안 된다")
    func previewValueIsResumable() {
        #expect(HeldSessionStore.previewValue.load()?.isResumableInCurrentProcess == true)
    }
}
