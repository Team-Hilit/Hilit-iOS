//
//  InterviewFeatureTests.swift
//  FeatureInterviewTests
//
//  Created by 서정원 on 26/07/27.
//

import AVFoundation
import ComposableArchitecture
import DomainInterviewInterface
import DomainInterviewReportInterface
import DomainInterviewReportTesting
import DomainRecordingInterface
import DomainSpeechInterface
import Foundation
import Testing

@testable import FeatureInterviewImplementation

// 코디네이터 delegate 라우팅을 분기별로 고정한다 — 화면 전환·캡처 정지·상위 통보.
@MainActor
struct InterviewFeatureTests {
    @Test("세션 종료는 산출물을 업로드 큐에 넘기고 장치를 정지한 뒤 즉시 상위에 종료를 통보한다 — 경유 화면 없음")
    func sessionFinishEnqueuesUploadThenNotifiesFinished() async {
        let enqueued = LockIsolated<[(Int, URL)]>([])
        let previewStopped = LockIsolated(0)
        let captureStopped = LockIsolated(0)
        var initialState = InterviewFeature.State(sessionId: 1)
        initialState.screen = .session(.fixture)
        // discardRecording·stopPlayback 미스텁 — 정상 종료가 산출 파일을 지우거나 마무리 멘트를 끊으면 잡힌다.
        let store = TestStore(initialState: initialState) {
            InterviewFeature()
        } withDependencies: {
            $0.interviewVideoUploadQueue.enqueue = { sessionId, fileURL, _ in
                enqueued.withValue { $0.append((sessionId, fileURL)) }
            }
            // 채점이 이미 끝난 응답 — 대기 없이 곧장 홈 통보로 이어진다(대기 경로는 아래 별도 테스트).
            $0.interviewReportClient.report = { _ in InterviewReportFixtures.ready }
            $0.recordingClient.stopPreview = { previewStopped.withValue { $0 += 1 } }
            $0.speechClient.stopCapture = { captureStopped.withValue { $0 += 1 } }
        }

        await store.send(.screen(.session(.delegate(.finished(.fixture, .fixture))))) {
            $0.isClosing = true
        }
        await store.receive(\.delegate.finished)
        await store.finish()
        #expect(enqueued.value.map(\.0) == [1])
        #expect(enqueued.value.map(\.1) == [RecordingRef.fixture.fileURL])
        #expect(previewStopped.value == 1)
        #expect(captureStopped.value == 1)
    }

    @Test("녹화 없는 종료(ref nil)는 큐를 부르지 않고 종료만 통보한다")
    func sessionFinishWithoutRecordingSkipsQueue() async {
        var initialState = InterviewFeature.State(sessionId: 1)
        initialState.screen = .session(.fixture)
        // interviewVideoUploadQueue 미스텁 — enqueue 가 불리면 unimplemented 가 잡는다.
        let store = TestStore(initialState: initialState) {
            InterviewFeature()
        } withDependencies: {
            $0.interviewReportClient.report = { _ in InterviewReportFixtures.ready }
            $0.recordingClient.stopPreview = {}
            $0.speechClient.stopCapture = {}
        }

        await store.send(.screen(.session(.delegate(.finished(nil, nil))))) {
            $0.isClosing = true
        }
        await store.receive(\.delegate.finished)
        await store.finish()
    }

    @Test("리포트가 GENERATING 이면 채점이 끝날 때까지 기다렸다 홈으로 통보한다 — 그동안 화면은 세션(로딩 모달)에 머문다")
    func sessionFinishWaitsUntilReportIsGenerated() async {
        let clock = TestClock()
        let polls = LockIsolated(0)
        var initialState = InterviewFeature.State(sessionId: 1)
        initialState.screen = .session(.fixture)
        let store = TestStore(initialState: initialState) {
            InterviewFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.interviewReportClient.report = { _ in
                polls.withValue { $0 += 1 }
                return polls.value < 2 ? InterviewReportFixtures.generating : InterviewReportFixtures.ready
            }
            $0.interviewVideoUploadQueue.enqueue = { _, _, _ in }
            $0.recordingClient.stopPreview = {}
            $0.speechClient.stopCapture = {}
        }

        await store.send(.screen(.session(.delegate(.finished(.fixture, .fixture))))) {
            $0.isClosing = true
        }
        // 첫 조회가 GENERATING — 주기만큼 흐른 뒤 다시 묻고, READY 를 받고서야 종료를 올린다.
        await clock.advance(by: InterviewFeature.reportPollInterval)
        await store.receive(\.delegate.finished)
        await store.finish()
        #expect(polls.value == 2)
    }

