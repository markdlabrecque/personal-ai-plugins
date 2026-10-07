"""Black-box tests for scripts/orch (the orchestration state CLI).

Contract: skills/orchestration/references/orch-cli.md

Run from the plugin dir:  python3 -m unittest discover -s tests -v
"""

import json
import os
import re
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
ORCH = os.path.realpath(os.path.join(HERE, "..", "scripts", "orch"))

PHASE_STATUS = {
    "ready": "ready",
    "dispatched": "in_progress",
    "spec": "in_progress",
    "tests": "in_progress",
    "implement": "in_progress",
    "fix": "in_progress",
    "review": "in_review",
    "verify": "verified",
    "report": "verified",
    "mr": "verified",
    "ci": "verified",
    "done": "done",
    "blocked": "blocked",
}


# Environment variables the agent harnesses export to their tools; scrubbed so
# harness detection never sees the agent running this suite.
HARNESS_MARKERS = ("CLAUDECODE", "PI_CODING_AGENT", "PI_SESSION_ID", "PI_SUBAGENT_CHILD",
                   "ORCH_PI_PARENT_SESSION", "CODEX_THREAD_ID", "CODEX_SESSION_ID",
                   "CODEX_CI", "AI_AGENT")


def pid_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def wait_until(fn, timeout=10.0, interval=0.05):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if fn():
            return True
        time.sleep(interval)
    return fn()


def ticket_id(t):
    return t["id"]


def list_in(obj, key):
    """Extract the list payload from a JSON object (e.g. {"tickets": [...]})."""
    assert isinstance(obj, dict), "expected a JSON object, got %r" % (obj,)
    assert isinstance(obj.get(key), list), "no %r list in %r" % (key, obj)
    return obj[key]


def ev_to(e):
    return e["to_phase"]


def ev_from(e):
    return e["from_phase"]


def is_retired(t):
    return bool(t["retired"])


def read_file(path):
    with open(path) as f:
        return f.read()


