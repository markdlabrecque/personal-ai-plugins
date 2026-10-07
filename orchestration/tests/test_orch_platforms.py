"""Black-box tests for the platform, hook and session-health parts of scripts/orch.

Contract: skills/orchestration/references/orch-cli.md ("Platforms", "Session
health", "Hooks", "Launching sessions", and the platform-aware commands).

Run from the plugin dir:  python3 -m unittest discover -s tests -v
"""

import json
import os
import re
import shlex
import signal
import subprocess
import sys
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from test_orch import OrchTestCase, list_in, read_file, wait_until  # noqa: E402

PLUGIN = os.path.realpath(os.path.join(HERE, ".."))
SCRUB_PREFIXES = ("ORCH_", "ORCA_", "HERDR_")
SCRUB_KEYS = ("CLAUDE_CODE_ENTRYPOINT",)

ORCA_CREATE_OK = {"result": {"terminal": {"handle": "term_abc"}}}
HERDR_CREATE_OK = {
    "result": {
        "workspace": {"workspace_id": "w1"},
        "tab": {"tab_id": "w1:t1"},
        "root_pane": {"pane_id": "w1:p1"},
    }
}
EMPTY_OK = {"result": {}}


class PlatformTestCase(OrchTestCase):
    """OrchTestCase with every platform-detection variable scrubbed, so the
    suite behaves the same inside Claude Desktop, Orca, Herdr or a plain shell."""

    def setUp(self):
        super().setUp()
        for k in list(self.env):
            if k.startswith(SCRUB_PREFIXES) or k in SCRUB_KEYS:
                if k != "ORCH_CLAUDE_BIN":
                    del self.env[k]
        self.set_test_platform_env()
        self._platform_records = {}
        self.init()

    # ---- fakes ---------------------------------------------------------------

    def fake_platform(self, name, responses=None):
        """A fake orca/herdr: appends argv to <tmp>/<name>-calls.jsonl and replies
        per the first two argv words. `responses` maps "terminal create" etc. to
        (exit_code, stdout_text_or_obj). Unlisted commands reply {"result":{}}."""
        responses = dict(responses or {})
        default = ORCA_CREATE_OK if name == "orca" else HERDR_CREATE_OK
        key = "terminal create" if name == "orca" else "worktree open"
        responses.setdefault(key, (0, default))
        table = {}
        for k, (rc, out) in responses.items():
            table[k] = [rc, out if isinstance(out, str) else json.dumps(out)]
        self._fake_count += 1
        record = os.path.join(self.tmp, "%s-calls.jsonl" % name)
        path = os.path.join(self.tmp, "fake-%s-%d" % (name, self._fake_count))
        with open(path, "w") as f:
            f.write(
                "#!%s\n"
                "import json, sys\n"
                "a = sys.argv[1:]\n"
                "with open(%r, 'a') as f:\n"
                "    f.write(json.dumps(a) + '\\n')\n"
                "table = json.loads(%r)\n"
                "rc, out = table.get(' '.join(a[:2]), [0, json.dumps({'result': {}})])\n"
                "print(out)\n"
                "if rc:\n"
                "    print('fake %s failed', file=sys.stderr)\n"
                "sys.exit(rc)\n" % (sys.executable, record, json.dumps(table), name)
            )
        os.chmod(path, 0o755)
        self._platform_records[name] = record
        return path

    def pcalls(self, name, waits=False):
        """Recorded argv lists. Orca's `terminal wait` (the folder-trust probe
        after every `terminal create`) is left out unless `waits`."""
        record = os.path.join(self.tmp, "%s-calls.jsonl" % name)
        if not os.path.exists(record):
            return []
        with open(record) as f:
            calls = [json.loads(line) for line in f if line.strip()]
        return [c for c in calls if waits or c[:2] != ["terminal", "wait"]]

    def use_orca(self, responses=None):
        self.env["ORCH_ORCA_BIN"] = self.fake_platform("orca", responses)

    def use_herdr(self, responses=None):
        self.env["ORCH_HERDR_BIN"] = self.fake_platform("herdr", responses)

    def live_process(self, delay_before=0.0):
        """A long-lived process standing in for the claude process a hook runs
        under. Its command line carries no session id."""
        if delay_before:
            time.sleep(delay_before)
        p = subprocess.Popen(["sleep", "60"], start_new_session=True)

        def cleanup():
            if p.poll() is None:
                p.kill()
            p.wait()
        self.addCleanup(cleanup)
        return p

    # ---- repo helpers --------------------------------------------------------

    def git_wt(self, name):
        path = os.path.join(self.tmp, "gwt-" + name)
        self.git("worktree", "add", "-q", "-b", "br-" + name, path)
        return os.path.realpath(path)

    def write_brief(self, text, name="brief-x.md"):
        path = os.path.join(self.tmp, name)
        with open(path, "w") as f:
            f.write(text)
        return path

    def spawn_on(self, ticket, platform, worktree, title="A ticket", extra=()):
        self.add(ticket, title)
        return self.ok("spawn", ticket, "--worktree", worktree, "--brief-file",
                       self.brief, "--platform", platform, *extra)

    def hook(self, event, sid, cwd, pid=None, extra=None, raw=None, proc_cwd=None):
        payload = {"session_id": sid, "cwd": cwd, "hook_event_name": event}
        if event == "SessionStart":
            payload["source"] = "startup"
        if event == "SessionEnd":
            payload["reason"] = "logout"
        if extra:
            payload.update(extra)
        e = dict(self.env)
        if pid is not None:
            e["ORCH_HOOK_CLAUDE_PID"] = str(pid)
        else:
            # Never let the walk find the real claude running this suite.
            e["ORCH_HOOK_CLAUDE_PID"] = str(self.live_process().pid)
        return subprocess.run(
            [os.path.join(PLUGIN, "scripts", "orch"), "hook"],
            input=raw if raw is not None else json.dumps(payload),
            cwd=proc_cwd or (cwd if os.path.isdir(cwd) else self.tmp),
            env=e, capture_output=True, text=True, timeout=30,
        )

    def hook_ok(self, *a, **kw):
        p = self.hook(*a, **kw)
        self.assertEqual(p.returncode, 0, "hook rc=%s stderr=%r" % (p.returncode, p.stderr))
        return p

    def run_cmd(self, cmd, cwd):
        """Execute a platform `<cmd>` string through sh the way a terminal would,
        with a fake `claude` both as ORCH_CLAUDE_BIN and on PATH; return its argv."""
        before = len(self.calls())
        fake = self.fake_claude(sleep=0)
        bindir = os.path.join(self.tmp, "claude-bin-%d" % self._fake_count)
        os.makedirs(bindir)
        os.symlink(fake, os.path.join(bindir, "claude"))
        e = dict(self.env)
        e["PATH"] = bindir + os.pathsep + e.get("PATH", "/usr/bin:/bin")
        p = subprocess.run(["sh", "-c", cmd], cwd=cwd, env=e,
                           stdin=subprocess.DEVNULL, capture_output=True, text=True,
                           timeout=30)
        self.assertEqual(p.returncode, 0, "cmd failed: %r %r" % (cmd, p.stderr))
        calls = self.calls()
        self.assertEqual(len(calls), before + 1, "cmd did not run claude: %r" % cmd)
        return calls[-1]["argv"]

    def event_kinds(self, ticket):
        return [e["kind"] for e in self.events(ticket)]


