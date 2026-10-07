"""Black-box tests for the harness switch: ticket sessions run on the harness
the main orchestrator runs on (claude, pi or codex).

Contract: skills/orchestration/references/orch-cli.md ("Harnesses") and
platforms.md (per-platform launch commands).

Run from the plugin dir:  python3 -m unittest discover -s tests -v
"""

import json
import os
import shlex
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from test_orch import ORCH, pid_alive, read_file, wait_until  # noqa: E402
from test_orch_adapters import AdapterTestCase, load_orch_module  # noqa: E402

BRIEF = "Implement ticket. Brief body."
PI_SKILL = "/skill:orchestration "
CODEX_SKILL = "$orchestration:orchestration "
CODEX_ARGS = ["--dangerously-bypass-approvals-and-sandbox", "--dangerously-bypass-hook-trust",
              "--enable", "hooks"]

# A stand-in for `pi` or `codex`: records argv, cwd, pid, stdin and a few env
# keys, prints what the real one prints first in JSON mode, then sleeps.
FAKE_AGENT_SRC = r'''
import json, os, sys, time
RECORD, KIND, SLEEP, HEADER, THREAD = %(record)r, %(kind)r, %(sleep)r, %(header)r, %(thread)r
a = sys.argv[1:]
data = sys.stdin.read() if not sys.stdin.isatty() else ""
env = {k: os.environ.get(k) for k in ("PI_SUBAGENT_CHILD", "ORCH_PI_PARENT_SESSION",
                                       "PI_SUBAGENT_ID")}
with open(RECORD, "a") as f:
    f.write(json.dumps({"argv": a, "cwd": os.getcwd(), "pid": os.getpid(),
                        "stdin": data, "env": env}) + "\n")
if HEADER and KIND == "pi" and "--session-id" in a:
    print(json.dumps({"type": "session", "version": 3,
                      "id": a[a.index("--session-id") + 1], "cwd": os.getcwd()}),
          flush=True)
if HEADER and KIND == "codex":
    tid = THREAD
    if a[:2] == ["exec", "resume"]:
        tid = [x for x in a[2:] if not x.startswith("-") and x != "hooks"][-1]
    print(json.dumps({"type": "thread.started", "thread_id": tid}), flush=True)
time.sleep(SLEEP)
'''

# A fake pi that behaves like a ticket session with the orchestration
# extension loaded: SessionStart through `orch hook` with its own pid, and on
# a fresh start (the brief, not a resume prompt) `orch phase <ticket> spec`.
SESSION_PI_SRC = r'''
import json, os, re, subprocess, sys, time
RECORD, ORCH = %(record)r, %(orch)r
a = sys.argv[1:]
data = sys.stdin.read()
with open(RECORD, "a") as f:
    f.write(json.dumps({"argv": a, "cwd": os.getcwd(), "pid": os.getpid(),
                        "stdin": data}) + "\n")
sid = a[a.index("--session-id") + 1]
resume = "You are resuming" in data
env = dict(os.environ, ORCH_HOOK_AGENT_PID=str(os.getpid()))
payload = {"session_id": sid, "cwd": os.getcwd(), "hook_event_name": "SessionStart",
           "source": "startup"}
h = subprocess.run([ORCH, "hook"], input=json.dumps(payload), env=env,
                   capture_output=True, text=True)
if not resume:
    m = re.search(r"orch phase ([A-Za-z0-9._-]+) spec", data)
    if m:
        subprocess.run([ORCH, "phase", m.group(1), "spec"], env=os.environ,
                       capture_output=True)
time.sleep(120)
'''

