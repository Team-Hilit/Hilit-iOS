//
//  InterviewFeatureResumeReadinessTests.swift
//  FeatureInterviewTests
//
//  Created by 서정원 on 26/11/23.
//

import AVFoundation
import ComposableArchitecture
import DomainInterviewInterface
import DomainPermissionInterface
import DomainRecordingInterface
import DomainSpeechInterface
import Testing

@testable import FeatureInterviewImplementation

// 재개 진입의 준비 화면 경유(2026-11-23) — 이탈 사이 카메라·마이크 권한이 꺼졌을 수 있어 세션으로 직행하지 않는다.
// 준비 화면이 권한을 다시 확인하고, «면접 시작하기» 탭이 재개 시드로 세션을 연다.
// 직행하면 권한 없이 녹화가 열려 영상·음성이 빈 채로 면접이 이어진다.
@MainActor
struct InterviewFeatureResumeReadinessTests {
    private static let seed = InterviewFeatureResumeRoutingTests.resumeSeed

    /// 스텁 편의 — 기본값은 전부 허용.
    private func permissionClient(
        status: @escaping @Sendable (MediaPermission) -> PermissionStatus = { _ in .granted }
    ) -> PermissionClient {
        PermissionClient(status: status, request: { _ in true }, openSettings: {})
    }

    // MARK: - 코디네이터

    @Test("재개 진입은 세션이 아니라 준비 화면으로 열린다 — 권한을 다시 확인할 기회를 건너뛰지 않는다")
    func resumeEntryOpensReadiness() {
        let state = InterviewFeature.State(sessionId: 5, resume: Self.seed)

        guard case let .readiness(readiness) = state.screen else {
            Issue.record("재개 진입이 준비 화면으로 열리지 않았다: \(state.screen)")
            return
        }
        #expect(readiness.sessionId == 5)
        #expect(readiness.isResume)
        #expect(state.resumeSeed == Self.seed)
    }

    @Test("일반 진입은 재개 표식이 없다 — 질문 준비 폴링과 요약 질문 시드를 그대로 쓴다")
    func freshEntryIsNotResume() {
        let state = InterviewFeature.State(sessionId: 5)

        guard case let .readiness(readiness) = state.screen else {
            Issue.record("일반 진입이 준비 화면으로 열리지 않았다: \(state.screen)")
            return
        }
        #expect(!readiness.isResume)
        #expect(state.resumeSeed == nil)
    }

    @Test("재개 시작 전환은 재개 시드와 프리뷰 핸들로 세션을 열고 장부는 건드리지 않는다")
    func startRequestedOpensSessionWithResumeSeed() async {
        let handle = CameraPreviewHandle(session: AVCaptureSession())
        var readiness = InterviewReadinessFeature.State(sessionId: 5, isResume: true)
        readiness.previewHandle = handle
        var initialState = InterviewFeature.State(sessionId: 5, resume: Self.seed)
        initialState.screen = .readiness(readiness)
        // heldSessionStore 미스텁 — 재개는 장부가 이미 «시작됨»·누적초 보유라, 읽거나 다시 쓰면(회수 판정 재료가
        // 흔들린다) unimplemented 가 잡는다. 표식은 세션이 녹화를 열 때 찍는다.
        let store = TestStore(initialState: initialState) { InterviewFeature() }

        await store.send(.screen(.readiness(.delegate(.startRequested)))) {
            $0.screen = .session(InterviewSessionFeature.State(
                sessionId: 5,
                resume: Self.seed,
                previewHandle: handle
            ))
        }
    }

