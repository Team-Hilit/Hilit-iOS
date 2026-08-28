//
//  FeatureHomeTests.swift
//  FeatureHomeTests
//
//  Created by 서정원 on 26/07/13.
//

import ComposableArchitecture
import DomainInterviewInterface
import DomainUserInterface
import Foundation
import Testing

@testable import FeatureHomeImplementation

@MainActor
struct HomeEntryLoadTests {
    // 표본 팩토리는 `nonisolated` — 의존성 클로저(@Sendable, 액터 밖)에서 부른다.
    private nonisolated static func profile(name: String? = "재원", remaining: Int = 3) -> UserProfile {
        UserProfile(
            userId: UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!,
            name: name,
            email: nil,
            provider: "KAKAO",
            jobRole: "BACKEND",
            jobRoleLabel: "백엔드",
            careerYears: 3,
            remainingTicketCount: remaining
        )
    }

    @Test("홈 진입은 프로필을 실어 이름·잔여를 채운다")
    func entryLoadFillsNameAndRemaining() async {
        let store = TestStore(initialState: HomeFeature.State()) {
            HomeFeature()
        } withDependencies: {
            // 진입 판정이 보관값을 읽는다 — testValue 는 unimplemented 라 명시로 주입한다.
            $0.heldSessionStore = .inMemory()
            $0.userClient.profile = { Self.profile(remaining: 2) }
            $0.interviewClient.reportList = { [] }
        }

        // 두 로드(프로필 / 기록 목록)는 별개 effect 라 해소 순서가 비결정이다 — 값만 고정한다.
        store.exhaustivity = .off
        await store.send(.view(.onAppear))
        await store.receive(\.inner.entryLoaded) {
            $0.userName = "재원"
            $0.startInterview.userName = "재원"
            $0.startInterview.remainingChances = 2
            // 잔여가 남았으면 `first` — 회차(포폴 보유) 분기는 없다(제품 결정 2026-08-08).
            $0.startInterview.variant = .first
        }
        await store.receive(\.inner.reportsLoaded)
    }

    @Test("프로필 로드가 실패하면 소진이 아니라 «모른다» 로 둔다")
    func profileFailureIsNotExhausted() async {
        struct LoadFailure: Error {}
        let store = TestStore(initialState: HomeFeature.State()) {
            HomeFeature()
        } withDependencies: {
            $0.heldSessionStore = .inMemory()
            $0.userClient.profile = { throw LoadFailure() }
            $0.interviewClient.reportList = { [] }
        }

        // 두 로드(프로필 / 기록 목록)는 별개 effect 라 해소 순서가 비결정이다 — 값만 고정한다.
        store.exhaustivity = .off
        await store.send(.view(.onAppear))
        // 잔여는 nil 그대로 — 0 으로 떨어뜨리면 «무료 횟수를 모두 사용했어요» 가 떠서
        // 시작 경로가 [홈으로] 하나로 막힌다. 변형도 초기값 `.first` 에서 안 움직인다.
        await store.receive(\.inner.entryLoaded)
        await store.receive(\.inner.reportsLoaded)
    }

    @Test("잔여 0 이면 소진 변형으로 바뀐다")
    func zeroRemainingBecomesExhausted() async {
        let store = TestStore(initialState: HomeFeature.State()) {
            HomeFeature()
        } withDependencies: {
            $0.heldSessionStore = .inMemory()
            $0.userClient.profile = { Self.profile(remaining: 0) }
            $0.interviewClient.reportList = { [] }
        }

        // 두 로드(프로필 / 기록 목록)는 별개 effect 라 해소 순서가 비결정이다 — 값만 고정한다.
        store.exhaustivity = .off
        await store.send(.view(.onAppear))
        await store.receive(\.inner.entryLoaded) {
            $0.userName = "재원"
            $0.startInterview.userName = "재원"
            $0.startInterview.remainingChances = 0
            $0.startInterview.variant = .exhausted
        }
        await store.receive(\.inner.reportsLoaded)
    }

    @Test("이름이 비어 오면 앞서 그리던 이름을 지우지 않는다")
    func emptyNameKeepsPreviousName() async {
        let store = TestStore(initialState: HomeFeature.State(userName: "재원")) {
            HomeFeature()
        } withDependencies: {
            $0.heldSessionStore = .inMemory()
            $0.userClient.profile = { Self.profile(name: nil, remaining: 3) }
            $0.interviewClient.reportList = { [] }
        }

        // 두 로드(프로필 / 기록 목록)는 별개 effect 라 해소 순서가 비결정이다 — 값만 고정한다.
        store.exhaustivity = .off
        await store.send(.view(.onAppear))
        await store.receive(\.inner.entryLoaded) {
            $0.startInterview.remainingChances = 3
        }
        await store.receive(\.inner.reportsLoaded)
    }
}