# A fake codex that behaves like a ticket session with the plugin's hooks:
# prints its thread, writes its rollout under CODEX_HOME, fires SessionStart
# with its own pid and, on a fresh start, runs `orch phase <ticket> spec`.
SESSION_CODEX_SRC = r'''
import json, os, re, subprocess, sys, time, uuid
RECORD, ORCH = %(record)r, %(orch)r
a = sys.argv[1:]
data = sys.stdin.read()
with open(RECORD, "a") as f:
    f.write(json.dumps({"argv": a, "cwd": os.getcwd(), "pid": os.getpid(),
                        "stdin": data}) + "\n")
resume = a[:2] == ["exec", "resume"]
tid = a[-2] if resume else str(uuid.uuid4())
print(json.dumps({"type": "thread.started", "thread_id": tid}), flush=True)
d = os.path.join(os.environ["CODEX_HOME"], "sessions", "2026", "10", "04")
os.makedirs(d, exist_ok=True)
open(os.path.join(d, "rollout-2026-10-04T00-00-00-%%s.jsonl" %% tid), "a").close()
env = dict(os.environ, ORCH_HOOK_AGENT_PID=str(os.getpid()))
payload = {"session_id": tid, "cwd": os.getcwd(), "hook_event_name": "SessionStart",
           "source": "resume" if resume else "startup"}
subprocess.run([ORCH, "hook"], input=json.dumps(payload), env=env, capture_output=True,
               text=True)
if not resume:
    m = re.search(r"orch phase ([A-Za-z0-9._-]+) spec", data)
    if m:
        subprocess.run([ORCH, "phase", m.group(1), "spec"], env=os.environ,
                       capture_output=True)
time.sleep(120)
'''


class HarnessTestCase(AdapterTestCase):
    def setUp(self):
        super().setUp()
        self.codex_home = os.path.join(self.tmp, "codex-home")
        os.makedirs(self.codex_home)
        self.env["CODEX_HOME"] = self.codex_home

    def fake_agent(self, kind, sleep=0, header=True, thread="thread-1"):
        return self._script("fake-%s" % kind, FAKE_AGENT_SRC % {
            "record": self.record, "kind": kind, "sleep": float(sleep),
            "header": bool(header), "thread": thread})

    def use_pi(self, sleep=0, header=True):
        self.env["ORCH_HARNESS"] = "pi"
        self.env["ORCH_PI_BIN"] = self.fake_agent("pi", sleep, header)

    def db_row(self, tid, *cols):
        return self.db_exec("SELECT %s FROM tickets WHERE id=?" % ", ".join(cols),
                            (tid,))[0]

    def harness_env(self, **env):
        """self.env without ORCH_HARNESS, plus `env`."""
        e = {k: v for k, v in self.env.items() if k != "ORCH_HARNESS"}
        e.update(env)
        return e

    def platform_out(self, **env):
        p = subprocess.run([ORCH, "platform", "--json"], cwd=self.repo, capture_output=True,
                           text=True, env=self.harness_env(**env), timeout=30)
        self.assertEqual(p.returncode, 0, p.stderr)
        return json.loads(p.stdout)


# ---------------------------------------------------------------------------


class HarnessDetectionTests(HarnessTestCase):
    """`orch platform` reports the harness: ORCH_HARNESS, else the one the
    environment shows, else claude."""

    def test_default_is_claude(self):
        out = self.platform_out()
        self.assertEqual(out["harness"], "claude")

    def test_detects_pi(self):
        self.assertEqual(self.platform_out(PI_CODING_AGENT="true")["harness"], "pi")

    def test_detects_codex(self):
        self.assertEqual(self.platform_out(CODEX_THREAD_ID="t-1")["harness"], "codex")

    def test_detects_claude(self):
        self.assertEqual(self.platform_out(CLAUDECODE="1")["harness"], "claude")

    def test_env_override_beats_detection(self):
        out = self.platform_out(ORCH_HARNESS="pi", CODEX_THREAD_ID="t-1")
        self.assertEqual(out["harness"], "pi")

    def test_unknown_env_override_is_usage_error(self):
        p = subprocess.run([ORCH, "platform", "--json"], cwd=self.repo, capture_output=True,
                           text=True, env=self.harness_env(ORCH_HARNESS="gemini"))
        self.assertEqual(p.returncode, 2)
        self.assertIn("ORCH_HARNESS", p.stderr)

    def test_preflight_reports_harness(self):
        self.env["ORCH_HARNESS"] = "pi"
        self.env["ORCH_PI_BIN"] = self.fake_agent("pi")
        with open(os.path.join(self.state_dir, "config.json"), "w") as f:
            json.dump({"verify_harness": "true"}, f)
        p = self.orch("preflight", "--json")
        if p.returncode == 5 and "docker" in p.stderr:
            self.skipTest("docker not on PATH")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(json.loads(p.stdout)["harness"], "pi")

    def test_preflight_needs_harness_binary(self):
        self.env["ORCH_HARNESS"] = "pi"
        self.env["ORCH_PI_BIN"] = os.path.join(self.tmp, "no-such-pi")
        p = self.refused(5, "preflight")
        self.assertIn("no-such-pi", p.stderr)


class IsAgentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.orch = load_orch_module()

    def test_harness_processes(self):
        for comm, command, want in (
            ("pi", "pi", "pi"),
            ("/usr/local/bin/node", "node /x/bin/pi --session-id s", "pi"),
            ("/Users/u/.codex/packages/standalone/current/bin/codex", "codex exec --json -",
             "codex"),
            ("codex", "codex resume abc", "codex"),
            ("/usr/local/bin/claude", "claude --resume s", "claude"),
            ("zsh", "zsh -lc pi", None),
            ("python3", "python3 -m codex", None),
        ):
            self.assertEqual(self.orch.agent_of(comm, command), want, (comm, command))


class PiHeadlessTests(HarnessTestCase):
    def test_spawn_starts_pi_in_json_mode_with_the_skill_command(self):
        self.use_pi(sleep=30)
        self.spawn_new("t1", "headless")
        t = self.show("t1")
        self.assertEqual(t["harness"], "pi")
        call = self.wait_calls(1)[0]
        sid = t["session_id"]
        self.assertTrue(sid)
        self.assertEqual(call["argv"], ["-p", "--mode", "json", "--session-id", sid,
                                        "--approve"])
        self.assertEqual(call["cwd"], self.wt_path("t1"))
        self.assertEqual(call["stdin"], PI_SKILL + BRIEF)
        self.assertEqual(read_file(os.path.join(self.state_dir, "briefs", "t1.md")),
                         PI_SKILL + BRIEF)

    def test_liveness_uses_the_start_time_recorded_at_launch(self):
        # Pi overwrites its process title, so the session id is not on its
        # command line: the launch records the start time instead.
        self.use_pi(sleep=30)
        self.spawn_new("t1", "headless")
        pid_start, = self.db_row("t1", "pid_start")
        self.assertTrue(pid_start)
        self.assertTrue(self.show("t1")["alive"])

    def test_pi_args_from_config(self):
        self.use_pi(sleep=30)
        self.write_config({"pi_args": ["--approve", "--model", "x/y"]})
        self.spawn_new("t1", "headless")
        self.assertEqual(self.wait_calls(1)[0]["argv"][-3:], ["--approve", "--model", "x/y"])

    def test_launch_env_drops_parent_session_markers(self):
        self.use_pi(sleep=30)
        self.spawn_new("t1", "headless", env={"PI_SUBAGENT_CHILD": "1",
                                              "ORCH_PI_PARENT_SESSION": "parent",
                                              "PI_SUBAGENT_ID": "x"})
        env = self.wait_calls(1)[0]["env"]
        self.assertEqual(env, {"PI_SUBAGENT_CHILD": None, "ORCH_PI_PARENT_SESSION": None,
                               "PI_SUBAGENT_ID": None})

    def test_resume_continues_the_same_session_with_the_skill_command(self):
        self.use_pi(sleep=0)
        self.spawn_new("t1", "headless")
        self.wait_dead("t1")
        sid = self.show("t1")["session_id"]
        self.use_pi(sleep=30)
        self.ok("resume", "t1")
        call = self.wait_calls(2)[1]
        self.assertEqual(call["argv"], ["-p", "--mode", "json", "--session-id", sid,
                                        "--approve"])
        self.assertTrue(call["stdin"].startswith(PI_SKILL + "You are resuming work on ticket t1."),
                        call["stdin"])
        self.assertEqual(self.show("t1")["session_id"], sid)

    def test_resume_of_a_session_that_never_started_sends_the_brief(self):
        self.use_pi(sleep=0, header=False)
        self.spawn_new("t1", "headless")
        self.wait_dead("t1")
        self.use_pi(sleep=30)
        self.ok("resume", "t1")
        self.assertEqual(self.wait_calls(2)[1]["stdin"], PI_SKILL + BRIEF)

    def test_hook_records_the_pid_the_extension_names(self):
        self.use_pi(sleep=30)
        self.spawn_new("t1", "headless")
        t = self.show("t1")
        live = self.live_process()
        p = subprocess.run([ORCH, "hook"], cwd=t["worktree"], capture_output=True, text=True,
                           input=json.dumps({"session_id": t["session_id"],
                                             "cwd": t["worktree"],
                                             "hook_event_name": "SessionStart",
                                             "source": "startup"}),
                           env=dict(self.env, ORCH_HOOK_AGENT_PID=str(live.pid)))
        self.assertEqual(p.returncode, 0)
        self.assertIn("ticket orchestrator for t1", p.stdout)
        self.assertEqual(self.show("t1")["pid"], live.pid)

    def test_resume_can_switch_harness_and_starts_fresh(self):
        self.use_pi(sleep=0)
        self.spawn_new("t1", "headless")
        self.wait_dead("t1")
        old = self.show("t1")["session_id"]
        self.ok("resume", "t1", "--harness", "claude",
                env={"ORCH_CLAUDE_BIN": self.fake_claude(30)})
        t = self.show("t1")
        self.assertEqual(t["harness"], "claude")
        self.assertNotEqual(t["session_id"], old)
        call = self.wait_calls(2)[1]
        self.assertIn("--session-id", call["argv"])
        self.assertEqual(call["stdin"], "/orchestration:orchestration " + BRIEF)


