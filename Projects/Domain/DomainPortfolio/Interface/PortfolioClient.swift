//
//  PortfolioClient.swift
//  DomainPortfolioInterface
//
//  Created by EunseoKim on 26/07/18.
//

import ComposableArchitecture
import Foundation

// MARK: - Models

/// 처리 상태 — 등록 직후 PROCESSING, S3 업로드·파싱·임베딩 완료 시 READY.
public enum PortfolioProcessingStatus: String, Decodable, Equatable, Sendable {
    case processing = "PROCESSING"
    case ready = "READY"
    case failedFile = "FAILED_FILE"
    case failedSystem = "FAILED_SYSTEM"
    case cancelled = "CANCELLED"
}

/// 등록된 포트폴리오. MVP 는 계정당 1개 (응답은 다건 확장 대비 배열).
public struct Portfolio: Decodable, Equatable, Sendable, Identifiable {
    public let portfolioId: UUID
    public let fileName: String?
    /// 파일 크기(byte)
    public let fileSize: Int?
    public let pageCount: Int?
    public let status: PortfolioProcessingStatus?
    public let uploadedAt: Date?
    /// 이 포폴을 참조하는 면접 세션이 진행 중인가 — 마이페이지 삭제 차단 조건.
    public let interviewInProgress: Bool?

    public var id: UUID { portfolioId }

    public init(
        portfolioId: UUID,
        fileName: String?,
        fileSize: Int?,
        pageCount: Int?,
        status: PortfolioProcessingStatus?,
        uploadedAt: Date?,
        interviewInProgress: Bool? = nil
    ) {
        self.portfolioId = portfolioId
        self.fileName = fileName
        self.fileSize = fileSize
        self.pageCount = pageCount
        self.status = status
        self.uploadedAt = uploadedAt
        self.interviewInProgress = interviewInProgress
    }
}

/// 목록 응답 — 등록 건 + 계정 단위 가용성 플래그.
/// 가용성은 **개별 포폴이 아니라 계정** 속성이라 `portfolios` 밖(= `data` 레벨)에 온다.
public struct PortfolioList: Decodable, Equatable, Sendable {
    public let portfolios: [Portfolio]
    /// 교체(재등록) 가능 여부
    public let replaceAvailable: Bool?
    /// 교체 불가일 때 다시 가능해지는 시각 (가능하면 nil)
    public let nextAvailableAt: Date?
    /// 삭제 가능 여부
    public let deleteAvailable: Bool?
    /// 삭제 불가일 때 다시 가능해지는 시각 (가능하면 nil)
    public let nextDeleteAvailableAt: Date?

    public init(
        portfolios: [Portfolio],
        replaceAvailable: Bool? = nil,
        nextAvailableAt: Date? = nil,
        deleteAvailable: Bool? = nil,
        nextDeleteAvailableAt: Date? = nil
    ) {
        self.portfolios = portfolios
        self.replaceAvailable = replaceAvailable
        self.nextAvailableAt = nextAvailableAt
        self.deleteAvailable = deleteAvailable
        self.nextDeleteAvailableAt = nextDeleteAvailableAt
    }
}

/// 계정 단위 교체·삭제 가용성 — `PortfolioList` 의 네 필드를 한 값으로 묶는다.
/// 서버 스키마상 `true` = 이번 달 1회 남음, `false` = 0회. 다시 가능한 시각은 막혀 있을 때만 온다.
/// 모르면(필드 누락·조회 전) 막지 않는다 — 최종 판정은 서버 거절(`*_LIMIT_EXCEEDED`)이 한다.
public struct PortfolioAvailability: Equatable, Sendable {
    /// 재업로드(교체) 가능 여부 — 소진이면 업로드가 `REPLACEMENT_LIMIT_EXCEEDED` 로 거절된다.
    public var replaceAvailable: Bool
    /// 재업로드가 다시 가능해지는 시각 (가능하면 nil)
    public var nextReplaceAvailableAt: Date?
    /// READY 포폴 삭제 가능 여부 — 소진이면 삭제가 `DELETE_LIMIT_EXCEEDED` 로 거절된다(업로드 중 취소는 무관).
    public var deleteAvailable: Bool
    /// 삭제가 다시 가능해지는 시각 (가능하면 nil)
    public var nextDeleteAvailableAt: Date?

