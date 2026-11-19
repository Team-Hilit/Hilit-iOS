//
//  Issue159UITests.swift
//  HilitUITests
//
//  Created by EunSeo on 26/11/18.
//

import XCTest

/// #159 포트폴리오 정합 — 실기기 시나리오. 로그인된 계정 전제(로그인은 사람이 미리 해 둔다).
/// 계정 상태(포폴 유무·이번 달 교체/삭제 소진)는 테스트가 못 바꾸므로, 맞지 않으면 XCTSkip 으로 이유를 남긴다.
/// 실행: make uitest device='<기기>' only=Issue159UITests → docs/device-qa.md
final class Issue159UITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: - HLT-107 / HLT-113 차단 모달

    /// 마이페이지 포트폴리오 X(삭제) → 계정 상태에 맞는 모달 하나가 뜨는지.
    /// 소진 계정이면 차단 모달 + «…부터 다시 삭제할 수 있어요»/«남은 삭제 기회 0번» 안내까지 본다.
    @MainActor
    func testRemoveShowsModalMatchingAccountState() throws {
        let app = XCUIApplication()
        app.launch()
        try openMyPage(app)

        guard let remove = portfolioRemoveButton(app) else {
            throw XCTSkip("등록된 포트폴리오 없음 — X 가 없는 상태 (빈 판/업로드 중/실패 판)")
        }
        remove.tap()

        let shown = try waitForAnyModal(app, titles: [
            "포트폴리오를 삭제하시겠어요?",
            "포트폴리오를 삭제할 수 없어요",
        ])
        DeviceActions.attachScreenshot("remove-modal", to: self)

        if shown == "포트폴리오를 삭제할 수 없어요", app.element(containing: "한 달에 한 번만").exists {
            XCTAssertTrue(
                app.element(containing: "부터 다시 삭제할 수 있어요").exists
                    || app.element(containing: "남은 삭제 기회 0번").exists,
                "삭제 한도 모달에 다음 가능일/남은 기회 안내가 없음"
            )
        }
        app.tap("취소")
    }

    /// 포트폴리오가 없는 판의 업로드 탭 → 교체 소진 계정이면 차단 모달(HLT-113).
    /// 소진 아닌 계정은 파일 선택기로 가므로 skip.
    @MainActor
    func testUploadTapBlockedWhenReplaceExhausted() throws {
        let app = XCUIApplication()
        app.launch()
        try openMyPage(app)

        guard app.element(containing: "아직 첨부된 포트폴리오가 없어요").waitForExistence(timeout: 5) else {
            throw XCTSkip("빈 판 아님 — 등록된 포트폴리오가 있어 업로드 진입 판이 없다")
        }
        let uploadCard = app.element(containing: "최대 20")
        guard uploadCard.exists else { throw XCTSkip("업로드 진입 판을 못 찾음") }
        uploadCard.tap()

        guard app.waitFor("새로 업로드할 수 없어요", timeout: 5) else {
            DeviceActions.attachScreenshot("upload-tap-not-blocked", to: self)
            throw XCTSkip("교체 소진 계정 아님 — 차단 모달 대신 다른 화면(파일 선택기 등)")
        }
        DeviceActions.attachScreenshot("replace-blocked", to: self)
        XCTAssertTrue(
            app.element(containing: "다음 가능일:").exists || app.element(containing: "이번 달 남은 기회 0번").exists,
            "교체 차단 모달에 다음 가능일/남은 기회 안내가 없음"
        )
        app.tap("확인")
    }

    // MARK: - HLT-35 업로드 중 백그라운드

    /// 업로드 처리 중 30초+ 백그라운드 → 복귀 후 완료 판 또는 실패 판으로 끝나는지(Processing 에 멈추지 않음).
    /// 화면 이동·파일 선택은 사람이 한다 — 테스트는 «Processing...» 이 뜨기를 120초 기다린다.
    @MainActor
    func testUploadFinishesAfterBackground() throws {
        let app = XCUIApplication()
        app.launch()

        guard app.waitFor("Processing...", timeout: 120) else {
            throw XCTSkip("120초 안에 업로드가 시작되지 않음 — 사람이 파일을 고르지 않았다")
        }
        DeviceActions.attachScreenshot("processing", to: self)

        DeviceActions.sendToBackground()
        Thread.sleep(forTimeInterval: 35)
        XCTAssertTrue(DeviceActions.bringToForeground(app), "복귀하지 못함")
        DeviceActions.attachScreenshot("returned", to: self)

        let outcome = waitForAny(app, texts: [
            "Completed!",
            "업로드에 실패했어요",
            "업로드 실패",
        ], timeout: 150)
        DeviceActions.attachScreenshot("outcome", to: self)
        XCTAssertNotNil(outcome, "복귀 후 150초 안에 완료/실패 판이 뜨지 않음 — Processing 에 멈춤")
        XCTContext.runActivity(named: "결과: \(outcome ?? "없음")") { _ in }
    }

    // MARK: - HLT-106 해외 시간대

    /// 기기 시간대를 LA 로 둬도 차단 안내 날짜가 KST 기준(다음 달 1일)인지.
    /// TZ 환경변수가 실기기에서 안 먹을 수 있어, 기기 설정을 LA 로 바꾼 뒤에도 같은 테스트를 돌린다.
    @MainActor
    func testAvailabilityDateUsesKSTInLosAngeles() throws {
        let app = XCUIApplication()
        app.launchEnvironment["TZ"] = "America/Los_Angeles"
        app.launch()
        try openMyPage(app)

        // 날짜가 실리는 모달: 삭제 확인(재업로드 소진) · 삭제 한도 · 교체 차단.
        if let remove = portfolioRemoveButton(app) {
            remove.tap()
        } else if app.element(containing: "아직 첨부된 포트폴리오가 없어요").exists {
            app.element(containing: "최대 20").tap()
        } else {
            throw XCTSkip("포트폴리오 판이 등록/빈 상태가 아님")
        }

        let dateLine = waitForAny(app, texts: ["부터 다시", "다음 가능일:"], timeout: 5)
        DeviceActions.attachScreenshot("date-modal", to: self)
        guard let dateLine else {
            throw XCTSkip("날짜가 실리는 모달이 아님 — 이번 달 교체/삭제 여유가 있는 계정")
        }
        let label = app.element(containing: dateLine).label
        XCTContext.runActivity(named: "안내: \(label)") { _ in }
        XCTAssertNotNil(
            label.range(of: #"\d{1,2}월 1일"#, options: .regularExpression),
            "다음 가능일이 1일이 아님(KST 아닌 기기 시간대로 하루 밀림 의심): \(label)"
        )
        if app.element(containing: "취소").exists { app.tap("취소") } else { app.tap("확인") }
    }
}

