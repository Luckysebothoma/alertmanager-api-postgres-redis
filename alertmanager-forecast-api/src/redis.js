import Redis from "ioredis";
import { readSecret } from "./secrets.js";

export const redis = new Redis({
  host: process.env.REDIS_HOST ?? "redis",
  port: Number(process.env.REDIS_PORT ?? 6379),
  retryStrategy: (times) => Math.min(times * 200, 5000),
});

redis.on("error", (err) => console.error(`[redis] ${err.message}`));
