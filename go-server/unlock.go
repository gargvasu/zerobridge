package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"time"
)

// POST /api/unlock
// Body: {"password": "<plaintext>"}   (plaintext, decrypted client-side)
// The password is typed via pi-agent HID and immediately discarded.
func handleUnlock(store *Store, sockPath string) http.HandlerFunc {
	return requireAuth(store, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		var body struct {
			Password string `json:"password"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Password == "" {
			http.Error(w, `{"error":"missing password"}`, http.StatusBadRequest)
			return
		}

		if err := typePasswordViaHID(body.Password, sockPath); err != nil {
			log.Printf("[unlock] HID error: %v", err)
			http.Error(w, `{"error":"HID failed"}`, http.StatusInternalServerError)
			return
		}

		log.Printf("[unlock] password typed via HID")
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
	})
}

// typePasswordViaHID sends type_text + Enter to pi-agent over the Unix socket.
func typePasswordViaHID(password, sockPath string) error {
	conn, err := net.DialTimeout("unix", sockPath, 3*time.Second)
	if err != nil {
		return fmt.Errorf("dial pi-agent: %w", err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(10 * time.Second))

	// Type the password
	typeCmd := fmt.Sprintf(`{"id":"unlock-1","type":"type_text","text":%s}`, jsonStr(password))
	if _, err := fmt.Fprintf(conn, "%s\n", typeCmd); err != nil {
		return fmt.Errorf("write type_text: %w", err)
	}
	if err := readOK(conn); err != nil {
		return fmt.Errorf("type_text: %w", err)
	}

	// Press Enter
	enterCmd := `{"id":"unlock-2","type":"key","code":"ENTER","modifiers":[]}`
	if _, err := fmt.Fprintf(conn, "%s\n", enterCmd); err != nil {
		return fmt.Errorf("write enter: %w", err)
	}
	if err := readOK(conn); err != nil {
		return fmt.Errorf("enter: %w", err)
	}

	return nil
}

func readOK(conn net.Conn) error {
	buf := make([]byte, 512)
	n, err := conn.Read(buf)
	if err != nil {
		return err
	}
	var resp map[string]interface{}
	if err := json.Unmarshal(buf[:n], &resp); err != nil {
		return fmt.Errorf("parse response: %w", err)
	}
	if t, _ := resp["type"].(string); t == "error" {
		return fmt.Errorf("pi-agent error: %v", resp["message"])
	}
	return nil
}

func jsonStr(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}
