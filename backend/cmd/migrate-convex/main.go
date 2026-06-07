package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/joho/godotenv"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
)

type convexClient struct {
	url    string
	key    string
	client *http.Client
}

func main() {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	_ = godotenv.Load(".env")
	if cwd, err := os.Getwd(); err == nil {
		_ = godotenv.Load(filepath.Join(cwd, "..", ".env"))
		_ = godotenv.Load(filepath.Join(cwd, "..", "..", ".env"))
	}
	mongoURI := os.Getenv("MONGO_URI")
	if mongoURI == "" {
		log.Fatal("MONGO_URI is required")
	}
	convexURL := convexURLFromEnv()
	convexKey := os.Getenv("CONVEX_DEPLOYMENT_KEY")
	if convexURL == "" || convexKey == "" {
		log.Fatal("CONVEX_DEPLOYMENT/CONVEX_URL and CONVEX_DEPLOYMENT_KEY are required")
	}
	mongoClient, err := mongo.Connect(ctx, options.Client().ApplyURI(mongoURI))
	if err != nil {
		log.Fatal(err)
	}
	defer mongoClient.Disconnect(context.Background())
	db := mongoClient.Database(databaseNameFromURI(mongoURI, "budget-app"))
	convex := &convexClient{url: convexURL, key: convexKey, client: &http.Client{Timeout: 30 * time.Second}}
	if err := migratePlaidItems(ctx, db, convex); err != nil {
		log.Fatal(err)
	}
	accountIDs, err := migrateAccounts(ctx, db, convex)
	if err != nil {
		log.Fatal(err)
	}
	if err := migrateTransactions(ctx, db, convex, accountIDs); err != nil {
		log.Fatal(err)
	}
	if err := migrateBudgets(ctx, db, convex); err != nil {
		log.Fatal(err)
	}
	if err := migrateGoals(ctx, db, convex); err != nil {
		log.Fatal(err)
	}
	if err := migrateStatements(ctx, db, convex, accountIDs); err != nil {
		log.Fatal(err)
	}
	log.Printf("migration complete: %d accounts mapped", len(accountIDs))
}

func migratePlaidItems(ctx context.Context, db *mongo.Database, convex *convexClient) error {
	cursor, err := db.Collection("plaid_items").Find(ctx, bson.M{})
	if err != nil {
		return err
	}
	defer cursor.Close(ctx)
	for cursor.Next(ctx) {
		var doc bson.M
		if err := cursor.Decode(&doc); err != nil {
			return err
		}
		userKey := stringValue(doc["user_id"])
		itemID := stringValue(doc["item_id"])
		if userKey == "" || itemID == "" {
			continue
		}
		var connectionID string
		args := map[string]any{
			"userKey":              userKey,
			"provider":             "plaid",
			"displayName":          defaultString(stringValue(doc["institution_id"]), itemID),
			"externalConnectionId": itemID,
			"syncCursor":           stringValue(doc["transactions_cursor"]),
			"encryptedPayload":     stringValue(doc["access_token_ciphertext"]),
		}
		if err := convex.mutation(ctx, "finance:legacyUpsertConnection", args, &connectionID); err != nil {
			return err
		}
	}
	return cursor.Err()
}

