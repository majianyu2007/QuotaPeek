import Foundation
import XCTest
@testable import QuotaCore

final class QuotaCoreTests: XCTestCase {
    private func parse(_ json: String) throws -> QuotaSnapshot {
        try QuotaParser.parse(Data(json.utf8))
    }

    private func assertParserError(_ json: String, _ expected: QuotaError, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try parse(json), file: file, line: line) {
            XCTAssertEqual($0 as? QuotaError, expected, file: file, line: line)
        }
    }

    func testActualVM2APIResponsePreservesZeroAndFractionalDate() throws {
        let snapshot = try parse(#"{"unit":"percent_used","five_hour":{"utilization":0,"status":"allowed","resets_at":"2026-10-15T17:19:59.796566+00:00"},"seven_day":{"utilization":58,"status":"allowed","resets_at":"2026-10-22T17:19:59Z"},"source":"extra"}"#)
        XCTAssertEqual(snapshot.windows.map(\.id), ["five_hour", "seven_day"])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [0, 58])
        XCTAssertEqual(snapshot.source, "extra")
        let formatter = ISO8601DateFormatter()
        let wholeSecond = try XCTUnwrap(formatter.date(from: "2026-10-15T17:19:59Z"))
        XCTAssertEqual(try XCTUnwrap(snapshot.windows[0].resetsAt).timeIntervalSince(wholeSecond), 0.796566, accuracy: 0.002)
        XCTAssertEqual(snapshot.windows[1].resetsAt, formatter.date(from: "2026-10-22T17:19:59Z"))
    }

    func testClaudeWindowsAndDataEnvelope() throws {
        let snapshot = try parse(#"{"data":{"five_hour":{"utilization":0.25},"seven_day":{"utilization":100},"seven_day_sonnet":{"utilization":12.5},"seven_day_opus":{"utilization":99.99}}}"#)
        XCTAssertEqual(snapshot.windows.map(\.id), ["five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus"])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [0.25, 100, 12.5, 99.99])
        XCTAssertTrue(snapshot.windows.allSatisfy { $0.resetsAt == nil })
    }

    func testNullAndMissingUtilizationAreNotZero() throws {
        let snapshot = try parse(#"{"five_hour":{"utilization":null},"seven_day":{"utilization":0},"seven_day_sonnet":{},"seven_day_opus":null}"#)
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows.first?.id, "seven_day")
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 0)
        assertParserError(#"{"five_hour":{"utilization":null}}"#, .noWindows)
        assertParserError(#"{"five_hour":{},"seven_day":null}"#, .noWindows)
    }

    func testRejectsBooleanStringNegativeAndOverHundred() {
        for value in ["true", "false", "\"58\"", "-0.001", "100.001", "[]", "{}"] {
            assertParserError("{\"five_hour\":{\"utilization\":\(value)}}", .invalidUtilization)
        }
    }

    func testRejectsMalformedWindowEvenAlongsideValidOne() {
        assertParserError(#"{"five_hour":{"utilization":0},"seven_day":{"utilization":true}}"#, .invalidUtilization)
        assertParserError(#"{"five_hour":{"utilization":0},"seven_day":42}"#, .unsupportedFormat)
    }

    func testRejectsUnknownAndMalformedUnits() {
        for unit in ["\"fraction\"", "\"percent_remaining\"", "\"percent\"", "null", "true", "1"] {
            assertParserError("{\"unit\":\(unit),\"five_hour\":{\"utilization\":50}}", .unsupportedUnit)
        }
        assertParserError(#"{"data":{"unit":"fraction","five_hour":{"utilization":0.5}}}"#, .unsupportedUnit)
        assertParserError(#"{"unit":"fraction","data":{"five_hour":{"utilization":0.5}}}"#, .unsupportedUnit)
    }

    func testDoesNotGuessArbitraryUsageFormats() {
        for json in [#"{"used":50,"limit":100}"#, #"{"usage":{"five_hour":{"utilization":5}}}"#, #"{"windows":[{"utilization":5}]}"#, #"{"monthly":{"utilization":5}}"#, "[]", "{}", #"{"data":null}"#] {
            assertParserError(json, .unsupportedFormat)
        }
        assertParserError("not json", .invalidJSON)
        assertParserError(#"{"five_hour":{"utilization":NaN}}"#, .invalidJSON)
    }

    func testInvalidOptionalResetDatesStayAbsent() throws {
        for date in ["null", "42", "true", "\"tomorrow\"", "\"\""] {
            let snapshot = try parse("{\"five_hour\":{\"utilization\":8,\"resets_at\":\(date)}}")
            XCTAssertNil(snapshot.windows.first?.resetsAt)
        }
    }

    func testRootVersionAndEndpointNormalization() throws {
        let cases = [
            ("https://example.com", "https://example.com/v1/usage"),
            ("https://example.com/", "https://example.com/v1/usage"),
            ("https://example.com/v1", "https://example.com/v1/usage"),
            ("https://example.com/v1/", "https://example.com/v1/usage"),
            ("https://example.com/v1/usage", "https://example.com/v1/usage"),
            ("https://example.com/v1/usage///", "https://example.com/v1/usage"),
            (" https://example.com/proxy/team/ \n", "https://example.com/proxy/team/v1/usage"),
            ("https://example.com:8443/proxy/v1", "https://example.com:8443/proxy/v1/usage"),
            ("https://example.com/proxy/v1/usage", "https://example.com/proxy/v1/usage"),
            ("https://example.com/team%20one", "https://example.com/team%20one/v1/usage"),
            ("https://example.com/not-v1", "https://example.com/not-v1/v1/usage")
        ]
        for (input, expected) in cases {
            XCTAssertEqual(try QuotaClient.endpoint(for: input).absoluteString, expected)
        }
    }

    func testHTTPOnlyAllowedForExactLoopbackHosts() throws {
        for input in ["http://localhost:8080", "http://127.0.0.1:8080/proxy", "http://[::1]:8080"] {
            XCTAssertEqual(try QuotaClient.endpoint(for: input).scheme, "http")
        }
        for input in ["http://example.com", "http://192.168.1.1", "http://localhost.evil.test", "http://127.0.0.1.evil.test", "ftp://localhost", "file:///tmp/quota.json"] {
            XCTAssertThrowsError(try QuotaClient.endpoint(for: input))
        }
    }

    func testRejectsCredentialsQueriesFragmentsAndRelativeURLs() {
        for input in ["", "example.com", "/v1/usage", "//example.com", "https://user@example.com", "https://user:secret@example.com", "https://example.com?key=secret", "https://example.com?", "https://example.com#fragment", "https://example.com#", "https://example.com/a b", "https://example.com:0", "https://example.com:65536"] {
            XCTAssertThrowsError(try QuotaClient.endpoint(for: input), "Unexpected acceptance: \(input)")
        }
    }

    func testInvalidKeysFailBeforeNetworkAccess() async {
        for key in ["", "  ", "secret\n", "secret\r", "secret\r\nInjected: value"] {
            do {
                _ = try await QuotaClient.fetch(baseURL: "https://example.invalid", apiKey: key)
                XCTFail("Invalid key was accepted")
            } catch { XCTAssertEqual(error as? QuotaError, .invalidKey) }
        }
    }

    func testTimeoutBoundsFailBeforeNetworkAccess() async {
        for timeout in [-1.0, 0, 0.5, 60.01, Double.infinity, Double.nan] {
            do {
                _ = try await QuotaClient.fetch(baseURL: "https://example.invalid", apiKey: "dummy", timeout: timeout)
                XCTFail("Invalid timeout was accepted")
            } catch { XCTAssertEqual(error as? QuotaError, .invalidTimeout) }
        }
    }

    func testCancellationBeforeRequest() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await QuotaClient.fetch(baseURL: "https://example.invalid", apiKey: "dummy")
                XCTFail("Cancelled request was accepted")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
        await task.value
    }

    func testErrorCodeKeepsOnlyShortIdentifiers() {
        func code(_ json: String) -> String? { QuotaClient.errorCode(from: Data(json.utf8)) }
        XCTAssertEqual(code(#"{"error":{"type":"overloaded_error","code":"pool_unavailable","message":"号池当前没有可用账号"}}"#), "pool_unavailable")
        XCTAssertEqual(code(#"{"error":{"type":"server_error","message":"boom"}}"#), "server_error")
        XCTAssertNil(code(#"{"error":{"code":"Bearer sk-secret leaked"}}"#))
        XCTAssertNil(code("<html>503</html>"))
        XCTAssertEqual(QuotaError.http(503, reason: "pool_unavailable").errorDescription,
                       "服务端出错（503 pool_unavailable），请稍后重试；持续出现请联系服务提供方。")
    }

    func testUnixSecondResetTimes() throws {
        let snapshot = try parse(#"{"unit":"percent_used","five_hour":{"utilization":17,"resets_at":"1792120800"},"seven_day":{"utilization":59,"resets_at":1792436400}}"#)
        XCTAssertEqual(snapshot.windows.map(\.resetsAt), [Date(timeIntervalSince1970: 1_792_120_800), Date(timeIntervalSince1970: 1_792_436_400)])
        let rejected = try parse(#"{"five_hour":{"utilization":1,"resets_at":"1792120800000"},"seven_day":{"utilization":1,"resets_at":"soon"}}"#)
        XCTAssertEqual(rejected.windows.map(\.resetsAt), [nil, nil])
    }
}
