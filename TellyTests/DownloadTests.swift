import XCTest
@testable import Telly

@MainActor
final class DownloadTests: XCTestCase {
    private func at(_ hour: Int) -> Date { Calendar.current.date(bySettingHour: hour, minute: 30, second: 0, of: Date())! }

    func testOnlyFilesCanBeDownloaded() {
        XCTAssertTrue(Downloads.canDownload("http://p.example/movie/u/p/1.mkv"))
        XCTAssertTrue(Downloads.canDownload("https://p.example/series/u/p/2.mp4"))
        XCTAssertFalse(Downloads.canDownload("http://p.example/movie/u/p/3.m3u8"))
        XCTAssertFalse(Downloads.canDownload("file:///tmp/x.mkv"))
    }

    func testTheOvernightWindow() {
        let d = Downloads.shared
        let saved = d.settings
        defer { d.settings = saved }
        d.settings = DownloadSettings(overnight: true, startHour: 1, endHour: 7)
        XCTAssertTrue(d.inWindow(at(1)))
        XCTAssertTrue(d.inWindow(at(6)))
        XCTAssertFalse(d.inWindow(at(7)))
        XCTAssertFalse(d.inWindow(at(23)))
        // A window across midnight.
        d.settings = DownloadSettings(overnight: true, startHour: 23, endHour: 6)
        XCTAssertTrue(d.inWindow(at(23)))
        XCTAssertTrue(d.inWindow(at(2)))
        XCTAssertFalse(d.inWindow(at(12)))
        // Not overnight: any time.
        d.settings = DownloadSettings(overnight: false)
        XCTAssertTrue(d.inWindow(at(12)))
    }

    func testTheNextWindowStarts() {
        let d = Downloads.shared
        let saved = d.settings
        defer { d.settings = saved }
        d.settings = DownloadSettings(overnight: true, startHour: 1, endHour: 7)
        let evening = at(22)
        let next = d.nextWindowStart(after: evening)
        XCTAssertEqual(Calendar.current.component(.hour, from: next), 1)
        XCTAssertTrue(next > evening && next.timeIntervalSince(evening) < 4 * 3600)
        XCTAssertEqual(d.nextWindowStart(after: at(3)), at(3), "already open")
    }

    func testFileNamesAreSafe() {
        let item = DownloadItem(id: "abc123|movie/5000.mkv", providerId: "abc123", url: "http://p.example/movie/u/p/5000.mkv",
                                kind: .film, title: "x", added: 0)
        XCTAssertEqual(item.fileName, "abc123_movie_5000_mkv.mkv")
    }

    func testTimesShowAsHoursAndMinutes() {
        XCTAssertEqual(hour(1), "01:00")
        XCTAssertEqual(hour(23), "23:00")
    }
}
