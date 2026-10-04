#!/usr/bin/env node
// Offline contract checks: no provider credentials, real calls, or gate authority.
import assert from 'node:assert/strict';
import test from 'node:test';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync, statSync, existsSync, symlinkSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { resolve } from 'node:path';

const root = process.env.JEVMODULE_ROOT || fileURLToPath(new URL('../..', import.meta.url));
const { DEFAULT_CONFIG, QUESTION_SETS, QUESTION_SET_VERSION, policyHash,
  validateConfig, validateRequest, decide } = await import(pathToFileURL(resolve(root, 'scripts/lib/jev-decision.mjs')));
const SECRET = 'ENV_ONLY_JEV_TEST_SECRET';
const env = { TYPESAFE_API_KEY: SECRET };
const enabled = { ...DEFAULT_CONFIG, enabled: true };
const clone = value => structuredClone(value);

// Execute the production shell functions with bounded, offline collaborators.
// This exercises the real hook and cap ordering, without starting a fleet loop.
function loopFunction(name) {
  const source = readFileSync(resolve(root, 'scripts/loop.sh'), 'utf8');
  const marker = `\n${name}() {\n`;
  assert.equal(source.split(marker).length, 2, `${name} must have one production definition`);
  const start = source.indexOf(marker) + 1;
  const end = source.indexOf('\n}\n', start);
  assert.ok(end > start, `${name} closing boundary must be found`);
  return source.slice(start, end + 2);
}

// These fixtures describe accepted summaries; they contain no free-form source,
// tool arguments, benchmark gold answers, or user-controlled prompt text.
const states = {
  'supervisor-escalation': { phase: 'build', infrastructure_health: 'degraded',
    consecutive_failures: 2, retry_count: 1, gate_status: 'red', halted: false },
  'model-or-agent-routing': { phase: 'review', required_capability: 'review', infrastructure_health: 'healthy' },
  'tool-call-guard': { tool_name: 'shell', operation: 'execute', scope: 'production',
    has_credentials: true, touches_sensitive_data: true },
  'benchmark-anomaly-triage': { task_result: 'failed', failure_category: 'infrastructure',
    telemetry_integrity: 'valid', infrastructure_health: 'degraded', attempt_count: 1 },
};
const request = (use = 'supervisor-escalation', mode = 'operator') => ({ use,
  state: clone(states[use]), experiment: { mode } });
const score = () => ({ type: 'score', score: 0, legend: { 0: 'low', 1: 'medium', 2: 'high' },
  probabilities: { 0: 1, 1: 0, 2: 0 }, confidence: 1 });
const answers = {
  'supervisor-escalation': { action: { type: 'choice', choice: 'continue', probabilities: {
    continue: 0.94, retry_infrastructure: 0.02, stop: 0.02, human_escalation: 0.02 }, confidence: 0.94 },
  needs_human: { type: 'noul', noul: 0.9 }, run_risk: score() },
  'model-or-agent-routing': { route: { type: 'choice', choice: 'codex', probabilities: {
    hermes: 0.04, codex: 0.88, claude_code: 0.03, grok: 0.03, human: 0.02 }, confidence: 0.88 } },
  'tool-call-guard': { allow_tool_call: { type: 'noul', noul: 0.9 }, risk: score() },
  'benchmark-anomaly-triage': { anomaly_class: { type: 'choice', choice: 'expected_task_failure', probabilities: {
    expected_task_failure: 0.91, infrastructure_failure: 0.03, telemetry_corruption: 0.03,
    requires_human_review: 0.03 }, confidence: 0.91 } },
};
const response = (use = 'supervisor-escalation') => ({ model: 'jev-1.13.0', answers: clone(answers[use]) });
const fetchJson = body => async () => new Response(JSON.stringify(body), { status: 200 });
const run = (req = request(), fetchImpl = fetchJson(response()), config = enabled, credentials = env) =>
  decide(req, { config, env: credentials, fetchImpl });

function assertReceipt(receipt, status, recordedFallbackAnswers = null) {
  assert.equal(receipt.authority, 'advisory');
  assert.equal(receipt.status, status);
  assert.equal(receipt.question_set_version, QUESTION_SET_VERSION);
  assert.match(receipt.policy_hash, /^[a-f0-9]{64}$/);
  if (status === 'disabled') assert.equal(receipt.request_state_hash, null);
  else assert.match(receipt.request_state_hash, /^[a-f0-9]{64}$/);
  assert.equal(typeof receipt.latency_ms, 'number');
  assert.ok(Number.isFinite(receipt.latency_ms) && receipt.latency_ms >= 0);
  const encoded = JSON.stringify(receipt);
  assert.ok(!encoded.includes(SECRET), 'credential must never enter a receipt');
  assert.ok(!encoded.includes('VERIFIED'), 'Jev must never assert evidence verification');
  assert.ok(!encoded.includes('RAW_REMOTE_ERROR'), 'remote prose must never enter a receipt');
  for (const key of ['state', 'prompt', 'instructions', 'permissions', 'tool_arguments', 'source_code', 'raw_response']) {
    assert.ok(!Object.hasOwn(receipt, key), `${key} must not enter a receipt`);
  }
  if (status === 'advisory') {
    assert.equal(receipt.fallback_or_error, null);
    assert.ok(receipt.typed_answers);
  } else {
    assert.deepEqual(receipt.typed_answers, recordedFallbackAnswers);
    assert.equal(typeof receipt.fallback_or_error, 'string');
  }
}

