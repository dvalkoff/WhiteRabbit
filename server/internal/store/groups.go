package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// Group is a group-chat row.
type Group struct {
	ID        string
	Name      string
	PhotoURL  string
	OwnerID   string
	CreatedAt time.Time
}

// CreateGroup creates a group owned by ownerID and adds the owner plus the given
// members. Returns the new group.
func (s *Store) CreateGroup(ctx context.Context, name, ownerID string, memberIDs []string) (Group, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return Group{}, err
	}
	defer tx.Rollback(ctx)

	var g Group
	err = tx.QueryRow(ctx,
		`INSERT INTO groups (name, owner_id) VALUES ($1, $2)
		 RETURNING id, name, COALESCE(photo_url, ''), owner_id, created_at`,
		name, ownerID,
	).Scan(&g.ID, &g.Name, &g.PhotoURL, &g.OwnerID, &g.CreatedAt)
	if err != nil {
		return Group{}, err
	}

	// Owner is always a member; dedupe the rest.
	seen := map[string]bool{ownerID: true}
	batch := &pgx.Batch{}
	batch.Queue(`INSERT INTO group_members (group_id, user_id) VALUES ($1, $2)`, g.ID, ownerID)
	for _, m := range memberIDs {
		if seen[m] {
			continue
		}
		seen[m] = true
		batch.Queue(`INSERT INTO group_members (group_id, user_id) VALUES ($1, $2)
			 ON CONFLICT DO NOTHING`, g.ID, m)
	}
	br := tx.SendBatch(ctx, batch)
	for i := 0; i < len(seen); i++ {
		if _, err := br.Exec(); err != nil {
			br.Close()
			return Group{}, err
		}
	}
	br.Close()

	if err := tx.Commit(ctx); err != nil {
		return Group{}, err
	}
	return g, nil
}

// GetGroup returns a group by id.
func (s *Store) GetGroup(ctx context.Context, groupID string) (Group, error) {
	var g Group
	err := s.pool.QueryRow(ctx,
		`SELECT id, name, COALESCE(photo_url, ''), owner_id, created_at FROM groups WHERE id = $1`, groupID,
	).Scan(&g.ID, &g.Name, &g.PhotoURL, &g.OwnerID, &g.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return Group{}, ErrNotFound
	}
	return g, err
}

// ListGroupsForUser returns the groups a user belongs to.
func (s *Store) ListGroupsForUser(ctx context.Context, userID string) ([]Group, error) {
	rows, err := s.pool.Query(ctx,
		`SELECT g.id, g.name, COALESCE(g.photo_url, ''), g.owner_id, g.created_at
		 FROM groups g
		 JOIN group_members m ON m.group_id = g.id
		 WHERE m.user_id = $1
		 ORDER BY g.created_at DESC`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Group
	for rows.Next() {
		var g Group
		if err := rows.Scan(&g.ID, &g.Name, &g.PhotoURL, &g.OwnerID, &g.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, g)
	}
	return out, rows.Err()
}

// GetMembers returns the member users of a group.
func (s *Store) GetMembers(ctx context.Context, groupID string) ([]User, error) {
	rows, err := s.pool.Query(ctx,
		`SELECT u.id, u.nickname, '', COALESCE(u.photo_url, ''), u.created_at
		 FROM users u
		 JOIN group_members m ON m.user_id = u.id
		 WHERE m.group_id = $1
		 ORDER BY u.nickname`, groupID)
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

// IsMember reports whether a user belongs to a group.
func (s *Store) IsMember(ctx context.Context, groupID, userID string) (bool, error) {
	var exists bool
	err := s.pool.QueryRow(ctx,
		`SELECT EXISTS(SELECT 1 FROM group_members WHERE group_id = $1 AND user_id = $2)`,
		groupID, userID).Scan(&exists)
	return exists, err
}

// AddMember adds a user to a group (idempotent).
func (s *Store) AddMember(ctx context.Context, groupID, userID string) error {
	_, err := s.pool.Exec(ctx,
		`INSERT INTO group_members (group_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`,
		groupID, userID)
	return err
}

// RemoveMember removes a user from a group.
func (s *Store) RemoveMember(ctx context.Context, groupID, userID string) error {
	_, err := s.pool.Exec(ctx,
		`DELETE FROM group_members WHERE group_id = $1 AND user_id = $2`, groupID, userID)
	return err
}
