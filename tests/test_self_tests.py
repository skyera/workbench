"""Check that tool self-tests work with isolated host and platform fixtures."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
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
                                    cwd=temp, env=env, capture_output=True, text=True, encoding="utf-8", timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("ALL TESTS PASSED", result.stdout)

    def test_fnet_self_test_runs(self):
        result = subprocess.run([LUAJIT, str(ROOT / "bin/fnet.lua"), "--test"],
                                capture_output=True, text=True, encoding="utf-8", timeout=90)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("0 failed", result.stdout)

    def test_fshot_self_test_encoder(self):
        result = subprocess.run([LUAJIT, str(ROOT / "bin/fshot.lua"), "--test"],
                                capture_output=True, text=True, encoding="utf-8", timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("0 failed", result.stdout)

    def run_fkill(self, *args, stdin_text=""):
        """Run fkill in its own session so a regression cannot signal the test runner."""
        return subprocess.run([LUAJIT, str(ROOT / "bin/fkill.lua"), *args],
                              input=stdin_text, capture_output=True, text=True,
                              encoding="utf-8", timeout=30, start_new_session=True)

    def test_fkill_self_test_runs(self):
        result = self.run_fkill("--test")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("0 failed", result.stdout)

    def test_fkill_rejects_invalid_command_lines_without_killing(self):
        cases = {
            ("0",): "invalid PID '0'",
            ("--bogus",): "unknown option '--bogus'",
            ("-9",): "need a PID or process name",
            ("--preview", "abc"): "requires a numeric PID",
        }
        for args, expected_message in cases.items():
            with self.subTest(args=args):
                result = self.run_fkill(*args)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn(expected_message, result.stderr)

    @unittest.skipUnless(sys.platform.startswith("linux"), "uses /proc process names")
    def test_fkill_by_name_is_exact_and_confirmed(self):
        with tempfile.TemporaryDirectory(prefix="fkill-test-") as temp:
            victim_name = "fkvictim%d" % (os.getpid() % 100000)
            victim_path = Path(temp) / victim_name
            shutil.copy(shutil.which("sleep"), victim_path)
            victim = subprocess.Popen([str(victim_path), "60"])
            try:
                time.sleep(0.3)

                substring = self.run_fkill("-y", victim_name[:-1])
                self.assertEqual(substring.returncode, 1, substring.stdout + substring.stderr)
                self.assertIn("named exactly", substring.stderr)
                self.assertIn(victim_name, substring.stderr)

                no_answer = self.run_fkill(victim_name)
                self.assertEqual(no_answer.returncode, 1, no_answer.stdout + no_answer.stderr)
                self.assertIn("Use -y", no_answer.stderr)

                declined = self.run_fkill(victim_name, stdin_text="n\n")
                self.assertEqual(declined.returncode, 1, declined.stdout + declined.stderr)
                self.assertIsNone(victim.poll(), "victim must survive a declined prompt")

                confirmed = self.run_fkill(victim_name, "-9", stdin_text="y\n")
                self.assertEqual(confirmed.returncode, 0, confirmed.stdout + confirmed.stderr)
                self.assertEqual(victim.wait(timeout=5), -9)
            finally:
                if victim.poll() is None:
                    victim.kill()
                    victim.wait()

    def test_fkill_reports_failed_kill_on_stderr_with_nonzero_exit(self):
        finished = subprocess.Popen([LUAJIT, "-e", ""])
        finished.wait()
        result = self.run_fkill(str(finished.pid))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Failed to kill PID %d" % finished.pid, result.stderr)
        self.assertEqual(result.stdout, "")

    def test_rfe_forced_ffi_availability_and_engine_cycling(self):
        # Test both platform branches without requiring a Windows host or
        # installing external image conversion utilities.
        target = ROOT / "bin/rfe.lua"
        if not target.exists():
            target = ROOT / "bin/rbrowse.lua"
        source = target.read_text(encoding="utf-8").rsplit("main({ ... })", 1)[0]
        driver = r'''
ImageRenderer.preferred_engine = "ffi"
IS_WINDOWS = false
local lines, engine = ImageRenderer.render_half_blocks(DEMO_PNG_BYTES, 24, 10)
assert(engine == "None" and lines[1]:find("unavailable", 1, true))
IS_WINDOWS = true
GdiPlusRenderer.available = false
lines, engine = ImageRenderer.render_half_blocks(DEMO_PNG_BYTES, 24, 10)
assert(engine == "None" and lines[1]:find("unavailable", 1, true))
GdiPlusRenderer.available = true
GdiPlusRenderer.render_half_blocks = function() return {"rendered pixels"} end
lines, engine = ImageRenderer.render_half_blocks(DEMO_PNG_BYTES, 24, 10)
assert(engine == "FFI/GDI+" and lines[1] == "rendered pixels")
for _, expected in ipairs({"chafa", "magick", "python", "auto"}) do
    assert(ImageRenderer.cycle_engine() == expected)
end
'''
        result = subprocess.run([LUAJIT, "-"], input=source + driver,
                                capture_output=True, text=True, encoding="utf-8", timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
