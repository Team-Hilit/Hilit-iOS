//
//  SmokeUITests.swift
//  HilitUITests
//
//  Created by EunSeo on 26/11/18.
//

import XCTest

/// 세팅 확인용 — 서명·설치·실행·백그라운드 왕복이 실기기에서 도는지만 본다.
/// 시나리오(면접 녹화·재개 등)는 이 위에 파일을 하나씩 늘린다.
final class SmokeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchAndBackgroundRoundTrip() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "앱이 앞에 뜨지 않음")
        DeviceActions.attachScreenshot("launched", to: self)

        DeviceActions.sendToBackground()
        // 곧장 suspended 로 넘어가기도 해서 runningBackground 하나만 기다리면 놓친다.
        let leftForeground = expectation(for: NSPredicate { _, _ in
            [.runningBackground, .runningBackgroundSuspended].contains(app.state)
        }, evaluatedWith: nil)
        wait(for: [leftForeground], timeout: 10)

        XCTAssertTrue(DeviceActions.bringToForeground(app), "복귀하지 못함")
        DeviceActions.attachScreenshot("returned", to: self)
    }
}