/// 프로필 로드를 죽여 두는 용도 — 잔여가 판정에 끼어들지 않아야 하는 테스트가 공유한다.
private struct ProfileUnavailable: Error {}

/// 진행 중(held) 면접 판정 — 재료는 로컬 보관값 하나다(진행 중 세션 목록 API 가 없다).
@MainActor
struct HomeHeldSessionTests {
    // 표본 팩토리는 `nonisolated` — 의존성 클로저(@Sendable, 액터 밖)에서 부른다.
    private nonisolated static func profile(remaining: Int) -> UserProfile {
        UserProfile(
            userId: UUID(uuidString: "00000000-0000-0000-0000-0000000000b1")!,
            name: "재원",
            email: nil,
            provider: "KAKAO",
            jobRole: "BACKEND",
            jobRoleLabel: "백엔드",
            careerYears: 3,
            remainingTicketCount: remaining
        )
    }

    /// 보관값만 갈아 끼우는 스토어 — `remaining` 을 안 주면 프로필을 죽여 잔여를 «모른다» 로 둔다.
    private static func store(
        held: HeldSession?,
        remaining: Int? = nil
    ) -> TestStore<HomeFeature.State, HomeFeature.Action> {
        let store = TestStore(initialState: HomeFeature.State()) {
            HomeFeature()
        } withDependencies: {
            $0.heldSessionStore = .inMemory(initial: held)
            $0.userClient.profile = {
                guard let remaining else { throw ProfileUnavailable() }
                return Self.profile(remaining: remaining)
            }
            $0.interviewClient.reportList = { [] }
        }
        // 두 로드(프로필 / 기록 목록)는 별개 effect 라 해소 순서가 비결정이다 — 변형만 고정한다.
        store.exhaustivity = .off
        return store
    }

    @Test("진행 중 세션이 있으면 잔여 0 이어도 소진이 아니라 진행 중이다")
    func heldSessionOutranksExhausted() async {
        // 갓 시작한 세션(0초 녹화) — 8분이 온전히 남아 질문 4개다.
        let store = Self.store(held: HeldSession(sessionId: 7, recordedSeconds: 0), remaining: 0)

        await store.send(.view(.onAppear))
        // 판정이 보관값 읽기라 프로필이 오기 전에 이미 진행 중이다(effect 없음).
        #expect(store.state.startInterview.variant == .inProgress(remainingQuestionCount: 4))
        await store.receive(\.inner.entryLoaded)
        // 잔여 0 이 실려 와도 덮어쓰지 않는다 — 진행 중이면 [이어서 진행] 이 유일한 정상 경로다.
        #expect(store.state.startInterview.remainingChances == 0)
        #expect(store.state.startInterview.variant == .inProgress(remainingQuestionCount: 4))
    }

    @Test("남은 질문 수는 남은 시간 구간으로 환산한다 — 경계 7:00(420초)은 3개다")
    func remainingQuestionCountBoundaries() async {
        // (남은 시간, 기대 질문 수) — 구간 경계 3분·5분·7분의 양쪽을 집는다.
        let boundaries = [(179, 1), (180, 2), (299, 2), (300, 3), (420, 3), (421, 4)]
        for (remainingSeconds, expected) in boundaries {
            // 보관값은 «녹화된 초» 라 최대 길이 8분(480초)에서 남기려는 시간을 뺀다.
            // 여기서 보는 건 환산 구간이라 진행분이 살아 있어야 한다 — 토큰을 찍어 카드까지 도달시킨다.
            let held = HeldSession(
                sessionId: 7,
                recordedSeconds: 480 - remainingSeconds,
                processToken: HeldSession.currentProcessToken
            )
            let store = Self.store(held: held)

            await store.send(.view(.onAppear))
            #expect(store.state.startInterview.variant == .inProgress(remainingQuestionCount: expected))
            await store.finish()
        }
    }

