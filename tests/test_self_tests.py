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
                                    cwd=temp, env=env, capture_output=True, text=True, encoding="utf-8", timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("ALL TESTS PASSED", result.stdout)

    def test_rbrowse_forced_ffi_availability_and_engine_cycling(self):
        # Test both platform branches without requiring a Windows host or
        # installing external image conversion utilities.
        source = (ROOT / "bin/rbrowse.lua").read_text(encoding="utf-8").rsplit("main({ ... })", 1)[0]
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
