import Charts
import SwiftUI

struct CashflowView: View {
    @Bindable var store: FinanceStore
    @State private var period: CashflowPeriod = .month
    @State private var selectedDate: Date?
    @State private var scrollPosition = Date()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Picker("Period", selection: $period) {
                        ForEach(CashflowPeriod.allCases) { period in
                            Text(period.title).tag(period)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)

                    HealthStyleCashChart(
                        period: period,
                        points: cashTrendPoints,
                        selectedDate: $selectedDate,
                        scrollPosition: $scrollPosition
                    )
                    .padding(.horizontal)

                    SelectedCashflowDayCard(trend: trend)
                        .padding(.horizontal)

                    TrendPill(trend: trend)
                        .padding(.horizontal)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Trends")
                            .font(.title.bold())
                        CashflowTrendCard(trend: trend, period: period)
                    }
                    .padding(.horizontal)

                    UpcomingProjectionSection(store: store)
                        .padding(.horizontal)
                }
                .padding(.vertical, 16)
            }
            .background(AppDesign.background)
            .navigationTitle("Cashflow")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await store.projectNextMonth() }
                    } label: {
                        Image(systemName: "sparkles")
                    }
                }
            }
            .onChange(of: period) { _, newValue in
                selectedDate = nil
                scrollPosition = newValue.defaultScrollPosition
            }
            .task {
                scrollPosition = period.defaultScrollPosition
                if store.projection.isEmpty {
                    await store.projectNextMonth()
                }
            }
        }
    }

    private var cashAccountIDs: Set<String> {
        Set(store.accounts
            .filter { $0.type != "credit" && $0.type != "loan" && $0.type != "investment" }
            .map(\.id))
    }

    private var currentCashBalanceCents: Int64 {
        store.accounts
            .filter { cashAccountIDs.contains($0.id) }
            .reduce(0) { $0 + $1.balanceCents }
    }

    private var cashTransactions: [Transaction] {
        guard !cashAccountIDs.isEmpty else { return store.cashflowTrendTransactions }
        return store.cashflowTrendTransactions.filter { cashAccountIDs.contains($0.accountID) }
    }

    private var cashTrendPoints: [CashTrendPoint] {
        let calendar = Calendar.current
        let now = Date()
        let currentInterval = period.dateInterval(endingAt: now)
        let transactionsThroughNow = cashTransactions.filter { $0.postedAt <= now }
        let earliestDate = transactionsThroughNow.map(\.postedAt).min() ?? currentInterval.start
        let startDate = min(earliestDate, currentInterval.start)
        let startBucket = period.bucketStart(for: startDate, calendar: calendar)
        let rangeTransactions = transactionsThroughNow.filter { $0.postedAt >= startBucket }
        let netChange = rangeTransactions.reduce(Int64(0)) { $0 + $1.amountCents }
        let openingBalance = currentCashBalanceCents - netChange
        let grouped = Dictionary(grouping: rangeTransactions) { period.bucketStart(for: $0.postedAt, calendar: calendar) }

        var points: [CashTrendPoint] = []
        var balance = openingBalance
        var bucket = startBucket
        let end = period.bucketStart(for: now, calendar: calendar)
        while bucket <= end {
            let transactions = (grouped[bucket] ?? []).sorted { $0.postedAt > $1.postedAt }
            let netFlow = transactions.reduce(Int64(0)) { $0 + $1.amountCents }
            balance += netFlow
            points.append(CashTrendPoint(date: bucket, balanceCents: balance, netFlowCents: netFlow, transactions: transactions))
            guard let next = period.nextBucket(after: bucket, calendar: calendar) else { break }
            bucket = next
        }
        return points
    }

    private var trend: CashflowTrend {
        CashflowTrend(points: cashTrendPoints, selectedDate: selectedDate, period: period)
    }
}

