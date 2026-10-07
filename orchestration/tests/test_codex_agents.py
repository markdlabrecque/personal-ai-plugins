"""Tests for scripts/codex-agents: the stage agents as Codex agent tomls.

Run from the plugin dir:  python3 -m unittest discover -s tests -v
"""

import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
GEN = os.path.join(ROOT, "scripts", "codex-agents")


def parse_toml(text):
    """Enough TOML for the generated files: `key = "str"` and `key = '''...'''`."""
    out, lines, i = {}, text.splitlines(), 0
    while i < len(lines):
        line = lines[i]
        i += 1
        if not line.strip() or line.startswith("#"):
            continue
        key, _, val = line.partition(" = ")
        if val == "'''":
            body = []
            while lines[i] != "'''":
                body.append(lines[i])
                i += 1
            i += 1
            out[key] = "\n".join(body)
        else:
            import json
            out[key] = json.loads(val)
    return out


class CodexAgentsTests(unittest.TestCase):
    def generate(self):
        out = tempfile.mkdtemp()
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", out]))
        p = subprocess.run([sys.executable, GEN, "--out", out], capture_output=True,
                           text=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        return out, {n: parse_toml(open(os.path.join(out, n)).read())
                     for n in sorted(os.listdir(out))}

    def test_one_toml_per_stage_agent(self):
        _, agents = self.generate()
        self.assertEqual(sorted(agents), ["implementor.toml", "reporter.toml",
                                          "reviewer.toml", "test_writer.toml",
                                          "verifier.toml"])
        self.assertEqual(agents["test_writer.toml"]["name"], "test-writer")

    def test_sandbox_follows_the_tools(self):
        _, a = self.generate()
        self.assertEqual(a["reviewer.toml"]["sandbox_mode"], "read-only")
        self.assertNotIn("sandbox_mode", a["verifier.toml"])  # inherits: drives a browser
        for n in ("test_writer.toml", "implementor.toml", "reporter.toml"):
            self.assertEqual(a[n]["sandbox_mode"], "workspace-write")

    def test_models_map_to_codex_tiers(self):
        _, a = self.generate()
        self.assertEqual((a["reporter.toml"]["model"],
                          a["reporter.toml"]["model_reasoning_effort"]),
                         ("gpt-6-luna", "low"))
        # Reviewer and verifier: the sonnet tier's model, opus's effort.
        for n in ("reviewer.toml", "verifier.toml"):
            self.assertEqual((a[n]["model"], a[n]["model_reasoning_effort"]),
                             ("gpt-6.1-sol", "high"), n)
        self.assertEqual((a["test_writer.toml"]["model"],
                          a["test_writer.toml"]["model_reasoning_effort"]),
                         ("gpt-6.1-sol", "medium"))
        # The implementor's dispatcher picks its model and effort.
        self.assertNotIn("model", a["implementor.toml"])
        self.assertNotIn("model_reasoning_effort", a["implementor.toml"])

    def test_instructions_are_the_agent_body(self):
        _, a = self.generate()
        body = open(os.path.join(ROOT, "agents", "reviewer.md")).read().split("---", 2)[2]
        self.assertEqual(a["reviewer.toml"]["developer_instructions"], body.strip())
        self.assertIn("orchestration pipeline", a["reviewer.toml"]["description"])


if __name__ == "__main__":
    unittest.main()