// MARK: - 이 이슈 전용 헬퍼

private extension Issue159UITests {
    /// 홈 상단 프로필 아이콘 → 마이페이지. 아이콘에 식별자가 없어(Home 은 이 이슈 화면 아님) 위치로 찾는다 —
    /// 화면 위쪽 버튼 중 가장 오른쪽.
    @MainActor
    func openMyPage(_ app: XCUIApplication) throws {
        guard app.wait(for: .runningForeground, timeout: 15) else { throw XCTSkip("앱이 앞에 안 뜸") }
        SystemAlert.allowIfPresented(timeout: 2)
        if app.waitFor("내 포트폴리오", timeout: 3) { return }

        let screen = app.windows.firstMatch.frame
        let topButtons = app.buttons.allElementsBoundByIndex.filter {
            $0.exists && $0.isHittable && $0.frame.minY < screen.minY + 140
        }
        guard let profile = topButtons.max(by: { $0.frame.maxX < $1.frame.maxX }) else {
            DeviceActions.attachScreenshot("no-home", to: self)
            throw XCTSkip("홈 상단 버튼 없음 — 로그인 안 됐거나 홈이 아님")
        }
        profile.tap()
        guard app.waitFor("내 포트폴리오", timeout: 10) else {
            DeviceActions.attachScreenshot("no-mypage", to: self)
            throw XCTSkip("마이페이지 진입 실패")
        }
    }

    /// 등록된 포트폴리오 카드의 X — 카드(FileCard)는 DS 컴포넌트라 식별자를 안 단다.
    /// «내 포트폴리오» 아래 첫 줄에서 가장 오른쪽 작은 버튼.
    @MainActor
    func portfolioRemoveButton(_ app: XCUIApplication) -> XCUIElement? {
        let header = app.element(containing: "내 포트폴리오")
        let notice = app.element(containing: "한 달에 한 번 바꿀 수 있어요")
        guard header.waitForExistence(timeout: 5), notice.waitForExistence(timeout: 5) else { return nil }
        let top = header.frame.maxY
        let bottom = notice.frame.minY
        return app.buttons.allElementsBoundByIndex
            .filter { $0.exists && $0.frame.midY > top && $0.frame.midY < bottom && $0.frame.width < 60 }
            .max(by: { $0.frame.maxX < $1.frame.maxX })
    }

    @MainActor
    func waitForAny(_ app: XCUIApplication, texts: [String], timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let hit = texts.first(where: { app.element(containing: $0).exists }) { return hit }
            Thread.sleep(forTimeInterval: 1)
        } while Date() < deadline
        return nil
    }

    @MainActor
    func waitForAnyModal(_ app: XCUIApplication, titles: [String]) throws -> String {
        guard let hit = waitForAny(app, texts: titles, timeout: 5) else {
            DeviceActions.attachScreenshot("no-modal", to: self)
            XCTFail("모달이 뜨지 않음 (기대: \(titles.joined(separator: " / ")))")
            throw XCTSkip("모달 없음")
        }
        return hit
    }
}
