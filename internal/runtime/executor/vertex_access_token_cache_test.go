package executor

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/MoeForge/moego/json"
	"github.com/router-for-me/CLIProxyAPI/v8/internal/config"
	cliproxyauth "github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/auth"
)

// newCountingVertexTokenServer serves OAuth token responses numbered tok-1, tok-2, ... and counts
// hits. The first failFirst requests answer 500.
func newCountingVertexTokenServer(t *testing.T, expiresIn, failFirst int32) (*httptest.Server, *atomic.Int32) {
	t.Helper()
	var hits atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n := hits.Add(1)
		if n <= failFirst {
			http.Error(w, "boom", http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = fmt.Fprintf(w, `{"access_token":"tok-%d","token_type":"Bearer","expires_in":%d}`, n, expiresIn)
	}))
	t.Cleanup(srv.Close)
	return srv, &hits
}

func TestVertexAccessTokenIsReusedAcrossCalls(t *testing.T) {
	srv, hits := newCountingVertexTokenServer(t, 3600, 0)
	sa := testVertexServiceAccountJSON(t, srv.URL)

	for i := range 3 {
		token, err := vertexAccessToken(context.Background(), &config.Config{}, &cliproxyauth.Auth{ID: "reuse"}, sa)
		if err != nil {
			t.Fatalf("call %d: %v", i, err)
		}
		if token != "tok-1" {
			t.Fatalf("call %d token = %q, want tok-1", i, token)
		}
	}
	if got := hits.Load(); got != 1 {
		t.Fatalf("token endpoint hits = %d, want 1", got)
	}
}

func TestVertexAccessTokenIsNotReusedForReplacedKey(t *testing.T) {
	srv, hits := newCountingVertexTokenServer(t, 3600, 0)
	// Both credentials share client_email, private_key_id and token_uri; only the key differs.
	first := testVertexServiceAccountJSON(t, srv.URL)
	second := testVertexServiceAccountJSON(t, srv.URL)

	tokenA, errA := vertexAccessToken(context.Background(), &config.Config{}, &cliproxyauth.Auth{ID: "rotate"}, first)
	tokenB, errB := vertexAccessToken(context.Background(), &config.Config{}, &cliproxyauth.Auth{ID: "rotate"}, second)
	if errA != nil || errB != nil {
		t.Fatalf("errors: %v, %v", errA, errB)
	}
	if tokenA == tokenB {
		t.Fatalf("replaced key reused token %q", tokenA)
	}
	if got := hits.Load(); got != 2 {
		t.Fatalf("token endpoint hits = %d, want 2", got)
	}
}

func TestVertexAccessTokenShortLivedTokenIsNotCached(t *testing.T) {
	// A token that expires inside the refresh margin would be unusable almost at once.
	srv, hits := newCountingVertexTokenServer(t, 120, 0)
	sa := testVertexServiceAccountJSON(t, srv.URL)

	for i := range 2 {
		if _, err := vertexAccessToken(context.Background(), &config.Config{}, &cliproxyauth.Auth{ID: "short"}, sa); err != nil {
			t.Fatalf("call %d: %v", i, err)
		}
	}
	if got := hits.Load(); got != 2 {
		t.Fatalf("token endpoint hits = %d, want 2", got)
	}
}

func TestVertexAccessTokenFailedExchangeIsNotCached(t *testing.T) {
	srv, hits := newCountingVertexTokenServer(t, 3600, 1)
	sa := testVertexServiceAccountJSON(t, srv.URL)
	auth := &cliproxyauth.Auth{ID: "fail"}

	if _, err := vertexAccessToken(context.Background(), &config.Config{}, auth, sa); err == nil {
		t.Fatal("first call succeeded, want the failed exchange to surface")
	}
	for i := range 2 {
		token, err := vertexAccessToken(context.Background(), &config.Config{}, auth, sa)
		if err != nil || token != "tok-2" {
			t.Fatalf("retry %d = %q, %v; want tok-2, nil", i, token, err)
		}
	}
	if got := hits.Load(); got != 2 {
		t.Fatalf("token endpoint hits = %d, want 2 (one failure, one success, then cached)", got)
	}
}

// TestVertexClaudeReusesAccessTokenAcrossRequests goes through the real path: the service account
// is re-marshaled from auth metadata on every request, and the same token must still be reused.
func TestVertexClaudeReusesAccessTokenAcrossRequests(t *testing.T) {
	tokenSrv, hits := newCountingVertexTokenServer(t, 3600, 0)
	var (
		mu         sync.Mutex
		authValues []string
	)
	apiSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		mu.Lock()
		authValues = append(authValues, r.Header.Get("Authorization"))
		mu.Unlock()
		vertexClaudeOKResponder(w, false)
	}))
	t.Cleanup(apiSrv.Close)
	prev := vertexClaudeBaseURL
	vertexClaudeBaseURL = func(string) string { return apiSrv.URL }
	t.Cleanup(func() { vertexClaudeBaseURL = prev })

	var sa map[string]any
	if err := json.Unmarshal(testVertexServiceAccountJSON(t, tokenSrv.URL), &sa); err != nil {
		t.Fatalf("unmarshal sa: %v", err)
	}
	auth := &cliproxyauth.Auth{
		ID:       "vertex-sa-reuse",
		Provider: "vertex",
		Metadata: map[string]any{"project_id": "proj-1", "location": "us-east5", "service_account": sa},
	}
	exec := vertexClaudeTestExecutor(nil)
	const requests = 3
	for i := range requests {
		req, opts := vertexClaudeReq("claude-sonnet-5-5")
		if _, err := exec.Execute(context.Background(), auth, req, opts); err != nil {
			t.Fatalf("request %d: %v", i, err)
		}
	}

	if got := hits.Load(); got != 1 {
		t.Fatalf("token endpoint hits = %d for %d requests, want 1", got, requests)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(authValues) != requests {
		t.Fatalf("upstream saw %d requests, want %d", len(authValues), requests)
	}
	for i, value := range authValues {
		if value != "Bearer tok-1" {
			t.Fatalf("request %d Authorization = %q, want Bearer tok-1", i, value)
		}
	}
}
