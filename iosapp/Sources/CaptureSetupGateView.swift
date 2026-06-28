import SwiftUI
import HTTrailCore

struct CapturePrivacyDisclosure: View {
    var targetLabel: String?
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: compact ? 16 : 19, weight: .semibold))
                .foregroundStyle(Theme.color.green)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: compact ? 3 : 6) {
                Text("Private by default")
                    .font(.system(size: compact ? 12.5 : 14, weight: .bold))
                    .foregroundStyle(Theme.color.textBright)
                Text(disclosureText)
                    .font(.system(size: compact ? 11.5 : 12.5))
                    .lineSpacing(2)
                    .foregroundStyle(Theme.color.textDim)
            }
        }
        .padding(compact ? 11 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.color.green.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: Theme.radius.field, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius.field, style: .continuous)
            .strokeBorder(Theme.color.green.opacity(0.24), lineWidth: 1))
    }

    private var disclosureText: String {
        let target = targetLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let target, !target.isEmpty, target != CaptureTarget.thisDevice.label {
            return "Captured URLs, headers, and bodies are routed only to \(target), because you selected that target. HTTrail does not sell, use, or disclose captured data to third parties. Nothing leaves your devices unless you export, share, or choose a capture target."
        }
        return "Captured URLs, headers, and bodies stay in HTTrail on this device. HTTrail does not sell, use, or disclose captured data to third parties. Nothing leaves your devices unless you explicitly export or share it."
    }
}

struct CaptureSetupGateSheet: View {
    let readiness: CaptureStartReadiness
    let targetLabel: String
    let isChecking: Bool
    let onInstallProfile: () -> Void
    let onRecheck: () -> Void
    let onOpenSettings: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    CapturePrivacyDisclosure(targetLabel: targetLabel)

                    VStack(alignment: .leading, spacing: 10) {
                        HTEyebrow("Before capture starts")
                        CaptureRequirementRow(
                            title: "VPN profile",
                            detail: readiness.contains(.vpnProfileMissing)
                                ? "Install and approve the HTTrail VPN profile in Settings."
                                : "Installed",
                            systemImage: "network",
                            isSatisfied: !readiness.contains(.vpnProfileMissing),
                            actionTitle: readiness.contains(.vpnProfileMissing) ? "Install Profile" : nil,
                            action: onInstallProfile
                        )
                        CaptureRequirementRow(
                            title: "Certificate trust",
                            detail: readiness.contains(.certificateUntrusted)
                                ? "Enable full trust for the HTTrail root certificate."
                                : "Trusted",
                            systemImage: "checkmark.shield",
                            isSatisfied: !readiness.contains(.certificateUntrusted),
                            actionTitle: readiness.contains(.certificateUntrusted) ? "Open Settings" : nil,
                            action: onOpenSettings
                        )
                    }

                    Text("After installing the profile, go to Settings > General > VPN & Device Management to approve it, then Settings > General > About > Certificate Trust Settings to enable full trust. Return here and re-check before starting capture.")
                        .font(.caption)
                        .foregroundStyle(Theme.color.textFaint)
                        .lineSpacing(2)

                    Button {
                        onRecheck()
                    } label: {
                        HStack {
                            if isChecking { ProgressView().controlSize(.small) }
                            Text(isChecking ? "Checking..." : "Re-check Setup")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.color.accent)
                    .disabled(isChecking)
                }
                .padding(18)
            }
            .background(Theme.appBackground)
            .navigationTitle("Capture Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct CaptureRequirementRow: View {
    let title: String
    let detail: String
    let systemImage: String
    let isSatisfied: Bool
    let actionTitle: String?
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            Image(systemName: isSatisfied ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(isSatisfied ? Theme.color.green : Theme.color.amber)
                .frame(width: 24)
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.color.textMuted)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.color.textBright)
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.color.textDim)
            }
            Spacer(minLength: 8)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .font(.system(size: 11.5, weight: .semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.color.surface.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: Theme.radius.field, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius.field, style: .continuous)
            .strokeBorder(Theme.color.borderStrong, lineWidth: 1))
    }
}
