#!/usr/bin/env python3
"""subagent-tiering — PreToolUse hook (Agent|Task) for every sub-agent.

Refuses a dispatch with no explicit `model` ("block" mode) or reminds Claude of
the tiers ("warn" mode), unless the agent type pins its own model (an
agents/<type>.md with `model:`) or is exempt. Fails open on internal errors.
"""
import json
import os
import re
import sys
from pathlib import Path

TOOL_DIR = Path(__file__).resolve().parent
HOME_DIR = TOOL_DIR.parent if TOOL_DIR.name == "subagent-tiering" else Path.home() / ".claude"
CONFIG_FILE = TOOL_DIR / "config.json"

DEFAULT_CONFIG = {
    "mode": "block",  # "block" | "warn"
    "exemptAgentTypes": ["fork", "statusline-setup", "claude-code-guide"],
}

GUIDANCE = "\n".join([
    "subagent-tiering: sub-agent dispatched without an explicit `model`.",
    "It would inherit the session model (often the most expensive). Re-dispatch with `model` (and `effort`) set by tier:",
    '  - cheap  -> model: "haiku",  effort: "low"    : search, reading, mechanical edits with a complete spec',
    '  - mid    -> model: "sonnet", effort: "medium" : default — implementation, debugging, normal reviews',
    '  - top    -> model: "opus",   effort: "medium" : architecture, subtle/high-risk review, a fix that failed 3+ times',
    "For pure research use the `Explore` agent (already pinned to Haiku). Or skip the sub-agent (< ~5 tool calls: do it inline).",
])


def load_config() -> dict:
    try:
        data = json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
        return {**DEFAULT_CONFIG, **(data if isinstance(data, dict) else {})}
    except Exception:
        return dict(DEFAULT_CONFIG)


def _find_agent_file(agents_dir: Path, name: str) -> Path | None:
    exact = agents_dir / f"{name}.md"
    if exact.is_file():
        return exact
    if agents_dir.is_dir():
        target_low = f"{name}.md".lower()
        for entry in agents_dir.iterdir():
            if entry.is_file() and entry.name.lower() == target_low:
                return entry
    return None


def agent_has_own_model(agent_type: str, cwd: str | None) -> bool:
    name = agent_type.split(":")[-1] if ":" in agent_type else agent_type
    dirs = [HOME_DIR / "agents"]
    if cwd:
        dirs.insert(0, Path(cwd) / ".claude" / "agents")
    for agents_dir in dirs:
        agent_file = _find_agent_file(agents_dir, name)
        if not agent_file:
            continue
        try:
            text = agent_file.read_text(encoding="utf-8")
            fm = re.match(r"^---\r?\n([\s\S]*?)\r?\n---", text)
            if fm:
                m = re.search(r"^model:\s*[\"']?([^\s\"']+)[\"']?", fm.group(1), re.MULTILINE)
                if m and m.group(1).lower() != "inherit":
                    return True
        except Exception:
            pass
    return False


def on_dispatch(payload: dict) -> int:
    ti = payload.get("tool_input") or {}
    if ti.get("model"):
        return 0
    agent_type = ti.get("subagent_type") or "general-purpose"
    cfg = load_config()
    if agent_type in cfg.get("exemptAgentTypes", []) or agent_has_own_model(agent_type, payload.get("cwd")):
        return 0

    if cfg.get("mode") == "warn":
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "additionalContext": GUIDANCE,
            }
        }))
        return 0

    print(GUIDANCE, file=sys.stderr)
    return 2


def main() -> int:
    try:
        payload = json.loads(sys.stdin.read())
        if not isinstance(payload, dict):
            return 0
        return on_dispatch(payload)
    except Exception:
        return 0  # fail open


if __name__ == "__main__":
    sys.exit(main())
