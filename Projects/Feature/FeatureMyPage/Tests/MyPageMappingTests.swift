//
//  MyPageMappingTests.swift
//  FeatureMyPageTests
//
//  Created by 서정원 on 26/08/08.
//

import DomainInterviewInterface
import DomainPortfolioInterface
import DomainUserInterface
import Foundation
import Testing
@testable import FeatureMyPageImplementation

struct MyPageMappingTests {
    // 2026-07-11 00:00 UTC = KST 09:00 — 포맷터가 KST 고정임을 함께 검증하는 값.
    private static let interviewedAt = Date(timeIntervalSince1970: 1_783_728_000)

    private func summary(
        status: ReportStatus = .ready,
        jobTypeLabel: String? = "백엔드 개발자",
        careerYears: Int? = 3,
        portfolioFileName: String? = "포폴.pdf",
        portfolioDeleted: Bool = false,
        jdUrl: String? = "https://jd.example.com/1",
        feedbackAvailable: Bool = true
    ) -> InterviewReportSummary {
        InterviewReportSummary(
            sessionId: 7,
            jobType: "BACKEND",
            jobTypeLabel: jobTypeLabel,
            careerYears: careerYears,
            // 마이페이지 접힘 제목은 직군·연차 조합이라 서버 title 은 비워 둔다(홈만 쓴다 — 8ebc7c8).
            title: nil,
            interviewedAt: Self.interviewedAt,
            portfolioFileName: portfolioFileName,
            portfolioDeleted: portfolioDeleted,
            jdUrl: jdUrl,
            reportStatus: status,
            feedbackAvailable: feedbackAvailable
        )
    }

    @Test("GENERATING 은 행을 만들지 않는다")
    func generatingProducesNoRow() {
        #expect(MyPageFeature.Report(summary: summary(status: .generating)) == nil)
    }

    @Test("정상 행 — 스냅샷 제목·날짜·시간·버튼 두 개")
    func readyRowMapsSnapshotTitleAndActions() throws {
        let report = try #require(MyPageFeature.Report(summary: summary()))
        #expect(report.id == 7)
        #expect(report.title == "백엔드 개발자 · 3년차 면접")
        #expect(report.date == "2026.07.11")
        #expect(report.time == "09:00")
        #expect(report.note == nil)
        #expect(report.status == nil)
        #expect(report.jobLevel == "백엔드 개발자 · 3년")
        #expect(report.jobDescription == "https://jd.example.com/1")
        #expect(report.canOpenReport)
        #expect(report.canRequestFeedback)
    }

    @Test("스냅샷 조각이 다 없으면 제목은 «면접 리포트» 폴백이다")
    func emptySnapshotFallsBack() throws {
        let report = try #require(
            MyPageFeature.Report(summary: summary(jobTypeLabel: nil, careerYears: nil))
        )
        #expect(report.title == "면접 리포트")
        #expect(report.jobLevel == "-")
    }

    @Test("포폴 삭제 행 — 파일명 제목·회색 태그·리포트는 열린다(홈 일관)")
    func portfolioDeletedRowKeepsFileNameAndOpens() throws {
        let report = try #require(
            MyPageFeature.Report(summary: summary(portfolioDeleted: true, feedbackAvailable: false))
        )
        #expect(report.title == "포폴.pdf")
        #expect(report.note == "삭제된 포트폴리오")
        #expect(report.canOpenReport)
        #expect(!report.canRequestFeedback)
    }

    @Test("실패 행 — 상태 태그·상세 오류 띠·버튼 없음")
    func failedRowShowsTagAndHidesActions() throws {
        let report = try #require(MyPageFeature.Report(summary: summary(status: .failed, jdUrl: nil)))
        #expect(report.title == "포폴.pdf")
        #expect(report.status == "생성 실패")
        #expect(report.detailError == "리포트 생성에 실패했어요 · 횟수는 차감되지 않았어요")
        #expect(report.jobDescription == "-")
        #expect(!report.canOpenReport)
        #expect(!report.canRequestFeedback)
    }

    @Test("INSUFFICIENT_ANALYSIS 는 READY 동급 — 태그 없이 열린다")
    func insufficientAnalysisBehavesLikeReady() throws {
        let report = try #require(MyPageFeature.Report(summary: summary(status: .insufficientAnalysis)))
        #expect(report.status == nil)
        #expect(report.canOpenReport)
    }

    @Test("포폴 목록 매핑 — 상태별 칸과 파일 메타 포맷")
    func portfolioListMapsStatusAndMeta() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        func list(_ status: PortfolioProcessingStatus?) -> PortfolioList {
            PortfolioList(portfolios: [
                Portfolio(
                    portfolioId: id,
                    fileName: "portfolio.pdf",
                    fileSize: 1_048_576,
                    pageCount: 12,
                    status: status,
                    uploadedAt: Self.interviewedAt
                )
            ])
        }

        #expect(MyPageFeature.Portfolio(list: PortfolioList(portfolios: [])) == .empty)
        #expect(MyPageFeature.Portfolio(list: list(.cancelled)) == .empty)

        let registered = MyPageFeature.Portfolio(list: list(.ready))
        #expect(registered == .registered(.init(id: id, name: "portfolio.pdf", date: "2026.07.11", size: "1.0mb")))

        #expect(MyPageFeature.Portfolio(list: list(.processing))
            == .uploading(.init(id: id, name: "portfolio.pdf", date: "2026.07.11", size: "1.0mb"), progress: 0))
        #expect(MyPageFeature.Portfolio(list: list(.failedFile))
            == .failed(.init(id: id, name: "portfolio.pdf", date: "2026.07.11", size: "1.0mb")))
    }

    @Test("프로필 매핑 — nil 조각은 빈 값·이메일은 대시 폴백")
    func profileMapsNilPieces() {
        let profile = MyPageFeature.Profile(
            profile: UserProfile(
                userId: nil,
                name: nil,
                email: nil,
                provider: "APPLE",
                jobRole: nil,
                jobRoleLabel: nil,
                careerYears: nil,
                remainingTicketCount: 2
            )
        )
        #expect(profile.name == "")
        #expect(profile.jobGroup == "")
        #expect(profile.careerLevel == "")
        #expect(profile.email == "-")
        #expect(profile.provider == "APPLE")
        #expect(profile.remainingTickets == 2)
    }
}
