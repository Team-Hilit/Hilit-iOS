//
//  HeldSessionStore.swift
//  DomainInterviewInterface
//
//  Created by EunseoKim on 26/08/08.
//

import ComposableArchitecture
import Foundation

// MARK: - 보관 값 (서버 스키마 아님 — 클라 로컬)

/// 진행 중(held) 면접 세션의 로컬 보관 값. 진행 중 세션 **목록 조회 API 가 없어**
/// 홈이 [이어서 진행] 에 실을 `sessionId` 를 클라가 들고 있어야 한다 ([[home#진입 로드]]).
public struct HeldSession: Codable, Equatable, Sendable {
    public var sessionId: Int
    /// 지금까지 녹화된 면접 영상 길이(초). 남은 질문 수 표기의 재료 — 최대 면접 길이 8분에서 뺀
    /// 잔여 시간으로 rule-base 환산하는 계산은 Feature 몫이고, 여기엔 저장만 한다.
    public var recordedSeconds: Int
    /// **면접이 시작된 프로세스**의 표식 — 시작하기 탭 시엔 nil 이고(세션 화면이 아직 녹화를 열기 전),
    /// 세션 화면이 녹화를 열 때 찍힌다(2026-08-09). 앱이 죽으면 세그먼트 파일(tmp·프로세스 수명)이 사라져
    /// 재개가 불가능해지므로(스펙 ⑤), 다른 프로세스의 표식 = 정리 대상이다.
    public var processToken: UUID?
    /// 사용자가 **[면접 시작하기] 를 눌렀는가**. 세션은 온보딩 분석이 끝난 순간 서버에 만들어지지만
    /// 그때는 아직 준비 화면이라, 이 값이 «장부에 올렸다» 와 «면접이 시작됐다» 를 가른다(2026-08-21).
    ///
    /// 둘을 가르는 이유: 세션이 서버에 생긴 순간부터 장부를 들어야 시작 전 이탈로 생긴 IN_PROGRESS
    /// 세션을 회수할 수 있는데(그 회수 경로의 입구가 전부 `load()` 다), 장부에 있다고 홈이 «진행 중»
    /// 카드를 그리면 시작하지도 않은 사용자에게 카드가 뜬다(#130 이 잡은 증상). 장부는 들되 카드는
    /// 가리는 자리가 이 플래그다.
    public var hasStarted: Bool

    /// 이 프로세스의 표식 — 실행마다 새 값. 저장 시 스탬프해 재실행 후 진행분 재개를 차단한다.
    public static let currentProcessToken = UUID()

    /// 홈이 [이어서 진행] 을 제안해도 되는가 — **표식이 없으면**(녹화가 열리기 전에 죽은 보관분) 잃을
    /// 영상이 없어 프로세스를 넘어 재개 가능하고, 있으면 그게 이 프로세스일 때만이다. 어기면 앞부분 없는
    /// 영상에 마킹만 이어져 서버 정렬이 무너진다(스펙 ⑤).
    ///
    /// 판정을 «0초» 가 아니라 표식으로 하는 이유(2026-08-09 수정): `recordedSeconds` 는 백그라운드
    /// 마감에서만 갱신돼, 백그라운드를 거치지 않고 죽은 면접(크래시·메모리 압박)이 0초로 남는다.
    /// 0초를 무조건 재개 가능으로 보면 그 세션이 시작 직후 보관분과 구분되지 않아 영영 정리되지 않는다.
    /// 표식 없는 구버전 저장값은 옛 규칙(0초 여부)으로 접는다 — 진행분이 있으면 죽은 값 취급.
    public var isResumableInCurrentProcess: Bool {
        guard let processToken else { return recordedSeconds == 0 }
        return processToken == Self.currentProcessToken
    }

    /// `hasStarted` 기본값이 `true` 인 이유: 이 값을 저장하던 자리가 원래 전부 «시작됨» 이었다.
    /// 시작 전 장부(온보딩 완주)만 `false` 를 명시로 넘긴다 — 예외가 눈에 띄는 쪽이 안전하다.
    public init(
        sessionId: Int,
        recordedSeconds: Int,
        hasStarted: Bool = true,
        processToken: UUID? = nil
    ) {
        self.sessionId = sessionId
        self.recordedSeconds = recordedSeconds
        self.hasStarted = hasStarted
        self.processToken = processToken
    }
}

// MARK: - Codable 하위호환

public extension HeldSession {
    /// 옛 저장값에는 `hasStarted` 가 없다 — 그 시절 장부는 [시작하기] 탭에서만 심었으니 **true** 로 읽는다.
    /// 키(`interview.heldSession.v1`)를 올려 버리면 업그레이드 순간 진행 중이던 면접의 장부가 사라져,
    /// 이 작업이 없애려는 바로 그 고아 세션을 우리 손으로 만든다.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            sessionId: try container.decode(Int.self, forKey: .sessionId),
            recordedSeconds: try container.decode(Int.self, forKey: .recordedSeconds),
            hasStarted: try container.decodeIfPresent(Bool.self, forKey: .hasStarted) ?? true,
            processToken: try container.decodeIfPresent(UUID.self, forKey: .processToken)
        )
    }
}

// MARK: - Store

