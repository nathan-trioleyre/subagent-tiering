#!/usr/bin/env node
// subagent-tiering — hook for every sub-agent, whichever skill, plugin or workflow launches it.
//
//   PreToolUse (Agent|Task) : logs the dispatch; in "block" mode refuses a dispatch with no
//                             explicit model, unless the agent type pins its own model
//                             (an agents/<type>.md with `model:`) or is exempt.
//   SubagentStop            : reads the sub-agent's transcript and logs the real token usage.
//
// Report:  node guard.js --report [days]
// Fails open: any internal error lets the dispatch through.

const fs = require('fs');
const path = require('path');
const os = require('os');

// Installed as <claude dir>/subagent-tiering/guard.js; config and log live next to it.
const TOOL_DIR = __dirname;
const HOME_DIR = path.basename(TOOL_DIR) === 'subagent-tiering'
  ? path.dirname(TOOL_DIR) : path.join(os.homedir(), '.claude');
const LOG_FILE = path.join(TOOL_DIR, 'dispatch.log');
const CONFIG_FILE = path.join(TOOL_DIR, 'config.json');

const DEFAULT_CONFIG = {
  mode: 'block',                 // "block" | "warn" | "log"
  exemptAgentTypes: ['fork', 'statusline-setup', 'claude-code-guide'],
};

function loadConfig() {
  try { return { ...DEFAULT_CONFIG, ...JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8')) }; }
  catch { return DEFAULT_CONFIG; }
}

// Does a user/project agent definition pin its own model?
function agentHasOwnModel(type, cwd) {
  if (!type) return false;
  const name = type.includes(':') ? type.split(':').pop() : type;
  const dirs = [path.join(HOME_DIR, 'agents')];
  if (cwd) dirs.unshift(path.join(cwd, '.claude', 'agents'));
  for (const dir of dirs) {
    try {
      const text = fs.readFileSync(path.join(dir, `${name}.md`), 'utf8');
      const fm = text.match(/^---\r?\n([\s\S]*?)\r?\n---/);
      const m = fm && fm[1].match(/^model:\s*(\S+)/m);
      if (m && m[1] !== 'inherit') return true;
    } catch { /* not found */ }
  }
  return false;
}

function log(entry) {
  try {
    fs.mkdirSync(TOOL_DIR, { recursive: true });
    fs.appendFileSync(LOG_FILE, JSON.stringify(entry) + '\n');
  } catch { /* ignore */ }
}

const GUIDANCE = [
  'subagent-tiering: sub-agent dispatched without an explicit `model`.',
  'It would inherit the session model (often the most expensive). Re-dispatch with `model` (and `effort`) set by tier:',
  '  - cheap  -> model: "haiku",  effort: "low"    : search, reading, mechanical edits with a complete spec',
  '  - mid    -> model: "sonnet", effort: "medium" : default — implementation, debugging, normal reviews',
  '  - top    -> model: "opus",   effort: "medium" : architecture, subtle/high-risk review, a fix that failed 3+ times',
  'For pure research use the `Explore` agent (already pinned to Haiku). Or skip the sub-agent (< ~5 tool calls: do it inline).',
].join('\n');

// ---------------------------------------------------------------- PreToolUse
function onDispatch(input) {
  const ti = input.tool_input || {};
  const type = ti.subagent_type || 'general-purpose';
  const cfg = loadConfig();

  const explicit = Boolean(ti.model);
  const exempt = cfg.exemptAgentTypes.includes(type) || agentHasOwnModel(type, input.cwd);
  const missing = !explicit && !exempt;
  const decision = missing ? (cfg.mode === 'block' ? 'blocked' : cfg.mode === 'warn' ? 'warned' : 'logged')
                           : 'allowed';

  log({
    ts: new Date().toISOString(), event: 'dispatch',
    session: input.session_id, cwd: input.cwd, type,
    model: ti.model || (exempt ? 'agent-default' : 'inherit'),
    effort: ti.effort || (exempt ? 'agent-default' : null),
    description: ti.description || null,
    decision,
  });

  if (decision === 'blocked') { process.stderr.write(GUIDANCE + '\n'); process.exit(2); }
  if (decision === 'warned') {
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: { hookEventName: 'PreToolUse', additionalContext: GUIDANCE },
    }));
  }
}

// -------------------------------------------------------------- SubagentStop
function subagentTranscript(input) {
  if (input.agent_transcript_path && fs.existsSync(input.agent_transcript_path)) return input.agent_transcript_path;
  if (!input.transcript_path || !input.agent_id) return null;
  const p = path.join(path.dirname(input.transcript_path), input.session_id || '',
                      'subagents', `agent-${input.agent_id}.jsonl`);
  return fs.existsSync(p) ? p : null;
}

