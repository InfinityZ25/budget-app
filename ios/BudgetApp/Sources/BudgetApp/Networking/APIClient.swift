import AuthenticationServices
import Foundation
import UIKit

struct APIClient: Sendable {
    var baseURL: URL
    var userID: String

    static var local: APIClient {
        APIClient(baseURL: URL(string: "http://192.168.4.48:8080/v1")!, userID: BudgetAuthStorage.savedUserID ?? "local-user")
    }

    func accounts() async throws -> [Account] {
        try await get("accounts", query: ["user_id": userID])
    }

    func transactions(limit: Int = 80, filter: TransactionFilter = TransactionFilter()) async throws -> [Transaction] {
        var query = filter.queryItems
        query["user_id"] = userID
        query["limit"] = String(limit)
        return try await get("transactions", query: query)
    }

    func budgets() async throws -> [Budget] {
        try await get("budgets", query: ["user_id": userID])
    }

    func goals() async throws -> [Goal] {
        try await get("goals", query: ["user_id": userID])
    }

    func statements() async throws -> [StatementUpload] {
        try await get("statements", query: ["user_id": userID])
    }

    func createPlaidLinkToken() async throws -> LinkTokenResponse {
        try await post("plaid/link-token", body: ["user_id": userID])
    }

    func exchangePlaidPublicToken(_ publicToken: String) async throws -> PlaidExchangeResult {
        try await post("plaid/exchange-public-token", body: ["user_id": userID, "public_token": publicToken])
    }

    func syncPlaidItems() async throws -> PlaidSyncResult {
        try await post("plaid/sync", body: ["user_id": userID])
    }

    func createManualAccount(_ draft: ManualAccountDraft) async throws -> Account {
        try await post("accounts/manual", body: draft.payload(userID: userID))
    }

    func deleteAccount(id: String) async throws {
        try await delete("accounts/\(id)", query: ["user_id": userID])
    }

    func createManualTransaction(_ draft: ManualTransactionDraft) async throws -> Transaction {
        try await post("transactions/manual", body: draft.payload(userID: userID))
    }

    func updateTransactionCategory(id: String, categoryName: String, applyToSimilar: Bool) async throws -> Transaction {
        try await patch("transactions/\(id)/category", body: TransactionCategoryPayload(userID: userID, categoryName: categoryName, applyToSimilar: applyToSimilar))
    }

    func createGoal(_ draft: GoalDraft) async throws -> Goal {
        try await post("goals", body: draft.payload(userID: userID))
    }

    func createBudget(_ draft: BudgetDraft) async throws -> Budget {
        try await post("budgets", body: draft.payload(userID: userID))
    }

    func updateBudget(id: String, draft: BudgetDraft) async throws -> Budget {
        try await put("budgets/\(id)", body: draft.payload(userID: userID))
    }

    func deleteBudget(id: String) async throws {
        try await delete("budgets/\(id)", query: ["user_id": userID])
    }

    func autoGenerateBudgets() async throws -> [Budget] {
        try await post("budgets/autogenerate", body: ["user_id": userID])
    }

    func askBudgetAssistant(_ message: String) async throws -> BudgetAssistantReply {
        try await post("budgets/assistant/chat", body: ["user_id": userID, "message": message])
    }

