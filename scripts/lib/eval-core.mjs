/**
 * eval-core.mjs — shared eval-layer plumbing (#583). Pure library, import only.
 *
 * Every event is appended to a local JSONL sink first. Shipping to Langfuse is
 * optional: it needs LANGFUSE_PUBLIC_KEY + LANGFUSE_SECRET_KEY in the
 * environment, uses plain fetch against the REST ingestion endpoint (no SDK,
 * no dependency), and never throws — a down collector must not fail a run.
 *
 * Secrets: keys are read from env only. Everything written (local or remote)
 * goes through redact() first, which strips key-shaped tokens and the literal
 * values of the LANGFUSE_* variables.
 */
import { appendFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { randomUUID } from "node:crypto";

export const DEFAULT_HOST = "https://cloud.langfuse.com";
export const DEFAULT_OUT_DIR = ".gibson-evals";

// Key-shaped tokens we never want in a trace. Conservative on purpose.
const SECRET_PATTERNS = [
  /\b(?:pk|sk)-lf-[A-Za-z0-9-]{8,}\b/g, // Langfuse keys
  /\bsk-[A-Za-z0-9_-]{16,}\b/g, // OpenAI / Anthropic / OpenRouter style
  /\bgh[pousr]_[A-Za-z0-9]{20,}\b/g, // GitHub tokens
  /\bxox[abprs]-[A-Za-z0-9-]{10,}\b/g, // Slack tokens
  /\bAKIA[0-9A-Z]{16}\b/g, // AWS access key id
  /\bBearer\s+[A-Za-z0-9._~+/=-]{16,}/g,
];

/**
 * @param {string} text
 * @param {Record<string, string|undefined>} [env]
 * @returns {string}
 */
export function redact(text, env = process.env) {
  let out = String(text);
  for (const name of ["LANGFUSE_PUBLIC_KEY", "LANGFUSE_SECRET_KEY"]) {
    const v = env[name];
    if (v && v.length >= 6) out = out.split(v).join("[REDACTED]");
  }
  for (const re of SECRET_PATTERNS) out = out.replace(re, "[REDACTED]");
  return out;
}

/**
 * Deep-redact every string in a JSON-able value.
 * @param {unknown} value
 * @param {Record<string, string|undefined>} [env]
 * @returns {unknown}
 */
export function redactDeep(value, env = process.env) {
  if (typeof value === "string") return redact(value, env);
  if (Array.isArray(value)) return value.map((v) => redactDeep(v, env));
  if (value && typeof value === "object") {
    /** @type {Record<string, unknown>} */
    const out = {};
    for (const [k, v] of Object.entries(value)) out[k] = redactDeep(v, env);
    return out;
  }
  return value;
}

/**
 * @param {Record<string, string|undefined>} [env]
 * @returns {{ configured: boolean, host: string, reason: string }}
 */
export function langfuseConfig(env = process.env) {
  const pk = env.LANGFUSE_PUBLIC_KEY;
  const sk = env.LANGFUSE_SECRET_KEY;
  const host = (env.LANGFUSE_HOST || DEFAULT_HOST).replace(/\/+$/, "");
  if (!pk || !sk) {
    return {
      configured: false,
      host,
      reason: "LANGFUSE_PUBLIC_KEY / LANGFUSE_SECRET_KEY not set",
    };
  }
  if (!/^https:\/\//.test(host) && !/^http:\/\/(localhost|127\.0\.0\.1)(:|\/|$)/.test(host)) {
    return {
      configured: false,
      host,
      reason: "LANGFUSE_HOST must be https:// (or http://localhost for a local instance)",
    };
  }
  return { configured: true, host, reason: "" };
}

/**
 * @param {string} file
 * @param {unknown} obj
 */
export function appendLocal(file, obj) {
  mkdirSync(dirname(file), { recursive: true });
  appendFileSync(file, `${JSON.stringify(obj)}\n`, "utf8");
}

/**
 * Build an ingestion envelope item.
 * @param {"trace-create"|"score-create"|"generation-create"} type
 * @param {Record<string, unknown>} body
 * @param {string} [timestamp]
 */
export function envelope(type, body, timestamp) {
  return {
    id: randomUUID(),
    type,
    timestamp: timestamp || new Date().toISOString(),
    body,
  };
}

/**
 * Write events to the local sink, then ship to Langfuse when configured.
 * Never throws. Returns what happened so the caller can say so out loud.
 *
 * @param {Array<{id:string,type:string,timestamp:string,body:Record<string,unknown>}>} events
 * @param {object} opts
 * @param {string} opts.localFile
 * @param {Record<string, string|undefined>} [opts.env]
 * @param {typeof fetch} [opts.fetchImpl]
 * @returns {Promise<{ local: number, shipped: number, status: "shipped"|"skipped"|"failed", detail: string }>}
 */
export async function emit(events, opts) {
  const env = opts.env || process.env;
  const clean = /** @type {typeof events} */ (redactDeep(events, env));
  for (const ev of clean) appendLocal(opts.localFile, ev);

  const cfg = langfuseConfig(env);
  if (!cfg.configured) {
    return { local: clean.length, shipped: 0, status: "skipped", detail: cfg.reason };
  }
  if (clean.length === 0) {
    return { local: 0, shipped: 0, status: "shipped", detail: "nothing to send" };
  }
  const doFetch = opts.fetchImpl || globalThis.fetch;
  const auth = Buffer.from(`${env.LANGFUSE_PUBLIC_KEY}:${env.LANGFUSE_SECRET_KEY}`).toString("base64");
  try {
    const res = await doFetch(`${cfg.host}/api/public/ingestion`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Basic ${auth}` },
      body: JSON.stringify({ batch: clean }),
      signal: AbortSignal.timeout(15000),
    });
    // Langfuse answers 207 with per-item successes/errors.
    const text = await res.text();
    if (!res.ok) {
      return {
        local: clean.length,
        shipped: 0,
        status: "failed",
        detail: redact(`HTTP ${res.status}: ${text.slice(0, 200)}`, env),
      };
    }
    let errors = 0;
    try {
      const parsed = JSON.parse(text);
      errors = Array.isArray(parsed.errors) ? parsed.errors.length : 0;
    } catch {
      /* non-JSON 2xx body: treat as accepted */
    }
    if (errors > 0) {
      return {
        local: clean.length,
        shipped: clean.length - errors,
        status: "failed",
        detail: `${errors} of ${clean.length} events rejected by Langfuse`,
      };
    }
    return { local: clean.length, shipped: clean.length, status: "shipped", detail: cfg.host };
  } catch (e) {
    return {
      local: clean.length,
      shipped: 0,
      status: "failed",
      detail: redact(`network error: ${e instanceof Error ? e.message : String(e)}`, env),
    };
  }
}

/**
 * One-line, honest account of what emit() did.
 * @param {Awaited<ReturnType<typeof emit>>} r
 * @returns {string}
 */
export function describeEmit(r) {
  if (r.status === "shipped") return `langfuse: shipped ${r.shipped} event(s) (${r.detail}); local copy kept`;
  if (r.status === "skipped") return `langfuse: SKIPPED (${r.detail}); wrote ${r.local} event(s) locally only`;
  return `langfuse: FAILED (${r.detail}); wrote ${r.local} event(s) locally, ${r.shipped} shipped`;
}
