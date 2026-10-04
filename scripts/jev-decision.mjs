#!/usr/bin/env node
/** Optional advisory CLI; output is never review evidence or a tool permission. */
import { closeSync, openSync, fstatSync, readSync, writeFileSync, linkSync, unlinkSync, existsSync, lstatSync, constants } from 'node:fs';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { parseFlags } from './lib/args.mjs';
import { decide, policyHash, validateConfig } from './lib/jev-decision.mjs';

const flags = parseFlags(process.argv.slice(2), {flags: {
  '--help': {key: 'help', type: 'boolean'}, '-h': {key: 'help', type: 'boolean'},
  '--config': {key: 'config'}, '--request': {key: 'request'}, '--out': {key: 'out'},
  '--loop-summary': {key: 'loop', type: 'boolean'}, '--failures': {key: 'failures'},
  '--runner': {key: 'runner', type: 'enum', values: ['grok', 'codex', 'claude']},
}});
function usageError() { console.error('jev-decision: invalid configuration, input, or output path'); process.exit(2); }
if (flags.help) {
  console.log(`jev-decision.mjs — optional advisory structured decisions

USAGE
  node scripts/jev-decision.mjs --request summary.json [--config FILE] [--out jev-advice.json]
  node scripts/jev-decision.mjs --loop-summary --failures N --runner codex [--out jev-escalation.json]

WHAT IT DOES
  Returns a typed advisory receipt, or an explicit deterministic/human fallback.
  Config defaults to config/jev.v1.json. No model writes code or grants verification.

ENV
  GIBSON_JEV_ENABLED=1          explicit optional activation (default disabled)
  GIBSON_JEV_OPERATOR_MODE=1    required for the loop hook (noncausal operator use)
  TYPESAFE_API_KEY              server-side provider credential; never passed as an argument

RISKS
  Enabled calls send only allowlisted summary metadata to TypeSafe and use its API.
  No retries, permission changes, gate verdicts, dispatch, or benchmark score updates.
  Output filenames must start jev- and end .json; existing files are refused.`);
  process.exit(0);
}

function readJSON(path) {
  const fd = openSync(path, constants.O_RDONLY | constants.O_NONBLOCK | constants.O_NOFOLLOW);
  try {
    const stat = fstatSync(fd);
    if (!stat.isFile() || stat.size > 16384) throw new Error('input');
    const buffer = Buffer.alloc(16385);
    let size = 0, count;
    while ((count = readSync(fd, buffer, size, buffer.length - size, null)) > 0) {
      size += count;
      if (size > 16384) throw new Error('input');
    }
    return JSON.parse(buffer.subarray(0, size).toString('utf8'));
  } finally { closeSync(fd); }
}
let config, request, forcedFallback = null;
try {
  if (Boolean(flags.request) === Boolean(flags.loop)) throw new Error('input');
  config = readJSON(flags.config || fileURLToPath(new URL('../config/jev.v1.json', import.meta.url)));
  if (process.env.GIBSON_JEV_ENABLED !== undefined) {
    if (!['0', '1'].includes(process.env.GIBSON_JEV_ENABLED)) throw new Error('config');
    config = {...config, enabled: process.env.GIBSON_JEV_ENABLED === '1'};
  }
  validateConfig(config);
  if (flags.loop) {
    if (!/^(?:0|[1-9][0-9]?)$|^100$/.test(flags.failures || '') || !flags.runner) throw new Error('input');
    request = {use: 'supervisor-escalation', state: {
      phase: 'unknown', infrastructure_health: 'unknown', consecutive_failures: Number(flags.failures),
      retry_count: 0, gate_status: 'red', halted: false,
    }, experiment: {mode: 'operator'}};
    if (process.env.GIBSON_JEV_OPERATOR_MODE !== '1') forcedFallback = 'operator_mode_required';
  } else {
    if (flags.failures !== null || flags.runner !== null) throw new Error('input');
    request = readJSON(flags.request);
  }
  if (flags.out) {
    if (!/^jev-[a-z0-9-]+\.json$/.test(basename(flags.out))) throw new Error('output');
    if (existsSync(flags.out) || (() => { try { return lstatSync(flags.out).isSymbolicLink(); } catch { return false; } })()) {
      throw new Error('output');
    }
  }
} catch { usageError(); }

const receipt = await decide(request, {config: forcedFallback ? {...config, enabled: false} : config, env: process.env});
if (forcedFallback && config.enabled) {
  receipt.status = 'fallback'; receipt.fallback_or_error = forcedFallback;
  // Hash the effective requested policy, including enabled state.
  receipt.policy_hash = policyHash(config);
}
const serialized = `${JSON.stringify(receipt)}\n`;
try {
  if (flags.out) {
    const temp = join(dirname(flags.out), `.jev-${randomUUID()}.tmp`);
    try { writeFileSync(temp, serialized, {flag: 'wx', mode: 0o600}); linkSync(temp, flags.out); }
    finally { try { unlinkSync(temp); } catch {} }
  } else process.stdout.write(serialized);
} catch { console.error('jev-decision: advisory receipt could not be written'); process.exit(1); }