test('AC1: immutable configuration defaults are disabled, versioned and bounded', () => {
  assert.deepEqual(DEFAULT_CONFIG, { enabled: false, model: 'jev-1.13.0', timeout_ms: 2000,
    min_confidence: 0.8, experiment_policy: 'excluded_from_scored_loop' });
  assert.equal(typeof QUESTION_SET_VERSION, 'string');
  assert.ok(QUESTION_SET_VERSION.length > 0);
  assert.deepEqual(Object.keys(QUESTION_SETS).sort(), Object.keys(states).sort());
  assert.ok(Object.isFrozen(DEFAULT_CONFIG));
  assert.ok(Object.isFrozen(QUESTION_SETS));
  assert.deepEqual(Object.keys(QUESTION_SETS['supervisor-escalation']).sort(), ['action', 'needs_human', 'run_risk']);
  assert.deepEqual(Object.keys(QUESTION_SETS['tool-call-guard']).sort(), ['allow_tool_call', 'risk']);
  assert.deepEqual(Object.keys(QUESTION_SETS['benchmark-anomaly-triage']), ['anomaly_class']);
  assert.deepEqual(Object.keys(QUESTION_SETS['model-or-agent-routing']), ['route']);
  assert.deepEqual(Object.keys(QUESTION_SETS['supervisor-escalation'].action.criteria),
    ['continue', 'retry_infrastructure', 'stop', 'human_escalation']);
  assert.deepEqual(Object.keys(QUESTION_SETS['model-or-agent-routing'].route.criteria),
    ['hermes', 'codex', 'claude_code', 'grok', 'human']);
  assert.deepEqual(Object.keys(QUESTION_SETS['benchmark-anomaly-triage'].anomaly_class.criteria),
    ['expected_task_failure', 'infrastructure_failure', 'telemetry_corruption', 'requires_human_review']);
  assert.deepEqual(QUESTION_SETS['tool-call-guard'].risk.criteria, ['low', 'medium', 'high']);
});

test('AC1: disabled default requires no key and never calls the provider', async () => {
  let calls = 0;
  const receipt = await run(request(), async () => { calls++; throw new Error('must not call'); }, DEFAULT_CONFIG, {});
  assertReceipt(receipt, 'disabled');
  assert.equal(calls, 0);
});

test('AC1/3: disabled integration ignores missing or untrusted request input', async () => {
  let calls = 0;
  const receipt = await run({ source_code: SECRET }, async () => { calls++; throw new Error('must not call'); }, DEFAULT_CONFIG, {});
  assertReceipt(receipt, 'disabled');
  assert.equal(receipt.use, null);
  assert.equal(calls, 0);
});

test('AC2/3: invalid embedded configuration is rejected without echo or fetch', async () => {
  let calls = 0;
  const receipt = await run(request(), async () => { calls++; return new Response('{}'); }, { ...enabled, api_key: SECRET });
  assert.equal(receipt.status, 'fallback');
  assert.equal(receipt.fallback_or_error, 'invalid_config');
  assert.equal(receipt.policy_hash, null);
  assert.equal(calls, 0);
  assert.ok(!JSON.stringify(receipt).includes(SECRET));
});

for (const [label, patch] of [
  ['embedded API key', { api_key: SECRET }], ['endpoint override', { endpoint: 'https://example.invalid' }],
  ['permission override', { permissions: { shell: true } }], ['unversioned model', { model: 'jev' }],
  ['other model version', { model: 'jev-999.0.0' }], ['string activation', { enabled: 'true' }],
  ['short deadline', { timeout_ms: 49 }], ['long deadline', { timeout_ms: 10001 }],
  ['fractional deadline', { timeout_ms: 50.5 }], ['low threshold', { min_confidence: 0.49 }],
  ['high threshold', { min_confidence: 1.01 }], ['nonfinite threshold', { min_confidence: NaN }],
  ['unrecognized fairness policy', { experiment_policy: 'best_effort' }],
]) {
  test(`AC2/3: configuration rejects ${label}`, () => {
    assert.throws(() => validateConfig({ ...enabled, ...patch }));
  });
}

