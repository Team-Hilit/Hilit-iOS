//
//  InterviewVideoUploadQueueLive.swift
//  DomainInterviewImplementation
//
//  Created by 서정원 on 26/08/06.
//

import ComposableArchitecture
import CoreNetworkInterface
import DomainInterviewInterface
import Foundation
import Network
import OSLog

extension InterviewVideoUploadQueue: @retroactive DependencyKey {
    public static var liveValue: InterviewVideoUploadQueue {
        // 저널·background 세션 구독이 프로세스 전역 1개여야 해 actor 를 static 으로 공유한다 —
        // AppDelegate(wake)·AppFeature(시작)·코디네이터(enqueue)가 같은 큐를 본다.
        InterviewVideoUploadQueue(
            enqueue: {
                await VideoUploadQueueActor.shared.enqueue(sessionId: $0, fileURL: $1, wrapUp: $2, allowsCellular: $3)
            },
            resumePending: { await VideoUploadQueueActor.shared.resumePending() },
            allowCellular: { await VideoUploadQueueActor.shared.allowCellular(sessionId: $0) },
            isOnCellular: { await currentPathIsExpensive() }
        )
    }
}

/// 현재 망 경로 1회 조회 — 모니터를 띄워 첫 경로만 받고 바로 닫는다. «expensive» = 셀룰러·개인 핫스팟
/// (PUT 의 `allowsExpensiveNetworkAccess` 와 같은 기준이라 «물었는데 실제론 Wi-Fi 였다» 가 없다).
/// 첫 콜백이 1초 안에 안 오면 false(= 묻지 않고 기본 정책) — 종료 흐름(로딩 모달)을 붙잡지 않는다.
private func currentPathIsExpensive() async -> Bool {
    let queue = DispatchQueue(label: "com.hilit.upload.path-check")
    return await withCheckedContinuation { continuation in
        let monitor = NWPathMonitor()
        let resumed = LockIsolated(false)
        // 한 번만 끝낸다 — 콜백과 타임아웃 중 먼저 온 쪽. 핸들러를 비워 모니터↔클로저 순환 참조도 끊는다.
        let finish: @Sendable (Bool) -> Void = { isExpensive in
            let first = resumed.withValue { done -> Bool in
                defer { done = true }
                return !done
            }
            guard first else { return }
            monitor.pathUpdateHandler = nil
            monitor.cancel()
            continuation.resume(returning: isExpensive)
        }
        monitor.pathUpdateHandler = { path in finish(path.status == .satisfied && path.isExpensive) }
        monitor.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 1) { finish(false) }
    }
}

