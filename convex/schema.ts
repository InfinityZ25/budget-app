import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

const accountSource = v.union(
  v.literal("plaid"),
  v.literal("financeKit"),
  v.literal("manual"),
  v.literal("statement"),
);

const providerKind = v.union(
  v.literal("plaid"),
  v.literal("financeKit"),
  v.literal("manual"),
  v.literal("statement"),
);

const transactionStatus = v.union(
  v.literal("pending"),
  v.literal("posted"),
  v.literal("removed"),
);

const matchStatus = v.union(
  v.literal("suggested"),
  v.literal("confirmed"),
  v.literal("rejected"),
);

const transactionSignalSource = v.union(
  v.literal("plaid_first_seen"),
  v.literal("financekit_transaction_date"),
  v.literal("quick_add"),
  v.literal("receipt"),
  v.literal("email_alert"),
);

const categorySplit = v.object({
  categoryId: v.optional(v.id("categories")),
  name: v.string(),
  amountCents: v.int64(),
});

export default defineSchema({
  users: defineTable({
    workosUserId: v.string(),
    tokenIdentifier: v.string(),
    email: v.optional(v.string()),
    name: v.optional(v.string()),
    imageUrl: v.optional(v.string()),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_workos_user_id", ["workosUserId"])
    .index("by_token", ["tokenIdentifier"])
    .index("by_email", ["email"]),

  connections: defineTable({
    userId: v.id("users"),
    provider: providerKind,
    displayName: v.string(),
    status: v.union(v.literal("active"), v.literal("revoked"), v.literal("error")),
    externalConnectionId: v.optional(v.string()),
    lastSyncedAt: v.optional(v.number()),
    syncCursor: v.optional(v.string()),
    historicalBackfilledAt: v.optional(v.number()),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_user", ["userId"])
    .index("by_user_provider", ["userId", "provider"])
    .index("by_provider_external", ["provider", "externalConnectionId"]),

  providerSecrets: defineTable({
    userId: v.id("users"),
    connectionId: v.id("connections"),
    provider: providerKind,
    encryptedPayload: v.string(),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_user", ["userId"])
    .index("by_connection", ["connectionId"]),

  accounts: defineTable({
    userId: v.id("users"),
    source: accountSource,
    name: v.string(),
    officialName: v.optional(v.string()),
    type: v.string(),
    subtype: v.optional(v.string()),
    currencyCode: v.string(),
    balanceCents: v.int64(),
    creditLimitCents: v.optional(v.int64()),
    statementCloseDay: v.optional(v.number()),
    paymentDueDay: v.optional(v.number()),
    primaryProviderAccountId: v.optional(v.id("providerAccounts")),
    archivedAt: v.optional(v.number()),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_user", ["userId"])
    .index("by_user_source", ["userId", "source"]),

  providerAccounts: defineTable({
    userId: v.id("users"),
    accountId: v.optional(v.id("accounts")),
    connectionId: v.id("connections"),
    provider: providerKind,
    externalAccountId: v.string(),
    displayName: v.string(),
    officialName: v.optional(v.string()),
    type: v.string(),
    subtype: v.optional(v.string()),
    currencyCode: v.string(),
    balanceCents: v.optional(v.int64()),
    creditLimitCents: v.optional(v.int64()),
    metadata: v.optional(v.any()),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_user", ["userId"])
    .index("by_account", ["accountId"])
    .index("by_provider_external", ["provider", "externalAccountId"])
    .index("by_user_provider_external", ["userId", "provider", "externalAccountId"]),

  transactions: defineTable({
    userId: v.id("users"),
    accountId: v.id("accounts"),
    description: v.string(),
    merchantName: v.optional(v.string()),
    amountCents: v.int64(),
    currencyCode: v.string(),
    authorizedAt: v.optional(v.number()),
    postedAt: v.number(),
    status: transactionStatus,
    source: accountSource,
    locationName: v.optional(v.string()),
    categorySplits: v.optional(v.array(categorySplit)),
    notes: v.optional(v.string()),
    receiptId: v.optional(v.id("receipts")),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_user", ["userId"])
    .index("by_user_posted_at", ["userId", "postedAt"])
    .index("by_user_account_posted_at", ["userId", "accountId", "postedAt"])
    .index("by_user_amount", ["userId", "amountCents"])
    .searchIndex("search_description", {
      searchField: "description",
      filterFields: ["userId", "accountId", "source"],
    }),

  transactionObservations: defineTable({
    userId: v.id("users"),
    transactionId: v.optional(v.id("transactions")),
    providerAccountId: v.optional(v.id("providerAccounts")),
    provider: providerKind,
    externalTransactionId: v.string(),
    description: v.string(),
    merchantName: v.optional(v.string()),
    amountCents: v.int64(),
    currencyCode: v.string(),
    authorizedAt: v.optional(v.number()),
    postedAt: v.optional(v.number()),
    status: transactionStatus,
    locationName: v.optional(v.string()),
    raw: v.optional(v.any()),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_user", ["userId"])
    .index("by_transaction", ["transactionId"])
    .index("by_provider_external", ["provider", "externalTransactionId"])
    .index("by_user_provider_external", ["userId", "provider", "externalTransactionId"])
    .index("by_user_amount", ["userId", "amountCents"]),

  transactionMatches: defineTable({
    userId: v.id("users"),
    transactionId: v.id("transactions"),
    observationIds: v.array(v.id("transactionObservations")),
    status: matchStatus,
    score: v.number(),
    reason: v.string(),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_user", ["userId"])
    .index("by_transaction", ["transactionId"])
    .index("by_status", ["userId", "status"]),

  transactionSignals: defineTable({
    userId: v.id("users"),
    source: transactionSignalSource,
    amountCents: v.optional(v.int64()),
    merchantHint: v.optional(v.string()),
    occurredAt: v.number(),
    locationName: v.optional(v.string()),
    latitude: v.optional(v.number()),
    longitude: v.optional(v.number()),
    matchedTransactionId: v.optional(v.id("transactions")),
    confidence: v.number(),
    status: v.union(v.literal("unmatched"), v.literal("suggested"), v.literal("confirmed"), v.literal("rejected")),
    raw: v.optional(v.any()),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_user", ["userId"])
    .index("by_user_occurred_at", ["userId", "occurredAt"])
    .index("by_transaction", ["matchedTransactionId"])
    .index("by_user_status", ["userId", "status"]),

  receipts: defineTable({
    userId: v.id("users"),
    transactionId: v.optional(v.id("transactions")),
    storageId: v.optional(v.id("_storage")),
    fileName: v.optional(v.string()),
    merchantName: v.optional(v.string()),
    purchasedAt: v.optional(v.number()),
    totalCents: v.optional(v.int64()),
    currencyCode: v.optional(v.string()),
    ocrStatus: v.union(v.literal("pending"), v.literal("parsed"), v.literal("failed")),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_user", ["userId"])
    .index("by_transaction", ["transactionId"]),

  receiptLineItems: defineTable({
    userId: v.id("users"),
    receiptId: v.id("receipts"),
    transactionId: v.optional(v.id("transactions")),
    name: v.string(),
    quantity: v.optional(v.string()),
    amountCents: v.int64(),
    categoryId: v.optional(v.id("categories")),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_user", ["userId"])
    .index("by_receipt", ["receiptId"])
    .index("by_transaction", ["transactionId"]),

  categories: defineTable({
    userId: v.id("users"),
    name: v.string(),
    parentCategoryId: v.optional(v.id("categories")),
    color: v.optional(v.string()),
    icon: v.optional(v.string()),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_user", ["userId"])
    .index("by_parent", ["userId", "parentCategoryId"]),

  budgets: defineTable({
    userId: v.id("users"),
    categoryId: v.id("categories"),
    period: v.string(),
    limitCents: v.int64(),
    spentCents: v.int64(),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_user", ["userId"])
    .index("by_user_category_period", ["userId", "categoryId", "period"]),

  budgetIncomeOverrides: defineTable({
    userId: v.id("users"),
    transactionId: v.string(),
    included: v.boolean(),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_user", ["userId"])
    .index("by_user_transaction", ["userId", "transactionId"]),

  recurringTransactions: defineTable({
    userId: v.id("users"),
    kind: v.union(v.literal("income"), v.literal("expense")),
    status: v.union(v.literal("suggested"), v.literal("confirmed"), v.literal("ignored")),
    cadence: v.union(v.literal("weekly"), v.literal("biweekly"), v.literal("semimonthly"), v.literal("monthly"), v.literal("irregular")),
    normalizedKey: v.string(),
    merchantName: v.string(),
    categoryName: v.optional(v.string()),
    averageAmountCents: v.int64(),
    lastAmountCents: v.int64(),
    transactionCount: v.number(),
    averageIntervalDays: v.number(),
    confidence: v.number(),
    firstSeenAt: v.number(),
    lastSeenAt: v.number(),
    nextExpectedAt: v.optional(v.number()),
    transactionIds: v.array(v.id("transactions")),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_user", ["userId"])
    .index("by_user_kind", ["userId", "kind"])
    .index("by_user_status", ["userId", "status"])
    .index("by_user_key", ["userId", "normalizedKey"]),

  budgetAssistantProposals: defineTable({
    userId: v.id("users"),
    prompt: v.string(),
    reply: v.string(),
    planJson: v.string(),
    status: v.union(v.literal("pending"), v.literal("applied"), v.literal("dismissed")),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_user_status", ["userId", "status", "updatedAt"])
    .index("by_user", ["userId"]),

  categoryRules: defineTable({
    userId: v.id("users"),
    pattern: v.string(),
    categoryId: v.id("categories"),
    matchField: v.string(),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_user", ["userId"])
    .index("by_user_pattern", ["userId", "pattern"]),

  goals: defineTable({
    userId: v.id("users"),
    name: v.string(),
    type: v.string(),
    targetCents: v.int64(),
    currentCents: v.int64(),
    priority: v.number(),
    createdAt: v.number(),
    updatedAt: v.number(),
  }).index("by_user", ["userId"]),

  statements: defineTable({
    userId: v.id("users"),
    accountId: v.id("accounts"),
    storageId: v.optional(v.id("_storage")),
    fileName: v.string(),
    fileType: v.string(),
    statementStart: v.number(),
    statementEnd: v.number(),
    importedCount: v.number(),
    createdAt: v.number(),
  })
    .index("by_user", ["userId"])
    .index("by_account", ["accountId"]),

  assistantConversations: defineTable({
    userId: v.id("users"),
    title: v.string(),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_user", ["userId"])
    .index("by_user_updated_at", ["userId", "updatedAt"]),

  assistantMessages: defineTable({
    userId: v.id("users"),
    conversationId: v.id("assistantConversations"),
    role: v.union(v.literal("user"), v.literal("assistant"), v.literal("system")),
    content: v.string(),
    model: v.optional(v.string()),
    createdAt: v.number(),
  })
    .index("by_user", ["userId"])
    .index("by_conversation", ["conversationId", "createdAt"]),
});
