import pg from "pg";
import { readFileSync } from "node:fs";

const { Pool } = pg;

// Password precedence: 1) PG_PASSWORD env  2) PG_PASSWORD_FILE  3) Swarm secret
function resolvePgPassword() {
  if (process.env.PG_PASSWORD) {
    console.log("[pg] password source: PG_PASSWORD env var");
    return process.env.PG_PASSWORD;
  }
  const filePath = process.env.PG_PASSWORD_FILE || "/run/secrets/app_db_password";
  try {
    const value = readFileSync(filePath, "utf8").trim();
    if (value) {
      console.log(`[pg] password source: file ${filePath}`);
      return value;
    }
  } catch (err) {
    if (err.code !== "ENOENT") {
      console.error(`[pg] failed reading ${filePath}: ${err.message}`);
    }
  }
  console.error("[pg] no password found (PG_PASSWORD, PG_PASSWORD_FILE or /run/secrets/app_db_password) - DB auth will fail");
  return undefined;
}

export const pool = new Pool({
  host: process.env.PG_HOST ?? "postgres",
  port: Number(process.env.PG_PORT ?? 5432),
  user: process.env.PG_USER ?? "alertm",
  password: resolvePgPassword(),
  database: process.env.PG_DATABASE ?? "alertmanager",
  max: Number(process.env.PG_POOL_MAX ?? 10),
  idleTimeoutMillis: 30000,
});

pool.on("error", (err) => {
  console.error(`[pg] pool error: ${err.message}`);
});
