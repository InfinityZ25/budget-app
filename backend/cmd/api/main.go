package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/csv"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"math"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/gofiber/fiber/v2"
	"github.com/joho/godotenv"
	pdfreader "github.com/ledongthuc/pdf"
	"github.com/workos/workos-go/v4/pkg/usermanagement"
)

type config struct {
	Port, PlaidBaseURL, PlaidClientID, PlaidSecret, TokenEncryptionKey string
	WorkOSAPIKey, WorkOSClientID, WorkOSRedirectURI                    string
	ConvexURL, ConvexDeployKey                                         string
}

type accountSource string

const (
	sourcePlaid      accountSource = "plaid"
	sourceManual     accountSource = "manual"
	sourceFinanceKit accountSource = "financekit"
)

type account struct {
	ID                string        `json:"id"`
	UserID            string        `json:"user_id"`
	Source            accountSource `json:"source"`
	Name              string        `json:"name"`
	OfficialName      string        `json:"official_name,omitempty"`
	Type              string        `json:"type"`
	Subtype           string        `json:"subtype,omitempty"`
	CurrencyCode      string        `json:"currency_code"`
	BalanceCents      int64         `json:"balance_cents"`
	CreditLimitCents  int64         `json:"credit_limit_cents,omitempty"`
	StatementCloseDay int           `json:"statement_close_day,omitempty"`
	PaymentDueDay     int           `json:"payment_due_day,omitempty"`
	PlaidItemID       string        `json:"plaid_item_id,omitempty"`
	PlaidAccountID    string        `json:"plaid_account_id,omitempty"`
	FinanceKitID      string        `json:"financekit_id,omitempty"`
	CreatedAt         time.Time     `json:"created_at"`
	UpdatedAt         time.Time     `json:"updated_at"`
}
type plaidSyncItem struct {
	UserID                string `json:"user_key"`
	ItemID                string `json:"external_connection_id"`
	DisplayName           string `json:"display_name"`
	TransactionsCursor    string `json:"sync_cursor"`
	AccessTokenCiphertext string `json:"encrypted_payload"`
}
type categorySplit struct {
	CategoryID  string `json:"category_id"`
	Name        string `json:"name"`
	AmountCents int64  `json:"amount_cents"`
}
type receiptLineItem struct {
	Name        string `json:"name"`
	Quantity    string `json:"quantity,omitempty"`
	AmountCents int64  `json:"amount_cents"`
	CategoryID  string `json:"category_id,omitempty"`
}
type transaction struct {
	ID               string            `json:"id"`
	UserID           string            `json:"user_id"`
	AccountID        string            `json:"account_id"`
	Source           accountSource     `json:"source"`
	ExternalID       string            `json:"external_id,omitempty"`
	Description      string            `json:"description"`
	MerchantName     string            `json:"merchant_name,omitempty"`
	AmountCents      int64             `json:"amount_cents"`
	CurrencyCode     string            `json:"currency_code"`
	PostedAt         time.Time         `json:"posted_at"`
	Pending          bool              `json:"pending"`
	LocationName     string            `json:"location_name,omitempty"`
	CategorySplits   []categorySplit   `json:"category_splits,omitempty"`
	ReceiptLineItems []receiptLineItem `json:"receipt_line_items,omitempty"`
	Notes            string            `json:"notes,omitempty"`
	CreatedAt        time.Time         `json:"created_at"`
	UpdatedAt        time.Time         `json:"updated_at"`
}
type apiAccount struct {
	ID                string        `json:"id"`
	UserID            string        `json:"user_id"`
	Source            accountSource `json:"source"`
	Name              string        `json:"name"`
	Type              string        `json:"type"`
	BalanceCents      int64         `json:"balance_cents"`
	CreditLimitCents  int64         `json:"credit_limit_cents"`
	StatementCloseDay int           `json:"statement_close_day"`
	PaymentDueDay     int           `json:"payment_due_day"`
}
type apiTransaction struct {
	ID           string        `json:"id"`
	UserID       string        `json:"user_id"`
	AccountID    string        `json:"account_id"`
	Source       accountSource `json:"source"`
	Description  string        `json:"description"`
	MerchantName string        `json:"merchant_name"`
	AmountCents  int64         `json:"amount_cents"`
	PostedAt     time.Time     `json:"posted_at"`
	Pending      bool          `json:"pending"`
}
type budget struct {
	ID           string    `json:"id"`
	UserID       string    `json:"user_id"`
	CategoryID   string    `json:"category_id"`
	CategoryName string    `json:"category_name"`
	Period       string    `json:"period"`
	LimitCents   int64     `json:"limit_cents"`
	SpentCents   int64     `json:"spent_cents"`
	CreatedAt    time.Time `json:"created_at"`
	UpdatedAt    time.Time `json:"updated_at"`
}
type goal struct {
	ID           string    `json:"id"`
	UserID       string    `json:"user_id"`
	Name         string    `json:"name"`
	Type         string    `json:"type"`
	TargetCents  int64     `json:"target_cents"`
	CurrentCents int64     `json:"current_cents"`
	Priority     int       `json:"priority"`
	CreatedAt    time.Time `json:"created_at"`
	UpdatedAt    time.Time `json:"updated_at"`
}

type financeKitImportRequest struct {
	UserID       string                         `json:"user_id"`
	Accounts     []financeKitAccountPayload     `json:"accounts"`
	Transactions []financeKitTransactionPayload `json:"transactions"`
}
type financeKitAccountPayload struct {
	ID                string `json:"id"`
	Name              string `json:"name"`
	OfficialName      string `json:"official_name"`
	InstitutionName   string `json:"institution_name"`
	Type              string `json:"type"`
	Subtype           string `json:"subtype"`
	CurrencyCode      string `json:"currency_code"`
	BalanceCents      int64  `json:"balance_cents"`
	CreditLimitCents  int64  `json:"credit_limit_cents"`
	StatementCloseDay int    `json:"statement_close_day"`
	PaymentDueDay     int    `json:"payment_due_day"`
}
type financeKitTransactionPayload struct {
	ID              string    `json:"id"`
	AccountID       string    `json:"account_id"`
	Description     string    `json:"description"`
	MerchantName    string    `json:"merchant_name"`
	AmountCents     int64     `json:"amount_cents"`
	CurrencyCode    string    `json:"currency_code"`
	PostedAt        time.Time `json:"posted_at"`
	Pending         bool      `json:"pending"`
	LocationName    string    `json:"location_name"`
	TransactionType string    `json:"transaction_type"`
	Status          string    `json:"status"`
}

type tokenCipher struct{ aead cipher.AEAD }
type plaidClient struct {
	baseURL, clientID, secret string
	httpClient                *http.Client
}
type convexClient struct {
	deploymentURL string
	deployKey     string
	httpClient    *http.Client
}
type server struct {
	cipher   *tokenCipher
	plaid    *plaidClient
	convex   *convexClient
	auth     *usermanagement.Client
	authConf authConfig
}

type authConfig struct {
	clientID    string
	redirectURI string
}

