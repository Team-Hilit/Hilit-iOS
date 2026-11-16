//
//  ReportMainView.swift
//  FeatureReport
//
//  Created by EunSeo on 26/07/25.
//

// Figma: «Report_Main_Default» https://figma.com/design/JL9YPbqBqmaC9Z0I3SzDZS/?node-id=443-7204
//        같은 화면 다른 판(대본 길이만 다름) https://figma.com/design/JL9YPbqBqmaC9Z0I3SzDZS/?node-id=443-7264
//        지인 피드백 도착 상태 https://figma.com/design/JL9YPbqBqmaC9Z0I3SzDZS/?node-id=443-7102

import ComposableArchitecture
import DomainInterviewReportInterface
import SharedDesignSystemInterface
import SwiftUI

/// 1차 리포트 — Figma «Report_Main_Default» 443:7204(기본) · 443:7102(지인 피드백 도착). 다크 화면(b900) 기준.
///
/// 세로 구성: 한 줄 요약 → 영상 카드 → 상세 리포트(질문 탭 + 선택 카드) → 지인 피드백.
/// 카드를 세로로 늘어놓지 않고 **질문 탭으로 한 장씩** 보여준다 — 대본이 길어 전부 펼치면 스크롤이 무너진다.
/// 색·타이포는 전부 DS 토큰이고, 사용자 문구는 대부분 서버 소유다 (정의서 §6).
@ViewAction(for: ReportMainFeature.self)
public struct ReportMainView: View {
    @Bindable public var store: StoreOf<ReportMainFeature>