    func streamBudgetAssistant(_ message: String) -> AsyncThrowingStream<BudgetAssistantStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var request = URLRequest(url: baseURL.appending(path: "budgets/assistant/chat/stream"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.httpBody = try encoder.encode(BudgetAssistantChatRequest(userID: userID, message: message))

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
                        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                        throw APIError.badStatus(status, "Streaming budget assistant request failed")
                    }

                    var eventName = "message"
                    for try await line in bytes.lines {
                        if line.hasPrefix("event:") {
                            eventName = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            let payload = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
                            if let event = try decodeBudgetAssistantStreamEvent(name: eventName, payload: payload) {
                                continuation.yield(event)
                            }
                        } else if line.isEmpty {
                            eventName = "message"
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func createStatement(_ draft: StatementDraft) async throws -> StatementUpload {
        try await post("statements", body: draft.payload(userID: userID))
    }

    func importStatementCSV(accountID: String, fileName: String, csv: String) async throws -> StatementImportResult {
        try await post("statements/import-csv", body: StatementImportPayload(userID: userID, accountID: accountID, fileName: fileName, csv: csv))
    }

    func importStatementPDF(accountID: String, fileURL: URL) async throws -> StatementImportResult {
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        let data = try Data(contentsOf: fileURL)
        return try await upload("statements/import-pdf", fields: ["user_id": userID, "account_id": accountID], fileField: "file", fileName: fileURL.lastPathComponent, contentType: "application/pdf", data: data)
    }

    func projectCashflow(startingBalanceCents: Int64, events: [CashflowEvent]) async throws -> [CashflowProjection] {
        try await post("cashflow/project", body: CashflowProjectionRequest(startingBalanceCents: startingBalanceCents, events: events))
    }

    func askAssistant(_ message: String) async throws -> AssistantReply {
        try await post("assistant/chat", body: ["user_id": userID, "message": message])
    }

    func assistantConversations() async throws -> [AssistantConversation] {
        try await get("assistant/conversations", query: ["user_id": userID])
    }

    func assistantMessages(conversationID: String) async throws -> [AssistantMessage] {
        try await get("assistant/conversations/\(conversationID)/messages", query: ["user_id": userID])
    }

    func createAssistantConversation(title: String = "New conversation") async throws -> AssistantConversation {
        try await post("assistant/conversations", body: ["user_id": userID, "title": title])
    }

    func deleteAssistantConversation(id: String) async throws {
        try await delete("assistant/conversations/\(id)", query: ["user_id": userID])
    }

    func streamAssistant(_ message: String, conversationID: String?) -> AsyncThrowingStream<AssistantStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var request = URLRequest(url: baseURL.appending(path: "assistant/chat/stream"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.httpBody = try encoder.encode(AssistantChatRequest(userID: userID, conversationID: conversationID, message: message))

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
                        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                        throw APIError.badStatus(status, "Streaming assistant request failed")
                    }

                    var eventName = "message"
                    for try await line in bytes.lines {
                        if line.hasPrefix("event:") {
                            eventName = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            let payload = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
                            if let event = try decodeAssistantStreamEvent(name: eventName, payload: payload) {
                                continuation.yield(event)
                            }
                        } else if line.isEmpty {
                            eventName = "message"
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func createVoiceSession() async throws -> VoiceSessionResponse {
        try await post("voice/xai/client-secret", body: ["user_id": userID])
    }

    func importFinanceKit(accounts: [FinanceKitAccountImport], transactions: [FinanceKitTransactionImport]) async throws -> FinanceKitImportResult {
        try await post("financekit/import", body: FinanceKitImportPayload(userID: userID, accounts: accounts, transactions: transactions))
    }

    func workOSAuthorizeURL(state: String = UUID().uuidString) async throws -> WorkOSAuthorizeResponse {
        try await get("auth/workos/authorize-url", query: ["state": state])
    }

    func exchangeWorkOSCode(_ code: String) async throws -> WorkOSAuthResponse {
        try await post("auth/workos/callback", body: ["code": code])
    }

    func refreshWorkOSSession(refreshToken: String) async throws -> WorkOSTokenRefreshResponse {
        try await post("auth/workos/refresh", body: ["refresh_token": refreshToken])
    }

    private func get<T: Decodable>(_ path: String, query: [String: String]) async throws -> T {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.map(URLQueryItem.init)
        let url = components.url!
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(from: url)
        } catch {
            throw APIError.transport(url, error)
        }
        try validate(response: response, data: data)
        return try decoder.decode(T.self, from: data)
    }

    private func post<T: Decodable, Body: Encodable>(_ path: String, body: Body) async throws -> T {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.transport(request.url!, error)
        }
        try validate(response: response, data: data)
        return try decoder.decode(T.self, from: data)
    }

    private func put<T: Decodable, Body: Encodable>(_ path: String, body: Body) async throws -> T {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.transport(request.url!, error)
        }
        try validate(response: response, data: data)
        return try decoder.decode(T.self, from: data)
    }

    private func patch<T: Decodable, Body: Encodable>(_ path: String, body: Body) async throws -> T {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.transport(request.url!, error)
        }
        try validate(response: response, data: data)
        return try decoder.decode(T.self, from: data)
    }

    private func delete(_ path: String, query: [String: String]) async throws {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.map(URLQueryItem.init)
        var request = URLRequest(url: components.url!)
        request.httpMethod = "DELETE"
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.transport(request.url!, error)
        }
        try validate(response: response, data: data)
    }

    private func upload<T: Decodable>(_ path: String, fields: [String: String], fileField: String, fileName: String, contentType: String, data: Data) async throws -> T {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        for (key, value) in fields {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(fileName)\"\r\n")
        body.append("Content-Type: \(contentType)\r\n\r\n")
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n")
        request.httpBody = body
        let (responseData, response): (Data, URLResponse)
        do {
            (responseData, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.transport(request.url!, error)
        }
        try validate(response: response, data: responseData)
        return try decoder.decode(T.self, from: responseData)
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard 200..<300 ~= httpResponse.statusCode else {
            let message = String(data: data, encoding: .utf8) ?? "Request failed"
            throw APIError.badStatus(httpResponse.statusCode, message)
        }
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func decodeAssistantStreamEvent(name: String, payload: String) throws -> AssistantStreamEvent? {
        guard let data = payload.data(using: .utf8) else { return nil }
        switch name {
        case "status":
            let decoded = try decoder.decode(AssistantStreamMessagePayload.self, from: data)
            return .status(decoded.message)
        case "token":
            let decoded = try decoder.decode(AssistantStreamTokenPayload.self, from: data)
            return .token(decoded.delta)
        case "done":
            let decoded = try decoder.decode(AssistantReply.self, from: data)
            return .done(decoded)
        case "notice":
            let decoded = try decoder.decode(AssistantStreamMessagePayload.self, from: data)
            return .notice(decoded.message)
        default:
            return nil
        }
    }

    private func decodeBudgetAssistantStreamEvent(name: String, payload: String) throws -> BudgetAssistantStreamEvent? {
        guard let data = payload.data(using: .utf8) else { return nil }
        switch name {
        case "status":
            let decoded = try decoder.decode(AssistantStreamMessagePayload.self, from: data)
            return .status(decoded.message)
        case "token":
            let decoded = try decoder.decode(AssistantStreamTokenPayload.self, from: data)
            return .token(decoded.delta)
        case "done":
            let decoded = try decoder.decode(BudgetAssistantReply.self, from: data)
            return .done(decoded)
        case "notice":
            let decoded = try decoder.decode(AssistantStreamMessagePayload.self, from: data)
            return .notice(decoded.message)
        default:
            return nil
        }
    }
}

enum AssistantStreamEvent {
    case status(String)
    case token(String)
    case done(AssistantReply)
    case notice(String)
}

enum BudgetAssistantStreamEvent {
    case status(String)
    case token(String)
    case done(BudgetAssistantReply)
    case notice(String)
}

private struct BudgetAssistantChatRequest: Encodable {
    let userID: String
    let message: String

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case message
    }
}

private struct AssistantChatRequest: Encodable {
    let userID: String
    let conversationID: String?
    let message: String

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case conversationID = "conversation_id"
        case message
    }
}

private struct AssistantStreamTokenPayload: Decodable {
    let delta: String
}

private struct AssistantStreamMessagePayload: Decodable {
    let message: String
}

struct WorkOSAuthorizeResponse: Codable, Hashable {
    let url: URL
    let state: String
    let redirectURI: String

