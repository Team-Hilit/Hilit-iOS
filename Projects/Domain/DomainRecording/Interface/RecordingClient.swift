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
// 세그먼트·원장은 Application Support 에 영구 보관해 앱이 죽어도 같은 세션을 이어 녹화한다(HLT-78).
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
    public var startRecording: @Sendable (_ sessionId: Int) async throws -> Double
    /// 진행 중 세그먼트의 세션 오디오 기록 경로(보관 폴더) — 녹화 시작 직후 세션 화면이 받아
    /// `SpeechClient.startSessionAudioRecording` 에 넘긴다. 원장이 이 이름을 시작 때부터 알아 앱이 마감 없이 죽어도
    /// 다음 실행이 오디오 짝을 찾는다(HLT-78). 진행 중 녹화가 없으면 nil.
    public var sessionAudioURL: @Sendable () async -> URL?
    /// 현 세그먼트 마감(스펙 ②) — 백그라운드 진입 시 파일을 닫고 세션오디오 쌍과 함께 원장에 올린다.
    /// 반환은 누적 녹화초(진행 중 녹화가 없으면 nil) — held 갱신 재료. 비던짐(실패는 세그먼트 유실 + 로그).
    public var suspendRecording: @Sendable (_ audio: RecordingAudioSegment?) async -> Double?
    /// 녹화 정지 + 원장 전 세그먼트 합성 — 마지막 세그먼트의 오디오 쌍을 받아 마감 후, 세그먼트별
    /// 립싱크 오프셋으로 이어 붙인 단일 mp4 를 만든다. 전 세그먼트 무음이면 throw(무음 영상 금지).
    public var stopRecording: @Sendable (_ finalAudio: RecordingAudioSegment?) async throws -> RecordingRef
    /// 녹화 폐기 — 진행 중이면 정지 후 그 세션 세그먼트 전부 삭제(멱등·비던짐). 이탈·실패 공통 정리.
    public var discardRecording: @Sendable () async -> Void
    /// 그 세션의 보관 파일(세그먼트·오디오·합성본·원장) 제거 — 이 프로세스 원장이 모르는(앞 프로세스가 남긴)
    /// 세션을 끝낼 때. 현재 원장의 세션이면 무시(`discardRecording` 몫) — 전체 삭제로 하면 정리와 새 세션의
    /// 세그먼트 0 이 레이스로 함께 지워질 수 있다. 끝낸 세션 정리는 «discard → purge» 를 짝으로 부른다.
    public var purgeRecordings: @Sendable (_ sessionId: Int) async -> Void
    /// 실행 시점 잔존 정리 — `keeping`(장부의 세션)·현재 원장 세션이 아닌 보관 파일 전부 제거(HLT-78).
    /// 세그먼트가 영구 보관이라 정리 경로가 하나라도 빠지면 쌓이기만 한다 — 그 누수를 실행마다 회수한다.
    public var purgeStaleRecordings: @Sendable (_ keeping: Int?) async -> Void

    public init(
        startPreview: @escaping @Sendable () async -> CameraPreviewHandle?,
        stopPreview: @escaping @Sendable () async -> Void,
        startRecording: @escaping @Sendable (_ sessionId: Int) async throws -> Double,
        sessionAudioURL: @escaping @Sendable () async -> URL?,
        suspendRecording: @escaping @Sendable (_ audio: RecordingAudioSegment?) async -> Double?,
        stopRecording: @escaping @Sendable (_ finalAudio: RecordingAudioSegment?) async throws -> RecordingRef,
        discardRecording: @escaping @Sendable () async -> Void,
        purgeRecordings: @escaping @Sendable (_ sessionId: Int) async -> Void,
        purgeStaleRecordings: @escaping @Sendable (_ keeping: Int?) async -> Void
    ) {
        self.startPreview = startPreview
        self.stopPreview = stopPreview
        self.startRecording = startRecording
        self.sessionAudioURL = sessionAudioURL
        self.suspendRecording = suspendRecording
        self.stopRecording = stopRecording
        self.discardRecording = discardRecording
        self.purgeRecordings = purgeRecordings
        self.purgeStaleRecordings = purgeStaleRecordings
    }
}

extension RecordingClient: TestDependencyKey {
    /// 컨벤션: testValue 는 반드시 unimplemented — 빈 클로저 금지 (스텁 누락을 테스트가 즉시 잡도록).
    public static var testValue: RecordingClient {
        RecordingClient(
            startPreview: unimplemented("RecordingClient.startPreview", placeholder: nil),
            stopPreview: unimplemented("RecordingClient.stopPreview"),
            startRecording: unimplemented("RecordingClient.startRecording", placeholder: 0),
            sessionAudioURL: unimplemented("RecordingClient.sessionAudioURL", placeholder: nil),
            suspendRecording: unimplemented("RecordingClient.suspendRecording", placeholder: nil),
            stopRecording: unimplemented("RecordingClient.stopRecording"),
            discardRecording: unimplemented("RecordingClient.discardRecording"),
            purgeRecordings: unimplemented("RecordingClient.purgeRecordings"),
            purgeStaleRecordings: unimplemented("RecordingClient.purgeStaleRecordings")
        )
    }

    /// Preview 용 — 프리뷰는 nil(placeholder 유지)로 두어 시뮬레이터 프리뷰에서도 화면 흐름만 그린다.
    public static var previewValue: RecordingClient {
        RecordingClient(
            startPreview: { nil },
            stopPreview: {},
            startRecording: { _ in 0 },
            sessionAudioURL: { nil },
            suspendRecording: { _ in nil },
            stopRecording: { _ in
                RecordingRef(sessionId: 0, fileURL: URL(fileURLWithPath: "/dev/null"), durationSeconds: 0)
            },
            discardRecording: {},
            purgeRecordings: { _ in },
            purgeStaleRecordings: { _ in }
        )
    }
}

public extension DependencyValues {
    var recordingClient: RecordingClient {
        get { self[RecordingClient.self] }
        set { self[RecordingClient.self] = newValue }
    }
}
