import SwiftUI

struct TransactionsView: View {
    @Bindable var store: FinanceStore
    @State private var draftFilter = TransactionFilter()
    @State private var showingFilters = false
    @State private var categoryEditingTransaction: Transaction?

    var body: some View {
        NavigationStack {
            Group {
                if store.transactions.isEmpty && pendingSignalCaptures.isEmpty {
                    ContentUnavailableView {
                        Label("No Transactions", systemImage: "list.bullet.rectangle")
                    } description: {
                        Text(draftFilter.isDefault ? "Connect a bank, import a statement, adjust your filters, or refresh after a sync." : "No transactions match the current filters.")
                    } actions: {
                        if draftFilter.isDefault {
                            Button("Refresh Activity") {
                                Task { await refreshActivity() }
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button("Clear Filters") {
                                Task { await clearFilters() }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .refreshable { await refreshActivity() }
                } else {
                    List {
                        if !activeFilterLabels.isEmpty {
                            Section {
                                ActiveTransactionFiltersView(labels: activeFilterLabels) {
                                    Task { await clearFilters() }
                                }
                            }
                        }
                        if !pendingSignalCaptures.isEmpty {
                            Section("Timestamp Captures") {
                                ForEach(pendingSignalCaptures) { signal in
                                    TransactionSignalListRow(signal: signal)
                                }
                            }
                        }
                        if !store.transactions.isEmpty {
                            Section("Transactions") {
                                ForEach(store.transactions) { transaction in
                                    NavigationLink(value: transaction) {
                                        TransactionRow(
                                            transaction: transaction,
                                            accountName: accountName(for: transaction),
                                            signals: timingSignals(for: transaction)
                                        )
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button {
                                            categoryEditingTransaction = transaction
                                        } label: {
                                            Label("Classify", systemImage: "tag")
                                        }
                                        Button {
                                            Task { await store.updateTransactionCategory(transaction, categoryName: quickCategory(for: transaction), applyToSimilar: true) }
                                        } label: {
                                            Label(quickCategory(for: transaction), systemImage: quickCategoryIcon(for: transaction))
                                        }
                                        .tint(quickCategoryTint(for: transaction))
                                    }
                                }
                                if store.hasMoreTransactions {
                                    Button {
                                        Task { await store.loadMoreTransactions() }
                                    } label: {
                                        HStack {
                                            Spacer()
                                            if store.isLoadingMoreTransactions {
                                                ProgressView()
                                                    .controlSize(.small)
                                                Text("Loading more…")
                                            } else {
                                                Text("Load more transactions")
                                            }
                                            Spacer()
                                        }
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.vertical, 8)
                                    }
                                    .disabled(store.isLoadingMoreTransactions)
                                    .onAppear {
                                        Task { await store.loadMoreTransactions() }
                                    }
                                }
                            }
                        }
                    }
                    .refreshable { await refreshActivity() }
                }
            }
            .navigationTitle("Activity")
            .searchable(text: $draftFilter.searchText, prompt: "Search merchant, memo, location")
            .onSubmit(of: .search) {
                Task { await store.applyTransactionFilter(draftFilter) }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Sort", selection: $draftFilter.sortField) {
                            ForEach(TransactionFilter.SortField.allCases) { field in
                                Text(field.label).tag(field)
                            }
                        }
                        Picker("Direction", selection: $draftFilter.sortDirection) {
                            ForEach(TransactionFilter.SortDirection.allCases) { direction in
                                Text(direction.label).tag(direction)
                            }
                        }
                        Button("Apply Sort") {
                            Task { await store.applyTransactionFilter(draftFilter) }
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showingFilters = true
                        } label: {
                            Label("Edit Filters", systemImage: "line.3.horizontal.decrease.circle")
                        }
                        Button(role: .destructive) {
                            Task { await clearFilters() }
                        } label: {
                            Label("Clear Filters", systemImage: "xmark.circle")
                        }
                        .disabled(draftFilter.isDefault)
                    } label: {
                        Label("Filters", systemImage: draftFilter.isDefault ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                }
            }
            .sheet(isPresented: $showingFilters) {
                TransactionFilterSheet(filter: $draftFilter, accounts: store.accounts) {
                    showingFilters = false
                    Task { await store.applyTransactionFilter(draftFilter) }
                }
            }
            .sheet(item: $categoryEditingTransaction) { transaction in
                TransactionCategoryEditorView(store: store, transaction: transaction)
            }
            .navigationDestination(for: Transaction.self) { transaction in
                TransactionDetailView(
                    store: store,
                    transaction: transaction,
                    account: store.accounts.first { $0.id == transaction.accountID },
                    signals: timingSignals(for: transaction)
                )
            }
            .onAppear {
                draftFilter = store.transactionFilter
                if store.transactions.isEmpty {
                    Task { await store.applyTransactionFilter(draftFilter) }
                }
            }
        }
    }

    private func refreshActivity() async {
        await store.syncPlaidTransactions()
        await store.applyTransactionFilter(draftFilter)
    }

    private func clearFilters() async {
        draftFilter = TransactionFilter()
        await store.applyTransactionFilter(draftFilter)
    }

    private func accountName(for transaction: Transaction) -> String {
        store.accounts.first { $0.id == transaction.accountID }?.name ?? transaction.source.capitalized
    }

    private var pendingSignalCaptures: [TransactionSignal] {
        store.transactionSignals
            .filter { $0.source == "quick_add" && $0.status != "confirmed" }
            .sorted { $0.occurredAt > $1.occurredAt }
    }

    private func timingSignals(for transaction: Transaction) -> [TransactionSignal] {
        store.transactionSignals
            .filter { $0.matchedTransactionID == transaction.id }
            .sorted { $0.occurredAt < $1.occurredAt }
    }

    private var activeFilterLabels: [String] {
        draftFilter.summaryLabels.map { label in
            if label == "Account selected", let account = store.accounts.first(where: { $0.id == draftFilter.accountID }) {
                return "Account: \(account.name)"
            }
            return label
        }
    }

    private func quickCategory(for transaction: Transaction) -> String {
        if transaction.amountCents > 0 {
            return looksLikeTransfer(transaction) ? "Transfer" : "Income"
        }
        let text = [transaction.merchantName ?? "", transaction.description].joined(separator: " ").lowercased()
        if text.contains("transfer") || text.contains("payment") || text.contains("autopay") {
            return "Transfer"
        }
        return "Uncategorized"
    }

    private func looksLikeTransfer(_ transaction: Transaction) -> Bool {
        let text = [transaction.description, transaction.merchantName ?? "", transaction.categorySplits?.first?.name ?? ""].joined(separator: " ").lowercased()
        return text.contains("transfer") || text.contains("credit card payment") || text.contains("payment from") || text.contains("payment to") || text.contains("online transfer")
    }

    private func quickCategoryIcon(for transaction: Transaction) -> String {
        quickCategory(for: transaction) == "Income" ? "arrow.down.left.circle" : "arrow.left.arrow.right.circle"
    }

    private func quickCategoryTint(for transaction: Transaction) -> Color {
        quickCategory(for: transaction) == "Income" ? AppDesign.positive : .orange
    }
}

private struct TransactionSignalListRow: View {
    let signal: TransactionSignal

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: signal.matchedTransactionID == nil ? "clock.badge.exclamationmark" : "clock.badge.checkmark")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(signal.matchedTransactionID == nil ? AppDesign.warning : AppDesign.positive)
                .frame(width: 32, height: 32)
                .background(.thinMaterial, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(signal.merchantHint?.isEmpty == false ? signal.merchantHint! : "Captured spend")
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                if let amount = signal.amountCents {
                    Text(AppDesign.money(amount))
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                }
                Text(signal.occurredAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusText: String {
        if signal.matchedTransactionID == nil {
            return "Waiting for Plaid match"
        }
        return "\(signal.status.capitalized) match · \(Int((signal.confidence * 100).rounded()))%"
    }
}

private struct ActiveTransactionFiltersView: View {
    let labels: [String]
    let clear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Filtered results", systemImage: "line.3.horizontal.decrease.circle.fill")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Clear", action: clear)
                    .font(.caption.weight(.semibold))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(labels, id: \.self) { label in
                        Text(label)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.thinMaterial, in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct TransactionRow: View {
    let transaction: Transaction
    let accountName: String
    let signals: [TransactionSignal]?

    init(transaction: Transaction, accountName: String, signals: [TransactionSignal]? = nil) {
        self.transaction = transaction
        self.accountName = accountName
        self.signals = signals
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: transaction.pending ? "clock" : "checkmark.circle")
                .symbolRenderingMode(.hierarchical)
                .frame(width: 32, height: 32)
                .background(.thinMaterial, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(transaction.merchantName ?? transaction.description)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text("\(accountName) · \(transaction.postedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(categoryLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                if hasTimingSignal {
                    Label("Exact-time signal", systemImage: "clock.badge.checkmark")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(AppDesign.positive)
                }
            }
            Spacer()
            Text(AppDesign.money(transaction.amountCents))
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(transaction.amountCents < 0 ? .primary : AppDesign.positive)
        }
        .padding(.vertical, 4)
    }

    private var hasTimingSignal: Bool {
        transaction.authorizedAt != nil || !(signals ?? []).isEmpty
    }

    private var categoryLabel: String {
        transaction.categorySplits?.first?.name ?? "Uncategorized"
    }
}

private struct TransactionFilterSheet: View {
    @Binding var filter: TransactionFilter
    let accounts: [Account]
    let apply: () -> Void
    @Environment(\.dismiss) private var dismiss

    private let sources = ["plaid", "manual", "statement", "financekit"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Text") {
                    TextField("Merchant, description, notes, location", text: $filter.searchText)
                }
                Section("Scope") {
                    Picker("Account", selection: $filter.accountID) {
                        Text("Any account").tag("")
                        ForEach(accounts.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { account in
                            Text(account.name).tag(account.id)
                        }
                    }
                    Picker("Source", selection: $filter.source) {
                        Text("Any source").tag("")
                        ForEach(sources, id: \.self) { source in
                            Text(TransactionFilter.sourceLabel(source)).tag(source)
                        }
                    }
                }
                Section("Amount") {
                    Picker("Match", selection: $filter.amountMode) {
                        ForEach(TransactionFilter.AmountMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    TextField("Signed amount, e.g. -25.00 or 100", text: $filter.amountText)
                        .keyboardType(.decimalPad)
                }
                Section("Date") {
                    Toggle("Start date", isOn: $filter.isStartDateEnabled)
                    if filter.isStartDateEnabled {
                        DatePicker("From", selection: $filter.startDate, displayedComponents: .date)
                    }
                    Toggle("End date", isOn: $filter.isEndDateEnabled)
                    if filter.isEndDateEnabled {
                        DatePicker("To", selection: $filter.endDate, displayedComponents: .date)
                    }
                }
                Section("Sort") {
                    Picker("Field", selection: $filter.sortField) {
                        ForEach(TransactionFilter.SortField.allCases) { field in
                            Text(field.label).tag(field)
                        }
                    }
                    Picker("Direction", selection: $filter.sortDirection) {
                        ForEach(TransactionFilter.SortDirection.allCases) { direction in
                            Text(direction.label).tag(direction)
                        }
                    }
                }
                Section {
                    Button("Reset") {
                        filter = TransactionFilter()
                    }
                }
            }
            .navigationTitle("Filter Activity")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { apply() }
                }
            }
        }
    }
}

