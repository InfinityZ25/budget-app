import SwiftUI

struct BudgetsView: View {
    @Bindable var store: FinanceStore
    @State private var showingCreateBudget = false
    @State private var showingBudgetAssistant = false
    @State private var showingIncomeReview = false
    @State private var showingRecurringReview = false
    @State private var selectedMonth = Date()

    private var selectedMonthInterval: DateInterval {
        Calendar.current.dateInterval(of: .month, for: selectedMonth) ?? DateInterval(start: selectedMonth, duration: 30 * 86_400)
    }

    private var budgetTransactions: [Transaction] {
        store.cashflowTrendTransactions.isEmpty ? store.transactions : store.cashflowTrendTransactions
    }

    private var selectedMonthTransactions: [Transaction] {
        budgetTransactions.filter { selectedMonthInterval.contains($0.postedAt) }
    }

    private var incomeOverrides: BudgetIncomeOverrides {
        BudgetIncomeOverrides(overrides: store.budgetIncomeOverrides)
    }

    private var incomeInsight: IncomeInsight {
        IncomeInsight(transactions: selectedMonthTransactions, month: selectedMonth, overrides: incomeOverrides)
    }

    private var monthlyLimit: Int64 {
        store.budgets.reduce(0) { $0 + normalizedMonthlyLimit($1) }
    }

    private var monthlySpent: Int64 {
        store.budgets.reduce(0) { $0 + spent(for: $1, in: selectedMonthTransactions) }
    }

    private var remaining: Int64 {
        monthlyLimit - monthlySpent
    }

    private var progress: Double {
        Double(monthlySpent) / Double(max(1, monthlyLimit))
    }

    private var budgetPaces: [BudgetPace] {
        store.budgets.map { BudgetPace(budget: $0, spentOverride: spent(for: $0, in: selectedMonthTransactions), now: min(Date(), selectedMonthInterval.end.addingTimeInterval(-1))) }
            .sorted { lhs, rhs in
                if lhs.severity != rhs.severity {
                    return lhs.severity > rhs.severity
                }
                return lhs.progress > rhs.progress
            }
    }

