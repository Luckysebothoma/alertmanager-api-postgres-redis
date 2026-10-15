import pg from "pg";
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