# ---------------------------------------------------------------------------


class PlatformDetectionTests(PlatformTestCase):
    """ORCH_PLATFORM, else the platform the environment shows, else headless
    (platforms.md "Platform resolution")."""

    def detect(self, **env):
        return self.j("platform", env=env)["platform"]

    def detected(self, **env):
        del self.env["ORCH_PLATFORM"]
        out = self.j("platform", env=env)
        self.env["ORCH_PLATFORM"] = "headless"
        return out["platform"]

    def test_default_headless(self):
        self.assertEqual(self.detected(), "headless")

    def test_orch_platform_override(self):
        for value in ("headless", "orca", "herdr", "desktop"):
            self.assertEqual(self.detect(ORCH_PLATFORM=value, HERDR_ENV="1"), value)

    def test_invalid_orch_platform_is_usage_error(self):
        self.refused(2, "platform", env={"ORCH_PLATFORM": "tmux"})

    def test_herdr_env(self):
        self.assertEqual(self.detected(HERDR_ENV="1"), "herdr")
        self.assertEqual(self.detected(HERDR_ENV="1", ORCA_TERMINAL_HANDLE="h",
                                       CLAUDE_CODE_ENTRYPOINT="claude-desktop"), "herdr")

    def test_orca_env(self):
        self.assertEqual(self.detected(ORCA_TERMINAL_HANDLE="h"), "orca")
        self.assertEqual(self.detected(ORCA_WORKTREE_ID="w"), "orca")
        self.assertEqual(self.detected(ORCA_WORKTREE_ID="w",
                                       CLAUDE_CODE_ENTRYPOINT="claude-desktop"), "orca")

    def test_desktop_env(self):
        self.assertEqual(self.detected(CLAUDE_CODE_ENTRYPOINT="claude-desktop"), "desktop")
        self.assertEqual(self.detected(CLAUDE_CODE_ENTRYPOINT="cli", CLAUDECODE="1"),
                         "headless")

    def test_spawn_rejects_unknown_platform(self):
        self.add("T-1")
        self.refused(2, "spawn", "T-1", "--worktree", self.worktree,
                     "--brief-file", self.brief, "--platform", "tmux")
        self.assertEqual(self.show("T-1")["phase"], "ready")


class PlatformPreflightTests(PlatformTestCase):
    def setUp(self):
        super().setUp()
        self.bin = os.path.join(self.tmp, "bin")
        os.makedirs(self.bin)
        os.symlink(subprocess.run(["sh", "-c", "command -v git"], capture_output=True,
                                  text=True).stdout.strip() or "/usr/bin/git",
                   os.path.join(self.bin, "git"))
        os.symlink(sys.executable, os.path.join(self.bin, "python3"))
        self.env["PATH"] = self.bin + os.pathsep + "/usr/bin:/bin:/usr/sbin:/sbin"
        for d in ("/usr/bin", "/bin", "/usr/sbin", "/sbin"):
            for tool in ("ddev", "orca", "herdr"):
                if os.path.exists(os.path.join(d, tool)):
                    self.skipTest("%s/%s exists; cannot control PATH" % (d, tool))
        with open(os.path.join(self.repo, ".env"), "w") as f:
            f.write("BASE_BRANCH=main\n")
        os.makedirs(os.path.join(self.repo, ".ddev"))
        with open(os.path.join(self.repo, ".ddev", "config.yaml"), "w") as f:
            f.write("name: test\n")
        self.fake_tool("ddev")

    def fake_tool(self, name):
        p = os.path.join(self.bin, name)
        with open(p, "w") as f:
            f.write("#!/bin/sh\nexit 0\n")
        os.chmod(p, 0o755)

    def test_reports_platform(self):
        self.assertEqual(self.j("preflight")["platform"], "headless")
        self.assertEqual(self.j("preflight", env={"ORCH_PLATFORM": "desktop"})["platform"],
                         "desktop")

    def test_orca_without_binary_fails(self):
        p = self.refused(5, "preflight", env={"ORCH_PLATFORM": "orca"})
        self.assertIn("orca", p.stdout + p.stderr)
        self.fake_tool("orca")
        self.assertEqual(self.j("preflight", env={"ORCH_PLATFORM": "orca"})["platform"],
                         "orca")

    def test_herdr_without_binary_fails(self):
        p = self.refused(5, "preflight", env={"ORCH_PLATFORM": "herdr"})
        self.assertIn("herdr", p.stdout + p.stderr)
        self.fake_tool("herdr")
        self.assertEqual(self.j("preflight", env={"ORCH_PLATFORM": "herdr"})["platform"],
                         "herdr")

    def test_platform_failure_listed_with_others(self):
        os.remove(os.path.join(self.repo, ".env"))
        p = self.refused(5, "preflight", env={"ORCH_PLATFORM": "herdr"})
        out = p.stdout + p.stderr
        self.assertIn("BASE_BRANCH", out)
        self.assertIn("herdr", out)


