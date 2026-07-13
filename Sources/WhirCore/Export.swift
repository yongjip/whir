import Foundation

public extension HistorySnapshot {
    /// Full-fidelity CSV of the usage history at the given granularity: one
    /// row per (period, provider, project, model), raw token columns plus a
    /// read-time cost. Cost cells are EMPTY (never 0.00) for models missing
    /// from the price table — same honesty rule as the UI's "—".
    func csv(_ g: Granularity) -> String {
        struct Key: Hashable {
            let period: String, provider: String, project: String, model: String
        }
        var rows: [Key: (Provider, ModelTokens)] = [:]
        var weekMemo: [String: (String, String)] = [:]
        for agg in aggs.values {
            for (hourKey, bd) in agg.buckets {
                let period = rollupKey(hourKey, g, &weekMemo).key
                for (proj, pa) in bd.projects {
                    for (model, t) in pa.models {
                        let k = Key(period: period, provider: agg.provider.rawValue,
                                    project: proj, model: model)
                        let prev = rows[k]?.1 ?? ModelTokens()
                        rows[k] = (agg.provider, prev + t)
                    }
                }
            }
        }
        func esc(_ s: String) -> String {
            s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" })
                ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        var out = "period,provider,project,model,input,cached_input,cache_read,"
                + "cache_write_5m,cache_write_1h,output,cost_usd\n"
        let sorted = rows.sorted {
            ($0.key.period, $0.key.provider, $0.key.project, $0.key.model)
                < ($1.key.period, $1.key.provider, $1.key.project, $1.key.model)
        }
        for (k, v) in sorted {
            let (provider, t) = v
            let c = cost(provider: provider, model: k.model, tokens: t)
            let costStr = c.priced ? String(format: "%.4f", c.usd) : ""
            out += [esc(k.period), esc(k.provider), esc(k.project), esc(k.model),
                    "\(t.input)", "\(t.cachedInput)", "\(t.cacheRead)",
                    "\(t.cacheWrite5m)", "\(t.cacheWrite1h)", "\(t.output)",
                    costStr].joined(separator: ",") + "\n"
        }
        return out
    }
}
