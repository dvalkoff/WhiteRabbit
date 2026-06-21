package api

import (
	"net/http"

	"github.com/coder/websocket"
)

// handleWS authenticates via the ?token= query param (the WS handshake can't
// reliably carry custom auth headers from all clients) and hands the socket to
// the hub.
func (a *API) handleWS(w http.ResponseWriter, r *http.Request) {
	token := r.URL.Query().Get("token")
	uid, err := a.tokens.Verify(token, "access")
	if err != nil {
		writeError(w, http.StatusUnauthorized, "invalid token")
		return
	}

	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		// Tighten in production to your app's origins.
		InsecureSkipVerify: true,
	})
	if err != nil {
		a.log.Warn("ws accept failed", "err", err)
		return
	}

	// Serve blocks until the connection ends.
	a.hub.Serve(r.Context(), uid, conn)
}