    private var suggestedRecurring: [RecurringTransaction] {
        store.recurringTransactions.filter { $0.status == "suggested" }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.budgets.isEmpty {
                    ScrollView {
                        VStack(spacing: 16) {
                            BudgetPeriodSelector(month: $selectedMonth)
                                .padding(.horizontal)
                            BudgetOverviewCard(
                                incomeInsight: incomeInsight,
                                limit: monthlyLimit,
                                spent: monthlySpent,
                                remaining: remaining,
                                progress: progress,
                                paces: budgetPaces
                            )
                                .padding(.horizontal)
                                .onTapGesture {
                                    showingIncomeReview = true
                                }
                            RecurringInsightsCard(
                                recurringTransactions: store.recurringTransactions,
                                suggestedCount: suggestedRecurring.count,
                                detect: { Task { await store.detectRecurringTransactions() } },
                                review: { showingRecurringReview = true }
                            )
                                .padding(.horizontal)
                            ContentUnavailableView {
                                Label("No Budgets", systemImage: "chart.pie")
                            } description: {
                                Text("Create your own budget or generate budgets from categorized transaction history.")
                            } actions: {
                                VStack(spacing: 10) {
                                    Button {
                                        showingBudgetAssistant = true
                                    } label: {
                                        Label("Plan with AI", systemImage: "sparkles")
                                    }
                                    .buttonStyle(.borderedProminent)
                                    Button("Auto-Generate Budgets") {
                                        Task { await store.generateBudgets() }
                                    }
                                    .buttonStyle(.bordered)
                                    Button("Create Budget") { showingCreateBudget = true }
                                        .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                } else {
                    List {
                        Section {
                            BudgetPeriodSelector(month: $selectedMonth)
                                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 0, trailing: 16))
                                .listRowBackground(Color.clear)
                        }
                        Section {
                            BudgetOverviewCard(
                                incomeInsight: incomeInsight,
                                limit: monthlyLimit,
                                spent: monthlySpent,
                                remaining: remaining,
                                progress: progress,
                                paces: budgetPaces
                            )
                                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 8, trailing: 16))
                                .listRowBackground(Color.clear)
                                .onTapGesture {
                                    showingIncomeReview = true
                                }
                        }
                        Section {
                            RecurringInsightsCard(
                                recurringTransactions: store.recurringTransactions,
                                suggestedCount: suggestedRecurring.count,
                                detect: { Task { await store.detectRecurringTransactions() } },
                                review: { showingRecurringReview = true }
                            )
                                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                                .listRowBackground(Color.clear)
                        }
                        Section("Categories") {
                            ForEach(budgetPaces) { pace in
                                NavigationLink {
                                    BudgetDetailView(store: store, budget: pace.budget, month: selectedMonth)
                                } label: {
                                    BudgetRow(pace: pace)
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        Task { await store.deleteBudget(pace.budget) }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        Section {
                            Button {
                                Task { await store.generateBudgets() }
                            } label: {
                                Label("Auto-Generate from Spending", systemImage: "sparkles")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Budgets")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showingBudgetAssistant = true
                    } label: {
                        Label("Budget Assistant", systemImage: "sparkles")
                    }
                    Button {
                        showingCreateBudget = true
                    } label: {
                        Label("Create Budget", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingCreateBudget) {
                BudgetEditorView(store: store, mode: .create)
            }
            .sheet(isPresented: $showingBudgetAssistant) {
                BudgetAssistantView(store: store)
            }
            .sheet(isPresented: $showingIncomeReview) {
                IncomeReviewView(store: store, transactions: selectedMonthTransactions, month: selectedMonth, overrides: incomeOverrides)
            }
            .sheet(isPresented: $showingRecurringReview) {
                RecurringReviewView(store: store)
            }
        }
    }

    private func normalizedMonthlyLimit(_ budget: Budget) -> Int64 {
        budget.period == "weekly" ? budget.limitCents * 4 : budget.limitCents
    }

    private func spent(for budget: Budget, in transactions: [Transaction]) -> Int64 {
        transactions.reduce(Int64(0)) { total, transaction in
            guard transaction.amountCents < 0 else { return total }
            let matches = (transaction.categorySplits ?? []).contains { split in
                split.categoryID == budget.categoryID || split.name.localizedCaseInsensitiveCompare(budget.categoryName) == .orderedSame
            }
            return matches ? total + abs(transaction.amountCents) : total
        }
    }
}

private struct BudgetPeriodSelector: View {
    @Binding var month: Date

    var body: some View {
        HStack(spacing: 12) {
            Button {
                shiftMonth(-1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
            }
            Spacer()
            VStack(spacing: 2) {
                Text(month.formatted(.dateTime.month(.wide).year()))
                    .font(.headline)
                Text("Classify and review this budget month")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                shiftMonth(1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.headline)
            }
            .disabled(Calendar.current.isDate(month, equalTo: Date(), toGranularity: .month))
            .opacity(Calendar.current.isDate(month, equalTo: Date(), toGranularity: .month) ? 0.35 : 1)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(AppDesign.panel.opacity(0.8), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func shiftMonth(_ value: Int) {
        guard let next = Calendar.current.date(byAdding: .month, value: value, to: month) else { return }
        if next <= Date() || value < 0 {
            month = next
        }
    }
}

private struct BudgetIncomeOverrides: Hashable {
    var decisionsByTransactionID: [String: Bool] = [:]

    init(overrides: [BudgetIncomeOverride] = []) {
        decisionsByTransactionID = Dictionary(uniqueKeysWithValues: overrides.map { ($0.transactionID, $0.included) })
    }

    func includes(_ transaction: Transaction) -> Bool {
        if let included = decisionsByTransactionID[transaction.id] {
            return included
        }
        return BudgetIncomeClassifier.looksLikeIncome(transaction)
    }
}

private enum BudgetIncomeClassifier {
    static func looksLikeIncome(_ transaction: Transaction) -> Bool {
        transaction.amountCents > 0 && !isTransfer(transaction)
    }

    static func isTransfer(_ transaction: Transaction) -> Bool {
        let text = [transaction.description, transaction.merchantName ?? "", transaction.categorySplits?.first?.name ?? ""].joined(separator: " ").lowercased()
        return text.contains("transfer") || text.contains("credit card payment") || text.contains("payment from") || text.contains("payment to") || text.contains("online transfer")
    }

    static func incomeKey(_ transaction: Transaction) -> String {
        (transaction.merchantName ?? transaction.description)
            .replacingOccurrences(of: #"\d+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func averageSpacingDays(_ transactions: [Transaction]) -> Int {
        let sorted = transactions.sorted { $0.postedAt < $1.postedAt }
        guard sorted.count > 1 else { return 0 }
        let intervals = zip(sorted.dropFirst(), sorted).map { newer, older in
            newer.postedAt.timeIntervalSince(older.postedAt) / 86_400
        }
        return Int((intervals.reduce(0, +) / Double(intervals.count)).rounded())
    }
}

private struct IncomeReviewView: View {
    @Bindable var store: FinanceStore
    let transactions: [Transaction]
    let month: Date
    let overrides: BudgetIncomeOverrides
    @Environment(\.dismiss) private var dismiss

    private var positiveTransactions: [Transaction] {
        transactions
            .filter { $0.amountCents > 0 }
            .sorted { $0.postedAt > $1.postedAt }
    }

    private var insight: IncomeInsight {
        IncomeInsight(transactions: transactions, month: month, overrides: overrides)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(AppDesign.money(insight.monthlyIncomeCents))
                            .font(.system(size: 42, weight: .bold, design: .rounded))
                            .foregroundStyle(AppDesign.positive)
                            .monospacedDigit()
                        Text(insight.cadenceLabel)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                } header: {
                    Text("Projected Income")
                } footer: {
                    Text("Toggle deposits below to include or exclude them from the income estimate used by budgets.")
                }

                Section("Deposits in \(month.formatted(.dateTime.month(.wide).year()))") {
                    if positiveTransactions.isEmpty {
                        Text("No deposits found for this month.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(positiveTransactions) { transaction in
                            Button {
                                Task { await toggle(transaction) }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: overrides.includes(transaction) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(overrides.includes(transaction) ? AppDesign.positive : .secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(transaction.merchantName ?? transaction.description)
                                            .lineLimit(2)
                                        Text(transaction.postedAt.formatted(date: .abbreviated, time: .omitted))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(AppDesign.money(transaction.amountCents))
                                        .fontWeight(.semibold)
                                        .foregroundStyle(AppDesign.positive)
                                        .monospacedDigit()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Income Detection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func toggle(_ transaction: Transaction) async {
        await store.setBudgetIncomeOverride(transactionID: transaction.id, included: !overrides.includes(transaction))
    }
}

private struct BudgetOverviewCard: View {
    let incomeInsight: IncomeInsight
    let limit: Int64
    let spent: Int64
    let remaining: Int64
    let progress: Double
    let paces: [BudgetPace]

    private var unbudgeted: Int64 {
        incomeInsight.monthlyIncomeCents - limit
    }

    private var urgent: [BudgetPace] {
        paces.filter { $0.status != .onTrack }
    }

    private var pacingTitle: String {
        urgent.isEmpty ? "On pace" : "\(urgent.count) need attention"
    }

    private var pacingSubtitle: String {
        urgent.first.map { "\($0.budget.categoryName) is \($0.status.description.lowercased())" } ?? "Spending is tracking normally"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Available this month")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(AppDesign.money(remaining))
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(remaining >= 0 ? .primary : AppDesign.warning)
                        .monospacedDigit()
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: remaining >= 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(remaining >= 0 ? AppDesign.positive : AppDesign.warning)
            }
            ProgressView(value: min(1, max(0, progress)), total: 1)
                .tint(progress > 1 ? AppDesign.warning : .accentColor)

            HStack(spacing: 10) {
                BudgetOverviewMetric(title: "Income", value: incomeInsight.monthlyIncomeCents > 0 ? AppDesign.money(incomeInsight.monthlyIncomeCents) : "Unknown", subtitle: incomeInsight.cadenceLabel, tint: AppDesign.positive)
                BudgetOverviewMetric(title: "Spent", value: AppDesign.money(spent), subtitle: "of \(AppDesign.money(limit))", tint: .accentColor)
            }

            HStack(spacing: 10) {
                BudgetOverviewMetric(title: "Unbudgeted", value: incomeInsight.monthlyIncomeCents > 0 ? AppDesign.money(unbudgeted) : "Add income", subtitle: "after limits", tint: unbudgeted >= 0 ? AppDesign.positive : AppDesign.warning)
                BudgetOverviewMetric(title: "Pacing", value: pacingTitle, subtitle: pacingSubtitle, tint: urgent.isEmpty ? AppDesign.positive : AppDesign.warning)
            }
        }
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private struct BudgetOverviewMetric: View {
    let title: String
    let value: String
    let subtitle: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppDesign.panel.opacity(0.75), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct RecurringInsightsCard: View {
    let recurringTransactions: [RecurringTransaction]
    let suggestedCount: Int
    let detect: () -> Void
    let review: () -> Void

    private var confirmedIncome: [RecurringTransaction] {
        recurringTransactions.filter { $0.kind == "income" && $0.status != "ignored" }
    }

    private var confirmedExpenses: [RecurringTransaction] {
        recurringTransactions.filter { $0.kind == "expense" && $0.status != "ignored" }
    }

    private var projectedIncome: Int64 {
        confirmedIncome.reduce(Int64(0)) { $0 + monthlyAmount($1) }
    }

    private var projectedBills: Int64 {
        confirmedExpenses.reduce(Int64(0)) { $0 + monthlyAmount($1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Recurring money", systemImage: "repeat.circle.fill")
                    .font(.headline)
                Spacer()
                if suggestedCount > 0 {
                    Text("\(suggestedCount) to review")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppDesign.warning)
                }
            }
            HStack(spacing: 10) {
                BudgetOverviewMetric(title: "Income", value: projectedIncome > 0 ? AppDesign.money(projectedIncome) : "Detect", subtitle: "monthly estimate", tint: AppDesign.positive)
                BudgetOverviewMetric(title: "Bills", value: projectedBills > 0 ? AppDesign.money(projectedBills) : "Unknown", subtitle: "fixed expenses", tint: AppDesign.warning)
            }
            if let next = recurringTransactions
                .filter({ $0.status != "ignored" && $0.nextExpectedAt != nil })
                .min(by: { ($0.nextExpectedAt ?? .distantFuture) < ($1.nextExpectedAt ?? .distantFuture) }) {
                HStack(spacing: 10) {
                    Image(systemName: next.isIncome ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                        .foregroundStyle(next.isIncome ? AppDesign.positive : AppDesign.warning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(next.merchantName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text("Next \(next.cadenceLabel.lowercased()) · \(next.nextExpectedAt?.formatted(date: .abbreviated, time: .omitted) ?? "unknown")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(AppDesign.money(next.displayAmountCents))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
            }
            HStack {
                Button {
                    detect()
                } label: {
                    Label("Detect", systemImage: "wand.and.stars")
                }
                .buttonStyle(.bordered)
                Button {
                    review()
                } label: {
                    Label("Review", systemImage: "checklist")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func monthlyAmount(_ recurring: RecurringTransaction) -> Int64 {
        let amount = recurring.displayAmountCents
        switch recurring.cadence {
        case "weekly": return amount * 52 / 12
        case "biweekly": return amount * 26 / 12
        case "semimonthly": return amount * 2
        case "monthly": return amount
        default: return recurring.averageIntervalDays > 0 ? Int64((Double(amount) * 30.4375 / Double(recurring.averageIntervalDays)).rounded()) : amount
        }
    }
}

private struct RecurringReviewView: View {
    @Bindable var store: FinanceStore
    @Environment(\.dismiss) private var dismiss

    private var grouped: [(String, [RecurringTransaction])] {
        [
            ("Income", store.recurringTransactions.filter { $0.kind == "income" && $0.status != "ignored" }),
            ("Bills and subscriptions", store.recurringTransactions.filter { $0.kind == "expense" && $0.status != "ignored" }),
            ("Ignored", store.recurringTransactions.filter { $0.status == "ignored" })
        ].filter { !$0.1.isEmpty }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Detected recurring items come from Plaid transaction history. Confirm them to use them for budget planning and cashflow projections, or ignore false positives.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button {
                        Task { await store.detectRecurringTransactions() }
                    } label: {
                        Label("Run detection again", systemImage: "wand.and.stars")
                    }
                }
                if store.recurringTransactions.isEmpty {
                    ContentUnavailableView("No recurring items yet", systemImage: "repeat", description: Text("Run detection after syncing at least a few months of Plaid transactions."))
                }
                ForEach(grouped, id: \.0) { title, rows in
                    Section(title) {
                        ForEach(rows) { recurring in
                            RecurringReviewRow(recurring: recurring) {
                                Task { await store.updateRecurringTransactionStatus(recurring, status: "confirmed") }
                            } ignore: {
                                Task { await store.updateRecurringTransactionStatus(recurring, status: "ignored") }
                            } restore: {
                                Task { await store.updateRecurringTransactionStatus(recurring, status: "suggested") }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Recurring")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct RecurringReviewRow: View {
    let recurring: RecurringTransaction
    let confirm: () -> Void
    let ignore: () -> Void
    let restore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: recurring.isIncome ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                    .font(.title3)
                    .foregroundStyle(recurring.isIncome ? AppDesign.positive : AppDesign.warning)
                VStack(alignment: .leading, spacing: 3) {
                    Text(recurring.merchantName)
                        .font(.headline)
                    Text([recurring.categoryName, recurring.cadenceLabel, recurring.confidenceLabel].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(AppDesign.money(recurring.displayAmountCents))
                        .font(.headline)
                        .monospacedDigit()
                    Text("\(recurring.transactionCount)x")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                if let nextExpectedAt = recurring.nextExpectedAt {
                    Label(nextExpectedAt.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if recurring.status == "ignored" {
                    Button("Restore", action: restore)
                        .buttonStyle(.bordered)
                } else {
                    Button(recurring.status == "confirmed" ? "Confirmed" : "Confirm", action: confirm)
                        .buttonStyle(.borderedProminent)
                        .disabled(recurring.status == "confirmed")
                    Button("Ignore", role: .destructive, action: ignore)
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

private struct BudgetAssistantView: View {
    @Bindable var store: FinanceStore
    @Environment(\.dismiss) private var dismiss
    @State private var messages: [BudgetAssistantMessage] = [
        BudgetAssistantMessage(role: .assistant, content: "Tell me how you want your budget structured. I can create or update budget categories, remove old ones, classify obvious transactions, and ask follow-ups for anything uncertain.")
    ]
    @State private var draft = ""
    @State private var isSending = false
    @State private var isApplying = false
    @State private var isLoadingPendingProposal = false
    @State private var showingHistory = false
    @State private var thinkingStatus: String?
    @State private var lastReply: BudgetAssistantReply?

    private let examples = [
        "Set up rent $2200, car payment $480, insurance $210, groceries $650, restaurants $250, health $150.",
        "Clean up my categories and classify obvious transactions.",
        "Delete the categories I do not use and ask me about anything uncertain."
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            BudgetAssistantCapabilityCard()
                            if messages.count == 1 {
                                BudgetAssistantExamples(examples: examples) { example in
                                    draft = example
                                }
                            }
                            ForEach(messages) { message in
                                BudgetAssistantBubble(message: message)
                                    .id(message.id)
                            }
                            if let lastReply {
                                BudgetAssistantActionSummary(reply: lastReply)
                                if let plan = lastReply.plan {
                                    if lastReply.normalizedMode == "pending" || lastReply.normalizedMode == "proposal" {
                                        BudgetAssistantReviewCard(reply: lastReply, plan: plan, budgets: store.budgets, transactions: store.transactions + store.cashflowTrendTransactions, isApplying: isApplying) {
                                            Task { await apply(plan, proposalID: lastReply.proposalID) }
                                        } dismiss: {
                                            Task { await dismissProposal(lastReply.proposalID) }
                                        }
                                    } else {
                                        BudgetAssistantPlanSnapshotCard(reply: lastReply, plan: plan, budgets: store.budgets, transactions: store.transactions + store.cashflowTrendTransactions)
                                    }
                                }
                            }
                            if isSending || isLoadingPendingProposal {
                                Label(thinkingStatus ?? "Thinking…", systemImage: "sparkles")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id("budget-assistant-loading")
                            }
                            Color.clear.frame(height: 1).id("budget-assistant-bottom")
                        }
                        .padding()
                    }
                    .onChange(of: messages.count) { _, _ in scrollToBottom(proxy) }
                    .onChange(of: isSending) { _, _ in scrollToBottom(proxy) }
                }
                BudgetAssistantComposer(text: $draft, isSending: isSending) {
                    Task { await send() }
                }
            }
            .task {
                await loadPendingProposal()
            }
            .navigationTitle("Budget AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingHistory = true
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        messages = [BudgetAssistantMessage(role: .assistant, content: "Started a fresh budget planning session. Tell me the categories, limits, or cleanup you want.")]
                        lastReply = nil
                        thinkingStatus = nil
                        isApplying = false
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
            .sheet(isPresented: $showingHistory) {
                BudgetAssistantHistoryView(store: store) { proposal in
                    lastReply = proposal
                    messages.append(BudgetAssistantMessage(role: .assistant, content: "Opened a saved \(proposal.mode ?? "proposal") plan for review."))
                    showingHistory = false
                }
            }
        }
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending, !isApplying else { return }
        draft = ""
        lastReply = nil
        thinkingStatus = "Thinking…"
        messages.append(BudgetAssistantMessage(role: .user, content: text))
        messages.append(BudgetAssistantMessage(role: .assistant, content: ""))
        let assistantID = messages[messages.count - 1].id
        isSending = true
        do {
            for try await event in store.streamBudgetAssistant(text) {
                switch event {
                case let .status(message):
                    thinkingStatus = message
                case let .token(delta):
                    if let index = messages.firstIndex(where: { $0.id == assistantID }) {
                        messages[index].content += delta
                    }
                case let .notice(message):
                    thinkingStatus = message
                case let .done(reply):
                    lastReply = reply
                    if let index = messages.firstIndex(where: { $0.id == assistantID }), messages[index].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        messages[index].content = responseText(from: reply)
                    }
                    thinkingStatus = "Ready for review"
                }
            }
        } catch {
            if let index = messages.firstIndex(where: { $0.id == assistantID }) {
                messages[index].content = "I could not update budgets because the request failed: \(error.localizedDescription)"
            } else {
                messages.append(BudgetAssistantMessage(role: .assistant, content: "I could not update budgets because the request failed: \(error.localizedDescription)"))
            }
        }
        thinkingStatus = nil
        isSending = false
    }

    private func loadPendingProposal() async {
        guard lastReply == nil, !isLoadingPendingProposal else { return }
        isLoadingPendingProposal = true
        thinkingStatus = "Checking for saved proposals…"
        defer {
            isLoadingPendingProposal = false
            thinkingStatus = nil
        }
        do {
            guard let proposal = try await store.pendingBudgetAssistantProposal() else { return }
            lastReply = proposal
            messages.append(BudgetAssistantMessage(role: .assistant, content: "I restored a budget plan that is waiting for your review."))
        } catch {
            messages.append(BudgetAssistantMessage(role: .assistant, content: "I could not load saved budget proposals: \(error.localizedDescription)"))
        }
    }

    private func apply(_ plan: BudgetAssistantPlan, proposalID: String?) async {
        guard !isApplying, !isSending else { return }
        isApplying = true
        thinkingStatus = "Applying approved changes…"
        do {
            let reply = try await store.applyBudgetAssistantPlan(plan, proposalID: proposalID)
            lastReply = reply
            messages.append(BudgetAssistantMessage(role: .assistant, content: responseText(from: reply)))
            thinkingStatus = "Applied"
        } catch {
            messages.append(BudgetAssistantMessage(role: .assistant, content: "I could not apply the approved changes: \(error.localizedDescription)"))
        }
        thinkingStatus = nil
        isApplying = false
    }

    private func dismissProposal(_ proposalID: String?) async {
        guard let proposalID else {
            lastReply = nil
            return
        }
        do {
            try await store.dismissBudgetAssistantProposal(id: proposalID)
            lastReply = nil
            messages.append(BudgetAssistantMessage(role: .assistant, content: "Dismissed that proposal. Tell me what you want to plan next."))
        } catch {
            messages.append(BudgetAssistantMessage(role: .assistant, content: "I could not dismiss that proposal: \(error.localizedDescription)"))
        }
    }

    private func responseText(from reply: BudgetAssistantReply) -> String {
        var parts = [reply.reply]
        if !reply.followUps.isEmpty {
            parts.append("Questions:\n" + reply.followUps.map { "• \($0)" }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.snappy(duration: 0.25)) {
            proxy.scrollTo("budget-assistant-bottom", anchor: .bottom)
        }
    }
}

private struct BudgetAssistantMessage: Identifiable, Hashable {
    enum Role: Hashable {
        case user
        case assistant
    }

    let id = UUID()
    let role: Role
    var content: String
}

private struct BudgetAssistantCapabilityCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.yellow)
                Text("Budget operator")
                    .font(.headline)
            }
            Text("This assistant proposes budget changes and transaction classifications first. Nothing changes until you review and apply the plan.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct BudgetAssistantExamples: View {
    let examples: [String]
    let action: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Try")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(examples, id: \.self) { example in
                Button {
                    action(example)
                } label: {
                    Text(example)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(AppDesign.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct BudgetAssistantBubble: View {
    let message: BudgetAssistantMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 48)
            }
            Group {
                if message.content.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Thinking…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(message.content)
                }
            }
                .font(.body)
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(message.role == .user ? Color.accentColor.opacity(0.85) : AppDesign.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            if message.role == .assistant {
                Spacer(minLength: 48)
            }
        }
    }
}

private struct BudgetAssistantActionSummary: View {
    let reply: BudgetAssistantReply

    var body: some View {
        HStack(spacing: 8) {
            BudgetAssistantStat(label: "Created", value: reply.createdBudgets, tint: AppDesign.positive)
            BudgetAssistantStat(label: "Updated", value: reply.updatedBudgets, tint: .accentColor)
            BudgetAssistantStat(label: "Deleted", value: reply.deletedBudgets, tint: AppDesign.warning)
            BudgetAssistantStat(label: "Classified", value: reply.classified, tint: AppDesign.positive)
        }
    }
}

private struct BudgetAssistantReviewCard: View {
    let reply: BudgetAssistantReply
    let plan: BudgetAssistantPlan
    let budgets: [Budget]
    let transactions: [Transaction]
    let isApplying: Bool
    let apply: () -> Void
    let dismiss: () -> Void
    @State private var showingApplyConfirmation = false

    private var budgetActions: [BudgetAssistantBudgetAction] {
        plan.budgets.filter { !$0.categoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var classifications: [BudgetAssistantClassification] {
        plan.classifications.filter { $0.confidence >= 0.72 }
    }

    private var needsConfirmation: Bool {
        budgetActions.count + classifications.count > 1 || budgetActions.contains { $0.operation.lowercased() == "delete" || $0.operation.lowercased() == "remove" }
    }

    private var changeCount: Int {
        budgetActions.count + classifications.count
    }

    private var includesDeletes: Bool {
        budgetActions.contains { $0.operation.lowercased() == "delete" || $0.operation.lowercased() == "remove" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "checklist")
                    .foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Review before applying")
                        .font(.headline)
                    Text("\(budgetActions.count) budget edits · \(classifications.count) classifications")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if !budgetActions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Budget edits")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(budgetActions.prefix(6)) { action in
                        BudgetAssistantBudgetDiffRow(action: action, existingBudget: existingBudget(for: action))
                    }
                    if budgetActions.count > 6 {
                        Text("+\(budgetActions.count - 6) more budget edit\(budgetActions.count - 6 == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !classifications.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Classifications")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(classifications.prefix(5)) { item in
                        BudgetAssistantClassificationDiffRow(classification: item, transaction: transaction(for: item))
                    }
                    if classifications.count > 5 {
                        Text("+\(classifications.count - 5) more classification\(classifications.count - 5 == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            let reviewOnly = plan.classifications.filter { $0.confidence < 0.72 }
            if !reviewOnly.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Needs confirmation")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(reviewOnly.prefix(3)) { item in
                        HStack(spacing: 10) {
                            Image(systemName: "questionmark.circle")
                                .foregroundStyle(AppDesign.warning)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(transaction(for: item)?.merchantName ?? transaction(for: item)?.description ?? "Transaction")
                                    .lineLimit(1)
                                Text("Suggested \(item.categoryName) · \(Int((item.confidence * 100).rounded()))% confidence")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .font(.subheadline)
                    }
                }
            }

            HStack(spacing: 10) {
                Button("Dismiss", role: .cancel, action: dismiss)
                    .buttonStyle(.bordered)
                    .disabled(isApplying)
                Button {
                    if needsConfirmation {
                        showingApplyConfirmation = true
                    } else {
                        apply()
                    }
                } label: {
                    Label(isApplying ? "Applying…" : "Apply Changes", systemImage: isApplying ? "hourglass" : "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isApplying || (budgetActions.isEmpty && classifications.isEmpty))
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .confirmationDialog("Apply Budget AI plan?", isPresented: $showingApplyConfirmation, titleVisibility: .visible) {
            if includesDeletes {
                Button("Apply \(changeCount) change\(changeCount == 1 ? "" : "s")", role: .destructive) {
                    apply()
                }
            } else {
                Button("Apply \(changeCount) change\(changeCount == 1 ? "" : "s")") {
                    apply()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(includesDeletes ? "This includes budget deletions. High-confidence classifications will also be applied; low-confidence suggestions remain for review." : "This will update budgets and classify high-confidence transactions. Low-confidence suggestions remain for review.")
        }
    }

    private func existingBudget(for action: BudgetAssistantBudgetAction) -> Budget? {
        let normalized = action.categoryName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return budgets.first { $0.categoryName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized }
    }

    private func transaction(for classification: BudgetAssistantClassification) -> Transaction? {
        transactions.first { $0.id == classification.transactionID }
    }
}

private struct BudgetAssistantPlanSnapshotCard: View {
    let reply: BudgetAssistantReply
    let plan: BudgetAssistantPlan
    let budgets: [Budget]
    let transactions: [Transaction]

    private var budgetActions: [BudgetAssistantBudgetAction] {
        plan.budgets.filter { !$0.categoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var classifications: [BudgetAssistantClassification] {
        plan.classifications.filter { $0.confidence >= 0.72 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: reply.normalizedMode == "applied" ? "checkmark.seal.fill" : "archivebox.fill")
                    .foregroundStyle(reply.normalizedMode == "applied" ? AppDesign.positive : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(reply.normalizedMode == "applied" ? "Applied plan details" : "Dismissed plan details")
                        .font(.headline)
                    Text("\(budgetActions.count) budget edits · \(classifications.count) classifications")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if !budgetActions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Budget edits")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(budgetActions.prefix(8)) { action in
                        BudgetAssistantBudgetDiffRow(action: action, existingBudget: existingBudget(for: action))
                    }
                    if budgetActions.count > 8 {
                        Text("+\(budgetActions.count - 8) more budget edit\(budgetActions.count - 8 == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !classifications.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Classifications")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(classifications.prefix(8)) { item in
                        BudgetAssistantClassificationDiffRow(classification: item, transaction: transaction(for: item))
                    }
                    if classifications.count > 8 {
                        Text("+\(classifications.count - 8) more classification\(classifications.count - 8 == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func existingBudget(for action: BudgetAssistantBudgetAction) -> Budget? {
        let normalized = action.categoryName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return budgets.first { $0.categoryName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized }
    }

    private func transaction(for classification: BudgetAssistantClassification) -> Transaction? {
        transactions.first { $0.id == classification.transactionID }
    }
}

private struct BudgetAssistantBudgetDiffRow: View {
    let action: BudgetAssistantBudgetAction
    let existingBudget: Budget?

    private var operation: String {
        action.operation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (existingBudget == nil ? "Create" : "Update") : action.operation.capitalized
    }

    private var tint: Color {
        switch action.operation.lowercased() {
        case "delete", "remove": .red
        case "update": .accentColor
        default: AppDesign.positive
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(operation)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 58, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(action.categoryName)
                    .lineLimit(1)
                if action.operation.lowercased() == "delete" || action.operation.lowercased() == "remove" {
                    Text(existingBudget == nil ? "No existing budget found" : "Remove current \(existingBudget!.period) limit of \(AppDesign.money(existingBudget!.limitCents))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if let existingBudget {
                    Text("\(existingBudget.period.capitalized) \(AppDesign.money(existingBudget.limitCents)) → \(action.period.capitalized) \(AppDesign.money(action.limitCents))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("New \(action.period) limit \(AppDesign.money(action.limitCents))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .font(.subheadline)
    }
}

private struct BudgetAssistantClassificationDiffRow: View {
    let classification: BudgetAssistantClassification
    let transaction: Transaction?

    private var currentCategory: String {
        transaction?.categorySplits?.first?.name ?? "Uncategorized"
    }

    private var subtitle: String {
        guard let transaction else {
            return "Transaction not loaded · \(Int((classification.confidence * 100).rounded()))% confidence"
        }
        return "\(transaction.postedAt.formatted(date: .abbreviated, time: .omitted)) · \(AppDesign.money(transaction.amountCents)) · \(Int((classification.confidence * 100).rounded()))% confidence"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "tag")
                .foregroundStyle(AppDesign.positive)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(transaction?.merchantName ?? transaction?.description ?? "Transaction")
                    .lineLimit(1)
                Text("\(currentCategory) → \(classification.categoryName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !classification.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(classification.reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if classification.applyToSimilar {
                    Label("Also applies to similar transactions", systemImage: "arrow.triangle.branch")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(AppDesign.positive)
                }
            }
            Spacer()
        }
        .font(.subheadline)
    }
}

private struct BudgetAssistantStat: View {
    let label: String
    let value: Int
    let tint: Color

    var body: some View {
        VStack(spacing: 3) {
            Text("\(value)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(tint)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(AppDesign.panel.opacity(0.8), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct BudgetAssistantHistoryView: View {
    @Bindable var store: FinanceStore
    let open: (BudgetAssistantReply) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var proposals: [BudgetAssistantReply] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
                if proposals.isEmpty && !isLoading {
                    ContentUnavailableView {
                        Label("No Proposal History", systemImage: "clock")
                    } description: {
                        Text("Ask Budget AI to plan categories or classify spending, then proposals will appear here.")
                    }
                } else {
                    Section("Recent plans") {
                        ForEach(proposals, id: \.id) { proposal in
                            Button {
                                open(proposal)
                                dismiss()
                            } label: {
                                BudgetAssistantHistoryRow(proposal: proposal)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .overlay {
                if isLoading {
                    ProgressView("Loading proposals…")
                }
            }
            .navigationTitle("Proposal History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
            .task {
                await load()
            }
        }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            proposals = try await store.budgetAssistantProposals()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct BudgetAssistantHistoryRow: View {
    let proposal: BudgetAssistantReply

    private var statusColor: Color {
        switch proposal.normalizedMode {
        case "pending", "proposal": AppDesign.warning
        case "applied": AppDesign.positive
        case "dismissed": .secondary
        default: .accentColor
        }
    }

    private var statusLabel: String {
        switch proposal.normalizedMode {
        case "pending", "proposal": "Pending"
        case "applied": "Applied"
        case "dismissed": "Dismissed"
        default: proposal.normalizedMode.capitalized
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(proposal.reply)
                        .font(.headline)
                        .lineLimit(2)
                    Text(proposal.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(statusLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(statusColor.opacity(0.14), in: Capsule())
            }
            HStack(spacing: 8) {
                BudgetAssistantMiniStat(label: "Budget", value: proposal.createdBudgets + proposal.updatedBudgets + proposal.deletedBudgets)
                BudgetAssistantMiniStat(label: "Classify", value: proposal.classified)
                BudgetAssistantMiniStat(label: "Review", value: proposal.needsReview)
            }
            Label(proposal.normalizedMode == "applied" ? "Open applied plan details" : "Open plan for review", systemImage: proposal.normalizedMode == "applied" ? "checkmark.seal" : "doc.text.magnifyingglass")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}

private struct BudgetAssistantMiniStat: View {
    let label: String
    let value: Int

    var body: some View {
        HStack(spacing: 4) {
            Text("\(value)")
                .font(.caption.weight(.bold).monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(AppDesign.panel, in: Capsule())
    }
}

private struct BudgetAssistantComposer: View {
    @Binding var text: String
    let isSending: Bool
    let send: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask AI to edit budgets", text: $text, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(AppDesign.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Button(action: send) {
                Image(systemName: isSending ? "hourglass" : "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(isSending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding()
        .background(.bar)
    }
}

private struct BudgetRow: View {
    let pace: BudgetPace
    private var budget: Budget { pace.budget }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(budget.categoryName)
                        .font(.body.weight(.medium))
                        .lineLimit(2)
                    Text("\(budget.period.capitalized) · \(pace.status.description)")
                        .font(.caption)
                        .foregroundStyle(pace.status.color)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(AppDesign.money(pace.remaining))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(pace.remaining >= 0 ? .primary : AppDesign.warning)
                    Text("left")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: min(1, max(0, pace.progress)), total: 1)
                .tint(pace.status.color)
            HStack {
                Text("\(AppDesign.money(pace.spent)) spent")
                Spacer()
                Text("\(Int(pace.progress * 100))% of \(AppDesign.money(budget.limitCents))")
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct BudgetDetailView: View {
    @Bindable var store: FinanceStore
    let budget: Budget
    let month: Date
    @State private var showingEdit = false
    @State private var isAssigning = false
    @State private var showingTransactionPicker = false
    @Environment(\.dismiss) private var dismiss

    private var monthInterval: DateInterval {
        Calendar.current.dateInterval(of: .month, for: month) ?? DateInterval(start: month, duration: 30 * 86_400)
    }

    private var allMonthTransactions: [Transaction] {
        (store.cashflowTrendTransactions.isEmpty ? store.transactions : store.cashflowTrendTransactions)
            .filter { monthInterval.contains($0.postedAt) }
            .sorted { $0.postedAt > $1.postedAt }
    }

    private var spent: Int64 {
        categoryTransactions.reduce(Int64(0)) { $0 + abs(min(0, $1.amountCents)) }
    }

    private var remaining: Int64 { budget.limitCents - spent }
    private var progress: Double { Double(spent) / Double(max(1, budget.limitCents)) }
    private var pace: BudgetPace { BudgetPace(budget: budget, spentOverride: spent, now: min(Date(), monthInterval.end.addingTimeInterval(-1))) }
    private var categoryTransactions: [Transaction] {
        allMonthTransactions.filter { transaction in
            (transaction.categorySplits ?? []).contains { $0.categoryID == budget.categoryID || $0.name.localizedCaseInsensitiveCompare(budget.categoryName) == .orderedSame }
        }
    }
    private var unassignedExpenseCount: Int {
        allMonthTransactions.filter { transaction in
            transaction.amountCents < 0 && !(transaction.categorySplits ?? []).contains { $0.categoryID == budget.categoryID || $0.name.localizedCaseInsensitiveCompare(budget.categoryName) == .orderedSame }
        }.count
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    Text(budget.categoryName)
                        .font(.title2.weight(.semibold))
                    Text(AppDesign.money(remaining))
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .foregroundStyle(remaining >= 0 ? .primary : AppDesign.warning)
                        .monospacedDigit()
                    Text("\(remaining >= 0 ? "remaining" : "over budget") · \(month.formatted(.dateTime.month(.wide).year()))")
                        .foregroundStyle(.secondary)
                    ProgressView(value: min(1, max(0, progress)), total: 1)
                        .tint(progress > 1 ? AppDesign.warning : .accentColor)
                }
                .padding(.vertical, 8)
            }
            Section("Plan") {
                BudgetDetailRow(label: "Limit", value: AppDesign.money(budget.limitCents))
                BudgetDetailRow(label: "Spent", value: AppDesign.money(spent))
                BudgetDetailRow(label: "Remaining", value: AppDesign.money(remaining))
                BudgetDetailRow(label: "Period", value: budget.period.capitalized)
                BudgetDetailRow(label: "Pace", value: pace.status.description)
                BudgetDetailRow(label: "Safe daily spend", value: AppDesign.money(pace.safeDailySpendCents))
                BudgetDetailRow(label: "Category ID", value: budget.categoryID)
            }
            Section {
                Button {
                    isAssigning = true
                    showingTransactionPicker = true
                } label: {
                    HStack {
                        Label("Add or reclassify transactions", systemImage: "plus.circle.fill")
                        Spacer()
                        Text("\(unassignedExpenseCount) available")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if isAssigning {
                    Text("Swipe an assigned transaction to remove it from this budget, or tap plus to add more from this month.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Classification")
            }
            Section {
                if categoryTransactions.isEmpty {
                    Text("No transactions have hit this category in \(month.formatted(.dateTime.month(.wide))).")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(categoryTransactions.prefix(60)) { transaction in
                        BudgetTransactionRow(transaction: transaction)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if isAssigning {
                                    Button(role: .destructive) {
                                        Task { await store.updateTransactionCategory(transaction, categoryName: "Uncategorized", applyToSimilar: false) }
                                    } label: {
                                        Label("Remove", systemImage: "xmark.circle")
                                    }
                                }
                            }
                    }
                }
            } header: {
                HStack {
                    Text("\(month.formatted(.dateTime.month(.wide))) Transactions")
                    Spacer()
                    Text("\(categoryTransactions.count)")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Button {
                    showingEdit = true
                } label: {
                    Label("Edit Budget", systemImage: "slider.horizontal.3")
                }
                Button(role: .destructive) {
                    Task {
                        await store.deleteBudget(budget)
                        dismiss()
                    }
                } label: {
                    Label("Delete Budget", systemImage: "trash")
                }
            }
        }
        .navigationTitle("Budget")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    isAssigning.toggle()
                } label: {
                    Image(systemName: isAssigning ? "checkmark.circle.fill" : "pencil.circle")
                }
                if isAssigning {
                    Button {
                        showingTransactionPicker = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showingEdit) {
            BudgetEditorView(store: store, mode: .edit(budget))
        }
        .sheet(isPresented: $showingTransactionPicker) {
            BudgetTransactionPickerView(store: store, budget: budget, month: month, transactions: allMonthTransactions)
        }
    }
}

private struct BudgetTransactionRow: View {
    let transaction: Transaction

    private var categoryLabel: String {
        transaction.categorySplits?.first?.name ?? "Uncategorized"
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(transaction.merchantName ?? transaction.description)
                    .lineLimit(1)
                Text("\(transaction.postedAt.formatted(date: .abbreviated, time: .omitted)) · \(categoryLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(AppDesign.money(transaction.amountCents))
                .fontWeight(.semibold)
                .foregroundStyle(transaction.amountCents >= 0 ? AppDesign.positive : AppDesign.warning)
                .monospacedDigit()
        }
    }
}

private struct BudgetTransactionPickerView: View {
    @Bindable var store: FinanceStore
    let budget: Budget
    let month: Date
    let transactions: [Transaction]
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs = Set<String>()
    @State private var query = ""
    @State private var applying = false

    private var candidates: [Transaction] {
        transactions
            .filter { $0.amountCents < 0 }
            .filter { transaction in
                !(transaction.categorySplits ?? []).contains { $0.categoryID == budget.categoryID || $0.name.localizedCaseInsensitiveCompare(budget.categoryName) == .orderedSame }
            }
            .filter { transaction in
                let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return true }
                return (transaction.merchantName ?? transaction.description).localizedCaseInsensitiveContains(trimmed) || transaction.description.localizedCaseInsensitiveContains(trimmed)
            }
    }
    private var selectedTransactions: [Transaction] {
        candidates.filter { selectedIDs.contains($0.id) }
    }
    private var selectedTotal: Int64 {
        selectedTransactions.reduce(Int64(0)) { $0 + abs(min(0, $1.amountCents)) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(selectedIDs.count) selected")
                                .font(.headline)
                            Text(AppDesign.money(selectedTotal))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Spacer()
                        Button(selectedIDs.isEmpty ? "Select visible" : "Clear") {
                            if selectedIDs.isEmpty {
                                selectedIDs = Set(candidates.map(\.id))
                            } else {
                                selectedIDs.removeAll()
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(candidates.isEmpty)
                    }
                }
                Section {
                    if candidates.isEmpty {
                        ContentUnavailableView("No Matching Transactions", systemImage: "line.3.horizontal.decrease.circle", description: Text("Try a different search or pick another month."))
                    }
                    ForEach(candidates) { transaction in
                        Button {
                            toggle(transaction.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selectedIDs.contains(transaction.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedIDs.contains(transaction.id) ? AppDesign.positive : .secondary)
                                BudgetTransactionRow(transaction: transaction)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Transactions in \(month.formatted(.dateTime.month(.wide).year()))")
                } footer: {
                    Text("Selected transactions will be assigned to \(budget.categoryName). Existing categories are replaced only for the selected transaction, not for similar merchants.")
                }
            }
            .searchable(text: $query, prompt: "Search transactions")
            .navigationTitle("Add Transactions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(applying ? "Applying…" : "Apply") {
                        Task { await apply() }
                    }
                    .disabled(selectedIDs.isEmpty || applying)
                }
            }
        }
    }

    private func toggle(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func apply() async {
        applying = true
        for transaction in candidates where selectedIDs.contains(transaction.id) {
            await store.updateTransactionCategory(transaction, categoryName: budget.categoryName, applyToSimilar: false)
        }
        applying = false
        dismiss()
    }
}

private struct BudgetEditorView: View {
    enum Mode {
        case create
        case edit(Budget)

        var title: String {
            switch self {
            case .create: "New Budget"
            case .edit: "Edit Budget"
            }
        }

        var actionTitle: String {
            switch self {
            case .create: "Create"
            case .edit: "Save"
            }
        }
    }

    @Bindable var store: FinanceStore
    let mode: Mode
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?
    @State private var draft: BudgetDraft
    @State private var limitDollars: String

    private enum Field {
        case category
        case amount
    }

    init(store: FinanceStore, mode: Mode) {
        self.store = store
        self.mode = mode
        switch mode {
        case .create:
            _draft = State(initialValue: BudgetDraft())
            _limitDollars = State(initialValue: "")
        case let .edit(budget):
            _draft = State(initialValue: BudgetDraft(categoryName: budget.categoryName, period: budget.period, limitCents: budget.limitCents))
            _limitDollars = State(initialValue: Self.dollars(from: budget.limitCents))
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    categoryCard
                    amountCard
                    periodCard
                    previewCard
                }
                .padding(20)
                .padding(.bottom, 96)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemBackground))
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                saveBar
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(mode.title)
                .font(.largeTitle.weight(.bold))
            Text("Set the category, spending limit, and pacing rhythm. You can classify past-month transactions from the budget detail screen.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var categoryCard: some View {
        BudgetEditorCard(title: "Category", subtitle: "Choose an existing category or type a new one.") {
            HStack(spacing: 12) {
                Image(systemName: "tag.fill")
                    .foregroundStyle(.secondary)
                TextField("Category name", text: $draft.categoryName)
                    .focused($focusedField, equals: .category)
                    .textInputAutocapitalization(.words)
                    .font(.title3.weight(.semibold))
                    .submitLabel(.next)
                    .onSubmit { focusedField = .amount }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(AppDesign.panel.opacity(0.9), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            if !suggestedCategories.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(suggestedCategories, id: \.self) { categoryName in
                            Button {
                                draft.categoryName = categoryName
                            } label: {
                                Text(categoryName)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(
                                        categoryName == draft.categoryName ? Color.accentColor.opacity(0.85) : AppDesign.panel,
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            if let categorySpendHint {
                Label(categorySpendHint, systemImage: "chart.line.uptrend.xyaxis")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var amountCard: some View {
        BudgetEditorCard(title: "Limit", subtitle: draft.period == "weekly" ? "Weekly cap for this category." : "Monthly cap for this category.") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("$")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                TextField("0", text: $limitDollars)
                    .focused($focusedField, equals: .amount)
                    .keyboardType(.decimalPad)
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.55)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(AppDesign.panel.opacity(0.9), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            VStack(alignment: .leading, spacing: 10) {
                Text("Quick amounts")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(amountPresets, id: \.self) { amount in
                        Button("$\(amount)") {
                            limitDollars = "\(amount)"
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                    }
                }
                if cents(from: limitDollars) > 0 {
                    Text(equivalentLimitText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var amountPresets: [Int] {
        draft.period == "weekly" ? [50, 100, 150, 250] : [100, 250, 500, 1000]
    }

    private var equivalentLimitText: String {
        let limit = cents(from: limitDollars)
        if draft.period == "weekly" {
            return "About \(AppDesign.money(limit * 4)) available across a four-week month."
        }
        return "About \(AppDesign.money(limit / 4)) available per week."
    }

    private var validationMessage: String? {
        if draft.categoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Add a category name."
        }
        if cents(from: limitDollars) <= 0 {
            return "Set a budget limit greater than $0."
        }
        return nil
    }

    private var categorySpendHint: String? {
        let normalized = draft.categoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let monthlySpend = store.cashflowTrendTransactions
            .filter { $0.amountCents < 0 }
            .filter { transaction in
                (transaction.categorySplits ?? []).contains { $0.name.localizedCaseInsensitiveCompare(normalized) == .orderedSame }
            }
            .reduce(Int64(0)) { $0 + abs($1.amountCents) }
        guard monthlySpend > 0 else { return nil }
        return "Tracked spending in this category is \(AppDesign.money(monthlySpend)) in loaded history."
    }

    private var periodCard: some View {
        BudgetEditorCard(title: "Pacing", subtitle: "Monthly is best for bills. Weekly is best for flexible spend.") {
            HStack(spacing: 10) {
                BudgetPeriodOption(
                    title: "Monthly",
                    subtitle: "Bills and fixed costs",
                    icon: "calendar",
                    isSelected: draft.period == "monthly"
                ) {
                    draft.period = "monthly"
                }
                BudgetPeriodOption(
                    title: "Weekly",
                    subtitle: "Food and day-to-day",
                    icon: "calendar.badge.clock",
                    isSelected: draft.period == "weekly"
                ) {
                    draft.period = "weekly"
                }
            }
        }
    }

    private var previewCard: some View {
        let limit = cents(from: limitDollars)
        let monthlyEquivalent = draft.period == "weekly" ? limit * 4 : limit
        return VStack(alignment: .leading, spacing: 10) {
            Label("Preview", systemImage: "chart.bar.fill")
                .font(.headline)
            HStack {
                BudgetDetailRow(label: "Budget", value: draft.categoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Unnamed" : draft.categoryName)
                Spacer(minLength: 0)
            }
            BudgetDetailRow(label: "Limit", value: AppDesign.money(limit))
            BudgetDetailRow(label: "Monthly equivalent", value: AppDesign.money(monthlyEquivalent))
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var saveBar: some View {
        VStack(spacing: 10) {
            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                save()
            } label: {
                HStack {
                    Spacer()
                    Text(mode.actionTitle)
                        .font(.headline)
                    Spacer()
                }
                .padding(.vertical, 15)
            }
            .buttonStyle(.plain)
            .foregroundStyle(canSave ? .white : .secondary)
            .background(canSave ? Color.accentColor : AppDesign.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .disabled(!canSave)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.bar)
    }

    private var suggestedCategories: [String] {
        let current = draft.categoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        let names = store.categoryNames.filter { !$0.isEmpty }
        if current.isEmpty {
            return Array(names.prefix(16))
        }
        return Array(names.filter { $0.localizedCaseInsensitiveContains(current) || current.localizedCaseInsensitiveContains($0) }.prefix(16))
    }

    private func save() {
        draft.limitCents = cents(from: limitDollars)
        Task {
            switch mode {
            case .create:
                await store.addBudget(draft)
            case let .edit(budget):
                await store.updateBudget(budget, draft: draft)
            }
            dismiss()
        }
    }

    private var canSave: Bool {
        !draft.categoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && cents(from: limitDollars) > 0
    }

    private func cents(from value: String) -> Int64 {
        let cleaned = value.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let amount = Decimal(string: cleaned) else { return 0 }
        return NSDecimalNumber(decimal: amount * Decimal(100)).int64Value
    }

    private static func dollars(from cents: Int64) -> String {
        let dollars = Decimal(cents) / Decimal(100)
        return NSDecimalNumber(decimal: dollars).stringValue
    }
}

private struct BudgetEditorCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private struct BudgetPeriodOption: View {
    let title: String
    let subtitle: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon)
                    .font(.title3)
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                    .lineLimit(2)
            }
            .foregroundStyle(isSelected ? .white : .primary)
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.9) : AppDesign.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct BudgetDetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct BudgetPace: Identifiable, Hashable {
    enum Status: Hashable {
        case onTrack
        case ahead
        case over

        var description: String {
            switch self {
            case .onTrack: "On Track"
            case .ahead: "Spending Fast"
            case .over: "Over Budget"
            }
        }

        var color: Color {
            switch self {
            case .onTrack: AppDesign.positive
            case .ahead: AppDesign.warning
            case .over: AppDesign.warning
            }
        }
    }

    let budget: Budget
    let spent: Int64
    let remaining: Int64
    let progress: Double
    let expectedProgress: Double
    let daysRemaining: Int
    let safeDailySpendCents: Int64
    let status: Status

    var id: String { budget.id }

    var severity: Int {
        switch status {
        case .over: 2
        case .ahead: 1
        case .onTrack: 0
        }
    }

    init(budget: Budget, spentOverride: Int64? = nil, now: Date = .now, calendar: Calendar = .current) {
        self.budget = budget
        spent = spentOverride ?? max(0, -budget.spentCents)
        remaining = budget.limitCents - spent
        progress = Double(spent) / Double(max(1, budget.limitCents))

        let interval: DateInterval
        if budget.period == "weekly" {
            interval = calendar.dateInterval(of: .weekOfYear, for: now) ?? DateInterval(start: now, duration: 7 * 86_400)
        } else {
            interval = calendar.dateInterval(of: .month, for: now) ?? DateInterval(start: now, duration: 30 * 86_400)
        }

        let elapsed = max(0, now.timeIntervalSince(interval.start))
        let duration = max(1, interval.duration)
        expectedProgress = min(1, max(0, elapsed / duration))
        let remainingSeconds = max(0, interval.end.timeIntervalSince(now))
        daysRemaining = max(1, Int(ceil(remainingSeconds / 86_400)))
        safeDailySpendCents = max(0, remaining) / Int64(daysRemaining)

        if remaining < 0 {
            status = .over
        } else if progress > expectedProgress + 0.12 {
            status = .ahead
        } else {
            status = .onTrack
        }
    }
}

private struct IncomeInsight: Hashable {
    let monthlyIncomeCents: Int64
    let cadenceLabel: String

    init(transactions: [Transaction], month: Date = .now, overrides: BudgetIncomeOverrides = BudgetIncomeOverrides()) {
        let incomeTransactions = transactions
            .filter { $0.amountCents > 0 && overrides.includes($0) }
            .sorted { $0.postedAt < $1.postedAt }
        let total = incomeTransactions.reduce(Int64(0)) { $0 + $1.amountCents }

        let grouped = Dictionary(grouping: incomeTransactions) { BudgetIncomeClassifier.incomeKey($0) }
        let recurring = grouped.values
            .filter { $0.count >= 2 }
            .max { lhs, rhs in
                lhs.reduce(Int64(0)) { $0 + $1.amountCents } < rhs.reduce(Int64(0)) { $0 + $1.amountCents }
            }
        if let recurring {
            let days = BudgetIncomeClassifier.averageSpacingDays(recurring)
            let source = BudgetIncomeClassifier.incomeKey(recurring.last!).prefix(22)
            let averageDeposit = recurring.reduce(Int64(0)) { $0 + $1.amountCents } / Int64(max(1, recurring.count))
            if (12...17).contains(days) {
                monthlyIncomeCents = Int64((Double(averageDeposit) * 26.0 / 12.0).rounded())
            } else if (25...35).contains(days) {
                monthlyIncomeCents = averageDeposit
            } else {
                monthlyIncomeCents = total
            }
            cadenceLabel = days > 0 ? "\(source) · every \(days)d" : "\(source) detected"
        } else if total > 0 {
            monthlyIncomeCents = total
            cadenceLabel = "\(incomeTransactions.count) included deposit\(incomeTransactions.count == 1 ? "" : "s") in \(month.formatted(.dateTime.month(.abbreviated)))"
        } else {
            monthlyIncomeCents = 0
            cadenceLabel = "No income detected yet"
        }
    }
}
