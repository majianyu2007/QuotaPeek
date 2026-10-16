import Foundation
import CoreFoundation

public struct QuotaWindow: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let usedPercent: Double
    public let resetsAt: Date?

    public init(id: String, title: String, usedPercent: Double, resetsAt: Date?) {
        self.id = id
        self.title = title
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

public struct QuotaSnapshot: Sendable {
    public let windows: [QuotaWindow]
    public let fetchedAt: Date
    public let source: String?

    public init(windows: [QuotaWindow], fetchedAt: Date, source: String?) {
        self.windows = windows
        self.fetchedAt = fetchedAt
        self.source = source
    }
}

public enum QuotaError: Error, LocalizedError, Sendable, Equatable {
    case invalidJSON
    case unsupportedFormat
    case unsupportedUnit
    case invalidUtilization
    case noWindows
    case invalidURL
    case insecureURL
    case invalidKey
    case invalidTimeout
    case redirectForbidden
    case responseTooLarge
    case invalidResponse
    case http(Int, reason: String? = nil)
    case network
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .invalidJSON: return "响应不是有效的 JSON，请检查服务地址。"
        case .unsupportedFormat: return "响应格式不受支持，需要 VM2API 或 Claude 兼容的用量接口。"
        case .unsupportedUnit: return "用量单位不受支持，需要 percent_used 百分比。"
        case .invalidUtilization: return "响应中的用量无效，必须是 0 到 100 的数字百分比。"
        case .noWindows: return "响应没有可用的用量窗口；未知用量不会显示为零。"
        case .invalidURL: return "服务地址无效，请输入不含账号、密码、查询参数或片段的完整 HTTPS 地址。"
        case .insecureURL: return "为保护 API Key，仅允许 HTTPS；本机 localhost、127.0.0.1 或 ::1 可使用 HTTP。"
        case .invalidKey: return "请输入有效的 API Key，且不要包含换行。"
        case .invalidTimeout: return "请求超时时间必须为 1 到 60 秒。"
        case .redirectForbidden: return "接口尝试重定向，已阻止以保护 API Key；请直接填写最终服务地址。"
        case .responseTooLarge: return "接口响应过大，已停止读取；请检查是否填写了正确的用量接口。"
        case .invalidResponse: return "服务器未返回有效的 HTTP 响应。"
        case .http(let code, let reason):
            let detail = reason.map { "（\(code) \($0)）" } ?? "（\(code)）"
            switch code {
            case 401: return "认证失败\(detail)，请检查 API Key。"
            case 403: return "无权读取用量\(detail)，请检查 API Key 的权限。"
            case 404: return "未找到用量接口\(detail)，请检查服务地址及其路径前缀。"
            case 429: return "请求过于频繁\(detail)，请稍后刷新。"
            case 500...599: return "服务端出错\(detail)，请稍后重试；持续出现请联系服务提供方。"
            default: return "用量请求失败\(detail)，请检查服务配置。"
            }
        case .network: return "无法连接用量服务，请检查网络、服务地址及 TLS 证书。"
        case .timedOut: return "请求超时，请检查网络或稍后刷新。"
        }
    }
}

public enum QuotaParser {
    private static func validateUnit(_ object: [String: Any]) throws {
        if let unit = object["unit"] {
            guard let text = unit as? String, text == "percent_used" else {
                throw QuotaError.unsupportedUnit
            }
        }
    }

    /// VM2API sends ISO 8601 or Unix seconds (as a number or a digit string) depending on the data source.
    private static func resetDate(_ raw: Any?, fractional: ISO8601DateFormatter, standard: ISO8601DateFormatter) -> Date? {
        let seconds: Double?
        if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            seconds = number.doubleValue
        } else if let text = raw as? String {
            if let date = fractional.date(from: text) ?? standard.date(from: text) { return date }
            seconds = text.allSatisfy(\.isASCII) ? Double(text) : nil
        } else {
            seconds = nil
        }
        // Reject milliseconds and nonsense: valid range is 2001 through 2100.
        guard let seconds, seconds.isFinite, (978_307_200...4_102_444_800).contains(seconds) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Only the documented named percentage windows are accepted. Null means unknown, not zero.
    public static func parse(_ data: Data) throws -> QuotaSnapshot {
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) }
        catch { throw QuotaError.invalidJSON }
        guard var root = object as? [String: Any] else { throw QuotaError.unsupportedFormat }
        try validateUnit(root)
        if let envelope = root["data"] {
            guard let payload = envelope as? [String: Any] else { throw QuotaError.unsupportedFormat }
            try validateUnit(payload)
            root = payload
        }
        let definitions = [
            ("five_hour", "5 小时"),
            ("seven_day", "7 天"),
            ("seven_day_sonnet", "Sonnet · 7 天"),
            ("seven_day_opus", "Opus · 7 天")
        ]
        var windows: [QuotaWindow] = []
        var recognized = false
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        for (id, title) in definitions {
            guard let raw = root[id] else { continue }
            recognized = true
            if raw is NSNull { continue }
            guard let window = raw as? [String: Any] else { throw QuotaError.unsupportedFormat }
            guard let rawUtilization = window["utilization"], !(rawUtilization is NSNull) else { continue }
            guard let number = rawUtilization as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { throw QuotaError.invalidUtilization }
            let utilization = number.doubleValue
            guard utilization.isFinite, (0...100).contains(utilization) else { throw QuotaError.invalidUtilization }
            let reset = resetDate(window["resets_at"], fractional: fractional, standard: standard)
            windows.append(QuotaWindow(id: id, title: title, usedPercent: utilization, resetsAt: reset))
        }
        guard recognized else { throw QuotaError.unsupportedFormat }
        guard !windows.isEmpty else { throw QuotaError.noWindows }
        return QuotaSnapshot(windows: windows, fetchedAt: Date(), source: root["source"] as? String)
    }
}
