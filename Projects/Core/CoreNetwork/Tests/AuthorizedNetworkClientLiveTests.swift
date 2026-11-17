//
//  AuthorizedNetworkClientLiveTests.swift
//  CoreNetworkTests
//
//  Created by EunseoKim on 26/07/18.
//

import ComposableArchitecture
import CoreNetworkInterface
import XCTest
@testable import CoreNetworkImplementation

final class AuthorizedNetworkClientLiveTests: XCTestCase {
    private func makeClient(
        tokenStore: TokenStore,
        handler: @escaping @Sendable (NetworkRequest) async throws -> Data
    ) -> AuthorizedNetworkClient {
        withDependencies {
            $0.networkClient = NetworkClient(request: handler)
            $0.tokenStore = tokenStore
        } operation: {
            AuthorizedNetworkClient.liveValue
        }
    }

    func test_request_Bearer토큰을_첨부한다() async throws {
        let store = TokenStore.inMemory
        try store.save(AuthTokens(accessToken: "access-1", refreshToken: "refresh-1"))
        let client = makeClient(tokenStore: store) { request in
            XCTAssertEqual(request.headers["Authorization"], "Bearer access-1")
            return Data("{}".utf8)
        }

        _ = try await client.request(NetworkRequest(path: "/api/v1/jobs"))
    }

    func test_request_저장된_토큰이_없으면_NotAuthenticatedError() async {
        let client = makeClient(tokenStore: .inMemory) { _ in Data() }

        do {
            _ = try await client.request(NetworkRequest(path: "/api/v1/jobs"))
            XCTFail("NotAuthenticatedError 가 나야 한다")
        } catch {
            XCTAssertTrue(error is NotAuthenticatedError)
        }
    }

