//
//  AppFeatureEffects.swift
//  Hilit
//
//  Created by 서정원 on 26/08/10.
//

import ComposableArchitecture
import CoreCommonInterface
import DomainAppVersionInterface
import DomainConsentInterface
import DomainInterviewInterface
import Feature
import Foundation

// @lat: [[app]]
// AppFeature 의 effect 헬퍼 — 타입 선언과 라우팅 본문(AppFeature.swift)에서 갈라낸 별도 파일.
// 마이페이지발 리포트 배선으로 한 타입이 length 상한을 넘어, MyPageReducer 선례대로 갈랐다.
// 리듀서 본문이 부르는 것만 internal, 이 파일 안에서 끝나는 헬퍼는 private.
extension AppFeature {
    // MARK: - 실행 시점 훅

    /// 실행 직후 한꺼번에 거는 네 갈래.
    ///
    /// 잔존 정리를 **판정보다 먼저** 끝낸다 — 순서를 지키려 판정을 effect 안에서 잇지 않고
    /// 별도 액션(`firstLaunchResolved`)으로 갈라 놓는다. 미완 영상 업로드 재개(저널)는 그 순서에
    /// 얽히지 않아 나란히 건다 — 강제 종료·complete 실패 회복은 실행 시점 훅이 유일하다(스펙 ⑤).
    /// 앱 사망 세션 정리도 마찬가지로 실행 시점 훅뿐이라 여기 나란히 건다.
    func startUpEffects() -> Effect<Action> {
        .merge(
            .run { send in
                clearIfFirstLaunch()
                await send(.firstLaunchResolved)
            },
            .run { [uploadQueue] _ in await uploadQueue.resumePending() },
            cleanUpDeadHeldSession(),
            observeResolvedDeeplinks()
        )
    }

    /// 링크 SDK 가 해석해 낸 링크를 받는다 — **deferred**(앱이 없어 스토어를 다녀온 뒤 첫 실행)
    /// 진입의 유일한 재료다. 설치 상태는 `onOpenURL` 이 원본 URL 로 이미 처리했고, 그때 SDK 가
    /// 뒤늦게 같은 링크를 다시 흘려도 진행 중 평가는 덮이지 않는다(`presentGuestFeedback` 의 가드).
    ///
    /// 한 번의 해석이 URL 을 여럿 흘릴 수 있다 — 토큰이 어느 쪽에 실려 오는지 SDK 계약이 못 박지
    /// 않아 후보를 다 받고 판정은 파서에 맡긴다. 앱이 사는 동안 열려 있는 스트림이라 취소하지 않는다.
    private func observeResolvedDeeplinks() -> Effect<Action> {
        .run { [deeplinkClient] send in
            for await url in deeplinkClient.resolvedLinks() {
                await send(.deeplinkReceived(url))
            }
        }
    }

    // MARK: - 진행 중(held) 면접 두 갈래 → [[app#Cross-feature Routing]]

    /// [처음부터 시작] — 진행분을 **버리고** 새로. 서버에 USER_EXIT 중단을 알려 진행분 리포트
    /// 생성을 트리거하고(차감은 리포트 성공 시 확정), 보관값을 지운다.
    func abandonHeldSession(_ sessionId: Int) -> Effect<Action> {
        .run { [heldSessionStore, interviewClient, recordingClient] send in
            do {
                _ = try await interviewClient.abandonSession(sessionId, .userExit)
            } catch InterviewError.sessionAlreadyEnded {
                // 중복 호출의 409 는 «이미 중단 완료» 라는 서버 계약이다 — 실패가 아니라 목적 달성.
            } catch {
                // TODO: 중단 실패 안내 미도안(토스트 자리) — 화면을 유지하고 삼킨다.
                // 보관값은 **지우지 않는다**: 세션이 아직 서버에 살아 있어 재개 재료가 남아야 한다.
                // 세그먼트도 남긴다 — 세션이 살아 있으면 그게 재개 재료다.
                return
            }
            // 중단 왕복 사이에 장부가 다른 세션으로 바뀌었으면(완주·새 온보딩 완주) 남의 장부를 지우게
            // 된다 — 확인과 삭제를 한 연산으로 묶고, 세그먼트 폐기도 그 뒤에 세운다.
            guard heldSessionStore.clearIfHolding(sessionId) else { return }
            // 세션이 끝났으니 재개 재료(세그먼트)도 폐기 — `.interrupted` 만이 세그먼트를 보존하는 유일한
            // 이탈 경로다. purgeRecordings 는 원장이 그 세션을 아직 소유해 no-op 이라 discard 가 맞다(멱등·비던짐).
            await recordingClient.discardRecording()
            await send(.interviewAbandonResolved)
        }
    }

