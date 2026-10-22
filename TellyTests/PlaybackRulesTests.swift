import XCTest
@testable import Telly

/** telly-sync's playback-cases.json (copied beside this file): every app runs the same cases. */
final class PlaybackRulesTests: XCTestCase {
    private func cases(_ section: String) throws -> [[String: Any]] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-cases", withExtension: "json"))
        let all = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let list = try XCTUnwrap(all[section] as? [[String: Any]])
        XCTAssertFalse(list.isEmpty)
        return list
    }

    private func num(_ c: [String: Any], _ k: String) -> Double? { (c[k] as? NSNumber)?.doubleValue }
    private func int(_ c: [String: Any], _ k: String) -> Int? { (c[k] as? NSNumber)?.intValue }
    private func bool(_ c: [String: Any], _ k: String) -> Bool { c[k] as? Bool ?? false }
    private func set(_ c: [String: Any], _ k: String) -> Set<Int> { Set((c[k] as? [NSNumber] ?? []).map(\.intValue)) }

    func testPrompt() throws {
        for c in try cases("prompt") {
            let got = PlaybackRules.promptSeconds(duration: num(c, "durationMs")!, position: num(c, "positionMs")!, hasNext: bool(c, "hasNext"),
                                                  autoNext: bool(c, "autoNext"), dismissed: bool(c, "dismissed"), live: bool(c, "live"))
            XCTAssertEqual(got, int(c, "seconds"), c["name"] as! String)
        }
    }

    func testAtEnd() throws {
        for c in try cases("atEnd") {
            XCTAssertEqual(PlaybackRules.advanceAtEnd(hasNext: bool(c, "hasNext"), autoNext: bool(c, "autoNext"), dismissed: bool(c, "dismissed")),
                           bool(c, "advance"), c["name"] as! String)
        }
    }

    func testWatched() throws {
        for c in try cases("watched") {
            XCTAssertEqual(PlaybackRules.watched(position: num(c, "positionMs")!, duration: num(c, "durationMs")!), bool(c, "watched"), c["name"] as! String)
        }
    }

    func testResume() throws {
        for c in try cases("resume") {
            XCTAssertEqual(PlaybackRules.startAt(position: num(c, "positionMs"), duration: num(c, "durationMs")), num(c, "startAt"), c["name"] as! String)
        }
    }

    func testContinueWatching() throws {
        for c in try cases("continue") {
            let watched = set(c, "watched")
            XCTAssertEqual(PlaybackRules.continueIndex(int(c, "index")!, count: int(c, "items")!) { watched.contains($0) }, int(c, "continueIndex"), c["name"] as! String)
            XCTAssertEqual(PlaybackRules.shownInContinue(int(c, "index")!, count: int(c, "items")!) { watched.contains($0) }, bool(c, "shown"), c["name"] as! String)
        }
    }

    func testNextPlayable() throws {
        for c in try cases("nextPlayable") {
            let downloaded = set(c, "downloaded")
            XCTAssertEqual(PlaybackRules.nextPlayable(int(c, "index")!, count: int(c, "items")!, downloaded: { downloaded.contains($0) }, online: bool(c, "online")),
                           int(c, "next"), c["name"] as! String)
        }
    }
}
