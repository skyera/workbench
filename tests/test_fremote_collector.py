"""Linux collector tests using disposable child processes and /proc."""
import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import sys
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform.startswith("linux"), "collector requires Linux /proc")
class RemoteCollectorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("collector", ROOT / "bin/fremote_collector.py")
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    def child(self):
        process = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        def cleanup():
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)
        self.addCleanup(cleanup)
        return process

    def command(self, collector, command):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            collector.command(command)
        return output.getvalue()

    def test_snapshots_cpu_and_selected_details(self):
        child = self.child()
        collector = self.module.Collector()
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            collector.snapshot()
            time.sleep(0.03)
            collector.snapshot()
        frames = output.getvalue().split("E\n")
        self.assertEqual(len(frames), 3)
        row = next(line.split("\t") for line in frames[1].splitlines() if line.startswith("P\t%d\t" % child.pid))
        self.assertGreaterEqual(float(row[4]), 0)
        self.assertGreater(int(row[5]), 0)
        result = self.command(collector, "DETAIL\t%d\t%s" % (child.pid, row[3]))
        detail = result.strip().split("\t")
        self.assertEqual(detail[0], "D")
        self.assertIn("time.sleep", bytes.fromhex(detail[3]).decode())
        self.assertTrue(bytes.fromhex(detail[4]).decode().startswith("/"))

    def test_reused_pid_is_rejected_without_signalling(self):
        child = self.child()
        start = self.module.process_stat(child.pid)["start"]
        with patch.object(self.module.os, "pidfd_open") as opened:
            result = self.command(self.module.Collector(), "SIGNAL\t%d\t%d\t15" % (child.pid, start + 1))
            opened.assert_not_called()
        self.assertIn("PID was reused", bytes.fromhex(result.strip().split("\t")[1]).decode())
        self.assertIsNone(child.poll())

    def test_real_sigterm_only_targets_disposable_child(self):
        child = self.child()
        start = self.module.process_stat(child.pid)["start"]
        result = self.command(self.module.Collector(), "SIGNAL\t%d\t%d\t15" % (child.pid, start))
        self.assertTrue(result.startswith("A\t"), result)
        self.assertEqual(child.wait(timeout=5), -15)

    def test_permission_errors_and_invalid_commands_preserve_diagnostics(self):
        child = self.child()
        start = self.module.process_stat(child.pid)["start"]
        with patch.object(self.module.os, "pidfd_open", side_effect=PermissionError(1, "Operation not permitted")):
            result = self.command(self.module.Collector(), "SIGNAL\t%d\t%d\t9" % (child.pid, start))
        message = bytes.fromhex(result.strip().split("\t")[1]).decode()
        self.assertIn("Operation not permitted", message)
        self.assertIn("no elevation was attempted", message)
        result = self.command(self.module.Collector(), "SIGNAL\t-1\t0\t15")
        self.assertTrue(result.startswith("X\t"))
        self.assertIsNone(child.poll())


if __name__ == "__main__":
    unittest.main()
