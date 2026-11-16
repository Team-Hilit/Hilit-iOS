//
//  BackgroundTransferClientLive.swift
//  CoreNetworkImplementation
//
//  Created by 서정원 on 26/08/06.
//

import ComposableArchitecture
import CoreNetworkInterface
import Foundation

extension BackgroundTransferClient: @retroactive DependencyKey {
    public static var liveValue: BackgroundTransferClient {
        let session = BackgroundTransferSession.shared
        return BackgroundTransferClient(
            enqueuePut: { try session.enqueuePut(id: $0, url: $1, contentType: $2, fileURL: $3, allowsExpensiveNetwork: $4) },
            cancel: { await session.cancel(id: $0) },
            completions: { session.completions },
            reattach: { await session.reattach() },
            attachBackgroundEventsCompletionHandler: { session.attach(completionHandler: $0) }
        )
    }
}

/// background URLSession 은 식별자당 1개만 존재해야 한다 — 프로세스 전역 싱글턴.
/// 유일성은 `static let shared`(전역 1회 초기화 보장)가 떠받친다 — 세션도 그 init 안에서 딱 한 번 만들어진다.
/// 델리게이트 콜백은 `delegateQueue: nil`(시스템 serial 큐)에서 오고, init 이후 상태 변이는
/// 스트림 continuation(스레드 안전)과 완료 핸들러 슬롯뿐 — 슬롯은 attach(메인)와 이벤트 소진(delegate 큐)이
/// 스레드를 달리해 만나는 유일한 가변 상태라 락으로 좁게 보호한다.
final class BackgroundTransferSession: NSObject, @unchecked Sendable {
    static let shared = BackgroundTransferSession()

    private let stream: AsyncStream<BackgroundTransferCompletion>
    private let continuation: AsyncStream<BackgroundTransferCompletion>.Continuation
    private let backgroundEventsHandlerLock = NSLock()
    private var backgroundEventsCompletionHandler: (@Sendable () -> Void)?
    /// 같은 식별자로 세션을 만들면 nsurlsessiond 에 남아 있던 태스크가 이 delegate 에 다시 붙는다 —
    /// 싱글턴 첫 접근(= 세션 생성)이 곧 재접속이다. `lazy` 로 두면 안 된다: Swift lazy 는 스레드 안전이 아니라
    /// 첫 접근이 겹치면 클로저가 두 번 돌아 같은 식별자의 세션이 2개 생긴다(식별자당 1개 불변식 위반).
    /// IUO 인 이유는 `delegate: self` 를 `super.init()` 이후에만 넘길 수 있어서다 — init 에서 1회 할당 후 불변.
    private var session: URLSession!

    override private init() {
        // 소비자(업로드 큐)가 구독하기 전에 도착하는 wake 이벤트를 잃지 않게 무제한 버퍼.
        (stream, continuation) = AsyncStream.makeStream(
            of: BackgroundTransferCompletion.self, bufferingPolicy: .unbounded
        )
        super.init()
        let configuration = URLSessionConfiguration.background(
            withIdentifier: BackgroundTransferClient.sessionIdentifier
        )
        configuration.sessionSendsLaunchEvents = true   // 앱 종료 후 완료 시 백그라운드 재기동(wake)
        configuration.isDiscretionary = false           // 시스템 재량 지연 금지 — 즉시 전송
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    var completions: AsyncStream<BackgroundTransferCompletion> { stream }

    func enqueuePut(id: String, url: URL, contentType: String, fileURL: URL, allowsExpensiveNetwork: Bool) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw NetworkError.transport(.fileDoesNotExist)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        // 망 정책은 요청 단위다 — 세션 설정은 허용으로 두고(세션은 식별자당 1개라 정책별로 못 가른다) 요청이 좁힌다.
        // «expensive» = 셀룰러·개인 핫스팟 — Android WorkManager 의 UNMETERED 제약과 같은 기준이다(HLT-87).
        request.allowsExpensiveNetworkAccess = allowsExpensiveNetwork
        let task = session.uploadTask(with: request, fromFile: fileURL)
        task.taskDescription = id
        task.resume()
    }

    func cancel(id: String) async {
        for task in await session.allTasks where task.taskDescription == id {
            task.cancel()
        }
    }

    func reattach() async -> [String] {
        await session.allTasks.compactMap { task in
            (task.state == .running || task.state == .suspended) ? task.taskDescription : nil
        }
    }

    func attach(completionHandler: @escaping @Sendable () -> Void) {
        backgroundEventsHandlerLock.lock()
        defer { backgroundEventsHandlerLock.unlock() }
        backgroundEventsCompletionHandler = completionHandler
    }
}

extension BackgroundTransferSession: URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription else { return }
        // 앱이 건 취소(`cancel(id:)` — 정책 변경·만료 폐기)는 실패가 아니다 — 흘리면 큐가 재시도해 취소한 태스크를
        // 되살린다. 강제 종료로 시스템이 취소한 태스크도 여기 걸리지만, 그쪽은 다음 실행의 저널 재개가 잇는다.
        if (error as? URLError)?.code == .cancelled { return }
        if let error {
            continuation.yield(.failed(id: id, .transport((error as? URLError)?.code ?? .unknown)))
            return
        }
        guard let http = task.response as? HTTPURLResponse else {
            continuation.yield(.failed(id: id, .invalidResponse))
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            // background 델리게이트는 응답 바디를 모으지 않는다 — 코드만 싣는다(진단은 코드로 충분).
            continuation.yield(.failed(id: id, .statusCode(http.statusCode, Data())))
            return
        }
        continuation.yield(.completed(id: id))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        backgroundEventsHandlerLock.lock()
        let handler = backgroundEventsCompletionHandler
        backgroundEventsCompletionHandler = nil
        backgroundEventsHandlerLock.unlock()
        DispatchQueue.main.async { handler?() }
    }
}
