import { serve } from "@hono/node-server";
import { Hono } from "hono";
import { pool } from "./db.js";
import { redis } from "./redis.js";
import { register, alertsReceivedTotal, webhookDuration, alertCurrentValue, alertFiring  } from "./metrics.js";
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
