/**
 * retro-signature.mjs — incident signature normalization (#569).
 *
 * Pure library. Import it; do not execute it.
 *
 * incident_key = (repo, normalized_signature, signature_schema_version).
 * event_id = (repo, attempt_id, head_sha, detector_version, raw_signature).
 * Attempt id and head SHA are evidence. They are not dedup inputs.
 *
 * signature_schema_version bumps when the normalizer changes. Callers must
 * re-examine open incidents before trusting keys produced by the new version.
 */

export const SIGNATURE_SCHEMA_VERSION = 1;

const ISO_TIMESTAMP =
  /\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?/g;
const TIME_OF_DAY = /\b\d{2}:\d{2}:\d{2}\b/g;
const SHA256 = /\b[0-9a-fA-F]{64}\b/g;
const SHA40 = /\b[0-9a-fA-F]{40}\b/g;
const RUN_ID =
  /\b(?:run(?:[ _-]?id)?|workflow[ _-]?run|actions\/runs)[=:/\s#-]*\d+\b/gi;
const LINE_WORD = /\bline\s+\d+\b/gi;
const FILE_LINE = /([A-Za-z0-9_./-]+):\d{1,6}(?::\d{1,6})?\b/g;

/**
 * Strip timestamps, SHAs, run ids, and line-number noise.
 * The same failure class collapses; a different message does not.
 *
 * @param {string} raw
 * @returns {string}
 */
export function normalizeSignature(raw) {
  if (typeof raw !== "string") {
    throw new TypeError("raw signature must be a string");
  }
  let text = raw;
  text = text.replace(ISO_TIMESTAMP, "<ts>");
  text = text.replace(TIME_OF_DAY, "<ts>");
  text = text.replace(SHA256, "<sha>");
  text = text.replace(SHA40, "<sha>");
  text = text.replace(RUN_ID, "<run>");
  text = text.replace(LINE_WORD, "line <line>");
  text = text.replace(FILE_LINE, "$1:<line>");
  text = text.replace(/[ \t]+/g, " ").trim();
  return text;
}

/**
 * @param {{ repo: string, attemptId: string, headSha: string, detectorVersion: string, rawSignature: string }} parts
 * @returns {string}
 */
export function eventId(parts) {
  return JSON.stringify([
    parts.repo,
    parts.attemptId,
    parts.headSha,
    parts.detectorVersion,
    parts.rawSignature,
  ]);
}

/**
 * @param {{ repo: string, normalizedSignature: string, signatureSchemaVersion: number }} parts
 * @returns {string}
 */
export function incidentKey(parts) {
  return JSON.stringify([
    parts.repo,
    parts.normalizedSignature,
    parts.signatureSchemaVersion,
  ]);
}
