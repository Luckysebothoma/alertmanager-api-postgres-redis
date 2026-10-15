#!/usr/bin/env bash
# alertmanager-forecast-api-njs.sh
# Node.js (Hono) + Postgres + Redis bridge that ingests Alertmanager webhooks
# (raw or n8n-wrapped) and generic text alerts (e.g. comfy-orchestrator),
# normalizes + stores them for forecast/predictive monitoring.
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Config (override via env)
# ---------------------------------------------------------------------------
STACK_NAME="${STACK_NAME:-alertmanager-forecast-api}"
APP_DIR="${APP_DIR:-./${STACK_NAME}}"
REGISTRY="${REGISTRY:-192.168.0.140:5000}"
IMAGE_NAME="${IMAGE_NAME:-${REGISTRY}/${STACK_NAME}}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
NETWORK_NAME="${NETWORK_NAME:-obs-network}"
API_PORT="${API_PORT:-4400}"
FORCE="${FORCE:-0}"
SKIP_PUSH="${SKIP_PUSH:-0}"
YES="${YES:-0}"

# If APP_DIR already exists, normalize it to an absolute path so every
# subcommand (init/deploy/ps/logs/rm) resolves the same location regardless
# of what the caller's cwd is later changed to.
if [[ -d "$APP_DIR" ]]; then
  APP_DIR="$(cd "$APP_DIR" && pwd)"
fi

log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }
trap 'die "unexpected failure at line $LINENO"' ERR

need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

write_file() {
  local path="$1" content="$2"
  if [[ -f "$path" && "$FORCE" != "1" ]]; then
    log "exists, skipping (FORCE=1 to overwrite): $path"
    return 0
  fi
  printf '%s' "$content" > "$path"
  log "wrote: $path"
}

gen_secret() {
    local secret_path="$1"
    local static_value="$2"

    # Remove the file if it already exists
    if [ -f "$secret_path" ]; then
        rm -f "$secret_path"
    fi

    # Ensure the parent directory exists
    mkdir -p "$(dirname "$secret_path")"

    if [ -n "$static_value" ]; then
        # Use the provided static data
        echo -n "$static_value" > "$secret_path"
    else
        # Fallback to generating a random secret if no static value is given
        openssl rand -base64 32 | tr -d '\n' > "$secret_path"
    fi

    # Secure the file permissions
    chmod 600 "$secret_path"
}

ensure_network() {
  if ! docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
    log "creating overlay network: $NETWORK_NAME"
    docker network create -d overlay --attachable "$NETWORK_NAME" >/dev/null
  fi
}

# ---------------------------------------------------------------------------
# init — scaffold app + schema + secrets, build & push image (idempotent)
# ---------------------------------------------------------------------------
cmd_init() {
  need docker; need openssl

  mkdir -p "$APP_DIR"/{src,postgres/init,secrets}
  APP_DIR="$(cd "$APP_DIR" && pwd)"
  log "app dir: $APP_DIR"

  write_file "$APP_DIR/package.json" '{
  "name": "alertmanager-forecast-api",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "main": "src/server.js",
  "scripts": { "start": "node src/server.js" },
  "dependencies": {
    "hono": "^4.5.0",
    "@hono/node-server": "^1.12.0",
    "pg": "^8.12.0",
    "ioredis": "^5.4.1",
    "prom-client": "^15.1.3"
  }
}
'

  write_file "$APP_DIR/src/secrets.js" 'import { readFileSync } from "node:fs";

// Reads a Docker secret file referenced by <NAME>_FILE, falling back to a
// plain env var if no _FILE path is set. Swarm secrets are mounted under
// /run/secrets/<name>; env_file: is deliberately NOT used anywhere in this
// stack (Swarm silently ignores env_file directives).
export function readSecret(name) {
  const filePath = process.env[`${name}_FILE`];
  if (filePath) {
    try {
      return readFileSync(filePath, "utf8").trim();
    } catch (err) {
      console.error(`[secrets] failed reading ${filePath}: ${err.message}`);
    }
  }
  return process.env[name] ?? null;
}
'

  write_file "$APP_DIR/src/db.js" 'import pg from "pg";
import { readSecret } from "./secrets.js";

const { Pool } = pg;

export const pool = new Pool({
  host: process.env.PG_HOST ?? "postgres",
  port: Number(process.env.PG_PORT ?? 5432),
  user: process.env.PG_USER ?? "app_user",
  password: readSecret("PG_PASSWORD") ?? "",
  database: process.env.PG_DATABASE ?? "forecast",
  max: Number(process.env.PG_POOL_MAX ?? 10),
  idleTimeoutMillis: 30000,
});