    @Test("보관값이 없으면 잔여 판정이 그대로다 — 잔여 0 은 소진")
    func noHeldSessionFallsBackToRemainingJudgement() async {
        let store = Self.store(held: nil, remaining: 0)

        await store.send(.view(.onAppear))
        // 보관값이 없고 잔여는 아직 모르는 자리 — 소진이 아니라 «처음» 이다.
        #expect(store.state.startInterview.variant == .first)
        await store.receive(\.inner.entryLoaded)
        #expect(store.state.startInterview.variant == .exhausted)
    }

    @Test("죽은 프로세스의 진행분 보관값은 카드가 되지 않는다 — 없는 것처럼 first 로 떨어진다")
    func deadHeldSessionIsIgnored() async {
        // 지난 실행이 남긴 진행분 — 세그먼트 파일(tmp·프로세스 수명)이 사라져 이어 붙일 앞부분이 없다.
        let store = Self.store(
            held: HeldSession(sessionId: 1, recordedSeconds: 60, processToken: UUID()),
            remaining: 3
        )

        await store.send(.view(.onAppear))
        #expect(store.state.startInterview.variant == .first)
        await store.receive(\.inner.entryLoaded)
        #expect(store.state.startInterview.variant == .first)
    }

    @Test("죽은 진행분이 소진 판정을 가리지 않는다 — 잔여 0 이면 소진이다")
    func deadHeldSessionDoesNotMaskExhausted() async {
        // 걸러 낸 자리는 «보관값이 없는» 자리와 같아야 한다 — 잔여 판정이 그대로 이어진다.
        let store = Self.store(
            held: HeldSession(sessionId: 1, recordedSeconds: 60, processToken: UUID()),
            remaining: 0
        )

        await store.send(.view(.onAppear))
        await store.receive(\.inner.entryLoaded)
        #expect(store.state.startInterview.variant == .exhausted)
    }

    @Test("0초 보관값(시작 직후)은 프로세스를 넘어 카드가 된다 — 잃을 영상이 없다")
    func zeroProgressHeldSurvivesRelaunch() async {
        let store = Self.store(
            held: HeldSession(sessionId: 1, recordedSeconds: 0, processToken: nil),
            remaining: 3
        )

        await store.send(.view(.onAppear))
        #expect(store.state.startInterview.variant == .inProgress(remainingQuestionCount: 4))
        await store.receive(\.inner.entryLoaded)
        #expect(store.state.startInterview.variant == .inProgress(remainingQuestionCount: 4))
    }

    // 2026-08-21 제품 결정 — 세션은 온보딩 분석이 끝난 순간 서버에 생기고 이용권도 그때 잡힌다.
    // [시작하기] 를 누르지 않았어도 카드를 그려야 사용자가 그 이용권을 회수한다(#130 이 숨겼던 자리).
    @Test("시작 전 장부도 카드가 된다 — 잡힌 이용권의 회수 동선이 그것뿐이다")
    func unstartedHeldBecomesCard() async {
        let held = HeldSession(sessionId: 1, recordedSeconds: 0, hasStarted: false, processToken: nil)
        let store = Self.store(held: held, remaining: 0)

        await store.send(.view(.onAppear))
        // 잔여 0 이어도 소진이 아니다 — 진행 중 세션이 그 이용권을 잡고 있다.
        #expect(store.state.startInterview.variant == .inProgress(remainingQuestionCount: 4))
        await store.receive(\.inner.entryLoaded)
        #expect(store.state.startInterview.variant == .inProgress(remainingQuestionCount: 4))
    }

    @Test("죽은 프로세스의 진행분 보관값도 카드가 되지 않는다 — 킬 클린업이 주울 몫이다")
    func deadProcessHeldDoesNotBecomeCard() async {
        let held = HeldSession(sessionId: 1, recordedSeconds: 320, hasStarted: true, processToken: UUID())
        let store = Self.store(held: held, remaining: 3)

        await store.send(.view(.onAppear))
        #expect(store.state.startInterview.variant == .first)
        await store.receive(\.inner.entryLoaded)
        #expect(store.state.startInterview.variant == .first)
    }

    @Test("현재 프로세스의 진행분 보관값은 환산된 남은 질문 수로 카드가 된다")
    func inProcessHeldShowsConvertedCount() async {
        let held = HeldSession(
            sessionId: 1,
            recordedSeconds: 320,
            processToken: HeldSession.currentProcessToken
        )
        let store = Self.store(held: held, remaining: 3)

        await store.send(.view(.onAppear))
        // 480−320=160초 → 3분 미만 → 1개.
        #expect(store.state.startInterview.variant == .inProgress(remainingQuestionCount: 1))
        await store.receive(\.inner.entryLoaded)
    }

