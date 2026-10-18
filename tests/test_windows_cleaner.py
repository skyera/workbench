"""Native junction regression tests; only isolated temporary fixtures are cleaned."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
LUAJIT = shutil.which("luajit")


def lua_string(value):
    return "[=[" + str(value) + "]=]"


@unittest.skipUnless(os.name == "nt" and LUAJIT, "requires Windows and LuaJIT")
class WindowsCleanerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cleaner-junction-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.target = self.base / "cleanup"
        self.outside = self.base / "outside"
        self.target.mkdir()
        self.outside.mkdir()
        self.sentinel = self.outside / "keep.txt"
        self.sentinel.write_bytes(b"outside-sentinel")
        self.link = self.target / "escape"
        result = subprocess.run(
            ["cmd", "/c", "mklink", "/J", str(self.link), str(self.outside)],
            capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        # Remove the junction itself before TemporaryDirectory cleans the fixture.
        self.addCleanup(os.rmdir, self.link)

    def run_driver(self, driver):
        source = (ROOT / "bin/clean_c_drive.lua").read_text(encoding="utf-8")
        source = source.rsplit("main({...})", 1)[0]
        result = subprocess.run(
            [LUAJIT, "-"], input=source + driver, capture_output=True,
            text=True, encoding="utf-8", timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.sentinel.read_bytes(), b"outside-sentinel")
        self.assertTrue(self.link.is_dir())
        return result

    def test_nested_junction_is_skipped_by_scan_dry_run_and_cleanup(self):
        nested = self.target / "ordinary"
        nested.mkdir()
        ordinary = nested / "remove.txt"
        ordinary.write_bytes(b"local")
        result = self.run_driver("local target = " + lua_string(self.target) + r'''
local bytes, files = scan_folder_win32(target)
assert(bytes == 5 and files == 1, "scan must count only ordinary files")
local freed, deleted, dirs = clean_folder_win32(target, true)
assert(freed == 5 and deleted == 1 and dirs == 0)
local f = assert(io.open(target .. "\\ordinary\\remove.txt", "rb"))
f:close()
freed, deleted, dirs = clean_folder_win32(target, false)
assert(freed == 5 and deleted == 1 and dirs == 1)
bytes, files = scan_folder_win32(target)
assert(bytes == 0 and files == 0)
''')
        self.assertFalse(ordinary.exists())
        self.assertIn("Skipped reparse point:", result.stderr)
        self.assertIn(str(self.link), result.stderr)

    def test_junction_root_is_skipped(self):
        result = self.run_driver("local target = " + lua_string(self.link) + r'''
local bytes, files = scan_folder_win32(target)
assert(bytes == 0 and files == 0)
for _, dry_run in ipairs({true, false}) do
    local freed, deleted, dirs = clean_folder_win32(target, dry_run)
    assert(freed == 0 and deleted == 0 and dirs == 0)
end
''')
        self.assertEqual(result.stderr.count("Skipped reparse point:"), 3)

    def test_missing_root_reports_windows_error(self):
        result = self.run_driver("local target = " + lua_string(self.base / "missing") + r'''
local bytes, files = scan_folder_win32(target)
assert(bytes == 0 and files == 0)
local freed, deleted, dirs = clean_folder_win32(target, false)
assert(freed == 0 and deleted == 0 and dirs == 0)
''')
        self.assertIn("Cannot inspect directory", result.stderr)
        self.assertIn("Windows error 2", result.stderr)
        self.assertIn("check that it exists and is accessible", result.stderr)


if __name__ == "__main__":
    unittest.main()