    public init(
        replaceAvailable: Bool = true,
        nextReplaceAvailableAt: Date? = nil,
        deleteAvailable: Bool = true,
        nextDeleteAvailableAt: Date? = nil
    ) {
        self.replaceAvailable = replaceAvailable
        self.nextReplaceAvailableAt = nextReplaceAvailableAt
        self.deleteAvailable = deleteAvailable
        self.nextDeleteAvailableAt = nextDeleteAvailableAt
    }
}

public extension PortfolioAvailability {
    /// 다시 가능한 날 표기 «1월 1일». 서버 LocalDateTime 을 디코더가 KST 로 읽으므로(`JSONDecoder.api`)
    /// 표기도 KST 로 고정한다 — 기기 타임존이면 UTC 서쪽에서 하루 밀린다. 그 가정을 이 한 곳에만 둔다.
    static func dayText(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        formatter.dateFormat = "M월 d일"
        return formatter
    }()
}

public extension PortfolioList {
    /// 가용성 네 필드 묶음 — 빠진 플래그는 `true`(막지 않음)로 읽는다.
    var availability: PortfolioAvailability {
        PortfolioAvailability(
            replaceAvailable: replaceAvailable ?? true,
            nextReplaceAvailableAt: nextAvailableAt,
            deleteAvailable: deleteAvailable ?? true,
            nextDeleteAvailableAt: nextDeleteAvailableAt
        )
    }
}

/// 업로드 입력 — PDF 20MB 이하 · 30페이지 이하 (서버 검증: `INVALID_FILE_TYPE`·`FILE_TOO_LARGE`·`PAGE_COUNT_EXCEEDED`).
public struct PortfolioUpload: Equatable, Sendable {
    public var fileName: String
    public var fileSize: Int?
    public var pageCount: Int?
    public var contentType: String
    /// PDF 바이너리
    public var data: Data

    public init(
        fileName: String,
        fileSize: Int? = nil,
        pageCount: Int? = nil,
        contentType: String = "application/pdf",
        data: Data
    ) {
        self.fileName = fileName
        self.fileSize = fileSize
        self.pageCount = pageCount
        self.contentType = contentType
        self.data = data
    }
}

/// 등록(202)·상태 폴링 공통 응답 — `{ portfolioId, status, message }`.
public struct PortfolioProcessing: Decodable, Equatable, Sendable {
    public let portfolioId: UUID
    public let status: PortfolioProcessingStatus
    /// 사용자에게 노출할 안내 메시지
    public let message: String?

    public init(portfolioId: UUID, status: PortfolioProcessingStatus, message: String?) {
        self.portfolioId = portfolioId
        self.status = status
        self.message = message
    }
}

/// 삭제 응답
public struct PortfolioDeletion: Decodable, Equatable, Sendable {
    public let portfolioId: UUID?
    public let deletedAt: Date?

    public init(portfolioId: UUID?, deletedAt: Date?) {
        self.portfolioId = portfolioId
        self.deletedAt = deletedAt
    }
}

/// 파일 열람 URL 발급 응답 — `fileUrl` 은 S3 presigned GET URL 이고 **10분만** 유효하다.
/// 그래서 값을 캐시하지 않고 열람할 때마다 새로 발급받는다(서버 스펙).
public struct PortfolioFileURL: Decodable, Equatable, Sendable {
    public let portfolioId: UUID?
    /// PDF 열람용 presigned GET URL. 키 이름은 서버 그대로다(`jdUrl` 과 같은 규칙).
    public let fileUrl: URL

