import SwiftUI

struct TodayView: View {
    @Bindable var store: FinanceStore
    @State private var showingAddData = false
    @State private var showingProfile = false
    @State private var showingQuickCapture = false
    @State private var collapsedAccountSections: Set<AccountSection.Kind> = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    quickCaptureCard
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        MetricTile(title: "Net worth", value: AppDesign.money(store.netWorthCents), subtitle: "Across tracked accounts", systemImage: "sum")
                        MetricTile(title: "Spend", value: AppDesign.money(store.monthlySpendCents), subtitle: "This month", systemImage: "arrow.down.forward.circle")
                        MetricTile(title: "Available credit", value: AppDesign.money(store.availableCreditCents), subtitle: "Before utilization pressure", systemImage: "creditcard")
                        MetricTile(title: "Goals", value: String(store.goals.count), subtitle: "Active plans", systemImage: "sparkles")
                    }
                    accountsSection
                    upcomingSection
                }
                .padding(20)
            }
            .background(AppDesign.background)
            .navigationTitle("Budget")
	            .toolbar {
	                ToolbarItem(placement: .topBarLeading) {
	                    Button { showingProfile = true } label: {
	                        Image(systemName: "person.crop.circle")
	                            .font(.title3)
	                    }
	                    .accessibilityLabel("Profile")
	                }
	                ToolbarItemGroup(placement: .topBarTrailing) {
	                    Button { showingAddData = true } label: {
	                        Image(systemName: "plus")
	                    }
	                    Button { Task { await store.refresh() } } label: {
	                        Image(systemName: store.isLoading ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
	                    }
	                }
	            }
            .sheet(isPresented: $showingAddData) {
                AddDataView(store: store)
            }
            .sheet(isPresented: $showingProfile) {
                ProfileView(store: store)
            }
            .sheet(isPresented: $showingQuickCapture) {
                QuickSpendCaptureView(store: store)
            }
        }
    }

	    private var header: some View {
	        let planningBalance = store.accounts.filter { $0.type != "credit" }.reduce(0) { $0 + $1.balanceCents }
	        return VStack(alignment: .leading, spacing: 8) {
	            Text("Available to plan")
	                .font(.subheadline.weight(.medium))
	                .foregroundStyle(.secondary)
	            Text(AppDesign.money(planningBalance))
	                .font(.system(size: 44, weight: .semibold, design: .rounded))
	                .contentTransition(.numericText())
            Text(store.errorMessage ?? "Cashflow, credit timing, and budgets in one place.")
                .font(.footnote)
                .foregroundStyle(store.errorMessage == nil ? Color.secondary : Color.red)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var quickCaptureCard: some View {
        Button {
            showingQuickCapture = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "clock.badge.checkmark")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.green)
                    .frame(width: 44, height: 44)
                    .background(Color.green.opacity(0.16), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("Spent now")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Capture the exact time, then match it to Plaid later.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(AppDesign.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var accountsSection: some View {
        let sections = accountSections
        return VStack(alignment: .leading, spacing: 12) {
            Text("Accounts").font(.headline)
            if store.accounts.isEmpty {
                ContentUnavailableView("No Accounts Connected", systemImage: "building.columns", description: Text("Open Profile to connect a real bank account with Plaid or add a manual account."))
                    .padding(.vertical, 20)
                    .background(AppDesign.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            ForEach(sections) { section in
                AccountSectionView(
                    section: section,
                    isCollapsed: collapsedAccountSections.contains(section.kind),
                    icon: icon(for:),
                    transactions: accountTransactions
                ) {
                    withAnimation(.snappy(duration: 0.2)) {
                        if collapsedAccountSections.contains(section.kind) {
                            collapsedAccountSections.remove(section.kind)
                        } else {
                            collapsedAccountSections.insert(section.kind)
                        }
                    }
                }
            }
        }
    }

    private var accountTransactions: [Transaction] {
        Array(Dictionary(grouping: store.cashflowTrendTransactions + store.transactions, by: \.id).compactMap { $0.value.first })
    }

	    private var upcomingSection: some View {
	        VStack(alignment: .leading, spacing: 10) {
	            Text("Next decisions").font(.headline)
	            if store.goals.isEmpty {
	                ContentUnavailableView("No Plans Yet", systemImage: "flag", description: Text("Create a savings or debt payoff plan when you are ready."))
	                    .padding(.vertical, 20)
	                    .background(AppDesign.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
	            }
	            ForEach(store.goals.prefix(2)) { goal in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(goal.name).font(.body.weight(.medium))
                        ProgressView(value: min(Double(max(0, goal.currentCents)), Double(max(1, goal.targetCents))), total: Double(max(1, goal.targetCents)))
                    }
                    Text(AppDesign.money(goal.targetCents - goal.currentCents))
                        .font(.subheadline.weight(.semibold))
                }
                .padding(14)
                .background(AppDesign.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private func icon(for account: Account) -> String {
        switch account.type {
        case "credit": "creditcard"
        case "investment": "chart.pie"
        case "loan": "dollarsign.arrow.circlepath"
        default: "building.columns"
        }
    }

    private var accountSections: [AccountSection] {
        AccountSection.Kind.allCases.compactMap { kind in
            let accounts = store.accounts
                .filter { kind.contains($0) }
                .sorted { lhs, rhs in
                    if lhs.balanceCents == rhs.balanceCents {
                        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                    }
                    return abs(lhs.balanceCents) > abs(rhs.balanceCents)
                }
            guard !accounts.isEmpty else { return nil }
            return AccountSection(kind: kind, accounts: accounts)
        }
    }
}

private struct QuickSpendCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: FinanceStore
    @State private var amountText = ""
    @State private var merchantHint = ""
    @State private var occurredAt = Date()
    @State private var locationName = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Capture a timestamp")
                            .font(.largeTitle.bold())
                        Text("Use this right after a purchase. When Plaid sees the real transaction, Budget can match by amount, merchant, and timing.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 0) {
                        TextField("Amount, e.g. 12.48", text: $amountText)
                            .keyboardType(.decimalPad)
                            .font(.title2.weight(.semibold))
                            .padding(.vertical, 16)
                        Divider()
                        TextField("Merchant hint", text: $merchantHint)
                            .textInputAutocapitalization(.words)
                            .padding(.vertical, 16)
                        Divider()
                        TextField("Location note, optional", text: $locationName)
                            .textInputAutocapitalization(.words)
                            .padding(.vertical, 16)
                        Divider()
                        DatePicker("Time", selection: $occurredAt, displayedComponents: [.date, .hourAndMinute])
                            .padding(.vertical, 14)
                    }
                    .padding(.horizontal, 16)
                    .background(AppDesign.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                    Button {
                        Task {
                            await store.createQuickTransactionSignal(draft)
                            dismiss()
                        }
                    } label: {
                        Label("Save timestamp", systemImage: "checkmark")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isLoading)

                    if let latest = store.transactionSignals.first {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Latest signal")
                                .font(.headline)
                            Text("\(latest.merchantHint ?? "Spend") · \(latest.occurredAt.formatted(date: .abbreviated, time: .shortened))")
                                .foregroundStyle(.secondary)
                            if let amount = latest.amountCents {
                                Text(AppDesign.money(amount))
                                    .font(.title3.weight(.semibold))
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppDesign.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
                .padding(20)
            }
            .background(AppDesign.background)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var draft: QuickTransactionSignalDraft {
        var decimal: Decimal?
        if let value = Decimal(string: amountText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            decimal = -abs(value)
        }
        return QuickTransactionSignalDraft(amount: decimal, merchantHint: merchantHint, occurredAt: occurredAt, locationName: locationName)
    }
}

private struct AccountSection: Identifiable, Hashable {
    enum Kind: String, CaseIterable, Hashable, Identifiable {
        case bank
        case credit
        case other

        var id: String { rawValue }

        var title: String {
            switch self {
            case .bank: "Bank Accounts"
            case .credit: "Credit Cards"
            case .other: "Other Products"
            }
        }

        var subtitle: String {
            switch self {
            case .bank: "Checking, savings, cash, and wallet balances"
            case .credit: "Cards and revolving credit"
            case .other: "Investments, loans, and other financial products"
            }
        }

        var symbolName: String {
            switch self {
            case .bank: "building.columns"
            case .credit: "creditcard"
            case .other: "chart.pie"
            }
        }

        func contains(_ account: Account) -> Bool {
            let type = account.type.lowercased()
            let subtype = account.subtype?.lowercased() ?? ""
            switch self {
            case .bank:
                return type == "depository" || ["checking", "savings", "cash management", "wallet"].contains(subtype)
            case .credit:
                return type == "credit" || subtype.contains("credit")
            case .other:
                return !Kind.bank.contains(account) && !Kind.credit.contains(account)
            }
        }
    }

    let kind: Kind
    let accounts: [Account]

    var id: Kind { kind }

    var balanceCents: Int64 {
        accounts.reduce(0) { total, account in
            total + (account.isCredit ? account.normalizedCreditBalanceCents : account.balanceCents)
        }
    }
}

private struct AccountSectionView: View {
    let section: AccountSection
    let isCollapsed: Bool
    let icon: (Account) -> String
    let transactions: [Transaction]
    let toggle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 12) {
                    Image(systemName: section.kind.symbolName)
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 32, height: 32)
                        .background(.thinMaterial, in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(section.kind.title)
                            .font(.body.weight(.semibold))
                        Text("\(section.accounts.count) \(section.accounts.count == 1 ? "account" : "accounts")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(AppDesign.money(section.balanceCents))
                            .font(.body.weight(.semibold))
                            .monospacedDigit()
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    }
                }
                .contentShape(Rectangle())
                .padding(14)
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                VStack(spacing: 8) {
                    ForEach(section.accounts) { account in
                        NavigationLink {
                            AccountDetailView(account: account, transactions: transactions.filter { $0.accountID == account.id })
                        } label: {
                            AccountRow(account: account, iconName: icon(account))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(AppDesign.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct AccountRow: View {
    let account: Account
    let iconName: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.caption.weight(.semibold))
                .frame(width: 30, height: 30)
                .background(.thinMaterial, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(account.source.capitalized)
                    if let subtype = account.subtype, !subtype.isEmpty {
                        Text("•")
                        Text(subtype.capitalized)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if account.type == "credit", let close = account.statementCloseDay {
                    Text("Closes day \(close)")
                        .font(.caption2)
                        .foregroundStyle(AppDesign.warning)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                Text(AppDesign.money(account.isCredit ? account.normalizedCreditBalanceCents : account.balanceCents))
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                if account.isCredit, account.normalizedCreditLimitCents > 0 {
                    Text("\(AppDesign.money(account.normalizedAvailableCreditCents)) avail")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(.background.opacity(0.62), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .padding(.leading, 22)
    }
}

private struct AccountDetailView: View {
    let account: Account
    let transactions: [Transaction]
    @State private var selectedStyle = 0
    @State private var nickname = ""

    private var styleKey: String { "BudgetApp.accountStyle.\(account.id)" }
    private var nicknameKey: String { "BudgetApp.accountNickname.\(account.id)" }

    private var latestTransactions: [Transaction] {
        transactions.sorted { $0.postedAt > $1.postedAt }.prefix(20).map { $0 }
    }

    private var title: String {
        nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? account.displayName : nickname
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                AccountHeroCard(account: account, title: title, styleIndex: selectedStyle)

                if account.isCredit {
                    creditSummary
                } else {
                    cashSummary
                }

                customizationSection
                transactionsSection
            }
            .padding(20)
        }
        .background(AppDesign.background)
        .navigationTitle(account.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            selectedStyle = UserDefaults.standard.integer(forKey: styleKey)
            nickname = UserDefaults.standard.string(forKey: nicknameKey) ?? ""
        }
        .onChange(of: selectedStyle) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: styleKey)
        }
        .onChange(of: nickname) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: nicknameKey)
        }
    }

    private var creditSummary: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            AccountMetricCard(title: "Card Balance", value: AppDesign.money(account.normalizedCreditBalanceCents), subtitle: account.normalizedCreditLimitCents > 0 ? "\(AppDesign.money(account.normalizedAvailableCreditCents)) available" : "Current balance", tint: .primary)
            AccountMetricCard(title: "Credit Limit", value: account.normalizedCreditLimitCents > 0 ? AppDesign.money(account.normalizedCreditLimitCents) : "Unknown", subtitle: account.normalizedCreditLimitCents > 0 ? "\(Int((account.creditUtilization * 100).rounded()))% used" : "Not provided", tint: AppDesign.positive)
        }
    }

    private var cashSummary: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            AccountMetricCard(title: "Balance", value: AppDesign.money(account.balanceCents), subtitle: account.currencyCode, tint: .primary)
            AccountMetricCard(title: "Source", value: account.source.capitalized, subtitle: account.subtype?.capitalized ?? account.type.capitalized, tint: .secondary)
        }
    }

    private var customizationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Card appearance")
                .font(.headline)
            TextField(account.displayName, text: $nickname)
                .textFieldStyle(.plain)
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            HStack(spacing: 10) {
                ForEach(0..<AccountHeroCard.gradients.count, id: \.self) { index in
                    Button {
                        selectedStyle = index
                    } label: {
                        Circle()
                            .fill(AccountHeroCard.gradients[index])
                            .frame(width: 34, height: 34)
                            .overlay {
                                if selectedStyle == index {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.white)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(AppDesign.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var transactionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(account.isCredit ? "Latest Card Transactions" : "Latest Transactions")
                    .font(.title2.weight(.bold))
                Spacer()
                Text("\(transactions.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if latestTransactions.isEmpty {
                ContentUnavailableView("No Transactions", systemImage: "list.bullet.rectangle", description: Text("Transactions for this account will appear after the next sync."))
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(latestTransactions) { transaction in
                        AccountTransactionPreviewRow(transaction: transaction)
                        if transaction.id != latestTransactions.last?.id {
                            Divider().padding(.leading, 54).opacity(0.35)
                        }
                    }
                }
                .background(AppDesign.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        }
    }
}

private struct AccountHeroCard: View {
    static let gradients: [LinearGradient] = [
        LinearGradient(colors: [.purple, .orange, .blue.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [.black, .gray, .blue.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [.green, .mint, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [.pink, .red, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
    ]

    let account: Account
    let title: String
    let styleIndex: Int

    var body: some View {
        ZStack(alignment: .topLeading) {
            Self.gradients[styleIndex % Self.gradients.count]
            VStack(alignment: .leading) {
                Image(systemName: account.isCredit ? "creditcard.fill" : "building.columns.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text(title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text([account.source.capitalized, account.subtype?.capitalized ?? account.type.capitalized].joined(separator: " · "))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.78))
            }
            .padding(22)
        }
        .frame(height: 214)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 22, y: 12)
    }
}

private struct AccountMetricCard: View {
    let title: String
    let value: String
    let subtitle: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .monospacedDigit()
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AppDesign.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct AccountTransactionPreviewRow: View {
    let transaction: Transaction

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(transaction.amountCents < 0 ? AppDesign.warning.opacity(0.18) : AppDesign.positive.opacity(0.18))
                .frame(width: 42, height: 42)
                .overlay {
                    Image(systemName: transaction.amountCents < 0 ? "arrow.up.right" : "arrow.down.left")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(transaction.amountCents < 0 ? AppDesign.warning : AppDesign.positive)
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(transaction.merchantName ?? transaction.description)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(transaction.postedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(AppDesign.money(abs(transaction.amountCents)))
                .font(.body.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