for (const use of Object.keys(states)) {
  test(`AC2: ${use} accepts only its summary and fixed typed answers`, async () => {
    assert.doesNotThrow(() => validateRequest(request(use)));
    const receipt = await run(request(use), fetchJson(response(use)));
    assertReceipt(receipt, 'advisory');
    assert.deepEqual(receipt.typed_answers, answers[use]);
  });
  test(`AC2/3: ${use} refuses extra raw state before any provider call`, async () => {
    const req = request(use);
    req.state.source_code = SECRET;
    assert.throws(() => validateRequest(req));
    let calls = 0;
    const receipt = await run(req, async () => { calls++; return new Response('{}'); });
    assert.equal(receipt.status, 'fallback');
    assert.equal(receipt.typed_answers, null);
    assert.equal(calls, 0);
    assert.ok(!JSON.stringify(receipt).includes(SECRET));
  });
}

for (const [label, alter] of [
  ['unsupported coding use', req => { req.use = 'code-generation'; }],
  ['unknown top-level field', req => { req.permissions = { shell: true }; }],
  ['missing state field', req => { delete req.state.phase; }],
  ['unknown phase', req => { req.state.phase = 'apply_jev_code'; }],
  ['negative count', req => { req.state.retry_count = -1; }],
  ['fractional count', req => { req.state.retry_count = 1.5; }],
  ['oversized count', req => { req.state.consecutive_failures = 101; }],
  ['nonboolean halt', req => { req.state.halted = 'false'; }],
  ['unknown experiment mode', req => { req.experiment.mode = 'uncontrolled'; }],
  ['extra experiment arm data', req => { req.experiment.gold_answer = SECRET; }],
  ['malformed policy hash', req => { req.experiment.frozen_policy_hash = 'unfrozen'; }],
]) {
  test(`AC2: request rejects ${label}`, () => {
    const req = request(); alter(req);
    assert.throws(() => validateRequest(req));
  });
}

for (const [label, alter] of [
  ['array use', req => { req.use = ['supervisor-escalation']; }],
  ['array frozen policy hash', req => { req.experiment.frozen_policy_hash = ['a'.repeat(64)]; }],
  ['object frozen policy hash', req => { req.experiment.frozen_policy_hash = { hash: 'a'.repeat(64) }; }],
]) {
  test(`AC2/6: request rejects ${label} without coercion or provider calls`, async () => {
    const req = request(); alter(req);
    assert.throws(() => validateRequest(req));
    let calls = 0;
    const receipt = await run(req, async () => { calls++; return new Response(JSON.stringify(response())); });
    assert.equal(receipt.status, 'fallback');
    assert.equal(receipt.fallback_or_error, 'invalid_request');
    assert.equal(receipt.typed_answers, null);
    assert.equal(calls, 0);
  });
}

test('AC2/3: provider receives the fixed official endpoint and an environment credential only', async () => {
  let calls = 0;
  const receipt = await run(request(), async (url, options) => {
    calls++;
    assert.equal(String(url), 'https://api.typesafe.ai/v1/systemone');
    assert.equal(options.method, 'POST');
    assert.equal(options.redirect, 'error', 'do not forward credential to a redirect destination');
    assert.equal(new Headers(options.headers).get('authorization'), `Bearer ${SECRET}`);
    const body = JSON.parse(options.body);
    assert.equal(body.model, 'jev-1.13.0');
    assert.ok(!options.body.includes(SECRET), 'key belongs in the authorization header only');
    return new Response(JSON.stringify(response()));
  });
  assertReceipt(receipt, 'advisory');
  assert.equal(calls, 1, 'one attempt only');
});

test('AC3: a missing environment key gives sanitized fallback without a call', async () => {
  let calls = 0;
  const receipt = await run(request(), async () => { calls++; return new Response('{}'); }, enabled, {});
  assertReceipt(receipt, 'fallback');
  assert.equal(calls, 0);
});

for (const [label, credentials] of [['wrong key name', { JEV_API_KEY: SECRET }], ['empty key', { TYPESAFE_API_KEY: '' }],
  ['header injection', { TYPESAFE_API_KEY: `${SECRET}\r\nInjected: true` }]]) {
  test(`AC3: environment credential rejects ${label}`, async () => {
    let calls = 0;
    const receipt = await run(request(), async () => { calls++; return new Response('{}'); }, enabled, credentials);
    assertReceipt(receipt, 'fallback');
    assert.equal(calls, 0);
  });
}

