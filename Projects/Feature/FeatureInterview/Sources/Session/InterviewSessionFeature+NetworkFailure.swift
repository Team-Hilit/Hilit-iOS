//
//  InterviewSessionFeature+NetworkFailure.swift
//  FeatureInterview
//
//  Created by EunseoKim on 26/11/17.
//

import ComposableArchitecture
import DomainInterviewInterface
import DomainRecordingInterface
import Foundation

// @lat: [[interview#세션]]
// 네트워크 실패 — 녹화를 **멈추고** 안내 오버레이를 띄운다(HLT-41, PM 결정 2026-10-24: Android 와 같게).
// 옛 동작은 녹화·마이크를 살린 채 오버레이를 얹었는데, 그동안 사용자가 말해도 꼬리 질문이 만들어지지 않는다.
// 버튼 흐름은 HLT-86 그대로다 — [이어서 진행하기] 는 새 세그먼트로 녹화를 다시 열고 실패한 단계를 재실행하고,
// [중단하기] 는 제출 없이 abandon(NETWORK_DISCONNECT, 이용권 환급) 후 홈. 턴은 서버가 보존한다.
extension InterviewSessionFeature {
    /// 실패 감지 — 재생·제출·토스트·**시계**를 끊고 백그라운드 동결과 같은 순서 계약으로 세그먼트를 마감한다
    /// (세션 오디오 마감 → `suspendRecording` → `stopCapture` → held 갱신). 오버레이는 마감이 끝난 뒤(`capturePaused`)에
    /// 띄운다 — 마감 중에 [이어서 진행하기] 가 오면 `startRecording` 이 마감 구간 가드에 막혀 새 세그먼트가 안 선다.
    func reduceNetworkFailure(_ state: inout State, retry: State.PendingRetry) -> Effect<Action> {
        state.isEarlyExitWarningPresented = false
        state.isExitConfirmPresented = false
        state.pendingRetry = retry
        state.toast = nil
        let cancels: Effect<Action> = .merge(
            .cancel(id: CancelID.playback),
            .cancel(id: CancelID.submission),
            .cancel(id: CancelID.toast),
            // 녹화가 없는 시간은 영상 타임라인이 아니다 — 시간 마킹 축도 함께 멈춘다(동결과 같은 규칙).
            .cancel(id: CancelID.clock)
        )
        // 이미 내리는 중·내려 둔 상태면 다시 마감하지 않는다. 오버레이도 여기서 세우지 않는다 — 마감이 아직 비행 중이면
        // 그 완료(`capturePaused`)가 띄우고, 그 전에 띄우면 재개의 `startRecording` 이 마감 구간 가드에 막혀 새 세그먼트 없이
        // 성공처럼 돌아온다. (재생·제출 effect 가 이 창엔 돌지 않아 현재 도달 경로는 없다 — 방어선이다.)
        guard !state.isCapturePaused else { return cancels }
        state.isCapturePaused = true
        let sessionId = state.sessionId
        let hasRecording = state.hasRecording
        return .merge(
            cancels,
            // 마이크 effect 는 취소하지 않는다 — 취소가 `stopCapture` 로 이어져 진행 중 세션 오디오를 폐기한다.
            // 마감 뒤에 같은 run 안에서 `stopCapture` 를 부르고, 그 종료가 캡처 effect 를 끝낸다(`freezeAndLeave` 와 같다).
            .run { send in
                let audio = await speechClient.finishSessionAudioRecording()
                let cumulative = await recordingClient.suspendRecording(
                    audio.map { RecordingAudioSegment(fileURL: $0.fileURL, startedAtHostSeconds: $0.startedAtHostSeconds) }
                )
                await speechClient.stopCapture()
                // 오버레이 위에서 앱이 죽거나 백그라운드로 나가도 홈 [이어서 진행] 이 이 누적초에서 잇는다.
                if hasRecording, let cumulative {
                    heldSessionStore.save(HeldSession(
                        sessionId: sessionId,
                        recordedSeconds: Int(cumulative.rounded()),
                        processToken: HeldSession.currentProcessToken
                    ))
                }
                await send(.inner(.capturePaused))
            }
        )
    }

