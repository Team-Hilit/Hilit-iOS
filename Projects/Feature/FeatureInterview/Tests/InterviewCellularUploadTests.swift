//
//  InterviewCellularUploadTests.swift
//  FeatureInterviewTests
//
//  Created by EunseoKim on 26/11/16.
//

import ComposableArchitecture
import DomainInterviewInterface
import DomainInterviewReportInterface
import DomainInterviewReportTesting
import DomainRecordingInterface
import DomainSpeechInterface
import Foundation
import Testing

@testable import FeatureInterviewImplementation

// 업로드 망 정책(HLT-87) — 산출물은 먼저 Wi-Fi 정책으로 접수하고, 셀룰러면 모바일 데이터 사용을 물어 허락 시 올린다.
// Wi-Fi 경로(묻지 않음)는 `InterviewFeatureTests` 의 정상 종료 테스트가 함께 고정한다.
@MainActor
struct InterviewCellularUploadTests {
    /// 셀룰러에서 마친 세션 — 접수·허용 호출을 기록한다.
    private func makeStore(
        enqueued: LockIsolated<[Bool]>,
        allowed: LockIsolated<[Int]>
    ) -> TestStoreOf<InterviewFeature> {
        var initialState = InterviewFeature.State(sessionId: 1)
        initialState.screen = .session(.fixture())
        return TestStore(initialState: initialState) {
            InterviewFeature()
        } withDependencies: {
            $0.interviewVideoUploadQueue.isOnCellular = { true }
            $0.interviewVideoUploadQueue.enqueue = { _, _, _, allowsCellular in
                enqueued.withValue { $0.append(allowsCellular) }
            }
            $0.interviewVideoUploadQueue.allowCellular = { sessionId in
                allowed.withValue { $0.append(sessionId) }
            }
            $0.interviewReportClient.report = { _ in InterviewReportFixtures.ready }
            $0.recordingClient.stopPreview = {}
            $0.speechClient.stopCapture = {}
        }
    }

    @Test("셀룰러에서 마치면 Wi-Fi 정책으로 먼저 접수한 뒤 모달을 띄우고, «모바일 데이터 사용» 이면 허용으로 올린다")
    func cellularFinishEnqueuesFirstThenAllowsCellular() async {
        let enqueued = LockIsolated<[Bool]>([])
        let allowed = LockIsolated<[Int]>([])
        let store = makeStore(enqueued: enqueued, allowed: allowed)

        await store.send(.screen(.session(.delegate(.finished(.fixture, .fixture))))) {
            $0.isClosing = true
        }
        await store.receive(\.inner.uploadNetworkChecked) {
            $0.isAwaitingCellularConsent = true
            $0.cellularUploadAlert = InterviewFeature.cellularUploadAlert
        }
        // 모달이 떠 있는 동안에도 파일은 이미 큐 소유다 — 그새 앱이 죽어도 영상이 지워지지 않는다.
        #expect(enqueued.value == [false])
        #expect(allowed.value.isEmpty)
        await store.send(.cellularUploadAlert(.presented(.userTappedUseCellular))) {
            $0.cellularUploadAlert = nil
            $0.isAwaitingCellularConsent = false
        }
        await store.receive(\.delegate.finished)
        await store.finish()
        #expect(allowed.value == [1])
    }

    @Test("셀룰러 확인 모달에서 «Wi-Fi 연결 시 업로드» 면 정책을 올리지 않고 마무리한다")
    func cellularFinishWaitForWiFiKeepsDefault() async {
        let enqueued = LockIsolated<[Bool]>([])
        let allowed = LockIsolated<[Int]>([])
        let store = makeStore(enqueued: enqueued, allowed: allowed)

        await store.send(.screen(.session(.delegate(.finished(.fixture, .fixture))))) {
            $0.isClosing = true
        }
        await store.receive(\.inner.uploadNetworkChecked) {
            $0.isAwaitingCellularConsent = true
            $0.cellularUploadAlert = InterviewFeature.cellularUploadAlert
        }
        await store.send(.cellularUploadAlert(.presented(.userTappedWaitForWiFi))) {
            $0.cellularUploadAlert = nil
            $0.isAwaitingCellularConsent = false
        }
        await store.receive(\.delegate.finished)
        await store.finish()
        #expect(enqueued.value == [false])
        #expect(allowed.value.isEmpty)
    }

    // 버튼 없이 닫히면(시스템이 알럿을 내림 등) 마무리가 영영 안 돌아 로딩 모달에 갇히던 구멍.
    @Test("모달이 버튼 없이 닫혀도 기본 정책으로 마무리한다")
    func alertDismissWithoutChoiceFinishes() async {
        let enqueued = LockIsolated<[Bool]>([])
        let allowed = LockIsolated<[Int]>([])
        let store = makeStore(enqueued: enqueued, allowed: allowed)

        await store.send(.screen(.session(.delegate(.finished(.fixture, .fixture))))) {
            $0.isClosing = true
        }
        await store.receive(\.inner.uploadNetworkChecked) {
            $0.isAwaitingCellularConsent = true
            $0.cellularUploadAlert = InterviewFeature.cellularUploadAlert
        }
        await store.send(.cellularUploadAlert(.dismiss)) {
            $0.cellularUploadAlert = nil
            $0.isAwaitingCellularConsent = false
        }
        await store.receive(\.delegate.finished)
        await store.finish()
        #expect(allowed.value.isEmpty)
    }

    @Test("모달 중 도착한 늦은 종료·중단·동결 신호는 무시한다")
    func lateSignalsDuringAlertAreIgnored() async {
        let enqueued = LockIsolated<[Bool]>([])
        let allowed = LockIsolated<[Int]>([])
        let store = makeStore(enqueued: enqueued, allowed: allowed)

        await store.send(.screen(.session(.delegate(.finished(.fixture, .fixture))))) {
            $0.isClosing = true
        }
        await store.receive(\.inner.uploadNetworkChecked) {
            $0.isAwaitingCellularConsent = true
            $0.cellularUploadAlert = InterviewFeature.cellularUploadAlert
        }
        // isClosing 가드 — 폐기·재생 정지 미스텁이라 뚫리면 unimplemented 로 잡힌다.
        await store.send(.screen(.session(.delegate(.finished(.fixture, .fixture)))))
        await store.send(.screen(.session(.delegate(.aborted))))
        await store.send(.screen(.session(.delegate(.interrupted))))
        #expect(enqueued.value == [false])   // 재접수 없음
        await store.send(.cellularUploadAlert(.presented(.userTappedWaitForWiFi))) {
            $0.cellularUploadAlert = nil
            $0.isAwaitingCellularConsent = false
        }
        await store.receive(\.delegate.finished)
        await store.finish()
    }
}

// MARK: - 픽스처

private extension RecordingRef {
    /// 세션이 넘기는 녹화 산출물 — 코디네이터는 내용을 보지 않고 정책과 함께 큐에 전달만 한다.
    static let fixture = RecordingRef(
        sessionId: 1, fileURL: URL(fileURLWithPath: "/tmp/interview-1.mp4"), durationSeconds: 600
    )
}

private extension InterviewVideoWrapUpSpan {
    static let fixture = InterviewVideoWrapUpSpan(wrapUpStartSec: 500, wrapUpEndSec: 512)
}
