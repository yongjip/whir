import SwiftUI
import AppKit
import WhirCore

struct PopoverView: View {
    @ObservedObject var model: UsageModel
    @Environment(\.openWindow) private var openWindow
    @State private var needsGrant = FolderAccess.needsOnboarding
    @StateObject private var monitor = SystemMonitor()
    @AppStorage("sub.claude") private var claudeSub = 0.0
    @AppStorage("sub.codex") private var codexSub = 0.0
    private var totalSub: Double { claudeSub + codexSub }

    var body: some View {
        if needsGrant { grantView } else { mainView }
    }

    /// Open a real Window scene (not a sheet) and pull it to the front. A sheet or
    /// popover presented from the MenuBarExtra(.window) panel dies when the panel
    /// resigns key — which is exactly the moment a TextField takes focus.
    private func openSettings() { openAppWindow("settings") }

    /// Open a real Window scene and front it on the NEXT runloop. Activating
    /// synchronously races the menu-bar panel resigning key (and, for a window
    /// that was fully closed, can land before SwiftUI recreates it).
    private func openAppWindow(_ id: String) {
        openWindow(id: id)
        DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
    }

    private func refreshGrant() {
        needsGrant = FolderAccess.needsOnboarding
        if !needsGrant { model.refresh() }
    }

    private func gb(_ b: Double) -> String { String(format: "%.0f", b / 1e9) }
    private func loadColor(_ f: Double) -> Color { f < 0.6 ? .green : (f < 0.85 ? .orange : .red) }
    private func statRow(_ label: String, _ fraction: Double, _ detail: String, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(color).frame(width: max(geo.size.width * min(fraction, 1), fraction > 0 ? 3 : 0))
                }
            }.frame(height: 5)
            Text(detail).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 92, alignment: .trailing)
        }
    }

    /// The ROI reframe — Whir's differentiator — given a visible, emphasized block.
    @ViewBuilder private var roiHero: some View {
        let shownSub = Int(totalSub.rounded())   // divide by the SAME number we display
        // Lead with the concrete last-30-days spend; the ROI multiple (vs the
        // monthly subscription) is the supporting context.
        if totalSub >= 1, let mult = roiMultiplier(total: model.last30, subscription: Double(shownSub)) {
            let win = mult >= 1   // below break-even shouldn't look like a value "win"
            roiBlock(win: win, accent: win) {
                Text(moneyAdaptive(model.last30))
                    .font(.system(size: 16, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(win ? Color.accentColor : .primary)
                Text(win ? "last 30d · \(roiText(mult)) your $\(shownSub)/mo"
                         : "last 30d · \(Int((mult * 100).rounded()))% of your $\(shownSub)/mo")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
        } else {
            // No subscription set yet — still show the 30-day spend, plus a prompt.
            roiBlock(win: false, accent: false) {
                Text(moneyAdaptive(model.last30))
                    .font(.system(size: 16, weight: .semibold)).monospacedDigit()
                Text("last 30 days").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Set $/mo for ROI →") { openSettings() }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color.accentColor)
            }
        }
    }

    private func roiBlock<Content: View>(win: Bool, accent: Bool, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((accent ? Color.accentColor : Color.secondary).opacity(accent ? 0.12 : 0.08),
                        in: RoundedRectangle(cornerRadius: 8))
            .padding(.top, 9)
    }

    private func roiText(_ m: Double) -> String {
        m >= 10 ? "\(Int(m.rounded()))×" : String(format: "%.1f×", m)
    }

    private var noLogsView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No logs found").font(.system(size: 16, weight: .medium))
            Text("Whir couldn't read Claude Code (~/.claude) or Codex (~/.codex) logs here. Run a coding session, or confirm those folders exist.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 12)
    }

    private var grantView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Grant read access").font(.system(size: 14, weight: .medium))
            Text("Whir reads token counts from your local Claude Code and Codex folders — nothing else, never uploaded. Pick each folder once (press \u{21E7}\u{2318}. to show hidden folders).")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Button(FolderAccess.hasBookmark(FolderAccess.claudeID) ? "✓ ~/.claude granted" : "Grant ~/.claude…") {
                FolderAccess.grant(id: FolderAccess.claudeID); refreshGrant()
            }
            Button(FolderAccess.hasBookmark(FolderAccess.codexID) ? "✓ ~/.codex granted" : "Grant ~/.codex…") {
                FolderAccess.grant(id: FolderAccess.codexID); refreshGrant()
            }
            HStack {
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.borderless)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private var mainView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("AI cost").font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
                Text("Today").font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }

            if model.loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Calculating…").foregroundStyle(.secondary).font(.system(size: 13))
                }.padding(.vertical, 18)
            } else if model.total == 0 && !model.hasReadableRoot {
                noLogsView
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(money0(model.total)).font(.system(size: 34, weight: .medium)).monospacedDigit()
                    Text("estimated").font(.system(size: 11))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }.padding(.top, 10)
                Text("usage value · API-equivalent").font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.top, 1)

                roiHero

                Divider().padding(.vertical, 11)

                ForEach(model.rows) { row in
                    HStack {
                        Text(row.name).font(.system(size: 14))
                        Spacer()
                        Text(money2(row.cost)).font(.system(size: 14, weight: .medium)).monospacedDigit()
                        Text("\(Int((row.pct * 100).rounded()))%")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }.padding(.vertical, 5)
                }
            }

            Divider().padding(.vertical, 11)
            VStack(spacing: 7) {
                statRow("CPU", monitor.snapshot.cpu,
                        "\(Int((monitor.snapshot.cpu * 100).rounded()))%", loadColor(monitor.snapshot.cpu))
                statRow("RAM", monitor.snapshot.ramFraction,
                        "\(gb(Double(monitor.snapshot.ramUsed))) / \(gb(Double(monitor.snapshot.ramTotal))) GB",
                        loadColor(monitor.snapshot.ramFraction))
                statRow("Disk", monitor.snapshot.diskFraction,
                        "\(gb(Double(monitor.snapshot.diskUsed))) / \(gb(Double(monitor.snapshot.diskTotal))) GB",
                        loadColor(monitor.snapshot.diskFraction))
            }

            Divider().padding(.vertical, 11)

            HStack(spacing: 6) {
                Image(systemName: "lock.open").font(.system(size: 11)).foregroundStyle(.tertiary)
                Text("Local logs only · no keychain, no network")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text(Pricing.isStale()
                 ? "⚠ prices as of \(Pricing.asOf) — may be outdated"
                 : "prices as of \(Pricing.asOf)")
                .font(.system(size: 10))
                .foregroundStyle(Pricing.isStale() ? Color.orange : Color.secondary)
                .padding(.top, 2)

            HStack(spacing: 8) {
                Button("Refresh") { model.refresh() }
                Button("History") { openAppWindow("history") }
                Button { openSettings() } label: { Image(systemName: "gearshape") }
                if model.refreshing {
                    ProgressView().controlSize(.small)
                    Text("updating…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .padding(.top, 12)
        }
        .padding(16)
        .frame(width: 300)
        .onAppear {
            monitor.start()
            needsGrant = FolderAccess.needsOnboarding   // re-detect a lost/revoked grant
        }
        .onDisappear { monitor.stop() }
    }
}
