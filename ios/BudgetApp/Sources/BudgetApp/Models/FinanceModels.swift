import Foundation

struct Account: Identifiable, Codable, Hashable {
    let id: String
    let userID: String
    let source: String
    let name: String
    let officialName: String?
    let type: String
    let subtype: String?
    let currencyCode: String
    let balanceCents: Int64
    let creditLimitCents: Int64?
    let statementCloseDay: Int?
    let paymentDueDay: Int?

    enum CodingKeys: String, CodingKey {
        case id, source, name, type, subtype
        case userID = "user_id"
        case officialName = "official_name"
        case currencyCode = "currency_code"
        case balanceCents = "balance_cents"
        case creditLimitCents = "credit_limit_cents"
        case statementCloseDay = "statement_close_day"
        case paymentDueDay = "payment_due_day"
    }
}

extension Account {
    var displayName: String {
        let official = (officialName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !official.isEmpty {
            return official
        }
        return name
    }

    var isCredit: Bool {
        type.lowercased() == "credit" || (subtype ?? "").localizedCaseInsensitiveContains("credit")
    }

    var normalizedCreditBalanceCents: Int64 {
        guard isCredit else { return balanceCents }
        if source == "financekit", let creditLimitCents, creditLimitCents > 0 {
            return max(0, creditLimitCents - balanceCents)
        }
        return max(0, balanceCents)
    }

    var normalizedAvailableCreditCents: Int64 {
        guard isCredit, let creditLimitCents, creditLimitCents > 0 else { return 0 }
        if source == "financekit" {
            return max(0, balanceCents)
        }
        return max(0, creditLimitCents - max(0, balanceCents))
    }

    var normalizedCreditLimitCents: Int64 {
        max(0, creditLimitCents ?? 0)
    }

    var creditUtilization: Double {
        guard normalizedCreditLimitCents > 0 else { return 0 }
        return min(1, max(0, Double(normalizedCreditBalanceCents) / Double(normalizedCreditLimitCents)))
    }
}

struct CategorySplit: Codable, Hashable, Identifiable {
    var id: String { categoryID + name + String(amountCents) }
    let categoryID: String
    let name: String
    let amountCents: Int64

    enum CodingKeys: String, CodingKey {
        case categoryID = "category_id"
        case name
        case amountCents = "amount_cents"
    }
}

struct ReceiptLineItem: Codable, Hashable, Identifiable {
    var id: String { name + quantity + String(amountCents) }
    let name: String
    let quantity: String
    let amountCents: Int64
    let categoryID: String?

    enum CodingKeys: String, CodingKey {
        case name, quantity
        case amountCents = "amount_cents"
        case categoryID = "category_id"
    }
}

struct Transaction: Identifiable, Codable, Hashable {
    let id: String
    let userID: String
    let accountID: String
    let source: String
    let description: String
    let merchantName: String?
    let amountCents: Int64
    let currencyCode: String
    let authorizedAt: Date?
    let postedAt: Date
    let pending: Bool
    let locationName: String?
    let categorySplits: [CategorySplit]?
    let receiptLineItems: [ReceiptLineItem]?
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case id, source, description, pending, notes
        case userID = "user_id"
        case accountID = "account_id"
        case merchantName = "merchant_name"
        case amountCents = "amount_cents"
        case currencyCode = "currency_code"
        case authorizedAt = "authorized_at"
        case postedAt = "posted_at"
        case locationName = "location_name"
        case categorySplits = "category_splits"
        case receiptLineItems = "receipt_line_items"
    }
}

struct TransactionFilter: Hashable {
    enum AmountMode: String, CaseIterable, Hashable, Identifiable {
        case any
        case equal
        case greaterThan
        case lessThan

        var id: String { rawValue }

        var label: String {
            switch self {
            case .any: "Any amount"
            case .equal: "Equals"
            case .greaterThan: "Greater than"
            case .lessThan: "Less than"
            }
        }
    }

    enum SortField: String, CaseIterable, Hashable, Identifiable {
        case date
        case amount
        case merchant

        var id: String { rawValue }

