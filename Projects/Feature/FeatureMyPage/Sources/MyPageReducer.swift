//
//  MyPageReducer.swift
//  FeatureMyPage
//
//  Created by 서정원 on 26/08/08.
//

import ComposableArchitecture
import DomainPortfolioInterface
import Foundation

// @lat: [[mypage#흐름]]
// MyPageFeature 의 리듀서 본문 — 타입 선언(Feature 파일)과 분리한 별도 파일.
// 업로드 이식으로 한 파일이 length 에러 임계를 넘어, GuestFeedbackReducer 선례대로 갈랐다.
// body 가 부르는 reduceView·reduceInner·fetchEntry 만 internal, 나머지 헬퍼는 private.
extension MyPageFeature {
    /// 진입 조회 취소 id — 재진입·재시도·삭제 후 재조회가 겹치면 늦게 끝난 쪽이 상태를 덮고,
    /// 앞선 fetch 의 지연된 실패가 닫힌 알럿을 되살린다. 앞 요청을 접어 막는다.
    /// upload 는 등록·폴링 한 줄기 — 새 파일을 고르거나 X(취소)를 누르면 앞 줄기를 접는다.
    enum CancelID { case entry, upload }

    /// 업로드 상한 20MB — Figma «최대 20MB, 30쪽 이내의 PDF 파일 1개만 가능합니다» · 서버 검증 FILE_TOO_LARGE.
    static let maxFileSizeBytes = 20 * 1024 * 1024
    /// 페이지 상한 30p — PRD S2 · 서버 검증 PAGE_COUNT_EXCEEDED. 클라 선검증(서버 실측 재검증).
    static let maxPageCount = 30
    /// 처리 상태 폴링 주기 — PortfolioClient 가이드(3~5초)의 하한.
    static let pollInterval: Duration = .seconds(3)
    /// register 요청이 떠 있는 동안의 채움 — 0 이 아니라 «시작은 됐다» 로 읽히게 한다(온보딩과 같은 값).
    static let registeringProgress: Double = 0.3
    /// 접수 후 status 폴링 구간의 채움 — 한 칸 나아갔지만 아직 안 끝났음을 보인다.
    static let pollingProgress: Double = 0.7

    // MARK: - view

    func reduceView(_ state: inout State, _ action: Action.View) -> Effect<Action> {
        switch action {
        case .binding:
            return .none

        case .onAppear:
            return fetchEntry()

        case .userTappedClose:
            return .send(.delegate(.closeRequested))

        case .userTappedEditProfile:
            // 프로필 수정 화면 시안이 Part5 에 없다 — 생기면 delegate 를 연다.
            return .none

        case .userTappedTicketInfo:
            // 티켓 안내 툴팁 시안이 Part5 에 없다.
            return .none

        case .userTappedLogout:
            // 실패 취급 없음 — AuthClient.logout 은 defer 로 서버 결과와 무관하게 로컬 토큰을 지운다.
            return .run { send in
                try? await authClient.logout()
                await send(.delegate(.loggedOut))
            }

        case .userTappedWithdraw:
            // 진행 중 면접이 참조하는 데이터가 도중에 사라지는 상황 차단(PRD 수용 기준 12).
            if state.isInterviewInProgress {
                state.alert = .plain(message: "면접이 진행 중이에요. 면접이 끝나면 다시 시도해주세요.")
            } else {
                state.alert = .withdrawConfirm
            }
            return .none

        // 포폴 칸 한 덩어리 — 업로드·교체·삭제와 그 모달은 서로 물려 있어 한 함수에서 읽는다.
        case .userTappedUploadPortfolio, .fileSelected, .fileSelectionFailed,
             .userTappedCancelUpload, .userTappedPortfolioFile, .userTappedRemovePortfolio,
             .userTappedPortfolioTooltip, .userTappedModalCancel, .userTappedModalConfirm:
            return reducePortfolio(&state, action)

        case let .userTappedReport(id):
            // 재탭이면 그 행만 접는다 — 다른 행은 건드리지 않는다(여러 리포트를 펼쳐 두고 비교한다).
            if state.expandedReportIDs.contains(id) {
                state.expandedReportIDs.remove(id)
            } else {
                state.expandedReportIDs.insert(id)
            }
            return .none

        case let .userTappedOpenReport(id):
            return .send(.delegate(.reportRequested(id: id)))

        case let .userTappedRequestFeedback(id):
            return .send(.delegate(.feedbackRequested(id: id)))
        }
    }

