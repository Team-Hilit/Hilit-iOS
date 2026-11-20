//
//  InterviewSessionFeature.swift
//  FeatureInterview
//
//  Created by 서정원 on 26/07/25.
//

import ComposableArchitecture
import DomainInterviewInterface
import DomainRecordingInterface
import DomainSpeechInterface
import Foundation
import OSLog

// @lat: [[interview#세션]]
/// 면접 진행 화면 — 턴 상태머신 + 세션 시계. 네트워크 실패는 화면을 갈아치우지 않고 세션이 소유한
/// `@Presents` 오버레이로 덮는다(상태·녹화 유지, 유효시간은 정지 — 스펙 ③).
@Reducer
public struct InterviewSessionFeature {
    static let clockTick: Duration = .seconds(1)
    /// 실기기 종료 경로를 반복 검증할 때 8분을 기다리지 않게 하는 단축 스위치 — 스킴 환경변수
    /// `HILIT_FAST_EXIT` 가 있을 때만 켜진다(STT 탐침·AV 스파이크와 같은 패턴). 제품 경로엔 없는 것과 같다.
    /// 테스트에선 항상 꺼둔다 — Xcode 의 Test 액션이 Run 액션 환경변수를 상속하는 설정이면 8분 상수를
    /// 검증하는 테스트들이 단축값을 보고 깨진다(실측 2026-08-07). `XCTestBundlePath` 는 테스트 런에만 있다.
    static let isFastExitEnabled = ProcessInfo.processInfo.environment["HILIT_FAST_EXIT"] != nil
        && ProcessInfo.processInfo.environment["XCTestBundlePath"] == nil
    static let exitUnlockSeconds = isFastExitEnabled ? 20 : 8 * 60
    static let hardCapSeconds = 12 * 60
    static let finalCountdownSeconds = 10
    /// 8분 해금 안내 토스트 유지 시간.
    static let exitNoticeHold: Duration = .seconds(3)
    /// 랩업 임계(8:45) — 이후 제출은 isWrapUp=true 로 서버에 마무리 국면을 알린다.
    /// 단축 모드에선 해금(20초)보다 앞에 둬야 «종료 → 마무리 멘트 → 합성» 전체 경로가 그대로 재현된다.
    static let wrapUpThresholdSeconds = isFastExitEnabled ? 15 : 8 * 60 + 45
    /// 503(aiTemporarilyUnavailable) 백오프 — 같은 제출을 지연 후 재시도(서버에 아무것도 저장 안 됨 계약).
    static let submissionRetryDelays: [Duration] = [.seconds(1), .seconds(3)]

    /// 진행 중 질문 — 요약 질문(턴 0)과 submitAnswer 응답(NextQuestion)을 한 형으로 접는다.
    public struct ActiveQuestion: Equatable, Sendable {
        public var questionId: Int
        public var turnLevel: Int
        public var isLast: Bool

        init(questionId: Int, turnLevel: Int, isLast: Bool) {
            self.questionId = questionId
            self.turnLevel = turnLevel
            self.isLast = isLast
        }

        init(_ question: SummaryQuestion) {
            self.init(questionId: question.questionId, turnLevel: question.turn?.turnLevel ?? 0, isLast: false)
        }

        init(_ question: NextQuestion) {
            self.init(questionId: question.questionId, turnLevel: question.turn?.turnLevel ?? 1, isLast: question.isLast ?? false)
        }
    }

    @ObservableState
    public struct State: Equatable {
        /// 턴 표시 상태 — View 는 이 값(+토스트)만 그린다. 질문 텍스트는 노출하지 않는다(TTS-only).
        public enum Phase: Equatable, Sendable {
            case asking
            case answering
            /// 답변 확정 직후 — «답변을 정리하고 있어요» (PRD §3.5 칩 3종). 되돌리지 않는다.
            /// 제출형 종료(마치기·상한)도 응답까지 이 phase 로 대기를 표현한다.
            case processingAnswer
            /// 세션 상한 임박 — 빨간 «N초» 칩 초읽기, 상태 칩 없음
            case finalCountdown
        }

        /// 오버레이가 보관하는 실패 단계 — 질문 재생 또는 제출(오디오 포함 payload 그대로).
        /// 제출을 payload 로 저장하는 이유: `answerAudio()` 가 1회 소모성(반환 후 파일 삭제)이라 재조회가 불가능하다.
        public enum PendingRetry: Equatable, Sendable {
            case playQuestion
            case submit(AnswerSubmission)
        }

        public enum Toast: Equatable, Sendable {
            case exitUnlocked
            case timeExpired

            public var message: String {
                switch self {
                case .exitUnlocked: "8분이 경과되어 면접을 종료할 수 있어요"
                case .timeExpired: "시간이 경과되어 면접을 종료합니다"
                }
            }

            public var hasTail: Bool { self == .exitUnlocked }
        }

        /// 답변 제출·질문 스트림의 경로 파라미터 — 준비 화면과 같은 세션이다.
        public let sessionId: Int
        /// READY 폴링이 동봉한 요약 질문 — 첫 asking 재생(base64 mp3)에 쓴다.
        /// 재개 진입은 readiness 를 건너뛰어 요약 질문 자체가 없다(nil) — 첫 재생부터 스트림이다.
        public let summaryQuestion: SummaryQuestion?

        public var phase: Phase = .asking
        /// 세션 경과 시간(초) — **영상 타임라인 축**(0점 = 녹화 시작). 시간 마킹은 전부 이 값이다.
        /// 면접 판정·표시는 정지 구간을 뺀 `effectiveElapsedSeconds` 를 쓴다.
        public var elapsedSeconds = 0
        /// 8:00 경과 — «면접 종료하기» 노출.
        public var isExitAvailable = false
        public var toast: Toast?
        /// 종료 확인 모달 (Figma ExitConfirm) — 화면 위 오버레이라 별도 destination 없이 Bool.
        public var isExitConfirmPresented = false
        /// 8분 전 중도 이탈 경고 모달 (Interview_EarlyExitWarning) — 차감 사실만 알린다 (PRD §3.7).
        public var isEarlyExitWarningPresented = false
        /// onAppear 재진입 가드 — 세션 시계 effect 중복 실행 방지.
        public var hasStarted = false
        /// 프리뷰 핸들 — 코디네이터가 준비 화면의 핸들을 시드해 첫 프레임부터 프리뷰가 붙는다
        /// (nil 시드면 onAppear 멱등 재요청이 채울 때까지 placeholder). 재요청은 백스톱으로 유지.
        public var previewHandle: CameraPreviewHandle?