    func reduceCapturePaused(_ state: inout State) -> Effect<Action> {
        guard state.isCapturePaused, state.failure == nil else { return .none }
        // 마감 중에 들어온 이탈 — 오버레이 대신 동결한다(세그먼트는 이미 닫혀 동결의 suspend 는 no-op 이다).
        if state.isLeavePending { return freezeAndLeave(&state, deferringCaptureTransition: false) }
        // 마감을 기다리는 사이 열린 모달은 오버레이 아래에 깔리지 않게 닫는다.
        state.isEarlyExitWarningPresented = false
        state.isExitConfirmPresented = false
        state.failure = InterviewFailureFeature.State(kind: .network)
        return .none
    }

    /// 녹화 재개 결과 — 시계·마이크(+세션 오디오)를 다시 열고 보관한 단계를 재실행한다.
    /// 재시작 실패면 **영상 없는 리포트로 수렴**한다(`hasRecording = false` — 녹화 시작 실패와 같은 계약). 앞 세그먼트만
    /// 합성하면 이후 턴의 시간 마킹이 영상 끝을 넘고, 홈 재개 땐 누적초 시드가 그 구간만큼 뒤로 돌아가 마킹이 겹친다.
    func reduceCaptureResumed(_ state: inout State, cumulativeSeconds: Double?) -> Effect<Action> {
        guard state.isCapturePaused else { return .none }
        state.isCapturePaused = false
        // 재개 녹화가 서는 동안 들어온 이탈 — 방금 선 세그먼트를 동결이 닫는다(늦게 선 녹화가 고아로 남지 않는다).
        if state.isLeavePending {
            state.pendingRetry = nil
            return freezeAndLeave(&state, deferringCaptureTransition: false)
        }
        if state.hasRecording, cumulativeSeconds == nil {
            state.hasRecording = false
        }
        if let cumulativeSeconds {
            state.elapsedSeconds = Int(cumulativeSeconds.rounded())   // 에셋 실측 누적초 = 새 세그먼트의 시작점
            heldSessionStore.save(HeldSession(
                sessionId: state.sessionId,
                recordedSeconds: Int(cumulativeSeconds.rounded()),
                processToken: HeldSession.currentProcessToken
            ))
        }
        // 재시드가 해금 경계를 건너뛰면 등호 tick 이 다시 오지 않는다 — 토스트 없이 켠다(재개 진입과 같은 규칙).
        if state.elapsedSeconds >= Self.exitUnlockSeconds {
            state.isExitAvailable = true
        }
        let retry = state.pendingRetry
        state.pendingRetry = nil
        let resume: Effect<Action> = .merge(
            sessionClock(),
            micCaptureLogging(startsSessionAudio: cumulativeSeconds != nil, startsMuted: retry == .playQuestion)
        )
        switch retry {
        case .playQuestion:
            // 계약 위반 진입은 processingAnswer 로 굳어 있다 — asking 으로 되돌려야 재생 완료 전환이 산다.
            state.phase = .asking
            // 재생 재시작 시점을 영상 축으로 다시 마킹 — 서버가 이 값으로 영상과 정렬한다.
            state.questionAudioStartedAt = state.elapsedSeconds
            return .merge(resume, playCurrentQuestion(state))
        case let .submit(submission):
            state.isSubmitting = true
            return .merge(resume, submissionEffect(state.sessionId, submission, fillsAudio: false))
        case nil:
            return resume
        }
    }

