import SwiftUI
import AppKit

// App entry point + scenes. Views/models live in their own files:
// PopoverView, UsageModel, HistoryView, HistoryModel, SubscriptionSettings, Formatting.

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu-bar agent, no Dock icon
        // Adopt a previously fetched price table BEFORE the first scan, then
        // keep it fresh (a daily fetch — the app's only network call).
        PricingUpdater.shared.start()
        // Pre-warm the all-time history in the background so opening the
        // History window is instant instead of showing a cold "Building…".
        HistoryModel.shared.start()
    }
}

@main
struct WhirApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var model = UsageModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
        } label: {
            Text(model.menuTitle)
        }
        .menuBarExtraStyle(.window)

        Window("Usage history", id: "history") {
            HistoryView(model: .shared)
                .task { HistoryModel.shared.start() }   // idempotent; pre-warm usually ran already
        }
        .defaultSize(width: 920, height: 580)

        // A real Window (not a sheet/popover) so its TextFields keep focus —
        // the menu-bar popover panel dismisses the instant a field is clicked.
        // Titled "Settings" (not "Subscriptions") — it now also holds launch-at-
        // login, the price-update network switch, and folder-access re-grant.
        Window("Settings", id: "settings") {
            SubscriptionSettings()
        }
        .windowResizability(.contentSize)
    }
}