private enum CashflowPeriod: String, CaseIterable, Identifiable {
    case day
    case week
    case month
    case sixMonths
    case year

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: "D"
        case .week: "W"
        case .month: "M"
        case .sixMonths: "6M"
        case .year: "Y"
        }
    }

    var visibleSeconds: TimeInterval {
        switch self {
        case .day: 60 * 60 * 24
        case .week: 60 * 60 * 24 * 7
        case .month: 60 * 60 * 24 * 31
        case .sixMonths: 60 * 60 * 24 * 183
        case .year: 60 * 60 * 24 * 366
        }
    }

    var defaultScrollPosition: Date {
        Date().addingTimeInterval(-visibleSeconds)
    }

    var bucketComponent: Calendar.Component {
        switch self {
        case .day:
            .hour
        case .week, .month:
            .day
        case .sixMonths:
            .weekOfYear
        case .year:
            .month
        }
    }

    var axisLabelFormat: Date.FormatStyle {
        switch self {
        case .day:
            .dateTime.hour()
        case .week, .month:
            .dateTime.day()
        case .sixMonths, .year:
            .dateTime.month(.abbreviated)
        }
    }

    func dateInterval(endingAt date: Date) -> DateInterval {
        let calendar = Calendar.current
        let component: Calendar.Component
        let value: Int
        switch self {
        case .day:
            component = .day
            value = -1
        case .week:
            component = .day
            value = -7
        case .month:
            component = .month
            value = -1
        case .sixMonths:
            component = .month
            value = -6
        case .year:
            component = .year
            value = -1
        }
        let start = calendar.date(byAdding: component, value: value, to: date) ?? date
        return DateInterval(start: start, end: date)
    }

    func bucketStart(for date: Date, calendar: Calendar) -> Date {
        switch self {
        case .day:
            return calendar.dateInterval(of: .hour, for: date)?.start ?? date
        case .week, .month:
            return calendar.startOfDay(for: date)
        case .sixMonths:
            return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        case .year:
            let components = calendar.dateComponents([.year, .month], from: date)
            return calendar.date(from: components) ?? calendar.startOfDay(for: date)
        }
    }

    func nextBucket(after date: Date, calendar: Calendar) -> Date? {
        calendar.date(byAdding: bucketComponent, value: 1, to: date)
    }
}

private struct CashTrendPoint: Identifiable {
    let date: Date
    let balanceCents: Int64
    let netFlowCents: Int64
    let transactions: [Transaction]

    var id: Date { date }
    var balanceDollars: Double { Double(balanceCents) / 100 }
    var netFlowDollars: Double { Double(netFlowCents) / 100 }
    var inflowCents: Int64 { transactions.reduce(0) { $0 + max(0, $1.amountCents) } }
    var outflowCents: Int64 { transactions.reduce(0) { $0 + min(0, $1.amountCents) } }
}

private struct CashflowTrend {
    let points: [CashTrendPoint]
    let selectedDate: Date?
    let period: CashflowPeriod

    var selectedPoint: CashTrendPoint? {
        guard let selectedDate else { return nil }
        return points.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }

    var latestPoint: CashTrendPoint? {
        points.last
    }

    var headlineCents: Int64 {
        selectedPoint?.netFlowCents ?? latestPoint?.balanceCents ?? totalNetFlowCents
    }

    var startCents: Int64 {
        points.first?.balanceCents ?? 0
    }

    var endCents: Int64 {
        points.last?.balanceCents ?? 0
    }

    var netCents: Int64 {
        endCents - startCents
    }

    var totalNetFlowCents: Int64 {
        points.reduce(0) { $0 + $1.netFlowCents }
    }

    var inflowCents: Int64 {
        points.reduce(0) { $0 + max(0, $1.netFlowCents) }
    }

    var outflowCents: Int64 {
        points.reduce(0) { $0 + min(0, $1.netFlowCents) }
    }

