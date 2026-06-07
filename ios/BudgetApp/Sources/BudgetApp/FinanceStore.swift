import Foundation
import Observation

@MainActor
@Observable
final class FinanceStore {
    private static let assistantConversationsKey = "BudgetApp.assistantConversations"

    var accounts: [Account] = []
    var transactions: [Transaction] = []
    var cashflowTrendTransactions: [Transaction] = []
    var budgets: [Budget] = []
    var goals: [Goal] = []
    var statements: [StatementUpload] = []
    var projection: [CashflowProjection] = []
    var assistantConversations: [AssistantConversation] = []
    var selectedAssistantConversationID: String?
    var assistantMessages: [AssistantMessage] = []
    var isLoading = false
    var errorMessage: String?
    var lastPlaidSyncSummary: String?
    var assistantTypingStatus: String?
    var transactionFilter = TransactionFilter()
    var authDisplayName = "Local Profile"
    var authEmail = "Not signed in"
    var isSignedIn = false

    private var api: APIClient
    private let authSession: BudgetAuthSession
    private var activeVoiceUserMessageID: String?
    private var activeVoiceAssistantMessageID: String?

    init(api: APIClient = .local) {
        self.api = api
        self.authSession = BudgetAuthSession(api: api)
        refreshAuthState()
        loadAssistantConversations()
    }

    var netWorthCents: Int64 {
        accounts.reduce(0) { $0 + $1.balanceCents }
    }

    var monthlySpendCents: Int64 {
        -transactions.filter { $0.amountCents < 0 }.reduce(0) { $0 + $1.amountCents }
    }

    var availableCreditCents: Int64 {
        accounts.reduce(0) { total, account in
            guard account.type == "credit", let limit = account.creditLimitCents else { return total }
            return total + max(0, limit + account.balanceCents)
        }
    }