class PiPlatformTests(HarnessTestCase):
    def test_orca_runs_interactive_pi(self):
        self.use_orca2()
        self.env["ORCH_PLATFORM"] = "orca"
        self.env["ORCH_HARNESS"] = "pi"
        self.spawn_new("t1")
        t = self.show("t1")
        create = [r for r in self.log("orca") if r["argv"][:2] == ["terminal", "create"]][0]
        cmd = create["argv"][create["argv"].index("--command") + 1]
        prompt = os.path.join(self.state_dir, "briefs", "t1.md")
        self.assertEqual(cmd, "pi --session-id %s --approve \"$(cat %s)\""
                         % (t["session_id"], shlex.quote(prompt)))
        # Claude's folder trust is Claude's: a Pi launch leaves it alone.
        with open(self.env["ORCH_CLAUDE_JSON"]) as f:
            self.assertEqual(json.load(f), {"projects": {}})

    def test_herdr_starts_kind_pi(self):
        self.use_herdr2()
        self.env["ORCH_PLATFORM"] = "herdr"
        self.env["ORCH_HARNESS"] = "pi"
        self.spawn_new("t1")
        t = self.show("t1")
        start = [r for r in self.log("herdr") if r["argv"][:2] == ["agent", "start"]][0]
        self.assertEqual(start["argv"][2:], ["tt1", "--kind", "pi", "--pane", "w1:p1", "--",
                                             "--session-id", t["session_id"], "--approve"])
        prompt = [r for r in self.log("herdr") if r["argv"][:2] == ["agent", "prompt"]][0]
        self.assertEqual(prompt["argv"][3], PI_SKILL + BRIEF)

    def test_desktop_refuses_pi(self):
        self.env["ORCH_HARNESS"] = "pi"
        p = self.orch("add", "t1", "--title", "x")
        p = self.refused(3, "spawn", "t1", "--worktree", self.worktree, "--brief-file",
                         self.brief, "--platform", "desktop")
        self.assertIn("Claude", p.stderr)


class PiSelftestTests(HarnessTestCase):
    def test_headless_selftest_on_pi(self):
        self.env["ORCH_HARNESS"] = "pi"
        self.env["ORCH_PI_BIN"] = self._script("fake-session-pi", SESSION_PI_SRC % {
            "record": self.record, "orch": ORCH})
        p = self.orch("selftest", "--json", "--timeout", "30", timeout=150)
        out = json.loads(p.stdout)
        self.assertEqual(p.returncode, 0, "stdout=%r stderr=%r" % (p.stdout, p.stderr))
        self.assertIs(out["ok"], True, out)
        self.assertEqual(out.get("harness"), "pi")
        for call in self.calls():
            self.assertTrue(wait_until(lambda: not pid_alive(call["pid"]), timeout=5))


class CodexTestCase(HarnessTestCase):
    def use_codex(self, sleep=0, header=True, thread="thread-1"):
        self.env["ORCH_HARNESS"] = "codex"
        self.env["ORCH_CODEX_BIN"] = self.fake_agent("codex", sleep, header, thread)

    def hook(self, tid, sid, pid, event="SessionStart"):
        t = self.show(tid)
        return subprocess.run([ORCH, "hook"], cwd=t["worktree"], capture_output=True,
                              text=True, env=dict(self.env, ORCH_HOOK_AGENT_PID=str(pid)),
                              input=json.dumps({"session_id": sid, "cwd": t["worktree"],
                                                "hook_event_name": event,
                                                "source": "startup"}))

    def rollout(self, sid):
        d = os.path.join(self.codex_home, "sessions", "2026", "10", "04")
        os.makedirs(d, exist_ok=True)
        open(os.path.join(d, "rollout-2026-10-04T10-00-00-%s.jsonl" % sid), "w").close()

    def codex_config(self):
        path = os.path.join(self.codex_home, "config.toml")
        return read_file(path) if os.path.exists(path) else None


