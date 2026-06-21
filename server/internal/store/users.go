package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// User is an account row.
type User struct {
	ID           string
	Nickname     string
	PasswordHash string
	PhotoURL     string
	CreatedAt    time.Time
}

// CreateUser inserts a new account. The caller passes an already-hashed
// password. Returns ErrNotFound-free errors; nickname uniqueness is enforced by
// the DB (caller should detect duplicate via IsUniqueViolation).
func (s *Store) CreateUser(ctx context.Context, nickname, passwordHash string) (User, error) {
	var u User
	err := s.pool.QueryRow(ctx,
		`INSERT INTO users (nickname, password_hash)
		 VALUES ($1, $2)
		 RETURNING id, nickname, password_hash, COALESCE(photo_url, ''), created_at`,
		nickname, passwordHash,
	).Scan(&u.ID, &u.Nickname, &u.PasswordHash, &u.PhotoURL, &u.CreatedAt)
	return u, err
}

// GetUserByNickname looks up an account by its unique nickname.
func (s *Store) GetUserByNickname(ctx context.Context, nickname string) (User, error) {
	var u User
	err := s.pool.QueryRow(ctx,
		`SELECT id, nickname, password_hash, COALESCE(photo_url, ''), created_at
		 FROM users WHERE nickname = $1`, nickname,
	).Scan(&u.ID, &u.Nickname, &u.PasswordHash, &u.PhotoURL, &u.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return User{}, ErrNotFound
	}
	return u, err
}

// GetUserByID looks up an account by id.
func (s *Store) GetUserByID(ctx context.Context, id string) (User, error) {
	var u User
	err := s.pool.QueryRow(ctx,
		`SELECT id, nickname, password_hash, COALESCE(photo_url, ''), created_at
		 FROM users WHERE id = $1`, id,
	).Scan(&u.ID, &u.Nickname, &u.PasswordHash, &u.PhotoURL, &u.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return User{}, ErrNotFound
	}
	return u, err
}

// UpdatePassword replaces the stored password hash.
func (s *Store) UpdatePassword(ctx context.Context, id, passwordHash string) error {
	_, err := s.pool.Exec(ctx, `UPDATE users SET password_hash = $2 WHERE id = $1`, id, passwordHash)
	return err
}

// UpdateNickname changes the nickname (subject to uniqueness).
func (s *Store) UpdateNickname(ctx context.Context, id, nickname string) error {
	_, err := s.pool.Exec(ctx, `UPDATE users SET nickname = $2 WHERE id = $1`, id, nickname)
	return err
}

// UpdatePhoto sets the profile photo URL.
func (s *Store) UpdatePhoto(ctx context.Context, id, photoURL string) error {
	_, err := s.pool.Exec(ctx, `UPDATE users SET photo_url = $2 WHERE id = $1`, id, photoURL)
	return err
}

// SearchUsers finds accounts whose nickname matches the query (prefix/substring),
// excluding the caller, capped at limit.
func (s *Store) SearchUsers(ctx context.Context, excludeID, query string, limit int) ([]User, error) {
	rows, err := s.pool.Query(ctx,
		`SELECT id, nickname, '', COALESCE(photo_url, ''), created_at
		 FROM users
		 WHERE id <> $1 AND nickname ILIKE '%' || $2 || '%'
		 ORDER BY nickname
		 LIMIT $3`, excludeID, query, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []User
	for rows.Next() {
		var u User
		if err := rows.Scan(&u.ID, &u.Nickname, &u.PasswordHash, &u.PhotoURL, &u.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, u)
	}
	return out, rows.Err()
}
