import Foundation

public struct ConnectionProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var baseURL: String
    public var enabled: Bool

    public init(id: String = UUID().uuidString, name: String = "", baseURL: String = "", enabled: Bool = true) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.enabled = enabled
    }
}

public enum ConnectionConfigurationError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case duplicateProfileID(String)
    case invalidProfileID

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            return "配置文件版本（\(version)）不受支持，原文件未被修改。请使用兼容版本的 QuotaPeek。"
        case .duplicateProfileID:
            return "配置文件包含重复的连接标识，原文件未被修改。"
        case .invalidProfileID:
            return "配置文件包含无效的连接标识，原文件未被修改。"
        }
    }
}

public struct Preferences: Codable, Equatable, Sendable {
    public var profiles: [ConnectionProfile] = []
    public var selectedProfileID: String? = nil
    public var refreshMinutes: Int = 5
    public var showRemaining: Bool = true
    public var appearance: String = "system"
    public var notifications: Bool = false
    public var warningPercent: Int = 80
    public var menuBarMode: String = "selected"
    public var showProfileName: Bool = true

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case version, profiles, selectedProfileID
        case refreshMinutes, showRemaining, appearance, notifications, warningPercent
        case menuBarMode, showProfileName
        case baseURL, name
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard version == 1 || version == 2 else {
            throw ConnectionConfigurationError.unsupportedSchemaVersion(version)
        }
        self.init()
        refreshMinutes = try container.decodeIfPresent(Int.self, forKey: .refreshMinutes) ?? refreshMinutes
        showRemaining = try container.decodeIfPresent(Bool.self, forKey: .showRemaining) ?? showRemaining
        appearance = try container.decodeIfPresent(String.self, forKey: .appearance) ?? appearance
        notifications = try container.decodeIfPresent(Bool.self, forKey: .notifications) ?? notifications
        warningPercent = try container.decodeIfPresent(Int.self, forKey: .warningPercent) ?? warningPercent
        menuBarMode = try container.decodeIfPresent(String.self, forKey: .menuBarMode) ?? menuBarMode
        showProfileName = try container.decodeIfPresent(Bool.self, forKey: .showProfileName) ?? showProfileName

        if version == 2 {
            profiles = try container.decode([ConnectionProfile].self, forKey: .profiles)
            selectedProfileID = try container.decodeIfPresent(String.self, forKey: .selectedProfileID)
        } else {
            // The original unversioned format always wrote baseURL, even when unconfigured.
            let baseURL = try container.decode(String.self, forKey: .baseURL)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = try container.decodeIfPresent(String.self, forKey: .name) ?? "我的额度"
            if !baseURL.isEmpty {
                // Keep the existing Keychain account; migration never reads or copies a secret.
                profiles = [ConnectionProfile(id: "default", name: name, baseURL: baseURL)]
                selectedProfileID = "default"
            }
        }
        try Self.validateProfileIDs(profiles)
        self = validated()
    }

    public func encode(to encoder: Encoder) throws {
        try Self.validateProfileIDs(profiles)
        let value = validated()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(2, forKey: .version)
        try container.encode(value.profiles, forKey: .profiles)
        try container.encodeIfPresent(value.selectedProfileID, forKey: .selectedProfileID)
        try container.encode(value.refreshMinutes, forKey: .refreshMinutes)
        try container.encode(value.showRemaining, forKey: .showRemaining)
        try container.encode(value.appearance, forKey: .appearance)
        try container.encode(value.notifications, forKey: .notifications)
        try container.encode(value.warningPercent, forKey: .warningPercent)
        try container.encode(value.menuBarMode, forKey: .menuBarMode)
        try container.encode(value.showProfileName, forKey: .showProfileName)
    }

    public func validated() -> Preferences {
        var value = self
        for index in value.profiles.indices {
            value.profiles[index].baseURL = value.profiles[index].baseURL
                .trimmingCharacters(in: .whitespacesAndNewlines)
            value.profiles[index].name = String(value.profiles[index].name
                .trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
            if value.profiles[index].name.isEmpty { value.profiles[index].name = "我的额度" }
        }
        if let selected = value.selectedProfileID, !value.profiles.contains(where: { $0.id == selected }) {
            value.selectedProfileID = nil
        }
        if ![1, 2, 5, 15, 30].contains(value.refreshMinutes) { value.refreshMinutes = 5 }
        if !["system", "light", "dark"].contains(value.appearance) { value.appearance = "system" }
        if !["selected", "tightest"].contains(value.menuBarMode) { value.menuBarMode = "selected" }
        value.warningPercent = min(95, max(50, value.warningPercent))
        return value
    }

    private static func validateProfileIDs(_ profiles: [ConnectionProfile]) throws {
        var ids = Set<String>()
        for profile in profiles {
            guard !profile.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConnectionConfigurationError.invalidProfileID
            }
            guard ids.insert(profile.id).inserted else {
                throw ConnectionConfigurationError.duplicateProfileID(profile.id)
            }
        }
    }
}
