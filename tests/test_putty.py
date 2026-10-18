"""Exercise PuTTY exports and failure paths without changing saved sessions."""

import os
from pathlib import Path
import shutil
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
LUAJIT = shutil.which("luajit")
SOURCE = ROOT / "bin" / "putty.lua"


@unittest.skipUnless(LUAJIT, "requires LuaJIT")
class PuttyRegressions(unittest.TestCase):
    def lua(self, driver, registry=False):
        source = SOURCE.read_text(encoding="utf-8")
        source = source.split("\n", 1)[1].rsplit("main({...})", 1)[0]
        if registry:
            # Replace only the Registry API; console initialization stays real.
            source = "local registry_api = {}\n" + source.replace(
                "ffi.C.Reg", "registry_api.Reg"
            )
        return subprocess.run(
            [LUAJIT, "-"],
            input=source + driver,
            cwd=ROOT,
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=20,
        )

    def assert_lua_passed(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    @unittest.skipUnless(os.name == "nt", "requires Windows Registry FFI types")
    def test_registry_write_failure_closes_handle_and_preserves_error(self):
        result = self.lua(r'''
local closed = 0
local writes = 0
registry_api.RegOpenKeyExA = function(root, path, options, access, handle)
    assert(access == KEY_WRITE)
    handle[0] = ffi.cast("HKEY", 1)
    return 0
end
registry_api.RegSetValueExA = function()
    writes = writes + 1
    return 5
end
registry_api.RegCloseKey = function()
    closed = closed + 1
    return 0
end
local ok, err = apply_colors_to_session("review", PRESET_THEMES.dracula.colors)
assert(ok == false)
assert(err:find("Colour0", 1, true), err)
assert(err:find("Windows error 5", 1, true), err)
assert(writes == 1 and closed == 1)
''', registry=True)
        self.assert_lua_passed(result)

    @unittest.skipUnless(os.name == "nt", "requires Windows Registry FFI types")
    def test_registry_open_failure_includes_key_and_error(self):
        result = self.lua(r'''
registry_api.RegOpenKeyExA = function()
    return 2
end
local ok, err = apply_colors_to_session("missing", PRESET_THEMES.dracula.colors)
assert(ok == false)
assert(err:find("Sessions\\missing", 1, true), err)
assert(err:find("Windows error 2", 1, true), err)
''', registry=True)
        self.assert_lua_passed(result)

    def test_bulk_apply_reports_each_failed_session(self):
        result = self.lua(r'''
fetch_all_sessions = function()
    return {
        { name = "Default Settings" },
        { name = "denied" }
    }
end
apply_colors_to_session = function(name)
    if name == "denied" then
        return false, "Could not write Colour7 (Windows error 5: Access is denied.)"
    end
    return true
end
assert(cmd_colors({ "apply", "dracula", "--all" }) == false)
''')
        self.assert_lua_passed(result)
        self.assertIn("Updated 1 of 2 session(s).", result.stdout)
        self.assertIn("session 'denied'", result.stderr)
        self.assertIn("Colour7", result.stderr)
        self.assertIn("Windows error 5", result.stderr)


if __name__ == "__main__":
    unittest.main()