/// 업로드 큐 본체 — 저널(JSON)·파일 이동·시도 오케스트레이션을 한 actor 가 직렬화한다(스펙 ⑤).
/// 의존은 init 주입(@Dependency 아님) — 테스트가 스텁 한 벌로 계약을 검증한다.
actor VideoUploadQueueActor {
    static let shared: VideoUploadQueueActor = {
        @Dependency(\.backgroundTransferClient) var transfer
        @Dependency(\.interviewClient) var interview
        return VideoUploadQueueActor(
            directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("InterviewUploads", isDirectory: true),
            interview: interview,
            transfer: transfer,
            now: { Date() }
        )
    }()

    /// 저널 한 항목 — 단계 2단: pending(발급·PUT 전) / completing(PUT 완료, complete 미확정).
    /// `InterviewVideoWrapUpSpan` 은 Encodable 전용이라 초 2개로 평탄화해 보관한다.
    struct JournalEntry: Codable, Equatable {
        enum Stage: String, Codable { case completing, pending }
        let sessionId: Int
        var stage: Stage
        let wrapUpStartSec: Double?
        let wrapUpEndSec: Double?
        let createdAt: Date
        /// 모바일 데이터로 PUT 해도 되는가(HLT-87) — 사용자가 확인 모달에서 허락한 업로드만 true.
        var allowsCellular: Bool

        init(
            sessionId: Int,
            stage: Stage,
            wrapUpStartSec: Double?,
            wrapUpEndSec: Double?,
            createdAt: Date,
            allowsCellular: Bool
        ) {
            self.sessionId = sessionId
            self.stage = stage
            self.wrapUpStartSec = wrapUpStartSec
            self.wrapUpEndSec = wrapUpEndSec
            self.createdAt = createdAt
            self.allowsCellular = allowsCellular
        }

        /// 정책 도입 전 저널엔 키가 없다 — 그때 접수된 업로드는 망 제한 없이 시작됐으니 **true** 로 이어 간다
        /// (false 로 읽으면 업데이트 직후 셀룰러에서 진행 중이던 업로드가 말없이 멈춘다).
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                sessionId: try container.decode(Int.self, forKey: .sessionId),
                stage: try container.decode(Stage.self, forKey: .stage),
                wrapUpStartSec: try container.decodeIfPresent(Double.self, forKey: .wrapUpStartSec),
                wrapUpEndSec: try container.decodeIfPresent(Double.self, forKey: .wrapUpEndSec),
                createdAt: try container.decode(Date.self, forKey: .createdAt),
                allowsCellular: try container.decodeIfPresent(Bool.self, forKey: .allowsCellular) ?? true
            )
        }
    }

    /// 만료 — 이 나이를 넘긴 항목은 폐기한다(72시간, 스펙 «결정 요약» — 영상 없는 리포트가 1급 폴백).
    static let maxAge: TimeInterval = 72 * 60 * 60
    static let logger = Logger(subsystem: "DomainInterview", category: "VideoUploadQueue")

    private let directory: URL
    private let interview: InterviewClient
    private let now: @Sendable () -> Date
    private let transfer: BackgroundTransferClient

    private var attemptsInFlight: Set<Int> = []
    private var hasLoadedJournal = false
    /// «시도 실패 시 즉시 1회 재시도» 소진 표시 — resumePending 이 초기화한다(실행 시점마다 1회 계약).
    private var immediateRetryUsed: Set<Int> = []
    private var journal: [JournalEntry] = []
    private var listenTask: Task<Void, Never>?
    /// `awaitQuiescence()` 대기자 — 마지막 시도가 끝날 때 한꺼번에 깨운다(폴링 대신).
    private var quiescenceWaiters: [CheckedContinuation<Void, Never>] = []
    /// 예약만 되고 아직 actor 에 진입하지 않은 즉시 재시도 — 잠잠함 판정이 이 «틈» 을 같이 세지 않으면
    /// finishAttempt 가 재시도 직전에 대기자를 깨워 `resumePending()` 이 조기 반환한다(assertion 헛돎).
    private var retriesScheduled: Set<Int> = []

    init(
        directory: URL,
        interview: InterviewClient,
        transfer: BackgroundTransferClient,
        now: @escaping @Sendable () -> Date
    ) {
        self.directory = directory
        self.interview = interview
        self.transfer = transfer
        self.now = now
    }

    func enqueue(sessionId: Int, fileURL: URL, wrapUp: InterviewVideoWrapUpSpan?, allowsCellular: Bool) async {
        loadJournalIfNeeded()
        ensureListening()
        // dedup — 코디네이터의 늦은 중복 finished 가 업로드를 재시작하지 못한다(스펙 ①).
        guard !journal.contains(where: { $0.sessionId == sessionId }) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var stored = storedFileURL(sessionId)
            try? FileManager.default.removeItem(at: stored)
            try FileManager.default.moveItem(at: fileURL, to: stored)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true   // 임시 산출물 — iCloud 백업 제외
            try? stored.setResourceValues(values)
        } catch {
            // 파일을 못 가져오면 접수 자체를 포기 — 리포트는 영상 없이 유효(스펙 ⑥).
            Self.logger.error("업로드 접수 실패(파일 이동): \(String(describing: error))")
            return
        }
        journal.append(JournalEntry(
            sessionId: sessionId,
            stage: .pending,
            wrapUpStartSec: wrapUp?.wrapUpStartSec,
            wrapUpEndSec: wrapUp?.wrapUpEndSec,
            createdAt: now(),
            allowsCellular: allowsCellular
        ))
        persistJournal()
        // 전송은 뒤에서 — enqueue 는 여기서 끝난다(코디네이터가 홈 전환 전에 await 하는 범위).
        Task { await self.attempt(sessionId) }
    }

    /// 재개는 **시도가 잦아들 때까지 반환하지 않는다** — 백그라운드 wake 호출부(`AppDelegate`)가 이 await 를
    /// background task assertion 으로 감싸 `completeVideoUpload` 가 앱 정지 전에 마쳐지게 하려는 것이다.
    /// 뿌리고 곧장 반환하면 감쌀 구간이 없어 assertion 이 헛돈다.
    func resumePending() async {
        loadJournalIfNeeded()
        ensureListening()
        immediateRetryUsed.removeAll()
        await purgeExpired()
        purgeOrphanFiles()
        let inFlightIds = await transfer.reattach()
        await withTaskGroup(of: Void.self) { group in
            for entry in journal {
                // PUT 이 데몬에서 아직 살아 있으면 재등록하지 않는다 — 완료 이벤트가 잇는다.
                if entry.stage == .pending, inFlightIds.contains(String(entry.sessionId)) { continue }
                group.addTask { await self.attempt(entry.sessionId) }
            }
        }
        // 완료 이벤트가 몰고 온 시도(스트림발 complete)는 이 그룹 밖이라 위 시도가 in-flight 가드에 걸려
        // 곧장 반환한다 — 그쪽이 끝날 때까지 한 번 더 기다려야 assertion 이 complete 를 실제로 덮는다.
        await awaitQuiescence()
    }

    /// 테스트 전용 스냅샷 — 후행 Task 의 저널 반영을 결정적으로 관찰한다.
    func entriesSnapshot() -> [JournalEntry] {
        loadJournalIfNeeded()
        return journal
    }

    // MARK: - 시도

    /// 모바일 데이터 허용으로 올린다(HLT-87) — 저널을 먼저 고쳐 진행 중인 시도도 새 정책으로 등록하게 하고,
    /// 이미 Wi-Fi 를 기다리며 등록된 PUT 은 취소한 뒤 다시 시도한다. complete 단계면 PUT 이 끝났으니 할 일이 없다.
    func allowCellular(sessionId: Int) async {
        loadJournalIfNeeded()
        guard let index = journal.firstIndex(where: { $0.sessionId == sessionId }),
              !journal[index].allowsCellular
        else { return }
        journal[index].allowsCellular = true
        persistJournal()
        guard journal[index].stage == .pending else { return }
        await transfer.cancel(String(sessionId))
        // 시도가 진행 중(발급 대기)이면 그 시도가 고친 저널을 읽어 새 정책으로 등록한다 — 여기선 비켜 간다.
        await attempt(sessionId)
    }

    private func attempt(_ sessionId: Int) async {
        guard !attemptsInFlight.contains(sessionId),
              let entry = journal.first(where: { $0.sessionId == sessionId })
        else { return }
        attemptsInFlight.insert(sessionId)
        defer { finishAttempt(sessionId) }
        do {
            switch entry.stage {
            case .pending:
                let target = try await interview.videoUploadURL(sessionId)
                guard let url = URL(string: target.uploadUrl) else { throw NetworkError.invalidURL }
                // 정책은 등록 직전에 저널에서 다시 읽는다 — 발급 대기 중 `allowCellular` 가 올렸을 수 있다.
                let allowsCellular = journal.first { $0.sessionId == sessionId }?.allowsCellular ?? entry.allowsCellular
                try await transfer.enqueuePut(
                    String(sessionId), url, target.contentType, storedFileURL(sessionId), allowsCellular
                )
                // 여기서 끝 — PUT 완료·실패는 completions 스트림이 잇는다(등록 프로세스가 죽어도 도착).
            case .completing:
                try await completeAndCleanUp(entry)
            }
        } catch {
            Self.logger.error("업로드 시도 실패(session \(sessionId)): \(String(describing: error))")
            retryOnceOrPark(sessionId)
        }
    }

    /// 진행 중·예약된 시도가 모두 끝날 때까지 기다린다 — 시도를 어디서 띄웠든(재개·스트림·재시도) 두 집합
    /// 중 하나를 지나므로 이 둘이 «큐가 잠잠해졌다» 의 정의다. 등록 시점에 이미 비어 있으면 곧장 반환한다.
    private func awaitQuiescence() async {
        guard !attemptsInFlight.isEmpty || !retriesScheduled.isEmpty else { return }
        await withCheckedContinuation { quiescenceWaiters.append($0) }
    }

    /// 시도 종료 기록 — 마지막 하나가 빠질 때만 대기자를 깨운다.
    private func finishAttempt(_ sessionId: Int) {
        attemptsInFlight.remove(sessionId)
        wakeWaitersIfQuiescent()
    }

    /// 잠잠함 판정·통보 — 진행 중 시도와 예약된 재시도가 «둘 다» 비어야 대기자를 깨운다.
    private func wakeWaitersIfQuiescent() {
        guard attemptsInFlight.isEmpty, retriesScheduled.isEmpty, !quiescenceWaiters.isEmpty else { return }
        let waiters = quiescenceWaiters
        quiescenceWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// 이벤트 스트림 단일 구독 — enqueue·resume 어느 쪽이 먼저 오든 1회만 시작한다.
    private func ensureListening() {
        guard listenTask == nil else { return }
        listenTask = Task { [transfer] in
            for await completion in transfer.completions() {
                await self.handle(completion)
            }
        }
    }

    private func handle(_ completion: BackgroundTransferCompletion) async {
        switch completion {
        case let .completed(id):
            guard let sessionId = Int(id),
                  let index = journal.firstIndex(where: { $0.sessionId == sessionId })
            else { return }
            journal[index].stage = .completing
            persistJournal()   // complete 전에 승격을 기록 — 여기서 죽어도 재개가 PUT 을 반복하지 않는다
            await attempt(sessionId)
        case let .failed(id, error):
            Self.logger.error("PUT 실패(\(id)): \(String(describing: error))")
            guard let sessionId = Int(id) else { return }
            retryOnceOrPark(sessionId)
        }
    }

    private func completeAndCleanUp(_ entry: JournalEntry) async throws {
        let wrapUp = entry.wrapUpStartSec.flatMap { start in
            entry.wrapUpEndSec.map { InterviewVideoWrapUpSpan(wrapUpStartSec: start, wrapUpEndSec: $0) }
        }
        try await interview.completeVideoUpload(entry.sessionId, wrapUp)
        journal.removeAll { $0.sessionId == entry.sessionId }
        persistJournal()
        try? FileManager.default.removeItem(at: storedFileURL(entry.sessionId))
        Self.logger.notice("업로드 완주(session \(entry.sessionId))")
    }

    /// 즉시 1회 재시도 → 소진 시 파킹(다음 resumePending 이 잇는다) — 기존 1+1 정책의 계승(스펙 «결정 요약»).
    private func retryOnceOrPark(_ sessionId: Int) {
        guard !immediateRetryUsed.contains(sessionId) else { return }
        immediateRetryUsed.insert(sessionId)
        // Task 가 actor 에 진입하기 전에 예약부터 기록한다 — 호출부(attempt)의 defer(finishAttempt)가
        // 이 직후에 돌아, 예약이 없으면 그 판정이 마지막 시도로 보고 대기자를 깨워 버린다.
        retriesScheduled.insert(sessionId)
        Task { await self.performScheduledRetry(sessionId) }
    }

    /// 예약된 재시도의 본체 — 예약 해제와 시도 등록(attempt 의 insert) 사이에 suspension 이 없어(동일 actor
    /// 동기 구간) 잠잠함 판정은 이 재시도를 두 집합 중 하나에서 반드시 본다.
    private func performScheduledRetry(_ sessionId: Int) async {
        retriesScheduled.remove(sessionId)
        await attempt(sessionId)
        // attempt 가 가드(중복 시도·항목 소멸)로 비켜가면 finishAttempt 를 안 지난다 — 판정을 여기서 한 번 더.
        wakeWaitersIfQuiescent()
    }

    // MARK: - 저널·파일

    private var journalURL: URL { directory.appendingPathComponent("journal.json") }

    private func storedFileURL(_ sessionId: Int) -> URL {
        directory.appendingPathComponent("\(sessionId).mp4")
    }

    private func loadJournalIfNeeded() {
        guard !hasLoadedJournal else { return }
        hasLoadedJournal = true
        guard let data = try? Data(contentsOf: journalURL) else { return }
        journal = (try? JSONDecoder().decode([JournalEntry].self, from: data)) ?? []
    }

    private func persistJournal() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
        } catch {
            Self.logger.error("저널 기록 실패: \(String(describing: error))")
        }
    }

    private func purgeExpired() async {
        let cutoff = now().addingTimeInterval(-Self.maxAge)
        let expired = journal.filter { $0.createdAt < cutoff }
        guard !expired.isEmpty else { return }
        for entry in expired {
            // Wi-Fi 를 기다리며 남은 PUT 도 걷는다 — 두면 파일이 지워진 뒤 데몬에 유령 태스크만 남는다(HLT-87).
            await transfer.cancel(String(entry.sessionId))
            try? FileManager.default.removeItem(at: storedFileURL(entry.sessionId))
            Self.logger.notice("만료 폐기(session \(entry.sessionId)) — 72시간 초과")
        }
        journal.removeAll { entry in expired.contains { $0.sessionId == entry.sessionId } }
        persistJournal()
    }

    /// 저널에 대응 항목이 없는 mp4 폐기 — `completeAndCleanUp` 이 저널 제거와 파일 삭제 사이에서 죽으면
    /// 파일만 남아 영구 누수가 된다. **저널을 읽고 만료 폐기까지 끝난 뒤에만** 부를 것: 먼저 돌면
    /// 아직 못 읽은 저널을 «비었다» 로 보고 진행 중 항목의 산출물까지 지운다.
    private func purgeOrphanFiles() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        let known = Set(journal.map { storedFileURL($0.sessionId).lastPathComponent })
        for file in files where file.pathExtension == "mp4" && !known.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
            Self.logger.notice("고아 파일 폐기(\(file.lastPathComponent)) — 저널에 대응 항목 없음")
        }
    }
}
