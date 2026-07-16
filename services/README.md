# minna-san services deployment

Copy `config/deploy.zon.example` to `/etc/minna-san-services/deploy.zon`; keep `UP_SERVICES_DATABASE_URL` only in the operator-managed environment or secret store, never in ZON or Git.

Run `script/services_bootstrap_db.sh "$UP_SERVICES_DATABASE_URL"` before first deployment. `GET /healthz` reports process liveness; `GET /readyz` checks PostgreSQL with `SELECT 1` and a TCP connection to the configured relay. Runtime logs contain only bind and HTTP status data; engine telemetry is rejected by configuration.

`deploy/minna-san-services.service` is a systemd unit template with an external environment file and read-only secret mount.
