//
//  InterviewClientLiveTests.swift
//  DomainInterviewTests
//
//  Created by EunseoKim on 26/07/07.
//

import ComposableArchitecture
import CoreNetworkInterface
import DomainInterviewInterface
import XCTest
@testable import DomainInterviewImplementation

final class InterviewClientLiveTests: XCTestCase {
    /// liveValue 가 AuthorizedNetworkClient "계약"만으로 동작하는지 — Core 구현(URLSession·토큰) 없이 검증한다.
    private func makeClient(
        handler: @escaping @Sendable (NetworkRequest) async throws -> Data
    ) -> InterviewClient {
        withDependencies {
            $0.authorizedNetworkClient = AuthorizedNetworkClient(
                request: handler,
                authorizedResource: { path in
                    AuthorizedResource(
                        url: URL(string: "http://stub.test\(path)")!,
                        headers: ["Authorization": "Bearer stub-token"]
                    )
                }
            )
        } operation: {
            InterviewClient.liveValue
        }
    }

    /// 종료 분기 디코딩 검증 공통 — 주어진 응답 JSON 으로 submitAnswer 를 돌려 결과를 준다.
    private func submitAnswer(returning json: String) async throws -> AnswerResult {
        let client = makeClient { _ in Data(json.utf8) }
        return try await client.submitAnswer(7, AnswerSubmission(questionId: 1, isWrapUp: false))
    }

    // MARK: - 세션 생성

