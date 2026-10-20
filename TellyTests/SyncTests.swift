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
    }

    func testReadsWhatTheOtherAppsWrite() throws {
        // As written by the Mac app (JSON.stringify) and Fire TV (kotlinx), field order varies.
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
