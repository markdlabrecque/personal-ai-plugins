"""Black-box tests for the machine config, platform adapters, bundled worktree
engines, `orch watch` and `orch selftest`.

Contract: skills/orchestration/references/platforms.md (extends orch-cli.md).

Interpretations the tests rely on (the spec leaves these open):
- `ORCH_CREATE_ENGINE` / `ORCH_RETIRE_ENGINE` override the path of the bundled
  `create-worktree` / `retire-worktree` engine scripts. Tests use fake engines
  that create/remove a real `git worktree` and record argv, cwd and env.
- Engines run with cwd = the main checkout (the real engines resolve the
  project root from it). `BASE_BRANCH` from `.orch` is passed in their
  environment, and `WORKTREE_ROOT` from
  orch's environment reaches them, so an engine-made worktree lives at
  `$WORKTREE_ROOT/<ticket>`.
- `retire-worktree.sh` is called with the worktree's directory name (= the
  ticket id for orch-made worktrees) and `--force` when retiring with --force.
- The fake `orca worktree create --json` replies
  `{"result": {"worktree": {"id": "repo1::<path>", "path": <path>}}}`.
- The fake `herdr worktree open` replies like `workspace create` does:
  `{"result": {"workspace": {"workspace_id": "w1"}, "root_pane": {"pane_id": "w1:p1"}}}`.
- `orch platform --json` / `orch preflight --json` with no ORCH_PLATFORM and
  no host signal report `"platform": "headless"`.
- `orch selftest --json` prints one JSON object. On desktop, the turn answers'
  shape is not specified; the tests answer generously
  (`ok`, `session_id`, `ref`, `worktree`, `session`).

Run from the plugin dir:  python3 -m unittest discover -s tests -v
"""

import importlib.machinery
import importlib.util
import json
import os
import re
import subprocess
import sys
import time
import unittest
import unittest.mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from test_orch import ORCH, pid_alive, read_file, wait_until  # noqa: E402
from test_orch_platforms import PLUGIN, PlatformTestCase  # noqa: E402

CREATE_ENGINE = os.path.join(PLUGIN, "skills", "create-worktree", "scripts",
                             "setup-worktree.sh")
RETIRE_ENGINE = os.path.join(PLUGIN, "skills", "retire-worktree", "scripts",
                             "retire-worktree.sh")
SELFTEST_STEPS = ["preflight", "create", "launch", "report-in", "state", "visible",
                  "kill", "resume", "teardown", "clean"]
BRIEF = "Implement ticket. Brief body."

ENGINE_SRC = r'''
import json, os, signal, subprocess, sys
KIND, LOG, RC, MSG, INTERRUPT = %(kind)r, %(log)r, %(rc)r, %(msg)r, %(interrupt)r
a = sys.argv[1:]
env = {k: os.environ.get(k) for k in
       ("BASE_BRANCH", "WORKTREE_ROOT", "WORKTREE_ENGINE", "RETIRE_ENGINE")}
with open(LOG, "a") as f:
    f.write(json.dumps({"who": KIND, "argv": a, "cwd": os.getcwd(), "env": env}) + "\n")
if INTERRUPT:
    os.kill(os.getppid(), signal.SIGINT)
if RC:
    sys.stderr.write(MSG + "\n")
    sys.exit(RC)
def git(*args):
    return subprocess.run(["git"] + list(args), capture_output=True, text=True)
if KIND == "create":
    if a[:1] == ["--provision"]:
        print("setup-worktree: provisioned " + os.getcwd())
        sys.exit(0)
    tid = a[0]
    base = os.environ.get("BASE_BRANCH")
    if not base:
        sys.stderr.write("setup-worktree: BASE_BRANCH is not set\n")
        sys.exit(1)
    main = git("rev-parse", "--show-toplevel").stdout.strip()
    root = os.environ["WORKTREE_ROOT"]
    path = os.path.join(root, tid)
    os.makedirs(root, exist_ok=True)
    p = git("-C", main, "worktree", "add", "-q", "-b", tid, path, base)
    if p.returncode:
        sys.stderr.write(p.stderr)
        sys.exit(1)
    print("setup-worktree: %%s ready at %%s." %% (tid, path))
else:
    tid = [x for x in a if not x.startswith("-")][0]
    main = git("rev-parse", "--show-toplevel").stdout.strip()
    out = git("-C", main, "worktree", "list", "--porcelain").stdout
    paths = [l[len("worktree "):] for l in out.splitlines() if l.startswith("worktree ")]
    match = [p for p in paths[1:] if os.path.basename(p) == tid]
    if not match:
        sys.stderr.write("retire-worktree: no worktree named %%s\n" %% tid)
        sys.exit(1)
    git("-C", main, "worktree", "remove", "--force", match[0])
    git("-C", main, "branch", "-D", tid)
    print("retire-worktree: done.")
'''

SHIM_SRC = r'''
import json, os, sys
LOG, KIND, VAR = %(log)r, %(kind)r, %(var)r
with open(LOG, "a") as f:
    f.write(json.dumps({"who": KIND, "argv": sys.argv[1:], "cwd": os.getcwd(),
                        "env": {VAR: os.environ.get(VAR)}}) + "\n")
engine = os.environ[VAR]
os.execv(engine, [engine] + sys.argv[1:])
'''

# What a launched "session" does in the fake orca/herdr, per OPTS (see use_orca2).
SESSION_HELPERS = r'''
def sid_in(words):
    for flag in ("--session-id", "--resume"):
        if flag in words:
            return words[words.index(flag) + 1]
    return None
def probe_trust(wt):
    """Log whether claude's config trusts `wt` at the moment the session starts."""
    try:
        with open(OPTS["claude_json"]) as f:
            entry = (json.load(f).get("projects") or {}).get(wt) or {}
        trusted = entry.get("hasTrustDialogAccepted") is True
    except (OSError, ValueError):
        trusted = None
    with open(LOG, "a") as f:
        f.write(json.dumps({"who": "trust-probe", "argv": [], "wt": wt,
                            "trusted": trusted}) + "\n")
def session_side_effects(wt, sid):
    probe_trust(wt)
    if OPTS.get("hook_pid") and sid:
        env = dict(os.environ, ORCH_HOOK_CLAUDE_PID=str(OPTS["hook_pid"]))
        subprocess.run([OPTS["orch"], "hook"], cwd=wt, env=env, capture_output=True,
                       input=json.dumps({"session_id": sid, "cwd": wt,
                                         "hook_event_name": "SessionStart",
                                         "source": "startup"}), text=True)
    if OPTS.get("leak") and sid:
        p = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)",
                              "--session-id", sid], start_new_session=True,
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL)
        with open(OPTS["leak"], "a") as f:
            f.write(str(p.pid) + "\n")
def maybe_block(cmd):
    if OPTS.get("block") and cmd in OPTS.get("block_cmds",
                                             ("terminal create", "agent start")):
        open(OPTS["block"] + ".started", "w").close()
        deadline = time.time() + 30
        while not os.path.exists(OPTS["block"]) and time.time() < deadline:
            time.sleep(0.05)
'''

ORCA_SRC = r'''
import json, os, shlex, signal, subprocess, sys, time
LOG, REPO, ROOT, FAIL, TRUST = %(log)r, %(repo)r, %(root)r, %(fail)r, %(trust)r
OPTS = %(opts)r
a = sys.argv[1:]
with open(LOG, "a") as f:
    f.write(json.dumps({"who": "orca", "argv": a, "cwd": os.getcwd()}) + "\n")
cmd = " ".join(a[:2])
if cmd in FAIL:
    sys.stderr.write("fake orca failed\n")
    sys.exit(1)
def opt(n):
    return a[a.index(n) + 1] if n in a else None
def git(*args):
    return subprocess.run(["git", "-C", REPO] + list(args), capture_output=True, text=True)
''' + SESSION_HELPERS.replace("%", "%%") + r'''
maybe_block(cmd)
if cmd in OPTS.get("interrupt", ()):
    os.kill(os.getppid(), signal.SIGINT)
    time.sleep(5)
registered = os.path.join(os.path.dirname(LOG), "orca-registered")
if cmd == "repo add":
    open(registered, "w").close()
if cmd == "worktree create" and OPTS.get("unregistered") and not os.path.exists(registered):
    print(json.dumps({"ok": False, "error": {"code": "repo_not_found",
                                             "message": "repo_not_found"}}))
    sys.exit(1)
if cmd == "worktree create":
    name = opt("--name")
    path = os.path.join(ROOT, name)
    os.makedirs(ROOT, exist_ok=True)
    p = git("worktree", "add", "-q", "-b", name, path, opt("--base-branch") or "HEAD")
    if p.returncode:
        sys.stderr.write(p.stderr)
        sys.exit(1)
    wt = {"path": path} if OPTS.get("no_id") else {"id": "repo1::" + path, "path": path}
    print(json.dumps({"result": {"worktree": wt}}))
elif cmd == "worktree rm":
    sel = opt("--worktree") or ""
    path = sel.split("::", 1)[1] if "::" in sel else sel.split(":", 1)[-1]
    if os.path.isdir(path):
        git("worktree", "remove", "--force", path)
        git("branch", "-D", os.path.basename(path))
    if OPTS.get("retrust"):
        # A claude process rewriting its config from stale memory.
        with open(OPTS["claude_json"]) as f:
            data = json.load(f)
        data.setdefault("projects", {})[path] = {"hasTrustDialogAccepted": True}
        with open(OPTS["claude_json"], "w") as f:
            json.dump(data, f)
    print(json.dumps({"result": {"removed": True}}))
elif cmd == "terminal create":
    wt = (opt("--worktree") or "")[len("path:"):]
    session_side_effects(wt, sid_in(shlex.split(opt("--command") or "")))
    if OPTS.get("no_handle"):
        print(json.dumps({"result": {"terminal": {}}}))
    else:
        print(json.dumps({"result": {"terminal": {"handle": "term_abc"}}}))
elif cmd == "terminal wait" and TRUST:
    print(json.dumps({"result": {"terminal": {"handle": opt("--terminal")},
                                 "blockedReason": "agent-trust-workspace"}}))
else:
    print(json.dumps({"result": {}}))
'''

