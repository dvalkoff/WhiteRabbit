package ws

import (
	"context"
	"time"

	"github.com/coder/websocket"
	"google.golang.org/protobuf/proto"

	"github.com/whiterabbit/server/internal/pb"
	"github.com/whiterabbit/server/internal/store"
)

const (
	sendBufferSize = 64
	writeTimeout   = 10 * time.Second
)

// Conn is a single authenticated websocket connection.
type Conn struct {
	userID string
	ws     *websocket.Conn
	send   chan []byte
	hub    *Hub
	closed chan struct{}
}

// Serve registers the connection, flushes any queued messages, and runs the
// read/write loops until the connection ends. It blocks until disconnect.
func (h *Hub) Serve(ctx context.Context, userID string, wsConn *websocket.Conn) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	c := &Conn{
		userID: userID,
		ws:     wsConn,
		send:   make(chan []byte, sendBufferSize),
		hub:    h,
		closed: make(chan struct{}),
	}

	h.register(ctx, c)
	defer h.unregister(context.Background(), c)

	go c.writeLoop(ctx)

	// Deliver messages that were queued while the user was offline.
	c.flushUndelivered(ctx)

	c.readLoop(ctx)
}

// enqueue queues raw bytes for delivery to the client. Drops if the buffer is
// full (slow consumer); the message stays in the DB queue as a fallback.
func (c *Conn) enqueue(b []byte) {
	select {
	case c.send <- b:
	default:
		c.hub.log.Warn("send buffer full, dropping frame", "user", c.userID)
	}
}

func (c *Conn) close() {
	select {
	case <-c.closed:
	default:
		close(c.closed)
		_ = c.ws.Close(websocket.StatusNormalClosure, "")
	}
}

func (c *Conn) writeLoop(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case <-c.closed:
			return
		case b := <-c.send:
			wctx, cancel := context.WithTimeout(ctx, writeTimeout)
			err := c.ws.Write(wctx, websocket.MessageBinary, b)
			cancel()
			if err != nil {
				c.close()
				return
			}
		}
	}
}

func (c *Conn) readLoop(ctx context.Context) {
	for {
		typ, data, err := c.ws.Read(ctx)
		if err != nil {
			c.close()
			return
		}
		if typ != websocket.MessageBinary {
			continue
		}
		var env pb.Envelope
		if err := proto.Unmarshal(data, &env); err != nil {
			c.sendError(env.GetId(), "bad_envelope", "could not parse envelope")
			continue
		}
		c.handleEnvelope(ctx, &env)
	}
}

func (c *Conn) handleEnvelope(ctx context.Context, env *pb.Envelope) {
	switch p := env.Payload.(type) {
	case *pb.Envelope_Send:
		c.handleSend(ctx, env.GetId(), p.Send)
	case *pb.Envelope_Receipt:
		c.handleReceipt(ctx, p.Receipt)
	case *pb.Envelope_Typing:
		c.handleTyping(ctx, p.Typing)
	case *pb.Envelope_Ping:
		c.handlePing(ctx)
	default:
		c.sendError(env.GetId(), "unsupported", "unsupported payload from client")
	}
}

