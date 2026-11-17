package executor

import (
	"context"
	"net/http"
	"reflect"
	"strings"
	"testing"

	"github.com/MoeForge/moego/json"
	"github.com/MoeForge/moego/ojson"
	"github.com/router-for-me/CLIProxyAPI/v8/internal/config"
	cliproxyexecutor "github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/executor"
	sdktranslator "github.com/router-for-me/CLIProxyAPI/v8/sdk/translator"
)

// All fixtures are synthetic.
const vertexClaudeUnsupportedPayload = `{
  "model": "claude-sonnet-5-5",
  "max_tokens": 64,
  "thinking": {"type": "adaptive"},
  "output_config": {"effort": "medium"},
  "diagnostics": {"previous_message_id": "msg_prev"},
  "thread": {"id": "thr_1"},
  "system": [
    {"type": "text", "text": "billing", "cache_control": {"type": "ephemeral", "scope": "global", "ttl": "1h"}},
    {"type": "text", "text": "plain"}
  ],
  "tools": [
    {"name": "lookup", "description": "d", "input_schema": {"type": "object"}},
    {"type": "advisor_20260301", "name": "advisor", "model": "claude-opus-5-5"},
    {"name": "other", "description": "d", "input_schema": {"type": "object"}}
  ],
  "messages": [
    {"role": "user", "content": "hello"},
    {"role": "system", "content": [], "output_config": {"effort": "low"}}
  ]
}`

func runVertexClaudeModes(t *testing.T, fn func(t *testing.T, stream bool)) {
	t.Helper()
	for _, stream := range []bool{false, true} {
		name := "rawPredict"
		if stream {
			name = "streamRawPredict"
		}
		t.Run(name, func(t *testing.T) { fn(t, stream) })
	}
}

