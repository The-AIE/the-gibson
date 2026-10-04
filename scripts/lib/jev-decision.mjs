/** Jev is an optional advisory service. This module has no tool or gate authority. */
import { createHash } from 'node:crypto';

export const ENDPOINT = 'https://api.typesafe.ai/v1/systemone';
export const QUESTION_SET_VERSION = 'gibson.jev.questions/v1';
export const MAX_STATE_BYTES = 4096;
export const MAX_RESPONSE_BYTES = 32768;
export const DEFAULT_CONFIG = Object.freeze({
  enabled: false, model: 'jev-1.13.0', timeout_ms: 2000,
  min_confidence: 0.8, experiment_policy: 'excluded_from_scored_loop',
});
const object = v => v !== null && typeof v === 'object' && !Array.isArray(v);
const unit = v => typeof v === 'number' && Number.isFinite(v) && v >= 0 && v <= 1;
const integer = v => Number.isInteger(v) && v >= 0 && v <= 100;
const hashPattern = /^[a-f0-9]{64}$/;
const keys = (v, required, optional = []) => object(v)
  && required.every(k => Object.hasOwn(v, k))
  && Object.keys(v).every(k => required.includes(k) || optional.includes(k));
function fail(reason) { throw new Error(reason); }
function freeze(v) {
  for (const child of Object.values(v)) if (object(child) || Array.isArray(child)) freeze(child);
  return Object.freeze(v);
}
export function canonical(v) {
  if (Array.isArray(v)) return `[${v.map(canonical).join(',')}]`;
  if (object(v)) return `{${Object.keys(v).sort().map(k => `${JSON.stringify(k)}:${canonical(v[k])}`).join(',')}}`;
  return JSON.stringify(v);
}
const hash = v => createHash('sha256').update(canonical(v)).digest('hex');
const choice = (instructions, options) => ({type: 'choice', instructions, criteria: Object.fromEntries(options.map(v => [v, v.replaceAll('_', ' ')]))});
const risk = instructions => ({type: 'score', instructions, criteria: ['low', 'medium', 'high']});
const noul = instructions => ({type: 'noul', instructions});
export const QUESTION_SETS = freeze({
  'supervisor-escalation': {
    action: choice('Recommend a bounded operational action. Do not retry task failures merely to obtain a pass. Infrastructure retry is advice only.', ['continue', 'retry_infrastructure', 'stop', 'human_escalation']),
    needs_human: noul('Does this summary need human review? No evidence verification or approval authority.'),
    run_risk: risk('Rate operational risk from this summary.'),
  },
  'model-or-agent-routing': {
    route: choice('Recommend an operator route. Do not generate code or change dispatch policy.', ['hermes', 'codex', 'claude_code', 'grok', 'human']),
  },
  'tool-call-guard': {
    allow_tool_call: noul('Does the metadata suggest a low-risk call under the existing policy? This answer grants no permission.'),
    risk: risk('Rate the risk of this operation metadata. Existing deterministic permissions remain authoritative.'),
  },
  'benchmark-anomaly-triage': {
    anomaly_class: choice('Classify the reported anomaly for human triage. Do not change scores, labels, attempts, or verification.', ['expected_task_failure', 'infrastructure_failure', 'telemetry_corruption', 'requires_human_review']),
  },
});
const member = values => value => values.includes(value);
const phase = member(['plan', 'decompose', 'build', 'test', 'review', 'ux-eval', 'security', 'merge', 'deploy', 'retro', 'unknown']);
const health = member(['healthy', 'degraded', 'unavailable', 'unknown']);
const boolean = v => typeof v === 'boolean';
export const STATE_FIELDS = freeze({
  'supervisor-escalation': {phase, infrastructure_health: health, consecutive_failures: integer, retry_count: integer, gate_status: member(['unknown', 'red', 'green']), halted: boolean},
  'model-or-agent-routing': {phase, required_capability: member(['coding', 'review', 'operations', 'human_judgment']), infrastructure_health: health},
  'tool-call-guard': {tool_name: member(['read_file', 'write_file', 'shell', 'network', 'git', 'unknown']), operation: member(['read', 'write', 'execute', 'delete', 'publish', 'unknown']), scope: member(['local', 'staging', 'production', 'external', 'unknown']), has_credentials: boolean, touches_sensitive_data: boolean},
  'benchmark-anomaly-triage': {task_result: member(['passed', 'failed', 'blocked', 'unknown']), failure_category: member(['task', 'infrastructure', 'telemetry', 'unknown']), telemetry_integrity: member(['valid', 'corrupt', 'missing', 'unknown']), infrastructure_health: health, attempt_count: integer},
});