func migrateAccounts(ctx context.Context, db *mongo.Database, convex *convexClient) (map[string]string, error) {
	out := map[string]string{}
	cursor, err := db.Collection("accounts").Find(ctx, bson.M{})
	if err != nil {
		return out, err
	}
	defer cursor.Close(ctx)
	for cursor.Next(ctx) {
		var doc bson.M
		if err := cursor.Decode(&doc); err != nil {
			return out, err
		}
		userKey := stringValue(doc["user_id"])
		if userKey == "" {
			continue
		}
		source := stringValue(doc["source"])
		oldID := objectIDString(doc["_id"])
		var saved map[string]any
		switch source {
		case "plaid":
			itemID := stringValue(doc["plaid_item_id"])
			if itemID == "" {
				continue
			}
			var connectionID string
			if err := convex.mutation(ctx, "finance:legacyUpsertConnection", map[string]any{"userKey": userKey, "provider": "plaid", "displayName": itemID, "externalConnectionId": itemID}, &connectionID); err != nil {
				return out, err
			}
			args := map[string]any{"userKey": userKey, "connectionId": connectionID, "provider": "plaid", "externalAccountId": stringValue(doc["plaid_account_id"]), "displayName": stringValue(doc["name"]), "officialName": stringValue(doc["official_name"]), "type": stringValue(doc["type"]), "subtype": stringValue(doc["subtype"]), "currencyCode": defaultString(stringValue(doc["currency_code"]), "USD"), "balanceCents": int64Value(doc["balance_cents"]), "creditLimitCents": int64Value(doc["credit_limit_cents"])}
			if err := convex.mutation(ctx, "finance:legacyUpsertProviderAccount", args, &saved); err != nil {
				return out, err
			}
		case "financekit":
			var connectionID string
			if err := convex.mutation(ctx, "finance:legacyUpsertConnection", map[string]any{"userKey": userKey, "provider": "financeKit", "displayName": "Apple Wallet", "externalConnectionId": "apple-wallet"}, &connectionID); err != nil {
				return out, err
			}
			args := map[string]any{"userKey": userKey, "connectionId": connectionID, "provider": "financeKit", "externalAccountId": stringValue(doc["financekit_id"]), "displayName": stringValue(doc["name"]), "officialName": stringValue(doc["official_name"]), "type": stringValue(doc["type"]), "subtype": stringValue(doc["subtype"]), "currencyCode": defaultString(stringValue(doc["currency_code"]), "USD"), "balanceCents": int64Value(doc["balance_cents"]), "creditLimitCents": int64Value(doc["credit_limit_cents"])}
			if err := convex.mutation(ctx, "finance:legacyUpsertProviderAccount", args, &saved); err != nil {
				return out, err
			}
		default:
			args := map[string]any{"userKey": userKey, "name": stringValue(doc["name"]), "type": stringValue(doc["type"]), "subtype": stringValue(doc["subtype"]), "currencyCode": defaultString(stringValue(doc["currency_code"]), "USD"), "balanceCents": int64Value(doc["balance_cents"]), "creditLimitCents": int64Value(doc["credit_limit_cents"]), "statementCloseDay": intValue(doc["statement_close_day"]), "paymentDueDay": intValue(doc["payment_due_day"])}
			if err := convex.mutation(ctx, "finance:legacyCreateManualAccount", args, &saved); err != nil {
				return out, err
			}
		}
		if oldID != "" && stringValue(saved["id"]) != "" {
			out[oldID] = stringValue(saved["id"])
		}
	}
	return out, cursor.Err()
}

func migrateTransactions(ctx context.Context, db *mongo.Database, convex *convexClient, accountIDs map[string]string) error {
	cursor, err := db.Collection("transactions").Find(ctx, bson.M{})
	if err != nil {
		return err
	}
	defer cursor.Close(ctx)
	for cursor.Next(ctx) {
		var doc bson.M
		if err := cursor.Decode(&doc); err != nil {
			return err
		}
		userKey := stringValue(doc["user_id"])
		accountID := accountIDs[objectIDString(doc["account_id"])]
		if userKey == "" || accountID == "" {
			continue
		}
		source := stringValue(doc["source"])
		postedAt := timeValue(doc["posted_at"])
		if postedAt.IsZero() {
			postedAt = time.Now().UTC()
		}
		if source == "plaid" && stringValue(doc["external_id"]) != "" {
			var saved map[string]any
			args := map[string]any{"userKey": userKey, "provider": "plaid", "externalAccountId": stringValue(doc["plaid_account_id"]), "externalTransactionId": stringValue(doc["external_id"]), "description": stringValue(doc["description"]), "merchantName": stringValue(doc["merchant_name"]), "amountCents": int64Value(doc["amount_cents"]), "currencyCode": defaultString(stringValue(doc["currency_code"]), "USD"), "postedAt": postedAt.Format(time.RFC3339), "pending": boolValue(doc["pending"]), "locationName": stringValue(doc["location_name"]), "raw": doc}
			_ = convex.mutation(ctx, "finance:legacyUpsertProviderTransaction", args, &saved)
			continue
		}
		var saved map[string]any
		args := map[string]any{"userKey": userKey, "accountId": accountID, "description": stringValue(doc["description"]), "merchantName": stringValue(doc["merchant_name"]), "amountCents": int64Value(doc["amount_cents"]), "currencyCode": defaultString(stringValue(doc["currency_code"]), "USD"), "postedAt": postedAt.Format(time.RFC3339), "locationName": stringValue(doc["location_name"]), "notes": stringValue(doc["notes"])}
		_ = convex.mutation(ctx, "finance:legacyCreateManualTransaction", args, &saved)
	}
	return cursor.Err()
}

func migrateBudgets(ctx context.Context, db *mongo.Database, convex *convexClient) error {
	cursor, err := db.Collection("budgets").Find(ctx, bson.M{})
	if err != nil {
		return err
	}
	defer cursor.Close(ctx)
	for cursor.Next(ctx) {
		var doc bson.M
		if err := cursor.Decode(&doc); err != nil {
			return err
		}
		var saved map[string]any
		args := map[string]any{"userKey": stringValue(doc["user_id"]), "categoryName": defaultString(stringValue(doc["category_name"]), "Uncategorized"), "period": defaultString(stringValue(doc["period"]), "monthly"), "limitCents": int64Value(doc["limit_cents"])}
		_ = convex.mutation(ctx, "finance:legacyCreateBudget", args, &saved)
	}
	return cursor.Err()
}

