import Foundation

struct SyncError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/** Talking to the relay. Only sealed parcels ever leave the device. */
enum SyncClient {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    private static func send(_ method: String, _ url: URL, _ keys: SyncCrypto.Keys, body: Data? = nil) async throws -> Data {
        guard url.scheme == "https" || url.host == "localhost" || url.host == "127.0.0.1" else {
            throw SyncError(message: "The sync relay must use HTTPS.")
        }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("Bearer \(keys.auth)", forHTTPHeaderField: "Authorization")
        if let body {
            r.httpBody = body
            r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: r) } catch { throw SyncError(message: "Couldn't reach the sync relay.") }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return data
        case 401: throw SyncError(message: "This sync code is no longer valid on the relay.")
        case 409: throw SyncError(message: "Too many devices are linked to this code (12 at most).")
        default: throw SyncError(message: "The sync relay answered \(status).")
        }
    }

    private static func base(_ relay: String) -> String {
        var s = relay
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /** Every other device's parcel that opens with our key; anything else is ignored. A version 1
     *  parcel is read as belonging to [current], the active provider's tag. */
    static func pull(_ relay: String, _ keys: SyncCrypto.Keys, device: String, current: String) async throws -> [SyncBundle] {
        guard let url = URL(string: "\(base(relay))/v1/\(keys.mailbox)") else { throw SyncError(message: "The relay address isn't right.") }
        let data = try await send("GET", url, keys)
        let parcels = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["parcels"] as? [[String: Any]] ?? []
        return parcels.compactMap { p in
            guard let from = p["device"] as? String, from != device,
                  let b64 = p["body"] as? String, let box = Data(base64Encoded: b64),
                  let text = SyncCrypto.open(keys, device: from, box) else { return nil }
            return SyncBundle.parse(text, current: current, keys: keys, device: from)
        }
    }

    static func push(_ relay: String, _ keys: SyncCrypto.Keys, device: String, _ bundle: SyncBundle) async throws {
        guard let url = URL(string: "\(base(relay))/v1/\(keys.mailbox)/\(device)") else { throw SyncError(message: "The relay address isn't right.") }
        let body = try SyncCrypto.seal(keys, device: device, bundle.json(keys: keys, device: device))
        _ = try await send("PUT", url, keys, body: body)
    }

    /** Takes this device's parcel off the relay (the others keep theirs). */
    static func leave(_ relay: String, _ keys: SyncCrypto.Keys, device: String) async throws {
        guard let url = URL(string: "\(base(relay))/v1/\(keys.mailbox)/\(device)") else { return }
        _ = try await send("DELETE", url, keys)
    }

    static func syncOnce(_ relay: String, _ keys: SyncCrypto.Keys, device: String, own: SyncBundle, current: String, now: Double) async throws -> SyncBundle {
        let merged = SyncBundle.merge(own, try await pull(relay, keys, device: device, current: current), now: now)
        try await push(relay, keys, device: device, merged)
        return merged
    }
}
