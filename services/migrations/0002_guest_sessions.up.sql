BEGIN;

CREATE FUNCTION service_issue_guest_session(
    p_identity_id uuid,
    p_identity_token_hash bytea,
    p_identity_expires_at timestamptz,
    p_session_id uuid,
    p_session_token_hash bytea,
    p_session_expires_at timestamptz
) RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
    INSERT INTO service_identities (id, token_hash, expires_at)
    VALUES (p_identity_id, p_identity_token_hash, p_identity_expires_at);
    INSERT INTO service_sessions (id, identity_id, token_hash, expires_at)
    VALUES (p_session_id, p_identity_id, p_session_token_hash, p_session_expires_at);
END;
$function$;

CREATE FUNCTION service_validate_guest_session(p_session_token_hash bytea)
RETURNS TABLE (session_id uuid, identity_id uuid, expires_at timestamptz)
LANGUAGE sql
STABLE
AS $function$
    SELECT session.id, session.identity_id, session.expires_at
    FROM service_sessions AS session
    JOIN service_identities AS identity ON identity.id = session.identity_id
    WHERE session.token_hash = p_session_token_hash
      AND session.revoked_at IS NULL
      AND session.expires_at > CURRENT_TIMESTAMP
      AND identity.revoked_at IS NULL
      AND identity.expires_at > CURRENT_TIMESTAMP;
$function$;

CREATE FUNCTION service_rotate_guest_session(
    p_session_id uuid,
    p_current_token_hash bytea,
    p_next_session_id uuid,
    p_next_token_hash bytea,
    p_next_expires_at timestamptz
) RETURNS uuid
LANGUAGE plpgsql
AS $function$
DECLARE
    v_identity_id uuid;
BEGIN
    UPDATE service_sessions
    SET revoked_at = CURRENT_TIMESTAMP
    WHERE id = p_session_id
      AND token_hash = p_current_token_hash
      AND revoked_at IS NULL
      AND expires_at > CURRENT_TIMESTAMP
    RETURNING identity_id INTO v_identity_id;
    IF v_identity_id IS NULL THEN RAISE EXCEPTION 'guest session is unavailable'; END IF;
    INSERT INTO service_sessions (id, identity_id, token_hash, expires_at)
    VALUES (p_next_session_id, v_identity_id, p_next_token_hash, p_next_expires_at);
    RETURN p_next_session_id;
END;
$function$;

CREATE FUNCTION service_revoke_guest_session(p_session_id uuid, p_session_token_hash bytea)
RETURNS boolean
LANGUAGE plpgsql
AS $function$
DECLARE
    v_revoked uuid;
BEGIN
    UPDATE service_sessions
    SET revoked_at = CURRENT_TIMESTAMP
    WHERE id = p_session_id
      AND token_hash = p_session_token_hash
      AND revoked_at IS NULL
    RETURNING id INTO v_revoked;
    RETURN v_revoked IS NOT NULL;
END;
$function$;

INSERT INTO service_schema_migrations (version, checksum)
VALUES (:'migration_version', :'migration_checksum');

COMMIT;