HERDR_SRC = r'''
import json, os, signal, subprocess, sys, time
LOG, FAIL, TRUST = %(log)r, %(fail)r, %(trust)r
OPTS = %(opts)r
a = sys.argv[1:]
with open(LOG, "a") as f:
    f.write(json.dumps({"who": "herdr", "argv": a, "cwd": os.getcwd()}) + "\n")
cmd = " ".join(a[:2])
if cmd in FAIL:
    sys.stderr.write("fake herdr failed\n")
    sys.exit(1)
''' + SESSION_HELPERS.replace("%", "%%") + r'''
maybe_block(cmd)
if cmd in OPTS.get("interrupt", ()):
    os.kill(os.getppid(), signal.SIGINT)
    time.sleep(5)
opened = os.path.join(os.path.dirname(LOG), "herdr-open-path")
# The main checkout's workspace ("w0"): open while this file exists.
main_ws = os.path.join(os.path.dirname(LOG), "herdr-main-open")
if cmd == "worktree open":
    with open(opened, "w") as f:
        f.write(a[a.index("--path") + 1])
    if OPTS.get("main_opens"):
        open(main_ws, "w").close()
# The main checkout's workspace id; main_reid: closing w1 reopens it as w9
# (the user closed and reopened it while selftest ran).
main_id_f = os.path.join(os.path.dirname(LOG), "herdr-main-id")
if cmd == "workspace close" and a[2:3] == ["w1"] and OPTS.get("main_reid"):
    with open(main_id_f, "w") as f:
        f.write("w9")
main_id = open(main_id_f).read() if os.path.exists(main_id_f) else "w0"
if cmd == "workspace close" and a[2:3] == [main_id] and os.path.exists(main_ws) \
        and not OPTS.get("main_sticky"):
    os.remove(main_ws)
if cmd == "workspace list":
    if OPTS.get("list_error"):
        print(json.dumps({"error": {"code": "server_unavailable", "message": "no server"}}))
        sys.exit(0)
    wss = []
    if os.path.exists(main_ws):
        wss.append({"workspace_id": main_id, "label": "main",
                    "worktree": {"checkout_path": OPTS["main"]}})
    if os.path.exists(opened):
        with open(opened) as f:
            wss.append({"workspace_id": "w1", "worktree": {"checkout_path": f.read()}})
    print(json.dumps({"result": {"workspaces": wss}}))
    sys.exit(0)
live = os.path.join(os.path.dirname(LOG), "herdr-agent-live")
if cmd == "agent start":
    open(live, "w").close()
    with open(opened) as f:
        session_side_effects(f.read(), sid_in(a[a.index("--") + 1:]))
if cmd in ("workspace close", "pane close") and os.path.exists(live):
    os.remove(live)
if cmd == "agent get" and not os.path.exists(live):
    print(json.dumps({"error": {"code": "agent_not_found", "message": "no agent"}}))
    sys.exit(0)
if cmd == "agent start" and TRUST:
    # herdr exits 0 on errors; "blocked" alone does not say which dialog
    print(json.dumps({"error": {"code": "agent_not_ready", "message":
                                "agent tt1 is blocked during startup"}}))
    sys.exit(0)
if cmd == "agent read":
    print("Do you trust the files in this folder?" if TRUST else "> ready")
elif cmd in ("worktree open", "workspace create"):
    print(json.dumps({"result": {"workspace": {"workspace_id": "w1"},
                                 "tab": {"tab_id": "w1:t1"},
                                 "root_pane": {"pane_id": "w1:p1"}}}))
else:
    print(json.dumps({"result": {}}))
'''

# A fake claude that behaves like a real ticket session: SessionStart hook with
# its own pid, `orch phase <ticket> spec` on a fresh start, then it waits.
SESSION_CLAUDE_SRC = r'''
import json, os, re, subprocess, sys, time
RECORD, ORCH, REPORT = %(record)r, %(orch)r, %(report)r
a = sys.argv[1:]
data = sys.stdin.read()
with open(RECORD, "a") as f:
    f.write(json.dumps({"argv": a, "cwd": os.getcwd(), "pid": os.getpid(),
                        "stdin": data}) + "\n")
resume = "--resume" in a
sid = a[a.index("--resume" if resume else "--session-id") + 1]
if REPORT:
    env = dict(os.environ, ORCH_HOOK_CLAUDE_PID=str(os.getpid()))
    payload = {"session_id": sid, "cwd": os.getcwd(), "hook_event_name": "SessionStart",
               "source": "resume" if resume else "startup"}
    h = subprocess.run([ORCH, "hook"], input=json.dumps(payload), env=env,
                       capture_output=True, text=True)
    if not resume:
        m = (re.search(r"orch phase ([A-Za-z0-9._-]+) spec", data)
             or re.search(r"orchestrator for ([A-Za-z0-9._-]+?)\. ", h.stdout))
        if m:
            subprocess.run([ORCH, "phase", m.group(1), "spec"], env=os.environ,
                           capture_output=True)
time.sleep(120)
'''


