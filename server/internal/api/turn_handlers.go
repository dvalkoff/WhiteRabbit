package api

import (
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"fmt"
	"net/http"
	"time"
)

// handleTURN returns WebRTC ICE servers (STUN + TURN). TURN uses coturn's
// shared-secret (REST) scheme: a short-lived username "<expiry>:<userID>" with
// credential = base64(HMAC-SHA1(secret, username)). The secret is shared only
// between this server and coturn; clients never see it.
func (a *API) handleTURN(w http.ResponseWriter, r *http.Request) {
	const ttl = 5 * time.Minute
	expiry := time.Now().Add(ttl).Unix()
	username := fmt.Sprintf("%d:%s", expiry, userID(r))

	mac := hmac.New(sha1.New, []byte(a.turnSecret))
	mac.Write([]byte(username))
	credential := base64.StdEncoding.EncodeToString(mac.Sum(nil))

	iceServers := []map[string]any{
		{"urls": []string{"stun:" + a.turnHost}},
		{
			"urls": []string{
				"turn:" + a.turnHost + "?transport=udp",
				"turn:" + a.turnHost + "?transport=tcp",
			},
			"username":   username,
			"credential": credential,
		},
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ice_servers": iceServers,
		"ttl":         int(ttl.Seconds()),
	})
}
