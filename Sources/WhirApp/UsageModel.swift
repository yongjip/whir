import SwiftUI
import Combine
import WhirCore

/// Projection of HistoryModel.shared for the menu bar + popover headline:
/// TODAY's spend as the glanceable number, plus the last-30-days total for the
/// ROI line. The History model owns the scan; this just mirrors its results.
@MainActor
final class UsageModel: ObservableObject {
    struct Row: Identifiable { let id = UUID(); let name: String; let cost: Double; let pct: Double }

    @Published var loading = true
    @Published var refreshing = false
    @Published var total = 0.0          // today's spend (the headline number)
    @Published var rows: [Row] = []     // today's provider split
    @Published var last30 = 0.0         // last-30-days value, for the ROI line
    @Published var hasReadableRoot = true

    private var cancellable: AnyCancellable?

    init() {
        let h = HistoryModel.shared
        sync(h)
        // Re-project whenever the shared history model changes. objectWillChange
        // fires before the value is set, so read on the next tick.
        cancellable = h.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.sync(HistoryModel.shared) }
        }
    }

    var menuTitle: String { loading ? "AI $…" : money0(total) }

    /// The History model owns the scan + its auto-refresh timer; just delegate.
    func refresh() { HistoryModel.shared.refresh() }

    private func sync(_ h: HistoryModel) {
        refreshing = h.building
        hasReadableRoot = h.hasReadableRoot
        guard let hl = h.headline else { loading = h.loading; return }
        total = hl.today
        last30 = hl.last30
        rows = [
            Row(name: "Codex", cost: hl.codex, pct: hl.today > 0 ? hl.codex / hl.today : 0),
            Row(name: "Claude Code", cost: hl.claude, pct: hl.today > 0 ? hl.claude / hl.today : 0),
        ]
        loading = false
    }
}