    var dateRangeLabel: String {
        guard let first = points.first?.date, let last = points.last?.date else { return "No data" }
        return "\(first.formatted(date: .abbreviated, time: .omitted)) – \(last.formatted(date: .abbreviated, time: .omitted))"
    }

    var selectedLabel: String {
        guard let selectedPoint else { return latestPoint?.date.formatted(date: .abbreviated, time: .omitted) ?? dateRangeLabel }
        return selectedPoint.date.formatted(date: .abbreviated, time: .omitted)
    }

    var summary: String {
        let direction = netCents >= 0 ? "increased" : "decreased"
        return "Your cash balance \(direction) by \(AppDesign.money(abs(netCents))) over this period."
    }
}

private struct HealthStyleCashChart: View {
    let period: CashflowPeriod
    let points: [CashTrendPoint]
    @Binding var selectedDate: Date?
    @Binding var scrollPosition: Date
    @State private var scrollOffset: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0

    private let chartHeight: CGFloat = 330
    private let minimumChartWidth: CGFloat = 520
    private let yAxisWidth: CGFloat = 44
    private let scrollEndInset: CGFloat = 8
    private let endAnchorID = "cashflow-chart-end"

    private var pointSpacing: CGFloat {
        switch period {
        case .day:
            return 34
        case .week:
            return 52
        case .month:
            return 22
        case .sixMonths:
            return 20
        case .year:
            return 40
        }
    }

    private var selectedPoint: CashTrendPoint? {
        guard let selectedDate else { return nil }
        return points.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }

    private var headlineBalanceCents: Int64 {
        selectedPoint?.balanceCents ?? averageVisibleBalanceCents
    }

    private var averageVisibleBalanceCents: Int64 {
        let visiblePoints = visibleTrendPoints
        let values = visiblePoints.isEmpty ? points.map(\.balanceCents) : visiblePoints.map(\.balanceCents)
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Int64(values.count)
    }

    private var balanceDomain: ClosedRange<Double> {
        var domainPoints = visibleTrendPoints
        if let selectedPoint, !domainPoints.contains(where: { $0.id == selectedPoint.id }) {
            domainPoints.append(selectedPoint)
        }
        let values = (domainPoints.isEmpty ? points : domainPoints).map(\.balanceDollars)
        let rawMinValue = values.min() ?? 0
        let rawMaxValue = values.max() ?? 0
        let minValue = rawMinValue < 0 ? rawMinValue : 0
        let maxValue = max(0, rawMaxValue)
        let span = max(25, maxValue - minValue)
        let padding = span * 0.08
        let paddedLower = minValue - padding
        let paddedUpper = maxValue + padding
        let tick = niceTickSize(for: paddedUpper - paddedLower)
        let lower = rawMinValue < 0 ? floor(paddedLower / tick) * tick : 0
        let upper = ceil(paddedUpper / tick) * tick
        return lower...upper
    }

    private var visibleTrendPoints: [CashTrendPoint] {
        guard points.count > 1, viewportWidth > 0 else { return points }
        let availableWidth = max(1, viewportWidth - yAxisWidth - scrollEndInset)
        let leftX = max(0, scrollOffset)
        let rightX = min(chartContentWidth, leftX + availableWidth)
        let lastPointIndex = CGFloat(max(points.count - 1, 1))
        let firstVisible = Int(floor((leftX / chartContentWidth) * lastPointIndex))
        let lastVisible = Int(ceil((rightX / chartContentWidth) * lastPointIndex))
        let lowerIndex = max(points.startIndex, firstVisible - 1)
        let upperIndex = min(points.index(before: points.endIndex), lastVisible + 1)
        return Array(points[lowerIndex...upperIndex])
    }

    private var selectedNetCents: Int64 {
        selectedPoint?.netFlowCents ?? 0
    }

    private var chartContentWidth: CGFloat {
        max(minimumChartWidth, CGFloat(max(points.count - 1, 1)) * pointSpacing)
    }