pool.on("error", (err) => {
  console.error(`[pg] pool error: ${err.message}`);
});
'

  write_file "$APP_DIR/src/redis.js" 'import Redis from "ioredis";
import { readSecret } from "./secrets.js";

export const redis = new Redis({
  host: process.env.REDIS_HOST ?? "redis",
  port: Number(process.env.REDIS_PORT ?? 6379),
  password: readSecret("REDIS_PASSWORD") ?? undefined,
  retryStrategy: (times) => Math.min(times * 200, 5000),
});

redis.on("error", (err) => console.error(`[redis] ${err.message}`));
'

  write_file "$APP_DIR/src/metrics.js" 'import client from "prom-client";

export const register = new client.Registry();
client.collectDefaultMetrics({ register });

export const alertsReceivedTotal = new client.Counter({
  name: "forecast_api_alerts_received_total",
  help: "Total alerts received, by kind/status/alertname",
  labelNames: ["kind", "status", "alertname"],
  registers: [register],
});

export const webhookDuration = new client.Histogram({
  name: "forecast_api_webhook_duration_seconds",
  help: "Webhook handler duration in seconds",
  labelNames: ["route"],
  registers: [register],
});

// Latest current_value reading per alert series - Prometheus gauges only
// reflect state at scrape time, so this gives you "now", not history.
// For a true trendline of current_value over time, query Postgres directly
// (starts_at/current_value are stored per-alert there).
export const alertCurrentValue = new client.Gauge({
  name: "forecast_api_alert_current_value",
  help: "Latest extracted current_value per alert series",
  labelNames: ["alertname", "instance", "sensor", "chip", "stage"],
  registers: [register],
});

// 1 while firing, 0 once resolved - lets you graph "how many distinct
// series are firing, by stage" over time via sum().
export const alertFiring = new client.Gauge({
  name: "forecast_api_alert_firing",
  help: "1 if this alert series is currently firing, 0 if resolved",
  labelNames: ["alertname", "instance", "sensor", "chip", "stage", "severity"],
  registers: [register],
});
'

  write_file "$APP_DIR/src/normalize.js" '// n8n wraps a single execution payload in an array: [{ headers, body, ... }]
// and sometimes body itself is an array of one. Alertmanager also sends a
// zero-date sentinel ("0001-01-01T00:00:00Z") for endsAt on still-firing
// alerts — that gets normalized to null here.
export function unwrapPayload(raw) {
  const item = Array.isArray(raw) ? raw[0] : raw;
  if (!item) return null;
  const body = Array.isArray(item.body) ? item.body[0] : (item.body ?? item);
  return {
    body,
    headers: item.headers ?? null,
    webhookUrl: item.webhookUrl ?? null,
    executionMode: item.executionMode ?? null,
  };
}

export function classifyEvent(body) {
  if (body && Array.isArray(body.alerts)) return "alertmanager";
  if (body && typeof body.text === "string") return "generic";
  return "unknown";
}

export function extractCurrentValue(description = "") {
  const m = description.match(/Current Value:\s*([\d.]+)%?/i);
  return m?.[1] ? parseFloat(m[1]) : null;
}

export function normalizeAlert(alert, body) {
  const labels = alert?.labels ?? {};
  const annotations = alert?.annotations ?? {};
  const description = annotations.description ?? "";
  const endsAt = alert?.endsAt && !alert.endsAt.startsWith("0001-01-01") ? alert.endsAt : null;
  return {
    receiver: body?.receiver ?? null,
    alertname: labels.alertname ?? "UnknownAlert",
    fingerprint: alert?.fingerprint ?? null,
    status: alert?.status ?? "unknown",
    severity: labels.severity ?? "unknown",
    stage: labels.stage ?? null,
    instance: labels.instance ?? null,
    job: labels.job ?? null,
    chip: labels.chip ?? null,
    sensor: labels.sensor ?? null,
    device: labels.device ?? null,
    fstype: labels.fstype ?? null,
    mountpoint: labels.mountpoint ?? null,
    summary: annotations.summary ?? null,
    description,
    currentValue: extractCurrentValue(description),
    startsAt: alert?.startsAt ?? null,
    endsAt,
    notificationReason: body?.notification_reason ?? null,
    groupKey: body?.groupKey ?? null,
    prometheusUrl: alert?.generatorURL ?? null,
    alertmanagerUrl: body?.externalURL ?? null,
    version: body?.version ?? null,
    isFiring: alert?.status === "firing",
    isResolved: alert?.status === "resolved",
    labels,
    annotations,
  };
}

