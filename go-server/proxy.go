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

const (
	wsPingInterval = 25 * time.Second
	wsPongWait     = 10 * time.Second
	wsWriteWait    = 10 * time.Second
)

func handleWS(w http.ResponseWriter, r *http.Request) {
	ws, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("[ws] upgrade error: %v", err)
		return
	}
	defer ws.Close()

	remote := r.RemoteAddr
	log.Printf("[ws] ← connected: %s", remote)

	unix, err := net.DialTimeout("unix", sockPath, 3*time.Second)
	if err != nil {
		log.Printf("[ws] pi-agent not reachable: %v", err)
		b, _ := json.Marshal(map[string]string{"type": "error", "id": "conn", "message": fmt.Sprintf("pi-agent not reachable: %v", err)})
		ws.WriteMessage(websocket.TextMessage, b)
		return
	}
	defer unix.Close()
	log.Printf("[ws] ✅ pi-agent connected for %s", remote)

	// Pong resets the read deadline so the connection stays alive.
	ws.SetReadDeadline(time.Now().Add(wsPingInterval + wsPongWait))
	ws.SetPongHandler(func(string) error {
		ws.SetReadDeadline(time.Now().Add(wsPingInterval + wsPongWait))
		return nil
	})

	wsDone := make(chan struct{})
	piDone := make(chan struct{})

	// browser → pi-agent
	go func() {
		defer close(wsDone)
		for {
			_, msg, err := ws.ReadMessage()
			if err != nil {
				if !websocket.IsCloseError(err, websocket.CloseNormalClosure, websocket.CloseGoingAway) {
					log.Printf("[ws] browser read error (%s): %v", remote, err)
				}
				return
			}
			line := strings.TrimSpace(string(msg))
			if line == "" {
				continue
			}
			unix.SetWriteDeadline(time.Now().Add(wsWriteWait))
			if _, err := fmt.Fprintf(unix, "%s\n", line); err != nil {
				log.Printf("[ws] unix write error (%s): %v", remote, err)
				return
			}
		}
	}()

	// pi-agent → browser
	go func() {
		defer close(piDone)
		scanner := bufio.NewScanner(unix)
		scanner.Buffer(make([]byte, 64*1024), 64*1024)
		for scanner.Scan() {
			line := scanner.Text()
			if line == "" {
				continue
			}
			ws.SetWriteDeadline(time.Now().Add(wsWriteWait))
			if err := ws.WriteMessage(websocket.TextMessage, []byte(line)); err != nil {
				log.Printf("[ws] browser write error (%s): %v", remote, err)
				return
			}
		}
		if err := scanner.Err(); err != nil && !strings.Contains(err.Error(), "use of closed network connection") {
			log.Printf("[ws] unix read error (%s): %v", remote, err)
		}
	}()

	// Ping ticker — keeps Safari from timing out the WS
	ticker := time.NewTicker(wsPingInterval)
	defer ticker.Stop()

	for {
		select {
		case <-wsDone:
			unix.Close()
			<-piDone
			log.Printf("[ws] ✗ disconnected: %s", remote)
			return
		case <-piDone:
			ws.Close()
			<-wsDone
			log.Printf("[ws] ✗ pi-agent closed: %s", remote)
			return
		case <-ticker.C:
			ws.SetWriteDeadline(time.Now().Add(wsWriteWait))
			if err := ws.WriteMessage(websocket.PingMessage, nil); err != nil {
				unix.Close()
				log.Printf("[ws] ping failed (%s): %v", remote, err)
				return
			}
		}
	}
}
