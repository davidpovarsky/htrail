import Foundation
import Crypto
import X509
import SwiftASN1

/// Generates and manages the root Certificate Authority used to perform TLS
/// man-in-the-middle, plus per-host leaf certificates minted on demand and
/// signed by that root. This is the heart of Charles-style HTTPS capture: the
/// proxy presents a leaf cert for the requested host that chains up to a CA the
/// user has trusted on their machine/device.
public final class CertificateAuthority: @unchecked Sendable {

    public struct LeafMaterial: Sendable {
        /// PEM-encoded leaf certificate followed by the CA certificate (chain).
        public let certificateChainPEM: String
        /// PEM-encoded EC private key for the leaf.
        public let privateKeyPEM: String
    }

    private let caCertificate: Certificate
    private let caPrivateKey: Certificate.PrivateKey
    private let caBackingKey: P256.Signing.PrivateKey

    private let lock = NSLock()
    private var leafCache: [String: LeafMaterial] = [:]

    /// Common name / organisation shown to the user when inspecting the cert.
    public static let organisationName = "HTTrail"
    public static let caCommonName = "HTTrail Root CA"

    private init(certificate: Certificate, privateKey: Certificate.PrivateKey, backingKey: P256.Signing.PrivateKey) {
        self.caCertificate = certificate
        self.caPrivateKey = privateKey
        self.caBackingKey = backingKey
    }

    /// PEM of the root CA certificate — this is what the user installs & trusts.
    public var caCertificatePEM: String {
        (try? caCertificate.serializeAsPEM().pemString) ?? ""
    }

    /// PEM of the root CA EC private key. Needed so a device can hand its CA to
    /// another HTTrail instance (Bonjour capture-to-Mac). Sensitive — only sent
    /// over the trusted LAN; never persisted by the receiver.
    public var caPrivateKeyPEM: String { caBackingKey.pemRepresentation }

    public var caCertificate509: Certificate { caCertificate }

    /// DER bytes of the root CA — needed when embedding it in an iOS profile.
    public var caCertificateDER: Data {
        var serializer = DER.Serializer()
        guard (try? serializer.serialize(caCertificate)) != nil else { return Data() }
        return Data(serializer.serializedBytes)
    }

    // MARK: - Loading / creation

    /// Load an existing CA from `directory`, or create & persist a new one.
    public static func loadOrCreate(in directory: URL) throws -> CertificateAuthority {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let certURL = directory.appendingPathComponent("httrail-ca.crt.pem")
        let keyURL = directory.appendingPathComponent("httrail-ca.key.pem")

        if fm.fileExists(atPath: certURL.path), fm.fileExists(atPath: keyURL.path) {
            let certPEM = try String(contentsOf: certURL, encoding: .utf8)
            let keyPEM = try String(contentsOf: keyURL, encoding: .utf8)
            return try from(certificatePEM: certPEM, keyPEM: keyPEM)
        }

        let ca = try create()
        try ca.caCertificatePEM.write(to: certURL, atomically: true, encoding: .utf8)
        try ca.caBackingKey.pemRepresentation.write(to: keyURL, atomically: true, encoding: .utf8)
        // Tighten permissions on the private key.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        return ca
    }

    /// Reconstruct a CA from externally supplied PEM material (e.g. a CA uploaded
    /// by an iPhone for capture-to-Mac). The reconstructed CA is identical to the
    /// source and mints leaves the source's trust store accepts.
    public static func from(certificatePEM: String, keyPEM: String) throws -> CertificateAuthority {
        let backingKey = try P256.Signing.PrivateKey(pemRepresentation: keyPEM)
        let cert = try Certificate(pemEncoded: certificatePEM)
        return CertificateAuthority(
            certificate: cert,
            privateKey: Certificate.PrivateKey(backingKey),
            backingKey: backingKey
        )
    }