    enum CodingKeys: String, CodingKey {
        case url
        case state
        case redirectURI = "redirect_uri"
    }
}

struct WorkOSAuthResponse: Codable, Hashable {
    let userID: String
    let workOSUserID: String
    let email: String
    let name: String
    let accessToken: String
    let refreshToken: String
    let organizationID: String?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case workOSUserID = "workos_user_id"
        case email
        case name
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case organizationID = "organization_id"
    }
}

struct WorkOSTokenRefreshResponse: Codable, Hashable {
    let accessToken: String
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

struct FinanceKitImportPayload: Encodable {
    let userID: String
    let accounts: [FinanceKitAccountImport]
    let transactions: [FinanceKitTransactionImport]

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case accounts
        case transactions
    }
}

struct FinanceKitAccountImport: Codable, Hashable {
    let id: String
    let name: String
    let officialName: String
    let institutionName: String
    let type: String
    let subtype: String
    let currencyCode: String
    let balanceCents: Int64
    let creditLimitCents: Int64
    let statementCloseDay: Int
    let paymentDueDay: Int

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case officialName = "official_name"
        case institutionName = "institution_name"
        case type
        case subtype
        case currencyCode = "currency_code"
        case balanceCents = "balance_cents"
        case creditLimitCents = "credit_limit_cents"
        case statementCloseDay = "statement_close_day"
        case paymentDueDay = "payment_due_day"
    }
}