    func test_createSession_직군연차없이_jdUrl과_jdText를_상호배타로_인코딩한다() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.path, "/api/v1/interview/sessions")
            XCTAssertEqual(request.method, .post)
            let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any]
            XCTAssertNil(body?["jobRole"])      // 프로필 스냅샷 — 서버가 회원 프로필 사용
            XCTAssertNil(body?["careerYears"])
            XCTAssertEqual(body?["jdUrl"] as? String, "https://example.com/careers/123")
            XCTAssertNil(body?["jdText"])  // 상호 배타 — url 입력이면 text 는 실리지 않는다
            return Data("""
            {"success": true, "data": {
                "sessionId": 7, "status": "PROCESSING", "statusUrl": "/api/v1/interview/sessions/7/status"
            }}
            """.utf8)
        }

        let created = try await client.createSession(InterviewConfig(
            portfolioId: UUID(),
            jobDescription: .url("https://example.com/careers/123")
        ))

        XCTAssertEqual(created.sessionId, 7)
        XCTAssertEqual(created.status, "PROCESSING")
    }

    func test_createSession_USER_PROFILE_NOT_REGISTERED를_전용케이스로_승격한다() async {
        let body = Data(#"{"success": false, "code": "USER_PROFILE_NOT_REGISTERED", "message": "프로필을 먼저 등록해주세요."}"#.utf8)
        let client = makeClient { _ in throw NetworkError.statusCode(400, body) }

        do {
            _ = try await client.createSession(InterviewConfig(portfolioId: UUID()))
            XCTFail("InterviewError 가 나야 한다")
        } catch {
            XCTAssertEqual(error as? InterviewError, .userProfileNotRegistered)
        }
    }

    func test_createSession_FREETEXT_NOT_RELEVANT_서버에러를_도메인에러로_승격한다() async {
        let body = Data(#"{"success": false, "code": "FREETEXT_NOT_RELEVANT", "message": "연관성이 낮아요."}"#.utf8)
        let client = makeClient { _ in throw NetworkError.statusCode(422, body) }

        do {
            _ = try await client.createSession(InterviewConfig(portfolioId: UUID()))
            XCTFail("InterviewError 가 나야 한다")
        } catch let error as InterviewError {
            XCTAssertEqual(error, .freeTextNotRelevant)
        } catch {
            XCTFail("InterviewError 가 아니라 \(error)")
        }
    }

    func test_createSession_미승격_서버에러는_server케이스로_승격한다() async {
        let body = Data(#"{"success": false, "code": "PORTFOLIO_NOT_READY", "message": "포폴 준비 중"}"#.utf8)
        let client = makeClient { _ in throw NetworkError.statusCode(409, body) }

        do {
            _ = try await client.createSession(InterviewConfig(portfolioId: UUID()))
            XCTFail("InterviewError 가 나야 한다")
        } catch let error as InterviewError {
            XCTAssertEqual(error, .server(code: "PORTFOLIO_NOT_READY", message: "포폴 준비 중"))
        } catch {
            XCTFail("InterviewError 가 아니라 \(error)")
        }
    }

    func test_createSession_이용권소진403을_noRemainingTicket으로_매핑한다() async throws {
        let client = makeClient { _ in
            throw NetworkError.statusCode(403, Data(
                #"{"success": false, "code": "NO_REMAINING_TICKET", "message": "남은 이용권이 없어요."}"#.utf8
            ))
        }

        do {
            _ = try await client.createSession(InterviewConfig(portfolioId: UUID()))
            XCTFail("에러가 던져져야 한다")
        } catch {
            XCTAssertEqual(error as? InterviewError, .noRemainingTicket)
        }
    }

    func test_createSession_JD캐시만료를_jdNotValidated로_매핑한다() async throws {
        let client = makeClient { _ in
            throw NetworkError.statusCode(400, Data(
                #"{"success": false, "code": "JD_CONTENT_NOT_FOUND", "message": "JD 링크의 캐시가 만료됐어요. 다시 검증해 주세요."}"#.utf8
            ))
        }

        do {
            _ = try await client.createSession(InterviewConfig(portfolioId: UUID()))
            XCTFail("에러가 던져져야 한다")
        } catch {
            XCTAssertEqual(error as? InterviewError, .jdNotValidated)
        }
    }

    // MARK: - 준비 폴링

    func test_sessionStatus_READY응답의_LocalDateTime과_요약질문을_디코딩한다() async throws {
        let json = """
        {"success": true, "data": {
            "status": "READY",
            "startedAt": "2026-07-06T10:00:04",
            "summaryQuestion": {"questionId": 1, "ttsAudio": null, "turn": {"turnLevel": 0, "depthLevel": 0}}
        }}
        """
        let client = makeClient { request in
            XCTAssertEqual(request.path, "/api/v1/interview/sessions/7/status")
            XCTAssertEqual(request.method, .get)
            return Data(json.utf8)
        }

        let status = try await client.sessionStatus(7)

        XCTAssertEqual(status.status, .ready)
        XCTAssertNotNil(status.startedAt)  // LocalDateTime(타임존 없음)도 JSONDecoder.api 가 파싱
        XCTAssertEqual(status.summaryQuestion?.turn, TurnInfo(turnLevel: 0, depthLevel: 0))
    }

    // MARK: - 답변 제출 (인코딩)

    func test_submitAnswer_메타데이터는_query로_오디오는_multipart로_보낸다() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.path, "/api/v1/interview/sessions/7/answers")
            XCTAssertEqual(request.method, .post)
            let query = Dictionary(uniqueKeysWithValues: request.queryItems.map { ($0.name, $0.value) })
            XCTAssertEqual(query["questionId"], "1")
            XCTAssertEqual(query["isWrapUp"], "false")
            XCTAssertTrue(request.headers["Content-Type"]?.hasPrefix("multipart/form-data; boundary=") == true)
            let body = String(bytes: request.body ?? Data(), encoding: .utf8) ?? ""
            XCTAssertTrue(body.contains(#"name="audio""#))
            XCTAssertTrue(body.contains("mp3-bytes"))
            return Data("""
            {"success": true, "data": {
                "answerId": 12,
                "nextQuestion": {"questionId": 13, "isLast": false, "turn": {"turnLevel": 1, "depthLevel": 1}},
                "sessionEnded": false,
                "wrapUpMessage": null,
                "endType": null
            }}
            """.utf8)
        }

        let result = try await client.submitAnswer(7, AnswerSubmission(
            questionId: 1,
            audio: Data("mp3-bytes".utf8),
            isWrapUp: false
        ))

        XCTAssertEqual(result.answerId, 12)
        XCTAssertEqual(result.nextQuestion?.questionId, 13)
        XCTAssertFalse(result.sessionEnded)
    }

    func test_submitAnswer_isWrapUp을_항상_query로_보낸다() async throws {
        let client = makeClient { request in
            let query = Dictionary(uniqueKeysWithValues: request.queryItems.map { ($0.name, $0.value) })
            XCTAssertEqual(query["isWrapUp"], "true")   // required — nil 전송 경로 없음
            return Data(#"{"success": true, "data": {"sessionEnded": false}}"#.utf8)
        }

        _ = try await client.submitAnswer(7, AnswerSubmission(questionId: 1, isWrapUp: true))
    }

    func test_submitAnswer_답변오디오를_m4a_메타로_싣는다() async throws {
        let form = LockIsolated<Data?>(nil)
        let client = makeClient { request in
            form.setValue(request.body)
            return Data("""
            {"success": true, "data": {
                "answerId": 1, "nextQuestion": null, "sessionEnded": true,
                "wrapUpMessage": null, "endType": "NORMAL_END"
            }}
            """.utf8)
        }
        var submission = AnswerSubmission(questionId: 1, isWrapUp: false)
        submission.audio = Data("aac".utf8)

        _ = try await client.submitAnswer(7, submission)

        let body = try XCTUnwrap(form.value.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(body.contains(#"filename="answer.m4a""#))
        XCTAssertTrue(body.contains("Content-Type: audio/mp4"))
        XCTAssertFalse(body.contains("answer.mp3"))
    }

    // MARK: - 답변 제출 (응답 분기 디코딩 — 스웨거 예시 기반 6분기)

    func test_submitAnswer_다음질문_응답을_디코딩한다() async throws {
        let result = try await submitAnswer(returning: """
        {"success": true, "data": {
            "answerId": 12,
            "nextQuestion": {"questionId": 13, "isLast": false, "turn": {"turnLevel": 1, "depthLevel": 1}},
            "sessionEnded": false
        }}
        """)

        XCTAssertFalse(result.sessionEnded)
        XCTAssertNil(result.endType)
        XCTAssertEqual(result.nextQuestion?.questionId, 13)
    }

    func test_submitAnswer_NORMAL_END_마무리멘트를_디코딩한다() async throws {
        let result = try await submitAnswer(returning: """
        {"success": true, "data": {
            "answerId": 30, "nextQuestion": null, "sessionEnded": true,
            "wrapUpMessage": {"ttsAudio": "bXAz"},
            "endType": "NORMAL_END"
        }}
        """)

        XCTAssertTrue(result.sessionEnded)
        XCTAssertEqual(result.endType, .normalEnd)
        XCTAssertEqual(result.wrapUpMessage?.audioData, Data("mp3".utf8))   // base64 "bXAz"
    }

    func test_submitAnswer_MANUAL_END를_디코딩한다() async throws {
        let result = try await submitAnswer(returning: """
        {"success": true, "data": {"sessionEnded": true, "wrapUpMessage": {"ttsAudio": null}, "endType": "MANUAL_END"}}
        """)

        XCTAssertEqual(result.endType, .manualEnd)
        XCTAssertNil(result.wrapUpMessage?.audioData)
    }

    func test_submitAnswer_HARD_CAP을_디코딩한다() async throws {
        let result = try await submitAnswer(returning: """
        {"success": true, "data": {"sessionEnded": true, "endType": "HARD_CAP"}}
        """)

        XCTAssertEqual(result.endType, .hardCap)
    }

    func test_submitAnswer_BACK_EXIT를_디코딩한다() async throws {
        let result = try await submitAnswer(returning: """
        {"success": true, "data": {"sessionEnded": true, "wrapUpMessage": null, "endType": "BACK_EXIT"}}
        """)

        XCTAssertEqual(result.endType, .backExit)
        XCTAssertNil(result.wrapUpMessage)
    }

    func test_submitAnswer_STT_RESET을_디코딩한다() async throws {
        let result = try await submitAnswer(returning: """
        {"success": true, "data": {"sessionEnded": true, "endType": "STT_RESET"}}
        """)

        XCTAssertEqual(result.endType, .sttReset)
    }

    // MARK: - 답변 제출 (에러)

    func test_submitAnswer_중복제출409를_answerAlreadySubmitted로_매핑한다() async throws {
        let client = makeClient { _ in
            throw NetworkError.statusCode(409, Data(
                #"{"success": false, "code": "ANSWER_ALREADY_SUBMITTED", "message": "이미 제출된 답변이에요."}"#.utf8
            ))
        }

        do {
            _ = try await client.submitAnswer(7, AnswerSubmission(questionId: 1, isWrapUp: false))
            XCTFail("에러가 던져져야 한다")
        } catch {
            XCTAssertEqual(error as? InterviewError, .answerAlreadySubmitted)
        }
    }

    func test_submitAnswer_503_AI_TEMPORARILY_UNAVAILABLE는_serverUnavailable가_아니라_전용케이스다() async {
        // 회귀 방지 — DomainAPIError 는 코드 매핑을 5xx 판정보다 먼저 시도한다(envelope 없는 503 만 serverUnavailable).
        let body = Data(#"{"success": false, "code": "AI_TEMPORARILY_UNAVAILABLE", "message": "AI 가 일시적으로 응답하지 못했어요."}"#.utf8)
        let client = makeClient { _ in throw NetworkError.statusCode(503, body) }

        do {
            _ = try await client.submitAnswer(7, AnswerSubmission(questionId: 1, isWrapUp: false))
            XCTFail("에러가 던져져야 한다")
        } catch {
            XCTAssertEqual(error as? InterviewError, .aiTemporarilyUnavailable)
        }
    }

    // MARK: - 질문 오디오 스트림

    func test_questionAudioStream_인증헤더가_실린_재생정보를_돌려준다() async throws {
        let client = makeClient { _ in Data() }

        let stream = try await client.questionAudioStream(7, 13)

        XCTAssertEqual(stream.url.absoluteString, "http://stub.test/api/v1/interview/sessions/7/questions/13/audio/stream")
        XCTAssertEqual(stream.headers["Authorization"], "Bearer stub-token")
    }

    // MARK: - 영상 업로드

    func test_videoUploadURL_presigned_PUT_대상을_디코딩한다() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.path, "/api/v1/interview/sessions/7/video/upload-url")
            XCTAssertEqual(request.method, .post)
            XCTAssertNil(request.body)   // 요청 바디 없음
            return Data("""
            {"success": true, "data": {
                "uploadUrl": "https://bucket.s3.ap-northeast-2.amazonaws.com/users/1/sessions/42/recording/raw.mp4?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Expires=600",
                "contentType": "video/mp4",
                "expiresInSeconds": 600
            }}
            """.utf8)
        }

        let target = try await client.videoUploadURL(7)

        XCTAssertTrue(target.uploadUrl.hasPrefix("https://bucket.s3.ap-northeast-2.amazonaws.com/"))
        XCTAssertEqual(target.contentType, "video/mp4")
        XCTAssertEqual(target.expiresInSeconds, 600)
    }

    func test_completeVideoUpload_마무리멘트_구간을_JSON바디로_인코딩한다() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.path, "/api/v1/interview/sessions/7/video/complete")
            XCTAssertEqual(request.method, .post)
            XCTAssertEqual(request.headers["Content-Type"], "application/json")
            let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any]
            XCTAssertEqual(body?["wrapUpStartSec"] as? Double, 512.4)
            XCTAssertEqual(body?["wrapUpEndSec"] as? Double, 515.8)
            return Data(#"{"success": true}"#.utf8)
        }

        try await client.completeVideoUpload(7, InterviewVideoWrapUpSpan(wrapUpStartSec: 512.4, wrapUpEndSec: 515.8))
    }

    func test_completeVideoUpload_마무리멘트가_없으면_바디를_생략한다() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.path, "/api/v1/interview/sessions/7/video/complete")
            XCTAssertEqual(request.method, .post)
            XCTAssertNil(request.body)   // 계약: wrapUp 없으면 바디 생략
            XCTAssertNil(request.headers["Content-Type"])
            return Data(#"{"success": true}"#.utf8)
        }

        try await client.completeVideoUpload(7, nil)
    }

    func test_videoUploadURL_세션없음404를_sessionNotFound로_매핑한다() async {
        let client = makeClient { _ in
            throw NetworkError.statusCode(404, Data(
                #"{"success": false, "code": "INTERVIEW_SESSION_NOT_FOUND", "message": "면접 세션을 찾을 수 없어요."}"#.utf8
            ))
        }

        do {
            _ = try await client.videoUploadURL(7)
            XCTFail("에러가 던져져야 한다")
        } catch {
            XCTAssertEqual(error as? InterviewError, .sessionNotFound)
        }
    }

    // MARK: - 레포트 목록

    func test_reportList_envelope의_reports를_벗겨_목록을_디코딩한다() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.path, "/api/v1/interview/sessions")
            XCTAssertEqual(request.method, .get)
            return Data("""
            {"success": true, "data": {"reports": [{
                "sessionId": 7,
                "jobType": "BACKEND",
                "jobTypeLabel": "백엔드 개발자",
                "careerYears": 3,
                "title": "캐시 도입 결정의 이유와 한계까지 설명했어요",
                "interviewedAt": "2026-08-01T10:00:00",
                "portfolioFileName": "portfolio.pdf",
                "portfolioDeleted": false,
                "jdUrl": "https://example.com/careers/123",
                "reportStatus": "READY",
                "feedbackAvailable": true
            }]}}
            """.utf8)
        }

        let reports = try await client.reportList()

        XCTAssertEqual(reports.count, 1)
        let report = try XCTUnwrap(reports.first)
        XCTAssertEqual(report.sessionId, 7)
        XCTAssertEqual(report.jobTypeLabel, "백엔드 개발자")
        XCTAssertEqual(report.title, "캐시 도입 결정의 이유와 한계까지 설명했어요")
        XCTAssertEqual(report.reportStatus, .ready)
        XCTAssertFalse(report.portfolioDeleted)
        XCTAssertTrue(report.feedbackAvailable)
    }

    func test_reportList_reportStatus_생성중과_분석부족과_실패를_디코딩한다() async throws {
        func row(_ id: Int, _ status: String) -> String {
            """
            {"sessionId": \(id), "interviewedAt": "2026-08-01T10:00:00",
             "portfolioDeleted": false, "reportStatus": "\(status)", "feedbackAvailable": false}
            """
        }
        let client = makeClient { _ in
            Data("""
            {"success": true, "data": {"reports": [
                \(row(1, "GENERATING")), \(row(2, "INSUFFICIENT_ANALYSIS")), \(row(3, "FAILED"))
            ]}}
            """.utf8)
        }

        let reports = try await client.reportList()

        XCTAssertEqual(reports.map(\.reportStatus), [.generating, .insufficientAnalysis, .failed])
        // title 이 빠진 행(필드 이전 세션)도 nil 로 디코딩된다 — 목록 전체가 실패하지 않는다.
        XCTAssertEqual(reports.compactMap(\.title).count, 0)
    }
}