for (const status of [401, 403, 429, 500, 503]) {
  test(`AC3/4: HTTP ${status} falls back once without echoing provider errors`, async () => {
    let calls = 0;
    const receipt = await run(request(), async () => {
      calls++;
      return new Response(`RAW_REMOTE_ERROR ${SECRET}`, { status });
    });
    assertReceipt(receipt, 'fallback');
    assert.equal(calls, 1);
  });
}

test('AC3/4: unavailable provider exceptions are sanitized and never retried', async () => {
  let calls = 0;
  const receipt = await run(request(), async () => { calls++; throw new Error(`RAW_REMOTE_ERROR ${SECRET}`); });
  assertReceipt(receipt, 'fallback');
  assert.equal(calls, 1);
});

test('AC3/4: a non-Error provider rejection still yields a sanitized fallback', async () => {
  const receipt = await run(request(), async () => { throw null; });
  assertReceipt(receipt, 'fallback');
});

test('AC3/6: midflight caller mutations cannot change the frozen decision or its audit hashes', async () => {
  const reference = await run();
  const req = request();
  const config = clone(enabled);
  let complete;
  const pending = run(req, async () => new Promise(resolveResponse => { complete = resolveResponse; }), config);
  assert.equal(typeof complete, 'function', 'the asynchronous provider boundary was reached');
  config.min_confidence = 1;
  config.model = 'jev-999.0.0';
  req.use = 'model-or-agent-routing';
  req.state.phase = 'review';
  req.state.retry_count = 99;
  req.experiment.mode = 'scored';
  complete(new Response(JSON.stringify(response())));
  const receipt = await pending;
  assertReceipt(receipt, 'advisory');
  assert.equal(receipt.use, 'supervisor-escalation');
  assert.equal(receipt.experiment_mode, 'operator');
  assert.equal(receipt.model, 'jev-1.13.0');
  assert.equal(receipt.policy_hash, reference.policy_hash);
  assert.equal(receipt.request_state_hash, reference.request_state_hash);
});

for (const [label, alter] of [
  ['other model', value => { value.model = 'jev-1.14.0'; }],
  ['missing answer type', value => { delete value.answers.needs_human.type; }],
  ['wrong answer type', value => { value.answers.action.type = 'noul'; }],
  ['unknown top-level VERIFIED field', value => { value.VERIFIED = true; }],
  ['missing answer', value => { delete value.answers.needs_human; }],
  ['unknown answer', value => { value.answers.instructions = 'RAW_REMOTE_ERROR'; }],
  ['unknown choice label', value => { value.answers.action.choice = 'VERIFIED'; }],
  ['injected answer prose', value => { value.answers.action.code = 'RAW_REMOTE_ERROR'; }],
  ['missing probability', value => { delete value.answers.action.probabilities.stop; }],
  ['extra probability', value => { value.answers.action.probabilities.VERIFIED = 0; }],
  ['negative probability', value => { value.answers.action.probabilities.stop = -0.02; }],
  ['probabilities do not sum to one', value => { value.answers.action.probabilities.continue = 0.7; }],
  ['choice conflicts with distribution', value => { value.answers.action.choice = 'stop'; }],
  ['confidence out of range', value => { value.answers.action.confidence = 1.5; }],
  ['Boolean Noul instead of probability', value => { value.answers.needs_human.noul = true; }],
  ['Noul out of range', value => { value.answers.needs_human.noul = -1; }],
  ['nested VERIFIED field', value => { value.answers.needs_human.VERIFIED = true; }],
  ['changed score legend', value => { value.answers.run_risk.legend = { 0: 'low', 1: 'medium', 2: 'critical' }; }],
  ['score conflicts with weighted probabilities', value => { value.answers.run_risk.score = 2; }],
  ['negative score', value => { value.answers.run_risk.score = -1; }],
  ['extra usage field', value => { value.usage = { input_tokens: 1, output_tokens: 1, raw_error: SECRET }; }],
  ['negative usage count', value => { value.usage = { input_tokens: -1, output_tokens: 1 }; }],
  ['fractional usage count', value => { value.usage = { input_tokens: 1.5, output_tokens: 1 }; }],
  ['unsafe usage count', value => { value.usage = { input_tokens: Number.MAX_SAFE_INTEGER + 1, output_tokens: 1 }; }],
]) {
  test(`AC2/5: provider response rejects ${label}`, async () => {
    const value = response(); alter(value);
    const receipt = await run(request(), fetchJson(value));
    assertReceipt(receipt, 'fallback');
    assert.equal(receipt.fallback_or_error, 'invalid_response');
  });
}

test('AC2: known finite token counts are accepted without adding authority', async () => {
  const value = response(); value.usage = { input_tokens: 5, output_tokens: 2 };
  assertReceipt(await run(request(), fetchJson(value)), 'advisory');
});

