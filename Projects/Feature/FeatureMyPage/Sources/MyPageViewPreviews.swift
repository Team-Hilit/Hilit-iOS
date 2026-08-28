//
//  MyPageViewPreviews.swift
//  FeatureMyPage
//
//  Created by 서정원 on 26/08/01.
//

// Figma «[Part5] 마이페이지» 의 화면들을 상태별 캔버스로 되살린다 — 시안과 나란히 놓고 대조하는 용도.
// 프로덕션 초기값은 중립값(빈 화면)이라, Default 탭만 previewValue 조회로 채우고
// 나머지 탭은 파일 하단 private 픽스처로 State 를 직접 세운다.

import ComposableArchitecture
import SharedDesignSystemInterface
import SwiftUI

#Preview("Default — previewValue 실흐름") {
    // 중립 초기값 + onAppear 조회 — userClient·portfolioClient·interviewClient 의 previewValue 가 화면을 채운다.
    MyPageView(store: Store(initialState: MyPageFeature.State()) { MyPageFeature() })
}

#Preview("업로드 전") {
    var state = MyPageFeature.State.filled
    state.portfolio = .empty
    return MyPageView(store: Store(initialState: state) { MyPageFeature() })
}

#Preview("업로드 중") {
    var state = MyPageFeature.State.filled
    state.portfolio = .uploading(.sample, progress: 0.2)
    return MyPageView(store: Store(initialState: state) { MyPageFeature() })
}

#Preview("업로드 완료") {
    var state = MyPageFeature.State.filled
    state.portfolio = .uploaded(.sample)
    return MyPageView(store: Store(initialState: state) { MyPageFeature() })
}

#Preview("업로드 실패 — 툴팁") {
    var state = MyPageFeature.State.filled
    state.portfolio = .failed(.sample)
    state.isPortfolioTooltipPresented = true
    return MyPageView(store: Store(initialState: state) { MyPageFeature() })
}

#Preview("리포트 없음") {
    // 시안 «MyPage_Report_empty» — 포폴·리포트 둘 다 비었고 «회원탈퇴» 가 바닥에 붙는다.
    var state = MyPageFeature.State.filled
    state.portfolio = .empty
    state.reports = []
    return MyPageView(store: Store(initialState: state) { MyPageFeature() })
}

#Preview("리포트 펼침 — 복수") {
    // 펼침은 한 줄로 제한되지 않는다 — 두 줄을 동시에 펼쳐 둔 모습.
    var state = MyPageFeature.State.filled
    state.expandedReportIDs = [1, 3]
    return MyPageView(store: Store(initialState: state) { MyPageFeature() })
}

#Preview("모달 — 포트폴리오 삭제") {
    var state = MyPageFeature.State.filled
    state.presentedModal = .deleteConfirm(canReupload: true)
    return MyPageView(store: Store(initialState: state) { MyPageFeature() })
}

#Preview("모달 — 삭제 불가") {
    var state = MyPageFeature.State.filled
    state.presentedModal = .deleteBlocked(canReupload: nil)
    return MyPageView(store: Store(initialState: state) { MyPageFeature() })
}

#Preview("모달 — 새로 업로드") {
    var state = MyPageFeature.State.filled
    state.presentedModal = .replaceConfirm(remaining: 1)
    return MyPageView(store: Store(initialState: state) { MyPageFeature() })
}

#Preview("모달 — 업로드 불가") {
    var state = MyPageFeature.State.filled
    state.presentedModal = .replaceBlocked(remaining: 0)
    return MyPageView(store: Store(initialState: state) { MyPageFeature() })
}

#Preview("모달 — 로딩") {
    var state = MyPageFeature.State.filled
    state.presentedModal = .loading
    return MyPageView(store: Store(initialState: state) { MyPageFeature() })
}

// MARK: - 프리뷰 픽스처 (Sources 는 Testing 을 import 못 한다 — 프리뷰 소유 샘플)

private extension MyPageFeature.PortfolioFile {
    static let sample = Self(name: "{파일명}.pdf", date: "{20xx.xx.xx}", size: "{0}mb")
}

private extension MyPageFeature.State {
    /// 시안 «MyPage_Main» 상태 — 프로필·등록 포폴·리포트 세 줄.
    static var filled: Self {
        Self(
            profile: .init(
                name: "{재원}",
                jobGroup: "iOS",
                careerLevel: "2년차",
                remainingTickets: 3,
                email: "jaewon****@kakao.com",
                provider: "KAKAO"
            ),
            portfolio: .registered(.sample),
            reports: [
                .init(
                    id: 1,
                    title: "iOS · 2년차 면접",
                    date: "2026.07.02",
                    time: "14:20",
                    jobLevel: "iOS · 2년",
                    portfolioName: "홍길동 자기소개서_SK프롭티어 기업 면접.pdf",
                    jobDescription: "careers.skproptier.com/jobs/1024",
                    canOpenReport: true,
                    canRequestFeedback: true
                ),
                .init(
                    id: 2,
                    title: "홍길동 자기소개서_SK프롭티어 기업 면접.pdf",
                    date: "2026.07.02",
                    time: "14:20",
                    note: "삭제된 포트폴리오",
                    jobLevel: "iOS · 2년",
                    portfolioName: "홍길동 자기소개서_SK프롭티어 기업 면접.pdf",
                    jobDescription: "직접 입력함",
                    canOpenReport: true
                ),
                .init(
                    id: 3,
                    title: "홍길동 자기소개서_SK프롭티어 기업 면접.pdf",
                    date: "2026.07.02",
                    time: "14:20",
                    status: "생성 실패",
                    jobLevel: "iOS · 2년",
                    portfolioName: "홍길동 자기소개서_SK프롭티어 기업 면접.pdf",
                    jobDescription: "-",
                    detailError: "리포트 생성에 실패했어요 · 횟수는 차감되지 않았어요"
                )
            ]
        )
    }
}
