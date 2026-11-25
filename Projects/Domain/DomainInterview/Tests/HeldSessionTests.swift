//
//  HeldSessionTests.swift
//  DomainInterviewTests
//
//  Created by 서정원 on 26/08/08.
//

import Foundation
import Testing

@testable import DomainInterviewInterface

// 보관값 계약 — 재개 가능 여부는 이 값이 아니라 서버(`resumeState`)가 정한다. 여기선 저장 형태와
// 회수 경로의 «await 뒤 재검증» seam 만 고정한다([[interview#Client 계약]]).
struct HeldSessionTests {
    @Test("토큰 없는 구버전 저장값도 디코딩된다 — 옵셔널 하위호환")
    func legacyStoredValueDecodesWithoutToken() throws {
        let legacy = Data(#"{"sessionId":7,"recordedSeconds":42}"#.utf8)
        let held = try JSONDecoder().decode(HeldSession.self, from: legacy)
        #expect(held.sessionId == 7)
        #expect(held.recordedSeconds == 42)
        // 옛 장부는 [시작하기] 탭에서만 심었다 — 없는 필드를 false 로 읽으면 업그레이드 순간
        // 진행 중이던 면접의 카드가 사라진다.
        #expect(held.hasStarted)
    }

    // 프로세스 표식을 걷기 전 버전이 저장한 값이다 — 업그레이드한 사용자의 UserDefaults 에 그대로 남아 있다.
    // 디코딩이 깨지면 장부가 통째로 사라져(`load()` nil) 진행 중이던 세션을 되찾을 길이 끊긴다.
    @Test("프로세스 표식(processToken)이 든 저장값도 디코딩된다 — 모르는 키는 버린다")
    func storedValueWithRetiredTokenStillDecodes() throws {
        let stored = Data(
            #"{"sessionId":9,"recordedSeconds":120,"hasStarted":true,"processToken":"4A1E6F3C-0B7D-4E52-9C1A-2D8F5B6A7C90"}"#.utf8
        )
        let held = try JSONDecoder().decode(HeldSession.self, from: stored)
        #expect(held == HeldSession(sessionId: 9, recordedSeconds: 120))
    }

    // MARK: - 시작 전 장부 (2026-08-21 제품 결정 — 이용권이 잡힌 세션은 카드가 된다)

    @Test("hasStarted 는 저장·복원을 왕복한다 — false 가 true 로 되살아나면 카드가 유령으로 뜬다")
    func hasStartedSurvivesRoundTrip() throws {
        let held = HeldSession(sessionId: 3, recordedSeconds: 0, hasStarted: false)
        let decoded = try JSONDecoder().decode(HeldSession.self, from: JSONEncoder().encode(held))
        #expect(decoded == held)
        #expect(!decoded.hasStarted)   // 카드는 뜨되 [이어서 진행] 은 준비 화면으로 되돌아간다
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

    @Test("프리뷰 보관값은 진행 중 세션을 든다 — 홈 프리뷰의 «진행 중» 변형이 보여야 한다")
    func previewValueHoldsASession() {
        #expect(HeldSessionStore.previewValue.load() != nil)
    }
}