    @Test("종료 확정 후 도착한 늦은 두 번째 종료·중단·실패 통보는 무시한다 — 업로드 재접수·이중 통보·파일 폐기 방지")
    func lateDuplicateSessionSignalsAreIgnoredAfterFinish() async {
        var initialState = InterviewFeature.State(sessionId: 1)
        initialState.screen = .session(.fixture)
        let store = TestStore(initialState: initialState) {
            InterviewFeature()
        } withDependencies: {
            $0.interviewReportClient.report = { _ in InterviewReportFixtures.ready }
            $0.interviewVideoUploadQueue.enqueue = { _, _, _ in }
            $0.recordingClient.stopPreview = {}
            $0.speechClient.stopCapture = {}
        }

        await store.send(.screen(.session(.delegate(.finished(.fixture, .fixture))))) {
            $0.isClosing = true
        }
        await store.receive(\.delegate.finished)
        // isClosing 가드 — 스텁을 최소로 유지한 채(폐기·재생 정지 미스텁) 세 신호가 조용히 무시되는지 본다.
        await store.send(.screen(.session(.delegate(.finished(nil, nil)))))
        await store.send(.screen(.session(.delegate(.aborted))))
        // 실패는 화면을 갈아끼우므로 case 가드가 아니라 isClosing 만이 막는다 —
        // 뚫리면 실패 헬퍼의 discardRecording 이 이미 큐에 넘긴 파일을 지운다(미스텁이라 unimplemented 로 잡힌다).
        await store.send(.screen(.session(.delegate(.failed(.speechRecognition)))))
        await store.finish()
    }