    public init(portfolioId: UUID?, fileUrl: URL) {
        self.portfolioId = portfolioId
        self.fileUrl = fileUrl
    }
}

// MARK: - Client

/// 포트폴리오 API (D14 `/api/v1/portfolios/**`).
/// 계정당 1개 제한 — 재등록은 `PORTFOLIO_ALREADY_EXISTS` → 삭제 후 등록 UX.
// @lat: [[api#Portfolio]]
public struct PortfolioClient: Sendable {
    /// GET /portfolios — 내 포트폴리오 목록 + 계정 단위 교체·삭제 가용성.
    public var list: @Sendable () async throws -> PortfolioList
    /// POST /portfolios — 202 PROCESSING 접수. 이후 `status` 폴링(3~5초)으로 READY 확인.
    public var register: @Sendable (PortfolioUpload) async throws -> PortfolioProcessing
    /// GET /portfolios/{id}/status — 처리 상태 폴링.
    public var status: @Sendable (_ portfolioId: UUID) async throws -> PortfolioProcessing
    /// DELETE /portfolios/{id}
    public var delete: @Sendable (_ portfolioId: UUID) async throws -> PortfolioDeletion
    /// GET /portfolios/{id}/file-url — PDF 열람용 presigned URL 발급. **READY 상태에서만** 나온다.
    public var fileURL: @Sendable (_ portfolioId: UUID) async throws -> PortfolioFileURL

    public init(
        list: @escaping @Sendable () async throws -> PortfolioList,
        register: @escaping @Sendable (PortfolioUpload) async throws -> PortfolioProcessing,
        status: @escaping @Sendable (_ portfolioId: UUID) async throws -> PortfolioProcessing,
        delete: @escaping @Sendable (_ portfolioId: UUID) async throws -> PortfolioDeletion,
        fileURL: @escaping @Sendable (_ portfolioId: UUID) async throws -> PortfolioFileURL
    ) {
        self.list = list
        self.register = register
        self.status = status
        self.delete = delete
        self.fileURL = fileURL
    }
}

extension PortfolioClient: TestDependencyKey {
    public static var testValue: PortfolioClient {
        PortfolioClient(
            list: unimplemented("PortfolioClient.list", placeholder: PortfolioList(portfolios: [])),
            register: unimplemented("PortfolioClient.register"),
            status: unimplemented("PortfolioClient.status"),
            delete: unimplemented("PortfolioClient.delete"),
            fileURL: unimplemented("PortfolioClient.fileURL")
        )
    }

    public static var previewValue: PortfolioClient {
        let sampleId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        return PortfolioClient(
            list: {
                PortfolioList(
                    portfolios: [
                        Portfolio(
                            portfolioId: sampleId,
                            fileName: "portfolio.pdf",
                            fileSize: 1_048_576,
                            pageCount: 12,
                            status: .ready,
                            uploadedAt: Date(timeIntervalSince1970: 1_782_000_000),
                            interviewInProgress: false
                        )
                    ],
                    replaceAvailable: true,
                    deleteAvailable: true
                )
            },
            register: { upload in
                PortfolioProcessing(portfolioId: sampleId, status: .processing, message: "\(upload.fileName) 분석을 시작했어요")
            },
            status: { id in
                PortfolioProcessing(portfolioId: id, status: .ready, message: nil)
            },
            delete: { id in
                PortfolioDeletion(portfolioId: id, deletedAt: Date(timeIntervalSince1970: 1_782_000_000))
            },
            fileURL: { id in
                PortfolioFileURL(portfolioId: id, fileUrl: URL(string: "https://example.com/preview.pdf")!)
            }
        )
    }
}

public extension DependencyValues {
    var portfolioClient: PortfolioClient {
        get { self[PortfolioClient.self] }
        set { self[PortfolioClient.self] = newValue }
    }
}
