import XCTest
import NIOCore
@testable import HTTrailCore

final class SharedConfigFieldsTests: XCTestCase {
    func testRoundTripsNewBonjourAndRemoteFields() throws {
        var config = SharedConfig()
        config.bonjourEnabled = true
        config.remoteProxyHost = "192.168.1.50"
        config.remoteProxyPort = 9091
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SharedConfig.self, from: data)
        XCTAssertTrue(decoded.bonjourEnabled)
        XCTAssertEqual(decoded.remoteProxyHost, "192.168.1.50")
        XCTAssertEqual(decoded.remoteProxyPort, 9091)
    }

    func testLegacyConfigDecodesWithDefaults() throws {
        // A config written before these fields existed must still decode.
        let legacy = #"{"rules":[],"sslAllowlist":[],"proxyPort":9090,"pinningEnabled":true,"forcedDecryptHosts":[]}"#
        let decoded = try JSONDecoder().decode(SharedConfig.self, from: Data(legacy.utf8))
        XCTAssertFalse(decoded.bonjourEnabled)
        XCTAssertNil(decoded.remoteProxyHost)
        XCTAssertNil(decoded.remoteProxyPort)
    }
}

final class ProfileHTTPServerTests: XCTestCase {
    func testServesPayloadWithProfileMIMEOnGivenHost() throws {
        let payload = Data("hello-profile".utf8)
        let server = ProfileHTTPServer(payload: payload)
        let port = try server.start(bindHost: "127.0.0.1")
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/HTTrail-CA.mobileconfig")!
        let exp = expectation(description: "fetch")
        var gotData: Data?
        var gotMIME: String?
        URLSession.shared.dataTask(with: url) { data, resp, _ in
            gotData = data
            gotMIME = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
            exp.fulfill()
        }.resume()
        wait(for: [exp], timeout: 5)

        XCTAssertEqual(gotData, payload)
        XCTAssertEqual(gotMIME, "application/x-apple-aspen-config")
    }

    func testCAOnlyProfileHasRootPayloadNoProxyPayload() throws {
        let ca = try CertificateAuthority.create()
        let data = try ProfileGenerator().makeProfile(
            caCertificateDER: ca.caCertificateDER, proxyHost: "10.0.0.1", proxyPort: 9090,
            includeProxyPayload: false)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let payloads = try XCTUnwrap((plist?["PayloadContent"]) as? [[String: Any]])
        XCTAssertTrue(payloads.contains { ($0["PayloadType"] as? String) == "com.apple.security.root" })
        XCTAssertFalse(payloads.contains { ($0["PayloadType"] as? String) == "com.apple.proxy.http.global" })
    }
}