export function validateConfig(config) {
  if (!keys(config, Object.keys(DEFAULT_CONFIG)) || !boolean(config.enabled)
      || config.model !== DEFAULT_CONFIG.model
      || !Number.isInteger(config.timeout_ms) || config.timeout_ms < 50 || config.timeout_ms > 10000
      || !unit(config.min_confidence) || config.min_confidence < 0.5
      || !['excluded_from_scored_loop', 'identical_across_all_arms'].includes(config.experiment_policy)) fail('invalid_config');
  return config;
}
export function validateRequest(request) {
  if (!keys(request, ['use', 'state', 'experiment']) || typeof request.use !== 'string' || !Object.hasOwn(STATE_FIELDS, request.use)) fail('invalid_request');
  const fields = STATE_FIELDS[request.use];
  if (!keys(request.state, Object.keys(fields)) || !Object.entries(fields).every(([k, check]) => check(request.state[k]))) fail('invalid_state');
  if (Buffer.byteLength(canonical(request.state)) > MAX_STATE_BYTES) fail('state_too_large');
  if (!keys(request.experiment, ['mode'], ['frozen_policy_hash'])
      || !['operator', 'outside-scored-loop', 'scored'].includes(request.experiment.mode)
      || (Object.hasOwn(request.experiment, 'frozen_policy_hash') && (typeof request.experiment.frozen_policy_hash !== 'string' || !hashPattern.test(request.experiment.frozen_policy_hash)))) fail('invalid_experiment');
  return request;
}
export function policyHash(config) {
  validateConfig(config);
  return hash({config, endpoint: ENDPOINT, question_set_version: QUESTION_SET_VERSION, questions: QUESTION_SETS, max_state_bytes: MAX_STATE_BYTES, max_response_bytes: MAX_RESPONSE_BYTES, attempts: 1});
}

function distribution(p, expected) {
  if (!keys(p, expected) || !Object.values(p).every(unit)
      || Math.abs(Object.values(p).reduce((a, b) => a + b, 0) - 1) > 1e-6) fail('invalid_response');
}
export function validateAnswers(response, use, model) {
  if (!keys(response, ['model', 'answers'], ['usage']) || response.model !== model) fail('invalid_response');
  if (Object.hasOwn(response, 'usage') && (!keys(response.usage, ['input_tokens', 'output_tokens'])
      || !Object.values(response.usage).every(v => Number.isSafeInteger(v) && v >= 0))) fail('invalid_response');
  const questions = QUESTION_SETS[use];
  if (!keys(response.answers, Object.keys(questions))) fail('invalid_response');
  for (const [name, question] of Object.entries(questions)) {
    const answer = response.answers[name];
    if (!object(answer) || answer.type !== question.type) fail('invalid_response');
    if (question.type === 'noul') {
      if (!keys(answer, ['type', 'noul']) || !unit(answer.noul)) fail('invalid_response');
    } else if (question.type === 'choice') {
      const options = Object.keys(question.criteria);
      if (!keys(answer, ['type', 'choice', 'probabilities', 'confidence']) || !options.includes(answer.choice) || !unit(answer.confidence)) fail('invalid_response');
      distribution(answer.probabilities, options);
      if (answer.probabilities[answer.choice] < Math.max(...Object.values(answer.probabilities))) fail('invalid_response');
    } else {
      const levels = question.criteria.map((_, i) => String(i));
      if (!keys(answer, ['type', 'score', 'legend', 'probabilities', 'confidence']) || !unit(answer.confidence)
          || typeof answer.score !== 'number' || !Number.isFinite(answer.score)
          || answer.score < 0 || answer.score > question.criteria.length - 1
          || !keys(answer.legend, levels) || !levels.every(i => answer.legend[i] === question.criteria[Number(i)])) fail('invalid_response');
      distribution(answer.probabilities, levels);
      const weighted = levels.reduce((sum, i) => sum + Number(i) * answer.probabilities[i], 0);
      if (Math.abs(answer.score - weighted) > 1e-6) fail('invalid_response');
    }
  }
  return response.answers;
}