export function extractGeneric(body) {
  const text = body?.text ?? "";
  const jobId = text.match(/job\s+([a-f0-9-]{36})/i)?.[1] ?? null;
  const mode = text.match(/mode=(\w+)/i)?.[1] ?? null;
  const sourceService = text.match(/^([a-z0-9_-]+)\s+alert:/i)?.[1] ?? null;
  return { message: text, jobId, mode, sourceService };
}
'

  write_file "$APP_DIR/src/server.js" 'import { serve } from "@hono/node-server";
import { Hono } from "hono";
import { pool } from "./db.js";
import { redis } from "./redis.js";
import { register, alertsReceivedTotal, webhookDuration } from "./metrics.js";
import { unwrapPayload, classifyEvent, normalizeAlert, extractGeneric } from "./normalize.js";

const app = new Hono();
const PORT = Number(process.env.PORT ?? 4400);

app.get("/health", async (c) => {
  try {
    await pool.query("SELECT 1");
    await redis.ping();
    return c.json({ status: "ok" });
  } catch (err) {
    return c.json({ status: "degraded", error: err.message }, 503);
  }
});

app.get("/metrics", async (c) => {
  c.header("Content-Type", register.contentType);
  return c.body(await register.metrics());
});

app.post("/webhook/alertmanager", async (c) => {
  const end = webhookDuration.startTimer({ route: "alertmanager" });
  const raw = await c.req.json().catch(() => null);
  if (!raw) { end(); return c.json({ error: "invalid json" }, 400); }

  const unwrapped = unwrapPayload(raw);
  if (!unwrapped?.body) { end(); return c.json({ error: "no payload" }, 400); }
  const { body, headers, webhookUrl, executionMode } = unwrapped;
  const kind = classifyEvent(body);

  const rawInsert = await pool.query(
    `INSERT INTO raw_events (source_agent, webhook_url, execution_mode, event_kind, headers, body)
     VALUES ($1,$2,$3,$4,$5,$6) RETURNING id`,
    [headers?.["user-agent"] ?? null, webhookUrl, executionMode, kind, headers ?? null, body]
  );
  const rawEventId = rawInsert.rows[0].id;

  if (kind === "alertmanager") {
    for (const alert of body.alerts) {
      const n = normalizeAlert(alert, body);
      if (!n.fingerprint || !n.startsAt) continue;
      await pool.query(
        `INSERT INTO alerts (raw_event_id, receiver, alertname, fingerprint, status, severity, stage,
           instance, job, chip, sensor, device, fstype, mountpoint, summary, description, current_value,
           starts_at, ends_at, notification_reason, group_key, prometheus_url, alertmanager_url, version,
           is_firing, is_resolved, labels, annotations)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23,$24,$25,$26,$27,$28)
         ON CONFLICT (fingerprint, starts_at) DO UPDATE SET
           status = EXCLUDED.status, ends_at = EXCLUDED.ends_at, is_firing = EXCLUDED.is_firing,
           is_resolved = EXCLUDED.is_resolved, current_value = EXCLUDED.current_value,
           description = EXCLUDED.description, updated_at = now()`,
        [rawEventId, n.receiver, n.alertname, n.fingerprint, n.status, n.severity, n.stage,
         n.instance, n.job, n.chip, n.sensor, n.device, n.fstype, n.mountpoint, n.summary, n.description,
         n.currentValue, n.startsAt, n.endsAt, n.notificationReason, n.groupKey, n.prometheusUrl,
         n.alertmanagerUrl, n.version, n.isFiring, n.isResolved, n.labels, n.annotations]
      );
      await redis.set(`alert:${n.fingerprint}`, JSON.stringify(n), "EX", 86400);

      alertsReceivedTotal.inc({ kind: "alertmanager", status: n.status, alertname: n.alertname, severity: n.severity, stage: n.stage ?? "none" });

        if (n.currentValue !== null) {
          alertCurrentValue.set(
            { alertname: n.alertname, instance: n.instance ?? "", sensor: n.sensor ?? "", chip: n.chip ?? "", stage: n.stage ?? "none" },
            n.currentValue
          );
        }
        alertFiring.set(
          { alertname: n.alertname, instance: n.instance ?? "", sensor: n.sensor ?? "", chip: n.chip ?? "", stage: n.stage ?? "none", severity: n.severity },
          n.isFiring ? 1 : 0
        );
    }
  } else if (kind === "generic") {
    const g = extractGeneric(body);
    await pool.query(
      `INSERT INTO generic_alerts (raw_event_id, source_service, message, job_id, mode, extracted)
       VALUES ($1,$2,$3,$4,$5,$6)`,
      [rawEventId, g.sourceService, g.message, g.jobId, g.mode, g]
    );
    alertsReceivedTotal.inc({ kind: "generic", status: "n/a", alertname: g.sourceService ?? "unknown" });
  }

  end();
  return c.json({ stored: true, rawEventId, kind }, 202);
});