    private var visibleStartDate: Date {
        date(atX: max(0, scrollOffset))
    }

    private var visibleEndDate: Date {
        date(atX: min(chartContentWidth, scrollOffset + max(1, viewportWidth - yAxisWidth - scrollEndInset)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(selectedPoint == nil ? "AVERAGE CASH BALANCE" : "CASH BALANCE")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(AppDesign.money(headlineBalanceCents))
                    .font(.system(size: 52, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(headlineBalanceCents >= 0 ? AppDesign.positive : AppDesign.warning)
                    .minimumScaleFactor(0.55)
                    .lineLimit(1)
                Text("cash")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text(selectedPoint?.date.formatted(date: .abbreviated, time: period == .day ? .shortened : .omitted) ?? visibleDateRangeLabel)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                if selectedPoint != nil {
                    Text(AppDesign.money(selectedNetCents))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(selectedNetCents >= 0 ? AppDesign.positive : AppDesign.warning)
                        .monospacedDigit()
                }
            }

            if points.count < 2 {
                ContentUnavailableView("Not Enough Data", systemImage: "chart.line.uptrend.xyaxis", description: Text("Connect or import more transactions to see a cashflow trend."))
                    .frame(height: 320)
            } else {
                GeometryReader { outerGeometry in
                    ZStack(alignment: .trailing) {
                        ScrollViewReader { scrollProxy in
                            ScrollView(.horizontal) {
                                HStack(spacing: 0) {
                                    cashChart
                                        .frame(width: chartContentWidth, height: chartHeight)
                                        .background(
                                            GeometryReader { contentGeometry in
                                                Color.clear.preference(
                                                    key: CashChartOffsetPreferenceKey.self,
                                                    value: contentGeometry.frame(in: .named("cashflowChartScroll")).minX
                                                )
                                            }
                                        )

                                    Color.clear
                                        .frame(width: scrollEndInset, height: chartHeight)
                                        .id(endAnchorID)
                                }
                            }
                            .coordinateSpace(name: "cashflowChartScroll")
                            .scrollIndicators(.hidden)
                            .padding(.trailing, yAxisWidth)
                            .onAppear {
                                viewportWidth = outerGeometry.size.width
                                scrollProxy.scrollTo(endAnchorID, anchor: .trailing)
                            }
                            .onChange(of: outerGeometry.size.width) { _, newWidth in
                                viewportWidth = newWidth
                            }
                            .onChange(of: period) { _, _ in
                                scrollProxy.scrollTo(endAnchorID, anchor: .trailing)
                            }
                            .onPreferenceChange(CashChartOffsetPreferenceKey.self) { minX in
                                let newOffset = max(0, -minX)
                                scrollOffset = newOffset
                                scrollPosition = date(atX: newOffset)
                            }
                        }

                        FixedCashYAxis(domain: balanceDomain)
                            .frame(width: yAxisWidth, height: chartHeight)
                            .background(AppDesign.background)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: chartHeight)
            }
        }
    }

    private var cashChart: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                let plotTop: CGFloat = 10
                let plotBottom: CGFloat = size.height - 34
                let plotHeight = max(1, plotBottom - plotTop)
                let lower = balanceDomain.lowerBound
                let upper = balanceDomain.upperBound
                let span = max(1, upper - lower)

                func xPosition(for index: Int) -> CGFloat {
                    guard points.count > 1 else { return 0 }
                    return CGFloat(index) / CGFloat(points.count - 1) * size.width
                }

                func yPosition(for value: Double) -> CGFloat {
                    let fraction = (value - lower) / span
                    return plotBottom - CGFloat(fraction) * plotHeight
                }

                for step in 0...4 {
                    let y = plotTop + plotHeight * CGFloat(step) / 4
                    var gridLine = Path()
                    gridLine.move(to: CGPoint(x: 0, y: y))
                    gridLine.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(gridLine, with: .color(.secondary.opacity(0.10)), lineWidth: 1)
                }

                let zeroY = yPosition(for: 0)
                var zeroLine = Path()
                zeroLine.move(to: CGPoint(x: 0, y: zeroY))
                zeroLine.addLine(to: CGPoint(x: size.width, y: zeroY))
                context.stroke(zeroLine, with: .color(.secondary.opacity(0.35)), style: StrokeStyle(lineWidth: 1))

                var linePath = Path()
                for (index, point) in points.enumerated() {
                    let position = CGPoint(x: xPosition(for: index), y: yPosition(for: point.balanceDollars))
                    if index == 0 {
                        linePath.move(to: position)
                    } else {
                        linePath.addLine(to: position)
                    }
                }
                context.stroke(linePath, with: .color(AppDesign.positive), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

                for (index, point) in points.enumerated() {
                    let center = CGPoint(x: xPosition(for: index), y: yPosition(for: point.balanceDollars))
                    context.fill(Path(ellipseIn: CGRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9)), with: .color(AppDesign.background))
                    context.fill(Path(ellipseIn: CGRect(x: center.x - 2.5, y: center.y - 2.5, width: 5, height: 5)), with: .color(AppDesign.positive))
                }

                if let selectedPoint, let selectedIndex = points.firstIndex(where: { $0.id == selectedPoint.id }) {
                    let selectedX = xPosition(for: selectedIndex)
                    var selectedLine = Path()
                    selectedLine.move(to: CGPoint(x: selectedX, y: plotTop))
                    selectedLine.addLine(to: CGPoint(x: selectedX, y: plotBottom))
                    context.stroke(selectedLine, with: .color(.secondary.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                    let selectedCenter = CGPoint(x: selectedX, y: yPosition(for: selectedPoint.balanceDollars))
                    context.fill(Path(ellipseIn: CGRect(x: selectedCenter.x - 6.5, y: selectedCenter.y - 6.5, width: 13, height: 13)), with: .color(.white))
                }
            }

            ForEach(xAxisTickIndices, id: \.self) { index in
                Text(points[index].date.formatted(period.axisLabelFormat))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .position(
                        x: xPosition(forIndex: index),
                        y: chartHeight - 12
                    )
            }

            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    SpatialTapGesture()
                        .onEnded { value in
                            updatePersistentSelection(value.location, allowToggle: true)
                        }
                )
        }
    }

    private var dateRangeLabel: String {
        guard let first = points.first?.date, let last = points.last?.date else { return "No data" }
        return "\(first.formatted(date: .abbreviated, time: .omitted)) – \(last.formatted(date: .abbreviated, time: .omitted))"
    }

    private var visibleDateRangeLabel: String {
        "\(visibleStartDate.formatted(date: .abbreviated, time: .omitted)) – \(visibleEndDate.formatted(date: .abbreviated, time: .omitted))"
    }

    private var xAxisTickIndices: [Int] {
        guard points.count > 1 else { return [0] }
        let desiredCount = min(5, points.count)
        return (0..<desiredCount).map { step in
            Int((CGFloat(step) / CGFloat(max(desiredCount - 1, 1)) * CGFloat(points.count - 1)).rounded())
        }.reduce(into: [Int]()) { result, index in
            if !result.contains(index) {
                result.append(index)
            }
        }
    }

    private func xPosition(forIndex index: Int) -> CGFloat {
        guard points.count > 1 else { return 0 }
        return CGFloat(index) / CGFloat(points.count - 1) * chartContentWidth
    }

    private func xPosition(for date: Date) -> CGFloat {
        guard points.count > 1 else { return 0 }
        let index = points.firstIndex {
            Calendar.current.isDate($0.date, inSameDayAs: date)
        } ?? 0
        return xPosition(forIndex: index)
    }

    private func date(atX xPosition: CGFloat) -> Date {
        guard points.count > 1 else { return points.first?.date ?? Date() }
        let fraction = min(max(xPosition / chartContentWidth, 0), 1)
        let index = Int((fraction * CGFloat(points.count - 1)).rounded())
        return points[min(max(index, points.startIndex), points.index(before: points.endIndex))].date
    }

    private func niceTickSize(for span: Double) -> Double {
        let roughStep = max(span / 4, 1)
        let exponent = floor(log10(roughStep))
        let magnitude = pow(10, exponent)
        let normalized = roughStep / magnitude
        let niceNormalized: Double
        if normalized <= 1 {
            niceNormalized = 1
        } else if normalized <= 2 {
            niceNormalized = 2
        } else if normalized <= 5 {
            niceNormalized = 5
        } else {
            niceNormalized = 10
        }
        return niceNormalized * magnitude
    }

    private func updatePersistentSelection(_ location: CGPoint, allowToggle: Bool = false) {
        guard points.count > 1, location.x >= 0, location.x <= chartContentWidth else { return }
        let pointIndex = location.x / chartContentWidth * CGFloat(points.count - 1)
        let nearestIndex = min(max(Int(pointIndex.rounded()), points.startIndex), points.index(before: points.endIndex))
        let nearestDate = points[nearestIndex].date
        if allowToggle, selectedDate == nearestDate {
            selectedDate = nil
        } else {
            selectedDate = nearestDate
        }
    }

    private func nearestPointDate(to date: Date) -> Date {
        points.min { lhs, rhs in
            abs(lhs.date.timeIntervalSince(date)) < abs(rhs.date.timeIntervalSince(date))
        }?.date ?? date
    }
}

private struct SelectedCashflowDayCard: View {
    let trend: CashflowTrend
    @State private var showingDetail = false