private struct TransactionDetailView: View {
    @Bindable var store: FinanceStore
    let transaction: Transaction
    let account: Account?
    let signals: [TransactionSignal]
    @State private var showingCategoryEditor = false
    @State private var showingReceiptEditor = false

    private var currentTransaction: Transaction {
        store.transactions.first { $0.id == transaction.id } ??
        store.cashflowTrendTransactions.first { $0.id == transaction.id } ??
        transaction
    }

    private var title: String {
        currentTransaction.merchantName?.isEmpty == false ? currentTransaction.merchantName! : currentTransaction.description
    }

    private var categoryTotal: Int64 {
        currentTransaction.categorySplits?.reduce(0) { $0 + abs($1.amountCents) } ?? 0
    }

    private var receiptTotal: Int64 {
        currentTransaction.receiptLineItems?.reduce(0) { $0 + abs($1.amountCents) } ?? 0
    }

    private var sortedSignals: [TransactionSignal] {
        signals.sorted { $0.occurredAt < $1.occurredAt }
    }

    private var bestObservedAt: Date? {
        currentTransaction.authorizedAt ?? sortedSignals.first?.occurredAt
    }

    var body: some View {
        let transaction = currentTransaction
        List {
            Section {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: iconName)
                            .font(.title2.weight(.semibold))
                            .symbolRenderingMode(.hierarchical)
                            .frame(width: 52, height: 52)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(title)
                                .font(.title2.weight(.semibold))
                            Text(account?.name ?? transaction.source.capitalized)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(transaction.amountCents < 0 ? "Spent" : "Received")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(AppDesign.money(transaction.amountCents))
                            .font(.system(size: 46, weight: .bold, design: .rounded))
                            .foregroundStyle(transaction.amountCents < 0 ? .primary : AppDesign.positive)
                            .monospacedDigit()
                    }
                    HStack(spacing: 10) {
                        StatusPill(title: transaction.pending ? "Pending" : "Posted", systemImage: transaction.pending ? "clock" : "checkmark.circle", tint: transaction.pending ? AppDesign.warning : AppDesign.positive)
                        StatusPill(title: transaction.source.capitalized, systemImage: sourceIcon, tint: .secondary)
                    }
                }
                .padding(.vertical, 8)
            }
            Section("Details") {
                DetailRow(label: "Account", value: account?.name ?? transaction.accountID)
                if let bestObservedAt {
                    DetailRow(label: "Observed", value: bestObservedAt.formatted(date: .complete, time: .shortened))
                }
                if let authorizedAt = transaction.authorizedAt {
                    DetailRow(label: "Authorized", value: authorizedAt.formatted(date: .complete, time: .shortened))
                }
                DetailRow(label: "Posted", value: transaction.postedAt.formatted(date: .complete, time: .shortened))
                DetailRow(label: "Source", value: transaction.source.capitalized)
                DetailRow(label: "Currency", value: transaction.currencyCode)
                if let location = transaction.locationName, !location.isEmpty {
                    DetailRow(label: "Location", value: location)
                }
                DetailRow(label: "Description", value: transaction.description)
            }
            if !sortedSignals.isEmpty {
                Section("Timing Signals") {
                    ForEach(sortedSignals) { signal in
                        TransactionSignalRow(signal: signal)
                    }
                }
            }
            if let splits = transaction.categorySplits, !splits.isEmpty {
                Section("Category Splits") {
                    ForEach(splits) { split in
                        VStack(alignment: .leading, spacing: 8) {
                            DetailRow(label: split.name, value: AppDesign.money(split.amountCents))
                            ProgressView(value: Double(abs(split.amountCents)), total: Double(max(1, categoryTotal)))
                        }
                    }
                }
            }
            Section("Classification") {
                DetailRow(label: "Current", value: transaction.categorySplits?.first?.name ?? "Uncategorized")
                HStack(spacing: 8) {
                    ForEach(quickDetailCategories(for: transaction), id: \.self) { categoryName in
                        Button(categoryName) {
                            Task { await store.updateTransactionCategory(transaction, categoryName: categoryName, applyToSimilar: true) }
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                    }
                }
                Button {
                    showingCategoryEditor = true
                } label: {
                    Label("Change Category", systemImage: "tag")
                }
            }
            if let lineItems = transaction.receiptLineItems, !lineItems.isEmpty {
                Section("Receipt Items") {
                    ForEach(lineItems) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            DetailRow(label: item.name, value: AppDesign.money(item.amountCents))
                            HStack {
                                Text(item.quantity.isEmpty ? "Line item" : item.quantity)
                                Spacer()
                                if let categoryID = item.categoryID, !categoryID.isEmpty {
                                    Text(categoryID)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            ProgressView(value: Double(abs(item.amountCents)), total: Double(max(1, receiptTotal)))
                        }
                    }
                }
            }
            Section("Receipt") {
                Button {
                    showingReceiptEditor = true
                } label: {
                    Label((transaction.receiptLineItems ?? []).isEmpty ? "Add Receipt Items" : "Edit Receipt Items", systemImage: "plus.rectangle.on.rectangle")
                }
                NavigationLink {
                    DigitalReceiptView(transaction: transaction)
                } label: {
                    Label("View Digital Receipt", systemImage: "receipt")
                }
                .disabled((transaction.receiptLineItems ?? []).isEmpty && (transaction.categorySplits ?? []).isEmpty)
            }
            if let notes = transaction.notes, !notes.isEmpty {
                Section("Notes") {
                    Text(notes)
                }
            }
        }
        .navigationTitle("Transaction")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingCategoryEditor) {
            TransactionCategoryEditorView(store: store, transaction: transaction)
        }
        .sheet(isPresented: $showingReceiptEditor) {
            ReceiptEditorView(store: store, transaction: transaction)
        }
    }

    private var iconName: String {
        if transaction.amountCents > 0 { return "arrow.down.left.circle.fill" }
        let text = title.lowercased()
        if text.contains("grocery") || text.contains("market") || text.contains("whole foods") { return "cart.fill" }
        if text.contains("restaurant") || text.contains("cafe") || text.contains("coffee") { return "fork.knife" }
        if text.contains("gas") || text.contains("fuel") { return "fuelpump.fill" }
        if text.contains("transfer") || text.contains("payment") { return "arrow.left.arrow.right.circle.fill" }
        return "creditcard.fill"
    }

    private var sourceIcon: String {
        switch transaction.source {
        case "plaid": "link.circle"
        case "manual": "hand.draw"
        case "financekit": "wallet.pass"
        default: "tray.full"
        }
    }

    private func quickDetailCategories(for transaction: Transaction) -> [String] {
        if transaction.amountCents > 0 {
            return ["Income", "Transfer"]
        }
        let text = [transaction.merchantName ?? "", transaction.description].joined(separator: " ").lowercased()
        if text.contains("transfer") || text.contains("payment") || text.contains("autopay") {
            return ["Transfer", "Uncategorized"]
        }
        return ["Uncategorized", "Shopping", "Restaurants"]
    }
}

