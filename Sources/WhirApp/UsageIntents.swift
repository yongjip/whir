import AppIntents
import WhirCore

/// "What's my AI usage today?" as a Shortcuts / Spotlight action.
///
/// Reads the cached all-time snapshot from our OWN app-support container, so it
/// needs no security-scoped folder access and works even when the menu-bar app
/// isn't foregrounded. The figure is "as of the last in-app refresh" — fine for
/// a glanceable shortcut; we don't kick off a full log rescan here.
struct TodayUsageIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Today's AI Usage"
    static var description = IntentDescription(
        "Returns today's estimated AI coding spend (Claude Code + Codex), computed locally on this Mac."
    )
    // We only read our own cache — no need to launch the UI.
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        // No cached scan yet → don't assert "$0"; tell the user to open Whir once.
        guard let total = TodayUsage.todaysSpend() else {
            return .result(value: 0, dialog: IntentDialog("No usage data yet — open Whir to scan your logs."))
        }
        return .result(value: total, dialog: IntentDialog("Today's AI usage: \(money0(total))"))
    }
}

struct WhirShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TodayUsageIntent(),
            phrases: [
                "Get today's AI usage in \(.applicationName)",
                "How much AI have I used today in \(.applicationName)",
                "\(.applicationName) today's spend",
            ],
            shortTitle: "Today's AI Usage",
            systemImageName: "dollarsign.circle"
        )
    }
}

/// Pure, actor-agnostic read of today's spend from the cached snapshot.
/// nil = no scan cached yet (distinct from a real "today so far: $0").
enum TodayUsage {
    static func todaysSpend() -> Double? {
        guard let snap = HistoryEngine().cachedSnapshot() else { return nil }
        let daily = snap.grouped(.day, by: .provider)
        return daily.last(where: { $0.key == HistoryModel.todayKey })?.total ?? 0
    }
}