class OrchTestCase(unittest.TestCase):
    """Each test gets its own git repo acting as the main checkout."""

    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="orch-test-"))
        self.repo = os.path.join(self.tmp, "main")
        os.makedirs(self.repo)
        self.state_dir = os.path.join(self.repo, ".agents", "orchestration")
        self.record = os.path.join(self.tmp, "claude-calls.jsonl")
        self._fake_count = 0

        # Strip platform detection too: spawn defaults to the detected platform,
        # and this suite may itself run inside Orca, Herdr or Claude Desktop.
        self.env = {
            k: v for k, v in os.environ.items()
            if not k.startswith(("ORCH_", "ORCA_", "HERDR_"))
            and k not in ("CLAUDE_CODE_ENTRYPOINT",) + HARNESS_MARKERS
        }
        self.env.update(
            {
                "GIT_AUTHOR_NAME": "Test",
                "GIT_AUTHOR_EMAIL": "test@example.com",
                "GIT_COMMITTER_NAME": "Test",
                "GIT_COMMITTER_EMAIL": "test@example.com",
            }
        )
        self.git("init", "-q", "-b", "main")
        with open(os.path.join(self.repo, "README"), "w") as f:
            f.write("hello\n")
        self.git("add", "README")
        self.git("commit", "-q", "-m", "init")

        # Never let a real `claude` run: default to a fake that exits at once.
        self.env["ORCH_CLAUDE_BIN"] = self.fake_claude(sleep=0)

        # A platform must be configured (platforms.md "Machine config"), the
        # real machine config must never be read, and retire must never reach
        # the real retire-worktree engine (it would remove worktrees and call
        # ddev): a no-op engine stands in.
        self.noop_retire = os.path.join(self.tmp, "noop-retire-engine")
        with open(self.noop_retire, "w") as f:
            f.write("#!/bin/sh\nexit 0\n")
        os.chmod(self.noop_retire, 0o755)
        self.xdg_default = os.path.join(self.tmp, "xdg-default")
        os.makedirs(self.xdg_default)
        # Claude's user config (folder trust) is a temp file: no test may ever
        # reach the real ~/.claude.json.
        self.claude_json = os.path.join(self.tmp, "claude-home", ".claude.json")
        os.makedirs(os.path.dirname(self.claude_json))
        with open(self.claude_json, "w") as f:
            json.dump({"projects": {}}, f)
        self.set_test_platform_env()

        self.worktree = os.path.join(self.tmp, "wt")
        os.makedirs(self.worktree)
        self.brief = os.path.join(self.tmp, "brief.md")
        with open(self.brief, "w") as f:
            f.write("Implement ticket. Brief body.")

    def set_test_platform_env(self):
        self.env["ORCH_PLATFORM"] = "headless"
        # The suite may run inside Claude Code, Pi or Codex: pin the harness.
        self.env["ORCH_HARNESS"] = "claude"
        self.env["XDG_CONFIG_HOME"] = self.xdg_default
        self.env["ORCH_RETIRE_ENGINE"] = self.noop_retire
        self.env["ORCH_CLAUDE_JSON"] = self.claude_json
        self.assert_claude_json_isolated()

    def assert_claude_json_isolated(self):
        path = self.env.get("ORCH_CLAUDE_JSON")
        assert path and path.startswith(self.tmp + os.sep), \
            "ORCH_CLAUDE_JSON must point into the test's temp dir, not %r" % path

    def tearDown(self):
        for call in self.calls():
            pid = call.get("pid")
            if not pid:
                continue
            for killer in (os.killpg, os.kill):
                try:
                    killer(pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError, OSError):
                    pass
        shutil.rmtree(self.tmp, ignore_errors=True)

    # ---- helpers ---------------------------------------------------------

    def git(self, *args, cwd=None):
        subprocess.run(
            ["git", *args],
            cwd=cwd or self.repo,
            env=self.env,
            check=True,
            capture_output=True,
            text=True,
        )

    def orch(self, *args, env=None, cwd=None, timeout=30):
        if not os.path.isfile(ORCH):
            self.fail("scripts/orch does not exist at %s" % ORCH)
        e = dict(self.env)
        if env:
            e.update(env)
        assert (e.get("ORCH_CLAUDE_JSON") or "").startswith(self.tmp + os.sep), \
            "refusing to run orch without a temp ORCH_CLAUDE_JSON"
        return subprocess.run(
            [ORCH, *args],
            cwd=cwd or self.repo,
            env=e,
            capture_output=True,
            text=True,
            timeout=timeout,
        )

    def ok(self, *args, **kw):
        p = self.orch(*args, **kw)
        self.assertEqual(
            p.returncode, 0, "orch %s failed: rc=%s stdout=%r stderr=%r"
            % (" ".join(args), p.returncode, p.stdout, p.stderr),
        )
        return p

    def j(self, *args, **kw):
        p = self.ok(*args, "--json", **kw)
        try:
            return json.loads(p.stdout)
        except ValueError:
            self.fail("orch %s --json did not print JSON: %r" % (" ".join(args), p.stdout))

    def refused(self, code, *args, **kw):
        p = self.orch(*args, **kw)
        self.assertEqual(
            p.returncode, code, "orch %s: expected rc=%s got %s; stdout=%r stderr=%r"
            % (" ".join(args), code, p.returncode, p.stdout, p.stderr),
        )
        if code in (3, 4, 5):
            self.assertTrue(p.stderr.strip(), "refusal must explain on stderr")
        return p

    def show(self, ticket):
        return self.j("show", ticket)

    def tickets(self, *cmd):
        return list_in(self.j(*cmd), "tickets")

    def fake_claude(self, sleep, init=True):
        """A stand-in for claude: records argv/cwd/pid/stdin, and (like real
        stream-json output) prints a system line carrying its session id."""
        self._fake_count += 1
        path = os.path.join(self.tmp, "fake-claude-%d" % self._fake_count)
        with open(path, "w") as f:
            f.write(
                "#!%s\n"
                "import json, os, sys, time\n"
                "data = sys.stdin.read()\n"
                "with open(%r, 'a') as f:\n"
                "    f.write(json.dumps({'argv': sys.argv[1:], 'cwd': os.getcwd(),"
                " 'pid': os.getpid(), 'stdin': data}) + '\\n')\n"
                "print('FAKE-CLAUDE-OUTPUT', flush=True)\n"
                "a = sys.argv[1:]\n"
                "for flag in ('--session-id', '--resume'):\n"
                "    if %r and flag in a:\n"
                "        print(json.dumps({'type': 'system', 'session_id':"
                " a[a.index(flag) + 1]}), flush=True)\n"
                "time.sleep(%r)\n" % (sys.executable, self.record, bool(init),
                                     float(sleep))
            )
        os.chmod(path, 0o755)
        return path

    def db_path(self):
        return os.path.join(self.state_dir, "state.db")

    def db_exec(self, sql, params=()):
        con = sqlite3.connect(self.db_path(), timeout=30)
        try:
            rows = con.execute(sql, params).fetchall()
            con.commit()
            return rows
        finally:
            con.close()

    def foreign_process(self):
        """An unrelated live process that is its own group leader."""
        p = subprocess.Popen(["sleep", "60"], start_new_session=True)

        def cleanup():
            p.kill()
            p.wait()
        self.addCleanup(cleanup)
        return p

    def events(self, ticket):
        return list_in(self.j("events", ticket), "events")

    def calls(self):
        if not os.path.exists(self.record):
            return []
        with open(self.record) as f:
            return [json.loads(line) for line in f if line.strip()]

    def wait_calls(self, n):
        self.assertTrue(
            wait_until(lambda: len(self.calls()) >= n),
            "fake claude was not invoked %d time(s)" % n,
        )
        return self.calls()

    def init(self):
        self.ok("init")

    def write_config(self, cfg):
        os.makedirs(self.state_dir, exist_ok=True)
        with open(os.path.join(self.state_dir, "config.json"), "w") as f:
            json.dump(cfg, f)

    def add(self, ticket, title="A ticket"):
        self.ok("add", ticket, "--title", title)

    def new_worktree(self, name):
        path = os.path.join(self.tmp, "wt-" + name)
        os.makedirs(path, exist_ok=True)
        return path

    def spawn(self, ticket, sleep=0, init=True, worktree=None):
        self.ok(
            "spawn", ticket, "--worktree", worktree or self.worktree,
            "--brief-file", self.brief,
            env={"ORCH_CLAUDE_BIN": self.fake_claude(sleep, init)},
        )
        return self.show(ticket)

    def wait_dead(self, ticket):
        self.assertTrue(
            wait_until(lambda: not self.show(ticket)["alive"]),
            "session for %s never died" % ticket,
        )

    def phases(self, ticket, *phases):
        for ph in phases:
            self.ok("phase", ticket, ph)

    def dispatched(self, ticket, worktree=None):
        """add + spawn with a session that exits immediately."""
        self.add(ticket)
        self.spawn(ticket, sleep=0, worktree=worktree)
        self.wait_dead(ticket)

    def to_ci(self, ticket, worktree=None):
        self.dispatched(ticket, worktree=worktree)
        self.phases(ticket, "spec", "tests", "implement", "review", "verify",
                    "report", "mr", "ci")

    def to_done(self, ticket, sha="abc123", worktree=None):
        self.to_ci(ticket, worktree=worktree)
        self.ok("ci", ticket, "--sha", sha, "--passed")
        self.ok("merged", ticket, "--sha", sha)


