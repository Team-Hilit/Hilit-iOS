//
//  AuthSuspensionFeature.swift
//  FeatureAuthImplementation
//
//  Created by EunSeo on 26/07/31.
//

import ComposableArchitecture
import Foundation

// @lat: [[auth#가입 플로우]]
/// AuthSuspension(A4) — 정지(블랙리스트) 계정이 면접 시작을 시도했을 때의 안내 화면.
/// 진입은 위저드 세션 생성의 403 `ACCOUNT_SUSPENDED` — 제시는 AppFeature(cross-feature, 위저드 cover 위).
/// 기획은 «면접 시작 탭 시점» 이지만 서버에 사전 조회 API 가 없어 세션 생성 응답이 유일한 신호다.
/// 정지는 면접 시작만 차단한다 — 로그인·레포트 열람·마이페이지·탈퇴는 정상(PRD Part7 확정).
@Reducer
public struct AuthSuspensionFeature {
    /// 이의 제기 CS 메일 주소. TODO: 운영 확정 주소로 교체(미결 S-5 — 주소는 확보됨, 값 전달 대기).
    public static let supportEmail = "cs@hilit.app"

    @ObservableState
    public struct State: Equatable {
        public init() {}
    }

    public enum Action: ViewAction {
        case view(View)
        case delegate(Delegate)

        /// 사용자 입력·생명주기. View 의 send(...) 로만 방출된다.
        public enum View: Equatable, Sendable {
            /// [메일 보내기] — CS 메일(mailto)로 이의 제기.
            case userTappedContactSupport
            /// [홈으로 돌아가기].
            case userTappedGoHome
        }

        /// 부모(AppFeature) 통보. 부모는 이것만 매칭한다 (D1).
        @CasePathable
        public enum Delegate: Equatable, Sendable {
            /// 홈 복귀 요청 — 이 화면을 내리는 것은 부모 몫.
            case homeRequested
        }
    }

    @Dependency(\.openURL) var openURL

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { _, action in
            switch action {
            case .view(.userTappedContactSupport):
                return .run { _ in
                    guard let url = URL(string: "mailto:\(Self.supportEmail)") else { return }
                    await openURL(url)
                }

            case .view(.userTappedGoHome):
                return .send(.delegate(.homeRequested))

            case .delegate:
                return .none
            }
        }
    }
}