app.get("/alerts", async (c) => {
  const limit = Math.min(Number(c.req.query("limit") ?? 50), 500);
  const { status, alertname, instance } = c.req.query();
  const clauses = [];
  const params = [];
  if (status)    { params.push(status);    clauses.push(`status = $${params.length}`); }
  if (alertname) { params.push(alertname); clauses.push(`alertname = $${params.length}`); }
  if (instance)  { params.push(instance);  clauses.push(`instance = $${params.length}`); }
  const where = clauses.length ? `WHERE ${clauses.join(" AND ")}` : "";
  params.push(limit);
  const { rows } = await pool.query(
    `SELECT * FROM alerts ${where} ORDER BY starts_at DESC LIMIT $${params.length}`, params
  );
  return c.json(rows);
});

app.get("/alerts/generic", async (c) => {
  const limit = Math.min(Number(c.req.query("limit") ?? 50), 500);
  const { rows } = await pool.query(
    `SELECT * FROM generic_alerts ORDER BY received_at DESC LIMIT $1`, [limit]
  );
  return c.json(rows);
});

const server = serve({ fetch: app.fetch, port: PORT }, (info) => {
  console.log(`[server] listening on ${info.port}`);
});

for (const sig of ["SIGTERM", "SIGINT"]) {
  process.on(sig, async () => {
    console.log(`[server] ${sig} received, shutting down`);
    server.close();
    await pool.end();
    redis.disconnect();
    process.exit(0);
  });
}
'

  write_file "$APP_DIR/Dockerfile" 'FROM node:20-alpine
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm install --omit=dev
COPY src ./src
RUN addgroup -S app && adduser -S app -G app
USER app
ENV NODE_ENV=production
EXPOSE 4400
CMD ["node", "src/server.js"]
'

  write_file "$APP_DIR/.dockerignore" 'node_modules
npm-debug.log
.env
secrets
'

  write_file "$APP_DIR/postgres/init/00_roles.sh" '#!/bin/sh
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
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '"'"'app_user'"'"') THEN
      CREATE ROLE app_user LOGIN PASSWORD '"'"'${APP_PW}'"'"';
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '"'"'monitoring_ro'"'"') THEN
      CREATE ROLE monitoring_ro LOGIN PASSWORD '"'"'${MON_PW}'"'"';
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '"'"'backup_ro'"'"') THEN
      CREATE ROLE backup_ro LOGIN PASSWORD '"'"'${BAK_PW}'"'"';
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
'

  write_file "$APP_DIR/postgres/init/01_schema.sql" 'CREATE TABLE IF NOT EXISTS raw_events (
    id              BIGSERIAL PRIMARY KEY,
    received_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    source_agent    TEXT,
    webhook_url     TEXT,
    execution_mode  TEXT,
    event_kind      TEXT NOT NULL,      -- '"'"'alertmanager'"'"' | '"'"'generic'"'"' | '"'"'unknown'"'"'
    headers         JSONB,
    body            JSONB NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_raw_events_received_at ON raw_events (received_at DESC);
CREATE INDEX IF NOT EXISTS idx_raw_events_kind ON raw_events (event_kind);