    @Test("진행 중 두 갈래는 보관값의 세션 id 를 실어 올린다")
    func heldSessionIDRidesOnDelegates() async {
        let store = Self.store(held: HeldSession(sessionId: 42, recordedSeconds: 0))

        await store.send(.startInterview(.delegate(.restartRequested)))
        await store.receive(\.delegate.interviewRestartRequested, 42)
        await store.send(.startInterview(.delegate(.resumeRequested)))
        await store.receive(\.delegate.interviewResumeRequested, 42)
    }

    @Test("보관값이 없으면 진행 중 두 갈래는 올릴 세션이 없어 삼킨다")
    func missingHeldSessionSwallowsDelegates() async {
        let store = Self.store(held: nil)

        // 진행 중 변형이 아닌데 도달한 비정상 경로 — 세션을 특정할 수 없으니 신호를 만들지 않는다.
        await store.send(.startInterview(.delegate(.restartRequested)))
        await store.send(.startInterview(.delegate(.resumeRequested)))
        await store.finish()
    }
}

@MainActor
struct HomeReportListTests {
    /// 2026-07-11(토) 09:00 KST — 표시 포맷 «7월 11일 토» 검증용 고정 시각.
    private static let interviewedAt = Date(timeIntervalSince1970: 1_783_728_000)

    /// `title` 기본값은 nil — 요약 문장 필드 이전에 만들어진 세션(스냅샷 제목 갈래)이 기본 표본이다.
    /// 표본 팩토리는 `nonisolated` — 의존성 클로저(@Sendable, 액터 밖)에서 부른다.
    private nonisolated static func summary(
        sessionId: Int = 7,
        careerYears: Int? = 3,
        interviewedAt: Date = HomeReportListTests.interviewedAt,
        jobTypeLabel: String? = "백엔드 개발자",
        title: String? = nil,
        status: ReportStatus = .ready
    ) -> InterviewReportSummary {
        InterviewReportSummary(
            sessionId: sessionId,
            jobType: "BACKEND",
            jobTypeLabel: jobTypeLabel,
            careerYears: careerYears,
            title: title,
            interviewedAt: interviewedAt,
            portfolioFileName: "포트폴리오.pdf",
            portfolioDeleted: false,
            jdUrl: nil,
            reportStatus: status,
            feedbackAvailable: false
        )
    }

    private static func store(
        initialState: HomeFeature.State = HomeFeature.State(),
        reportList: @escaping @Sendable () async throws -> [InterviewReportSummary]
    ) -> TestStore<HomeFeature.State, HomeFeature.Action> {
        let store = TestStore(initialState: initialState) {
            HomeFeature()
        } withDependencies: {
            $0.heldSessionStore = .inMemory()
            $0.userClient.profile = { throw ProfileUnavailable() }
            $0.interviewClient.reportList = reportList
        }
        // 프로필 로드와 순서가 섞인다 — 목록 쪽 값만 고정한다.
        store.exhaustivity = .off
        return store
    }

    @Test("목록 응답은 세션 id·날짜·직군 스냅샷 행으로 들어오고 phase 가 report 로 바뀐다")
    func reportListFillsRows() async {
        let store = Self.store(reportList: { [Self.summary()] })

        await store.send(.view(.onAppear))
        await store.receive(\.inner.reportsLoaded) {
            $0.reports = [
                HomeFeature.Report(id: 7, dateText: "7월 11일 토", title: "백엔드 개발자 · 3년차")
            ]
            $0.expandedReportIDs = [7]
            $0.phase = .report(.returning)
        }
    }

    @Test("응답 순서가 뒤집혀 와도 최신순으로 정렬해 맨 위 행을 펼친다")
    func reportListSortsNewestFirst() async {
        // 응답 순서를 일부러 뒤집어 둔다 — 정렬은 서버가 아니라 리듀서 책임이다.
        let older = Date(timeIntervalSince1970: 1_783_641_600)  // 7월 10일(금) 09:00 KST
        let store = Self.store(reportList: {
            [
                Self.summary(sessionId: 1, interviewedAt: older),
                Self.summary(sessionId: 2)
            ]
        })

        await store.send(.view(.onAppear))
        await store.receive(\.inner.reportsLoaded) {
            $0.reports = [
                HomeFeature.Report(id: 2, dateText: "7월 11일 토", title: "백엔드 개발자 · 3년차"),
                HomeFeature.Report(id: 1, dateText: "7월 10일 금", title: "백엔드 개발자 · 3년차")
            ]
            $0.expandedReportIDs = [2]
            $0.phase = .report(.returning)
        }
    }