    private var point: CashTrendPoint? { trend.selectedPoint }
    private var categorySummaries: [CashflowCategorySummary] {
        CashflowCategorySummary.group(transactions: point?.transactions ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Selected Day")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(point?.date.formatted(date: .abbreviated, time: trend.period == .day ? .shortened : .omitted) ?? "No day selected")
                        .font(.headline)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(AppDesign.money(point?.netFlowCents ?? 0))
                        .font(.headline.weight(.semibold))
                        .foregroundStyle((point?.netFlowCents ?? 0) >= 0 ? AppDesign.positive : AppDesign.warning)
                        .monospacedDigit()
                    Text("\(point?.transactions.count ?? 0) transaction\(point?.transactions.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let point, !point.transactions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(categorySummaries.prefix(5)) { category in
                        CashflowCategorySummaryRow(category: category)
                        if category.id != categorySummaries.prefix(5).last?.id {
                            Divider()
                        }
                    }
                }
                HStack {
                    Text("Show More Data")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            } else {
                Text("Tap a point on the chart to inspect that day and unlock more detail.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(AppDesign.panel, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onTapGesture {
            if point?.transactions.isEmpty == false {
                showingDetail = true
            }
        }
        .accessibilityAddTraits(point?.transactions.isEmpty == false ? .isButton : [])
        .sheet(isPresented: $showingDetail) {
            if let point {
                CashflowDataDetailView(point: point, period: trend.period)
            }
        }
    }
}

private struct FixedCashYAxis: View {
    let domain: ClosedRange<Double>

