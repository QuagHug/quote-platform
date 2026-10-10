package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"log"
	"math/rand/v2" // nosemgrep: go.lang.security.audit.crypto.math_random.math-random-used -- picks a quote, not a secret
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// About 100ms of CPU on an Apple M1 core; override with QUOTE_WORK_ROUNDS.
const defaultWorkRounds = 1900000

var quotes = [][2]string{
	{"The best way out is always through.", "Robert Frost"},
	{"It always seems impossible until it's done.", "Nelson Mandela"},
	{"Well done is better than well said.", "Benjamin Franklin"},
	{"Act as if what you do makes a difference. It does.", "William James"},
	{"Quality is not an act, it is a habit.", "Will Durant"},
	{"Start where you are. Use what you have. Do what you can.", "Arthur Ashe"},
	{"Simplicity is prerequisite for reliability.", "Edsger W. Dijkstra"},
	{"Hope is not a strategy.", "Google SRE book"},
}

var (
	requests = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "quote_api_requests_total",
		Help: "HTTP requests handled, by route and status code.",
	}, []string{"route", "code"})
	latency = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "quote_api_request_duration_seconds",
		Help:    "Request latency by route.",
		Buckets: []float64{.05, .1, .15, .2, .3, .5, .75, 1, 1.5, 2, 3, 5},
	}, []string{"route"})
)

type statusRecorder struct {
	http.ResponseWriter
	code int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.code = code
	r.ResponseWriter.WriteHeader(code)
}

func instrument(route string, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, code: http.StatusOK}
		next(rec, r)
		requests.WithLabelValues(route, strconv.Itoa(rec.code)).Inc()
		latency.WithLabelValues(route).Observe(time.Since(start).Seconds())
	}
}

// burnCPU is the simulated work: a chain of SHA-256 hashes the compiler cannot skip.
func burnCPU(rounds int) [32]byte {
	sum := sha256.Sum256([]byte("quote"))
	for i := 0; i < rounds; i++ {
		sum = sha256.Sum256(sum[:])
	}
	return sum
}

func newMux(rounds int, ready *atomic.Bool) *http.ServeMux {
	pod, _ := os.Hostname()
	node := os.Getenv("NODE_NAME")
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", instrument("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Write([]byte("ok\n"))
	}))
	mux.HandleFunc("GET /readyz", instrument("/readyz", func(w http.ResponseWriter, _ *http.Request) {
		if !ready.Load() {
			http.Error(w, "shutting down", http.StatusServiceUnavailable)
			return
		}
		w.Write([]byte("ready\n"))
	}))
	mux.Handle("GET /metrics", promhttp.Handler())
	mux.HandleFunc("GET /api/quote", instrument("/api/quote", func(w http.ResponseWriter, _ *http.Request) {
		burnCPU(rounds)
		q := quotes[rand.IntN(len(quotes))]
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"quote": q[0], "author": q[1], "pod": pod, "node": node})
	}))
	return mux
}

func main() {
	rounds := defaultWorkRounds
	if v, err := strconv.Atoi(os.Getenv("QUOTE_WORK_ROUNDS")); err == nil && v >= 0 {
		rounds = v
	}
	addr := ":" + orDefault(os.Getenv("PORT"), "8080")

	var ready atomic.Bool
	srv := &http.Server{Handler: newMux(rounds, &ready), ReadHeaderTimeout: 5 * time.Second}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatal(err)
	}
	go func() {
		if err := srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatal(err)
		}
	}()
	ready.Store(true)
	log.Printf("quote-api listening on %s (%d hash rounds per quote)", addr, rounds)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()
	<-ctx.Done()

	// Fail readiness first so the Service and Traefik stop routing here, then drain.
	ready.Store(false)
	time.Sleep(5 * time.Second)
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Printf("shutdown: %v", err)
	}
}

func orDefault(v, fallback string) string {
	if v == "" {
		return fallback
	}
	return v
}
