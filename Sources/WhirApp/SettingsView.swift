import SwiftUI
import ServiceManagement

/// Settings window: subscription inputs (drive the ROI multiplier) + launch at
/// login. Shown as a real Window scene (see WhirApp) so its TextFields keep
/// focus — a sheet from the menu-bar popover would dismiss on the first click.
struct SubscriptionSettings: View {
    @AppStorage("sub.claude") private var claudeSub = 0.0
    @AppStorage("sub.codex") private var codexSub = 0.0
    @AppStorage(PricingUpdater.defaultsKey) private var autoUpdatePricing = true
    @Environment(\.dismiss) private var dismiss

    // Drive the toggle straight from the real login-item status (no @State
    // mirror): the getter re-reads each render, and the setter surfaces
    // .requiresApproval by sending the user to System Settings instead of
    // claiming success.
    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { LaunchAtLogin.isEnabled },
            set: { on in
                if LaunchAtLogin.set(on) == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Monthly subscriptions").font(.system(size: 15, weight: .medium))
            Text("Enter your flat monthly cost so Whir can show value vs. what you actually pay.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            row("Claude", $claudeSub)
            row("Codex", $codexSub)
            HStack {
                Text("Total").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Text("$\(Int((claudeSub + codexSub).rounded()))/mo").font(.system(size: 12, weight: .medium)).monospacedDigit()
            }

            Divider().padding(.vertical, 2)

            Toggle("Launch Whir at login", isOn: launchAtLogin)
                .font(.system(size: 13))

            Toggle("Update model prices automatically", isOn: $autoUpdatePricing)
                .font(.system(size: 13))
                .onChange(of: autoUpdatePricing) { _, on in
                    // Fetch right away on opt-in (bypass the daily throttle) instead
                    // of waiting for the timer.
                    if on { Task { @MainActor in PricingUpdater.shared.refreshNow(force: true) } }
                }
            Text("Once a day, Whir downloads its price table (pricing.json) from GitHub — its only network request. Nothing about you or your usage is sent.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Recovery path for a grant that points at the wrong folder — the
            // onboarding view never reappears once bookmarks exist.
            if FolderAccess.isSandboxed {
                Divider().padding(.vertical, 2)
                Text("Folder access").font(.system(size: 13, weight: .medium))
                HStack(spacing: 8) {
                    Button("Re-grant ~/.claude…") {
                        if FolderAccess.grant(id: FolderAccess.claudeID) { HistoryModel.shared.refresh() }
                    }
                    Button("Re-grant ~/.codex…") {
                        if FolderAccess.grant(id: FolderAccess.codexID) { HistoryModel.shared.refresh() }
                    }
                }
                .font(.system(size: 12))
            }

            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func row(_ label: String, _ value: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 13)).frame(width: 64, alignment: .leading)
            Text("$")
            TextField("0", value: value, format: .number)
                .textFieldStyle(.roundedBorder).frame(width: 90).monospacedDigit()
            Text("/mo").font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
        }
    }
}
