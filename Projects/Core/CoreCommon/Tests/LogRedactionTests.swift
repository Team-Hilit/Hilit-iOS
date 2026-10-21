//
//  LogRedactionTests.swift
//  CoreCommonTests
//

import CoreCommonInterface
import Foundation
import Testing

struct LogRedactionTests {
    private static func json(_ raw: String) -> String {
        LogRedaction.redacted(body: Data(raw.utf8))
    }

    // MARK: - 헤더

    @Test("Authorization 값은 가리고 키는 남긴다")
    func redactsAuthorizationValueKeepingKey() {
        let redacted = LogRedaction.redacted(headers: [
            "Authorization": "Bearer eyJhbGciOi.secret.signature",
            "Content-Type": "application/json"
        ])

        #expect(redacted["Authorization"] == LogRedaction.placeholder)
        // 어떤 헤더가 붙었는지는 디버깅에 필요하고 이름 자체는 비밀이 아니다.
        #expect(redacted["Content-Type"] == "application/json")
    }

    @Test("헤더 이름의 대소문자·구분자 차이를 무시한다")
    func matchesHeaderNamesRegardlessOfCasing() {
        let redacted = LogRedaction.redacted(headers: [
            "authorization": "Bearer a",
            "Set-Cookie": "session=b",
            "x_api_key": "c"
        ])

        #expect(redacted.values.allSatisfy { $0 == LogRedaction.placeholder })
    }

    // MARK: - 바디

    @Test("토큰류 키의 값을 가린다")
    func redactsTokenLikeKeys() {
        let redacted = Self.json(#"{"accessToken":"a","refresh_token":"b","userId":"u1"}"#)

        #expect(!redacted.contains("\"a\""))
        #expect(!redacted.contains("\"b\""))
        // 민감하지 않은 필드는 남아야 로그가 쓸모를 유지한다.
        #expect(redacted.contains("u1"))
    }

    @Test("심사용 코드가 실리는 credential 도 가린다")
    func redactsReviewCredential() {
        let redacted = Self.json(#"{"provider":"KAKAO","credential":"956ThisisDemo++Hilit"}"#)

        #expect(!redacted.contains("956ThisisDemo++Hilit"))
        #expect(redacted.contains("KAKAO"))
    }

    @Test("중첩 객체·배열 안쪽까지 내려가 가린다")
    func redactsNestedValues() {
        let redacted = Self.json(#"{"items":[{"password":"p"},{"nested":{"secretKey":"s"}}]}"#)

        #expect(!redacted.contains("\"p\""))
        #expect(!redacted.contains("\"s\""))
    }

    @Test("민감 키의 값이 객체면 통째로 가린다")
    func redactsWholeSubtreeUnderSensitiveKey() {
        let redacted = Self.json(#"{"credential":{"id":"leak","inner":{"x":"leak2"}}}"#)

        #expect(!redacted.contains("leak"))
        #expect(redacted.contains(LogRedaction.placeholder))
    }

    @Test("JSON 이 아니면 원문을 내보내지 않는다")
    func doesNotEmitNonJSONBody() {
        let redacted = LogRedaction.redacted(body: Data("credential=956ThisisDemo++Hilit".utf8))

        #expect(!redacted.contains("956ThisisDemo++Hilit"))
        #expect(redacted.contains("bytes"))
    }

    @Test("가릴 것이 없는 JSON 은 그대로 통과한다")
    func passesThroughCleanJSON() {
        let redacted = Self.json(#"{"page":1,"size":20}"#)

        #expect(redacted.contains("\"page\":1"))
        #expect(redacted.contains("\"size\":20"))
    }
}
