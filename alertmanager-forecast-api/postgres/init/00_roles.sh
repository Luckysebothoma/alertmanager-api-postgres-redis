#!/bin/sh
set -e

# Least-privilege roles, matching the hardened admin/monitoring/backup
# pattern. Passwords come in via _FILE env vars (Swarm secrets) so nothing
# sensitive lands in `docker service inspect` output.
read_secret() {
  var_file="$1"
  eval "path=\$$var_file"
  if [ -n "$path" ] && [ -f "$path" ]; then cat "$path"; fi
}

APP_PW="$(read_secret APP_DB_PASSWORD_FILE)"
MON_PW="$(read_secret MONITORING_DB_PASSWORD_FILE)"
BAK_PW="$(read_secret BACKUP_DB_PASSWORD_FILE)"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
  DO \$\$
  BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_user') THEN
      CREATE ROLE app_user LOGIN PASSWORD '${APP_PW}';
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'monitoring_ro') THEN
      CREATE ROLE monitoring_ro LOGIN PASSWORD '${MON_PW}';
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'backup_ro') THEN
      CREATE ROLE backup_ro LOGIN PASSWORD '${BAK_PW}';
    END IF;
  END
  \$\$;

  GRANT CONNECT ON DATABASE ${POSTGRES_DB} TO app_user, monitoring_ro, backup_ro;
  GRANT USAGE, CREATE ON SCHEMA public TO app_user;
  GRANT USAGE ON SCHEMA public TO monitoring_ro, backup_ro;
  GRANT pg_monitor TO monitoring_ro;

  ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE ON TABLES TO app_user;
  ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT ON TABLES TO monitoring_ro, backup_ro;
EOSQL