struct FinanceKitTransactionImport: Codable, Hashable {
    let id: String
    let accountID: String
    let description: String
    let merchantName: String
    let amountCents: Int64
    let currencyCode: String
    let postedAt: Date
    let pending: Bool
    let locationName: String
    let transactionType: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case id
        case accountID = "account_id"
        case description
        case merchantName = "merchant_name"
        case amountCents = "amount_cents"
        case currencyCode = "currency_code"
        case postedAt = "posted_at"
        case pending
        case locationName = "location_name"
        case transactionType = "transaction_type"
        case status
    }
}

struct FinanceKitImportResult: Codable, Hashable {
    let accounts: Int
    let transactions: Int
}

@MainActor
final class BudgetAuthSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let api: APIClient
    private var webSession: ASWebAuthenticationSession?

    init(api: APIClient = .local) {
        self.api = api
    }

    static var savedUserID: String? {
        BudgetAuthStorage.savedUserID
    }

    var isSignedIn: Bool {
        Self.savedUserID != nil && UserDefaults.standard.string(forKey: BudgetAuthStorage.refreshTokenKey) != nil
    }

    var displayName: String {
        UserDefaults.standard.string(forKey: BudgetAuthStorage.nameKey) ?? "Local Profile"
    }

    var email: String {
        UserDefaults.standard.string(forKey: BudgetAuthStorage.emailKey) ?? "Not signed in"
    }

    var accessToken: String? {
        UserDefaults.standard.string(forKey: BudgetAuthStorage.accessTokenKey)
    }

    var refreshToken: String? {
        UserDefaults.standard.string(forKey: BudgetAuthStorage.refreshTokenKey)
    }

    func signIn() async throws -> WorkOSAuthResponse {
        let authorize = try await api.workOSAuthorizeURL()
        let callbackURL = try await openAuthenticationSession(url: authorize.url)
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty
        else {
            throw APIError.badStatus(400, "WorkOS callback did not include an authorization code.")
        }
        let response = try await api.exchangeWorkOSCode(code)
        persist(response)
        return response
    }

    func refreshIfPossible() async throws -> String? {
        guard let refreshToken else { return nil }
        let response = try await api.refreshWorkOSSession(refreshToken: refreshToken)
        UserDefaults.standard.set(response.accessToken, forKey: BudgetAuthStorage.accessTokenKey)
        UserDefaults.standard.set(response.refreshToken, forKey: BudgetAuthStorage.refreshTokenKey)
        return response.accessToken
    }

    func signOut() {
        UserDefaults.standard.removeObject(forKey: BudgetAuthStorage.userIDKey)
        UserDefaults.standard.removeObject(forKey: BudgetAuthStorage.accessTokenKey)
        UserDefaults.standard.removeObject(forKey: BudgetAuthStorage.refreshTokenKey)
        UserDefaults.standard.removeObject(forKey: BudgetAuthStorage.emailKey)
        UserDefaults.standard.removeObject(forKey: BudgetAuthStorage.nameKey)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    private func persist(_ response: WorkOSAuthResponse) {
        UserDefaults.standard.set(response.userID, forKey: BudgetAuthStorage.userIDKey)
        UserDefaults.standard.set(response.accessToken, forKey: BudgetAuthStorage.accessTokenKey)
        UserDefaults.standard.set(response.refreshToken, forKey: BudgetAuthStorage.refreshTokenKey)
        UserDefaults.standard.set(response.email, forKey: BudgetAuthStorage.emailKey)
        UserDefaults.standard.set(response.name.isEmpty ? response.email : response.name, forKey: BudgetAuthStorage.nameKey)
    }

    private func openAuthenticationSession(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "budgetapp") { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: error ?? APIError.badStatus(400, "Sign in was cancelled."))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            webSession = session
            if !session.start() {
                continuation.resume(throwing: APIError.badStatus(400, "Could not start WorkOS sign in."))
            }
        }
    }
}

struct ConvexClient: Sendable {
    var deploymentURL: URL
    var tokenProvider: @Sendable () -> String?

    static let production = ConvexClient(
        deploymentURL: URL(string: "https://lovable-peccary-205.convex.cloud")!,
        tokenProvider: { UserDefaults.standard.string(forKey: BudgetAuthStorage.accessTokenKey) }
    )