        var label: String {
            switch self {
            case .date: "Date"
            case .amount: "Amount"
            case .merchant: "Merchant"
            }
        }
    }

    enum SortDirection: String, CaseIterable, Hashable, Identifiable {
        case desc
        case asc

        var id: String { rawValue }
        var label: String { self == .desc ? "Descending" : "Ascending" }
    }

    var searchText = ""
    var amountText = ""
    var amountMode: AmountMode = .any
    var sortField: SortField = .date
    var sortDirection: SortDirection = .desc
    var accountID = ""
    var source = ""
    var isStartDateEnabled = false
    var startDate = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    var isEndDateEnabled = false
    var endDate = Date()

    var isDefault: Bool {
        self == TransactionFilter()
    }

    var summaryLabels: [String] {
        var labels: [String] = []
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSearch.isEmpty {
            labels.append("Search: \(trimmedSearch)")
        }
        let trimmedAmount = amountText.trimmingCharacters(in: .whitespacesAndNewlines)
        if amountMode != .any, !trimmedAmount.isEmpty {
            labels.append("\(amountMode.label) \(trimmedAmount)")
        }
        if !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            labels.append("Account selected")
        }
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSource.isEmpty {
            labels.append("Source: \(Self.sourceLabel(trimmedSource))")
        }
        if isStartDateEnabled {
            labels.append("From \(startDate.formatted(date: .abbreviated, time: .omitted))")
        }
        if isEndDateEnabled {
            labels.append("To \(endDate.formatted(date: .abbreviated, time: .omitted))")
        }
        if sortField != .date || sortDirection != .desc {
            labels.append("Sort: \(sortField.label), \(sortDirection.label)")
        }
        return labels
    }

    static func sourceLabel(_ source: String) -> String {
        switch source {
        case "plaid": "Plaid"
        case "manual": "Manual"
        case "statement": "Statement"
        case "financekit": "FinanceKit"
        default: source.capitalized
        }
    }

    var queryItems: [String: String] {
        var query: [String: String] = ["sort": sortField.rawValue, "direction": sortDirection.rawValue]
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSearch.isEmpty {
            query["q"] = trimmedSearch
        }
        let trimmedAmount = amountText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAmount.isEmpty {
            switch amountMode {
            case .any:
                break
            case .equal:
                query["amount_eq"] = trimmedAmount
            case .greaterThan:
                query["amount_gt"] = trimmedAmount
            case .lessThan:
                query["amount_lt"] = trimmedAmount
            }
        }
        let trimmedAccountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAccountID.isEmpty {
            query["account_id"] = trimmedAccountID
        }
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSource.isEmpty {
            query["source"] = trimmedSource
        }
        if isStartDateEnabled, isEndDateEnabled, startDate > endDate {
            query["posted_from"] = Self.apiDate(endDate)
            query["posted_to"] = Self.apiDate(startDate)
        } else {
            if isStartDateEnabled {
                query["posted_from"] = Self.apiDate(startDate)
            }
            if isEndDateEnabled {
                query["posted_to"] = Self.apiDate(endDate)
            }
        }
        return query
    }

    private static func apiDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

struct Budget: Identifiable, Codable, Hashable {
    let id: String
    let userID: String
    let categoryID: String
    let categoryName: String
    let period: String
    let limitCents: Int64
    let spentCents: Int64

    enum CodingKeys: String, CodingKey {
        case id, period
        case userID = "user_id"
        case categoryID = "category_id"
        case categoryName = "category_name"
        case limitCents = "limit_cents"
        case spentCents = "spent_cents"
    }
}

