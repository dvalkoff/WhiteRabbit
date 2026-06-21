// Package api wires the HTTP handlers: auth, prekey distribution, search, and
// the websocket upgrade endpoint.
package api

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"strings"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"

	"github.com/whiterabbit/server/internal/auth"
	"github.com/whiterabbit/server/internal/store"
	"github.com/whiterabbit/server/internal/ws"
)

type ctxKey string

const userIDKey ctxKey = "userID"

// API holds dependencies shared by handlers.
type API struct {
	store  *store.Store
	tokens *auth.TokenManager
	hub    *ws.Hub
	log    *slog.Logger
}

// New constructs the API.
func New(st *store.Store, tokens *auth.TokenManager, hub *ws.Hub, log *slog.Logger) *API {
	return &API{store: st, tokens: tokens, hub: hub, log: log}
}

// Routes returns the configured HTTP handler.
func (a *API) Routes() http.Handler {
	r := chi.NewRouter()
	r.Use(middleware.Recoverer)
	r.Use(middleware.RealIP)

	r.Get("/healthz", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok")) })
	r.Get("/readyz", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ready")) })

	// Public auth endpoints.
	r.Post("/v1/register", a.handleRegister)
	r.Post("/v1/login", a.handleLogin)
	r.Post("/v1/refresh", a.handleRefresh)

	// Authenticated endpoints.
	r.Group(func(r chi.Router) {
		r.Use(a.requireAuth)
		r.Post("/v1/keys", a.handleUploadKeys)
		r.Get("/v1/keys/{userID}", a.handleFetchBundle)
		r.Get("/v1/keys/count", a.handleKeyCount)
		r.Get("/v1/users/search", a.handleSearchUsers)
		r.Get("/v1/users/{userID}", a.handleGetUser)
		r.Get("/v1/me", a.handleMe)
	})

	// Websocket upgrade authenticates via ?token= (browsers/clients can't set
	// custom headers on the WS handshake reliably).
	r.Get("/v1/ws", a.handleWS)

	return r
}

// requireAuth validates the Bearer access token and injects the user id.
func (a *API) requireAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := r.Header.Get("Authorization")
		token, ok := strings.CutPrefix(h, "Bearer ")
		if !ok {
			writeError(w, http.StatusUnauthorized, "missing bearer token")
			return
		}
		userID, err := a.tokens.Verify(token, "access")
		if err != nil {
			writeError(w, http.StatusUnauthorized, "invalid token")
			return
		}
		ctx := context.WithValue(r.Context(), userIDKey, userID)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

func userID(r *http.Request) string {
	v, _ := r.Context().Value(userIDKey).(string)
	return v
}

// --- JSON helpers ---

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

func decodeJSON(r *http.Request, v any) error {
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	return dec.Decode(v)
}
