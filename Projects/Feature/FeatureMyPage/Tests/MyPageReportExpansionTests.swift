//
//  MyPageReportExpansionTests.swift
//  FeatureMyPageTests
//
//  Created by 서정원 on 26/08/21.
//

import ComposableArchitecture
import Foundation
import Testing
@testable import FeatureMyPageImplementation

@MainActor
struct MyPageReportExpansionTests {
    private static func report(_ id: Int) -> MyPageFeature.Report {
        MyPageFeature.Report(
            id: id,
            title: "iOS · 2년차 면접",
            date: "2026.07.02",
            time: "14:20",
            jobLevel: "iOS · 2년",
            portfolioName: "portfolio.pdf",
            jobDescription: "-"
        )
    }

    @Test("여러 리포트를 동시에 펼쳐 두고, 재탭한 줄만 접는다")
    func expandsManyRowsAndCollapsesOnlyTheRetappedOne() async {
        let store = TestStore(
            initialState: MyPageFeature.State(reports: [Self.report(1), Self.report(2)])
        ) {
            MyPageFeature()
        }

        await store.send(.view(.userTappedReport(id: 1))) { $0.expandedReportIDs = [1] }
        // 다른 줄을 펼쳐도 앞 줄은 접히지 않는다 — 두 리포트를 나란히 비교하는 자리다.
        await store.send(.view(.userTappedReport(id: 2))) { $0.expandedReportIDs = [1, 2] }
        await store.send(.view(.userTappedReport(id: 1))) { $0.expandedReportIDs = [2] }
    }
}
