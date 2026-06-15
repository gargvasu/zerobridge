package main

import (
	"encoding/base64"
	"encoding/json"
	"io"
	"log"
	"math/rand"
	"net/http"
	"strings"
	"time"

	"github.com/go-webauthn/webauthn/protocol"
	"github.com/go-webauthn/webauthn/webauthn"
)

// newWebAuthn creates the WebAuthn instance for the given origin hostname.
func newWebAuthn(rpid, origin string) (*webauthn.WebAuthn, error) {
	return webauthn.New(&webauthn.Config{
		RPDisplayName: "ZeroBridge",
		RPID:          rpid,
		RPOrigins:     []string{origin},
		Timeouts: webauthn.TimeoutsConfig{
			Login: webauthn.TimeoutConfig{
				Enforce:    true,
				Timeout:    60 * time.Second,
				TimeoutUVD: 60 * time.Second,
			},
			Registration: webauthn.TimeoutConfig{
				Enforce:    true,
				Timeout:    60 * time.Second,
				TimeoutUVD: 60 * time.Second,
			},
		},
	})
}

// ── Setup code ──────────────────────────────────────────────────────────────

// POST /admin/setup-code  (localhost only, called by gen-setup-code script)
func handleGenerateSetupCode(store *Store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		code := store.GenerateSetupCode()
		log.Printf("[auth] setup code generated: %s (valid 5m)", code)
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"code": code})
	}
}

// ── Registration ────────────────────────────────────────────────────────────

// POST /api/register/begin   body: {"code":"123456"}
func handleRegisterBegin(wa *webauthn.WebAuthn, store *Store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		var body struct{ Code string `json:"code"` }
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Code == "" {
			http.Error(w, `{"error":"missing code"}`, http.StatusBadRequest)
			return
		}
		if !store.ConsumeSetupCode(body.Code) {
			http.Error(w, `{"error":"invalid or expired code"}`, http.StatusForbidden)
			return
		}

		user := zbUser{store}

		log.Printf("[auth] BeginRegistration: user=%s existing_creds=%d", user.WebAuthnName(), len(user.WebAuthnCredentials()))
		// Request PRF extension — iOS 17+ Safari honours it, older falls back gracefully
		creation, session, err := wa.BeginRegistration(user,
			webauthn.WithResidentKeyRequirement(protocol.ResidentKeyRequirementRequired),
			webauthn.WithAuthenticatorSelection(protocol.AuthenticatorSelection{
				AuthenticatorAttachment: protocol.Platform,
				ResidentKey:             protocol.ResidentKeyRequirementRequired,
				UserVerification:        protocol.VerificationRequired,
			}),
			webauthn.WithExtensions(protocol.AuthenticationExtensions{
				"prf": map[string]interface{}{},
			}),
		)
		if err != nil {
			log.Printf("[auth] BeginRegistration error: %v", err)
			http.Error(w, `{"error":"internal"}`, http.StatusInternalServerError)
			return
		}

		store.SetRegSession(session)
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(creation)
	}
}

