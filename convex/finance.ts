// @ts-nocheck
import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import { getCurrentUserOrThrow } from "./users";

const providerKind = v.union(
  v.literal("plaid"),
  v.literal("financeKit"),
  v.literal("manual"),
  v.literal("statement"),
);

const accountSource = providerKind;

const transactionStatus = v.union(
  v.literal("pending"),
  v.literal("posted"),
  v.literal("removed"),
);

const categorySplitArg = v.object({
  categoryId: v.optional(v.id("categories")),
  name: v.string(),
  amountCents: v.int64(),
});

const legacyCategorySplitArg = v.object({
  categoryId: v.optional(v.string()),
  name: v.string(),
  amountCents: v.int64(),
});

const legacyStatementTransactionArg = v.object({
  description: v.string(),
  merchantName: v.optional(v.string()),
  amountCents: v.int64(),
  currencyCode: v.string(),
  postedAt: v.string(),
  externalTransactionId: v.optional(v.string()),
});

const legacyReceiptLineItemArg = v.object({
  name: v.string(),
  quantity: v.optional(v.string()),
  amountCents: v.int64(),
  categoryName: v.optional(v.string()),
});

async function findUserByLegacyKey(ctx: any, userKey: string) {
  const workosUserId = userKey.startsWith("legacy:") ? userKey : `legacy:${userKey}`;
  return await ctx.db
    .query("users")
    .withIndex("by_workos_user_id", (q: any) => q.eq("workosUserId", workosUserId))
    .unique();
}

async function ensureUserByLegacyKey(ctx: any, userKey: string) {
  const now = Date.now();
  const workosUserId = userKey.startsWith("legacy:") ? userKey : `legacy:${userKey}`;
  const existing = await findUserByLegacyKey(ctx, userKey);
  if (existing) {
    await ctx.db.patch(existing._id, { updatedAt: now });
    return existing;
  }
  const userId = await ctx.db.insert("users", {
    workosUserId,
    tokenIdentifier: workosUserId,
    email: `${userKey}@legacy.local`,
    name: userKey === "local-user" ? "Local Profile" : userKey,
    createdAt: now,
    updatedAt: now,
  });
  return await ctx.db.get(userId);
}

async function categoryByName(ctx: any, userId: any, name: string) {
  const normalizedName = (name || "Uncategorized").trim() || "Uncategorized";
  const existing = await ctx.db
    .query("categories")
    .withIndex("by_user", (q: any) => q.eq("userId", userId))
    .filter((q: any) => q.eq(q.field("name"), normalizedName))
    .first();
  if (existing) return existing;
  const now = Date.now();
  const id = await ctx.db.insert("categories", {
    userId,
    name: normalizedName,
    createdAt: now,
    updatedAt: now,
  });
  return await ctx.db.get(id);
}

function millisFromDateString(value: string | undefined) {
  if (!value) return Date.now();
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : Date.now();
}

function iso(value: number | undefined) {
  return new Date(value ?? Date.now()).toISOString();
}

function legacySource(source: string) {
  return source === "financeKit" ? "financekit" : source;
}

function signalStatusForMatch(transactionId: any | undefined) {
  return transactionId ? "suggested" : "unmatched";
}

async function findBestSignalMatch(ctx: any, userId: any, amountCents: bigint | undefined, merchantHint: string | undefined, occurredAt: number) {
  if (amountCents === undefined) return null;
  const oneWeek = 7 * 24 * 60 * 60 * 1000;
  const candidates = await ctx.db
    .query("transactions")
    .withIndex("by_user_amount", (q: any) => q.eq("userId", userId).eq("amountCents", amountCents))
    .take(50);
  const merchant = (merchantHint ?? "").trim().toLowerCase();
  let best: any = null;
  let bestScore = 0;
  for (const tx of candidates) {
    const timeDelta = Math.abs((tx.authorizedAt ?? tx.postedAt) - occurredAt);
    if (timeDelta > oneWeek) continue;
    const txMerchant = `${tx.merchantName ?? ""} ${tx.description ?? ""}`.trim().toLowerCase();
    let score = 0.65;
    score += Math.max(0, 0.25 * (1 - timeDelta / oneWeek));
    if (merchant && txMerchant.includes(merchant)) score += 0.1;
    if (score > bestScore) {
      best = tx;
      bestScore = score;
    }
  }
  return best ? { transaction: best, score: bestScore } : null;
}

async function insertTransactionSignal(ctx: any, args: any) {
  const now = Date.now();
  const matchedTransaction = args.matchedTransactionId ? await ctx.db.get(args.matchedTransactionId) : null;
  const match = matchedTransaction ? { transaction: matchedTransaction, score: args.confidence ?? 0.5 } : await findBestSignalMatch(ctx, args.userId, args.amountCents, args.merchantHint, args.occurredAt);
  const id = await ctx.db.insert("transactionSignals", {
    userId: args.userId,
    source: args.source,
    amountCents: args.amountCents,
    merchantHint: args.merchantHint,
    occurredAt: args.occurredAt,
    locationName: args.locationName,
    latitude: args.latitude,
    longitude: args.longitude,
    matchedTransactionId: match?.transaction?._id,
    confidence: match?.score ?? args.confidence ?? 0.2,
    status: signalStatusForMatch(match?.transaction?._id),
    raw: args.raw,
    createdAt: now,
    updatedAt: now,
  });
  return await ctx.db.get(id);
}

async function legacyAccount(ctx: any, account: any) {
  const provider = account.primaryProviderAccountId ? await ctx.db.get(account.primaryProviderAccountId) : null;
  const connection = provider?.connectionId ? await ctx.db.get(provider.connectionId) : null;
  return {
    id: account._id,
    user_id: account.userId,
    source: legacySource(account.source),
    name: account.name,
    official_name: account.officialName,
    type: account.type,
    subtype: account.subtype,
    currency_code: account.currencyCode,
    balance_cents: Number(account.balanceCents ?? 0n),
    credit_limit_cents: account.creditLimitCents === undefined ? undefined : Number(account.creditLimitCents),
    statement_close_day: account.statementCloseDay,
    payment_due_day: account.paymentDueDay,
    plaid_item_id: connection?.provider === "plaid" ? connection.externalConnectionId : undefined,
    plaid_account_id: provider?.provider === "plaid" ? provider.externalAccountId : undefined,
    created_at: iso(account.createdAt),
    updated_at: iso(account.updatedAt),
  };
}

async function legacyTransaction(ctx: any, tx: any) {
  const receiptItems = tx.receiptId
    ? await ctx.db
        .query("receiptLineItems")
        .withIndex("by_transaction", (q: any) => q.eq("transactionId", tx._id))
        .collect()
    : [];
  return {
    id: tx._id,
    user_id: tx.userId,
    account_id: tx.accountId,
    source: legacySource(tx.source),
    description: tx.description,
    merchant_name: tx.merchantName,
    amount_cents: Number(tx.amountCents),
    currency_code: tx.currencyCode,
    authorized_at: tx.authorizedAt === undefined ? undefined : iso(tx.authorizedAt),
    posted_at: iso(tx.postedAt),
    pending: tx.status === "pending",
    location_name: tx.locationName,
    category_splits: (tx.categorySplits ?? []).map((split: any) => ({
      category_id: split.categoryId,
      name: split.name,
      amount_cents: Number(split.amountCents),
    })),
    receipt_line_items: receiptItems.map((item: any) => ({
      name: item.name,
      quantity: item.quantity ?? "",
      amount_cents: Number(item.amountCents),
      category_id: item.categoryId,
    })),
    notes: tx.notes,
    created_at: iso(tx.createdAt),
    updated_at: iso(tx.updatedAt),
  };
}

async function legacyBudget(ctx: any, budget: any) {
  const category = await ctx.db.get(budget.categoryId);
  const now = new Date();
  const periodStart =
    budget.period === "weekly"
      ? new Date(now.getFullYear(), now.getMonth(), now.getDate() - now.getDay()).getTime()
      : new Date(now.getFullYear(), now.getMonth(), 1).getTime();
  const transactions = await ctx.db
    .query("transactions")
    .withIndex("by_user_posted_at", (q: any) => q.eq("userId", budget.userId))
    .order("desc")
    .take(1000);
  let spentCents = 0n;
  for (const tx of transactions) {
    if (tx.postedAt < periodStart) continue;
    for (const split of tx.categorySplits ?? []) {
      if (split.categoryId === budget.categoryId && split.amountCents < 0n) {
        spentCents += split.amountCents;
      }
    }
  }
  return {
    id: budget._id,
    user_id: budget.userId,
    category_id: budget.categoryId,
    category_name: category?.name ?? "Uncategorized",
    period: budget.period,
    limit_cents: Number(budget.limitCents),
    spent_cents: Number(spentCents),
  };
}

function isBudgetableCategory(name: string) {
  const lower = (name || "").toLowerCase();
  return !["income", "payroll", "transfer", "credit card payment", "loan payment", "internal account transfer", "deposit"].some((needle) =>
    lower.includes(needle),
  );
}

function categoryRulePattern(value: string | undefined) {
  return (value ?? "").trim().toLowerCase();
}

async function matchingCategoryRule(ctx: any, userId: any, merchantName: string | undefined, description: string | undefined) {
  const merchantPattern = categoryRulePattern(merchantName);
  if (merchantPattern) {
    const rule = await ctx.db
      .query("categoryRules")
      .withIndex("by_user_pattern", (q: any) => q.eq("userId", userId).eq("pattern", merchantPattern))
      .first();
    if (rule) return rule;
  }
  const descriptionPattern = categoryRulePattern(description);
  if (descriptionPattern) {
    return await ctx.db
      .query("categoryRules")
      .withIndex("by_user_pattern", (q: any) => q.eq("userId", userId).eq("pattern", descriptionPattern))
      .first();
  }
  return null;
}

async function ruleCategorySplit(ctx: any, rule: any, amountCents: bigint) {
  if (!rule) return null;
  const category = await ctx.db.get(rule.categoryId);
  if (!category) return null;
  return { categoryId: category._id, name: category.name, amountCents };
}

export const listAccounts = query({
  args: {},
  handler: async (ctx) => {
    const user = await getCurrentUserOrThrow(ctx);
    return await ctx.db
      .query("accounts")
      .withIndex("by_user", (q) => q.eq("userId", user._id))
      .collect();
  },
});