class SpawnPlatformTests(PlatformTestCase):
    def setUp(self):
        super().setUp()
        self.wt = self.git_wt("one")
        self.use_orca()
        self.use_herdr()

    def assert_interactive_cmd(self, cmd, ticket, sid, resume=False):
        self.assertNotIn("Brief body", cmd, "brief text must not be inlined")
        argv = self.run_cmd(cmd, self.wt)
        self.assertNotIn("-p", argv)
        flag = "--resume" if resume else "--session-id"
        self.assertIn(flag, argv)
        self.assertEqual(argv[argv.index(flag) + 1], sid)
        self.assertIn("--dangerously-skip-permissions", argv)
        return argv

    def test_headless_records_platform_and_launch_ref(self):
        self.add("T-1")
        self.spawn("T-1", sleep=30, worktree=self.wt)
        t = self.show("T-1")
        self.assertEqual(t["platform"], "headless")
        self.assertEqual(t["launch_ref"], {"pid": t["pid"]})
        self.assertIn(t["health"], ("none", "working"))
        self.assertEqual(self.pcalls("orca"), [])

    def test_orca_spawn(self):
        self.spawn_on("T-1", "orca", self.wt)
        calls = self.pcalls("orca")
        self.assertEqual(len(calls), 1)
        argv = calls[0]
        self.assertEqual(argv[:2], ["terminal", "create"])
        waits = [c for c in self.pcalls("orca", waits=True) if c[:2] == ["terminal", "wait"]]
        self.assertEqual(len(waits), 1)
        self.assertEqual(waits[0][waits[0].index("--terminal") + 1], "term_abc")
        self.assertEqual(argv[argv.index("--worktree") + 1], "path:" + self.wt)
        self.assertEqual(argv[argv.index("--title") + 1], "tT-1")
        self.assertIn("--json", argv)
        cmd = argv[argv.index("--command") + 1]
        self.assertIn("claude", cmd)
        self.assertIn("$(cat ", cmd)
        t = self.show("T-1")
        brief_path = os.path.join(self.state_dir, "briefs", "T-1.md")
        self.assertIn(brief_path, cmd)
        self.assertEqual(read_file(brief_path), "/orchestration:orchestration Implement ticket. Brief body.")
        argv = self.assert_interactive_cmd(cmd, "T-1", t["session_id"])
        self.assertEqual(argv[-1], "/orchestration:orchestration Implement ticket. Brief body.")
        self.assertEqual(t["phase"], "dispatched")
        self.assertEqual(t["platform"], "orca")
        self.assertEqual(t["launch_ref"], {"terminal": "term_abc"})
        self.assertIsNone(t["pid"])
        self.assertFalse(t["alive"])
        self.assertEqual(t["health"], "none")
        self.assertEqual(t["attempt"], 1)

    def test_orca_spawn_uses_config_claude_args(self):
        self.write_config({"claude_args": ["--model", "opus"]})
        self.spawn_on("T-1", "orca", self.wt)
        cmd = self.pcalls("orca")[0]
        cmd = cmd[cmd.index("--command") + 1]
        argv = self.run_cmd(cmd, self.wt)
        self.assertEqual(argv[argv.index("--model") + 1], "opus")
        self.assertNotIn("--dangerously-skip-permissions", argv)

    def test_orca_handle_found_anywhere(self):
        self.use_orca({"terminal create": (0, {"data": [{"id": 3, "handle": "h-9"}]})})
        self.spawn_on("T-1", "orca", self.wt)
        self.assertEqual(self.show("T-1")["launch_ref"], {"terminal": "h-9"})

    def test_platform_detected_when_not_given(self):
        """Without --platform, spawn uses the platform the environment shows."""
        del self.env["ORCH_PLATFORM"]
        self.add("T-1")
        self.ok("spawn", "T-1", "--worktree", self.wt, "--brief-file", self.brief,
                env={"ORCA_TERMINAL_HANDLE": "h"})
        self.assertEqual(self.show("T-1")["platform"], "orca")
        self.assertEqual(len(self.pcalls("orca")), 1)
        self.assertEqual(self.calls(), [])

    def test_herdr_spawn(self):
        self.spawn_on("T-1", "herdr", self.wt)
        calls = self.pcalls("herdr")
        self.assertEqual(len(calls), 3)
        opened, start, prompt = calls
        self.assertEqual(opened[:2], ["worktree", "open"])
        self.assertEqual(opened[opened.index("--path") + 1], self.wt)
        self.assertEqual(opened[opened.index("--cwd") + 1], os.path.realpath(self.repo))
        self.assertEqual(opened[opened.index("--label") + 1], "tT-1")
        self.assertIn("--no-focus", opened)
        t = self.show("T-1")
        self.assertEqual(start[:3], ["agent", "start", "tt-1"])
        self.assertEqual(start[start.index("--pane") + 1], "w1:p1")
        rest = start[start.index("--") + 1:]
        self.assertEqual(rest[:2], ["--session-id", t["session_id"]])
        self.assertIn("--dangerously-skip-permissions", rest)
        self.assertNotIn("Brief body", " ".join(start), "brief goes in agent prompt")
        self.assertEqual(prompt, ["agent", "prompt", "tt-1",
                                  "/orchestration:orchestration Implement ticket. Brief body."])
        self.assertEqual(t["platform"], "herdr")
        self.assertEqual(t["launch_ref"], {"workspace": "w1", "pane": "w1:p1",
                                           "agent": "tt-1"})
        self.assertIsNone(t["pid"])
        self.assertEqual(t["health"], "none")

    def test_desktop_spawn(self):
        self.add("T-1")
        out = self.j("spawn", "T-1", "--worktree", self.wt, "--brief-file", self.brief,
                     "--platform", "desktop")
        self.assertEqual(out["action"], "desktop_start")
        self.assertEqual(os.path.realpath(out["cwd"]), self.wt)
        self.assertEqual(out["title"], "tT-1")
        self.assertTrue(os.path.isfile(out["prompt_file"]))
        self.assertIn("Implement ticket. Brief body.", read_file(out["prompt_file"]))
        time.sleep(0.3)
        self.assertEqual(self.calls(), [])
        self.assertEqual(self.pcalls("orca"), [])
        self.assertEqual(self.pcalls("herdr"), [])
        t = self.show("T-1")
        self.assertEqual(t["phase"], "dispatched")
        self.assertEqual(t["platform"], "desktop")
        self.assertIsNone(t["pid"])
        self.assertEqual(t["health"], "none")

    # -- rollback --------------------------------------------------------------

    def assert_rolled_back(self, ticket, p):
        self.assertIn("cannot start", p.stderr)
        self.assertNotIn("Traceback", p.stderr)
        t = self.show(ticket)
        self.assertEqual(t["phase"], "ready")
        self.assertIsNone(t["session_id"])
        self.assertEqual(self.event_kinds(ticket), ["add"])

    def spawn_refused(self, ticket, platform):
        self.add(ticket)
        return self.refused(3, "spawn", ticket, "--worktree", self.wt,
                            "--brief-file", self.brief, "--platform", platform)

    def test_orca_create_fails(self):
        self.use_orca({"terminal create": (1, "boom")})
        self.assert_rolled_back("T-1", self.spawn_refused("T-1", "orca"))

    def test_orca_reply_without_handle(self):
        self.use_orca({"terminal create": (0, {"result": {"terminal": {"id": 4}}})})
        self.assert_rolled_back("T-1", self.spawn_refused("T-1", "orca"))

    def test_orca_reply_not_json(self):
        self.use_orca({"terminal create": (0, "not json at all")})
        self.assert_rolled_back("T-1", self.spawn_refused("T-1", "orca"))

    def test_orca_binary_missing(self):
        self.env["ORCH_ORCA_BIN"] = os.path.join(self.tmp, "no-such-orca")
        self.assert_rolled_back("T-1", self.spawn_refused("T-1", "orca"))

    def test_herdr_create_fails(self):
        self.use_herdr({"worktree open": (2, "boom")})
        self.assert_rolled_back("T-1", self.spawn_refused("T-1", "herdr"))

    def test_herdr_reply_without_ids(self):
        self.use_herdr({"worktree open": (0, {"result": {"workspace": {}}})})
        self.assert_rolled_back("T-1", self.spawn_refused("T-1", "herdr"))

    def test_herdr_agent_start_fails(self):
        self.use_herdr({"agent start": (1, "boom")})
        self.assert_rolled_back("T-1", self.spawn_refused("T-1", "herdr"))
        self.assertEqual(self.pcalls("herdr")[-1], ["workspace", "close", "w1"])

    def test_herdr_error_reply_with_exit_0_fails(self):
        """herdr exits 0 on errors: a top-level "error" is a failure."""
        self.use_herdr({"agent prompt": (0, {"error": {"code": "agent_not_found",
                                                       "message": "no agent"}})})
        self.assert_rolled_back("T-1", self.spawn_refused("T-1", "herdr"))
        self.assertEqual(self.pcalls("herdr")[-1], ["workspace", "close", "w1"])

    def test_herdr_already_open_workspace_left_open_on_failure(self):
        reply = json.loads(json.dumps(HERDR_CREATE_OK))
        reply["result"]["already_open"] = True
        self.use_herdr({"worktree open": (0, reply), "agent start": (1, "boom")})
        self.assert_rolled_back("T-1", self.spawn_refused("T-1", "herdr"))
        self.assertNotIn(["workspace", "close", "w1"], self.pcalls("herdr"))

    def test_herdr_already_open_prompt_failure_closes_agent_pane(self):
        reply = json.loads(json.dumps(HERDR_CREATE_OK))
        reply["result"]["already_open"] = True
        self.use_herdr({"worktree open": (0, reply), "agent prompt": (1, "boom")})
        self.assert_rolled_back("T-1", self.spawn_refused("T-1", "herdr"))
        calls = self.pcalls("herdr")
        self.assertIn(["pane", "close", "w1:p1"], calls)
        self.assertNotIn(["workspace", "close", "w1"], calls)

    def test_orca_reply_without_handle_closes_terminals(self):
        self.use_orca({"terminal create": (0, {"result": {"terminal": {}}})})
        self.assert_rolled_back("T-1", self.spawn_refused("T-1", "orca"))
        self.assertIn(["terminal", "close", "--worktree", "path:" + self.wt, "--all",
                       "--json"], self.pcalls("orca"))

    def test_herdr_blocked_but_not_at_trust_is_plain_failure(self):
        self.use_herdr({
            "agent start": (0, {"error": {"code": "agent_not_ready",
                                          "message": "agent tt-1 is blocked during"
                                                     " startup"}}),
            "agent read": (0, "Please run /login to sign in")})
        p = self.spawn_refused("T-1", "herdr")
        self.assertNotIn("folder-trust", p.stderr)
        self.assert_rolled_back("T-1", p)
        self.assertIn(["workspace", "close", "w1"], self.pcalls("herdr"))

    def test_herdr_trust_prompt_at_agent_prompt(self):
        self.use_herdr({
            "agent prompt": (0, {"error": {"code": "agent_blocked",
                                           "message": "agent tt-1 is blocked"}}),
            "agent read": (0, "Do you trust the files in this folder?")})
        p = self.spawn_refused("T-1", "herdr")
        self.assertIn("folder-trust prompt", p.stderr)
        self.assertIn("herdr agent prompt tt-1", p.stderr)
        self.assertNotIn("Traceback", p.stderr)
        t = self.show("T-1")
        self.assertEqual(t["phase"], "dispatched")
        self.assertIn("trust_prompt", self.event_kinds("T-1"))
        self.assertNotIn(["workspace", "close", "w1"], self.pcalls("herdr"))

    def test_herdr_reply_without_pane_closes_workspace(self):
        self.use_herdr({"worktree open": (0, {"result": {"workspace": {
            "workspace_id": "w9"}}})})
        self.assert_rolled_back("T-1", self.spawn_refused("T-1", "herdr"))
        self.assertIn(["workspace", "close", "w9"], self.pcalls("herdr"))

    def test_brief_over_128k_refused_on_orca_and_herdr(self):
        big = self.write_brief("x" * (128 * 1024 + 1), "big.md")
        for platform in ("orca", "herdr"):
            ticket = "T-" + platform
            self.add(ticket)
            p = self.refused(3, "spawn", ticket, "--worktree", self.wt,
                             "--brief-file", big, "--platform", platform)
            self.assertIn("128", p.stderr)
            self.assertNotIn("Traceback", p.stderr)
            t = self.show(ticket)
            self.assertEqual(t["phase"], "ready")
            self.assertIsNone(t["session_id"])
            self.assertEqual(self.event_kinds(ticket), ["add"])
        self.assertEqual(self.pcalls("orca"), [])
        self.assertEqual(self.pcalls("herdr"), [])

    def test_rolled_back_ticket_can_spawn_again(self):
        self.use_orca({"terminal create": (1, "boom")})
        self.spawn_refused("T-1", "orca")
        self.use_orca()
        self.ok("spawn", "T-1", "--worktree", self.wt, "--brief-file", self.brief,
                "--platform", "orca")
        self.assertEqual(self.show("T-1")["phase"], "dispatched")

    # -- empty brief -----------------------------------------------------------

    def test_empty_brief_refused(self):
        for i, text in enumerate(("", "  \n\t\n")):
            ticket = "T-%d" % i
            self.add(ticket)
            for platform in ("headless", "orca", "desktop"):
                p = self.refused(3, "spawn", ticket, "--worktree", self.wt,
                                 "--brief-file", self.write_brief(text),
                                 "--platform", platform)
                self.assertNotIn("Traceback", p.stderr)
                t = self.show(ticket)
                self.assertEqual(t["phase"], "ready")
                self.assertIsNone(t["session_id"])
                self.assertEqual(self.event_kinds(ticket), ["add"])
        time.sleep(0.3)
        self.assertEqual(self.calls(), [])
        self.assertEqual(self.pcalls("orca"), [])


