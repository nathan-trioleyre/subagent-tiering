#!/usr/bin/env bash
# Installs (or removes) subagent-tiering into the user's global Claude Code config (~/.claude).
# Usage: ./install.sh [--uninstall] [--claude-dir PATH]
# Requires: python3 (to merge settings.json safely and run the guard hook).
set -euo pipefail

NAME="subagent-tiering"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${HOME}/.claude"
UNINSTALL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall) UNINSTALL=1 ;;
    --claude-dir) CLAUDE_DIR="$2"; shift ;;
    -h|--help) sed -n '2,4p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "python3 is required" >&2; exit 1; }

TOOL_DIR="$CLAUDE_DIR/$NAME"
LEGACY_DIR="$CLAUDE_DIR/model-router"
mkdir -p "$CLAUDE_DIR/agents"

# 1. Agents (+ retire agents shipped by earlier versions, only if they still look like our copies)
retire() { local f="$CLAUDE_DIR/agents/$1"; if [ -f "$f" ] && grep -qF "$2" "$f"; then rm -f "$f"; echo "  - retired agent $1 removed"; fi; }
retire worker.md    "description: Implementer for a well-defined"
retire reviewer.md  "description: Independent code reviewer. Use after a non-trivial change"
retire architect.md "description: Expensive deep thinker"
retire scout.md     "description: Fast, cheap read-only researcher"
for f in "$REPO_DIR"/agents/*.md; do
  name="$(basename "$f")"; target="$CLAUDE_DIR/agents/$name"
  if [ "$UNINSTALL" = 1 ]; then
    if [ -f "$target" ] && grep -qF "managed by $NAME" "$target"; then rm -f "$target"; echo "  - agent $name removed"; fi
    if [ -f "$target.bak" ] && [ ! -f "$target" ]; then mv "$target.bak" "$target"; echo "  + your previous $name restored"; fi
  else
    if [ -f "$target" ] && ! grep -qF "managed by $NAME" "$target"; then cp "$target" "$target.bak"; echo "  ! existing $name backed up to $name.bak"; fi
    cp "$f" "$target"; echo "  + agent $name"
  fi
done

# 2. Hook files (+ migration from the legacy folder)
if [ -f "$LEGACY_DIR/guard.js" ]; then
  if [ "$UNINSTALL" = 0 ]; then
    mkdir -p "$TOOL_DIR"
    if [ -f "$LEGACY_DIR/config.json" ] && [ ! -f "$TOOL_DIR/config.json" ]; then mv "$LEGACY_DIR/config.json" "$TOOL_DIR/config.json"; fi
  fi
  rm -rf "$LEGACY_DIR"; echo "  - legacy folder $LEGACY_DIR migrated and removed"
fi
INSTALL_HOOK=0
if [ "$UNINSTALL" = 1 ]; then
  rm -rf "$TOOL_DIR" && echo "  - $TOOL_DIR removed"
else
  INSTALL_HOOK=1
  mkdir -p "$TOOL_DIR"
  cp "$REPO_DIR/hooks/guard.py" "$TOOL_DIR/guard.py"
  if [ -f "$TOOL_DIR/guard.js" ]; then rm -f "$TOOL_DIR/guard.js"; echo "  - old guard.js removed"; fi
  # journal of earlier versions, no longer written
  if [ -f "$TOOL_DIR/dispatch.log" ]; then rm -f "$TOOL_DIR/dispatch.log"; echo "  - old dispatch.log removed"; fi
  [ -f "$TOOL_DIR/config.json" ] || cp "$REPO_DIR/hooks/config.json" "$TOOL_DIR/config.json"
  echo "  + hook copied to $TOOL_DIR (config.json kept if it already existed)"
fi

# 3 & 4. CLAUDE.md managed block + settings.json (env vars, hooks)
[ -f "$CLAUDE_DIR/settings.json" ] && cp "$CLAUDE_DIR/settings.json" "$CLAUDE_DIR/settings.json.bak"

"$PY" - "$REPO_DIR" "$CLAUDE_DIR" "$UNINSTALL" "$INSTALL_HOOK" "$NAME" <<'PYEOF'
import json, os, re, sys
repo, cdir, uninstall, install_hook, name = sys.argv[1], sys.argv[2], sys.argv[3] == "1", sys.argv[4] == "1", sys.argv[5]
start, end = f"<!-- {name}:start -->", f"<!-- {name}:end -->"
legacy_start, legacy_end = "<!-- claude-model-router:start -->", "<!-- claude-model-router:end -->"
legacy_heading = "Model & sub-agent routing (token economy)"
hook_tags = (f"{name}/guard.py", f"{name}/guard.js", "model-router/guard.js")

def remove_block(text, s, e, must_contain=None):
    pat = re.compile(r"\n?" + re.escape(s) + r"(.*?)" + re.escape(e) + r"\n?", re.S)
    return pat.sub(lambda m: "\n" if (must_contain is None or must_contain in m.group(1)) else m.group(0), text)

md_path = os.path.join(cdir, "CLAUDE.md")
text = open(md_path, encoding="utf-8").read() if os.path.exists(md_path) else ""
text = remove_block(text, start, end)
text = remove_block(text, legacy_start, legacy_end, legacy_heading).rstrip()
if not uninstall:
    rules = open(os.path.join(repo, "rules", "CLAUDE.md"), encoding="utf-8").read().rstrip()
    block = f"{start}\n{rules}\n{end}"
    text = f"{text}\n\n{block}" if text else block
if text or os.path.exists(md_path):
    open(md_path, "w", encoding="utf-8", newline="\n").write(text + "\n")
print(("  - rules removed from " if uninstall else "  + rules written to ") + md_path)

s_path = os.path.join(cdir, "settings.json")
settings = json.load(open(s_path, encoding="utf-8")) if os.path.exists(s_path) else {}

env_vars = json.load(open(os.path.join(repo, "settings", "env.json"), encoding="utf-8"))
env = settings.setdefault("env", {})
for k, v in env_vars.items():
    if uninstall: env.pop(k, None)
    else: env[k] = v
if not env: settings.pop("env")

# top-level keys (e.g. default model); on uninstall, removed only if still our value
for k, v in json.load(open(os.path.join(repo, "settings", "settings.json"), encoding="utf-8")).items():
    if uninstall:
        if settings.get(k) == v: settings.pop(k)
    else:
        settings[k] = v

def ours(entry):
    return any(t in (h.get("command") or "") for h in entry.get("hooks", []) for t in hook_tags)

hooks = settings.setdefault("hooks", {})
cmd = f'"{sys.executable}" "' + os.path.join(cdir, name, "guard.py").replace("\\", "/") + '"'
# SubagentStop: no entry any more, only removes the measurement hook added by earlier versions.
new = {
    "PreToolUse": {"matcher": "Agent|Task", "hooks": [{"type": "command", "command": cmd, "timeout": 10}]},
    "SubagentStop": None,
}
for event, entry in new.items():
    lst = [e for e in hooks.get(event, []) if not ours(e)]
    if install_hook and entry: lst.append(entry)
    if lst: hooks[event] = lst
    else: hooks.pop(event, None)
if not hooks: settings.pop("hooks")

open(s_path, "w", encoding="utf-8", newline="\n").write(json.dumps(settings, indent=2) + "\n")
print(("  - env vars and hooks removed from " if uninstall else "  + env vars and hooks set in ") + s_path + " (backup: settings.json.bak)")
PYEOF

echo
if [ "$UNINSTALL" = 1 ]; then echo "$NAME uninstalled."; else echo "$NAME installed. Restart Claude Code sessions to pick it up."; fi