for (const [label, riskScore, probabilities, status] of [
  ['exact zero', 0, { 0: 1, 1: 0, 2: 0 }, 'advisory'],
  ['exact two', 2, { 0: 0, 1: 0, 2: 1 }, 'advisory'],
  ['slightly below zero', -5e-7, { 0: 1, 1: 0, 2: 0 }, 'fallback'],
  ['slightly above two', 2 + 5e-7, { 0: 0, 1: 0, 2: 1 }, 'fallback'],
]) {
  test(`AC2: Score bounds ${label} remain exact despite weighted-average tolerance`, async () => {
    const value = response();
    value.answers.run_risk = { type: 'score', score: riskScore,
      legend: { 0: 'low', 1: 'medium', 2: 'high' }, probabilities, confidence: 0.9 };
    const receipt = await run(request(), fetchJson(value));
    assertReceipt(receipt, status);
    if (status === 'fallback') assert.equal(receipt.fallback_or_error, 'invalid_response');
    else assert.equal(receipt.typed_answers.run_risk.score, riskScore);
  });
}

for (const [label, value] of [['null', null], ['array', []], ['free text', 'generate code'],
  ['answer array', { model: 'jev-1.13.0', answers: [] }]]) {
  test(`AC2/5: provider rejects ${label} instead of treating it as generative output`, async () => {
    const receipt = await run(request(), fetchJson(value));
    assertReceipt(receipt, 'fallback');
    assert.equal(receipt.fallback_or_error, 'invalid_response');
  });
}

test('AC2/4: malformed JSON and oversized bodies fail closed', async () => {
  for (const body of [`RAW_REMOTE_ERROR ${SECRET}`, ' '.repeat(100000) + JSON.stringify(response())]) {
    const receipt = await run(request(), async () => new Response(body));
    assertReceipt(receipt, 'fallback');
    assert.ok(['invalid_response', 'response_too_large'].includes(receipt.fallback_or_error));
  }
});

for (const [label, alter] of [
  ['Choice', value => { value.answers.action = { type: 'choice', choice: 'continue', probabilities: {
    continue: 0.6, retry_infrastructure: 0.2, stop: 0.1, human_escalation: 0.1 }, confidence: 0.6 }; }],
  ['Score', value => { value.answers.run_risk = { type: 'score', score: 0.4, legend: { 0: 'low', 1: 'medium', 2: 'high' },
    probabilities: { 0: 0.6, 1: 0.4, 2: 0 }, confidence: 0.6 }; }],
  ['Noul', value => { value.answers.needs_human.noul = 0.5; }],
]) {
  test(`AC4: low-confidence ${label} uses deterministic/human fallback`, async () => {
    const value = response(); alter(value);
    const receipt = await run(request(), fetchJson(value));
    assertReceipt(receipt, 'fallback', value.answers);
    assert.equal(receipt.fallback_or_error, 'low_confidence');
    assert.equal(receipt.fallback, 'deterministic_or_human');
  });
}

test('AC4: deadline bounds provider fetch even when it ignores cancellation', { timeout: 2000 }, async () => {
  let providerFinished = false;
  const receipt = await run(request(), async () => {
    await new Promise(resolveDelay => setTimeout(resolveDelay, 200));
    providerFinished = true;
    return new Response(JSON.stringify(response()));
  }, { ...enabled, timeout_ms: 50 });
  assertReceipt(receipt, 'fallback');
  assert.equal(providerFinished, false, 'must not wait for an uncooperative fetch');
});

test('AC4: deadline covers a stalled response body after headers arrive', { timeout: 2000 }, async () => {
  const started = Date.now();
  let cancelled = false;
  const receipt = await run(request(), async () => new Response(new ReadableStream({
    start(controller) { controller.enqueue(new TextEncoder().encode('{')); },
    cancel() { cancelled = true; },
  })), { ...enabled, timeout_ms: 50 });
  assertReceipt(receipt, 'fallback');
  assert.ok(Date.now() - started < 1500, 'body deadline must not hang indefinitely');
  assert.ok(cancelled, 'stalled reader must be cancelled');
});

test('AC6: scored mode is excluded by default before any provider call', async () => {
  let calls = 0;
  const req = request('supervisor-escalation', 'scored');
  req.experiment.frozen_policy_hash = policyHash(enabled);
  const receipt = await run(req, async () => { calls++; return new Response(JSON.stringify(response())); });
  assertReceipt(receipt, 'fallback');
  assert.equal(calls, 0);
});

test('AC5: an existing STOP cannot be reviewed or overridden by Jev', async () => {
  const req = request(); req.state.halted = true;
  let calls = 0;
  const receipt = await run(req, async () => { calls++; return new Response(JSON.stringify(response())); });
  assertReceipt(receipt, 'fallback');
  assert.equal(calls, 0);
  assert.equal(receipt.fallback_or_error, 'halted');
});