    /// [이어서 진행] — 서버에 살아 있는 세션으로 복귀. ① 재개 가능 조회 ② 재개 확정 ③ 면접 화면.
    /// ①·② 가 «끝난 세션» 을 내면 재개 재료가 아니므로 보관값을 지우고 홈을 다시 태워
    /// 변형을 갱신한다(진행 중 → 처음·소진).
    ///
    /// **시작 전 세션은 ② 를 건너뛰고 준비 화면으로 되돌린다**(2026-08-21) — 아직 질문이 오가지
    /// 않아 확정할 «다음 턴» 이 없고, 사용자는 카메라 확인·가이드를 아직 보지 않았다.
    func resumeHeldSession(_ sessionId: Int) -> Effect<Action> {
        .run { [heldSessionStore, interviewClient, recordingClient] send in
            do {
                let check = try await interviewClient.checkResume(sessionId)
                // 대기 사이에 장부가 바뀌었을 수 있다(완주·중단이 지웠거나 새 세션이 저장됐거나) —
                // 그러면 이 판정의 대상이 이미 없으니 아래 정리·라우팅을 **남의 값에 꽂지 않고** 멈춘다.
                guard let held = heldSessionStore.load(matching: sessionId) else { return }
                // ENDED — hold 만료 처리(세션 ABANDONED 전환·이용권 환불)는 서버가 이 호출
                // 안에서 이미 끝냈다. 클라가 할 일은 보관값 삭제뿐이다.
                // TODO(#69): status == .invalid 는 Interview_SttFailure 화면 — 복귀 라우팅
                //            ([[interview#코디네이터]])엔 배선됐고, 홈 탭 경로의 화면 전환만 미도안.
                guard check.isResumable else {
                    guard heldSessionStore.clearIfHolding(sessionId) else { return }
                    // 세션이 끝났으니 재개 재료(세그먼트)도 폐기 — `.interrupted` 만이 세그먼트를 보존하는 유일한
                    // 이탈 경로다. purgeRecordings 는 원장이 그 세션을 아직 소유해 no-op 이라 discard 가 맞다(멱등·비던짐).
                    await recordingClient.discardRecording()
                    return await send(.home(.view(.onAppear)))
                }
                // 시작 전 세션 — 살아 있다는 것만 확인하고 준비 화면으로 되돌린다.
                if !held.hasStarted {
                    return await send(.interviewReadinessResumeResolved(sessionId: sessionId))
                }
                // 재개가 hold 무효화와 레이스면 409 가 아니라 200 + sessionEnded 로 온다(서버 계약).
                // 질문이 비어 오는 것도 «끝난 세션» 과 같게 다룬다 — 이어서 물을 게 없으면 재개가 아니다.
                let resumed = try await interviewClient.confirmResume(sessionId)
                // 두 번째 대기도 같은 이유로 다시 맞춘다 — 여기선 라우팅이 목적이라 읽기로 확인한다.
                guard heldSessionStore.load(matching: sessionId) != nil else { return }
                guard !resumed.sessionEnded, let question = resumed.nextQuestion else {
                    guard heldSessionStore.clearIfHolding(sessionId) else { return }
                    // 위와 같은 이유 — 끝난 세션의 세그먼트는 재개 재료가 아니다(discard 는 멱등·비던짐).
                    await recordingClient.discardRecording()
                    return await send(.home(.view(.onAppear)))
                }
                await send(.interviewResumeResolved(sessionId: sessionId, question: question))
            } catch {
                // TODO: 재개 실패 안내 미도안(토스트 자리) — 화면을 유지하고 삼킨다.
                // 네트워크가 죽은 것과 세션이 끝난 것은 다르므로 보관값은 지우지 않는다.
            }
        }
    }

    // MARK: - dev 데이터 초기화