func migrateGoals(ctx context.Context, db *mongo.Database, convex *convexClient) error {
	cursor, err := db.Collection("goals").Find(ctx, bson.M{})
	if err != nil {
		return err
	}
	defer cursor.Close(ctx)
	for cursor.Next(ctx) {
		var doc bson.M
		if err := cursor.Decode(&doc); err != nil {
			return err
		}
		var saved map[string]any
		args := map[string]any{"userKey": stringValue(doc["user_id"]), "name": stringValue(doc["name"]), "type": defaultString(stringValue(doc["type"]), "savings"), "targetCents": int64Value(doc["target_cents"]), "currentCents": int64Value(doc["current_cents"]), "priority": intValue(doc["priority"])}
		_ = convex.mutation(ctx, "finance:legacyCreateGoal", args, &saved)
	}
	return cursor.Err()
}

func migrateStatements(ctx context.Context, db *mongo.Database, convex *convexClient, accountIDs map[string]string) error {
	cursor, err := db.Collection("statements").Find(ctx, bson.M{})
	if err != nil {
		return err
	}
	defer cursor.Close(ctx)
	for cursor.Next(ctx) {
		var doc bson.M
		if err := cursor.Decode(&doc); err != nil {
			return err
		}
		accountID := accountIDs[objectIDString(doc["account_id"])]
		if accountID == "" {
			continue
		}
		var saved map[string]any
		start := timeValue(doc["statement_start"])
		end := timeValue(doc["statement_end"])
		args := map[string]any{"userKey": stringValue(doc["user_id"]), "accountId": accountID, "fileName": defaultString(stringValue(doc["file_name"]), "Imported statement"), "fileType": defaultString(stringValue(doc["file_type"]), "manual"), "statementStart": start.Format(time.RFC3339), "statementEnd": end.Format(time.RFC3339), "importedCount": intValue(doc["imported_count"])}
		_ = convex.mutation(ctx, "finance:legacyCreateStatement", args, &saved)
	}
	return cursor.Err()
}

func (c *convexClient) mutation(ctx context.Context, path string, args any, responseBody any) error {
	return c.call(ctx, "api/mutation", path, args, responseBody)
}

func (c *convexClient) call(ctx context.Context, endpoint string, path string, args any, responseBody any) error {
	body, err := json.Marshal(map[string]any{"path": path, "format": "convex_encoded_json", "args": []any{convexEncode(args)}})
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(c.url, "/")+"/"+endpoint, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Convex "+c.key)
	resp, err := c.client.Do(req)
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
		return fmt.Errorf("convex %s failed: %s", path, string(data))
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
		return map[string]any{"$integer": base64.StdEncoding.EncodeToString(buf[:])}
	case []map[string]any:
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

func convexURLFromEnv() string {
	if value := os.Getenv("CONVEX_URL"); value != "" {
		return strings.TrimRight(value, "/")
	}
	deployment := strings.TrimPrefix(os.Getenv("CONVEX_DEPLOYMENT"), "prod:")
	if strings.HasPrefix(deployment, "http") {
		return strings.TrimRight(deployment, "/")
	}
	if deployment == "" {
		return ""
	}
	return "https://" + deployment + ".convex.cloud"
}

func databaseNameFromURI(uri string, fallback string) string {
	withoutQuery := strings.Split(uri, "?")[0]
	parts := strings.Split(strings.TrimRight(withoutQuery, "/"), "/")
	if len(parts) == 0 || parts[len(parts)-1] == "" || strings.Contains(parts[len(parts)-1], ":") {
		return fallback
	}
	return parts[len(parts)-1]
}

func objectIDString(value any) string {
	switch typed := value.(type) {
	case primitive.ObjectID:
		return typed.Hex()
	case string:
		return typed
	default:
		return ""
	}
}

func stringValue(value any) string {
	if value == nil {
		return ""
	}
	switch typed := value.(type) {
	case string:
		return typed
	case primitive.ObjectID:
		return typed.Hex()
	default:
		return fmt.Sprint(typed)
	}
}

func int64Value(value any) int64 {
	switch typed := value.(type) {
	case int32:
		return int64(typed)
	case int64:
		return typed
	case int:
		return int64(typed)
	case float64:
		if math.IsNaN(typed) || math.IsInf(typed, 0) {
			return 0
		}
		return int64(typed)
	default:
		return 0
	}
}

func intValue(value any) int { return int(int64Value(value)) }

func boolValue(value any) bool {
	typed, _ := value.(bool)
	return typed
}

func timeValue(value any) time.Time {
	switch typed := value.(type) {
	case time.Time:
		return typed.UTC()
	case primitive.DateTime:
		return typed.Time().UTC()
	default:
		return time.Time{}
	}
}

func defaultString(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}