export const listTransactions = query({
  args: {
    accountId: v.optional(v.id("accounts")),
    limit: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const user = await getCurrentUserOrThrow(ctx);
    const limit = Math.min(args.limit ?? 100, 500);
    if (args.accountId) {
      const account = await ctx.db.get(args.accountId);
      if (!account || account.userId !== user._id) {
        throw new Error("Account not found");
      }
      return await ctx.db
        .query("transactions")
        .withIndex("by_user_account_posted_at", (q) =>
          q.eq("userId", user._id).eq("accountId", args.accountId!),
        )
        .order("desc")
        .take(limit);
    }
    return await ctx.db
      .query("transactions")
      .withIndex("by_user_posted_at", (q) => q.eq("userId", user._id))
      .order("desc")
      .take(limit);
  },
});

export const legacyListAccounts = query({
  args: { userKey: v.string() },
  handler: async (ctx, args) => {
    const user = await findUserByLegacyKey(ctx, args.userKey);
    if (!user) return [];
    const accounts = await ctx.db.query("accounts").withIndex("by_user", (q: any) => q.eq("userId", user._id)).collect();
    return await Promise.all(accounts.map((account: any) => legacyAccount(ctx, account)));
  },
});

export const legacyListTransactions = query({
  args: {
    userKey: v.string(),
    accountId: v.optional(v.string()),
    source: v.optional(v.string()),
    q: v.optional(v.string()),
    amountEq: v.optional(v.int64()),
    amountGt: v.optional(v.int64()),
    amountLt: v.optional(v.int64()),
    postedFrom: v.optional(v.number()),
    postedTo: v.optional(v.number()),
    sort: v.optional(v.string()),
    direction: v.optional(v.string()),
    limit: v.optional(v.number()),
    offset: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const user = await findUserByLegacyKey(ctx, args.userKey);
    if (!user) return [];
    const limit = Math.min(args.limit ?? 100, 1000);
    const offset = Math.max(args.offset ?? 0, 0);
    const scanLimit = Math.min(Math.max(limit + offset + 1, 1000), 5000);
    let rows = await ctx.db
      .query("transactions")
      .withIndex("by_user_posted_at", (q: any) => q.eq("userId", user._id))
      .order(args.direction === "asc" ? "asc" : "desc")
      .take(scanLimit);
    if (args.accountId) rows = rows.filter((tx: any) => tx.accountId === args.accountId);
    if (args.source) rows = rows.filter((tx: any) => legacySource(tx.source) === args.source);
    if (args.amountEq !== undefined) rows = rows.filter((tx: any) => tx.amountCents === args.amountEq);
    if (args.amountGt !== undefined) rows = rows.filter((tx: any) => tx.amountCents > args.amountGt!);
    if (args.amountLt !== undefined) rows = rows.filter((tx: any) => tx.amountCents < args.amountLt!);
    if (args.postedFrom !== undefined) rows = rows.filter((tx: any) => tx.postedAt >= args.postedFrom!);
    if (args.postedTo !== undefined) rows = rows.filter((tx: any) => tx.postedAt <= args.postedTo!);
    if (args.q) {
      const needle = args.q.toLowerCase();
      rows = rows.filter((tx: any) => [tx.description, tx.merchantName, tx.locationName, tx.notes].some((value) => (value ?? "").toLowerCase().includes(needle)));
    }
    if (args.sort === "amount") rows.sort((a: any, b: any) => Number(a.amountCents - b.amountCents));
    if (args.sort === "merchant") rows.sort((a: any, b: any) => (a.merchantName ?? a.description).localeCompare(b.merchantName ?? b.description));
    if (args.direction !== "asc" && args.sort !== undefined && args.sort !== "date") rows.reverse();
    return await Promise.all(rows.slice(offset, offset + limit).map((tx: any) => legacyTransaction(ctx, tx)));
  },
});

export const legacyListTransactionSignals = query({
  args: { userKey: v.string(), limit: v.optional(v.number()) },
  handler: async (ctx, args) => {
    const user = await findUserByLegacyKey(ctx, args.userKey);
    if (!user) return [];
    const rows = await ctx.db
      .query("transactionSignals")
      .withIndex("by_user_occurred_at", (q: any) => q.eq("userId", user._id))
      .order("desc")
      .take(Math.min(args.limit ?? 50, 200));
    return rows.map((signal: any) => ({
      id: signal._id,
      user_id: signal.userId,
      source: signal.source,
      amount_cents: signal.amountCents === undefined ? undefined : Number(signal.amountCents),
      merchant_hint: signal.merchantHint,
      occurred_at: iso(signal.occurredAt),
      location_name: signal.locationName,
      latitude: signal.latitude,
      longitude: signal.longitude,
      matched_transaction_id: signal.matchedTransactionId,
      confidence: signal.confidence,
      status: signal.status,
      created_at: iso(signal.createdAt),
      updated_at: iso(signal.updatedAt),
    }));
  },
});

export const legacyListBudgets = query({
  args: { userKey: v.string() },
  handler: async (ctx, args) => {
    const user = await findUserByLegacyKey(ctx, args.userKey);
    if (!user) return [];
    const budgets = await ctx.db.query("budgets").withIndex("by_user", (q: any) => q.eq("userId", user._id)).collect();
    return await Promise.all(budgets.map((budget: any) => legacyBudget(ctx, budget)));
  },
});

export const legacyListGoals = query({
  args: { userKey: v.string() },
  handler: async (ctx, args) => {
    const user = await findUserByLegacyKey(ctx, args.userKey);
    if (!user) return [];
    const goals = await ctx.db.query("goals").withIndex("by_user", (q: any) => q.eq("userId", user._id)).collect();
    return goals.map((goal: any) => ({
      id: goal._id,
      user_id: goal.userId,
      name: goal.name,
      type: goal.type,
      target_cents: Number(goal.targetCents),
      current_cents: Number(goal.currentCents),
      priority: goal.priority,
    }));
  },
});

export const legacyListStatements = query({
  args: { userKey: v.string() },
  handler: async (ctx, args) => {
    const user = await findUserByLegacyKey(ctx, args.userKey);
    if (!user) return [];
    const statements = await ctx.db.query("statements").withIndex("by_user", (q: any) => q.eq("userId", user._id)).collect();
    return statements.map((statement: any) => ({
      id: statement._id,
      user_id: statement.userId,
      account_id: statement.accountId,
      file_name: statement.fileName,
      file_type: statement.fileType,
      statement_start: iso(statement.statementStart),
      statement_end: iso(statement.statementEnd),
      imported_count: statement.importedCount,
      created_at: iso(statement.createdAt),
    }));
  },
});

export const legacyEnsureUser = mutation({
  args: { userKey: v.string(), email: v.optional(v.string()), name: v.optional(v.string()) },
  handler: async (ctx, args) => {
    const user = await ensureUserByLegacyKey(ctx, args.userKey);
    const patch: any = {};
    if (args.email) patch.email = args.email.trim().toLowerCase();
    if (args.name) patch.name = args.name;
    if (Object.keys(patch).length > 0) {
      patch.updatedAt = Date.now();
      await ctx.db.patch(user._id, patch);
    }
    const saved = await ctx.db.get(user._id);
    return {
      id: args.userKey,
      convex_id: saved!._id,
      email: saved!.email,
      name: saved!.name,
      created_at: iso(saved!.createdAt),
      updated_at: iso(saved!.updatedAt),
    };
  },
});

export const legacyListUsersForMigration = query({
  args: {},
  handler: async (ctx) => {
    const users = await ctx.db.query("users").collect();
    const out = [];
    for (const user of users) {
      const accounts = await ctx.db.query("accounts").withIndex("by_user", (q: any) => q.eq("userId", user._id)).collect();
      const transactions = await ctx.db.query("transactions").withIndex("by_user_posted_at", (q: any) => q.eq("userId", user._id)).take(1);
      out.push({
        id: user._id,
        workos_user_id: user.workosUserId,
        key: (user.workosUserId ?? "").startsWith("legacy:") ? user.workosUserId.slice("legacy:".length) : user.workosUserId,
        email: user.email,
        name: user.name,
        accounts: accounts.length,
        has_transactions: transactions.length > 0,
      });
    }
    return out;
  },
});

export const legacyFindDataOwnerByEmail = query({
  args: { email: v.string(), excludeUserKey: v.optional(v.string()) },
  handler: async (ctx, args) => {
    const normalizedEmail = args.email.trim().toLowerCase();
    if (!normalizedEmail) return null;
    const excludeUser = args.excludeUserKey ? await findUserByLegacyKey(ctx, args.excludeUserKey) : null;
    let users = await ctx.db
      .query("users")
      .withIndex("by_email", (q: any) => q.eq("email", normalizedEmail))
      .collect();
    if (users.length === 0) {
      users = (await ctx.db.query("users").collect()).filter((user: any) => (user.email ?? "").trim().toLowerCase() === normalizedEmail);
    }

    let best: any = null;
    let bestAccounts = 0;
    let bestHasTransactions = false;

    for (const user of users) {
      if (excludeUser && user._id === excludeUser._id) continue;
      const accounts = await ctx.db.query("accounts").withIndex("by_user", (q: any) => q.eq("userId", user._id)).collect();
      const transactions = await ctx.db.query("transactions").withIndex("by_user_posted_at", (q: any) => q.eq("userId", user._id)).take(1);
      if (!best || accounts.length > bestAccounts || (accounts.length === bestAccounts && transactions.length > 0 && !bestHasTransactions)) {
        best = user;
        bestAccounts = accounts.length;
        bestHasTransactions = transactions.length > 0;
      }
    }

    if (!best || bestAccounts === 0) return null;
    const key = (best.workosUserId ?? "").startsWith("legacy:") ? best.workosUserId.slice("legacy:".length) : best.workosUserId;
    return {
      user_id: best._id,
      key,
      email: best.email,
      accounts: bestAccounts,
      has_transactions: bestHasTransactions,
    };
  },
});

export const legacyMergeUserData = mutation({
  args: { fromUserKey: v.string(), toUserKey: v.string() },
  handler: async (ctx, args) => {
    if (args.fromUserKey === args.toUserKey) return { moved: 0, skipped: true };
    const fromUser = await findUserByLegacyKey(ctx, args.fromUserKey);
    const toUser = await ensureUserByLegacyKey(ctx, args.toUserKey);
    if (!fromUser) throw new Error("Source user not found");
    if (fromUser._id === toUser._id) return { moved: 0, skipped: true };
    const tables = [
      "connections",
      "providerSecrets",
      "accounts",
      "providerAccounts",
      "transactions",
      "transactionObservations",
      "transactionMatches",
      "transactionSignals",
      "receipts",
      "receiptLineItems",
      "categories",
      "categoryRules",
      "budgets",
      "recurringTransactions",
      "goals",
      "statements",
      "assistantConversations",
      "assistantMessages",
    ];
    let moved = 0;
    const now = Date.now();
    for (const table of tables) {
      const docs = await ctx.db.query(table as any).withIndex("by_user", (q: any) => q.eq("userId", fromUser._id)).collect();
      for (const doc of docs) {
        const patch: any = { userId: toUser._id };
        if (doc.updatedAt !== undefined) patch.updatedAt = now;
        await ctx.db.patch(doc._id, patch);
        moved += 1;
      }
    }
    await ctx.db.patch(toUser._id, { updatedAt: now });
    return { moved, from_user_id: fromUser._id, to_user_id: toUser._id };
  },
});