    /// «내 포트폴리오» 칸 — 업로드·교체·삭제와 그 모달. 나머지 View 액션은 reduceView 가 처리한다.
    private func reducePortfolio(_ state: inout State, _ action: Action.View) -> Effect<Action> {
        switch action {
        case .userTappedUploadPortfolio:
            return reduceUploadRequest(&state)

        case let .fileSelected(url):
            return reduceFileSelected(&state, url)

        case .fileSelectionFailed:
            // 피커 자체 실패(파일 접근 불가 등) — 아직 어떤 전이도 없던 시점이라 이전 판(빈 판·실패 판·등록 판)을 그대로 보존한다.
            return .none

        case .userTappedCancelUpload:
            // 서버 접수분이 있으면 지운다 — 로컬만 비우면 다음 재조회 때 PROCESSING 이 되살아난다.
            let serverID = state.uploadServerID
            state.uploadServerID = nil
            state.portfolio = .empty
            return .merge(
                .cancel(id: CancelID.upload),
                .run { send in
                    if let serverID {
                        _ = try? await portfolioClient.delete(serverID)
                    }
                    await send(.inner(.entryRefetchRequested))
                }
            )

        case .userTappedPortfolioFile:
            // 등록된 판에서만 연다 — presigned URL 은 READY 상태에서만 발급된다(서버 스펙).
            // 발급값은 10분짜리라 State 에 캐시하지 않고 탭할 때마다 새로 받는다.
            guard case let .registered(file) = state.portfolio else { return .none }
            return .run { send in
                let issued = try await portfolioClient.fileURL(file.id)
                await send(.inner(.portfolioFileURLLoaded(issued.fileUrl)))
            } catch: { _, send in
                await send(.inner(.portfolioFileURLFailed))
            }

        case .userTappedRemovePortfolio:
            // 면접 중에는 지울 수 없다(PRD — 삭제 차단 사유는 이것뿐). 안내줄은 재업로드 가능 여부 고지.
            if state.isInterviewInProgress {
                state.presentedModal = .deleteBlocked(canReupload: state.replaceAvailable)
            } else {
                state.presentedModal = .deleteConfirm(canReupload: state.replaceAvailable)
            }
            return .none

        case .userTappedPortfolioTooltip:
            state.isPortfolioTooltipPresented = false
            return .none

        case .userTappedModalCancel:
            state.presentedModal = nil
            return .none

        case .userTappedModalConfirm:
            return reduceModalConfirm(&state)

        // 라우팅(reduceView)과 처리 목록이 갈라져 있어 default 를 두면 신규 케이스 누락을 컴파일러가 못 잡는다 —
        // reduceView 가 여기로 넘기지 않는 케이스를 전부 적어 양쪽 switch 를 망라로 유지한다.
        case .binding, .onAppear, .userTappedClose, .userTappedEditProfile, .userTappedTicketInfo,
             .userTappedLogout, .userTappedWithdraw, .userTappedReport, .userTappedOpenReport,
             .userTappedRequestFeedback:
            return .none
        }
    }

    /// 업로드 버튼 — 이미 등록된 포트폴리오가 있으면 «교체»라 한 달 한 번 규칙을 먼저 묻는다.
    private func reduceUploadRequest(_ state: inout State) -> Effect<Action> {
        guard case .registered = state.portfolio else {
            state.isFilePickerPresented = true
            return .none
        }
        state.presentedModal = state.replaceAvailable
            ? .replaceConfirm(remaining: 1)
            : .replaceBlocked(remaining: 0)
        return .none
    }

    /// 모달 오른쪽 버튼. 삭제는 서버로 나가고, 교체는 파일 선택기를 연다.
    private func reduceModalConfirm(_ state: inout State) -> Effect<Action> {
        let modal = state.presentedModal
        state.presentedModal = nil
        switch modal {
        case .deleteConfirm:
            // 낙관 갱신 없음 — 성공 시 전체 재조회가 포폴 칸·가용성·리포트 «삭제된 포트폴리오» 를 함께 맞춘다.
            guard case let .registered(file) = state.portfolio else { return .none }
            return .run { send in
                _ = try await portfolioClient.delete(file.id)
                await send(.inner(.portfolioDeleted))
            } catch: { _, send in
                await send(.inner(.portfolioDeleteFailed))
            }
        case .replaceConfirm:
            state.isFilePickerPresented = true
            return .none
        case .deleteBlocked, .replaceBlocked, .loading, .none:
            return .none
        }
    }

