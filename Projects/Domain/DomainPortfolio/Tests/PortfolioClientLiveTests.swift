//
//  PortfolioClientLiveTests.swift
//  DomainPortfolioTests
//
//  Created by EunseoKim on 26/07/18.
//

import ComposableArchitecture
import CoreNetworkInterface
import DomainPortfolioInterface
import XCTest
@testable import DomainPortfolioImplementation

final class PortfolioClientLiveTests: XCTestCase {
    private func makeClient(
        handler: @escaping @Sendable (NetworkRequest) async throws -> Data
    ) -> PortfolioClient {
        withDependencies {
            $0.authorizedNetworkClient = AuthorizedNetworkClient(
                request: handler,
                authorizedResource: { _ in AuthorizedResource(url: URL(string: "stub://")!, headers: [:]) }
            )
        } operation: {
            PortfolioClient.liveValue
        }
    }

    func test_list_envelope을_벗겨_목록과_uploadedAt을_디코딩한다() async throws {
        // 가용성 4종은 개별 포폴이 아니라 계정 속성이라 `portfolios` 밖(data 레벨)에 온다.
        let json = """
        {"success": true, "data": {
            "replaceAvailable": true,
            "nextAvailableAt": null,
            "deleteAvailable": false,
            "nextDeleteAvailableAt": "2026-09-01T00:00:00",
            "portfolios": [{
                "portfolioId": "3E1A8E4B-6C1B-4E1F-9B5A-2F1C0D9E8A70",
                "fileName": "portfolio.pdf",
                "fileSize": 1048576,
                "pageCount": 12,
                "status": "READY",
                "uploadedAt": "2026-07-06T10:00:04"
            }]
        }}
        """
        let client = makeClient { request in
            XCTAssertEqual(request.path, "/api/v1/portfolios")
            XCTAssertEqual(request.method, .get)
            return Data(json.utf8)
        }

        let list = try await client.list()

        XCTAssertEqual(list.portfolios.count, 1)
        XCTAssertEqual(list.portfolios.first?.status, .ready)
        XCTAssertNotNil(list.portfolios.first?.uploadedAt)  // LocalDateTime 도 JSONDecoder.api 가 파싱
        XCTAssertEqual(list.replaceAvailable, true)
        XCTAssertNil(list.nextAvailableAt)
        XCTAssertEqual(list.deleteAvailable, false)
        XCTAssertNotNil(list.nextDeleteAvailableAt)
    }

    func test_list_가용성_필드가_없어도_목록만으로_디코딩된다() async throws {
        let client = makeClient { _ in
            Data("""
            {"success": true, "data": {"portfolios": []}}
            """.utf8)
        }

        let list = try await client.list()

        XCTAssertTrue(list.portfolios.isEmpty)
        XCTAssertNil(list.replaceAvailable)
        XCTAssertNil(list.deleteAvailable)
    }

    func test_list_decodesCancelledStatusAndInterviewInProgress() async throws {
        // CANCELLED 는 서버 스펙에 있는 값 — 케이스가 없으면 여기서 디코드가 throw 한다.
        let client = makeClient { _ in
            Data("""
            {"success": true, "data": {"portfolios": [{
                "portfolioId": "3E1A8E4B-6C1B-4E1F-9B5A-2F1C0D9E8A70",
                "fileName": "portfolio.pdf",
                "status": "CANCELLED",
                "interviewInProgress": true
            }]}}
            """.utf8)
        }

        let list = try await client.list()

        XCTAssertEqual(list.portfolios.first?.status, .cancelled)
        XCTAssertEqual(list.portfolios.first?.interviewInProgress, true)
    }