def load_orch_module():
    loader = importlib.machinery.SourceFileLoader("orch_under_test", ORCH)
    spec = importlib.util.spec_from_loader("orch_under_test", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


class AdapterTestCase(PlatformTestCase):
    """PlatformTestCase plus: an isolated machine config dir, BASE_BRANCH in
    .orch, a WORKTREE_ROOT under tmp, fake engines, and
    ORCH_PLATFORM=headless unless a test changes it."""

    def setUp(self):
        super().setUp()
        self.xdg = os.path.join(self.tmp, "xdg")
        os.makedirs(self.xdg)
        self.env["XDG_CONFIG_HOME"] = self.xdg
        self.env["ORCH_PLATFORM"] = "headless"
        self.wts = os.path.join(self.tmp, "wts")
        self.env["WORKTREE_ROOT"] = self.wts
        self.write_orch("BASE_BRANCH=main\n")
        self.order = os.path.join(self.tmp, "order.jsonl")
        self.env["ORCH_CREATE_ENGINE"] = self.fake_engine("create")
        self.env["ORCH_RETIRE_ENGINE"] = self.fake_engine("retire")
        self.brief_text = BRIEF

    # ---- fakes -----------------------------------------------------------

    def _script(self, name, src):
        self._fake_count += 1
        path = os.path.join(self.tmp, "%s-%d" % (name, self._fake_count))
        with open(path, "w") as f:
            f.write("#!%s\n%s" % (sys.executable, src))
        os.chmod(path, 0o755)
        return path

    def fake_engine(self, kind, rc=0, msg="engine failed", interrupt=False):
        """`interrupt`: SIGINT the caller (orch) first, then carry on."""
        return self._script("fake-%s-engine" % kind, ENGINE_SRC % {
            "kind": kind, "log": self.order, "rc": rc, "msg": msg,
            "interrupt": interrupt})

    def use_orca2(self, fail=(), trust=False, **opts):
        """Fake orca. `opts`: hook_pid (on `terminal create`, fire SessionStart
        as that pid), leak (file: start a process carrying the session id and
        record its pid there), block (file: wait until it exists), interrupt
        (commands that SIGINT the caller), block_cmds (the commands `block`
        holds; default the launch command), no_handle, unregistered, no_id,
        retrust (re-add the trust entry on `worktree rm`)."""
        opts.setdefault("orch", ORCH)
        opts.setdefault("claude_json", self.env["ORCH_CLAUDE_JSON"])
        self.env["ORCH_ORCA_BIN"] = self._script("fake-orca", ORCA_SRC % {
            "log": self.order, "repo": self.repo,
            "root": os.path.join(self.tmp, "orca-wts"), "fail": list(fail),
            "trust": trust, "opts": opts})

    def use_herdr2(self, fail=(), trust=False, main_open=False, **opts):
        """Fake herdr; `opts` as for use_orca2, fired on `agent start`, plus
        main_opens (`worktree open` also opens the main checkout's workspace
        w0, as live herdr does) and list_error (`workspace list` replies with
        an error), main_sticky (closing w0 leaves it open). `main_open`: w0 is open from the start."""
        opts.setdefault("orch", ORCH)
        opts.setdefault("main", os.path.realpath(self.repo))
        if main_open:
            open(os.path.join(os.path.dirname(self.order), "herdr-main-open"), "w").close()
        opts.setdefault("claude_json", self.env["ORCH_CLAUDE_JSON"])
        self.env["ORCH_HERDR_BIN"] = self._script("fake-herdr", HERDR_SRC % {
            "log": self.order, "fail": list(fail), "trust": trust, "opts": opts})

    def session_claude(self, report=True):
        return self._script("fake-session-claude", SESSION_CLAUDE_SRC % {
            "record": self.record, "orch": ORCH, "report": bool(report)})

    def log(self, who=None):
        if not os.path.exists(self.order):
            return []
        with open(self.order) as f:
            rows = [json.loads(line) for line in f if line.strip()]
        return [r for r in rows if who is None or r["who"] == who]

    def index_of(self, pred):
        for i, r in enumerate(self.log()):
            if pred(r):
                return i
        self.fail("no matching call in %r" % self.log())

    # ---- repo state --------------------------------------------------------

    def git_out(self, *args):
        return subprocess.run(["git", "-C", self.repo] + list(args), env=self.env,
                              capture_output=True, text=True).stdout

    def worktree_paths(self):
        out = self.git_out("worktree", "list", "--porcelain")
        return [os.path.realpath(l[len("worktree "):]) for l in out.splitlines()
                if l.startswith("worktree ")]

    def branches(self, pattern="*"):
        return self.git_out("branch", "--list", pattern,
                            "--format=%(refname:short)").split()

    def wt_path(self, tid):
        return os.path.realpath(os.path.join(self.wts, tid))

    # ---- flows -------------------------------------------------------------

    def spawn_new(self, tid, platform=None, env=None, json_out=False):
        """add + spawn without --worktree."""
        self.add(tid)
        args = ["spawn", tid, "--brief-file", self.brief]
        if platform:
            args += ["--platform", platform]
        if json_out:
            return self.j(*args, env=env)
        return self.ok(*args, env=env)

    def done_new(self, tid):
        self.spawn_new(tid, "headless")
        self.wait_dead(tid)
        self.phases(tid, "spec", "tests", "implement", "review", "verify",
                    "report", "mr", "ci")
        self.ok("ci", tid, "--sha", "abc", "--passed")
        self.ok("merged", tid, "--sha", "abc")

    def no_platform(self):
        del self.env["ORCH_PLATFORM"]


# ---------------------------------------------------------------------------


class PlatformResolutionTests(AdapterTestCase):
    def test_environment_decides_platform(self):
        self.no_platform()
        self.assertEqual(self.j("platform")["platform"], "headless")
        self.assertEqual(self.j("platform", env={"ORCA_TERMINAL_HANDLE": "h"})["platform"],
                         "orca")
        self.assertEqual(self.j("platform", env={"ORCH_PLATFORM": "orca"})["platform"],
                         "orca")

    def test_machine_config_is_ignored(self):
        """Ticket 206: a leftover ~/.config/orchestration/config.json saying
        herdr + pi sent a plain Claude Code session's ticket into Herdr on Pi."""
        self.no_platform()
        path = os.path.join(self.xdg, "orchestration", "config.json")
        os.makedirs(os.path.dirname(path))
        with open(path, "w") as f:
            json.dump({"platform": "herdr", "harness": "pi"}, f)
        out = self.j("platform", env={"CLAUDECODE": "1"})
        self.assertEqual((out["platform"], out["harness"]), ("headless", "claude"))
        out = self.j("platform")
        self.assertEqual((out["platform"], out["harness"]), ("headless", "claude"))

    def test_setup_is_gone(self):
        self.refused(2, "setup", "--platform", "orca")

    def test_preflight_reports_platform(self):
        self.no_platform()
        os.makedirs(os.path.join(self.repo, ".ddev"))
        with open(os.path.join(self.repo, ".ddev", "config.yaml"), "w") as f:
            f.write("name: test\n")
        bindir = os.path.join(self.tmp, "pf-bin")
        os.makedirs(bindir)
        ddev = os.path.join(bindir, "ddev")
        with open(ddev, "w") as f:
            f.write("#!/bin/sh\nexit 0\n")
        os.chmod(ddev, 0o755)
        out = self.j("preflight", env={
            "PATH": bindir + os.pathsep + self.env.get("PATH", "/usr/bin:/bin")})
        self.assertEqual(out["platform"], "headless")


class SpawnCreatesWorktreeTests(AdapterTestCase):
    def assert_git_worktree(self, path, branch):
        self.assertTrue(os.path.isdir(path), path)
        self.assertIn(path, self.worktree_paths())
        self.assertIn(branch, self.branches())

    def assert_create_call(self, tid):
        creates = self.log("create")
        self.assertEqual(len(creates), 1, creates)
        c = creates[0]
        self.assertEqual(c["argv"], [tid])
        self.assertEqual(c["env"]["BASE_BRANCH"], "main")
        self.assertEqual(os.path.realpath(c["cwd"]), os.path.realpath(self.repo))

    def test_headless_spawn_creates_worktree(self):
        self.spawn_new("t1", "headless")
        self.assert_create_call("t1")
        wt = self.wt_path("t1")
        self.assert_git_worktree(wt, "t1")
        t = self.show("t1")
        self.assertEqual(t["worktree"], wt)
        self.assertEqual(t["phase"], "dispatched")
        call = self.wait_calls(1)[0]
        self.assertEqual(os.path.realpath(call["cwd"]), wt)

    def test_desktop_spawn_creates_worktree(self):
        out = self.spawn_new("t1", "desktop", json_out=True)
        self.assert_create_call("t1")
        wt = self.wt_path("t1")
        self.assert_git_worktree(wt, "t1")
        self.assertEqual(out["action"], "desktop_start")
        self.assertEqual(os.path.realpath(out["cwd"]), wt)
        self.assertEqual(self.show("t1")["worktree"], wt)

    def test_orca_spawn_creates_worktree_via_orca_then_provisions(self):
        self.use_orca2()
        self.spawn_new("t1", "orca")
        orca = self.log("orca")
        create = orca[0]["argv"]
        self.assertEqual(create[:2], ["worktree", "create"])
        self.assertEqual(create[create.index("--name") + 1], "t1")
        self.assertIn("--no-parent", create)
        self.assertEqual(create[create.index("--base-branch") + 1], "main")
        self.assertIn("--repo", create)
        self.assertNotIn("--agent", create)
        wt = os.path.realpath(os.path.join(self.tmp, "orca-wts", "t1"))
        self.assert_git_worktree(wt, "t1")
        creates = self.log("create")
        self.assertEqual(len(creates), 1, creates)
        self.assertEqual(creates[0]["argv"], ["--provision"])
        self.assertEqual(os.path.realpath(creates[0]["cwd"]), wt)
        t = self.show("t1")
        self.assertEqual(t["worktree"], wt)
        term = [r["argv"] for r in orca if r["argv"][:2] == ["terminal", "create"]]
        self.assertEqual(len(term), 1)
        self.assertEqual(term[0][term[0].index("--worktree") + 1], "path:" + wt)
        self.assertLess(self.index_of(lambda r: r["who"] == "create"),
                        self.index_of(lambda r: r["argv"][:2] == ["terminal", "create"]))

    def test_herdr_spawn_engine_then_workspace_then_agent(self):
        self.use_herdr2()
        self.spawn_new("t1", "herdr")
        self.assert_create_call("t1")
        wt = self.wt_path("t1")
        self.assert_git_worktree(wt, "t1")
        herdr = [r["argv"] for r in self.log("herdr")]
        self.assertNotIn(["pane", "run"], [h[:2] for h in herdr])
        opened = [h for h in herdr if h[:2] == ["worktree", "open"]]
        self.assertEqual(len(opened), 1, herdr)
        self.assertEqual(opened[0][opened[0].index("--path") + 1], wt)
        self.assertIn("--no-focus", opened[0])
        t = self.show("t1")
        sid = t["session_id"]
        start = [h for h in herdr if h[:2] == ["agent", "start"]]
        self.assertEqual(len(start), 1, herdr)
        start = start[0]
        self.assertEqual(start[2], "tt1")
        self.assertEqual(start[start.index("--kind") + 1], "claude")
        self.assertEqual(start[start.index("--pane") + 1], "w1:p1")
        rest = start[start.index("--") + 1:]
        self.assertEqual(rest[:2], ["--session-id", sid])
        self.assertIn("--dangerously-skip-permissions", rest)
        prompt = [h for h in herdr if h[:2] == ["agent", "prompt"]]
        self.assertEqual(len(prompt), 1, herdr)
        self.assertEqual(prompt[0][:4], ["agent", "prompt", "tt1",
                                     "/orchestration:orchestration " + BRIEF])
        i_create = self.index_of(lambda r: r["who"] == "create")
        i_open = self.index_of(lambda r: r["argv"][:2] == ["worktree", "open"])
        i_start = self.index_of(lambda r: r["argv"][:2] == ["agent", "start"])
        i_prompt = self.index_of(lambda r: r["argv"][:2] == ["agent", "prompt"])
        self.assertLess(i_create, i_open)
        self.assertLess(i_open, i_start)
        self.assertLess(i_start, i_prompt)
        self.assertEqual(t["worktree"], wt)
        self.assertEqual((t["launch_ref"] or {}).get("workspace"), "w1")

    def test_herdr_resume_uses_agent_start_resume(self):
        self.use_herdr2()
        self.spawn_new("t1", "herdr")
        sid = self.show("t1")["session_id"]
        proc = self.live_process()
        self.hook_ok("SessionStart", sid, self.wt_path("t1"), pid=proc.pid)
        proc.kill()
        proc.wait()
        self.ok("resume", "t1")
        herdr = [r["argv"] for r in self.log("herdr")]
        start = [h for h in herdr if h[:2] == ["agent", "start"]][-1]
        rest = start[start.index("--") + 1:]
        self.assertEqual(rest[:2], ["--resume", sid])
        prompt = [h for h in herdr if h[:2] == ["agent", "prompt"]][-1]
        self.assertIn("orch show t1", prompt[3])

    def test_create_failure_leaves_ticket_ready_and_nothing_behind(self):
        self.env["ORCH_CREATE_ENGINE"] = self.fake_engine("create", rc=1, msg="boom")
        self.add("t1")
        p = self.refused(3, "spawn", "t1", "--brief-file", self.brief,
                         "--platform", "headless")
        self.assertNotIn("Traceback", p.stderr)
        t = self.show("t1")
        self.assertEqual(t["phase"], "ready")
        self.assertIsNone(t["session_id"])
        self.assertIsNone(t["worktree"])
        self.assertEqual(self.event_kinds("t1"), ["add"])
        self.assertFalse(os.path.exists(self.wt_path("t1")))
        self.assertEqual(self.branches("t1"), [])
        time.sleep(0.3)
        self.assertEqual(self.calls(), [])

    def test_orca_create_failure_leaves_ticket_ready(self):
        self.use_orca2(fail=["worktree create"])
        self.add("t1")
        self.refused(3, "spawn", "t1", "--brief-file", self.brief, "--platform", "orca")
        t = self.show("t1")
        self.assertEqual(t["phase"], "ready")
        self.assertEqual(self.event_kinds("t1"), ["add"])
        self.assertNotIn(["terminal", "create"],
                         [r["argv"][:2] for r in self.log("orca")])

    def test_existing_worktree_still_accepted(self):
        wt = self.git_wt("given")
        self.add("t1")
        self.ok("spawn", "t1", "--worktree", wt, "--brief-file", self.brief)
        self.assertEqual(self.log("create"), [])
        self.assertEqual(self.show("t1")["worktree"], wt)


class EngineShimTests(AdapterTestCase):
    def shim(self, name, kind, var):
        d = os.path.join(self.repo, "scripts")
        os.makedirs(d, exist_ok=True)
        path = os.path.join(d, name)
        with open(path, "w") as f:
            f.write("#!%s\n%s" % (sys.executable, SHIM_SRC % {
                "log": self.order, "kind": kind, "var": var}))
        os.chmod(path, 0o755)
        return path

    def test_create_shim_invoked_with_worktree_engine(self):
        self.shim("setup-worktree.sh", "shim-create", "WORKTREE_ENGINE")
        self.spawn_new("t1", "headless")
        shim = self.log("shim-create")
        self.assertEqual(len(shim), 1, self.log())
        self.assertEqual(shim[0]["argv"], ["t1"])
        self.assertEqual(shim[0]["env"]["WORKTREE_ENGINE"],
                         self.env["ORCH_CREATE_ENGINE"])
        self.assertEqual(self.log("create")[0]["argv"], ["t1"])
        self.assertEqual(self.show("t1")["worktree"], self.wt_path("t1"))

    def test_create_engine_called_directly_without_shim(self):
        self.spawn_new("t1", "headless")
        self.assertEqual(self.log("shim-create"), [])
        self.assertEqual(self.log("create")[0]["argv"], ["t1"])

    def test_retire_shim_invoked_with_retire_engine(self):
        self.shim("retire-worktree.sh", "shim-retire", "RETIRE_ENGINE")
        self.spawn_new("t1", "headless")
        self.wait_dead("t1")
        self.ok("retire", "t1", "--force")
        shim = self.log("shim-retire")
        self.assertEqual(len(shim), 1, self.log())
        self.assertEqual(shim[0]["argv"][0], "t1")
        self.assertIn("--force", shim[0]["argv"])
        self.assertEqual(shim[0]["env"]["RETIRE_ENGINE"], self.env["ORCH_RETIRE_ENGINE"])
        self.assertEqual(len(self.log("retire")), 1)
        self.assertFalse(os.path.exists(self.wt_path("t1")))

    def test_retire_engine_called_directly_without_shim(self):
        self.spawn_new("t1", "headless")
        self.wait_dead("t1")
        self.ok("retire", "t1", "--force")
        self.assertEqual(self.log("shim-retire"), [])
        self.assertEqual(len(self.log("retire")), 1)


class RetireRemovesWorktreeTests(AdapterTestCase):
    def retire_calls(self):
        return [r["argv"] for r in self.log("retire")]

    def test_headless_retire_kills_then_removes(self):
        self.spawn_new("t1", "headless", env={"ORCH_CLAUDE_BIN": self.fake_claude(30)})
        call = self.wait_calls(1)[0]
        self.ok("retire", "t1", "--force")
        self.assertTrue(wait_until(lambda: not pid_alive(call["pid"])),
                        "retire left the session running")
        self.assertEqual(len(self.retire_calls()), 1)
        self.assertEqual(self.retire_calls()[0][0], "t1")
        self.assertFalse(os.path.exists(self.wt_path("t1")))
        self.assertEqual(self.branches("t1"), [])
        self.assertTrue(self.show("t1")["retired"])

    def test_retire_without_force_does_not_pass_force(self):
        self.done_new("t1")
        self.ok("retire", "t1")
        self.assertEqual(len(self.retire_calls()), 1)
        self.assertNotIn("--force", self.retire_calls()[0])
        self.assertTrue(self.show("t1")["retired"])

    def test_force_passed_to_engine(self):
        self.spawn_new("t1", "headless")
        self.wait_dead("t1")
        self.ok("retire", "t1", "--force")
        self.assertIn("--force", self.retire_calls()[0])

    def test_keep_worktree_skips_removal(self):
        self.spawn_new("t1", "headless")
        self.wait_dead("t1")
        self.ok("retire", "t1", "--force", "--keep-worktree")
        self.assertEqual(self.retire_calls(), [])
        self.assertTrue(os.path.isdir(self.wt_path("t1")))
        self.assertTrue(self.show("t1")["retired"])

    def test_engine_refusal_keeps_ticket_unretired(self):
        self.done_new("t1")
        self.env["ORCH_RETIRE_ENGINE"] = self.fake_engine(
            "retire", rc=2, msg="retire-worktree: t1 has uncommitted changes")
        p = self.refused(3, "retire", "t1")
        self.assertIn("uncommitted", p.stderr)
        self.assertNotIn("Traceback", p.stderr)
        t = self.show("t1")
        self.assertFalse(t["retired"])
        self.assertEqual(t["phase"], "done")
        self.assertTrue(os.path.isdir(self.wt_path("t1")))
        self.assertNotIn("retire", self.event_kinds("t1"))

    def test_orca_retire_close_engine_then_orca_rm(self):
        self.use_orca2()
        self.spawn_new("t1", "orca")
        wt = self.show("t1")["worktree"]
        self.ok("retire", "t1", "--force")
        i_close = self.index_of(lambda r: r["argv"][:2] == ["terminal", "close"])
        i_engine = self.index_of(lambda r: r["who"] == "retire")
        i_rm = self.index_of(lambda r: r["argv"][:2] == ["worktree", "rm"])
        self.assertLess(i_close, i_engine)
        self.assertLess(i_engine, i_rm)
        rm = self.log()[i_rm]["argv"]
        self.assertIn(wt, rm[rm.index("--worktree") + 1])
        self.assertFalse(os.path.exists(wt))
        self.assertEqual(self.branches("t1"), [])
        self.assertTrue(self.show("t1")["retired"])

    def test_orca_keep_worktree_skips_orca_rm(self):
        self.use_orca2()
        self.spawn_new("t1", "orca")
        self.ok("retire", "t1", "--force", "--keep-worktree")
        self.assertEqual(self.retire_calls(), [])
        self.assertNotIn(["worktree", "rm"], [r["argv"][:2] for r in self.log("orca")])

    def test_herdr_retire_closes_workspace_then_engine(self):
        self.use_herdr2()
        self.spawn_new("t1", "herdr")
        self.ok("retire", "t1", "--force")
        i_close = self.index_of(lambda r: r["argv"] == ["workspace", "close", "w1"])
        i_engine = self.index_of(lambda r: r["who"] == "retire")
        self.assertLess(i_close, i_engine)
        self.assertFalse(os.path.exists(self.wt_path("t1")))

    def test_desktop_retire_removes_worktree(self):
        self.spawn_new("t1", "desktop")
        p = self.ok("retire", "t1", "--force")
        self.assertIn("desktop_archive", p.stdout)
        self.assertEqual(len(self.retire_calls()), 1)
        self.assertFalse(os.path.exists(self.wt_path("t1")))
        self.assertTrue(self.show("t1")["retired"])


class RealEnginesTests(AdapterTestCase):
    """The bundled engines themselves, against a plain repo with no .ddev/.
    PATH is limited so no real ddev/herdr/orca is ever reached."""

    def setUp(self):
        super().setUp()
        del self.env["ORCH_CREATE_ENGINE"]
        del self.env["ORCH_RETIRE_ENGINE"]
        bindir = os.path.join(self.tmp, "real-bin")
        os.makedirs(bindir)
        git = subprocess.run(["sh", "-c", "command -v git"], capture_output=True,
                             text=True).stdout.strip() or "/usr/bin/git"
        os.symlink(git, os.path.join(bindir, "git"))
        os.symlink(sys.executable, os.path.join(bindir, "python3"))
        self.env["PATH"] = bindir + os.pathsep + "/usr/bin:/bin:/usr/sbin:/sbin"

    def test_bundled_engines_present(self):
        for path in (CREATE_ENGINE, RETIRE_ENGINE):
            self.assertTrue(os.path.isfile(path), "bundled engine missing: %s" % path)
            self.assertTrue(os.access(path, os.X_OK) or path.endswith(".sh"))

    def test_spawn_and_retire_with_real_engines(self):
        self.assertTrue(os.path.isfile(CREATE_ENGINE), CREATE_ENGINE)
        self.assertTrue(os.path.isfile(RETIRE_ENGINE), RETIRE_ENGINE)
        self.spawn_new("t-42", "headless")
        wt = self.wt_path("t-42")
        self.assertTrue(os.path.isdir(wt))
        self.assertIn(wt, self.worktree_paths())
        self.assertIn("t-42", self.branches())
        self.assertEqual(self.show("t-42")["worktree"], wt)
        self.wait_dead("t-42")
        self.ok("retire", "t-42", "--force")
        self.assertFalse(os.path.exists(wt))
        self.assertNotIn(wt, self.worktree_paths())
        self.assertEqual(self.branches("t-42"), [])
        self.assertTrue(self.show("t-42")["retired"])


class WatchTests(AdapterTestCase):
    def setUp(self):
        super().setUp()
        self.add("w-ready")
        self.add("w-desk")
        self.ok("spawn", "w-desk", "--worktree", self.git_wt("desk"), "--brief-file",
                self.brief, "--platform", "desktop")
        self.add("w-gone")
        self.ok("retire", "w-gone", "--force", "--keep-worktree")

    def test_watch_once_table(self):
        p = self.ok("watch", "--once", timeout=20)
        lines = p.stdout.splitlines()
        for tid in ("w-ready", "w-desk"):
            t = self.show(tid)
            row = [l for l in lines if tid in l]
            self.assertEqual(len(row), 1, p.stdout)
            for value in (t["platform"], t["phase"], t["health"]):
                self.assertIn(value, row[0])
        self.assertNotIn("w-gone", p.stdout)

    def test_watch_once_json(self):
        p = self.ok("watch", "--once", "--json", timeout=20)
        out = json.loads(p.stdout)
        ts = {t["id"]: t for t in out["tickets"]}
        self.assertEqual(set(ts), {"w-ready", "w-desk"})
        for t in ts.values():
            for key in ("platform", "phase", "health", "review_rounds"):
                self.assertIn(key, t)
        self.assertEqual(ts["w-desk"]["platform"], "desktop")
        self.assertEqual(ts["w-desk"]["phase"], "dispatched")


class SelftestTests(AdapterTestCase):
    def setUp(self):
        super().setUp()
        self.env["ORCH_CLAUDE_BIN"] = self.session_claude()

    def selftest(self, *extra, timeout=150):
        p = self.orch("selftest", "--json", *extra, timeout=timeout)
        try:
            out = json.loads(p.stdout)
        except ValueError:
            self.fail("selftest --json printed %r (stderr %r)" % (p.stdout, p.stderr))
        return p, out

    def steps(self, out):
        return {s["name"]: s for s in out["steps"]}

    def assert_nothing_left(self):
        rows = self.db_exec("SELECT id FROM tickets WHERE id LIKE 'selftest-%'")
        self.assertEqual(rows, [])
        evs = self.db_exec("SELECT ticket FROM events WHERE ticket LIKE 'selftest-%'")
        self.assertEqual(evs, [])
        for sub in ("briefs", "logs"):
            d = os.path.join(self.state_dir, sub)
            left = [f for f in (os.listdir(d) if os.path.isdir(d) else [])
                    if f.startswith("selftest-")]
            self.assertEqual(left, [], sub)
        self.assertEqual(self.worktree_paths(), [os.path.realpath(self.repo)])
        self.assertEqual(self.branches("selftest-*"), [])
        if os.path.isdir(self.wts):
            self.assertEqual([d for d in os.listdir(self.wts)
                              if d.startswith("selftest-")], [])
        for call in self.calls():
            self.assertTrue(wait_until(lambda: not pid_alive(call["pid"]), timeout=5),
                            "session process %s left running" % call["pid"])

    def test_headless_selftest_passes_and_cleans_up(self):
        p, out = self.selftest("--timeout", "30")
        self.assertEqual(p.returncode, 0, "stdout=%r stderr=%r" % (p.stdout, p.stderr))
        self.assertIs(out["ok"], True)
        self.assertEqual(out["platform"], "headless")
        self.assertTrue(out["run"])
        self.assertEqual([s["name"] for s in out["steps"]], SELFTEST_STEPS)
        for s in out["steps"]:
            self.assertEqual(s["status"], "pass", s)
        calls = self.calls()
        self.assertEqual(len(calls), 2, "expected one start and one resume")
        self.assertIn("--session-id", calls[0]["argv"])
        self.assertIn("--resume", calls[1]["argv"])
        sid = calls[0]["argv"][calls[0]["argv"].index("--session-id") + 1]
        self.assertEqual(calls[1]["argv"][calls[1]["argv"].index("--resume") + 1], sid)
        self.assertRegex(os.path.basename(calls[0]["cwd"]), r"^selftest-[0-9a-f]{8}$")
        self.assert_nothing_left()

    def test_headless_selftest_with_real_engines(self):
        del self.env["ORCH_CREATE_ENGINE"]
        del self.env["ORCH_RETIRE_ENGINE"]
        bindir = os.path.join(self.tmp, "st-bin")
        os.makedirs(bindir)
        git = subprocess.run(["sh", "-c", "command -v git"], capture_output=True,
                             text=True).stdout.strip() or "/usr/bin/git"
        os.symlink(git, os.path.join(bindir, "git"))
        os.symlink(sys.executable, os.path.join(bindir, "python3"))
        self.env["PATH"] = bindir + os.pathsep + "/usr/bin:/bin:/usr/sbin:/sbin"
        p, out = self.selftest("--timeout", "30")
        self.assertEqual(p.returncode, 0, "stdout=%r stderr=%r" % (p.stdout, p.stderr))
        self.assertIs(out["ok"], True)
        self.assert_nothing_left()

    def test_session_that_never_reports_in_fails_and_cleans_up(self):
        self.env["ORCH_CLAUDE_BIN"] = self.session_claude(report=False)
        start = time.time()
        p, out = self.selftest("--timeout", "3")
        self.assertLess(time.time() - start, 60)
        self.assertNotEqual(p.returncode, 0)
        self.assertIs(out["ok"], False)
        steps = self.steps(out)
        for name in ("preflight", "create", "launch"):
            self.assertEqual(steps[name]["status"], "pass", steps[name])
        self.assertEqual(steps["report-in"]["status"], "fail")
        self.assertTrue(steps["report-in"]["detail"])
        for name in ("state", "visible", "kill", "resume"):
            if name in steps:
                self.assertNotEqual(steps[name]["status"], "pass", name)
        self.assertEqual(steps["teardown"]["status"], "pass")
        self.assertEqual(steps["clean"]["status"], "pass")
        self.assertTrue(self.calls(), "the session was never launched")
        self.assert_nothing_left()

    def test_keep_leaves_worktree_and_ticket(self):
        p, out = self.selftest("--timeout", "30", "--keep")
        rows = self.db_exec("SELECT id, worktree FROM tickets WHERE id LIKE 'selftest-%'")
        self.assertEqual(len(rows), 1, out)
        tid, wt = rows[0]
        self.assertRegex(tid, r"^selftest-[0-9a-f]{8}$")
        self.assertTrue(os.path.isdir(wt))
        self.assertIn(os.path.realpath(wt), self.worktree_paths())
        self.assertIn(tid, self.branches())

class DesktopSelftestTests(AdapterTestCase):
    def setUp(self):
        super().setUp()
        self.env["ORCH_PLATFORM"] = "desktop"

    def ticket_of(self, action):
        if action.get("prompt_file") and os.path.isfile(action["prompt_file"]):
            m = re.search(r"orch phase ([A-Za-z0-9._-]+) spec",
                          read_file(action["prompt_file"]))
            if m:
                return m.group(1)
        if action.get("ticket"):
            return action["ticket"]
        title = action.get("title") or ""
        return title[1:] if title.startswith("t") else None

    def test_turn_based_selftest(self):
        p = self.ok("selftest", "--json", "--timeout", "30")
        out = json.loads(p.stdout)
        self.assertEqual(out["action"], "desktop_start")
        run = out["run"]
        self.assertTrue(run)
        self.assertNotIn("ok", out)
        sid = "desktop-selftest-sid"
        state = {"proc": None, "archived": False, "cwd": out.get("cwd"), "ticket": None}
        actions = []
        for _ in range(20):
            if "action" not in out:
                break
            action = out["action"]
            actions.append(action)
            self.assertEqual(out["run"], run)
            answer = {"ok": True}
            if action == "desktop_start":
                state["cwd"] = out["cwd"]
                state["ticket"] = self.ticket_of(out)
                self.assertTrue(state["ticket"], out)
                state["proc"] = self.live_process()
                self.hook_ok("SessionStart", sid, state["cwd"], pid=state["proc"].pid)
                self.ok("phase", state["ticket"], "spec", cwd=state["cwd"])
                answer.update({"session_id": sid, "ref": "local_selftest"})
            elif action == "desktop_check":
                shown = not state["archived"]
                answer.update({"worktree": shown, "session": shown})
            elif action == "desktop_resume":
                state["proc"] = self.live_process()
                self.hook_ok("SessionStart", sid, state["cwd"], pid=state["proc"].pid,
                             extra={"source": "resume"})
                answer.update({"session_id": sid})
            elif action == "desktop_archive":
                if state["proc"] and state["proc"].poll() is None:
                    state["proc"].kill()
                    state["proc"].wait()
                state["archived"] = True
            elif "stop" in action or "kill" in action:
                if state["proc"] and state["proc"].poll() is None:
                    state["proc"].kill()
                    state["proc"].wait()
            p = self.orch("selftest", "--json", "--continue", run, "--answer",
                          json.dumps(answer), timeout=60)
            self.assertEqual(p.returncode, 0,
                             "continue after %s: rc=%s stdout=%r stderr=%r"
                             % (action, p.returncode, p.stdout, p.stderr))
            out = json.loads(p.stdout)
        self.assertNotIn("action", out, "selftest never finished: %r" % actions)
        self.assertIs(out["ok"], True, out)
        self.assertEqual([s["name"] for s in out["steps"]], SELFTEST_STEPS)
        for s in out["steps"]:
            self.assertEqual(s["status"], "pass", s)
        self.assertEqual(actions[0], "desktop_start")
        self.assertIn("desktop_check", actions)
        self.assertIn("desktop_resume", actions)
        self.assertIn("desktop_archive", actions)
        self.assertEqual(self.db_exec(
            "SELECT id FROM tickets WHERE id LIKE 'selftest-%'"), [])
        self.assertEqual(self.branches("selftest-*"), [])
        self.assertFalse(os.path.exists(state["cwd"]))

    def test_continue_unknown_run_is_not_found(self):
        self.refused(4, "selftest", "--continue", "no-such-run", "--answer", "{}")


# ---- follow-ups from the last review ----------------------------------------


class HijackWindowTests(AdapterTestCase):
    """While session_seen=0, a SessionStart with another session id must not
    take a headless/orca/herdr ticket over; desktop still allows it."""

    def setUp(self):
        super().setUp()
        self.use_orca2()
        self.wt = self.git_wt("hj")

    def assert_not_taken(self, tid, sid):
        n = len(self.events(tid))
        p = self.hook_ok("SessionStart", "sid-intruder", self.wt,
                         pid=self.live_process().pid)
        self.assertEqual(p.stdout, "")
        t = self.show(tid)
        self.assertEqual(t["session_id"], sid)
        self.assertNotIn("attach", self.event_kinds(tid))
        self.assertEqual(len(self.events(tid)), n)
        self.assertEqual(self.db_exec(
            "SELECT session_seen FROM tickets WHERE id=?", (tid,))[0][0], 0)

    def test_orca_not_taken_over_before_report_in(self):
        self.spawn_on("t1", "orca", self.wt)
        self.assert_not_taken("t1", self.show("t1")["session_id"])

    def test_herdr_not_taken_over_before_report_in(self):
        self.spawn_on("t1", "orca", self.wt)
        self.db_exec("UPDATE tickets SET platform='herdr' WHERE id='t1'")
        self.assert_not_taken("t1", self.show("t1")["session_id"])

    def test_headless_not_taken_over_before_report_in(self):
        self.add("t1")
        self.spawn("t1", sleep=0, init=False, worktree=self.wt)
        self.wait_dead("t1")
        self.assert_not_taken("t1", self.show("t1")["session_id"])

    def test_desktop_taken_over_before_report_in(self):
        self.spawn_on("t1", "desktop", self.wt)
        proc = self.live_process()
        p = self.hook_ok("SessionStart", "sid-desktop", self.wt, pid=proc.pid)
        self.assertIn("orch show t1", p.stdout)
        t = self.show("t1")
        self.assertEqual((t["session_id"], t["pid"]), ("sid-desktop", proc.pid))
        self.assertEqual(self.event_kinds("t1")[-1], "attach")


class MainCheckoutSubdirTests(AdapterTestCase):
    def test_subdirectory_of_main_checkout_refused(self):
        sub = os.path.join(self.repo, "sub")
        os.makedirs(sub)
        self.add("t1")
        p = self.refused(3, "spawn", "t1", "--worktree", sub, "--brief-file", self.brief)
        self.assertNotIn("Traceback", p.stderr)
        self.assertEqual(self.show("t1")["phase"], "ready")
        time.sleep(0.3)
        self.assertEqual(self.calls(), [])

    def test_linked_worktree_inside_main_checkout_allowed(self):
        wt = os.path.join(self.repo, ".claude", "worktrees", "x")
        self.git("worktree", "add", "-q", "-b", "x", wt)
        self.add("t1")
        self.ok("spawn", "t1", "--worktree", wt, "--brief-file", self.brief)
        self.assertEqual(self.show("t1")["worktree"], os.path.realpath(wt))


class IsClaudeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.orch = load_orch_module()

    def test_not_claude(self):
        for comm, command in (
            ("/bin/zsh", "zsh -lc claude --foo"),
            ("zsh", "/bin/zsh -lc claude --foo"),
            ("bash", "bash -c claude"),
            ("sh", "sh -c claude -p hi"),
            ("python3", "python3 -m claude"),
            ("/usr/bin/python3", "/usr/bin/python3 -m claude --x"),
            ("bash", "bash ./scripts/claude"),
        ):
            self.assertFalse(self.orch.is_claude(comm, command), (comm, command))

    def test_claude(self):
        for comm, command in (
            ("/usr/local/bin/claude", "claude --session-id s"),
            ("/Users/u/.local/share/claude/versions/2.1.288", "claude"),
            ("/Applications/Claude.app/Contents/Resources/app/claude/versions/2.1.288",
             "/x/claude/versions/2.1.288 --resume s"),
            ("node", "node /x/bin/claude --resume s"),
            ("/usr/local/bin/node", "/usr/local/bin/node /x/bin/claude"),
        ):
            self.assertTrue(self.orch.is_claude(comm, command), (comm, command))


class ResumeRefTests(AdapterTestCase):
    def test_resume_onto_desktop_from_orca_nulls_closed_terminal_ref(self):
        self.use_orca2()
        wt = self.git_wt("rd")
        self.spawn_on("t1", "orca", wt)
        proc = self.live_process()
        self.hook_ok("SessionStart", self.show("t1")["session_id"], wt, pid=proc.pid)
        proc.kill()
        proc.wait()
        out = self.j("resume", "t1", "--platform", "desktop")
        self.assertEqual(out["action"], "desktop_resume")
        self.assertNotIn("ref", out)
        self.assertIn(["terminal", "close"], [r["argv"][:2] for r in self.log("orca")])
        t = self.show("t1")
        self.assertEqual(t["platform"], "desktop")
        self.assertIsNone(t["launch_ref"], "launch_ref still names the closed terminal")


class PidPairTests(AdapterTestCase):
    def setUp(self):
        super().setUp()
        self.use_orca2()
        self.wt = self.git_wt("pp")

    def pair(self, tid="t1"):
        return tuple(self.db_exec("SELECT pid, pid_start FROM tickets WHERE id=?",
                                  (tid,))[0])

    def test_lstart_failure_keeps_previous_pair(self):
        self.spawn_on("t1", "orca", self.wt)
        sid = self.show("t1")["session_id"]
        proc = self.live_process()
        self.hook_ok("SessionStart", sid, self.wt, pid=proc.pid)
        before = self.pair()
        self.assertEqual(before[0], proc.pid)
        self.assertTrue(before[1])
        gone = subprocess.Popen(["true"])
        gone.wait()
        self.hook_ok("SessionStart", sid, self.wt, pid=gone.pid,
                     extra={"source": "resume"})
        self.assertEqual(self.pair(), before)
        self.assertTrue(self.show("t1")["alive"])

    def test_headless_resume_then_session_start_new_pid(self):
        self.add("t1")
        self.spawn("t1", sleep=0, worktree=self.wt)
        sid = self.show("t1")["session_id"]
        first = self.live_process()
        self.hook_ok("SessionStart", sid, self.wt, pid=first.pid)
        first.kill()
        first.wait()
        self.wait_dead("t1")
        self.ok("resume", "t1", env={"ORCH_CLAUDE_BIN": self.fake_claude(30)})
        self.wait_calls(2)
        new = self.live_process()
        self.hook_ok("SessionStart", sid, self.wt, pid=new.pid,
                     extra={"source": "resume"})
        t = self.show("t1")
        self.assertEqual(t["pid"], new.pid)
        self.assertTrue(self.pair()[1])
        self.assertTrue(t["alive"])
        self.assertEqual(t["health"], "working")


class FolderTrustTests(AdapterTestCase):
    """Interactive claude in a folder it has not trusted stops at the trust
    dialog. orca/herdr launches detect it, record the launch (the terminal
    stays open for the user) and refuse with exit 3; selftest fails report-in
    with that reason."""

    def argv2(self, who):
        return [r["argv"][:2] for r in self.log(who)]

    def assert_trust_refusal(self, p, wt):
        self.assertIn("folder-trust prompt", p.stderr)
        self.assertIn(wt, p.stderr)
        self.assertNotIn("Traceback", p.stderr)

    def test_orca_spawn_blocked_at_trust(self):
        self.use_orca2(trust=True)
        wt = self.git_wt("tr")
        self.add("t1")
        p = self.refused(3, "spawn", "t1", "--worktree", wt, "--brief-file", self.brief,
                         "--platform", "orca")
        self.assert_trust_refusal(p, wt)
        wait = [r["argv"] for r in self.log("orca") if r["argv"][:2] == ["terminal", "wait"]]
        self.assertEqual(len(wait), 1)
        self.assertEqual(wait[0][wait[0].index("--for") + 1], "tui-idle")
        t = self.show("t1")
        self.assertEqual(t["phase"], "dispatched")
        self.assertEqual(t["launch_ref"], {"terminal": "term_abc"})
        self.assertIn("trust_prompt", self.event_kinds("t1"))
        self.assertNotIn(["terminal", "close"], self.argv2("orca"))

    def test_orca_spawn_not_blocked(self):
        self.use_orca2()
        self.add("t1")
        self.ok("spawn", "t1", "--worktree", self.git_wt("ok"), "--brief-file",
                self.brief, "--platform", "orca")
        self.assertNotIn("trust_prompt", self.event_kinds("t1"))

    def test_herdr_spawn_blocked_at_trust(self):
        self.use_herdr2(trust=True)
        wt = self.git_wt("tr")
        self.add("t1")
        p = self.refused(3, "spawn", "t1", "--worktree", wt, "--brief-file", self.brief,
                         "--platform", "herdr")
        self.assert_trust_refusal(p, wt)
        self.assertIn("herdr agent prompt tt1", p.stderr)
        t = self.show("t1")
        self.assertEqual(t["phase"], "dispatched")
        self.assertEqual(t["launch_ref"], {"workspace": "w1", "pane": "w1:p1",
                                           "agent": "tt1"})
        self.assertIn("trust_prompt", self.event_kinds("t1"))
        calls = self.argv2("herdr")
        self.assertNotIn(["workspace", "close"], calls)
        self.assertNotIn(["agent", "prompt"], calls)

    def selftest_blocked(self, platform):
        self.env["ORCH_PLATFORM"] = platform
        p = self.orch("selftest", "--json", "--timeout", "30", timeout=120)
        out = json.loads(p.stdout)
        self.assertNotEqual(p.returncode, 0)
        self.assertIs(out["ok"], False)
        steps = {s["name"]: s for s in out["steps"]}
        self.assertEqual(steps["launch"]["status"], "pass", steps["launch"])
        self.assertEqual(steps["report-in"]["status"], "fail")
        self.assertIn("folder-trust prompt", steps["report-in"]["detail"])
        self.assertEqual(steps["teardown"]["status"], "pass", steps["teardown"])
        return steps

    def test_orca_selftest_reports_trust(self):
        self.use_orca2(trust=True)
        start = time.time()
        steps = self.selftest_blocked("orca")
        self.assertLess(time.time() - start, 25, "report-in waited out its timeout")
        self.assertEqual(steps["clean"]["status"], "pass", steps["clean"])
        self.assertEqual(self.branches("selftest-*"), [])

    def test_herdr_selftest_reports_trust(self):
        self.use_herdr2(trust=True)
        steps = self.selftest_blocked("herdr")
        self.assertEqual(steps["clean"]["status"], "pass", steps["clean"])
        self.assertEqual(self.branches("selftest-*"), [])


class HookDuringLaunchTests(AdapterTestCase):
    """A SessionStart that lands while orca/herdr are still starting the
    session (orca's trust wait, herdr's agent start + prompt) keeps its pid."""

    def assert_kept(self, tid, proc):
        t = self.show(tid)
        self.assertEqual(t["pid"], proc.pid, t)
        self.assertTrue(t["alive"], t)
        self.assertEqual(t["health"], "working")

    def test_orca_hook_pid_survives_step_3(self):
        proc = self.live_process()
        self.use_orca2(hook_pid=proc.pid)
        self.spawn_on("t1", "orca", self.git_wt("hk"))
        self.assert_kept("t1", proc)

    def test_herdr_hook_pid_survives_step_3(self):
        proc = self.live_process()
        self.use_herdr2(hook_pid=proc.pid)
        self.spawn_on("t1", "herdr", self.git_wt("hk"))
        self.assert_kept("t1", proc)


class LaunchMarkerTests(AdapterTestCase):
    """spawn/resume/retire release the write lock while external commands
    run; an in-flight marker keeps a second one off the same ticket."""

    def set_marker(self, tid, pid=None, age_s=0):
        at = time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime(time.time() - age_s))
        self.db_exec("UPDATE tickets SET launching=? WHERE id=?", (json.dumps(
            {"token": "x", "op": "spawn", "pid": pid or os.getpid(), "at": at}), tid))

    def marker(self, tid):
        return self.db_exec("SELECT launching FROM tickets WHERE id=?", (tid,))[0][0]

    def dead_ticket(self, tid="t1"):
        self.add(tid)
        self.spawn(tid, sleep=0, worktree=self.git_wt(tid))
        self.wait_dead(tid)

    def test_fresh_marker_refuses_resume_retire_spawn(self):
        self.dead_ticket()
        self.set_marker("t1")
        for args in (("resume", "t1"), ("retire", "t1", "--force")):
            p = self.refused(3, *args)
            self.assertIn("launch in progress", p.stderr)
        self.assertFalse(self.show("t1")["retired"])
        self.add("t2")
        self.set_marker("t2")
        p = self.refused(3, "spawn", "t2", "--brief-file", self.brief)
        self.assertIn("launch in progress", p.stderr)
        self.assertEqual(self.log("create"), [])

    def test_abandoned_marker_is_ignored(self):
        self.dead_ticket()
        gone = subprocess.Popen(["true"])
        gone.wait()
        self.set_marker("t1", pid=gone.pid)
        self.ok("resume", "t1")
        self.assertIsNone(self.marker("t1"))
        self.wait_dead("t1")
        self.set_marker("t1", age_s=3600)
        self.ok("resume", "t1")
        self.assertIsNone(self.marker("t1"))

    def background(self, *args):
        p = subprocess.Popen([ORCH] + list(args), cwd=self.repo, env=self.env,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: p.poll() is None and p.kill())
        return p

    def test_resume_and_retire_refused_during_spawn_step_2(self):
        block = os.path.join(self.tmp, "release")
        self.use_orca2(block=block)
        wt = self.git_wt("bl")
        self.add("t1")
        p = self.background("spawn", "t1", "--worktree", wt, "--brief-file",
                            self.brief, "--platform", "orca")
        self.assertTrue(wait_until(lambda: os.path.exists(block + ".started"), 20))
        self.assertIn("launch in progress", self.refused(3, "resume", "t1").stderr)
        self.assertIn("launch in progress",
                      self.refused(3, "retire", "t1", "--force").stderr)
        open(block, "w").close()
        out, err = p.communicate(timeout=60)
        self.assertEqual(p.returncode, 0, err)
        self.assertIsNone(self.marker("t1"))
        terms = [r for r in self.log("orca") if r["argv"][:2] == ["terminal", "create"]]
        self.assertEqual(len(terms), 1)

    def test_resume_refused_during_retire(self):
        block = os.path.join(self.tmp, "release")
        self.use_orca2(block=block, block_cmds=["terminal close"])
        wt = self.git_wt("rr")
        self.spawn_on("t1", "orca", wt)
        p = self.background("retire", "t1", "--force")
        self.assertTrue(wait_until(lambda: os.path.exists(block + ".started"), 20))
        self.assertIn("launch in progress", self.refused(3, "resume", "t1").stderr)
        open(block, "w").close()
        out, err = p.communicate(timeout=60)
        self.assertEqual(p.returncode, 0, err)
        self.assertTrue(self.show("t1")["retired"])
        self.assertIsNone(self.marker("t1"))
        self.assertEqual(len([r for r in self.log("orca")
                              if r["argv"][:2] == ["terminal", "create"]]), 1)

    def test_marker_cleared_after_failed_launch(self):
        self.use_orca2(fail=["terminal create"])
        self.add("t1")
        self.refused(3, "spawn", "t1", "--worktree", self.git_wt("fl"),
                     "--brief-file", self.brief, "--platform", "orca")
        self.assertIsNone(self.marker("t1"))
        self.assertEqual(self.show("t1")["phase"], "ready")

    def test_spawn_refused_while_same_worktree_name_is_launching(self):
        self.add("t.1")
        self.set_marker("t.1")
        self.add("T-1")
        p = self.refused(3, "spawn", "T-1", "--brief-file", self.brief)
        self.assertIn("launch in progress", p.stderr)
        self.assertEqual(self.log("create"), [])