function accountMigrationKey(account: any) {
  return [
    account.source ?? "",
    account.type ?? "",
    account.subtype ?? "",
    (account.name ?? "").trim().toLowerCase(),
  ].join("|");
}

export const legacyAdoptMissingUserData = mutation({
  args: { fromUserKey: v.string(), toUserKey: v.string() },
  handler: async (ctx, args) => {
    if (!args.fromUserKey || args.fromUserKey === args.toUserKey) {
      return { moved: 0, moved_accounts: 0, skipped_accounts: 0, skipped: true };
    }

    const fromUser = await findUserByLegacyKey(ctx, args.fromUserKey);
    const toUser = await ensureUserByLegacyKey(ctx, args.toUserKey);
    if (!fromUser) {
      return { moved: 0, moved_accounts: 0, skipped_accounts: 0, skipped: true };
    }
    if (fromUser._id === toUser._id) {
      return { moved: 0, moved_accounts: 0, skipped_accounts: 0, skipped: true };
    }

    const now = Date.now();
    const destinationAccounts = await ctx.db
      .query("accounts")
      .withIndex("by_user", (q: any) => q.eq("userId", toUser._id))
      .collect();
    const destinationAccountsByKey = new Map(destinationAccounts.map((account: any) => [accountMigrationKey(account), account]));
    const destinationKeys = new Set(destinationAccountsByKey.keys());
    const sourceAccounts = await ctx.db
      .query("accounts")
      .withIndex("by_user", (q: any) => q.eq("userId", fromUser._id))
      .collect();

    const movedAccountIds = new Set<any>();
    const sourceAccountToDestinationAccount = new Map<any, any>();
    let skippedAccounts = 0;
    let moved = 0;

    for (const account of sourceAccounts) {
      const key = accountMigrationKey(account);
      if (destinationKeys.has(key)) {
        const destination = destinationAccountsByKey.get(key);
        if (destination?._id) sourceAccountToDestinationAccount.set(account._id, destination._id);
        skippedAccounts += 1;
        continue;
      }
      await ctx.db.patch(account._id, { userId: toUser._id, updatedAt: now });
      destinationKeys.add(key);
      destinationAccountsByKey.set(key, { ...account, userId: toUser._id });
      sourceAccountToDestinationAccount.set(account._id, account._id);
      movedAccountIds.add(account._id);
      moved += 1;
    }

    const movedProviderAccountIds = new Set<any>();
    const sourceProviderAccountToDestinationProviderAccount = new Map<any, any>();
    const movedConnectionIds = new Set<any>();
    const sourceProviderAccounts = await ctx.db
      .query("providerAccounts")
      .withIndex("by_user", (q: any) => q.eq("userId", fromUser._id))
      .collect();
    for (const providerAccount of sourceProviderAccounts) {
      if (!providerAccount.accountId) continue;
      const destinationAccountId = sourceAccountToDestinationAccount.get(providerAccount.accountId);
      if (!destinationAccountId) continue;

      const existingProviderAccount = await ctx.db
        .query("providerAccounts")
        .withIndex("by_user_provider_external", (q: any) =>
          q.eq("userId", toUser._id).eq("provider", providerAccount.provider).eq("externalAccountId", providerAccount.externalAccountId),
        )
        .unique();
      if (existingProviderAccount) {
        sourceProviderAccountToDestinationProviderAccount.set(providerAccount._id, existingProviderAccount._id);
        if (!existingProviderAccount.accountId && destinationAccountId) {
          await ctx.db.patch(existingProviderAccount._id, { accountId: destinationAccountId, updatedAt: now });
          moved += 1;
        }
      } else {
        await ctx.db.patch(providerAccount._id, { userId: toUser._id, accountId: destinationAccountId, updatedAt: now });
        sourceProviderAccountToDestinationProviderAccount.set(providerAccount._id, providerAccount._id);
        movedProviderAccountIds.add(providerAccount._id);
        moved += 1;
      }
      movedConnectionIds.add(providerAccount.connectionId);
    }

    for (const connectionId of movedConnectionIds) {
      const connection = await ctx.db.get(connectionId);
      if (connection && connection.userId === fromUser._id) {
        await ctx.db.patch(connectionId, { userId: toUser._id, updatedAt: now });
        moved += 1;
      }
      const secrets = await ctx.db
        .query("providerSecrets")
        .withIndex("by_connection", (q: any) => q.eq("connectionId", connectionId))
        .collect();
      for (const secret of secrets) {
        if (secret.userId !== fromUser._id) continue;
        await ctx.db.patch(secret._id, { userId: toUser._id, updatedAt: now });
        moved += 1;
      }
    }

    const movedTransactionIds = new Set<any>();
    const sourceTransactions = await ctx.db
      .query("transactions")
      .withIndex("by_user", (q: any) => q.eq("userId", fromUser._id))
      .collect();
    for (const transaction of sourceTransactions) {
      const destinationAccountId = sourceAccountToDestinationAccount.get(transaction.accountId);
      if (!destinationAccountId) continue;
      const patch: any = { userId: toUser._id, updatedAt: now };
      if (destinationAccountId !== transaction.accountId) patch.accountId = destinationAccountId;
      await ctx.db.patch(transaction._id, patch);
      movedTransactionIds.add(transaction._id);
      moved += 1;
    }

    const sourceObservations = await ctx.db
      .query("transactionObservations")
      .withIndex("by_user", (q: any) => q.eq("userId", fromUser._id))
      .collect();
    for (const observation of sourceObservations) {
      const belongsToMovedTransaction = observation.transactionId && movedTransactionIds.has(observation.transactionId);
      const destinationProviderAccountId = observation.providerAccountId
        ? sourceProviderAccountToDestinationProviderAccount.get(observation.providerAccountId)
        : undefined;
      const belongsToMovedProviderAccount = Boolean(destinationProviderAccountId);
      if (!belongsToMovedTransaction && !belongsToMovedProviderAccount) continue;
      const patch: any = { userId: toUser._id, updatedAt: now };
      if (destinationProviderAccountId && destinationProviderAccountId !== observation.providerAccountId) {
        patch.providerAccountId = destinationProviderAccountId;
      }
      await ctx.db.patch(observation._id, patch);
      moved += 1;
    }

    const sourceMatches = await ctx.db
      .query("transactionMatches")
      .withIndex("by_user", (q: any) => q.eq("userId", fromUser._id))
      .collect();
    for (const match of sourceMatches) {
      if (!movedTransactionIds.has(match.transactionId)) continue;
      await ctx.db.patch(match._id, { userId: toUser._id, updatedAt: now });
      moved += 1;
    }

    const movedReceiptIds = new Set<any>();
    const sourceReceipts = await ctx.db
      .query("receipts")
      .withIndex("by_user", (q: any) => q.eq("userId", fromUser._id))
      .collect();
    for (const receipt of sourceReceipts) {
      if (!receipt.transactionId || !movedTransactionIds.has(receipt.transactionId)) continue;
      await ctx.db.patch(receipt._id, { userId: toUser._id, updatedAt: now });
      movedReceiptIds.add(receipt._id);
      moved += 1;
    }

    const sourceReceiptLineItems = await ctx.db
      .query("receiptLineItems")
      .withIndex("by_user", (q: any) => q.eq("userId", fromUser._id))
      .collect();
    for (const item of sourceReceiptLineItems) {
      const belongsToMovedReceipt = movedReceiptIds.has(item.receiptId);
      const belongsToMovedTransaction = item.transactionId && movedTransactionIds.has(item.transactionId);
      if (!belongsToMovedReceipt && !belongsToMovedTransaction) continue;
      await ctx.db.patch(item._id, { userId: toUser._id, updatedAt: now });
      moved += 1;
    }

    const sourceStatements = await ctx.db
      .query("statements")
      .withIndex("by_user", (q: any) => q.eq("userId", fromUser._id))
      .collect();
    for (const statement of sourceStatements) {
      const destinationAccountId = sourceAccountToDestinationAccount.get(statement.accountId);
      if (!destinationAccountId) continue;
      const patch: any = { userId: toUser._id };
      if (destinationAccountId !== statement.accountId) patch.accountId = destinationAccountId;
      await ctx.db.patch(statement._id, patch);
      moved += 1;
    }

    const sourceSignals = await ctx.db
      .query("transactionSignals")
      .withIndex("by_user", (q: any) => q.eq("userId", fromUser._id))
      .collect();
    for (const signal of sourceSignals) {
      if (!signal.matchedTransactionId || !movedTransactionIds.has(signal.matchedTransactionId)) continue;
      await ctx.db.patch(signal._id, { userId: toUser._id, updatedAt: now });
      moved += 1;
    }

    await ctx.db.patch(toUser._id, { updatedAt: now });
    return {
      moved,
      moved_accounts: movedAccountIds.size,
      skipped_accounts: skippedAccounts,
      from_user_id: fromUser._id,
      to_user_id: toUser._id,
    };
  },
});

export const legacyCreateManualAccount = mutation({
  args: {
    userKey: v.string(),
    name: v.string(),
    type: v.string(),
    subtype: v.optional(v.string()),
    currencyCode: v.string(),
    balanceCents: v.int64(),
    creditLimitCents: v.optional(v.int64()),
    statementCloseDay: v.optional(v.number()),
    paymentDueDay: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const user = await ensureUserByLegacyKey(ctx, args.userKey);
    const now = Date.now();
    const id = await ctx.db.insert("accounts", {
      userId: user._id,
      source: "manual",
      name: args.name,
      type: args.type,
      subtype: args.subtype,
      currencyCode: args.currencyCode,
      balanceCents: args.balanceCents,
      creditLimitCents: args.creditLimitCents,
      statementCloseDay: args.statementCloseDay,
      paymentDueDay: args.paymentDueDay,
      createdAt: now,
      updatedAt: now,
    });
    return await legacyAccount(ctx, await ctx.db.get(id));
  },
});