class HookTests(PlatformTestCase):
    def setUp(self):
        super().setUp()
        self.wt = self.git_wt("hk")
        self.use_orca()
        self.spawn_on("T-1", "orca", self.wt)
        self.sid = self.show("T-1")["session_id"]

    def row(self, *cols):
        return self.db_exec("SELECT %s FROM tickets WHERE id='T-1'" % ", ".join(cols))[0]

    def context_line(self, ticket):
        return ("You are the ticket orchestrator for %s. Run `orch show %s` before"
                " anything else." % (ticket, ticket))

    def test_no_state_db_does_nothing(self):
        other = os.path.join(self.tmp, "other-repo")
        os.makedirs(other)
        subprocess.run(["git", "init", "-q", other], env=self.env, check=True)
        plain = os.path.join(self.tmp, "plain-dir")
        os.makedirs(plain)
        for cwd in (other, plain):
            for ev in ("SessionStart", "PostToolUse", "Stop", "SessionEnd"):
                p = self.hook_ok(ev, "sid-x", cwd)
                self.assertEqual(p.stdout, "")
        self.assertFalse(os.path.exists(os.path.join(other, ".agents")))

    def test_session_start_in_worktree(self):
        proc = self.live_process()
        p = self.hook_ok("SessionStart", self.sid, self.wt, pid=proc.pid)
        self.assertIn(self.context_line("T-1"), p.stdout)
        t = self.show("T-1")
        self.assertEqual(t["session_id"], self.sid)
        self.assertEqual(t["pid"], proc.pid)
        self.assertTrue(t["alive"])
        self.assertEqual(t["health"], "working")
        self.assertEqual(t["activity"], "working")
        self.assertTrue(t["last_seen_at"])
        self.assertEqual(self.row("session_seen")[0], 1)
        self.assertNotIn("attach", self.event_kinds("T-1"))

    def test_session_start_new_session_attaches(self):
        """A Desktop ticket's session id is only known once its session starts,
        so a new session id attaches before any report-in (an orca ticket's
        would be ignored: see HijackWindowTests)."""
        wt = self.git_wt("desk")
        self.spawn_on("T-2", "desktop", wt)
        proc = self.live_process()
        p = self.hook_ok("SessionStart", "sid-new", wt, pid=proc.pid)
        self.assertIn(self.context_line("T-2"), p.stdout)
        t = self.show("T-2")
        self.assertEqual(t["session_id"], "sid-new")
        self.assertEqual(t["pid"], proc.pid)
        self.assertEqual(self.event_kinds("T-2")[-1], "attach")

    def test_session_start_in_subdirectory(self):
        sub = os.path.join(self.wt, "a", "b")
        os.makedirs(sub)
        proc = self.live_process()
        p = self.hook_ok("SessionStart", self.sid, sub, pid=proc.pid)
        self.assertIn("orch show T-1", p.stdout)
        self.assertEqual(self.show("T-1")["pid"], proc.pid)

    def test_unrelated_directory_not_matched(self):
        other = self.git_wt("unrelated")
        p = self.hook_ok("SessionStart", "sid-z", other, pid=self.live_process().pid)
        self.assertEqual(p.stdout, "")
        t = self.show("T-1")
        self.assertEqual(t["session_id"], self.sid)
        self.assertIsNone(t["pid"])

    def test_session_start_for_done_ticket_prints_nothing(self):
        wt = self.git_wt("done")
        self.to_done("T-2", worktree=wt)
        p = self.hook_ok("SessionStart", "sid-d", wt, pid=self.live_process().pid)
        self.assertEqual(p.stdout, "")

    def test_retired_ticket_not_matched(self):
        self.ok("retire", "T-1", "--force")
        p = self.hook_ok("SessionStart", self.sid, self.wt, pid=self.live_process().pid)
        self.assertEqual(p.stdout, "")
        self.assertIsNone(self.show("T-1")["pid"])

    def test_activity_events(self):
        proc = self.live_process()
        self.hook_ok("SessionStart", self.sid, self.wt, pid=proc.pid)
        n_events = len(self.events("T-1"))
        p = self.hook_ok("Stop", self.sid, self.wt, pid=proc.pid)
        self.assertEqual(p.stdout, "")
        t = self.show("T-1")
        self.assertEqual((t["activity"], t["health"]), ("idle", "idle"))
        p = self.hook_ok("PostToolUse", self.sid, self.wt, pid=proc.pid)
        self.assertEqual(p.stdout, "")
        t = self.show("T-1")
        self.assertEqual((t["activity"], t["health"]), ("working", "working"))
        self.assertEqual(len(self.events("T-1")), n_events,
                         "activity updates must not write events")

    def test_post_tool_use_throttled(self):
        proc = self.live_process()
        self.hook_ok("SessionStart", self.sid, self.wt, pid=proc.pid)
        first = self.show("T-1")["last_seen_at"]
        time.sleep(1.2)
        self.hook_ok("PostToolUse", self.sid, self.wt, pid=proc.pid)
        self.hook_ok("PostToolUse", self.sid, self.wt, pid=proc.pid)
        self.assertEqual(self.show("T-1")["last_seen_at"], first)
        self.hook_ok("Stop", self.sid, self.wt, pid=proc.pid)
        t = self.show("T-1")
        self.assertEqual(t["activity"], "idle")
        self.assertNotEqual(t["last_seen_at"], first)

    def test_session_end(self):
        proc = self.live_process()
        self.hook_ok("SessionStart", self.sid, self.wt, pid=proc.pid)
        p = self.hook_ok("SessionEnd", self.sid, self.wt, pid=proc.pid,
                         extra={"reason": "prompt_input_exit"})
        self.assertEqual(p.stdout, "")
        t = self.show("T-1")
        self.assertEqual(t["activity"], "ended")
        self.assertEqual(t["health"], "dead")
        self.assertFalse(t["alive"])
        ev = self.events("T-1")[-1]
        self.assertEqual(ev["kind"], "session_end")
        self.assertIn("prompt_input_exit", ev["detail"] or "")
        self.assertIn("T-1", [x["id"] for x in self.tickets("stale")])

    def test_other_session_ignored_except_session_start(self):
        proc = self.live_process()
        self.hook_ok("SessionStart", self.sid, self.wt, pid=proc.pid)
        self.hook_ok("Stop", self.sid, self.wt, pid=proc.pid)
        before = self.show("T-1")
        n_events = len(self.events("T-1"))
        other = self.live_process()
        for ev in ("PostToolUse", "Stop", "SessionEnd"):
            p = self.hook_ok(ev, "sid-intruder", self.wt, pid=other.pid)
            self.assertEqual(p.stdout, "")
        after = self.show("T-1")
        for k in ("session_id", "pid", "activity", "health", "last_seen_at"):
            self.assertEqual(after[k], before[k], k)
        self.assertEqual(len(self.events("T-1")), n_events)

    def test_live_session_not_hijacked(self):
        proc = self.live_process()
        self.hook_ok("SessionStart", self.sid, self.wt, pid=proc.pid)
        sub = os.path.join(self.wt, "sub")
        os.makedirs(sub)
        n_events = len(self.events("T-1"))
        intruder = self.live_process()
        p = self.hook_ok("SessionStart", "sid-intruder", sub, pid=intruder.pid)
        self.assertEqual(p.stdout, "")
        t = self.show("T-1")
        self.assertEqual((t["session_id"], t["pid"]), (self.sid, proc.pid))
        self.assertTrue(t["alive"])
        self.assertEqual(len(self.events("T-1")), n_events)
        self.hook_ok("SessionEnd", "sid-intruder", sub, pid=intruder.pid)
        self.assertEqual(self.show("T-1")["activity"], "working")
        self.hook_ok("Stop", self.sid, self.wt, pid=proc.pid)
        self.assertEqual(self.show("T-1")["activity"], "idle")
        self.assertEqual(len(self.events("T-1")), n_events)

    def test_dead_session_taken_over(self):
        proc = self.live_process()
        self.hook_ok("SessionStart", self.sid, self.wt, pid=proc.pid)
        proc.kill()
        proc.wait()
        new = self.live_process()
        p = self.hook_ok("SessionStart", "sid-new", self.wt, pid=new.pid)
        self.assertIn(self.context_line("T-1"), p.stdout)
        t = self.show("T-1")
        self.assertEqual((t["session_id"], t["pid"]), ("sid-new", new.pid))
        self.assertTrue(t["alive"])
        self.assertEqual(self.event_kinds("T-1")[-1], "attach")

    def test_clear_in_same_process_takes_over(self):
        proc = self.live_process()
        self.hook_ok("SessionStart", self.sid, self.wt, pid=proc.pid)
        p = self.hook_ok("SessionStart", "sid-cleared", self.wt, pid=proc.pid,
                         extra={"source": "clear"})
        self.assertIn(self.context_line("T-1"), p.stdout)
        t = self.show("T-1")
        self.assertEqual((t["session_id"], t["pid"]), ("sid-cleared", proc.pid))
        self.assertTrue(t["alive"])
        self.assertEqual(self.event_kinds("T-1")[-1], "attach")

    def test_same_session_failed_walk_keeps_pid(self):
        proc = self.live_process()
        self.hook_ok("SessionStart", self.sid, self.wt, pid=proc.pid)
        start = self.row("pid_start")[0]
        self.assertTrue(start)
        p = self.hook_ok("SessionStart", self.sid, self.wt, pid="none",
                         extra={"source": "resume"})
        self.assertIn(self.context_line("T-1"), p.stdout)
        t = self.show("T-1")
        self.assertEqual(t["pid"], proc.pid)
        self.assertEqual(self.row("pid_start")[0], start)
        self.assertTrue(t["alive"])

    def test_main_checkout_never_a_ticket(self):
        self.db_exec(
            "INSERT INTO tickets (id, title, phase, created_at, worktree, session_id)"
            " VALUES ('T-main', 'm', 'spec', '2026-01-01T00:00:00+00:00', ?, 'sid-m')",
            (self.repo,))
        before = self.db_exec("SELECT * FROM tickets ORDER BY id")
        n_events = self.db_exec("SELECT COUNT(*) FROM events")[0][0]
        for ev in ("SessionStart", "PostToolUse", "Stop", "SessionEnd"):
            for sid in ("sid-x", "sid-m"):
                p = self.hook_ok(ev, sid, self.repo, pid=self.live_process().pid)
                self.assertEqual(p.stdout, "", (ev, sid))
        self.assertEqual(self.db_exec("SELECT * FROM tickets ORDER BY id"), before)
        self.assertEqual(self.db_exec("SELECT COUNT(*) FROM events")[0][0], n_events)

    def test_session_start_on_done_ticket_writes_nothing(self):
        wt = self.git_wt("done2")
        self.to_done("T-2", worktree=wt)
        q = "SELECT * FROM tickets WHERE id='T-2'"
        before = self.db_exec(q)
        n_events = len(self.events("T-2"))
        own = self.db_exec("SELECT session_id FROM tickets WHERE id='T-2'")[0][0]
        for sid in ("sid-d", own):
            p = self.hook_ok("SessionStart", sid, wt, pid=self.live_process().pid)
            self.assertEqual(p.stdout, "")
        self.assertEqual(self.db_exec(q), before)
        self.assertEqual(len(self.events("T-2")), n_events)

    def test_liveness_independent_of_tz_and_locale(self):
        proc = self.live_process()
        self.env["TZ"] = "America/Vancouver"
        self.hook_ok("SessionStart", self.sid, self.wt, pid=proc.pid)
        del self.env["TZ"]
        self.assertTrue(self.j("show", "T-1", env={"TZ": "UTC"})["alive"])
        self.assertTrue(self.j("show", "T-1", env={"TZ": "Asia/Tokyo"})["alive"])
        locales = subprocess.run(["locale", "-a"], capture_output=True,
                                 text=True).stdout.split()
        fr = [l for l in locales if l.lower() in ("fr_fr.utf-8", "fr_fr.utf8")]
        if fr:
            self.assertTrue(self.j("show", "T-1", env={
                "TZ": "UTC", "LC_ALL": fr[0], "LANG": fr[0]})["alive"])

    def test_walk_finds_native_versions_binary(self):
        """The native CLI's executable is .../claude/versions/<version>."""
        vdir = os.path.join(self.tmp, "share", "claude", "versions")
        os.makedirs(vdir)
        native = os.path.join(vdir, "2.1.288")
        os.symlink("/bin/bash", native)
        payload = json.dumps({"session_id": self.sid, "cwd": self.wt,
                              "hook_event_name": "SessionStart", "source": "startup"})
        e = {k: v for k, v in self.env.items() if k != "ORCH_HOOK_CLAUDE_PID"}
        # `; echo` keeps bash from exec-ing the hook in its own process.
        p = subprocess.run([native, "-c", '"$0" hook; echo "PID=$$"',
                            os.path.join(PLUGIN, "scripts", "orch")],
                           input=payload, cwd=self.wt, env=e, capture_output=True,
                           text=True, timeout=30)
        self.assertIn(self.context_line("T-1"), p.stdout)
        bash_pid = int(re.search(r"PID=(\d+)", p.stdout).group(1))
        self.assertEqual(self.show("T-1")["pid"], bash_pid)

    def test_garbage_stdin(self):
        for raw in ("", "not json", "[1, 2]", '{"hook_event_name": "SessionStart"}'):
            p = self.hook("SessionStart", None, self.wt, raw=raw, proc_cwd=self.wt)
            self.assertEqual(p.returncode, 0, raw)
            self.assertEqual(p.stdout, "", raw)
            self.assertNotIn("Traceback", p.stderr)
        self.assertIsNone(self.show("T-1")["pid"])

    def test_hook_survives_unreadable_state(self):
        with open(os.path.join(self.state_dir, "config.json"), "w") as f:
            f.write("{broken")
        p = self.hook("SessionStart", self.sid, self.wt)
        self.assertEqual(p.returncode, 0)
        self.assertNotIn("Traceback", p.stderr)