    private var values: [Double] {
        let lower = domain.lowerBound
        let upper = domain.upperBound
        guard upper > lower else { return [upper] }
        return stride(from: 0, through: 4, by: 1).map { step in
            upper - ((upper - lower) * Double(step) / 4)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.secondary.opacity(0.18))
                    .frame(width: 1)
                    .frame(maxHeight: geometry.size.height - 34, alignment: .top)

                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    Text(compactMoney(value))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .position(
                            x: geometry.size.width / 2 + 2,
                            y: yPosition(index: index, height: geometry.size.height)
                        )
                }
            }
        }
    }

    private func yPosition(index: Int, height: CGFloat) -> CGFloat {
        let chartTopPadding: CGFloat = 10
        let chartBottomPadding: CGFloat = 34
        let drawableHeight = max(1, height - chartTopPadding - chartBottomPadding)
        return chartTopPadding + drawableHeight * CGFloat(index) / 4
    }

    private func compactMoney(_ dollars: Double) -> String {
        let rounded = dollars.rounded()
        let sign = rounded < 0 ? "-" : ""
        let absolute = abs(rounded)
        if absolute >= 1_000 {
            let value = absolute / 1_000
            return "\(sign)$\(value.formatted(.number.precision(.fractionLength(value >= 10 ? 0 : 1))))k"
        }
        return "\(sign)$\(Int(absolute))"
    }
}

