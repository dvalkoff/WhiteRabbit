package auth

import (
	"errors"
	"fmt"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const (
	accessTokenTTL  = 24 * time.Hour
	refreshTokenTTL = 30 * 24 * time.Hour
)

// TokenManager issues and validates HS256 JWTs.
type TokenManager struct {
	secret []byte
}

// NewTokenManager creates a manager with the given signing secret.
func NewTokenManager(secret string) *TokenManager {
	return &TokenManager{secret: []byte(secret)}
}

type claims struct {
	jwt.RegisteredClaims
	Kind string `json:"knd"` // "access" or "refresh"
}

// Issue returns a signed access and refresh token pair for the user.
func (t *TokenManager) Issue(userID string) (access, refresh string, err error) {
	access, err = t.sign(userID, "access", accessTokenTTL)
	if err != nil {
		return "", "", err
	}
	refresh, err = t.sign(userID, "refresh", refreshTokenTTL)
	if err != nil {
		return "", "", err
	}
	return access, refresh, nil
}

func (t *TokenManager) sign(userID, kind string, ttl time.Duration) (string, error) {
	now := time.Now()
	c := claims{
		RegisteredClaims: jwt.RegisteredClaims{
			Subject:   userID,
			IssuedAt:  jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(now.Add(ttl)),
		},
		Kind: kind,
	}
	return jwt.NewWithClaims(jwt.SigningMethodHS256, c).SignedString(t.secret)
}

// Verify parses a token of the expected kind and returns the user id (subject).
func (t *TokenManager) Verify(token, expectedKind string) (string, error) {
	var c claims
	parsed, err := jwt.ParseWithClaims(token, &c, func(tok *jwt.Token) (any, error) {
		if _, ok := tok.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, fmt.Errorf("unexpected signing method: %v", tok.Header["alg"])
		}
		return t.secret, nil
	})
	if err != nil || !parsed.Valid {
		return "", errors.New("invalid token")
	}
	if c.Kind != expectedKind {
		return "", errors.New("wrong token kind")
	}
	return c.Subject, nil
}
