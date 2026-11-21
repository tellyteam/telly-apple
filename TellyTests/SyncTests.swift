import CryptoKit
import XCTest
@testable import Telly

final class SyncCryptoTests: XCTestCase {
    private let keys = SyncCrypto.deriveKeys("0123456789ABCDEF")

    /** The shared vector in telly-sync's PROTOCOL.md; the Fire TV and Mac tests pin the same values. */
    func testMatchesTheSharedVector() throws {
        XCTAssertEqual(keys.mailbox, "964c34622b2ead29bde1300eddb81273")
        XCTAssertEqual(keys.key.withUnsafeBytes { SyncCrypto.hex($0) }, "b98184ea929152cda7eb1b420ea2d4445b5c01aa84480b86670365cb2310586e")
        XCTAssertEqual(keys.auth, "U4UwJNTeVMR0DU0Bem7LRlBoeCR4UAL9ouKh7CuGXjQ")
        let sealed = try SyncCrypto.seal(keys, device: "00112233aabbccdd", #"{"v":1}"#, nonce: Array(0..<12))
        XCTAssertEqual(SyncCrypto.hex(sealed), "01000102030405060708090a0b8c30ca4029013ae61434a3351cb312ca06d33a229d9dd9")
    }

    func testOpensOnlyWithTheRightKeyAndDevice() throws {
        let sealed = try SyncCrypto.seal(keys, device: "00112233aabbccdd", "hello")
        XCTAssertEqual(SyncCrypto.open(keys, device: "00112233aabbccdd", sealed), "hello")
        XCTAssertNil(SyncCrypto.open(keys, device: "ffffffffffffffff", sealed))
        XCTAssertNil(SyncCrypto.open(SyncCrypto.deriveKeys("1123456789ABCDEF"), device: "00112233aabbccdd", sealed))
        var tampered = sealed
        tampered[20] ^= 1
        XCTAssertNil(SyncCrypto.open(keys, device: "00112233aabbccdd", tampered))
    }

    func testCodes() {
        let code = SyncCrypto.newCode()
        XCTAssertEqual(code.count, 16)
        XCTAssertEqual(SyncCrypto.normaliseCode(code), code)
        XCTAssertEqual(SyncCrypto.normaliseCode("abcd-efgh jkmn-pqrs"), "ABCDEFGHJKMNPQRS")
        XCTAssertEqual(SyncCrypto.normaliseCode("OIL0-0000-0000-0000"), "0110000000000000")
        XCTAssertNil(SyncCrypto.normaliseCode("ABCD-EFGH-JKMN-PQRU"))
        XCTAssertEqual(SyncCrypto.formatCode("ABCDEFGHJKMNPQRS"), "ABCD-EFGH-JKMN-PQRS")
        // 80 bits from 10 bytes: all-ones bytes give all "Z".
        XCTAssertEqual(SyncCrypto.newCode([UInt8](repeating: 255, count: 10)), String(repeating: "Z", count: 16))
    }
}

final class SyncParcelTests: XCTestCase {
    func testDropsAnythingThatCouldCarryALogin() throws {
        let p = try XCTUnwrap(SyncParcel.parse("""
        {"v":1,"at":5,
         "progress":{"series/12.mkv":[1,2,3],"http://host/user/pass/12.ts":[1,2,3],"movie/5.mp4":[1,0,3]},
         "history":[{"kind":"film","id":"5","at":1},{"kind":"live","id":"http://host/u/p/1.ts","at":1},
                    {"kind":"series","id":"9","at":1},{"kind":"series","id":"9","series":"4","at":2,"removed":true}],
         "list":{"film:5":[1,true],"live:http://x":[1,true],"series:4":[1,"yes"]}}
        """))
        XCTAssertEqual(Set(p.progress.keys), ["series/12.mkv"])
        XCTAssertEqual(p.history, [SyncEntry(kind: .film, id: "5", at: 1), SyncEntry(kind: .series, id: "9", series: "4", at: 2, removed: true)])
        XCTAssertEqual(p.list, ["film:5": .init(at: 1, on: true)])
        XCTAssertNil(SyncParcel.parse(#"{"v":2}"#))
    }

    func testRoundTripsThroughJSON() {
        let p = SyncParcel(at: 9, progress: ["series/1.mkv": Progress(position: 5, duration: 10, at: 3)],
                           history: [SyncEntry(kind: .series, id: "1", series: "77", at: 9), SyncEntry(kind: .film, id: "5", at: 4, removed: true)],
                           list: ["film:5": .init(at: 4, on: false)], cleared: 2)
        XCTAssertEqual(SyncParcel.parse(p.json()), p)
        XCTAssertTrue(p.json().contains(#""at":9"#), "times are written as integers, like the other apps")
        // Fractions would be dropped by the Fire TV app: always whole milliseconds.
        let fractional = SyncParcel(at: 1.6, progress: ["series/1.mkv": Progress(position: 5.4, duration: 10, at: 3.5)])
        XCTAssertEqual(SyncParcel.parse(fractional.json())?.progress["series/1.mkv"], Progress(position: 5, duration: 10, at: 4))
    }

    func testReadsWhatTheOtherAppsWrite() throws {
        // As written by the LG app (JSON.stringify) and Fire TV (kotlinx), field order varies.
        let text = #"{"v":1,"at":1760000000000,"progress":{"series/1234.mkv":[600000,2700000,1760000000000]},"history":[{"kind":"series","id":"1234","series":"88","at":1760000000000}],"list":{"film:4567":[1760000000000,true]},"cleared":0}"#
        let p = try XCTUnwrap(SyncParcel.parse(text))
        XCTAssertEqual(p.progress["series/1234.mkv"], Progress(position: 600_000, duration: 2_700_000, at: 1_760_000_000_000))
        XCTAssertEqual(p.history.first?.series, "88")
        XCTAssertEqual(p.list["film:4567"]?.on, true)
    }

    func testMergesNewestWinsPerKey() {
        let own = SyncParcel(progress: ["series/1.mkv": Progress(position: 100, duration: 1000, at: 10), "series/2.mkv": Progress(position: 500, duration: 1000, at: 50)],
                             history: [SyncEntry(kind: .film, id: "7", at: 20)], list: ["film:7": .init(at: 10, on: true)])
        let other = SyncParcel(progress: ["series/1.mkv": Progress(position: 900, duration: 1000, at: 30), "series/2.mkv": Progress(position: 10, duration: 1000, at: 40)],
                               history: [SyncEntry(kind: .film, id: "7", at: 30, removed: true)], list: ["film:7": .init(at: 20, on: false)])
        let m = SyncParcel.merge(own, [other], now: 100)
        XCTAssertEqual(m.progress["series/1.mkv"]?.position, 900)
        XCTAssertEqual(m.progress["series/2.mkv"]?.position, 500)
        XCTAssertEqual(m.history, [SyncEntry(kind: .film, id: "7", at: 30, removed: true)])
        XCTAssertEqual(m.list["film:7"], .init(at: 20, on: false))
    }

    func testWatchedRecordRoundTripsMergesAndClears() {
        let own = SyncParcel(watched: ["series:88": .init(at: 10, on: true, episode: "1234"), "film:5": .init(at: 5, on: true)])
        XCTAssertEqual(SyncParcel.parse(own.json())?.watched, own.watched)
        let other = SyncParcel(watched: ["series:88": .init(at: 20, on: false, episode: ""), "film:6": .init(at: 30, on: true)])
        let m = SyncParcel.merge(own, [other], now: 100)
        XCTAssertEqual(m.watched["series:88"]?.on, false, "newer wins: new episodes arrived")
        XCTAssertEqual(Set(m.watched.keys), ["series:88", "film:5", "film:6"])
        // An older app's section has no `watched`, and removes nothing.
        XCTAssertEqual(SyncParcel.merge(own, [SyncParcel(at: 50)], now: 100).watched, own.watched)
        XCTAssertEqual(Set(SyncParcel.merge(own, [SyncParcel(cleared: 7)], now: 100).watched.keys), ["series:88"])
    }

    func testLedgersSavedBeforeTheWatchedRecordStillLoad() throws {
        let old = #"{"list":{"film:5":{"at":4,"on":true}},"removed":{},"cleared":0}"#
        let ledger = try JSONDecoder().decode(SyncLedger.self, from: Data(old.utf8))
        XCTAssertEqual(ledger.list["film:5"]?.on, true)
        XCTAssertTrue(ledger.watched.isEmpty)
    }

    func testAClearAnywhereDropsOlderProgress() {
        let m = SyncParcel.merge(SyncParcel(progress: ["series/1.mkv": Progress(position: 1, duration: 9, at: 10), "series/2.mkv": Progress(position: 1, duration: 9, at: 40)]),
                                 [SyncParcel(cleared: 30)], now: 50)
        XCTAssertEqual(Set(m.progress.keys), ["series/2.mkv"])
        XCTAssertEqual(m.cleared, 30)
    }
}

final class SyncLocalTests: XCTestCase {
    private func ch(_ id: String, _ kind: String) -> Channel {
        Channel(id: id, name: "E\(id)", group: "Season 1", url: "http://host/\(kind)/user/secret/\(id).mkv")
    }
    private func film(_ id: String, _ at: Double) -> LastWatched {
        LastWatched(heading: Playback.film, live: false, index: 0, items: [ch(id, "movie")], at: at)
    }

    func testSharesIdsNeverURLsOrNames() {
        let local = SyncLocal.Local(
            progress: ["series/1.mkv": Progress(position: 5, duration: 10, at: 3), "http://host/u/p/1.ts": Progress(position: 1, duration: 2, at: 3)],
            history: [LastWatched(heading: "Ted", live: false, index: 0, items: [ch("1", "series")], seriesId: "77", at: 9), film("9", 8)],
            favourites: ["film:9", "live:http://m3u/x"], ledger: SyncLedger())
        let p = SyncLocal.toParcel(local, now: 100)
        XCTAssertEqual(Set(p.progress.keys), ["series/1.mkv"])
        XCTAssertEqual(p.history, [SyncEntry(kind: .series, id: "1", series: "77", at: 9), SyncEntry(kind: .film, id: "9", at: 8)])
        XCTAssertEqual(p.list, ["film:9": .init(at: 0, on: true)])
        for secret in ["user", "secret", "host", "Ted", "E1"] { XCTAssertFalse(p.json().contains(secret), secret) }
    }

    func testTakesInNewerThingsAndPlaysSharedHistoryHere() async {
        let local = SyncLocal.Local(progress: ["series/1.mkv": Progress(position: 5, duration: 10, at: 20)],
                                    history: [film("5", 10), film("6", 40)], favourites: ["film:1"], ledger: SyncLedger())
        let merged = SyncParcel(progress: ["series/1.mkv": Progress(position: 9, duration: 10, at: 10), "series/2.mkv": Progress(position: 8, duration: 10, at: 5)],
                                history: [SyncEntry(kind: .film, id: "7", at: 30), SyncEntry(kind: .film, id: "5", at: 20, removed: true),
                                          SyncEntry(kind: .film, id: "6", at: 35, removed: true)],
                                list: ["film:1": .init(at: 5, on: false), "film:3": .init(at: 30, on: true)])
        let next = await SyncLocal.apply(local, merged) { e in self.film(e.id, 0) }
        XCTAssertEqual(next.progress["series/1.mkv"]?.position, 5)
        XCTAssertEqual(next.progress["series/2.mkv"]?.position, 8)
        XCTAssertEqual(next.history.map { [$0.current.id, "\(Int($0.at))"] }, [["6", "40"], ["7", "30"]])
        XCTAssertEqual(next.ledger.removed, ["film:5": 20])
        XCTAssertEqual(next.favourites, ["film:3"])
    }

    func testClearingKeepsMyList() async {
        let local = SyncLocal.Local(progress: ["series/1.mkv": Progress(position: 5, duration: 10, at: 20)], history: [film("5", 10)],
                                    favourites: ["film:5"], ledger: SyncLedger())
        let next = await SyncLocal.apply(local, SyncParcel(cleared: 30)) { _ in nil }
        XCTAssertTrue(next.progress.isEmpty)
        XCTAssertTrue(next.history.isEmpty)
        XCTAssertEqual(next.favourites, ["film:5"])
        XCTAssertEqual(next.ledger.cleared, 30)
    }
}

final class SyncLinkTests: XCTestCase {
    func testCarriesOnlyTheCode() {
        XCTAssertEqual(SyncLink.url(code: "ABCDEFGHJKMNPQRS"), "telly://sync?code=ABCDEFGHJKMNPQRS")
    }

    func testReadsWhatFireTVAndMacShow() {
        XCTAssertEqual(SyncLink.parse("telly://sync?code=abcd-efgh-jkmn-pqrs"), "ABCDEFGHJKMNPQRS")
        // An older app's link to another relay still links, with telly's relay.
        XCTAssertEqual(SyncLink.parse("telly://sync?code=ABCDEFGHJKMNPQRS&relay=https%3A%2F%2Frelay.example%2F"), "ABCDEFGHJKMNPQRS")
        XCTAssertNil(SyncLink.parse("https://evil.example/sync?code=ABCDEFGHJKMNPQRS"))
        XCTAssertNil(SyncLink.parse("telly://sync?code=TOO-SHORT"))
    }

    func testDrawsAQRCode() {
        XCTAssertNotNil(SyncLink.image("telly://sync?code=ABCDEFGHJKMNPQRS"))
    }

    // MARK: Version 2: providers

    func testProviderTagsMatchTheSharedVector() {
        let keys = SyncCrypto.deriveKeys("0123456789ABCDEF")
        XCTAssertEqual(Provider.normaliseServer(" Example.com:8080/ "), "http://example.com:8080")
        XCTAssertEqual(Provider.normaliseServer("https://tv.example:443/"), "https://tv.example")
        XCTAssertEqual(Provider.normaliseServer("HTTP://tv.example:80"), "http://tv.example")
        let xtream = Provider.xtream(name: "A", server: " Example.com:8080/ ", username: "me", password: "secret", allowCleartext: true)
        let m3u = Provider.m3u(name: "B", url: " https://example.com/list.m3u ", allowCleartext: false)
        XCTAssertEqual(SyncCrypto.providerTag(keys, identity: xtream.syncIdentity), "7a6c86b8dde4ea72")
        XCTAssertEqual(SyncCrypto.providerTag(keys, identity: m3u.syncIdentity), "ff2163ea5d23fc01")
        // Never the password, and different codes give unrelated tags.
        XCTAssertFalse(xtream.syncIdentity.contains("secret"))
        XCTAssertNotEqual(SyncCrypto.providerTag(SyncCrypto.deriveKeys("1123456789ABCDEF"), identity: xtream.syncIdentity), "7a6c86b8dde4ea72")
    }

    func testVersion2KeepsEachProviderApart() throws {
        var a = SyncParcel(at: 10)
        a.progress["movie/1.mkv"] = Progress(position: 5, duration: 10, at: 10)
        var b = SyncParcel(at: 10)
        b.progress["movie/1.mkv"] = Progress(position: 7, duration: 10, at: 20)
        let bundle = SyncBundle(at: 30, sections: ["aaaaaaaaaaaaaaaa": a, "bbbbbbbbbbbbbbbb": b])
        let back = try XCTUnwrap(SyncBundle.parse(bundle.json(), current: "cccccccccccccccc"))
        XCTAssertEqual(back.sections["aaaaaaaaaaaaaaaa"]?.progress["movie/1.mkv"]?.position, 5)
        XCTAssertEqual(back.sections["bbbbbbbbbbbbbbbb"]?.progress["movie/1.mkv"]?.position, 7)
        XCTAssertNil(back.sections["cccccccccccccccc"])
        // Anything that isn't a tag is dropped.
        XCTAssertEqual(SyncBundle.parse(#"{"v":2,"at":1,"providers":{"http://x":{"progress":{}}}}"#, current: "aaaaaaaaaaaaaaaa")?.sections.count, 0)
    }

    func testReadsVersion1AsTheCurrentProvider() throws {
        let v1 = #"{"v":1,"at":5,"progress":{"movie/9.mp4":[1,2,5]},"history":[],"list":{},"cleared":0}"#
        let b = try XCTUnwrap(SyncBundle.parse(v1, current: "dddddddddddddddd"))
        XCTAssertEqual(Array(b.sections.keys), ["dddddddddddddddd"])
        XCTAssertEqual(b.sections["dddddddddddddddd"]?.progress["movie/9.mp4"]?.position, 1)
        XCTAssertNil(SyncBundle.parse(#"{"v":3}"#, current: "dddddddddddddddd"))
    }

    func testMergesOnlyTheProvidersThisDeviceHas() {
        var mine = SyncParcel(at: 1)
        mine.progress["movie/1.mkv"] = Progress(position: 1, duration: 10, at: 1)
        var theirs = SyncParcel(at: 2)
        theirs.progress["movie/1.mkv"] = Progress(position: 6, duration: 10, at: 2)
        let other = SyncBundle(at: 2, sections: ["aaaaaaaaaaaaaaaa": theirs, "eeeeeeeeeeeeeeee": theirs])
        let m = SyncBundle.merge(SyncBundle(at: 1, sections: ["aaaaaaaaaaaaaaaa": mine]), [other], now: 3)
        XCTAssertEqual(Array(m.sections.keys), ["aaaaaaaaaaaaaaaa"])
        XCTAssertEqual(m.sections["aaaaaaaaaaaaaaaa"]?.progress["movie/1.mkv"]?.position, 6)
    }

    func testAnOlderAppsLoginsAreIgnoredAndNeverWrittenBack() throws {
        let old = #"{"v":2,"at":5,"providers":{"aaaaaaaaaaaaaaaa":{"progress":{"movie/9.mp4":[1,2,5]}}},"logins":"AQABAgMEBQYHCAkKC7jlJIwRytFBbqbV37GRZNfWfA"}"#
        let b = try XCTUnwrap(SyncBundle.parse(old, current: "0000000000000000"))
        XCTAssertEqual(b.sections["aaaaaaaaaaaaaaaa"]?.progress["movie/9.mp4"]?.position, 1)
        let merged = SyncBundle.merge(SyncBundle(at: 6, sections: ["aaaaaaaaaaaaaaaa": SyncParcel(at: 6)]), [b], now: 7)
        XCTAssertFalse(merged.json().contains("logins"))
    }
}

final class SyncCheckTests: XCTestCase {
    private func episode(_ id: String) -> Channel { Channel(id: id, name: id, group: "", url: "http://host/series/u/p/\(id).vod") }

    /** After a sync, only series whose entry, episode progress or watched record changed are checked again. */
    @MainActor func testSeriesChangedBySync() {
        let a = LastWatched(heading: "A", live: false, index: 0, items: [episode("1"), episode("2")], seriesId: "a", at: 1)
        let b = LastWatched(heading: "B", live: false, index: 0, items: [episode("3")], seriesId: "b", at: 1)
        let c = LastWatched(heading: "C", live: false, index: 0, items: [episode("4")], seriesId: "c", at: 1)
        let old = (progress: ["series/2.vod": Progress(position: 1, duration: 10, at: 1)], history: [a, b, c],
                   watched: ["series:d": SyncParcel.Watched(at: 1, on: false)])
        var cMoved = c
        cMoved.at = 2
        let new = Records.Set(favourites: [], progress: ["series/2.vod": Progress(position: 9, duration: 10, at: 2)], history: [a, b, cMoved],
                              ledger: SyncLedger(watched: ["series:d": SyncParcel.Watched(at: 2, on: true, episode: "9")]))
        XCTAssertEqual(AppModel.seriesChanged(from: old, to: new), ["a", "c", "d"])
        XCTAssertEqual(AppModel.seriesChanged(from: (new.progress, new.history, new.ledger.watched), to: new), [])
    }
}

final class SyncJoinTests: XCTestCase {
    /** PROTOCOL.md's join box, sealed the same way on every device. */
    func testMatchesTheSharedVector() throws {
        let join = try XCTUnwrap(SyncJoin.parse("telly://join?id=00112233445566778899aabbccddeeff&key=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"))
        XCTAssertEqual(join.key, Array(0..<32))
        let box = try join.seal(code: "0123456789ABCDEF", nonce: Array(1...12))
        XCTAssertEqual(SyncCrypto.hex(box), "010102030405060708090a0b0c7ec839ba88f1d2bc6e9252752327df1e757bd8bfd52e1480e77d847a23a8054b9746a38ee4fdc41370785a")
        XCTAssertEqual(join.open(box), SyncJoin.Message(code: "0123456789ABCDEF"))
        XCTAssertFalse(join.takesProvider)
    }

    func testOpensOnlyItsOwnBox() throws {
        let join = SyncJoin.new()
        let box = try join.seal(code: "0123456789ABCDEF")
        XCTAssertNil(SyncJoin.new().open(box), "another device's key")
        XCTAssertNil(SyncJoin(id: SyncJoin.new().id, key: join.key).open(box), "another box's id")
        XCTAssertEqual(SyncJoin.parse(join.url), join)
        XCTAssertNil(SyncJoin.parse("telly://sync?code=0123456789ABCDEF"))
        XCTAssertNil(SyncJoin.parse("telly://join?id=00&key=AAEC"))
    }

    // SETUP-BY-PHONE.md: the tv.gettelly.app link, and a provider in the box.

    static let link = "https://tv.gettelly.app/#id=00112233445566778899aabbccddeeff&key=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
    static let vectorA = "010102030405060708090a0b0c7ec82aa783e299e229d0417d6b3181412c27c3c4b51524b7c43e9406b29418a4e981b9e54cf895bfe4fa98c9e7a89d2fe8933dc2eebb530957107ca10a2f57631a47331387c17fcc6967c31f895662cab8120a0a8f4cdcec58e6f77853894f51f3e4565fcf047d16d5a15293d9923ae0bae54bb4be0ed202164c83b2d9e959163a1370d08fa409c4f0c60f71f75a4cbbac013310a3aa08"
    static let vectorB = "010102030405060708090a0b0c7ec839ba88f1d2bc6e9252752327df1e757bd8bfd52e1480e77dd506eec419b3ed80fead4c8f97bddbc5d481e7e1da30ad836dccf6f7571c535f36ef4d2d1679051129199d9929943b618a55d45d7bc6b0405c4dcc4a91ad55faff7854d04d10e2e4405fde28620a8295fd40ca846ca9e0f005e2b718fd1d16508cffebfa6ed7ea178a5377d65ad6f4018d"
    static let providerA = Provider.xtream(name: "My TV", server: "example.com:8080", username: "me", password: "p@ss wörd", allowCleartext: true)
    static let providerB = Provider.m3u(name: "", url: "https://example.com/list.m3u", allowCleartext: false)

    func testParsesBothLinkForms() throws {
        let new = try XCTUnwrap(SyncJoin.parse(Self.link))
        XCTAssertTrue(new.takesProvider)
        XCTAssertEqual(new.id, "00112233445566778899aabbccddeeff")
        XCTAssertEqual(new.key, Array(0..<32))
        XCTAssertEqual(new.url, Self.link)
        let old = try XCTUnwrap(SyncJoin.parse("telly://join?id=00112233445566778899aabbccddeeff&key=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"))
        XCTAssertFalse(old.takesProvider)
        XCTAssertEqual(old.key, new.key)
        XCTAssertNotEqual(old, new, "which form it was is part of it")

        // Either order, unknown parameters ignored, the id lowercased, the host in any case.
        let loose = try XCTUnwrap(SyncJoin.parse(" HTTPS://TV.GetTelly.app#v=2&key=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8&id=00112233445566778899AABBCCDDEEFF\n"))
        XCTAssertEqual(loose, new)

        for bad in [
            "https://tv.gettelly.app/setup#id=00112233445566778899aabbccddeeff&key=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
            "https://tv.gettelly.app/?x=1#id=00112233445566778899aabbccddeeff&key=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
            "https://tv.gettelly.app:8443/#id=00112233445566778899aabbccddeeff&key=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
            "http://tv.gettelly.app/#id=00112233445566778899aabbccddeeff&key=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
            "https://tv.gettelly.app.example.com/#id=00112233445566778899aabbccddeeff&key=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
            "https://sync.gettelly.app/#id=00112233445566778899aabbccddeeff&key=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
            "https://tv.gettelly.app/?id=00112233445566778899aabbccddeeff&key=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
            "https://tv.gettelly.app/#id=00112233445566778899aabbccddeeff",
            "https://tv.gettelly.app/#id=0011&key=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
            "https://tv.gettelly.app/#id=00112233445566778899aabbccddeeff&key=AAEC",
            "https://tv.gettelly.app/",
        ] {
            XCTAssertNil(SyncJoin.parse(bad), bad)
        }
    }

    func testOpensTheSharedProviderVectors() throws {
        let join = try XCTUnwrap(SyncJoin.parse(Self.link))
        let a = try XCTUnwrap(SyncCrypto.unhex(Self.vectorA))
        XCTAssertEqual(join.open(Data(a)), SyncJoin.Message(code: nil, provider: Self.providerA))
        let b = try XCTUnwrap(SyncCrypto.unhex(Self.vectorB))
        XCTAssertEqual(join.open(Data(b)), SyncJoin.Message(code: "0123456789ABCDEF", provider: Self.providerB))
    }

    func testSealsThenOpensEachCombination() throws {
        let join = SyncJoin.new()
        for (code, provider) in [("0123456789ABCDEF", nil), (nil, Self.providerA), (nil, Self.providerB),
                                 ("0123456789ABCDEF", Self.providerA), ("0123456789ABCDEF", Self.providerB)] as [(String?, Provider?)] {
            let box = try join.seal(code: code, provider: provider)
            XCTAssertEqual(join.open(box), SyncJoin.Message(code: code, provider: provider))
            XCTAssertNil(SyncJoin.new().open(box))
        }
        XCTAssertThrowsError(try join.seal(), "a message with neither")
    }

    /** Section 2's limits: a longer value makes the whole message unreadable. */
    func testOpeningKeepsToTheLimits() throws {
        let join = SyncJoin.new()
        func open(_ json: String) throws -> SyncJoin.Message? { join.open(try Self.sealRaw(join, json)) }
        func xtream(server: String = "example.com", username: String = "me", password: String = "pw", name: String = "") -> String {
            #"{"provider":{"kind":"xtream","name":"\#(name)","server":"\#(server)","username":"\#(username)","password":"\#(password)"}}"#
        }
        let s255 = String(repeating: "s", count: 255), s256 = String(repeating: "s", count: 256)
        XCTAssertNotNil(try open(xtream(server: s255, username: s255, password: s255, name: String(repeating: "n", count: 60))))
        XCTAssertNil(try open(xtream(server: s256)))
        XCTAssertNil(try open(xtream(username: s256)))
        XCTAssertNil(try open(xtream(password: s256)))
        XCTAssertNil(try open(xtream(name: String(repeating: "n", count: 61))))
        let path = String(repeating: "u", count: 2048 - "https://e.com/".count)
        XCTAssertNotNil(try open(#"{"provider":{"kind":"m3u","url":"https://e.com/\#(path)"}}"#))
        XCTAssertNil(try open(#"{"provider":{"kind":"m3u","url":"https://e.com/\#(path)u"}}"#))

        // Trimmed (not the password), a missing name and allowCleartext, unknown fields ignored.
        XCTAssertEqual(try open(#"{"v":2,"provider":{"kind":"xtream","server":" example.com ","username":" me ","password":" pw ","x":1}}"#),
                       SyncJoin.Message(provider: .xtream(name: "", server: "example.com", username: "me", password: " pw ", allowCleartext: false)))
        XCTAssertEqual(try open(#"{"code":"abcd-efgh-jkmn-pqrs"}"#), SyncJoin.Message(code: "ABCDEFGHJKMNPQRS"))

        for bad in [#"{}"#, #"{"v":2}"#, #"{"code":"nope"}"#, #"{"code":"0123456789ABCDEF","provider":{"kind":"stalker","url":"x"}}"#,
                    #"{"provider":{"kind":"m3u","url":""}}"#, #"{"provider":{"kind":"xtream","server":"e.com","username":"me"}}"#,
                    #"{"provider":{"kind":"m3u","url":"https://e.com","allowCleartext":"yes"}}"#, #"{"provider":"m3u"}"#, #"[1]"#] {
            XCTAssertNil(try open(bad), bad)
        }
    }

    /** What's sent is trimmed, its name shortened to fit; anything else too long isn't sent. */
    func testOnlySendsWhatTheReceiverTakes() {
        let long = String(repeating: "é", count: 70)
        XCTAssertEqual(SyncJoin.sendable(.xtream(name: long, server: " e.com ", username: " me ", password: " pw ", allowCleartext: false)),
                       .xtream(name: String(repeating: "é", count: 60), server: "e.com", username: "me", password: " pw ", allowCleartext: false))
        XCTAssertNil(SyncJoin.sendable(.xtream(name: "", server: "e.com", username: "me", password: String(repeating: "p", count: 256), allowCleartext: false)))
        XCTAssertNil(SyncJoin.sendable(.m3u(name: "", url: "https://e.com/" + String(repeating: "u", count: 2048), allowCleartext: false)))
    }

    /** A box sealed around any text, as another app (or someone else) might send it. */
    static func sealRaw(_ join: SyncJoin, _ json: String) throws -> Data {
        let nonce = Array(1...12).map(UInt8.init)
        let box = try AES.GCM.seal(Data(json.utf8), using: SymmetricKey(data: join.key), nonce: AES.GCM.Nonce(data: nonce),
                                   authenticating: Data("telly-join v1|\(join.id)".utf8))
        return Data([1] + nonce) + box.ciphertext + box.tag
    }
}

private extension SyncCrypto {
    static func unhex(_ text: String) -> [UInt8]? {
        let chars = Array(text)
        guard chars.count % 2 == 0 else { return nil }
        return stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...$0 + 1]), radix: 16) }.reduce(into: [UInt8]?([])) { all, b in
            if let b { all?.append(b) } else { all = nil }
        }
    }
}