        /// 진행 중 질문 — 요약 질문으로 시작해 submitAnswer 응답으로 갈아탄다.
        public var currentQuestion: ActiveQuestion
        /// 시간 마킹(초 — 세션 시계 스냅샷, 실녹화 전 근사값). 제출 시 Double 로 변환된다.
        public var questionAudioStartedAt: Int?
        public var questionAudioEndedAt: Int?
        public var answerStartedAt: Int?
        /// 이번 답변 턴에서 사용자 발화가 감지됐다(진폭 8% 이상 연속 2버퍼 — [[interview#음성 캡처]]) —
        /// «답변 완료하기» 노출 조건. 답변 진입(`questionPlaybackFinished`)마다 리셋하고, 침묵이 와도 되돌리지 않는다
        /// (말을 마친 사용자는 침묵 상태에서 버튼을 눌러야 한다).
        public var hasDetectedSpeech = false
        /// 마이크 캡처 시작 실패(권한 거부·세션 구성 실패 등) — 발화를 감지할 수 없으니 «답변 완료하기» 를
        /// 상시 노출로 돌린다(버튼이 영영 안 나와 갇히는 것을 막는 폴백). 세션 수명 동안 유지한다.
        public var isMicCaptureFailed = false
        /// 중복 제출 가드 (ANSWER_ALREADY_SUBMITTED 예방).
        public var isSubmitting = false
        /// 질문 재생 실패 1회 재시도 가드 — 질문이 바뀌면 리셋.
        public var hasRetriedPlayback = false
        /// 제출 비행 중 12:00 도달 — 새 질문을 여는 대신 응답 수신 후 HARD_CAP 마감으로 잇는다.
        public var hardCapReachedWhileSubmitting = false
        /// 실녹화 시작 성공 — 종료 시 stopRecording·업로드 배선 여부 (실패 = 영상 없는 리포트).
        public var hasRecording = false
        /// 마무리 멘트 재생 중 — 시계는 계측용으로만 돌고 해금·상한 로직은 잠근다.
        public var isWrappingUp = false
        /// 마무리 멘트 재생 시작 시점(녹화 타임라인 초).
        public var wrapUpStartedAt: Int?
        /// 계측 완료된 마무리 구간 — recordingStopped 가 delegate 로 실어 보낸다.
        public var wrapUpSpan: InterviewVideoWrapUpSpan?
        /// 종료 처리 중(정지+합성 또는 녹화 없는 즉시 종료) — 재진입(두 번째 stopRecording)과 종료·이탈
        /// 입력을 함께 막고, 화면은 `LoadingModal` 로 덮인다. 코디네이터의 리포트 생성 대기까지
        /// 이 한 벌의 인디케이터가 이어 돈다([[interview#코디네이터]]) — 그동안 화면은 여기 머문다.
        public var isFinishing = false
        /// 네트워크 실패 오버레이 — 세션 상태·녹화를 살린 채 위에 얹는다(스펙 ③). nil 복귀 = 재개.
        @Presents public var failure: InterviewFailureFeature.State?
        /// 오버레이가 보관한 «실패한 단계» — 이어서 진행하기가 이것을 재실행한다.
        public var pendingRetry: PendingRetry?
        /// 오버레이 동안 흐른 tick — 시계는 영상 축(elapsed)으로 계속 돌고, 면접 판정·표시는
        /// 유효시간(elapsed − suspended)으로 계산해 «일시정지»를 만든다(isWrappingUp 계측 tick 과 같은 장치).
        public var suspendedSeconds = 0
        /// 백그라운드 동결(스펙 ②) — 세그먼트를 마감하고 시계·입력을 전면 잠근 상태. 복귀 라우팅
        /// (checkResume)은 코디네이터 몫이고, 이 화면은 dismiss 또는 실패 화면 교체를 기다린다.
        public var isInterrupted = false
        /// 오버레이 «중단하기» 의 abandon 레이스(최대 3초) 진행 중 — 그 창의 입력을 전면 잠근다.
        /// 열어 두면 X→«이탈하기» 가 BACK_EXIT 를, 8분 후 X→«마치기» 가 MANUAL_END 를 **다시** 제출해
        /// «제출 없이 중단»(이용권 미차감 문구) 계약이 깨지고, 버린 세션의 영상이 업로드 큐로 샌다.
        /// 백그라운드도 막는다 — 동결의 held save 가 이탈의 clear 뒤에 남으면 죽은 세션이 홈에 되살아난다.
        /// 동결(`isInterrupted`)과 겸용하지 않는 이유: 복귀 판정이 그걸 «재개 후보» 로 읽는다(스펙 ③).
        public var isAbandoning = false

        /// 면접 로직·표시용 유효시간 — 해금·상한·랩업·시간 칩이 이 값을 쓴다. 시간 마킹은 raw(영상 축).
        public var effectiveElapsedSeconds: Int { elapsedSeconds - suspendedSeconds }

        /// «답변 완료하기» 를 보여도 되는가 — 발화가 감지됐거나, 마이크가 죽어 감지 자체가 불가능할 때.
        /// phase(answering) 조건은 View 가 따로 건다.
        public var canCompleteAnswer: Bool { hasDetectedSpeech || isMicCaptureFailed }

        /// 최종 카운트다운 잔여 초 — 상한까지 남은 시간.
        public var countdownRemaining: Int {
            max(0, InterviewSessionFeature.hardCapSeconds - effectiveElapsedSeconds)
        }

        public init(
            sessionId: Int,
            summaryQuestion: SummaryQuestion,
            previewHandle: CameraPreviewHandle? = nil
        ) {
            self.sessionId = sessionId
            self.summaryQuestion = summaryQuestion
            self.previewHandle = previewHandle
            self.currentQuestion = ActiveQuestion(summaryQuestion)
        }

        /// 재개 진입(스펙 ③) — 요약 질문 없이 confirmResume 의 최신 턴 질문과 누적초 시드로 시작한다.
        /// 8:00 해금 판정은 등호 tick 이라 시드가 경계를 넘겼으면 여기서 토스트 없이 켠다.
        public init(
            sessionId: Int,
            resume: InterviewResumeSeed,
            previewHandle: CameraPreviewHandle? = nil
        ) {
            self.sessionId = sessionId
            self.summaryQuestion = nil
            self.previewHandle = previewHandle
            self.currentQuestion = ActiveQuestion(resume.question)
            self.elapsedSeconds = resume.approximateElapsedSeconds
            self.isExitAvailable = resume.approximateElapsedSeconds >= InterviewSessionFeature.exitUnlockSeconds
        }
    }

