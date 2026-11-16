//
//  InterviewVideoExpiry.swift
//  DomainInterviewReportInterface
//
//  Created by 서정원 on 26/08/04.
//

import Foundation

/// GET …/video/expiry 응답 — 영상 삭제(만료)까지 남은 시간. 리포트 카운트다운의 유일한 출처.
/// 리포트 응답 `video.expiresAt` 과 같은 만료 시각의 초 단위 재계산. 이미 만료면 `0 / true`.
/// 최대 보관 30일(2,592,000초).
public struct InterviewVideoExpiry: Decodable, Equatable, Sendable {
    public let expiresInSeconds: Int
    public let expired: Bool

    public init(expiresInSeconds: Int, expired: Bool) {
        self.expiresInSeconds = expiresInSeconds
        self.expired = expired
    }
}
