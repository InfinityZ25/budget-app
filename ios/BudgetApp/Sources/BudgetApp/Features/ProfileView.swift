import SwiftUI
import UniformTypeIdentifiers

struct ProfileView: View {
    @Bindable var store: FinanceStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingAddAccount = false

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

                Section("Connected accounts") {
                    ForEach(store.accounts) { account in
                        AccountManagementRow(account: account) {
                            Task { await store.removeAccount(account) }
                        }
                    }
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
                    Button {
                        Task { await store.syncPlaidTransactions() }
                    } label: {
                        Label("Sync Plaid transactions", systemImage: "arrow.triangle.2.circlepath")
                    }
                    if let summary = store.lastPlaidSyncSummary {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
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

private struct AccountManagementRow: View {
    let account: Account
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 34, height: 34)
                .background(.thinMaterial, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(account.name)
                    .font(.body.weight(.medium))
                Text("\(account.source.capitalized) · \(account.type.capitalized)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(AppDesign.money(account.balanceCents))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
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
                Text(status)
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
        status = "Requesting FinanceKit permission…"
        await store.importFinanceKitSnapshot()
        if let error = store.errorMessage {
            status = error
        } else {
            status = store.lastPlaidSyncSummary ?? "Apple Wallet data imported."
        }
        isImporting = false
    }
}
