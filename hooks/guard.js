#!/usr/bin/env node
// subagent-tiering — PreToolUse hook (Agent|Task) for every sub-agent, whichever skill, plugin
// or workflow launches it. It refuses a dispatch with no explicit model ("block" mode) or reminds
// Claude of the tiers ("warn" mode), unless the agent type pins its own model (an
// agents/<type>.md with `model:`) or is exempt. Fails open: any internal error lets it through.

const fs = require('fs');
const path = require('path');
const os = require('os');

// Installed as <claude dir>/subagent-tiering/guard.js; config.json lives next to it.
const TOOL_DIR = __dirname;
const HOME_DIR = path.basename(TOOL_DIR) === 'subagent-tiering'
  ? path.dirname(TOOL_DIR) : path.join(os.homedir(), '.claude');
const CONFIG_FILE = path.join(TOOL_DIR, 'config.json');

const DEFAULT_CONFIG = {
  mode: 'block',                 // "block" | "warn"
  exemptAgentTypes: ['fork', 'statusline-setup', 'claude-code-guide'],
};

function loadConfig() {
  try { return { ...DEFAULT_CONFIG, ...JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8')) }; }
  catch { return DEFAULT_CONFIG; }
}

// Does a user/project agent definition pin its own model?
function agentHasOwnModel(type, cwd) {
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

const GUIDANCE = [
  'subagent-tiering: sub-agent dispatched without an explicit `model`.',
  'It would inherit the session model (often the most expensive). Re-dispatch with `model` (and `effort`) set by tier:',
  '  - cheap  -> model: "haiku",  effort: "low"    : search, reading, mechanical edits with a complete spec',
  '  - mid    -> model: "sonnet", effort: "medium" : default — implementation, debugging, normal reviews',
  '  - top    -> model: "opus",   effort: "medium" : architecture, subtle/high-risk review, a fix that failed 3+ times',
  'For pure research use the `Explore` agent (already pinned to Haiku). Or skip the sub-agent (< ~5 tool calls: do it inline).',
].join('\n');

function onDispatch(input) {
  const ti = input.tool_input || {};
  if (ti.model) return;
  const type = ti.subagent_type || 'general-purpose';
  const cfg = loadConfig();
  if (cfg.exemptAgentTypes.includes(type) || agentHasOwnModel(type, input.cwd)) return;

  if (cfg.mode === 'warn') {
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: { hookEventName: 'PreToolUse', additionalContext: GUIDANCE },
    }));
    return;
  }
  process.stderr.write(GUIDANCE + '\n');
  process.exit(2);
}

let data = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', c => { data += c; });
process.stdin.on('end', () => {
  try { onDispatch(JSON.parse(data)); } catch { /* fail open */ }
  process.exit(0);
});