    func test_request_TOKEN_EXPIRED면_재발급_후_1회_재시도한다() async throws {
        let store = TokenStore.inMemory
        try store.save(AuthTokens(accessToken: "expired", refreshToken: "refresh-1"))
        let calls = LockIsolated<[String]>([])

        let client = makeClient(tokenStore: store) { request in
            calls.withValue { $0.append("\(request.method.rawValue) \(request.path) \(request.headers["Authorization"] ?? "-")") }
            switch (request.path, request.headers["Authorization"]) {
            case ("/api/v1/jobs", "Bearer expired"):
                let body = Data(#"{"success": false, "code": "TOKEN_EXPIRED", "message": "만료된 토큰입니다."}"#.utf8)
                throw NetworkError.statusCode(401, body)
            case ("/api/v1/auth/token/refresh", _):
                return Data(#"{"success": true, "data": {"accessToken": "access-2", "refreshToken": "refresh-2"}}"#.utf8)
            case ("/api/v1/jobs", "Bearer access-2"):
                return Data(#"{"success": true, "data": {"jobs": []}}"#.utf8)
            default:
                XCTFail("예상 밖 요청: \(request.path)")
                throw NetworkError.invalidURL
            }
        }

        _ = try await client.request(NetworkRequest(path: "/api/v1/jobs"))

        // Rotation — 재발급된 페어로 교체됐는지
        XCTAssertEqual(try store.load(), AuthTokens(accessToken: "access-2", refreshToken: "refresh-2"))
        XCTAssertEqual(calls.value.count, 3)  // 원요청 → 재발급 → 재시도
    }

    /// 재발급 없이 원요청 1회만 나가고 원 에러가 그대로 전파되는지 — 토큰도 그대로여야 한다.
    private func assertPassesThroughWithoutRefresh(
        status: Int,
        body: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let store = TokenStore.inMemory
        let tokens = AuthTokens(accessToken: "access-1", refreshToken: "refresh-1")
        try store.save(tokens)
        let calls = LockIsolated<[String]>([])

        let client = makeClient(tokenStore: store) { request in
            calls.withValue { $0.append(request.path) }
            throw NetworkError.statusCode(status, body)
        }

        do {
            _ = try await client.request(NetworkRequest(method: .post, path: "/api/v1/interview/sessions"))
            XCTFail("\(status) 가 그대로 전파돼야 한다", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? NetworkError, .statusCode(status, body), "원 에러 그대로", file: file, line: line)
        }
        XCTAssertEqual(calls.value, ["/api/v1/interview/sessions"], "재발급·재시도 없이 1회", file: file, line: line)
        XCTAssertEqual(try store.load(), tokens, file: file, line: line)
    }

    func test_request_403_업무거절코드는_재발급하지_않고_그대로_던진다() async throws {
        // HLT-57: 403 은 권한·업무 거절(이용권 소진·계정 정지) — 재발급 대상이 아니다.
        try await assertPassesThroughWithoutRefresh(
            status: 403,
            body: Data(#"{"success": false, "code": "NO_REMAINING_TICKET", "message": "남은 이용권이 없어요."}"#.utf8)
        )
        try await assertPassesThroughWithoutRefresh(
            status: 403,
            body: Data(#"{"success": false, "code": "ACCOUNT_SUSPENDED", "message": "정지된 계정이에요."}"#.utf8)
        )
    }

    func test_request_403_Spring기본body도_재발급하지_않는다() async throws {
        let springBody = #"{"timestamp": "2026-08-02T03:33:33.209+00:00", "status": 403, "error": "Forbidden", "#
            + #""path": "/api/v1/interview/sessions"}"#
        try await assertPassesThroughWithoutRefresh(status: 403, body: Data(springBody.utf8))
        try await assertPassesThroughWithoutRefresh(status: 403, body: Data())
    }

    func test_request_403에_만료코드가_실려도_재발급하지_않는다() async throws {
        // 판정은 «401 + 코드» 둘 다 — 상태가 401 이 아니면 코드만으로는 트리거하지 않는다.
        try await assertPassesThroughWithoutRefresh(
            status: 403,
            body: Data(#"{"success": false, "code": "TOKEN_EXPIRED", "message": "만료된 토큰입니다."}"#.utf8)
        )
    }

    func test_request_401이어도_만료코드가_아니면_재발급하지_않는다() async throws {
        try await assertPassesThroughWithoutRefresh(status: 401, body: Data())
        try await assertPassesThroughWithoutRefresh(
            status: 401,
            body: Data(#"{"success": false, "code": "UNAUTHORIZED", "message": "인증이 필요해요."}"#.utf8)
        )
    }

    func test_request_401_INVALID_TOKEN도_재발급_후_재시도한다() async throws {
        let store = TokenStore.inMemory
        try store.save(AuthTokens(accessToken: "stale", refreshToken: "refresh-1"))
        let calls = LockIsolated<[String]>([])

        let client = makeClient(tokenStore: store) { request in
            calls.withValue { $0.append(request.path) }
            switch (request.path, request.headers["Authorization"]) {
            case ("/api/v1/consents/pending", "Bearer stale"):
                throw NetworkError.statusCode(
                    401, Data(#"{"success": false, "code": "INVALID_TOKEN", "message": "유효하지 않은 토큰입니다."}"#.utf8)
                )
            case ("/api/v1/auth/token/refresh", _):
                return Data(#"{"success": true, "data": {"accessToken": "access-2", "refreshToken": "refresh-2"}}"#.utf8)
            case ("/api/v1/consents/pending", "Bearer access-2"):
                return Data(#"{"success": true, "data": {"consentStatus": "UP_TO_DATE", "items": []}}"#.utf8)
            default:
                XCTFail("예상 밖 요청: \(request.path)")
                throw NetworkError.invalidURL
            }
        }

        _ = try await client.request(NetworkRequest(path: "/api/v1/consents/pending"))

        XCTAssertEqual(try store.load(), AuthTokens(accessToken: "access-2", refreshToken: "refresh-2"))
        XCTAssertEqual(calls.value.count, 3)  // 원요청 → 재발급 → 재시도
    }

    func test_request_재시도도_401만료면_재발급을_다시_하지_않고_던진다() async throws {
        let store = TokenStore.inMemory
        try store.save(AuthTokens(accessToken: "expired", refreshToken: "refresh-1"))
        let calls = LockIsolated<[String]>([])
        let expiredBody = Data(#"{"success": false, "code": "TOKEN_EXPIRED", "message": "만료된 토큰입니다."}"#.utf8)

        let client = makeClient(tokenStore: store) { request in
            calls.withValue { $0.append(request.path) }
            if request.path == "/api/v1/auth/token/refresh" {
                return Data(#"{"success": true, "data": {"accessToken": "access-2", "refreshToken": "refresh-2"}}"#.utf8)
            }
            throw NetworkError.statusCode(401, expiredBody)
        }

        do {
            _ = try await client.request(NetworkRequest(path: "/api/v1/jobs"))
            XCTFail("재시도의 401 이 그대로 전파돼야 한다")
        } catch {
            XCTAssertEqual(error as? NetworkError, .statusCode(401, expiredBody))
        }
        // 원요청 → 재발급 → 재시도 — 재발급은 1회뿐
        XCTAssertEqual(calls.value, ["/api/v1/jobs", "/api/v1/auth/token/refresh", "/api/v1/jobs"])
    }

    func test_request_재발급이_LOGIN_EXPIRED면_토큰을_폐기하고_던진다() async throws {
        let store = TokenStore.inMemory
        try store.save(AuthTokens(accessToken: "expired", refreshToken: "dead"))

        let client = makeClient(tokenStore: store) { request in
            if request.path == "/api/v1/auth/token/refresh" {
                let body = Data(#"{"success": false, "code": "LOGIN_EXPIRED", "message": "다시 로그인해 주세요."}"#.utf8)
                throw NetworkError.statusCode(401, body)
            }
            let body = Data(#"{"success": false, "code": "TOKEN_EXPIRED", "message": "만료된 토큰입니다."}"#.utf8)
            throw NetworkError.statusCode(401, body)
        }

        do {
            _ = try await client.request(NetworkRequest(path: "/api/v1/jobs"))
            XCTFail("LOGIN_EXPIRED 가 나야 한다")
        } catch let error as ServerError {
            XCTAssertEqual(error.code, "LOGIN_EXPIRED")
            XCTAssertNil(try store.load())  // 재로그인 필요 — 세션 잔해 제거
        } catch {
            XCTFail("예상 밖 에러: \(error)")
        }
    }

    func test_api_서버에러payload를_ServerError로_승격한다() async throws {
        let store = TokenStore.inMemory
        try store.save(AuthTokens(accessToken: "access-1", refreshToken: "refresh-1"))
        let client = makeClient(tokenStore: store) { _ in
            let body = Data(#"{"success": false, "code": "PORTFOLIO_NOT_FOUND", "message": "포트폴리오를 찾을 수 없어요."}"#.utf8)
            throw NetworkError.statusCode(404, body)
        }

        do {
            try await client.api(NetworkRequest(path: "/api/v1/portfolios/x/status"))
            XCTFail("ServerError 가 나야 한다")
        } catch let error as ServerError {
            XCTAssertEqual(error.code, "PORTFOLIO_NOT_FOUND")
            XCTAssertEqual(error.statusCode, 404)
        } catch {
            XCTFail("예상 밖 에러: \(error)")
        }
    }
}