CREATE TABLE IF NOT EXISTS alerts (
    id                  BIGSERIAL PRIMARY KEY,
    raw_event_id        BIGINT REFERENCES raw_events(id) ON DELETE SET NULL,
    receiver            TEXT,
    alertname           TEXT NOT NULL,
    fingerprint         TEXT NOT NULL,
    status              TEXT NOT NULL,
    severity            TEXT,
    stage               TEXT,
    instance            TEXT,
    job                 TEXT,
    chip                TEXT,
    sensor              TEXT,
    device              TEXT,
    fstype              TEXT,
    mountpoint          TEXT,
    summary             TEXT,
    description         TEXT,
    current_value       NUMERIC,
    starts_at           TIMESTAMPTZ NOT NULL,
    ends_at             TIMESTAMPTZ,
    notification_reason TEXT,
    group_key           TEXT,
    prometheus_url      TEXT,
    alertmanager_url    TEXT,
    version             TEXT,
    is_firing           BOOLEAN NOT NULL DEFAULT false,
    is_resolved         BOOLEAN NOT NULL DEFAULT false,
    labels              JSONB,
    annotations         JSONB,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (fingerprint, starts_at)
);
CREATE INDEX IF NOT EXISTS idx_alerts_name_instance_stage ON alerts (alertname, instance, stage);
CREATE INDEX IF NOT EXISTS idx_alerts_status ON alerts (status);
CREATE INDEX IF NOT EXISTS idx_alerts_starts_at ON alerts (starts_at DESC);
CREATE INDEX IF NOT EXISTS idx_alerts_fingerprint ON alerts (fingerprint);

CREATE TABLE IF NOT EXISTS generic_alerts (
    id              BIGSERIAL PRIMARY KEY,
    raw_event_id    BIGINT REFERENCES raw_events(id) ON DELETE SET NULL,
    source_service  TEXT,
    message         TEXT NOT NULL,
    job_id          TEXT,
    mode            TEXT,
    extracted       JSONB,
    received_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_generic_alerts_source ON generic_alerts (source_service);
CREATE INDEX IF NOT EXISTS idx_generic_alerts_job_id ON generic_alerts (job_id);

CREATE OR REPLACE FUNCTION set_updated_at() RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_alerts_updated_at ON alerts;
CREATE TRIGGER trg_alerts_updated_at
BEFORE UPDATE ON alerts
FOR EACH ROW EXECUTE FUNCTION set_updated_at();
'

  write_file "$APP_DIR/stack.yml" 'version: "3.8"

services:
  api:
    image: ${IMAGE_NAME}:${IMAGE_TAG}
    networks:
      - obs-network
    ports:
      - "${API_PORT}:4400"
    environment:
      PORT: "4400"
      PG_HOST: 192.168.0.140
      PG_PORT: "8067"
      PG_USER: alertm
      PG_DATABASE: alertmanager
      PG_PASSWORD_FILE: /run/secrets/app_db_password
      REDIS_HOST: redis
      REDIS_PORT: "6379"
    secrets:
      - app_db_password
    deploy:
      replicas: 1
      restart_policy:
        condition: on-failure
      resources:
        limits:
          memory: 256M
    healthcheck:
      test: ["CMD", "node", "-e", "require(\"http\").get(\"http://localhost:4400/health\",r=>process.exit(r.statusCode===200?0:1)).on(\"error\",()=>process.exit(1))"]
      interval: 30s
      timeout: 5s
      retries: 3

  redis:
    image: redis:7-alpine
    networks:
      - obs-network
    volumes:
      - redis_data:/data
    deploy:
      replicas: 1
      restart_policy:
        condition: on-failure

networks:
  obs-network:
    external: true

volumes:
  pg_data:
  redis_data:

secrets:
  pg_root_password:
    file: ./secrets/pg_root_password.txt
  app_db_password:
    file: ./secrets/app_db_password.txt
  monitoring_db_password:
    file: ./secrets/monitoring_db_password.txt
  backup_db_password:
    file: ./secrets/backup_db_password.txt
'

  gen_secret "$APP_DIR/secrets/pg_root_password.txt"
  gen_secret "$APP_DIR/secrets/app_db_password.txt"
  gen_secret "$APP_DIR/secrets/monitoring_db_password.txt"
  gen_secret "$APP_DIR/secrets/backup_db_password.txt"
  chmod +x "$APP_DIR/postgres/init/00_roles.sh"

  log "building image: ${IMAGE_NAME}:${IMAGE_TAG}"
  docker build -t "${IMAGE_NAME}:${IMAGE_TAG}" "$APP_DIR"

  if [[ "$SKIP_PUSH" != "1" ]]; then
    log "pushing image: ${IMAGE_NAME}:${IMAGE_TAG}"
    docker push "${IMAGE_NAME}:${IMAGE_TAG}"
  else
    log "SKIP_PUSH=1 — not pushing"
  fi

  log "init complete. Next: $0 deploy"
}