function onSubagentStop(input) {
  const file = subagentTranscript(input);
  if (!file) return;
  const seen = new Set();
  const byModel = {};
  for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
    if (!line) continue;
    let rec; try { rec = JSON.parse(line); } catch { continue; }
    const msg = rec.type === 'assistant' && rec.message;
    if (!msg || !msg.usage || seen.has(msg.id)) continue;
    seen.add(msg.id);
    const u = msg.usage;
    const t = byModel[msg.model || 'unknown'] ||= { input: 0, cacheWrite: 0, cacheRead: 0, output: 0, calls: 0 };
    t.input += u.input_tokens || 0;
    t.cacheWrite += u.cache_creation_input_tokens || 0;
    t.cacheRead += u.cache_read_input_tokens || 0;
    t.output += u.output_tokens || 0;
    t.calls += 1;
  }
  for (const [model, t] of Object.entries(byModel)) {
    log({ ts: new Date().toISOString(), event: 'usage', session: input.session_id,
          agentId: input.agent_id, type: input.agent_type || null, model, ...t });
  }
}

// -------------------------------------------------------------------- report
function report(days) {
  let lines = [];
  try { lines = fs.readFileSync(LOG_FILE, 'utf8').trim().split('\n').filter(Boolean); }
  catch { console.log('Nothing logged yet.'); return; }
  const since = Date.now() - days * 86400000;
  const rows = lines.map(l => { try { return JSON.parse(l); } catch { return null; } })
                    .filter(r => r && Date.parse(r.ts) >= since);
  const dispatches = rows.filter(r => (r.event || 'dispatch') === 'dispatch');
  // SubagentStop can fire several times for one agent and each entry re-reads the whole
  // transcript (cumulative totals): keep only the latest entry per agent and model.
  const latest = new Map();
  rows.filter(r => r.event === 'usage').forEach(r => latest.set(`${r.agentId}|${r.model}`, r));
  const usage = [...latest.values()];
  const fmt = n => n.toLocaleString('en-US');

  console.log(`Sub-agent dispatches, last ${days} day(s): ${dispatches.length}\n`);
  const count = (list, key) => list.reduce((acc, r) => { const k = key(r); acc[k] = (acc[k] || 0) + 1; return acc; }, {});
  for (const [title, fn] of [['By requested model', r => r.model], ['By effort', r => r.effort || '(default)'],
                             ['By agent type', r => r.type], ['By decision', r => r.decision]]) {
    console.log(title);
    Object.entries(count(dispatches, fn)).sort((a, b) => b[1] - a[1])
      .forEach(([k, v]) => console.log(`  ${String(v).padStart(5)}  ${k}`));
    console.log('');
  }

  if (!usage.length) { console.log('No token usage recorded yet (needs the SubagentStop hook).'); return; }
  const sum = (list, key) => list.reduce((acc, r) => {
    const k = key(r); const a = acc[k] ||= { agents: new Set(), input: 0, cacheWrite: 0, cacheRead: 0, output: 0 };
    a.agents.add(r.agentId); a.input += r.input; a.cacheWrite += r.cacheWrite; a.cacheRead += r.cacheRead; a.output += r.output;
    return acc; }, {});
  for (const [title, fn] of [['Real token usage by model', r => r.model], ['Real token usage by agent type', r => r.type || '?']]) {
    console.log(title);
    console.log('  agents       input  cache write   cache read       output  name');
    Object.entries(sum(usage, fn)).sort((a, b) => (b[1].input + b[1].cacheWrite + b[1].output) - (a[1].input + a[1].cacheWrite + a[1].output))
      .forEach(([k, a]) => console.log(`  ${String(a.agents.size).padStart(6)} ${fmt(a.input).padStart(11)} ${fmt(a.cacheWrite).padStart(12)} ${fmt(a.cacheRead).padStart(12)} ${fmt(a.output).padStart(12)}  ${k}`));
    console.log('');
  }
}

// ---------------------------------------------------------------------- main
if (process.argv[2] === '--report') {
  report(Number(process.argv[3]) || 7);
} else {
  let data = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', c => { data += c; });
  process.stdin.on('end', () => {
    try {
      const input = JSON.parse(data);
      if (input.hook_event_name === 'SubagentStop') onSubagentStop(input);
      else onDispatch(input);
    } catch { /* fail open */ }
    process.exit(0);
  });
}
