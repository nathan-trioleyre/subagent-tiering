import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
GUARD_SRC = REPO / "hooks" / "guard.py"


def setup_installed_guard(root: Path, config: dict | None = None, agents: dict | None = None) -> Path:
    claude_dir = root / ".claude"
    tool_dir = claude_dir / "subagent-tiering"
    tool_dir.mkdir(parents=True)
    guard = tool_dir / "guard.py"
    shutil.copyfile(GUARD_SRC, guard)
    if config is not None:
        (tool_dir / "config.json").write_text(json.dumps(config), encoding="utf-8")
    if agents:
        agents_dir = claude_dir / "agents"
        agents_dir.mkdir(parents=True)
        for fname, content in agents.items():
            (agents_dir / fname).write_text(content, encoding="utf-8")
    return guard


def run_guard(guard: Path, payload: str | dict) -> subprocess.CompletedProcess:
    raw = payload if isinstance(payload, str) else json.dumps(payload)
    return subprocess.run([sys.executable, str(guard)], input=raw, capture_output=True, text=True)


class TestSubagentTieringGuard(unittest.TestCase):
    def test_blocks_dispatch_without_model(self):
        with tempfile.TemporaryDirectory() as tmp:
            guard = setup_installed_guard(Path(tmp))
            r = run_guard(guard, {"tool_input": {"subagent_type": "general-purpose"}})
            self.assertEqual(r.returncode, 2)
            self.assertIn("subagent-tiering:", r.stderr)

    def test_allows_dispatch_with_explicit_model_or_exempt_type(self):
        with tempfile.TemporaryDirectory() as tmp:
            guard = setup_installed_guard(Path(tmp))
            r1 = run_guard(guard, {"tool_input": {"subagent_type": "general-purpose", "model": "sonnet"}})
            self.assertEqual(r1.returncode, 0)
            r2 = run_guard(guard, {"tool_input": {"subagent_type": "fork"}})
            self.assertEqual(r2.returncode, 0)

    def test_allows_agent_with_own_model_case_insensitively(self):
        with tempfile.TemporaryDirectory() as tmp:
            t = Path(tmp)
            guard = setup_installed_guard(t, agents={"Explore.md": "---\nname: Explore\nmodel: \"haiku\"\n---\n"})
            r = run_guard(guard, {"tool_input": {"subagent_type": "explore"}})
            self.assertEqual(r.returncode, 0)

    def test_warn_mode_emits_context_and_exits_zero(self):
        with tempfile.TemporaryDirectory() as tmp:
            guard = setup_installed_guard(Path(tmp), config={"mode": "warn"})
            r = run_guard(guard, {"tool_input": {"subagent_type": "general-purpose"}})
            self.assertEqual(r.returncode, 0)
            out = json.loads(r.stdout)
            self.assertEqual(out["hookSpecificOutput"]["hookEventName"], "PreToolUse")
            self.assertIn("subagent-tiering:", out["hookSpecificOutput"]["additionalContext"])

    def test_fails_open_on_invalid_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            guard = setup_installed_guard(Path(tmp))
            r = run_guard(guard, "not-json")
            self.assertEqual(r.returncode, 0)


if __name__ == "__main__":
    unittest.main()
