//
//  InterviewFeature.swift
//  FeatureInterview
//
//  Created by 서정원 on 26/07/25.
//

import ComposableArchitecture
import DomainInterviewInterface
import DomainInterviewReportInterface
import DomainRecordingInterface
import DomainSpeechInterface

/// 재개 진입 시드(스펙 ③④) — confirmResume 의 최신 턴 질문 + 표시용 근사 누적초(held 값).
/// raw 축 확정은 세션 진입의 `startRecording` 반환(에셋 실측)이 한다.
public struct InterviewResumeSeed: Equatable, Sendable {
    public let question: NextQuestion
    public let approximateElapsedSeconds: Int

    public init(question: NextQuestion, approximateElapsedSeconds: Int) {
        self.question = question
        self.approximateElapsedSeconds = approximateElapsedSeconds
    }
}

// @lat: [[interview#코디네이터]]
/// Part 2 면접 흐름 코디네이터 — 도메인 내부 화면 전환(준비 → 세션 → 실패)만 담당한다.
/// 화면들은 delegate 로만 신호를 올리고, 이 리듀서가 screen 을 갈아끼운다.
/// 종료엔 화면이 없다 — 산출물을 업로드 큐에 접수(소유권 이전)하고 장치를 정지한 뒤 즉시 홈으로 통보한다(스펙 ①).
/// 흐름 밖(보고서 진입·닫기)은 다시 delegate 로 AppFeature 에 올린다 (D1 — cross-feature 조립은 AppFeature).
/// 세션 payload(sessionId — 온보딩 분석 산출물)는 `State(sessionId:)` 로 받는다 — AppFeature 배선은 작업 D.
@Reducer
public struct InterviewFeature {
    /// 리포트 생성 폴링 주기 — [[api#Interview Report]] 의 3~5초 규약. 리포트 화면(`ReportMainFeature`)과 같은 계약이다.
    static let reportPollInterval: Duration = .seconds(3)
    /// 대기 상한(≈1분). 채점 SLA 는 이보다 길 수 있어 무한정 붙잡지 않는다 — 넘으면 그대로 홈으로 보내고
    /// 홈 목록의 «생성 중» 카드가 이어받는다(리포트 화면이 다시 폴링한다).
    static let reportPollLimit = 20

    /// 면접 흐름 하위 화면 — push 스택이 아니라 전면 교체라 StackState 대신 enum destination.
    @Reducer
    public enum Screen {
        case readiness(InterviewReadinessFeature)
        case session(InterviewSessionFeature)
        case failure(InterviewFailureFeature)
    }

    @ObservableState
    public struct State: Equatable {
        public var screen: Screen.State
        /// 온보딩 분석이 만든 세션 id — 흐름 내내 같은 세션을 쓴다.
        public let sessionId: Int
        /// 종료 신호 first-wins — 정상 종료엔 갈아탈 화면이 없어 finished 후에도 screen 이 .session 에 머문다.
        /// 늦은 두 번째 finished/aborted 를 case 가드만으로 거를 수 없어, 이 플래그가 이중 통보·재접수를 막는다.
        public var isClosing = false

        public init(sessionId: Int) {
            self.sessionId = sessionId
            self.screen = .readiness(InterviewReadinessFeature.State(sessionId: sessionId))
        }

        /// 재개 진입(스펙 «결정 요약») — readiness 를 생략하고 세션으로 직행한다. 질문 준비 폴링이
        /// 필요 없고(confirmResume 이 이미 질문을 줬다), 카메라는 세션 onAppear 의 startPreview 가 연다.
        public init(sessionId: Int, resume: InterviewResumeSeed) {
            self.sessionId = sessionId
            self.screen = .session(InterviewSessionFeature.State(sessionId: sessionId, resume: resume))
        }
    }

    public enum Action: ViewAction {
        /// 준비 화면 복귀의 재개 판정 결과 — ENDED 만 처리한다(스펙 ③ 표).
        case resumeChecked(InterviewResumeCheck)
        case screen(Screen.Action)
        case view(View)
        case delegate(Delegate)