    func test_register_메타데이터는_query로_PDF는_multipart로_보낸다() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.path, "/api/v1/portfolios")
            XCTAssertEqual(request.method, .post)
            let query = Dictionary(uniqueKeysWithValues: request.queryItems.map { ($0.name, $0.value) })
            XCTAssertEqual(query["fileName"], "portfolio.pdf")
            XCTAssertEqual(query["contentType"], "application/pdf")
            XCTAssertEqual(query["fileSize"], "1048576")
            let body = String(bytes: request.body ?? Data(), encoding: .utf8) ?? ""
            XCTAssertTrue(body.contains(#"name="file"; filename="portfolio.pdf""#))
            return Data("""
            {"success": true, "data": {
                "portfolioId": "3E1A8E4B-6C1B-4E1F-9B5A-2F1C0D9E8A70", "status": "PROCESSING", "message": "분석을 시작했어요"
            }}
            """.utf8)
        }

        let processing = try await client.register(PortfolioUpload(
            fileName: "portfolio.pdf",
            fileSize: 1_048_576,
            data: Data("pdf-bytes".utf8)
        ))

        XCTAssertEqual(processing.status, .processing)
    }

    func test_register_기등록409를_alreadyExists로_매핑한다() async throws {
        let client = makeClient { _ in
            throw NetworkError.statusCode(409, Data(
                #"{"success": false, "code": "PORTFOLIO_ALREADY_EXISTS", "message": "이미 등록된 포트폴리오가 있어요."}"#.utf8
            ))
        }

        do {
            _ = try await client.register(PortfolioUpload(fileName: "p.pdf", data: Data()))
            XCTFail("에러가 던져져야 한다")
        } catch {
            // 서버 문구를 배너에 그대로 싣기 때문에 message 까지 보존돼야 한다.
            XCTAssertEqual(error as? PortfolioError, .alreadyExists(message: "이미 등록된 포트폴리오가 있어요."))
        }
    }

    func test_register_교체소진409를_replacementLimitExceeded로_매핑한다() async throws {
        let client = makeClient { _ in
            throw NetworkError.statusCode(409, Data(
                #"{"success": false, "code": "REPLACEMENT_LIMIT_EXCEEDED", "message": "재업로드는 한 달에 한 번만 가능해요."}"#.utf8
            ))
        }

        do {
            _ = try await client.register(PortfolioUpload(fileName: "p.pdf", data: Data()))
            XCTFail("에러가 던져져야 한다")
        } catch {
            XCTAssertEqual(error as? PortfolioError, .replacementLimitExceeded(message: "재업로드는 한 달에 한 번만 가능해요."))
        }
    }

    func test_delete_삭제차단409_두종을_각각_매핑한다() async throws {
        let cases: [(code: String, expected: PortfolioError)] = [
            ("DELETE_LIMIT_EXCEEDED", .deleteLimitExceeded(message: "m")),
            ("PORTFOLIO_DELETE_BLOCKED_BY_INTERVIEW", .deleteBlockedByInterview(message: "m"))
        ]
        for (code, expected) in cases {
            let client = makeClient { _ in
                throw NetworkError.statusCode(409, Data(
                    #"{"success": false, "code": "\#(code)", "message": "m"}"#.utf8
                ))
            }
            do {
                _ = try await client.delete(UUID())
                XCTFail("에러가 던져져야 한다 — \(code)")
            } catch {
                XCTAssertEqual(error as? PortfolioError, expected)
            }
        }
    }

    func test_dayText_서버_LocalDateTime을_KST_월일로_표기한다() {
        // "2027-01-01T00:00:00"(KST) — 서버 nextMonthStart() 모양. 기기 타임존과 무관하게 1월 1일.
        XCTAssertEqual(PortfolioAvailability.dayText(Date(timeIntervalSince1970: 1_798_729_200)), "1월 1일")
    }

    func test_availability_빠진_플래그는_막지_않는_쪽으로_읽는다() {
        let next = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertEqual(
            PortfolioList(portfolios: []).availability,
            PortfolioAvailability()
        )
        XCTAssertEqual(
            PortfolioList(portfolios: [], replaceAvailable: false, nextAvailableAt: next, deleteAvailable: false).availability,
            PortfolioAvailability(replaceAvailable: false, nextReplaceAvailableAt: next, deleteAvailable: false)
        )
    }

    func test_delete_경로에_UUID를_싣는다() async throws {
        let id = UUID(uuidString: "3E1A8E4B-6C1B-4E1F-9B5A-2F1C0D9E8A70")!
        let client = makeClient { request in
            XCTAssertEqual(request.path, "/api/v1/portfolios/\(id.uuidString)")
            XCTAssertEqual(request.method, .delete)
            return Data("""
            {"success": true, "data": {
                "portfolioId": "3E1A8E4B-6C1B-4E1F-9B5A-2F1C0D9E8A70", "deletedAt": "2026-07-06T10:00:04"
            }}
            """.utf8)
        }

        let deletion = try await client.delete(id)

        XCTAssertEqual(deletion.portfolioId, id)
    }
}