// handleSend persists the ciphertext, acks the sender, and fans the message out
// to the recipient via Redis.
func (c *Conn) handleSend(ctx context.Context, clientID string, m *pb.SendMessage) {
	if m.GetRecipientId() == "" || len(m.GetCiphertext()) == 0 {
		c.sendError(clientID, "invalid_message", "recipient and ciphertext required")
		return
	}

	id, createdAt, err := c.hub.store.EnqueueMessage(ctx, store.Message{
		SenderID:    c.userID,
		RecipientID: m.GetRecipientId(),
		Ciphertext:  m.GetCiphertext(),
		MsgType:     int32(m.GetType()),
		IsPreKey:    m.GetIsPrekey(),
	})
	if err != nil {
		c.hub.log.Error("enqueue message", "err", err)
		c.sendError(clientID, "enqueue_failed", "could not persist message")
		return
	}

	// Ack the sender so the UI can mark the message as sent.
	c.enqueue(mustMarshal(&pb.Envelope{Payload: &pb.Envelope_Ack{Ack: &pb.Ack{
		ClientId:        clientID,
		MessageId:       id,
		CreatedAtUnixMs: createdAt.UnixMilli(),
	}}}))

	// Fan out to the recipient (any instance). If they're offline, this is a
	// no-op and the message is delivered on their next connect via flush.
	incoming := mustMarshal(&pb.Envelope{Payload: &pb.Envelope_Incoming{Incoming: &pb.IncomingMessage{
		MessageId:       id,
		SenderId:        c.userID,
		Ciphertext:      m.GetCiphertext(),
		Type:            m.GetType(),
		IsPrekey:        m.GetIsPrekey(),
		CreatedAtUnixMs: createdAt.UnixMilli(),
	}}})
	c.hub.publishToUser(ctx, m.GetRecipientId(), incoming)
}

// handleReceipt marks a message delivered/read and relays the receipt to the
// original sender.
func (c *Conn) handleReceipt(ctx context.Context, r *pb.Receipt) {
	if r.GetKind() == pb.Receipt_KIND_DELIVERED {
		if err := c.hub.store.MarkDelivered(ctx, r.GetMessageId()); err != nil {
			c.hub.log.Error("mark delivered", "err", err)
		}
	}
	if r.GetSenderId() != "" {
		relay := mustMarshal(&pb.Envelope{Payload: &pb.Envelope_Receipt{Receipt: &pb.Receipt{
			MessageId: r.GetMessageId(),
			SenderId:  c.userID,
			Kind:      r.GetKind(),
		}}})
		c.hub.publishToUser(ctx, r.GetSenderId(), relay)
	}
}

func (c *Conn) handleTyping(ctx context.Context, t *pb.Typing) {
	if t.GetPeerId() == "" {
		return
	}
	relay := mustMarshal(&pb.Envelope{Payload: &pb.Envelope_Typing{Typing: &pb.Typing{
		PeerId: c.userID,
		Typing: t.GetTyping(),
	}}})
	c.hub.publishToUser(ctx, t.GetPeerId(), relay)
}

func (c *Conn) handlePing(ctx context.Context) {
	c.hub.touchPresence(ctx, c.userID)
	c.enqueue(mustMarshal(&pb.Envelope{Payload: &pb.Envelope_Pong{Pong: &pb.Pong{}}}))
}

// flushUndelivered pushes queued messages to a freshly-connected client.
func (c *Conn) flushUndelivered(ctx context.Context) {
	msgs, err := c.hub.store.FetchUndelivered(ctx, c.userID, flushBatch)
	if err != nil {
		c.hub.log.Error("fetch undelivered", "err", err)
		return
	}
	for _, m := range msgs {
		c.enqueue(mustMarshal(&pb.Envelope{Payload: &pb.Envelope_Incoming{Incoming: &pb.IncomingMessage{
			MessageId:       m.ID,
			SenderId:        m.SenderID,
			Ciphertext:      m.Ciphertext,
			Type:            pb.MessageType(m.MsgType),
			IsPrekey:        m.IsPreKey,
			CreatedAtUnixMs: m.CreatedAt.UnixMilli(),
		}}}))
	}
}

func (c *Conn) sendError(id, code, msg string) {
	c.enqueue(mustMarshal(&pb.Envelope{
		Id:      id,
		Payload: &pb.Envelope_Error{Error: &pb.Error{Code: code, Message: msg}},
	}))
}

func mustMarshal(env *pb.Envelope) []byte {
	b, err := proto.Marshal(env)
	if err != nil {
		// Marshalling our own well-formed messages should never fail.
		panic(err)
	}
	return b
}
