package executor

import (
	"context"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"

	"github.com/MoeForge/moego/ojson"
	"github.com/gin-gonic/gin"
	"github.com/router-for-me/CLIProxyAPI/v8/internal/config"
	cliproxyexecutor "github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/executor"
	sdktranslator "github.com/router-for-me/CLIProxyAPI/v8/sdk/translator"
)

// The native per-turn control must travel with the beta that authorizes it.
// Keeping both on the Vertex wire preserves effort ordering and cached history.
func TestVertexClaudeForwardsBetaWithoutRewritingEffortDirectives(t *testing.T) {
	const model = "claude-haiku-5-5"
	const beta = "per-turn-control-2026-07-01"
	const payload = `{"model":"claude-haiku-5-5","max_tokens":128000,"thinking":{"type":"adaptive"},"output_config":{"effort":"medium","format":{"type":"json_schema","schema":{"type":"object"}}},"messages":[{"role":"user","content":"hello"},{"role":"system","content":[],"output_config":{"effort":"high"}},{"role":"assistant","content":[{"type":"tool_use","id":"call_test","name":"lookup","input":{}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"call_test","content":"done"}]},{"role":"system","content":[{"type":"text","text":"Use the latest result."}],"output_config":{"effort":"low"}}],"tools":[{"name":"lookup","input_schema":{"type":"object"}}]}`
	for _, mode := range []string{"execute", "stream"} {
		for _, tc := range []struct {
			name        string
			headers     http.Header
			contextOnly bool
			override    string
			want        []string
		}{
			{name: "native", headers: http.Header{"Anthropic-Beta": {beta}}, want: []string{beta}},
			{name: "multiple lowercase values", headers: http.Header{"anthropic-beta": {" " + beta + " ", "", "mid-conversation-output-config-2026-07-01,effort-2025-11-24"}}, want: []string{beta + ",mid-conversation-output-config-2026-07-01,effort-2025-11-24"}},
			{name: "split values deduplicated in order", headers: http.Header{"Anthropic-Beta": {" , " + beta + ",effort-2025-11-24, " + beta, " effort-2025-11-24, ,mid-conversation-output-config-2026-07-01, "}}, want: []string{beta + ",effort-2025-11-24,mid-conversation-output-config-2026-07-01"}},
			{name: "empty comma values", headers: http.Header{"Anthropic-Beta": {", ,", " ,"}}},
			{name: "no implicit opt in"},
			{name: "request context", contextOnly: true, headers: http.Header{"Anthropic-Beta": {beta}}, want: []string{beta}},
			{name: "operator override", headers: http.Header{"Anthropic-Beta": {beta, "effort-2025-11-24"}}, override: "operator-beta", want: []string{"operator-beta"}},
		} {
			t.Run(mode+"/"+tc.name, func(t *testing.T) {
				auth, capture := newVertexClaudeTestEnv(t, func(w http.ResponseWriter, stream bool) {
					response := httptest.NewRecorder()
					vertexClaudeOKResponder(response, stream)
					w.Header().Set("Content-Type", response.Header().Get("Content-Type"))
					_, _ = w.Write([]byte(strings.ReplaceAll(response.Body.String(), "claude-sonnet-5-5", model)))
				})
				if tc.override != "" {
					auth.Attributes = map[string]string{"header:Anthropic-Beta": tc.override}
				}
				headers := tc.headers.Clone()
				if headers != nil {
					headers.Set("Authorization", "Bearer client-only")
					headers.Set("X-Api-Key", "client-only")
				}
				before := headers.Clone()
				ctx := context.Background()
				opts := cliproxyexecutor.Options{SourceFormat: sdktranslator.FormatClaude, Headers: headers}
				if tc.contextOnly {
					g, _ := gin.CreateTestContext(httptest.NewRecorder())
					g.Request = httptest.NewRequest(http.MethodPost, "/v1/messages", nil)
					g.Request.Header = headers
					ctx = context.WithValue(ctx, "gin", g)
					opts.Headers = nil
				}
				ex := NewGeminiVertexExecutor(&config.Config{VertexClaudeModels: []string{model}})
				req := cliproxyexecutor.Request{Model: model, Payload: []byte(payload)}
				if mode == "stream" {
					result, err := ex.ExecuteStream(ctx, auth, req, opts)
					if err != nil {
						t.Fatal(err)
					}
					if _, err = drainVertexClaudeStream(t, result); err != nil {
						t.Fatal(err)
					}
				} else if _, err := ex.Execute(ctx, auth, req, opts); err != nil {
					t.Fatal(err)
				}
				capture.mu.Lock()
				wireHeaders := capture.headers.Clone()
				capture.mu.Unlock()
				if got := wireHeaders.Values("Anthropic-Beta"); !reflect.DeepEqual(got, tc.want) {
					t.Fatalf("Anthropic-Beta = %q, want %q", got, tc.want)
				}
				if got := wireHeaders.Get("Authorization"); got != "Bearer sa-token" || wireHeaders.Get("X-Api-Key") != "" {
					t.Fatal("client credentials leaked onto the Vertex request")
				}
				if !reflect.DeepEqual(headers, before) {
					t.Fatal("incoming headers were mutated")
				}
				path, _, body := capture.get()
				if !strings.Contains(path, "/publishers/anthropic/models/"+model+":") {
					t.Fatalf("wrong model route: %s", path)
				}
				for _, field := range []string{"messages", "output_config", "tools"} {
					if !reflect.DeepEqual(ojson.GetBytes(body, field).Value(), ojson.GetBytes([]byte(payload), field).Value()) {
						t.Fatalf("%s was rewritten: %s", field, body)
					}
				}
			})
		}
	}
}