struct BudgetIncomeOverride: Identifiable, Codable, Hashable {
    let id: String
    let userID: String
    let transactionID: String
    let included: Bool
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, included
        case userID = "user_id"
        case transactionID = "transaction_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct RecurringTransaction: Identifiable, Codable, Hashable {
    let id: String
    let userID: String
    let kind: String
    let status: String
    let cadence: String
    let normalizedKey: String
    let merchantName: String
    let categoryName: String?
    let averageAmountCents: Int64
    let lastAmountCents: Int64
    let transactionCount: Int
    let averageIntervalDays: Int
    let confidence: Double
    let firstSeenAt: Date
    let lastSeenAt: Date
    let nextExpectedAt: Date?
    let transactionIDs: [String]
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, kind, status, cadence, confidence
        case userID = "user_id"
        case normalizedKey = "normalized_key"
        case merchantName = "merchant_name"
        case categoryName = "category_name"
        case averageAmountCents = "average_amount_cents"
        case lastAmountCents = "last_amount_cents"
        case transactionCount = "transaction_count"
        case averageIntervalDays = "average_interval_days"
        case firstSeenAt = "first_seen_at"
        case lastSeenAt = "last_seen_at"
        case nextExpectedAt = "next_expected_at"
        case transactionIDs = "transaction_ids"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var isIncome: Bool { kind == "income" }

    var displayAmountCents: Int64 {
        abs(averageAmountCents)
    }

    var cadenceLabel: String {
        switch cadence {
        case "weekly": "Weekly"
        case "biweekly": "Every 2 weeks"
        case "semimonthly": "Twice monthly"
        case "monthly": "Monthly"
        default: averageIntervalDays > 0 ? "Every \(averageIntervalDays)d" : "Irregular"
        }
    }

    var confidenceLabel: String {
        "\(Int((confidence * 100).rounded()))% confidence"
    }
}

struct Goal: Identifiable, Codable, Hashable {
    let id: String
    let userID: String
    let name: String
    let type: String
    let targetCents: Int64
    let currentCents: Int64
    let priority: Int

    enum CodingKeys: String, CodingKey {
        case id, name, type, priority
        case userID = "user_id"
        case targetCents = "target_cents"
        case currentCents = "current_cents"
    }
}

struct StatementUpload: Identifiable, Codable, Hashable {
    let id: String
    let userID: String
    let accountID: String
    let fileName: String
    let fileType: String
    let statementStart: Date
    let statementEnd: Date
    let importedCount: Int
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case accountID = "account_id"
        case fileName = "file_name"
        case fileType = "file_type"
        case statementStart = "statement_start"
        case statementEnd = "statement_end"
        case importedCount = "imported_count"
        case createdAt = "created_at"
    }
}

struct CashflowEvent: Codable, Hashable, Identifiable {
    var id: String { label + date.ISO8601Format() + String(amountCents) }
    let date: Date
    let label: String
    let amountCents: Int64

    enum CodingKeys: String, CodingKey {
        case date, label
        case amountCents = "amount_cents"
    }
}

struct CashflowProjection: Codable, Hashable, Identifiable {
    var id: String { label + date.ISO8601Format() + String(balanceCents) }
    let date: Date
    let label: String
    let amountCents: Int64
    let balanceCents: Int64

    enum CodingKeys: String, CodingKey {
        case date, label
        case amountCents = "amount_cents"
        case balanceCents = "balance_cents"
    }
}

struct AssistantReply: Codable, Hashable {
    let reply: String
    let createdAt: Date
    let conversationID: String?

    enum CodingKeys: String, CodingKey {
        case reply
        case createdAt = "created_at"
        case conversationID = "conversation_id"
    }
}

struct BudgetAssistantReply: Codable, Hashable {
    var id: String { proposalID ?? "\(createdAt.timeIntervalSince1970)-\(reply.hashValue)" }
    var normalizedMode: String {
        let value = (mode ?? "proposal").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.isEmpty ? "proposal" : value
    }
    let reply: String
    let createdBudgets: Int
    let updatedBudgets: Int
    let deletedBudgets: Int
    let classified: Int
    let needsReview: Int
    let followUps: [String]
    let plan: BudgetAssistantPlan?
    let proposalID: String?
    let mode: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case reply, plan, mode
        case proposalID = "proposal_id"
        case createdBudgets = "created_budgets"
        case updatedBudgets = "updated_budgets"
        case deletedBudgets = "deleted_budgets"
        case classified
        case needsReview = "needs_review"
        case followUps = "follow_ups"
        case createdAt = "created_at"
    }
}

struct BudgetAssistantPlan: Codable, Hashable {
    var reply: String
    var budgets: [BudgetAssistantBudgetAction]
    var classifications: [BudgetAssistantClassification]
    var followUps: [String]

