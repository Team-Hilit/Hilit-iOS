//
//  RecordingClient.swift
//  DomainRecordingInterface
//
//  Created by 서정원 on 26/07/28.
//

import AVFoundation
import ComposableArchitecture

// @lat: [[interview#프리뷰]]
// 전면 카메라 프리뷰 + 비디오 녹화 — 준비·세션 화면이 하나의 캡처 세션을 이어 쓴다.
// 캡처 세션은 «비디오 전용»(A안-2) — 마이크는 답변 오디오 엔진이 단독 소유하고,
// 정지 시점에 세그먼트들과 세션 오디오(m4a)를 사후 합성해 통짜 mp4 를 만든다.
// 소비처: 면접 준비·세션 화면(P0) — docs/work/ai-interview.md §3.
// testValue 는 여기(Interface), liveValue 는 Implementation — App/Example 만 link (D4).

/// AVCaptureSession 을 감싼 프리뷰 핸들 — TCA State 저장용.
/// Equatable 은 참조 identity(===) — 세션 객체가 바뀔 때만 뷰가 갱신된다.
public struct CameraPreviewHandle: Equatable, @unchecked Sendable {
    public let session: AVCaptureSession

    public init(session: AVCaptureSession) {
        self.session = session
    }
}

/// 녹화 산출물 참조 — 정상 종료 시 코디네이터가 업로드 큐에 넘겨 소유권을 이전한다 (2026-08-06 스펙 §①).
public struct RecordingRef: Equatable, Sendable {
    public let sessionId: Int
    public let fileURL: URL
    public let durationSeconds: Double

    public init(sessionId: Int, fileURL: URL, durationSeconds: Double) {
        self.sessionId = sessionId
        self.fileURL = fileURL
        self.durationSeconds = durationSeconds
    }
}

/// 세그먼트 하나에 얹을 세션 오디오 — Speech 의 `SessionAudioRecording` 을 호출부가 풀어 넘긴다
/// (Speech→Recording Interface 의존을 만들지 않는 «풀어 전달» 선례 — [[interview#음성 캡처]]).
public struct RecordingAudioSegment: Equatable, Sendable {
    public let fileURL: URL
    public let startedAtHostSeconds: Double

    public init(fileURL: URL, startedAtHostSeconds: Double) {
        self.fileURL = fileURL
        self.startedAtHostSeconds = startedAtHostSeconds
    }
}

/// 녹화 실패 — 실패해도 면접은 계속된다(영상 없는 리포트, 스펙 §⑥). 사유 문자열은 로그용.
public enum RecordingError: Error, Equatable {
    /// 프리뷰 세션 없음·입출력 추가 실패·기록 시작 실패.
    case startFailed(String)
    /// 진행 중 녹화 없음·기록 종료 실패·산출 파일 없음.
    case stopFailed(String)
}