export const legacyDeleteAccount = mutation({
  args: { userKey: v.string(), accountId: v.string() },
  handler: async (ctx, args) => {
    const user = await ensureUserByLegacyKey(ctx, args.userKey);
    const account = await ctx.db.get(args.accountId as any);
    if (!account || account.userId !== user._id) return { deleted: 0 };
    const txs = await ctx.db.query("transactions").withIndex("by_user_account_posted_at", (q: any) => q.eq("userId", user._id).eq("accountId", account._id)).collect();
    for (const tx of txs) await ctx.db.delete(tx._id);
    await ctx.db.delete(account._id);
    return { deleted: 1 };
  },
});

export const legacyCreateManualTransaction = mutation({
  args: {
    userKey: v.string(),
    accountId: v.string(),
    description: v.string(),
    merchantName: v.optional(v.string()),
    amountCents: v.int64(),
    currencyCode: v.string(),
    postedAt: v.string(),
    locationName: v.optional(v.string()),
    categorySplits: v.optional(v.array(legacyCategorySplitArg)),
    notes: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const user = await ensureUserByLegacyKey(ctx, args.userKey);
    const account = await ctx.db.get(args.accountId as any);
    if (!account || account.userId !== user._id) throw new Error("Account not found");
    const now = Date.now();
    const rule = await matchingCategoryRule(ctx, user._id, args.merchantName, args.description);
    const ruleSplit = await ruleCategorySplit(ctx, rule, args.amountCents);
    const splits = [];
    for (const split of args.categorySplits ?? []) {
      const category = await categoryByName(ctx, user._id, split.name);
      splits.push({ categoryId: category._id, name: split.name, amountCents: split.amountCents });
    }
    const id = await ctx.db.insert("transactions", {
      userId: user._id,
      accountId: account._id,
      description: args.description,
      merchantName: args.merchantName,
      amountCents: args.amountCents,
      currencyCode: args.currencyCode,
      postedAt: millisFromDateString(args.postedAt),
      status: "posted",
      source: "manual",
      locationName: args.locationName,
      categorySplits: ruleSplit ? [ruleSplit] : splits,
      notes: args.notes,
      createdAt: now,
      updatedAt: now,
    });
    return await legacyTransaction(ctx, await ctx.db.get(id));
  },
});

export const legacyUpdateTransactionCategory = mutation({
  args: {
    userKey: v.string(),
    transactionId: v.string(),
    categoryName: v.string(),
    applyToSimilar: v.optional(v.boolean()),
  },
  handler: async (ctx, args) => {
    const user = await ensureUserByLegacyKey(ctx, args.userKey);
    const transaction = await ctx.db.get(args.transactionId as any);
    if (!transaction || transaction.userId !== user._id) throw new Error("Transaction not found");
    const category = await categoryByName(ctx, user._id, args.categoryName);
    const now = Date.now();
    const categorySplits = [{ categoryId: category._id, name: category.name, amountCents: transaction.amountCents }];
    await ctx.db.patch(transaction._id, { categorySplits, updatedAt: now });

    if (args.applyToSimilar) {
      const pattern = categoryRulePattern(transaction.merchantName || transaction.description);
      if (pattern) {
        const existingRule = await ctx.db
          .query("categoryRules")
          .withIndex("by_user_pattern", (q: any) => q.eq("userId", user._id).eq("pattern", pattern))
          .first();
        const rulePatch = { categoryId: category._id, matchField: transaction.merchantName ? "merchantName" : "description", updatedAt: now };
        if (existingRule) {
          await ctx.db.patch(existingRule._id, rulePatch);
        } else {
          await ctx.db.insert("categoryRules", { userId: user._id, pattern, ...rulePatch, createdAt: now });
        }

        const rows = await ctx.db
          .query("transactions")
          .withIndex("by_user_posted_at", (q: any) => q.eq("userId", user._id))
          .take(1000);
        for (const row of rows) {
          const rowPattern = categoryRulePattern(row.merchantName || row.description);
          if (rowPattern === pattern) {
            await ctx.db.patch(row._id, { categorySplits: [{ categoryId: category._id, name: category.name, amountCents: row.amountCents }], updatedAt: now });
          }
        }
      }
    }

    return await legacyTransaction(ctx, await ctx.db.get(transaction._id));
  },
});

export const legacyUpsertTransactionReceipt = mutation({
  args: {
    userKey: v.string(),
    transactionId: v.string(),
    merchantName: v.optional(v.string()),
    purchasedAt: v.optional(v.string()),
    totalCents: v.optional(v.int64()),
    currencyCode: v.optional(v.string()),
    lineItems: v.array(legacyReceiptLineItemArg),
  },
  handler: async (ctx, args) => {
    const user = await ensureUserByLegacyKey(ctx, args.userKey);
    const transaction = await ctx.db.get(args.transactionId as any);
    if (!transaction || transaction.userId !== user._id) throw new Error("Transaction not found");
    const now = Date.now();
    let receiptId = transaction.receiptId;
    const receiptPatch = {
      transactionId: transaction._id,
      merchantName: args.merchantName || transaction.merchantName || transaction.description,
      purchasedAt: args.purchasedAt ? millisFromDateString(args.purchasedAt) : transaction.authorizedAt ?? transaction.postedAt,
      totalCents: args.totalCents ?? transaction.amountCents,
      currencyCode: args.currencyCode || transaction.currencyCode,
      ocrStatus: "parsed",
      updatedAt: now,
    };
    if (receiptId) {
      await ctx.db.patch(receiptId, receiptPatch);
      const existingItems = await ctx.db.query("receiptLineItems").withIndex("by_receipt", (q: any) => q.eq("receiptId", receiptId)).collect();
      for (const item of existingItems) {
        await ctx.db.delete(item._id);
      }
    } else {
      receiptId = await ctx.db.insert("receipts", {
        userId: user._id,
        createdAt: now,
        ...receiptPatch,
      });
      await ctx.db.patch(transaction._id, { receiptId, updatedAt: now });
    }

    for (const item of args.lineItems) {
      const name = item.name.trim();
      if (!name) continue;
      const category = item.categoryName ? await categoryByName(ctx, user._id, item.categoryName) : null;
      await ctx.db.insert("receiptLineItems", {
        userId: user._id,
        receiptId,
        transactionId: transaction._id,
        name,
        quantity: item.quantity,
        amountCents: item.amountCents,
        categoryId: category?._id,
        createdAt: now,
        updatedAt: now,
      });
    }

    return await legacyTransaction(ctx, await ctx.db.get(transaction._id));
  },
});

export const legacyCreateStatement = mutation({
  args: {
    userKey: v.string(),
    accountId: v.string(),
    fileName: v.string(),
    fileType: v.string(),
    statementStart: v.string(),
    statementEnd: v.string(),
    importedCount: v.number(),
  },
  handler: async (ctx, args) => {
    const user = await ensureUserByLegacyKey(ctx, args.userKey);
    const account = await ctx.db.get(args.accountId as any);
    if (!account || account.userId !== user._id) throw new Error("Account not found");
    const now = Date.now();
    const id = await ctx.db.insert("statements", {
      userId: user._id,
      accountId: account._id,
      fileName: args.fileName,
      fileType: args.fileType,
      statementStart: millisFromDateString(args.statementStart),
      statementEnd: millisFromDateString(args.statementEnd),
      importedCount: args.importedCount,
      createdAt: now,
    });
    const statement = await ctx.db.get(id);
    return {
      id: statement!._id,
      user_id: statement!.userId,
      account_id: statement!.accountId,
      file_name: statement!.fileName,
      file_type: statement!.fileType,
      statement_start: iso(statement!.statementStart),
      statement_end: iso(statement!.statementEnd),
      imported_count: statement!.importedCount,
      created_at: iso(statement!.createdAt),
    };
  },
});

export const legacyImportStatement = mutation({
  args: {
    userKey: v.string(),
    accountId: v.string(),
    fileName: v.string(),
    fileType: v.string(),
    statementStart: v.optional(v.string()),
    statementEnd: v.optional(v.string()),
    transactions: v.array(legacyStatementTransactionArg),
  },
  handler: async (ctx, args) => {
    const user = await ensureUserByLegacyKey(ctx, args.userKey);
    const account = await ctx.db.get(args.accountId as any);
    if (!account || account.userId !== user._id) throw new Error("Account not found");
    const now = Date.now();
    let imported = 0;
    let skipped = 0;
    for (let index = 0; index < args.transactions.length; index += 1) {
      const tx = args.transactions[index];
      const externalTransactionId =
        tx.externalTransactionId ??
        `statement:${account._id}:${args.fileName}:${tx.postedAt}:${tx.description}:${tx.amountCents}:${index}`;
      const existingObservation = await ctx.db
        .query("transactionObservations")
        .withIndex("by_user_provider_external", (q: any) => q.eq("userId", user._id).eq("provider", "statement").eq("externalTransactionId", externalTransactionId))
        .unique();
      if (existingObservation) {
        skipped += 1;
        continue;
      }
      const id = await ctx.db.insert("transactions", {
        userId: user._id,
        accountId: account._id,
        description: tx.description,
        merchantName: tx.merchantName,
        amountCents: tx.amountCents,
        currencyCode: tx.currencyCode,
        postedAt: millisFromDateString(tx.postedAt),
        status: "posted",
        source: "statement",
        createdAt: now,
        updatedAt: now,
      });
      await ctx.db.insert("transactionObservations", {
        userId: user._id,
        transactionId: id,
        provider: "statement",
        externalTransactionId,
        description: tx.description,
        merchantName: tx.merchantName,
        amountCents: tx.amountCents,
        currencyCode: tx.currencyCode,
        postedAt: millisFromDateString(tx.postedAt),
        status: "posted",
        createdAt: now,
        updatedAt: now,
      });
      imported += 1;
    }
    const statementId = await ctx.db.insert("statements", {
      userId: user._id,
      accountId: account._id,
      fileName: args.fileName,
      fileType: args.fileType,
      statementStart: millisFromDateString(args.statementStart),
      statementEnd: millisFromDateString(args.statementEnd),
      importedCount: imported,
      createdAt: now,
    });
    const statement = await ctx.db.get(statementId);
    return {
      statement: {
        id: statement!._id,
        user_id: statement!.userId,
        account_id: statement!.accountId,
        file_name: statement!.fileName,
        file_type: statement!.fileType,
        statement_start: iso(statement!.statementStart),
        statement_end: iso(statement!.statementEnd),
        imported_count: statement!.importedCount,
        created_at: iso(statement!.createdAt),
      },
      imported_count: imported,
      skipped_count: skipped,
    };
  },
});