class HealthTests(PlatformTestCase):
    def setUp(self):
        super().setUp()
        self.wt = self.git_wt("hl")
        self.use_orca()
        self.use_herdr()

    def started(self, ticket="T-1", platform="orca", wt=None):
        wt = wt or self.wt
        self.spawn_on(ticket, platform, wt)
        sid = self.show(ticket)["session_id"]
        proc = self.live_process()
        self.hook_ok("SessionStart", sid, wt, pid=proc.pid)
        return sid, proc

    def test_list_has_health_fields(self):
        self.started()
        for t in self.tickets("list"):
            for key in ("platform", "health", "activity", "last_seen_at"):
                self.assertIn(key, t)

    def test_working_then_dead_when_process_exits(self):
        sid, proc = self.started()
        self.assertEqual(self.show("T-1")["health"], "working")
        proc.kill()
        proc.wait()
        self.assertTrue(wait_until(lambda: self.show("T-1")["health"] == "dead"))
        self.assertFalse(self.show("T-1")["alive"])

    def test_stalled(self):
        self.write_config({"stall_minutes": 0.01})
        self.started()
        time.sleep(1.5)
        self.assertEqual(self.show("T-1")["health"], "stalled")
        self.assertTrue(self.show("T-1")["alive"])

    def test_idle_never_stalls(self):
        self.write_config({"stall_minutes": 0.01})
        sid, proc = self.started()
        self.hook_ok("Stop", sid, self.wt, pid=proc.pid)
        time.sleep(1.5)
        self.assertEqual(self.show("T-1")["health"], "idle")

    def test_pid_reused_is_dead(self):
        sid, proc = self.started()
        imposter = self.live_process(delay_before=1.2)  # different start time
        self.db_exec("UPDATE tickets SET pid=? WHERE id='T-1'", (imposter.pid,))
        t = self.show("T-1")
        self.assertFalse(t["alive"])
        self.assertEqual(t["health"], "dead")
        self.assertIn("T-1", [x["id"] for x in self.tickets("stale")])
        self.ok("retire", "T-1", "--force")
        time.sleep(0.5)
        self.assertIsNone(imposter.poll(), "retire signalled an unrelated process")

    def test_stale_includes_dead_orca_and_herdr(self):
        _, p1 = self.started("T-o", "orca")
        _, p2 = self.started("T-h", "herdr", wt=self.git_wt("h2"))
        stale = [x["id"] for x in self.tickets("stale")]
        self.assertNotIn("T-o", stale)
        self.assertNotIn("T-h", stale)
        for p in (p1, p2):
            p.kill()
            p.wait()
        stale = [x["id"] for x in self.tickets("stale")]
        self.assertIn("T-o", stale)
        self.assertIn("T-h", stale)

    def test_desktop_dispatched_not_stale_until_stall_minutes(self):
        self.spawn_on("T-1", "desktop", self.wt)
        self.assertNotIn("T-1", [x["id"] for x in self.tickets("stale")])
        self.write_config({"stall_minutes": 0.01})
        time.sleep(1.5)
        self.assertIn("T-1", [x["id"] for x in self.tickets("stale")])