    public enum Action: ViewAction {
        case view(View)
        case inner(Inner)
        case delegate(Delegate)
        case failure(PresentationAction<InterviewFailureFeature.Action>)

        /// 사용자 입력·생명주기. View 의 send(...) 로만 방출된다.
        public enum View: Equatable, Sendable {
            case onAppear
            /// 백그라운드 진입 = 세그먼트 경계(스펙 ②) — 세션을 동결한다. 복귀 관측은 코디네이터 몫.
            case sceneBackgrounded
            case userTappedAnswerComplete
            /// 좌상단 X — 8분 전엔 중도 이탈 경고, 8분 후엔 종료 확인 모달. (이탈 동선 표기는 «협의 가능» — 임시 X)
            case userTappedClose
            /// 중도 이탈 경고 «그대로 나가기» — 서버 세션을 **끝내지 않고** 동결해 홈으로 나간다(2026-08-09 개정).
            /// 재개는 홈 «진행 중» 카드의 [이어서 진행] 몫 → `reduceUserLeave`.
            case userTappedLeaveInterview
            case userTappedExit
            case userTappedContinueInterview
            /// 종료 확인 모달 «마치기» — MANUAL_END 제출을 거쳐 종료, 지금까지 답변으로 분석.
            case userTappedFinishInterview
        }

        /// effect 결과·리듀서 내부 신호. 리듀서만 방출한다.
        @CasePathable
        public enum Inner: Equatable, Sendable {
            /// 프리뷰 핸들 확보 — 실패(권한 회수 등)면 nil, placeholder 로 진행.
            case previewStarted(CameraPreviewHandle?)
            /// 녹화 시작 종료(성공 여부) — 이 시점이 세션 시계 0점·첫 질문 재생(타임라인 정렬, 스펙 §①).
            /// `cumulativeSeconds` 는 이전까지 누적 녹화초(첫 세그먼트 0) — 재개의 raw 시드를 확정한다.
            case recordingStarted(success: Bool, cumulativeSeconds: Double)
            /// 마무리 멘트 재생 종료(실패 포함) — 구간을 확정하고 녹화를 정지한다.
            case wrapUpPlaybackFinished
            /// 녹화 정지 종료 — 실패면 nil(영상 없는 리포트).
            case recordingStopped(RecordingRef?)
            /// 세션 시계 1초 경과.
            case clockTicked
            /// 질문 TTS 재생 완료 — answering 전환.
            case questionPlaybackFinished
            /// 질문 TTS 재생 실패 — 같은 질문 1회 재시도(TTS 재생성) 후 네트워크 실패 처리.
            case questionPlaybackFailed
            /// 답변 구간 발화 감지(`SpeechCaptureEvent.speechStarted`) — «답변 완료하기» 노출 조건.
            case speechDetected
            /// 마이크 캡처 시작 실패(`SpeechCaptureEvent.captureFailed`) — 발화 감지가 불가능하니 버튼을 상시 노출로 돌린다.
            case micCaptureFailed
            /// 8분 해금 토스트 유지 시간 경과.
            case exitNoticeExpired
            /// 답변 제출 성공 — 다음 질문 재생 또는 세션 종료(endType) 분기.
            case answerSubmitted(AnswerResult)
            /// 답변 제출 실패(503 재시도 소진 포함) — 종료됐던 세션이면 정상 종료로, 그 외 네트워크 오버레이.
            /// 실패한 payload 를 동봉한다 — 오버레이의 «이어서 진행하기» 가 그대로 재전송한다.
            case answerSubmissionFailed(InterviewError, AnswerSubmission)
            /// 네트워크 단절 감지 — delegate 승격 대신 세션이 소유한 오버레이를 얹는다(세션·녹화 유지).
            /// STT 는 이 경로가 아니다 — `endSession` 이 delegate(.failed(.speechRecognition))로 직행한다.
            case networkFailureDetected(State.PendingRetry)
        }

        @CasePathable
        public enum Delegate: Equatable, Sendable {
            /// 정상 종료 — 녹화 산출물(nil = 영상 없는 리포트)과 마무리 멘트 구간(nil = 멘트 없음)을 함께 넘긴다.
            /// 업로드 배선은 코디네이터 몫.
            case finished(RecordingRef?, InterviewVideoWrapUpSpan?)
            /// 중도 이탈·세션 무결성 훼손 — 그때까지의 턴은 서버가 보존한다(차감 D1, PRD §3.7). 클라는 이탈 신호만.
            case aborted
            /// STT 실패(`.speechRecognition` 전용) — 코디네이터가 실패 화면으로 전환한다.
            /// 네트워크 실패는 여기로 오지 않는다 — 세션이 오버레이로 직접 소유한다(스펙 ③).
            case failed(InterviewFailureKind)
            /// 백그라운드 동결 완료(스펙 ②) — 세그먼트 마감·held 갱신까지 끝난 뒤에만 올린다.
            /// 코디네이터가 장치를 놓고 홈으로 내보낸다: 복귀 판정을 기다렸다가 닫으면 그 왕복 동안
            /// 동결된 면접 화면이 그대로 보인다(«복귀 즉시 홈» — 2026-08-09 개정).
            case interrupted
        }
    }

    /// internal — 동결 경로(`InterviewSessionFeature+Interruption.swift`)가 같은 취소 id 로 세션 effect 를 끊는다.
    enum CancelID { case clock, toast, submission, micCapture, playback }

    /// 마이크 검증 로그 — 실기기에서 레벨·발화 감지를 눈으로 확인하는 용도 (docs/superpowers/specs/2026-07-29-mic-capture-design.md).
    static let micLogger = Logger(subsystem: "FeatureInterview", category: "MicCapture")
    /// 질문 재생 실패 사유 로그 — 재시도 판단은 리듀서가 하고, 원문은 여기만 남긴다.
    static let playbackLogger = Logger(subsystem: "FeatureInterview", category: "Playback")
    /// 녹화 시작·정지 실패 사유 로그 — 실패해도 면접은 계속되므로(영상 없는 리포트) 원문은 여기만 남는다.
    static let recordingLogger = Logger(subsystem: "FeatureInterview", category: "Recording")

    @Dependency(\.continuousClock) var clock
    @Dependency(\.heldSessionStore) var heldSessionStore
    @Dependency(\.interviewClient) var interviewClient
    @Dependency(\.recordingClient) var recordingClient
    @Dependency(\.speechClient) var speechClient

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case let .view(action):
                return reduceView(&state, action)
            case let .inner(action):
                return reduceInner(&state, action)
            case let .failure(action):
                return reduceFailure(&state, action)
            case .delegate:
                return .none
            }
        }
        .ifLet(\.$failure, action: \.failure) {
            InterviewFailureFeature()
        }
    }

}