class OrcaWorktreeTests(AdapterTestCase):
    def rm_selector(self):
        rm = [r["argv"] for r in self.log("orca") if r["argv"][:2] == ["worktree", "rm"]]
        self.assertEqual(len(rm), 1, rm)
        return rm[0][rm[0].index("--worktree") + 1]

    def test_repo_add_then_retry_on_repo_not_found(self):
        self.use_orca2(unregistered=True)
        self.spawn_new("t1", "orca")
        calls = [r["argv"][:2] for r in self.log("orca")]
        self.assertEqual(calls[:3], [["worktree", "create"], ["repo", "add"],
                                     ["worktree", "create"]])
        add = self.log("orca")[1]["argv"]
        self.assertEqual(os.path.realpath(add[add.index("--path") + 1]),
                         os.path.realpath(self.repo))
        self.assertEqual(self.show("t1")["phase"], "dispatched")

    def test_rm_uses_id_selector(self):
        self.use_orca2()
        self.spawn_new("t1", "orca")
        wt = self.show("t1")["worktree"]
        self.ok("retire", "t1", "--force")
        self.assertEqual(self.rm_selector(), "id:repo1::" + wt)

    def test_rm_falls_back_to_path_selector(self):
        self.use_orca2(no_id=True)
        self.spawn_new("t1", "orca")
        wt = self.show("t1")["worktree"]
        self.ok("retire", "t1", "--force")
        self.assertEqual(self.rm_selector(), "path:" + wt)
        self.assertFalse(os.path.exists(wt))


