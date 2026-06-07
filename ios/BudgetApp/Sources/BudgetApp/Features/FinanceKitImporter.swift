import Foundation

#if canImport(FinanceKit)
import FinanceKit
#endif

enum FinanceKitImportError: LocalizedError {
    case unavailable
    case restricted
    case denied

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "FinanceKit financial data is not available on this device or for this region/account."
        case .restricted:
            "FinanceKit is available only after Apple grants the managed entitlement for this bundle ID."
        case .denied:
            "FinanceKit access was denied. Enable access in Settings or request permission again."
        }
    }
}

struct FinanceKitSnapshot: Hashable {
    let accounts: [FinanceKitAccountImport]
    let transactions: [FinanceKitTransactionImport]
}

enum FinanceKitImporter {
    private static func log(_ message: String) {
        NSLog("[FinanceKitImporter] %@", message)
    }

    static var canUseNativeFinanceKit: Bool {
#if canImport(FinanceKit)
        if #available(iOS 17.4, *) {
            return true
        }
#endif
        return false
    }

    static var availabilityMessage: String {
#if canImport(FinanceKit)
        guard #available(iOS 17.4, *) else {
            return "FinanceKit requires iOS 17.4 or later."
        }
        return "Ready to request Apple Wallet financial data access."
#else
        return "FinanceKit is not available in this SDK build."
#endif
    }

    static func loadSnapshot(limit: Int = 500, progress: (@MainActor (String) -> Void)? = nil) async throws -> FinanceKitSnapshot {
#if canImport(FinanceKit)
        if #available(iOS 17.4, *) {
            log("Checking data availability")
            await progress?("Checking FinanceKit availability…")
            guard FinanceKit.FinanceStore.isDataAvailable(.financialData) else {
                log("Financial data is unavailable")
                throw FinanceKitImportError.unavailable
            }
            let store = FinanceKit.FinanceStore.shared
            log("Checking authorization status")
            await progress?("Checking Wallet permission…")
            let status = try await store.authorizationStatus()
            log("Authorization status: \(String(describing: status))")
            let authorized: Bool
            switch status {
            case .authorized:
                authorized = true
            case .notDetermined:
                log("Requesting authorization")
                await progress?("Waiting for Wallet permission…")
                let requestedStatus = try await store.requestAuthorization()
                log("Authorization request returned: \(String(describing: requestedStatus))")
                authorized = requestedStatus == .authorized
            case .denied:
                authorized = false
            @unknown default:
                authorized = false
            }
            guard authorized else {
                log("Authorization denied")
                throw FinanceKitImportError.denied
            }

            log("Reading accounts")
            await progress?("Reading Wallet accounts…")
            let accounts = try await store.accounts(query: FinanceKit.AccountQuery())
            log("Read \(accounts.count) accounts")
            log("Reading balances")
            await progress?("Reading Wallet balances…")
            let balances = try await store.accountBalances(query: FinanceKit.AccountBalanceQuery())
            log("Read \(balances.count) balances")
            log("Reading transactions")
            await progress?("Reading Wallet transactions…")
            let transactions = try await store.transactions(query: FinanceKit.TransactionQuery(limit: limit))
            log("Read \(transactions.count) transactions")
            let balanceByAccount = Dictionary(
                balances.map { ($0.accountID, $0) },
                uniquingKeysWith: preferredBalance
            )
            log("Preparing snapshot")
            await progress?("Preparing Wallet import…")
            return FinanceKitSnapshot(
                accounts: accounts.map { account in
                    mapAccount(account, balance: balanceByAccount[account.id])
                },
                transactions: transactions.map(mapTransaction)
            )
        }
#endif
        throw FinanceKitImportError.unavailable
    }

#if canImport(FinanceKit)
    @available(iOS 17.4, *)
    private static func mapAccount(_ account: FinanceKit.Account, balance: FinanceKit.AccountBalance?) -> FinanceKitAccountImport {
        let type: String
        let subtype: String
        let creditLimitCents: Int64
        switch account {
        case .asset:
            type = "depository"
            subtype = "wallet"
            creditLimitCents = 0
        case let .liability(liability):
            type = "credit"
            subtype = "credit card"
            creditLimitCents = cents(liability.creditInformation.creditLimit?.amount ?? Decimal(0))
        @unknown default:
            type = "depository"
            subtype = "wallet"
            creditLimitCents = 0
        }
        return FinanceKitAccountImport(
            id: account.id.uuidString,
            name: account.displayName,
            officialName: account.accountDescription ?? account.displayName,
            institutionName: account.institutionName,
            type: type,
            subtype: subtype,
            currencyCode: account.currencyCode,
            balanceCents: balance.map(balanceCents) ?? 0,
            creditLimitCents: creditLimitCents,
            statementCloseDay: 0,
            paymentDueDay: 0
        )
    }

    @available(iOS 17.4, *)
    private static func mapTransaction(_ transaction: FinanceKit.Transaction) -> FinanceKitTransactionImport {
        let signedCents = cents(transaction.transactionAmount.amount) * (transaction.creditDebitIndicator == .debit ? -1 : 1)
        return FinanceKitTransactionImport(
            id: transaction.id.uuidString,
            accountID: transaction.accountID.uuidString,
            description: transaction.transactionDescription,
            merchantName: transaction.merchantName ?? "",
            amountCents: signedCents,
            currencyCode: transaction.transactionAmount.currencyCode,
            authorizedAt: transaction.transactionDate,
            postedAt: transaction.postedDate ?? transaction.transactionDate,
            pending: transaction.status == .pending || transaction.status == .authorized || transaction.status == .memo,
            locationName: "",
            transactionType: String(describing: transaction.transactionType),
            status: String(describing: transaction.status)
        )
    }

    @available(iOS 17.4, *)
    private static func balanceCents(_ balance: FinanceKit.AccountBalance) -> Int64 {
        if let available = balance.available {
            return cents(available.amount.amount) * (available.creditDebitIndicator == .debit ? -1 : 1)
        }
        if let booked = balance.booked {
            return cents(booked.amount.amount) * (booked.creditDebitIndicator == .debit ? -1 : 1)
        }
        return 0
    }

    @available(iOS 17.4, *)
    private static func preferredBalance(_ current: FinanceKit.AccountBalance, _ next: FinanceKit.AccountBalance) -> FinanceKit.AccountBalance {
        if next.available != nil {
            return next
        }
        if current.available != nil {
            return current
        }
        if next.booked != nil {
            return next
        }
        return current
    }
#endif

    private static func cents(_ decimal: Decimal) -> Int64 {
        let number = NSDecimalNumber(decimal: decimal * Decimal(100))
        return number.rounding(accordingToBehavior: nil).int64Value
    }
}
