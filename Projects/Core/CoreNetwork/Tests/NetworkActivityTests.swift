//
//  NetworkActivityTests.swift
//  CoreNetworkTests
//
//  Created by EunseoKim on 26/08/02.
//

import CoreNetworkInterface
import Foundation
import XCTest

/// `trackingActivity()` 데코레이터의 카운터 계약을 검증한다 — 요청 중 +1, 성공·실패 무관 복귀.
/// `NetworkActivity.shared` 는 싱글톤이라 절대값 대신 시작 시점 대비 상대값으로 검증한다.
final class NetworkActivityTests: XCTestCase {
    @MainActor
    func test_요청중_카운터가_오르고_완료되면_복귀한다() async throws {
        let before = NetworkActivity.shared.inFlightCount
        let client = NetworkClient { _ in
            let during = await NetworkActivity.shared.inFlightCount
            XCTAssertEqual(during, before + 1)
            return Data()
        }.trackingActivity()

        _ = try await client.request(NetworkRequest(path: "/ping"))

        XCTAssertEqual(NetworkActivity.shared.inFlightCount, before)
    }

    @MainActor
    func test_요청_시작_즉시_입력을_차단한다() async throws {
        let client = NetworkClient { _ in
            let blocking = await NetworkActivity.shared.isBlocking
            XCTAssertTrue(blocking, "모달 표출 지연과 무관하게 요청 중엔 차단해야 한다")
            return Data()
        }.trackingActivity()

        _ = try await client.request(NetworkRequest(path: "/ping"))
    }

    @MainActor
    func test_요청이_실패해도_카운터가_복귀한다() async {
        let before = NetworkActivity.shared.inFlightCount
        let client = NetworkClient { _ in
            throw NetworkError.invalidResponse
        }.trackingActivity()

        _ = try? await client.request(NetworkRequest(path: "/ping"))

        XCTAssertEqual(NetworkActivity.shared.inFlightCount, before)
    }

    @MainActor
    func test_억제_스코프_안에서는_카운터가_오르지_않는다() async throws {
        let before = NetworkActivity.shared.inFlightCount
        let client = NetworkClient { _ in
            let during = await NetworkActivity.shared.inFlightCount
            XCTAssertEqual(during, before, "억제 스코프는 begin 을 부르지 않아야 한다")
            return Data()
        }.trackingActivity()

        try await GlobalLoadingSuppression.run {
            _ = try await client.request(NetworkRequest(path: "/poll"))
        }

        XCTAssertEqual(NetworkActivity.shared.inFlightCount, before)
    }

    @MainActor
    func test_억제는_스코프를_벗어나면_풀린다() async throws {
        let before = NetworkActivity.shared.inFlightCount
        let client = NetworkClient { _ in
            let during = await NetworkActivity.shared.inFlightCount
            XCTAssertEqual(during, before + 1)
            return Data()
        }.trackingActivity()

        // 억제는 스코프 안에서만 — 빠져나온 뒤의 요청은 다시 계측된다.
        await GlobalLoadingSuppression.run { }
        _ = try await client.request(NetworkRequest(path: "/ping"))

        XCTAssertEqual(NetworkActivity.shared.inFlightCount, before)
    }
}
