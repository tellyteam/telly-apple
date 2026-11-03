import XCTest
@testable import Telly

@MainActor
final class SecurityTests: XCTestCase {
    /** A join link hands over the household's code, so one from a message or web page is ignored. */
    func testJoinLinksOnlyComeFromTheScanner() throws {
        let app = AppModel()
        app.open(try XCTUnwrap(URL(string: SyncJoin.new().url)))
        XCTAssertNil(app.pendingJoin)
        app.open(try XCTUnwrap(URL(string: SyncLink.url(code: "0123456789ABCDEF"))))
        XCTAssertEqual(app.pendingLink?.code, "0123456789ABCDEF", "a sync link still asks first")
    }

    /** An https address that redirects to plain HTTP isn't followed while plain HTTP is off. */
    func testRedirectToPlainHTTPIsRefused() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RedirectStub.self]
        // The stub never finishes a refused redirect (a real server's answer would), so it times out.
        config.timeoutIntervalForRequest = 2
        let session = URLSession(configuration: config)
        let url = try XCTUnwrap(URL(string: "https://p.example/player_api.php"))

        RedirectStub.plainRequested = false
        let off = RedirectGuard(allowCleartext: false)
        _ = try? await session.data(from: url, delegate: off)
        XCTAssertTrue(off.refused)
        XCTAssertFalse(RedirectStub.plainRequested, "the login never went over plain HTTP")

        let on = RedirectGuard(allowCleartext: true)
        let (data, _) = try await session.data(from: url, delegate: on)
        XCTAssertFalse(on.refused)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "plain")
    }

    func testOnlyHTTPSUnlessPlainHTTPIsAllowed() {
        XCTAssertTrue(RedirectGuard.allows(URL(string: "https://p.example/a"), allowCleartext: false))
        XCTAssertFalse(RedirectGuard.allows(URL(string: "http://p.example/a"), allowCleartext: false))
        XCTAssertTrue(RedirectGuard.allows(URL(string: "HTTP://p.example/a"), allowCleartext: true))
        XCTAssertFalse(RedirectGuard.allows(URL(string: "ftp://p.example/a"), allowCleartext: true))
    }

    /** A provider's token address on plain HTTP is let through when it carries none of the login. */
    func testPlainHTTPWithoutTheLoginIsAllowedWhenTheLoginIsKnown() {
        let login = ["alice", "s3cret&!"]
        XCTAssertTrue(RedirectGuard.allows(URL(string: "http://cdn.example/stream/9f8e7d.ts?token=abc"), allowCleartext: false, secrets: login))
        XCTAssertFalse(RedirectGuard.allows(URL(string: "http://cdn.example/movie/alice/x/1.mkv"), allowCleartext: false, secrets: login))
        XCTAssertFalse(RedirectGuard.allows(URL(string: "http://cdn.example/1.mkv?p=s3cret%26%21"), allowCleartext: false, secrets: login))
        XCTAssertFalse(RedirectGuard.allows(URL(string: "http://cdn.example/stream/9f8e7d.ts"), allowCleartext: false), "login unknown: refused")
        XCTAssertFalse(RedirectGuard.allows(URL(string: "http://cdn.example/stream/9f8e7d.ts"), allowCleartext: false, secrets: [""]))
    }
}

/** https answers with a redirect to http, which answers "plain". */
private final class RedirectStub: URLProtocol {
    nonisolated(unsafe) static var plainRequested = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        if url.scheme == "https" {
            let to = URL(string: "http://p.example/player_api.php?username=u&password=p")!
            let moved = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": to.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: to), redirectResponse: moved)
            return
        }
        Self.plainRequested = true
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("plain".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