private struct CashChartOffsetPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct CashflowTransactionCauseRow: View {
    let transaction: Transaction
    var overrideAmountCents: Int64?

    private var amountCents: Int64 {
        overrideAmountCents ?? transaction.amountCents
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: amountCents >= 0 ? "arrow.down.left.circle.fill" : "arrow.up.right.circle.fill")
                .font(.title3)
                .foregroundStyle(amountCents >= 0 ? AppDesign.positive : AppDesign.warning)
            VStack(alignment: .leading, spacing: 3) {
                Text(transaction.merchantName ?? transaction.description)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(transaction.postedAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(AppDesign.money(amountCents))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(amountCents >= 0 ? AppDesign.positive : AppDesign.warning)
                .monospacedDigit()
        }
        .padding(.vertical, 10)
    }
}

private struct CashflowCategorySummary: Identifiable {
    struct Entry: Identifiable {
        let id: String
        let transaction: Transaction
        let amountCents: Int64
    }

    let id: String
    let name: String
    let amountCents: Int64
    let entries: [Entry]

    var transactionCount: Int { entries.count }

    static func group(transactions: [Transaction]) -> [CashflowCategorySummary] {
        var grouped: [String: (name: String, amount: Int64, entries: [Entry])] = [:]
        for transaction in transactions {
            let splits = transaction.categorySplits?.isEmpty == false ? transaction.categorySplits! : [
                CategorySplit(categoryID: "uncategorized", name: "Uncategorized", amountCents: transaction.amountCents)
            ]
            for split in splits {
                let key = split.name.isEmpty ? "Uncategorized" : split.name
                var bucket = grouped[key] ?? (name: key, amount: 0, entries: [])
                bucket.amount += split.amountCents
                bucket.entries.append(Entry(id: "\(transaction.id)-\(key)-\(bucket.entries.count)", transaction: transaction, amountCents: split.amountCents))
                grouped[key] = bucket
            }
        }
        return grouped.values
            .map { CashflowCategorySummary(id: $0.name, name: $0.name, amountCents: $0.amount, entries: $0.entries.sorted { $0.transaction.postedAt > $1.transaction.postedAt }) }
            .sorted { abs($0.amountCents) > abs($1.amountCents) }
    }
}

private struct CashflowCategorySummaryRow: View {
    let category: CashflowCategorySummary

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(category.amountCents >= 0 ? AppDesign.positive : AppDesign.warning)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text(category.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text("\(category.transactionCount) transaction\(category.transactionCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(AppDesign.money(category.amountCents))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(category.amountCents >= 0 ? AppDesign.positive : AppDesign.warning)
                .monospacedDigit()
        }
        .padding(.vertical, 10)
    }
}

private struct CashflowDataDetailView: View {
    let point: CashTrendPoint
    let period: CashflowPeriod
    @Environment(\.dismiss) private var dismiss

    private var categories: [CashflowCategorySummary] {
        CashflowCategorySummary.group(transactions: point.transactions)
    }

