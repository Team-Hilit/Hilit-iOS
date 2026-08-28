//
//  FeatureMyPageExampleApp.swift
//  FeatureMyPageExample
//
//  Created by 서정원 on 26/08/01.
//

import ComposableArchitecture
import DomainInterviewInterface
import DomainPortfolioInterface
import DomainUserInterface
import FeatureMyPageImplementation
import Foundation
import SwiftUI

// Feature 단독 실행 앱 — FeatureMyPage 스킴의 실행 타겟. 모드 2종:
// • mock(기본) — 외부 IO 를 아래 픽스처로 채워 네트워크 없이 화면 흐름만 돌린다.
// • live — 스킴 Run 환경변수 `HILIT_ACCESS_TOKEN` 존재 시 실서버 하네스(LiveMyPageBootstrap).
//   토큰은 Dev 앱에서 브레이크포인트로 추출 — AuthorizedEngine.perform 의 Bearer 부착 줄에
//   Log Message 액션(«🔑 @tokens.accessToken@», Automatically continue)을 걸면 API 호출마다
//   콘솔에 나온다. 그 한 줄을 통째로 복사 (Bearer 접두 없이 원문만, 커밋되는 코드 0줄).
//   ⚠️ tuist generate 가 스킴을 재생성하면 환경변수가 사라진다 — 재입력 필요.
@main
struct FeatureMyPageExampleApp: App {
    var body: some Scene {
        WindowGroup {
            // mock — 기본. live — 스킴 Run 환경변수 `HILIT_ACCESS_TOKEN` 존재 시 실서버 하네스.
            if let token = ProcessInfo.processInfo.environment["HILIT_ACCESS_TOKEN"], !token.isEmpty {
                LiveMyPageBootstrap(accessToken: token)
            } else {
                MyPageView(store: Self.mockStore())
            }
        }
    }

    /// mock 모드 스토어 — 픽스처로 채운 가짜 의존성(live 모드는 LiveMyPageBootstrap 이 따로 만든다).
    private static func mockStore() -> StoreOf<MyPageFeature> {
        Store(initialState: MyPageFeature.State()) {
            MyPageFeature()
        } withDependencies: {
            // 진입 조회 3종 + 계정 동선을 가짜로 채워 네트워크 없이 돌린다 — live 하네스 때문에 Domain
            // Implementation 이 link 돼 있어, 안 채우면 mock 모드가 실서버로 나간다
            // (authClient 는 link 밖이라 안 채우면 liveValue 부재로 unimplemented 트랩).
            $0.userClient.profile = { Self.profile }
            $0.portfolioClient.list = { Self.list }
            $0.interviewClient.reportList = { Self.reports }
            $0.portfolioClient.delete = { _ in
                Self.deleted.setValue(true)
                return PortfolioDeletion(portfolioId: nil, deletedAt: nil)
            }
            // register 가 `deleted` 를 되돌려 «삭제 → 업로드 → 카드 복귀» 한 바퀴가 mock 에서 완성된다.
            $0.portfolioClient.register = { _ in
                Self.deleted.setValue(false)
                return PortfolioProcessing(portfolioId: UUID(), status: .processing, message: nil)
            }
            $0.portfolioClient.status = { id in
                PortfolioProcessing(portfolioId: id, status: .ready, message: nil)
            }
            // 열람 URL 도 채운다 — 안 채우면 mock 모드가 실서버로 나간다(Implementation 이 link 돼 있다).
            // 공개 샘플 PDF 라 Safari 시트가 실제로 무언가를 그리는 것까지 확인된다.
            $0.portfolioClient.fileURL = { id in
                PortfolioFileURL(
                    portfolioId: id,
                    fileUrl: URL(string: "https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf")!
                )
            }
            $0.userClient.withdraw = {}
            $0.authClient.logout = {}
        }
    }