    enum CodingKeys: String, CodingKey {
        case reply, budgets, classifications
        case followUps = "follow_ups"
    }
}

struct BudgetAssistantBudgetAction: Codable, Hashable, Identifiable {
    var id: String { [operation, categoryName, period, String(limitCents)].joined(separator: "|") }
    let operation: String
    let categoryName: String
    let period: String
    let limitCents: Int64

    enum CodingKeys: String, CodingKey {
        case operation, period
        case categoryName = "category_name"
        case limitCents = "limit_cents"
    }
}

struct BudgetAssistantClassification: Codable, Hashable, Identifiable {
    var id: String { transactionID + "|" + categoryName }
    let transactionID: String
    let categoryName: String
    let confidence: Double
    let reason: String
    let applyToSimilar: Bool

    enum CodingKeys: String, CodingKey {
        case confidence, reason
        case transactionID = "transaction_id"
        case categoryName = "category_name"
        case applyToSimilar = "apply_to_similar"
    }
}

struct VoiceSessionResponse: Codable, Hashable {
    let clientSecret: String
    let expiresAt: Date
    let model: String
    let voice: String
    let websocketURL: URL
    let session: VoiceSessionUpdate

    enum CodingKeys: String, CodingKey {
        case model, voice, session
        case clientSecret = "client_secret"
        case expiresAt = "expires_at"
        case websocketURL = "websocket_url"
    }
}

struct VoiceSessionUpdate: Codable, Hashable {
    let type: String
    let session: VoiceSessionConfiguration
}

struct VoiceSessionConfiguration: Codable, Hashable {
    let voice: String
    let instructions: String
    let turnDetection: VoiceTurnDetection?
    let inputAudioTranscription: VoiceTranscription
    let audio: VoiceAudioConfiguration

    enum CodingKeys: String, CodingKey {
        case voice, instructions, audio
        case turnDetection = "turn_detection"
        case inputAudioTranscription = "input_audio_transcription"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(voice, forKey: .voice)
        try container.encode(instructions, forKey: .instructions)
        if let turnDetection {
            try container.encode(turnDetection, forKey: .turnDetection)
        } else {
            try container.encodeNil(forKey: .turnDetection)
        }
        try container.encode(inputAudioTranscription, forKey: .inputAudioTranscription)
        try container.encode(audio, forKey: .audio)
    }
}

struct VoiceTurnDetection: Codable, Hashable {
    let type: String
}

struct VoiceTranscription: Codable, Hashable {
    let model: String
}

struct VoiceAudioConfiguration: Codable, Hashable {
    let input: VoiceAudioDirection
    let output: VoiceAudioDirection
}

struct VoiceAudioDirection: Codable, Hashable {
    let format: VoiceAudioFormat
}

struct VoiceAudioFormat: Codable, Hashable {
    let type: String
    let rate: Int
}

struct StatementImportResult: Codable, Hashable {
    let statement: StatementUpload
    let importedCount: Int

    enum CodingKeys: String, CodingKey {
        case statement
        case importedCount = "imported_count"
    }
}

struct AssistantConversation: Identifiable, Codable, Hashable {
    let id: String
    var title: String
    var messages: [AssistantMessage]
    var createdAt: Date
    var updatedAt: Date

    init(id: String = UUID().uuidString, title: String, messages: [AssistantMessage] = [], createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, title, messages
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        messages = try container.decodeIfPresent([AssistantMessage].self, forKey: .messages) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

struct AssistantMessage: Identifiable, Codable, Hashable {
    let id: String
    let role: String
    var content: String
    var createdAt: Date
    var isStreaming = false

    init(id: String = UUID().uuidString, role: String, content: String, createdAt: Date, isStreaming: Bool = false) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.isStreaming = isStreaming
    }

    enum CodingKeys: String, CodingKey {
        case id, role, content, isStreaming
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        role = try container.decode(String.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isStreaming = try container.decodeIfPresent(Bool.self, forKey: .isStreaming) ?? false
    }
}

extension Int64 {
    var dollars: Decimal { Decimal(self) / 100 }
}