class CodexHeadlessTests(CodexTestCase):
    def test_spawn_runs_codex_exec_with_the_prompt_on_stdin(self):
        self.use_codex(sleep=30)
        self.spawn_new("t1", "headless")
        t = self.show("t1")
        self.assertEqual(t["harness"], "codex")
        self.assertIsNone(t["session_id"])  # Codex picks the thread id itself
        self.assertTrue(t["alive"])
        call = self.wait_calls(1)[0]
        self.assertEqual(call["argv"], ["exec", "--json"] + CODEX_ARGS + ["-"])
        self.assertEqual(call["stdin"], CODEX_SKILL + BRIEF)

    def test_session_start_from_the_launched_process_attaches_its_thread(self):
        self.use_codex(sleep=30)
        self.spawn_new("t1", "headless")
        pid = self.show("t1")["pid"]
        p = self.hook("t1", "thr-9", pid)
        self.assertIn("ticket orchestrator for t1", p.stdout)
        t = self.show("t1")
        self.assertEqual(t["session_id"], "thr-9")
        self.assertEqual(t["pid"], pid)
        self.assertTrue(t["alive"])

    def test_session_start_from_another_process_does_not_attach(self):
        self.use_codex(sleep=30)
        self.spawn_new("t1", "headless")
        other = self.live_process()
        self.hook("t1", "thr-x", other.pid)
        self.assertIsNone(self.show("t1")["session_id"])

    def test_resume_continues_the_thread_when_its_rollout_exists(self):
        self.use_codex(sleep=3)
        self.spawn_new("t1", "headless")
        self.hook("t1", "thr-9", self.show("t1")["pid"])
        self.rollout("thr-9")
        self.wait_dead("t1")
        self.use_codex(sleep=30)
        self.ok("resume", "t1")
        call = self.wait_calls(2)[1]
        self.assertEqual(call["argv"], ["exec", "resume", "--json"] + CODEX_ARGS
                         + ["thr-9", "-"])
        self.assertTrue(call["stdin"].startswith(
            CODEX_SKILL + "You are resuming work on ticket t1."), call["stdin"])
        self.assertEqual(self.show("t1")["session_id"], "thr-9")

    def test_resume_without_a_rollout_starts_fresh_from_the_brief(self):
        self.use_codex(sleep=3)
        self.spawn_new("t1", "headless")
        self.hook("t1", "thr-9", self.show("t1")["pid"])
        self.wait_dead("t1")
        self.use_codex(sleep=30)
        self.ok("resume", "t1")
        call = self.wait_calls(2)[1]
        self.assertEqual(call["argv"], ["exec", "--json"] + CODEX_ARGS + ["-"])
        self.assertEqual(call["stdin"], CODEX_SKILL + BRIEF)
        self.assertIsNone(self.show("t1")["session_id"])

    def test_resume_takes_the_thread_from_the_log_when_no_hook_came(self):
        self.use_codex(sleep=0, thread="thr-log")
        self.spawn_new("t1", "headless")
        self.wait_dead("t1")
        self.rollout("thr-log")
        self.use_codex(sleep=30)
        self.ok("resume", "t1")
        call = self.wait_calls(2)[1]
        self.assertEqual(call["argv"][:2], ["exec", "resume"])
        self.assertEqual(call["argv"][-2:], ["thr-log", "-"])
        self.assertEqual(self.show("t1")["session_id"], "thr-log")