        /// 사용자 입력·생명주기 — InterviewView(코디네이터 뷰)의 send 전용(D5).
        public enum View: Equatable, Sendable {
            /// 포그라운드 복귀 — **준비 화면**의 세션이 아직 살아 있는지 묻는다(게이트는 리듀서가 건다).
            /// 세션 화면은 백그라운드 진입 때 이미 나갔으므로 여기 걸리지 않는다.
            case sceneBecameActive
        }

        /// 부모(AppFeature) 통보. 부모는 이것만 매칭한다 (D1).
        @CasePathable
        public enum Delegate: Equatable, Sendable {
            /// 면접 정상 종료(산출물 업로드 큐 접수 완료 → 홈으로) — 보고서 전환·dismiss 는 AppFeature 몫.
            case finished
            /// 면접 흐름 이탈(중단 폐기·실패 화면 X) — dismiss 는 AppFeature 몫.
            case closed
            /// 백그라운드 동결 — cover 닫기·held 보존·홈 재조회는 AppFeature 몫(스펙 ③④).
            /// 복귀 판정을 기다리지 않는다: 기다리면 복귀 후 면접 화면이 잠깐 보인다(2026-08-09 개정).
            case interrupted
        }
    }

    @Dependency(\.continuousClock) var clock
    @Dependency(\.heldSessionStore) var heldSessionStore
    @Dependency(\.interviewClient) var interviewClient
    @Dependency(\.interviewReportClient) var interviewReportClient
    @Dependency(\.interviewVideoUploadQueue) var uploadQueue
    @Dependency(\.recordingClient) var recordingClient
    @Dependency(\.speechClient) var speechClient

    public init() {}