// POST /api/register/finish   body: WebAuthn credential + mode info
//
//	{
//	  "credential": <standard WebAuthn response>,
//	  "mode": "prf" | "split-key",
//	  "blob": "<base64 ciphertext>",          // Option A
//	  "split_key": "<base64 AES key>"         // Option B
//	}
func handleRegisterFinish(wa *webauthn.WebAuthn, store *Store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		// Parse the outer envelope
		var body struct {
			Credential json.RawMessage `json:"credential"`
			Mode       string          `json:"mode"`
			Blob       string          `json:"blob"`     // base64, Option A
			SplitKey   string          `json:"split_key"` // base64, Option B
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			http.Error(w, `{"error":"bad body"}`, http.StatusBadRequest)
			return
		}

		session := store.GetRegSession()
		if session == nil {
			log.Printf("[auth] RegisterFinish: no session in store")
			http.Error(w, `{"error":"no registration in progress"}`, http.StatusBadRequest)
			return
		}

		log.Printf("[auth] RegisterFinish: mode=%s credential_json_len=%d", body.Mode, len(body.Credential))

		// Parse the inner credential using a synthetic request
		credReq, err := protocol.ParseCredentialCreationResponseBody(
			&wrappedReader{data: body.Credential},
		)
		if err != nil {
			log.Printf("[auth] ParseCredentialCreationResponseBody error: %v  raw=%s", err, string(body.Credential))
			http.Error(w, `{"error":"invalid credential"}`, http.StatusBadRequest)
			return
		}
		log.Printf("[auth] ParseCredentialCreationResponseBody ok: type=%s id_len=%d", credReq.Type, len(credReq.ID))

		user := zbUser{store}
		credential, err := wa.CreateCredential(user, *session, credReq)
		if err != nil {
			log.Printf("[auth] CreateCredential error: %v", err)
			http.Error(w, `{"error":"credential verification failed"}`, http.StatusBadRequest)
			return
		}
		log.Printf("[auth] CreateCredential ok: cred_id_len=%d", len(credential.ID))

		mode := CredMode(body.Mode)
		if mode != ModePRF && mode != ModeSplitKey {
			http.Error(w, `{"error":"invalid mode"}`, http.StatusBadRequest)
			return
		}

		if err := store.SaveCredential(*credential, mode); err != nil {
			log.Printf("[auth] SaveCredential error: %v", err)
			http.Error(w, `{"error":"internal"}`, http.StatusInternalServerError)
			return
		}

		switch mode {
		case ModePRF:
			// Blob saved separately via POST /api/credential/blob after first auth assertion

		case ModeSplitKey:
			if body.SplitKey == "" {
				http.Error(w, `{"error":"missing split_key"}`, http.StatusBadRequest)
				return
			}
			key, err := base64.StdEncoding.DecodeString(body.SplitKey)
			if err != nil {
				http.Error(w, `{"error":"invalid split_key encoding"}`, http.StatusBadRequest)
				return
			}
			if err := store.SaveSplitKey(key); err != nil {
				log.Printf("[auth] SaveSplitKey error: %v", err)
				http.Error(w, `{"error":"internal"}`, http.StatusInternalServerError)
				return
			}
		}

		log.Printf("[auth] registration complete, mode=%s", mode)
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"status": "ok", "mode": string(mode)})
	}
}

// ── Authentication ───────────────────────────────────────────────────────────

// POST /api/auth/begin
func handleAuthBegin(wa *webauthn.WebAuthn, store *Store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if !store.HasCredential() {
			http.Error(w, `{"error":"no credential registered"}`, http.StatusPreconditionFailed)
			return
		}

		user := zbUser{store}

		// Include PRF evaluation with our fixed salt so the key is deterministic
		prfSalt := []byte("zerobridge-mac-password-v1")
		opts := []webauthn.LoginOption{
			webauthn.WithUserVerification(protocol.VerificationRequired),
		}
		if store.GetMode() == ModePRF {
			opts = append(opts, webauthn.WithAssertionExtensions(protocol.AuthenticationExtensions{
				"prf": map[string]interface{}{
					"eval": map[string]interface{}{
						"first": prfSalt,
					},
				},
			}))
		}

		log.Printf("[auth] BeginLogin: mode=%s creds=%d", store.GetMode(), len(user.WebAuthnCredentials()))
		assertion, session, err := wa.BeginLogin(user, opts...)
		if err != nil {
			log.Printf("[auth] BeginLogin error: %v", err)
			http.Error(w, `{"error":"internal"}`, http.StatusInternalServerError)
			return
		}
		log.Printf("[auth] BeginLogin ok: challenge issued")

		store.SetAuthSession(session)
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(assertion)
	}
}

