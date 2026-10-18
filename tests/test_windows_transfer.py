"""Windows transfer argument tests, including a native test on Windows hosts."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
LUAJIT = shutil.which("luajit")


def lua_string(value):
    # Lua long strings preserve Windows paths and UTF-8 without JSON's \u escapes.
    separator = "="
    while "]" + separator + "]" in value:
        separator += "="
    return "[" + separator + "[" + value + "]" + separator + "]"


def run_driver(driver):
    source = (ROOT / "bin/fscp.lua").read_text(encoding="utf-8").rsplit("main(...)", 1)[0]
    return subprocess.run([LUAJIT, "-"], input=source + driver,
                          capture_output=True, text=True, encoding="utf-8", timeout=20)


@unittest.skipUnless(LUAJIT, "requires LuaJIT")
class WindowsTransferTests(unittest.TestCase):
    def test_windows_argument_quoting(self):
        cases = [
            ("", '""'),
            ("a b", '"a b"'),
            ("%PATH%!TEMP!&|<>^", '"%PATH%!TEMP!&|<>^"'),
            ('say "hello"', '"say \\"hello\\""'),
            ("C:\\dir with space\\", '"C:\\dir with space\\\\"'),
            ('a\\"b', '"a\\\\\\"b"'),
            ("café.txt", '"café.txt"'),
        ]
        driver = "\n".join(
            "assert(windows_quote_arg(" + lua_string(value) + ") == "
            + lua_string(expected) + ", 'Windows argument quoting mismatch')"
            for value, expected in cases
        )
        result = run_driver(driver)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_windows_spawn_bypasses_shell_and_reports_launch_errors(self):
        # Model the Win32/CRT boundary on any OS. This checks dispatch, UTF-16
        # buffer lifetimes, argument construction, exit status, and diagnostics;
        # it does not substitute for the native Windows test below.
        result = run_driver(r'''
IS_WINDOWS = true
local captured, exit_status = {}, 17
ffi = {
    C = {
        MultiByteToWideChar = function(_, _, value, length, dest)
            if dest then dest.value = value end
            return length
        end,
    },
    new = function() return {} end,
    string = function(value) return value end,
}
msvcrt = {
    _wspawnvp = function(mode, command, argv)
        assert(mode == 0 and command.value == "scp.exe")
        for i = 0, 3 do captured[i] = argv[i].value end
        assert(argv[4] == nil, "argv must be NULL terminated")
        return exit_status
    end,
    _errno = function() return {[0]=2} end,
    strerror = function(code) assert(code == 2); return "No such file or directory" end,
}
os.execute = function() error("Windows transfers must not invoke a shell") end
local args = {"scp", "%PATH%!TEMP!& report.txt", "", "C:\\trailing\\"}
local status, err = run_transfer(args)
assert(status == 17 and err == nil)
for i, value in ipairs(args) do assert(captured[i-1] == windows_quote_arg(value)) end
exit_status = -1
status, err = run_transfer(args)
assert(status == nil and err:find("No such file or directory", 1, true))
assert(err:find("PATH", 1, true))
''')
        self.assertEqual(result.returncode, 0, result.stderr)

    @unittest.skipUnless(os.name == "nt", "requires native Windows")
    def test_native_windows_arguments_and_exit_status(self):
        with tempfile.TemporaryDirectory(prefix="fscp-windows-") as temp:
            output = Path(temp) / "argv.json"
            values = ["%PATH%", "!TEMP!", "a&b|c", "space name.txt", 'a"b',
                      "C:\\trailing\\", "café.txt", ""]
            code = "import json,sys;open(sys.argv[1],'w',encoding='utf-8').write(json.dumps(sys.argv[2:]));sys.exit(17)"
            args = [sys.executable, "-c", code, str(output), *values]
            driver = "local status, err = run_transfer({" + ",".join(map(lua_string, args)) + "})\n"
            driver += "assert(status == 17, err or tostring(status))\n"
            driver += 'local status, err = run_transfer({"fscp-missing-tool-97b61.exe"})\n'
            driver += 'assert(status == nil and err:find("Cannot launch", 1, true), err)\n'
            result = run_driver(driver)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(output.read_text(encoding="utf-8")), values)


if __name__ == "__main__":
    unittest.main()
