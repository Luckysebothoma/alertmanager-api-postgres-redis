CREATE TABLE IF NOT EXISTS raw_events (
    id              BIGSERIAL PRIMARY KEY,
    received_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    source_agent    TEXT,
    webhook_url     TEXT,
    execution_mode  TEXT,
    event_kind      TEXT NOT NULL,      -- 'alertmanager' | 'generic' | 'unknown'
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
