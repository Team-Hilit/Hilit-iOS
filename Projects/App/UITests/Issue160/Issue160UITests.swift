//
//  Issue160UITests.swift
//  HilitUITests
//
//  Created by EunSeo on 26/11/18.
//

import XCTest

/// #160 녹화 보관·재개 — 자동화 가능한 부분만. 녹화 파일·held·원장 확인은 테스트 밖
/// `make device-qa cmd=pull` 몫이고, 진짜 강제 종료(SIGKILL)는 `make device-qa cmd=kill` 이 기준이다.
/// 실행: `make uitest device='<기기>' only=Issue160UITests`. → docs/device-qa.md
///
/// 진행 중 세션이 있으면 새로 만들지 않고 이어서 들어간다 — 케이스를 연달아 돌려도 이용권은 한 장.
final class Issue160UITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// HLT-41·78 백그라운드 마감 — 답변 중 홈 버튼 → 복귀하면 세션이 동결돼 홈 «이어서 진행» 으로 돌아오고,
    /// 탭하면 새 세그먼트로 녹화·시계가 다시 돈다.
    @MainActor
    func testBackgroundThenResumeRestartsRecording() throws {
        let app = XCUIApplication()
        app.launch()
        try reachAnswering(app)

        DeviceActions.sendToBackground()
        Thread.sleep(forTimeInterval: 3)
        XCTAssertTrue(DeviceActions.bringToForeground(app), "복귀하지 못함")
        DeviceActions.attachScreenshot("returned", to: self)

        try assertResumeCardThenRecording(app)
    }

    /// HLT-78 앱 종료 후 재개 — `app.terminate()` 로 끝낸 뒤 다시 실행.
    ///
    /// `terminate()` 는 testmanagerd 가 프로세스를 내리는 XCTest 경로라, 앱 전환기에서 쓸어 올린 SIGKILL
    /// (`device-qa.sh kill`)과 같은 경로인지 확인되지 않았다 — 마감 코드가 돌 수도 있다. 그래서 이 케이스는
    /// «XCTest 종료» 로 이름을 나눠 둔다. SIGKILL 판정은 `make device-qa cmd=force-kill` 로 한다.
    @MainActor
    func testXCTestTerminateThenResumeRestartsRecording() throws {
        let app = XCUIApplication()
        app.launch()
        try reachAnswering(app)

        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "종료되지 않음")
        app.launch()
        DeviceActions.attachScreenshot("relaunched", to: self)

        try assertResumeCardThenRecording(app)
    }

    /// HLT-41 네트워크 오버레이 — **사람 조작 혼합**. 답변 중에 사람이 비행기 모드를 켜고 [답변 완료하기] 를
    /// 누르면 «연결이 끊겼어요» 가 뜬다(120초 대기). 오버레이 동안 시계가 멈췄는지 보고, 사람이 비행기 모드를
    /// 끄도록 30초 기다린 뒤 [이어서 진행하기] → 다음 질문으로 넘어가는지 본다.
    /// USB 로 연결해 돌릴 것 — Wi-Fi 디버깅이면 비행기 모드에서 테스트 연결이 끊긴다.
    @MainActor
    func testNetworkOverlayFreezesClockAndResumes() throws {
        let app = XCUIApplication()
        app.launch()
        try reachAnswering(app)

        var lastSeen: Int?
        let overlay = app.element(containing: "연결이 끊겼어요")
        XCTContext.runActivity(named: "사람: 지금 비행기 모드 ON → [답변 완료하기] 탭") { _ in
            let deadline = Date().addingTimeInterval(120)
            while !overlay.exists, Date() < deadline {
                lastSeen = timerSeconds(app) ?? lastSeen
                Thread.sleep(forTimeInterval: 1)
            }
        }
        guard overlay.exists else {
            throw XCTSkip("120초 안에 연결 끊김 오버레이가 안 뜸 — 사람 조작 없음")
        }
        DeviceActions.attachScreenshot("overlay", to: self)

        // 칩이 오버레이 위로 보이면 그 자리에서 10초 동안 그대로인지 본다.
        if let frozen = timerSeconds(app) {
            Thread.sleep(forTimeInterval: 10)
            XCTAssertEqual(timerSeconds(app), frozen, "오버레이 중에 시간 칩이 흐름")
        }

        XCTContext.runActivity(named: "사람: 비행기 모드 OFF (30초 대기)") { _ in
            Thread.sleep(forTimeInterval: 30)
        }
        app.tap("이어서 진행하기")
        XCTAssertTrue(
            app.waitFor("질문 듣는 중", timeout: 60) || app.waitFor("답변 녹음 중", timeout: 30),
            "이어서 진행 후 다음 질문으로 못 감"
        )
        DeviceActions.attachScreenshot("after-resume", to: self)

        // 오버레이에 머문 40초+ 가 시계에 들어가지 않았는지 — 끊기기 직전 값에서 크게 뛰면 실패.
        if let before = lastSeen, let after = timerSeconds(app) {
            XCTAssertLessThan(after - before, 30, "오버레이 시간이 시계에 더해짐 (\(before)s → \(after)s)")
        }
    }

    // MARK: - 공통 판정

    /// 홈 면접 시작 겹에 [이어서 진행] 이 있고, 누르면 녹화(시간 칩)가 다시 흐르는지.
    @MainActor
    private func assertResumeCardThenRecording(_ app: XCUIApplication) throws {
        try revealStartLayer(app)
        XCTAssertTrue(app.buttons["이어서 진행"].waitForExistence(timeout: 10), "홈 «이어서 진행» 카드 없음")
        DeviceActions.attachScreenshot("resume-card", to: self)

        app.buttons["이어서 진행"].tap()
        SystemAlert.allowIfPresented()
        XCTAssertTrue(
            app.waitFor("질문 듣는 중", timeout: 60) || app.waitFor("답변 녹음 중", timeout: 60),
            "재개 후 세션 화면이 안 뜸"
        )
        XCTAssertTrue(timerAdvances(app), "재개 후 시간 칩이 멈춰 있음 — 녹화가 다시 안 열림")
        DeviceActions.attachScreenshot("resumed", to: self)
    }
}
