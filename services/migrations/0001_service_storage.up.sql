BEGIN;

CREATE TABLE service_identities (
    id uuid PRIMARY KEY,
    token_hash bytea NOT NULL UNIQUE CHECK (octet_length(token_hash) = 32),
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz,
    CHECK (expires_at > created_at),
    CHECK (revoked_at IS NULL OR revoked_at >= created_at)
);

CREATE TABLE service_sessions (
    id uuid PRIMARY KEY,
    identity_id uuid NOT NULL REFERENCES service_identities (id) ON DELETE CASCADE,
    token_hash bytea NOT NULL UNIQUE CHECK (octet_length(token_hash) = 32),
    issued_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz,
    CHECK (expires_at > issued_at),
    CHECK (revoked_at IS NULL OR revoked_at >= issued_at)
);

CREATE INDEX service_sessions_identity_active_idx
    ON service_sessions (identity_id, expires_at)
    WHERE revoked_at IS NULL;

CREATE TABLE service_lobbies (
    id uuid PRIMARY KEY,
    owner_identity_id uuid NOT NULL REFERENCES service_identities (id) ON DELETE RESTRICT,
    status text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'closed', 'expired')),
    max_members smallint NOT NULL CHECK (max_members BETWEEN 1 AND 64),
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    expires_at timestamptz NOT NULL,
    closed_at timestamptz,
    CHECK (expires_at > created_at),
    CHECK (closed_at IS NULL OR closed_at >= created_at)
);

CREATE TABLE service_lobby_memberships (
    id uuid PRIMARY KEY,
    lobby_id uuid NOT NULL REFERENCES service_lobbies (id) ON DELETE CASCADE,
    identity_id uuid NOT NULL REFERENCES service_identities (id) ON DELETE CASCADE,
    role text NOT NULL CHECK (role IN ('owner', 'member')),
    joined_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    left_at timestamptz,
    CHECK (left_at IS NULL OR left_at >= joined_at)
);

CREATE UNIQUE INDEX service_lobby_memberships_active_identity_idx
    ON service_lobby_memberships (lobby_id, identity_id)
    WHERE left_at IS NULL;

CREATE UNIQUE INDEX service_lobby_memberships_active_owner_idx
    ON service_lobby_memberships (lobby_id)
    WHERE role = 'owner' AND left_at IS NULL;

CREATE TABLE service_matches (
    id uuid PRIMARY KEY,
    lobby_id uuid REFERENCES service_lobbies (id) ON DELETE RESTRICT,
    status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'active', 'completed', 'cancelled')),
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    started_at timestamptz,
    finished_at timestamptz,
    bootstrap_token_hash bytea UNIQUE CHECK (bootstrap_token_hash IS NULL OR octet_length(bootstrap_token_hash) = 32),
    CHECK (started_at IS NULL OR started_at >= created_at),
    CHECK (finished_at IS NULL OR (started_at IS NOT NULL AND finished_at >= started_at))
);

CREATE TABLE service_match_participants (
    match_id uuid NOT NULL REFERENCES service_matches (id) ON DELETE CASCADE,
    identity_id uuid NOT NULL REFERENCES service_identities (id) ON DELETE RESTRICT,
    role text NOT NULL CHECK (role IN ('host', 'client')),
    joined_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    left_at timestamptz,
    PRIMARY KEY (match_id, identity_id),
    CHECK (left_at IS NULL OR left_at >= joined_at)
);

CREATE TABLE service_relay_allocations (
    id uuid PRIMARY KEY,
    match_id uuid NOT NULL REFERENCES service_matches (id) ON DELETE CASCADE,
    issued_identity_id uuid NOT NULL REFERENCES service_identities (id) ON DELETE RESTRICT,
    route_token_hash bytea NOT NULL UNIQUE CHECK (octet_length(route_token_hash) = 32),
    endpoint text NOT NULL CHECK (length(endpoint) BETWEEN 1 AND 255),
    max_connections smallint NOT NULL CHECK (max_connections BETWEEN 1 AND 64),
    max_bandwidth_kbps integer NOT NULL CHECK (max_bandwidth_kbps BETWEEN 1 AND 1000000),
    allocated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    expires_at timestamptz NOT NULL,
    released_at timestamptz,
    status text NOT NULL DEFAULT 'allocated' CHECK (status IN ('allocated', 'released', 'expired')),
    CHECK (expires_at > allocated_at),
    CHECK (released_at IS NULL OR released_at >= allocated_at)
);

CREATE INDEX service_relay_allocations_match_active_idx
    ON service_relay_allocations (match_id, expires_at)
    WHERE status = 'allocated';

INSERT INTO service_schema_migrations (version, checksum)
VALUES (:'migration_version', :'migration_checksum');

COMMIT;