export const legacyCreateBudget = mutation({
  args: { userKey: v.string(), categoryName: v.string(), period: v.string(), limitCents: v.int64() },
  handler: async (ctx, args) => {
    const user = await ensureUserByLegacyKey(ctx, args.userKey);
    const category = await categoryByName(ctx, user._id, args.categoryName);
    const now = Date.now();
    const id = await ctx.db.insert("budgets", {
      userId: user._id,
      categoryId: category._id,
      period: args.period || "monthly",
      limitCents: args.limitCents,
      spentCents: 0n,
      createdAt: now,
      updatedAt: now,
    });
    return await legacyBudget(ctx, await ctx.db.get(id));
  },
});

export const legacyUpdateBudget = mutation({
  args: { userKey: v.string(), budgetId: v.string(), categoryName: v.string(), period: v.string(), limitCents: v.int64() },
  handler: async (ctx, args) => {
    const user = await ensureUserByLegacyKey(ctx, args.userKey);
    const budget = await ctx.db.get(args.budgetId as any);
    if (!budget || budget.userId !== user._id) throw new Error("Budget not found");
    const category = await categoryByName(ctx, user._id, args.categoryName);
    await ctx.db.patch(budget._id, { categoryId: category._id, period: args.period || "monthly", limitCents: args.limitCents, updatedAt: Date.now() });
    return await legacyBudget(ctx, await ctx.db.get(budget._id));
  },
});

export const legacyDeleteBudget = mutation({
  args: { userKey: v.string(), budgetId: v.string() },
  handler: async (ctx, args) => {
    const user = await ensureUserByLegacyKey(ctx, args.userKey);
    const budget = await ctx.db.get(args.budgetId as any);
    if (!budget || budget.userId !== user._id) return { deleted: 0 };
    await ctx.db.delete(budget._id);
    return { deleted: 1 };
  },
});

export const legacyListBudgetIncomeOverrides = query({
  args: { userKey: v.string() },
  handler: async (ctx, args) => {
    const user = await findUserByLegacyKey(ctx, args.userKey);
    if (!user) return [];
    const rows = await ctx.db
      .query("budgetIncomeOverrides")
      .withIndex("by_user", (q: any) => q.eq("userId", user._id))
      .collect();
    return rows.map((row: any) => ({
      id: row._id,
      user_id: row.userId,
      transaction_id: row.transactionId,
      included: row.included,
      created_at: iso(row.createdAt),
      updated_at: iso(row.updatedAt),
    }));
  },
});

export const legacySetBudgetIncomeOverride = mutation({
  args: { userKey: v.string(), transactionId: v.string(), included: v.boolean() },
  handler: async (ctx, args) => {
    const user = await ensureUserByLegacyKey(ctx, args.userKey);
    const now = Date.now();
    const existing = await ctx.db
      .query("budgetIncomeOverrides")
      .withIndex("by_user_transaction", (q: any) => q.eq("userId", user._id).eq("transactionId", args.transactionId))
      .first();
    if (existing) {
      await ctx.db.patch(existing._id, { included: args.included, updatedAt: now });
      return {
        id: existing._id,
        user_id: user._id,
        transaction_id: args.transactionId,
        included: args.included,
        created_at: iso(existing.createdAt),
        updated_at: iso(now),
      };
    }
    const id = await ctx.db.insert("budgetIncomeOverrides", {
      userId: user._id,
      transactionId: args.transactionId,
      included: args.included,
      createdAt: now,
      updatedAt: now,
    });
    return {
      id,
      user_id: user._id,
      transaction_id: args.transactionId,
      included: args.included,
      created_at: iso(now),
      updated_at: iso(now),
    };
  },
});

