package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

func get(t *testing.T, h http.Handler, path string) *http.Response {
	t.Helper()
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
	return rec.Result()
}

func TestHealthz(t *testing.T) {
	var ready atomic.Bool
	if code := get(t, newMux(1, &ready), "/healthz").StatusCode; code != http.StatusOK {
		t.Fatalf("healthz = %d, want 200", code)
	}
}

func TestReadyzFollowsReadyFlag(t *testing.T) {
	var ready atomic.Bool
	mux := newMux(1, &ready)
	if code := get(t, mux, "/readyz").StatusCode; code != http.StatusServiceUnavailable {
		t.Fatalf("readyz before ready = %d, want 503", code)
	}
	ready.Store(true)
	if code := get(t, mux, "/readyz").StatusCode; code != http.StatusOK {
		t.Fatalf("readyz when ready = %d, want 200", code)
	}
}

func TestQuoteReturnsJSON(t *testing.T) {
	var ready atomic.Bool
	res := get(t, newMux(10, &ready), "/api/quote")
	if res.StatusCode != http.StatusOK {
		t.Fatalf("status = %d", res.StatusCode)
	}
	if ct := res.Header.Get("Content-Type"); ct != "application/json" {
		t.Fatalf("content-type = %q", ct)
	}
	var body map[string]string
	if err := json.NewDecoder(res.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	if body["quote"] == "" || body["author"] == "" {
		t.Fatalf("missing quote or author: %v", body)
	}
}

func TestMetricsCountQuotes(t *testing.T) {
	var ready atomic.Bool
	mux := newMux(1, &ready)
	get(t, mux, "/api/quote")
	b, _ := io.ReadAll(get(t, mux, "/metrics").Body)
	want := `quote_api_requests_total{code="200",route="/api/quote"}`
	if !strings.Contains(string(b), want) {
		t.Fatalf("metrics missing %s", want)
	}
}

func TestUnknownMethodRejected(t *testing.T) {
	var ready atomic.Bool
	rec := httptest.NewRecorder()
	newMux(1, &ready).ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/api/quote", nil))
	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("POST /api/quote = %d, want 405", rec.Code)
	}
}

func BenchmarkBurnCPU(b *testing.B) {
	for i := 0; i < b.N; i++ {
		burnCPU(defaultWorkRounds)
	}
}
