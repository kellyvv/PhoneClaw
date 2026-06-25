import XCTest
@testable import PhoneClawGateway

final class PairOriginPolicyTests: XCTestCase {
    func testPairOriginPolicyAllowsNativeRequestsWithoutBrowserHeaders() {
        XCTAssertTrue(PairOriginPolicy.allows(origin: nil, referer: nil))
        XCTAssertTrue(PairOriginPolicy.allows(origin: "", referer: ""))
    }

    func testPairOriginPolicyAllowsOnlyLoopbackBrowserOrigins() {
        XCTAssertTrue(PairOriginPolicy.allows(origin: "http://localhost:5173", referer: nil))
        XCTAssertTrue(PairOriginPolicy.allows(origin: "http://127.0.0.1:5173", referer: "http://localhost:5173/pair"))

        XCTAssertFalse(PairOriginPolicy.allows(origin: "https://evil.example", referer: nil))
        XCTAssertFalse(PairOriginPolicy.allows(origin: nil, referer: "https://evil.example/pair"))
        XCTAssertFalse(PairOriginPolicy.allows(origin: "not a url", referer: nil))
    }

    func testHTTPRequestParserLowercasesOriginHeaderForPairPolicyLookup() throws {
        let raw = """
        POST /pair HTTP/1.1\r
        Host: phoneclaw.local\r
        Origin: https://evil.example\r
        Referer: https://evil.example/pair\r
        Content-Length: 0\r
        \r

        """

        let req = try XCTUnwrap(GatewayHTTPRequest.parse(Data(raw.utf8)))
        XCTAssertEqual(req.headers["origin"], "https://evil.example")
        XCTAssertEqual(req.headers["referer"], "https://evil.example/pair")
        XCTAssertFalse(PairOriginPolicy.allows(origin: req.headers["origin"], referer: req.headers["referer"]))
    }
}
