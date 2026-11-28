package helps

import (
	"errors"
	"runtime"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// fakeClock lets a test move time without sleeping.
type fakeClock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *fakeClock) Advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.t = c.t.Add(d)
}

func newTestVertexTokenCache() (*VertexAccessTokenCache, *fakeClock) {
	clock := &fakeClock{t: time.Date(2026, 11, 19, 8, 0, 0, 0, time.UTC)}
	cache := NewVertexAccessTokenCache()
	cache.now = clock.Now
	return cache, clock
}

// countingFetch returns a fetch func that counts calls and issues tokens expiring ttl after the clock.
func countingFetch(clock *fakeClock, ttl time.Duration, calls *atomic.Int32) func() (string, time.Time, error) {
	return func() (string, time.Time, error) {
		n := calls.Add(1)
		return "token-" + string(rune('0'+n)), clock.Now().Add(ttl), nil
	}
}

func TestVertexAccessTokenCacheReusesToken(t *testing.T) {
	cache, clock := newTestVertexTokenCache()
	var calls atomic.Int32
	fetch := countingFetch(clock, time.Hour, &calls)

	for i := range 3 {
		token, err := cache.Get("k", fetch)
		if err != nil {
			t.Fatalf("Get #%d: %v", i, err)
		}
		if token != "token-1" {
			t.Fatalf("Get #%d token = %q, want token-1", i, token)
		}
	}
	if got := calls.Load(); got != 1 {
		t.Fatalf("fetch calls = %d, want 1", got)
	}
}

func TestVertexAccessTokenCacheRefreshesInsideMargin(t *testing.T) {
	cache, clock := newTestVertexTokenCache()
	var calls atomic.Int32
	fetch := countingFetch(clock, time.Hour, &calls)

	if _, err := cache.Get("k", fetch); err != nil {
		t.Fatalf("first Get: %v", err)
	}
	// One second before the margin starts, the token is still served.
	clock.Advance(time.Hour - vertexAccessTokenRefreshMargin - time.Second)
	if token, _ := cache.Get("k", fetch); token != "token-1" {
		t.Fatalf("token before margin = %q, want token-1", token)
	}
	if got := calls.Load(); got != 1 {
		t.Fatalf("fetch calls before margin = %d, want 1", got)
	}
	// At the margin the token is no longer handed out.
	clock.Advance(time.Second)
	if token, _ := cache.Get("k", fetch); token != "token-2" {
		t.Fatalf("token at margin = %q, want token-2", token)
	}
	if got := calls.Load(); got != 2 {
		t.Fatalf("fetch calls at margin = %d, want 2", got)
	}
}

func TestVertexAccessTokenCacheSkipsTokensWorthNotKeeping(t *testing.T) {
	tests := []struct {
		name  string
		token string
		ttl   time.Duration
		zero  bool
	}{
		{name: "no expiry", token: "tok", zero: true},
		{name: "expiry inside margin", token: "tok", ttl: vertexAccessTokenRefreshMargin - time.Second},
		{name: "expiry exactly at margin", token: "tok", ttl: vertexAccessTokenRefreshMargin},
		{name: "empty token", token: "", ttl: time.Hour},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cache, clock := newTestVertexTokenCache()
			var calls atomic.Int32
			fetch := func() (string, time.Time, error) {
				calls.Add(1)
				if tt.zero {
					return tt.token, time.Time{}, nil
				}
				return tt.token, clock.Now().Add(tt.ttl), nil
			}
			for range 2 {
				if _, err := cache.Get("k", fetch); err != nil {
					t.Fatalf("Get: %v", err)
				}
			}
			if got := calls.Load(); got != 2 {
				t.Fatalf("fetch calls = %d, want 2 (token must not be cached)", got)
			}
		})
	}
}

func TestVertexAccessTokenCacheDoesNotCacheFailures(t *testing.T) {
	cache, clock := newTestVertexTokenCache()
	var calls atomic.Int32
	errExchange := errors.New("exchange failed")
	fetch := func() (string, time.Time, error) {
		if calls.Add(1) == 1 {
			return "", time.Time{}, errExchange
		}
		return "good", clock.Now().Add(time.Hour), nil
	}

	if _, err := cache.Get("k", fetch); !errors.Is(err, errExchange) {
		t.Fatalf("first Get error = %v, want %v", err, errExchange)
	}
	token, err := cache.Get("k", fetch)
	if err != nil || token != "good" {
		t.Fatalf("second Get = %q, %v; want good, nil", token, err)
	}
	if _, err = cache.Get("k", fetch); err != nil {
		t.Fatalf("third Get: %v", err)
	}
	if got := calls.Load(); got != 2 {
		t.Fatalf("fetch calls = %d, want 2", got)
	}
}

