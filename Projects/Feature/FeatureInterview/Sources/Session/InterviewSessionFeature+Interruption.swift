//
//  InterviewSessionFeature+Interruption.swift
//  FeatureInterview
//
//  Created by 서정원 on 26/08/08.
//

import ComposableArchitecture
import DomainInterviewInterface
import DomainRecordingInterface
import Foundation

// @lat: [[interview#세션]]
// depends-on: [[interview#코디네이터]] — 동결 뒤 다음 상태는 코디네이터가 받는 `delegate(.interrupted)` 하나뿐이다.
// 세션 동결 — 진행 중인 면접을 **끝내지 않고** 세그먼트만 닫아 홈으로 내보낸다. 들어오는 문은 둘이다:
// 백그라운드 진입(스펙 ② — 카메라 캡처가 즉시 끊겨 «유예» 가 없다. 모든 백그라운드 = 세그먼트 경계)과
// 8분 전 중도 이탈(2026-08-09 개정 — 아래 `reduceUserLeave`). 랩업·합성 중은 예외(이미 종료 확정).
extension InterviewSessionFeature {
    func reduceSceneBackgrounded(_ state: inout State) -> Effect<Action> {
        if state.isFinishing { return .none }
        if state.isWrappingUp {
            // 멘트 청취 포기 + 즉시 마감 — 백그라운드에선 재생이 죽어 완료 이벤트가 영영 안 와
            // 세션이 랩업에 갇힌다. 서버 세션은 이미 끝났으므로(제출 응답이 종료 확정) 재개 대상이 아니다.
            state.isWrappingUp = false
            state.wrapUpSpan = state.wrapUpStartedAt.map {
                InterviewVideoWrapUpSpan(wrapUpStartSec: Double($0), wrapUpEndSec: Double(state.elapsedSeconds))
            }
            return .merge(.cancel(id: CancelID.playback), stopRecordingAndFinish(&state))
        }
        // 시작 전(onAppear 직후 창)은 닫을 세그먼트도 갱신할 누적초도 없다 — 화면은 그대로 두고
        // 복귀를 기다린다. 사용자 이탈과 갈리는 유일한 지점이다(그쪽은 «나가기» 를 반드시 이행해야 한다).
        guard state.hasStarted else { return .none }
        return freezeAndLeave(&state)
    }

    /// 8분 전 중도 이탈 «그대로 나가기» — **서버 세션을 끝내지 않는다**(2026-08-09 개정).
    /// 옛 동작은 BACK_EXIT 를 최선 노력 제출해 그 자리에서 세션을 닫고 진행분 리포트를 만들었는데,
    /// 그러면 `checkResume` 이 ENDED 를 돌려줘 재개가 원천 봉쇄된다. 이제 백그라운드 동결과 **같은**
    /// 경로를 타 세그먼트·held 를 남기고 홈으로 나가고, 홈 «진행 중» 카드의 [이어서 진행] 이 잇는다.
    /// 확정 종료(진행분 리포트·차감)는 홈 [처음부터 시작] 의 `abandon(USER_EXIT)` 몫이다 → [[app#Cross-feature Routing]].
    func reduceUserLeave(_ state: inout State) -> Effect<Action> {
        freezeAndLeave(&state)
    }

    /// 동결 본체 — 진행 중 effect 를 끊고 세그먼트를 닫은 뒤 이탈을 통보한다.
    private func freezeAndLeave(_ state: inout State) -> Effect<Action> {
        state.isInterrupted = true
        state.isEarlyExitWarningPresented = false
        state.isExitConfirmPresented = false
        state.isSubmitting = false   // 비행 중 제출은 취소한다 — 서버 처리 여부는 재개 재동기화가 흡수(스펙 ⑥)
        state.failure = nil          // 오버레이보다 동결이 세다 — 이탈 뒤 재개(confirmResume)가 재동기화한다
        state.pendingRetry = nil
        state.toast = nil
        let sessionId = state.sessionId
        let hasRecording = state.hasRecording
        let elapsedSeconds = state.elapsedSeconds
        return .merge(
            .cancel(id: CancelID.clock),      // raw 축도 함께 정지 — 녹화가 없는 시간은 영상 타임라인이 아니다
            .cancel(id: CancelID.toast),
            .cancel(id: CancelID.submission),
            .cancel(id: CancelID.playback),
            // 마이크 취소는 여기 걸지 않는다 — 취소는 캡처 스트림 종료 → live `stopCapture()` → **진행 중
            // 세션 기록 폐기(파일 삭제)** 로 이어져, 아래 마감과 merge 로 나란히 두면 어느 쪽이 먼저인지
            // 미보장이다(`stopRecordingAndFinish` 가 `includingMicCapture: false` 인 것과 같은 이유).
            // 마감이 진 백그라운드는 무음 세그먼트가 되고, 전 세그먼트가 무음이면 합성이 통째로 throw 한다.
            // 대신 아래 run 이 순서대로 stopCapture 를 부르고, 그 continuation.finish 가 캡처 effect 를 끝낸다.
            .run { send in
                // 순서 계약(스펙 ②): 마감 → suspend(쌍 등록) → stopCapture. 마감이 stopCapture 보다
                // 먼저여야 진행 중 세션 오디오가 폐기되지 않는다(정상 종료의 기존 순서 계승).
                let audio = await speechClient.finishSessionAudioRecording()
                let cumulative = await recordingClient.suspendRecording(
                    audio.map { RecordingAudioSegment(fileURL: $0.fileURL, startedAtHostSeconds: $0.startedAtHostSeconds) }
                )
                await speechClient.stopCapture()
                // held 갱신 — #69 «녹화하며 갱신» 미배선이 여기서 해소된다. 진행 길이는 녹화가 있으면 세그먼트
                // 누적초, 없으면(영상 없이 진행 중이던 세션 — 앱이 죽었다 살아난 재개 포함) 세션 시계 raw 축이다.
                // 영상 없는 세션의 길이를 안 남기면 다음 재개의 시계 시드가 옛 값이라 8분·12분 상한이 리셋된다.
                // 녹화가 있는데 마감이 실패해 누적초가 없으면(nil) 갱신하지 않는다 — 옛 값이 원장과 맞는 쪽이다.
                let recordedSeconds = hasRecording ? cumulative.map { Int($0.rounded()) } : elapsedSeconds
                if let recordedSeconds {
                    heldSessionStore.save(HeldSession(sessionId: sessionId, recordedSeconds: recordedSeconds))
                }
                // 이탈 통보는 **맨 끝**이다(2026-08-09) — 이걸 받은 코디네이터·AppFeature 가 cover 를 닫고,
                // 그 dismiss 가 이 effect 를 취소한다. 위로 올리면 세그먼트 마감·held 갱신이 중간에 잘린다.
                await send(.delegate(.interrupted))
            }
        )
    }
}
