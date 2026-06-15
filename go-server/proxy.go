package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/gorilla/websocket"
)

var upgrader = websocket.Upgrader{
	CheckOrigin:     func(r *http.Request) bool { return true },
	ReadBufferSize:  4096,
	WriteBufferSize: 4096,
}

func handleWS(w http.ResponseWriter, r *http.Request) {
	ws, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("[ws] upgrade error: %v", err)
		return
	}
	defer ws.Close()

	remote := r.RemoteAddr
	log.Printf("[ws] ← connected: %s", remote)

	// Connect to pi-agent Unix socket
	unix, err := net.DialTimeout("unix", sockPath, 3*time.Second)
	if err != nil {
		log.Printf("[ws] pi-agent not reachable: %v", err)
		errMsg, _ := json.Marshal(map[string]string{
			"type":    "error",
			"id":      "conn",
			"message": fmt.Sprintf("pi-agent not reachable: %v", err),
		})
		ws.WriteMessage(websocket.TextMessage, errMsg)
		return
	}
	defer unix.Close()

	log.Printf("[ws] ✅ pi-agent connected for %s", remote)

	done := make(chan struct{})

	// goroutine 1: browser → pi-agent
	go func() {
		defer close(done)
		for {
			_, msg, err := ws.ReadMessage()
			if err != nil {
				if !websocket.IsCloseError(err, websocket.CloseNormalClosure, websocket.CloseGoingAway) {
					log.Printf("[ws] read error (%s): %v", remote, err)
				}
				return
			}
			line := strings.TrimSpace(string(msg))
			if line == "" {
				continue
			}
			if _, err := fmt.Fprintf(unix, "%s\n", line); err != nil {
				log.Printf("[ws] unix write error (%s): %v", remote, err)
				return
			}
		}
	}()

	// goroutine 2: pi-agent → browser (runs in main goroutine scope)
	scanner := bufio.NewScanner(unix)
	scanner.Buffer(make([]byte, 64*1024), 64*1024)
	piDone := make(chan struct{})
	go func() {
		defer close(piDone)
		for scanner.Scan() {
			line := scanner.Text()
			if line == "" {
				continue
			}
			if err := ws.WriteMessage(websocket.TextMessage, []byte(line)); err != nil {
				log.Printf("[ws] ws write error (%s): %v", remote, err)
				return
			}
		}
		if err := scanner.Err(); err != nil {
			log.Printf("[ws] unix read error (%s): %v", remote, err)
		}
	}()

	// Wait for either side to close
	select {
	case <-done:
		unix.Close()
		<-piDone
	case <-piDone:
		ws.Close()
		<-done
	}

	log.Printf("[ws] ✗ disconnected: %s", remote)
}
