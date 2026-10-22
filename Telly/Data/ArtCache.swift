import CryptoKit
import Foundation
import ImageIO
import SwiftUI

/**
 * Artwork kept on the device for what's downloaded, in My List or in Continue watching, so those
 * cards keep their pictures with no connection. Everything else comes from the network as it's
 * shown. One folder per provider, files named by a hash of the address; a provider's folder only
 * ever holds what it currently needs.
 */
enum ArtCache {
    private static var dir: URL { Device.dataDirectory.appendingPathComponent("art", isDirectory: true) }

    private static func file(_ url: URL, _ providerId: String) -> URL {
        let name = SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(providerId, isDirectory: true).appendingPathComponent(name)
    }

    /** Decoded images, so scrolling back past a card doesn't decode it again. */
    private static let memory: NSCache<NSURL, CGImage> = {
        let c = NSCache<NSURL, CGImage>()
        c.countLimit = 300
        return c
    }()

    private static func decode(_ data: Data) -> CGImage? {
        if let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return image
        }
        // What ImageIO can't read (an SVG, say), the system's own image type sometimes can.
        #if os(iOS)
        return UIImage(data: data)?.cgImage
        #else
        return NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
    }

    /** The saved copy if there is one, otherwise from the network. */
    static func image(_ url: URL, providerId: String?) async -> CGImage? {
        if let hit = memory.object(forKey: url as NSURL) { return hit }
        let saved = providerId.map { file(url, $0) }
        let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            if let saved, let data = try? Data(contentsOf: saved), let image = decode(data) { return image }
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode ?? 200 == 200 else { return nil }
            return decode(data)
        }.value
        if let image { memory.setObject(image, forKey: url as NSURL) }
        return image
    }

    /**
     * Makes a provider's saved artwork exactly [urls]: fetches what's missing, deletes the rest,
     * and drops the folders of providers that are gone. Stops quietly if cancelled.
     */
    static func keep(_ urls: Set<URL>, providerId: String, providers: Set<String>) async {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            for old in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            where !providers.contains(old.lastPathComponent) {
                try? fm.removeItem(at: old)
            }
            let folder = dir.appendingPathComponent(providerId, isDirectory: true)
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let wanted = Dictionary(urls.map { (file($0, providerId).lastPathComponent, $0) }, uniquingKeysWith: { a, _ in a })
            for old in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            where wanted[old.lastPathComponent] == nil {
                try? fm.removeItem(at: old)
            }
            for (name, url) in wanted where !fm.fileExists(atPath: folder.appendingPathComponent(name).path) {
                if Task.isCancelled { return }
                guard let (data, response) = try? await URLSession.shared.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode ?? 200 == 200, decode(data) != nil else { continue }
                try? data.write(to: folder.appendingPathComponent(name), options: [.atomic, Device.fileProtection])
            }
        }.value
    }
}

/** Keeps the active provider's saved artwork in step with its downloads, My List and Continue watching. */
struct ArtKeeper: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        // Nothing until the lists have loaded: My List would look empty and lose its artwork.
        Color.clear.task(id: app.live == nil ? nil : wanted) {
            guard let id = app.activeId, app.live != nil else { return }
            // Settles first: My List and progress change in bursts.
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await ArtCache.keep(wanted, providerId: id, providers: Set(app.providers.map(\.id)))
        }
    }

    private var wanted: Set<URL> {
        let mine = app.favouriteItems()
        var art: [String?] = mine.live.map(\.logo) + mine.films.map(\.logo) + mine.series.map(\.cover)
        for h in app.continueWatching {
            let item = h.items[h.continueIndex(app.progressOf)]
            art += [h.art, item.logo]
        }
        art += Downloads.shared.items(for: app.activeId).map(\.art)
        return Set(art.compactMap { Artwork.allowed($0, app) })
    }
}
