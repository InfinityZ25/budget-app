# Agent Handoff Guide

This repo is a native iOS budgeting app plus a Go/Fiber backend and Convex database. Treat Convex as the source of truth. MongoDB is legacy only for `backend/cmd/migrate-convex`.

## High-Priority Rules

- Do not commit secrets or personal financial data. `.env`, `.env.local`, `statements_examples/`, build folders, and DerivedData must stay ignored.
- Do not print secret values from `.env` in logs or final messages.
- Keep iOS changes Apple-native: SwiftUI, SF Symbols, system materials, clean motion, and Health/Wallet-style information density.
- Keep provider integrations server-mediated. Plaid, WorkOS, OpenRouter, xAI, and Convex deploy keys stay behind the Go API.
- FinanceKit is entitlement-gated. Keep fallback/status UI honest; do not imply arbitrary Wallet data can be accessed without Apple approval and user consent.

## Architecture

- iOS app: `ios/BudgetApp`
- Go API: `backend/cmd/api/main.go`
- Convex schema/functions: `convex/`
- Convex generated files: `convex/_generated/` are committed and should be regenerated after Convex function/schema changes.

Data flow:

1. SwiftUI calls `APIClient` in `ios/BudgetApp/Sources/BudgetApp/Networking/APIClient.swift`.
2. Go API validates/normalizes requests and talks to providers.
3. Go API stores and reads data through Convex functions.
4. iOS renders normalized accounts, transactions, budgets, cashflow, receipts, and assistant conversations.

## Local Runbook

Backend:

```sh
cd backend
go test ./...
go run ./cmd/api
```

Convex:

```sh
npm run convex:codegen
npm run convex:deploy
```

iOS:

```sh
open ios/BudgetApp/BudgetApp.xcodeproj
```

For a physical iPhone, update `APIClient.local` to the Mac LAN endpoint. `localhost` will not work from the phone.

## Common Validation

- Backend health: `curl http://localhost:8080/health`
- Backend tests: `cd backend && go test ./...`
- Convex codegen: `npm run convex:codegen`
- iOS device build: use Xcode or `xcodebuild -project ios/BudgetApp/BudgetApp.xcodeproj -scheme BudgetApp -destination 'id=DEVICE_ID' -configuration Debug build`

## Current Product State

Implemented areas include WorkOS sign-in, Plaid Link/sync/backfill, Convex-backed finance data, activity search/filter/refresh, Health-style cashflow chart, budgets with income review and transaction assignment, Budget AI, finance assistant chat with streaming/Markdown, xAI voice plumbing, statement import, and FinanceKit scaffolding.

Known gaps include FinanceKit entitlement approval, persistent income override settings, budget AI review/apply workflow, optimized historical Plaid backfill markers, richer receipt OCR/classification, and hardened production authorization middleware.

## Code Style

- Prefer small, direct changes over broad rewrites unless the user explicitly asks for a clean rewrite.
- Match existing SwiftUI styling from `Design/AppDesign.swift`.
- Keep Go handlers straightforward and move repeated provider/Convex logic into helpers only when it reduces duplication.
- For Convex, avoid writes inside queries. Use mutations for writes.
- After editing Go, run `gofmt` on changed files.
