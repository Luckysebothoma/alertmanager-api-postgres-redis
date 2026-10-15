import { readFileSync } from "node:fs";

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
