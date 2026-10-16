import Foundation
import Darwin
import QuotaCore

@main
struct QuotaPeekCLI {
    private enum CLIError: Error, LocalizedError {
        case arguments, file, keyInput
        var errorDescription: String? {
            switch self {
            case .arguments: return "参数无效。使用 --base-url URL [--key-stdin] 或 --parse FILE；--help 查看帮助。"
            case .file: return "无法读取 JSON 文件，或文件超过 1 MiB。"
            case .keyInput: return "无法读取 API Key。请设置 QUOTAPEEK_API_KEY，或通过 --key-stdin 输入单行密钥。"
            }
        }
    }

    private static func readBounded(_ handle: FileHandle, maximum: Int, error: CLIError) throws -> Data {
        var data = Data()
        while let chunk = try handle.read(upToCount: min(8192, maximum - data.count + 1)), !chunk.isEmpty {
            guard chunk.count <= maximum - data.count else { throw error }
            data.append(chunk)
        }
        return data
    }

    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--help"] || arguments == ["-h"] {
                print("""
                quota-peek --base-url URL [--key-stdin]
                quota-peek --parse FILE

                默认从 QUOTAPEEK_API_KEY 环境变量读取 API Key。
                --key-stdin 从标准输入读取密钥（请勿把密钥放在命令行参数中）。
                --parse 只解析已保存的 JSON，不发起网络请求。
                输出 JSON 包含已知用量窗口、百分比和可用的重置时间；未知用量不显示为零。
                """)
                return
            }
            var baseURL: String?
            var parseFile: String?
            var keyStdin = false
            var index = 0
            while index < arguments.count {
                switch arguments[index] {
                case "--base-url":
                    guard baseURL == nil, index + 1 < arguments.count else { throw CLIError.arguments }
                    index += 1
                    baseURL = arguments[index]
                case "--parse":
                    guard parseFile == nil, index + 1 < arguments.count else { throw CLIError.arguments }
                    index += 1
                    parseFile = arguments[index]
                case "--key-stdin":
                    guard !keyStdin else { throw CLIError.arguments }
                    keyStdin = true
                default: throw CLIError.arguments
                }
                index += 1
            }
            let snapshot: QuotaSnapshot
            if let parseFile {
                guard baseURL == nil, !keyStdin else { throw CLIError.arguments }
                let data: Data
                do {
                    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: parseFile))
                    defer { try? handle.close() }
                    data = try readBounded(handle, maximum: 1_048_576, error: .file)
                } catch { throw CLIError.file }
                snapshot = try QuotaParser.parse(data)
            } else if let baseURL {
                let key: String
                if keyStdin {
                    let input: Data
                    do { input = try readBounded(.standardInput, maximum: 65_536, error: .keyInput) }
                    catch { throw CLIError.keyInput }
                    guard var text = String(data: input, encoding: .utf8) else { throw CLIError.keyInput }
                    // Permit a single conventional line terminator, not embedded or multiple lines.
                    if text.hasSuffix("\r\n") || text.hasSuffix("\n") { text.removeLast() }
                    key = text
                } else {
                    guard let value = ProcessInfo.processInfo.environment["QUOTAPEEK_API_KEY"] else { throw CLIError.keyInput }
                    key = value
                }
                snapshot = try await QuotaClient.fetch(baseURL: baseURL, apiKey: key)
            } else { throw CLIError.arguments }

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let windows: [[String: Any]] = snapshot.windows.map { window in
                var result: [String: Any] = ["id": window.id, "title": window.title, "used_percent": window.usedPercent]
                if let date = window.resetsAt { result["resets_at"] = formatter.string(from: date) }
                else { result["resets_at"] = NSNull() }
                return result
            }
            // Source and raw server fields are intentionally excluded from diagnostic output.
            let output = try JSONSerialization.data(withJSONObject: ["windows": windows], options: [.prettyPrinted, .sortedKeys])
            FileHandle.standardOutput.write(output)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            let message: String
            if error is CancellationError { message = "请求已取消。" }
            else if let localized = error as? LocalizedError { message = localized.errorDescription ?? "请求失败。" }
            else { message = "无法完成请求。" }
            FileHandle.standardError.write(Data((message + "\n").utf8))
            exit(1)
        }
    }
}