async function readResponse(response, signal) {
  if (!response.body || typeof response.body.getReader !== 'function') fail('invalid_response');
  const reader = response.body.getReader();
  const cancel = () => { try { void reader.cancel().catch(() => {}); } catch {} };
  signal.addEventListener('abort', cancel, {once: true});
  if (signal.aborted) cancel();
  const chunks = [];
  let size = 0;
  try {
    while (true) {
      const {done, value} = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > MAX_RESPONSE_BYTES) { cancel(); fail('response_too_large'); }
      chunks.push(Buffer.from(value));
    }
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch (error) {
    if (error?.message === 'response_too_large') throw error;
    fail('invalid_response');
  } finally { signal.removeEventListener('abort', cancel); reader.releaseLock(); }
}

export async function decide(request, {config = DEFAULT_CONFIG, env = {}, fetchImpl = globalThis.fetch, now = () => Date.now()} = {}) {
  const started = now();
  const receipt = {
    schema: 'gibson.jev.receipt/v1', authority: 'advisory', status: 'fallback',
    use: null, experiment_mode: null, model: null, endpoint: ENDPOINT,
    question_set_version: QUESTION_SET_VERSION, request_state_hash: null,
    policy_hash: null, typed_answers: null, latency_ms: 0,
    fallback_or_error: null, fallback: 'deterministic_or_human',
  };
  const finish = reason => {
    receipt.fallback_or_error = reason;
    receipt.latency_ms = Math.max(0, Math.round(now() - started));
    return receipt;
  };
  try { validateConfig(config); config = Object.freeze({...config}); receipt.policy_hash = policyHash(config); }
  catch { return finish('invalid_config'); }
  receipt.model = config.model;
  // An absent key must not become a requirement merely because the module is loaded.
  if (!config.enabled) { receipt.status = 'disabled'; return finish('disabled'); }
  try { validateRequest(request); request = JSON.parse(canonical(request)); } catch { return finish('invalid_request'); }
  receipt.use = request.use;
  receipt.experiment_mode = request.experiment.mode;
  receipt.request_state_hash = hash(request.state);
  if (request.use === 'model-or-agent-routing' && request.experiment.mode !== 'operator') return finish('routing_requires_operator_mode');
  if (request.experiment.mode === 'scored' && (config.experiment_policy !== 'identical_across_all_arms'
      || request.experiment.frozen_policy_hash !== receipt.policy_hash)) return finish('scored_loop_excluded');
  if (request.use === 'supervisor-escalation' && request.state.halted) return finish('halted');
  const key = env.TYPESAFE_API_KEY;
  if (typeof key !== 'string' || !key.trim() || /[\r\n]/.test(key)) return finish('missing_credentials');
  let timer;
  const controller = new AbortController();
  const deadline = new Promise((_, reject) => {
    timer = setTimeout(() => { controller.abort(); reject(new Error('timeout')); }, config.timeout_ms);
  });
  try {
    const payload = {model: config.model, state: request.state, questions: QUESTION_SETS[request.use]};
    const call = (async () => {
      const response = await fetchImpl(ENDPOINT, {method: 'POST', redirect: 'error', signal: controller.signal,
        headers: {Authorization: `Bearer ${key}`, 'Content-Type': 'application/json'}, body: JSON.stringify(payload)});
      if (!response.ok) {
        if (response.status === 401 || response.status === 403) fail('authentication_failed');
        if (response.status === 429 || response.status === 529) fail('rate_limited');
        fail('provider_unavailable');
      }
      return validateAnswers(await readResponse(response, controller.signal), request.use, config.model);
    })();
    const answers = await Promise.race([call, deadline]);
    receipt.typed_answers = answers;
    const uncertain = Object.values(answers).some(a => a.type === 'noul'
      ? Math.max(a.noul, 1 - a.noul) < config.min_confidence : a.confidence < config.min_confidence);
    if (uncertain) return finish('low_confidence');
    receipt.status = 'advisory';
    return finish(null);
  } catch (error) {
    const reasons = ['timeout', 'invalid_response', 'response_too_large', 'authentication_failed', 'rate_limited', 'provider_unavailable'];
    return finish(controller.signal.aborted ? 'timeout' : reasons.includes(error?.message) ? error.message : 'provider_unavailable');
  } finally { clearTimeout(timer); controller.abort(); }
}
