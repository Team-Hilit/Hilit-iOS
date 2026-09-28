//
//  NetworkActivity.swift
//  CoreNetworkInterface
//
//  Created by EunseoKim on 26/08/02.
//

import Foundation
import Observation

// @lat: [[domain.map#네트워킹 인프라]]
/// 앱 전역 API in-flight 카운터. `trackingActivity()` 데코레이터만 증감하고,
/// AppView 가 `isLoading` 을 관찰해 전역 로딩(LoadingModal)을 표출한다.
@MainActor @Observable
public final class NetworkActivity {
    public static let shared = NetworkActivity()

    public private(set) var inFlightCount = 0

    /// 전역 로딩 오버레이 표출 조건 — **켜기는 늦추고, 한번 켜지면 최소 시간은 유지**한다.
    /// `inFlightCount > 0` 을 그대로 쓰면 세 곳에서 어긋난다.
    /// - 빠른 응답: 모달이 떴다 곧 사라져 «반짝» 한다 → `showDelay` 안에 끝나면 아예 안 띄운다.
    /// - 지연 직후 응답: 켜지자마자 꺼져 «반짝» 한다 → 켜지면 `minimumVisible` 만큼 유지한다.
    /// - 순차 호출: A 종료와 B 시작 사이에 카운트가 0 을 스쳐 «깜빡» 한다 → `settleDelay` 로 잇는다.
    ///
    /// 지연은 체인 전체에서 한 번씩만 든다 — 켜기 예약은 hop 마다 다시 걸지 않고,
    /// 끄기 예약은 다음 `begin()` 이 취소한다. API·콘텐츠 도착 시점엔 영향 없다(오버레이 전용).
    /// 표출 전 구간의 연타는 `isBlocking` 이 막는다.
    public private(set) var isLoading = false

    /// 입력 차단 조건 — 요청 시작 **즉시** 켜진다(보이지 않는 차단막). 모달 표출 지연(`showDelay`)
    /// 동안에도 버튼 연타로 같은 요청이 두 번 나가지 않게 하려는 것. 모달이 떠 있는 동안도 유지한다.
    public var isBlocking: Bool { inFlightCount > 0 || isLoading }

    /// 켜기 지연 — 이 안에 끝나는 요청은 로딩을 표시하지 않는다(입력 차단만 든다).
    private static let showDelay: Duration = .milliseconds(100)

    /// 최소 표출 — 한번 켜진 모달은 이만큼 지난 뒤에야 끈다.
    private static let minimumVisible: Duration = .milliseconds(300)

    /// 끄기 유예 — 체인 hop 사이 틈만 덮을 최소치. 완료 후 이만큼 딤이 남는다.
    private static let settleDelay: Duration = .milliseconds(80)

    /// 모달이 켜진 시각 — 최소 표출 잔여 시간 계산용. 꺼지면 nil.
    private var shownAt: ContinuousClock.Instant?

    /// 켜기 예약 진행 중 — 체인 중간에 카운트가 0 을 스쳐도 리셋하지 않는다.
    /// 그래야 지연이 **체인 시작 기준**으로 재져, 짧은 요청 여러 개가 이어질 때도 제때 뜬다.
    private var isShowScheduled = false

    /// 대기 중인 끄기 예약. 이어지는 `begin()` 이 취소해 표출을 물려받는다.
    private var hideTask: Task<Void, Never>?

    private init() {}

    func begin() {
        hideTask?.cancel()
        hideTask = nil
        inFlightCount += 1
        guard !isLoading, !isShowScheduled else { return }
        isShowScheduled = true
        // 취소하지 않는다 — 항상 완주해 예약 플래그를 내리고, 그 시점 카운트로 표출을 판정한다.
        Task { [weak self] in
            try? await Task.sleep(for: Self.showDelay)
            guard let self else { return }
            isShowScheduled = false
            guard inFlightCount > 0 else { return }   // 지연 안에 끝났다 — 표시 없이 넘어간다
            shownAt = .now
            isLoading = true
        }
    }

    func end() {
        inFlightCount -= 1
        guard inFlightCount == 0, isLoading else { return }
        // 최소 표출 잔여분과 hop 유예 중 긴 쪽만큼 기다렸다 끈다.
        let remaining = shownAt.map { Self.minimumVisible - (ContinuousClock.now - $0) } ?? .zero
        let delay = max(Self.settleDelay, remaining)
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, inFlightCount == 0 else { return }
            isLoading = false
            shownAt = nil
        }
    }
}

// @lat: [[domain.map#네트워킹 인프라]]
/// 전역 로딩 억제 스코프 — 이 안에서 나가는 요청은 in-flight 카운터를 건드리지 않는다.
///
/// ```swift
/// try await GlobalLoadingSuppression.run {
///     try await network.api(request)
/// }
/// ```
///
/// **쓰는 자리는 Domain Implementation 뿐이다.** Feature 는 Core 를 모르고(`NetworkClient` 주석),
/// 억제 여부는 «그 엔드포인트를 부르는 화면이 자기 대기 UI 를 이미 그리는가» 로 갈리므로
/// 엔드포인트 정의 옆에 두는 게 판단 근거와 가장 가깝다.
///
/// 억제 대상은 두 종류다 — ① **폴링**(3초 간격 재조회. 매 hop 마다 딤이 깜빡이고, 응답이
/// `showDelay` 보다 빠르면 아예 안 떠서 긴 대기 동안 아무 표시도 남지 않는다) ② **화면이
/// designed 대기 UI 를 그리는 구간**(모달로 덮으면 그 화면과 그 안의 취소 동선이 가려진다).
///
/// 태스크 로컬이라 스코프 안에서 만든 자식 태스크까지 따라간다 — 단, `Task { }` 로 떼어낸
/// 비구조적 태스크는 시작 시점 값을 복사하므로 스코프 밖에서 만들면 억제가 안 걸린다.
public enum GlobalLoadingSuppression {
    @TaskLocal public static var isActive = false

    /// `body` 가 도는 동안 전역 로딩 표출을 끈다.
    public static func run<T>(_ body: () async throws -> T) async rethrows -> T {
        try await $isActive.withValue(true, operation: body)
    }
}

public extension NetworkClient {
    /// 요청 시작/종료를 `NetworkActivity.shared` 에 반영하는 데코레이터.
    /// liveValue 한 곳에만 씌운다 — Authorized·토큰 재발급 포함 모든 실 HTTP 가
    /// base client 를 지나므로 이 한 겹으로 전 API 가 잡힌다. (스텁 기반 테스트는
    /// `live(session:baseURL:)` 를 직접 쓰므로 계측에 안 걸린다.)
    func trackingActivity() -> NetworkClient {
        NetworkClient { request in
            // 억제 스코프(폴링·자체 대기 UI) 는 계측을 통째로 건너뛴다 — begin 을 부르지 않으므로
            // end 도 없고, 바깥에서 돌고 있는 다른 요청의 카운트에도 영향이 없다.
            guard !GlobalLoadingSuppression.isActive else { return try await self.request(request) }
            await NetworkActivity.shared.begin()
            do {
                let data = try await self.request(request)
                await NetworkActivity.shared.end()
                return data
            } catch {
                // 취소(CancellationError) 포함 — actor hop 은 취소된 태스크에서도 완주한다
                await NetworkActivity.shared.end()
                throw error
            }
        }
    }
}