    private var dateLabel: String {
        point.date.formatted(date: .abbreviated, time: period == .day ? .shortened : .omitted)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Cashflow")
                            .font(.title.bold())
                        Text(dateLabel)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 12) {
                        CashflowAmountTile(title: "Money In", value: point.inflowCents, color: AppDesign.positive)
                        CashflowAmountTile(title: "Money Out", value: point.outflowCents, color: AppDesign.warning)
                    }
                    HStack(spacing: 12) {
                        CashflowAmountTile(title: "Net Change", value: point.netFlowCents, color: point.netFlowCents >= 0 ? AppDesign.positive : AppDesign.warning)
                        CashflowAmountTile(title: "Balance", value: point.balanceCents, color: point.balanceCents >= 0 ? AppDesign.positive : AppDesign.warning)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Categories")
                            .font(.title2.bold())
                        if categories.isEmpty {
                            Text("No categorized transactions in this interval.")
                                .foregroundStyle(.secondary)
                                .padding(16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(AppDesign.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        } else {
                            VStack(spacing: 10) {
                                ForEach(categories) { category in
                                    CashflowCategoryDisclosure(category: category)
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .background(AppDesign.background)
            .navigationTitle("Show More Data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct CashflowAmountTile: View {
    let title: String
    let value: Int64
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(AppDesign.money(value))
                .font(.title2.weight(.semibold))
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppDesign.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct CashflowCategoryDisclosure: View {
    let category: CashflowCategorySummary
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(spacing: 0) {
                ForEach(category.entries) { entry in
                    CashflowTransactionCauseRow(transaction: entry.transaction, overrideAmountCents: entry.amountCents)
                    if entry.id != category.entries.last?.id {
                        Divider()
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            CashflowCategorySummaryRow(category: category)
        }
        .tint(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(AppDesign.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct TrendPill: View {
    let trend: CashflowTrend

    var body: some View {
        HStack {
            Text("Trend")
                .foregroundStyle(.secondary)
            Spacer()
            Text(trend.points.count < 2 ? "Unavailable" : AppDesign.money(trend.netCents))
                .fontWeight(.semibold)
                .foregroundStyle(trend.netCents >= 0 ? AppDesign.positive : AppDesign.warning)
                .monospacedDigit()
        }
        .font(.title3)
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background(
            Capsule()
                .stroke(.secondary.opacity(0.25), lineWidth: 1.5)
                .background(.thinMaterial, in: Capsule())
        )
    }
}

private struct CashflowTrendCard: View {
    let trend: CashflowTrend
    let period: CashflowPeriod

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Image(systemName: "dollarsign.circle.fill")
                    .foregroundStyle(.blue)
                Text("Cashflow")
                    .foregroundStyle(.blue)
                    .font(.headline)
            }
            Text(trend.points.count < 2 ? "Add more cash transactions to calculate a trend." : trend.summary)
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                TrendMetric(title: "In", value: AppDesign.money(trend.inflowCents), color: AppDesign.positive)
                TrendMetric(title: "Out", value: AppDesign.money(trend.outflowCents), color: AppDesign.warning)
                TrendMetric(title: "Balance", value: AppDesign.money(trend.endCents), color: trend.endCents >= 0 ? AppDesign.positive : AppDesign.warning)
            }
        }
        .padding(20)
        .background(AppDesign.panel, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

private struct UpcomingProjectionSection: View {
    @Bindable var store: FinanceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Upcoming")
                    .font(.title2.bold())
                Spacer()
                Text(AppDesign.money(store.projection.last?.balanceCents ?? store.netWorthCents))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            VStack(spacing: 0) {
                ForEach(store.projection) { event in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(event.label).font(.body.weight(.medium))
                            Text(event.date.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(AppDesign.money(event.amountCents)).monospacedDigit()
                            Text(AppDesign.money(event.balanceCents))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .padding(.vertical, 12)
                    if event.id != store.projection.last?.id {
                        Divider()
                    }
                }
            }
            .padding(.horizontal, 16)
            .background(AppDesign.panel, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }
}

private struct TrendMetric: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
