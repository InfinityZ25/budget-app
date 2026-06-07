import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import { getCurrentUserOrThrow } from "./users";

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
  if (existing) return existing;
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

async function defaultLegacyConversation(ctx: any, userId: any, title: string) {
  const existing = await ctx.db
    .query("assistantConversations")
    .withIndex("by_user_updated_at", (q: any) => q.eq("userId", userId))
    .order("desc")
    .first();
  if (existing) return existing;
  const now = Date.now();
  const id = await ctx.db.insert("assistantConversations", {
    userId,
    title,
    createdAt: now,
    updatedAt: now,
  });
  return await ctx.db.get(id);
}

function conversationPayload(conversation: any) {
  return {
    id: conversation._id,
    title: conversation.title,
    created_at: new Date(conversation.createdAt).toISOString(),
    updated_at: new Date(conversation.updatedAt).toISOString(),
  };
}

function messagePayload(message: any) {
  return {
    id: message._id,
    conversation_id: message.conversationId,
    role: message.role,
    content: message.content,
    model: message.model,
    created_at: new Date(message.createdAt).toISOString(),
  };
}

export const listConversations = query({
  args: { limit: v.optional(v.number()) },
  handler: async (ctx, args) => {
    const user = await getCurrentUserOrThrow(ctx);
    return await ctx.db
      .query("assistantConversations")
      .withIndex("by_user_updated_at", (q) => q.eq("userId", user._id))
      .order("desc")
      .take(Math.min(args.limit ?? 50, 100));
  },
});

export const listMessages = query({
  args: { conversationId: v.id("assistantConversations") },
  handler: async (ctx, args) => {
    const user = await getCurrentUserOrThrow(ctx);
    const conversation = await ctx.db.get(args.conversationId);
    if (!conversation || conversation.userId !== user._id) {
      throw new Error("Conversation not found");
    }
    return await ctx.db
      .query("assistantMessages")
      .withIndex("by_conversation", (q) => q.eq("conversationId", args.conversationId))
      .collect();
  },
});

export const createConversation = mutation({
  args: { title: v.optional(v.string()) },
  handler: async (ctx, args) => {
    const user = await getCurrentUserOrThrow(ctx);
    const now = Date.now();
    return await ctx.db.insert("assistantConversations", {
      userId: user._id,
      title: args.title ?? "New conversation",
      createdAt: now,
      updatedAt: now,
    });
  },
});

export const addMessage = mutation({
  args: {
    conversationId: v.id("assistantConversations"),
    role: v.union(v.literal("user"), v.literal("assistant"), v.literal("system")),
    content: v.string(),
    model: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const user = await getCurrentUserOrThrow(ctx);
    const conversation = await ctx.db.get(args.conversationId);
    if (!conversation || conversation.userId !== user._id) {
      throw new Error("Conversation not found");
    }
    const now = Date.now();
    const messageId = await ctx.db.insert("assistantMessages", {
      userId: user._id,
      conversationId: args.conversationId,
      role: args.role,
      content: args.content,
      model: args.model,
      createdAt: now,
    });
    const title =
      conversation.title === "New conversation" && args.role === "user"
        ? args.content.trim().slice(0, 48) || conversation.title
        : conversation.title;
    await ctx.db.patch(args.conversationId, { title, updatedAt: now });
    return messageId;
  },
});

export const legacyAddMessage = mutation({
  args: {
    userKey: v.string(),
    conversationId: v.optional(v.string()),
    role: v.union(v.literal("user"), v.literal("assistant"), v.literal("system")),
    content: v.string(),
    model: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const user = await ensureUserByLegacyKey(ctx, args.userKey);
    const requestedConversation: any = args.conversationId ? await ctx.db.get(args.conversationId as any) : null;
    const conversation =
      requestedConversation && requestedConversation.userId === user._id
        ? requestedConversation
        : await defaultLegacyConversation(ctx, user._id, "Assistant");
    const now = Date.now();
    const messageId = await ctx.db.insert("assistantMessages", {
      userId: user._id,
      conversationId: conversation._id,
      role: args.role,
      content: args.content,
      model: args.model,
      createdAt: now,
    });
    const title = conversation.title === "Assistant" && args.role === "user" ? args.content.trim().slice(0, 48) || conversation.title : conversation.title;
    await ctx.db.patch(conversation._id, { title, updatedAt: now });
    return {
      id: messageId,
      conversation_id: conversation._id,
      created_at: new Date(now).toISOString(),
    };
  },
});

export const legacyListConversations = query({
  args: { userKey: v.string(), limit: v.optional(v.number()) },
  handler: async (ctx, args) => {
    const user = await findUserByLegacyKey(ctx, args.userKey);
    if (!user) return [];
    const conversations = await ctx.db
      .query("assistantConversations")
      .withIndex("by_user_updated_at", (q: any) => q.eq("userId", user._id))
      .order("desc")
      .take(Math.min(args.limit ?? 50, 100));

    const rows = [];
    for (const conversation of conversations) {
      const messages = await ctx.db
        .query("assistantMessages")
        .withIndex("by_conversation", (q: any) => q.eq("conversationId", conversation._id))
        .collect();
      rows.push({
        ...conversationPayload(conversation),
        message_count: messages.length,
        last_message: messages.length > 0 ? messagePayload(messages[messages.length - 1]) : null,
      });
    }
    return rows;
  },
});

export const legacyListMessages = query({
  args: { userKey: v.string(), conversationId: v.string() },
  handler: async (ctx, args) => {
    const user = await findUserByLegacyKey(ctx, args.userKey);
    if (!user) return [];
    const conversation: any = await ctx.db.get(args.conversationId as any);
    if (!conversation || conversation.userId !== user._id) return [];
    const messages = await ctx.db
      .query("assistantMessages")
      .withIndex("by_conversation", (q: any) => q.eq("conversationId", conversation._id))
      .collect();
    return messages.map(messagePayload);
  },
});

export const legacyCreateConversation = mutation({
  args: { userKey: v.string(), title: v.optional(v.string()) },
  handler: async (ctx, args) => {
    const user = await ensureUserByLegacyKey(ctx, args.userKey);
    const now = Date.now();
    const id = await ctx.db.insert("assistantConversations", {
      userId: user._id,
      title: args.title ?? "New conversation",
      createdAt: now,
      updatedAt: now,
    });
    const conversation: any = await ctx.db.get(id);
    return conversationPayload(conversation);
  },
});

export const legacyDeleteConversation = mutation({
  args: { userKey: v.string(), conversationId: v.string() },
  handler: async (ctx, args) => {
    const user = await findUserByLegacyKey(ctx, args.userKey);
    if (!user) return { deleted: false };
    const conversation: any = await ctx.db.get(args.conversationId as any);
    if (!conversation || conversation.userId !== user._id) return { deleted: false };
    const messages = await ctx.db
      .query("assistantMessages")
      .withIndex("by_conversation", (q: any) => q.eq("conversationId", conversation._id))
      .collect();
    for (const message of messages) {
      await ctx.db.delete(message._id);
    }
    await ctx.db.delete(conversation._id);
    return { deleted: true };
  },
});
