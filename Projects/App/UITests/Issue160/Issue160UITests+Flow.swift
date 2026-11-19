//
//  Issue160UITests+Flow.swift
//  HilitUITests
//
//  Created by EunSeo on 26/11/18.
//

import XCTest

/// #160 시나리오가 공유하는 경로 — 홈에서 «답변 녹음 중» 까지 데려가고, 시간 칩을 읽는다.
/// 로그인은 기기에 유지된 계정을 전제한다. 전제(이용권·로그인)가 안 맞으면 XCTSkip.
@MainActor
extension Issue160UITests {
    enum Entry {
        /// 새 면접 — 위저드(채용공고 → 포트폴리오 → 대표 프로젝트 → 준비) → 준비 화면 → 세션.
        case fresh
        /// 홈 [이어서 진행] — 준비 화면을 건너뛰고 세션으로 바로 들어간다.
        case resumed
    }

    /// 홈 면접 시작 겹에서 «답변 녹음 중» 까지. 진행 중 세션이 있으면 새로 만들지 않고 이어서 들어간다
    /// (이용권을 아끼고, 진행 중이면 [이어서 진행] 이 유일한 정상 경로라서).
    @discardableResult
    func reachAnswering(_ app: XCUIApplication) throws -> Entry {
        try revealStartLayer(app)
        let entry: Entry
        if app.buttons["이어서 진행"].exists {
            app.buttons["이어서 진행"].tap()
            entry = .resumed
        } else {
            app.tap("시작하기")
            try passWizard(app)
            try passReadiness(app)
            entry = .fresh
        }
        SystemAlert.allowIfPresented()
        XCTAssertTrue(app.waitFor("답변 녹음 중", timeout: 120), "답변 단계까지 못 감")
        DeviceActions.attachScreenshot("answering", to: self)
        return entry
    }

    /// 시트를 끝까지 내려 뒤에 깔린 면접 시작 겹을 드러낸다.
    func revealStartLayer(_ app: XCUIApplication) throws {
        guard app.waitFor("남은 면접 기회", timeout: 20) || app.waitFor("밑으로 스크롤", timeout: 5) else {
            throw XCTSkip("홈이 아님 — 로그인 상태 확인")
        }
        for _ in 0..<4 where !startLayerVisible(app) {
            app.swipeDown(velocity: .fast)
        }
        if app.buttons["홈으로"].exists {
            throw XCTSkip("남은 면접 기회 0회 — 이용권 충전 후 다시")
        }
        guard startLayerVisible(app) else {
            throw XCTSkip("면접 시작 겹을 못 드러냄")
        }
    }

    private func startLayerVisible(_ app: XCUIApplication) -> Bool {
        ["시작하기", "이어서 진행", "홈으로"].contains { app.buttons[$0].exists && app.buttons[$0].isHittable }
    }

    /// 온보딩 위저드 — 채용공고 건너뛰기 · 기존 포트폴리오 · 대표 프로젝트 건너뛰기 · 준비 완료 대기.
    private func passWizard(_ app: XCUIApplication) throws {
        XCTAssertTrue(app.waitFor("채용공고 링크", timeout: 15), "채용공고 단계가 안 뜸")
        app.tap("건너뛰기")

        XCTAssertTrue(app.waitFor("포트폴리오를", timeout: 15), "포트폴리오 단계가 안 뜸")
        if app.buttons["진행할게요"].waitForExistence(timeout: 10) {
            app.buttons["진행할게요"].tap()
        }
        let next = app.buttons["계속하기"]
        guard next.waitForExistence(timeout: 10), next.isEnabled else {
            throw XCTSkip("서버에 READY 포트폴리오 없음 — 한 번 올려 둔 계정으로")
        }
        next.tap()

        XCTAssertTrue(app.waitFor("프로젝트 내용 입력", timeout: 15), "대표 프로젝트 단계가 안 뜸")
        app.tap("건너뛰기")

        if app.buttons["대표 프로젝트 없이 진행"].waitForExistence(timeout: 3) {
            app.buttons["대표 프로젝트 없이 진행"].tap()
        }
        if app.waitFor("면접 준비에 실패했어요", timeout: 1) {
            throw XCTSkip("면접 준비 실패(서버) — 다시 시도")
        }
    }

    /// 준비 화면 — 카메라·마이크 권한을 허용하고 [면접 시작하기] 가 살아나면 누른다.
    private func passReadiness(_ app: XCUIApplication) throws {
        SystemAlert.allowIfPresented(timeout: 10)
        SystemAlert.allowIfPresented()
        let start = app.buttons["면접 시작하기"]
        XCTAssertTrue(start.waitForExistence(timeout: 180), "준비 화면이 안 뜸")
        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: start)
        wait(for: [enabled], timeout: 120)
        start.tap()
    }

    /// 세션 상단 시간 칩 «m:ss» 를 초로. 칩이 없으면(실패 오버레이가 덮는 등) nil.
    func timerSeconds(_ app: XCUIApplication) -> Int? {
        let chip = app.staticTexts
            .matching(NSPredicate(format: "label MATCHES %@", "^[0-9]+:[0-9]{2}$"))
            .firstMatch
        guard chip.exists else { return nil }
        let parts = chip.label.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return parts[0] * 60 + parts[1]
    }

    /// 시간 칩이 흐르는지 — `window` 초 사이 값이 늘면 녹화·시계가 다시 돈 것으로 본다.
    func timerAdvances(_ app: XCUIApplication, within window: TimeInterval = 5) -> Bool {
        guard let before = timerSeconds(app) else { return false }
        Thread.sleep(forTimeInterval: window)
        guard let after = timerSeconds(app) else { return false }
        return after > before
    }
}