class CodexPlatformTests(CodexTestCase):
    def test_orca_runs_interactive_codex_and_trusts_the_worktree(self):
        with open(os.path.join(self.codex_home, "config.toml"), "w") as f:
            f.write('model = "m"\n')
        self.use_orca2()
        self.env["ORCH_PLATFORM"] = "orca"
        self.env["ORCH_HARNESS"] = "codex"
        self.spawn_new("t1")
        create = [r for r in self.log("orca") if r["argv"][:2] == ["terminal", "create"]][0]
        cmd = create["argv"][create["argv"].index("--command") + 1]
        prompt = os.path.join(self.state_dir, "briefs", "t1.md")
        self.assertEqual(cmd, "codex %s \"$(cat %s)\"" % (" ".join(CODEX_ARGS),
                                                         shlex.quote(prompt)))
        wt = self.show("t1")["worktree"]
        self.assertEqual(self.codex_config(), 'model = "m"\n\n[projects."%s"]\n'
                         'trust_level = "trusted"\n' % wt)
        # Claude's folder trust is Claude's: a Codex launch leaves it alone.
        with open(self.env["ORCH_CLAUDE_JSON"]) as f:
            self.assertEqual(json.load(f), {"projects": {}})
        self.ok("retire", "t1", "--force")
        self.assertEqual(self.codex_config(), 'model = "m"\n')

    def test_existing_codex_project_entry_is_left_alone(self):
        self.use_orca2()
        self.env["ORCH_PLATFORM"] = "orca"
        self.use_codex()
        wt = os.path.realpath(os.path.join(self.tmp, "orca-wts", "t1"))
        text = 'model = "m"\n\n[projects."%s"]\ntrust_level = "untrusted"\n' % wt
        with open(os.path.join(self.codex_home, "config.toml"), "w") as f:
            f.write(text)
        self.spawn_new("t1")
        self.assertEqual(self.codex_config(), text)
        self.ok("retire", "t1", "--force")
        self.assertEqual(self.codex_config(), text)

    def test_session_start_attaches_the_first_thread_on_orca(self):
        self.use_orca2()
        self.env["ORCH_PLATFORM"] = "orca"
        self.use_codex()
        self.spawn_new("t1")
        live = self.live_process()
        self.hook("t1", "thr-o", live.pid)
        t = self.show("t1")
        self.assertEqual(t["session_id"], "thr-o")
        self.assertEqual(t["pid"], live.pid)
        # A second codex in the same worktree does not take over a live one.
        other = self.live_process()
        self.hook("t1", "thr-p", other.pid)
        self.assertEqual(self.show("t1")["session_id"], "thr-o")

    def test_herdr_starts_kind_codex(self):
        self.use_herdr2()
        self.env["ORCH_PLATFORM"] = "herdr"
        self.use_codex()
        self.spawn_new("t1")
        start = [r for r in self.log("herdr") if r["argv"][:2] == ["agent", "start"]][0]
        self.assertEqual(start["argv"][2:], ["tt1", "--kind", "codex", "--pane", "w1:p1",
                                             "--"] + CODEX_ARGS)
        prompt = [r for r in self.log("herdr") if r["argv"][:2] == ["agent", "prompt"]][0]
        self.assertEqual(prompt["argv"][3], CODEX_SKILL + BRIEF)

    def test_herdr_resume_continues_the_thread(self):
        self.use_herdr2()
        self.env["ORCH_PLATFORM"] = "herdr"
        self.use_codex()
        self.spawn_new("t1")
        live = self.live_process()
        self.hook("t1", "thr-h", live.pid)
        self.rollout("thr-h")
        live.kill()
        live.wait()
        self.wait_dead("t1")
        self.ok("resume", "t1")
        start = [r for r in self.log("herdr") if r["argv"][:2] == ["agent", "start"]][-1]
        self.assertEqual(start["argv"][-len(CODEX_ARGS) - 3:],
                         ["--", "resume"] + CODEX_ARGS + ["thr-h"])


class CodexSelftestTests(HarnessTestCase):
    def test_headless_selftest_on_codex(self):
        self.env["ORCH_HARNESS"] = "codex"
        self.env["ORCH_CODEX_BIN"] = self._script("fake-session-codex", SESSION_CODEX_SRC % {
            "record": self.record, "orch": ORCH})
        p = self.orch("selftest", "--json", "--timeout", "30", timeout=150)
        out = json.loads(p.stdout)
        self.assertEqual(p.returncode, 0, "stdout=%r stderr=%r" % (p.stdout, p.stderr))
        self.assertIs(out["ok"], True, out)
        self.assertEqual(out.get("harness"), "codex")
        calls = self.calls()
        self.assertEqual(calls[1]["argv"][:2], ["exec", "resume"])
        for call in calls:
            self.assertTrue(wait_until(lambda: not pid_alive(call["pid"]), timeout=5))


if __name__ == "__main__":
    unittest.main()
