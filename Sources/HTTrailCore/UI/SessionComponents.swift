import SwiftUI

/// Horizontal Chrome-style resource-type filter chips. "All" clears the set.
public struct ResourceFilterBar: View {
    @Binding var selection: Set<ResourceType>
    public init(selection: Binding<Set<ResourceType>>) { self._selection = selection }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(label: "All", systemImage: "square.grid.2x2",
                     active: selection.isEmpty) { selection.removeAll() }
                ForEach(ResourceType.allCases, id: \.self) { type in
                    chip(label: type.label, systemImage: type.systemImage,
                         active: selection.contains(type)) {
                        if selection.contains(type) { selection.remove(type) } else { selection.insert(type) }
                    }
                }
            }
            .padding(.horizontal, 10)
        }
    }

    private func chip(label: String, systemImage: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 10))
                Text(label).font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(active ? Theme.color.accent.opacity(0.22) : Theme.color.fill,
                        in: Capsule())
            .overlay(Capsule().stroke(active ? Theme.color.accent : Theme.color.hairline, lineWidth: 1))
            .foregroundStyle(active ? Theme.color.accent : Theme.color.textMuted)
        }
        .buttonStyle(.plain)
    }
}

/// One row in the Sessions list: name, time, record count, REC indicator.
public struct SessionRow: View {
    let session: CaptureSession
    public init(session: CaptureSession) { self.session = session }

    public var body: some View {
        HStack(spacing: 9) {
            Image(systemName: session.isRecording ? "record.circle" : "folder")
                .font(.system(size: 13))
                .foregroundStyle(session.isRecording ? Theme.color.red : Theme.color.textMuted)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.color.textBright).lineLimit(1)
                Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 10)).foregroundStyle(Theme.color.textFaint)
            }
            Spacer()
            if session.isRecording {
                Text("REC").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.color.red)
            }
            Text("\(session.recordCount)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.color.textFaint)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Theme.color.fill, in: Capsule())
        }
        .padding(.vertical, 3)
    }
}