    @Test("생성 중 세션은 행에서 빠지고, 분석 부족은 READY·실패는 상태 문구 행으로 들어온다")
    func generatingReportsAreDropped() async {
        // 날짜를 하루씩 달리 둔다 — 최신순 정렬이 같은 날짜에서 흔들리지 않게(정렬 자체는 별도 테스트).
        let july10 = Date(timeIntervalSince1970: 1_783_641_600)
        let july9 = Date(timeIntervalSince1970: 1_783_555_200)
        let store = Self.store(reportList: {
            [
                Self.summary(sessionId: 1, status: .generating),
                Self.summary(sessionId: 2, interviewedAt: july10, status: .insufficientAnalysis),
                Self.summary(sessionId: 3, interviewedAt: july9, status: .failed)
            ]
        })

        await store.send(.view(.onAppear))
        await store.receive(\.inner.reportsLoaded) {
            $0.reports = [
                HomeFeature.Report(id: 2, dateText: "7월 10일 금", title: "백엔드 개발자 · 3년차"),
                HomeFeature.Report(
                    id: 3,
                    dateText: "7월 9일 목",
                    title: "레포트 생성에 실패했어요",
                    subtitle: "이용권 횟수는 차감되지 않아요",
                    canOpenReport: false
                )
            ]
            $0.expandedReportIDs = [2]
            $0.phase = .report(.returning)
        }
    }

    @Test("전부 생성 중이면 목록이 비어 기본 상태로 떨어진다")
    func allGeneratingFallsBackToDefaultPhase() async {
        let store = Self.store(
            initialState: HomeFeature.State(phase: .report(.returning), reports: [
                HomeFeature.Report(id: 1, dateText: "7월 10일 금", title: "옛 행")
            ]),
            reportList: { [Self.summary(sessionId: 1, status: .generating)] }
        )

        await store.send(.view(.onAppear))
        await store.receive(\.inner.reportsLoaded) {
            $0.reports = []
            $0.expandedReportIDs = []
            $0.phase = .default
        }
    }

    @Test("연차 표기는 온보딩 휠 규칙을 따른다 — 0 은 신입, 10 이상은 «10년 이상»")
    func careerTextFollowsWheelRule() async {
        let older = Date(timeIntervalSince1970: 1_783_641_600)  // 7월 10일(금) 09:00 KST
        let store = Self.store(reportList: {
            [
                Self.summary(sessionId: 1, careerYears: 0),
                Self.summary(sessionId: 2, careerYears: 12, interviewedAt: older)
            ]
        })

        await store.send(.view(.onAppear))
        await store.receive(\.inner.reportsLoaded) {
            $0.reports = [
                HomeFeature.Report(id: 1, dateText: "7월 11일 토", title: "백엔드 개발자 · 신입"),
                HomeFeature.Report(id: 2, dateText: "7월 10일 금", title: "백엔드 개발자 · 10년 이상")
            ]
            $0.expandedReportIDs = [1]
            $0.phase = .report(.returning)
        }
    }

    @Test("요약 문장이 오면 행 제목은 스냅샷 대신 그 문장이다")
    func summaryTitleWinsOverSnapshot() async {
        let store = Self.store(reportList: {
            [Self.summary(title: "캐시 도입 결정의 이유와 한계까지 설명했어요")]
        })

        await store.send(.view(.onAppear))
        await store.receive(\.inner.reportsLoaded) {
            $0.reports = [
                HomeFeature.Report(
                    id: 7,
                    dateText: "7월 11일 토",
                    title: "캐시 도입 결정의 이유와 한계까지 설명했어요"
                )
            ]
            $0.expandedReportIDs = [7]
            $0.phase = .report(.returning)
        }
    }

