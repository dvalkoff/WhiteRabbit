package api

import (
	"net/http"

	"github.com/go-chi/chi/v5"

	"github.com/whiterabbit/server/internal/store"
)

type groupView struct {
	ID       string     `json:"id"`
	Name     string     `json:"name"`
	PhotoURL string     `json:"photo_url,omitempty"`
	OwnerID  string     `json:"owner_id"`
	Members  []userView `json:"members"`
}

func (a *API) groupWithMembers(w http.ResponseWriter, r *http.Request, g store.Group) {
	members, err := a.store.GetMembers(r.Context(), g.ID)
	if err != nil {
		a.log.Error("group members", "err", err)
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}
	mv := make([]userView, len(members))
	for i, m := range members {
		mv[i] = userView{ID: m.ID, Nickname: m.Nickname, PhotoURL: m.PhotoURL}
	}
	writeJSON(w, http.StatusOK, groupView{
		ID: g.ID, Name: g.Name, PhotoURL: g.PhotoURL, OwnerID: g.OwnerID, Members: mv,
	})
}

func (a *API) handleCreateGroup(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Name      string   `json:"name"`
		MemberIDs []string `json:"member_ids"`
	}
	if err := decodeJSON(r, &req); err != nil || req.Name == "" {
		writeError(w, http.StatusBadRequest, "name required")
		return
	}
	g, err := a.store.CreateGroup(r.Context(), req.Name, userID(r), req.MemberIDs)
	if err != nil {
		a.log.Error("create group", "err", err)
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}
	a.groupWithMembers(w, r, g)
}

func (a *API) handleListGroups(w http.ResponseWriter, r *http.Request) {
	groups, err := a.store.ListGroupsForUser(r.Context(), userID(r))
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}
	out := make([]groupView, 0, len(groups))
	for _, g := range groups {
		members, err := a.store.GetMembers(r.Context(), g.ID)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
		mv := make([]userView, len(members))
		for i, m := range members {
			mv[i] = userView{ID: m.ID, Nickname: m.Nickname, PhotoURL: m.PhotoURL}
		}
		out = append(out, groupView{ID: g.ID, Name: g.Name, PhotoURL: g.PhotoURL, OwnerID: g.OwnerID, Members: mv})
	}
	writeJSON(w, http.StatusOK, out)
}

// requireMember loads the group and verifies the caller belongs to it.
func (a *API) requireMember(w http.ResponseWriter, r *http.Request) (store.Group, bool) {
	groupID := chi.URLParam(r, "groupID")
	g, err := a.store.GetGroup(r.Context(), groupID)
	if err != nil {
		writeError(w, http.StatusNotFound, "group not found")
		return store.Group{}, false
	}
	ok, err := a.store.IsMember(r.Context(), groupID, userID(r))
	if err != nil || !ok {
		writeError(w, http.StatusForbidden, "not a member")
		return store.Group{}, false
	}
	return g, true
}

func (a *API) handleGetGroup(w http.ResponseWriter, r *http.Request) {
	g, ok := a.requireMember(w, r)
	if !ok {
		return
	}
	a.groupWithMembers(w, r, g)
}

func (a *API) handleAddMember(w http.ResponseWriter, r *http.Request) {
	g, ok := a.requireMember(w, r)
	if !ok {
		return
	}
	var req struct {
		UserID string `json:"user_id"`
	}
	if err := decodeJSON(r, &req); err != nil || req.UserID == "" {
		writeError(w, http.StatusBadRequest, "user_id required")
		return
	}
	if err := a.store.AddMember(r.Context(), g.ID, req.UserID); err != nil {
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}
	a.groupWithMembers(w, r, g)
}

func (a *API) handleRemoveMember(w http.ResponseWriter, r *http.Request) {
	g, ok := a.requireMember(w, r)
	if !ok {
		return
	}
	target := chi.URLParam(r, "userID")
	// Only the owner may remove others; anyone may remove (leave) themselves.
	if target != userID(r) && g.OwnerID != userID(r) {
		writeError(w, http.StatusForbidden, "only the owner can remove members")
		return
	}
	if err := a.store.RemoveMember(r.Context(), g.ID, target); err != nil {
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}
	a.groupWithMembers(w, r, g)
}
