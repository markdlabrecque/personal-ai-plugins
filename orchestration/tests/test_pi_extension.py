"""Runs the Pi extension's node tests (tests/pi/extension.test.mjs).

Skipped without node and an installed Pi (the tests load the extension with
Pi's own TypeScript loader).

Run from the plugin dir:  python3 -m unittest discover -s tests -v
"""

import os
import shutil
import subprocess
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))


def pi_installed():
    if not shutil.which("node") or not shutil.which("npm"):
        return False
    root = subprocess.run(["npm", "root", "-g"], capture_output=True, text=True).stdout.strip()
    return os.path.isdir(os.path.join(root, "@earendil-works", "pi-coding-agent"))


@unittest.skipUnless(pi_installed(), "node and a global Pi install are needed")
class PiExtensionTests(unittest.TestCase):
    def test_node_suite(self):
        env = {k: v for k, v in os.environ.items()
               if k not in ("ORCH_HOME", "PI_SUBAGENT_CHILD", "ORCH_PI_PARENT_SESSION")}
        p = subprocess.run(["node", "--test", os.path.join(HERE, "pi", "extension.test.mjs")],
                           capture_output=True, text=True, timeout=120, env=env)
        self.assertEqual(p.returncode, 0, p.stdout[-4000:] + p.stderr[-2000:])


if __name__ == "__main__":
    unittest.main()
