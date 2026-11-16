//
//  PortfolioError.swift
//  DomainPortfolioInterface
//
//  Created by EunseoKim on 26/07/23.
//

import DomainCommonInterface

/// Portfolio API 에러 — State 가 다르게 반응해야 하는 경우의 수만큼만 둔다 (AuthError 와 같은 원칙).
/// 서버 코드 ↔ 케이스 매핑 표는 [[api#Portfolio]].
/// 서버 4xx 는 사용자에게 그대로 보여줄 한국어 `message` 를 함께 준다 —
/// 클라 문구가 확정되지 않은 지금은 이 원문을 배너에 싣는다(`userMessage`).
public enum PortfolioError: Error, Equatable, Sendable {
    /// INVALID_FILE_TYPE (400) — PDF 만 허용.
    case invalidFileType(message: String)
    /// FILE_TOO_LARGE (400) — 20MB 초과.
    case fileTooLarge(message: String)
    /// PAGE_COUNT_EXCEEDED (400) — 30페이지 초과.
    case pageCountExceeded(message: String)
    /// INVALID_PDF_FILE (400) — 손상된 파일. 재선택 유도.
    case invalidPDFFile(message: String)
    /// PORTFOLIO_ALREADY_EXISTS (409) — 계정당 1개 제한. 삭제 후 등록 UX.
    case alreadyExists(message: String)
    /// PORTFOLIO_DELETE_BLOCKED_BY_INTERVIEW (409) — 이 포폴을 쓰는 면접이 진행 중이라 삭제 불가.
    case deleteBlockedByInterview(message: String)
    /// DELETE_LIMIT_EXCEEDED (409) — 이번 달 삭제 기회 소진(READY 포폴 삭제만 센다).
    case deleteLimitExceeded(message: String)
    /// REPLACEMENT_LIMIT_EXCEEDED (409) — 이번 달 재업로드(교체) 기회 소진.
    case replacementLimitExceeded(message: String)
    /// PORTFOLIO_NOT_FOUND (404) — 없거나 본인 소유가 아님.
    case notFound(message: String)
    /// 재로그인 필요 (LOGIN_EXPIRED — 자동 재발급까지 실패한 뒤 도달)
    case sessionExpired
    case networkFailure
    case serverUnavailable
    case unexpected

    /// 화면에 그대로 노출할 서버 문구 — 인프라 실패(네트워크·5xx·미승격)는 nil 이라 클라 폴백 문구를 쓴다.
    public var userMessage: String? {
        switch self {
        case let .invalidFileType(message),
             let .fileTooLarge(message),
             let .pageCountExceeded(message),
             let .invalidPDFFile(message),
             let .alreadyExists(message),
             let .deleteBlockedByInterview(message),
             let .deleteLimitExceeded(message),
             let .replacementLimitExceeded(message),
             let .notFound(message):
            return message
        case .sessionExpired, .networkFailure, .serverUnavailable, .unexpected:
            return nil
        }
    }
}

// MARK: - 서버 코드 매핑 (공통 규칙·토큰 만료는 DomainAPIError 가 처리)

extension PortfolioError: DomainAPIError {
    public init?(serverCode code: String, message: String) {
        switch code {
        case "INVALID_FILE_TYPE": self = .invalidFileType(message: message)
        case "FILE_TOO_LARGE": self = .fileTooLarge(message: message)
        case "PAGE_COUNT_EXCEEDED": self = .pageCountExceeded(message: message)
        case "INVALID_PDF_FILE": self = .invalidPDFFile(message: message)
        case "PORTFOLIO_ALREADY_EXISTS": self = .alreadyExists(message: message)
        case "PORTFOLIO_DELETE_BLOCKED_BY_INTERVIEW": self = .deleteBlockedByInterview(message: message)
        case "DELETE_LIMIT_EXCEEDED": self = .deleteLimitExceeded(message: message)
        case "REPLACEMENT_LIMIT_EXCEEDED": self = .replacementLimitExceeded(message: message)
        case "PORTFOLIO_NOT_FOUND": self = .notFound(message: message)
        default: return nil
        }
    }
}