test('AC5: favorable tool advice neither modifies input nor returns permissions', async () => {
  const req = request('tool-call-guard');
  const original = clone(req);
  const config = clone(enabled);
  const receipt = await run(req, fetchJson(response(req.use)), config);
  assertReceipt(receipt, 'advisory');
  assert.deepEqual(req, original);
  assert.deepEqual(config, enabled);
  assert.ok(!Object.hasOwn(receipt, 'authorized'));
  assert.ok(!Object.hasOwn(receipt, 'permission_change'));
});

test('AC6: identical-arm scored policy needs the exact frozen effective hash', async () => {
  const config = { ...enabled, experiment_policy: 'identical_across_all_arms' };
  for (const hash of [undefined, 'a'.repeat(64), policyHash(enabled)]) {
    const req = request('supervisor-escalation', 'scored');
    if (hash !== undefined) req.experiment.frozen_policy_hash = hash;
    let calls = 0;
    const receipt = await run(req, async () => { calls++; return new Response(JSON.stringify(response())); }, config);
    assertReceipt(receipt, 'fallback');
    assert.equal(calls, 0);
  }
  const req = request('supervisor-escalation', 'scored');
  req.experiment.frozen_policy_hash = policyHash(config);
  const receipt = await run(req, fetchJson(response()), config);
  assertReceipt(receipt, 'advisory');
  assert.equal(receipt.policy_hash, req.experiment.frozen_policy_hash);
});

for (const mode of ['outside-scored-loop', 'scored']) {
  test(`AC6: routing remains operator-only and refuses ${mode}`, async () => {
    const config = { ...enabled, experiment_policy: 'identical_across_all_arms' };
    const req = request('model-or-agent-routing', mode);
    req.experiment.frozen_policy_hash = policyHash(config);
    let calls = 0;
    const receipt = await run(req, async () => { calls++; return new Response(JSON.stringify(response('model-or-agent-routing'))); }, config);
    assertReceipt(receipt, 'fallback');
    assert.equal(calls, 0);
  });
}

test('AC6: benchmark triage outside scored causal loops is accepted', async () => {
  const req = request('benchmark-anomaly-triage', 'outside-scored-loop');
  assertReceipt(await run(req, fetchJson(response(req.use))), 'advisory');
});

test('AC3/6: state and policy hashes are deterministic and exclude credentials', async () => {
  const first = await run();
  const reordered = request();
  reordered.state = Object.fromEntries(Object.entries(reordered.state).reverse());
  const second = await run(reordered, fetchJson(response()), enabled, { TYPESAFE_API_KEY: 'ENV_ONLY_OTHER_SECRET' });
  assert.equal(first.request_state_hash, second.request_state_hash);
  assert.equal(first.policy_hash, second.policy_hash);
  const changed = request(); changed.state.retry_count++;
  assert.notEqual(first.request_state_hash, (await run(changed)).request_state_hash);
  assert.equal(policyHash(enabled), policyHash(Object.fromEntries(Object.entries(enabled).reverse())));
  assert.notEqual(policyHash(enabled), policyHash({ ...enabled, min_confidence: 0.9 }));
  assert.notEqual(policyHash(enabled), policyHash({ ...enabled, timeout_ms: 1000 }));
});

test('AC5/7: CLI refuses unsupported flags with exit 2 and no secret echo', () => {
  const result = spawnSync(process.execPath, [resolve(root, 'scripts/jev-decision.mjs'), '--jev-allow-verified'], {
    env: { PATH: process.env.PATH || '', TYPESAFE_API_KEY: SECRET }, encoding: 'utf8', timeout: 3000,
  });
  assert.ifError(result.error);
  assert.equal(result.status, 2);
  assert.ok(!(result.stdout + result.stderr).includes(SECRET));
});

const cli = (args, overrides = {}) => spawnSync(process.execPath, [resolve(root, 'scripts/jev-decision.mjs'), ...args], {
  env: { PATH: process.env.PATH || '', ...overrides }, encoding: 'utf8', timeout: 3000,
});
function withFixtures(check) {
  const folder = mkdtempSync(resolve(tmpdir(), 'gibson-jev-test-'));
  const config = resolve(folder, 'config.json');
  const summary = resolve(folder, 'summary.json');
  writeFileSync(config, JSON.stringify(DEFAULT_CONFIG));
  writeFileSync(summary, JSON.stringify(request()));
  try { check({ folder, config, summary }); }
  finally { rmSync(folder, { recursive: true, force: true }); }
}
function assertUsageError(result) {
  assert.ifError(result.error);
  assert.equal(result.status, 2);
  assert.ok(!(result.stdout + result.stderr).includes(SECRET));
}