func main() {
	cfg, err := loadConfig()
	if err != nil {
		log.Fatal(err)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	cipher, err := newTokenCipher(cfg.TokenEncryptionKey)
	if err != nil {
		log.Fatal(err)
	}
	srv := &server{
		cipher: cipher,
		plaid:  &plaidClient{baseURL: cfg.PlaidBaseURL, clientID: cfg.PlaidClientID, secret: cfg.PlaidSecret, httpClient: &http.Client{Timeout: 20 * time.Second}},
		convex: &convexClient{
			deploymentURL: cfg.ConvexURL,
			deployKey:     cfg.ConvexDeployKey,
			httpClient:    &http.Client{Timeout: 30 * time.Second},
		},
		auth: usermanagement.NewClient(cfg.WorkOSAPIKey),
		authConf: authConfig{
			clientID:    cfg.WorkOSClientID,
			redirectURI: cfg.WorkOSRedirectURI,
		},
	}
	app := srv.routes()
	go func() {
		if err := app.Listen(":" + cfg.Port); err != nil {
			log.Print(err)
			stop()
		}
	}()
	<-ctx.Done()
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = app.ShutdownWithContext(shutdownCtx)
}

func loadConfig() (config, error) {
	_ = godotenv.Load(".env")
	if cwd, err := os.Getwd(); err == nil {
		_ = godotenv.Load(filepath.Join(cwd, "..", ".env"))
		_ = godotenv.Load(filepath.Join(cwd, "..", "..", "Documents", "repos", "hynix", "budget-app", ".env"))
	}
	plaidEnv := env("PLAID_ENV", "production")
	convexDeployment := strings.TrimPrefix(os.Getenv("CONVEX_DEPLOYMENT"), "prod:")
	convexURL := env("CONVEX_URL", "")
	if convexURL == "" && strings.HasPrefix(convexDeployment, "http") {
		convexURL = strings.TrimRight(convexDeployment, "/")
	} else if convexURL == "" && convexDeployment != "" {
		convexURL = "https://" + convexDeployment + ".convex.cloud"
	}
	plaidSecret := os.Getenv("PLAID_SECRET")
	if plaidSecret == "" && plaidEnv == "production" {
		plaidSecret = os.Getenv("PLAID_SECRET_PROD")
	}
	if plaidSecret == "" {
		plaidSecret = os.Getenv("PLAID_SECRET_SANDBOX")
	}
	cfg := config{
		Port:               env("PORT", "8080"),
		PlaidBaseURL:       env("PLAID_BASE_URL", plaidBaseURL(plaidEnv)),
		PlaidClientID:      os.Getenv("PLAID_CLIENT_ID"),
		PlaidSecret:        plaidSecret,
		TokenEncryptionKey: os.Getenv("TOKEN_ENCRYPTION_KEY"),
		WorkOSAPIKey:       os.Getenv("WORKOS_API_KEY"),
		WorkOSClientID:     os.Getenv("WORKOS_CLIENT_ID"),
		WorkOSRedirectURI:  env("WORKOS_REDIRECT_URI", "budgetapp://auth/callback"),
		ConvexURL:          convexURL,
		ConvexDeployKey:    os.Getenv("CONVEX_DEPLOYMENT_KEY"),
	}
	if cfg.TokenEncryptionKey == "" {
		key := make([]byte, 32)
		if _, err := io.ReadFull(rand.Reader, key); err != nil {
			return cfg, err
		}
		cfg.TokenEncryptionKey = base64.StdEncoding.EncodeToString(key)
		log.Print("TOKEN_ENCRYPTION_KEY is not set; using an ephemeral development key")
	}
	if !strings.HasPrefix(cfg.PlaidBaseURL, "https://") {
		return cfg, errors.New("PLAID_BASE_URL must use https")
	}
	return cfg, nil
}
func env(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
func plaidBaseURL(plaidEnv string) string {
	switch plaidEnv {
	case "production":
		return "https://production.plaid.com"
	case "development":
		return "https://development.plaid.com"
	default:
		return "https://production.plaid.com"
	}
}
func newTokenCipher(encodedKey string) (*tokenCipher, error) {
	key, err := base64.StdEncoding.DecodeString(encodedKey)
	if err != nil {
		return nil, err
	}
	if len(key) != 32 {
		return nil, errors.New("TOKEN_ENCRYPTION_KEY must decode to 32 bytes")
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	return &tokenCipher{aead: aead}, nil
}
func (c *tokenCipher) encrypt(value string) (string, error) {
	nonce := make([]byte, c.aead.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(c.aead.Seal(nonce, nonce, []byte(value), nil)), nil
}
func (c *tokenCipher) decrypt(value string) (string, error) {
	payload, err := base64.StdEncoding.DecodeString(value)
	if err != nil {
		return "", err
	}
	size := c.aead.NonceSize()
	if len(payload) < size {
		return "", errors.New("ciphertext is too short")
	}
	plain, err := c.aead.Open(nil, payload[:size], payload[size:], nil)
	return string(plain), err
}

func (s *server) routes() *fiber.App {
	app := fiber.New(fiber.Config{AppName: "Budget API"})
	app.Get("/health", func(c *fiber.Ctx) error { return c.JSON(fiber.Map{"ok": true}) })
	v1 := app.Group("/v1")
	v1.Get("/accounts", s.listAccounts)
	v1.Post("/auth/dev-session", s.devSession)
	v1.Get("/auth/workos/authorize-url", s.workOSAuthorizeURL)
	v1.Post("/auth/workos/callback", s.workOSCallback)
	v1.Post("/auth/workos/refresh", s.workOSRefresh)
	v1.Post("/accounts/manual", s.createManualAccount)
	v1.Delete("/accounts/:id", s.deleteAccount)
	v1.Get("/transactions", s.listTransactions)
	v1.Post("/transactions/manual", s.createManualTransaction)
	v1.Patch("/transactions/:id/category", s.updateTransactionCategory)
	v1.Get("/statements", s.listStatements)
	v1.Post("/statements", s.createStatement)
	v1.Post("/statements/import-csv", s.importStatementCSV)
	v1.Post("/statements/import-pdf", s.importStatementPDF)
	v1.Get("/budgets", s.listBudgets)
	v1.Post("/budgets", s.createBudget)
	v1.Put("/budgets/:id", s.updateBudget)
	v1.Delete("/budgets/:id", s.deleteBudget)
	v1.Post("/budgets/autogenerate", s.autoBudgets)
	v1.Post("/budgets/assistant/chat", s.budgetAssistantChat)
	v1.Post("/budgets/assistant/chat/stream", s.budgetAssistantChatStream)
	v1.Get("/goals", s.listGoals)
	v1.Post("/goals", s.createGoal)
	v1.Post("/cashflow/project", s.projectCashflow)
	v1.Get("/insights/summary", s.summary)
	v1.Get("/assistant/conversations", s.listAssistantConversations)
	v1.Post("/assistant/conversations", s.createAssistantConversation)
	v1.Get("/assistant/conversations/:id/messages", s.listAssistantMessages)
	v1.Delete("/assistant/conversations/:id", s.deleteAssistantConversation)
	v1.Post("/assistant/chat", s.assistantChat)
	v1.Post("/assistant/chat/stream", s.assistantChatStream)
	v1.Post("/voice/xai/client-secret", s.createXAIRealtimeClientSecret)
	v1.Post("/financekit/import", s.importFinanceKit)
	v1.Post("/plaid/link-token", s.createLinkToken)
	v1.Post("/plaid/exchange-public-token", s.exchangePublicToken)
	v1.Post("/plaid/sync", s.syncPlaidItems)
	v1.Post("/plaid/items/:id/sync", s.syncPlaidItem)
	v1.Post("/plaid/webhook", s.plaidWebhook)
	return app
}
func bad(c *fiber.Ctx, err error) error  { return c.Status(400).JSON(fiber.Map{"error": err.Error()}) }
func fail(c *fiber.Ctx, err error) error { return c.Status(500).JSON(fiber.Map{"error": err.Error()}) }

func (s *server) createManualAccount(c *fiber.Ctx) error {
	var req account
	if err := c.BodyParser(&req); err != nil {
		return bad(c, err)
	}
	if req.UserID == "" || req.Name == "" || req.Type == "" {
		return bad(c, errors.New("user_id, name, and type are required"))
	}
	if req.CurrencyCode == "" {
		req.CurrencyCode = "USD"
	}
	var out map[string]any
	args := fiber.Map{
		"userKey":           req.UserID,
		"name":              req.Name,
		"type":              req.Type,
		"subtype":           req.Subtype,
		"currencyCode":      req.CurrencyCode,
		"balanceCents":      req.BalanceCents,
		"creditLimitCents":  req.CreditLimitCents,
		"statementCloseDay": req.StatementCloseDay,
		"paymentDueDay":     req.PaymentDueDay,
	}
	if err := s.convex.mutation(c.Context(), "finance:legacyCreateManualAccount", args, &out); err != nil {
		return fail(c, err)
	}
	return c.Status(201).JSON(out)
}
func (s *server) devSession(c *fiber.Ctx) error {
	var req struct {
		Email string `json:"email"`
		Name  string `json:"name"`
	}
	if err := c.BodyParser(&req); err != nil {
		return bad(c, err)
	}
	req.Email = defaultString(req.Email, "local@budget.app")
	req.Name = defaultString(req.Name, "Local User")
	userID := "local-user"
	var user map[string]any
	if err := s.convex.mutation(c.Context(), "finance:legacyEnsureUser", fiber.Map{"userKey": userID, "email": req.Email, "name": req.Name}, &user); err != nil {
		return fail(c, err)
	}
	return c.JSON(fiber.Map{"user": user, "user_id": userID})
}

func (s *server) workOSAuthorizeURL(c *fiber.Ctx) error {
	if s.authConf.clientID == "" || s.auth.APIKey == "" {
		return bad(c, errors.New("WORKOS_CLIENT_ID and WORKOS_API_KEY are required"))
	}
	state := c.Query("state")
	if state == "" {
		state = randomState()
	}
	url, err := s.auth.GetAuthorizationURL(usermanagement.GetAuthorizationURLOpts{
		ClientID:    s.authConf.clientID,
		RedirectURI: s.authConf.redirectURI,
		Provider:    "authkit",
		State:       state,
	})
	if err != nil {
		return bad(c, err)
	}
	return c.JSON(fiber.Map{"url": url.String(), "state": state, "redirect_uri": s.authConf.redirectURI})
}

func (s *server) workOSCallback(c *fiber.Ctx) error {
	if s.authConf.clientID == "" || s.auth.APIKey == "" {
		return bad(c, errors.New("WORKOS_CLIENT_ID and WORKOS_API_KEY are required"))
	}
	var req struct {
		Code         string `json:"code"`
		CodeVerifier string `json:"code_verifier"`
	}
	if err := c.BodyParser(&req); err != nil {
		return bad(c, err)
	}
	if req.Code == "" {
		return bad(c, errors.New("code is required"))
	}
	authResp, err := s.auth.AuthenticateWithCode(c.Context(), usermanagement.AuthenticateWithCodeOpts{
		ClientID:     s.authConf.clientID,
		Code:         req.Code,
		CodeVerifier: req.CodeVerifier,
		IPAddress:    c.IP(),
		UserAgent:    c.Get("User-Agent"),
	})
	if err != nil {
		return fail(c, err)
	}
	userID, err := s.upsertWorkOSUser(c.Context(), authResp.User.ID, authResp.User.Email, strings.TrimSpace(authResp.User.FirstName+" "+authResp.User.LastName))
	if err != nil {
		return fail(c, err)
	}
	return c.JSON(fiber.Map{
		"user_id":         userID,
		"workos_user_id":  authResp.User.ID,
		"email":           authResp.User.Email,
		"name":            strings.TrimSpace(authResp.User.FirstName + " " + authResp.User.LastName),
		"access_token":    authResp.AccessToken,
		"refresh_token":   authResp.RefreshToken,
		"organization_id": authResp.OrganizationID,
	})
}

func (s *server) workOSRefresh(c *fiber.Ctx) error {
	if s.authConf.clientID == "" || s.auth.APIKey == "" {
		return bad(c, errors.New("WORKOS_CLIENT_ID and WORKOS_API_KEY are required"))
	}
	var req struct {
		RefreshToken string `json:"refresh_token"`
	}
	if err := c.BodyParser(&req); err != nil {
		return bad(c, err)
	}
	if req.RefreshToken == "" {
		return bad(c, errors.New("refresh_token is required"))
	}
	authResp, err := s.auth.AuthenticateWithRefreshToken(c.Context(), usermanagement.AuthenticateWithRefreshTokenOpts{
		ClientID:     s.authConf.clientID,
		RefreshToken: req.RefreshToken,
		IPAddress:    c.IP(),
		UserAgent:    c.Get("User-Agent"),
	})
	if err != nil {
		return fail(c, err)
	}
	return c.JSON(fiber.Map{"access_token": authResp.AccessToken, "refresh_token": authResp.RefreshToken})
}

func (s *server) upsertWorkOSUser(ctx context.Context, workOSUserID, email, name string) (string, error) {
	if email == "" {
		email = workOSUserID + "@workos.local"
	}
	if name == "" {
		name = email
	}
	if err := s.convex.mutation(ctx, "finance:legacyEnsureUser", fiber.Map{"userKey": workOSUserID, "email": email, "name": name}, nil); err != nil {
		return "", err
	}
	return workOSUserID, nil
}

func randomState() string {
	bytes := make([]byte, 16)
	if _, err := io.ReadFull(rand.Reader, bytes); err != nil {
		return strconv.FormatInt(time.Now().UnixNano(), 36)
	}
	return base64.RawURLEncoding.EncodeToString(bytes)
}

func (s *server) listAccounts(c *fiber.Ctx) error {
	var out []map[string]any
	if err := s.convex.query(c.Context(), "finance:legacyListAccounts", fiber.Map{"userKey": c.Query("user_id")}, &out); err != nil {
		return fail(c, err)
	}
	if out == nil {
		out = []map[string]any{}
	}
	return c.JSON(out)
}
func (s *server) deleteAccount(c *fiber.Ctx) error {
	var out fiber.Map
	if err := s.convex.mutation(c.Context(), "finance:legacyDeleteAccount", fiber.Map{"userKey": c.Query("user_id"), "accountId": c.Params("id")}, &out); err != nil {
		return fail(c, err)
	}
	return c.JSON(out)
}
func (s *server) createManualTransaction(c *fiber.Ctx) error {
	var req struct {
		UserID, AccountID, Description, MerchantName, CurrencyCode, LocationName, Notes string
		AmountCents                                                                     int64             `json:"amount_cents"`
		PostedAt                                                                        time.Time         `json:"posted_at"`
		CategorySplits                                                                  []categorySplit   `json:"category_splits"`
		ReceiptLineItems                                                                []receiptLineItem `json:"receipt_line_items"`
	}
	if err := c.BodyParser(&req); err != nil {
		return bad(c, err)
	}
	if req.PostedAt.IsZero() {
		req.PostedAt = time.Now().UTC()
	}
	var tx map[string]any
	args := fiber.Map{"userKey": req.UserID, "accountId": req.AccountID, "description": req.Description, "merchantName": req.MerchantName, "amountCents": req.AmountCents, "currencyCode": defaultString(req.CurrencyCode, "USD"), "postedAt": req.PostedAt.Format(time.RFC3339), "locationName": req.LocationName, "categorySplits": req.CategorySplits, "notes": req.Notes}
	if err := s.convex.mutation(c.Context(), "finance:legacyCreateManualTransaction", args, &tx); err != nil {
		return fail(c, err)
	}
	return c.Status(201).JSON(tx)
}

func (s *server) updateTransactionCategory(c *fiber.Ctx) error {
	var req struct {
		UserID         string `json:"user_id"`
		CategoryName   string `json:"category_name"`
		ApplyToSimilar bool   `json:"apply_to_similar"`
	}
	if err := c.BodyParser(&req); err != nil {
		return bad(c, err)
	}
	if req.UserID == "" {
		return bad(c, errors.New("user_id is required"))
	}
	if strings.TrimSpace(req.CategoryName) == "" {
		return bad(c, errors.New("category_name is required"))
	}
	var tx map[string]any
	args := fiber.Map{"userKey": req.UserID, "transactionId": c.Params("id"), "categoryName": req.CategoryName, "applyToSimilar": req.ApplyToSimilar}
	if err := s.convex.mutation(c.Context(), "finance:legacyUpdateTransactionCategory", args, &tx); err != nil {
		return fail(c, err)
	}
	return c.JSON(tx)
}

func (s *server) importFinanceKit(c *fiber.Ctx) error {
	var req financeKitImportRequest
	if err := c.BodyParser(&req); err != nil {
		return bad(c, err)
	}
	if req.UserID == "" {
		return bad(c, errors.New("user_id is required"))
	}
	var connectionID string
	if err := s.convex.mutation(c.Context(), "finance:legacyUpsertConnection", fiber.Map{"userKey": req.UserID, "provider": "financeKit", "displayName": "Apple Wallet", "externalConnectionId": "apple-wallet"}, &connectionID); err != nil {
		return fail(c, err)
	}
	accountIDs := map[string]bool{}
	accountsImported := 0
	for _, payload := range req.Accounts {
		if payload.ID == "" {
			continue
		}
		name := defaultString(payload.Name, defaultString(payload.OfficialName, "Apple Wallet Account"))
		currency := defaultString(payload.CurrencyCode, "USD")
		var saved map[string]any
		args := fiber.Map{"userKey": req.UserID, "connectionId": connectionID, "provider": "financeKit", "externalAccountId": payload.ID, "displayName": name, "officialName": defaultString(payload.OfficialName, payload.InstitutionName), "type": defaultString(payload.Type, "depository"), "subtype": payload.Subtype, "currencyCode": currency, "balanceCents": payload.BalanceCents, "creditLimitCents": payload.CreditLimitCents}
		if err := s.convex.mutation(c.Context(), "finance:legacyUpsertProviderAccount", args, &saved); err != nil {
			return fail(c, err)
		}
		accountIDs[payload.ID] = true
		accountsImported++
	}

	transactionsImported := 0
	for _, payload := range req.Transactions {
		if payload.ID == "" || payload.AccountID == "" {
			continue
		}
		if !accountIDs[payload.AccountID] {
			continue
		}
		postedAt := payload.PostedAt
		if postedAt.IsZero() {
			postedAt = time.Now().UTC()
		}
		externalID := "financekit:" + payload.ID
		var saved map[string]any
		args := fiber.Map{"userKey": req.UserID, "provider": "financeKit", "externalAccountId": payload.AccountID, "externalTransactionId": externalID, "description": defaultString(payload.Description, "Apple Wallet transaction"), "merchantName": payload.MerchantName, "amountCents": payload.AmountCents, "currencyCode": defaultString(payload.CurrencyCode, "USD"), "postedAt": postedAt.Format(time.RFC3339), "pending": payload.Pending, "locationName": payload.LocationName, "raw": payload}
		if err := s.convex.mutation(c.Context(), "finance:legacyUpsertProviderTransaction", args, &saved); err != nil {
			return fail(c, err)
		}
		transactionsImported++
	}
	return c.JSON(fiber.Map{"accounts": accountsImported, "transactions": transactionsImported})
}

func (s *server) createStatement(c *fiber.Ctx) error {
	var req struct {
		UserID         string    `json:"user_id"`
		AccountID      string    `json:"account_id"`
		FileName       string    `json:"file_name"`
		FileType       string    `json:"file_type"`
		StatementStart time.Time `json:"statement_start"`
		StatementEnd   time.Time `json:"statement_end"`
		ImportedCount  int       `json:"imported_count"`
	}
	if err := c.BodyParser(&req); err != nil {
		return bad(c, err)
	}
	args := fiber.Map{
		"userKey":        req.UserID,
		"accountId":      req.AccountID,
		"fileName":       defaultString(req.FileName, "Manual statement"),
		"fileType":       defaultString(req.FileType, "manual"),
		"statementStart": req.StatementStart.Format(time.RFC3339),
		"statementEnd":   req.StatementEnd.Format(time.RFC3339),
		"importedCount":  req.ImportedCount,
	}
	var statement map[string]any
	if err := s.convex.mutation(c.Context(), "finance:legacyCreateStatement", args, &statement); err != nil {
		return fail(c, err)
	}
	return c.Status(201).JSON(statement)
}
func (s *server) importStatementCSV(c *fiber.Ctx) error {
	var req struct {
		UserID    string `json:"user_id"`
		AccountID string `json:"account_id"`
		FileName  string `json:"file_name"`
		CSV       string `json:"csv"`
	}
	if err := c.BodyParser(&req); err != nil {
		return bad(c, err)
	}
	reader := csv.NewReader(strings.NewReader(req.CSV))
	reader.FieldsPerRecord = -1
	rows, err := reader.ReadAll()
	if err != nil {
		return bad(c, err)
	}
	if len(rows) == 0 {
		return bad(c, errors.New("csv is empty"))
	}
	headers := map[string]int{}
	for index, header := range rows[0] {
		headers[strings.ToLower(strings.TrimSpace(header))] = index
	}
	dateIndex, amountIndex, descriptionIndex := headers["date"], headers["amount"], headers["description"]
	if _, ok := headers["description"]; !ok {
		descriptionIndex = headers["name"]
	}
	now := time.Now().UTC()
	transactions := []fiber.Map{}
	for _, row := range rows[1:] {
		if len(row) <= amountIndex || len(row) <= dateIndex || len(row) <= descriptionIndex {
			continue
		}
		amount, err := strconv.ParseFloat(strings.ReplaceAll(strings.TrimSpace(row[amountIndex]), "$", ""), 64)
		if err != nil {
			continue
		}
		postedAt, err := parseStatementDate(row[dateIndex])
		if err != nil {
			postedAt = now
		}
		transactions = append(transactions, fiber.Map{"description": row[descriptionIndex], "merchantName": row[descriptionIndex], "amountCents": int64(math.Round(amount * 100)), "currencyCode": "USD", "postedAt": postedAt.Format(time.RFC3339)})
	}
	var out map[string]any
	args := fiber.Map{"userKey": req.UserID, "accountId": req.AccountID, "fileName": defaultString(req.FileName, "Imported CSV"), "fileType": "csv", "statementStart": now.Format(time.RFC3339), "statementEnd": now.Format(time.RFC3339), "transactions": transactions}
	if err := s.convex.mutation(c.Context(), "finance:legacyImportStatement", args, &out); err != nil {
		return fail(c, err)
	}
	return c.Status(201).JSON(out)
}
func (s *server) importStatementPDF(c *fiber.Ctx) error {
	userID := c.FormValue("user_id")
	if userID == "" {
		return bad(c, errors.New("user_id is required"))
	}
	accountID := c.FormValue("account_id")
	if accountID == "" {
		return bad(c, errors.New("account_id is required"))
	}
	fileHeader, err := c.FormFile("file")
	if err != nil {
		return bad(c, err)
	}
	file, err := fileHeader.Open()
	if err != nil {
		return bad(c, err)
	}
	defer file.Close()
	data, err := io.ReadAll(file)
	if err != nil {
		return bad(c, err)
	}
	tmp, err := os.CreateTemp("", "budget-statement-*.pdf")
	if err != nil {
		return fail(c, err)
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return fail(c, err)
	}
	if err := tmp.Close(); err != nil {
		return fail(c, err)
	}
	text, err := extractPDFText(tmpPath)
	if err != nil {
		return bad(c, err)
	}
	transactions, statementStart, statementEnd := parsePDFStatementTransactions(text, fileHeader.Filename)
	if len(transactions) == 0 {
		return bad(c, errors.New("no supported transactions found in PDF statement"))
	}
	now := time.Now().UTC()
	rows := []fiber.Map{}
	for index, parsed := range transactions {
		externalID := statementExternalID(accountID, fileHeader.Filename, parsed, index)
		rows = append(rows, fiber.Map{"description": parsed.Description, "merchantName": parsed.Description, "amountCents": parsed.AmountCents, "currencyCode": "USD", "postedAt": parsed.PostedAt.Format(time.RFC3339), "externalTransactionId": externalID})
	}
	var out map[string]any
	args := fiber.Map{"userKey": userID, "accountId": accountID, "fileName": defaultString(fileHeader.Filename, "Imported PDF"), "fileType": "pdf", "statementStart": statementStart.Format(time.RFC3339), "statementEnd": statementEnd.Format(time.RFC3339), "transactions": rows, "importedAt": now.Format(time.RFC3339)}
	if err := s.convex.mutation(c.Context(), "finance:legacyImportStatement", args, &out); err != nil {
		return fail(c, err)
	}
	return c.Status(201).JSON(out)
}
func (s *server) listStatements(c *fiber.Ctx) error {
	var out []map[string]any
	if err := s.convex.query(c.Context(), "finance:legacyListStatements", fiber.Map{"userKey": c.Query("user_id")}, &out); err != nil {
		return fail(c, err)
	}
	if out == nil {
		out = []map[string]any{}
	}
	return c.JSON(out)
}
func (s *server) listTransactions(c *fiber.Ctx) error {
	limit, _ := strconv.ParseInt(c.Query("limit", "100"), 10, 64)
	if limit <= 0 || limit > 1000 {
		limit = 100
	}
	args := fiber.Map{"userKey": c.Query("user_id"), "limit": int(limit), "sort": c.Query("sort"), "direction": c.Query("direction")}
	if query := strings.TrimSpace(c.Query("q")); query != "" {
		args["q"] = query
	}
	if accountID := strings.TrimSpace(c.Query("account_id")); accountID != "" {
		args["accountId"] = accountID
	}
	if source := strings.TrimSpace(c.Query("source")); source != "" {
		args["source"] = source
	}
	if amount := centsFromQuery(c.Query("amount_eq")); amount != nil {
		args["amountEq"] = *amount
	}
	if amount := centsFromQuery(c.Query("amount_gt")); amount != nil {
		args["amountGt"] = *amount
	}
	if amount := centsFromQuery(c.Query("amount_lt")); amount != nil {
		args["amountLt"] = *amount
	}
	var out []map[string]any
	if err := s.convex.query(c.Context(), "finance:legacyListTransactions", args, &out); err != nil {
		return fail(c, err)
	}
	if out == nil {
		out = []map[string]any{}
	}
	return c.JSON(out)
}

func centsFromQuery(value string) *int64 {
	value = strings.TrimSpace(strings.ReplaceAll(value, "$", ""))
	if value == "" {
		return nil
	}
	amount, err := strconv.ParseFloat(value, 64)
	if err != nil {
		return nil
	}
	cents := int64(math.Round(amount * 100))
	return &cents
}

func (s *server) createBudget(c *fiber.Ctx) error {
	var req budget
	if err := c.BodyParser(&req); err != nil {
		return bad(c, err)
	}
	var out map[string]any
	args := fiber.Map{"userKey": req.UserID, "categoryName": defaultString(req.CategoryName, "Uncategorized"), "period": defaultString(req.Period, "monthly"), "limitCents": req.LimitCents}
	if err := s.convex.mutation(c.Context(), "finance:legacyCreateBudget", args, &out); err != nil {
		return fail(c, err)
	}
	return c.Status(201).JSON(out)
}
func (s *server) updateBudget(c *fiber.Ctx) error {
	var req budget
	if err := c.BodyParser(&req); err != nil {
		return bad(c, err)
	}
	if req.UserID == "" {
		return bad(c, errors.New("user_id is required"))
	}
	var out map[string]any
	args := fiber.Map{"userKey": req.UserID, "budgetId": c.Params("id"), "categoryName": defaultString(req.CategoryName, "Uncategorized"), "period": defaultString(req.Period, "monthly"), "limitCents": req.LimitCents}
	if err := s.convex.mutation(c.Context(), "finance:legacyUpdateBudget", args, &out); err != nil {
		return fail(c, err)
	}
	return c.JSON(out)
}
func (s *server) deleteBudget(c *fiber.Ctx) error {
	var out map[string]any
	if err := s.convex.mutation(c.Context(), "finance:legacyDeleteBudget", fiber.Map{"userKey": c.Query("user_id"), "budgetId": c.Params("id")}, &out); err != nil {
		return fail(c, err)
	}
	return c.JSON(out)
}
func (s *server) listBudgets(c *fiber.Ctx) error {
	var out []map[string]any
	if err := s.convex.query(c.Context(), "finance:legacyListBudgets", fiber.Map{"userKey": c.Query("user_id")}, &out); err != nil {
		return fail(c, err)
	}
	if out == nil {
		out = []map[string]any{}
	}
	return c.JSON(out)
}
func (s *server) autoBudgets(c *fiber.Ctx) error {
	var req struct {
		UserID string `json:"user_id"`
	}
	if err := c.BodyParser(&req); err != nil {
		return bad(c, err)
	}
	var out []map[string]any
	if err := s.convex.mutation(c.Context(), "finance:legacyAutoBudgets", fiber.Map{"userKey": req.UserID}, &out); err != nil {
		return fail(c, err)
	}
	if out == nil {
		out = []map[string]any{}
	}
	return c.JSON(out)
}

type budgetAssistantRequest struct {
	UserID  string `json:"user_id"`
	Message string `json:"message"`
}

type budgetAssistantPlan struct {
	Reply           string                          `json:"reply"`
	Budgets         []budgetAssistantBudgetAction   `json:"budgets"`
	Classifications []budgetAssistantClassification `json:"classifications"`
	FollowUps       []string                        `json:"follow_ups"`
}

type budgetAssistantBudgetAction struct {
	Operation    string `json:"operation"`
	CategoryName string `json:"category_name"`
	Period       string `json:"period"`
	LimitCents   int64  `json:"limit_cents"`
}

type budgetAssistantClassification struct {
	TransactionID  string  `json:"transaction_id"`
	CategoryName   string  `json:"category_name"`
	Confidence     float64 `json:"confidence"`
	Reason         string  `json:"reason"`
	ApplyToSimilar bool    `json:"apply_to_similar"`
}

func (s *server) budgetAssistantChat(c *fiber.Ctx) error {
	var req budgetAssistantRequest
	if err := c.BodyParser(&req); err != nil {
		return bad(c, err)
	}
	req.Message = strings.TrimSpace(req.Message)
	if req.UserID == "" || req.Message == "" {
		return bad(c, errors.New("user_id and message are required"))
	}

	var budgets []map[string]any
	var transactions []map[string]any
	_ = s.convex.query(c.Context(), "finance:legacyListBudgets", fiber.Map{"userKey": req.UserID}, &budgets)
	_ = s.convex.query(c.Context(), "finance:legacyListTransactions", fiber.Map{"userKey": req.UserID, "limit": 250, "sort": "posted_at", "direction": "desc"}, &transactions)

	plan, err := s.openRouterBudgetPlan(c.Context(), req.UserID, req.Message, budgets, transactions)
	if err != nil {
		plan = fallbackBudgetAssistantPlan(req.Message, budgets, transactions)
	}
	result := s.applyBudgetAssistantPlan(c.Context(), req.UserID, plan, budgets)
	return c.JSON(fiber.Map{
		"reply":           result.Reply,
		"created_budgets": result.CreatedBudgets,
		"updated_budgets": result.UpdatedBudgets,
		"deleted_budgets": result.DeletedBudgets,
		"classified":      result.Classified,
		"needs_review":    result.NeedsReview,
		"follow_ups":      result.FollowUps,
		"created_at":      time.Now().UTC(),
	})
}

func (s *server) budgetAssistantChatStream(c *fiber.Ctx) error {
	var req budgetAssistantRequest
	if err := c.BodyParser(&req); err != nil {
		return bad(c, err)
	}
	req.Message = strings.TrimSpace(req.Message)
	if req.UserID == "" || req.Message == "" {
		return bad(c, errors.New("user_id and message are required"))
	}

	c.Set(fiber.HeaderContentType, "text/event-stream")
	c.Set(fiber.HeaderCacheControl, "no-cache")
	c.Set(fiber.HeaderConnection, "keep-alive")
	c.Set("X-Accel-Buffering", "no")

	c.Context().SetBodyStreamWriter(func(w *bufio.Writer) {
		sendSSE(w, "status", fiber.Map{"message": "Thinking through your budgets…"})
		_ = w.Flush()

		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
		defer cancel()

		var budgets []map[string]any
		var transactions []map[string]any
		sendSSE(w, "status", fiber.Map{"message": "Loading categories and transactions…"})
		_ = w.Flush()
		_ = s.convex.query(ctx, "finance:legacyListBudgets", fiber.Map{"userKey": req.UserID}, &budgets)
		_ = s.convex.query(ctx, "finance:legacyListTransactions", fiber.Map{"userKey": req.UserID, "limit": 250, "sort": "posted_at", "direction": "desc"}, &transactions)

		sendSSE(w, "status", fiber.Map{"message": "Classifying and planning changes…"})
		_ = w.Flush()
		plan, err := s.openRouterBudgetPlan(ctx, req.UserID, req.Message, budgets, transactions)
		if err != nil {
			plan = fallbackBudgetAssistantPlan(req.Message, budgets, transactions)
			sendSSE(w, "notice", fiber.Map{"message": err.Error()})
			_ = w.Flush()
		}

		sendSSE(w, "status", fiber.Map{"message": "Applying high-confidence updates…"})
		_ = w.Flush()
		result := s.applyBudgetAssistantPlan(ctx, req.UserID, plan, budgets)
		reply := budgetAssistantResponseText(result)
		for _, token := range chunkText(reply, 18) {
			sendSSE(w, "token", fiber.Map{"delta": token})
			_ = w.Flush()
			time.Sleep(12 * time.Millisecond)
		}
		sendSSE(w, "done", fiber.Map{
			"reply":           result.Reply,
			"created_budgets": result.CreatedBudgets,
			"updated_budgets": result.UpdatedBudgets,
			"deleted_budgets": result.DeletedBudgets,
			"classified":      result.Classified,
			"needs_review":    result.NeedsReview,
			"follow_ups":      result.FollowUps,
			"created_at":      time.Now().UTC(),
		})
		_ = w.Flush()
	})
	return nil
}

type budgetAssistantResult struct {
	Reply          string   `json:"reply"`
	CreatedBudgets int      `json:"created_budgets"`
	UpdatedBudgets int      `json:"updated_budgets"`
	DeletedBudgets int      `json:"deleted_budgets"`
	Classified     int      `json:"classified"`
	NeedsReview    int      `json:"needs_review"`
	FollowUps      []string `json:"follow_ups"`
}

func (s *server) applyBudgetAssistantPlan(ctx context.Context, userID string, plan budgetAssistantPlan, existingBudgets []map[string]any) budgetAssistantResult {
	result := budgetAssistantResult{Reply: strings.TrimSpace(plan.Reply), FollowUps: plan.FollowUps}
	if result.Reply == "" {
		result.Reply = "I reviewed your budgets and transactions."
	}
	budgetByCategory := map[string]map[string]any{}
	for _, budget := range existingBudgets {
		name := normalizeCategoryName(stringValue(budget["category_name"]))
		if name != "" {
			budgetByCategory[name] = budget
		}
	}

	for _, action := range plan.Budgets {
		categoryName := strings.TrimSpace(action.CategoryName)
		if categoryName == "" {
			continue
		}
		operation := strings.ToLower(strings.TrimSpace(action.Operation))
		if operation == "" {
			operation = "upsert"
		}
		period := strings.ToLower(strings.TrimSpace(action.Period))
		if period != "weekly" {
			period = "monthly"
		}
		key := normalizeCategoryName(categoryName)
		existing := budgetByCategory[key]

		switch operation {
		case "delete", "remove":
			if existing == nil {
				continue
			}
			var out map[string]any
			if err := s.convex.mutation(ctx, "finance:legacyDeleteBudget", fiber.Map{"userKey": userID, "budgetId": stringValue(existing["id"])}, &out); err == nil {
				result.DeletedBudgets++
			}
		default:
			if action.LimitCents <= 0 {
				continue
			}
			args := fiber.Map{"userKey": userID, "categoryName": categoryName, "period": period, "limitCents": action.LimitCents}
			var out map[string]any
			if existing != nil {
				args["budgetId"] = stringValue(existing["id"])
				if err := s.convex.mutation(ctx, "finance:legacyUpdateBudget", args, &out); err == nil {
					result.UpdatedBudgets++
				}
			} else if err := s.convex.mutation(ctx, "finance:legacyCreateBudget", args, &out); err == nil {
				result.CreatedBudgets++
			}
		}
	}

	for _, classification := range plan.Classifications {
		if strings.TrimSpace(classification.TransactionID) == "" || strings.TrimSpace(classification.CategoryName) == "" {
			continue
		}
		if classification.Confidence < 0.72 {
			result.NeedsReview++
			continue
		}
		var tx map[string]any
		args := fiber.Map{"userKey": userID, "transactionId": classification.TransactionID, "categoryName": classification.CategoryName, "applyToSimilar": classification.ApplyToSimilar}
		if err := s.convex.mutation(ctx, "finance:legacyUpdateTransactionCategory", args, &tx); err == nil {
			result.Classified++
		}
	}

	if len(result.FollowUps) == 0 && result.NeedsReview > 0 {
		result.FollowUps = []string{"I found transactions that need confirmation before I classify them. Tell me the merchant/category mapping you want, or classify one and apply it to similar transactions."}
	}
	return result
}

func budgetAssistantResponseText(reply budgetAssistantResult) string {
	parts := []string{strings.TrimSpace(reply.Reply)}
	if len(reply.FollowUps) > 0 {
		questions := make([]string, 0, len(reply.FollowUps))
		for _, followUp := range reply.FollowUps {
			if trimmed := strings.TrimSpace(followUp); trimmed != "" {
				questions = append(questions, "• "+trimmed)
			}
		}
		if len(questions) > 0 {
			parts = append(parts, "Questions:\n"+strings.Join(questions, "\n"))
		}
	}
	return strings.Join(parts, "\n\n")
}

func chunkText(value string, size int) []string {
	if size <= 0 {
		size = 24
	}
	runes := []rune(value)
	if len(runes) == 0 {
		return []string{}
	}
	chunks := make([]string, 0, (len(runes)/size)+1)
	for start := 0; start < len(runes); start += size {
		end := start + size
		if end > len(runes) {
			end = len(runes)
		}
		chunks = append(chunks, string(runes[start:end]))
	}
	return chunks
}

func normalizeCategoryName(value string) string {
	return strings.ToLower(strings.Join(strings.Fields(value), " "))
}

func (s *server) createGoal(c *fiber.Ctx) error {
	var req goal
	if err := c.BodyParser(&req); err != nil {
		return bad(c, err)
	}
	var out map[string]any
	args := fiber.Map{"userKey": req.UserID, "name": req.Name, "type": req.Type, "targetCents": req.TargetCents, "currentCents": req.CurrentCents, "priority": req.Priority}
	if err := s.convex.mutation(c.Context(), "finance:legacyCreateGoal", args, &out); err != nil {
		return fail(c, err)
	}
	return c.Status(201).JSON(out)
}
func (s *server) listGoals(c *fiber.Ctx) error {
	var out []map[string]any
	if err := s.convex.query(c.Context(), "finance:legacyListGoals", fiber.Map{"userKey": c.Query("user_id")}, &out); err != nil {
		return fail(c, err)
	}
	if out == nil {
		out = []map[string]any{}
	}
	return c.JSON(out)
}
func (s *server) projectCashflow(c *fiber.Ctx) error {
	var req struct {
		StartingBalanceCents int64 `json:"starting_balance_cents"`
		Events               []struct {
			Date        time.Time `json:"date"`
			Label       string    `json:"label"`
			AmountCents int64     `json:"amount_cents"`
		} `json:"events"`
	}
	if err := c.BodyParser(&req); err != nil {
		return bad(c, err)
	}
	balance := req.StartingBalanceCents
	out := []fiber.Map{}
	for _, event := range req.Events {
		balance += event.AmountCents
		out = append(out, fiber.Map{"date": event.Date, "label": event.Label, "amount_cents": event.AmountCents, "balance_cents": balance})
	}
	return c.JSON(out)
}
func (s *server) summary(c *fiber.Ctx) error {
	userID := c.Query("user_id")
	var accounts []map[string]any
	var transactions []map[string]any
	_ = s.convex.query(c.Context(), "finance:legacyListAccounts", fiber.Map{"userKey": userID}, &accounts)
	_ = s.convex.query(c.Context(), "finance:legacyListTransactions", fiber.Map{"userKey": userID, "limit": 200}, &transactions)
	var netWorth, monthlySpend, availableCredit int64
	for _, account := range accounts {
		balanceCents := int64(intFromAny(account["balance_cents"]))
		creditLimitCents := int64(intFromAny(account["credit_limit_cents"]))
		netWorth += balanceCents
		if stringValue(account["type"]) == "credit" && creditLimitCents > 0 {
			availableCredit += max(0, creditLimitCents+balanceCents)
		}
	}
	monthStart := time.Now().UTC().AddDate(0, 0, -30)
	for _, tx := range transactions {
		amountCents := int64(intFromAny(tx["amount_cents"]))
		postedAt := timeFromAny(tx["posted_at"])
		if amountCents < 0 && postedAt.After(monthStart) {
			monthlySpend += -amountCents
		}
	}
	return c.JSON(fiber.Map{"net_worth_cents": netWorth, "monthly_spend_cents": monthlySpend, "available_credit_cents": availableCredit, "accounts_count": len(accounts), "transactions_count": len(transactions)})
}

func (s *server) listAssistantConversations(c *fiber.Ctx) error {
	userID := c.Query("user_id")
	if userID == "" {
		return bad(c, errors.New("user_id is required"))
	}
	var conversations []map[string]any
	if err := s.convex.query(c.Context(), "assistant:legacyListConversations", fiber.Map{"userKey": userID, "limit": 100}, &conversations); err != nil {
		return bad(c, err)
	}
	return c.JSON(conversations)
}

func (s *server) createAssistantConversation(c *fiber.Ctx) error {
	var req struct {
		UserID string `json:"user_id"`
		Title  string `json:"title"`
	}
	if err := c.BodyParser(&req); err != nil {
		return bad(c, err)
	}
	if req.UserID == "" {
		return bad(c, errors.New("user_id is required"))
	}
	var conversation map[string]any
	if err := s.convex.mutation(c.Context(), "assistant:legacyCreateConversation", fiber.Map{"userKey": req.UserID, "title": req.Title}, &conversation); err != nil {
		return bad(c, err)
	}
	return c.JSON(conversation)
}

func (s *server) listAssistantMessages(c *fiber.Ctx) error {
	userID := c.Query("user_id")
	conversationID := c.Params("id")
	if userID == "" || conversationID == "" {
		return bad(c, errors.New("user_id and conversation id are required"))
	}
	var messages []map[string]any
	if err := s.convex.query(c.Context(), "assistant:legacyListMessages", fiber.Map{"userKey": userID, "conversationId": conversationID}, &messages); err != nil {
		return bad(c, err)
	}
	return c.JSON(messages)
}

func (s *server) deleteAssistantConversation(c *fiber.Ctx) error {
	userID := c.Query("user_id")
	conversationID := c.Params("id")
	if userID == "" || conversationID == "" {
		return bad(c, errors.New("user_id and conversation id are required"))
	}
	var result map[string]any
	if err := s.convex.mutation(c.Context(), "assistant:legacyDeleteConversation", fiber.Map{"userKey": userID, "conversationId": conversationID}, &result); err != nil {
		return bad(c, err)
	}
	return c.JSON(result)
}

func (s *server) assistantChat(c *fiber.Ctx) error {
	var req struct {
		UserID         string `json:"user_id"`
		ConversationID string `json:"conversation_id"`
		Message        string `json:"message"`
	}
	if err := c.BodyParser(&req); err != nil {
		return bad(c, err)
	}
	now := time.Now().UTC()
	var userMessage map[string]any
	_ = s.convex.mutation(c.Context(), "assistant:legacyAddMessage", fiber.Map{"userKey": req.UserID, "conversationId": req.ConversationID, "role": "user", "content": req.Message}, &userMessage)
	conversationID := defaultString(stringValue(userMessage["conversation_id"]), req.ConversationID)
	response, err := s.openRouterReply(c.Context(), req.UserID, req.Message)
	if err != nil || response == "" {
		response = "I can help analyze spending, plan debt payoff, and project cashflow. Connect accounts or add transactions, then ask about a specific category, bill date, or goal."
		if strings.Contains(strings.ToLower(req.Message), "credit") {
			response = "For credit utilization, keep statement balances low before the close date. Add each card's close day and limit so I can model when spending will report."
		}
	}
	_ = s.convex.mutation(c.Context(), "assistant:legacyAddMessage", fiber.Map{"userKey": req.UserID, "conversationId": conversationID, "role": "assistant", "content": response, "model": "openrouter"}, nil)
	return c.JSON(fiber.Map{"reply": response, "created_at": now.Add(time.Millisecond), "conversation_id": conversationID})
}

func (s *server) assistantChatStream(c *fiber.Ctx) error {
	var req struct {
		UserID         string `json:"user_id"`
		ConversationID string `json:"conversation_id"`
		Message        string `json:"message"`
	}
	if err := c.BodyParser(&req); err != nil {
		return bad(c, err)
	}
	req.Message = strings.TrimSpace(req.Message)
	if req.UserID == "" || req.Message == "" {
		return bad(c, errors.New("user_id and message are required"))
	}
	var userMessage map[string]any
	_ = s.convex.mutation(c.Context(), "assistant:legacyAddMessage", fiber.Map{"userKey": req.UserID, "conversationId": req.ConversationID, "role": "user", "content": req.Message}, &userMessage)
	conversationID := defaultString(stringValue(userMessage["conversation_id"]), req.ConversationID)

	c.Set(fiber.HeaderContentType, "text/event-stream")
	c.Set(fiber.HeaderCacheControl, "no-cache")
	c.Set(fiber.HeaderConnection, "keep-alive")
	c.Set("X-Accel-Buffering", "no")

	c.Context().SetBodyStreamWriter(func(w *bufio.Writer) {
		sendSSE(w, "status", fiber.Map{"message": "Assistant is typing"})
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
		defer cancel()

		var reply strings.Builder
		err := s.openRouterReplyStream(ctx, req.UserID, req.Message, func(delta string) {
			if delta == "" {
				return
			}
			reply.WriteString(delta)
			sendSSE(w, "token", fiber.Map{"delta": delta})
		})
		if err != nil || strings.TrimSpace(reply.String()) == "" {
			fallback := assistantFallback(req.Message)
			reply.Reset()
			reply.WriteString(fallback)
			sendSSE(w, "token", fiber.Map{"delta": fallback})
			if err != nil {
				sendSSE(w, "notice", fiber.Map{"message": err.Error()})
			}
		}

		insertCtx, insertCancel := context.WithTimeout(context.Background(), 5*time.Second)
		_ = s.convex.mutation(insertCtx, "assistant:legacyAddMessage", fiber.Map{"userKey": req.UserID, "conversationId": conversationID, "role": "assistant", "content": reply.String(), "model": "openrouter"}, nil)
		insertCancel()
		sendSSE(w, "done", fiber.Map{"reply": reply.String(), "created_at": time.Now().UTC(), "conversation_id": conversationID})
	})
	return nil
}

func (s *server) openRouterReply(ctx context.Context, userID string, message string) (string, error) {
	apiKey := os.Getenv("OPENROUTER_API_KEY")
	if apiKey == "" {
		return "", errors.New("OPENROUTER_API_KEY is not set")
	}
	summary, _ := s.financeContext(ctx, userID)
	body := map[string]any{
		"model": defaultString(os.Getenv("OPENROUTER_MODEL"), "openai/gpt-5.5"),
		"messages": []map[string]string{
			{"role": "system", "content": "You are a careful personal finance assistant. Give practical, concise guidance. Do not claim to be a financial advisor. Use the provided account context only."},
			{"role": "user", "content": "Finance context:\n" + summary + "\n\nQuestion: " + message},
		},
	}
	payload, err := json.Marshal(body)
	if err != nil {
		return "", err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://openrouter.ai/api/v1/chat/completions", bytes.NewReader(payload))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+apiKey)
	req.Header.Set("HTTP-Referer", "http://localhost")
	req.Header.Set("X-Title", "Budget")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", fmt.Errorf("openrouter failed with %d: %s", resp.StatusCode, string(data))
	}
	var decoded struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(data, &decoded); err != nil {
		return "", err
	}
	if len(decoded.Choices) == 0 {
		return "", errors.New("openrouter returned no choices")
	}
	return decoded.Choices[0].Message.Content, nil
}

func (s *server) openRouterReplyStream(ctx context.Context, userID string, message string, onToken func(string)) error {
	apiKey := os.Getenv("OPENROUTER_API_KEY")
	if apiKey == "" {
		return errors.New("OPENROUTER_API_KEY is not set")
	}
	summary, _ := s.financeContext(ctx, userID)
	body := map[string]any{
		"model":  defaultString(os.Getenv("OPENROUTER_MODEL"), "openai/gpt-5.5"),
		"stream": true,
		"messages": []map[string]string{
			{"role": "system", "content": "You are a careful personal finance assistant. Give practical, concise guidance in Markdown. Do not claim to be a financial advisor. Use the provided account context only."},
			{"role": "user", "content": "Finance context:\n" + summary + "\n\nQuestion: " + message},
		},
	}
	payload, err := json.Marshal(body)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://openrouter.ai/api/v1/chat/completions", bytes.NewReader(payload))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "text/event-stream")
	req.Header.Set("Authorization", "Bearer "+apiKey)
	req.Header.Set("HTTP-Referer", "http://localhost")
	req.Header.Set("X-Title", "Budget")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		data, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("openrouter stream failed with %d: %s", resp.StatusCode, string(data))
	}

	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, ":") || !strings.HasPrefix(line, "data:") {
			continue
		}
		data := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
		if data == "[DONE]" {
			return nil
		}
		var chunk struct {
			Choices []struct {
				Delta struct {
					Content string `json:"content"`
				} `json:"delta"`
			} `json:"choices"`
		}
		if err := json.Unmarshal([]byte(data), &chunk); err != nil {
			continue
		}
		for _, choice := range chunk.Choices {
			onToken(choice.Delta.Content)
		}
	}
	return scanner.Err()
}

func (s *server) openRouterBudgetPlan(ctx context.Context, userID string, message string, budgets []map[string]any, transactions []map[string]any) (budgetAssistantPlan, error) {
	apiKey := os.Getenv("OPENROUTER_API_KEY")
	if apiKey == "" {
		return budgetAssistantPlan{}, errors.New("OPENROUTER_API_KEY is not set")
	}
	contextText := budgetAssistantContext(budgets, transactions)
	system := `You are Budget's category and budgeting operator. You can create, update, and delete budget categories and classify transactions.
Return only valid JSON. No Markdown. No prose outside JSON.
Schema:
{
  "reply": "short user-facing summary and any caveats",
  "budgets": [
    {"operation":"create|update|upsert|delete","category_name":"Rent","period":"monthly|weekly","limit_cents":150000}
  ],
  "classifications": [
    {"transaction_id":"id","category_name":"Groceries","confidence":0.0-1.0,"reason":"short reason","apply_to_similar":true}
  ],
  "follow_ups": ["specific question for uncertain transactions or missing amounts"]
}
Rules:
- If the user gives categories and amounts, create/update those budgets.
- If a category exists, use operation "update" or "upsert"; do not duplicate it.
- Delete only when the user clearly asks to remove/delete a category/budget.
- Classify only transactions where the merchant/description makes the category reasonably clear.
- Set confidence below 0.72 when uncertain; those will be left for review.
- Use cents. $1,200 = 120000.
- Prefer practical category names a normal person would understand.`
	body := map[string]any{
		"model": defaultString(os.Getenv("OPENROUTER_MODEL"), "openai/gpt-5.5"),
		"messages": []map[string]string{
			{"role": "system", "content": system},
			{"role": "user", "content": "Current budget and transaction context:\n" + contextText + "\n\nUser request:\n" + message},
		},
		"response_format": map[string]string{"type": "json_object"},
	}
	payload, err := json.Marshal(body)
	if err != nil {
		return budgetAssistantPlan{}, err
	}
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://openrouter.ai/api/v1/chat/completions", bytes.NewReader(payload))
	if err != nil {
		return budgetAssistantPlan{}, err
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Authorization", "Bearer "+apiKey)
	httpReq.Header.Set("HTTP-Referer", "http://localhost")
	httpReq.Header.Set("X-Title", "Budget")
	resp, err := http.DefaultClient.Do(httpReq)
	if err != nil {
		return budgetAssistantPlan{}, err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return budgetAssistantPlan{}, err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return budgetAssistantPlan{}, fmt.Errorf("openrouter budget assistant failed with %d: %s", resp.StatusCode, string(data))
	}
	var decoded struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(data, &decoded); err != nil {
		return budgetAssistantPlan{}, err
	}
	if len(decoded.Choices) == 0 {
		return budgetAssistantPlan{}, errors.New("openrouter returned no choices")
	}
	var plan budgetAssistantPlan
	if err := json.Unmarshal([]byte(extractJSONObject(decoded.Choices[0].Message.Content)), &plan); err != nil {
		return budgetAssistantPlan{}, err
	}
	return plan, nil
}

func budgetAssistantContext(budgets []map[string]any, transactions []map[string]any) string {
	var builder strings.Builder
	builder.WriteString("Existing budgets:\n")
	for _, budget := range budgets {
		fmt.Fprintf(&builder, "- id=%s category=%q period=%s limit_cents=%d spent_cents=%d\n", stringValue(budget["id"]), stringValue(budget["category_name"]), stringValue(budget["period"]), intFromAny(budget["limit_cents"]), intFromAny(budget["spent_cents"]))
	}
	builder.WriteString("\nRecent transactions:\n")
	for index, tx := range transactions {
		if index >= 120 {
			break
		}
		category := ""
		if splits, ok := tx["category_splits"].([]any); ok && len(splits) > 0 {
			if split, ok := splits[0].(map[string]any); ok {
				category = stringValue(split["name"])
			}
		}
		fmt.Fprintf(&builder, "- id=%s date=%s amount_cents=%d merchant=%q description=%q current_category=%q\n", stringValue(tx["id"]), timeFromAny(tx["posted_at"]).Format("2006-01-02"), intFromAny(tx["amount_cents"]), stringValue(tx["merchant_name"]), stringValue(tx["description"]), category)
	}
	return builder.String()
}

func extractJSONObject(value string) string {
	value = strings.TrimSpace(value)
	if strings.HasPrefix(value, "{") && strings.HasSuffix(value, "}") {
		return value
	}
	start := strings.Index(value, "{")
	end := strings.LastIndex(value, "}")
	if start >= 0 && end > start {
		return value[start : end+1]
	}
	return value
}

func fallbackBudgetAssistantPlan(message string, budgets []map[string]any, transactions []map[string]any) budgetAssistantPlan {
	lower := strings.ToLower(message)
	plan := budgetAssistantPlan{
		Reply:     "I can set up budget categories and classify transactions once the model is available. For now, I can still auto-generate budgets from categorized spending.",
		FollowUps: []string{"Tell me the exact category names and monthly amounts, for example: Rent $2,200, Car payment $450, Insurance $180, Groceries $600."},
	}
	if strings.Contains(lower, "delete") || strings.Contains(lower, "remove") {
		plan.Reply = "I need the specific category name to remove. Tell me which budget category should be deleted."
	}
	return plan
}

func assistantFallback(message string) string {
	response := "I can help analyze spending, plan debt payoff, and project cashflow. Connect accounts or add transactions, then ask about a specific category, bill date, or goal."
	if strings.Contains(strings.ToLower(message), "credit") {
		response = "For credit utilization, keep statement balances low before the close date. Add each card's close day and limit so I can model when spending will report."
	}
	return response
}

func sendSSE(w *bufio.Writer, event string, payload any) {
	data, err := json.Marshal(payload)
	if err != nil {
		return
	}
	_, _ = fmt.Fprintf(w, "event: %s\ndata: %s\n\n", event, data)
	_ = w.Flush()
}
func (s *server) createXAIRealtimeClientSecret(c *fiber.Ctx) error {
	var req struct {
		UserID string `json:"user_id"`
	}
	if err := c.BodyParser(&req); err != nil {
		return bad(c, err)
	}
	apiKey := defaultString(os.Getenv("XAI_API_KEY"), os.Getenv("XAI_KEY"))
	if apiKey == "" {
		return bad(c, errors.New("XAI_API_KEY or XAI_KEY is not set"))
	}
	payload, err := json.Marshal(map[string]any{"expires_after": map[string]int{"seconds": 300}})
	if err != nil {
		return fail(c, err)
	}
	httpReq, err := http.NewRequestWithContext(c.Context(), http.MethodPost, "https://api.x.ai/v1/realtime/client_secrets", bytes.NewReader(payload))
	if err != nil {
		return fail(c, err)
	}
	httpReq.Header.Set("Authorization", "Bearer "+apiKey)
	httpReq.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(httpReq)
	if err != nil {
		return fail(c, err)
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return fail(c, err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fail(c, fmt.Errorf("xai client secret failed with %d: %s", resp.StatusCode, string(data)))
	}
	var decoded struct {
		Value     string `json:"value"`
		ExpiresAt int64  `json:"expires_at"`
	}
	if err := json.Unmarshal(data, &decoded); err != nil {
		return fail(c, err)
	}
	model := defaultString(os.Getenv("XAI_VOICE_MODEL"), "grok-voice-fast-1.0")
	voice := defaultString(os.Getenv("XAI_VOICE"), "Eve")
	instructions := "You are Budget's voice finance assistant. Be concise, practical, and privacy-conscious. Help with spending, debt payoff, cashflow timing, budgets, goals, and statement questions. Do not claim to be a financial advisor."
	if req.UserID != "" {
		if summary, err := s.financeContext(c.Context(), req.UserID); err == nil && summary != "" {
			instructions += "\n\nCurrent finance context:\n" + summary
		}
	}
	return c.JSON(fiber.Map{
		"client_secret": decoded.Value,
		"expires_at":    time.Unix(decoded.ExpiresAt, 0).UTC(),
		"model":         model,
		"voice":         voice,
		"websocket_url": "wss://api.x.ai/v1/realtime?model=" + model,
		"session": fiber.Map{
			"type": "session.update",
			"session": fiber.Map{
				"voice":          voice,
				"instructions":   instructions,
				"turn_detection": nil,
				"input_audio_transcription": fiber.Map{
					"model": "grok-2-audio",
				},
				"audio": fiber.Map{
					"input":  fiber.Map{"format": fiber.Map{"type": "audio/pcm", "rate": 24000}},
					"output": fiber.Map{"format": fiber.Map{"type": "audio/pcm", "rate": 24000}},
				},
			},
		},
	})
}
func (s *server) financeContext(ctx context.Context, userID string) (string, error) {
	var accounts []apiAccount
	var transactions []apiTransaction
	if err := s.convex.query(ctx, "finance:legacyListAccounts", fiber.Map{"userKey": userID}, &accounts); err != nil {
		return "", err
	}
	_ = s.convex.query(ctx, "finance:legacyListTransactions", fiber.Map{"userKey": userID, "limit": 20}, &transactions)
	lines := []string{fmt.Sprintf("Accounts: %d", len(accounts)), fmt.Sprintf("Recent transactions: %d", len(transactions))}
	for _, account := range accounts {
		lines = append(lines, fmt.Sprintf("- %s %s balance=%d limit=%d close_day=%d due_day=%d", account.Name, account.Type, account.BalanceCents, account.CreditLimitCents, account.StatementCloseDay, account.PaymentDueDay))
	}
	for _, tx := range transactions {
		lines = append(lines, fmt.Sprintf("- %s amount=%d date=%s", tx.Description, tx.AmountCents, tx.PostedAt.Format("2006-01-02")))
	}
	return strings.Join(lines, "\n"), nil
}
func parseStatementDate(value string) (time.Time, error) {
	value = strings.TrimSpace(value)
	layouts := []string{"2006-01-02", "01/02/2006", "1/2/2006", "Jan 2, 2006"}
	for _, layout := range layouts {
		if parsed, err := time.Parse(layout, value); err == nil {
			return parsed, nil
		}
	}
	return time.Time{}, errors.New("unsupported date format")
}

type parsedStatementTransaction struct {
	PostedAt    time.Time
	Description string
	AmountCents int64
}

func extractPDFText(path string) (string, error) {
	text, err := extractPDFTextGo(path)
	if err == nil && strings.TrimSpace(text) != "" {
		return text, nil
	}
	text, fallbackErr := extractPDFTextPython(path)
	if fallbackErr == nil && strings.TrimSpace(text) != "" {
		return text, nil
	}
	if err != nil {
		return "", err
	}
	return "", fallbackErr
}
func extractPDFTextGo(path string) (string, error) {
	file, reader, err := pdfreader.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	plain, err := reader.GetPlainText()
	if err != nil {
		return "", err
	}
	var buffer bytes.Buffer
	if _, err := io.Copy(&buffer, plain); err != nil {
		return "", err
	}
	return buffer.String(), nil
}
func extractPDFTextPython(path string) (string, error) {
	python := env("PDF_TEXT_PYTHON", "/Users/jcedeno/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3")
	if _, err := os.Stat(python); err != nil {
		python = "python3"
	}
	script := `import sys
from pypdf import PdfReader
reader = PdfReader(sys.argv[1])
print("\n".join(page.extract_text() or "" for page in reader.pages))
`
	output, err := exec.Command(python, "-c", script, path).Output()
	if err != nil {
		return "", err
	}
	return string(output), nil
}
func parsePDFStatementTransactions(text string, fileName string) ([]parsedStatementTransaction, time.Time, time.Time) {
	statementStart, statementEnd := parseStatementRange(text)
	fileLower := strings.ToLower(fileName)
	textLower := strings.ToLower(text)
	if strings.Contains(fileLower, "chase") || strings.Contains(textLower, "jpmorgan chase") || strings.Contains(textLower, "chase bank") {
		return parseChaseStatement(text, statementStart, statementEnd), statementStart, statementEnd
	}
	if strings.Contains(fileLower, "capital one") || strings.Contains(fileLower, "capitalone") || strings.Contains(textLower, "capitalone.com") {
		return parseCapitalOneStatement(text, statementStart, statementEnd), statementStart, statementEnd
	}
	return parseChaseStatement(text, statementStart, statementEnd), statementStart, statementEnd
}
func parseChaseStatement(text string, statementStart time.Time, statementEnd time.Time) []parsedStatementTransaction {
	year := inferredStatementYear(statementStart, statementEnd)
	rowPattern := regexp.MustCompile(`^([0-9]{2})/([0-9]{2})\s+(.+?)\s+-\s*([0-9,]+\.[0-9]{2})\s+[0-9,]+\.[0-9]{2}$`)
	out := []parsedStatementTransaction{}
	for _, line := range strings.Split(text, "\n") {
		line = normalizeSpaces(line)
		matches := rowPattern.FindStringSubmatch(line)
		if len(matches) == 0 {
			continue
		}
		month, _ := strconv.Atoi(matches[1])
		day, _ := strconv.Atoi(matches[2])
		amount, err := parseMoneyCents(matches[4])
		if err != nil {
			continue
		}
		description := cleanStatementDescription(matches[3])
		if description == "" || isStatementHeader(description) {
			continue
		}
		out = append(out, parsedStatementTransaction{PostedAt: time.Date(year, time.Month(month), day, 12, 0, 0, 0, time.UTC), Description: description, AmountCents: -amount})
	}
	return out
}
func parseCapitalOneStatement(text string, statementStart time.Time, statementEnd time.Time) []parsedStatementTransaction {
	year := inferredStatementYear(statementStart, statementEnd)
	monthPattern := `Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec`
	rowPattern := regexp.MustCompile(`(?is)\b(` + monthPattern + `)\s+([0-9]{1,2})\s+(` + monthPattern + `)\s+([0-9]{1,2})\s+(.+?)\s+(-\s*)?\$([0-9,]+\.[0-9]{2})`)
	out := []parsedStatementTransaction{}
	for _, matches := range rowPattern.FindAllStringSubmatch(text, -1) {
		month := monthNumber(matches[1])
		day, _ := strconv.Atoi(matches[2])
		amount, err := parseMoneyCents(matches[7])
		if err != nil {
			continue
		}
		description := cleanStatementDescription(matches[5])
		if description == "" || isStatementHeader(description) {
			continue
		}
		amountCents := -amount
		if strings.TrimSpace(matches[6]) != "" {
			amountCents = amount
		}
		out = append(out, parsedStatementTransaction{PostedAt: time.Date(year, time.Month(month), day, 12, 0, 0, 0, time.UTC), Description: description, AmountCents: amountCents})
	}
	return out
}
func parseStatementRange(text string) (time.Time, time.Time) {
	monthPattern := `January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec`
	patterns := []*regexp.Regexp{
		regexp.MustCompile(`(?i)\b(` + monthPattern + `)\s+([0-9]{1,2}),\s*(20[0-9]{2})\s+(?:through|-)\s+(` + monthPattern + `)\s+([0-9]{1,2}),\s*(20[0-9]{2})\b`),
		regexp.MustCompile(`(?i)\b(` + monthPattern + `)\s+([0-9]{1,2}),\s*(20[0-9]{2})\s*-\s*(` + monthPattern + `)\s+([0-9]{1,2}),\s*(20[0-9]{2})\b`),
	}
	for _, pattern := range patterns {
		matches := pattern.FindStringSubmatch(text)
		if len(matches) == 7 {
			startYear, _ := strconv.Atoi(matches[3])
			endYear, _ := strconv.Atoi(matches[6])
			startDay, _ := strconv.Atoi(matches[2])
			endDay, _ := strconv.Atoi(matches[5])
			return time.Date(startYear, time.Month(monthNumber(matches[1])), startDay, 0, 0, 0, 0, time.UTC), time.Date(endYear, time.Month(monthNumber(matches[4])), endDay, 0, 0, 0, 0, time.UTC)
		}
	}
	return time.Time{}, time.Time{}
}
func inferredStatementYear(statementStart time.Time, statementEnd time.Time) int {
	if !statementEnd.IsZero() {
		return statementEnd.Year()
	}
	if !statementStart.IsZero() {
		return statementStart.Year()
	}
	return time.Now().UTC().Year()
}
func statementExternalID(accountID string, fileName string, parsed parsedStatementTransaction, index int) string {
	sum := sha256.Sum256([]byte(fmt.Sprintf("%s|%s|%s|%s|%d|%d", accountID, fileName, parsed.PostedAt.Format("2006-01-02"), parsed.Description, parsed.AmountCents, index)))
	return "statement_pdf:" + fmt.Sprintf("%x", sum[:16])
}
func parseMoneyCents(value string) (int64, error) {
	cleaned := strings.NewReplacer("$", "", ",", "", " ", "").Replace(value)
	amount, err := strconv.ParseFloat(cleaned, 64)
	if err != nil {
		return 0, err
	}
	return int64(math.Round(amount * 100)), nil
}
func monthNumber(value string) int {
	switch strings.ToLower(value[:3]) {
	case "jan":
		return 1
	case "feb":
		return 2
	case "mar":
		return 3
	case "apr":
		return 4
	case "may":
		return 5
	case "jun":
		return 6
	case "jul":
		return 7
	case "aug":
		return 8
	case "sep":
		return 9
	case "oct":
		return 10
	case "nov":
		return 11
	case "dec":
		return 12
	default:
		return 1
	}
}
func cleanStatementDescription(value string) string {
	value = regexp.MustCompile(`(?i)\b(JUAN\s+O\s+CEDENO\s+#[0-9]+:|Trans Date|Post Date|Description|Amount|Transactions|Payments, Credits and Adjustments|Total Transactions)\b`).ReplaceAllString(value, " ")
	return normalizeSpaces(value)
}
func normalizeSpaces(value string) string {
	return strings.Join(strings.Fields(strings.ReplaceAll(value, "\u00a0", " ")), " ")
}
func isStatementHeader(value string) bool {
	lower := strings.ToLower(value)
	return lower == "" || strings.Contains(lower, "visit capitalone.com") || strings.Contains(lower, "account summary") || strings.Contains(lower, "payment information")
}

func (s *server) createLinkToken(c *fiber.Ctx) error {
	var req struct {
		UserID string `json:"user_id"`
	}
	if err := c.BodyParser(&req); err != nil {
		return bad(c, err)
	}
	var out struct {
		LinkToken  string    `json:"link_token"`
		Expiration time.Time `json:"expiration"`
		RequestID  string    `json:"request_id"`
	}
	request := map[string]any{"client_id": s.plaid.clientID, "secret": s.plaid.secret, "client_name": defaultString(os.Getenv("PLAID_APP_NAME"), "Budget"), "country_codes": []string{"US"}, "language": "en", "products": []string{"transactions"}, "user": map[string]string{"client_user_id": req.UserID}}
	if redirectURI := os.Getenv("PLAID_REDIRECT_URI"); strings.HasPrefix(redirectURI, "https://") {
		request["redirect_uri"] = redirectURI
	}
	if err := s.plaid.post(c.Context(), "/link/token/create", request, &out); err != nil {
		return fail(c, err)
	}
	return c.JSON(out)
}

type plaidExchangeResponse struct {
	AccessToken string `json:"access_token"`
	ItemID      string `json:"item_id"`
}

type plaidAccountsResponse struct {
	Accounts []struct {
		AccountID    string `json:"account_id"`
		Name         string `json:"name"`
		OfficialName string `json:"official_name"`
		Type         string `json:"type"`
		Subtype      string `json:"subtype"`
		Balances     struct {
			Current         float64 `json:"current"`
			Limit           float64 `json:"limit"`
			IsoCurrencyCode string  `json:"iso_currency_code"`
		} `json:"balances"`
	} `json:"accounts"`
	Item struct {
		InstitutionID string `json:"institution_id"`
	} `json:"item"`
}

type plaidSyncTransaction struct {
	TransactionID           string  `json:"transaction_id"`
	AccountID               string  `json:"account_id"`
	Name                    string  `json:"name"`
	MerchantName            string  `json:"merchant_name"`
	Amount                  float64 `json:"amount"`
	IsoCurrencyCode         string  `json:"iso_currency_code"`
	Date                    string  `json:"date"`
	Pending                 bool    `json:"pending"`
	PersonalFinanceCategory struct {
		Primary    string `json:"primary"`
		Detailed   string `json:"detailed"`
		Confidence string `json:"confidence_level"`
	} `json:"personal_finance_category"`
	Location struct {
		City   string `json:"city"`
		Region string `json:"region"`
	} `json:"location"`
}

type plaidSyncResponse struct {
	Added    []plaidSyncTransaction `json:"added"`
	Modified []plaidSyncTransaction `json:"modified"`
	Removed  []struct {
		TransactionID string `json:"transaction_id"`
	} `json:"removed"`
	NextCursor string `json:"next_cursor"`
	HasMore    bool   `json:"has_more"`
}

type plaidTransactionsGetResponse struct {
	Transactions      []plaidSyncTransaction `json:"transactions"`
	TotalTransactions int                    `json:"total_transactions"`
}

func (s *server) exchangePublicToken(c *fiber.Ctx) error {
	var req struct {
		UserID      string `json:"user_id"`
		PublicToken string `json:"public_token"`
	}
	if err := c.BodyParser(&req); err != nil {
		return bad(c, err)
	}
	var exchange plaidExchangeResponse
	if err := s.plaid.post(c.Context(), "/item/public_token/exchange", map[string]any{"client_id": s.plaid.clientID, "secret": s.plaid.secret, "public_token": req.PublicToken}, &exchange); err != nil {
		return fail(c, err)
	}
	encrypted, err := s.cipher.encrypt(exchange.AccessToken)
	if err != nil {
		return fail(c, err)
	}
	var accountsResponse plaidAccountsResponse
	if err := s.plaid.post(c.Context(), "/accounts/get", map[string]any{"client_id": s.plaid.clientID, "secret": s.plaid.secret, "access_token": exchange.AccessToken}, &accountsResponse); err != nil {
		return fail(c, err)
	}
	displayName := defaultString(accountsResponse.Item.InstitutionID, "Plaid")
	var connectionID string
	if err := s.convex.mutation(c.Context(), "finance:legacyUpsertConnection", fiber.Map{"userKey": req.UserID, "provider": "plaid", "displayName": displayName, "externalConnectionId": exchange.ItemID, "encryptedPayload": encrypted}, &connectionID); err != nil {
		return fail(c, err)
	}
	createdAccounts := []map[string]any{}
	for _, plaidAccount := range accountsResponse.Accounts {
		var acc map[string]any
		args := fiber.Map{"userKey": req.UserID, "connectionId": connectionID, "provider": "plaid", "externalAccountId": plaidAccount.AccountID, "displayName": plaidAccount.Name, "officialName": plaidAccount.OfficialName, "type": plaidAccount.Type, "subtype": plaidAccount.Subtype, "currencyCode": defaultString(plaidAccount.Balances.IsoCurrencyCode, "USD"), "balanceCents": int64(math.Round(plaidAccount.Balances.Current * 100)), "creditLimitCents": int64(math.Round(plaidAccount.Balances.Limit * 100))}
		if err := s.convex.mutation(c.Context(), "finance:legacyUpsertProviderAccount", args, &acc); err != nil {
			return fail(c, err)
		}
		createdAccounts = append(createdAccounts, acc)
	}
	item := plaidSyncItem{UserID: req.UserID, ItemID: exchange.ItemID, DisplayName: displayName, AccessTokenCiphertext: encrypted}
	syncResult, err := s.syncPlaidAccessToken(c.Context(), item, exchange.AccessToken)
	if err != nil {
		return fail(c, err)
	}
	return c.JSON(fiber.Map{"item": item, "accounts": createdAccounts, "sync": syncResult})
}

func (s *server) syncPlaidItems(c *fiber.Ctx) error {
	var req struct {
		UserID string `json:"user_id"`
	}
	if err := c.BodyParser(&req); err != nil {
		return bad(c, err)
	}
	if req.UserID == "" {
		req.UserID = c.Query("user_id")
	}
	if req.UserID == "" {
		return bad(c, errors.New("user_id is required"))
	}
	var items []plaidSyncItem
	if err := s.convex.query(c.Context(), "finance:legacyListPlaidConnections", fiber.Map{"userKey": req.UserID}, &items); err != nil {
		return fail(c, err)
	}
	totalAdded := 0
	totalModified := 0
	totalRemoved := 0
	totalBackfilled := 0
	results := []fiber.Map{}
	for _, item := range items {
		item.UserID = req.UserID
		accessToken, err := s.cipher.decrypt(item.AccessTokenCiphertext)
		if err != nil {
			return fail(c, err)
		}
		result, err := s.syncPlaidAccessToken(c.Context(), item, accessToken)
		if err != nil {
			return fail(c, err)
		}
		totalAdded += fiberInt(result, "added")
		totalModified += fiberInt(result, "modified")
		totalRemoved += fiberInt(result, "removed")
		totalBackfilled += fiberInt(result, "backfilled")
		result["item_id"] = item.ItemID
		results = append(results, result)
	}
	return c.JSON(fiber.Map{"items": len(items), "added": totalAdded, "modified": totalModified, "removed": totalRemoved, "backfilled": totalBackfilled, "results": results})
}

func (s *server) syncPlaidItem(c *fiber.Ctx) error {
	userID := c.Query("user_id")
	itemID := c.Params("id")
	syncResult, err := s.syncPlaidItemByID(c.Context(), userID, itemID)
	if err != nil {
		return fail(c, err)
	}
	return c.JSON(syncResult)
}

func (s *server) syncPlaidItemByID(ctx context.Context, userID string, itemID string) (fiber.Map, error) {
	var secret struct {
		SyncCursor       string `json:"syncCursor"`
		EncryptedPayload string `json:"encryptedPayload"`
	}
	if err := s.convex.query(ctx, "finance:legacyGetConnectionSecret", fiber.Map{"userKey": userID, "provider": "plaid", "externalConnectionId": itemID}, &secret); err != nil {
		return nil, err
	}
	accessToken, err := s.cipher.decrypt(secret.EncryptedPayload)
	if err != nil {
		return nil, err
	}
	item := plaidSyncItem{UserID: userID, ItemID: itemID, TransactionsCursor: secret.SyncCursor, AccessTokenCiphertext: secret.EncryptedPayload}
	return s.syncPlaidAccessToken(ctx, item, accessToken)
}

func (s *server) plaidWebhook(c *fiber.Ctx) error {
	var req struct {
		WebhookType string `json:"webhook_type"`
		WebhookCode string `json:"webhook_code"`
		ItemID      string `json:"item_id"`
	}
	if err := c.BodyParser(&req); err != nil {
		return bad(c, err)
	}
	if req.ItemID == "" {
		return c.JSON(fiber.Map{"ok": true, "ignored": true})
	}
	if req.WebhookType != "TRANSACTIONS" {
		return c.JSON(fiber.Map{"ok": true, "ignored": true})
	}
	var item plaidSyncItem
	if err := s.convex.query(c.Context(), "finance:legacyGetPlaidConnectionByItemId", fiber.Map{"externalConnectionId": req.ItemID}, &item); err != nil {
		log.Printf("plaid webhook lookup failed item_id=%s code=%s err=%v", req.ItemID, req.WebhookCode, err)
		return c.JSON(fiber.Map{"ok": true, "queued": false, "item_id": req.ItemID, "warning": "connection not found"})
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
		defer cancel()
		accessToken, err := s.cipher.decrypt(item.AccessTokenCiphertext)
		if err != nil {
			log.Printf("plaid webhook decrypt failed item_id=%s err=%v", req.ItemID, err)
			return
		}
		result, err := s.syncPlaidAccessToken(ctx, item, accessToken)
		if err != nil {
			log.Printf("plaid webhook sync failed item_id=%s code=%s err=%v", req.ItemID, req.WebhookCode, err)
			return
		}
		log.Printf("plaid webhook synced item_id=%s code=%s added=%d modified=%d removed=%d", req.ItemID, req.WebhookCode, fiberInt(result, "added"), fiberInt(result, "modified"), fiberInt(result, "removed"))
	}()
	return c.JSON(fiber.Map{"ok": true, "queued": true, "item_id": req.ItemID, "webhook_code": req.WebhookCode})
}

func (s *server) syncPlaidAccessToken(ctx context.Context, item plaidSyncItem, accessToken string) (fiber.Map, error) {
	request := map[string]any{"client_id": s.plaid.clientID, "secret": s.plaid.secret, "access_token": accessToken, "options": map[string]any{"include_personal_finance_category": true}}
	if item.TransactionsCursor != "" {
		request["cursor"] = item.TransactionsCursor
	}
	added := 0
	modified := 0
	removed := 0
	for {
		var syncResponse plaidSyncResponse
		if err := s.plaid.post(ctx, "/transactions/sync", request, &syncResponse); err != nil {
			return nil, err
		}
		for _, plaidTransaction := range syncResponse.Added {
			if err := s.upsertPlaidTransaction(ctx, item.UserID, plaidTransaction); err != nil {
				return nil, err
			}
			added++
		}
		for _, plaidTransaction := range syncResponse.Modified {
			if err := s.upsertPlaidTransaction(ctx, item.UserID, plaidTransaction); err != nil {
				return nil, err
			}
			modified++
		}
		for _, removedTransaction := range syncResponse.Removed {
			if removedTransaction.TransactionID == "" {
				continue
			}
			var out map[string]any
			if err := s.convex.mutation(ctx, "finance:legacyRemoveProviderTransaction", fiber.Map{"userKey": item.UserID, "provider": "plaid", "externalTransactionId": removedTransaction.TransactionID}, &out); err != nil {
				return nil, err
			}
			removed += intFromAny(out["removed"])
		}
		item.TransactionsCursor = syncResponse.NextCursor
		if !syncResponse.HasMore {
			break
		}
		request["cursor"] = syncResponse.NextCursor
	}
	_ = s.convex.mutation(ctx, "finance:legacyUpdateConnectionCursor", fiber.Map{"userKey": item.UserID, "provider": "plaid", "externalConnectionId": item.ItemID, "syncCursor": item.TransactionsCursor}, nil)
	backfilled, err := s.backfillPlaidTransactions(ctx, item.UserID, accessToken, 12)
	if err != nil {
		return fiber.Map{"added": added, "modified": modified, "removed": removed, "backfilled": backfilled, "backfill_error": err.Error(), "next_cursor": item.TransactionsCursor}, nil
	}
	return fiber.Map{"added": added, "modified": modified, "removed": removed, "backfilled": backfilled, "next_cursor": item.TransactionsCursor}, nil
}

func (s *server) backfillPlaidTransactions(ctx context.Context, userID string, accessToken string, months int) (int, error) {
	if months <= 0 {
		months = 12
	}
	end := time.Now().UTC()
	start := end.AddDate(0, -months, 0)
	count := 500
	offset := 0
	backfilled := 0
	for {
		request := map[string]any{
			"client_id":    s.plaid.clientID,
			"secret":       s.plaid.secret,
			"access_token": accessToken,
			"start_date":   start.Format("2006-01-02"),
			"end_date":     end.Format("2006-01-02"),
			"options": map[string]any{
				"count":                             count,
				"offset":                            offset,
				"include_personal_finance_category": true,
			},
		}
		var response plaidTransactionsGetResponse
		if err := s.plaid.post(ctx, "/transactions/get", request, &response); err != nil {
			return backfilled, err
		}
		for _, plaidTransaction := range response.Transactions {
			if err := s.upsertPlaidTransaction(ctx, userID, plaidTransaction); err != nil {
				return backfilled, err
			}
			backfilled++
		}
		offset += len(response.Transactions)
		if len(response.Transactions) == 0 || offset >= response.TotalTransactions {
			break
		}
	}
	return backfilled, nil
}

func (s *server) upsertPlaidTransaction(ctx context.Context, userID string, plaidTransaction plaidSyncTransaction) error {
	postedAt, _ := time.Parse("2006-01-02", plaidTransaction.Date)
	location := plaidTransaction.Location.City
	if plaidTransaction.Location.Region != "" {
		location += ", " + plaidTransaction.Location.Region
	}
	if postedAt.IsZero() {
		postedAt = time.Now().UTC()
	}
	amountCents := plaidAmountToCents(plaidTransaction.Amount)
	categoryName := plaidCategoryName(plaidTransaction)
	categorySplits := []categorySplit{}
	if categoryName != "" {
		categorySplits = append(categorySplits, categorySplit{Name: categoryName, AmountCents: amountCents})
	}
	var out map[string]any
	args := fiber.Map{"userKey": userID, "provider": "plaid", "externalAccountId": plaidTransaction.AccountID, "externalTransactionId": plaidTransaction.TransactionID, "description": plaidTransaction.Name, "merchantName": plaidTransaction.MerchantName, "amountCents": amountCents, "currencyCode": defaultString(plaidTransaction.IsoCurrencyCode, "USD"), "postedAt": postedAt.Format(time.RFC3339), "pending": plaidTransaction.Pending, "locationName": location, "categorySplits": categorySplits, "raw": plaidTransaction}
	return s.convex.mutation(ctx, "finance:legacyUpsertProviderTransaction", args, &out)
}

func plaidCategoryName(tx plaidSyncTransaction) string {
	detailed := strings.TrimSpace(strings.ReplaceAll(tx.PersonalFinanceCategory.Detailed, "_", " "))
	primary := strings.TrimSpace(strings.ReplaceAll(tx.PersonalFinanceCategory.Primary, "_", " "))
	value := defaultString(detailed, primary)
	value = strings.ToLower(value)
	parts := strings.Fields(value)
	for i, part := range parts {
		parts[i] = strings.ToUpper(part[:1]) + part[1:]
	}
	return strings.Join(parts, " ")
}

func fiberInt(values fiber.Map, key string) int {
	value, ok := values[key]
	if !ok {
		return 0
	}
	switch typed := value.(type) {
	case int:
		return typed
	case int32:
		return int(typed)
	case int64:
		return int(typed)
	default:
		return 0
	}
}

func intFromAny(value any) int {
	switch typed := value.(type) {
	case int:
		return typed
	case int32:
		return int(typed)
	case int64:
		return int(typed)
	case float64:
		return int(typed)
	case json.Number:
		n, _ := typed.Int64()
		return int(n)
	default:
		return 0
	}
}

func stringValue(value any) string {
	if value == nil {
		return ""
	}
	switch typed := value.(type) {
	case string:
		return typed
	default:
		return fmt.Sprint(typed)
	}
}

func timeFromAny(value any) time.Time {
	switch typed := value.(type) {
	case time.Time:
		return typed.UTC()
	case string:
		parsed, _ := time.Parse(time.RFC3339, typed)
		return parsed.UTC()
	default:
		return time.Time{}
	}
}

func (p *plaidClient) post(ctx context.Context, path string, requestBody any, responseBody any) error {
	body, err := json.Marshal(requestBody)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, p.baseURL+path, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := p.httpClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("plaid %s failed with %d: %s", path, resp.StatusCode, string(data))
	}
	return json.Unmarshal(data, responseBody)
}

func (c *convexClient) query(ctx context.Context, path string, args any, responseBody any) error {
	return c.call(ctx, "api/query", path, args, responseBody)
}

func (c *convexClient) mutation(ctx context.Context, path string, args any, responseBody any) error {
	return c.call(ctx, "api/mutation", path, args, responseBody)
}

func (c *convexClient) call(ctx context.Context, endpoint string, path string, args any, responseBody any) error {
	if c.deploymentURL == "" || c.deployKey == "" {
		return errors.New("CONVEX_DEPLOYMENT and CONVEX_DEPLOYMENT_KEY are required")
	}
	body, err := json.Marshal(fiber.Map{"path": path, "format": "convex_encoded_json", "args": []any{convexEncode(args)}})
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(c.deploymentURL, "/")+"/"+endpoint, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Convex "+c.deployKey)
	resp, err := c.httpClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("convex %s failed with %d: %s", path, resp.StatusCode, string(data))
	}
	var envelope struct {
		Status       string          `json:"status"`
		Value        json.RawMessage `json:"value"`
		ErrorMessage string          `json:"errorMessage"`
	}
	if err := json.Unmarshal(data, &envelope); err != nil {
		return err
	}
	if envelope.Status != "success" {
		return fmt.Errorf("convex %s failed: %s", path, defaultString(envelope.ErrorMessage, string(data)))
	}
	if responseBody == nil {
		return nil
	}
	return json.Unmarshal(envelope.Value, responseBody)
}

func convexEncode(value any) any {
	switch typed := value.(type) {
	case nil, string, bool, float64, float32:
		return typed
	case int64:
		var buf [8]byte
		binary.LittleEndian.PutUint64(buf[:], uint64(typed))
		return fiber.Map{"$integer": base64.StdEncoding.EncodeToString(buf[:])}
	case []categorySplit:
		out := make([]any, 0, len(typed))
		for _, item := range typed {
			out = append(out, convexEncode(fiber.Map{"categoryId": item.CategoryID, "name": item.Name, "amountCents": item.AmountCents}))
		}
		return out
	case []fiber.Map:
		out := make([]any, 0, len(typed))
		for _, item := range typed {
			out = append(out, convexEncode(item))
		}
		return out
	case []any:
		out := make([]any, 0, len(typed))
		for _, item := range typed {
			out = append(out, convexEncode(item))
		}
		return out
	case fiber.Map:
		out := fiber.Map{}
		for key, item := range typed {
			if !skipConvexValue(item) {
				out[key] = convexEncode(item)
			}
		}
		return out
	case map[string]any:
		out := map[string]any{}
		for key, item := range typed {
			if !skipConvexValue(item) {
				out[key] = convexEncode(item)
			}
		}
		return out
	default:
		return typed
	}
}

func skipConvexValue(value any) bool {
	if value == nil {
		return true
	}
	if text, ok := value.(string); ok {
		return text == ""
	}
	return false
}

func defaultString(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}
func plaidAmountToCents(amount float64) int64 { return -int64(math.Round(amount * 100)) }
