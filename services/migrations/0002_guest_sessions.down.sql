BEGIN;

DROP FUNCTION IF EXISTS service_revoke_guest_session(uuid, bytea);
DROP FUNCTION IF EXISTS service_rotate_guest_session(uuid, bytea, uuid, bytea, timestamptz);
DROP FUNCTION IF EXISTS service_validate_guest_session(bytea);
DROP FUNCTION IF EXISTS service_issue_guest_session(uuid, bytea, timestamptz, uuid, bytea, timestamptz);

DELETE FROM service_schema_migrations WHERE version = :'migration_version';

COMMIT;
