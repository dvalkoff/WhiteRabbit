package store

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
)

// PreKeyBundle is the public material a peer needs to start an X3DH session.
// OneTimePreKey may be empty if the user has exhausted their one-time prekeys
// (X3DH degrades gracefully without it).
type PreKeyBundle struct {
	UserID           string
	RegistrationID   int32
	IdentityKeyEd    []byte // Ed25519 public, verifies SignedPreKeySig
	IdentityKeyX     []byte // X25519 public, used in DH
	SignedPreKeyID   int32
	SignedPreKey     []byte // X25519 public
	SignedPreKeySig  []byte // signature over SignedPreKey by IdentityKeyEd
	OneTimePreKeyID  int32
	OneTimePreKey    []byte // X25519 public, may be nil
	HasOneTimePreKey bool
}

// UpsertDevice stores/updates the user's public identity keys and registration id.
func (s *Store) UpsertDevice(ctx context.Context, userID string, registrationID int32, identityKeyEd, identityKeyX []byte) error {
	_, err := s.pool.Exec(ctx,
		`INSERT INTO devices (user_id, registration_id, identity_key_ed, identity_key_x, updated_at)
		 VALUES ($1, $2, $3, $4, now())
		 ON CONFLICT (user_id) DO UPDATE
		   SET registration_id = EXCLUDED.registration_id,
		       identity_key_ed = EXCLUDED.identity_key_ed,
		       identity_key_x = EXCLUDED.identity_key_x,
		       updated_at = now()`,
		userID, registrationID, identityKeyEd, identityKeyX)
	return err
}

// UpsertSignedPreKey stores/replaces the user's current signed prekey.
func (s *Store) UpsertSignedPreKey(ctx context.Context, userID string, keyID int32, publicKey, signature []byte) error {
	_, err := s.pool.Exec(ctx,
		`INSERT INTO signed_prekeys (user_id, key_id, public_key, signature, created_at)
		 VALUES ($1, $2, $3, $4, now())
		 ON CONFLICT (user_id) DO UPDATE
		   SET key_id = EXCLUDED.key_id,
		       public_key = EXCLUDED.public_key,
		       signature = EXCLUDED.signature,
		       created_at = now()`,
		userID, keyID, publicKey, signature)
	return err
}

// OneTimePreKey is a single uploaded one-time prekey.
type OneTimePreKey struct {
	KeyID     int32
	PublicKey []byte
}

// AddOneTimePreKeys replaces a batch of one-time prekeys. On key-id conflict the
// public key is overwritten: when a client regenerates its identity (e.g. on
// re-login) and re-uploads, the server must serve the NEW public keys, otherwise
// peers would do X3DH against stale prekeys whose private halves no longer exist,
// and decryption would fail.
func (s *Store) AddOneTimePreKeys(ctx context.Context, userID string, keys []OneTimePreKey) error {
	batch := &pgx.Batch{}
	for _, k := range keys {
		batch.Queue(
			`INSERT INTO one_time_prekeys (user_id, key_id, public_key)
			 VALUES ($1, $2, $3)
			 ON CONFLICT (user_id, key_id) DO UPDATE SET public_key = EXCLUDED.public_key`,
			userID, k.KeyID, k.PublicKey)
	}
	br := s.pool.SendBatch(ctx, batch)
	defer br.Close()
	for range keys {
		if _, err := br.Exec(); err != nil {
			return err
		}
	}
	return nil
}

// CountOneTimePreKeys reports how many one-time prekeys remain for a user, so the
// client can top up when running low.
func (s *Store) CountOneTimePreKeys(ctx context.Context, userID string) (int, error) {
	var n int
	err := s.pool.QueryRow(ctx, `SELECT count(*) FROM one_time_prekeys WHERE user_id = $1`, userID).Scan(&n)
	return n, err
}

// FetchPreKeyBundle returns the target user's bundle, atomically consuming one
// one-time prekey (if any remain). Returns ErrNotFound if the user has no
// device/identity registered.
func (s *Store) FetchPreKeyBundle(ctx context.Context, userID string) (PreKeyBundle, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return PreKeyBundle{}, err
	}
	defer tx.Rollback(ctx)

	var b PreKeyBundle
	b.UserID = userID
	err = tx.QueryRow(ctx,
		`SELECT registration_id, identity_key_ed, identity_key_x
		 FROM devices WHERE user_id = $1`, userID,
	).Scan(&b.RegistrationID, &b.IdentityKeyEd, &b.IdentityKeyX)
	if errors.Is(err, pgx.ErrNoRows) {
		return PreKeyBundle{}, ErrNotFound
	} else if err != nil {
		return PreKeyBundle{}, err
	}

	err = tx.QueryRow(ctx,
		`SELECT key_id, public_key, signature FROM signed_prekeys WHERE user_id = $1`, userID,
	).Scan(&b.SignedPreKeyID, &b.SignedPreKey, &b.SignedPreKeySig)
	if errors.Is(err, pgx.ErrNoRows) {
		return PreKeyBundle{}, ErrNotFound
	} else if err != nil {
		return PreKeyBundle{}, err
	}

	// Consume one one-time prekey if available.
	err = tx.QueryRow(ctx,
		`DELETE FROM one_time_prekeys
		 WHERE (user_id, key_id) IN (
		   SELECT user_id, key_id FROM one_time_prekeys
		   WHERE user_id = $1
		   ORDER BY key_id
		   LIMIT 1
		   FOR UPDATE SKIP LOCKED
		 )
		 RETURNING key_id, public_key`, userID,
	).Scan(&b.OneTimePreKeyID, &b.OneTimePreKey)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		b.HasOneTimePreKey = false
	case err != nil:
		return PreKeyBundle{}, err
	default:
		b.HasOneTimePreKey = true
	}

	if err := tx.Commit(ctx); err != nil {
		return PreKeyBundle{}, err
	}
	return b, nil
}