class SelftestTeardownTests(AdapterTestCase):
    """Teardown and clean run whatever happened before them, and the run is
    always reported."""

    def selftest(self, timeout="3"):
        p = self.orch("selftest", "--json", "--timeout", timeout, timeout=150)
        try:
            out = json.loads(p.stdout)
        except ValueError:
            self.fail("selftest --json printed %r (stderr %r)" % (p.stdout, p.stderr))
        return p, out, {s["name"]: s for s in out["steps"]}

    def assert_no_worktree_left(self):
        self.assertEqual(self.worktree_paths(), [os.path.realpath(self.repo)])
        self.assertEqual(self.branches("selftest-*"), [])
        root = os.path.join(self.tmp, "orca-wts")
        if os.path.isdir(root):
            self.assertEqual(os.listdir(root), [])

    def saved_runs(self):
        return [json.loads(r[0]) for r in self.db_exec("SELECT state FROM selftest_runs")]

    def test_failed_launch_leaves_no_worktree(self):
        self.env["ORCH_PLATFORM"] = "orca"
        self.use_orca2(fail=["terminal create"])
        p, out, steps = self.selftest()
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(steps["launch"]["status"], "fail")
        self.assertEqual(steps["teardown"]["status"], "pass", steps["teardown"])
        self.assertEqual(steps["clean"]["status"], "pass", steps["clean"])
        self.assert_no_worktree_left()

    def test_interrupt_at_launch_still_tears_down(self):
        self.env["ORCH_PLATFORM"] = "orca"
        self.use_orca2(interrupt=["terminal create"])
        p, out, steps = self.selftest()
        self.assertNotEqual(p.returncode, 0)
        self.assertNotIn("Traceback", p.stderr)
        self.assertIs(out["ok"], False)
        self.assertEqual(steps["launch"]["status"], "fail")
        self.assertIn("interrupt", steps["launch"]["detail"].lower())
        self.assertEqual(steps["teardown"]["status"], "pass", steps["teardown"])
        self.assertEqual(steps["clean"]["status"], "pass", steps["clean"])
        self.assert_no_worktree_left()
        runs = self.saved_runs()
        self.assertEqual(len(runs), 1)
        self.assertIn("clean", [s["name"] for s in runs[0]["steps"]])

    def test_interrupt_inside_teardown_still_runs_clean(self):
        self.env["ORCH_CLAUDE_BIN"] = self.session_claude()
        self.env["ORCH_RETIRE_ENGINE"] = self.fake_engine("retire", interrupt=True)
        p, out, steps = self.selftest("30")
        self.assertNotEqual(p.returncode, 0)
        self.assertNotIn("Traceback", p.stderr)
        self.assertEqual(steps["resume"]["status"], "pass", steps["resume"])
        self.assertEqual(steps["teardown"]["status"], "fail")
        self.assertIn("clean", steps)
        self.assertEqual(self.db_exec(
            "SELECT id FROM tickets WHERE id LIKE 'selftest-%'"), [])
        self.assertEqual(len(self.saved_runs()), 1)


