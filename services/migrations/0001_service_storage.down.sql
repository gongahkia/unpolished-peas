BEGIN;

DROP TABLE IF EXISTS service_relay_allocations;
DROP TABLE IF EXISTS service_match_participants;
DROP TABLE IF EXISTS service_matches;
DROP TABLE IF EXISTS service_lobby_memberships;
DROP TABLE IF EXISTS service_lobbies;
DROP TABLE IF EXISTS service_sessions;
DROP TABLE IF EXISTS service_identities;

DELETE FROM service_schema_migrations WHERE version = :'migration_version';

COMMIT;
