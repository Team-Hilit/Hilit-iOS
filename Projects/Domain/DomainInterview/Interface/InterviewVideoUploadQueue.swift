//
//  InterviewVideoUploadQueue.swift
//  DomainInterviewInterface
//
//  Created by 서정원 on 26/08/06.
//

import ComposableArchitecture
import Foundation

// @lat: [[interview#업로드 큐]]
/// 면접 영상 업로드 큐 — 화면·앱 수명과 무관하게 업로드를 완주시키는 유일한 통로(스펙 ⑤).
/// enqueue 가 파일 소유권을 가져가(영구 디렉토리 이동 + 저널 기록) 즉시 반환하고,
/// 실제 전송(발급 → background PUT → complete)은 큐가 뒤에서 진행한다. 진행·결과 UI 는 없다(조용한 업로드).
///
/// **망 정책(HLT-87)**: 기본은 Wi-Fi 등 비과금 망에서만 PUT 한다(A-PRD «UNMETERED», Android 와 동일).
/// 코디네이터는 **먼저 Wi-Fi 정책으로 접수**하고(파일 소유권부터 넘긴다 — 모달 중 앱이 죽어도 영상이 남는다),
/// 셀룰러에서 사용자가 확인 모달로 허락하면 `allowCellular` 로 정책을 올린다.
public struct InterviewVideoUploadQueue: Sendable {
    /// 산출물 접수 — 같은 sessionId 재접수는 무시(dedup). 반환 시점엔 파일 이동·저널 기록까지 끝나
    /// 있다(네트워크 미포함 — 코디네이터가 홈 전환 전에 await 해도 밀리초). `allowsCellular` 는 저널에 남아
    /// 재시도·재실행 재개에도 같은 정책으로 이어진다.
    public var enqueue: @Sendable (
        _ sessionId: Int, _ fileURL: URL, _ wrapUp: InterviewVideoWrapUpSpan?, _ allowsCellular: Bool
    ) async -> Void
    /// 미완 업로드 재개 — 앱 시작·background wake 에 1회. 만료(72시간) 항목 폐기도 여기서 한다.
    public var resumePending: @Sendable () async -> Void
    /// 접수된 업로드를 모바일 데이터 허용으로 올린다 — 저널 갱신 + Wi-Fi 를 기다리던 PUT 을 취소하고 다시 등록.
    /// 이미 PUT 이 끝났거나(complete 단계) 항목이 없으면 아무 일도 없다.
    public var allowCellular: @Sendable (_ sessionId: Int) async -> Void
    /// 지금 과금 망(셀룰러·개인 핫스팟)에 붙어 있는가 — 확인 모달을 띄울지 판단하는 재료.
    /// 오프라인이면 false(물어볼 필요 없이 기본 정책대로 Wi-Fi 를 기다린다).
    public var isOnCellular: @Sendable () async -> Bool

    public init(
        enqueue: @escaping @Sendable (
            _ sessionId: Int, _ fileURL: URL, _ wrapUp: InterviewVideoWrapUpSpan?, _ allowsCellular: Bool
        ) async -> Void,
        resumePending: @escaping @Sendable () async -> Void,
        allowCellular: @escaping @Sendable (_ sessionId: Int) async -> Void,
        isOnCellular: @escaping @Sendable () async -> Bool
    ) {
        self.enqueue = enqueue
        self.resumePending = resumePending
        self.allowCellular = allowCellular
        self.isOnCellular = isOnCellular
    }
}

extension InterviewVideoUploadQueue: TestDependencyKey {
    /// 컨벤션: testValue 는 반드시 unimplemented — 빈 클로저 금지 (스텁 누락을 테스트가 즉시 잡도록).
    public static var testValue: InterviewVideoUploadQueue {
        InterviewVideoUploadQueue(
            enqueue: unimplemented("InterviewVideoUploadQueue.enqueue"),
            resumePending: unimplemented("InterviewVideoUploadQueue.resumePending"),
            allowCellular: unimplemented("InterviewVideoUploadQueue.allowCellular"),
            isOnCellular: unimplemented("InterviewVideoUploadQueue.isOnCellular", placeholder: false)
        )
    }

    /// Preview 용 — 업로드 없이 조용히 통과.
    public static var previewValue: InterviewVideoUploadQueue {
        InterviewVideoUploadQueue(
            enqueue: { _, _, _, _ in }, resumePending: {}, allowCellular: { _ in }, isOnCellular: { false }
        )
    }
}

public extension DependencyValues {
    var interviewVideoUploadQueue: InterviewVideoUploadQueue {
        get { self[InterviewVideoUploadQueue.self] }
        set { self[InterviewVideoUploadQueue.self] = newValue }
    }
}