class SelftestCleanTests(AdapterTestCase):
    """clean fails when it cannot tell whether something is left."""

    def selftest(self, timeout="3"):
        p = self.orch("selftest", "--json", "--timeout", timeout, timeout=150)
        out = json.loads(p.stdout)
        return p, {s["name"]: s for s in out["steps"]}

    def test_ddev_error_is_unknown(self):
        self.env["ORCH_CLAUDE_BIN"] = self.session_claude()
        bindir = os.path.join(self.tmp, "ddev-bin")
        os.makedirs(bindir)
        with open(os.path.join(bindir, "ddev"), "w") as f:
            f.write("#!/bin/sh\necho 'docker is not running' >&2\nexit 1\n")
        os.chmod(os.path.join(bindir, "ddev"), 0o755)
        self.env["PATH"] = bindir + os.pathsep + self.env.get("PATH", "/usr/bin:/bin")
        p, steps = self.selftest("30")
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(steps["teardown"]["status"], "pass", steps["teardown"])
        self.assertEqual(steps["clean"]["status"], "fail", steps["clean"])
        self.assertIn("DDEV", steps["clean"]["detail"])

    def test_platform_tool_error_is_unknown(self):
        self.env["ORCH_PLATFORM"] = "orca"
        self.use_orca2(fail=["worktree list"])
        p, steps = self.selftest()
        self.assertEqual(steps["teardown"]["status"], "pass", steps["teardown"])
        self.assertEqual(steps["clean"]["status"], "fail", steps["clean"])
        self.assertIn("unknown", steps["clean"]["detail"])

    def test_session_processes_checked_after_trust_block(self):
        self.env["ORCH_PLATFORM"] = "orca"
        leak = os.path.join(self.tmp, "leaked-pids")

        def kill_leaked():
            for line in (read_file(leak).split() if os.path.exists(leak) else []):
                try:
                    os.kill(int(line), 9)
                except OSError:
                    pass
        self.addCleanup(kill_leaked)
        self.use_orca2(trust=True, leak=leak)
        p, steps = self.selftest("30")
        self.assertIn("folder-trust", steps["report-in"]["detail"])
        self.assertEqual(steps["clean"]["status"], "fail", steps["clean"])
        self.assertIn("processes still running", steps["clean"]["detail"])


