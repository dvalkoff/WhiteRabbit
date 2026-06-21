package api

import (
	"net/http"
	"strings"
)

// handleUploadURL returns a fresh object key and a presigned PUT URL the client
// uses to upload an encrypted blob directly to object storage.
func (a *API) handleUploadURL(w http.ResponseWriter, r *http.Request) {
	key, putURL, err := a.files.NewUploadURL(r.Context())
	if err != nil {
		a.log.Error("upload url", "err", err)
		writeError(w, http.StatusInternalServerError, "could not create upload url")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"key":        key,
		"url":        putURL,
		"expires_in": a.files.ExpirySeconds(),
	})
}

// handleDownloadURL returns a presigned GET URL for an existing blob key.
func (a *API) handleDownloadURL(w http.ResponseWriter, r *http.Request) {
	key := strings.TrimSpace(r.URL.Query().Get("key"))
	if key == "" {
		writeError(w, http.StatusBadRequest, "key required")
		return
	}
	getURL, err := a.files.DownloadURL(r.Context(), key)
	if err != nil {
		a.log.Error("download url", "err", err)
		writeError(w, http.StatusInternalServerError, "could not create download url")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"url":        getURL,
		"expires_in": a.files.ExpirySeconds(),
	})
}
