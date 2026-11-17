package executor

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"

	log "github.com/sirupsen/logrus"
	logtest "github.com/sirupsen/logrus/hooks/test"
)

func warnEntries(hook *logtest.Hook) []*log.Entry {
	var out []*log.Entry
	for _, entry := range hook.AllEntries() {
		if entry.Level == log.WarnLevel && strings.Contains(entry.Message, "claude request rejected upstream") {
			out = append(out, entry)
		}
	}
	return out
}

func executeVertexClaudeWithStatus(t *testing.T, status int, body string) (*logtest.Hook, error) {
	t.Helper()
	hook := logtest.NewGlobal()
	t.Cleanup(hook.Reset)
	auth, _ := newVertexClaudeTestEnv(t, func(w http.ResponseWriter, _ bool) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = io.WriteString(w, body)
	})
	exec := vertexClaudeTestExecutor(nil)
	req, opts := vertexClaudeReq("claude-sonnet-5-5")
	opts.Headers = http.Header{"Anthropic-Beta": {"per-turn-control-2026-07-01,advisor-tool-2026-03-01"}}
	_, err := exec.Execute(context.Background(), auth, req, opts)
	return hook, err
}

func TestVertexClaudeLogsUpstreamClientErrorAtWarn(t *testing.T) {
	const upstream = "{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"Unexpected value(s) `cache-diagnosis-2026-04-07` for the `anthropic-beta` header.\"}}"
	hook, err := executeVertexClaudeWithStatus(t, http.StatusBadRequest, upstream)
	if err == nil {
		t.Fatal("expected an upstream error")
	}
	// The client still receives the upstream body untouched, so Claude Code can
	// recognize the rejected beta by name.
	if err.Error() != upstream {
		t.Fatalf("error body changed: %q", err.Error())
	}
	entries := warnEntries(hook)
	if len(entries) != 1 {
		t.Fatalf("warn entries = %d, want 1: %v", len(entries), hook.AllEntries())
	}
	msg := entries[0].Message
	for _, want := range []string{"status=400", "auth=vertex-sa", "cache-diagnosis-2026-04-07", "per-turn-control-2026-07-01"} {
		if !strings.Contains(msg, want) {
			t.Fatalf("log line missing %q: %s", want, msg)
		}
	}
	// The denylisted beta was dropped before sending, so the log shows what was on the wire.
	if strings.Contains(msg, "anthropic-beta=\"per-turn-control-2026-07-01,advisor-tool-2026-03-01\"") {
		t.Fatalf("log shows a header that was not sent: %s", msg)
	}
	if strings.Contains(msg, "sa-token") || strings.Contains(strings.ToLower(msg), "bearer") {
		t.Fatalf("log line leaks credentials: %s", msg)
	}
}

func TestVertexClaudeLogTruncatesLongUpstreamMessages(t *testing.T) {
	long := strings.Repeat("x", 5000)
	hook, _ := executeVertexClaudeWithStatus(t, http.StatusBadRequest, "{\"error\":{\"message\":\""+long+"\"}}")
	entries := warnEntries(hook)
	if len(entries) != 1 {
		t.Fatalf("warn entries = %d, want 1", len(entries))
	}
	if got := len(entries[0].Message); got > 1024 {
		t.Fatalf("log line is %d bytes, expected it to be bounded", got)
	}
	if !strings.HasSuffix(entries[0].Message, "...") {
		t.Fatalf("truncated line should end with an ellipsis: %s", entries[0].Message)
	}
}

func TestVertexClaudeDoesNotWarnOnRateLimitOrServerErrors(t *testing.T) {
	for _, status := range []int{http.StatusTooManyRequests, http.StatusInternalServerError, http.StatusServiceUnavailable} {
		hook, _ := executeVertexClaudeWithStatus(t, status, `{"error":"x"}`)
		if entries := warnEntries(hook); len(entries) != 0 {
			t.Fatalf("status %d produced a warn line: %s", status, entries[0].Message)
		}
	}
}

func TestTruncateVertexClaudeLogKeepsRunesIntact(t *testing.T) {
	in := strings.Repeat("錯", vertexClaudeErrorLogLimit+10)
	got := truncateVertexClaudeLog(in)
	if !strings.HasSuffix(got, "...") || len([]rune(got)) != vertexClaudeErrorLogLimit+3 {
		t.Fatalf("unexpected truncation: %d runes", len([]rune(got)))
	}
	if short := "短訊息"; truncateVertexClaudeLog(short) != short {
		t.Fatal("short messages must pass through unchanged")
	}
}
