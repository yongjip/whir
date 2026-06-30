import SwiftUI
import ServiceManagement

/// Settings window: subscription inputs (drive the ROI multiplier) + launch at
/// login. Shown as a real Window scene (see WhirApp) so its TextFields keep
/// focus — a sheet from the menu-bar popover would dismiss on the first click.
struct SubscriptionSettings: View {
    @AppStorage("sub.claude") private var claudeSub = 0.0
    @AppStorage("sub.codex") private var codexSub = 0.0
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
