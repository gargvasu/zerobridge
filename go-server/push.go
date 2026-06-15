package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"log"
	"math/big"
	"net"
	"net/http"
	"net/url"
	"sync"
	"time"

	webpush "github.com/SherClockHolmes/webpush-go"
)

// buildVAPIDAuth generates a VAPID Authorization header with a hand-rolled
// ES256 JWT, bypassing webpush-go's JWT layer which has known Apple issues.
func buildVAPIDAuth(endpoint, vapidPub, vapidPriv string) (string, error) {
	u, err := url.Parse(endpoint)
	if err != nil {
		return "", err
	}
	aud := u.Scheme + "://" + u.Host

	// --- JWT header + payload ---
	hdr := base64.RawURLEncoding.EncodeToString([]byte(`{"typ":"JWT","alg":"ES256"}`))
	payJSON, _ := json.Marshal(map[string]interface{}{
		"aud": aud,
		"exp": time.Now().Add(12 * time.Hour).Unix(),
		"sub": "mailto:zerobridge@local.device",
	})
	pay := base64.RawURLEncoding.EncodeToString(payJSON)
	sigInput := hdr + "." + pay

	// --- decode VAPID private key scalar ---
	privBytes, err := base64.RawURLEncoding.DecodeString(vapidPriv)
	if err != nil {
		privBytes, err = base64.URLEncoding.DecodeString(vapidPriv)
		if err != nil {
			return "", err
		}
	}

	// --- reconstruct P-256 ECDSA key ---
	curve := elliptic.P256()
	px, py := curve.ScalarBaseMult(privBytes)
	privKey := &ecdsa.PrivateKey{
		PublicKey: ecdsa.PublicKey{Curve: curve, X: px, Y: py},
		D:         new(big.Int).SetBytes(privBytes),
	}

	// --- sign: ES256 = ECDSA P-256 SHA-256 ---
	digest := sha256.Sum256([]byte(sigInput))
	r, s, err := ecdsa.Sign(rand.Reader, privKey, digest[:])
	if err != nil {
		return "", err
	}

	// IEEE P1363 format: r || s, each zero-padded to 32 bytes
	sig := make([]byte, 64)
	rB, sB := r.Bytes(), s.Bytes()
	copy(sig[32-len(rB):32], rB)
	copy(sig[64-len(sB):64], sB)

	jwtToken := sigInput + "." + base64.RawURLEncoding.EncodeToString(sig)

	// k = uncompressed public key (65 bytes: 0x04 || x || y)
	pubBytes, _ := base64.RawURLEncoding.DecodeString(vapidPub)

	auth := "vapid t=" + jwtToken + ", k=" + base64.RawURLEncoding.EncodeToString(pubBytes)
	log.Printf("[push] VAPID auth header built, aud=%s", aud)
	return auth, nil
}

// vapidClient overrides the Authorization header set by webpush-go with our
// hand-rolled JWT to ensure Apple accepts it.
type vapidClient struct {
	endpoint string
	pub      string
	priv     string
}

func (c *vapidClient) Do(req *http.Request) (*http.Response, error) {
	auth, err := buildVAPIDAuth(c.endpoint, c.pub, c.priv)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", auth)
	return http.DefaultClient.Do(req)
}

type pushManager struct {
	mu        sync.RWMutex
	vapidPub  string
	vapidPriv string
	sub       *webpush.Subscription
}

var pushMgr = &pushManager{}

func initPush(store *Store) error {
	pub, priv, err := store.GetVAPIDKeys()
	if err != nil {
		return err
	}
	pushMgr.vapidPub = pub
	pushMgr.vapidPriv = priv
	log.Printf("[push] VAPID ready, pub=%s…", pub[:20])
	return nil
}

// GET /api/push/vapid-key
func handleVAPIDKey(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"public_key": pushMgr.vapidPub})
}