// MARK: - 영상 업로드 응집 (발급 → presigned PUT → complete)

/// 본체 클래스가 SwiftLint type_body_length 상한에 닿아 별도 extension 으로 둔다 — 스텁이 두 개(네트워크·파일전송)라
/// makeClient 오버로드도 여기 함께 산다.
extension InterviewClientLiveTests {
    /// uploadInterviewVideo 검증용 — authorizedNetworkClient + fileTransferClient 를 함께 스텁한다.
    private func makeClient(
        handler: @escaping @Sendable (NetworkRequest) async throws -> Data,
        fileTransfer: @escaping @Sendable (URL, String, URL) async throws -> Void
    ) -> InterviewClient {
        withDependencies {
            $0.authorizedNetworkClient = AuthorizedNetworkClient(
                request: handler,
                authorizedResource: { path in
                    AuthorizedResource(url: URL(string: "http://stub.test\(path)")!, headers: [:])
                }
            )
            $0.fileTransferClient = FileTransferClient(upload: fileTransfer)
        } operation: {
            InterviewClient.liveValue
        }
    }

    /// 발급 응답 — presigned 대상 한 벌.
    private var uploadTargetJSON: Data {
        Data("""
        {"success": true, "data": {
            "uploadUrl": "https://s3.test/video?sig=1", "contentType": "video/mp4", "expiresInSeconds": 600
        }}
        """.utf8)
    }

