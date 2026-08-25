//
//  HeldSessionStoreLive.swift
//  DomainInterviewImplementation
//
//  Created by EunseoKim on 26/08/08.
//

import ComposableArchitecture
import DomainInterviewInterface
import Foundation

extension HeldSessionStore: @retroactive DependencyKey {
    /// 키에 버전을 박아 둔다 — 보관 값이 늘어 디코드가 깨지면 키를 올려 옛 값을 버린다.
    private static let key = "interview.heldSession.v1"

    /// 네 연산을 **한 줄로 세우는** 락. UserDefaults 자체는 스레드 안전이지만 `clearIfHolding` 은
    /// 읽기+삭제 복합 연산이라, 저장(리듀서 본문 = 메인)과 삭제(회수 effect = 협력 스레드)가
    /// 그 사이에 끼면 새 장부를 지운다 — 그래서 save·clear 도 같은 락을 지나야 뜻이 산다.
    /// 타입에 두는 건 `liveValue` 가 computed 라 여기서 만들면 접근마다 다른 락이 되기 때문이다.
    private static let lock = NSLock()

    public static var liveValue: HeldSessionStore {
        HeldSessionStore(
            load: { lock.withLock { loadUnlocked() } },
            save: { session in
                guard let raw = try? JSONEncoder().encode(session) else { return }
                lock.withLock { UserDefaults.standard.set(raw, forKey: key) }
            },
            clear: { lock.withLock { UserDefaults.standard.removeObject(forKey: key) } },
            clearIfHolding: { sessionId in
                lock.withLock {
                    guard loadUnlocked()?.sessionId == sessionId else { return false }
                    UserDefaults.standard.removeObject(forKey: key)
                    return true
                }
            }
        )
    }

    /// 락을 **이미 쥔 채** 부르는 읽기 — `NSLock` 은 재진입이 안 돼 `load` 클로저를 다시 부를 수 없다.
    private static func loadUnlocked() -> HeldSession? {
        guard let raw = UserDefaults.standard.data(forKey: key),
              let session = try? JSONDecoder().decode(HeldSession.self, from: raw)
        else { return nil }
        return session
    }
}
