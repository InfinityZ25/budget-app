import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import { getCurrentUserOrThrow } from "./users";

export const listForTransaction = query({
  args: { transactionId: v.id("transactions") },
  handler: async (ctx, args) => {
    const user = await getCurrentUserOrThrow(ctx);
    const transaction = await ctx.db.get(args.transactionId);
    if (!transaction || transaction.userId !== user._id) {
      throw new Error("Transaction not found");
    }
    return await ctx.db
      .query("receipts")
      .withIndex("by_transaction", (q) => q.eq("transactionId", args.transactionId))
      .collect();
  },
});

export const create = mutation({
  args: {
    transactionId: v.optional(v.id("transactions")),
    storageId: v.optional(v.id("_storage")),
    fileName: v.optional(v.string()),
    merchantName: v.optional(v.string()),
    purchasedAt: v.optional(v.number()),
    totalCents: v.optional(v.int64()),
    currencyCode: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const user = await getCurrentUserOrThrow(ctx);
    if (args.transactionId) {
      const transaction = await ctx.db.get(args.transactionId);
      if (!transaction || transaction.userId !== user._id) {
        throw new Error("Transaction not found");
      }
    }
    const now = Date.now();
    return await ctx.db.insert("receipts", {
      userId: user._id,
      transactionId: args.transactionId,
      storageId: args.storageId,
      fileName: args.fileName,
      merchantName: args.merchantName,
      purchasedAt: args.purchasedAt,
      totalCents: args.totalCents,
      currencyCode: args.currencyCode,
      ocrStatus: "pending",
      createdAt: now,
      updatedAt: now,
    });
  },
});

export const replaceLineItems = mutation({
  args: {
    receiptId: v.id("receipts"),
    items: v.array(
      v.object({
        name: v.string(),
        quantity: v.optional(v.string()),
        amountCents: v.int64(),
        categoryId: v.optional(v.id("categories")),
      }),
    ),
  },
  handler: async (ctx, args) => {
    const user = await getCurrentUserOrThrow(ctx);
    const receipt = await ctx.db.get(args.receiptId);
    if (!receipt || receipt.userId !== user._id) {
      throw new Error("Receipt not found");
    }

    const existing = await ctx.db
      .query("receiptLineItems")
      .withIndex("by_receipt", (q) => q.eq("receiptId", args.receiptId))
      .collect();
    for (const item of existing) {
      await ctx.db.delete(item._id);
    }

    const now = Date.now();
    for (const item of args.items) {
      await ctx.db.insert("receiptLineItems", {
        userId: user._id,
        receiptId: args.receiptId,
        transactionId: receipt.transactionId,
        name: item.name,
        quantity: item.quantity,
        amountCents: item.amountCents,
        categoryId: item.categoryId,
        createdAt: now,
        updatedAt: now,
      });
    }
    await ctx.db.patch(args.receiptId, { ocrStatus: "parsed", updatedAt: now });
  },
});