    func test_uploadInterviewVideo_발급_PUT_complete를_순서대로_응집한다() async throws {
        let steps = LockIsolated<[String]>([])
        let fileURL = URL(fileURLWithPath: "/tmp/interview-recording-7.mp4")
        let target = uploadTargetJSON
        let client = makeClient(
            handler: { request in
                steps.withValue { $0.append(request.path) }
                if request.path.hasSuffix("upload-url") {
                    return target
                }
                XCTAssertNil(request.body)   // wrapUp nil → complete 바디 생략 계약
                return Data(#"{"success": true}"#.utf8)
            },
            fileTransfer: { url, contentType, file in
                steps.withValue { $0.append("PUT \(url.host ?? "?") \(contentType) \(file.lastPathComponent)") }
            }
        )

        try await client.uploadInterviewVideo(7, fileURL, nil)

        XCTAssertEqual(steps.value, [
            "/api/v1/interview/sessions/7/video/upload-url",
            "PUT s3.test video/mp4 interview-recording-7.mp4",
            "/api/v1/interview/sessions/7/video/complete"
        ])
    }

    func test_uploadInterviewVideo_wrapUp이_있으면_complete_바디에_구간을_싣는다() async throws {
        let completeBody = LockIsolated<Data?>(nil)
        let target = uploadTargetJSON
        let client = makeClient(
            handler: { request in
                if request.path.hasSuffix("upload-url") {
                    return target
                }
                completeBody.setValue(request.body)
                return Data(#"{"success": true}"#.utf8)
            },
            fileTransfer: { _, _, _ in }
        )

        try await client.uploadInterviewVideo(
            7,
            URL(fileURLWithPath: "/tmp/v.mp4"),
            InterviewVideoWrapUpSpan(wrapUpStartSec: 500, wrapUpEndSec: 512.0)
        )

        let json = try JSONSerialization.jsonObject(with: XCTUnwrap(completeBody.value)) as? [String: Any]
        XCTAssertEqual(json?["wrapUpStartSec"] as? Double, 500)
        XCTAssertEqual(json?["wrapUpEndSec"] as? Double, 512)
    }

    func test_uploadInterviewVideo_PUT_실패면_complete를_호출하지_않는다() async {
        let paths = LockIsolated<[String]>([])
        let target = uploadTargetJSON
        let client = makeClient(
            handler: { request in
                paths.withValue { $0.append(request.path) }
                return target
            },
            fileTransfer: { _, _, _ in throw NetworkError.statusCode(403, Data()) }
        )

        do {
            try await client.uploadInterviewVideo(7, URL(fileURLWithPath: "/tmp/v.mp4"), nil)
            XCTFail("에러가 던져져야 한다")
        } catch {
            XCTAssertFalse(paths.value.contains { $0.hasSuffix("complete") })
        }
    }
}