# ---------------------------------------------------------------------------


class InitTests(OrchTestCase):
    def test_init_creates_state_and_gitignore(self):
        self.init()
        self.assertTrue(os.path.exists(os.path.join(self.state_dir, "state.db")))
        with open(os.path.join(self.state_dir, ".gitignore")) as f:
            lines = [l.strip() for l in f.read().splitlines()]
        self.assertIn("state.db*", lines)
        self.assertIn("logs/", lines)
        self.assertIn("briefs/", lines)

    def test_init_is_idempotent_and_keeps_data(self):
        self.init()
        self.add("T-1")
        self.init()
        with open(os.path.join(self.state_dir, ".gitignore")) as f:
            lines = [l.strip() for l in f.read().splitlines()]
        self.assertEqual(lines.count("state.db*"), 1)
        self.assertEqual(lines.count("logs/"), 1)
        self.assertEqual(self.show("T-1")["phase"], "ready")

    def test_orch_home_override(self):
        home = os.path.join(self.tmp, "custom-home")
        self.ok("init", env={"ORCH_HOME": home})
        self.assertTrue(os.path.exists(os.path.join(home, "state.db")))
        self.assertFalse(os.path.exists(os.path.join(self.state_dir, "state.db")))

    def test_linked_worktree_resolves_to_main_checkout(self):
        linked = os.path.join(self.tmp, "linked")
        self.git("worktree", "add", "-q", "-b", "feature", linked)
        self.ok("init", cwd=linked)
        self.assertTrue(os.path.exists(os.path.join(self.state_dir, "state.db")))
        self.assertFalse(os.path.exists(os.path.join(linked, ".agents")))
        self.ok("add", "T-9", "--title", "from worktree", cwd=linked)
        ids = [ticket_id(t) for t in self.tickets("list")]  # run in main checkout
        self.assertIn("T-9", ids)

    def test_usage_error_exit_2(self):
        self.init()
        self.refused(2, "add", "T-1")  # missing --title


class PreflightTests(OrchTestCase):
    def setUp(self):
        super().setUp()
        self.bin = os.path.join(self.tmp, "bin")
        os.makedirs(self.bin)
        os.symlink(shutil.which("git", path=self.env.get("PATH")) or "/usr/bin/git",
                   os.path.join(self.bin, "git"))
        os.symlink(sys.executable, os.path.join(self.bin, "python3"))
        self.env["PATH"] = self.bin + os.pathsep + "/usr/bin:/bin:/usr/sbin:/sbin"
        for d in ("/usr/bin", "/bin", "/usr/sbin", "/sbin"):
            for tool in ("ddev", "docker"):
                if os.path.exists(os.path.join(d, tool)):
                    self.skipTest("%s/%s exists; cannot control PATH" % (d, tool))
        self.init()

    def fake_tool(self, name):
        p = os.path.join(self.bin, name)
        with open(p, "w") as f:
            f.write("#!/bin/sh\nexit 0\n")
        os.chmod(p, 0o755)

    def write_env(self, text):
        with open(os.path.join(self.repo, ".env"), "w") as f:
            f.write(text)

    def ddev_project(self):
        os.makedirs(os.path.join(self.repo, ".ddev"))
        with open(os.path.join(self.repo, ".ddev", "config.yaml"), "w") as f:
            f.write("name: test\n")

    def test_missing_base_branch_fails(self):
        self.write_env("OTHER=1\n")
        self.ddev_project()
        self.fake_tool("ddev")
        p = self.refused(5, "preflight")
        self.assertIn("BASE_BRANCH", p.stdout + p.stderr)

    def test_no_env_file_fails(self):
        self.ddev_project()
        self.fake_tool("ddev")
        self.refused(5, "preflight")

    def test_ddev_chosen(self):
        self.write_env("BASE_BRANCH=develop\n")
        self.ddev_project()
        self.fake_tool("ddev")
        self.fake_tool("docker")
        self.write_config({"verify_harness": "docker compose up -d"})
        out = self.j("preflight")
        self.assertEqual(out["verify_env"], "ddev")
        self.assertEqual(out["base_branch"], "develop")

    def test_env_quoted_value_with_trailing_comment(self):
        self.ddev_project()
        self.fake_tool("ddev")
        for text in ('export BASE_BRANCH="dev" # trailing\n',
                     "BASE_BRANCH='dev' # trailing\n",
                     "BASE_BRANCH=dev # c\n"):
            self.write_env(text)
            self.assertEqual(self.j("preflight")["base_branch"], "dev", text)

    def test_docker_chosen_without_ddev(self):
        self.write_env("BASE_BRANCH=main\n")
        self.ddev_project()  # config present but ddev not on PATH
        self.fake_tool("docker")
        self.write_config({"verify_harness": "docker compose up -d"})
        out = self.j("preflight")
        self.assertEqual(out["verify_env"], "docker")
        self.assertEqual(out["base_branch"], "main")

    def test_docker_needs_verify_harness(self):
        self.write_env("BASE_BRANCH=main\n")
        self.fake_tool("docker")
        self.refused(5, "preflight")

    def test_ddev_on_path_without_config_yaml_is_not_ddev(self):
        self.write_env("BASE_BRANCH=main\n")
        self.fake_tool("ddev")
        self.refused(5, "preflight")

    def test_neither_env_fails(self):
        self.write_env("BASE_BRANCH=main\n")
        self.refused(5, "preflight")

    def test_lists_every_failure(self):
        self.write_env("NOPE=1\n")
        p = self.refused(5, "preflight")
        out = p.stdout + p.stderr
        self.assertIn("BASE_BRANCH", out)
        self.assertRegex(out.lower(), r"ddev|docker|verif")

    def test_env_other_keys_not_echoed(self):
        secret1 = "sk-live-" + uuid.uuid4().hex
        secret2 = "pw-" + uuid.uuid4().hex
        self.write_env(
            "API_TOKEN=%s\nBASE_BRANCH=main\nDB_PASSWORD=%s\n" % (secret1, secret2)
        )
        self.ddev_project()
        self.fake_tool("ddev")
        for args in (("preflight",), ("preflight", "--json")):
            p = self.ok(*args)
            out = p.stdout + p.stderr
            for s in (secret1, secret2, "API_TOKEN", "DB_PASSWORD"):
                self.assertNotIn(s, out)
        # also on the failure path
        os.remove(os.path.join(self.bin, "ddev"))
        p = self.refused(5, "preflight")
        for s in (secret1, secret2, "API_TOKEN", "DB_PASSWORD"):
            self.assertNotIn(s, p.stdout + p.stderr)


