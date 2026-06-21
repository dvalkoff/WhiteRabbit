package api

import (
	"errors"
	"net/http"

	"github.com/go-chi/chi/v5"

	"github.com/whiterabbit/server/internal/store"
)

// uploadKeysRequest carries the public X3DH material. []byte fields are
// base64-encoded in JSON automatically by encoding/json.
type uploadKeysRequest struct {
	RegistrationID  int32  `json:"registration_id"`
	IdentityKeyEd   []byte `json:"identity_key_ed"`
	IdentityKeyX    []byte `json:"identity_key_x"`
	SignedPreKeyID  int32  `json:"signed_prekey_id"`
	SignedPreKey    []byte `json:"signed_prekey"`
	SignedPreKeySig []byte `json:"signed_prekey_sig"`
	OneTimePreKeys  []struct {
		KeyID     int32  `json:"key_id"`
		PublicKey []byte `json:"public_key"`
	} `json:"one_time_prekeys"`
}

func (a *API) handleUploadKeys(w http.ResponseWriter, r *http.Request) {
	uid := userID(r)
	var req uploadKeysRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	if len(req.IdentityKeyEd) == 0 || len(req.IdentityKeyX) == 0 || len(req.SignedPreKey) == 0 {
		writeError(w, http.StatusBadRequest, "missing required keys")
		return
	}

	ctx := r.Context()
	if err := a.store.UpsertDevice(ctx, uid, req.RegistrationID, req.IdentityKeyEd, req.IdentityKeyX); err != nil {
		a.log.Error("upsert device", "err", err)
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}
	if err := a.store.UpsertSignedPreKey(ctx, uid, req.SignedPreKeyID, req.SignedPreKey, req.SignedPreKeySig); err != nil {
		a.log.Error("upsert signed prekey", "err", err)
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}
	if len(req.OneTimePreKeys) > 0 {
		keys := make([]store.OneTimePreKey, len(req.OneTimePreKeys))
		for i, k := range req.OneTimePreKeys {
			keys[i] = store.OneTimePreKey{KeyID: k.KeyID, PublicKey: k.PublicKey}
		}
		if err := a.store.AddOneTimePreKeys(ctx, uid, keys); err != nil {
			a.log.Error("add one-time prekeys", "err", err)
			writeError(w, http.StatusInternalServerError, "internal error")
			return
		}
	}
	w.WriteHeader(http.StatusNoContent)
}

type bundleResponse struct {
	UserID           string `json:"user_id"`
	RegistrationID   int32  `json:"registration_id"`
	IdentityKeyEd    []byte `json:"identity_key_ed"`
	IdentityKeyX     []byte `json:"identity_key_x"`
	SignedPreKeyID   int32  `json:"signed_prekey_id"`
	SignedPreKey     []byte `json:"signed_prekey"`
	SignedPreKeySig  []byte `json:"signed_prekey_sig"`
	HasOneTimePreKey bool   `json:"has_one_time_prekey"`
	OneTimePreKeyID  int32  `json:"one_time_prekey_id"`
	OneTimePreKey    []byte `json:"one_time_prekey"`
}

func (a *API) handleFetchBundle(w http.ResponseWriter, r *http.Request) {
	target := chi.URLParam(r, "userID")
	b, err := a.store.FetchPreKeyBundle(r.Context(), target)
	if err != nil {
		if errors.Is(err, store.ErrNotFound) {
			writeError(w, http.StatusNotFound, "no key bundle for user")
			return
		}
		a.log.Error("fetch bundle", "err", err)
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}
	writeJSON(w, http.StatusOK, bundleResponse{
		UserID:           b.UserID,
		RegistrationID:   b.RegistrationID,
		IdentityKeyEd:    b.IdentityKeyEd,
		IdentityKeyX:     b.IdentityKeyX,
		SignedPreKeyID:   b.SignedPreKeyID,
		SignedPreKey:     b.SignedPreKey,
		SignedPreKeySig:  b.SignedPreKeySig,
		HasOneTimePreKey: b.HasOneTimePreKey,
		OneTimePreKeyID:  b.OneTimePreKeyID,
		OneTimePreKey:    b.OneTimePreKey,
	})
}

func (a *API) handleKeyCount(w http.ResponseWriter, r *http.Request) {
	n, err := a.store.CountOneTimePreKeys(r.Context(), userID(r))
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]int{"one_time_prekeys": n})
}
