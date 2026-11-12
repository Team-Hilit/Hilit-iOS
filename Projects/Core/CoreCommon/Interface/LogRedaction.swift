//
//  LogRedaction.swift
//  CoreCommonInterface
//

import Foundation

/// 상세 로그에 실리는 헤더·바디에서 자격증명을 가린다.
///
/// `LogGate.isVerbose` 는 «찍을지» 를 정하고 여기는 «무엇을 찍을지» 를 정한다 — 게이트가 열린 뒤에도
/// 토큰이 콘솔에 남지 않게 하는 층이다. 로거가 여럿(요청·응답·디코딩 실패)이라 판정을 한 곳에 모은다:
/// 로거마다 각자 가리면 새 로거가 늘 때 빠뜨린다.
///
/// 가림은 **키 이름**으로 판정한다(값의 모양으로 추측하지 않는다) — 서버가 필드를 늘려도
/// 이름에 `token`·`credential` 이 들어가면 자동으로 걸린다.
public enum LogRedaction {
    /// 가려진 값 자리에 남기는 표시.
    public static let placeholder = "***"

    /// 값을 가릴 헤더 — 정규화(소문자·구분자 제거) 후 완전일치로 본다.
    private static let sensitiveHeaders: Set<String> = [
        "authorization",
        "cookie",
        "proxyauthorization",
        "setcookie",
        "xapikey"
    ]

    /// 값을 가릴 JSON 키 — 정규화 후 **부분일치**. `accessToken`·`refresh_token` 이 `token` 하나로 걸린다.
    private static let sensitiveKeyFragments = [
        "apikey",
        "authorization",
        "credential",
        "password",
        "secret",
        "token"
    ]

    /// 민감 헤더의 값을 `placeholder` 로 바꾼다. 키는 남긴다 — 어떤 헤더가 붙었는지는 디버깅에 필요하고
    /// 이름 자체는 비밀이 아니다.
    public static func redacted(headers: [String: String]) -> [String: String] {
        headers.reduce(into: [:]) { output, pair in
            output[pair.key] = sensitiveHeaders.contains(normalized(pair.key)) ? placeholder : pair.value
        }
    }

    /// 바디를 찍을 수 있는 문자열로 만든다.
    ///
    /// JSON 이면 민감 키의 값만 가리고 나머지 구조는 보존한다(중첩 객체·배열도 따라 내려간다).
    /// JSON 이 아니면 **원문을 내보내지 않는다** — 폼 인코딩·바이너리엔 키 구조가 없어 가릴 수가 없고,
    /// 그대로 찍으면 가림이 뚫린다. 대신 크기만 남겨 «바디가 있었다» 는 사실은 지킨다.
    public static func redacted(body: Data) -> String {
        guard
            let parsed = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])
        else {
            return "<non-JSON body, \(body.count) bytes>"
        }
        guard
            // sortedKeys — 로그 줄이 호출마다 달라지지 않게(테스트도 이 순서에 의존).
            let data = try? JSONSerialization.data(
                withJSONObject: redacting(parsed), options: [.fragmentsAllowed, .sortedKeys]
            ),
            let json = String(data: data, encoding: .utf8)
        else {
            return "<unprintable body, \(body.count) bytes>"
        }
        return json
    }

    /// JSON 트리를 내려가며 민감 키의 값을 치환한다. 민감 키를 만나면 그 아래는 보지 않는다 —
    /// 값이 객체여도 통째로 비밀이다.
    private static func redacting(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            return dictionary.reduce(into: [String: Any]()) { output, pair in
                output[pair.key] = isSensitive(key: pair.key) ? placeholder : redacting(pair.value)
            }
        case let array as [Any]:
            return array.map(redacting)
        default:
            return value
        }
    }

    private static func isSensitive(key: String) -> Bool {
        let key = normalized(key)
        return sensitiveKeyFragments.contains { key.contains($0) }
    }

    /// 대소문자·구분자 차이를 지운다 — `Set-Cookie`·`set_cookie`·`setCookie` 가 한 값으로 모인다.
    private static func normalized(_ key: String) -> String {
        key.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