class TicketCrudTests(OrchTestCase):
    def setUp(self):
        super().setUp()
        self.init()

    def test_add_and_show(self):
        self.ok("add", "T-1", "--title", "First", "--url", "https://example.com/1")
        t = self.show("T-1")
        self.assertEqual(ticket_id(t), "T-1")
        self.assertEqual(t["phase"], "ready")
        self.assertEqual(t["status"], "ready")
        self.assertEqual(t["review_rounds"], 0)
        self.assertFalse(t["alive"])
        self.assertFalse(is_retired(t))

    def test_add_rejects_unsafe_ids(self):
        for bad in ("../../escape", "a/b", "-x", "", "a..b", ".hidden", "a b"):
            p = self.refused(2, "add", "--title", "T", "--", bad)
            self.assertNotIn("Traceback", p.stderr)
        self.assertEqual(self.tickets("list"), [])
        for good in ("T-1", "PROJ_42", "a.b", "113"):
            self.add(good)

    def test_duplicate_add_refused(self):
        self.add("T-1")
        self.refused(3, "add", "T-1", "--title", "again")

    def test_show_unknown(self):
        self.refused(4, "show", "NOPE")

    def test_phase_unknown_ticket(self):
        self.refused(4, "phase", "NOPE", "spec")

    def test_list(self):
        self.add("T-1")
        self.add("T-2")
        ts = self.tickets("list")
        self.assertEqual(sorted(ticket_id(t) for t in ts), ["T-1", "T-2"])
        for t in ts:
            for key in ("phase", "status", "review_rounds", "pid", "alive"):
                self.assertIn(key, t)
            self.assertFalse(is_retired(t))