func TestVertexClaudeBetaHeaderDropsUnsupportedBetas(t *testing.T) {
	const keep1 = "per-turn-control-2026-07-01"
	const keep2 = "effort-2025-11-24"
	for _, tc := range []struct {
		name    string
		headers http.Header
		want    string
	}{
		{
			name:    "mixed values keep order on one line",
			headers: http.Header{"Anthropic-Beta": {keep1 + ",advisor-tool-2026-03-01", "cache-diagnosis-2026-04-07, " + keep2 + " ,message-threads-2026-08-12"}},
			want:    keep1 + "," + keep2,
		},
		{
			name:    "only unsupported values",
			headers: http.Header{"Anthropic-Beta": {"advisor-tool-2026-03-01,cache-diagnosis-2026-04-07", "message-threads-2026-08-12"}},
			want:    "",
		},
		{
			name:    "case-insensitive match",
			headers: http.Header{"anthropic-beta": {"Advisor-Tool-2026-03-01", keep1}},
			want:    keep1,
		},
		{
			name:    "supported betas untouched",
			headers: http.Header{"Anthropic-Beta": {keep1 + "," + keep2 + ",context-management-2025-06-27"}},
			want:    keep1 + "," + keep2 + ",context-management-2025-06-27",
		},
		{
			name:    "similar but different beta is kept",
			headers: http.Header{"Anthropic-Beta": {"advisor-tool-2026-03-02"}},
			want:    "advisor-tool-2026-03-02",
		},
		{name: "no header"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := vertexClaudeBetaHeader(tc.headers); got != tc.want {
				t.Fatalf("vertexClaudeBetaHeader = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestVertexClaudeWireBetaHeaderFiltersUnsupportedBetas(t *testing.T) {
	const keep = "per-turn-control-2026-07-01"
	for _, tc := range []struct {
		name     string
		header   []string
		override string
		want     []string
	}{
		{name: "mixed", header: []string{keep + ",advisor-tool-2026-03-01", "cache-diagnosis-2026-04-07,message-threads-2026-08-12"}, want: []string{keep}},
		{name: "only unsupported sends no header", header: []string{"advisor-tool-2026-03-01,cache-diagnosis-2026-04-07,message-threads-2026-08-12"}},
		// An operator override is the escape hatch for when Vertex adds support.
		{name: "operator override passes unsupported value", header: []string{keep}, override: "advisor-tool-2026-03-01", want: []string{"advisor-tool-2026-03-01"}},
	} {
		runVertexClaudeModes(t, func(t *testing.T, stream bool) {
			t.Run(tc.name, func(t *testing.T) {
				auth, capture := newVertexClaudeTestEnv(t, vertexClaudeOKResponder)
				if tc.override != "" {
					auth.Attributes = map[string]string{"header:Anthropic-Beta": tc.override}
				}
				exec := vertexClaudeTestExecutor(nil)
				req, opts := vertexClaudeReq("claude-sonnet-5-5")
				opts.Headers = http.Header{"Anthropic-Beta": tc.header}
				if stream {
					result, err := exec.ExecuteStream(context.Background(), auth, req, opts)
					if err != nil {
						t.Fatal(err)
					}
					if _, err = drainVertexClaudeStream(t, result); err != nil {
						t.Fatal(err)
					}
				} else if _, err := exec.Execute(context.Background(), auth, req, opts); err != nil {
					t.Fatal(err)
				}
				capture.mu.Lock()
				got := capture.headers.Values("Anthropic-Beta")
				capture.mu.Unlock()
				if !reflect.DeepEqual(got, tc.want) {
					t.Fatalf("Anthropic-Beta = %q, want %q", got, tc.want)
				}
			})
		})
	}
}

func TestVertexClaudeStripsUnsupportedBodyFields(t *testing.T) {
	runVertexClaudeModes(t, func(t *testing.T, stream bool) {
		auth, capture := newVertexClaudeTestEnv(t, vertexClaudeOKResponder)
		exec := vertexClaudeTestExecutor(nil)
		req := cliproxyexecutor.Request{Model: "claude-sonnet-5-5", Payload: []byte(vertexClaudeUnsupportedPayload)}
		opts := cliproxyexecutor.Options{SourceFormat: sdktranslator.FormatClaude}
		if stream {
			result, err := exec.ExecuteStream(context.Background(), auth, req, opts)
			if err != nil {
				t.Fatal(err)
			}
			if _, err = drainVertexClaudeStream(t, result); err != nil {
				t.Fatal(err)
			}
		} else if _, err := exec.Execute(context.Background(), auth, req, opts); err != nil {
			t.Fatal(err)
		}
		_, _, body := capture.get()

		for _, path := range []string{"diagnostics", "thread", "system.0.cache_control.scope"} {
			if ojson.GetBytes(body, path).Exists() {
				t.Fatalf("%s reached Vertex: %s", path, body)
			}
		}
		if got := ojson.GetBytes(body, "system.0.cache_control.type").String(); got != "ephemeral" {
			t.Fatalf("cache_control.type = %q: %s", got, body)
		}
		if got := ojson.GetBytes(body, "system.0.cache_control.ttl").String(); got != "1h" {
			t.Fatalf("cache_control.ttl = %q: %s", got, body)
		}
		tools := ojson.GetBytes(body, "tools").Array()
		if len(tools) != 2 || tools[0].Get("name").String() != "lookup" || tools[1].Get("name").String() != "other" {
			t.Fatalf("tools = %s", ojson.GetBytes(body, "tools").Raw)
		}
		// The per-message effort directive is what issue #2 needs Vertex to keep.
		src := []byte(vertexClaudeUnsupportedPayload)
		for _, field := range []string{"messages", "output_config", "thinking", "system.1"} {
			if !reflect.DeepEqual(ojson.GetBytes(body, field).Value(), ojson.GetBytes(src, field).Value()) {
				t.Fatalf("%s was rewritten: %s", field, body)
			}
		}
	})
}

func TestVertexClaudePayloadRulesRunAfterUnsupportedFieldStrip(t *testing.T) {
	runVertexClaudeModes(t, func(t *testing.T, stream bool) {
		auth, capture := newVertexClaudeTestEnv(t, vertexClaudeOKResponder)
		models := []config.PayloadModelRule{{Name: "claude-sonnet-5-5", Protocol: "claude"}}
		// An operator who knows better must still be able to put these back.
		cfg := &config.Config{Payload: config.PayloadConfig{Override: []config.PayloadRule{{
			Models: models,
			Params: map[string]any{"thread.id": "thr_operator", "diagnostics.previous_message_id": "msg_operator"},
		}}}}
		exec := vertexClaudeTestExecutor(cfg)
		req := cliproxyexecutor.Request{Model: "claude-sonnet-5-5", Payload: []byte(vertexClaudeUnsupportedPayload)}
		opts := cliproxyexecutor.Options{SourceFormat: sdktranslator.FormatClaude}
		if stream {
			result, err := exec.ExecuteStream(context.Background(), auth, req, opts)
			if err != nil {
				t.Fatal(err)
			}
			if _, err = drainVertexClaudeStream(t, result); err != nil {
				t.Fatal(err)
			}
		} else if _, err := exec.Execute(context.Background(), auth, req, opts); err != nil {
			t.Fatal(err)
		}
		_, _, body := capture.get()
		if got := ojson.GetBytes(body, "thread.id").String(); got != "thr_operator" {
			t.Fatalf("payload rule for thread was overwritten: %s", body)
		}
		if got := ojson.GetBytes(body, "diagnostics.previous_message_id").String(); got != "msg_operator" {
			t.Fatalf("payload rule for diagnostics was overwritten: %s", body)
		}
	})
}

// The forced tool_choice check drops thinking and effort. It must see the request
// after the advisor tool and any tool_choice naming it are gone, otherwise a
// request that no longer forces tool use still loses its thinking settings.
func TestVertexClaudeKeepsThinkingWhenForcedAdvisorChoiceIsRemoved(t *testing.T) {
	const advisor = `{"type":"advisor_20260301","name":"advisor","model":"claude-opus-5-5"}`
	const lookup = `{"name":"lookup","description":"d","input_schema":{"type":"object"}}`
	for _, tc := range []struct {
		name         string
		tools        string
		toolChoice   string
		wantChoice   bool
		wantThinking bool
	}{
		{name: "forced advisor next to another tool", tools: `[` + lookup + `,` + advisor + `]`, toolChoice: `{"type":"tool","name":"advisor"}`, wantThinking: true},
		{name: "any with only advisor tools", tools: `[` + advisor + `]`, toolChoice: `{"type":"any"}`, wantThinking: true},
		// Unchanged behavior: a forced choice that survives still disables thinking.
		{name: "forced surviving tool", tools: `[` + lookup + `,` + advisor + `]`, toolChoice: `{"type":"tool","name":"lookup"}`, wantChoice: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			runVertexClaudeModes(t, func(t *testing.T, stream bool) {
				auth, capture := newVertexClaudeTestEnv(t, vertexClaudeOKResponder)
				exec := vertexClaudeTestExecutor(nil)
				payload := `{"model":"claude-sonnet-5-5","max_tokens":4096,"thinking":{"type":"enabled","budget_tokens":2048},"output_config":{"effort":"medium"},"tools":` + tc.tools + `,"tool_choice":` + tc.toolChoice + `,"messages":[{"role":"user","content":"hi"}]}`
				req := cliproxyexecutor.Request{Model: "claude-sonnet-5-5", Payload: []byte(payload)}
				opts := cliproxyexecutor.Options{SourceFormat: sdktranslator.FormatClaude}
				if stream {
					result, err := exec.ExecuteStream(context.Background(), auth, req, opts)
					if err != nil {
						t.Fatal(err)
					}
					if _, err = drainVertexClaudeStream(t, result); err != nil {
						t.Fatal(err)
					}
				} else if _, err := exec.Execute(context.Background(), auth, req, opts); err != nil {
					t.Fatal(err)
				}
				_, _, body := capture.get()
				if got := ojson.GetBytes(body, "tool_choice").Exists(); got != tc.wantChoice {
					t.Fatalf("tool_choice present = %v, want %v: %s", got, tc.wantChoice, body)
				}
				if got := ojson.GetBytes(body, "thinking").Exists(); got != tc.wantThinking {
					t.Fatalf("thinking present = %v, want %v: %s", got, tc.wantThinking, body)
				}
				if got := ojson.GetBytes(body, "output_config.effort").Exists(); got != tc.wantThinking {
					t.Fatalf("output_config.effort present = %v, want %v: %s", got, tc.wantThinking, body)
				}
				for _, tool := range ojson.GetBytes(body, "tools").Array() {
					if strings.HasPrefix(tool.Get("type").String(), "advisor_") {
						t.Fatalf("advisor tool reached Vertex: %s", body)
					}
				}
			})
		})
	}
}

func TestStripVertexClaudeUnsupportedFields(t *testing.T) {
	for _, tc := range []struct {
		name string
		in   string
		want string
	}{
		{
			name: "system as a string is untouched",
			in:   `{"system":"plain","messages":[]}`,
			want: `{"system":"plain","messages":[]}`,
		},
		{
			name: "scope removed only where present",
			in:   `{"system":[{"type":"text","text":"a","cache_control":{"type":"ephemeral","scope":"global"}},{"type":"text","text":"b","cache_control":{"type":"ephemeral","ttl":"5m"}},{"type":"text","text":"c"}]}`,
			want: `{"system":[{"type":"text","text":"a","cache_control":{"type":"ephemeral"}},{"type":"text","text":"b","cache_control":{"type":"ephemeral","ttl":"5m"}},{"type":"text","text":"c"}]}`,
		},
		{
			name: "scope removed from tools, messages and the top level too",
			in:   `{"cache_control":{"type":"ephemeral","scope":"global"},"tools":[{"name":"a","input_schema":{},"cache_control":{"type":"ephemeral","scope":"global","ttl":"1h"}}],"messages":[{"role":"user","content":[{"type":"text","text":"x","cache_control":{"type":"ephemeral","scope":"org"}},{"type":"text","text":"y"}]},{"role":"assistant","content":"plain string"}]}`,
			want: `{"cache_control":{"type":"ephemeral"},"tools":[{"name":"a","input_schema":{},"cache_control":{"type":"ephemeral","ttl":"1h"}}],"messages":[{"role":"user","content":[{"type":"text","text":"x","cache_control":{"type":"ephemeral"}},{"type":"text","text":"y"}]},{"role":"assistant","content":"plain string"}]}`,
		},
		{
			name: "a message text that merely contains the word scope is untouched",
			in:   `{"messages":[{"role":"user","content":[{"type":"text","text":"the \"scope\" of work","cache_control":{"type":"ephemeral"}}]}]}`,
			want: `{"messages":[{"role":"user","content":[{"type":"text","text":"the \"scope\" of work","cache_control":{"type":"ephemeral"}}]}]}`,
		},
		{
			name: "all tools are advisors: tools and tool_choice removed",
			in:   `{"tools":[{"type":"advisor_20260301","name":"advisor"}],"tool_choice":{"type":"auto"},"messages":[]}`,
			want: `{"messages":[]}`,
		},
		{
			name: "forced advisor tool_choice removed, other tools kept",
			in:   `{"tools":[{"name":"lookup","input_schema":{}},{"type":"advisor_20260301","name":"advisor"}],"tool_choice":{"type":"tool","name":"advisor"}}`,
			want: `{"tools":[{"name":"lookup","input_schema":{}}]}`,
		},
		{
			name: "tool_choice for another tool is kept",
			in:   `{"tools":[{"name":"lookup","input_schema":{}},{"type":"advisor_20260301","name":"advisor"}],"tool_choice":{"type":"tool","name":"lookup"}}`,
			want: `{"tools":[{"name":"lookup","input_schema":{}}],"tool_choice":{"type":"tool","name":"lookup"}}`,
		},
		{
			name: "tool_choice auto is kept while other tools remain",
			in:   `{"tools":[{"type":"advisor_20260301","name":"advisor"},{"name":"lookup","input_schema":{}}],"tool_choice":{"type":"auto"}}`,
			want: `{"tools":[{"name":"lookup","input_schema":{}}],"tool_choice":{"type":"auto"}}`,
		},
		{
			name: "adjacent advisor tools are all removed",
			in:   `{"tools":[{"type":"advisor_20260301","name":"advisor"},{"type":"advisor_20260401","name":"advisor2"},{"name":"lookup","input_schema":{}}]}`,
			want: `{"tools":[{"name":"lookup","input_schema":{}}]}`,
		},
		{
			name: "a custom tool that merely mentions advisor stays",
			in:   `{"tools":[{"name":"advisor","description":"mine","input_schema":{}}]}`,
			want: `{"tools":[{"name":"advisor","description":"mine","input_schema":{}}]}`,
		},
		{
			name: "advisor history in messages is left alone",
			in:   `{"messages":[{"role":"assistant","content":[{"type":"server_tool_use","id":"srvtoolu_1","name":"advisor","input":{}},{"type":"advisor_tool_result","tool_use_id":"srvtoolu_1","content":{"type":"advisor_result","text":"x"}}]}]}`,
			want: `{"messages":[{"role":"assistant","content":[{"type":"server_tool_use","id":"srvtoolu_1","name":"advisor","input":{}},{"type":"advisor_tool_result","tool_use_id":"srvtoolu_1","content":{"type":"advisor_result","text":"x"}}]}]}`,
		},
		{
			name: "diagnostics and thread removed",
			in:   `{"diagnostics":{"previous_message_id":"m"},"thread":{"id":"t"},"max_tokens":1}`,
			want: `{"max_tokens":1}`,
		},
		{
			name: "nothing to strip",
			in:   `{"max_tokens":1,"messages":[{"role":"user","content":"hi"}]}`,
			want: `{"max_tokens":1,"messages":[{"role":"user","content":"hi"}]}`,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			doc := ojson.NewDocString(tc.in)
			stripVertexClaudeUnsupportedFields(doc)
			var got, want any
			if err := json.Unmarshal(doc.Bytes(), &got); err != nil {
				t.Fatalf("result is not valid JSON: %v: %s", err, doc.String())
			}
			if err := json.Unmarshal([]byte(tc.want), &want); err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("got  %s\nwant %s", doc.String(), tc.want)
			}
		})
	}
}