// 진행 중 세션의 로컬 영속 seam (UserDefaults, 외부 IO = Domain 레이어 규칙). 서버 무관이고
// 한 번에 한 세션만 보관한다 — 이용권 예약이 세션 하나를 잡는 구조라 동시 진행이 없다.
// 수명: **온보딩 완주(= 서버에 세션이 생긴 순간)** 에 `hasStarted false` 로 연다(2026-08-21) →
// [시작하기] 탭에서 `hasStarted true` → 세션 화면이 녹화를 열 때 **프로세스 표식**을 찍고 →
// 백그라운드 마감(세그먼트 경계)마다 누적초로 갱신 → 면접 완료 시 삭제.
// 중단(abandon)·재개 불가(ENDED) 판정도 끝난 세션이라 같이 삭제한다.
//
// 여는 시점이 «세션 생성» 인 이유: 회수 경로(킬 클린업·복귀 검증·홈 두 갈래)의 입구가 전부 `load()` 라
// 장부가 비면 회수 기계 전체가 no-op 이고, 그 사이 서버 세션은 IN_PROGRESS 로 굳는다. 2026-08-18~21
// 사흘간 «시작하기 탭에 저장» 이었고(#130), 그동안 준비 화면에서 이탈한 세션이 전부 고아가 됐다.
// 카드가 뜨는 문제는 여는 시점이 아니라 `hasStarted` 로 가린다 — [[interview#코디네이터]].
public struct HeldSessionStore: Sendable {
    public var load: @Sendable () -> HeldSession?
    public var save: @Sendable (HeldSession) -> Void
    public var clear: @Sendable () -> Void
    /// **장부가 아직 그 세션일 때만** 지운다 — 지웠으면 true(= 뒤처리 권한이 이 호출에 있다).
    ///
    /// 회수 경로(홈 두 갈래·복귀 검증·킬 클린업)는 전부 서버 왕복을 건넌 뒤에 장부를 걷는데, 그 사이
    /// 다른 액션이 장부를 지우거나(완주·중단) **새 세션을 저장한다**(온보딩 완주 = 이용권이 잡히는 순간).
    /// `load()` 로 확인한 뒤 `clear()` 를 부르면 그 두 호출 사이가 열려 있어, 하필 거기서 저장된 새 장부를
    /// 지운다 — 회수 동선이 통째로 사라지는 #130 과 같은 고아를 우리 손으로 만든다. 확인과 삭제가
    /// **한 연산**이어야 그 틈이 구조적으로 없다. 세그먼트 폐기·홈 재조회도 반환값 뒤에 세운다.
    public var clearIfHolding: @Sendable (_ sessionId: Int) -> Bool

    public init(
        load: @escaping @Sendable () -> HeldSession?,
        save: @escaping @Sendable (HeldSession) -> Void,
        clear: @escaping @Sendable () -> Void,
        clearIfHolding: @escaping @Sendable (_ sessionId: Int) -> Bool
    ) {
        self.load = load
        self.save = save
        self.clear = clear
        self.clearIfHolding = clearIfHolding
    }
}

public extension HeldSessionStore {
    /// **판정을 시작한 그 세션의 보관값일 때만** 돌려준다 — 아니면 nil.
    ///
    /// 서버 왕복을 건넌 뒤 장부의 값(`hasStarted` 등)으로 **라우팅할 때** 쓴다: 그 사이 다른 세션이
    /// 저장됐으면 B 의 값으로 A 를 라우팅하게 된다. 어긋나면 그 effect 는 할 일이 없으니 멈춘다
    /// (장부를 바꾼 쪽이 자기 후속을 이미 들고 있다). **삭제는 이걸로 가드하지 않는다** —
    /// 확인과 삭제 사이가 열려 있어서다. 그 자리는 `clearIfHolding` 한 연산이 맡는다.
    func load(matching sessionId: Int) -> HeldSession? {
        guard let held = load(), held.sessionId == sessionId else { return nil }
        return held
    }

    /// 인메모리 구현 — Preview·Example·Feature 테스트 용. UserDefaults 를 건드리지 않는다.
    static func inMemory(initial: HeldSession? = nil) -> HeldSessionStore {
        let held = LockIsolated<HeldSession?>(initial)
        return HeldSessionStore(
            load: { held.value },
            save: { session in held.withValue { $0 = session } },
            clear: { held.withValue { $0 = nil } },
            clearIfHolding: { sessionId in
                held.withValue { value in
                    guard value?.sessionId == sessionId else { return false }
                    value = nil
                    return true
                }
            }
        )
    }
}

extension HeldSessionStore: TestDependencyKey {
    /// 컨벤션: testValue 는 반드시 unimplemented — 빈 클로저 금지.
    public static var testValue: HeldSessionStore {
        HeldSessionStore(
            load: unimplemented("HeldSessionStore.load", placeholder: nil),
            save: unimplemented("HeldSessionStore.save"),
            clear: unimplemented("HeldSessionStore.clear"),
            clearIfHolding: unimplemented("HeldSessionStore.clearIfHolding", placeholder: false)
        )
    }

    /// Preview 는 진행 중 세션이 **있는** 상태를 그린다 — 홈의 진행 중 변형이 그래야 보인다.
    /// 프리뷰는 «살아 있는 프로세스의 진행분» 을 그린다 — 토큰을 안 찍으면 죽은 값이라 홈이 걸러 버린다.
    public static var previewValue: HeldSessionStore {
        .inMemory(
            initial: HeldSession(
                sessionId: 1,
                recordedSeconds: 132,
                processToken: HeldSession.currentProcessToken
            )
        )
    }
}

public extension DependencyValues {
    var heldSessionStore: HeldSessionStore {
        get { self[HeldSessionStore.self] }
        set { self[HeldSessionStore.self] = newValue }
    }
}