class TransitionTests(OrchTestCase):
    def setUp(self):
        super().setUp()
        self.init()

    def assert_status(self, ticket, phase):
        t = self.show(ticket)
        self.assertEqual(t["phase"], phase)
        self.assertEqual(t["status"], PHASE_STATUS[phase], "phase %s" % phase)

    def test_derived_status_per_phase(self):
        self.add("T-1")
        self.assert_status("T-1", "ready")
        self.spawn("T-1")
        self.assert_status("T-1", "dispatched")
        for ph in ("spec", "tests", "implement", "review", "fix", "review",
                   "verify", "report", "mr", "ci"):
            self.ok("phase", "T-1", ph)
            self.assert_status("T-1", ph)
        self.ok("block", "T-1", "--reason", "waiting")
        self.assert_status("T-1", "blocked")
        self.ok("unblock", "T-1")
        self.ok("ci", "T-1", "--sha", "s1", "--passed")
        self.ok("merged", "T-1", "--sha", "s1")
        self.assert_status("T-1", "done")

    def test_happy_path(self):
        self.add("T-1")
        t = self.spawn("T-1")
        self.assertEqual(t["phase"], "dispatched")
        self.wait_dead("T-1")
        self.phases("T-1", "spec", "tests", "implement", "review", "verify",
                    "report", "mr", "ci")
        self.assertEqual(self.show("T-1")["review_rounds"], 1)
        self.ok("ci", "T-1", "--sha", "deadbeef", "--passed")
        self.ok("merged", "T-1", "--sha", "deadbeef")
        self.assertEqual(self.show("T-1")["phase"], "done")
        self.ok("retire", "T-1")
        self.assertTrue(is_retired(self.show("T-1")))

    def test_illegal_transitions(self):
        self.add("T-1")
        self.refused(3, "phase", "T-1", "spec")  # ready -> spec
        self.refused(3, "phase", "T-1", "done")
        self.spawn("T-1")
        self.ok("phase", "T-1", "spec")
        self.refused(3, "phase", "T-1", "review")  # spec -> review
        self.refused(3, "phase", "T-1", "done")
        self.refused(3, "phase", "T-1", "ready")
        self.assertEqual(self.show("T-1")["phase"], "spec")
        self.phases("T-1", "tests", "implement", "review", "verify", "report",
                    "mr", "ci")
        self.refused(3, "phase", "T-1", "done")  # ci -> done only via merged
        self.assertEqual(self.show("T-1")["phase"], "ci")

    def test_skip_lane_spec_to_implement(self):
        self.dispatched("T-1")
        self.phases("T-1", "spec", "implement")
        self.assertEqual(self.show("T-1")["phase"], "implement")

    def test_skip_lane_review_to_report(self):
        self.dispatched("T-1")
        self.phases("T-1", "spec", "implement", "review", "report", "mr")
        self.assertEqual(self.show("T-1")["phase"], "mr")

    def test_ci_back_to_mr(self):
        self.to_ci("T-1")
        self.ok("phase", "T-1", "mr")
        self.ok("phase", "T-1", "ci")

    def test_review_cap(self):
        self.dispatched("T-1")
        self.phases("T-1", "spec", "tests", "implement", "review")
        self.assertEqual(self.show("T-1")["review_rounds"], 1)
        self.phases("T-1", "fix", "review")
        self.assertEqual(self.show("T-1")["review_rounds"], 2)
        p = self.refused(3, "phase", "T-1", "fix")
        self.assertRegex(p.stderr.lower(), r"follow.?up")
        self.assertEqual(self.show("T-1")["phase"], "review")
        self.ok("phase", "T-1", "verify")
        self.refused(3, "phase", "T-1", "fix")
        self.phases("T-1", "report", "mr", "ci")
        self.ok("phase", "T-1", "fix")  # CI repair is never capped
        self.ok("phase", "T-1", "ci")
        self.ok("phase", "T-1", "fix")
        self.ok("phase", "T-1", "ci")
        self.assertEqual(self.show("T-1")["review_rounds"], 2)

    def test_block_unblock_restores_prior_phase(self):
        self.dispatched("T-1")
        self.phases("T-1", "spec", "tests")
        self.ok("block", "T-1", "--reason", "needs input")
        self.assertEqual(self.show("T-1")["phase"], "blocked")
        self.ok("unblock", "T-1")
        self.assertEqual(self.show("T-1")["phase"], "tests")
        self.ok("phase", "T-1", "implement")

    def test_events_in_order(self):
        self.add("T-1")
        self.spawn("T-1")
        self.phases("T-1", "spec", "tests")
        self.ok("block", "T-1", "--reason", "r")
        self.ok("unblock", "T-1")
        evs = list_in(self.j("events", "T-1"), "events")
        tos = [ev_to(e) for e in evs]
        self.assertEqual(tos, ["ready", "dispatched", "spec", "tests", "blocked", "tests"])
        self.assertEqual(ev_from(evs[2]), "dispatched")
        self.assertEqual(ev_from(evs[3]), "spec")
        for e in evs:
            self.assertIn("kind", e)
        self.refused(4, "events", "NOPE")

    def test_refused_transition_not_logged(self):
        self.dispatched("T-1")
        self.ok("phase", "T-1", "spec")
        before = len(list_in(self.j("events", "T-1"), "events"))
        self.refused(3, "phase", "T-1", "review")
        after = len(list_in(self.j("events", "T-1"), "events"))
        self.assertEqual(before, after)


class CiMergeTests(OrchTestCase):
    def setUp(self):
        super().setUp()
        self.init()

    def test_ci_requires_phase_ci(self):
        self.dispatched("T-1")
        self.phases("T-1", "spec", "tests", "implement", "review", "verify",
                    "report", "mr")
        self.refused(3, "ci", "T-1", "--sha", "s1", "--passed")
        self.ok("phase", "T-1", "ci")
        self.ok("ci", "T-1", "--sha", "s1", "--passed")

    def test_merged_refused_without_ci_pass(self):
        self.to_ci("T-1")
        self.refused(3, "merged", "T-1", "--sha", "s1")
        self.ok("ci", "T-1", "--sha", "s1", "--failed")
        self.refused(3, "merged", "T-1", "--sha", "s1")
        self.assertEqual(self.show("T-1")["phase"], "ci")

    def test_merged_refused_for_different_sha(self):
        self.to_ci("T-1")
        self.ok("ci", "T-1", "--sha", "aaa111", "--passed")
        self.refused(3, "merged", "T-1", "--sha", "bbb222")
        self.assertEqual(self.show("T-1")["phase"], "ci")
        self.ok("merged", "T-1", "--sha", "aaa111")

    def test_later_failed_for_same_sha_wins(self):
        self.to_ci("T-1")
        self.ok("ci", "T-1", "--sha", "s1", "--passed")
        self.ok("ci", "T-1", "--sha", "s1", "--failed")
        self.refused(3, "merged", "T-1", "--sha", "s1")
        self.assertEqual(self.show("T-1")["phase"], "ci")

    def test_merged_unknown_ticket(self):
        self.refused(4, "merged", "NOPE", "--sha", "s1")


