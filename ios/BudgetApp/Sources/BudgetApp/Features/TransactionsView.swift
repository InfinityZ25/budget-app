import SwiftUI

struct TransactionsView: View {
    @Bindable var store: FinanceStore
    @State private var draftFilter = TransactionFilter()
    @State private var showingFilters = false

    var body: some View {
        NavigationStack {
            Group {
                if store.transactions.isEmpty {
                    ContentUnavailableView {
                        Label("No Transactions", systemImage: "list.bullet.rectangle")
                    } description: {
                        Text("Connect a bank, import a statement, adjust your filters, or refresh after a sync.")
                    } actions: {
                        Button("Refresh Activity") {
                            Task { await refreshActivity() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .refreshable { await refreshActivity() }
                } else {
                    List(store.transactions) { transaction in
                        NavigationLink(value: transaction) {
                            TransactionRow(transaction: transaction, accountName: accountName(for: transaction))
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
                    Button {
                        showingFilters = true
                    } label: {
                        Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .sheet(isPresented: $showingFilters) {
                TransactionFilterSheet(filter: $draftFilter) {
                    showingFilters = false
                    Task { await store.applyTransactionFilter(draftFilter) }
                }
            }
            .navigationDestination(for: Transaction.self) { transaction in
                TransactionDetailView(store: store, transaction: transaction, account: store.accounts.first { $0.id == transaction.accountID })
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

    private func accountName(for transaction: Transaction) -> String {
        store.accounts.first { $0.id == transaction.accountID }?.name ?? transaction.source.capitalized
    }
}

struct TransactionRow: View {
    let transaction: Transaction
    let accountName: String

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
            }
            Spacer()
            Text(AppDesign.money(transaction.amountCents))
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(transaction.amountCents < 0 ? .primary : AppDesign.positive)
        }
        .padding(.vertical, 4)
    }
}

private struct TransactionFilterSheet: View {
    @Binding var filter: TransactionFilter
    let apply: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Text") {
                    TextField("Merchant, description, notes, location", text: $filter.searchText)
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
    @State private var showingCategoryEditor = false

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
                DetailRow(label: "Date", value: transaction.postedAt.formatted(date: .complete, time: .shortened))
                DetailRow(label: "Source", value: transaction.source.capitalized)
                DetailRow(label: "Currency", value: transaction.currencyCode)
                if let location = transaction.locationName, !location.isEmpty {
                    DetailRow(label: "Location", value: location)
                }
                DetailRow(label: "Description", value: transaction.description)
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
