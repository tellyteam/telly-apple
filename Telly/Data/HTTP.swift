import Foundation

/**
 * Requests to the provider. Plain HTTP is refused unless the user allows it for their provider, and
 * error messages name only the host, because Xtream URLs carry the username and password.
 */
final class HTTP: @unchecked Sendable {
    static let shared = HTTP()

    /** Follows the active provider's "allow plain HTTP" setting. */
    var allowCleartext = false

    let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.httpAdditionalHeaders = ["User-Agent": "\(Device.userAgent)/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1")"]
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    static func host(_ url: URL) -> String { url.host ?? "The provider" }

    func data(_ url: URL) async throws -> Data {
        if url.scheme == "http" && !allowCleartext {
            throw ProviderError("Unencrypted HTTP to \(HTTP.host(url)) is turned off. If your provider has no HTTPS, allow it in Settings.")
        }
        let (data, response): (Data, URLResponse)
        let guarded = RedirectGuard(allowCleartext: allowCleartext)
        do {
            (data, response) = try await session.data(from: url, delegate: guarded)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProviderError("Couldn't reach \(HTTP.host(url)).")
        }
        if guarded.refused {
            throw ProviderError("\(HTTP.host(url)) redirected to unencrypted HTTP, which is turned off. If your provider has no HTTPS, allow it in Settings.")
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ProviderError("\(HTTP.host(url)) returned HTTP \(http.statusCode).")
        }
        return data
    }

    func json(_ url: URL) async throws -> Any {
        try parseJSON(try await data(url))
    }
}

/**
 * Refuses a redirect to plain HTTP that the setting doesn't allow: checking only the first address
 * would let an https one hand the login (in the query) over unencrypted. A refused redirect ends
 * the request with the redirect's own response.
 *
 * Given the login as [secrets], plain HTTP that carries none of it is let through: many providers
 * send every stream on to a plain-HTTP server with a token address of its own.
 */
final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let allowCleartext: Bool
    let secrets: [String]
    private(set) var refused = false

    init(allowCleartext: Bool, secrets: [String] = []) {
        self.allowCleartext = allowCleartext
        self.secrets = secrets
    }

    static func allows(_ url: URL?, allowCleartext: Bool, secrets: [String] = []) -> Bool {
        switch url?.scheme?.lowercased() {
        case "https": return true
        case "http":
            if allowCleartext { return true }
            let known = secrets.filter { !$0.isEmpty }
            guard let text = url?.absoluteString, !known.isEmpty else { return false }
            return !known.contains { text.contains($0) || text.contains($0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0) }
        default: return false
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        if Self.allows(request.url, allowCleartext: allowCleartext, secrets: secrets) { return request }
        refused = true
        return nil
    }
}

func parseJSON(_ data: Data) throws -> Any {
    do {
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    } catch {
        throw ProviderError("The provider did not return valid JSON. Check the server address.")
    }
}
