package main

import (
	"context"
	"crypto/tls"
	"embed"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

//go:embed static
var staticFiles embed.FS

var sockPath string

func main() {
	bind    := flag.String("bind",     "0.0.0.0",              "bind address")
	port    := flag.Int("port",        8443,                    "HTTPS port")
	sock    := flag.String("sock",     "/tmp/zerobridge.sock",  "pi-agent Unix socket")
	dataDir := flag.String("data",     "/etc/zerobridge",       "persistent data directory")
	certFile := flag.String("cert",    "/etc/zerobridge/tls/server.crt", "TLS certificate")
	keyFile  := flag.String("key",     "/etc/zerobridge/tls/server.key", "TLS key")
	rpid    := flag.String("rpid",     "zerobridge.local",      "WebAuthn RP ID")
	origin  := flag.String("origin",   "",                      "WebAuthn origin (default: https://<rpid>:<port>)")
	noTLS   := flag.Bool("no-tls",    false,                   "disable TLS (dev only)")
	flag.Parse()

	sockPath = *sock

	if *origin == "" {
		scheme := "https"
		if *noTLS { scheme = "http" }
		*origin = fmt.Sprintf("%s://%s:%d", scheme, *rpid, *port)
	}

	store, err := NewStore(*dataDir)
	if err != nil {
		log.Fatalf("[main] store init: %v", err)
	}

	wa, err := newWebAuthn(*rpid, *origin)
	if err != nil {
		log.Fatalf("[main] webauthn init: %v", err)
	}

	if err := initPush(store); err != nil {
		log.Fatalf("[main] push init: %v", err)
	}
	startMacStatePoller(*sock)

	mux := http.NewServeMux()

	// ── Public ─────────────────────────────────────────────────────────────
	mux.HandleFunc("/", handleStatic)
	mux.HandleFunc("/health", handleHealth)

	// CA certificate download (so iPhone can install it)
	caPath := fmt.Sprintf("%s/tls/ca.crt", *dataDir)
	mux.HandleFunc("/ca.crt", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/x-x509-ca-cert")
		http.ServeFile(w, r, caPath)
	})

	// Apple App Site Association (for Associated Domains / Passkeys)
	mux.HandleFunc("/.well-known/apple-app-site-association", handleAASA)

	// WebAuthn registration (code-gated)
	mux.HandleFunc("/api/register/begin",  handleRegisterBegin(wa, store))
	mux.HandleFunc("/api/register/finish", handleRegisterFinish(wa, store))

	// WebAuthn authentication → JWT
	mux.HandleFunc("/api/auth/begin",  handleAuthBegin(wa, store))
	mux.HandleFunc("/api/auth/finish", handleAuthFinish(wa, store))

	// Credential metadata (public — client needs mode before auth)
	mux.HandleFunc("/api/credential/mode", handleGetMode(store))

	// ── JWT protected ───────────────────────────────────────────────────────
	mux.HandleFunc("/api/credential/blob", func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost {
			handleSaveBlob(store)(w, r)
		} else {
			handleGetBlob(store)(w, r)
		}
	})
	mux.HandleFunc("/api/credential/key",  handleGetSplitKey(store))
	mux.HandleFunc("/api/unlock",          handleUnlock(store, sockPath))
	mux.HandleFunc("/ws",                  requireAuth(store, handleWS))

	// ── Push notifications ──────────────────────────────────────────────────
	mux.HandleFunc("/api/push/vapid-key",  handleVAPIDKey)
	mux.HandleFunc("/api/push/subscribe",  handlePushSubscribe(store))

	// ── Admin — localhost only ──────────────────────────────────────────────
	mux.HandleFunc("/admin/setup-code",  localhostOnly(handleGenerateSetupCode(store)))
	mux.HandleFunc("/admin/test-push",   localhostOnly(handleTestPush))

	addr := fmt.Sprintf("%s:%d", *bind, *port)

	tlsCfg := &tls.Config{
		MinVersion: tls.VersionTLS13,
	}

	srv := &http.Server{
		Addr:         addr,
		Handler:      mux,
		TLSConfig:    tlsCfg,
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 0, // disabled — WS connections are long-lived
		IdleTimeout:  120 * time.Second,
	}

	if *noTLS {
		log.Printf("[go-server] DEV MODE — listening on http://%s  sock=%s", addr, sockPath)
		go func() {
			if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
				log.Fatalf("[go-server] listen: %v", err)
			}
		}()
	} else {
		log.Printf("[go-server] listening on https://%s  sock=%s  rpid=%s", addr, sockPath, *rpid)
		go func() {
			if err := srv.ListenAndServeTLS(*certFile, *keyFile); err != nil && err != http.ErrServerClosed {
				log.Fatalf("[go-server] listen: %v", err)
			}
		}()
	}

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	log.Println("[go-server] shutting down...")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	srv.Shutdown(ctx)
	log.Println("[go-server] stopped")
}

// ── Handlers ─────────────────────────────────────────────────────────────────

func handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]bool{"ok": true})
}

func handleStatic(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path
	if path == "/" {
		path = "/index.html"
	}
	data, err := staticFiles.ReadFile("static" + path)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	ct := contentType(path)
	w.Header().Set("Content-Type", ct)
	// PWA assets — cache manifest/sw with no-cache so updates land immediately
	if path == "/manifest.json" || path == "/sw.js" {
		w.Header().Set("Cache-Control", "no-cache")
	}
	w.Write(data)
}

func handleAASA(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	// ZSNGYUZM66 is the Team ID; update bundle ID here if it changes
	json.NewEncoder(w).Encode(map[string]interface{}{
		"webcredentials": map[string]interface{}{
			"apps": []string{"ZSNGYUZM66.com.vasugarg.zerobridge"},
		},
		"applinks": map[string]interface{}{
			"apps": []string{},
			"details": []map[string]interface{}{
				{
					"appID": "ZSNGYUZM66.com.vasugarg.zerobridge",
					"paths": []string{"*"},
				},
			},
		},
	})
}

// localhostOnly restricts a handler to 127.0.0.1 / ::1.
func localhostOnly(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		host, _, err := net.SplitHostPort(r.RemoteAddr)
		if err != nil || (host != "127.0.0.1" && host != "::1") {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		next(w, r)
	}
}

func contentType(path string) string {
	switch {
	case len(path) > 5 && path[len(path)-5:] == ".html":
		return "text/html; charset=utf-8"
	case len(path) > 4 && path[len(path)-4:] == ".css":
		return "text/css"
	case len(path) > 3 && path[len(path)-3:] == ".js":
		return "application/javascript"
	case len(path) > 5 && path[len(path)-5:] == ".json":
		return "application/json"
	case len(path) > 4 && path[len(path)-4:] == ".png":
		return "image/png"
	case len(path) > 4 && path[len(path)-4:] == ".ico":
		return "image/x-icon"
	default:
		return "application/octet-stream"
	}
}
