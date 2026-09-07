import Foundation

/// Produces a standards-compliant, uncompressed ZIP without adding another
/// runtime framework to the Packet Tunnel or application bundle.
public enum PurelineDiagnosticArchive {
    public static func export(diagnostics: PurelinePacketTunnelDiagnostics = .shared) throws -> URL {
        let events = (try? Data(contentsOf: diagnostics.logURL)) ?? Data()
        let summaryObject: [String: Any] = [
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "packetTunnelEventCount": diagnostics.events().count,
            "privacy": "Operational metadata only. Credentials and URL query values are redacted."
        ]
        let summary = try JSONSerialization.data(withJSONObject: summaryObject, options: [.prettyPrinted, .sortedKeys])
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Pureline-Diagnostics-\(stamp).zip")
        let data = makeZIP(entries: [
            ("packet-tunnel-events.jsonl", events),
            ("summary.json", summary)
        ])
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func makeZIP(entries: [(String, Data)]) -> Data {
        var archive = Data()
        var central = Data()
        var offset: UInt32 = 0
        for (name, payload) in entries {
            let nameData = Data(name.utf8)
            let crc = crc32(payload)
            var local = Data()
            local.appendLE(UInt32(0x04034b50)); local.appendLE(UInt16(20)); local.appendLE(UInt16(0))
            local.appendLE(UInt16(0)); local.appendLE(UInt16(0)); local.appendLE(UInt16(0))
            local.appendLE(crc); local.appendLE(UInt32(payload.count)); local.appendLE(UInt32(payload.count))
            local.appendLE(UInt16(nameData.count)); local.appendLE(UInt16(0)); local.append(nameData); local.append(payload)
            archive.append(local)

            central.appendLE(UInt32(0x02014b50)); central.appendLE(UInt16(20)); central.appendLE(UInt16(20))
            central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
            central.appendLE(crc); central.appendLE(UInt32(payload.count)); central.appendLE(UInt32(payload.count))
            central.appendLE(UInt16(nameData.count)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
            central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(UInt32(0)); central.appendLE(offset)
            central.append(nameData)
            offset += UInt32(local.count)
        }
        let centralOffset = UInt32(archive.count)
        archive.append(central)
        archive.appendLE(UInt32(0x06054b50)); archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(entries.count)); archive.appendLE(UInt16(entries.count))
        archive.appendLE(UInt32(central.count)); archive.appendLE(centralOffset); archive.appendLE(UInt16(0))
        return archive
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xedb8_8320 & (0 &- (crc & 1))) }
        }
        return crc ^ 0xffff_ffff
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