    /// 고른 PDF 한 개 — 클라 선검증 → (교체면) 기존 삭제 → 등록. 선검증은 UX 용 빠른 차단이고
    /// 최종 판정은 서버 실측 재검증이다(글자 수·암호 최종 판별은 서버).
    private func reduceFileSelected(_ state: inout State, _ url: URL) -> Effect<Action> {
        let fileName = url.lastPathComponent
        // 교체 대상 — 계정당 1개 제한(PORTFOLIO_ALREADY_EXISTS)이라 새 파일 확정 후에 지운다(피커 취소 시 기존 무손상).
        let replacingID: UUID? = {
            switch state.portfolio {
            case let .registered(file): return file.id
            // 실패 판 재시도 — 서버엔 앞 판이 그대로 남아 있을 수 있다(점유 id 우선, 없으면 표시 id).
            case let .failed(file): return state.uploadServerID ?? file.id
            case .empty, .uploaded, .uploading: return state.uploadServerID
            }
        }()
        // 점유 후보를 그대로 들고 간다 — 삭제·등록이 도중에 실패해 실패 판으로 닫혀도, 다음 재시도가 이 id 로
        // 정리 삭제를 선행해 PORTFOLIO_ALREADY_EXISTS 409 루프에 빠지지 않는다(접수되면 새 id 로 갈린다).
        state.uploadServerID = replacingID
        state.portfolio = .uploading(.init(id: uuid(), name: fileName), progress: Self.registeringProgress)
        // 진행 중 진입 조회를 함께 끊는다 — 취소 직후 재선택 같은 경합에서 늦게 도착한 entryLoaded 가 갓 시작한
        // `.uploading` 을 덮으면, 뒤이은 uploadAccepted 가 가드에 막혀 판이 멈춘 듯 보인다.
        // 업로드는 완료 시 fetchEntry() 로 다시 조회하므로 진행 중 조회를 죽여도 잃는 게 없다.
        return .merge(
            .cancel(id: CancelID.entry),
            .run { send in
                let file = try await fileReader.read(url)
                guard file.data.count <= Self.maxFileSizeBytes else {
                    return await send(.inner(.uploadFailed))
                }
                guard !file.isEncrypted else {
                    return await send(.inner(.uploadFailed))
                }
                if let pageCount = file.pageCount, pageCount > Self.maxPageCount {
                    return await send(.inner(.uploadFailed))
                }
                if let replacingID {
                    // 404 는 무해 — 로컬 uuid 폴백이거나 이미 지워진 id 여도 그대로 등록으로 나아간다.
                    _ = try? await portfolioClient.delete(replacingID)
                }
                let upload = PortfolioUpload(
                    fileName: fileName,
                    fileSize: file.data.count,
                    pageCount: file.pageCount,
                    data: file.data
                )
                await send(.inner(.uploadAccepted(try await portfolioClient.register(upload))))
            } catch: { _, send in
                await send(.inner(.uploadFailed))
            }
            .cancellable(id: CancelID.upload, cancelInFlight: true)
        )
    }

    // MARK: - inner