    public var body: some ReducerOf<Self> {
        Scope(state: \.screen, action: \.screen) {
            Screen.body
        }
        Reduce { state, action in
            switch action {
            case .screen(.readiness(.delegate(.startRequested))):
                // 준비 화면의 READY 페이로드(요약 질문)와 프리뷰 핸들을 세션 상태로 시드 —
                // 요약 질문은 첫 턴 재생(작업 C), 핸들은 비동기 재요청을 기다리는 동안
                // placeholder 로 떨어지는 깜빡임 방지. 재요청(onAppear)은 백스톱으로 유지된다.
                guard case let .readiness(readiness) = state.screen,
                      case let .ready(summaryQuestion) = readiness.questionPrep
                else { return .none }
                // 장부는 이미 온보딩 완주 때 열렸다(2026-08-21) — 여기서 하는 일은 **«시작했다» 로
                // 올리는 것**뿐이다. 이 플래그가 서면 비로소 홈이 «진행 중» 카드를 그린다.
                // 표식은 세션 화면이 녹화를 열 때 찍고, 누적초는 백그라운드 마감마다 갱신한다
                // ([[interview#세션]] 동결 경로).
                //
                // 장부가 없으면(비정상 — 재개 진입은 준비 화면을 건너뛴다) 새로 연다: 시작한 세션이
                // 장부에 없는 채로 두면 회수도 재개도 못 하는 고아가 된다.
                var held = heldSessionStore.load() ?? HeldSession(sessionId: state.sessionId, recordedSeconds: 0)
                held.hasStarted = true
                heldSessionStore.save(held)
                state.screen = .session(InterviewSessionFeature.State(
                    sessionId: state.sessionId,
                    summaryQuestion: summaryQuestion,
                    previewHandle: readiness.previewHandle
                ))
                return .none

            case .screen(.readiness(.delegate(.backRequested))):
                // 준비 화면 뒤로가기 = 흐름 이탈. 아직 면접 전이라 서버 제출 없이 장치만 정리하고 나간다
                // (세션은 서버에 남지만 답변 0개 — 재진입 동선은 홈의 «이어서 진행» 몫, home-account §4).
                return stopCaptureDevicesThenNotifyClosed()

            case .screen(.readiness(.delegate(.prepFailed))):
                state.screen = .failure(InterviewFailureFeature.State(kind: .questionPrep))
                return stopCaptureDevicesAndPlayback()

            case let .screen(.session(.delegate(.finished(ref, wrapUp)))):
                // 세션 effect 는 이 전환으로 취소되지 않는다(Scope-on-enum) — 「정지+합성」 구간에서 뒤늦은
                // 두 번째 통보가 도달할 수 있어, 이미 종료를 확정했으면 무시한다(업로드 재접수·이중 통보 방지).
                guard case .session = state.screen, !state.isClosing else { return .none }
                state.isClosing = true
                // 산출물 소유권은 큐로 — enqueue(파일 이동+저널, 밀리초) 뒤 장치를 정지한다(스펙 ①).
                // 전환 중 유일하게 `discardRecording()` 을 부르지 않는 경로다 — 파일은 이제 큐 것이다.
                // 그다음 **리포트 채점이 끝날 때까지 기다렸다가** 홈으로 통보한다(2026-08-14) — 그동안
                // 화면은 세션의 `LoadingModal`(isFinishing)이 그대로 덮고 있어 인디케이터가 이어진다.
                let sessionId = state.sessionId
                return .run { send in
                    if let ref {
                        await uploadQueue.enqueue(ref.sessionId, ref.fileURL, wrapUp)
                    }
                    await recordingClient.stopPreview()
                    await speechClient.stopCapture()
                    await waitForReportGeneration(sessionId: sessionId)
                    await send(.delegate(.finished))
                }

            case .screen(.session(.delegate(.aborted))):
                // finished 와 같은 창(위 주석) — 뒤늦게 도달하면 폐기가 **큐에 넘긴 파일**을 지운다.
                guard case .session = state.screen, !state.isClosing else { return .none }
                state.isClosing = true
                return stopCaptureDevicesThenNotifyClosed()

            case let .screen(.session(.delegate(.failed(kind)))):
                // 화면 교체 전이라 case 가드만으론 «종료 확정 뒤 도착한 실패» 를 못 막는다 — isClosing 이 막는다
                // (뚫리면 실패 헬퍼의 discardRecording 이 큐에 넘긴 파일을 지운다).
                guard case .session = state.screen, !state.isClosing else { return .none }
                state.screen = .failure(InterviewFailureFeature.State(kind: kind))
                return stopCaptureDevicesAndPlayback()

            // 아래 catch-all(`case .screen, .delegate`)보다 반드시 앞 — 빠뜨려도 컴파일러가 조용히
            // 흡수해 백그라운드를 다녀와도 면접 화면이 그대로 남는 화면이 된다(경고 없음).
            case .screen(.session(.delegate(.interrupted))):
                // 동결 완료 = **즉시** 홈 경유(2026-08-09 개정). 복귀 판정(checkResume)을 기다렸다가 닫으면
                // 그 왕복 동안 동결된 면접 화면이 보인다 — 복귀 시점 보관값 검증은 홈 위에서 [[app#Cross-feature Routing]] 이 한다.
                // 여기서 닫으면 사용자가 아직 백그라운드라 전환 자체가 보이지 않는다.
                guard case .session = state.screen, !state.isClosing else { return .none }
                state.isClosing = true
                return leaveForResumeAtHome()

            case .view(.sceneBecameActive):
                // 호출 게이트(스펙 ③): **준비 화면뿐**이다(2026-08-09 개정 — 세션은 백그라운드 진입 때
                // 이미 나갔다). 세션(랩업·합성·inactive 바운스로 살아 있는 것)은 체크하지 않는다 —
                // 산 세션의 운명은 세션 자신이 정한다(ENDED 판정을 들이대면 랩업→enqueue 중이던 영상을 찢는다).
                guard !state.isClosing, case .readiness = state.screen else { return .none }
                return checkResumeEffect(sessionId: state.sessionId)

            case let .resumeChecked(check):
                // 준비 화면 전용 — RESUMABLE 이면 잃을 게 없어 그 자리를 지킨다(스펙 ③ 표).
                guard !state.isClosing, case .readiness = state.screen, !check.isResumable else { return .none }
                heldSessionStore.clear()   // 끝난 세션 — 홈 «진행 중» 판정을 끈다(스펙 ③)
                if check.status == .invalid {
                    state.screen = .failure(InterviewFailureFeature.State(kind: .speechRecognition))
                    return stopCaptureDevicesAndPlayback()
                }
                state.isClosing = true
                return stopCaptureDevicesThenNotifyClosed()

            case .screen(.failure(.delegate(.closeRequested))):
                return stopCaptureDevicesThenNotifyClosed()

            case .screen, .delegate:
                return .none
            }
        }
    }

