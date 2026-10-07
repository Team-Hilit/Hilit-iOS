//
//  GuestFeedbackExampleApp.swift
//  FeatureGuestFeedbackExample
//
//  Created by 서정원 on 26/07/20.
//

import ComposableArchitecture
import Core   // NetworkClient.live — Example 은 composition root 라 Implementation link 허용 (D4)
import Domain // DomainGuestFeedback liveValue 활성화
import DomainGuestFeedbackInterface
import DomainGuestFeedbackTesting
import FeatureGuestFeedbackImplementation
import SwiftUI

/// G4 를 단독 구동하는 미니 루트 — 스텁 시나리오로 모든 게이트 상태를, 실서버 모드로 dev 서버를 확인한다.
@main
struct GuestFeedbackExampleApp: App {
    var body: some Scene {
        WindowGroup {
            ExampleHomeView()
        }
    }
}

struct ExampleHomeView: View {
    @State private var realServerToken = ""

    var body: some View {
        NavigationStack {
            List {
                Section("스텁 시나리오") {
                    ForEach(ExampleScenario.allCases) { scenario in
                        NavigationLink(scenario.title, value: scenario)
                    }
                }
                Section("실서버 (dev — https://dev.hilit.my)") {
                    TextField("공유 토큰 붙여넣기", text: $realServerToken)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    NavigationLink("실서버로 진입", value: realServerToken)
                        .disabled(realServerToken.isEmpty)
                }
            }
            .navigationTitle("G4 지인 평가")
            // delegate(.dismissed) 라우팅은 실제 앱의 코디네이터 몫 — Example 은 화면 상태 확인이 목적이라
            // GuestFeedbackView 를 그대로 얹는다(상단 X 는 여기선 무반응이 정상).
            .navigationDestination(for: ExampleScenario.self) { scenario in
                GuestFeedbackView(store: scenario.makeStore())
            }
            .navigationDestination(for: String.self) { token in
                GuestFeedbackView(store: Self.makeRealServerStore(token: token))
            }
        }
    }

    /// 실서버 — Example 번들엔 API_BASE_URL Info.plist 키가 없어 dev URL 을 직접 주입한다.
    /// guestFeedbackClient·localStore 는 link 된 Implementation 의 liveValue 가 그대로 쓰인다.
    @MainActor
    static func makeRealServerStore(token: String) -> StoreOf<GuestFeedbackFeature> {
        Store(initialState: GuestFeedbackFeature.State(token: token)) {
            GuestFeedbackFeature()
        } withDependencies: {
            $0.networkClient = .live(
                session: .shared,
                baseURL: { URL(string: "https://dev.hilit.my")! }
            )
        }
    }
}

enum ExampleScenario: String, CaseIterable, Identifiable, Hashable {
    case open
    case restoredDraft
    case full
    case privateLink
    case expired
    case alreadySubmitted
    case submitCapacityFull

    var id: String { rawValue }

    var title: String {
        switch self {
        case .open: "OPEN — 정상 평가 플로우"
        case .restoredDraft: "이어하기 — 임시저장 복원"
        case .full: "FULL — 정원 마감(시청 전용)"
        case .privateLink: "PRIVATE — 비공개/무효 링크"
        case .expired: "EXPIRED — 영상 만료"
        case .alreadySubmitted: "ALREADY_SUBMITTED — 기제출"
        case .submitCapacityFull: "제출 시 409 정원 마감"
        }
    }

    @MainActor
    func makeStore() -> StoreOf<GuestFeedbackFeature> {
        Store(initialState: GuestFeedbackFeature.State(token: "example-\(rawValue)")) {
            GuestFeedbackFeature()
        } withDependencies: {
            let localStore = GuestFeedbackLocalStore.inMemory()
            switch self {
            case .open:
                $0.guestFeedbackClient = .mock()
            case .restoredDraft:
                localStore.saveDraft("example-\(rawValue)", GuestFeedbackDraft(
                    nickname: "민지",
                    ratings: ["GAZE": RatingDraft(level: 2, comment: "가끔 피하는 느낌이었어요")],
                    overallFeedback: "",
                    startedEvaluation: true
                ))
                $0.guestFeedbackClient = .mock()
            case .full:
                $0.guestFeedbackClient = .mock(entry: .fixture(gate: .full, submissionOpen: false))
            case .privateLink:
                $0.guestFeedbackClient = .mock(entry: .fixture(gate: .private, submissionOpen: false))
            case .expired:
                $0.guestFeedbackClient = .mock(entry: .fixture(gate: .expired, submissionOpen: false))
            case .alreadySubmitted:
                $0.guestFeedbackClient = .mock(entry: .fixture(gate: .alreadySubmitted, submissionOpen: false))
            case .submitCapacityFull:
                $0.guestFeedbackClient = .mock(submitError: .capacityFull)
            }
            $0.guestFeedbackLocalStore = localStore
        }
    }
}
