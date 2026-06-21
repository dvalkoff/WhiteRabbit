package api

import (
	"net/http"
	"strings"

	"github.com/go-chi/chi/v5"
)

type userView struct {
	ID       string `json:"id"`
	Nickname string `json:"nickname"`
	PhotoURL string `json:"photo_url,omitempty"`
}

func (a *API) handleSearchUsers(w http.ResponseWriter, r *http.Request) {
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	if q == "" {
		writeJSON(w, http.StatusOK, []userView{})
		return
	}
	users, err := a.store.SearchUsers(r.Context(), userID(r), q, 25)
	if err != nil {
		a.log.Error("search users", "err", err)
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}
	out := make([]userView, len(users))
	for i, u := range users {
		out[i] = userView{ID: u.ID, Nickname: u.Nickname, PhotoURL: u.PhotoURL}
	}
	writeJSON(w, http.StatusOK, out)
}

func (a *API) handleMe(w http.ResponseWriter, r *http.Request) {
	u, err := a.store.GetUserByID(r.Context(), userID(r))
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}
	writeJSON(w, http.StatusOK, userView{ID: u.ID, Nickname: u.Nickname, PhotoURL: u.PhotoURL})
}

func (a *API) handleGetUser(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "userID")
	u, err := a.store.GetUserByID(r.Context(), id)
	if err != nil {
		writeError(w, http.StatusNotFound, "user not found")
		return
	}
	writeJSON(w, http.StatusOK, userView{ID: u.ID, Nickname: u.Nickname, PhotoURL: u.PhotoURL})
}