    func query<Response: Decodable, Args: Encodable>(_ path: String, args: Args) async throws -> Response {
        try await call(endpoint: "api/query", path: path, args: args)
    }

    func mutation<Response: Decodable, Args: Encodable>(_ path: String, args: Args) async throws -> Response {
        try await call(endpoint: "api/mutation", path: path, args: args)
    }

    private func call<Response: Decodable, Args: Encodable>(endpoint: String, path: String, args: Args) async throws -> Response {
        var request = URLRequest(url: deploymentURL.appending(path: endpoint))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = tokenProvider(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(ConvexRequest(path: path, args: args))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let message = String(data: data, encoding: .utf8) ?? "Convex request failed"
            throw APIError.badStatus(status, message)
        }
        let decoded = try JSONDecoder().decode(ConvexResponse<Response>.self, from: data)
        switch decoded.status {
        case "success":
            if let value = decoded.value {
                return value
            }
            throw APIError.badStatus(500, "Convex response did not include a value.")
        default:
            throw APIError.badStatus(500, decoded.errorMessage ?? "Convex function failed.")
        }
    }
}

private struct ConvexRequest<Args: Encodable>: Encodable {
    let path: String
    let args: Args
}

private struct ConvexResponse<Value: Decodable>: Decodable {
    let status: String
    let value: Value?
    let errorMessage: String?
}

enum BudgetAuthStorage {
    static let userIDKey = "BudgetApp.auth.userID"
    static let accessTokenKey = "BudgetApp.auth.workOSAccessToken"
    static let refreshTokenKey = "BudgetApp.auth.workOSRefreshToken"
    static let emailKey = "BudgetApp.auth.email"
    static let nameKey = "BudgetApp.auth.name"

    static var savedUserID: String? {
        UserDefaults.standard.string(forKey: userIDKey)
    }
}

struct ManualAccountDraft: Hashable {
    var name = ""
    var type = "depository"
    var subtype = "checking"
    var balanceCents: Int64 = 0
    var creditLimitCents: Int64 = 0
    var statementCloseDay: Int = 0
    var paymentDueDay: Int = 0

    fileprivate func payload(userID: String) -> ManualAccountPayload {
        ManualAccountPayload(userID: userID, name: name, type: type, subtype: subtype, currencyCode: "USD", balanceCents: balanceCents, creditLimitCents: creditLimitCents, statementCloseDay: statementCloseDay, paymentDueDay: paymentDueDay)
    }
}

struct ManualTransactionDraft: Hashable {
    var accountID = ""
    var description = ""
    var merchantName = ""
    var amountCents: Int64 = 0
    var categoryName = "Uncategorized"
    var notes = ""

    fileprivate func payload(userID: String) -> ManualTransactionPayload {
        ManualTransactionPayload(userID: userID, accountID: accountID, description: description, merchantName: merchantName, amountCents: amountCents, currencyCode: "USD", postedAt: Date(), locationName: "", categorySplits: [CategorySplit(categoryID: categoryName.lowercased().replacingOccurrences(of: " ", with: "-"), name: categoryName, amountCents: amountCents)], receiptLineItems: [], notes: notes)
    }
}

struct GoalDraft: Hashable {
    var name = ""
    var type = "savings"
    var targetCents: Int64 = 0
    var currentCents: Int64 = 0
    var priority = 1

    fileprivate func payload(userID: String) -> GoalPayload {
        GoalPayload(userID: userID, name: name, type: type, targetCents: targetCents, currentCents: currentCents, priority: priority)
    }
}

struct BudgetDraft: Hashable {
    var categoryName = ""
    var period = "monthly"
    var limitCents: Int64 = 0

    fileprivate func payload(userID: String) -> BudgetPayload {
        let normalizedName = categoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        let categoryID = normalizedName.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return BudgetPayload(userID: userID, categoryID: categoryID.isEmpty ? "uncategorized" : categoryID, categoryName: normalizedName.isEmpty ? "Uncategorized" : normalizedName, period: period, limitCents: limitCents, spentCents: 0)
    }
}

struct StatementDraft: Hashable {
    var accountID = ""
    var fileName = "Manual statement"
    var fileType = "manual"
    var statementStart = Date()
    var statementEnd = Date()
    var importedCount = 0