    var categoryNames: [String] {
        let budgetNames = budgets.map(\.categoryName)
        let transactionNames = (transactions + cashflowTrendTransactions)
            .flatMap { $0.categorySplits ?? [] }
            .map(\.name)
        return Array(Set((budgetNames + transactionNames).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func refresh() async {
        if !isSignedIn {
            refreshAuthState()
        }
        isLoading = true
        errorMessage = nil
        do {
            async let fetchedAccounts = api.accounts()
            async let fetchedTransactions = api.transactions(filter: transactionFilter)
            async let fetchedCashflowTrendTransactions = api.transactions(limit: 1000, filter: TransactionFilter())
            async let fetchedBudgets = api.budgets()
            async let fetchedGoals = api.goals()
            async let fetchedStatements = api.statements()
            accounts = try await fetchedAccounts
            transactions = try await fetchedTransactions
            cashflowTrendTransactions = try await fetchedCashflowTrendTransactions
            budgets = try await fetchedBudgets
            goals = try await fetchedGoals
            statements = try await fetchedStatements
            await loadAssistantConversationsFromServer()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func signInWithWorkOS() async {
        isLoading = true
        errorMessage = nil
        do {
            let session = try await authSession.signIn()
            api.userID = session.userID
            refreshAuthState()
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func signOut() {
        authSession.signOut()
        api.userID = "local-user"
        refreshAuthState()
        accounts = []
        transactions = []
        cashflowTrendTransactions = []
        budgets = []
        goals = []
        statements = []
        projection = []
    }

    func addManualAccount(_ draft: ManualAccountDraft) async {
        await performMutation {
            let account = try await api.createManualAccount(draft)
            accounts.append(account)
        }
    }

    func connectPlaid(publicToken: String) async {
        await performMutation {
            let result = try await api.exchangePlaidPublicToken(publicToken)
            for account in result.accounts where !accounts.contains(where: { $0.id == account.id }) {
                accounts.append(account)
            }
            await refresh()
        }
    }

    func syncPlaidTransactions() async {
        await performMutation {
            let result = try await api.syncPlaidItems()
            lastPlaidSyncSummary = "Synced \(result.items) item\(result.items == 1 ? "" : "s"): \(result.added) new, \(result.modified) updated, \(result.removed) removed, \(result.backfilled) checked from history."
            await refresh()
        }
    }

    func removeAccount(_ account: Account) async {
        await performMutation {
            try await api.deleteAccount(id: account.id)
            accounts.removeAll { $0.id == account.id }
            transactions.removeAll { $0.accountID == account.id }
        }
    }

    func addManualTransaction(_ draft: ManualTransactionDraft) async {
        await performMutation {
            let transaction = try await api.createManualTransaction(draft)
            transactions.insert(transaction, at: 0)
            cashflowTrendTransactions.insert(transaction, at: 0)
        }
    }

    func updateTransactionCategory(_ transaction: Transaction, categoryName: String, applyToSimilar: Bool) async {
        await performMutation {
            let updated = try await api.updateTransactionCategory(id: transaction.id, categoryName: categoryName, applyToSimilar: applyToSimilar)
            replaceTransaction(updated)
            if applyToSimilar {
                await refresh()
            } else {
                budgets = try await api.budgets()
            }
        }
    }

    func addGoal(_ draft: GoalDraft) async {
        await performMutation {
            let goal = try await api.createGoal(draft)
            goals.append(goal)
        }
    }

    private func replaceTransaction(_ transaction: Transaction) {
        if let index = transactions.firstIndex(where: { $0.id == transaction.id }) {
            transactions[index] = transaction
        }
        if let index = cashflowTrendTransactions.firstIndex(where: { $0.id == transaction.id }) {
            cashflowTrendTransactions[index] = transaction
        }
    }

    func addBudget(_ draft: BudgetDraft) async {
        await performMutation {
            let budget = try await api.createBudget(draft)
            budgets.append(budget)
        }
    }

    func updateBudget(_ budget: Budget, draft: BudgetDraft) async {
        await performMutation {
            let updated = try await api.updateBudget(id: budget.id, draft: draft)
            if let index = budgets.firstIndex(where: { $0.id == budget.id }) {
                budgets[index] = updated
            } else {
                budgets.append(updated)
            }
        }
    }

    func deleteBudget(_ budget: Budget) async {
        await performMutation {
            try await api.deleteBudget(id: budget.id)
            budgets.removeAll { $0.id == budget.id }
        }
    }

    func applyTransactionFilter(_ filter: TransactionFilter) async {
        transactionFilter = filter
        await performMutation {
            transactions = try await api.transactions(filter: filter)
        }
    }

    func addStatement(_ draft: StatementDraft) async {
        await performMutation {
            let statement = try await api.createStatement(draft)
            statements.insert(statement, at: 0)
        }
    }

    func importStatementCSV(accountID: String, fileName: String, csv: String) async {
        await performMutation {
            let result = try await api.importStatementCSV(accountID: accountID, fileName: fileName, csv: csv)
            statements.insert(result.statement, at: 0)
            await refresh()
        }
    }

    func importStatementPDF(accountID: String, fileURL: URL) async {
        await performMutation {
            let result = try await api.importStatementPDF(accountID: accountID, fileURL: fileURL)
            statements.insert(result.statement, at: 0)
            await refresh()
        }
    }

    func generateBudgets() async {
        await performMutation {
            budgets = try await api.autoGenerateBudgets()
        }
    }

    func askBudgetAssistant(_ message: String) async throws -> BudgetAssistantReply {
        let reply = try await api.askBudgetAssistant(message)
        async let fetchedBudgets = api.budgets()
        async let fetchedTransactions = api.transactions(filter: transactionFilter)
        async let fetchedCashflowTrendTransactions = api.transactions(limit: 1000, filter: TransactionFilter())
        budgets = try await fetchedBudgets
        transactions = try await fetchedTransactions
        cashflowTrendTransactions = try await fetchedCashflowTrendTransactions
        return reply
    }

    func projectNextMonth() async {
        let events = defaultProjectionEvents()
        await performMutation {
            projection = try await api.projectCashflow(startingBalanceCents: accounts.filter { $0.type != "credit" }.reduce(0) { $0 + $1.balanceCents }, events: events)
        }
    }

    func importFinanceKitSnapshot() async {
        await performMutation {
            let snapshot = try await FinanceKitImporter.loadSnapshot()
            let result = try await api.importFinanceKit(accounts: snapshot.accounts, transactions: snapshot.transactions)
            lastPlaidSyncSummary = "Imported \(result.accounts) Apple Wallet account\(result.accounts == 1 ? "" : "s") and \(result.transactions) transaction\(result.transactions == 1 ? "" : "s")."
            await refresh()
        }
    }

    func askAssistant(_ message: String) async {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        finishVoiceAssistantMessage(status: nil)
        activeVoiceUserMessageID = nil
        errorMessage = nil
        assistantTypingStatus = "Assistant is typing…"

        do {
            let conversationID = try await ensureAssistantConversation()
            assistantMessages.append(AssistantMessage(role: "user", content: trimmed, createdAt: .now))
            assistantMessages.append(AssistantMessage(role: "assistant", content: "", createdAt: .now, isStreaming: true))
            let assistantID = assistantMessages[assistantMessages.count - 1].id
            saveCurrentAssistantConversation()

            for try await event in api.streamAssistant(trimmed, conversationID: conversationID) {
                switch event {
                case let .status(message):
                    assistantTypingStatus = message
                case let .token(delta):
                    if let index = assistantMessages.firstIndex(where: { $0.id == assistantID }) {
                        assistantMessages[index].content += delta
                        saveCurrentAssistantConversation()
                    }
                case let .notice(message):
                    errorMessage = message
                case let .done(reply):
                    if let serverConversationID = reply.conversationID, serverConversationID != selectedAssistantConversationID {
                        replaceSelectedAssistantConversationID(with: serverConversationID)
                    }
                    if let index = assistantMessages.firstIndex(where: { $0.id == assistantID }) {
                        assistantMessages[index].content = reply.reply
                        assistantMessages[index].createdAt = reply.createdAt
                        assistantMessages[index].isStreaming = false
                        saveCurrentAssistantConversation()
                    }
                    assistantTypingStatus = "Finished typing"
                }
            }
            if let index = assistantMessages.firstIndex(where: { $0.id == assistantID }), assistantMessages[index].isStreaming {
                assistantMessages[index].isStreaming = false
                assistantTypingStatus = "Finished typing"
                saveCurrentAssistantConversation()
            }
            Task { await loadAssistantConversationsFromServer(preserveSelection: true) }
        } catch {
            let assistantID = assistantMessages.last(where: { $0.role == "assistant" && $0.isStreaming })?.id
            if let index = assistantMessages.firstIndex(where: { $0.id == assistantID }), assistantMessages[index].content.isEmpty {
                assistantMessages.remove(at: index)
                saveCurrentAssistantConversation()
            }
            assistantTypingStatus = nil
            errorMessage = error.localizedDescription
        }
    }

    func appendVoiceUserMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        finishActiveVoiceAssistantMessage()
        if let activeVoiceUserMessageID,
           let index = assistantMessages.firstIndex(where: { $0.id == activeVoiceUserMessageID }) {
            assistantMessages[index].content = trimmed
            assistantMessages[index].createdAt = .now
        } else {
            let message = AssistantMessage(role: "user", content: trimmed, createdAt: .now)
            assistantMessages.append(message)
            activeVoiceUserMessageID = message.id
        }
        assistantTypingStatus = "Assistant is speaking…"
        saveCurrentAssistantConversation()
    }

    func appendVoiceAssistantDelta(_ delta: String) {
        guard !delta.isEmpty else { return }
        activeVoiceUserMessageID = nil
        let messageID: String
        if let activeVoiceAssistantMessageID {
            messageID = activeVoiceAssistantMessageID
        } else {
            let message = AssistantMessage(role: "assistant", content: "", createdAt: .now, isStreaming: true)
            assistantMessages.append(message)
            activeVoiceAssistantMessageID = message.id
            messageID = message.id
        }
        if let index = assistantMessages.firstIndex(where: { $0.id == messageID }) {
            assistantMessages[index].content += delta
            saveCurrentAssistantConversation()
        }
    }

    func finishVoiceAssistantMessage(status: String? = "Finished speaking") {
        activeVoiceUserMessageID = nil
        finishActiveVoiceAssistantMessage()
        assistantTypingStatus = status
    }

    private func finishActiveVoiceAssistantMessage() {
        if let activeVoiceAssistantMessageID,
           let index = assistantMessages.firstIndex(where: { $0.id == activeVoiceAssistantMessageID }) {
            assistantMessages[index].isStreaming = false
            if assistantMessages[index].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                assistantMessages.remove(at: index)
            }
            saveCurrentAssistantConversation()
        }
        activeVoiceAssistantMessageID = nil
    }

    func createNewAssistantConversation() async {
        finishVoiceAssistantMessage(status: nil)
        saveCurrentAssistantConversation()
        do {
            let conversation = try await api.createAssistantConversation()
            assistantConversations.removeAll { $0.id == conversation.id }
            assistantConversations.insert(conversation, at: 0)
            selectedAssistantConversationID = conversation.id
            assistantMessages = []
            persistAssistantConversations()
        } catch {
            errorMessage = error.localizedDescription
            let conversation = AssistantConversation(title: "New conversation")
            assistantConversations.insert(conversation, at: 0)
            selectedAssistantConversationID = conversation.id
            assistantMessages = []
            persistAssistantConversations()
        }
    }

    func selectAssistantConversation(_ conversation: AssistantConversation) async {
        finishVoiceAssistantMessage(status: nil)
        saveCurrentAssistantConversation()
        selectedAssistantConversationID = conversation.id
        do {
            assistantMessages = try await api.assistantMessages(conversationID: conversation.id)
            saveCurrentAssistantConversation()
        } catch {
            assistantMessages = conversation.messages
            errorMessage = error.localizedDescription
        }
        assistantTypingStatus = nil
        activeVoiceUserMessageID = nil
        activeVoiceAssistantMessageID = nil
    }

    func deleteAssistantConversation(_ conversation: AssistantConversation) async {
        do {
            try await api.deleteAssistantConversation(id: conversation.id)
        } catch {
            errorMessage = error.localizedDescription
        }
        assistantConversations.removeAll { $0.id == conversation.id }
        if selectedAssistantConversationID == conversation.id {
            selectedAssistantConversationID = assistantConversations.first?.id
            assistantMessages = assistantConversations.first?.messages ?? []
        }
        if assistantConversations.isEmpty {
            await createNewAssistantConversation()
        } else {
            persistAssistantConversations()
        }
    }

    private func performMutation(_ operation: () async throws -> Void) async {
        errorMessage = nil
        do {
            try await operation()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadAssistantConversations() {
        if
            let data = UserDefaults.standard.data(forKey: Self.assistantConversationsKey),
            let decoded = try? JSONDecoder().decode([AssistantConversation].self, from: data),
            !decoded.isEmpty
        {
            assistantConversations = decoded.sorted { $0.updatedAt > $1.updatedAt }
        } else {
            assistantConversations = [AssistantConversation(title: "New conversation")]
        }
        selectedAssistantConversationID = assistantConversations.first?.id
        assistantMessages = assistantConversations.first?.messages ?? []
    }

    private func loadAssistantConversationsFromServer(preserveSelection: Bool = false) async {
        do {
            let remoteConversations = try await api.assistantConversations()
            guard !remoteConversations.isEmpty else {
                if assistantConversations.isEmpty {
                    let conversation = try await api.createAssistantConversation()
                    assistantConversations = [conversation]
                    selectedAssistantConversationID = conversation.id
                    assistantMessages = []
                    persistAssistantConversations()
                }
                return
            }
            let previousSelection = selectedAssistantConversationID
            assistantConversations = remoteConversations.map { remote in
                var conversation = remote
                if let cached = assistantConversations.first(where: { $0.id == remote.id }) {
                    conversation.messages = cached.messages
                }
                return conversation
            }
            if preserveSelection, let previousSelection, assistantConversations.contains(where: { $0.id == previousSelection }) {
                selectedAssistantConversationID = previousSelection
            } else {
                selectedAssistantConversationID = assistantConversations.first?.id
                if let selected = assistantConversations.first {
                    assistantMessages = try await api.assistantMessages(conversationID: selected.id)
                    saveCurrentAssistantConversation()
                }
            }
            persistAssistantConversations()
        } catch {
            if assistantConversations.isEmpty {
                loadAssistantConversations()
            }
        }
    }

    private func ensureAssistantConversation() async throws -> String {
        if let selectedAssistantConversationID,
           !selectedAssistantConversationID.contains("-"),
           assistantConversations.contains(where: { $0.id == selectedAssistantConversationID }) {
            return selectedAssistantConversationID
        }
        let conversation = try await api.createAssistantConversation()
        assistantConversations.insert(conversation, at: 0)
        selectedAssistantConversationID = conversation.id
        assistantMessages = []
        persistAssistantConversations()
        return conversation.id
    }

    private func replaceSelectedAssistantConversationID(with serverConversationID: String) {
        guard let selectedAssistantConversationID, selectedAssistantConversationID != serverConversationID else { return }
        if let index = assistantConversations.firstIndex(where: { $0.id == selectedAssistantConversationID }) {
            assistantConversations[index] = AssistantConversation(
                id: serverConversationID,
                title: assistantConversations[index].title,
                messages: assistantConversations[index].messages,
                createdAt: assistantConversations[index].createdAt,
                updatedAt: assistantConversations[index].updatedAt
            )
            self.selectedAssistantConversationID = serverConversationID
            persistAssistantConversations()
        }
    }

    private func saveCurrentAssistantConversation() {
        guard let selectedAssistantConversationID else { return }
        guard let index = assistantConversations.firstIndex(where: { $0.id == selectedAssistantConversationID }) else { return }
        assistantConversations[index].messages = assistantMessages
        assistantConversations[index].updatedAt = .now
        assistantConversations[index].title = assistantConversationTitle(for: assistantMessages)
        assistantConversations.sort { $0.updatedAt > $1.updatedAt }
        persistAssistantConversations()
    }

    private func assistantConversationTitle(for messages: [AssistantMessage]) -> String {
        guard let firstUserMessage = messages.first(where: { $0.role == "user" })?.content.trimmingCharacters(in: .whitespacesAndNewlines), !firstUserMessage.isEmpty else {
            return "New conversation"
        }
        if firstUserMessage.count <= 42 {
            return firstUserMessage
        }
        return "\(firstUserMessage.prefix(42))…"
    }

    private func persistAssistantConversations() {
        guard let data = try? JSONEncoder().encode(assistantConversations) else { return }
        UserDefaults.standard.set(data, forKey: Self.assistantConversationsKey)
    }

    private func refreshAuthState() {
        isSignedIn = authSession.isSignedIn
        authDisplayName = authSession.displayName
        authEmail = authSession.email
        if let savedUserID = BudgetAuthSession.savedUserID {
            api.userID = savedUserID
        }
    }

    private func defaultProjectionEvents() -> [CashflowEvent] {
        let calendar = Calendar.current
        let now = Date()
        let weeklyFood = (0..<4).compactMap { week -> CashflowEvent? in
            guard let date = calendar.date(byAdding: .day, value: week * 7 + 2, to: now) else { return nil }
            return CashflowEvent(date: date, label: "Flexible food budget", amountCents: -15000)
        }
        let fixedBills = accounts.filter { $0.type == "credit" }.compactMap { account -> CashflowEvent? in
            let dueDay = account.paymentDueDay ?? 28
            guard let date = calendar.nextDate(after: now, matching: DateComponents(day: dueDay), matchingPolicy: .nextTime) else { return nil }
            return CashflowEvent(date: date, label: "\(account.name) payment", amountCents: min(-2500, account.balanceCents))
        }
        return (weeklyFood + fixedBills).sorted { $0.date < $1.date }
    }
}