    /// 리포트 채점 대기 — `status != .generating` 이 될 때까지(또는 상한까지) 폴링한다.
    /// 조회 실패는 «아직» 으로 본다(미생성 404 포함) — 상한 안에서 다시 묻는다. 상한을 넘으면 그냥 반환해
    /// 홈으로 보낸다: 홈 목록이 «생성 중» 상태를 그리고 리포트 화면이 폴링을 잇는다.
    /// 취소(상위 dismiss)면 즉시 빠져나온다 — 화면이 이미 없다.
    private func waitForReportGeneration(sessionId: Int) async {
        for _ in 0..<Self.reportPollLimit {
            do {
                if try await interviewReportClient.report(sessionId).status != .generating { return }
            } catch is CancellationError {
                return
            } catch {
                // 아직 — 아래 대기 후 다시 묻는다.
            }
            do {
                try await clock.sleep(for: Self.reportPollInterval)
            } catch {
                return   // 취소
            }
        }
    }

    /// 준비 화면 복귀의 재개 판정(스펙 ③) — 순수 조회 GET. 실패(오프라인 복귀)는 삼킨다:
    /// 준비 화면은 잃을 게 없어 그 자리를 지키고, 다음 복귀가 다시 묻는다.
    private func checkResumeEffect(sessionId: Int) -> Effect<Action> {
        .run { send in
            guard let check = try? await interviewClient.checkResume(sessionId) else { return }
            await send(.resumeChecked(check))
        }
    }

    /// 동결 세션의 홈 경유 이탈 — 세그먼트는 **남긴다**(재개 재료). `discardRecording()` 을 부르지 않는
    /// 유일한 이탈 경로다. 대신 장치는 놓는다: 안 놓으면 홈에서도 카메라가 살아 «계속 보고 있다» 가 된다.
    /// 통보가 맨 끝인 건 상위 dismiss 가 이 effect 를 취소하기 때문(`stopCaptureDevicesThenNotifyClosed` 와 같은 이유).
    private func leaveForResumeAtHome() -> Effect<Action> {
        .run { send in
            // 시작 ~1초 내 백그라운드는 recordingStarted 가 동결 잠금에 먹혀 액터에 고아 녹화가
            // 남을 수 있다 — 평시엔 동결이 이미 마감해 no-op(nil), 고아면 여기서 마감돼 세그먼트가
            // 산다. stopPreview 보다 먼저인 이유: 파일 마감(moov)은 캡처세션이 도는 동안 써져야 한다.
            _ = await recordingClient.suspendRecording(nil)
            await recordingClient.stopPreview()
            await speechClient.stopCapture()
            await send(.delegate(.interrupted))
        }
    }

    /// 실패 전환 공통 — 캡처에 더해 진행 중 질문 재생도 끊는다(실패 화면 뒤에서 소리가 이어지지 않게).
    /// 진행 중 녹화가 있으면 정지·폐기한다(스펙 §① 실패 = 즉시 정지 + 파일 폐기) — 멱등이라 준비 화면 경로에선 no-op.
    private func stopCaptureDevicesAndPlayback() -> Effect<Action> {
        .run { _ in
            await recordingClient.discardRecording()
            await recordingClient.stopPreview()
            await speechClient.stopCapture()
            await speechClient.stopPlayback()
        }
    }

    /// 흐름 이탈 공통 — 정지(재생 포함) 완료 후 상위 통보. merge 로 두면 상위 dismiss 가 정지 effect 를
    /// 취소할 수 있어(작업 D: ifLet 해제 시 자식 effect 취소) 순서를 보장한다.
    /// 진행 중 녹화가 있으면 정지·폐기한다(스펙 §① BACK_EXIT = 즉시 정지 + 파일 폐기) — 준비 화면 경로에선 no-op.
    private func stopCaptureDevicesThenNotifyClosed() -> Effect<Action> {
        .run { send in
            await recordingClient.discardRecording()
            await recordingClient.stopPreview()
            await speechClient.stopCapture()
            await speechClient.stopPlayback()
            await send(.delegate(.closed))
        }
    }
}

extension InterviewFeature.Screen.State: Equatable {}
