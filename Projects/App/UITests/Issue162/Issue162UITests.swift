//
//  Issue162UITests.swift
//  HilitUITests
//
//  Created by EunSeo on 26/11/18.
//

import XCTest

/// #162 (HLT-111) — 로그아웃 시 면접 로컬 데이터(보관값·draft·녹화 잔존 파일) 정리 확인.
/// 면접 진행·소셜 로그인은 사람이 조작하고, 테스트는 화면 도달만 기다린다.
/// 녹화 파일 판정은 test1 직후 `make device-qa cmd=pull` 로 tmp 에 `interview-*` 가 없는지 본다.
/// 실행: `make uitest device='<기기>' only=Issue162UITests` — test1 → test2 순서(이름순)로 돈다.
/// 끝나면 test2 의 재로그인까지 마쳐야 기기 로그인이 원래대로 돌아온다. → docs/device-qa.md
final class Issue162UITests: XCTestCase {
    private enum Marker {
        static let home = "밑으로 스크롤해서 면접을 시작해 보세요"
        static let login = "Sign in with Kakao"
        static let recording = "답변 녹음 중"
        static let resume = "이어서 진행"
        static let logout = "로그아웃"
        static let logoutConfirm = "로그아웃하시겠어요?"
    }

    override func setUp() {
        continueAfterFailure = false
    }

    /// 면접 녹화 중 백그라운드 → 홈 «이어서 진행» 카드 → 마이페이지 로그아웃 → 로그인 화면.
    @MainActor
    func test1LogoutAfterHeldInterview() {
        let app = XCUIApplication()
        app.launch()
        waitForHome(app, prompt: "로그인되어 있지 않음 — 소셜 로그인으로 홈까지 진행해 주세요")

        guide("면접을 시작해 «\(Marker.recording)» 상태까지 진행해 주세요 (권한 팝업은 허용)")
        XCTAssertTrue(app.waitFor(Marker.recording, timeout: 600), "녹화 중 화면에 도달하지 못함")
        DeviceActions.attachScreenshot("1-recording", to: self)

        DeviceActions.sendToBackground()
        sleep(3)  // 세그먼트 마감·held 저장 시간
        XCTAssertTrue(DeviceActions.bringToForeground(app), "복귀하지 못함")

        XCTAssertTrue(app.waitFor(Marker.home, timeout: 30), "백그라운드 복귀 후 홈으로 나오지 않음")
        XCTAssertTrue(app.waitFor(Marker.resume, timeout: 30), "홈에 «이어서 진행» 카드가 없음 — 보관값 저장 실패")
        DeviceActions.attachScreenshot("2-home-resume-card", to: self)

        tapProfile(app)
        app.tap(Marker.logout)
        XCTAssertTrue(app.waitFor(Marker.logoutConfirm), "로그아웃 확인 모달이 뜨지 않음")
        tapModalConfirm(app, label: Marker.logout)

        XCTAssertTrue(app.waitFor(Marker.login, timeout: 30), "로그아웃 후 로그인 화면에 도달하지 못함")
        DeviceActions.attachScreenshot("3-login", to: self)
    }

    /// 로그아웃 뒤 재로그인 — 홈에 이전 세션의 «이어서 진행» 카드가 남지 않아야 한다.
    @MainActor
    func test2ReloginHasNoResumeCard() {
        let app = XCUIApplication()
        app.launch()
        waitForHome(app, prompt: "소셜 로그인으로 다시 로그인해 주세요 (최대 3분 대기)")

        // 프로필·held 검증 응답이 늦게 와 카드가 뒤늦게 뜨는 경우까지 본다.
        XCTAssertFalse(app.waitFor(Marker.resume, timeout: 10), "재로그인 홈에 «이어서 진행» 카드가 남아 있음")
        DeviceActions.attachScreenshot("4-relogin-home", to: self)
    }

    // MARK: - 헬퍼 (이 이슈 전용)

    /// 홈이면 통과, 로그인 화면이면 사람이 로그인할 때까지 최대 3분 기다린다.
    @MainActor
    private func waitForHome(_ app: XCUIApplication, prompt: String) {
        if app.waitFor(Marker.home, timeout: 15) { return }
        guide(prompt)
        XCTAssertTrue(app.waitFor(Marker.home, timeout: 180), "홈에 도달하지 못함")
    }

    /// 홈 내비바 오른쪽 프로필 아이콘 — DS 컴포넌트라 식별자가 없어 내비바의 가장 오른쪽 버튼을 누른다.
    @MainActor
    private func tapProfile(_ app: XCUIApplication) {
        let bar = app.navigationBars.firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "내비바 없음")
        let buttons = bar.buttons.allElementsBoundByIndex.filter(\.isHittable)
        guard let profile = buttons.max(by: { $0.frame.maxX < $1.frame.maxX }) else {
            return XCTFail("프로필 버튼을 못 찾음")
        }
        profile.tap()
    }

    /// 모달의 확인 버튼 — 아래 화면의 같은 이름 버튼(«로그아웃»)과 겹치므로 화면에서 가장 아래 것을 누른다.
    @MainActor
    private func tapModalConfirm(_ app: XCUIApplication, label: String) {
        let candidates = app.buttons.matching(NSPredicate(format: "label == %@", label))
            .allElementsBoundByIndex.filter(\.isHittable)
        guard let confirm = candidates.max(by: { $0.frame.minY < $1.frame.minY }) else {
            return XCTFail("모달 «\(label)» 버튼을 못 찾음")
        }
        confirm.tap()
    }

    /// 사람 조작 안내 — xcodebuild 로그와 xcresult 활동 이름에 남는다.
    private func guide(_ message: String) {
        print("👉 [Issue162] \(message)")
        XCTContext.runActivity(named: "👉 \(message)") { _ in }
    }
}
