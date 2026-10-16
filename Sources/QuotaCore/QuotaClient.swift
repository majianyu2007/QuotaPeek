import Foundation

public enum QuotaClient {
    private static let maximumResponseBytes = 1_048_576

    /// Accept a service root, /v1, or /v1/usage while retaining a reverse-proxy prefix.
    public static func endpoint(for baseURL: String) throws -> URL {
        let input = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty,
              !input.contains(where: { $0.isWhitespace || $0.isNewline }),
              var components = URLComponents(string: input),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true else {
            throw QuotaError.invalidURL
        }
        let loopbackHosts = ["localhost", "127.0.0.1", "::1", "[::1]"]
        guard scheme == "https" || (scheme == "http" && loopbackHosts.contains(host.lowercased())) else {
            throw QuotaError.insecureURL
        }
        components.scheme = scheme
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/v1/usage") {
            // Already the endpoint; do not duplicate the version or usage suffix.
        } else if path.hasSuffix("/v1") {
            path += "/usage"
        } else {
            path += "/v1/usage"
        }
        components.percentEncodedPath = path
        guard let url = components.url else { throw QuotaError.invalidURL }
        return url
    }

    public static func fetch(baseURL: String, apiKey: String, timeout: TimeInterval = 15) async throws -> QuotaSnapshot {
        let url = try endpoint(for: baseURL)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty,
              !apiKey.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw QuotaError.invalidKey
        }
        guard timeout.isFinite, (1...60).contains(timeout) else { throw QuotaError.invalidTimeout }
        try Task.checkCancellation()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: RejectRedirects())
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw QuotaError.invalidResponse }
            if (300...399).contains(response.statusCode) { throw QuotaError.redirectForbidden }
            guard (200...299).contains(response.statusCode) else {
                throw QuotaError.http(response.statusCode, reason: await errorCode(from: bytes))
            }
            guard response.expectedContentLength <= Int64(maximumResponseBytes) else { throw QuotaError.responseTooLarge }
            var data = Data()
            if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
            // AsyncBytes streams the body, including decompressed bytes, rather than buffering an unbounded response.
            for try await byte in bytes {
                guard data.count < maximumResponseBytes else { throw QuotaError.responseTooLarge }
                if data.count.isMultiple(of: 4096) { try Task.checkCancellation() }
                data.append(byte)
            }
            try Task.checkCancellation()
            return try QuotaParser.parse(data)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as QuotaError {
            throw error
        } catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
            if error.code == .timedOut { throw QuotaError.timedOut }
            throw QuotaError.network
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw QuotaError.network
        }
    }
}

extension QuotaClient {
    /// Only short identifiers are kept; free-form server text could echo the key.
    static func errorCode(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let error = root["error"] as? [String: Any] ?? root
        for field in ["code", "type"] {
            if let value = error[field] as? String,
               value.range(of: "^[A-Za-z][A-Za-z0-9_.-]{0,63}$", options: .regularExpression) != nil {
                return value
            }
        }
        return nil
    }

    private static func errorCode(from bytes: URLSession.AsyncBytes) async -> String? {
        var data = Data()
        do {
            for try await byte in bytes {
                guard data.count < 16_384 else { return nil }
                data.append(byte)
            }
        } catch { return nil }
        return errorCode(from: data)
    }
}

private final class RejectRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
