import Foundation

private func pad(_ s: String, _ w: Int) -> String {
    s.count >= w ? s : s + String(repeating: " ", count: w - s.count)
}
private func padLeft(_ s: String, _ w: Int) -> String {
    s.count >= w ? s : String(repeating: " ", count: w - s.count) + s
}
private func money(_ v: Double) -> String { String(format: "$%.2f", v) }
private func valueLabel(_ value: Double, hasUnpriced: Bool) -> String {
    hasUnpriced ? (value > 0 ? money(value) + "+" : "—") : money(value)
}

public extension UsageReport {
    /// Plain-text summary for the CLI.
    func render(windowLabel: String) -> String {
        var out = "================ \(windowLabel) — estimated usage value ================\n"

        for provider in [Provider.claude, .codex] {
            let ms = models.filter { $0.provider == provider }.sorted { $0.cost > $1.cost }
            if ms.isEmpty { continue }
            out += "\n\(provider.rawValue)\n"
            for m in ms {
                let tag = m.estimate ? " *" : (m.priced ? "" : " (no price)")
                let toks = String(format: "%.1fM tok", Double(m.tokens.total) / 1e6)
                out += "  \(pad(m.model, 22)) \(padLeft(m.priced ? money(m.cost) : "—", 10))   \(padLeft(toks, 11))\(tag)\n"
            }
            out += "  subtotal: \(valueLabel(cost(for: provider), hasUnpriced: hasUnpriced(for: provider)))\n"
        }

        if !costByProject.isEmpty {
            out += "\n  top projects (Claude):\n"
            for (proj, c) in costByProject.sorted(by: { $0.value > $1.value }).prefix(6) {
                out += "    \(pad(proj, 26)) \(padLeft(valueLabel(c, hasUnpriced: unpricedProjects.contains(proj)), 10))\n"
            }
        }

        out += "\n================ ALL AI: \(valueLabel(totalCost, hasUnpriced: hasUnpriced)) ================\n"
        out += "  Claude Code \(valueLabel(cost(for: .claude), hasUnpriced: hasUnpriced(for: .claude)))"
        out += "  ·  Codex \(valueLabel(cost(for: .codex), hasUnpriced: hasUnpriced(for: .codex)))\n"
        out += "  \(filesScanned) files · prices as of \(Pricing.asOf)"
        if hasEstimates { out += " · * = rough tier estimate" }
        if hasUnpriced { out += " · + = partial value" }
        out += "\n  local logs only — no credentials, no keychain\n"
        return out
    }
}