private struct TransactionSignalRow: View {
    let signal: TransactionSignal

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbolName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body.weight(.medium))
                    Text(signal.occurredAt.formatted(date: .complete, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int((signal.confidence * 100).rounded()))%")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if let amount = signal.amountCents {
                DetailRow(label: "Amount", value: AppDesign.money(amount))
            }
            if let merchant = signal.merchantHint, !merchant.isEmpty {
                DetailRow(label: "Merchant", value: merchant)
            }
            if let location = signal.locationName, !location.isEmpty {
                DetailRow(label: "Location", value: location)
            }
            DetailRow(label: "Status", value: signal.status.capitalized)
        }
        .padding(.vertical, 4)
    }

    private var title: String {
        switch signal.source {
        case "plaid_first_seen": "Plaid first saw it"
        case "financekit_transaction_date": "Wallet transaction time"
        case "quick_add": "Manual timestamp capture"
        case "receipt": "Receipt timestamp"
        case "email_alert": "Card alert timestamp"
        default: signal.source.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private var symbolName: String {
        switch signal.source {
        case "quick_add": "hand.tap"
        case "financekit_transaction_date": "wallet.pass"
        case "plaid_first_seen": "link.circle"
        case "receipt": "receipt"
        default: "clock.badge.checkmark"
        }
    }

    private var tint: Color {
        switch signal.source {
        case "financekit_transaction_date", "quick_add": AppDesign.positive
        case "plaid_first_seen": .blue
        default: .secondary
        }
    }
}

private struct DetailRow: View {
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

private struct TransactionCategoryEditorView: View {
    @Bindable var store: FinanceStore
    let transaction: Transaction
    @Environment(\.dismiss) private var dismiss
    @State private var categoryName: String
    @State private var applyToSimilar = true

    init(store: FinanceStore, transaction: Transaction) {
        self.store = store
        self.transaction = transaction
        _categoryName = State(initialValue: transaction.categorySplits?.first?.name ?? Self.suggestedCategory(for: transaction))
    }

    private var suggestions: [String] {
        let defaults = ["Groceries", "Restaurants", "Coffee", "Gas", "Shopping", "Travel", "Utilities", "Subscriptions", "Income", "Transfer"]
        let existing = store.categoryNames.filter { !defaults.contains($0) }
        var ordered = [Self.suggestedCategory(for: transaction)] + defaults + existing
        ordered.removeAll { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return ordered.reduce(into: [String]()) { result, item in
            if !result.contains(where: { $0.localizedCaseInsensitiveCompare(item) == .orderedSame }) {
                result.append(item)
            }
        }
    }

    private var merchantLabel: String {
        transaction.merchantName?.isEmpty == false ? transaction.merchantName! : transaction.description
    }

    private static func suggestedCategory(for transaction: Transaction) -> String {
        if transaction.amountCents > 0 {
            return "Income"
        }
        let text = [transaction.merchantName ?? "", transaction.description].joined(separator: " ").lowercased()
        if text.contains("whole foods") || text.contains("publix") || text.contains("market") || text.contains("grocery") {
            return "Groceries"
        }
        if text.contains("starbucks") || text.contains("coffee") || text.contains("cafe") {
            return "Coffee"
        }
        if text.contains("restaurant") || text.contains("doordash") || text.contains("uber eats") || text.contains("grill") {
            return "Restaurants"
        }
        if text.contains("shell") || text.contains("chevron") || text.contains("exxon") || text.contains("gas") || text.contains("fuel") {
            return "Gas"
        }
        if text.contains("netflix") || text.contains("spotify") || text.contains("apple.com") || text.contains("openrouter") {
            return "Subscriptions"
        }
        if text.contains("transfer") || text.contains("payment") || text.contains("autopay") {
            return "Transfer"
        }
        return "Shopping"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Category") {
                    TextField("Category name", text: $categoryName)
                        .textInputAutocapitalization(.words)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(suggestions, id: \.self) { suggestion in
                                Button(suggestion) {
                                    categoryName = suggestion
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                Section("Rule") {
                    Toggle("Apply to similar transactions", isOn: $applyToSimilar)
                    Text("When enabled, future transactions from \(merchantLabel) will be classified as \(categoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "this category" : categoryName).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button("Save Category") {
                        Task {
                            await store.updateTransactionCategory(transaction, categoryName: categoryName, applyToSimilar: applyToSimilar)
                            dismiss()
                        }
                    }
                    .disabled(categoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Classify")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

private struct ReceiptEditorView: View {
    @Bindable var store: FinanceStore
    let transaction: Transaction
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ReceiptDraft
    @State private var isSaving = false
    @State private var showingScanner = false
    @State private var scanSummary = ""

    init(store: FinanceStore, transaction: Transaction) {
        self.store = store
        self.transaction = transaction
        let existingItems = transaction.receiptLineItems ?? []
        let items = existingItems.isEmpty
            ? [ReceiptLineItemDraft()]
            : existingItems.map {
                ReceiptLineItemDraft(
                    name: $0.name,
                    quantity: $0.quantity,
                    amountText: Self.dollars(from: $0.amountCents),
                    categoryName: $0.categoryID ?? ""
                )
            }
        _draft = State(initialValue: ReceiptDraft(
            merchantName: transaction.merchantName ?? transaction.description,
            purchasedAt: transaction.authorizedAt ?? transaction.postedAt,
            totalText: Self.dollars(from: abs(transaction.amountCents)),
            currencyCode: transaction.currencyCode,
            lineItems: items
        ))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Receipt") {
                    TextField("Merchant", text: $draft.merchantName)
                    DatePicker("Purchased", selection: $draft.purchasedAt)
                    TextField("Total", text: $draft.totalText)
                        .keyboardType(.decimalPad)
                    DetailRow(label: "Line item total", value: AppDesign.money(draft.lineItems.reduce(Int64(0)) { $0 + $1.amountCents }))
                    Button {
                        showingScanner = true
                    } label: {
                        Label("Scan Receipt", systemImage: "camera.viewfinder")
                    }
                    if !scanSummary.isEmpty {
                        Text(scanSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    ForEach($draft.lineItems) { $item in
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Item name", text: $item.name)
                            HStack {
                                TextField("Qty", text: $item.quantity)
                                TextField("Amount", text: $item.amountText)
                                    .keyboardType(.decimalPad)
                            }
                            TextField("Category", text: $item.categoryName)
                                .textInputAutocapitalization(.words)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                draft.lineItems.removeAll { $0.id == item.id }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    Button {
                        draft.lineItems.append(ReceiptLineItemDraft())
                    } label: {
                        Label("Add Line Item", systemImage: "plus.circle")
                    }
                } header: {
                    Text("Line Items")
                } footer: {
                    Text("Use this for receipt-level category detail, like splitting a grocery receipt into food, household, and snacks.")
                }
            }
            .navigationTitle("Receipt Items")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .disabled(!canSave || isSaving)
                }
            }
            .sheet(isPresented: $showingScanner) {
                DocumentScannerView { result in
                    applyScanResult(result)
                    showingScanner = false
                }
            }
        }
    }

    private var canSave: Bool {
        draft.lineItems.contains { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.amountCents != 0 }
    }

    private func save() async {
        isSaving = true
        await store.upsertReceipt(for: transaction, draft: draft)
        isSaving = false
        dismiss()
    }

    private func applyScanResult(_ result: ReceiptScanResult) {
        scanSummary = "\(result.pageCount) page\(result.pageCount == 1 ? "" : "s") scanned · \(result.lineItems.count) line item\(result.lineItems.count == 1 ? "" : "s") detected"
        guard !result.lineItems.isEmpty else { return }
        draft.lineItems = result.lineItems
        if draft.totalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let totalCents = result.lineItems.reduce(Int64(0)) { $0 + $1.amountCents }
            draft.totalText = Self.dollars(from: totalCents)
        }
    }

    private static func dollars(from cents: Int64) -> String {
        let dollars = Decimal(cents) / Decimal(100)
        return NSDecimalNumber(decimal: dollars).stringValue
    }
}

private struct StatusPill: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

private struct DigitalReceiptView: View {
    let transaction: Transaction

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "receipt")
                        .font(.largeTitle)
                    Text(transaction.merchantName ?? transaction.description)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text(transaction.postedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            if let lineItems = transaction.receiptLineItems, !lineItems.isEmpty {
                Section("Items") {
                    ForEach(lineItems) { item in
                        DetailRow(label: item.name, value: AppDesign.money(item.amountCents))
                    }
                }
            }
            if let splits = transaction.categorySplits, !splits.isEmpty {
                Section("Categories") {
                    ForEach(splits) { split in
                        DetailRow(label: split.name, value: AppDesign.money(split.amountCents))
                    }
                }
            }
            Section {
                DetailRow(label: "Total", value: AppDesign.money(transaction.amountCents))
                    .font(.headline)
            }
        }
        .navigationTitle("Receipt")
        .navigationBarTitleDisplayMode(.inline)
    }
}
