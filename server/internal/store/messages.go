package store

import (
	"context"
	"time"
)

// Message is a queued encrypted message row.
type Message struct {
	ID          string
	SenderID    string
	RecipientID string
	Ciphertext  []byte
	MsgType     int32
	IsPreKey    bool
	CreatedAt   time.Time
}

// EnqueueMessage persists an encrypted message for store-and-forward delivery
// and returns its server-assigned id and timestamp.
func (s *Store) EnqueueMessage(ctx context.Context, m Message) (string, time.Time, error) {
	var id string
	var createdAt time.Time
	err := s.pool.QueryRow(ctx,
		`INSERT INTO messages (sender_id, recipient_id, ciphertext, msg_type, is_prekey)
		 VALUES ($1, $2, $3, $4, $5)
		 RETURNING id, created_at`,
		m.SenderID, m.RecipientID, m.Ciphertext, m.MsgType, m.IsPreKey,
	).Scan(&id, &createdAt)
	return id, createdAt, err
}

// FetchUndelivered returns messages queued for a recipient that have not yet
// been delivered, oldest first.
func (s *Store) FetchUndelivered(ctx context.Context, recipientID string, limit int) ([]Message, error) {
	rows, err := s.pool.Query(ctx,
		`SELECT id, sender_id, recipient_id, ciphertext, msg_type, is_prekey, created_at
		 FROM messages
		 WHERE recipient_id = $1 AND delivered_at IS NULL
		 ORDER BY created_at
		 LIMIT $2`, recipientID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Message
	for rows.Next() {
		var m Message
		if err := rows.Scan(&m.ID, &m.SenderID, &m.RecipientID, &m.Ciphertext, &m.MsgType, &m.IsPreKey, &m.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// MarkDelivered stamps a message as delivered (idempotent).
func (s *Store) MarkDelivered(ctx context.Context, messageID string) error {
	_, err := s.pool.Exec(ctx,
		`UPDATE messages SET delivered_at = now()
		 WHERE id = $1 AND delivered_at IS NULL`, messageID)
	return err
}