    func reduceInner(_ state: inout State, _ action: Action.Inner) -> Effect<Action> {
        switch action {
        case .entryFailed:
            state.alert = .entryFailed
            return .none

        case let .entryLoaded(profile, list, reports):
            state.profile = .init(profile: profile)
            state.portfolio = .init(list: list)
            state.replaceAvailable = list.replaceAvailable ?? true
            state.isInterviewInProgress = list.portfolios.first?.interviewInProgress ?? false
            state.reports = IdentifiedArray(uniqueElements: reports.compactMap(Report.init(summary:)))
            // 재조회로 사라진 세션의 펼침만 버린다 — 남은 펼침은 그대로 둔다(깜빡임 방지, 홈과 같은 규칙).
            state.expandedReportIDs.formIntersection(state.reports.ids)
            guard case let .uploading(file, _) = state.portfolio else {
                // 업로드 아닌 판으로 확정 — 남은 접수 id 를 지운다(다음 취소가 남의 포폴을 지우면 안 된다).
                state.uploadServerID = nil
                return .none
            }
            // 타 화면 업로드 직후 진입 — 서버 PROCESSING 을 이어서 폴링해 완료를 따라잡는다.
            state.uploadServerID = file.id
            return pollUploadStatus(file.id)

        case .entryRefetchRequested:
            // 새 업로드가 화면을 소유했으면 늦은 재조회를 버린다 — 완료 시 스스로 전체 재조회한다
            // (applyUploadProcessing 과 같은 철학).
            guard case .uploading = state.portfolio else { return fetchEntry() }
            return .none

        case .portfolioFileURLFailed:
            state.alert = .plain(message: "포트폴리오를 여는 데 실패했어요. 잠시 후 다시 시도해 주세요.")
            return .none

        case let .portfolioFileURLLoaded(url):
            state.portfolioPreview = .init(url: url)
            return .none

        case .portfolioDeleteFailed:
            state.alert = .plain(message: "잠시 후 다시 시도해 주세요.")
            return .none

        case .portfolioDeleted:
            return fetchEntry()

        case let .uploadAccepted(processing), let .uploadStatusPolled(processing):
            return applyUploadProcessing(&state, processing)

        case .uploadFailed:
            guard case let .uploading(file, _) = state.portfolio else { return .none }
            state.portfolio = .failed(file)
            state.isPortfolioTooltipPresented = true
            return .none

        case .withdrawFailed:
            state.alert = .plain(message: "잠시 후 다시 시도해 주세요.")
            return .none
        }
    }

    /// 등록·폴링 공통 응답 반영 — PROCESSING 이면 폴링을 잇고, READY 는 전체 재조회로 판·가용성을 함께 맞춘다.
    private func applyUploadProcessing(_ state: inout State, _ processing: PortfolioProcessing) -> Effect<Action> {
        // X(취소) 등으로 업로드 흐름이 이미 끊겼으면 늦게 도착한 응답을 무시한다(온보딩과 같은 가드).
        guard case let .uploading(file, _) = state.portfolio else { return .none }
        state.uploadServerID = processing.portfolioId

        switch processing.status {
        case .processing:
            state.portfolio = .uploading(file, progress: Self.pollingProgress)
            return pollUploadStatus(processing.portfolioId)

        case .ready:
            // 교체 카운터 소진·가용성은 서버가 안다 — 낙관 전이 대신 전체 재조회(삭제와 같은 정합 논리).
            return fetchEntry()

        case .failedFile, .failedSystem, .cancelled:
            state.portfolio = .failed(file)
            state.isPortfolioTooltipPresented = true
            return .none
        }
    }

    // MARK: - effects

    /// 처리 상태 폴링 한 바퀴 — 등록 응답(PROCESSING)과 조회로 이어받은 PROCESSING 이 같은 줄기를 탄다.
    /// 한 줄기(CancelID.upload)라 새 폴링·취소가 앞 폴링을 접는다.
    private func pollUploadStatus(_ portfolioID: UUID) -> Effect<Action> {
        .run { send in
            try await clock.sleep(for: Self.pollInterval)
            await send(.inner(.uploadStatusPolled(try await portfolioClient.status(portfolioID))))
        } catch: { _, send in
            await send(.inner(.uploadFailed))
        }
        .cancellable(id: CancelID.upload, cancelInFlight: true)
    }

    /// 진입 조회 — 3콜 병렬, 부분 성공 없음. 재시도·삭제·업로드 완료 후 재조회가 같은 경로를 탄다.
    func fetchEntry() -> Effect<Action> {
        .run { send in
            async let profile = userClient.profile()
            async let list = portfolioClient.list()
            async let reports = interviewClient.reportList()
            let loadedProfile = try? await profile
            let loadedList = try? await list
            let loadedReports = try? await reports
            guard let loadedProfile, let loadedList, let loadedReports else {
                return await send(.inner(.entryFailed))
            }
            await send(.inner(.entryLoaded(loadedProfile, loadedList, loadedReports)))
        }
        .cancellable(id: CancelID.entry, cancelInFlight: true)
    }
}