class ResumePlatformTests(PlatformTestCase):
    def setUp(self):
        super().setUp()
        self.wt = self.git_wt("rs")
        self.use_orca()
        self.use_herdr()

    def last_cmd(self, name="orca"):
        argv = self.pcalls(name)[-1]
        if name == "orca":
            return argv[argv.index("--command") + 1]
        return argv[3]

    def orca_close(self):
        return ["terminal", "close", "--worktree", "path:" + self.wt, "--all", "--json"]

    def test_orca_resume_fresh_without_session_seen(self):
        self.spawn_on("T-1", "orca", self.wt)
        sid = self.show("T-1")["session_id"]
        self.ok("resume", "T-1", "--note", "extra context")
        calls = self.pcalls("orca")
        self.assertEqual(len(calls), 3)
        self.assertEqual(calls[1], self.orca_close())
        self.assertEqual(calls[2][:2], ["terminal", "create"])
        argv = self.run_cmd(self.last_cmd(), self.wt)
        self.assertNotIn("--resume", argv)
        self.assertEqual(argv[argv.index("--session-id") + 1], sid)
        self.assertTrue(argv[-1].startswith("/orchestration:orchestration Implement ticket. Brief body."))
        self.assertIn("extra context", argv[-1])
        t = self.show("T-1")
        self.assertEqual(t["attempt"], 2)
        self.assertEqual(t["platform"], "orca")
        self.assertEqual(t["launch_ref"], {"terminal": "term_abc"})

    def test_orca_resume_continues_seen_session(self):
        self.spawn_on("T-1", "orca", self.wt)
        sid = self.show("T-1")["session_id"]
        proc = self.live_process()
        self.hook_ok("SessionStart", sid, self.wt, pid=proc.pid)
        self.ok("phase", "T-1", "spec")
        self.refused(3, "resume", "T-1")  # alive by hook-reported pid
        self.refused(3, "resume", "T-1", "--platform", "headless")
        self.assertEqual(len(self.pcalls("orca")), 1)
        proc.kill()
        proc.wait()
        self.ok("resume", "T-1")
        self.assertEqual(self.pcalls("orca")[1], self.orca_close())
        argv = self.run_cmd(self.last_cmd(), self.wt)
        self.assertEqual(argv[argv.index("--resume") + 1], sid)
        self.assertNotIn("--session-id", argv)
        self.assertIn("orch show T-1", argv[-1])
        self.assertEqual(self.show("T-1")["phase"], "spec")

    def test_herdr_resume_closes_workspace(self):
        self.spawn_on("T-1", "herdr", self.wt)
        self.ok("resume", "T-1")
        calls = self.pcalls("herdr")
        self.assertEqual(calls[3], ["workspace", "close", "w1"])
        self.assertEqual(calls[4][:2], ["worktree", "open"])
        self.assertEqual(calls[5][:3], ["agent", "start", "tt-1"])
        self.assertEqual(calls[6][:3], ["agent", "prompt", "tt-1"])

    def test_resume_ignores_close_errors(self):
        self.use_orca({"terminal close": (1, "gone")})
        self.spawn_on("T-1", "orca", self.wt)
        self.ok("resume", "T-1")
        self.assertEqual(self.show("T-1")["attempt"], 2)

    def test_resume_switches_platform_when_dead(self):
        self.spawn_on("T-1", "orca", self.wt)
        sid = self.show("T-1")["session_id"]
        proc = self.live_process()
        self.hook_ok("SessionStart", sid, self.wt, pid=proc.pid)
        proc.kill()
        proc.wait()
        self.ok("resume", "T-1", "--platform", "headless",
                env={"ORCH_CLAUDE_BIN": self.fake_claude(30)})
        call = self.wait_calls(1)[0]
        self.assertIn("-p", call["argv"])
        self.assertEqual(call["argv"][call["argv"].index("--resume") + 1], sid)
        t = self.show("T-1")
        self.assertEqual(t["platform"], "headless")
        self.assertEqual(t["pid"], call["pid"])
        self.assertEqual(t["launch_ref"], {"pid": call["pid"]})

    def test_fresh_resume_without_brief_refused(self):
        self.spawn_on("T-1", "orca", self.wt)
        self.db_exec("UPDATE tickets SET brief=NULL WHERE id='T-1'")
        n = len(self.pcalls("orca"))
        p = self.refused(3, "resume", "T-1")
        self.assertIn("no stored brief", p.stderr)
        self.assertEqual(self.show("T-1")["attempt"], 1)
        self.assertEqual(len(self.pcalls("orca")), n)

    def test_fresh_headless_resume_without_brief_refused(self):
        self.add("T-1")
        self.spawn("T-1", sleep=0, init=False, worktree=self.wt)
        self.wait_dead("T-1")
        self.db_exec("UPDATE tickets SET brief=NULL WHERE id='T-1'")
        p = self.refused(3, "resume", "T-1")
        self.assertIn("no stored brief", p.stderr)
        self.assertEqual(self.show("T-1")["attempt"], 1)

    def test_failed_resume_after_close_clears_launch_ref(self):
        for name, ticket in (("orca", "T-o"), ("herdr", "T-h")):
            wt = self.git_wt("rb-" + name)
            self.spawn_on(ticket, name, wt)
            if name == "orca":
                self.use_orca({"terminal create": (1, "boom")})
                closed = ["terminal", "close", "--worktree", "path:" + wt, "--all",
                          "--json"]
            else:
                self.use_herdr({"worktree open": (1, "boom")})
                closed = ["workspace", "close", "w1"]
            p = self.refused(3, "resume", ticket)
            self.assertIn("cannot start", p.stderr)
            self.assertIn(closed, self.pcalls(name))
            t = self.show(ticket)
            self.assertIsNone(t["launch_ref"], "rollback restored a closed %s ref" % name)
            self.assertEqual(t["attempt"], 1)
            self.assertEqual(t["phase"], "dispatched")
            self.assertEqual(t["platform"], name)

    def test_failed_resume_after_failed_close_keeps_launch_ref(self):
        self.spawn_on("T-1", "orca", self.wt)
        self.use_orca({"terminal create": (1, "boom"), "terminal close": (1, "busy")})
        self.refused(3, "resume", "T-1")
        self.assertEqual(self.show("T-1")["launch_ref"], {"terminal": "term_abc"})

    def test_desktop_resume(self):
        self.spawn_on("T-1", "desktop", self.wt)
        self.ok("attach", "T-1", "--ref", "local_abc")
        out = self.j("resume", "T-1")
        self.assertEqual(out["action"], "desktop_resume")
        self.assertEqual(out["ref"], "local_abc")
        self.assertEqual(self.show("T-1")["attempt"], 2)


