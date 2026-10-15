// n8n wraps a single execution payload in an array: [{ headers, body, ... }]
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
