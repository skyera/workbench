"""Check that tool self-tests work with isolated host and platform fixtures."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
LUAJIT = shutil.which("luajit")


@unittest.skipUnless(LUAJIT, "requires LuaJIT")
class SelfTestRegressions(unittest.TestCase):
    def test_fssh_self_test_accepts_hyphenated_host(self):
        with tempfile.TemporaryDirectory(prefix="fssh-self-test-") as temp:
            ssh = Path(temp) / ".ssh"
            ssh.mkdir()
            (ssh / "config").write_text("Host review-host\n HostName 192.0.2.1\n User review\n")
            env = dict(os.environ, HOME=temp, USERPROFILE=temp)
            result = subprocess.run([LUAJIT, str(ROOT / "bin/fssh.lua"), "--test"],
                                    cwd=temp, env=env, capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("ALL TESTS PASSED", result.stdout)


if __name__ == "__main__":
    unittest.main()
