import SwiftUI
import Foundation

/// Builds a classic `hexdump`-style listing for binary data:
/// `00000000  48 54 54 50 2f 31 2e 31  …  |HTTP/1.1 200 OK.|`
public enum HexDump {
    /// Render `data` as offset / hex / ASCII rows. Capped at `maxBytes` so a huge
    /// body doesn't build a multi-megabyte string. Used for the copy-to-clipboard
    /// action; the on-screen viewer formats rows lazily via ``row(_:_:)``.
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

    /// Number of 16-byte rows needed to display `count` bytes.
    public static func rowCount(_ count: Int) -> Int { count <= 0 ? 0 : (count + 15) / 16 }

    /// Format a single 16-byte row (offset / hex / ASCII) of `data` on demand, so
    /// the viewer can virtualise arbitrarily large bodies without building one
    /// huge string. `row` is a 0-based row index (16 bytes each).
    public static func row(_ data: Data, _ row: Int) -> String {
        let start = data.startIndex + row * 16
        guard start < data.endIndex else { return "" }
        let end = data.index(start, offsetBy: 16, limitedBy: data.endIndex) ?? data.endIndex
        let hexWidth = 16 * 3 + 1
        var hex = ""; hex.reserveCapacity(hexWidth)
        var ascii = ""; ascii.reserveCapacity(16)
        var i = 0
        var idx = start
        while idx < end {
            let byte = data[idx]
            hex += String(format: "%02x ", byte)
            if i == 7 { hex += " " }
            ascii += (byte >= 0x20 && byte < 0x7F) ? String(UnicodeScalar(byte)) : "."
            i += 1
            idx = data.index(after: idx)
        }
        return String(format: "%08x  ", row * 16)
            + hex.padding(toLength: hexWidth, withPad: " ", startingAt: 0)
            + " |" + ascii + "|"
    }
}

/// Read-only monospaced hex viewer for binary bodies that can't render as text.
///
/// Rows are realised lazily (one `Text` per 16-byte row inside a `LazyVStack`),
/// so even a multi-megabyte body scrolls smoothly instead of freezing the UI on
/// a single giant selectable `Text`.
public struct HexViewer: View {
    let data: Data
    private let maxBytes: Int

    /// - Parameter maxBytes: how many bytes to expose as rows. Virtualisation keeps
    ///   rendering cheap; the cap just bounds the row count for pathologically large
    ///   bodies. Anything beyond is noted as truncated (Export still saves all bytes).
    public init(data: Data, maxBytes: Int = 1024 * 1024) {
        self.data = data
        self.maxBytes = maxBytes
    }

    private var shownCount: Int { min(data.count, maxBytes) }
    private var rows: Int { HexDump.rowCount(shownCount) }

    public var body: some View {
        Group {
            if data.isEmpty {
                Text("—")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.color.textFaint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(14)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(0..<rows), id: \.self) { row in
                            Text(HexDump.row(data, row))
                                .fixedSize(horizontal: true, vertical: false)
                                .textSelection(.enabled)
                        }
                        if data.count > shownCount {
                            Text("… \(UIFormat.byteSize(data.count - shownCount)) more (truncated for display)")
                                .foregroundStyle(Theme.color.textFaint)
                                .padding(.top, 6)
                        }
                    }
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.color.codeText)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.color.codeBG)
    }
}