    fileprivate func payload(userID: String) -> StatementPayload {
        StatementPayload(userID: userID, accountID: accountID, fileName: fileName, fileType: fileType, statementStart: statementStart, statementEnd: statementEnd, importedCount: importedCount)
    }
}

private struct ManualAccountPayload: Encodable {
    let userID: String
    let name: String
    let type: String
    let subtype: String
    let currencyCode: String
    let balanceCents: Int64
    let creditLimitCents: Int64
    let statementCloseDay: Int
    let paymentDueDay: Int

    enum CodingKeys: String, CodingKey {
        case name, type, subtype
        case userID = "user_id"
        case currencyCode = "currency_code"
        case balanceCents = "balance_cents"
        case creditLimitCents = "credit_limit_cents"
        case statementCloseDay = "statement_close_day"
        case paymentDueDay = "payment_due_day"
    }
}

private struct ManualTransactionPayload: Encodable {
    let userID: String
    let accountID: String
    let description: String
    let merchantName: String
    let amountCents: Int64
    let currencyCode: String
    let postedAt: Date
    let locationName: String
    let categorySplits: [CategorySplit]
    let receiptLineItems: [ReceiptLineItem]
    let notes: String

    enum CodingKeys: String, CodingKey {
        case description, notes
        case userID = "user_id"
        case accountID = "account_id"
        case merchantName = "merchant_name"
        case amountCents = "amount_cents"
        case currencyCode = "currency_code"
        case postedAt = "posted_at"
        case locationName = "location_name"
        case categorySplits = "category_splits"
        case receiptLineItems = "receipt_line_items"
    }
}

private struct TransactionCategoryPayload: Encodable {
    let userID: String
    let categoryName: String
    let applyToSimilar: Bool

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case categoryName = "category_name"
        case applyToSimilar = "apply_to_similar"
    }
}

private struct GoalPayload: Encodable {
    let userID: String
    let name: String
    let type: String
    let targetCents: Int64
    let currentCents: Int64
    let priority: Int

    enum CodingKeys: String, CodingKey {
        case name, type, priority
        case userID = "user_id"
        case targetCents = "target_cents"
        case currentCents = "current_cents"
    }
}

private struct BudgetPayload: Encodable {
    let userID: String
    let categoryID: String
    let categoryName: String
    let period: String
    let limitCents: Int64
    let spentCents: Int64

    enum CodingKeys: String, CodingKey {
        case period
        case userID = "user_id"
        case categoryID = "category_id"
        case categoryName = "category_name"
        case limitCents = "limit_cents"
        case spentCents = "spent_cents"
    }
}

private struct StatementPayload: Encodable {
    let userID: String
    let accountID: String
    let fileName: String
    let fileType: String
    let statementStart: Date
    let statementEnd: Date
    let importedCount: Int

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case accountID = "account_id"
        case fileName = "file_name"
        case fileType = "file_type"
        case statementStart = "statement_start"
        case statementEnd = "statement_end"
        case importedCount = "imported_count"
    }
}

private struct StatementImportPayload: Encodable {
    let userID: String
    let accountID: String
    let fileName: String
    let csv: String

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case accountID = "account_id"
        case fileName = "file_name"
        case csv
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}

private struct CashflowProjectionRequest: Encodable {
    let startingBalanceCents: Int64
    let events: [CashflowEvent]

    enum CodingKeys: String, CodingKey {
        case startingBalanceCents = "starting_balance_cents"
        case events
    }
}

struct LinkTokenResponse: Decodable, Hashable {
    let linkToken: String
    let expiration: Date
    let requestID: String

    enum CodingKeys: String, CodingKey {
        case linkToken = "link_token"
        case expiration
        case requestID = "request_id"
    }
}

struct PlaidExchangeResult: Decodable, Hashable {
    let accounts: [Account]
}

struct PlaidSyncResult: Decodable, Hashable {
    let items: Int
    let added: Int
    let modified: Int
    let removed: Int
    let backfilled: Int
}

enum APIError: LocalizedError {
    case badStatus(Int, String)
    case transport(URL, Error)

    var errorDescription: String? {
        switch self {
        case let .badStatus(status, message):
            return "HTTP \(status): \(message)"
        case let .transport(url, error):
            return "Could not connect to \(url.absoluteString). \(error.localizedDescription)"
        }
    }
}