    /// Create a brand new self-signed root CA (10 year validity).
    public static func create() throws -> CertificateAuthority {
        let backingKey = P256.Signing.PrivateKey()
        let key = Certificate.PrivateKey(backingKey)

        let name = try DistinguishedName {
            CommonName(caCommonName)
            OrganizationName(organisationName)
        }

        let now = Date()
        let notBefore = now.addingTimeInterval(-60 * 60 * 24)
        let notAfter = now.addingTimeInterval(60 * 60 * 24 * 365 * 10)

        let extensions = try Certificate.Extensions {
            Critical(
                BasicConstraints.isCertificateAuthority(maxPathLength: nil)
            )
            Critical(
                KeyUsage(keyCertSign: true, cRLSign: true)
            )
            SubjectKeyIdentifier(keyIdentifier: ArraySlice(Insecure.SHA1.hash(data: key.publicKey.subjectPublicKeyInfoBytes)))
        }

        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: key.publicKey,
            notValidBefore: notBefore,
            notValidAfter: notAfter,
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: extensions,
            issuerPrivateKey: key
        )

        return CertificateAuthority(certificate: certificate, privateKey: key, backingKey: backingKey)
    }

    // MARK: - Leaf minting

    /// Return (creating + caching on first use) a leaf certificate + key for `host`.
    public func leaf(for host: String) throws -> LeafMaterial {
        let key = cacheKey(for: host)
        lock.lock()
        if let cached = leafCache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let material = try mintLeaf(for: host)

        lock.lock()
        leafCache[key] = material
        lock.unlock()
        return material
    }

    private func cacheKey(for host: String) -> String {
        // Wildcard-collapse: foo.example.com and bar.example.com can share a
        // *.example.com leaf to keep the cache small, but for fidelity we key
        // on the exact host here.
        host.lowercased()
    }

    private func mintLeaf(for host: String) throws -> LeafMaterial {
        let leafBackingKey = P256.Signing.PrivateKey()
        let leafKey = Certificate.PrivateKey(leafBackingKey)

        let subject = try DistinguishedName {
            CommonName(host)
            OrganizationName(Self.organisationName)
        }

        let san: SubjectAlternativeNames
        if let ip = parseIPv4(host) {
            san = SubjectAlternativeNames([.ipAddress(ASN1OctetString(contentBytes: ArraySlice(ip)))])
        } else {
            san = SubjectAlternativeNames([.dnsName(host)])
        }

        let now = Date()
        let notBefore = now.addingTimeInterval(-60 * 60 * 24)
        // Keep leaves short-lived (~13 months) to mirror modern CA practice.
        let notAfter = now.addingTimeInterval(60 * 60 * 24 * 397)

        let extensions = try Certificate.Extensions {
            Critical(
                BasicConstraints.notCertificateAuthority
            )
            KeyUsage(digitalSignature: true, keyEncipherment: true)
            try ExtendedKeyUsage([.serverAuth, .clientAuth])
            san
            SubjectKeyIdentifier(keyIdentifier: ArraySlice(Insecure.SHA1.hash(data: leafKey.publicKey.subjectPublicKeyInfoBytes)))
            AuthorityKeyIdentifier(keyIdentifier: ArraySlice(Insecure.SHA1.hash(data: caPrivateKey.publicKey.subjectPublicKeyInfoBytes)))
        }

        let leaf = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: leafKey.publicKey,
            notValidBefore: notBefore,
            notValidAfter: notAfter,
            issuer: caCertificate.subject,
            subject: subject,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: extensions,
            issuerPrivateKey: caPrivateKey
        )

        let leafPEM = try leaf.serializeAsPEM().pemString
        let chainPEM = leafPEM + "\n" + caCertificatePEM
        return LeafMaterial(certificateChainPEM: chainPEM, privateKeyPEM: leafBackingKey.pemRepresentation)
    }

    private func parseIPv4(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard let value = UInt8(part) else { return nil }
            bytes.append(value)
        }
        return bytes
    }
}