test('AC1/7: CLI disabled default returns a usable receipt without any environment credential', () => {
  withFixtures(({ config, summary }) => {
    const result = cli(['--config', config, '--request', summary]);
    assert.ifError(result.error);
    assert.equal(result.status, 0);
    assertReceipt(JSON.parse(result.stdout), 'disabled');
  });
});

test('AC3/7: CLI malformed and oversized local inputs are sanitized usage errors', () => {
  withFixtures(({ config, summary }) => {
    writeFileSync(summary, `RAW_REMOTE_ERROR ${SECRET}`);
    assertUsageError(cli(['--config', config, '--request', summary]));
    writeFileSync(summary, ' '.repeat(20000) + JSON.stringify(request()));
    assertUsageError(cli(['--config', config, '--request', summary]));
    writeFileSync(config, JSON.stringify({ ...enabled, api_key: SECRET }));
    assertUsageError(cli(['--config', config, '--request', summary]));
  });
});

test('AC3/7: CLI does not follow local request symlinks', () => {
  withFixtures(({ folder, config, summary }) => {
    const link = resolve(folder, 'linked-summary.json');
    symlinkSync(summary, link);
    assertUsageError(cli(['--config', config, '--request', link]));
  });
});

test('AC5/7: CLI only writes immutable, private Jev receipts and cannot replace evidence', () => {
  withFixtures(({ folder, config, summary }) => {
    const output = resolve(folder, 'jev-advice.json');
    const args = ['--config', config, '--request', summary, '--out', output];
    const created = cli(args);
    assert.ifError(created.error);
    assert.equal(created.status, 0);
    const original = readFileSync(output, 'utf8');
    assertReceipt(JSON.parse(original), 'disabled');
    assert.equal(statSync(output).mode & 0o777, 0o600);
    assertUsageError(cli(args));
    assert.equal(readFileSync(output, 'utf8'), original);
    const evidence = resolve(folder, 'review.json');
    assertUsageError(cli(['--config', config, '--request', summary, '--out', evidence]));
    assert.equal(existsSync(evidence), false);
    const evidenceTarget = resolve(folder, 'original-review.json');
    writeFileSync(evidenceTarget, 'EVIDENCE_GATE_SENTINEL');
    const evidenceLink = resolve(folder, 'jev-linked.json');
    symlinkSync(evidenceTarget, evidenceLink);
    assertUsageError(cli(['--config', config, '--request', summary, '--out', evidenceLink]));
    assert.equal(readFileSync(evidenceTarget, 'utf8'), 'EVIDENCE_GATE_SENTINEL');
  });
});

test('AC5/6/7: CLI loop advice needs an explicit operator context before it can call', () => {
  withFixtures(({ config }) => {
    writeFileSync(config, JSON.stringify(enabled));
    const result = cli(['--config', config, '--loop-summary', '--failures', '2', '--runner', 'codex'], { TYPESAFE_API_KEY: SECRET });
    assert.ifError(result.error);
    assert.equal(result.status, 0);
    const receipt = JSON.parse(result.stdout);
    assert.equal(receipt.status, 'fallback');
    assert.equal(receipt.fallback_or_error, 'operator_mode_required');
    assert.equal(receipt.typed_answers, null);
    assert.ok(!result.stdout.includes(SECRET));
  });
});

test('AC7: CLI rejects ambiguous modes, malformed activation and invalid loop counts', () => {
  withFixtures(({ config, summary }) => {
    assertUsageError(cli(['--config', config]));
    assertUsageError(cli(['--config', config, '--request', summary, '--loop-summary']));
    assertUsageError(cli(['--config', config, '--request', summary], { GIBSON_JEV_ENABLED: 'true' }));
    for (const failures of ['-1', '1.5', '101', '01']) {
      assertUsageError(cli(['--config', config, '--loop-summary', '--failures', failures, '--runner', 'codex']));
    }
  });
});