class PidWalkTests(PlatformTestCase):
    def test_headless_hook_records_the_claude_pid(self):
        """A real walk: the hook runs as a child of an executable named
        `claude`, with no ORCH_HOOK_CLAUDE_PID override."""
        wt = self.git_wt("walk")
        bindir = os.path.join(self.tmp, "walk-bin")
        os.makedirs(bindir)
        fake = os.path.join(bindir, "claude")
        with open(fake, "w") as f:
            f.write(
                "#!%s\n"
                "import json, os, subprocess, sys, time\n"
                "data = sys.stdin.read()\n"
                "a = sys.argv[1:]\n"
                "sid = a[a.index('--session-id') + 1]\n"
                "payload = json.dumps({'session_id': sid, 'cwd': os.getcwd(),"
                " 'hook_event_name': 'SessionStart', 'source': 'startup'})\n"
                "env = {k: v for k, v in os.environ.items()"
                " if k != 'ORCH_HOOK_CLAUDE_PID'}\n"
                "p = subprocess.run([%r, 'hook'], input=payload, env=env,"
                " capture_output=True, text=True)\n"
                "with open(%r, 'a') as f:\n"
                "    f.write(json.dumps({'argv': a, 'cwd': os.getcwd(),"
                " 'pid': os.getpid(), 'stdin': data, 'hook_stdout': p.stdout}) + '\\n')\n"
                "time.sleep(30)\n" % (sys.executable,
                                      os.path.join(PLUGIN, "scripts", "orch"),
                                      self.record))
        os.chmod(fake, 0o755)
        self.add("T-1")
        self.ok("spawn", "T-1", "--worktree", wt, "--brief-file", self.brief,
                "--platform", "headless", env={"ORCH_CLAUDE_BIN": fake})
        call = self.wait_calls(1)[0]
        self.assertIn("orch show T-1", call["hook_stdout"])
        t = self.show("T-1")
        self.assertEqual(t["pid"], call["pid"])
        self.assertEqual(t["launch_ref"], {"pid": call["pid"]})
        self.assertTrue(t["alive"])
        pid_start, seen = self.db_exec(
            "SELECT pid_start, session_seen FROM tickets WHERE id='T-1'")[0]
        self.assertTrue(pid_start, "the hook did not record the walked pid")
        self.assertEqual(seen, 1)