// POST /api/auth/finish
func handleAuthFinish(wa *webauthn.WebAuthn, store *Store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		session := store.GetAuthSession()
		if session == nil {
			http.Error(w, `{"error":"no auth in progress"}`, http.StatusBadRequest)
			return
		}

		user := zbUser{store}
		body2, _ := io.ReadAll(r.Body)
		log.Printf("[auth] AuthFinish: body_len=%d body=%s", len(body2), string(body2))
		credResp, err := protocol.ParseCredentialRequestResponseBody(io.NopCloser(strings.NewReader(string(body2))))
		if err != nil {
			log.Printf("[auth] ParseCredentialRequestResponseBody error: %v", err)
			http.Error(w, `{"error":"invalid credential"}`, http.StatusBadRequest)
			return
		}
		log.Printf("[auth] ParseCredentialRequestResponseBody ok: type=%s", credResp.Type)

		credential, err := wa.ValidateLogin(user, *session, credResp)
		if err != nil {
			log.Printf("[auth] ValidateLogin error: %v", err)
			http.Error(w, `{"error":"authentication failed"}`, http.StatusUnauthorized)
			return
		}
		log.Printf("[auth] ValidateLogin ok")

		if err := store.UpdateCredential(*credential); err != nil {
			log.Printf("[auth] UpdateCredential error: %v", err)
		}

		token, err := issueJWT(store)
		if err != nil {
			log.Printf("[auth] issueJWT error: %v", err)
			http.Error(w, `{"error":"internal"}`, http.StatusInternalServerError)
			return
		}

		log.Printf("[auth] authentication successful, JWT issued")
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]interface{}{
			"token": token,
			"mode":  string(store.GetMode()),
		})
	}
}

// ── Credential data endpoints (JWT protected) ───────────────────────────────

// POST /api/credential/blob — Option A: save blob after registration (JWT protected)
func handleSaveBlob(store *Store) http.HandlerFunc {
	return requireAuth(store, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		var body struct{ Blob string `json:"blob"` }
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Blob == "" {
			http.Error(w, `{"error":"missing blob"}`, http.StatusBadRequest)
			return
		}
		blob, err := base64.StdEncoding.DecodeString(body.Blob)
		if err != nil {
			http.Error(w, `{"error":"invalid blob encoding"}`, http.StatusBadRequest)
			return
		}
		if err := store.SaveBlob(blob); err != nil {
			http.Error(w, `{"error":"internal"}`, http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
	})
}

// GET /api/credential/blob — Option A: return ciphertext for client to decrypt
func handleGetBlob(store *Store) http.HandlerFunc {
	return requireAuth(store, func(w http.ResponseWriter, r *http.Request) {
		blob := store.GetBlob()
		if blob == nil {
			http.Error(w, `{"error":"no blob stored"}`, http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{
			"blob": base64.StdEncoding.EncodeToString(blob),
		})
	})
}

// GET /api/credential/key — Option B: return split key (iPhone has ciphertext)
func handleGetSplitKey(store *Store) http.HandlerFunc {
	return requireAuth(store, func(w http.ResponseWriter, r *http.Request) {
		key := store.GetSplitKey()
		if key == nil {
			http.Error(w, `{"error":"no split key stored"}`, http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{
			"key": base64.StdEncoding.EncodeToString(key),
		})
	})
}

// GET /api/credential/mode — tell client which mode was registered
func handleGetMode(store *Store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]interface{}{
			"registered": store.HasCredential(),
			"mode":       string(store.GetMode()),
		})
	}
}

// ── helpers ─────────────────────────────────────────────────────────────────

// wrappedReader wraps a []byte so protocol.ParseCredentialCreationResponseBody can read it.
type wrappedReader struct {
	data []byte
	pos  int
}

func (w *wrappedReader) Read(p []byte) (int, error) {
	if w.pos >= len(w.data) {
		return 0, io.EOF
	}
	n := copy(p, w.data[w.pos:])
	w.pos += n
	return n, nil
}

// jitter adds ≤50ms random delay to prevent timing attacks on auth endpoints.
func jitter() {
	time.Sleep(time.Duration(rand.Intn(50)) * time.Millisecond)
}
