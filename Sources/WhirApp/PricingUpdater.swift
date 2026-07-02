import Foundation
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

    private static let source = URL(string: "https://raw.githubusercontent.com/yongjip/whir/main/pricing.json")!
    private var timer: Timer?

    private var enabled: Bool {
        UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool ?? true   // default on
    }

    /// At launch: adopt the cached table synchronously (so the first scan
    /// prices with it), then check GitHub in the background and again daily.
    func start() {
        Pricing.loadOverride()
        refreshNow()
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in
            Task { @MainActor in PricingUpdater.shared.refreshNow() }
        }
    }

    func refreshNow() {
        guard enabled else { return }
        Task {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15
            let session = URLSession(configuration: config)
            guard let (data, resp) = try? await session.data(from: Self.source),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let table = PricingTable.parse(data) else { return }   // bad fetch/parse → keep current table
            // Cache the raw file (the next launch adopts it offline), then apply.
            // A newer table shifts Pricing.asOf, which invalidates the scan
            // caches — the triggered refresh re-prices everything consistently.
            let url = Pricing.overrideURL()
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
            if Pricing.apply(table) {
                HistoryModel.shared.refresh()
            }
        }
    }
}
