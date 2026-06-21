-- Users: account identity. Password is argon2id-hashed; the server never sees
-- any message plaintext or private keys.
CREATE TABLE users (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    nickname      TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    photo_url     TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- One device per user in v1. Holds the public identity keys other users need
-- for X3DH. identity_key_ed verifies signatures; identity_key_x is the DH key.
CREATE TABLE devices (
    user_id         UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    registration_id INTEGER NOT NULL,
    identity_key_ed BYTEA NOT NULL,
    identity_key_x  BYTEA NOT NULL,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Current signed prekey (public), signed by the user's Ed25519 identity key.
CREATE TABLE signed_prekeys (
    user_id    UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    key_id     INTEGER NOT NULL,
    public_key BYTEA NOT NULL,
    signature  BYTEA NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- One-time prekeys (public). Each is consumed (deleted) when a peer fetches a
-- bundle to start a session.
CREATE TABLE one_time_prekeys (
    user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    key_id     INTEGER NOT NULL,
    public_key BYTEA NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, key_id)
);

-- Encrypted message queue for store-and-forward. ciphertext is opaque Double
-- Ratchet output; the server cannot read it. Rows are retained until delivered
-- (retention policy is a later decision).
CREATE TABLE messages (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sender_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    recipient_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    ciphertext   BYTEA NOT NULL,
    msg_type     INTEGER NOT NULL DEFAULT 1,
    is_prekey    BOOLEAN NOT NULL DEFAULT FALSE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    delivered_at TIMESTAMPTZ
);

CREATE INDEX idx_messages_recipient_undelivered
    ON messages (recipient_id, created_at)
    WHERE delivered_at IS NULL;
