import XCTest
@testable import Telly

final class XtreamTests: XCTestCase {
    func testServerAddresses() throws {
        XCTAssertEqual(try Xtream.serverURL("example.com:8080").absoluteString, "https://example.com:8080/")
        XCTAssertEqual(try Xtream.serverURL("http://example.com/ ").absoluteString, "http://example.com/")
        XCTAssertThrowsError(try Xtream.serverURL("ftp://x"))
    }

    func testStreamAndApiURLs() throws {
        let s = try Xtream.serverURL("https://tv.example")
        XCTAssertEqual(Xtream.streamURL(s, "series", "me", "p w", "12", "mkv"), "https://tv.example/series/me/p%20w/12.mkv")
        XCTAssertEqual(Xtream.apiURL(s, "me", "a b", action: "get_series").absoluteString,
                       "https://tv.example/player_api.php?username=me&password=a%20b&action=get_series")
    }

    func testLenientCatalogues() throws {
        let s = try Xtream.serverURL("https://tv.example")
        let json = try JSONSerialization.jsonObject(with: Data(#"[{"stream_id":5,"name":" Film ","category_id":"1","container_extension":"mkv","added":"1700000000"},{"name":"no id"}]"#.utf8))
        let films = try Xtream.films(s, "u", "p", cats: ["1": "Action"], json)
        XCTAssertEqual(films.count, 1)
        XCTAssertEqual(films[0].id, "5")
        XCTAssertEqual(films[0].name, "Film")
        XCTAssertEqual(films[0].group, "Action")
        XCTAssertEqual(films[0].url, "https://tv.example/movie/u/p/5.mkv")
        XCTAssertEqual(films[0].added, 1_700_000_000)
        XCTAssertThrowsError(try Xtream.films(s, "u", "p", cats: [:], [String: Any]()))
    }

    func testSeasonsInOrder() throws {
        let s = try Xtream.serverURL("https://tv.example")
        let info = try JSONSerialization.jsonObject(with: Data(#"{"episodes":{"10":[{"id":"9","episode_num":1,"title":"Show - S10E01 - Pilot"}],"2":[{"id":"3","episode_num":"4"}]}}"#.utf8))
        let seasons = Xtream.seasons(s, "u", "p", info)
        XCTAssertEqual(seasons.map(\.name), ["Season 2", "Season 10"])
        XCTAssertEqual(seasons[1].episodes[0].name, "E1  Pilot")
        XCTAssertEqual(seasons[0].episodes[0].name, "E4")
    }

    func testBooleansAreNotNumbers() {
        XCTAssertNil(Xtream.str(true as NSNumber))
        XCTAssertEqual(Xtream.str(42 as NSNumber), "42")
    }
}

final class PlaybackTests: XCTestCase {
    func testProgressKeysDropTheLogin() {
        XCTAssertEqual(Playback.progressKey("https://tv.example/series/me/secret/12.mkv"), "series/12.mkv")
    }

    func testCreditsCountAsWatched() {
        // 40 minutes: the last 2 minutes (5%).
        XCTAssertTrue(Progress(position: 2_285_000, duration: 2_400_000).finished)
        XCTAssertFalse(Progress(position: 2_270_000, duration: 2_400_000).finished)
        XCTAssertEqual(Playback.resumePosition(Progress(position: 10_000, duration: 2_400_000)), 0)
        XCTAssertEqual(Playback.resumePosition(Progress(position: 90_000, duration: 2_400_000)), 90_000)
    }

    func testM3U() {
        let channels = M3U.parse("#EXTM3U\n#EXTINF:-1 tvg-id=\"a\" tvg-logo=\"http://l\" group-title=\"News, UK\",BBC One\nhttp://s/1.ts\n#EXTINF:-1,Plain\n#EXTGRP:Misc\nhttp://s/2.ts\n")
        XCTAssertEqual(channels.map(\.name), ["BBC One", "Plain"])
        XCTAssertEqual(channels.map(\.group), ["News, UK", "Misc"])
        XCTAssertEqual(channels[0].epgId, "a")
    }
}

@MainActor
final class PlayerFailureTests: XCTestCase {
    func testExplainsWhatTheProviderAnswered() {
        XCTAssertTrue(PlayerController.explain(511).contains("VPN"))
        XCTAssertTrue(PlayerController.explain(403).contains("VPN"))
        XCTAssertTrue(PlayerController.explain(509).contains("another device"))
        XCTAssertTrue(PlayerController.explain(401).contains("login"))
        XCTAssertTrue(PlayerController.explain(nil).contains("internet"))
        XCTAssertTrue(PlayerController.explain(500).contains("won't play"))
    }
}