    @Test("공백뿐인 요약 문장은 스냅샷으로 떨어지고, 실패 세션은 요약이 있어도 상태 문구다")
    func blankTitleFallsBackAndFailedKeepsStatusText() async {
        let store = Self.store(reportList: {
            [
                Self.summary(sessionId: 1, title: "   "),
                Self.summary(sessionId: 2, title: "말끝을 흐리지 않고 마무리했어요", status: .failed)
            ]
        })

        await store.send(.view(.onAppear))
        await store.receive(\.inner.reportsLoaded) {
            $0.reports = [
                HomeFeature.Report(id: 1, dateText: "7월 11일 토", title: "백엔드 개발자 · 3년차"),
                HomeFeature.Report(
                    id: 2,
                    dateText: "7월 11일 토",
                    title: "레포트 생성에 실패했어요",
                    subtitle: "이용권 횟수는 차감되지 않아요",
                    canOpenReport: false
                )
            ]
            $0.expandedReportIDs = [1]
            $0.phase = .report(.returning)
        }
    }

    @Test("직군·연차가 비어 오면 조각을 빼고 준비 완료 문구만 남긴다")
    func missingSnapshotFallsBackToReadyText() async {
        let store = Self.store(reportList: { [Self.summary(careerYears: nil, jobTypeLabel: nil)] })

        await store.send(.view(.onAppear))
        await store.receive(\.inner.reportsLoaded) {
            $0.reports = [
                HomeFeature.Report(id: 7, dateText: "7월 11일 토", title: "면접 레포트가 준비됐어요")
            ]
            $0.expandedReportIDs = [7]
            $0.phase = .report(.returning)
        }
    }

    @Test("빈 목록은 기본 상태로 되돌리고 확장 자리를 접는다")
    func emptyListFallsBackToDefaultPhase() async {
        let store = Self.store(
            initialState: HomeFeature.State(phase: .report(.returning), reports: [
                HomeFeature.Report(id: 1, dateText: "7월 10일 금", title: "옛 행")
            ]),
            reportList: { [] }
        )

        await store.send(.view(.onAppear))
        await store.receive(\.inner.reportsLoaded) {
            $0.reports = []
            $0.expandedReportIDs = []
            $0.phase = .default
        }
    }

    @Test("목록 호출이 실패하면 앞서 그리던 목록을 지우지 않는다")
    func listFailureKeepsPreviousRows() async {
        struct LoadFailure: Error {}
        let previous = HomeFeature.Report(id: 1, dateText: "7월 10일 금", title: "옛 행")
        let store = Self.store(
            initialState: HomeFeature.State(phase: .report(.recent), reports: [previous]),
            reportList: { throw LoadFailure() }
        )

        await store.send(.view(.onAppear))
        // nil = «모른다» — 목록을 비우면 기록이 사라진 것처럼 보인다.
        await store.receive(\.inner.reportsLoaded)
        #expect(store.state.reports.elements == [previous])
        #expect(store.state.phase == .report(.recent))
    }
}

@MainActor
struct HomeReportExpansionTests {
    private static func report(_ id: Int) -> HomeFeature.Report {
        HomeFeature.Report(id: id, dateText: "7월 1\(id)일 토", title: "백엔드 개발자 · 3년차")
    }

    private static func store() -> TestStore<HomeFeature.State, HomeFeature.Action> {
        TestStore(
            initialState: HomeFeature.State(
                phase: .report(.returning),
                reports: [report(1), report(2), report(3)]
            )
        ) {
            HomeFeature()
        }
    }

    @Test("행 탭은 다른 행을 닫지 않는다 — 여러 행을 동시에 펼쳐 둔다")
    func rowsExpandIndependently() async {
        let store = Self.store()
        // 진입 시엔 최신 1개만 펼쳐져 있다.
        #expect(store.state.expandedReportIDs == [1])

        await store.send(.view(.userTappedReportRow(id: 2))) {
            $0.expandedReportIDs = [1, 2]
        }
        await store.send(.view(.userTappedReportRow(id: 3))) {
            $0.expandedReportIDs = [1, 2, 3]
        }
    }

    @Test("펼친 행을 다시 탭하면 그 행만 접힌다")
    func tappingExpandedRowCollapsesOnlyThatRow() async {
        let store = Self.store()
        await store.send(.view(.userTappedReportRow(id: 2))) {
            $0.expandedReportIDs = [1, 2]
        }
        await store.send(.view(.userTappedReportRow(id: 1))) {
            $0.expandedReportIDs = [2]
        }
    }

    @Test("[>] 탭은 세션 id 를 그대로 상세 진입 delegate 로 넘긴다")
    func detailButtonForwardsSessionID() async {
        let store = Self.store()
        await store.send(.view(.userTappedReport(id: 3)))
        await store.receive(\.delegate.reportDetailRequested)
    }
}
