package api

import (
	"errors"
	"net/http"
	"strings"

	"github.com/whiterabbit/server/internal/auth"
	"github.com/whiterabbit/server/internal/store"
)

type authResponse struct {
	UserID       string `json:"user_id"`
	Nickname     string `json:"nickname"`
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
}

type credentials struct {
	Nickname string `json:"nickname"`
	Password string `json:"password"`
}

func (a *API) handleRegister(w http.ResponseWriter, r *http.Request) {
	var req credentials
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	req.Nickname = strings.TrimSpace(req.Nickname)
	if len(req.Nickname) < 3 || len(req.Password) < 8 {
		writeError(w, http.StatusBadRequest, "nickname must be >=3 chars and password >=8 chars")
		return
	}

	hash, err := auth.HashPassword(req.Password)
	if err != nil {
		a.log.Error("hash password", "err", err)
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}

	u, err := a.store.CreateUser(r.Context(), req.Nickname, hash)
	if err != nil {
		if store.IsUniqueViolation(err) {
			writeError(w, http.StatusConflict, "nickname already taken")
			return
		}
		a.log.Error("create user", "err", err)
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}

	a.issueAndRespond(w, u)
}

func (a *API) handleLogin(w http.ResponseWriter, r *http.Request) {
	var req credentials
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}

	u, err := a.store.GetUserByNickname(r.Context(), strings.TrimSpace(req.Nickname))
	if err != nil {
		if errors.Is(err, store.ErrNotFound) {
			writeError(w, http.StatusUnauthorized, "invalid credentials")
			return
		}
		a.log.Error("get user", "err", err)
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}
	if err := auth.VerifyPassword(req.Password, u.PasswordHash); err != nil {
		writeError(w, http.StatusUnauthorized, "invalid credentials")
		return
	}

	a.issueAndRespond(w, u)
}

func (a *API) handleRefresh(w http.ResponseWriter, r *http.Request) {
	var req struct {
		RefreshToken string `json:"refresh_token"`
	}
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	uid, err := a.tokens.Verify(req.RefreshToken, "refresh")
	if err != nil {
		writeError(w, http.StatusUnauthorized, "invalid refresh token")
		return
	}
	u, err := a.store.GetUserByID(r.Context(), uid)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "invalid refresh token")
		return
	}
	a.issueAndRespond(w, u)
}

func (a *API) issueAndRespond(w http.ResponseWriter, u store.User) {
	access, refresh, err := a.tokens.Issue(u.ID)
	if err != nil {
		a.log.Error("issue tokens", "err", err)
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}
	writeJSON(w, http.StatusOK, authResponse{
		UserID:       u.ID,
		Nickname:     u.Nickname,
		AccessToken:  access,
		RefreshToken: refresh,
	})
}
