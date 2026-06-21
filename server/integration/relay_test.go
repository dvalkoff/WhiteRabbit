//go:build integration

// Package integration exercises the live relay over real websockets against a
// running stack (docker compose up). Run with:
//
//	WR_BASE_A=http://localhost:8080 WR_BASE_B=http://localhost:8080 \
//	  go test -tags integration ./integration/ -v
//
// Set WR_BASE_B to a *different* server instance to prove cross-instance routing.
package integration

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"google.golang.org/protobuf/proto"

	"github.com/whiterabbit/server/internal/pb"
)

func baseA() string { return envOr("WR_BASE_A", "http://localhost:8080") }
func baseB() string { return envOr("WR_BASE_B", "http://localhost:8080") }

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func register(t *testing.T, base, nickname string) (userID, token string) {
	t.Helper()
	body, _ := json.Marshal(map[string]string{"nickname": nickname, "password": "password123"})
	resp, err := http.Post(base+"/v1/register", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatalf("register: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("register status %d", resp.StatusCode)
	}
	var out struct {
		UserID      string `json:"user_id"`
		AccessToken string `json:"access_token"`
	}
	json.NewDecoder(resp.Body).Decode(&out)
	return out.UserID, out.AccessToken
}

func dialWS(t *testing.T, base, token string) (*websocket.Conn, context.Context) {
	t.Helper()
	url := strings.Replace(base, "http", "ws", 1) + "/v1/ws?token=" + token
	ctx := context.Background()
	c, _, err := websocket.Dial(ctx, url, nil)
	if err != nil {
		t.Fatalf("ws dial: %v", err)
	}
	return c, ctx
}

func send(t *testing.T, c *websocket.Conn, ctx context.Context, env *pb.Envelope) {
	t.Helper()
	b, _ := proto.Marshal(env)
	if err := c.Write(ctx, websocket.MessageBinary, b); err != nil {
		t.Fatalf("ws write: %v", err)
	}
}

// readUntil reads frames until one matches pred or the deadline passes.
func readUntil(t *testing.T, c *websocket.Conn, pred func(*pb.Envelope) bool) *pb.Envelope {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for {
		_, data, err := c.Read(ctx)
		if err != nil {
			t.Fatalf("read: %v", err)
		}
		var env pb.Envelope
		if err := proto.Unmarshal(data, &env); err != nil {
			continue
		}
		if pred(&env) {
			return &env
		}
	}
}

// TestRealtimeRelay: A and B both online; A's message reaches B and A gets an Ack.
func TestRealtimeRelay(t *testing.T) {
	suffix := fmt.Sprintf("%d", time.Now().UnixNano())
	_, tokenA := register(t, baseA(), "rt_alice_"+suffix)
	bID, tokenB := register(t, baseB(), "rt_bob_"+suffix)

	connA, ctxA := dialWS(t, baseA(), tokenA)
	defer connA.Close(websocket.StatusNormalClosure, "")
	connB, _ := dialWS(t, baseB(), tokenB)
	defer connB.Close(websocket.StatusNormalClosure, "")

	time.Sleep(300 * time.Millisecond) // let B's subscription register

	cipher := []byte("opaque-ciphertext-hello")
	send(t, connA, ctxA, &pb.Envelope{
		Id:      "client-1",
		Payload: &pb.Envelope_Send{Send: &pb.SendMessage{RecipientId: bID, Ciphertext: cipher, Type: pb.MessageType_MESSAGE_TYPE_TEXT}},
	})

	// A should get an Ack.
	ack := readUntil(t, connA, func(e *pb.Envelope) bool { return e.GetAck() != nil })
	if ack.GetAck().GetClientId() != "client-1" {
		t.Fatalf("ack client id = %q", ack.GetAck().GetClientId())
	}

	// B should receive the incoming message with identical ciphertext.
	inc := readUntil(t, connB, func(e *pb.Envelope) bool { return e.GetIncoming() != nil })
	if !bytes.Equal(inc.GetIncoming().GetCiphertext(), cipher) {
		t.Fatalf("ciphertext mismatch")
	}
	t.Logf("realtime relay OK (A base=%s, B base=%s)", baseA(), baseB())
}

// TestOfflineStoreAndForward: send to B while B is offline, then connect B and
// confirm the queued message is flushed.
func TestOfflineStoreAndForward(t *testing.T) {
	suffix := fmt.Sprintf("%d", time.Now().UnixNano())
	_, tokenA := register(t, baseA(), "sf_alice_"+suffix)
	bID, tokenB := register(t, baseB(), "sf_bob_"+suffix)

	connA, ctxA := dialWS(t, baseA(), tokenA)
	defer connA.Close(websocket.StatusNormalClosure, "")

	cipher := []byte("queued-while-offline")
	send(t, connA, ctxA, &pb.Envelope{
		Id:      "client-2",
		Payload: &pb.Envelope_Send{Send: &pb.SendMessage{RecipientId: bID, Ciphertext: cipher, Type: pb.MessageType_MESSAGE_TYPE_TEXT}},
	})
	readUntil(t, connA, func(e *pb.Envelope) bool { return e.GetAck() != nil })

	// Now B comes online and should receive the queued message on connect.
	connB, _ := dialWS(t, baseB(), tokenB)
	defer connB.Close(websocket.StatusNormalClosure, "")

	inc := readUntil(t, connB, func(e *pb.Envelope) bool { return e.GetIncoming() != nil })
	if !bytes.Equal(inc.GetIncoming().GetCiphertext(), cipher) {
		t.Fatalf("offline ciphertext mismatch")
	}
	t.Logf("offline store-and-forward OK")
}
