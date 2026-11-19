//
//  UIQuery.swift
//  HilitUITests
//
//  Created by EunSeo on 26/11/18.
//

import XCTest

/// 시나리오 테스트 공용 조회·탭 — 세션(브랜치)마다 이 파일을 고치지 않고 가져다 쓴다(머지 충돌 방지).
/// 화면 요소는 `accessibilityIdentifier` 가 있으면 그걸로, 없으면 보이는 문구로 찾는다. → docs/device-qa.md
@MainActor
extension XCUIApplication {
    /// 문구가 들어간 아무 요소(버튼·텍스트·셀) — 정확히 일치하지 않아도 포함이면 찾는다.
    func element(containing text: String) -> XCUIElement {
        descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR identifier == %@", text, text))
            .firstMatch
    }

    /// 문구가 나타날 때까지 기다린다 — 화면 전환 판정용.
    @discardableResult
    func waitFor(_ text: String, timeout: TimeInterval = 10) -> Bool {
        element(containing: text).waitForExistence(timeout: timeout)
    }

    /// 문구가 나타날 때까지 기다렸다가 탭한다. 못 찾으면 테스트 실패.
    func tap(_ text: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let target = element(containing: text)
        guard target.waitForExistence(timeout: timeout) else {
            XCTFail("'\(text)' 를 \(Int(timeout))초 안에 못 찾음", file: file, line: line)
            return
        }
        target.tap()
    }
}

@MainActor
enum SystemAlert {
    /// 권한 팝업(카메라·마이크·알림 등)을 허용 쪽으로 누른다. 팝업이 없으면 아무것도 안 한다.
    /// 시스템 알럿은 앱이 아니라 SpringBoard 소속이라 앱 쿼리로는 안 보인다.
    static func allowIfPresented(timeout: TimeInterval = 3) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["허용", "Allow", "확인", "OK"] {
            let button = springboard.alerts.buttons[label]
            if button.waitForExistence(timeout: timeout) {
                button.tap()
                return
            }
        }
    }
}
