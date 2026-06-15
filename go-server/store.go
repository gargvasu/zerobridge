package main

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	webpush "github.com/SherClockHolmes/webpush-go"
	"github.com/go-webauthn/webauthn/webauthn"
)

// webpushVAPID wraps the library call so store.go doesn't import push.go symbols.
func webpushVAPID() (priv, pub string, err error) {
	return webpush.GenerateVAPIDKeys()
}

type CredMode string

const (
	ModePRF      CredMode = "prf"
	ModeSplitKey CredMode = "split-key"
	ModeNone     CredMode = ""
)

type storedData struct {
	Credentials []webauthn.Credential `json:"credentials"`
	Mode        CredMode              `json:"mode,omitempty"`
	Blob        []byte                `json:"blob,omitempty"`
	SplitKey    []byte                `json:"split_key,omitempty"`
	JWTSecret   []byte                `json:"jwt_secret"`
	VAPIDPub    string                `json:"vapid_pub,omitempty"`
	VAPIDPriv   string                `json:"vapid_priv,omitempty"`
}

type Store struct {
	mu   sync.RWMutex
	d    storedData
	path string

	// ephemeral — never persisted
	setupCode    string
	setupCodeExp time.Time
	regSession   *webauthn.SessionData
	authSession  *webauthn.SessionData
}

func NewStore(dir string) (*Store, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("create data dir: %w", err)
	}
	s := &Store{path: filepath.Join(dir, "store.json")}
	if err := s.load(); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *Store) load() error {
	data, err := os.ReadFile(s.path)
	if os.IsNotExist(err) {
		secret := make([]byte, 32)
		if _, err := rand.Read(secret); err != nil {
			return fmt.Errorf("generate jwt secret: %w", err)
		}
		s.d.JWTSecret = secret
		return s.save()
	}
	if err != nil {
		return fmt.Errorf("read store: %w", err)
	}
	return json.Unmarshal(data, &s.d)
}

func (s *Store) save() error {
	data, err := json.MarshalIndent(s.d, "", "  ")
	if err != nil {
		return err
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.path)
}

// ── Setup code ─────────────────────────────────────────────────────────────

func (s *Store) GenerateSetupCode() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	b := make([]byte, 3)
	rand.Read(b)
	code := fmt.Sprintf("%06d", (int(b[0])<<16|int(b[1])<<8|int(b[2]))%1000000)
	s.setupCode = code
	s.setupCodeExp = time.Now().Add(5 * time.Minute)
	return code
}

func (s *Store) ValidateSetupCode(code string) bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.setupCode != "" && s.setupCode == code && time.Now().Before(s.setupCodeExp)
}

func (s *Store) ConsumeSetupCode(code string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.setupCode == "" || s.setupCode != code || time.Now().After(s.setupCodeExp) {
		return false
	}
	s.setupCode = ""
	return true
}

// ── WebAuthn sessions ───────────────────────────────────────────────────────

func (s *Store) SetRegSession(sd *webauthn.SessionData) {
	s.mu.Lock(); defer s.mu.Unlock()
	s.regSession = sd
}
func (s *Store) GetRegSession() *webauthn.SessionData {
	s.mu.RLock(); defer s.mu.RUnlock()
	return s.regSession
}
func (s *Store) SetAuthSession(sd *webauthn.SessionData) {
	s.mu.Lock(); defer s.mu.Unlock()
	s.authSession = sd
}
func (s *Store) GetAuthSession() *webauthn.SessionData {
	s.mu.RLock(); defer s.mu.RUnlock()
	return s.authSession
}

// ── Credentials ─────────────────────────────────────────────────────────────

func (s *Store) GetCredentials() []webauthn.Credential {
	s.mu.RLock(); defer s.mu.RUnlock()
	return s.d.Credentials
}

func (s *Store) HasCredential() bool {
	s.mu.RLock(); defer s.mu.RUnlock()
	return len(s.d.Credentials) > 0
}

func (s *Store) SaveCredential(c webauthn.Credential, mode CredMode) error {
	s.mu.Lock(); defer s.mu.Unlock()
	s.d.Credentials = []webauthn.Credential{c} // single-user; replace any prior credential
	s.d.Mode = mode
	s.d.Blob = nil     // old blob was encrypted with the replaced passkey — useless now
	s.d.SplitKey = nil // likewise for split-key mode
	return s.save()
}

func (s *Store) UpdateCredential(c webauthn.Credential) error {
	s.mu.Lock(); defer s.mu.Unlock()
	for i, existing := range s.d.Credentials {
		if string(existing.ID) == string(c.ID) {
			s.d.Credentials[i] = c
			return s.save()
		}
	}
	return nil
}

func (s *Store) GetMode() CredMode {
	s.mu.RLock(); defer s.mu.RUnlock()
	return s.d.Mode
}

// ── Option A: server-side ciphertext (Pi cannot decrypt) ───────────────────

func (s *Store) SaveBlob(ciphertext []byte) error {
	s.mu.Lock(); defer s.mu.Unlock()
	s.d.Blob = ciphertext
	return s.save()
}

func (s *Store) GetBlob() []byte {
	s.mu.RLock(); defer s.mu.RUnlock()
	return s.d.Blob
}

// ── Option B: server-side AES key (iPhone has ciphertext) ──────────────────

func (s *Store) SaveSplitKey(key []byte) error {
	s.mu.Lock(); defer s.mu.Unlock()
	s.d.SplitKey = key
	return s.save()
}

func (s *Store) GetSplitKey() []byte {
	s.mu.RLock(); defer s.mu.RUnlock()
	return s.d.SplitKey
}

// ── JWT secret ──────────────────────────────────────────────────────────────

func (s *Store) JWTSecret() []byte {
	s.mu.RLock(); defer s.mu.RUnlock()
	return s.d.JWTSecret
}

// ── VAPID keys (generated once, persisted) ───────────────────────────────────

func (s *Store) GetVAPIDKeys() (pub, priv string, err error) {
	s.mu.Lock(); defer s.mu.Unlock()
	if s.d.VAPIDPub != "" {
		return s.d.VAPIDPub, s.d.VAPIDPriv, nil
	}
	// Generate fresh VAPID key pair
	priv, pub, err = webpushVAPID()
	if err != nil {
		return "", "", err
	}
	s.d.VAPIDPub = pub
	s.d.VAPIDPriv = priv
	return pub, priv, s.save()
}

// ── WebAuthn user (single-user system) ──────────────────────────────────────

type zbUser struct{ store *Store }

func (u zbUser) WebAuthnID() []byte              { return []byte("zerobridge-user") }
func (u zbUser) WebAuthnName() string            { return "zerobridge" }
func (u zbUser) WebAuthnDisplayName() string     { return "ZeroBridge" }
func (u zbUser) WebAuthnCredentials() []webauthn.Credential { return u.store.GetCredentials() }
func (u zbUser) WebAuthnIcon() string            { return "" }