    @Test("재개 준비 화면 뒤로가기는 장부·세그먼트를 남기고 장치만 놓은 채 홈으로 나간다 — 연타해도 통보는 한 번")
    func resumeReadinessBackKeepsResumeMaterial() async {
        let calls = LockIsolated<[String]>([])
        let store = TestStore(initialState: InterviewFeature.State(sessionId: 5, resume: Self.seed)) {
            InterviewFeature()
        } withDependencies: {
            $0.recordingClient.suspendRecording = { _ in
                calls.withValue { $0.append("suspend") }
                return nil
            }
            $0.recordingClient.stopPreview = { calls.withValue { $0.append("stopPreview") } }
            $0.speechClient.stopCapture = { calls.withValue { $0.append("stopCapture") } }
            // discardRecording·heldSessionStore·interviewClient 미스텁 — 세그먼트 원장을 비우거나(이어 볼 영상이 사라진다)
            // 장부를 지우거나(홈 카드가 꺼진다) 서버에 중단을 쏘면(리포트 생성 = 차감) unimplemented 가 잡는다.
        }

        await store.send(.screen(.readiness(.delegate(.backRequested)))) { $0.isClosing = true }
        await store.receive(\.delegate.interrupted)
        await store.send(.screen(.readiness(.delegate(.backRequested))))   // 이미 나가는 중 — 무시
        await store.finish()
        #expect(calls.value == ["suspend", "stopPreview", "stopCapture"])
    }

    // MARK: - 준비 화면

    @Test("재개 진입은 질문 준비 폴링 없이 guide2 에서 시작 게이트가 열린다 — 질문은 confirmResume 이 이미 줬다")
    func resumeOpensStartGateWithoutQuestionPrepPolling() async {
        let clock = TestClock()
        let store = TestStore(initialState: InterviewReadinessFeature.State(sessionId: 1, isResume: true)) {
            InterviewReadinessFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.permissionClient = permissionClient()
            $0.recordingClient.startPreview = { nil }
            // interviewClient 미스텁 — sessionStatus 폴링을 걸면 unimplemented 가 잡는다.
        }
        store.exhaustivity = .off   // 권한·프리뷰 해소 순서는 비결정 — phase 진행과 게이트만 고정한다.

        await store.send(.view(.onAppear))
        await clock.advance(by: InterviewReadinessFeature.aligningHold)
        await store.skipReceivedActions()
        await clock.advance(by: InterviewReadinessFeature.readyHold)
        await store.skipReceivedActions()
        await clock.advance(by: InterviewReadinessFeature.guide1Hold)
        await store.skipReceivedActions()
        #expect(store.state.phase == .guide2)
        #expect(store.state.isMediaPermissionGranted)
        #expect(store.state.isQuestionPrepReady)   // 서버 상태에 물리지 않는다

        await store.send(.view(.userTappedStart))
        await store.receive(\.delegate.startRequested)
        await store.finish()
    }

    @Test("재개 진입 시 권한이 꺼져 있으면 설정 유도 alert 를 띄운다 — 직행하던 때는 알릴 길이 없었다")
    func resumeWithRevokedPermissionShowsAlert() async {
        let clock = TestClock()
        let store = TestStore(initialState: InterviewReadinessFeature.State(sessionId: 1, isResume: true)) {
            InterviewReadinessFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.permissionClient = permissionClient(status: { $0 == .microphone ? .denied : .granted })
            $0.recordingClient.startPreview = { nil }
        }
        store.exhaustivity = .off

        await store.send(.view(.onAppear))
        await store.skipReceivedActions()
        #expect(!store.state.isMediaPermissionGranted)
        #expect(store.state.alert == InterviewReadinessFeature.permissionDeniedAlert())

        await clock.advance(by: .seconds(8))   // 잔여 phase 타이머 소진
        await store.skipReceivedActions()
        await store.finish()
    }

    @Test("재개 진입도 권한이 미허용이면 시작하기가 통하지 않는다 — 무음 녹화로 이어지지 않는다")
    func resumeStartBlockedWhilePermissionDenied() async {
        var state = InterviewReadinessFeature.State(sessionId: 1, isResume: true)
        state.phase = .guide2
        state.hasStarted = true
        state.isMediaPermissionGranted = false
        let store = TestStore(initialState: state) { InterviewReadinessFeature() }

        await store.send(.view(.userTappedStart))   // 상태 무변화·delegate 없음
        await store.finish()
    }
}