class TrustMarkTests(AdapterTestCase):
    """orch marks each Orca/Herdr ticket worktree trusted in Claude's user
    config (ORCH_CLAUDE_JSON here) before launch, and removes what it added
    on retire."""

    def setUp(self):
        super().setUp()
        self.assertTrue(self.env["ORCH_CLAUDE_JSON"].startswith(self.tmp + os.sep))
        self.write_cj({"numStartups": 7, "oauthAccount": {"emailAddress": "x@y"},
                       "projects": {"/elsewhere": {"allowedTools": ["Bash"],
                                                   "hasTrustDialogAccepted": True}}})

    def write_cj(self, data, mode=0o600):
        with open(self.claude_json, "w") as f:
            f.write(data if isinstance(data, str) else json.dumps(data, indent=2))
        os.chmod(self.claude_json, mode)

    def cj(self):
        with open(self.claude_json) as f:
            return json.load(f)

    def entry(self, wt):
        return self.cj()["projects"].get(wt)

    def probes(self):
        return [r for r in self.log("trust-probe")]

    def assert_others_kept(self):
        data = self.cj()
        self.assertEqual(data["numStartups"], 7)
        self.assertEqual(data["oauthAccount"], {"emailAddress": "x@y"})
        self.assertEqual(data["projects"]["/elsewhere"],
                         {"allowedTools": ["Bash"], "hasTrustDialogAccepted": True})

    def test_orca_spawn_marks_before_launch(self):
        self.use_orca2()
        wt = self.git_wt("o1")
        self.spawn_on("t1", "orca", wt)
        self.assertEqual([(p["wt"], p["trusted"]) for p in self.probes()], [(wt, True)])
        self.assertEqual(self.entry(wt), {"hasTrustDialogAccepted": True})
        self.assert_others_kept()
        self.assertEqual(os.stat(self.claude_json).st_mode & 0o777, 0o600)
        self.assertIn("trust_mark", self.event_kinds("t1"))

    def test_herdr_spawn_and_resume_mark(self):
        self.use_herdr2()
        wt = self.git_wt("h1")
        self.spawn_on("t1", "herdr", wt)
        self.assertEqual(self.entry(wt), {"hasTrustDialogAccepted": True})
        data = self.cj()
        del data["projects"][wt]
        self.write_cj(data)
        self.ok("resume", "t1")
        self.assertEqual([p["trusted"] for p in self.probes()], [True, True])
        self.assertEqual(self.entry(wt), {"hasTrustDialogAccepted": True})
        self.ok("retire", "t1", "--force")
        self.assertNotIn(wt, self.cj()["projects"])
        self.assert_others_kept()

    def test_headless_does_not_mark(self):
        before = read_file(self.claude_json)
        self.add("t1")
        self.spawn("t1", sleep=0, worktree=self.git_wt("hl"))
        self.assertEqual(read_file(self.claude_json), before)

    def test_existing_entry_keeps_its_keys(self):
        self.use_orca2()
        wt = self.git_wt("ek")
        data = self.cj()
        data["projects"][wt] = {"allowedTools": ["Edit"], "lastCost": 1.5}
        self.write_cj(data, mode=0o640)
        self.spawn_on("t1", "orca", wt)
        self.assertEqual(self.entry(wt), {"allowedTools": ["Edit"], "lastCost": 1.5,
                                          "hasTrustDialogAccepted": True})
        self.assertEqual(os.stat(self.claude_json).st_mode & 0o777, 0o640)
        self.ok("retire", "t1", "--force")
        self.assertEqual(self.entry(wt), {"allowedTools": ["Edit"], "lastCost": 1.5})
        self.assert_others_kept()

    def test_pre_trusted_entry_left_on_retire(self):
        self.use_orca2()
        wt = self.git_wt("pt")
        data = self.cj()
        data["projects"][wt] = {"hasTrustDialogAccepted": True, "x": 1}
        self.write_cj(data)
        self.spawn_on("t1", "orca", wt)
        self.assertNotIn("trust_mark", self.event_kinds("t1"))
        self.ok("retire", "t1", "--force")
        self.assertEqual(self.entry(wt), {"hasTrustDialogAccepted": True, "x": 1})

    def test_retire_removes_created_entry(self):
        self.use_orca2()
        self.spawn_new("t1", "orca")
        wt = self.show("t1")["worktree"]
        self.assertEqual(self.entry(wt), {"hasTrustDialogAccepted": True})
        self.ok("retire", "t1", "--force")
        self.assertNotIn(wt, self.cj()["projects"])
        self.assert_others_kept()

    def trust_marked(self, tid):
        return self.db_exec("SELECT trust_marked FROM tickets WHERE id=?", (tid,))[0][0]

    def test_two_tickets_one_worktree_keep_trust_until_last_retires(self):
        self.use_orca2()
        wt = self.git_wt("tw")
        self.spawn_on("t1", "orca", wt)
        # A done ticket's worktree may be handed to a new ticket.
        self.db_exec("UPDATE tickets SET phase='done' WHERE id='t1'")
        self.spawn_on("t2", "orca", wt)
        self.assertEqual(self.trust_marked("t1"), 2)
        self.assertEqual(self.trust_marked("t2"), 0)
        self.assertNotIn("trust_mark", self.event_kinds("t2"))
        self.ok("retire", "t1", "--force")
        self.assertEqual(self.entry(wt), {"hasTrustDialogAccepted": True})
        self.assertEqual(self.trust_marked("t1"), 0)
        self.assertEqual(self.trust_marked("t2"), 2)
        self.ok("retire", "t2", "--force")
        self.assertNotIn(wt, self.cj()["projects"])
        self.assert_others_kept()

    def test_keep_worktree_keeps_trust(self):
        self.use_orca2()
        wt = self.git_wt("kw")
        self.spawn_on("t1", "orca", wt)
        self.ok("retire", "t1", "--force", "--keep-worktree")
        self.assertEqual(self.entry(wt), {"hasTrustDialogAccepted": True})

    def test_failed_launch_removes_mark(self):
        self.use_orca2(fail=["terminal create"])
        wt = self.git_wt("fl")
        self.add("t1")
        self.refused(3, "spawn", "t1", "--worktree", wt, "--brief-file", self.brief,
                     "--platform", "orca")
        self.assertNotIn(wt, self.cj()["projects"])

    def test_missing_file_warns_and_launches(self):
        os.remove(self.claude_json)
        self.use_orca2()
        wt = self.git_wt("mf")
        p = self.spawn_on("t1", "orca", wt)
        self.assertIn("warning", p.stderr)
        self.assertIn("folder", p.stderr)
        self.assertFalse(os.path.exists(self.claude_json))
        self.assertEqual(self.show("t1")["phase"], "dispatched")
        self.ok("retire", "t1", "--force")
        self.assertFalse(os.path.exists(self.claude_json))

    def test_invalid_file_untouched_and_not_printed(self):
        bad = '{"primaryApiKey": "sk-SECRET-123", "projects": {'
        self.write_cj(bad)
        self.use_herdr2()
        wt = self.git_wt("ij")
        p = self.spawn_on("t1", "herdr", wt)
        self.assertIn("warning", p.stderr)
        self.assertNotIn("SECRET", p.stderr + p.stdout)
        self.assertEqual(read_file(self.claude_json), bad)
        self.assertEqual(self.show("t1")["phase"], "dispatched")


