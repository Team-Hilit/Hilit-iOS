//
//  InterviewReportClient.swift
//  DomainInterviewReportInterface
//
//  Created by EunseoKim on 26/07/23.
//

import ComposableArchitecture
import Foundation

/// 면접 보고서 조회 API (D14 `/api/v1/interview/sessions/{id}/report`).
/// 채점 파이프라인 결과를 사용자용 리포트 화면 형태로 받는다 — `status == .generating` 이면 폴링 지속.
/// 면접 진행(세션·답변)은 [[api#Interview]], 보고서 위 지인 피드백 요청은 [[api#Feedback Share]].
// @lat: [[api#Interview Report]]
public struct InterviewReportClient: Sendable {
    /// GET /interview/sessions/{id}/report — 보고서 미생성이면 404 가 아니라 `status == .generating` 으로 온다(폴링 지속).
    public var report: @Sendable (_ sessionId: Int) async throws -> InterviewReport
    /// GET /interview/sessions/{id}/video/expiry — 영상 만료 카운트다운용(리포트 로드·새로고침·재진입 때 조회).
    /// 영상 레코드가 아직 없으면(업로드 완료 전) `InterviewReportError.videoNotFound`.
    public var videoExpiry: @Sendable (_ sessionId: Int) async throws -> InterviewVideoExpiry

    public init(
        report: @escaping @Sendable (_ sessionId: Int) async throws -> InterviewReport,
        videoExpiry: @escaping @Sendable (_ sessionId: Int) async throws -> InterviewVideoExpiry
    ) {
        self.report = report
        self.videoExpiry = videoExpiry
    }
}

extension InterviewReportClient: TestDependencyKey {
    public static var testValue: InterviewReportClient {
        InterviewReportClient(
            report: unimplemented("InterviewReportClient.report"),
            videoExpiry: unimplemented("InterviewReportClient.videoExpiry")
        )
    }

    public static var previewValue: InterviewReportClient {
        InterviewReportClient(
            report: { _ in
                InterviewReport(
                    status: .ready,
                    headline: "캐시 도입 결정의 이유와 한계까지 구체적인 수치로 설명해주셨어요.",
                    video: InterviewReportVideo(
                        url: nil,
                        expired: false,
                        expiresAt: Date(timeIntervalSince1970: 1_782_172_800)
                    ),
                    cards: [
                        InterviewReportCard(
                            axisOrder: 1,
                            depthLevel: 1,
                            questionText: "Q. 결제 응답 속도를 개선하신 경험을 말씀해주세요.",
                            transcript: "결제 화면에서 응답이 평균 800ms 정도로 느려서 사용자 이탈이 있었어요.",
                            highlightSpans: [
                                HighlightSpan(
                                    startIndex: 0,
                                    endIndex: 20,
                                    tone: "GOOD",
                                    reason: "SUFFICIENT",
                                    title: "구체적 수치로 문제 설명",
                                    analysis: "구체적인 수치를 근거로 문제를 설명했습니다.",
                                    startSec: 18.2
                                )
                            ],
                            resolutionNotice: nil,
                            cardRedFlagNotices: nil,
                            questionIntentTitle: "성능 저하 인지 수준",
                            questionIntent: "성능 문제를 얼마나 구체적으로 인지했는지 확인하는 질문입니다.",
                            scriptSegments: [
                                ScriptSegment(
                                    role: .interviewer,
                                    text: "Q. 결제 응답 속도를 개선하신 경험을 말씀해주세요.",
                                    startIndex: 0,
                                    endIndex: 27,
                                    startSec: 12.0,
                                    endSec: 15.4
                                ),
                                ScriptSegment(
                                    role: .interviewee,
                                    text: "결제 화면에서 응답이 평균 800ms 정도로 느려서 사용자 이탈이 있었어요.",
                                    startIndex: 0,
                                    endIndex: 38,
                                    startSec: 18.2,
                                    endSec: 22.6
                                )
                            ]
                        )
                    ],
                    script: [
                        ScriptSegment(
                            role: .interviewer,
                            text: "안녕하세요, 오늘 면접을 진행하겠습니다.",
                            startSec: 0.0,
                            endSec: 3.2
                        ),
                        ScriptSegment(
                            role: .interviewer,
                            text: "Q. 결제 응답 속도를 개선하신 경험을 말씀해주세요.",
                            startSec: 12.0,
                            endSec: 15.4
                        ),
                        ScriptSegment(
                            role: .interviewee,
                            text: "결제 화면에서 응답이 평균 800ms 정도로 느려서 사용자 이탈이 있었어요.",
                            startSec: 18.2,
                            endSec: 22.6
                        )
                    ],
                    guestFeedback: GuestFeedbackSection(participantCount: 0, guests: [])
                )
            },
            videoExpiry: { _ in
                InterviewVideoExpiry(expiresInSeconds: 2_591_480, expired: false)
            }
        )
    }
}

public extension DependencyValues {
    var interviewReportClient: InterviewReportClient {
        get { self[InterviewReportClient.self] }
        set { self[InterviewReportClient.self] = newValue }
    }
}
