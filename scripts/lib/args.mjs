/**
 * Shared CLI flag-parsing helpers for scripts/*.mjs (#192).
 *
 * Contract:
 *   - unknown `--flag` → stderr `unknown flag: X`, exit 2
 *   - value flag with no following token → stderr usage error, exit 2
 *     (never a raw Node stack trace from reading undefined)
 *   - enum-valued flags reject unknown values with a usage error, exit 2
 *
 * Defaults and known flags stay per-script; this module only standardizes
 * error behavior. Pure library — import, do not execute.
 */

/**
 * @param {string} msg
 * @returns {never}
 */
export function dieUsage(msg) {
  console.error(msg);
  process.exit(2);
}

/**
 * @param {string} flag
 * @returns {never}
 */
export function unknownFlag(flag) {
  dieUsage(`unknown flag: ${flag}`);
}

/**
 * Lookup a single `--flag value` pair in an argv array (test-integrity style).
 * Missing flag → null. Present without a value → usage error, exit 2.
 *
 * @param {string[]} args
 * @param {string} name  e.g. "--input"
 * @returns {string | null}
 */
export function readFlag(args, name) {
  const i = args.indexOf(name);
  if (i < 0) return null;
  if (i + 1 >= args.length) {
    dieUsage(`${name} requires a value`);
  }
  // Consume the next token verbatim — a value may look like a flag
  // (`--waiver-text '--documented waiver'`). Missing only when i+1 >= length.
  return args[i + 1];
}

/**
 * @param {string[]} args
 * @param {string} name
 * @returns {boolean}
 */
export function hasFlag(args, name) {
  return args.includes(name);
}

/**
 * @typedef {object} FlagSpec
 * @property {string} key              property name on the result object
 * @property {'boolean'|'string'|'enum'} [type=string]
 * @property {boolean} [multiple]      collect repeated flags into an array
 * @property {unknown} [default]       default when flag absent (function ok)
 * @property {string[]} [values]       allowed values when type==='enum'
 * @property {(v: string) => unknown} [transform]  map the raw string value
 * @property {boolean} [emptyOk]       allow empty string value (e.g. --pr-title "")
 */

/**
 * Parse argv against an explicit flag table. Unknown `--*` / `-X` fails closed.
 *
 * @param {string[]} argv   typically process.argv.slice(2)
 * @param {object} schema
 * @param {Record<string, FlagSpec>} schema.flags  map of flag name → spec
 * @param {boolean} [schema.allowPositionals=false]
 * @param {string} [schema.positionalsKey='_']
 * @param {string} [schema.prefix='']  optional "script: " prefix on value errors
 * @returns {Record<string, unknown>}
 */
export function parseFlags(argv, schema) {
  const flags = schema.flags || {};
  const allowPositionals = Boolean(schema.allowPositionals);
  const positionalsKey = schema.positionalsKey || "_";
  const prefix = schema.prefix || "";

  /** @type {Record<string, unknown>} */
  const out = {};
  for (const spec of Object.values(flags)) {
    if (spec.multiple) {
      out[spec.key] = [];
    } else if (Object.prototype.hasOwnProperty.call(spec, "default")) {
      const d = spec.default;
      out[spec.key] = typeof d === "function" ? d() : d;
    } else if (spec.type === "boolean") {
      out[spec.key] = false;
    } else {
      out[spec.key] = null;
    }
  }

  /** @type {string[]} */
  const positionals = [];

  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--") {
      positionals.push(...argv.slice(i + 1));
      break;
    }
    if (a.startsWith("-") && a !== "-") {
      const spec = flags[a];
      if (!spec) unknownFlag(a);

      if (spec.type === "boolean") {
        out[spec.key] = true;
        continue;
      }

      if (i + 1 >= argv.length) {
        dieUsage(`${prefix}${a} requires a value`);
      }
      // Consume the next argv token verbatim, whatever it looks like.
      const raw = argv[++i];

      if (spec.type === "enum") {
        const allowed = spec.values || [];
        if (!allowed.includes(raw)) {
          dieUsage(
            `${prefix}${a} must be one of: ${allowed.join("|")} (got ${JSON.stringify(raw)})`
          );
        }
      }

      let val = /** @type {unknown} */ (raw);
      if (typeof spec.transform === "function") {
        val = spec.transform(raw);
      }
      if (spec.multiple) {
        /** @type {unknown[]} */ (out[spec.key]).push(val);
      } else {
        out[spec.key] = val;
      }
      continue;
    }

    if (allowPositionals) {
      positionals.push(a);
    } else {
      // Non-flag junk: report as unknown flag when it looks like one, else usage.
      if (a.startsWith("-")) unknownFlag(a);
      dieUsage(`${prefix}unexpected argument: ${a}`);
    }
  }

  if (allowPositionals) out[positionalsKey] = positionals;
  return out;
}

/**
 * Reject any `--*` / `-X` token not in the allow-list (for scripts that mix
 * custom parsing with a need to fail on typos). Exit 2 on the first stranger.
 *
 * Value tokens that follow a known value-taking flag are never inspected — a
 * waiver line like `- Test-integrity: removed 2…` is a *value*, not a flag.
 *
 * @param {string[]} argv
 * @param {Iterable<string>} allowed  e.g. ["--input", "--out", "--json"]
 * @param {object} [opts]
 * @param {Iterable<string>} [opts.valueFlags]  flags that consume the next argv
 *   token as a value (defaults: every allowed entry that is not a pure boolean
 *   short/long help flag)
 */
export function rejectUnknownFlags(argv, allowed, opts = {}) {
  const allow = new Set(allowed);
  const valueFlags = new Set(
    opts.valueFlags ||
      [...allow].filter((f) => f !== "-h" && f !== "--help" && f !== "--json")
  );
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--") break;
    if (a.startsWith("-") && a !== "-") {
      if (!allow.has(a)) unknownFlag(a);
      // Skip the following value token so markdown/negative values are not
      // re-scanned as flags.
      if (valueFlags.has(a) && i + 1 < argv.length) {
        i += 1;
      }
      continue;
    }
  }
}