// MARK: - Reduce (본체 밖 extension — 타입 본문 길이 규칙, 접근은 파일 내 private)

extension InterviewSessionFeature {
    private func reduceView(_ state: inout State, _ action: Action.View) -> Effect<Action> {
        // 동결 중엔 화면이 관성으로 받는 어떤 입력도 무시한다 — 복귀 라우팅(코디네이터)만이 다음 상태다.
        // 중단 레이스(최대 3초) 중에도 같다 — 다음 상태는 그 effect 의 aborted 뿐이다.
        if state.isInterrupted || state.isAbandoning { return .none }

        // 마무리 멘트 계측·정지+합성 중(= 종료 확정 후)엔 종료·이탈 입력을 닫는다. 열어 두면 재제출이 409 를
        // 부르고, 그 sessionAlreadyEnded 경로와 뒤이은 wrapUpPlaybackFinished·recordingStopped 가 각각 종료를
        // 통보해 delegate 가 두 번 나간다 — 먼저 도착한 빈 결과가 코디네이터의 first-wins 로 진짜 ref 를 덮는다.
        if state.isWrappingUp || state.isFinishing {
            switch action {
            case .userTappedClose, .userTappedExit, .userTappedFinishInterview, .userTappedLeaveInterview:
                return .none
            case .onAppear, .sceneBackgrounded, .userTappedAnswerComplete, .userTappedContinueInterview:
                break
            }
        }

        switch action {
        case .onAppear:
            guard !state.hasStarted else { return .none }
            state.hasStarted = true
            let sessionId = state.sessionId
            // 프리뷰 확보 → 녹화 시작 순서를 한 effect 로 잇는다 — 재개 직행(readiness 생략)은 프리뷰가
            // 아직 없어서 병렬이면 startRecording 이 «프리뷰 세션 없음» 으로 죽는다. startPreview 는
            // 멱등이라 일반 진입(핸들 보유)에선 즉시 반환된다.
            // 타임라인 정렬(스펙 §①): 녹화 시작 완료 → 세션 시계 시드 → 첫 질문. 시계·재생은 recordingStarted 가 연다.
            return .run { send in
                await send(.inner(.previewStarted(recordingClient.startPreview())))
                do {
                    let cumulative = try await recordingClient.startRecording(sessionId)
                    await send(.inner(.recordingStarted(success: true, cumulativeSeconds: cumulative)))
                } catch {
                    Self.recordingLogger.error("녹화 시작 실패: \(String(describing: error))")
                    await send(.inner(.recordingStarted(success: false, cumulativeSeconds: 0)))
                }
            }

        case .sceneBackgrounded:
            return reduceSceneBackgrounded(&state)

        case .userTappedAnswerComplete:
            guard state.phase == .answering, !state.isSubmitting else { return .none }
            // 누르면 그 즉시 확정 (PRD §3.5) — 침묵 판정을 기다리지 않는다.
            state.phase = .processingAnswer
            return submitCurrentAnswer(&state, endType: nil)

        case .userTappedClose:
            if state.isExitAvailable {
                state.isExitConfirmPresented = true
            } else {
                state.isEarlyExitWarningPresented = true
            }
            return .none

        case .userTappedLeaveInterview:
            return reduceUserLeave(&state)

        case .userTappedExit:
            guard state.isExitAvailable else { return .none }
            state.isExitConfirmPresented = true
            return .none

        case .userTappedContinueInterview:
            state.isExitConfirmPresented = false
            state.isEarlyExitWarningPresented = false
            return .none

        case .userTappedFinishInterview:
            state.isExitConfirmPresented = false
            // 비행 중 제출이 있으면 그 응답이 곧 종료를 판정한다 — 중복 제출하지 않는다.
            guard !state.isSubmitting else { return .none }
            state.phase = .processingAnswer
            return submitCurrentAnswer(&state, endType: .manualEnd)
        }
    }

    private func reduceInner(_ state: inout State, _ action: Action.Inner) -> Effect<Action> {
        // 동결 후 도착한 잔광(비행 중 제출 응답·재생 완료 등)은 전부 무시한다 — 취소와 도착의 레이스를
        // 상태로 닫는다. 재개 재동기화(confirmResume)가 어떤 결과든 흡수한다(스펙 ⑥).
        // 중단 레이스도 같은 잔광을 받는다 — 이미 버린 세션이라 어떤 결과도 상태를 바꾸지 않는다.
        if state.isInterrupted || state.isAbandoning { return .none }

        switch action {
        case let .previewStarted(handle):
            state.previewHandle = handle
            return .none

        case let .recordingStarted(success, cumulative):
            return reduceRecordingStarted(&state, success: success, cumulativeSeconds: cumulative)

        case .wrapUpPlaybackFinished:
            guard state.isWrappingUp else { return .none }
            state.isWrappingUp = false
            state.wrapUpSpan = state.wrapUpStartedAt.map {
                InterviewVideoWrapUpSpan(wrapUpStartSec: Double($0), wrapUpEndSec: Double(state.elapsedSeconds))
            }
            return stopRecordingAndFinish(&state)

        case let .recordingStopped(ref):
            // 마감이 끝난 지금에야 마이크를 끊는다 — 먼저 끊으면 stopCapture 가 세션 기록을 폐기한다.
            return .merge(
                .cancel(id: CancelID.micCapture),
                .send(.delegate(.finished(ref, state.wrapUpSpan)))
            )

        case .clockTicked:
            return reduceClockTick(&state)

        case .questionPlaybackFinished:
            guard state.phase == .asking else { return .none }
            state.phase = .answering
            state.hasDetectedSpeech = false   // 질문마다 처음부터 — 버튼은 이번 턴 발화가 잡혀야 나온다
            state.questionAudioEndedAt = state.elapsedSeconds
            state.answerStartedAt = state.elapsedSeconds
            // AI 발화가 끝났으니 세션 오디오를 되살린 뒤(무음 해제) 답변 구간 m4a 기록을 연다
            // (제출 시 answerAudio() 로 회수 — 스펙 §②). 순서를 보장하려고 한 effect 에 둔다.
            return .run { _ in
                await speechClient.setSessionAudioMuted(false)
                await speechClient.startAnswerRecording()
            }

        case .questionPlaybackFailed:
            guard state.phase == .asking else { return .none }
            guard !state.hasRetriedPlayback else {
                return reduceInner(&state, .networkFailureDetected(.playQuestion))
            }
            // 같은 questionId 재호출 = 서버가 TTS 를 처음부터 재생성한다([[api#Interview]] 스트리밍 규약).
            state.hasRetriedPlayback = true
            return playCurrentQuestion(state)

        case .speechDetected:
            // 감지기는 답변 구간에만 열려 있지만, 닫힘 직후 도착한 잔광(제출·상한 전환 뒤)은 여기서 한 번 더 거른다.
            guard state.phase == .answering else { return .none }
            state.hasDetectedSpeech = true
            return .none

        case .micCaptureFailed:
            state.isMicCaptureFailed = true
            return .none

        case .exitNoticeExpired:
            guard state.toast == .exitUnlocked else { return .none }
            state.toast = nil
            return .none

        case let .answerSubmitted(result):
            return reduceAnswerSubmitted(&state, result: result)

        case let .answerSubmissionFailed(error, submission):
            state.isSubmitting = false
            switch error {
            case .sessionAlreadyEnded:
                // 이미 종료된 세션(409) — 정상 종료로 수습한다. 녹화가 있으면 그래도 정지·합성 후 업로드 경로를 탄다.
                state.isExitConfirmPresented = false
                guard state.hasRecording else {
                    // 합성이 없어도 인디케이터는 세운다 — 코디네이터가 리포트 생성을 기다리는 동안
                    // 화면이 이 자리에 머물러서다(빈 세션 화면이 아니라 로딩 모달을 보여야 한다).
                    state.isFinishing = true
                    return .merge(sessionCleanup(), .send(.delegate(.finished(nil, nil))))
                }
                return stopRecordingAndFinish(&state)
            default:
                return reduceInner(&state, .networkFailureDetected(.submit(submission)))
            }

        case let .networkFailureDetected(retry):
            // 세션을 살린 채 오버레이만 얹는다 — 시계 tick 은 유지(clockTicked 가 suspended 로 접는다),
            // 녹화·마이크도 유지(영상에 공백 구간 — 허용, 스펙 ③). 재생·토스트·제출만 끊는다.
            state.failure = InterviewFailureFeature.State(kind: .network)
            state.isEarlyExitWarningPresented = false
            state.isExitConfirmPresented = false
            state.pendingRetry = retry
            state.toast = nil
            return .merge(
                .cancel(id: CancelID.playback),
                .cancel(id: CancelID.submission),
                .cancel(id: CancelID.toast)
            )
        }
    }

