package helps

import (
	"crypto/sha256"
	"encoding/hex"
	"sync"
	"time"

	"github.com/MoeForge/moego/ojson"
	"golang.org/x/sync/singleflight"
)

// vertexAccessTokenRefreshMargin is how long before expiry a cached token stops being reused,
// so a token is never sent to Vertex in the last moments of its lifetime.
const vertexAccessTokenRefreshMargin = 5 * time.Minute

type vertexAccessTokenEntry struct {
	token  string
	expiry time.Time
}

// VertexAccessTokenCache keeps service account access tokens until shortly before they expire.
// Only the token string and its expiry are stored, never an oauth2 token source: a token source
// captures the context and HTTP client (proxy) it was created with, so every miss runs the
// exchange with the requesting call's own client instead. Concurrent misses for one key share a
// single exchange, and failed exchanges are not cached.
type VertexAccessTokenCache struct {
	mu      sync.Mutex
	entries map[string]vertexAccessTokenEntry
	flight  singleflight.Group
	now     func() time.Time
}

// NewVertexAccessTokenCache returns an empty cache that reads time from time.Now.
func NewVertexAccessTokenCache() *VertexAccessTokenCache {
	return &VertexAccessTokenCache{
		entries: make(map[string]vertexAccessTokenEntry),
		now:     time.Now,
	}
}

// usable reports whether a token expiring at expiry may still be handed out.
func (c *VertexAccessTokenCache) usable(expiry time.Time, now time.Time) bool {
	return now.Before(expiry.Add(-vertexAccessTokenRefreshMargin))
}

func (c *VertexAccessTokenCache) lookup(key string) (string, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	entry, ok := c.entries[key]
	if !ok {
		return "", false
	}
	if !c.usable(entry.expiry, c.now()) {
		delete(c.entries, key)
		return "", false
	}
	return entry.token, true
}

// store caches a token. A token without an expiry, or one that would already be inside the
// refresh margin, is not worth keeping and is skipped.
func (c *VertexAccessTokenCache) store(key, token string, expiry time.Time) {
	now := c.now()
	if token == "" || expiry.IsZero() || !c.usable(expiry, now) {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	// Drop entries that can no longer be served, such as those left behind by a rotated key.
	for k, entry := range c.entries {
		if !c.usable(entry.expiry, now) {
			delete(c.entries, k)
		}
	}
	c.entries[key] = vertexAccessTokenEntry{token: token, expiry: expiry}
}

// Get returns the cached token for key, or calls fetch to obtain one. fetch must return the
// token together with the time it expires.
func (c *VertexAccessTokenCache) Get(key string, fetch func() (string, time.Time, error)) (string, error) {
	if token, ok := c.lookup(key); ok {
		return token, nil
	}
	result, err, _ := c.flight.Do(key, func() (any, error) {
		// Another caller may have stored a token between our miss and this flight starting.
		if token, ok := c.lookup(key); ok {
			return token, nil
		}
		token, expiry, errFetch := fetch()
		if errFetch != nil {
			return "", errFetch
		}
		c.store(key, token, expiry)
		return token, nil
	})
	if err != nil {
		return "", err
	}
	token, _ := result.(string)
	return token, nil
}

// VertexAccessTokenCacheKey identifies a service account credential for token reuse. The key is
// built from the credential's fields rather than from its serialized bytes, because the same
// credential can be marshaled with a different key order on every request. The private key is
// part of the key so a replaced key never reuses a token issued for the old one. Only a digest
// is returned, so the map never holds credential material.
func VertexAccessTokenCacheKey(saJSON []byte, scope string) string {
	h := sha256.New()
	for _, field := range []string{"client_email", "private_key_id", "token_uri", "private_key"} {
		_, _ = h.Write([]byte(ojson.GetBytesNoCopy(saJSON, field).String()))
		_, _ = h.Write([]byte{0})
	}
	_, _ = h.Write([]byte(scope))
	return hex.EncodeToString(h.Sum(nil))
}

var defaultVertexAccessTokenCache = NewVertexAccessTokenCache()

// CachedVertexAccessToken returns the process-wide cached token for a service account, calling
// fetch only when no usable token is cached.
func CachedVertexAccessToken(saJSON []byte, scope string, fetch func() (string, time.Time, error)) (string, error) {
	return defaultVertexAccessTokenCache.Get(VertexAccessTokenCacheKey(saJSON, scope), fetch)
}