    /// 오버레이(네트워크 실패)의 delegate — 재개는 녹화를 다시 연 뒤 보관한 단계를 재실행, 중단은 **제출 없이** 이탈.
    /// BACK_EXIT 제출을 태우면 이용권이 차감돼 화면 문구(«차감되지 않아요»)와 어긋난다(스펙 «결정 요약») —
    /// 중단이 서버에 알리는 건 제출이 아니라 중단 API(abandon)다.
    func reduceFailure(
        _ state: inout State, _ action: PresentationAction<InterviewFailureFeature.Action>
    ) -> Effect<Action> {
        // 중단 레이스(최대 3초) 중엔 오버레이가 그대로 떠 있어 두 버튼이 계속 눌린다 — 전부 no-op 이어야 한다.
        // [중단하기] 재탭은 abandon 재발사(이미 버린 세션에 두 번째 요청)를, [이어서 진행하기]는 버린 세션의
        // 재생·재제출을 부른다. 첫 탭은 아래에서 `isAbandoning` 을 세우기 «전» 이라 이 가드를 그대로 지난다.
        if state.isAbandoning { return .none }

        switch action {
        case .presented(.delegate(.resumeRequested)):
            state.failure = nil
            // 녹화가 있던 세션이면 새 세그먼트를 연다 — 재생·재제출은 녹화가 선 뒤(`captureResumed`)에 시작해야
            // 그 구간이 영상에 담기고 시간 마킹이 새 세그먼트 축에 맞는다.
            let sessionId = state.sessionId
            let hasRecording = state.hasRecording
            return .run { send in
                var cumulative: Double?
                if hasRecording {
                    do {
                        cumulative = try await recordingClient.startRecording(sessionId)
                    } catch {
                        Self.recordingLogger.error("네트워크 재개 녹화 시작 실패: \(String(describing: error))")
                    }
                }
                await send(.inner(.captureResumed(cumulativeSeconds: cumulative)))
            }
        case .presented(.delegate(.closeRequested)):
            // 오버레이는 **내리지 않는다** — 중단은 최대 3초 걸리고, 그동안 «진행 중» 이라는 시각 상태가
            // 필요하다. 여기서 nil 로 두면 [중단하기]를 누른 사용자가 3초간 산 것처럼 보이는 세션 화면을
            // 마주한다(입력은 아래 `isAbandoning` 으로 죽어 있어 더 어긋난다). 실제로 걷히는 건
            // `aborted` 를 받은 코디네이터의 teardown 이다 — cover 째 사라지고, 마감해 둔 세그먼트도 거기서 폐기된다.
            state.pendingRetry = nil
            // 레이스가 끝날 때까지 입력·잔광을 전면 잠근다(`isAbandoning` 주석 참조) —
            // 오버레이 두 버튼도 이 리듀서 맨 앞 가드가 함께 막는다.
            state.isAbandoning = true
            let sessionId = state.sessionId
            return .merge(
                sessionCleanup(),
                .run { send in
                    // 네트워크 중단 = 이용권 환급(스웨거 abandon 계약) — 화면 문구 «차감되지 않아요» 의
                    // 근거가 서버에 반영된다(스펙 ②). 오프라인일 공산이 커 3초 레이스로 묶고
                    // 결과와 무관하게 이탈한다 — 남는 서버 세션은 hold 만료 위임(스펙 ⑥, 백엔드 확인 ①).
                    await withTaskGroup(of: Void.self) { group in
                        group.addTask { _ = try? await interviewClient.abandonSession(sessionId, .networkDisconnect) }
                        group.addTask { try? await clock.sleep(for: .seconds(3)) }
                        _ = await group.next()
                        group.cancelAll()
                    }
                    // 보관값도 결과와 무관하게 지운다 — 재개 재료가 없는 세션이라(중단 성공이면 ENDED,
                    // 실패여도 hold 만료가 뒤따른다) 남겨 두면 홈이 살아 있지 않은 세션을 계속 제안한다.
                    heldSessionStore.clear()
                    await send(.delegate(.aborted))
                }
            )
        case .presented, .dismiss:
            return .none
        }
    }

    /// 세션 시계 — 녹화 시작·네트워크 재개·랩업 계측이 함께 쓴다. 시작마다 이전 타이머를 대체한다.
    func sessionClock() -> Effect<Action> {
        .run { send in
            for await _ in clock.timer(interval: Self.clockTick) {
                await send(.inner(.clockTicked))
            }
        }
        .cancellable(id: CancelID.clock, cancelInFlight: true)
    }
}