func TestVertexAccessTokenCacheKeepsKeysSeparate(t *testing.T) {
	cache, clock := newTestVertexTokenCache()
	var calls atomic.Int32
	fetch := countingFetch(clock, time.Hour, &calls)

	first, _ := cache.Get("a", fetch)
	second, _ := cache.Get("b", fetch)
	if first == second {
		t.Fatalf("different keys shared token %q", first)
	}
	if got := calls.Load(); got != 2 {
		t.Fatalf("fetch calls = %d, want 2", got)
	}
}

func TestVertexAccessTokenCachePrunesUnusableEntries(t *testing.T) {
	cache, clock := newTestVertexTokenCache()
	var calls atomic.Int32
	fetch := countingFetch(clock, time.Hour, &calls)

	if _, err := cache.Get("old", fetch); err != nil {
		t.Fatalf("Get old: %v", err)
	}
	clock.Advance(2 * time.Hour)
	if _, err := cache.Get("new", fetch); err != nil {
		t.Fatalf("Get new: %v", err)
	}
	cache.mu.Lock()
	defer cache.mu.Unlock()
	if len(cache.entries) != 1 {
		t.Fatalf("entries = %d, want 1 after the old entry became unusable", len(cache.entries))
	}
	if _, ok := cache.entries["new"]; !ok {
		t.Fatal("new entry missing")
	}
}

func TestVertexAccessTokenCacheSharesConcurrentExchange(t *testing.T) {
	cache, clock := newTestVertexTokenCache()
	const callers = 16
	var fetches atomic.Int32
	started := make(chan struct{})
	release := make(chan struct{})
	fetch := func() (string, time.Time, error) {
		if fetches.Add(1) == 1 {
			close(started)
		}
		<-release
		return "shared", clock.Now().Add(time.Hour), nil
	}

	var ready, done sync.WaitGroup
	tokens := make([]string, callers)
	for i := range callers {
		ready.Add(1)
		done.Go(func() {
			ready.Done()
			token, err := cache.Get("k", fetch)
			if err != nil {
				t.Errorf("caller %d: %v", i, err)
			}
			tokens[i] = token
		})
	}
	ready.Wait()
	<-started
	// Give the other callers a chance to reach the in-flight exchange before it completes. The
	// assertion below does not depend on this: a late caller finds the stored token instead.
	for range 100 {
		runtime.Gosched()
	}
	close(release)
	done.Wait()

	if got := fetches.Load(); got != 1 {
		t.Fatalf("fetch calls = %d, want 1", got)
	}
	for i, token := range tokens {
		if token != "shared" {
			t.Fatalf("caller %d token = %q, want shared", i, token)
		}
	}
}

func TestVertexAccessTokenCacheKey(t *testing.T) {
	const scope = "https://www.googleapis.com/auth/cloud-platform"
	base := []byte(`{"client_email":"sa@p.iam","private_key_id":"kid","token_uri":"https://t/token","private_key":"KEY-A","project_id":"p"}`)
	baseKey := VertexAccessTokenCacheKey(base, scope)

	t.Run("field order does not matter", func(t *testing.T) {
		reordered := []byte(`{"private_key":"KEY-A","project_id":"p","token_uri":"https://t/token","private_key_id":"kid","client_email":"sa@p.iam"}`)
		if got := VertexAccessTokenCacheKey(reordered, scope); got != baseKey {
			t.Fatalf("reordered credential produced a different key")
		}
	})
	t.Run("unrelated fields do not matter", func(t *testing.T) {
		other := []byte(`{"client_email":"sa@p.iam","private_key_id":"kid","token_uri":"https://t/token","private_key":"KEY-A","project_id":"other"}`)
		if got := VertexAccessTokenCacheKey(other, scope); got != baseKey {
			t.Fatalf("project_id changed the key")
		}
	})
	for name, changed := range map[string][]byte{
		"replaced private key":  []byte(`{"client_email":"sa@p.iam","private_key_id":"kid","token_uri":"https://t/token","private_key":"KEY-B"}`),
		"different private id":  []byte(`{"client_email":"sa@p.iam","private_key_id":"kid2","token_uri":"https://t/token","private_key":"KEY-A"}`),
		"different client mail": []byte(`{"client_email":"other@p.iam","private_key_id":"kid","token_uri":"https://t/token","private_key":"KEY-A"}`),
		"different token uri":   []byte(`{"client_email":"sa@p.iam","private_key_id":"kid","token_uri":"https://t2/token","private_key":"KEY-A"}`),
	} {
		t.Run(name, func(t *testing.T) {
			if got := VertexAccessTokenCacheKey(changed, scope); got == baseKey {
				t.Fatalf("%s reused the same key", name)
			}
		})
	}
	t.Run("different scope", func(t *testing.T) {
		if got := VertexAccessTokenCacheKey(base, scope+"/other"); got == baseKey {
			t.Fatal("scope did not change the key")
		}
	})
	t.Run("key holds no credential material", func(t *testing.T) {
		if len(baseKey) != 64 {
			t.Fatalf("key length = %d, want a 64 character digest", len(baseKey))
		}
	})
}