    /// 오버레이(네트워크 실패)의 delegate — 재개는 보관한 단계를 재실행, 중단은 **제출 없이** 이탈.
    /// BACK_EXIT 제출을 태우면 이용권이 차감돼 화면 문구(«차감되지 않아요»)와 어긋난다(스펙 «결정 요약») —
    /// 중단이 서버에 알리는 건 제출이 아니라 중단 API(abandon)다.
    private func reduceFailure(
        _ state: inout State, _ action: PresentationAction<InterviewFailureFeature.Action>
    ) -> Effect<Action> {
        // 중단 레이스(최대 3초) 중엔 오버레이가 그대로 떠 있어 두 버튼이 계속 눌린다 — 전부 no-op 이어야 한다.
        // [중단하기] 재탭은 abandon 재발사(이미 버린 세션에 두 번째 요청)를, [이어서 진행하기]는 버린 세션의
        // 재생·재제출을 부른다. 첫 탭은 아래에서 `isAbandoning` 을 세우기 «전» 이라 이 가드를 그대로 지난다.
        if state.isAbandoning { return .none }

        switch action {
        case .presented(.delegate(.resumeRequested)):
            let retry = state.pendingRetry
            state.failure = nil
            state.pendingRetry = nil
            switch retry {
            case .playQuestion:
                // 계약 위반 진입은 processingAnswer 로 굳어 있다 — asking 으로 되돌려야 재생 완료 전환이 산다.
                state.phase = .asking
                // 재생 재시작 시점을 영상 축으로 다시 마킹 — 서버가 이 값으로 영상과 정렬한다.
                state.questionAudioStartedAt = state.elapsedSeconds
                return playCurrentQuestion(state)
            case let .submit(submission):
                state.isSubmitting = true
                return submissionEffect(state.sessionId, submission, fillsAudio: false)
            case nil:
                return .none
            }
        case .presented(.delegate(.closeRequested)):
            // 오버레이는 **내리지 않는다** — 중단은 최대 3초 걸리고, 그동안 «진행 중» 이라는 시각 상태가
            // 필요하다. 여기서 nil 로 두면 [중단하기]를 누른 사용자가 3초간 산 것처럼 보이는 세션 화면을
            // 마주한다(입력은 아래 `isAbandoning` 으로 죽어 있어 더 어긋난다). 실제로 걷히는 건
            // `aborted` 를 받은 코디네이터의 teardown 이다 — cover 째 사라진다.
            state.pendingRetry = nil
            // 레이스가 끝날 때까지 입력·잔광을 전면 잠근다(`isAbandoning` 주석 참조) —
            // 오버레이 두 버튼도 이 리듀서 맨 앞 가드가 함께 막는다.
            state.isAbandoning = true
            let sessionId = state.sessionId
            return .merge(
                sessionCleanup(),
                .run { send in
                    // 네트워크 중단 = 이용권 환급(스웨거 abandon 계약) — 화면 문구 «차감되지 않아요» 의
                    // 근거가 처음으로 서버에 반영된다(스펙 ②). 오프라인일 공산이 커 3초 레이스로 묶고
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

    /// 녹화 시작 종료 — 이 순간이 타임라인 기준점이다(스펙 §①). 시계·세션 오디오·질문 재생을 한꺼번에 연다.
    /// 재개(세그먼트 보유)면 반환된 누적초(에셋 실측)가 raw 시드를 확정한다 — 근사값(held)을 덮는다.
    /// 시작 실패(success == false)는 시드를 지킨 채 진행한다 — 영상 없는 리포트로 수렴(스펙 §⑥).
    private func reduceRecordingStarted(
        _ state: inout State, success: Bool, cumulativeSeconds: Double
    ) -> Effect<Action> {
        state.hasRecording = success
        if success {
            state.elapsedSeconds = Int(cumulativeSeconds.rounded())
        }
        if state.effectiveElapsedSeconds >= Self.exitUnlockSeconds {
            state.isExitAvailable = true   // 시드가 경계를 넘긴 재개 — 등호 tick 이 다시 오지 않는다
        }
        state.questionAudioStartedAt = state.elapsedSeconds
        // «이 프로세스에서 면접이 시작됐다» 를 여기서 못 박는다(2026-08-09) — 이 표식이 없으면 앱이
        // 백그라운드를 **거치지 않고** 죽었을 때(크래시·메모리 압박·동결 완주 전 강제 종료) 보관값이
        // 시작 탭 시점의 «0초·토큰 없음» 그대로 남아 갓 시작한 보관분과 구분되지 않고, 킬 클린업이
        // 대상으로 잡지 못해 서버 세션이 영영 살아남는다([[interview#Client 계약]]).
        // 녹화 실패(success == false)여도 찍는다 — 표식의 뜻은 «세그먼트 보유» 가 아니라 «면접 시작» 이고,
        // 음성만으로 진행한 세션도 답변이 서버에 쌓여 정리 대상이다.
        heldSessionStore.save(HeldSession(
            sessionId: state.sessionId,
            recordedSeconds: Int(cumulativeSeconds.rounded()),
            processToken: HeldSession.currentProcessToken
        ))
        return .merge(
            .run { send in
                for await _ in clock.timer(interval: Self.clockTick) {
                    await send(.inner(.clockTicked))
                }
            }
            .cancellable(id: CancelID.clock),
            // 세션 오디오는 녹화 성공 시에만 — 합성 입력이 없으면 어차피 포기 경로(스펙 §⑥).
            // 캡처 구독과 같은 effect 로 묶어 «엔진 먼저» 순서를 보장한다(observeMicCapture 주석 참조).
            observeMicCapture(startsSessionAudio: success),
            playCurrentQuestion(state)
        )
    }

    /// 세션 시계 1초 진행 — 8:00 해금, 상한 10초 전 최종 카운트다운, 상한 도달 시 HARD_CAP 제출.
    private func reduceClockTick(_ state: inout State) -> Effect<Action> {
        state.elapsedSeconds += 1

        if state.isWrappingUp { return .none }   // 계측 전용 tick — 해금·상한 로직 잠금
        if state.failure != nil {
            // 오버레이 동안도 계측 전용 — 영상 축은 흐르고 유효시간(판정·표시)은 멈춘다(스펙 ③).
            state.suspendedSeconds += 1
            return .none
        }

        if state.effectiveElapsedSeconds >= Self.hardCapSeconds {
            return reachHardCap(&state)
        }

        if state.effectiveElapsedSeconds >= Self.hardCapSeconds - Self.finalCountdownSeconds {
            if state.phase != .finalCountdown {
                state.phase = .finalCountdown
                state.toast = .timeExpired   // 카운트다운 동안 상시 유지 — 만료 타이머 없음.
                return .cancel(id: CancelID.toast)
            }
            return .none
        }

        if state.effectiveElapsedSeconds == Self.exitUnlockSeconds {
            state.isExitAvailable = true
            // 해금과 함께 낡은 차감 경고는 닫는다 — 안내는 아래 해금 토스트가 잇는다.
            state.isEarlyExitWarningPresented = false
            state.toast = .exitUnlocked
            return .run { send in
                try await clock.sleep(for: Self.exitNoticeHold)
                await send(.inner(.exitNoticeExpired))
            }
            .cancellable(id: CancelID.toast, cancelInFlight: true)
        }

        return .none
    }

    /// 12:00 상한 — 시계를 멈추고 HARD_CAP 을 제출한다(제출 완료까지 processingAnswer 로 대기 표현).
    /// 이미 제출이 비행 중이면 그 응답 수신이 마감을 잇는다(hardCapReachedWhileSubmitting).
    private func reachHardCap(_ state: inout State) -> Effect<Action> {
        state.isExitConfirmPresented = false
        state.isEarlyExitWarningPresented = false
        if state.isSubmitting {
            state.hardCapReachedWhileSubmitting = true
            return .cancel(id: CancelID.clock)
        }
        state.phase = .processingAnswer
        return .merge(
            .cancel(id: CancelID.clock),
            .cancel(id: CancelID.playback),
            submitCurrentAnswer(&state, endType: .hardCap)
        )
    }

    /// 제출 응답 처리 — 종료 판정이면 endSession, 아니면 다음 질문으로 턴을 넘긴다.
    /// (`reduceInner` 에서 떼어 낸 case 본문 — 동결 잠금이 더해지며 그 switch 가 복잡도 한계를 넘었다.)
    private func reduceAnswerSubmitted(_ state: inout State, result: AnswerResult) -> Effect<Action> {
        state.isSubmitting = false
        if result.sessionEnded {
            return endSession(&state, result: result)
        }
        if let next = result.nextQuestion {
            state.currentQuestion = ActiveQuestion(next)
            state.hasRetriedPlayback = false
            if state.hardCapReachedWhileSubmitting {
                // 비행 중 상한 도달 — 새 질문을 여는 대신 즉시 HARD_CAP 으로 마감한다.
                state.phase = .processingAnswer
                return submitCurrentAnswer(&state, endType: .hardCap)
            }
            if state.phase == .finalCountdown {
                // 초읽기 중엔 재생을 열지 않는다 — 12:00 도달이 HARD_CAP 으로 마감한다.
                return .none
            }
            guard state.phase == .processingAnswer else { return .none }
            state.phase = .asking
            state.questionAudioStartedAt = state.elapsedSeconds
            state.questionAudioEndedAt = nil
            state.answerStartedAt = nil
            return playCurrentQuestion(state)
        }
        // sessionEnded 도 다음 질문도 아니다 — 계약 위반 응답.
        // 도달 불가 가정이라 재시도 단계는 질문 재생으로 접는다(«중단하기» 가 탈출구).
        return reduceInner(&state, .networkFailureDetected(.playQuestion))
    }

    /// 서버가 세션 종료를 알렸다 — endType 별 delegate 로 갈라 통보한다(스펙 §5.2-3).
    private func endSession(_ state: inout State, result: AnswerResult) -> Effect<Action> {
        state.isExitConfirmPresented = false
        switch result.endType {
        case .backExit:
            return .merge(sessionCleanup(), .send(.delegate(.aborted)))
        case .sttReset:
            return .merge(sessionCleanup(), .send(.delegate(.failed(.speechRecognition))))
        case .normalEnd, .manualEnd, .hardCap, nil:
            let audioData = result.wrapUpMessage?.audioData
            guard state.hasRecording else {
                // 녹화 없음 — 마무리 멘트는 fire-and-forget 으로 걸어두고 즉시 종료(영상 없는 리포트).
                // 재생 주체는 Implementation 액터라 effect 종료·화면 교체에도 재생은 지속된다(PRD §3.7).
                // 인디케이터는 세운다 — 리포트 생성 대기 동안 화면이 여기 머문다(위 sessionAlreadyEnded 와 같은 이유).
                state.isFinishing = true
                let wrapUp: Effect<Action> = audioData.map { data in
                    .run { _ in _ = await speechClient.play(data) }
                } ?? .none
                return .merge(wrapUp, sessionCleanup(), .send(.delegate(.finished(nil, nil))))
            }
            guard let audioData else {
                // 멘트 오디오 없음 — 즉시 정지, wrapUp = nil 업로드 경로(스펙 §①).
                return stopRecordingAndFinish(&state)
            }
            // 마무리 멘트를 영상에 담는다 — 재생 완료 후 정지(스펙 §①). 구간은 세션 시계로 계측.
            state.isWrappingUp = true
            state.wrapUpStartedAt = state.elapsedSeconds
            return .merge(
                .cancel(id: CancelID.toast),
                // HARD_CAP 경로는 시계가 이미 취소됨 — 계측을 위해 다시 돌린다.
                .run { send in
                    for await _ in clock.timer(interval: Self.clockTick) {
                        await send(.inner(.clockTicked))
                    }
                }
                .cancellable(id: CancelID.clock, cancelInFlight: true),
                .run { send in
                    // 마무리 멘트도 서버 TTS 가 얹는 구간(wrapUpSpan 계약) — 재생 전에 무음으로 건다.
                    // 해제는 없다: 이 재생이 끝나면 곧바로 세션 오디오 마감이라 이후 기록 자체가 없다.
                    await speechClient.setSessionAudioMuted(true)
                    for await _ in await speechClient.play(audioData) { break }   // finished/failed 첫 이벤트가 곧 재생 종료
                    await send(.inner(.wrapUpPlaybackFinished))
                }
                .cancellable(id: CancelID.playback, cancelInFlight: true)
            )
        }
    }

    /// 세션 오디오 마감 → 마이크 정지 → 녹화 정지+합성 → 종료 통보 — 실패는 nil ref(영상 없는 리포트, 스펙 §⑥).
    ///
    /// **마이크를 마감 «뒤에» 끊는 이유(경합 제거)**: `stopCapture()` 는 진행 중이던 세션 기록을 **폐기**한다
    /// (파일 삭제). 마감(`finishSessionAudioRecording`)과 merge 로 같이 걸면 어느 쪽이 먼저인지 미보장이라
    /// 정상 종료마다 산출물이 통째로 날아갈 수 있다. 마감이 반환한 뒤엔 기록기 url 이 비어 있어
    /// (`TapFileRecorder.finishKeepingFile` 의 defer) 폐기가 아무것도 지우지 않으므로, 같은 effect 안에서
    /// 순서를 세워 곧바로 끊는다. `.cancel(id: .micCapture)` 는 `recordingStopped` 에 백스톱으로 남겨 둔다.
    ///
    /// **합성 «앞에서» 끊는 이유(장치 즉시 해제)**: 합성(AVAssetExportSession)은 실기기에서 8~10초 걸리고
    /// 그 대기는 영상 길이와 무관한 고정 비용이다(2026-08-07 실측 — 37초 세션도 555초 세션도 같았다).
    /// 그 구간 동안 마이크가 살아 있으면 «종료했는데 계속 듣고 있다» 가 된다. 카메라도 같은 이유로
    /// 놓아주지만 그건 여기가 아니다 — mp4 의 moov 가 캡처세션이 도는 동안 써지므로, 파일 마감 뒤·합성 앞이라는
    /// 좁은 자리가 필요해 `CameraSessionManager.stopRecording` 안에서 처리한다.
    ///
    /// **재진입 가드(`isFinishing`)**: 정지+합성은 수 초 걸리고 그동안 액터의 recording 은 이미 비어 있어,
    /// 두 번째 호출은 즉시 throw 해 `finished(nil, nil)` 을 진짜 결과보다 **먼저** 내보낸다 —
    /// 코디네이터의 first-wins 가 진짜 ref 를 버리고 영상이 조용히 사라진다.
    ///
    /// internal — 랩업 중 백그라운드(동결 파일)가 «청취 포기 + 즉시 마감» 으로 이 경로를 그대로 탄다.
    func stopRecordingAndFinish(_ state: inout State) -> Effect<Action> {
        guard !state.isFinishing else { return .none }
        state.isFinishing = true
        return .merge(
            sessionCleanup(includingMicCapture: false),
            .run { send in
                let audio = await speechClient.finishSessionAudioRecording()
                await speechClient.stopCapture()
                let ref: RecordingRef?
                do {
                    ref = try await recordingClient.stopRecording(
                        audio.map { RecordingAudioSegment(fileURL: $0.fileURL, startedAtHostSeconds: $0.startedAtHostSeconds) }
                    )
                } catch {
                    Self.recordingLogger.error("녹화 정지·합성 실패: \(String(describing: error))")
                    ref = nil
                }
                await send(.inner(.recordingStopped(ref)))
            }
        )
    }

    /// 세션 effect 일괄 취소 — 시계·토스트·제출·재생·마이크. 화면 전환(보고서·닫기)은 상위 몫.
    /// `includingMicCapture: false` 는 정지+합성 경로 전용 — 마이크 취소가 세션 오디오를 폐기하기 때문
    /// (`stopRecordingAndFinish` 주석). 그 경로에선 마감 후 `recordingStopped` 가 대신 끊는다.
    private func sessionCleanup(includingMicCapture: Bool = true) -> Effect<Action> {
        .merge(
            .cancel(id: CancelID.clock),
            .cancel(id: CancelID.toast),
            .cancel(id: CancelID.submission),
            includingMicCapture ? .cancel(id: CancelID.micCapture) : .none,
            .cancel(id: CancelID.playback)
        )
    }

    /// 진행 중 질문 재생 — 요약 질문(턴 0)은 동봉 mp3(`play`), 이후 질문은 chunked 스트림(`playStream`).
    /// 요약 질문에 오디오가 없으면(계약상 없을 일) 스트림으로 폴백한다. 재개 진입은 요약 질문 자체가
    /// 없어(nil) 첫 질문부터 스트림이다.
    private func playCurrentQuestion(_ state: State) -> Effect<Action> {
        let question = state.currentQuestion
        let summaryAudio = state.summaryQuestion.flatMap { summary in
            question.questionId == summary.questionId ? summary.audioData : nil
        }
        let sessionId = state.sessionId
        return .run { send in
            // 질문 TTS 는 서버가 영상에 다시 얹는 구간 — 스피커 에코가 이중 음성이 되지 않게 먼저 무음으로 건다.
            // 요약·스트림·재시도가 전부 이 단일 진입점을 지나므로 여기 한 곳이면 충분하다(해제는 answering 진입).
            await speechClient.setSessionAudioMuted(true)
            let events: AsyncStream<PlaybackEvent>
            if let summaryAudio {
                events = await speechClient.play(summaryAudio)
            } else {
                do {
                    let stream = try await interviewClient.questionAudioStream(sessionId, question.questionId)
                    events = await speechClient.playStream(stream.url, stream.headers)
                } catch is CancellationError {
                    return
                } catch {
                    Self.playbackLogger.error("질문 스트림 요청 실패: \(String(describing: error))")
                    return await send(.inner(.questionPlaybackFailed))
                }
            }
            for await event in events {
                switch event {
                case .finished:
                    return await send(.inner(.questionPlaybackFinished))
                case let .failed(reason):
                    Self.playbackLogger.error("질문 재생 실패: \(reason)")
                    return await send(.inner(.questionPlaybackFailed))
                }
            }
        }
        .cancellable(id: CancelID.playback, cancelInFlight: true)
    }

    /// 답변 제출 — 시간 마킹을 실은 submission 에 답변 오디오를 채워 503 백오프로 보낸다.
    /// 제출형 종료(마치기·상한)도 이 경로다 — endType 만 다르다.
    private func submitCurrentAnswer(_ state: inout State, endType: AnswerEndType?) -> Effect<Action> {
        state.isSubmitting = true
        return submissionEffect(state.sessionId, makeSubmission(state, endType: endType), fillsAudio: true)
    }

    /// 제출 공용 effect — 오버레이 재시도(fillsAudio: false)는 보관한 payload 를 그대로 재전송한다
    /// (`answerAudio()` 는 1회 소모성 — 재호출하면 nil 로 씻긴다). 실패 액션에 payload 를 동봉하는 이유다.
    private func submissionEffect(
        _ sessionId: Int, _ submission: AnswerSubmission, fillsAudio: Bool
    ) -> Effect<Action> {
        .run { send in
            var submission = submission
            if fillsAudio { submission.audio = await speechClient.answerAudio() }
            // 답변별 산출물 크기 — 세션 «도중» 기록이 죽는 지점을 콘솔에서 판별한다(STT_RESET 추적).
            // 정상 은 대략 12KB/s + 4KB 헤더 — 수 KB 면 빈 껍데기, 0 이면 기록이 안 열린 것.
            Self.recordingLogger.notice(
                "답변 오디오 \(submission.audio?.count ?? 0) bytes — 질문 \(submission.questionId)"
            )
            do {
                await send(.inner(.answerSubmitted(try await submitWithRetry(sessionId, submission))))
            } catch is CancellationError {
            } catch let error as InterviewError {
                await send(.inner(.answerSubmissionFailed(error, submission)))
            } catch {
                await send(.inner(.answerSubmissionFailed(.unexpected, submission)))
            }
        }
        .cancellable(id: CancelID.submission, cancelInFlight: true)
    }

    /// 시간 마킹(세션 시계 스냅샷 — 실녹화 전 근사값)을 Double 계약으로 변환한다.
    private func makeSubmission(_ state: State, endType: AnswerEndType?) -> AnswerSubmission {
        AnswerSubmission(
            questionId: state.currentQuestion.questionId,
            questionAudioStartAt: state.questionAudioStartedAt.map(Double.init),
            questionAudioEndAt: state.questionAudioEndedAt.map(Double.init),
            answerStartAt: state.answerStartedAt.map(Double.init),
            answerEndAt: state.answerStartedAt.map { _ in Double(state.elapsedSeconds) },
            answerDuration: state.answerStartedAt.map { Double(state.elapsedSeconds - $0) },
            endType: endType,
            isWrapUp: state.effectiveElapsedSeconds >= Self.wrapUpThresholdSeconds
        )
    }

    /// 제출 + 503 백오프 — `aiTemporarilyUnavailable`(서버에 아무것도 저장 안 됨)만 같은 요청을 재시도한다.
    private func submitWithRetry(_ sessionId: Int, _ submission: AnswerSubmission) async throws -> AnswerResult {
        for delay in Self.submissionRetryDelays {
            do {
                return try await interviewClient.submitAnswer(sessionId, submission)
            } catch let error as InterviewError where error == .aiTemporarilyUnavailable {
                try await clock.sleep(for: delay)
            }
        }
        return try await interviewClient.submitAnswer(sessionId, submission)
    }

    /// 마이크 캡처 구독 — 세션 전구간. 발화 시작(`speechStarted`)·캡처 실패는 inner 로 올려 «답변 완료하기»
    /// 노출을 결정하고, 나머지(레벨·발화 종료)는 로그만 남긴다. 침묵 10초 확정을 도입할 때 `speechEnded` 를 승격한다.
    /// 정지는 코디네이터 stopCaptureDevices + 취소 양쪽.
    ///
    /// `startsSessionAudio` 를 별도 effect 로 떼지 않는 이유: `startSessionAudioRecording` 은 캡처 엔진이
    /// 세팅하는 tap 포맷을 전제로 하고, 없으면 **조용히 무시**된다(SpeechClientLive `guard let tapFormat`).
    /// merge 로 두면 두 Task 의 순서가 미보장이라 세션 오디오가 먼저 도착하는 순간 항상 무기록이 되고,
    /// finish 가 nil → stopRecording throw → 모든 세션이 영상 없는 리포트로 수렴한다.
    /// `startCapture()` 반환 시점엔 엔진 시작이 끝나 있으므로 같은 effect 안에서 이어 부른다.
    private func observeMicCapture(startsSessionAudio: Bool) -> Effect<Action> {
        .run { send in
            let events = await speechClient.startCapture()
            if startsSessionAudio {
                await speechClient.startSessionAudioRecording()
            }
            for await event in events {
                switch event {
                case let .level(decibels):
                    Self.micLogger.info("입력 레벨 \(decibels, format: .fixed(precision: 1), align: .right(columns: 6)) dBFS")
                case .speechStarted:
                    Self.micLogger.notice("음성 감지 시작")
                    await send(.inner(.speechDetected))
                case .speechEnded:
                    Self.micLogger.notice("음성 감지 종료")
                case let .captureFailed(reason):
                    Self.micLogger.error("마이크 캡처 시작 실패: \(reason)")
                    await send(.inner(.micCaptureFailed))
                }
            }
        }
        .cancellable(id: CancelID.micCapture)
    }
}