    @Test("면접 시작 전환은 요약 질문·프리뷰 핸들을 세션에 시드하고 장부를 «시작됨» 으로 올린다")
    func startRequestedSeedsSummaryQuestionAndPreviewHandle() async {
        let handle = CameraPreviewHandle(session: AVCaptureSession())
        // 온보딩 완주가 이미 열어 둔 장부 — 시작 전이라 hasStarted false, 표식은 찍혀 있다.
        let opened = HeldSession(
            sessionId: 1,
            recordedSeconds: 0,
            hasStarted: false,
            processToken: HeldSession.currentProcessToken
        )
        let held = LockIsolated<HeldSession?>(opened)
        var readiness = InterviewReadinessFeature.State(sessionId: 1)
        readiness.previewHandle = handle
        readiness.questionPrep = .ready(.fixture)
        var initialState = InterviewFeature.State(sessionId: 1)
        initialState.screen = .readiness(readiness)
        let store = TestStore(initialState: initialState) {
            InterviewFeature()
        } withDependencies: {
            $0.heldSessionStore.load = { held.value }
            $0.heldSessionStore.save = { held.setValue($0) }
        }

        await store.send(.screen(.readiness(.delegate(.startRequested)))) {
            $0.screen = .session(InterviewSessionFeature.State(
                sessionId: 1,
                summaryQuestion: .fixture,
                previewHandle: handle
            ))
        }
        // 플래그만 오른다 — 표식·누적초는 장부에 있던 값 그대로다(덮어쓰면 회수 판정이 흔들린다).
        #expect(held.value == HeldSession(
            sessionId: 1,
            recordedSeconds: 0,
            hasStarted: true,
            processToken: HeldSession.currentProcessToken
        ))
    }

    @Test("장부가 비어 있으면 시작 전환이 새로 연다 — 시작한 세션이 장부 밖에 남으면 회수 불가다")
    func startRequestedOpensLedgerWhenMissing() async {
        let handle = CameraPreviewHandle(session: AVCaptureSession())
        let held = LockIsolated<HeldSession?>(nil)
        var readiness = InterviewReadinessFeature.State(sessionId: 9)
        readiness.previewHandle = handle
        readiness.questionPrep = .ready(.fixture)
        var initialState = InterviewFeature.State(sessionId: 9)
        initialState.screen = .readiness(readiness)
        let store = TestStore(initialState: initialState) {
            InterviewFeature()
        } withDependencies: {
            $0.heldSessionStore.load = { held.value }
            $0.heldSessionStore.save = { held.setValue($0) }
        }

        await store.send(.screen(.readiness(.delegate(.startRequested)))) {
            $0.screen = .session(InterviewSessionFeature.State(
                sessionId: 9,
                summaryQuestion: .fixture,
                previewHandle: handle
            ))
        }
        #expect(held.value == HeldSession(sessionId: 9, recordedSeconds: 0, hasStarted: true))
    }

    @Test("질문 준비 실패는 questionPrep 실패 화면으로 전환한다")
    func prepFailedRoutesToFailure() async {
        let store = TestStore(initialState: InterviewFeature.State(sessionId: 1)) {
            InterviewFeature()
        } withDependencies: {
            $0.recordingClient.stopPreview = {}
            $0.recordingClient.discardRecording = {}
            $0.speechClient.stopCapture = {}
            $0.speechClient.stopPlayback = {}
        }

        await store.send(.screen(.readiness(.delegate(.prepFailed)))) {
            $0.screen = .failure(InterviewFailureFeature.State(kind: .questionPrep))
        }
        await store.finish()
    }

    @Test("실패 화면 X(닫기)로 흐름을 떠날 때도 캡처 장치·재생을 정지하고 녹화를 폐기한 뒤 종료를 통보한다")
    func closingFromFailureStopsDevices() async {
        let previewStopped = LockIsolated(0)
        let captureStopped = LockIsolated(0)
        let playbackStopped = LockIsolated(0)
        let recordingDiscarded = LockIsolated(0)
        var initialState = InterviewFeature.State(sessionId: 1)
        initialState.screen = .failure(InterviewFailureFeature.State(kind: .questionPrep))
        let store = TestStore(initialState: initialState) {
            InterviewFeature()
        } withDependencies: {
            $0.recordingClient.stopPreview = { previewStopped.withValue { $0 += 1 } }
            $0.recordingClient.discardRecording = { recordingDiscarded.withValue { $0 += 1 } }
            $0.speechClient.stopCapture = { captureStopped.withValue { $0 += 1 } }
            $0.speechClient.stopPlayback = { playbackStopped.withValue { $0 += 1 } }
        }

        await store.send(.screen(.failure(.delegate(.closeRequested))))
        await store.receive(\.delegate.closed)
        await store.finish()
        #expect(previewStopped.value == 1)
        #expect(captureStopped.value == 1)
        #expect(playbackStopped.value == 1)
        #expect(recordingDiscarded.value == 1)
    }

    @Test("준비 화면 뒤로가기는 캡처 장치를 정지한 뒤 상위에 종료를 통보한다 — 모달 없이 즉시 이탈")
    func readinessBackStopsDevicesThenNotifiesClosed() async {
        let previewStopped = LockIsolated(0)
        let captureStopped = LockIsolated(0)
        let playbackStopped = LockIsolated(0)
        let recordingDiscarded = LockIsolated(0)
        let store = TestStore(initialState: InterviewFeature.State(sessionId: 1)) {
            InterviewFeature()
        } withDependencies: {
            $0.recordingClient.stopPreview = { previewStopped.withValue { $0 += 1 } }
            $0.recordingClient.discardRecording = { recordingDiscarded.withValue { $0 += 1 } }
            $0.speechClient.stopCapture = { captureStopped.withValue { $0 += 1 } }
            $0.speechClient.stopPlayback = { playbackStopped.withValue { $0 += 1 } }
        }

        // heldSessionStore.save 미스텁 — 시작 전 이탈이 진행 중 보관을 심으면 unimplemented 가 잡는다
        // (심으면 홈이 «진행 중» 카드를 그린다 — 2026-08-18 이 화면의 회귀 지점).
        await store.send(.screen(.readiness(.delegate(.backRequested))))
        await store.receive(\.delegate.closed)
        await store.finish()
        #expect(previewStopped.value == 1)
        #expect(captureStopped.value == 1)
        #expect(playbackStopped.value == 1)
        // 준비 화면엔 녹화가 없지만 폐기는 멱등이라 그대로 부른다(경로별 분기 없음).
        #expect(recordingDiscarded.value == 1)
    }

    @Test("세션 중도 이탈은 화면 전환 없이 캡처 장치·재생을 정지하고 녹화를 폐기한 뒤 종료를 통보한다")
    func sessionAbortStopsDevicesThenNotifiesClosed() async {
        let previewStopped = LockIsolated(0)
        let captureStopped = LockIsolated(0)
        let playbackStopped = LockIsolated(0)
        let recordingDiscarded = LockIsolated(0)
        var initialState = InterviewFeature.State(sessionId: 1)
        initialState.screen = .session(.fixture)
        let store = TestStore(initialState: initialState) {
            InterviewFeature()
        } withDependencies: {
            $0.recordingClient.stopPreview = { previewStopped.withValue { $0 += 1 } }
            $0.recordingClient.discardRecording = { recordingDiscarded.withValue { $0 += 1 } }
            $0.speechClient.stopCapture = { captureStopped.withValue { $0 += 1 } }
            $0.speechClient.stopPlayback = { playbackStopped.withValue { $0 += 1 } }
        }

        await store.send(.screen(.session(.delegate(.aborted)))) {
            $0.isClosing = true
        }
        await store.receive(\.delegate.closed)
        await store.finish()
        #expect(previewStopped.value == 1)
        #expect(captureStopped.value == 1)
        #expect(playbackStopped.value == 1)
        #expect(recordingDiscarded.value == 1)
    }

    @Test("세션 실패 통보는 같은 kind 의 실패 화면으로 전환하고 캡처 장치·재생 정지·녹화 폐기를 한다")
    func sessionFailureRoutesToFailureScreen() async {
        let previewStopped = LockIsolated(0)
        let captureStopped = LockIsolated(0)
        let playbackStopped = LockIsolated(0)
        let recordingDiscarded = LockIsolated(0)
        var initialState = InterviewFeature.State(sessionId: 1)
        initialState.screen = .session(.fixture)
        // 코디네이터에 도달하는 실패는 STT 뿐이다 — network 는 세션이 오버레이로 직접 소유한다(스펙 ③).
        let store = TestStore(initialState: initialState) {
            InterviewFeature()
        } withDependencies: {
            $0.recordingClient.stopPreview = { previewStopped.withValue { $0 += 1 } }
            $0.recordingClient.discardRecording = { recordingDiscarded.withValue { $0 += 1 } }
            $0.speechClient.stopCapture = { captureStopped.withValue { $0 += 1 } }
            $0.speechClient.stopPlayback = { playbackStopped.withValue { $0 += 1 } }
        }

        await store.send(.screen(.session(.delegate(.failed(.speechRecognition))))) {
            $0.screen = .failure(InterviewFailureFeature.State(kind: .speechRecognition))
        }
        await store.finish()
        #expect(previewStopped.value == 1)
        #expect(captureStopped.value == 1)
        #expect(playbackStopped.value == 1)
        #expect(recordingDiscarded.value == 1)
    }
}

// MARK: - 픽스처

private extension SummaryQuestion {
    /// READY 폴링 페이로드 — 준비 → 세션 시드 검증용 최소 형태(turnLevel=0).
    static let fixture = SummaryQuestion(
        questionId: 1, ttsAudio: nil, turn: TurnInfo(turnLevel: 0, depthLevel: 0)
    )
}

private extension InterviewSessionFeature.State {
    /// 코디네이터 라우팅 검증용 세션 화면 상태 — 내용은 라우팅에 영향 없다.
    static let fixture = InterviewSessionFeature.State(sessionId: 1, summaryQuestion: .fixture)
}

private extension RecordingRef {
    /// 세션이 넘기는 녹화 산출물 — 코디네이터는 내용을 보지 않고 그대로 전달만 한다.
    static let fixture = RecordingRef(
        sessionId: 1, fileURL: URL(fileURLWithPath: "/tmp/interview-1.mp4"), durationSeconds: 600
    )
}

private extension InterviewVideoWrapUpSpan {
    /// 마무리 멘트 구간 — 코디네이터가 그대로 업로드 큐에 실어 보낸다.
    static let fixture = InterviewVideoWrapUpSpan(wrapUpStartSec: 500, wrapUpEndSec: 512)
}
