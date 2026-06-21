import XCTest
@testable import HTTrailCore

final class CertificateAuthorityReconstructTests: XCTestCase {
    func testReconstructFromPEMMintsLeafChainingToSameRoot() throws {
        let original = try CertificateAuthority.create()
        let certPEM = original.caCertificatePEM
        let keyPEM = original.caPrivateKeyPEM
        XCTAssertFalse(certPEM.isEmpty)
        XCTAssertTrue(keyPEM.contains("PRIVATE KEY"))

        let restored = try CertificateAuthority.from(certificatePEM: certPEM, keyPEM: keyPEM)
        XCTAssertEqual(restored.caCertificateDER, original.caCertificateDER)
        let leaf = try restored.leaf(for: "example.com")
        XCTAssertTrue(leaf.certificateChainPEM.contains(original.caCertificatePEM))
        XCTAssertTrue(leaf.privateKeyPEM.contains("PRIVATE KEY"))
    }

    func testReconstructFromGarbageThrows() {
        XCTAssertThrowsError(try CertificateAuthority.from(certificatePEM: "nope", keyPEM: "nope"))
    }
}
