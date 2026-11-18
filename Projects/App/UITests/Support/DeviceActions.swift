//
//  DeviceActions.swift
//  HilitUITests
//
//  Created by EunSeo on 26/11/18.
//

import XCTest

/// 실기기 QA 에서 반복하는 기기 조작 묶음 — 시나리오 테스트가 이것만 조합하게 한다.
/// 강제 종료·컨테이너 확인처럼 테스트 프로세스 밖 조작은 `Tools/DeviceQA/device-qa.sh` 몫. → docs/device-qa.md
enum DeviceActions {
    /// 홈 버튼 — 앱을 백그라운드로 보낸다. 녹화 세그먼트 마감·held 저장 경로를 탄다.
    static func sendToBackground() {
        XCUIDevice.shared.press(.home)
    }

    /// 백그라운드에 둔 앱을 다시 앞으로. `launch()` 와 달리 프로세스를 새로 띄우지 않는다.
    static func bringToForeground(_ app: XCUIApplication, timeout: TimeInterval = 10) -> Bool {
        app.activate()
        return app.wait(for: .runningForeground, timeout: timeout)
    }

    /// 현재 화면을 테스트 결과(xcresult)에 남긴다 — 판정 증거.
    static func attachScreenshot(_ name: String, to testCase: XCTestCase) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
    }
}
