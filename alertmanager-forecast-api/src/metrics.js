import client from "prom-client";

export const register = new client.Registry();
client.collectDefaultMetrics({ register });

export const alertsReceivedTotal = new client.Counter({
  name: "forecast_api_alerts_received_total",
  help: "Total alerts received, by kind/status/alertname/severity/stage",
  labelNames: ["kind", "status", "alertname", "severity", "stage"],
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