# ---------------------------------------------------------------------------
# deploy
# ---------------------------------------------------------------------------
cmd_deploy() {
  need docker
  [[ -f "$APP_DIR/stack.yml" ]] || die "stack.yml not found in $APP_DIR — run '$0 init' first"
  ensure_network

  local init_dir
  init_dir="$(cd "$APP_DIR/postgres/init" && pwd)"

  ( cd "$APP_DIR" && \
    IMAGE_NAME="$IMAGE_NAME" IMAGE_TAG="$IMAGE_TAG" API_PORT="$API_PORT" \
    POSTGRES_INIT_DIR="$init_dir" \
    docker stack deploy --resolve-image always -c stack.yml "$STACK_NAME" )
  log "deployed stack '$STACK_NAME'"
}

# ---------------------------------------------------------------------------
# ps
# ---------------------------------------------------------------------------
cmd_ps() {
  need docker
  echo "== docker stack ps $STACK_NAME =="
  docker stack ps "$STACK_NAME" --no-trunc || die "stack '$STACK_NAME' not found — is it deployed?"
  echo
  echo "== docker service ls (filtered) =="
  docker service ls --filter "label=com.docker.stack.namespace=$STACK_NAME"
}

# ---------------------------------------------------------------------------
# logs [service]
# ---------------------------------------------------------------------------
cmd_logs() {
  need docker
  local svc="${1:-api}"
  docker service logs -f --tail 200 "${STACK_NAME}_${svc}"
}

# ---------------------------------------------------------------------------
# rm
# ---------------------------------------------------------------------------
cmd_rm() {
  need docker
  if [[ "$YES" != "1" ]]; then
    read -r -p "Remove stack '$STACK_NAME' (services+tasks; volumes/secrets persist)? [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]] || { log "aborted"; return 0; }
  fi
  docker stack rm "$STACK_NAME"
  log "removed stack '$STACK_NAME' — data volumes and secrets were left intact"
}

# ---------------------------------------------------------------------------
# doc / help
# ---------------------------------------------------------------------------
cmd_doc() {
  cat <<EOF
alertmanager-forecast-api-njs.sh — Node.js/Postgres/Redis bridge for Alertmanager
and generic webhook alerts, storing normalized data for forecast/predictive
monitoring.

USAGE:
  $0 <command> [args]

COMMANDS:
  init              Scaffold app (Hono/pg/ioredis), Dockerfile, stack.yml,
                     Postgres schema + hardened roles, generate secrets,
                     build & push image. Idempotent; FORCE=1 to overwrite.
  deploy            docker stack deploy --resolve-image always -c stack.yml $STACK_NAME
  ps                Show stack tasks + services
  logs [svc]        Follow logs (api|postgres|redis), default: api
  rm                Remove the stack (prompts unless YES=1)
  doc | help        Show this text

ENV OVERRIDES:
  STACK_NAME    default: alertmanager-forecast-api
  APP_DIR       default: ./\$STACK_NAME
  REGISTRY      default: 192.168.0.140:5000
  NETWORK_NAME  default: obs-network
  API_PORT      default: 4400
  FORCE=1       overwrite scaffolded files on init
  SKIP_PUSH=1   build only, don't push to registry
  YES=1         skip confirmation on rm

ENDPOINTS (once deployed):
  POST /webhook/alertmanager   Alertmanager payloads (raw or n8n-wrapped),
                                 OR generic {"text": "..."} alerts — both
                                 shapes hit the same route and are classified
                                 automatically.
  GET  /alerts                  Query normalized alerts
                                 (?status=&alertname=&instance=&limit=)
  GET  /alerts/generic           Query generic/text alerts
  GET  /health                   Liveness/readiness
  GET  /metrics                  Prometheus metrics

DATA MODEL:
  raw_events      full raw payload, audit/replay trail (jsonb)
  alerts          normalized Alertmanager alerts, one row per
                  (fingerprint, starts_at); indexed on (alertname, instance,
                  stage) to support forecast-stage progression queries
  generic_alerts  normalized free-text alerts (job_id/mode extracted)

ROLES CREATED IN POSTGRES:
  app_user        used by the API (read/write on alerts tables)
  monitoring_ro   read-only + pg_monitor (for postgres_exporter)
  backup_ro       read-only (for pg_dump / backup jobs)
EOF
}

# ---------------------------------------------------------------------------
main() {
  local cmd="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$cmd" in
    init)         cmd_init "$@" ;;
    deploy)       cmd_deploy "$@" ;;
    ps)           cmd_ps "$@" ;;
    logs)         cmd_logs "$@" ;;
    rm)           cmd_rm "$@" ;;
    doc|help|-h|--help|"") cmd_doc ;;
    *) die "unknown command: $cmd (see: $0 doc)" ;;
  esac
}

main "$@"