    /// 가짜 프로필 — 애플 계정 분기를 보려면 provider 를 "APPLE" 로 바꾼다.
    private static let profile = UserProfile(
        userId: UUID(uuidString: "00000000-0000-0000-0000-0000000000e1")!,
        name: "재원",
        email: "hilit@kakao.com",
        provider: "KAKAO",
        jobRole: "IOS",
        jobRoleLabel: "iOS",
        careerYears: 2,
        remainingTicketCount: 3
    )

    /// 삭제 여부 — delete 오버라이드가 켜면 다음 list 조회가 빈 목록을 줘, 낙관 갱신 없는
    /// «삭제 → 전체 재조회 → 빈 포폴 전환» 이 하네스에서 실제로 보인다.
    private static let deleted = LockIsolated(false)

    /// 가짜 포폴 — READY 1건(삭제 후엔 빈 목록). `.processing` 으로 바꾸면 «처리 중» 판, 시작부터 빈 판은 `deleted` 초기값 true.
    /// `replaceAvailable: false` 로 바꾸면 삭제 확인 모달의 «다음 달 1일부터» 고지가 보인다.
    private static var list: PortfolioList {
        PortfolioList(
            portfolios: deleted.value ? [] : [
                Portfolio(
                    portfolioId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                    fileName: "홍길동 자기소개서_SK프롭티어 기업 면접.pdf",
                    fileSize: 3_355_443,
                    pageCount: 12,
                    status: .ready,
                    uploadedAt: Date(timeIntervalSince1970: 1_783_728_000),
                    interviewInProgress: false
                )
            ],
            replaceAvailable: true
        )
    }

    /// 가짜 기록 — 상태 4종을 한 건씩. GENERATING 은 행이 안 그려져 3행이 보인다(홈과 같은 규칙).
    /// «삭제된 포트폴리오» 태그는 13행(분석 부족)에 둔다 — 실패 행(14)에 겹치면 «삭제돼도 리포트 보기는
    /// 열린다(canOpen = !failed)» 규칙이 화면에서 안 보인다.
    private static let reports: [InterviewReportSummary] = [
        summary(sessionId: 11, status: .ready, feedbackAvailable: true),
        summary(sessionId: 12, status: .generating, feedbackAvailable: false),
        summary(sessionId: 13, status: .insufficientAnalysis, feedbackAvailable: false, portfolioDeleted: true),
        summary(sessionId: 14, status: .failed, feedbackAvailable: false)
    ]

    private static func summary(
        sessionId: Int,
        status: ReportStatus,
        feedbackAvailable: Bool,
        portfolioDeleted: Bool = false
    ) -> InterviewReportSummary {
        InterviewReportSummary(
            sessionId: sessionId,
            jobType: "IOS",
            jobTypeLabel: "iOS",
            careerYears: 2,
            // 마이페이지 접힘 제목은 직군·연차 조합이라 서버 title 은 비워 둔다(홈만 쓴다 — 8ebc7c8).
            title: nil,
            interviewedAt: Date(timeIntervalSince1970: 1_783_728_000 - TimeInterval(sessionId) * 86_400),
            portfolioFileName: "홍길동 자기소개서_SK프롭티어 기업 면접.pdf",
            portfolioDeleted: portfolioDeleted,
            jdUrl: sessionId == 11 ? "careers.skproptier.com/jobs/1024" : nil,
            reportStatus: status,
            feedbackAvailable: feedbackAvailable
        )
    }
}

// MARK: - 시나리오 가이드
//
// ▸ 업로드·교체 한 바퀴: 시뮬레이터 Files 에 PDF 를 하나 넣고 빈 판·«다시 올리기»·교체 확인에서 고른다 —
//   mock 도 파일 읽기·선검증은 실제로 타고(register 접수 → 3초 뒤 READY), live 는 실서버 register/폴링이다.
// ▸ 부분 실패(알럿+재시도): 위 클로저 하나를 `{ throw URLError(.timedOut) }` 로 바꾼다.
// ▸ 진행 중 면접(삭제·탈퇴 차단): Portfolio 의 `interviewInProgress: true`.
// ▸ 로그아웃·탈퇴는 delegate 만 올라간다 — Example 은 라우팅을 붙이지 않는다(화면 상태 확인 목적).
