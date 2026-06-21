package api

import (
	"net/http"
	"strings"

	"github.com/whiterabbit/server/internal/auth"
	"github.com/whiterabbit/server/internal/store"
)

// handleUpdateMe updates profile fields (nickname and/or photo). Identity keys
// are untouched — only display metadata changes.
func (a *API) handleUpdateMe(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Nickname *string `json:"nickname"`
		PhotoURL *string `json:"photo_url"`
	}
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	uid := userID(r)
	ctx := r.Context()

	if req.Nickname != nil {
		nick := strings.TrimSpace(*req.Nickname)
		if len(nick) < 3 {
			writeError(w, http.StatusBadRequest, "nickname must be >=3 chars")
			return
		}
		if err := a.store.UpdateNickname(ctx, uid, nick); err != nil {
			if store.IsUniqueViolation(err) {
				writeError(w, http.StatusConflict, "nickname already taken")
				return
			}
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
	}
	if req.PhotoURL != nil {
		if err := a.store.UpdatePhoto(ctx, uid, *req.PhotoURL); err != nil {
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
	}

	u, err := a.store.GetUserByID(ctx, uid)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}
	writeJSON(w, http.StatusOK, userView{ID: u.ID, Nickname: u.Nickname, PhotoURL: u.PhotoURL})
}

// handleChangePassword verifies the current password and sets a new one.
func (a *API) handleChangePassword(w http.ResponseWriter, r *http.Request) {
	var req struct {
		OldPassword string `json:"old_password"`
		NewPassword string `json:"new_password"`
	}
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	if len(req.NewPassword) < 8 {
		writeError(w, http.StatusBadRequest, "new password must be >=8 chars")
		return
	}
	uid := userID(r)
	u, err := a.store.GetUserByID(r.Context(), uid)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}
	if err := auth.VerifyPassword(req.OldPassword, u.PasswordHash); err != nil {
		writeError(w, http.StatusUnauthorized, "current password is incorrect")
		return
	}
	hash, err := auth.HashPassword(req.NewPassword)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}
	if err := a.store.UpdatePassword(r.Context(), uid, hash); err != nil {
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
