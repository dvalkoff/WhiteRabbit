// Package ws implements the realtime layer: authenticated websocket connections,
// a per-instance connection registry, and cross-instance message fan-out via
// Redis Pub/Sub. Any instance can accept any connection (no sticky sessions):
// PostgreSQL is the source of truth for undelivered messages, and Redis is the
// fast path that pushes a message to whichever instance currently holds the
// recipient's socket.
package ws

import (
	"context"
	"log/slog"
	"strings"
	"sync"
	"time"

	"github.com/redis/go-redis/v9"

	"github.com/whiterabbit/server/internal/store"
)

const (
	userChannelPrefix = "user:"
	presenceTTL       = 60 * time.Second
	flushBatch        = 200
)

// Hub owns the local connection registry and the Redis subscription used to
// receive messages routed to users connected to this instance.
type Hub struct {
	rdb        *redis.Client
	store      *store.Store
	log        *slog.Logger
	instanceID string

	mu     sync.RWMutex
	conns  map[string]*Conn // userID -> connection (one device per user in v1)
	pubsub *redis.PubSub
}

// NewHub creates a hub and starts its Redis subscription loop.
func NewHub(ctx context.Context, rdb *redis.Client, st *store.Store, log *slog.Logger, instanceID string) *Hub {
	h := &Hub{
		rdb:        rdb,
		store:      st,
		log:        log,
		instanceID: instanceID,
		conns:      make(map[string]*Conn),
	}
	// Subscribe with a placeholder so the PubSub object exists; real user
	// channels are added/removed as connections come and go.
	h.pubsub = rdb.Subscribe(ctx)
	go h.subscriptionLoop(ctx)
	return h
}

func userChannel(userID string) string { return userChannelPrefix + userID }

// register adds a connection and subscribes this instance to the user's channel.
func (h *Hub) register(ctx context.Context, c *Conn) {
	h.mu.Lock()
	// Evict an existing connection for the same user (single device): the newest
	// wins. The old one is closed.
	if old, ok := h.conns[c.userID]; ok {
		old.close()
	}
	h.conns[c.userID] = c
	h.mu.Unlock()

	if err := h.pubsub.Subscribe(ctx, userChannel(c.userID)); err != nil {
		h.log.Error("redis subscribe", "user", c.userID, "err", err)
	}
	h.touchPresence(ctx, c.userID)
}

// unregister removes a connection and unsubscribes if no longer present.
func (h *Hub) unregister(ctx context.Context, c *Conn) {
	h.mu.Lock()
	if cur, ok := h.conns[c.userID]; ok && cur == c {
		delete(h.conns, c.userID)
	}
	h.mu.Unlock()

	if err := h.pubsub.Unsubscribe(ctx, userChannel(c.userID)); err != nil {
		h.log.Debug("redis unsubscribe", "user", c.userID, "err", err)
	}
	h.rdb.Del(ctx, "presence:"+c.userID)
}

func (h *Hub) localConn(userID string) (*Conn, bool) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	c, ok := h.conns[userID]
	return c, ok
}

func (h *Hub) touchPresence(ctx context.Context, userID string) {
	h.rdb.Set(ctx, "presence:"+userID, h.instanceID, presenceTTL)
}

// subscriptionLoop receives messages published to user channels this instance is
// subscribed to and writes them to the corresponding local socket.
func (h *Hub) subscriptionLoop(ctx context.Context) {
	ch := h.pubsub.Channel()
	for {
		select {
		case <-ctx.Done():
			return
		case msg, ok := <-ch:
			if !ok {
				return
			}
			userID := strings.TrimPrefix(msg.Channel, userChannelPrefix)
			if c, ok := h.localConn(userID); ok {
				c.enqueue([]byte(msg.Payload))
			}
			// If not connected locally, the message remains undelivered in
			// Postgres and is flushed on the recipient's next connect.
		}
	}
}

// publishToUser sends raw envelope bytes to whatever instance holds the user's
// socket (possibly this one). Returns whether anyone is believed to be online.
func (h *Hub) publishToUser(ctx context.Context, userID string, payload []byte) {
	if err := h.rdb.Publish(ctx, userChannel(userID), payload).Err(); err != nil {
		h.log.Error("redis publish", "user", userID, "err", err)
	}
}

// Close tears down the Redis subscription.
func (h *Hub) Close() error {
	if h.pubsub != nil {
		return h.pubsub.Close()
	}
	return nil
}
