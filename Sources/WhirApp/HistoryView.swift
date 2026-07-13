import SwiftUI
import Charts
import WhirCore

struct HistoryView: View {
    @Bindable var model: HistoryModel
    // List stays the default (restraint); the chart is an opt-in view style.
    @AppStorage("history.chart") private var showChart = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.loading {
                buildingView
            } else if model.recent.isEmpty {
                Text("No usage found.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                legendView
                HStack(alignment: .top, spacing: 16) {
                    Group { if showChart { chart } else { spine } }.frame(width: 360)
                    detailPanel
                }
            }
            Text("Local logs only · no keychain · nothing uploaded · prices as of \(Pricing.asOf)")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(16)
        // Wide enough that the 360pt spine + the ~448pt drilldown table both fit
        // without the Cost column overflowing the right edge.
        .frame(minWidth: 880, minHeight: 460)
        .task { model.start() }
    }

    // The one anchor number + controls.
    private var header: some View {
        HStack(spacing: 12) {
            if model.recent.isEmpty {
                Text("Usage history").font(.title3.weight(.semibold))
            } else {
                Text(moneyAdaptive(model.rangeTotal)).font(.title3.weight(.semibold)).monospacedDigit()
                // "with usage" — recent shows buckets that had cost, not a contiguous calendar span.
                Text("\(model.recent.count) \(model.granularity.rawValue)s with usage")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: Binding(get: { model.granularity }, set: { model.setGranularity($0) })) {
                ForEach(Granularity.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(width: 210)
            Picker("", selection: Binding(get: { model.groupBy }, set: { model.setGroupBy($0) })) {
                ForEach(GroupBy.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
            Picker("", selection: $showChart) {
                Image(systemName: "list.bullet").tag(false)
                Image(systemName: "chart.bar.fill").tag(true)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 70)
                .help("List or chart")
            if model.building { ProgressView().controlSize(.small) }
            Button {
                if let url = model.exportCSV() {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } label: { Image(systemName: "square.and.arrow.up") }
                .buttonStyle(.borderless).help("Export CSV to Downloads")
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Refresh")
        }
    }

    // MARK: chart (stacked bars over time; click a bar to drill down)

    /// Groups ordered by total cost desc — keeps chart colors identical to the
    /// legend and the spine (model.color drives all three).
    private var chartGroups: [String] {
        var totals: [String: Double] = [:]
        for p in model.recent { for s in p.slices { totals[s.name, default: 0] += s.cost } }
        return totals.sorted { $0.value > $1.value }.map(\.key)
    }

    private var chart: some View {
        let labels = model.recent.map(\.label)
        let stride = max(1, labels.count / 6)
        let ticks = Swift.stride(from: 0, to: labels.count, by: stride).map { labels[$0] }
        return Chart {
            ForEach(model.recent) { p in
                ForEach(p.slices, id: \.name) { s in
                    BarMark(x: .value("Period", p.label), y: .value("Cost", s.cost))
                        .foregroundStyle(by: .value("Group", s.name))
                }
            }
        }
        .chartForegroundStyleScale(domain: chartGroups, range: chartGroups.map { model.color($0) })
        .chartLegend(.hidden)   // the legend row above already covers it
        .chartXAxis { AxisMarks(values: ticks) }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let plot = proxy.plotFrame else { return }
                        let x = location.x - geo[plot].origin.x
                        if let label: String = proxy.value(atX: x),
                           let key = model.key(forLabel: label) {
                            model.selectedKey = key
                        }
                    }
            }
        }
    }

    private var buildingView: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Building history… the first scan reads all local logs and can take a minute.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var legendView: some View {
        // Horizontal scroll + fixedSize so long model names (by-model grouping)
        // show in full instead of compressing to identical truncated stubs.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(model.legend) { g in
                    HStack(spacing: 4) {
                        Circle().fill(g.color).frame(width: 7, height: 7)
                        Text(g.name).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    }
                }
            }
        }
    }

    // Spine: bars live inside the list rows (chart + list merged into one element).
    private var spine: some View {
        List(selection: $model.selectedKey) {
            ForEach(model.recent.reversed()) { p in
                HStack(spacing: 10) {
                    Text(p.label).font(.system(size: 12)).monospacedDigit()
                        .foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
                    bar(p, lane: 150)
                    Spacer(minLength: 4)
                    Text(moneyAdaptive(p.total)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                }
                .tag(p.key)
            }
        }
    }

    private func bar(_ p: GroupedPoint, lane: CGFloat) -> some View {
        let filled = model.recentMax > 0 ? CGFloat(p.total / model.recentMax) * lane : 0
        return HStack(spacing: 0.5) {
            ForEach(p.slices, id: \.name) { s in
                Rectangle().fill(model.color(s.name))
                    .frame(width: max(filled * CGFloat(s.cost / max(p.total, 0.0001)), s.cost > 0 ? 1 : 0))
            }
            Spacer(minLength: 0)
        }
        .frame(width: lane, height: 10)
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }

    // MARK: drilldown token table (Total column + provider tag removed as redundant)

    private func num(_ s: String, _ w: CGFloat) -> some View {
        Text(s).font(.system(size: 11)).monospacedDigit().frame(width: w, alignment: .trailing)
    }
    private func head(_ s: String, _ w: CGFloat, _ a: Alignment = .trailing) -> some View {
        Text(s).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: w, alignment: a)
    }
    private var columnHeader: some View {
        HStack(spacing: 8) {
            head("", 176, .leading)
            head("Input", 56); head("Cache", 56); head("Output", 56); head("Cost", 72)
        }
    }
    private func usageRow(_ name: AnyView, _ t: ModelTokens, _ cost: Double, priced: Bool = true) -> some View {
        HStack(spacing: 8) {
            name.frame(width: 176, alignment: .leading)
            num(tokenShort(t.input), 56); num(tokenShort(t.cacheAll), 56)
            num(tokenShort(t.output), 56); num(priced ? moneyAdaptive(cost) : "—", 72)
        }
    }

    @ViewBuilder private var detailPanel: some View {
        if let d = model.detail, let key = model.selectedKey {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(key).font(.system(size: 14, weight: .medium))
                    if !d.models.isEmpty {
                        Text("By model").font(.caption).foregroundStyle(.secondary)
                        columnHeader
                        ForEach(d.models) { m in
                            usageRow(AnyView(Text(m.model).font(.system(size: 11)).lineLimit(1)),
                                     m.tokens, m.cost, priced: m.priced)
                        }
                        if d.models.contains(where: { !$0.priced }) {
                            Text("— price unknown for this model (not included in totals)")
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                    }
                    if !d.projects.isEmpty {
                        Text("By project").font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                        columnHeader
                        ForEach(d.projects) { p in
                            usageRow(AnyView(Text(p.project).font(.system(size: 11))
                                .lineLimit(1).truncationMode(.middle)), p.tokens, p.cost)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("Select a period to see its models and projects")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