class SessionTests(OrchTestCase):
    def setUp(self):
        super().setUp()
        self.init()

    def test_spawn_requires_ready(self):
        self.add("T-1")
        self.spawn("T-1")
        self.refused(3, "spawn", "T-1", "--worktree", self.worktree,
                     "--brief-file", self.brief)
        self.refused(4, "spawn", "NOPE", "--worktree", self.worktree,
                     "--brief-file", self.brief)

    def test_spawn_invokes_claude_with_defaults(self):
        self.add("T-1")
        t = self.spawn("T-1", sleep=30)
        call = self.wait_calls(1)[0]
        argv = call["argv"]
        self.assertEqual(argv[0], "-p")
        # The brief goes to claude on stdin, never on the command line.
        for a in argv:
            self.assertNotIn("Brief body", a)
        # The skill is user-invoked only, so the brief starts with its command.
        self.assertEqual(call["stdin"], "/orchestration:orchestration Implement ticket. Brief body.")
        i = argv.index("--session-id")
        sid = argv[i + 1]
        uuid.UUID(sid)
        self.assertEqual(t["session_id"], sid)
        i = argv.index("--output-format")
        self.assertEqual(argv[i + 1], "stream-json")
        self.assertIn("--verbose", argv)
        self.assertIn("--dangerously-skip-permissions", argv)
        self.assertNotIn("--permission-mode", argv)
        self.assertEqual(os.path.realpath(call["cwd"]), os.path.realpath(self.worktree))
        self.assertEqual(t["phase"], "dispatched")
        self.assertEqual(t["pid"], call["pid"])
        self.assertTrue(t["alive"])
        self.assertEqual(t["attempt"], 1)
        self.assertEqual(os.path.realpath(t["worktree"]), os.path.realpath(self.worktree))
        log = os.path.join(self.state_dir, "logs", "T-1.log")
        self.assertTrue(wait_until(lambda: os.path.exists(log)
                                   and "FAKE-CLAUDE-OUTPUT" in read_file(log)))
        self.assertEqual(
            self.db_exec("SELECT brief FROM tickets WHERE id='T-1'"),
            [("Implement ticket. Brief body.",)])

    def test_spawn_uses_config_claude_args(self):
        self.write_config({"claude_args": ["--model", "opus", "--permission-mode", "plan"]})
        self.add("T-1")
        self.spawn("T-1", sleep=0)
        argv = self.wait_calls(1)[0]["argv"]
        self.assertEqual(argv[-4:], ["--model", "opus", "--permission-mode", "plan"])
        self.assertNotIn("--dangerously-skip-permissions", argv)

    def test_resume(self):
        self.add("T-1")
        t1 = self.spawn("T-1", sleep=30)
        self.wait_calls(1)
        self.refused(3, "resume", "T-1")  # still alive
        self.ok("phase", "T-1", "spec")
        os.killpg(t1["pid"], signal.SIGKILL)
        self.wait_dead("T-1")
        self.ok("resume", "T-1", env={"ORCH_CLAUDE_BIN": self.fake_claude(30)})
        call = self.wait_calls(2)[1]
        argv = call["argv"]
        self.assertIn("-p", argv)
        i = argv.index("--resume")
        self.assertEqual(argv[i + 1], t1["session_id"])
        self.assertEqual(os.path.realpath(call["cwd"]), os.path.realpath(self.worktree))
        t2 = self.show("T-1")
        self.assertEqual(t2["attempt"], 2)
        self.assertEqual(t2["phase"], "spec")
        self.assertEqual(t2["session_id"], t1["session_id"])
        self.assertEqual(t2["pid"], call["pid"])
        self.assertNotEqual(t2["pid"], t1["pid"])
        self.assertTrue(t2["alive"])

    def test_resume_prompt_mentions_show_and_note(self):
        self.dispatched("T-7")
        self.ok("resume", "T-7")
        call = self.wait_calls(2)[1]
        self.assertIn("-p", call["argv"])
        self.assertIn("--resume", call["argv"])
        prompt = call["stdin"]
        self.assertIn("orch show T-7", prompt)
        for a in call["argv"]:
            self.assertNotIn("orch show", a)
        self.wait_dead("T-7")
        note = "Reviewer flagged the null check " + uuid.uuid4().hex
        self.ok("resume", "T-7", "--note", note)
        call = self.wait_calls(3)[2]
        prompt = call["stdin"]
        for a in call["argv"]:
            self.assertNotIn(note, a)
        self.assertIn("orch show T-7", prompt)
        self.assertIn(note, prompt)
        self.assertGreater(prompt.index(note), prompt.index("orch show T-7"))
        self.assertEqual(self.show("T-7")["attempt"], 3)

    def test_resume_refused_for_ready_done_retired(self):
        self.add("T-ready")
        self.refused(3, "resume", "T-ready")
        self.to_done("T-done")
        self.refused(3, "resume", "T-done")
        self.dispatched("T-ret")
        self.ok("retire", "T-ret", "--force")
        self.refused(3, "resume", "T-ret")
        self.refused(4, "resume", "NOPE")

    def test_stale(self):
        self.add("T-alive")
        self.spawn("T-alive", sleep=30, worktree=self.new_worktree("alive"))
        self.dispatched("T-dead")
        self.ok("phase", "T-dead", "spec")
        self.add("T-ready")
        self.to_done("T-done", worktree=self.new_worktree("done"))
        self.dispatched("T-ret", worktree=self.new_worktree("ret"))
        self.ok("retire", "T-ret", "--force")
        ids = [ticket_id(t) for t in self.tickets("stale")]
        self.assertEqual(ids, ["T-dead"])

    def test_next_default_max_workers(self):
        for i in range(1, 6):
            self.add("T-%d" % i)
        ids = [ticket_id(t) for t in self.tickets("next")]
        self.assertEqual(ids, ["T-1", "T-2", "T-3"])

    def test_next_respects_active_and_order(self):
        self.write_config({"max_workers": 2})
        for name in ("T-c", "T-a", "T-d", "T-b"):  # insertion order, not alpha
            self.add(name)
        self.assertEqual([ticket_id(t) for t in self.tickets("next")], ["T-c", "T-a"])
        self.spawn("T-c", worktree=self.new_worktree("c"))
        self.assertEqual([ticket_id(t) for t in self.tickets("next")], ["T-a"])
        self.spawn("T-a", worktree=self.new_worktree("a"))
        self.assertEqual(self.tickets("next"), [])
        # blocked tickets are not active
        self.ok("block", "T-a", "--reason", "x")
        self.assertEqual([ticket_id(t) for t in self.tickets("next")], ["T-d"])

    def test_retire_requires_done(self):
        self.dispatched("T-1")
        self.refused(3, "retire", "T-1")
        self.assertFalse(is_retired(self.show("T-1")))

    def test_retire_force_kills_session(self):
        self.add("T-1")
        t = self.spawn("T-1", sleep=30)
        self.wait_calls(1)
        self.assertTrue(pid_alive(t["pid"]))
        self.ok("retire", "T-1", "--force")
        self.assertTrue(wait_until(lambda: not pid_alive(t["pid"])),
                        "retire did not kill the session")
        after = self.show("T-1")
        self.assertTrue(is_retired(after))
        self.assertFalse(after["alive"])
        retired_ids = [ticket_id(x) for x in self.tickets("list") if is_retired(x)]
        self.assertEqual(retired_ids, ["T-1"])

    def test_state_survives_killed_session(self):
        self.add("T-1")
        t = self.spawn("T-1", sleep=30)
        self.wait_calls(1)
        self.phases("T-1", "spec", "tests")
        os.killpg(t["pid"], signal.SIGKILL)
        self.wait_dead("T-1")
        after = self.show("T-1")
        self.assertEqual(after["phase"], "tests")
        self.assertEqual(after["pid"], t["pid"])
        self.assertEqual(after["session_id"], t["session_id"])
        self.assertEqual([ticket_id(x) for x in self.tickets("stale")], ["T-1"])