    public init(store: StoreOf<ReportMainFeature>) {
        self.store = store
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.HilitBlack.b900.ignoresSafeArea())
            // 다크 판 선언 — 하위 `.mini`(재시도 버튼·지인 이름 탭)의 팔레트가 다크용으로 바뀐다.
            .hilitSurface(.dark)
            // X = 리포트 닫기(플로우 종료) — 기본 pop 이 아니라 리듀서가 소유한다.
            // `background: .filled` — 스크롤 화면이라 투명 바로 두면 요약 문구가 X 뒤로 지나간다.
            .hilitNavigationBar(surface: .dark, background: .filled, onClose: { send(.userTappedClose) })
            .onAppear { send(.onAppear) }
        .sheet(item: $store.scope(state: \.highlightDetail, action: \.highlightDetail)) { store in
            ReportHighlightDetailView(store: store)
        }
        // 미승격 서버 에러코드 — 서버 원문을 OS 기본 Alert 로 (임시 노출 규칙).
        .alert($store.scope(state: \.alert, action: \.alert))
    }

    /// 상태 분기 (정의서 §4-4) — 폴링 지연·재시도 가능 에러는 수동 재시도 버튼을 붙이고,
    /// 복구 불가 에러(세션 없음·타인 소유, 로그인 만료)와 채점 실패는 닫기만 남긴다.
    @ViewBuilder
    private var content: some View {
        switch store.loadState {
        case .loading:
            statusMessage("리포트를 만들고 있어요.", showsProgress: true)
        case .loaded:
            reportBody
        case .generationFailed:
            statusMessage(ReportMainView.generationFailureMessage)
        case .pollTimedOut:
            statusMessage(
                "채점이 예상보다 오래 걸리고 있어요.\n잠시 후 다시 확인해 주세요.",
                showsRetry: true
            )
        case let .failed(error):
            statusMessage(message(for: error), showsRetry: isRetryable(error))
        }
    }

    private var reportBody: some View {
        ScrollView {
            // 시안은 «title-box(pt10)» 다음 블록이 pt24 로 시작한다 — 요약과 본문 사이만 24,
            // 본문 섹션 사이는 36 이라 두 열로 나눈다.
            VStack(alignment: .leading, spacing: 0) {
                headline
                VStack(alignment: .leading, spacing: Metric.sectionSpacing) {
                    videoSection
                    HilitDivider()
                    detailReportSection
                    peerFeedbackSection
                }
                .padding(.top, .ds(.p24))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, .ds(.p20))
            .padding(.top, .ds(.p10))
            .padding(.bottom, .ds(.p24))
        }
        // 늦게 도착한 지인 피드백을 받아오는 단발 재조회 — 폴링 재개가 아니고, `onAppear` 도 아니라
        // 접어 둔 툴팁을 다시 펼치지 않는다.
        .refreshable { await send(.userPulledToRefresh).finish() }
    }

    /// 한 줄 요약 — 서버 소유 문구. nil 이면 분석 부족 폴백만 쓴다 (정의서 §6).
    /// 시안의 «title-box» 인스턴스라 DS `TitleBox`(뱃지·서브 없이 타이틀 한 줄)를 쓰고,
    /// 글자색은 화면이 선언한 `.hilitSurface(.dark)` 가 흰색으로 정한다.
    private var headline: some View {
        TitleBox([.init(store.report?.headline ?? ReportMainView.headlineFallback)])
    }

    // MARK: - 영상

    private var videoSection: some View {
        VStack(alignment: .leading, spacing: .ds(.p12)) {
            VideoCountdownCard(
                expiresAt: store.videoExpiresAt,
                isExpired: store.playableVideoURL == nil,
                onTap: { send(.userTappedWatchVideo) }
            )
            // 시청 시간 연장 안내 — 이미 피드백이 도착했으면 연장이 끝난 얘기라 감춘다.
            if !store.hasGuestFeedback {
                Text(ReportMainView.videoExtensionNotice)
                    .dsTypography(.body9)
                    .foregroundStyle(Color.GrayScale.g600)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 상세 리포트

    private var detailReportSection: some View {
        VStack(alignment: .leading, spacing: Metric.detailSpacing) {
            VStack(alignment: .leading, spacing: .ds(.p10)) {
                detailReportHeader
                QuestionTabBar(
                    cards: store.cards,
                    selectedIndex: store.selectedCardIndex,
                    onSelect: { send(.userTappedQuestionTab($0)) }
                )
            }
            if let card = store.selectedCard {
                selectedCardBody(card)
            }
        }
    }

    /// 제목 + 안내 느낌표·툴팁. 배치는 `DetailReportHeader` 가 갖고, 여기선 상태만 넘긴다.
    private var detailReportHeader: some View {
        DetailReportHeader(
            notice: store.hasDetailReportNotices ? store.detailReportTooltipMessage : nil,
            isTooltipVisible: store.isRedFlagTooltipVisible,
            onTapIcon: { send(.userTappedRedFlagInfo) },
            onTapTooltip: { send(.userTappedRedFlagTooltip) }
        )
    }

    private func selectedCardBody(_ card: InterviewReportCard) -> some View {
        VStack(alignment: .leading, spacing: .ds(.p24)) {
            VStack(alignment: .leading, spacing: .ds(.p16)) {
                questionRow(card)

                // 질문 의도 분석 — 볼드 제목·본문 모두 서버 소유 문구.
                // 메인에 서는 분석 카드는 이 한 종류뿐이다(시안 443:7204) — «Hilit의 답변 분석» 은
                // 하이라이트 상세 시트 전용이라 여기서 그리지 않는다.
                if let questionIntent = card.questionIntent {
                    QuestionAnalysisCard(title: card.questionIntentTitle, contents: questionIntent)
                }
                // 해상도 안내·카드 레드플래그는 카드 본문에 한 줄 판으로 세우지 않는다 —
                // 제목 옆 느낌표 툴팁(`detailReportHeader`) 한 곳으로 모았다. 시안의 `MessageCard(.mini)`
                // 한 줄 판은 하이라이트 상세 시트 전용이다.
            }

            if let transcript = card.transcript {
                TranscriptText(
                    transcript: transcript,
                    spans: card.highlightSpans ?? [],
                    onTapSpan: { spanIndex in
                        send(.userTappedHighlight(cardIndex: store.selectedCardIndex, spanIndex: spanIndex))
                    }
                )
            }
        }
    }

    /// 질문 배지 + 질문 원문. 질문이 비면 배지만 덩그러니 남으므로 행째 렌더하지 않는다.
    @ViewBuilder
    private func questionRow(_ card: InterviewReportCard) -> some View {
        if let questionText = card.questionText {
            HStack(alignment: .top, spacing: .ds(.p8)) {
                Image.Q.default
                    .resizable()
                    .scaledToFit()
                    .frame(width: Metric.questionBadgeSide, height: Metric.questionBadgeSide)

                Text(questionText)
                    .dsTypography(.body3)
                    .foregroundStyle(Color.BlackWhite.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - 지인 피드백

    /// 도착한 평가가 있으면 그 위에 얹고, **«보내기» 카드는 항상 남긴다** — 정원(4명)이 차기 전까지
    /// 다음 지인에게 또 보낼 수 있어야 해서다(시안 443:7102 는 평가 목록 아래 «1/4» 카드를 함께 그린다).
    private var peerFeedbackSection: some View {
        VStack(alignment: .leading, spacing: store.hasGuestFeedback ? .ds(.p10) : .ds(.p16)) {
            Text("지인 피드백")
                .dsTypography(.sub7)
                .foregroundStyle(Color.BlackWhite.white)

            if store.hasGuestFeedback {
                GuestFeedbackPanel(
                    guests: store.guests,
                    selectedIndex: store.selectedGuestIndex,
                    expandedAxes: store.expandedCommentAxes,
                    onSelectGuest: { send(.userTappedGuestTab($0)) },
                    onToggleComment: { send(.userTappedAttitudeComment(axisCode: $0)) }
                )
            }

            PeerFeedbackCard(
                participantCount: store.guestParticipantCount,
                maxCount: ReportMainFeature.maxGuestCount,
                onTap: { send(.userTappedPeerFeedback) }
            )
        }
    }

    // MARK: - 보조

    private func statusMessage(
        _ message: String,
        showsProgress: Bool = false,
        showsRetry: Bool = false
    ) -> some View {
        VStack(spacing: .ds(.p12)) {
            Spacer()
            if showsProgress {
                ProgressView()
                    .tint(Color.HilitGreen.g500)
            }
            Text(message)
                .dsTypography(.body3)
                .foregroundStyle(Color.GrayScale.g300)
                .multilineTextAlignment(.center)
            if showsRetry {
                // 문구는 클라 소유(§13 카피 미확정) — 확정되면 여기만 바꾼다.
                Button("다시 시도하기") { send(.userTappedReload) }
                    .buttonStyle(.mini(.black))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.ds(.p20))
    }

    private func message(for error: InterviewReportError) -> String {
        switch error {
        case .sessionNotFound: "리포트를 찾을 수 없어요."
        case .sessionExpired: "로그인이 만료됐어요.\n다시 로그인해 주세요."
        case .networkFailure: "네트워크 연결을 확인해 주세요."
        default: "리포트를 불러오지 못했어요.\n잠시 후 다시 시도해 주세요."
        }
    }

    /// 재시도로 나아질 수 있는 에러만 버튼을 보여준다 (정의서 §4-4).
    /// 세션 없음(타인 소유·삭제)과 로그인 만료는 다시 눌러도 같은 답이다.
    private func isRetryable(_ error: InterviewReportError) -> Bool {
        switch error {
        case .sessionNotFound, .sessionExpired: false
        default: true
        }
    }

    private enum Metric {
        // @ds(spacing): 34 — 질문 탭 줄과 선택 카드 사이
        static let detailSpacing: CGFloat = 34
        /// 질문 배지 한 변 20 — Figma `Q` 배지.
        static let questionBadgeSide: CGFloat = 20
        // @ds(spacing): 36 — 본문 섹션 사이
        static let sectionSpacing: CGFloat = 36
    }

    /// 채점 실패(FAILED) 안내 — 홈 위젯 실패 행과 같은 계열 문구. 재조회해도 같은 답이라 버튼이 없다.
    // TODO(prd-외): FAILED UX 는 PRD 미확정 — 홈 위젯 실패 행과 같은 계열로 임시 재량 구현. 문구·후속 행동이 정해지면 여기만 바꾼다.
    static let generationFailureMessage = "레포트 생성에 실패했어요.\n이용권 횟수는 차감되지 않아요."
    /// 서버 `headline` 이 비었을 때의 폴백 (정의서 §6).
    static let headlineFallback = "이번 면접의 답변이 충분하지 않아요. 다음 면접 연습 때는 조금 더 충분한 답변을 말씀해주세요."
    /// 영상 카드 아래 안내 — 클라 소유 문구.
    static let videoExtensionNotice = "* 지인 1명이라도 피드백이 완료될 시 시청 시간이 최대로 연장됩니다."
}

// MARK: - Previews

#Preview("1차 리포트") {
    ReportMainView(
        store: Store(initialState: ReportMainFeature.State(sessionId: 1)) {
            ReportMainFeature()
        } withDependencies: {
            $0.interviewReportClient = .previewValue
        }
    )
}

#Preview("레드플래그 · 영상 만료 — 443:7204") {
    reportMainPreview(
        cardRedFlagNotices: [
            RedFlagNotice(type: "CONTRADICTION", message: "면접 앞부분과 뒷부분의 답변이 서로 어긋나는 지점이 있었어요."),
            RedFlagNotice(type: "LOW_RESOLUTION", message: "영상 해상도가 낮아 분석율이 떨어질 수 있어요.")
        ],
        resolutionNotice: "AI가 분석을 제공하기에는 이번 질문에 대한 답변이 충분하지 않아요.",
        video: InterviewReportVideo(url: nil, expired: true, expiresAt: nil)
    )
}

#Preview("지인 피드백 도착 — 443:7102") {
    reportMainPreview(
        video: InterviewReportVideo(
            url: "https://example.com/interview.mp4",
            expired: false,
            expiresAt: Date().addingTimeInterval(86_373)
        ),
        guestFeedback: GuestFeedbackSection(
            participantCount: 4,
            guests: ["허자연", "박민주", "노영진", "유노유노"].map {
                GuestReview(alias: $0, attitudeRatings: previewAttitudeRatings)
            }
        )
    )
}

/// 시안 «지인 피드백 도착» 의 다섯 축 — 코멘트 없음·한 줄·말줄임(펼치기) 세 경우를 모두 담는다.
private let previewAttitudeRatings = [
    GuestAttitudeRating(axis: "GAZE", level: 3, comment: "꼬리질문에서 눈빛이 흔들려서 자신감이 없어 보였어요."),
    GuestAttitudeRating(
        axis: "EXPRESSION",
        level: 1,
        comment: "꼬리질문에서 눈빛이 흔들려서 자신감이 없어 보였어요. 그래서 조금 아쉬웠습니다."
    ),
    GuestAttitudeRating(axis: "POSTURE", level: 1, comment: nil),
    GuestAttitudeRating(axis: "GESTURE", level: 1, comment: nil),
    GuestAttitudeRating(axis: "VOICE", level: 1, comment: "꼬리질문에서 눈빛이 흔들려서 자신감이 없어 보였어요.")
]

/// 시안 대조용 화면 — 상태를 가르는 네 필드(레드플래그·해상도 안내·영상·지인 피드백)만 바꿔 끼운다.
/// 안내는 카드 소유라 첫 카드에만 싣는다 — 툴팁은 보고 있는 카드 것만 세우므로
/// 질문 탭을 옮기면 느낌표·툴팁이 사라지는 것까지 프리뷰에서 확인된다.
@ViewBuilder
private func reportMainPreview(
    cardRedFlagNotices: [RedFlagNotice]? = nil,
    resolutionNotice: String? = nil,
    video: InterviewReportVideo,
    guestFeedback: GuestFeedbackSection? = nil
) -> some View {
    let report = InterviewReport(
        status: .ready,
        headline: "캐시 도입 결정의 이유와 한계까지 구체적인 수치로 설명해 주셨어요",
        video: video,
        cards: (1...5).map { depth in
            InterviewReportCard(
                axisOrder: 1,
                depthLevel: depth,
                questionText: "트래픽이 10배일 때 가장 치명적인 지점과, 그 임계치를 어떻게 생각하시나요?",
                transcript: "음.. 어릴 적부터 맡은 일은 끝까지 해내야 직성이 풀리는 성격이라, 대학교에서는 시각디자인을 전공하며 여러 공모전에 도전했습니다.",
                highlightSpans: [
                    HighlightSpan(startIndex: 40, endIndex: 62, tone: "IMPROVE", analysis: nil)
                ],
                resolutionNotice: depth == 1 ? resolutionNotice : nil,
                cardRedFlagNotices: depth == 1 ? cardRedFlagNotices : nil,
                questionIntent: "트래픽이 증가했을 때 발생할 병목 지점과 시스템의 한계, 그리고 이를 어떻게 판단할지 설명하는 질문입니다."
            )
        },
        guestFeedback: guestFeedback
    )

    ReportMainView(
        store: Store(initialState: ReportMainFeature.State(sessionId: 1)) {
            ReportMainFeature()
        } withDependencies: {
            $0.interviewReportClient.report = { _ in report }
            // 카운트다운은 `video/expiry` 만 본다 — 프리뷰 영상의 `expiresAt` 을 잔여초로 돌려 같은 시각을 낸다.
            $0.interviewReportClient.videoExpiry = { _ in
                let remaining = max(0, Int(video.expiresAt?.timeIntervalSinceNow ?? 0))
                return InterviewVideoExpiry(expiresInSeconds: remaining, expired: remaining == 0)
            }
        }
    )
}
