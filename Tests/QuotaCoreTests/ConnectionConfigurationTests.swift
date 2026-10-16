import Foundation
import XCTest
@testable import QuotaCore

final class ConnectionConfigurationTests: XCTestCase {
    private func decode(_ json: String) throws -> Preferences {
        try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
    }

    func testPopulatedLegacyConfigurationRetainsKeychainIdentityAndSettings() throws {
        let preferences = try decode(#"{"baseURL":" https://example.com/proxy/ \n","name":" 工作账号 ","refreshMinutes":15,"showRemaining":false,"appearance":"dark","notifications":true,"warningPercent":90}"#)
        XCTAssertEqual(preferences.profiles, [ConnectionProfile(id: "default", name: "工作账号", baseURL: "https://example.com/proxy/")])
        XCTAssertEqual(preferences.selectedProfileID, "default")
        XCTAssertEqual(preferences.refreshMinutes, 15)
        XCTAssertFalse(preferences.showRemaining)
        XCTAssertEqual(preferences.appearance, "dark")
        XCTAssertTrue(preferences.notifications)
        XCTAssertEqual(preferences.warningPercent, 90)
        XCTAssertEqual(preferences.menuBarMode, "selected")
        XCTAssertTrue(preferences.showProfileName)

        let data = try JSONEncoder().encode(preferences)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 2)
        XCTAssertNil(object["baseURL"])
        XCTAssertNil(object["name"])
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: data), preferences)
    }

    func testEmptyLegacyConfigurationDoesNotCreateAConnection() throws {
        for baseURL in ["", "   "] {
            let preferences = try decode("{\"baseURL\":\"\(baseURL)\",\"name\":\"未配置\",\"refreshMinutes\":2,\"showRemaining\":false,\"appearance\":\"light\",\"notifications\":true,\"warningPercent\":95}")
            XCTAssertTrue(preferences.profiles.isEmpty)
            XCTAssertNil(preferences.selectedProfileID)
            XCTAssertEqual(preferences.refreshMinutes, 2)
            XCTAssertFalse(preferences.showRemaining)
            XCTAssertEqual(preferences.appearance, "light")
            XCTAssertTrue(preferences.notifications)
            XCTAssertEqual(preferences.warningPercent, 95)
        }
    }

    func testExplicitLegacyVersionUsesTheSameMigration() throws {
        let preferences = try decode(#"{"version":1,"baseURL":"https://example.com"}"#)
        XCTAssertEqual(preferences.profiles.first?.id, "default")
        XCTAssertEqual(preferences.selectedProfileID, "default")
    }

    func testMultipleProfilesAndEverySettingRoundTrip() throws {
        var preferences = Preferences()
        preferences.profiles = [
            ConnectionProfile(id: "first", name: "同名账号", baseURL: "https://example.com"),
            ConnectionProfile(id: "second", name: "同名账号", baseURL: "https://example.com", enabled: false),
            ConnectionProfile(id: "third", name: "第三个账号", baseURL: "https://other.example.com/v1")
        ]
        preferences.selectedProfileID = "second"
        preferences.refreshMinutes = 30
        preferences.showRemaining = false
        preferences.appearance = "light"
        preferences.notifications = true
        preferences.warningPercent = 95
        preferences.menuBarMode = "tightest"
        preferences.showProfileName = false

        let data = try JSONEncoder().encode(preferences)
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: data), preferences)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 2)
        let profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        XCTAssertEqual(profiles.count, 3)
        XCTAssertTrue(profiles.allSatisfy { Set($0.keys) == Set(["id", "name", "baseURL", "enabled"]) })
    }

    func testDefaultsAndOverviewRoundTrip() throws {
        let preferences = Preferences()
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences)), preferences)
        XCTAssertEqual(try decode(#"{"version":2,"profiles":[]}"#), preferences)

        var overview = preferences
        overview.profiles = [ConnectionProfile(id: "first", name: "账号", baseURL: "https://example.com")]
        XCTAssertNil(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(overview)).selectedProfileID)
    }

    func testDuplicateProfileIDsAreRejectedOnDecodeAndEncode() throws {
        let json = #"{"version":2,"profiles":[{"id":"same","name":"A","baseURL":"https://a.example.com","enabled":true},{"id":"same","name":"B","baseURL":"https://b.example.com","enabled":false}]}"#
        XCTAssertThrowsError(try decode(json)) {
            XCTAssertEqual($0 as? ConnectionConfigurationError, .duplicateProfileID("same"))
        }
        var preferences = Preferences()
        preferences.profiles = [ConnectionProfile(id: "same"), ConnectionProfile(id: "same")]
        XCTAssertThrowsError(try JSONEncoder().encode(preferences)) {
            XCTAssertEqual($0 as? ConnectionConfigurationError, .duplicateProfileID("same"))
        }
    }

    func testFutureSchemaIsRejectedBeforeReadingOtherFields() {
        for version in [3, 99, Int.max] {
            XCTAssertThrowsError(try decode("{\"version\":\(version)}")) {
                XCTAssertEqual($0 as? ConnectionConfigurationError, .unsupportedSchemaVersion(version))
            }
        }
    }

    func testInvalidSelectionBecomesOverviewWithoutChangingProfiles() throws {
        let preferences = try decode(#"{"version":2,"profiles":[{"id":"present","name":"账号","baseURL":"https://example.com","enabled":true}],"selectedProfileID":"missing"}"#)
        XCTAssertNil(preferences.selectedProfileID)
        XCTAssertEqual(preferences.profiles.map(\.id), ["present"])
        var candidate = preferences
        candidate.selectedProfileID = "missing"
        XCTAssertNil(candidate.validated().selectedProfileID)
        candidate.selectedProfileID = "present"
        XCTAssertEqual(candidate.validated().selectedProfileID, "present")
    }

    func testValidationNormalizesSettingsAndDisplayFieldsButNeverIdentity() {
        var preferences = Preferences()
        preferences.profiles = [ConnectionProfile(id: " stable-id ", name: " \n ", baseURL: " https://example.com \n", enabled: false)]
        preferences.selectedProfileID = " stable-id "
        preferences.refreshMinutes = Int.max
        preferences.appearance = "unsupported"
        preferences.menuBarMode = "unsupported"
        preferences.warningPercent = Int.max
        let value = preferences.validated()
        XCTAssertEqual(value.profiles.first?.id, " stable-id ")
        XCTAssertEqual(value.profiles.first?.name, "我的额度")
        XCTAssertEqual(value.profiles.first?.baseURL, "https://example.com")
        XCTAssertEqual(value.profiles.first?.enabled, false)
        XCTAssertEqual(value.selectedProfileID, " stable-id ")
        XCTAssertEqual(value.refreshMinutes, 5)
        XCTAssertEqual(value.appearance, "system")
        XCTAssertEqual(value.menuBarMode, "selected")
        XCTAssertEqual(value.warningPercent, 95)
        preferences.warningPercent = Int.min
        XCTAssertEqual(preferences.validated().warningPercent, 50)
        preferences.profiles[0].name = String(repeating: "名", count: 45)
        XCTAssertEqual(preferences.validated().profiles[0].name.count, 40)
    }

    func testFiniteRefreshOptionsAndValidModesArePreserved() {
        for interval in [1, 2, 5, 15, 30] {
            var preferences = Preferences()
            preferences.refreshMinutes = interval
            XCTAssertEqual(preferences.validated().refreshMinutes, interval)
        }
        for interval in [Int.min, -1, 0, 3, 60] {
            var preferences = Preferences()
            preferences.refreshMinutes = interval
            XCTAssertEqual(preferences.validated().refreshMinutes, 5)
        }
        for appearance in ["system", "light", "dark"] {
            var preferences = Preferences()
            preferences.appearance = appearance
            XCTAssertEqual(preferences.validated().appearance, appearance)
        }
        for mode in ["selected", "tightest"] {
            var preferences = Preferences()
            preferences.menuBarMode = mode
            XCTAssertEqual(preferences.validated().menuBarMode, mode)
        }
    }

    func testMalformedConfigurationsAreNotReplacedWithDefaults() {
        for json in ["{}", #"{"version":2}"#, #"{"version":2,"profiles":null}"#, #"{"baseURL":null}"#, #"{"version":2,"profiles":[],"refreshMinutes":"five"}"#] {
            XCTAssertThrowsError(try decode(json))
        }
        XCTAssertThrowsError(try decode(#"{"version":2,"profiles":[{"id":" ","name":"账号","baseURL":"https://example.com","enabled":true}]}"#)) {
            XCTAssertEqual($0 as? ConnectionConfigurationError, .invalidProfileID)
        }
    }
}
