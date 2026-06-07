import SwiftUI
import UniformTypeIdentifiers

struct ProfileView: View {
    @Bindable var store: FinanceStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingAddAccount = false
    @State private var collapsedAccountSections: Set<ProfileAccountSection.Kind> = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 52))
                            .symbolRenderingMode(.hierarchical)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(store.authDisplayName)
                                .font(.title3.weight(.semibold))
                            Text(store.authEmail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                }

                Section("Account") {
                    if store.isSignedIn {
                        Label("Signed in with WorkOS", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        if let authMigrationMessage = store.authMigrationMessage {
                            Label(authMigrationMessage, systemImage: "arrow.triangle.2.circlepath.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            Task { await store.recoverWorkOSData() }
                        } label: {
                            Label("Recover previous linked accounts", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(store.isLoading)
                        Button(role: .destructive) {
                            store.signOut()
                        } label: {
                            Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    } else {
                        Button {
                            Task { await store.signInWithWorkOS() }
                        } label: {
                            Label("Sign in with WorkOS", systemImage: "person.badge.key")
                        }
                        Text("Uses AuthKit, then links your Plaid, manual, statement, chat, and future FinanceKit data to your user.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    ProfileDataHealthCard(store: store)
                    Button {
                        Task { await store.syncPlaidTransactions() }
                    } label: {
                        Label(store.isSyncingPlaid ? "Syncing Plaid…" : "Sync latest Plaid transactions", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(store.isSyncingPlaid)
                    Button {
                        Task { await store.syncPlaidTransactions(backfill: true) }
                    } label: {
                        Label("Backfill 12 months from Plaid", systemImage: "clock.arrow.circlepath")
                    }
                    .disabled(store.isSyncingPlaid)
                    if let summary = store.lastPlaidSyncSummary {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let error = store.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Sync")
                } footer: {
                    Text("Latest sync is incremental and fast. Historical backfill intentionally scans up to 12 months and may take longer.")
                }

                Section("Connected accounts") {
                    if store.accounts.isEmpty {
                        ContentUnavailableView("No Accounts", systemImage: "building.columns", description: Text("Connect Plaid, import Wallet data, or add a manual account."))
                            .padding(.vertical, 8)
                    }
                    ForEach(accountSections) { section in
                        ProfileAccountSectionView(
                            section: section,
                            isCollapsed: collapsedAccountSections.contains(section.kind)
                        ) {
                            withAnimation(.snappy(duration: 0.2)) {
                                if collapsedAccountSections.contains(section.kind) {
                                    collapsedAccountSections.remove(section.kind)
                                } else {
                                    collapsedAccountSections.insert(section.kind)
                                }
                            }
                        } remove: { account in
                            Task { await store.removeAccount(account) }
                        }
                    }
                }

                Section("Add and import") {
                    Button {
                        showingAddAccount = true
                    } label: {
                        Label("Add manual account", systemImage: "plus.circle")
                    }
                    NavigationLink {
                        PlaidConnectView(store: store)
                    } label: {
                        Label("Connect bank with Plaid", systemImage: "link.circle")
                    }
                    NavigationLink {
                        FinanceKitConnectView(store: store)
                    } label: {
                        Label("Apple Wallet and Apple Card", systemImage: "wallet.pass")
                    }
                    NavigationLink {
                        StatementImportView(store: store)
                    } label: {
                        Label("Import bank statement", systemImage: "square.and.arrow.down")
                    }
                }

                Section("Statements") {
                    if store.statements.isEmpty {
                        Text("No statements tracked yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.statements) { statement in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(statement.fileName)
                                .font(.body.weight(.medium))
                            Text("\(statement.importedCount) transactions imported")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Profile")
            .toolbar {
                Button("Done") { dismiss() }
            }
            .sheet(isPresented: $showingAddAccount) {
                AddDataView(store: store)
            }
        }
    }

    private var accountSections: [ProfileAccountSection] {
        ProfileAccountSection.Kind.allCases.compactMap { kind in
            let accounts = store.accounts
                .filter { kind.contains($0) }
                .sorted { lhs, rhs in
                    if lhs.balanceCents == rhs.balanceCents {
                        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                    }
                    return abs(lhs.balanceCents) > abs(rhs.balanceCents)
                }
            guard !accounts.isEmpty else { return nil }
            return ProfileAccountSection(kind: kind, accounts: accounts)
        }
    }
}

private struct ProfileDataHealthCard: View {
    let store: FinanceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Data health", systemImage: "waveform.path.ecg")
                .font(.headline)
            HStack(spacing: 10) {
                ProfileHealthMetric(title: "Accounts", value: "\(store.accounts.count)", symbol: "building.columns")
                ProfileHealthMetric(title: "Transactions", value: "\(store.cashflowTrendTransactions.count)", symbol: "list.bullet.rectangle")
                ProfileHealthMetric(title: "Pending", value: "\(store.pendingTransactionCount)", symbol: "clock.badge")
            }
            VStack(spacing: 8) {
                ProfileHealthRow(label: "Sources", value: store.accountSourceSummary)
                ProfileHealthRow(label: "Profile", value: store.isSignedIn ? "WorkOS" : "Local")
                ProfileHealthRow(label: "Last refresh", value: lastRefreshText)
            }
        }
        .padding(.vertical, 6)
    }

    private var lastRefreshText: String {
        guard let date = store.lastRefreshedAt else { return "Not refreshed yet" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct ProfileHealthMetric: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct ProfileHealthRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.primary)
        }
        .font(.caption)
    }
}

struct StatementImportView: View {
    @Bindable var store: FinanceStore
    @State private var accountID = ""
    @State private var fileName = "statement.csv"
    @State private var csvText = "date,description,amount\n2026-06-01,Grocery Store,-42.18"
    @State private var showingImporter = false

    var body: some View {
        Form {
            Picker("Account", selection: $accountID) {
                Text("Select").tag("")
                ForEach(store.accounts) { account in
                    Text(account.name).tag(account.id)
                }
            }
            Section("PDF") {
                Button("Choose PDF statement") {
                    showingImporter = true
                }
                Text("Supports bank PDF statements. Chase and Capital One parsers are being trained from your examples.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("CSV fallback") {
                TextField("File name", text: $fileName)
                TextField("CSV", text: $csvText, axis: .vertical)
                    .lineLimit(8...16)
                Button("Import CSV") {
                    Task { await store.importStatementCSV(accountID: accountID, fileName: fileName, csv: csvText) }
                }
                .disabled(accountID.isEmpty || csvText.isEmpty)
            }
        }
        .navigationTitle("Import Statement")
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.pdf]) { result in
            guard case let .success(url) = result else { return }
            Task { await store.importStatementPDF(accountID: accountID, fileURL: url) }
        }
    }
}

private struct ProfileAccountSection: Identifiable, Hashable {
    enum Kind: String, CaseIterable, Hashable, Identifiable {
        case bank
        case credit
        case other

        var id: String { rawValue }

        var title: String {
            switch self {
            case .bank: "Bank accounts"
            case .credit: "Credit cards"
            case .other: "Other products"
            }
        }

        var subtitle: String {
            switch self {
            case .bank: "Checking, savings, Apple Cash, and wallets"
            case .credit: "Cards and revolving credit"
            case .other: "Investments, loans, and other balances"
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
        accounts.reduce(0) { $0 + $1.balanceCents }
    }
}

private struct ProfileAccountSectionView: View {
    let section: ProfileAccountSection
    let isCollapsed: Bool
    let toggle: () -> Void
    let remove: (Account) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 12) {
                    Image(systemName: section.kind.symbolName)
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 34, height: 34)
                        .background(.thinMaterial, in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(section.kind.title)
                            .font(.body.weight(.semibold))
                        Text(section.kind.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(AppDesign.money(section.balanceCents))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                        HStack(spacing: 4) {
                            Text("\(section.accounts.count)")
                            Image(systemName: "chevron.down")
                                .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                VStack(spacing: 0) {
                    Divider().opacity(0.35).padding(.top, 12)
                    ForEach(section.accounts) { account in
                        AccountManagementRow(account: account) {
                            remove(account)
                        }
                        if account.id != section.accounts.last?.id {
                            Divider().padding(.leading, 46).opacity(0.35)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 8)
    }
}

private struct AccountManagementRow: View {
    let account: Account
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 34, height: 34)
                .background(.thinMaterial, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(account.displayName)
                    .font(.body.weight(.medium))
                Text("\(account.source.capitalized) · \(account.type.capitalized)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(AppDesign.money(account.isCredit ? account.normalizedCreditBalanceCents : account.balanceCents))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                if account.isCredit, account.normalizedCreditLimitCents > 0 {
                    Text("\(AppDesign.money(account.normalizedCreditLimitCents)) limit")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                remove()
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    private var icon: String {
        switch account.type {
        case "credit": "creditcard"
        case "investment": "chart.pie"
        case "loan": "banknote"
        default: "building.columns"
        }
    }
}

struct PlaidConnectView: View {
    @Bindable var store: FinanceStore
    @State private var status = "Ready to connect a production Plaid account."
    @State private var isConnecting = false
#if canImport(LinkKit)
    @State private var plaidPresenter = PlaidLinkPresenter()
#endif

    var body: some View {
        List {
            Section {
                Label("Plaid Link", systemImage: "link")
                    .font(.headline)
                Text("Connect a real bank account through Plaid production. Your credentials stay inside Plaid Link; this app only receives account and transaction data through the backend.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button {
                    Task { await openPlaidLink() }
                } label: {
                    Label(isConnecting ? "Connecting…" : "Connect Bank Account", systemImage: "building.columns")
                }
                .disabled(isConnecting)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Connect Bank")
    }

    private func openPlaidLink() async {
        isConnecting = true
        status = "Creating secure Plaid Link session…"
        do {
            let response = try await APIClient.local.createPlaidLinkToken()
#if canImport(LinkKit)
            status = "Opening Plaid Link…"
            await MainActor.run {
                plaidPresenter.open(linkToken: response.linkToken) { publicToken in
                    status = "Exchanging Plaid public token…"
                    Task {
                        await store.connectPlaid(publicToken: publicToken)
                        status = store.errorMessage ?? "Bank account connected."
                        isConnecting = false
                    }
                } onExit: { message in
                    status = message
                    isConnecting = false
                }
            }
#else
            status = "Received production Link token expiring \(response.expiration.formatted(date: .abbreviated, time: .shortened)), but LinkKit is not available in this build."
            isConnecting = false
#endif
        } catch {
            status = error.localizedDescription
            isConnecting = false
        }
    }
}

struct FinanceKitConnectView: View {
    @Bindable var store: FinanceStore
    @State private var status = FinanceKitImporter.availabilityMessage
    @State private var isImporting = false

    var body: some View {
        List {
            Section {
                Label("FinanceKit", systemImage: "wallet.pass")
                    .font(.headline)
                Text("Imports eligible Apple Wallet financial accounts and transactions directly from the on-device FinanceKit store after you grant permission.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button {
                    Task { await importWalletData() }
                } label: {
                    Label(isImporting ? "Importing…" : "Import Apple Wallet Data", systemImage: "square.and.arrow.down")
                }
                .disabled(isImporting || !FinanceKitImporter.canUseNativeFinanceKit)
                Text(isImporting ? store.financeKitImportStatus ?? status : status)
                    .font(.caption)
                    .foregroundStyle(FinanceKitImporter.canUseNativeFinanceKit ? Color.secondary : Color.orange)
            }
            Section("Required") {
                Label("iPhone on iOS 17.4 or later", systemImage: "iphone")
                Label("Apple Developer organization account", systemImage: "person.2.badge.gearshape")
                Label("FinanceKit managed entitlement", systemImage: "checkmark.seal")
                Label("NSFinancialDataUsageDescription", systemImage: "doc.text")
            }
        }
        .navigationTitle("Apple Wallet")
    }

    private func importWalletData() async {
        isImporting = true
        store.financeKitImportStatus = "Requesting FinanceKit permission…"
        status = "Requesting FinanceKit permission…"
        await store.importFinanceKitSnapshot()
        if let error = store.errorMessage {
            status = error
        } else {
            status = store.lastPlaidSyncSummary ?? "Apple Wallet data imported."
        }
        store.financeKitImportStatus = nil
        isImporting = false
    }
}
