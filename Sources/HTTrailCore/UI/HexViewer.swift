import SwiftUI
import Foundation

/// Builds a classic `hexdump`-style listing for binary data:
/// `00000000  48 54 54 50 2f 31 2e 31  …  |HTTP/1.1 200 OK.|`
public enum HexDump {
    /// Render `data` as offset / hex / ASCII rows. Capped at `maxBytes` so a huge
    /// body doesn't build a multi-megabyte string for the viewer.
    public static func make(_ data: Data, maxBytes: Int = 64 * 1024) -> String {
        if data.isEmpty { return "—" }
        let shown = data.prefix(maxBytes)
        let bytes = [UInt8](shown)
        let hexWidth = 16 * 3 + 1   // 16 bytes, "xx " each, +1 for the mid gutter
        var out = String()
        out.reserveCapacity((bytes.count / 16 + 1) * 78)
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + 16, bytes.count)
            out += String(format: "%08x  ", offset)
            var hex = ""
            for (i, byte) in bytes[offset..<end].enumerated() {
                hex += String(format: "%02x ", byte)
                if i == 7 { hex += " " }   // extra gutter between the two 8-byte halves
            }
            out += hex.padding(toLength: hexWidth, withPad: " ", startingAt: 0)
            out += " |"
            for byte in bytes[offset..<end] {
                out += (byte >= 0x20 && byte < 0x7F) ? String(UnicodeScalar(byte)) : "."
            }
            out += "|\n"
            offset = end
        }
        if data.count > bytes.count {
            out += "\n… \(UIFormat.byteSize(data.count - bytes.count)) more (truncated for display)\n"
        }
        return out
    }
}

/// Read-only monospaced hex viewer for binary bodies that can't render as text.
public struct HexViewer: View {
    let data: Data
    public init(data: Data) { self.data = data }
    public var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(HexDump.make(data))
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.color.codeText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.color.codeBG)
    }
}
