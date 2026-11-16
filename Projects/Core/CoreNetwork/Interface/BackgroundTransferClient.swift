//
//  BackgroundTransferClient.swift
//  CoreNetworkInterface
//
//  Created by 서정원 on 26/08/06.
//

import ComposableArchitecture
import Foundation

// @lat: [[domain.map#네트워킹 인프라]]
/// background URLSession presigned PUT — 앱이 백그라운드·시스템 종료로 사라져도 전송이 계속된다.
/// `FileTransferClient`(포그라운드 await 업로드)와 달리 **등록·이벤트 분리**다: `enqueuePut` 은 태스크 등록만
/// 하고, 완료·실패는 `completions` 스트림으로 온다 — 등록한 프로세스가 죽어도 재기동 후 이벤트가 도착한다.
public enum BackgroundTransferCompletion: Equatable, Sendable {
    case completed(id: String)
    case failed(id: String, NetworkError)
}

public struct BackgroundTransferClient: Sendable {
    /// background 세션 식별자 — AppDelegate 의 wake 콜백이 자기 세션인지 판별하는 기준.
    public static let sessionIdentifier = "com.yapp.hilit.interview-video-upload"

    /// presigned PUT 태스크 등록 — `id` 는 호출자의 저널 키(taskDescription 에 새겨 완료 이벤트가 들고 온다).
    /// `contentType` 은 발급 응답 원문(서명 포함 — 다르면 저장소가 거부). 파일이 없으면 즉시 throw.
    /// `allowsExpensiveNetwork` 가 false 면 셀룰러·개인 핫스팟에선 전송하지 않고 Wi-Fi 등 비과금 망을 기다린다
    /// (background 세션은 망이 생길 때까지 태스크를 대기시킨다 — HLT-87).
    public var enqueuePut: @Sendable (
        _ id: String, _ url: URL, _ contentType: String, _ fileURL: URL, _ allowsExpensiveNetwork: Bool
    ) async throws -> Void
    /// 그 id 의 대기·실행 중 태스크 취소 — 망 정책을 바꿔 다시 등록하거나 만료 폐기할 때(HLT-87).
    /// 취소로 끝난 태스크는 `completions` 에 실패로 흘리지 않는다 — 취소한 쪽이 후속을 이미 들고 있다.
    public var cancel: @Sendable (_ id: String) async -> Void
    /// 전송 완료·실패 스트림 — 단일 소비자(업로드 큐) 전제. 구독 전 이벤트는 버퍼링된다.
    public var completions: @Sendable () -> AsyncStream<BackgroundTransferCompletion>
    /// 세션 재접속 — 앱 시작·wake 시. 살아 있는(실행·대기) 태스크의 id 목록을 줘 중복 등록을 막는다.
    public var reattach: @Sendable () async -> [String]
    /// 시스템 wake completionHandler 연결 — 이벤트 소진 시점에 main 에서 호출된다. AppDelegate 전용.
    public var attachBackgroundEventsCompletionHandler: @Sendable (_ handler: @escaping @Sendable () -> Void) -> Void

    public init(
        enqueuePut: @escaping @Sendable (
            _ id: String, _ url: URL, _ contentType: String, _ fileURL: URL, _ allowsExpensiveNetwork: Bool
        ) async throws -> Void,
        cancel: @escaping @Sendable (_ id: String) async -> Void,
        completions: @escaping @Sendable () -> AsyncStream<BackgroundTransferCompletion>,
        reattach: @escaping @Sendable () async -> [String],
        attachBackgroundEventsCompletionHandler: @escaping @Sendable (_ handler: @escaping @Sendable () -> Void) -> Void
    ) {
        self.enqueuePut = enqueuePut
        self.cancel = cancel
        self.completions = completions
        self.reattach = reattach
        self.attachBackgroundEventsCompletionHandler = attachBackgroundEventsCompletionHandler
    }
}

extension BackgroundTransferClient: TestDependencyKey {
    /// 컨벤션: testValue 는 반드시 unimplemented — 빈 클로저 금지 (스텁 누락을 테스트가 즉시 잡도록).
    public static var testValue: BackgroundTransferClient {
        BackgroundTransferClient(
            enqueuePut: unimplemented("BackgroundTransferClient.enqueuePut"),
            cancel: unimplemented("BackgroundTransferClient.cancel"),
            completions: unimplemented(
                "BackgroundTransferClient.completions",
                placeholder: AsyncStream { $0.finish() }
            ),
            reattach: unimplemented("BackgroundTransferClient.reattach", placeholder: []),
            attachBackgroundEventsCompletionHandler: unimplemented("BackgroundTransferClient.attachBackgroundEventsCompletionHandler")
        )
    }

    /// Preview 용 — 전송 없이 조용히 통과.
    public static var previewValue: BackgroundTransferClient {
        BackgroundTransferClient(
            enqueuePut: { _, _, _, _, _ in },
            cancel: { _ in },
            completions: { AsyncStream { $0.finish() } },
            reattach: { [] },
            attachBackgroundEventsCompletionHandler: { _ in }
        )
    }
}

public extension DependencyValues {
    var backgroundTransferClient: BackgroundTransferClient {
        get { self[BackgroundTransferClient.self] }
        set { self[BackgroundTransferClient.self] = newValue }
    }
}