// POST /api/push/subscribe  (JWT protected)
func handlePushSubscribe(store *Store) http.HandlerFunc {
	return requireAuth(store, func(w http.ResponseWriter, r *http.Request) {
		var sub webpush.Subscription
		if err := json.NewDecoder(r.Body).Decode(&sub); err != nil || sub.Endpoint == "" {
			http.Error(w, `{"error":"invalid subscription"}`, http.StatusBadRequest)
			return
		}
		pushMgr.mu.Lock()
		pushMgr.sub = &sub
		pushMgr.mu.Unlock()
		ep := sub.Endpoint
		if len(ep) > 50 {
			ep = ep[:50] + "…"
		}
		log.Printf("[push] subscription saved: %s", ep)
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
	})
}

// SendPush fires a push notification if a subscription is registered.
func SendPush(title, body string) {
	pushMgr.mu.RLock()
	sub := pushMgr.sub
	pub := pushMgr.vapidPub
	priv := pushMgr.vapidPriv
	pushMgr.mu.RUnlock()

	if sub == nil {
		return
	}
	payload, _ := json.Marshal(map[string]string{"title": title, "body": body})
	resp, err := webpush.SendNotification(payload, sub, &webpush.Options{
		HTTPClient:      &vapidClient{endpoint: sub.Endpoint, pub: pub, priv: priv},
		VAPIDPublicKey:  pub,
		VAPIDPrivateKey: priv,
		Subscriber:      "zerobridge@local.device",
		TTL:             60,
		Urgency:         webpush.UrgencyHigh,
	})
	if err != nil {
		log.Printf("[push] send error: %v", err)
		return
	}
	defer resp.Body.Close()
	body2 := make([]byte, 512)
	n, _ := resp.Body.Read(body2)
	log.Printf("[push] sent %q → HTTP %d body=%s", title, resp.StatusCode, string(body2[:n]))
	if resp.StatusCode == 410 || resp.StatusCode == 404 {
		pushMgr.mu.Lock()
		pushMgr.sub = nil
		pushMgr.mu.Unlock()
		log.Printf("[push] subscription expired, cleared")
	}
}

// startMacStatePoller polls mac state every 10s and sends push on transitions.
func startMacStatePoller(sock string) {
	go func() {
		var last string
		for range time.NewTicker(10 * time.Second).C {
			state, locked, sleep := pollMacState(sock)
			if state == "" || state == last {
				continue
			}
			switch {
			case sleep && last != "display_sleep":
				SendPush("Mac is sleeping 😴", "Display sleep active")
			case locked && !sleep && last != "locked":
				SendPush("Mac is locked 🔒", "Tap to unlock")
			case !locked && !sleep && (last == "locked" || last == "display_sleep"):
				SendPush("Mac is active ✅", "Unlocked and ready")
			}
			_ = locked
			last = state
		}
	}()
}

// POST /admin/test-push  (localhost only)
func handleTestPush(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	pushMgr.mu.RLock()
	hasSub := pushMgr.sub != nil
	pushMgr.mu.RUnlock()
	if !hasSub {
		http.Error(w, `{"error":"no push subscription registered — open the PWA first"}`, http.StatusPreconditionFailed)
		return
	}
	SendPush("ZeroBridge test 🌉", "Push notifications are working!")
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"status": "sent"})
}

func pollMacState(sockPath string) (state string, locked, displaySleep bool) {
	conn, err := net.DialTimeout("unix", sockPath, 2*time.Second)
	if err != nil {
		return "", false, false
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(3 * time.Second))

	if _, err := conn.Write([]byte(`{"id":"push-poll","type":"get_mac_state"}` + "\n")); err != nil {
		return "", false, false
	}
	buf := make([]byte, 4096)
	n, err := conn.Read(buf)
	if err != nil || n == 0 {
		return "", false, false
	}
	var resp struct {
		State        string `json:"state"`
		Locked       bool   `json:"locked"`
		DisplaySleep bool   `json:"display_sleep"`
	}
	if err := json.Unmarshal(buf[:n], &resp); err != nil {
		return "", false, false
	}
	return resp.State, resp.Locked, resp.DisplaySleep
}
