import SwiftUI
import WhirCore

/// Projection of HistoryModel.shared for the menu bar + popover headline:
/// TODAY's spend as the glanceable number, plus the last-30-days total for the
/// ROI line. The History model owns the scan; this just mirrors its results.
///
/// Everything here is a computed read of HistoryModel.shared. Because that model
/// is `@Observable`, SwiftUI tracks these reads transitively — so the old
/// `objectWillChange.sink` re-projection glue is gone.
@MainActor
@Observable
final class UsageModel {
    // Identify by name (stable) so ForEach doesn't churn on every recompute.
    struct Row: Identifiable { let name: String; let cost: Double; let pct: Double; var id: String { name } }

    private var h: HistoryModel { HistoryModel.shared }

    var loading: Bool { h.headline == nil && h.loading }
    var refreshing: Bool { h.building }
    var hasReadableRoot: Bool { h.hasReadableRoot }
    var total: Double { h.headline?.today ?? 0 }        // today's spend (the headline number)
    var last30: Double { h.headline?.last30 ?? 0 }      // last-30-days value, for the ROI line

    /// Today's provider split.
    var rows: [Row] {
        guard let hl = h.headline else { return [] }
        return [
            Row(name: "Codex", cost: hl.codex, pct: hl.today > 0 ? hl.codex / hl.today : 0),
            Row(name: "Claude Code", cost: hl.claude, pct: hl.today > 0 ? hl.claude / hl.today : 0),
        ]
    }

    var menuTitle: String { loading ? "AI $…" : money0(total) }

    /// The History model owns the scan + its auto-refresh timer; just delegate.
    func refresh() { h.refresh() }
}
