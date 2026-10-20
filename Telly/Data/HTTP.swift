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
        c.httpAdditionalHeaders = ["User-Agent": "telly-ipad/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1")"]
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    static func host(_ url: URL) -> String { url.host ?? "The provider" }

    func data(_ url: URL) async throws -> Data {
        if url.scheme == "http" && !allowCleartext {
            throw ProviderError("Unencrypted HTTP to \(HTTP.host(url)) is turned off. If your provider has no HTTPS, allow it in Settings.")
        }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(from: url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProviderError("Couldn't reach \(HTTP.host(url)).")
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

func parseJSON(_ data: Data) throws -> Any {
    do {
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    } catch {
        throw ProviderError("The provider did not return valid JSON. Check the server address.")
    }
}
