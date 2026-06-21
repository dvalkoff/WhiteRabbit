# WhiteRabbit

End-to-end encrypted, real-time, horizontally-scalable messenger.

- **Backend:** Go relay (auth + prekey distribution + encrypted message queue),
  PostgreSQL, Redis (cross-instance fan-out), MinIO (encrypted blobs). The server
  **never sees plaintext or private keys** — it stores and relays ciphertext only.
- **Client:** native iOS (SwiftUI).
- **E2E crypto:** our own **X3DH + Double Ratchet** built on Apple **CryptoKit**
  (client) — the Signal protocol design assembled from first-party, audited
  primitives, with no third-party crypto dependency.
- **Transport:** WebSocket + protobuf; scales across instances via Redis Pub/Sub
  with **no sticky sessions** (any instance can hold any connection).

This is **Phase 1**: registration/login, 1:1 real-time E2E text chat, a chat feed
sorted by latest activity, and offline store-and-forward. Files/images + search
(Phase 2) and group chats + profile settings (Phase 3) are planned next.

## Layout

```
proto/                 protobuf wire schema (source of truth)
server/                Go backend (relay)
  cmd/server           entrypoint
  internal/            api, ws, auth, store, relay, config, pb
  migrations/          SQL migrations (embedded, auto-applied on boot)
ios/
  WhiteRabbitKit/      dependency-free, unit-tested E2E crypto core (CryptoKit)
  WhiteRabbitApp/      SwiftUI app (networking + UI)
  project.yml          XcodeGen spec
docker-compose.yml     postgres + redis + minio + server
```

## Run the backend

```bash
cp .env.example .env
docker compose up --build            # single instance
docker compose up --build --scale server=2   # two instances (proves cross-instance routing)
```

Server listens on `:8080` (mapped to host `8080-8090` when scaled). Migrations run
automatically on boot. Health check: `curl localhost:8080/healthz`.

## Run the iOS app

Requires Xcode 16+ and [XcodeGen](https://github.com/yonki/XcodeGen)
(`brew install xcodegen`).

```bash
cd ios
xcodegen generate
open WhiteRabbit.xcodeproj
```

Build & run on the iOS Simulator. The app talks to `http://localhost:8080` by
default (override with the `WR_BASE_URL` env var in the scheme). To test 1:1 chat,
run two simulators (or a simulator + device), register two accounts, search for
the other nickname, and start chatting.

### Regenerating protobuf

Go: `protoc --proto_path=proto --go_out=server/internal/pb --go_opt=paths=source_relative proto/messenger.proto`

Swift: generate with a `protoc-gen-swift` whose version matches the pinned
`SwiftProtobuf` (1.31.0) in `ios/project.yml`, into `ios/WhiteRabbitApp/Generated`.

## Tests

```bash
cd server && go test ./...                 # backend unit tests
cd ios/WhiteRabbitKit && swift test        # E2E crypto: X3DH, ratchet, out-of-order, tamper
```

## Phase 1 known simplifications (tracked for later)

- One device per user; identity/prekeys are regenerated per login and kept in
  memory (no Keychain persistence yet).
- Local message history is in-memory (GRDB-backed persistence comes with Phase 2
  search).
- WebSocket origin check is permissive in dev (`InsecureSkipVerify`); lock down
  for production.