    /// dev 전용 «재설치 흉내» — 서버 로그아웃 · Keychain 전체 · 온보딩 draft ·
    /// 앱 UserDefaults 도메인 전체. 서버 호출이 실패해도 로컬 정리는 그대로 진행한다.
    func resetAppData() -> Effect<Action> {
        .run { send in
            try? await authClient.logout()
            clearLocalData()
            if let bundleId = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: bundleId)
            }
            await send(.appDataCleared)
        }
    }

    // MARK: - 업데이트 안내

    /// 스토어로 보낸다. 강제(FORCE)면 그냥 돌아와도 차단을 유지하려 같은 알럿을 다시 세운다.
    func openStore(_ policy: AppVersionPolicy) -> Effect<Action> {
        .run { [openURL] send in
            if let url = URL(string: policy.storeUrl) { await openURL(url) }
            if policy.updateType == .force { await send(.updateAlertReasserted) }
        }
    }

    // MARK: - 첫 실행 정리 → [[app#첫 실행 정리]]

    /// 이 설치의 첫 실행이면 잔존 로컬 데이터를 지운다 — 앱을 지워도 Keychain 은 남기 때문이다.
    ///
    /// 남는 게 토큰뿐이라 정리를 안 하면 재설치 직후가 «로그인된 상태» 로 판정된다. 삭제와 함께
    /// 사라지는 UserDefaults 쪽(draft)은 이미 비어 있어 지워도 손해가 없다 — 판정 하나로 둘 다 맞춘다.
    ///
    /// 마커는 **정리 뒤에** 찍는다. 사이에서 앱이 죽으면 다음 실행이 다시 첫 실행으로 판정돼 정리를
    /// 마치는데, 먼저 찍으면 지우다 만 상태로 굳는다.
    func clearIfFirstLaunch() {
        guard firstLaunchStore.isFirstLaunch() else { return }
        clearLocalData()
        firstLaunchStore.markLaunched()
    }

    /// 로컬 저장소 정리 — 첫 실행 정리와 로그아웃이 공유한다. 서버 호출은 하지 않는다.
    ///
    /// Keychain 은 `tokenStore.clear()`(항목 하나)가 아니라 **전체**를 지운다 — 목적이 «앱이 남긴 것
    /// 전부» 라 Keychain 항목이 늘어도 놓치지 않아야 한다. UserDefaults 는 도메인째 지우지 않는다:
    /// 첫 실행 마커가 거기 있어 통째로 날리면 다음 실행이 다시 첫 실행으로 판정된다.
    func clearLocalData() {
        KeychainWipe.wipeAll()
        draftStore.clear()
    }

    // MARK: - 복귀 시점 보관값 검증

    /// 포그라운드 복귀 — 홈에 남은 보관값이 그새 끝난 세션(hold 20분 만료 등)인지 확인하고, 끝났으면
    /// 카드를 걷는다(스펙 ③ «20분 초과 복귀 → 카드 없이 홈»). 이 판정이 면접 화면이 아니라 여기 있는 건,
    /// 동결 세션이 백그라운드 진입 즉시 홈으로 나오기 때문이다([[interview#코디네이터]] — 2026-08-09 개정).
    /// 죽은 프로세스 보관값은 대상이 아니다 — 그건 실행 시점 킬 클린업 몫이라 술어를 정확히 반대로 쓴다.
    /// 실패(오프라인)는 삼킨다: 보관값을 남겨 두고 다음 복귀나 카드 탭이 다시 묻는다.
    func validateHeldSession() -> Effect<Action> {
        .run { [heldSessionStore, interviewClient, recordingClient] send in
            guard let held = heldSessionStore.load(), held.isResumableInCurrentProcess else { return }
            guard let check = try? await interviewClient.checkResume(held.sessionId), !check.isResumable
            else { return }
            // 물어본 그 세션의 장부가 아직 그대로일 때만 걷는다 — 대기 사이에 새 세션이 저장됐으면
            // 여기서 지우는 것이 그 새 장부이고, 버리는 세그먼트도 그쪽 것이다(#130 이 만든 고아와 같은 꼴).
            // 끝난 세션이니 재개 재료(세그먼트)도 폐기한다 — 홈 두 갈래의 ENDED 처리와 같은 규약이다.
            // 환불은 서버가 그 GET 안에서 끝냈다. INVALID 도 여기선 카드를 걷는 것까지다 —
            // 띄울 면접 흐름이 없어 STT 실패 화면은 홈 [이어서 진행] 경로에 남는다(#69 TODO).
            guard heldSessionStore.clearIfHolding(held.sessionId) else { return }
            await recordingClient.discardRecording()
            await send(.home(.view(.onAppear)))
        }
    }

    // MARK: - 앱 사망 세션 정리

    /// 앱 사망 세션 정리(스펙 ④) — 죽은 프로세스의 진행분 보관값을 서버에 USER_EXIT 로 닫고 로컬을 걷는다.
    /// 실패(오프라인·미로그인 401 등)는 보관값 유지 — 다음 실행이 재시도하고, 그동안 홈 카드는
    /// 프로세스 토큰 필터가 막는다(스펙 ⑤). 홈 렌더와 레이스해도 같은 이유로 무해하다.
    func cleanUpDeadHeldSession() -> Effect<Action> {
        .run { [heldSessionStore, interviewClient, recordingClient] _ in
            guard let sessionId = HeldSessionCleanup.target(heldSessionStore.load()) else { return }
            do {
                let check = try await interviewClient.checkResume(sessionId)
                if HeldSessionCleanup.followup(check) == .abandonUserExit {
                    _ = try await interviewClient.abandonSession(sessionId, .userExit)
                }
            } catch InterviewError.sessionAlreadyEnded {
                // 이미 중단 완료(409) — 목적 달성으로 간주([처음부터 시작] 과 같은 규약).
            } catch InterviewError.sessionNotFound {
                // 내 세션이 아니다(계정 전환 등 404) — 서버에 닫을 것이 없으니 로컬만 걷는다.
            } catch {
                return
            }
            // 정리를 시작한 그 장부일 때만 걷는다 — 서버 왕복 사이에 사용자가 새 면접을 시작했으면
            // (온보딩 완주가 장부를 연다) 여기서 지우는 것이 살아 있는 세션의 장부다.
            guard heldSessionStore.clearIfHolding(sessionId) else { return }
            await recordingClient.purgeRecordings(sessionId)
        }
    }

    // MARK: - Splash 세션 복구 판정 → [[auth#가입 플로우]]

    /// 버전 게이트 → 토큰 유무 → pending 한 콜로 목적지를 정한다 (docs/work/launch-routing.md §4).
    ///
    /// 버전 게이트가 **먼저**다 — FORCE 인데 뒤에 두면 이미 홈에 들어간 뒤에 막게 된다. 무인증 API 라
    /// 토큰 유무와 무관하게 돌릴 수 있다. 실패는 **fail-open** — 버전 정책 서버가 죽었다고 앱 실행까지
    /// 막지 않는다([[api#AppVersion]]).
    ///
    /// refresh 를 **먼저 때리지 않는다** — Access 는 3시간이라 콜드 스타트 대부분 살아 있고,
    /// 만료면 이 호출의 403 을 AuthorizedNetworkClient 가 잡아 재발급 후 재시도한다([[api#토큰 수명주기]]).
    /// 매 실행 무조건 rotation 은 콜 낭비 + 페어 교체 중 앱 킬 = 세션 유실 리스크만 키운다.
    ///
    /// 실패는 **두 종류로 갈라야** 한다 — `sessionExpired`(재발급까지 실패, 토큰은 인터셉터가 이미 폐기)는
    /// 재로그인이고, 네트워크·5xx 는 판정 불가라 토큰을 살려 둔 채 재시도한다.
    /// 뭉뚱그리면 오프라인에서 앱을 켠 사용자가 로그아웃당한다.
    func resolveLaunchRouting() -> Effect<Action> {
        .run { send in
            if let policy = await checkAppVersion(), policy.updateType != .none {
                await send(.appVersionResolved(policy))
                // FORCE 는 여기서 끝 — 세션 판정을 시작하지 않는다.
                if policy.updateType == .force { return }
            }
            guard authClient.isAuthenticated() else {
                return await send(.launchRoutingResolved(.login))
            }
            do {
                // 게이트 판정값 2개를 한 번에 받는다 — 약관 항목까지 딸려와 재조회가 없고,
                // 인증 필요 API 라 세션 유효성 검증을 겸한다.
                let pending = try await consentClient.pending()
                await send(.launchRoutingResolved(routing(for: pending)))
            } catch ConsentError.sessionExpired {
                await send(.launchRoutingResolved(.login))
            } catch {
                await send(.launchRoutingResolved(.failed(step: "consents/pending", reason: "\(error)")))
            }
        }
    }

    func apply(_ routing: LaunchRouting, to state: inout State) -> Effect<Action> {
        switch routing {
        case .login:
            state.auth = AuthFeature.State()
            state.root = .auth
        case let .resume(destination):
            state.auth = AuthFeature.State(resuming: destination)
            state.root = .auth
        case .home:
            state.root = .home
        case let .failed(step, reason):
            if LogGate.isVerbose {
                print("🚧 [LAUNCH-ROUTING] \(step) 실패 — \(reason)")
            }
            state.root = .splashFailed
        }
        return .none
    }

    /// 버전 판정 — 실패(네트워크·5xx·버전 키 없음)는 nil 로 삼켜 진입을 막지 않는다(fail-open).
    private func checkAppVersion() async -> AppVersionPolicy? {
        guard let version = AppEnvironment.marketingVersion else { return nil }
        return try? await appVersionClient.check(version)
    }

    /// 게이트 2단 체인 — ① 동의(`status`) ② 프로필(`profileRegistered`). 순서가 고정이다.
    private func routing(for pending: ConsentPending) -> LaunchRouting {
        guard pending.status == .upToDate else {
            return .resume(.terms(items: pending.items, profileRegistered: pending.profileRegistered))
        }
        return pending.profileRegistered ? .home : .resume(.onboarding)
    }
}
