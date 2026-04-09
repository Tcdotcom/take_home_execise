package main

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"os"
	"time"
)

// response is the standard JSON envelope for all API responses.
type response struct {
	Status  string `json:"status"`
	Message string `json:"message,omitempty"`
	Time    string `json:"time"`
}

func main() {
	// Structured JSON logger — writes to stdout so the container runtime
	// (and ultimately Kubernetes + Fluentd/Fluent-bit) can capture it.
	logLevel := slog.LevelInfo
	if os.Getenv("LOG_LEVEL") == "debug" {
		logLevel = slog.LevelDebug
	}
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: logLevel}))
	slog.SetDefault(logger)

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	mux := http.NewServeMux()

	// Root handler — returns a simple greeting to prove the service is running.
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		slog.Info("request received", "path", r.URL.Path, "method", r.Method, "remote", r.RemoteAddr)
		writeJSON(w, http.StatusOK, response{
			Status:  "ok",
			Message: "Golden-path demo service",
			Time:    time.Now().UTC().Format(time.RFC3339),
		})
	})

	// Liveness probe — Kubernetes uses this to decide whether to restart the pod.
	// A 200 means the process is alive; anything else triggers a restart.
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, response{
			Status: "healthy",
			Time:   time.Now().UTC().Format(time.RFC3339),
		})
	})

	// Readiness probe — Kubernetes uses this to decide whether to send traffic.
	// In a real service you would check downstream dependencies here (DB, cache, etc.).
	mux.HandleFunc("/ready", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, response{
			Status: "ready",
			Time:   time.Now().UTC().Format(time.RFC3339),
		})
	})

	server := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       120 * time.Second,
	}

	slog.Info("starting server", "port", port)
	if err := server.ListenAndServe(); err != nil {
		slog.Error("server failed", "error", err)
		os.Exit(1)
	}
}

// writeJSON serialises v as JSON and writes it to the response.
func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		slog.Error("failed to encode response", "error", err)
	}
}
