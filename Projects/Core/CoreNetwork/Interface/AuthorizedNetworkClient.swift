//
//  AuthorizedNetworkClient.swift
//  CoreNetworkInterface
//
//  Created by EunseoKim on 26/07/18.
//

import ComposableArchitecture
import Foundation

// @lat: [[api#토큰 수명주기]]
// 인증 요청 전용 transport — `NetworkClient` 위에 D14 토큰 규약을 얹는다:
// Bearer 첨부(TokenStore) → 401 + `TOKEN_EXPIRED`/`INVALID_TOKEN` 이면 단일 비행 재발급 후 원요청 1회 재시도.
// 403(정지·이용권 소진 등 업무 거절)은 재발급 없이 그대로 던진다.
// `LOGIN_EXPIRED`(리프레시도 만료)면 토큰을 폐기하고 던진다 — 앱 레벨 재로그인 신호.
// 실패 표면은 NetworkClient 와 동일(NetworkError·CancellationError) + `NotAuthenticatedError`(로컬 토큰 없음).
public struct AuthorizedNetworkClient: Sendable {
    /// Bearer 첨부·재발급까지 끝낸 요청 → 2xx 응답 body
    public var request: @Sendable (NetworkRequest) async throws -> Data
    /// URLSession 밖 소비자(AVPlayer 오디오 스트리밍 등)를 위한 인증 URL 조립
    public var authorizedResource: @Sendable (_ path: String) async throws -> AuthorizedResource

    public init(
        request: @escaping @Sendable (NetworkRequest) async throws -> Data,
        authorizedResource: @escaping @Sendable (_ path: String) async throws -> AuthorizedResource
    ) {
        self.request = request
        self.authorizedResource = authorizedResource
    }
}

/// 인증 헤더가 필요한 외부 재생/다운로드 지점 (예: `AVURLAsset(url:options:)` 의 HTTP 헤더).
public struct AuthorizedResource: Equatable, Sendable {
    public let url: URL
    public let headers: [String: String]

    public init(url: URL, headers: [String: String]) {
        self.url = url
        self.headers = headers
    }
}

public extension AuthorizedNetworkClient {
    /// D14 공통 규약 요청 — `NetworkClient.api(_:as:)` 와 동일 시맨틱 (envelope 언랩 + ServerError 승격).
    func api<T: Decodable & Sendable>(
        _ request: NetworkRequest,
        as type: T.Type = T.self,
        decoder: JSONDecoder = .api
    ) async throws -> T {
        try ServerEnvelope<T>.unwrap(from: try await apiData(request), decoder: decoder)
    }

    /// 응답 본문을 쓰지 않는 D14 요청 (204 등)
    func api(_ request: NetworkRequest) async throws {
        _ = try await apiData(request)
    }

    private func apiData(_ request: NetworkRequest) async throws -> Data {
        do {
            return try await self.request(request)
        } catch let error as NetworkError {
            if case .statusCode(let status, let body) = error,
               let serverError = ServerError.decode(statusCode: status, body: body) {
                throw serverError
            }
            throw error
        }
    }
}

extension AuthorizedNetworkClient: TestDependencyKey {
    public static var testValue: AuthorizedNetworkClient {
        AuthorizedNetworkClient(
            request: unimplemented("AuthorizedNetworkClient.request", placeholder: Data()),
            authorizedResource: unimplemented(
                "AuthorizedNetworkClient.authorizedResource",
                placeholder: AuthorizedResource(url: URL(string: "unimplemented://")!, headers: [:])
            )
        )
    }
}

public extension DependencyValues {
    var authorizedNetworkClient: AuthorizedNetworkClient {
        get { self[AuthorizedNetworkClient.self] }
        set { self[AuthorizedNetworkClient.self] = newValue }
    }
}