class TrustWriteTests(AdapterTestCase):
    """The read-modify-replace write retries when a concurrent writer drops
    the key, in process against the loaded module."""

    def setUp(self):
        super().setUp()
        self.mod = load_orch_module()
        patcher = unittest.mock.patch.dict(os.environ, {"ORCH_CLAUDE_JSON": self.claude_json})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.wt = os.path.join(self.tmp, "wt-x")

    def clobbering_writer(self, times):
        real = self.mod.write_claude_json
        calls = []

        def write(path, data, **kw):
            real(path, data, **kw)
            calls.append(path)
            if len(calls) <= times:
                with open(path, "w") as f:
                    json.dump({"projects": {}, "other": 1}, f)
        self.mod.write_claude_json = write
        return calls

    def test_retry_after_concurrent_drop(self):
        calls = self.clobbering_writer(times=1)
        self.assertEqual(self.mod.set_trust(self.wt, True), 2)
        self.assertEqual(len(calls), 2)
        with open(self.claude_json) as f:
            data = json.load(f)
        self.assertEqual(data["projects"][self.wt], {"hasTrustDialogAccepted": True})
        self.assertEqual(data["other"], 1)

    def test_gives_up_after_three_writes(self):
        calls = self.clobbering_writer(times=99)
        with self.assertRaises(self.mod.TrustError):
            self.mod.set_trust(self.wt, True)
        self.assertEqual(len(calls), 3)


    def read_cj(self, path=None):
        with open(path or self.claude_json) as f:
            return json.load(f)

    def test_symlinked_config_stays_a_link(self):
        real_dir = os.path.join(self.tmp, "real-home")
        os.makedirs(real_dir)
        target = os.path.join(real_dir, ".claude.json")
        with open(target, "w") as f:
            json.dump({"projects": {}, "keep": 1}, f)
        os.chmod(target, 0o640)
        link = os.path.join(self.tmp, "link.claude.json")
        os.symlink(target, link)
        with unittest.mock.patch.dict(os.environ, {"ORCH_CLAUDE_JSON": link}):
            self.assertEqual(self.mod.set_trust(self.wt, True), 2)
        self.assertTrue(os.path.islink(link))
        self.assertEqual(os.readlink(link), target)
        data = self.read_cj(target)
        self.assertEqual(data["projects"][self.wt], {"hasTrustDialogAccepted": True})
        self.assertEqual(data["keep"], 1)
        self.assertEqual(os.stat(target).st_mode & 0o777, 0o640)
        self.assertEqual([n for n in os.listdir(self.tmp) if ".orch-" in n], [])

    def test_concurrent_write_between_read_and_replace_survives(self):
        real = self.mod.read_claude_json_sig
        calls = []

        def read(path):
            out = real(path)
            calls.append(path)
            if len(calls) == 1:
                # Another claude process rewrites the file after our read.
                data = self.read_cj()
                data["concurrent"] = "written meanwhile"
                with open(self.claude_json, "w") as f:
                    json.dump(data, f)
            return out
        self.mod.read_claude_json_sig = read
        self.assertEqual(self.mod.set_trust(self.wt, True), 2)
        data = self.read_cj()
        self.assertEqual(data["concurrent"], "written meanwhile")
        self.assertEqual(data["projects"][self.wt], {"hasTrustDialogAccepted": True})

    def test_temp_file_removed_on_interrupt(self):
        before = self.read_cj()
        d = os.path.dirname(self.claude_json)
        with unittest.mock.patch.object(self.mod.os, "replace",
                                        side_effect=KeyboardInterrupt):
            with self.assertRaises(KeyboardInterrupt):
                self.mod.set_trust(self.wt, True)
        self.assertEqual([n for n in os.listdir(d) if ".orch-" in n], [])
        self.assertEqual(self.read_cj(), before)

    def test_whole_entry_removal_keeps_entry_gaining_keys(self):
        with open(self.claude_json, "w") as f:
            json.dump({"projects": {self.wt: {"hasTrustDialogAccepted": True,
                                              "allowedTools": ["Bash"]}}}, f)
        self.mod.set_trust(self.wt, False, whole_entry=True)
        self.assertEqual(self.read_cj()["projects"][self.wt], {"allowedTools": ["Bash"]})

    def test_whole_entry_removal_removes_exact_entry(self):
        with open(self.claude_json, "w") as f:
            json.dump({"projects": {self.wt: {"hasTrustDialogAccepted": True}}}, f)
        self.mod.set_trust(self.wt, False, whole_entry=True)
        self.assertNotIn(self.wt, self.read_cj()["projects"])


class TrustSelftestTests(AdapterTestCase):
    def selftest(self):
        p = self.orch("selftest", "--json", "--timeout", "3", timeout=150)
        out = json.loads(p.stdout)
        return p, {s["name"]: s for s in out["steps"]}

    def test_clean_passes_when_trust_removed(self):
        self.env["ORCH_PLATFORM"] = "orca"
        self.use_orca2()
        p, steps = self.selftest()
        self.assertEqual(steps["teardown"]["status"], "pass", steps["teardown"])
        self.assertEqual(steps["clean"]["status"], "pass", steps["clean"])
        self.assertTrue(any(r["trusted"] for r in self.log("trust-probe")))
        with open(self.claude_json) as f:
            self.assertEqual(json.load(f)["projects"], {})

    def test_clean_fails_when_trust_entry_left(self):
        self.env["ORCH_PLATFORM"] = "orca"
        self.use_orca2(retrust=True)
        p, steps = self.selftest()
        self.assertEqual(steps["clean"]["status"], "fail", steps["clean"])
        self.assertIn("folder-trust", steps["clean"]["detail"])


class HerdrMainWorkspaceTests(AdapterTestCase):
    """`herdr worktree open` also opens a workspace for the main checkout when
    none is open. selftest closes it only when it opened it; retire never."""

    def setUp(self):
        super().setUp()
        self.env["ORCH_PLATFORM"] = "herdr"

    def selftest(self):
        p = self.orch("selftest", "--json", "--timeout", "3", timeout=150)
        try:
            out = json.loads(p.stdout)
        except ValueError:
            self.fail("selftest --json printed %r (stderr %r)" % (p.stdout, p.stderr))
        return p, out, {s["name"]: s for s in out["steps"]}

    def main_open(self):
        return os.path.exists(os.path.join(self.tmp, "herdr-main-open"))

    def closes(self):
        return [r["argv"] for r in self.log("herdr") if r["argv"][:2] == ["workspace", "close"]]

    def test_selftest_closes_main_workspace_it_opened(self):
        self.use_herdr2(trust=True, main_opens=True)
        p, out, steps = self.selftest()
        self.assertEqual(steps["teardown"]["status"], "pass", steps["teardown"])
        self.assertEqual(steps["clean"]["status"], "pass", steps["clean"])
        self.assertIn(["workspace", "close", "w0"], self.closes())
        self.assertFalse(self.main_open())

    def test_selftest_leaves_main_workspace_open_before(self):
        self.use_herdr2(trust=True, main_opens=True, main_open=True)
        p, out, steps = self.selftest()
        self.assertEqual(steps["teardown"]["status"], "pass", steps["teardown"])
        self.assertEqual(steps["clean"]["status"], "pass", steps["clean"])
        self.assertNotIn(["workspace", "close", "w0"], self.closes())
        self.assertTrue(self.main_open())

    def test_check_error_leaves_main_workspace_open(self):
        self.use_herdr2(trust=True, main_opens=True, list_error=True)
        p, out, steps = self.selftest()
        self.assertEqual(steps["teardown"]["status"], "pass", steps["teardown"])
        self.assertIn("main checkout", steps["teardown"]["detail"])
        self.assertNotIn(["workspace", "close", "w0"], self.closes())
        self.assertTrue(self.main_open())

    def test_clean_fails_when_opened_main_workspace_still_open(self):
        # The close is accepted but the workspace stays open.
        self.use_herdr2(trust=True, main_opens=True, main_sticky=True)
        p, out, steps = self.selftest()
        self.assertEqual(steps["clean"]["status"], "fail", steps["clean"])
        self.assertIn("w0", steps["clean"]["detail"])

    def test_interrupt_closes_main_workspace(self):
        self.use_herdr2(main_opens=True, interrupt=["agent start"])
        p, out, steps = self.selftest()
        self.assertNotIn("Traceback", p.stderr)
        self.assertIn("interrupt", steps["launch"]["detail"].lower())
        self.assertEqual(steps["teardown"]["status"], "pass", steps["teardown"])
        self.assertEqual(steps["clean"]["status"], "pass", steps["clean"])
        self.assertIn(["workspace", "close", "w0"], self.closes())
        self.assertFalse(self.main_open())

    def test_selftest_leaves_main_workspace_reopened_under_new_id(self):
        self.use_herdr2(trust=True, main_opens=True, main_reid=True)
        p, out, steps = self.selftest()
        self.assertEqual(steps["teardown"]["status"], "pass", steps["teardown"])
        self.assertEqual(steps["clean"]["status"], "pass", steps["clean"])
        self.assertNotIn(["workspace", "close", "w9"], self.closes())
        self.assertTrue(self.main_open())

    def test_retire_never_closes_main_workspace(self):
        self.use_herdr2(main_opens=True)
        self.spawn_new("t1", "herdr")
        self.assertTrue(self.main_open())
        self.ok("retire", "t1", "--force")
        self.assertIn(["workspace", "close", "w1"], self.closes())
        self.assertNotIn(["workspace", "close", "w0"], self.closes())
        self.assertTrue(self.main_open())
        self.assertNotIn(["workspace", "list"], [r["argv"] for r in self.log("herdr")])


if __name__ == "__main__":
    unittest.main()
