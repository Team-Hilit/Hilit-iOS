//
//  MyPageEntryTests.swift
//  FeatureMyPageTests
//
//  Created by 서정원 on 26/08/08.
//

import ComposableArchitecture
import DomainInterviewInterface
import DomainPortfolioInterface
import DomainUserInterface
import Foundation
import Testing
@testable import FeatureMyPageImplementation

@MainActor
struct MyPageEntryTests {
    private struct StubError: Error {}

    private static let portfolioId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private static let profile = UserProfile(
        userId: UUID(),
        name: "재원",
        email: "hilit@kakao.com",
        provider: "KAKAO",
        jobRole: "BACKEND",
        jobRoleLabel: "백엔드",
        careerYears: 3,
        remainingTicketCount: 2
    )

    private static let list = PortfolioList(
        portfolios: [
            Portfolio(
                portfolioId: portfolioId,
                fileName: "portfolio.pdf",
                fileSize: 1_048_576,
                pageCount: 12,
                status: .ready,
                uploadedAt: Date(timeIntervalSince1970: 1_783_728_000),
                interviewInProgress: true
            )
        ],
        replaceAvailable: false
    )

    private static let summary = InterviewReportSummary(
        sessionId: 7,
        jobType: "BACKEND",
        jobTypeLabel: "백엔드 개발자",
        careerYears: 3,
        // 마이페이지 접힘 제목은 서버 title 이 아니라 직군·연차 조합이다(홈만 title 을 쓴다 — 8ebc7c8).
        title: nil,
        interviewedAt: Date(timeIntervalSince1970: 1_783_728_000),
        portfolioFileName: "portfolio.pdf",
        portfolioDeleted: false,
        jdUrl: nil,
        reportStatus: .ready,
        feedbackAvailable: false
    )

    @Test("진입 조회 성공 — 세 응답이 표시 모델·가용성·면접 중 플래그로 앉는다")
    func onAppearLoadsEntry() async {
        let store = TestStore(initialState: MyPageFeature.State()) {
            MyPageFeature()
        } withDependencies: {
            $0.userClient.profile = { Self.profile }
            $0.portfolioClient.list = { Self.list }
            $0.interviewClient.reportList = { [Self.summary] }
        }

        await store.send(.view(.onAppear))
        await store.receive(\.inner.entryLoaded) {
            $0.profile = .init(profile: Self.profile)
            $0.portfolio = .init(list: Self.list)
            $0.replaceAvailable = false
            $0.isInterviewInProgress = true
            $0.reports = [MyPageFeature.Report(summary: Self.summary)!]
        }
    }

    @Test("하나라도 실패하면 알럿 — 다시 시도가 재조회한다")
    func partialFailureAlertsAndRetries() async {
        let store = TestStore(initialState: MyPageFeature.State()) {
            MyPageFeature()
        } withDependencies: {
            $0.userClient.profile = { throw StubError() }
            $0.portfolioClient.list = { Self.list }
            $0.interviewClient.reportList = { [Self.summary] }
        }

        await store.send(.view(.onAppear))
        await store.receive(\.inner.entryFailed) {
            $0.alert = .entryFailed
        }

        store.dependencies.userClient.profile = { Self.profile }
        await store.send(.alert(.presented(.retryEntry))) {
            $0.alert = nil
        }
        await store.receive(\.inner.entryLoaded) {
            $0.profile = .init(profile: Self.profile)
            $0.portfolio = .init(list: Self.list)
            $0.replaceAvailable = false
            $0.isInterviewInProgress = true
            $0.reports = [MyPageFeature.Report(summary: Self.summary)!]
        }
    }

    @Test("알럿 닫기 — 기존 값을 유지한다")
    func alertDismissKeepsState() async {
        let store = TestStore(initialState: MyPageFeature.State()) {
            MyPageFeature()
        } withDependencies: {
            $0.userClient.profile = { throw StubError() }
            $0.portfolioClient.list = { Self.list }
            $0.interviewClient.reportList = { [Self.summary] }
        }

        await store.send(.view(.onAppear))
        await store.receive(\.inner.entryFailed) {
            $0.alert = .entryFailed
        }
        await store.send(.alert(.dismiss)) {
            $0.alert = nil
        }
    }
}
