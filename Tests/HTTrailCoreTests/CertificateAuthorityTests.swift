import XCTest
import X509
@testable import HTTrailCore

final class CertificateAuthorityTests: XCTestCase {
    func testCreatesRootCA() throws {
        let ca = try CertificateAuthority.create()
        XCTAssertTrue(ca.caCertificatePEM.contains("BEGIN CERTIFICATE"))
    }

    func testMintsLeafForHost() throws {
        let ca = try CertificateAuthority.create()
        let leaf = try ca.leaf(for: "example.com")
        XCTAssertTrue(leaf.certificateChainPEM.contains("BEGIN CERTIFICATE"))
        XCTAssertTrue(leaf.privateKeyPEM.contains("BEGIN PRIVATE KEY") || leaf.privateKeyPEM.contains("BEGIN EC PRIVATE KEY"))
    }

    func testLeafCachingReturnsStable() throws {
        let ca = try CertificateAuthority.create()
        let a = try ca.leaf(for: "example.com")
        let b = try ca.leaf(for: "example.com")
        XCTAssertEqual(a.certificateChainPEM, b.certificateChainPEM)
    }
}
