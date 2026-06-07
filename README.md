# Budget App

Native iOS budgeting app plus a Go backend. The first slice supports Plaid Link token creation, public token exchange, encrypted Plaid access-token storage, account import, transaction sync, manual accounts, manual transactions, statement metadata, budgets, goals, and cashflow projection.

## Layout

- `backend`: Go 1.25 API using Fiber, MongoDB, and Plaid REST endpoints.
- `ios/BudgetApp`: SwiftUI native app scaffold with Apple-style navigation, system materials, financial summary surfaces, budgets, goals, and digital receipts.

## Backend Setup

Create `.env` in the repo root using `.env.example` as the shape. Required keys are `MONGO_URI`, `PLAID_CLIENT_ID`, `PLAID_SECRET`, and `TOKEN_ENCRYPTION_KEY`.

Generate a local encryption key with:

```sh
openssl rand -base64 32
```

Run the API:

```sh
cd backend
go run ./cmd/api
```

Useful endpoints:

- `GET /health`
- `POST /v1/plaid/link-token`
- `POST /v1/plaid/exchange-public-token`
- `POST /v1/plaid/items/:id/sync?user_id=...`
- `GET /v1/accounts?user_id=...`
- `POST /v1/accounts/manual`
- `GET /v1/transactions?user_id=...`
- `POST /v1/transactions/manual`
- `POST /v1/budgets/autogenerate`
- `POST /v1/cashflow/project`

## iOS Setup

Open the Swift package in Xcode:

```sh
open ios/BudgetApp/Package.swift
```

The app currently points to `http://localhost:8080/v1` through `APIClient.local`. For an iPhone device build, use your Mac LAN IP or a development API host instead of `localhost`.

## Product Notes

- Apple Wallet and Apple Card data should be integrated through FinanceKit where available. FinanceKit requires Apple-managed entitlements and user consent, so the app models a `financekit` source now but does not pretend arbitrary Wallet card data is available.
- Receipt scanning should use Vision/VisionKit on-device and send structured line items to the backend after user review.
- AI finance chat should be added behind a backend mediation layer so provider keys, audit logging, and privacy controls never live in the client.