function normalizeRecurringText(value: string | undefined) {
  return (value ?? "")
    .toLowerCase()
    .replace(/[0-9#*]+/g, " ")
    .replace(/[^a-z\s]/g, " ")
    .replace(/\b(pos|debit|card|purchase|online|payment|ach|web|check|inc|llc|co)\b/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function recurringTransferLike(tx: any) {
  const text = [tx.description, tx.merchantName, tx.categorySplits?.[0]?.name].filter(Boolean).join(" ").toLowerCase();
  return ["transfer", "credit card payment", "payment to", "payment from", "online transfer", "autopay payment"].some((needle) => text.includes(needle));
}

function recurringCadence(intervalDays: number, dates: number[]) {
  const daysOfMonth = dates.map((date) => new Date(date).getUTCDate()).sort((a, b) => a - b);
  const semimonthly = daysOfMonth.length >= 3 && daysOfMonth.some((day) => day <= 7) && daysOfMonth.some((day) => day >= 13 && day <= 20);
  if (intervalDays >= 5 && intervalDays <= 9) return "weekly";
  if (intervalDays >= 12 && intervalDays <= 17) return semimonthly ? "semimonthly" : "biweekly";
  if (intervalDays >= 25 && intervalDays <= 35) return "monthly";
  return "irregular";
}

function nextRecurringDate(lastSeenAt: number, cadence: string, intervalDays: number) {
  const day = 24 * 60 * 60 * 1000;
  if (cadence === "weekly") return lastSeenAt + 7 * day;
  if (cadence === "biweekly") return lastSeenAt + 14 * day;
  if (cadence === "semimonthly") return lastSeenAt + 15 * day;
  if (cadence === "monthly") {
    const date = new Date(lastSeenAt);
    date.setUTCMonth(date.getUTCMonth() + 1);
    return date.getTime();
  }
  if (intervalDays > 0) return lastSeenAt + intervalDays * day;
  return undefined;
}

function recurringConfidence(count: number, cadence: string, intervals: number[], amounts: bigint[]) {
  if (count < 2 || cadence === "irregular") return 0.35;
  const averageInterval = intervals.reduce((sum, value) => sum + value, 0) / Math.max(1, intervals.length);
  const intervalVariance = intervals.reduce((sum, value) => sum + Math.abs(value - averageInterval), 0) / Math.max(1, intervals.length);
  const numericAmounts = amounts.map((amount) => Number(amount < 0n ? -amount : amount));
  const averageAmount = numericAmounts.reduce((sum, value) => sum + value, 0) / Math.max(1, numericAmounts.length);
  const amountVariance = numericAmounts.reduce((sum, value) => sum + Math.abs(value - averageAmount), 0) / Math.max(1, numericAmounts.length);
  const amountPenalty = averageAmount > 0 ? Math.min(0.25, amountVariance / averageAmount) : 0.15;
  const intervalPenalty = Math.min(0.25, intervalVariance / 10);
  const countBonus = Math.min(0.2, (count - 2) * 0.05);
  return Math.max(0.45, Math.min(0.98, 0.78 + countBonus - amountPenalty - intervalPenalty));
}

async function legacyRecurringTransaction(ctx: any, row: any) {
  return {
    id: row._id,
    user_id: row.userId,
    kind: row.kind,
    status: row.status,
    cadence: row.cadence,
    normalized_key: row.normalizedKey,
    merchant_name: row.merchantName,
    category_name: row.categoryName,
    average_amount_cents: Number(row.averageAmountCents),
    last_amount_cents: Number(row.lastAmountCents),
    transaction_count: row.transactionCount,
    average_interval_days: row.averageIntervalDays,
    confidence: row.confidence,
    first_seen_at: iso(row.firstSeenAt),
    last_seen_at: iso(row.lastSeenAt),
    next_expected_at: row.nextExpectedAt ? iso(row.nextExpectedAt) : undefined,
    transaction_ids: row.transactionIds,
    created_at: iso(row.createdAt),
    updated_at: iso(row.updatedAt),
  };
}

export const legacyDetectRecurringTransactions = mutation({
  args: { userKey: v.string(), lookbackDays: v.optional(v.number()) },
  handler: async (ctx, args) => {
    const user = await ensureUserByLegacyKey(ctx, args.userKey);
    const now = Date.now();
    const lookbackDays = Math.max(60, Math.min(730, args.lookbackDays ?? 365));
    const cutoff = now - lookbackDays * 24 * 60 * 60 * 1000;
    const transactions = (await ctx.db
      .query("transactions")
      .withIndex("by_user_posted_at", (q: any) => q.eq("userId", user._id))
      .order("desc")
      .take(2000))
      .filter((tx: any) => tx.postedAt >= cutoff && tx.status !== "removed" && tx.amountCents !== 0n && !recurringTransferLike(tx));

    const groups = new Map<string, any[]>();
    for (const tx of transactions) {
      const kind = tx.amountCents > 0n ? "income" : "expense";
      const label = normalizeRecurringText(tx.merchantName || tx.description);
      if (!label || label.length < 3) continue;
      const category = normalizeRecurringText(tx.categorySplits?.[0]?.name);
      const key = [kind, label, category].filter(Boolean).join("|");
      const group = groups.get(key) ?? [];
      group.push(tx);
      groups.set(key, group);
    }

    const detected = [];
    for (const [key, group] of groups) {
      const sorted = group.sort((a, b) => a.postedAt - b.postedAt);
      if (sorted.length < 2) continue;
      const intervals = [];
      for (let index = 1; index < sorted.length; index += 1) {
        intervals.push(Math.round((sorted[index].postedAt - sorted[index - 1].postedAt) / (24 * 60 * 60 * 1000)));
      }
      const averageInterval = intervals.reduce((sum, value) => sum + value, 0) / Math.max(1, intervals.length);
      const cadence = recurringCadence(averageInterval, sorted.map((tx) => tx.postedAt));
      if (cadence === "irregular" && sorted.length < 4) continue;
      const amounts = sorted.map((tx) => tx.amountCents);
      const averageAmount = amounts.reduce((sum, value) => sum + value, 0n) / BigInt(amounts.length);
      const first = sorted[0];
      const last = sorted[sorted.length - 1];
      const confidence = recurringConfidence(sorted.length, cadence, intervals, amounts);
      if (confidence < 0.5) continue;
      const existing = await ctx.db
        .query("recurringTransactions")
        .withIndex("by_user_key", (q: any) => q.eq("userId", user._id).eq("normalizedKey", key))
        .unique();
      const payload = {
        userId: user._id,
        kind: first.amountCents > 0n ? "income" : "expense",
        status: existing?.status ?? "suggested",
        cadence,
        normalizedKey: key,
        merchantName: first.merchantName || first.description,
        categoryName: first.categorySplits?.[0]?.name,
        averageAmountCents: averageAmount,
        lastAmountCents: last.amountCents,
        transactionCount: sorted.length,
        averageIntervalDays: Math.round(averageInterval),
        confidence,
        firstSeenAt: first.postedAt,
        lastSeenAt: last.postedAt,
        nextExpectedAt: nextRecurringDate(last.postedAt, cadence, Math.round(averageInterval)),
        transactionIds: sorted.map((tx) => tx._id),
        updatedAt: now,
      };
      let recurringId = existing?._id;
      if (existing) {
        await ctx.db.patch(existing._id, payload);
      } else {
        recurringId = await ctx.db.insert("recurringTransactions", { ...payload, createdAt: now });
      }
      detected.push(await legacyRecurringTransaction(ctx, await ctx.db.get(recurringId)));
    }
    detected.sort((a, b) => b.confidence - a.confidence || Math.abs(b.average_amount_cents) - Math.abs(a.average_amount_cents));
    return detected;
  },
});

export const legacyListRecurringTransactions = query({
  args: { userKey: v.string(), kind: v.optional(v.union(v.literal("income"), v.literal("expense"))) },
  handler: async (ctx, args) => {
    const user = await findUserByLegacyKey(ctx, args.userKey);
    if (!user) return [];
    const rows = args.kind
      ? await ctx.db.query("recurringTransactions").withIndex("by_user_kind", (q: any) => q.eq("userId", user._id).eq("kind", args.kind)).collect()
      : await ctx.db.query("recurringTransactions").withIndex("by_user", (q: any) => q.eq("userId", user._id)).collect();
    const out = [];
    for (const row of rows) out.push(await legacyRecurringTransaction(ctx, row));
    out.sort((a, b) => {
      if (a.status !== b.status) return a.status === "suggested" ? -1 : 1;
      return Math.abs(b.average_amount_cents) - Math.abs(a.average_amount_cents);
    });
    return out;
  },
});

export const legacyUpdateRecurringTransactionStatus = mutation({
  args: { userKey: v.string(), recurringId: v.string(), status: v.union(v.literal("suggested"), v.literal("confirmed"), v.literal("ignored")) },
  handler: async (ctx, args) => {
    const user = await ensureUserByLegacyKey(ctx, args.userKey);
    const row: any = await ctx.db.get(args.recurringId as any);
    if (!row || row.userId !== user._id) throw new Error("Recurring transaction not found");
    await ctx.db.patch(row._id, { status: args.status, updatedAt: Date.now() });
    return await legacyRecurringTransaction(ctx, await ctx.db.get(row._id));
  },
});

export const legacyCreateBudgetAssistantProposal = mutation({
  args: { userKey: v.string(), prompt: v.string(), reply: v.string(), planJson: v.string() },
  handler: async (ctx, args) => {
    const user = await ensureUserByLegacyKey(ctx, args.userKey);
    const now = Date.now();
    const id = await ctx.db.insert("budgetAssistantProposals", {
      userId: user._id,
      prompt: args.prompt,
      reply: args.reply,
      planJson: args.planJson,
      status: "pending",
      createdAt: now,
      updatedAt: now,
    });
    return {
      id,
      user_id: user._id,
      prompt: args.prompt,
      reply: args.reply,
      plan_json: args.planJson,
      status: "pending",
      created_at: iso(now),
      updated_at: iso(now),
    };
  },
});

export const legacyLatestPendingBudgetAssistantProposal = query({
  args: { userKey: v.string() },
  handler: async (ctx, args) => {
    const user = await findUserByLegacyKey(ctx, args.userKey);
    if (!user) return null;
    const row = await ctx.db
      .query("budgetAssistantProposals")
      .withIndex("by_user_status", (q: any) => q.eq("userId", user._id).eq("status", "pending"))
      .order("desc")
      .first();
    if (!row) return null;
    return {
      id: row._id,
      user_id: row.userId,
      prompt: row.prompt,
      reply: row.reply,
      plan_json: row.planJson,
      status: row.status,
      created_at: iso(row.createdAt),
      updated_at: iso(row.updatedAt),
    };
  },
});

export const legacyListBudgetAssistantProposals = query({
  args: { userKey: v.string(), limit: v.optional(v.number()) },
  handler: async (ctx, args) => {
    const user = await findUserByLegacyKey(ctx, args.userKey);
    if (!user) return [];
    const rows = await ctx.db
      .query("budgetAssistantProposals")
      .withIndex("by_user", (q: any) => q.eq("userId", user._id))
      .order("desc")
      .take(Math.min(args.limit ?? 25, 100));
    return rows.map((row: any) => ({
      id: row._id,
      user_id: row.userId,
      prompt: row.prompt,
      reply: row.reply,
      plan_json: row.planJson,
      status: row.status,
      created_at: iso(row.createdAt),
      updated_at: iso(row.updatedAt),
    }));
  },
});

export const legacyUpdateBudgetAssistantProposalStatus = mutation({
  args: { userKey: v.string(), proposalId: v.string(), status: v.union(v.literal("pending"), v.literal("applied"), v.literal("dismissed")) },
  handler: async (ctx, args) => {
    const user = await ensureUserByLegacyKey(ctx, args.userKey);
    const proposal: any = await ctx.db.get(args.proposalId as any);
    if (!proposal || proposal.userId !== user._id) throw new Error("Proposal not found");
    const now = Date.now();
    await ctx.db.patch(proposal._id, { status: args.status, updatedAt: now });
    return {
      id: proposal._id,
      user_id: user._id,
      prompt: proposal.prompt,
      reply: proposal.reply,
      plan_json: proposal.planJson,
      status: args.status,
      created_at: iso(proposal.createdAt),
      updated_at: iso(now),
    };
  },
});

export const legacyAutoBudgets = mutation({
  args: { userKey: v.string() },
  handler: async (ctx, args) => {
    const user = await ensureUserByLegacyKey(ctx, args.userKey);
    const cutoff = Date.now() - 90 * 24 * 60 * 60 * 1000;
    const transactions = await ctx.db
      .query("transactions")
      .withIndex("by_user_posted_at", (q: any) => q.eq("userId", user._id))
      .order("desc")
      .take(1000);
    const grouped = new Map<string, { name: string; spent: bigint }>();
    for (const tx of transactions) {
      if (tx.postedAt < cutoff || tx.amountCents >= 0n) continue;
      const split = tx.categorySplits?.[0];
      const name = split?.name ?? "Uncategorized";
      if (!isBudgetableCategory(name)) continue;
      const key = split?.categoryId ?? `name:${name}`;
      const existing = grouped.get(key) ?? { name, spent: 0n };
      existing.spent += tx.amountCents;
      grouped.set(key, existing);
    }
    const recurringExpenses = await ctx.db
      .query("recurringTransactions")
      .withIndex("by_user_kind", (q: any) => q.eq("userId", user._id).eq("kind", "expense"))
      .collect();
    for (const recurring of recurringExpenses.filter((row: any) => row.status === "confirmed")) {
      const name = recurring.categoryName || recurring.merchantName || "Recurring Bills";
      if (!isBudgetableCategory(name)) continue;
      let monthlyAmount = recurring.averageAmountCents < 0n ? -recurring.averageAmountCents : recurring.averageAmountCents;
      if (recurring.cadence === "weekly") monthlyAmount = (monthlyAmount * 52n) / 12n;
      else if (recurring.cadence === "biweekly") monthlyAmount = (monthlyAmount * 26n) / 12n;
      else if (recurring.cadence === "semimonthly") monthlyAmount = monthlyAmount * 2n;
      else if (recurring.cadence !== "monthly" && recurring.averageIntervalDays > 0) {
        monthlyAmount = BigInt(Math.round((Number(monthlyAmount) * 30.4375) / recurring.averageIntervalDays));
      }
      const key = `recurring:${recurring.normalizedKey}`;
      const existing = grouped.get(key) ?? { name, spent: 0n };
      existing.spent -= monthlyAmount * 3n;
      grouped.set(key, existing);
    }
    if (grouped.size === 0) grouped.set("name:Uncategorized", { name: "Uncategorized", spent: -50000n });
    const out = [];
    const now = Date.now();
    for (const row of grouped.values()) {
      const category = await categoryByName(ctx, user._id, row.name);
      let limit = BigInt(Math.ceil(Number(-row.spent) / 3 / 100) * 100);
      if (limit < 10000n) limit = 10000n;
      const existing = await ctx.db
        .query("budgets")
        .withIndex("by_user_category_period", (q: any) => q.eq("userId", user._id).eq("categoryId", category._id).eq("period", "monthly"))
        .unique();
      let budgetId = existing?._id;
      if (existing) await ctx.db.patch(existing._id, { limitCents: limit, spentCents: -row.spent, updatedAt: now });
      else budgetId = await ctx.db.insert("budgets", { userId: user._id, categoryId: category._id, period: "monthly", limitCents: limit, spentCents: -row.spent, createdAt: now, updatedAt: now });
      out.push(await legacyBudget(ctx, await ctx.db.get(budgetId)));
    }
    return out;
  },
});

export const legacyCreateGoal = mutation({
  args: { userKey: v.string(), name: v.string(), type: v.string(), targetCents: v.int64(), currentCents: v.int64(), priority: v.number() },
  handler: async (ctx, args) => {
    const user = await ensureUserByLegacyKey(ctx, args.userKey);
    const now = Date.now();
    const id = await ctx.db.insert("goals", { userId: user._id, name: args.name, type: args.type, targetCents: args.targetCents, currentCents: args.currentCents, priority: args.priority, createdAt: now, updatedAt: now });
    const goal = await ctx.db.get(id);
    return { id: goal!._id, user_id: goal!.userId, name: goal!.name, type: goal!.type, target_cents: Number(goal!.targetCents), current_cents: Number(goal!.currentCents), priority: goal!.priority };
  },
});

export const legacyUpsertConnection = mutation({
  args: { userKey: v.string(), provider: providerKind, displayName: v.string(), externalConnectionId: v.string(), syncCursor: v.optional(v.string()), historicalBackfilledAt: v.optional(v.number()), encryptedPayload: v.optional(v.string()) },
  handler: async (ctx, args) => {
    const user = await ensureUserByLegacyKey(ctx, args.userKey);
    const now = Date.now();
    const existing = await ctx.db.query("connections").withIndex("by_provider_external", (q: any) => q.eq("provider", args.provider).eq("externalConnectionId", args.externalConnectionId)).unique();
    let connectionId;
    if (existing) {
      if (existing.userId !== user._id) throw new Error("Connection belongs to another user");
      await ctx.db.patch(existing._id, { displayName: args.displayName, status: "active", syncCursor: args.syncCursor ?? existing.syncCursor, historicalBackfilledAt: args.historicalBackfilledAt ?? existing.historicalBackfilledAt, lastSyncedAt: now, updatedAt: now });
      connectionId = existing._id;
    } else {
      connectionId = await ctx.db.insert("connections", { userId: user._id, provider: args.provider, displayName: args.displayName, status: "active", externalConnectionId: args.externalConnectionId, syncCursor: args.syncCursor, historicalBackfilledAt: args.historicalBackfilledAt, lastSyncedAt: now, createdAt: now, updatedAt: now });
    }
    if (args.encryptedPayload) {
      const existingSecret = await ctx.db.query("providerSecrets").withIndex("by_connection", (q: any) => q.eq("connectionId", connectionId)).first();
      if (existingSecret) await ctx.db.patch(existingSecret._id, { encryptedPayload: args.encryptedPayload, updatedAt: now });
      else await ctx.db.insert("providerSecrets", { userId: user._id, connectionId, provider: args.provider, encryptedPayload: args.encryptedPayload, createdAt: now, updatedAt: now });
    }
    return connectionId;
  },
});

export const legacyGetConnectionSecret = query({
  args: { userKey: v.string(), provider: providerKind, externalConnectionId: v.string() },
  handler: async (ctx, args) => {
    const user = await findUserByLegacyKey(ctx, args.userKey);
    if (!user) throw new Error("Connection not found");
    const connection = await ctx.db.query("connections").withIndex("by_provider_external", (q: any) => q.eq("provider", args.provider).eq("externalConnectionId", args.externalConnectionId)).unique();
    if (!connection || connection.userId !== user._id) throw new Error("Connection not found");
    const secret = await ctx.db.query("providerSecrets").withIndex("by_connection", (q: any) => q.eq("connectionId", connection._id)).first();
    return { connectionId: connection._id, syncCursor: connection.syncCursor, historical_backfilled_at: connection.historicalBackfilledAt, encryptedPayload: secret?.encryptedPayload ?? "" };
  },
});

export const legacyListPlaidConnections = query({
  args: { userKey: v.string() },
  handler: async (ctx, args) => {
    const user = await findUserByLegacyKey(ctx, args.userKey);
    if (!user) return [];
    const connections = await ctx.db.query("connections").withIndex("by_user_provider", (q: any) => q.eq("userId", user._id).eq("provider", "plaid")).collect();
    const out = [];
    for (const connection of connections) {
      const secret = await ctx.db.query("providerSecrets").withIndex("by_connection", (q: any) => q.eq("connectionId", connection._id)).first();
      out.push({ connection_id: connection._id, external_connection_id: connection.externalConnectionId, display_name: connection.displayName, sync_cursor: connection.syncCursor, historical_backfilled_at: connection.historicalBackfilledAt, encrypted_payload: secret?.encryptedPayload ?? "" });
    }
    return out;
  },
});

export const legacyGetPlaidConnectionByItemId = query({
  args: { externalConnectionId: v.string() },
  handler: async (ctx, args) => {
    const connection = await ctx.db.query("connections").withIndex("by_provider_external", (q: any) => q.eq("provider", "plaid").eq("externalConnectionId", args.externalConnectionId)).unique();
    if (!connection) throw new Error("Connection not found");
    const user = await ctx.db.get(connection.userId);
    if (!user) throw new Error("User not found");
    const secret = await ctx.db.query("providerSecrets").withIndex("by_connection", (q: any) => q.eq("connectionId", connection._id)).first();
    const userKey = (user.workosUserId ?? "").startsWith("legacy:") ? user.workosUserId.slice("legacy:".length) : user.workosUserId;
    return {
      user_key: userKey,
      connection_id: connection._id,
      external_connection_id: connection.externalConnectionId,
      display_name: connection.displayName,
      sync_cursor: connection.syncCursor,
      historical_backfilled_at: connection.historicalBackfilledAt,
      encrypted_payload: secret?.encryptedPayload ?? "",
    };
  },
});

export const legacyUpsertProviderAccount = mutation({
  args: { userKey: v.string(), connectionId: v.string(), provider: providerKind, externalAccountId: v.string(), displayName: v.string(), officialName: v.optional(v.string()), type: v.string(), subtype: v.optional(v.string()), currencyCode: v.string(), balanceCents: v.optional(v.int64()), creditLimitCents: v.optional(v.int64()) },
  handler: async (ctx, args) => {
    const user = await ensureUserByLegacyKey(ctx, args.userKey);
    const connection = await ctx.db.get(args.connectionId as any);
    if (!connection || connection.userId !== user._id) throw new Error("Connection not found");
    const now = Date.now();
    const existing = await ctx.db.query("providerAccounts").withIndex("by_user_provider_external", (q: any) => q.eq("userId", user._id).eq("provider", args.provider).eq("externalAccountId", args.externalAccountId)).unique();
    let accountId = existing?.accountId;
    const accountPatch = { name: args.displayName, officialName: args.officialName, type: args.type, subtype: args.subtype, currencyCode: args.currencyCode, balanceCents: args.balanceCents ?? 0n, creditLimitCents: args.creditLimitCents, updatedAt: now };
    if (accountId) await ctx.db.patch(accountId, accountPatch);
    else accountId = await ctx.db.insert("accounts", { userId: user._id, source: args.provider, ...accountPatch, createdAt: now });
    if (existing) await ctx.db.patch(existing._id, { accountId, connectionId: connection._id, displayName: args.displayName, officialName: args.officialName, type: args.type, subtype: args.subtype, currencyCode: args.currencyCode, balanceCents: args.balanceCents, creditLimitCents: args.creditLimitCents, updatedAt: now });
    else {
      const providerAccountId = await ctx.db.insert("providerAccounts", { userId: user._id, accountId, connectionId: connection._id, provider: args.provider, externalAccountId: args.externalAccountId, displayName: args.displayName, officialName: args.officialName, type: args.type, subtype: args.subtype, currencyCode: args.currencyCode, balanceCents: args.balanceCents, creditLimitCents: args.creditLimitCents, createdAt: now, updatedAt: now });
      await ctx.db.patch(accountId, { primaryProviderAccountId: providerAccountId });
    }
    return await legacyAccount(ctx, await ctx.db.get(accountId));
  },
});

export const legacyUpsertProviderTransaction = mutation({
  args: {
    userKey: v.string(),
    provider: providerKind,
    externalAccountId: v.string(),
    externalTransactionId: v.string(),
    description: v.string(),
    merchantName: v.optional(v.string()),
    amountCents: v.int64(),
    currencyCode: v.string(),
    authorizedAt: v.optional(v.string()),
    postedAt: v.string(),
    pending: v.boolean(),
    locationName: v.optional(v.string()),
    categorySplits: v.optional(v.array(legacyCategorySplitArg)),
    raw: v.optional(v.any()),
  },
  handler: async (ctx, args) => {
    const user = await ensureUserByLegacyKey(ctx, args.userKey);
    const providerAccount = await ctx.db.query("providerAccounts").withIndex("by_user_provider_external", (q: any) => q.eq("userId", user._id).eq("provider", args.provider).eq("externalAccountId", args.externalAccountId)).unique();
    if (!providerAccount || !providerAccount.accountId) throw new Error("Provider account not found");
    const now = Date.now();
    const existingObservation = await ctx.db.query("transactionObservations").withIndex("by_user_provider_external", (q: any) => q.eq("userId", user._id).eq("provider", args.provider).eq("externalTransactionId", args.externalTransactionId)).unique();
    const rule = await matchingCategoryRule(ctx, user._id, args.merchantName, args.description);
    const ruleSplit = await ruleCategorySplit(ctx, rule, args.amountCents);
    const splits = [];
    for (const split of args.categorySplits ?? []) {
      const category = await categoryByName(ctx, user._id, split.name);
      splits.push({ categoryId: category._id, name: category.name, amountCents: split.amountCents });
    }
    const authorizedAt = args.authorizedAt ? millisFromDateString(args.authorizedAt) : undefined;
    const canonicalPayload = { userId: user._id, accountId: providerAccount.accountId, description: args.description, merchantName: args.merchantName, amountCents: args.amountCents, currencyCode: args.currencyCode, authorizedAt, postedAt: millisFromDateString(args.postedAt), status: args.pending ? "pending" : "posted", source: args.provider, locationName: args.locationName, categorySplits: ruleSplit ? [ruleSplit] : splits, updatedAt: now };
    let transactionId = existingObservation?.transactionId;
    if (transactionId) await ctx.db.patch(transactionId, canonicalPayload);
    else transactionId = await ctx.db.insert("transactions", { ...canonicalPayload, createdAt: now });
    const observationPayload = { userId: user._id, transactionId, providerAccountId: providerAccount._id, provider: args.provider, externalTransactionId: args.externalTransactionId, description: args.description, merchantName: args.merchantName, amountCents: args.amountCents, currencyCode: args.currencyCode, authorizedAt, postedAt: millisFromDateString(args.postedAt), status: args.pending ? "pending" : "posted", locationName: args.locationName, raw: args.raw, updatedAt: now };
    if (existingObservation) await ctx.db.patch(existingObservation._id, observationPayload);
    else await ctx.db.insert("transactionObservations", { ...observationPayload, createdAt: now });
    if (!existingObservation && args.provider === "plaid") {
      await insertTransactionSignal(ctx, {
        userId: user._id,
        source: "plaid_first_seen",
        amountCents: args.amountCents,
        merchantHint: args.merchantName || args.description,
        occurredAt: authorizedAt ?? now,
        locationName: args.locationName,
        matchedTransactionId: transactionId,
        confidence: authorizedAt ? 0.65 : 0.35,
        raw: { externalTransactionId: args.externalTransactionId, firstSeenAt: now, authorizedAt },
      });
    }
    return await legacyTransaction(ctx, await ctx.db.get(transactionId));
  },
});

export const legacyCreateQuickTransactionSignal = mutation({
  args: {
    userKey: v.string(),
    amountCents: v.optional(v.int64()),
    merchantHint: v.optional(v.string()),
    occurredAt: v.string(),
    locationName: v.optional(v.string()),
    latitude: v.optional(v.number()),
    longitude: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const user = await ensureUserByLegacyKey(ctx, args.userKey);
    const signal = await insertTransactionSignal(ctx, {
      userId: user._id,
      source: "quick_add",
      amountCents: args.amountCents,
      merchantHint: args.merchantHint,
      occurredAt: millisFromDateString(args.occurredAt),
      locationName: args.locationName,
      latitude: args.latitude,
      longitude: args.longitude,
      confidence: 0.8,
    });
    return {
      id: signal._id,
      user_id: signal.userId,
      source: signal.source,
      amount_cents: signal.amountCents === undefined ? undefined : Number(signal.amountCents),
      merchant_hint: signal.merchantHint,
      occurred_at: iso(signal.occurredAt),
      location_name: signal.locationName,
      latitude: signal.latitude,
      longitude: signal.longitude,
      matched_transaction_id: signal.matchedTransactionId,
      confidence: signal.confidence,
      status: signal.status,
      created_at: iso(signal.createdAt),
      updated_at: iso(signal.updatedAt),
    };
  },
});

const legacyProviderAccountImportArg = v.object({
  externalAccountId: v.string(),
  displayName: v.string(),
  officialName: v.optional(v.string()),
  type: v.string(),
  subtype: v.optional(v.string()),
  currencyCode: v.string(),
  balanceCents: v.optional(v.int64()),
  creditLimitCents: v.optional(v.int64()),
});

const legacyProviderTransactionImportArg = v.object({
  externalAccountId: v.string(),
  externalTransactionId: v.string(),
  description: v.string(),
  merchantName: v.optional(v.string()),
  amountCents: v.int64(),
  currencyCode: v.string(),
  authorizedAt: v.optional(v.string()),
  postedAt: v.string(),
  pending: v.boolean(),
  locationName: v.optional(v.string()),
  raw: v.optional(v.any()),
});

export const legacyImportProviderSnapshot = mutation({
  args: {
    userKey: v.string(),
    provider: providerKind,
    displayName: v.string(),
    externalConnectionId: v.string(),
    accounts: v.array(legacyProviderAccountImportArg),
    transactions: v.array(legacyProviderTransactionImportArg),
  },
  handler: async (ctx, args) => {
    const user = await ensureUserByLegacyKey(ctx, args.userKey);
    const now = Date.now();
    const existingConnection = await ctx.db
      .query("connections")
      .withIndex("by_provider_external", (q: any) => q.eq("provider", args.provider).eq("externalConnectionId", args.externalConnectionId))
      .unique();
    let connectionId = existingConnection?._id;
    if (existingConnection) {
      if (existingConnection.userId !== user._id) throw new Error("Connection belongs to another user");
      await ctx.db.patch(existingConnection._id, { displayName: args.displayName, status: "active", lastSyncedAt: now, updatedAt: now });
    } else {
      connectionId = await ctx.db.insert("connections", {
        userId: user._id,
        provider: args.provider,
        displayName: args.displayName,
        status: "active",
        externalConnectionId: args.externalConnectionId,
        lastSyncedAt: now,
        createdAt: now,
        updatedAt: now,
      });
    }

    const accountIdsByExternal = new Map<string, any>();
    let accountsImported = 0;
    for (const account of args.accounts) {
      const existing = await ctx.db
        .query("providerAccounts")
        .withIndex("by_user_provider_external", (q: any) => q.eq("userId", user._id).eq("provider", args.provider).eq("externalAccountId", account.externalAccountId))
        .unique();
      let accountId = existing?.accountId;
      const accountPatch = {
        name: account.displayName,
        officialName: account.officialName,
        type: account.type,
        subtype: account.subtype,
        currencyCode: account.currencyCode,
        balanceCents: account.balanceCents ?? 0n,
        creditLimitCents: account.creditLimitCents,
        updatedAt: now,
      };
      if (accountId) await ctx.db.patch(accountId, accountPatch);
      else accountId = await ctx.db.insert("accounts", { userId: user._id, source: args.provider, ...accountPatch, createdAt: now });
      if (existing) {
        await ctx.db.patch(existing._id, {
          accountId,
          connectionId,
          displayName: account.displayName,
          officialName: account.officialName,
          type: account.type,
          subtype: account.subtype,
          currencyCode: account.currencyCode,
          balanceCents: account.balanceCents,
          creditLimitCents: account.creditLimitCents,
          updatedAt: now,
        });
      } else {
        const providerAccountId = await ctx.db.insert("providerAccounts", {
          userId: user._id,
          accountId,
          connectionId,
          provider: args.provider,
          externalAccountId: account.externalAccountId,
          displayName: account.displayName,
          officialName: account.officialName,
          type: account.type,
          subtype: account.subtype,
          currencyCode: account.currencyCode,
          balanceCents: account.balanceCents,
          creditLimitCents: account.creditLimitCents,
          createdAt: now,
          updatedAt: now,
        });
        await ctx.db.patch(accountId, { primaryProviderAccountId: providerAccountId });
      }
      accountIdsByExternal.set(account.externalAccountId, accountId);
      accountsImported += 1;
    }

    let transactionsImported = 0;
    for (const tx of args.transactions) {
      const accountId = accountIdsByExternal.get(tx.externalAccountId);
      if (!accountId) continue;
      const existingObservation = await ctx.db
        .query("transactionObservations")
        .withIndex("by_user_provider_external", (q: any) => q.eq("userId", user._id).eq("provider", args.provider).eq("externalTransactionId", tx.externalTransactionId))
        .unique();
      const rule = await matchingCategoryRule(ctx, user._id, tx.merchantName, tx.description);
      const ruleSplit = await ruleCategorySplit(ctx, rule, tx.amountCents);
      const authorizedAt = tx.authorizedAt ? millisFromDateString(tx.authorizedAt) : undefined;
      const canonicalPayload = {
        userId: user._id,
        accountId,
        description: tx.description,
        merchantName: tx.merchantName,
        amountCents: tx.amountCents,
        currencyCode: tx.currencyCode,
        authorizedAt,
        postedAt: millisFromDateString(tx.postedAt),
        status: tx.pending ? "pending" : "posted",
        source: args.provider,
        locationName: tx.locationName,
        categorySplits: ruleSplit ? [ruleSplit] : [],
        updatedAt: now,
      };
      let transactionId = existingObservation?.transactionId;
      if (transactionId) await ctx.db.patch(transactionId, canonicalPayload);
      else transactionId = await ctx.db.insert("transactions", { ...canonicalPayload, createdAt: now });
      const providerAccount = await ctx.db
        .query("providerAccounts")
        .withIndex("by_user_provider_external", (q: any) => q.eq("userId", user._id).eq("provider", args.provider).eq("externalAccountId", tx.externalAccountId))
        .unique();
      const observationPayload = {
        userId: user._id,
        transactionId,
        providerAccountId: providerAccount?._id,
        provider: args.provider,
        externalTransactionId: tx.externalTransactionId,
        description: tx.description,
        merchantName: tx.merchantName,
        amountCents: tx.amountCents,
        currencyCode: tx.currencyCode,
        authorizedAt,
        postedAt: millisFromDateString(tx.postedAt),
        status: tx.pending ? "pending" : "posted",
        locationName: tx.locationName,
        raw: tx.raw,
        updatedAt: now,
      };
      if (existingObservation) await ctx.db.patch(existingObservation._id, observationPayload);
      else await ctx.db.insert("transactionObservations", { ...observationPayload, createdAt: now });
      if (!existingObservation && args.provider === "financeKit" && authorizedAt !== undefined) {
        await insertTransactionSignal(ctx, {
          userId: user._id,
          source: "financekit_transaction_date",
          amountCents: tx.amountCents,
          merchantHint: tx.merchantName || tx.description,
          occurredAt: authorizedAt,
          locationName: tx.locationName,
          matchedTransactionId: transactionId,
          confidence: 0.9,
          raw: { externalTransactionId: tx.externalTransactionId },
        });
      }
      transactionsImported += 1;
    }

    return { accounts: accountsImported, transactions: transactionsImported };
  },
});

export const legacyRemoveProviderTransaction = mutation({
  args: { userKey: v.string(), provider: providerKind, externalTransactionId: v.string() },
  handler: async (ctx, args) => {
    const user = await ensureUserByLegacyKey(ctx, args.userKey);
    const observation = await ctx.db.query("transactionObservations").withIndex("by_user_provider_external", (q: any) => q.eq("userId", user._id).eq("provider", args.provider).eq("externalTransactionId", args.externalTransactionId)).unique();
    if (!observation || observation.userId !== user._id) return { removed: 0 };
    if (observation.transactionId) await ctx.db.delete(observation.transactionId);
    await ctx.db.delete(observation._id);
    return { removed: 1 };
  },
});

export const legacyUpdateConnectionCursor = mutation({
  args: { userKey: v.string(), provider: providerKind, externalConnectionId: v.string(), syncCursor: v.string(), historicalBackfilledAt: v.optional(v.number()) },
  handler: async (ctx, args) => {
    const user = await ensureUserByLegacyKey(ctx, args.userKey);
    const connection = await ctx.db.query("connections").withIndex("by_provider_external", (q: any) => q.eq("provider", args.provider).eq("externalConnectionId", args.externalConnectionId)).unique();
    if (!connection || connection.userId !== user._id) throw new Error("Connection not found");
    const now = Date.now();
    const patch: any = { syncCursor: args.syncCursor, lastSyncedAt: now, updatedAt: now };
    if (args.historicalBackfilledAt !== undefined) {
      patch.historicalBackfilledAt = args.historicalBackfilledAt;
    }
    await ctx.db.patch(connection._id, patch);
    return { ok: true };
  },
});

export const upsertConnection = mutation({
  args: {
    provider: providerKind,
    displayName: v.string(),
    externalConnectionId: v.optional(v.string()),
    syncCursor: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const user = await getCurrentUserOrThrow(ctx);
    const now = Date.now();
    const existing = args.externalConnectionId
      ? await ctx.db
          .query("connections")
          .withIndex("by_provider_external", (q) =>
            q.eq("provider", args.provider).eq("externalConnectionId", args.externalConnectionId),
          )
          .unique()
      : null;

    if (existing) {
      if (existing.userId !== user._id) {
        throw new Error("Connection belongs to another user");
      }
      await ctx.db.patch(existing._id, {
        displayName: args.displayName,
        status: "active",
        syncCursor: args.syncCursor,
        lastSyncedAt: now,
        updatedAt: now,
      });
      return existing._id;
    }

    return await ctx.db.insert("connections", {
      userId: user._id,
      provider: args.provider,
      displayName: args.displayName,
      status: "active",
      externalConnectionId: args.externalConnectionId,
      syncCursor: args.syncCursor,
      lastSyncedAt: now,
      createdAt: now,
      updatedAt: now,
    });
  },
});