public struct RecordingClient: Sendable {
    public var startPreview: @Sendable () async -> CameraPreviewHandle?
    public var stopPreview: @Sendable () async -> Void
    /// 녹화 시작 — 새 «세그먼트» 를 연다(재개 경계마다 파일이 갈라진다 — 스펙 ①). 파일 기록이 실제로
    /// 구른 뒤(didStartRecordingTo) 반환하며, 반환값은 **이전까지 누적 녹화초**(첫 세그먼트 0) —
    /// 호출부가 세션 시계 시드로 삼는다.
    ///
    /// `resumingAtSeconds` 는 **재개 지점** — 처음 시작이면 nil, 재개면 held 가 기억하는 진행 길이(초)다.
    /// 원장이 그 지점을 이어받을 수 없으면(앱이 죽어 세그먼트 원장이 사라진 경우) 새 녹화를 열지 않고
    /// `startFailed` 로 던진다 — 호출부는 영상 없이 진행한다(스펙 §⑥). 던지지 않고 열면 앞부분 없는 영상에
    /// 시계만 0 으로 돌아가 서버 마킹과 어긋난다.
    public var startRecording: @Sendable (_ sessionId: Int, _ resumingAtSeconds: Int?) async throws -> Double
    /// 현 세그먼트 마감(스펙 ②) — 백그라운드 진입 시 파일을 닫고 세션오디오 쌍과 함께 원장에 올린다.
    /// 반환은 누적 녹화초(진행 중 녹화가 없으면 nil) — held 갱신 재료. 비던짐(실패는 세그먼트 유실 + 로그).
    public var suspendRecording: @Sendable (_ audio: RecordingAudioSegment?) async -> Double?
    /// 녹화 정지 + 원장 전 세그먼트 합성 — 마지막 세그먼트의 오디오 쌍을 받아 마감 후, 세그먼트별
    /// 립싱크 오프셋으로 이어 붙인 단일 mp4 를 만든다. 전 세그먼트 무음이면 throw(무음 영상 금지).
    public var stopRecording: @Sendable (_ finalAudio: RecordingAudioSegment?) async throws -> RecordingRef
    /// 녹화 폐기 — 진행 중이면 정지 후 그 세션 세그먼트 전부 삭제(멱등·비던짐). 이탈·실패 공통 정리.
    public var discardRecording: @Sendable () async -> Void
    /// 그 세션의 잔존 파일(세그먼트·합성본) 제거 — 앱이 죽어 원장 없이 남은 파일 전용(스펙 ④): 서버가 끝낸 세션의
    /// 보관값을 걷을 때와 이어받지 못할 재개 지점에서 부른다. 현재 진행 중인 세션이면 무시
    /// — 전체 삭제로 하면 클린업과 새 세션의 세그먼트 0 이 레이스로 함께 지워질 수 있다.
    public var purgeRecordings: @Sendable (_ sessionId: Int) async -> Void

    public init(
        startPreview: @escaping @Sendable () async -> CameraPreviewHandle?,
        stopPreview: @escaping @Sendable () async -> Void,
        startRecording: @escaping @Sendable (_ sessionId: Int, _ resumingAtSeconds: Int?) async throws -> Double,
        suspendRecording: @escaping @Sendable (_ audio: RecordingAudioSegment?) async -> Double?,
        stopRecording: @escaping @Sendable (_ finalAudio: RecordingAudioSegment?) async throws -> RecordingRef,
        discardRecording: @escaping @Sendable () async -> Void,
        purgeRecordings: @escaping @Sendable (_ sessionId: Int) async -> Void
    ) {
        self.startPreview = startPreview
        self.stopPreview = stopPreview
        self.startRecording = startRecording
        self.suspendRecording = suspendRecording
        self.stopRecording = stopRecording
        self.discardRecording = discardRecording
        self.purgeRecordings = purgeRecordings
    }
}

extension RecordingClient: TestDependencyKey {
    /// 컨벤션: testValue 는 반드시 unimplemented — 빈 클로저 금지 (스텁 누락을 테스트가 즉시 잡도록).
    public static var testValue: RecordingClient {
        RecordingClient(
            startPreview: unimplemented("RecordingClient.startPreview", placeholder: nil),
            stopPreview: unimplemented("RecordingClient.stopPreview"),
            startRecording: unimplemented("RecordingClient.startRecording", placeholder: 0),
            suspendRecording: unimplemented("RecordingClient.suspendRecording", placeholder: nil),
            stopRecording: unimplemented("RecordingClient.stopRecording"),
            discardRecording: unimplemented("RecordingClient.discardRecording"),
            purgeRecordings: unimplemented("RecordingClient.purgeRecordings")
        )
    }

    /// Preview 용 — 프리뷰는 nil(placeholder 유지)로 두어 시뮬레이터 프리뷰에서도 화면 흐름만 그린다.
    public static var previewValue: RecordingClient {
        RecordingClient(
            startPreview: { nil },
            stopPreview: {},
            startRecording: { _, _ in 0 },
            suspendRecording: { _ in nil },
            stopRecording: { _ in
                RecordingRef(sessionId: 0, fileURL: URL(fileURLWithPath: "/dev/null"), durationSeconds: 0)
            },
            discardRecording: {},
            purgeRecordings: { _ in }
        )
    }
}

public extension DependencyValues {
    var recordingClient: RecordingClient {
        get { self[RecordingClient.self] }
        set { self[RecordingClient.self] = newValue }
    }
}
