import SwiftUI

struct AddDataView: View {
    @Bindable var store: FinanceStore
    @Environment(\.dismiss) private var dismiss
    @State private var mode = "Account"
    @State private var accountDraft = ManualAccountDraft()
    @State private var transactionDraft = ManualTransactionDraft()
    @State private var goalDraft = GoalDraft()
    @State private var statementDraft = StatementDraft()

    private let modes = ["Account", "Transaction", "Goal", "Statement"]

    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: $mode) {
                    ForEach(modes, id: \.self) { Text($0) }
                }
                .pickerStyle(.segmented)

                switch mode {
                case "Transaction": transactionForm
                case "Goal": goalForm
                case "Statement": statementForm
                default: accountForm
                }
            }
            .navigationTitle("Add")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save(); dismiss() } }
                }
            }
        }
    }

    private var accountForm: some View {
        Section("Account") {
            TextField("Name", text: $accountDraft.name)
            Picker("Type", selection: $accountDraft.type) {
                Text("Checking").tag("depository")
                Text("Credit Card").tag("credit")
                Text("Loan").tag("loan")
                Text("Investment").tag("investment")
            }
            TextField("Subtype", text: $accountDraft.subtype)
            MoneyField(title: "Balance", cents: $accountDraft.balanceCents)
            if accountDraft.type == "credit" {
                MoneyField(title: "Credit limit", cents: $accountDraft.creditLimitCents)
                Stepper("Statement closes day \(accountDraft.statementCloseDay)", value: $accountDraft.statementCloseDay, in: 0...31)
                Stepper("Payment due day \(accountDraft.paymentDueDay)", value: $accountDraft.paymentDueDay, in: 0...31)
            }
        }
    }

    private var transactionForm: some View {
        Section("Transaction") {
            Picker("Account", selection: $transactionDraft.accountID) {
                Text("Select").tag("")
                ForEach(store.accounts) { account in
                    Text(account.name).tag(account.id)
                }
            }
            TextField("Merchant", text: $transactionDraft.merchantName)
            TextField("Description", text: $transactionDraft.description)
            MoneyField(title: "Amount", cents: $transactionDraft.amountCents)
            TextField("Category", text: $transactionDraft.categoryName)
            TextField("Notes", text: $transactionDraft.notes, axis: .vertical)
        }
    }

    private var goalForm: some View {
        Section("Plan") {
            TextField("Name", text: $goalDraft.name)
            Picker("Type", selection: $goalDraft.type) {
                Text("Savings").tag("savings")
                Text("Debt payoff").tag("debt_payoff")
            }
            MoneyField(title: "Target", cents: $goalDraft.targetCents)
            MoneyField(title: "Current", cents: $goalDraft.currentCents)
            Stepper("Priority \(goalDraft.priority)", value: $goalDraft.priority, in: 1...10)
        }
    }

    private var statementForm: some View {
        Section("Statement") {
            Picker("Account", selection: $statementDraft.accountID) {
                Text("Select").tag("")
                ForEach(store.accounts) { account in
                    Text(account.name).tag(account.id)
                }
            }
            TextField("File name", text: $statementDraft.fileName)
            DatePicker("Start", selection: $statementDraft.statementStart, displayedComponents: .date)
            DatePicker("End", selection: $statementDraft.statementEnd, displayedComponents: .date)
            Stepper("Imported transactions \(statementDraft.importedCount)", value: $statementDraft.importedCount, in: 0...500)
        }
    }

    private func save() async {
        switch mode {
        case "Transaction": await store.addManualTransaction(transactionDraft)
        case "Goal": await store.addGoal(goalDraft)
        case "Statement": await store.addStatement(statementDraft)
        default: await store.addManualAccount(accountDraft)
        }
    }
}

struct MoneyField: View {
    let title: String
    @Binding var cents: Int64
    @State private var text = ""

    var body: some View {
        TextField(title, text: Binding(
            get: { text.isEmpty ? decimalString : text },
            set: { newValue in
                text = newValue
                let normalized = newValue.replacingOccurrences(of: "$", with: "")
                if let value = Decimal(string: normalized) {
                    cents = NSDecimalNumber(decimal: value * 100).int64Value
                }
            }
        ))
        .onAppear { text = decimalString }
    }

    private var decimalString: String {
        NSDecimalNumber(decimal: cents.dollars).stringValue
    }
}