class AttachRetireTests(PlatformTestCase):
    def setUp(self):
        super().setUp()
        self.wt = self.git_wt("ar")
        self.use_orca()
        self.use_herdr()

    def test_attach_ref(self):
        self.spawn_on("T-1", "desktop", self.wt)
        self.ok("attach", "T-1", "--ref", "local_123")
        t = self.show("T-1")
        self.assertEqual(t["launch_ref"], {"desktop": "local_123"})
        self.assertEqual(self.event_kinds("T-1")[-1], "attach")

    def test_attach_session_id(self):
        self.spawn_on("T-1", "desktop", self.wt)
        self.ok("attach", "T-1", "--session-id", "sid-desktop")
        self.assertEqual(self.show("T-1")["session_id"], "sid-desktop")
        self.assertEqual(self.event_kinds("T-1")[-1], "attach")

    def test_attach_unknown_ticket(self):
        self.refused(4, "attach", "NOPE", "--ref", "x")

    def test_retire_orca_closes_terminal(self):
        self.spawn_on("T-1", "orca", self.wt)
        self.ok("retire", "T-1", "--force")
        self.assertIn(["terminal", "close", "--worktree", "path:" + self.wt, "--all",
                       "--json"], self.pcalls("orca"))
        self.assertTrue(self.show("T-1")["retired"])

    def test_retire_orca_signals_session_still_alive(self):
        self.spawn_on("T-1", "orca", self.wt)
        proc = self.live_process()
        self.hook_ok("SessionStart", self.show("T-1")["session_id"], self.wt,
                     pid=proc.pid)
        self.ok("retire", "T-1", "--force")
        self.assertTrue(wait_until(lambda: proc.poll() is not None),
                        "retire left the live session running")

    def test_retire_herdr_closes_workspace(self):
        self.spawn_on("T-1", "herdr", self.wt)
        self.ok("retire", "T-1", "--force")
        self.assertIn(["workspace", "close", "w1"], self.pcalls("herdr"))
        self.assertTrue(self.show("T-1")["retired"])

    def test_retire_desktop_prints_archive_action(self):
        self.spawn_on("T-1", "desktop", self.wt)
        self.ok("attach", "T-1", "--ref", "local_9")
        out = self.j("retire", "T-1", "--force")
        self.assertEqual(out["action"], "desktop_archive")
        self.assertEqual(out["ref"], "local_9")
        self.assertTrue(self.show("T-1")["retired"])

    def test_retire_close_failure_still_retires(self):
        self.use_orca({"terminal close": (1, "no such terminal")})
        self.spawn_on("T-1", "orca", self.wt)
        p = self.ok("retire", "T-1", "--force")
        self.assertRegex((p.stdout + p.stderr).lower(), r"error|fail|cannot|could not")
        self.assertTrue(self.show("T-1")["retired"])


class UnblockTests(PlatformTestCase):
    def test_unblock_without_remembered_phase(self):
        self.add("T-1")
        self.ok("block", "T-1", "--reason", "x")
        self.db_exec("UPDATE tickets SET prior_phase=NULL WHERE id='T-1'")
        p = self.refused(3, "unblock", "T-1")
        self.assertNotIn("Traceback", p.stderr)
        self.assertEqual(self.show("T-1")["phase"], "blocked")


class HooksJsonTests(unittest.TestCase):
    def test_hooks_json(self):
        path = os.path.join(PLUGIN, "hooks", "hooks.json")
        self.assertTrue(os.path.isfile(path), "%s missing" % path)
        with open(path) as f:
            data = json.load(f)
        hooks = data.get("hooks", data)

        def commands(node):
            if isinstance(node, dict):
                for k, v in node.items():
                    if k == "command" and isinstance(v, str):
                        yield v
                    else:
                        yield from commands(v)
            elif isinstance(node, list):
                for v in node:
                    yield from commands(v)

        for event in ("SessionStart", "PostToolUse", "Stop", "SessionEnd"):
            self.assertIn(event, hooks)
            cmds = list(commands(hooks[event]))
            self.assertTrue(cmds, "no command for %s" % event)
            for c in cmds:
                self.assertIn("${CLAUDE_PLUGIN_ROOT}/scripts/orch", c)
                self.assertIn("hook", shlex.split(c.replace("${CLAUDE_PLUGIN_ROOT}", "R")))


if __name__ == "__main__":
    unittest.main()
