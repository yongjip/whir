import Foundation
import AppKit
import OSLog
import WhirCore

/// Whir's single network touchpoint: refreshes the model price table
/// (pricing.json) from this project's GitHub repo, at most once a day.
/// Strictly one-way — a GET for a public file; nothing about the user or their
/// usage is ever sent, and Settings can turn it off. WhirCore and the CLI stay
/// network-free: they only read the file this writes to Application Support.
@MainActor
final class PricingUpdater {
    static let shared = PricingUpdater()
    static let defaultsKey = "pricing.autoUpdate"
    private static let lastFetchKey = "pricing.lastFetch"
    private static let lastAttemptKey = "pricing.lastAttempt"
    static let lastFailureKey = "pricing.lastFailure"

    private static let source = URL(string: "https://raw.githubusercontent.com/yongjip/whir/main/pricing.json")!
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var fetching = false
    private let logger = Logger(subsystem: "com.whir.Whir", category: "pricing")

    private var enabled: Bool {
        UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool ?? true   // default on
    }

    /// At launch: adopt the cached table synchronously (so the first scan
    /// prices with it), then check GitHub in the background. Check the daily
    /// eligibility hourly and on wake so a sleeping menu-bar app does not
    /// depend on one timer firing at exactly the right time.
    func start() {
        Pricing.loadOverride()
        refreshNow()
        let timer = Timer(timeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in PricingUpdater.shared.refreshNow() }
        }
        timer.tolerance = 300
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in PricingUpdater.shared.refreshNow() }
        }
    }

    /// `force` (Settings opt-in) bypasses the once-a-day throttle for immediacy.
    func refreshNow(force: Bool = false) {
        guard enabled, !fetching else { return }
        // Throttle attempts, not just successes: a network failure must not
        // cause a request on every wake or app relaunch.
        let defaults = UserDefaults.standard
        let lastAttempt = defaults.object(forKey: Self.lastAttemptKey) as? Date
            ?? defaults.object(forKey: Self.lastFetchKey) as? Date
        if !force, let last = lastAttempt,
           Date().timeIntervalSince(last) < 24 * 3600 { return }
        fetching = true
        defaults.set(Date(), forKey: Self.lastAttemptKey)
        Task {
            defer { fetching = false }
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15
            let session = URLSession(configuration: config)
            do {
                let (data, resp) = try await session.data(from: Self.source)
                guard let response = resp as? HTTPURLResponse else {
                    markFailure("Price update returned a non-HTTP response")
                    return
                }
                guard response.statusCode == 200 else {
                    markFailure("Price update returned HTTP \(response.statusCode)")
                    return
                }
                guard let table = PricingTable.parse(data) else {
                    markFailure("Price update returned an invalid table")
                    return
                }
                // Save only a newer table, before adopting it in memory. If the
                // write fails, the next daily attempt must still be able to retry.
                if table.asOf > Pricing.asOf {
                    let url = Pricing.overrideURL()
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                    if Pricing.apply(table) { HistoryModel.shared.refresh() }
                }
                defaults.set(Date(), forKey: Self.lastFetchKey)
                defaults.set(false, forKey: Self.lastFailureKey)
            } catch {
                markFailure("Price update failed: \(error.localizedDescription)")
            }
        }
    }

    private func markFailure(_ message: String) {
        UserDefaults.standard.set(true, forKey: Self.lastFailureKey)
        logger.error("\(message, privacy: .public)")
    }
}