for (const scenario of [
  { label: 'missing activation', operator: '1', invoked: false },
  { label: 'disabled activation', activation: '0', operator: '1', invoked: false },
  { label: 'missing operator context', activation: '1', invoked: false },
  { label: 'disabled operator context', activation: '1', operator: '0', invoked: false },
  { label: 'existing STOP', activation: '1', operator: '1', halted: true, invoked: false },
  { label: 'enabled operator advice', activation: '1', operator: '1', invoked: true },
  { label: 'unavailable advice', activation: '1', operator: '1', providerRC: 1, invoked: true },
  { label: 'exhausted review cap', activation: '1', operator: '1', capped: true, invoked: false },
]) {
  test(`AC1/5/6: real loop hook handles ${scenario.label} without changing execution authority`, () => {
    withFixtures(({ folder }) => {
      const calls = resolve(folder, 'calls.txt');
      const journal = resolve(folder, 'journal.md');
      const review = resolve(folder, 'second-opinion.md');
      const receipt = resolve(folder, 'review-receipt.json');
      const variables = resolve(folder, 'variables.txt');
      const shell = resolve(folder, 'hook.sh');
      writeFileSync(review, 'EXISTING_REVIEW_ARTIFACT');
      writeFileSync(receipt, 'EXISTING_DETERMINISTIC_REVIEW_RECEIPT');
      const script = [
        'set -eu',
        'STATE_DIR="$TEST_FOLDER"', 'SCRIPT_DIR="$TEST_SCRIPT_DIR"', 'JOURNAL="$TEST_JOURNAL"',
        'REVIEW_ARTIFACT="$TEST_REVIEW"', 'REVIEW_RECEIPT="$TEST_RECEIPT"',
        'failures=7', 'RUNNER=codex', 'REVIEWERS=claude,grok', 'SOLO_PLATFORM=0', 'REPO="$TEST_FOLDER"',
        'info() { printf "%s\\n" "$*" >> "$TEST_INFO"; }',
        'halted() { [ "$TEST_HALTED" = "1" ]; }',
        'refuse_review_round_if_capped() { [ "$TEST_CAPPED" = "0" ]; }',
        'resolve_base_pin() { return 1; }',
        'run_with_wall_timeout() { printf "%s\\n" "$@" >> "$TEST_CALLS"; return "$TEST_PROVIDER_RC"; }',
        loopFunction('jev_escalation_advice'), loopFunction('escalate'),
        'if [ "$TEST_CAPPED" = "1" ]; then escalate; else jev_escalation_advice; fi',
        'printf "%s\\n" "$failures" "$RUNNER" "$REVIEWERS" "$REVIEW_ARTIFACT" "$REVIEW_RECEIPT" > "$TEST_VARIABLES"',
      ].join('\n');
      writeFileSync(shell, script);
      const environment = {
        PATH: process.env.PATH || '', TEST_FOLDER: folder, TEST_SCRIPT_DIR: resolve(root, 'scripts'),
        TEST_JOURNAL: journal, TEST_REVIEW: review, TEST_RECEIPT: receipt, TEST_VARIABLES: variables,
        TEST_CALLS: calls, TEST_INFO: resolve(folder, 'info.txt'), TEST_HALTED: scenario.halted ? '1' : '0',
        TEST_CAPPED: scenario.capped ? '1' : '0', TEST_PROVIDER_RC: String(scenario.providerRC || 0),
      };
      if (scenario.activation !== undefined) environment.GIBSON_JEV_ENABLED = scenario.activation;
      if (scenario.operator !== undefined) environment.GIBSON_JEV_OPERATOR_MODE = scenario.operator;
      const syntax = spawnSync('bash', ['-n', shell], { env: environment, encoding: 'utf8', timeout: 3000 });
      assert.ifError(syntax.error);
      assert.equal(syntax.status, 0, syntax.stderr);
      const result = spawnSync('bash', [shell], { env: environment, encoding: 'utf8', timeout: 3000 });
      assert.ifError(result.error);
      assert.equal(result.status, scenario.capped ? 1 : 0, result.stderr);
      assert.equal(existsSync(calls), scenario.invoked);
      if (scenario.invoked) {
        const args = readFileSync(calls, 'utf8').trim().split('\n');
        args[2] = resolve(args[2]);
        assert.deepEqual(args.slice(0, 9), ['15', 'node', resolve(root, 'scripts/jev-decision.mjs'),
          '--loop-summary', '--failures', '7', '--runner', 'codex', '--out']);
        assert.equal(args.length, 10, 'one bounded receipt call, with no coding or reviewer arguments');
        assert.equal(resolve(args[9], '..'), folder);
        assert.match(args[9].split('/').pop(), /^jev-escalation-[0-9]+-[0-9]+-[0-9]+\.json$/);
        const written = readFileSync(journal, 'utf8');
        assert.ok(written.includes(scenario.providerRC ? 'existing deterministic escalation continues' : 'no execution authority'));
      }
      assert.equal(readFileSync(review, 'utf8'), 'EXISTING_REVIEW_ARTIFACT');
      assert.equal(readFileSync(receipt, 'utf8'), 'EXISTING_DETERMINISTIC_REVIEW_RECEIPT');
      if (!scenario.capped) {
        assert.deepEqual(readFileSync(variables, 'utf8').trim().split('\n'), ['7', 'codex', 'claude,grok', review, receipt]);
      }
    });
  });
}
