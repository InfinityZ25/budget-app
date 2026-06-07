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
    static var canUseNativeFinanceKit: Bool {
#if canImport(FinanceKit)
        if #available(iOS 17.4, *) {
            return entitlementEnabledInBuild
        }
#endif
        return false
    }

    static var availabilityMessage: String {
#if canImport(FinanceKit)
        guard #available(iOS 17.4, *) else {
            return "FinanceKit requires iOS 17.4 or later."
        }
        guard entitlementEnabledInBuild else {
            return "FinanceKit is compiled in, but disabled for this build until Apple's managed entitlement is granted and added to signing."
        }
        return "Ready to request Apple Wallet financial data access."
#else
        return "FinanceKit is not available in this SDK build."
#endif
    }

    static func loadSnapshot(limit: Int = 500) async throws -> FinanceKitSnapshot {
#if canImport(FinanceKit)
        if #available(iOS 17.4, *) {
            guard entitlementEnabledInBuild else {
                throw FinanceKitImportError.restricted
            }
            guard FinanceKit.FinanceStore.isDataAvailable(.financialData) else {
                throw FinanceKitImportError.unavailable
            }
            let store = FinanceKit.FinanceStore.shared
            let status = try await store.authorizationStatus()
            let authorized: Bool
            switch status {
            case .authorized:
                authorized = true
            case .notDetermined:
                authorized = try await store.requestAuthorization() == .authorized
            case .denied:
                authorized = false
            @unknown default:
                authorized = false
            }
            guard authorized else {
                throw FinanceKitImportError.denied
            }

            let accounts = try await store.accounts(query: FinanceKit.AccountQuery())
            let balances = try await store.accountBalances(query: FinanceKit.AccountBalanceQuery())
            let transactions = try await store.transactions(query: FinanceKit.TransactionQuery(limit: limit))
            let balanceByAccount = Dictionary(uniqueKeysWithValues: balances.map { ($0.accountID, $0) })
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

    private static var entitlementEnabledInBuild: Bool {
        Bundle.main.object(forInfoDictionaryKey: "FinanceKitManagedEntitlementEnabled") as? Bool == true
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
#endif

    private static func cents(_ decimal: Decimal) -> Int64 {
        let number = NSDecimalNumber(decimal: decimal * Decimal(100))
        return number.rounding(accordingToBehavior: nil).int64Value
    }
}