class HardeningTests(OrchTestCase):
    def setUp(self):
        super().setUp()
        self.init()

    # -- process identity ----------------------------------------------------

    def test_foreign_pid_is_not_alive_and_survives_retire(self):
        self.dispatched("T-1")
        self.ok("phase", "T-1", "spec")
        other = self.foreign_process()
        self.db_exec("UPDATE tickets SET pid=? WHERE id='T-1'", (other.pid,))
        self.assertEqual([ticket_id(t) for t in self.tickets("stale")], ["T-1"])
        self.assertFalse(self.show("T-1")["alive"])
        self.ok("retire", "T-1", "--force")
        time.sleep(0.5)
        self.assertIsNone(other.poll(), "retire killed an unrelated process")

    def test_resume_allowed_when_pid_is_reused(self):
        self.dispatched("T-1")
        other = self.foreign_process()
        self.db_exec("UPDATE tickets SET pid=? WHERE id='T-1'", (other.pid,))
        self.ok("resume", "T-1")
        self.assertEqual(self.show("T-1")["attempt"], 2)
        self.assertIsNone(other.poll())

    def test_dispatched_without_pid_is_stale(self):
        self.dispatched("T-1")
        self.db_exec("UPDATE tickets SET pid=NULL WHERE id='T-1'")
        self.assertEqual([ticket_id(t) for t in self.tickets("stale")], ["T-1"])
        self.assertFalse(self.show("T-1")["alive"])

    # -- resume of a blocked ticket -----------------------------------------

    def test_resume_blocked_restores_prior_phase(self):
        self.write_config({"max_workers": 1})
        self.dispatched("T-1")
        self.add("T-2")
        self.phases("T-1", "spec", "tests")
        self.ok("block", "T-1", "--reason", "question for user")
        self.assertEqual([ticket_id(t) for t in self.tickets("next")], ["T-2"])
        self.ok("resume", "T-1", "--note", "the answer")
        t = self.show("T-1")
        self.assertEqual(t["phase"], "tests")
        self.assertIsNone(t["prior_phase"])
        evs = self.events("T-1")
        self.assertEqual([e["kind"] for e in evs[-2:]], ["unblock", "resume"])
        self.assertEqual((ev_from(evs[-2]), ev_to(evs[-2])), ("blocked", "tests"))
        self.assertEqual(self.tickets("next"), [])

    # -- launch failures ------------------------------------------------------

    def test_spawn_missing_binary(self):
        self.add("T-1")
        p = self.refused(3, "spawn", "T-1", "--worktree", self.worktree,
                         "--brief-file", self.brief,
                         env={"ORCH_CLAUDE_BIN": os.path.join(self.tmp, "no-such-bin")})
        self.assertIn("cannot start", p.stderr)
        self.assertNotIn("Traceback", p.stderr)
        t = self.show("T-1")
        self.assertEqual(t["phase"], "ready")
        self.assertIsNone(t["session_id"])
        self.assertEqual([e["kind"] for e in self.events("T-1")], ["add"])
        self.spawn("T-1")  # still spawnable afterwards

    def test_resume_with_worktree_gone(self):
        self.dispatched("T-1")
        before = self.events("T-1")
        shutil.rmtree(self.worktree)
        p = self.refused(3, "resume", "T-1")
        self.assertIn("cannot start", p.stderr)
        self.assertNotIn("Traceback", p.stderr)
        t = self.show("T-1")
        self.assertEqual(t["attempt"], 1)
        self.assertEqual(t["phase"], "dispatched")
        self.assertEqual(self.events("T-1"), before)

    def test_resume_blocked_launch_failure_stays_blocked(self):
        self.dispatched("T-1")
        self.ok("phase", "T-1", "spec")
        self.ok("block", "T-1", "--reason", "q")
        shutil.rmtree(self.worktree)
        self.refused(3, "resume", "T-1")
        t = self.show("T-1")
        self.assertEqual((t["phase"], t["prior_phase"], t["attempt"]),
                         ("blocked", "spec", 1))

    # -- config ---------------------------------------------------------------

    def test_invalid_config_is_a_refusal(self):
        os.makedirs(self.state_dir, exist_ok=True)
        with open(os.path.join(self.state_dir, "config.json"), "w") as f:
            f.write("{not json")
        p = self.refused(3, "next")
        self.assertIn("config.json", p.stderr)
        self.assertNotIn("Traceback", p.stderr)

    # -- briefs ---------------------------------------------------------------

    def test_brief_column_added_to_old_database(self):
        os.remove(self.db_path())
        con = sqlite3.connect(self.db_path())
        con.executescript(
            "CREATE TABLE tickets (seq INTEGER PRIMARY KEY AUTOINCREMENT,"
            " id TEXT NOT NULL UNIQUE, title TEXT, url TEXT, phase TEXT NOT NULL,"
            " prior_phase TEXT, review_rounds INTEGER NOT NULL DEFAULT 0, pid INTEGER,"
            " session_id TEXT, worktree TEXT, attempt INTEGER NOT NULL DEFAULT 0,"
            " created_at TEXT NOT NULL, retired_at TEXT);"
            "INSERT INTO tickets (id, title, phase, created_at)"
            " VALUES ('OLD-1', 'old', 'ready', '2026-01-01');")
        con.close()
        self.assertEqual([ticket_id(t) for t in self.tickets("list")], ["OLD-1"])
        self.spawn("OLD-1")
        self.assertEqual(self.db_exec("SELECT brief FROM tickets WHERE id='OLD-1'"),
                         [("Implement ticket. Brief body.",)])

    def test_resume_without_created_session_starts_fresh(self):
        self.add("T-1")
        t = self.spawn("T-1", sleep=0, init=False)
        self.wait_dead("T-1")
        self.ok("resume", "T-1", "--note", "extra context")
        call = self.wait_calls(2)[1]
        argv = call["argv"]
        self.assertNotIn("--resume", argv)
        self.assertEqual(argv[argv.index("--session-id") + 1], t["session_id"])
        self.assertTrue(call["stdin"].startswith("/orchestration:orchestration Implement ticket. Brief body."))
        self.assertIn("extra context", call["stdin"])
        self.assertEqual(self.show("T-1")["attempt"], 2)

    def test_resume_with_created_session_resumes(self):
        self.add("T-1")
        t = self.spawn("T-1", sleep=0, init=True)
        self.wait_dead("T-1")
        self.ok("resume", "T-1")
        argv = self.wait_calls(2)[1]["argv"]
        self.assertNotIn("--session-id", argv)
        self.assertEqual(argv[argv.index("--resume") + 1], t["session_id"])

    # -- worktree uniqueness --------------------------------------------------

    def test_spawn_refuses_worktree_in_use(self):
        self.add("T-1")
        self.add("T-2")
        self.spawn("T-1")
        p = self.refused(3, "spawn", "T-2", "--worktree",
                         os.path.join(self.worktree, "."), "--brief-file", self.brief)
        self.assertIn("T-1", p.stderr)
        self.assertEqual(self.show("T-2")["phase"], "ready")
        self.ok("retire", "T-1", "--force")
        self.spawn("T-2")

    def test_spawn_refuses_main_checkout(self):
        self.add("T-1")
        # The main checkout itself, and a directory containing it.
        for wt in (self.repo, os.path.join(self.repo, "."), self.tmp):
            p = self.refused(3, "spawn", "T-1", "--worktree", wt,
                             "--brief-file", self.brief)
            self.assertIn("main checkout", p.stderr)
            self.assertNotIn("Traceback", p.stderr)
        self.assertEqual(self.show("T-1")["phase"], "ready")
        self.assertEqual([e["kind"] for e in self.events("T-1")], ["add"])
        time.sleep(0.3)
        self.assertEqual(self.calls(), [])

    def test_spawn_refuses_nested_worktrees(self):
        outer = os.path.join(self.tmp, "nest")
        inner = os.path.join(outer, "inner")
        os.makedirs(os.path.join(inner, "sub"))
        for t in ("T-1", "T-2", "T-3"):
            self.add(t)
        self.spawn("T-1", worktree=inner)
        for t, wt in (("T-2", os.path.join(inner, "sub")), ("T-3", outer)):
            p = self.refused(3, "spawn", t, "--worktree", wt, "--brief-file", self.brief)
            self.assertIn("T-1", p.stderr)
            self.assertEqual(self.show(t)["phase"], "ready")
        # A sibling whose name merely shares a prefix is not nested.
        sibling = inner + "-2"
        os.makedirs(sibling)
        self.spawn("T-2", worktree=sibling)
        self.ok("retire", "T-1", "--force")
        self.spawn("T-3", worktree=outer + os.sep + "inner" + os.sep + "sub")

    # -- read-only commands ---------------------------------------------------

    def test_reads_do_not_wait_for_writers(self):
        self.add("T-1")
        con = sqlite3.connect(self.db_path(), timeout=1, isolation_level=None)
        con.execute("BEGIN IMMEDIATE")
        try:
            for cmd in (("show", "T-1"), ("list",), ("next",), ("stale",),
                        ("events", "T-1")):
                p = self.orch(*cmd, timeout=10)
                self.assertEqual(p.returncode, 0, p.stderr)
        finally:
            con.execute("ROLLBACK")
            con.close()


if __name__ == "__main__":
    unittest.main()
