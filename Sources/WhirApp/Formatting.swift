import Foundation

// Shared currency formatting. Module-internal so every view can use it.

private func money(_ v: Double, digits: Int) -> String {
    let f = NumberFormatter()
    f.numberStyle = .currency
    f.currencyCode = "USD"
    // Prices are USD; pin US grouping/symbol placement so a non-US device
    // locale doesn't render lakh grouping or a trailing symbol.
    f.locale = Locale(identifier: "en_US")
    f.maximumFractionDigits = digits
    f.minimumFractionDigits = digits
    return f.string(from: v as NSNumber) ?? "$0"
}

func money0(_ v: Double) -> String { money(v, digits: 0) }
func money2(_ v: Double) -> String { money(v, digits: 2) }

/// Adaptive: cents only below $100 (no false precision on large totals).
func moneyAdaptive(_ v: Double) -> String { money(v, digits: v >= 100 ? 0 : 2) }

/// Compact token count: 1.2M / 34K / 512.
func tokenShort(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1e6) }
    if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1e3) }
    return "\(n)"
}
