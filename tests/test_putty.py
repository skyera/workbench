"""Exercise PuTTY exports and failure paths without changing saved sessions."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
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

    def test_session_encoding_matches_putty_registry_names(self):
        result = self.lua(r'''
local cases = {
    { "user@host", "user@host" },
    { "a+b", "a+b" },
    { "Default Settings", "Default%20Settings" },
    { ".host", "%2Ehost" },
    { "a.b", "a.b" },
    { "~host", "%7Ehost" },
    { "a\\b*?%", "a%5Cb%2A%3F%25" },
    { "tab\tname", "tab%09name" },
    { "caf\195\169", "caf%C3%A9" }
}
for _, case in ipairs(cases) do
    local encoded = encode_session_name(case[1])
    assert(encoded == case[2], encoded)
    assert(url_decode(encoded) == case[1])
end
''')
        self.assert_lua_passed(result)

    def test_bulk_apply_preserves_original_registry_key(self):
        result = self.lua(r'''
fetch_all_sessions = function()
    return {
        { name = "user@host", raw_name = "user%40host" },
        { name = "Default Settings", raw_name = "Default%20Settings" }
    }
end
local visited = 0
apply_colors_to_session = function(name, colors, raw_name)
    visited = visited + 1
    if name == "user@host" then
        assert(raw_name == "user%40host")
    else
        assert(raw_name == "Default%20Settings")
    end
    return true
end
cmd_colors({ "apply", "dracula", "--all" })
assert(visited == 2)
''')
        self.assert_lua_passed(result)

    @unittest.skipUnless(os.name == "nt", "requires Windows Registry FFI types")
    def test_apply_opens_canonical_or_preserved_registry_key(self):
        result = self.lua(r'''
local expected_path = "Software\\SimonTatham\\PuTTY\\Sessions\\user@host"
registry_api.RegOpenKeyExA = function(root, path, options, access, handle)
    assert(path == expected_path, path)
    handle[0] = ffi.cast("HKEY", 1)
    return 0
end
registry_api.RegSetValueExA = function()
    return 0
end
registry_api.RegCloseKey = function()
    return 0
end
assert(apply_colors_to_session("user@host", PRESET_THEMES.dracula.colors))
expected_path = "Software\\SimonTatham\\PuTTY\\Sessions\\user%40host"
assert(apply_colors_to_session("user@host", PRESET_THEMES.dracula.colors, "user%40host"))
''', registry=True)
        self.assert_lua_passed(result)

    def test_wsl_reads_actual_session_values_and_hex_dwords(self):
        result = self.lua(r'''
IS_WINDOWS = false
is_wsl = function()
    return true
end
run_wsl_registry = function(arguments)
    assert(arguments[1] == "query" and arguments[3] == "/s")
    return [[
HKEY_CURRENT_USER\Software\SimonTatham\PuTTY\Sessions

HKEY_CURRENT_USER\Software\SimonTatham\PuTTY\Sessions\user@host
    HostName    REG_SZ    actual.example.org
    PortNumber    REG_DWORD    0x8ae
    UserName    REG_SZ    actual-user
    Protocol    REG_SZ    ssh
    PublicKeyFile    REG_SZ    C:\Users\Test User\id.ppk
    AgentFwd    REG_DWORD    0x1

HKEY_CURRENT_USER\Software\SimonTatham\PuTTY\Sessions\Default%20Settings
    HostName    REG_SZ
]]
end
local sessions = assert(fetch_all_sessions())
assert(#sessions == 2)
local session = sessions[2]
assert(session.name == "user@host")
assert(session.raw_name == "user@host")
assert(session.host == "actual.example.org")
assert(session.port == "2222", session.port)
assert(session.user == "actual-user")
assert(session.key_file == "C:\\Users\\Test User\\id.ppk")
assert(session.agent_fwd == "1")
assert(sessions[1].host == "")
''')
        self.assert_lua_passed(result)

    def test_wsl_command_failure_preserves_command_and_diagnostic(self):
        result = self.lua(r'''
io.popen = function(command)
    assert(command:find("'review'\\''host'", 1, true), command)
    return {
        read = function()
            return "ERROR: Access is denied.\r\n\n__PUTTY_REG_STATUS__1\n"
        end,
        close = function()
            return true
        end
    }
end
local output, err = run_wsl_registry({ "query", "review'host" })
assert(output == nil)
assert(err:find("reg.exe 'query'", 1, true), err)
assert(err:find("status 1", 1, true), err)
assert(err:find("Access is denied.", 1, true), err)
''')
        self.assert_lua_passed(result)

    def test_wsl_apply_stops_on_failed_write(self):
        result = self.lua(r'''
IS_WINDOWS = false
is_wsl = function()
    return true
end
local calls = 0
run_wsl_registry = function(arguments)
    calls = calls + 1
    assert(arguments[2]:find("Sessions\\user%40host", 1, true))
    assert(arguments[4] == "Colour0")
    return nil, "reg.exe: access denied"
end
local ok, err = apply_colors_to_session(
    "user@host", PRESET_THEMES.dracula.colors, "user%40host"
)
assert(ok == false and calls == 1)
assert(err == "reg.exe: access denied")
''')
        self.assert_lua_passed(result)

    def test_wsl_query_failure_returns_diagnostic(self):
        result = self.lua(r'''
IS_WINDOWS = false
is_wsl = function()
    return true
end
run_wsl_registry = function()
    return nil, "reg.exe query: permission denied"
end
local sessions, err = fetch_all_sessions()
assert(sessions == nil)
assert(err == "reg.exe query: permission denied")
''')
        self.assert_lua_passed(result)

    def test_json_export_round_trips_controls_quotes_paths_and_unicode(self):
        result = self.lua(r'''
local control_characters = {}
for code = 0, 31 do
    table.insert(control_characters, string.char(code))
end
fetch_all_sessions = function()
    return {
        {
            name = table.concat(control_characters),
            host = "host\"quoted",
            key_file = "C:\\Users\\Test User\\key.ppk",
            user = "caf\195\169"
        },
        { name = "plain" }
    }
end
cmd_sessions({ "--json" })
''')
        self.assert_lua_passed(result)
        sessions = json.loads(result.stdout)
        self.assertEqual(sessions[0]["name"], "".join(chr(code) for code in range(32)))
        self.assertEqual(sessions[0]["host"], 'host"quoted')
        self.assertEqual(sessions[0]["key_file"], r"C:\Users\Test User\key.ppk")
        self.assertEqual(sessions[0]["user"], "café")
        self.assertEqual(sessions[1]["protocol"], "ssh")

    def test_json_export_empty_sessions(self):
        result = self.lua(r'''
fetch_all_sessions = function()
    return {}
end
cmd_sessions({ "--json" })
''')
        self.assert_lua_passed(result)
        self.assertEqual(json.loads(result.stdout), [])

    def test_ssh_export_quotes_values_and_openssh_accepts_spaced_key_path(self):
        result = self.lua(r'''
fetch_all_sessions = function()
    return {
        {
            name = "review-host",
            host = "example.org",
            user = "review",
            port = "2222",
            key_file = "C:\\Users\\Test User\\key.ppk"
        }
    }
end
cmd_sessions({ "--ssh-config" })
''')
        self.assert_lua_passed(result)
        self.assertIn('Host "review-host"', result.stdout)
        self.assertIn('    Port "2222"', result.stdout)
        self.assertIn(r'IdentityFile "C:\\Users\\Test User\\key.ppk"', result.stdout)

        if os.name == "nt":
            ssh = Path(os.environ.get("WINDIR", "C:/Windows")) / "System32/OpenSSH/ssh.exe"
        else:
            ssh = shutil.which("ssh")
        if not ssh or not Path(ssh).exists():
            self.skipTest("OpenSSH is unavailable for config parser verification")

        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            prefix=".putty-test-",
            suffix=".conf",
            dir=ROOT,
            delete=False,
        ) as temporary:
            temporary.write(result.stdout)
            config = Path(temporary.name)

        try:
            parsed = subprocess.run(
                [str(ssh), "-G", "-F", str(config), "review-host"],
                capture_output=True,
                text=True,
                encoding="utf-8",
                timeout=20,
            )
        finally:
            config.unlink()
        self.assertEqual(parsed.returncode, 0, parsed.stdout + parsed.stderr)
        self.assertIn("hostname example.org", parsed.stdout)
        self.assertIn("port 2222", parsed.stdout)
        self.assertIn("Test User", parsed.stdout)

    def test_ssh_export_escapes_quotes_and_preserves_spaced_alias(self):
        result = self.lua(r'''
local config = assert(render_ssh_config({
    {
        name = "My server",
        host = "example.org",
        key_file = "path\\with\"quote"
    }
}))
assert(config:find('Host "My server"', 1, true), config)
assert(config:find('IdentityFile "path\\\\with\\"quote"', 1, true), config)
''')
        self.assert_lua_passed(result)

    def test_ssh_export_rejects_control_characters_without_partial_output(self):
        result = self.lua(r'''
fetch_all_sessions = function()
    return {
        { name = "valid", host = "example.org" },
        { name = "invalid", host = "example.org\nProxyCommand injected" }
    }
end
assert(cmd_sessions({ "--ssh-config" }) == false)
''')
        self.assert_lua_passed(result)
        self.assertEqual(result.stdout, "")
        self.assertIn('HostName for session "invalid"', result.stderr)
        self.assertIn("control characters", result.stderr)


if __name__ == "__main__":
    unittest.main()
