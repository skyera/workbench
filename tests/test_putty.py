"""Exercise PuTTY exports and failure paths without changing saved sessions."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


# ------------------------------------------------------------------------------
# Paths and runtime
# ------------------------------------------------------------------------------
ROOT = Path(__file__).resolve().parents[1]
LUAJIT = shutil.which("luajit")
SOURCE = ROOT / "bin" / "fputty.lua"


@unittest.skipUnless(LUAJIT, "requires LuaJIT")
class PuttyRegressions(unittest.TestCase):
    # --------------------------------------------------------------------------
    # Isolated Lua harness
    # --------------------------------------------------------------------------
    def lua(self, driver, registry=False, env=None):
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
            env=env,
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=20,
        )

    def assert_lua_passed(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def cli(self, *arguments):
        return subprocess.run(
            [LUAJIT, str(SOURCE), *arguments],
            cwd=ROOT,
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=20,
        )

    # --------------------------------------------------------------------------
    # Registry writes and bulk application
    # --------------------------------------------------------------------------

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

    # --------------------------------------------------------------------------
    # Session name encoding
    # --------------------------------------------------------------------------
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

    # --------------------------------------------------------------------------
    # WSL Registry bridge
    # --------------------------------------------------------------------------
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

    # --------------------------------------------------------------------------
    # JSON and OpenSSH exports
    # --------------------------------------------------------------------------
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
        self.assertIn(r"identityfile C:\Users\Test User\key.ppk", parsed.stdout)

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

    # --------------------------------------------------------------------------
    # Theme discovery
    # --------------------------------------------------------------------------
    def test_home_themes_are_discovered_without_appdata(self):
        result = self.lua(r'''
get_repo_dir = function()
    return "/fixture/repo"
end
os.getenv = function(name)
    if name == "HOME" then
        return "/fixture/home"
    end
end
local home_directory = "/fixture/home/.config/putty/themes"
local home_checked = false
dir_exists = function(path)
    if path == home_directory then
        home_checked = true
        return true
    end
    return false
end
io.popen = function()
    return {
        lines = function()
            local yielded = false
            return function()
                if not yielded then
                    yielded = true
                    return home_directory .. "/review-theme.reg"
                end
            end
        end,
        close = function()
            return true
        end
    }
end
parse_reg_file = function(path)
    assert(path == home_directory .. "/review-theme.reg")
    return PRESET_THEMES.dracula.colors
end
local themes = load_all_themes()
assert(home_checked)
assert(themes["review-theme"].path == home_directory .. "/review-theme.reg")
''')
        self.assert_lua_passed(result)

    # --------------------------------------------------------------------------
    # CLI errors, file failures, and launcher exit status
    # --------------------------------------------------------------------------
    @unittest.skipUnless(os.name == "nt", "requires Windows Registry FFI types")
    def test_registry_reader_distinguishes_denied_access_from_missing_root(self):
        result = self.lua(r'''
registry_api.RegOpenKeyExA = function()
    return 5
end
local sessions, err = fetch_all_sessions()
assert(sessions == nil)
assert(err:find("Windows error 5", 1, true), err)
registry_api.RegOpenKeyExA = function()
    return 2
end
sessions = assert(fetch_all_sessions())
assert(#sessions == 0)
''', registry=True)
        self.assert_lua_passed(result)

    @unittest.skipUnless(os.name == "nt", "requires Windows Registry FFI types")
    def test_registry_reader_closes_handles_on_query_failure(self):
        result = self.lua(r'''
local closed = 0
local queries = 0
registry_api.RegOpenKeyExA = function(root, path, options, access, handle)
    handle[0] = ffi.cast("HKEY", 1)
    return 0
end
registry_api.RegEnumKeyExA = function(root, index, buffer, length)
    if index > 0 then
        return 259
    end
    ffi.copy(buffer, "review")
    length[0] = 6
    return 0
end
registry_api.RegQueryValueExA = function()
    queries = queries + 1
    return 5
end
registry_api.RegCloseKey = function()
    closed = closed + 1
    return 0
end
local sessions, err = fetch_all_sessions()
assert(sessions == nil and closed == 2 and queries == 1)
assert(err:find("HostName", 1, true), err)
assert(err:find("Windows error 5", 1, true), err)
''', registry=True)
        self.assert_lua_passed(result)

    @unittest.skipUnless(os.name == "nt", "requires Windows Registry FFI types")
    def test_registry_reader_reports_enumeration_failure(self):
        result = self.lua(r'''
local closed = false
registry_api.RegOpenKeyExA = function(root, path, options, access, handle)
    handle[0] = ffi.cast("HKEY", 1)
    return 0
end
registry_api.RegEnumKeyExA = function()
    return 234
end
registry_api.RegCloseKey = function()
    closed = true
    return 0
end
local sessions, err = fetch_all_sessions()
assert(sessions == nil and closed)
assert(err:find("enumerate", 1, true), err)
assert(err:find("Windows error 234", 1, true), err)
''', registry=True)
        self.assert_lua_passed(result)

    def test_invalid_arguments_exit_nonzero_with_diagnostics(self):
        cases = [
            (("unknown-command",), "Unknown command"),
            (("sessions", "--unknown"), "Unknown sessions option"),
            (("sessions", "--json", "--ssh-config"), "Choose either"),
            (("colors", "unknown-subcommand"), "Unknown colors subcommand"),
            (("colors", "list", "--unknown"), "does not accept arguments"),
            (("colors", "preview"), "Usage:"),
            (("colors", "preview", "review-no-such-theme"), "not found"),
            (("colors", "apply"), "Usage:"),
            (("colors", "apply", "review-no-such-theme"), "Unknown theme"),
            (("colors", "apply", "dracula", "--session"), "requires a session name"),
            (("colors", "apply", "dracula", "--unknown"), "Unexpected apply argument"),
            (("colors", "export"), "Usage:"),
            (("colors", "export", "review-no-such-theme"), "not found"),
            (("colors", "export", "dracula", "--output"), "requires an output filename"),
            (("colors", "export", "dracula", "--session"), "requires a session name"),
        ]
        for arguments, diagnostic in cases:
            with self.subTest(arguments=arguments):
                result = self.cli(*arguments)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(diagnostic, result.stderr)
                self.assertNotIn("stack traceback", result.stderr)

    def test_help_and_preview_exit_successfully(self):
        for arguments in [
            ("--help",),
            ("sessions", "--help"),
            ("colors", "--help"),
            ("colors", "preview", "dracula", "--raw"),
        ]:
            with self.subTest(arguments=arguments):
                result = self.cli(*arguments)
                self.assert_lua_passed(result)
                self.assertTrue(result.stdout)

    def test_failed_apply_and_query_propagate_to_process_exit(self):
        cases = [
            r'''
apply_colors_to_session = function()
    return false, "Could not write Colour0: access denied"
end
main({ "colors", "apply", "dracula" })
''',
            r'''
fetch_all_sessions = function()
    return nil, "Could not query registry: access denied"
end
main({ "sessions", "--json" })
''',
            r'''
fetch_all_sessions = function()
    return { { name = "Default Settings" } }
end
apply_colors_to_session = function()
    return false, "Could not write Colour0: access denied"
end
main({ "colors", "apply", "dracula", "--all" })
''',
        ]
        for driver in cases:
            with self.subTest(driver=driver):
                result = self.lua(driver)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("access denied", result.stderr)

    def test_file_write_and_close_errors_are_preserved(self):
        result = self.lua(r'''
local closed = 0
io.open = function()
    return {
        write = function()
            return nil, "disk full"
        end,
        close = function()
            closed = closed + 1
            return true
        end
    }
end
local ok, err = write_text_file("review.reg", "data")
assert(ok == false and closed == 1)
assert(err:find("disk full", 1, true), err)
io.open = function()
    return {
        write = function()
            return true
        end,
        close = function()
            return nil, "flush failed"
        end
    }
end
ok, err = write_text_file("review.reg", "data")
assert(ok == false)
assert(err:find("flush failed", 1, true), err)
''')
        self.assert_lua_passed(result)

    def test_export_open_failure_exits_nonzero_with_system_error(self):
        result = self.lua(r'''
load_all_themes = function()
    return PRESET_THEMES
end
io.open = function()
    return nil, "permission denied"
end
main({ "colors", "export", "dracula", "--output", "review.reg" })
''')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("review.reg: permission denied", result.stderr)
        self.assertNotIn("Exported", result.stdout)

    def test_missing_fzf_exits_nonzero_with_install_guidance(self):
        result = self.lua(r'''
load_all_themes = function()
    return PRESET_THEMES
end
os.execute = function()
    return 1
end
main({ "colors" })
''')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Install fzf", result.stderr)

    def test_export_writes_all_colors_and_canonical_session_key(self):
        with tempfile.NamedTemporaryFile(prefix=".putty-test-", suffix=".reg", dir=ROOT,
                                         delete=False) as temporary:
            output = Path(temporary.name)
        try:
            result = self.cli("colors", "export", "dracula", "-s", "user@host", "-o", str(output))
            self.assert_lua_passed(result)
            exported = output.read_text(encoding="utf-8")
        finally:
            output.unlink()
        self.assertIn("Sessions\\user@host]", exported)
        self.assertEqual(exported.count('"Colour'), 22)
        self.assertIn('"Colour21"="255,255,255"', exported)

    @unittest.skipIf(os.name == "nt", "requires POSIX session files")
    def test_linux_apply_preserves_settings_and_replaces_colors(self):
        with tempfile.TemporaryDirectory(prefix="putty test-") as temporary:
            session_directory = Path(temporary) / ".putty" / "sessions"
            session_directory.mkdir(parents=True)
            session_file = session_directory / "user@host"
            session_file.write_text(
                "HostName=actual.example.org\nPortNumber=2222\nColour0=0,0,0\n",
                encoding="utf-8",
            )
            env = dict(os.environ, HOME=temporary)
            result = self.lua(r'''
IS_WINDOWS = false
is_wsl = function()
    return false
end
local ok, err = apply_colors_to_session("user@host", PRESET_THEMES.dracula.colors)
assert(ok, err)
local sessions = assert(fetch_all_sessions())
assert(#sessions == 1 and sessions[1].host == "actual.example.org")
assert(sessions[1].port == "2222")
''', env=env)
            self.assert_lua_passed(result)
            contents = session_file.read_text(encoding="utf-8")
        self.assertIn("HostName=actual.example.org", contents)
        self.assertEqual(contents.count("Colour0="), 1)
        self.assertEqual(contents.count("Colour"), 22)
        self.assertIn("Colour0=248,248,242", contents)

    @unittest.skipUnless(os.name == "nt", "requires Windows batch launchers")
    def test_windows_launchers_preserve_failure_and_success_status(self):
        launchers = [
            ("fputty.bat", ["colors", "preview", "review-no-such-theme"], ["--help"]),
            ("putty_colors.bat", ["preview", "review-no-such-theme"], ["--help"]),
            ("putty_sessions.bat", ["--unknown"], ["--help"]),
        ]
        for launcher, failure_args, success_args in launchers:
            for arguments, expected_status in [(failure_args, 1), (success_args, 0)]:
                with self.subTest(launcher=launcher, arguments=arguments):
                    result = subprocess.run(
                        ["cmd.exe", "/d", "/c", str(ROOT / "bin" / launcher), *arguments],
                        capture_output=True,
                        text=True,
                        encoding="utf-8",
                        timeout=20,
                    )
                    self.assertEqual(result.returncode, expected_status, result.stdout + result.stderr)


    def test_interactive_colors_cancels_cleanly_without_registry_writes(self):
        result = self.lua(r'''
local writes = 0
apply_colors_to_session = function()
    writes = writes + 1
    return true
end
local original_popen = io.popen
io.popen = function(cmd)
    if cmd:find("fzf", 1, true) then
        return {
            read = function() return nil end,
            close = function() return nil, "exit", 130 end,
        }
    end
    return original_popen(cmd)
end
os.execute = function() return 0 end
local res = cmd_colors({})
assert(res == true, "cmd_colors should return true on cancellation")
assert(writes == 0, "apply_colors_to_session must not be called when fzf is cancelled")
''')
        self.assert_lua_passed(result)

    def test_interactive_colors_applies_default_on_enter_and_all_on_ctrla(self):
        result = self.lua(r'''
local applied_targets = {}
apply_colors_to_session = function(target)
    table.insert(applied_targets, target)
    return true
end
local mock_output = { key = "", selected = "dracula" }
local original_popen = io.popen
io.popen = function(cmd)
    if cmd:find("fzf", 1, true) then
        local read_count = 0
        return {
            read = function()
                read_count = read_count + 1
                if read_count == 1 then return mock_output.key end
                if read_count == 2 then return mock_output.selected end
                return nil
            end,
            close = function() return true end,
        }
    end
    return original_popen(cmd)
end
os.execute = function() return 0 end

-- 1. Normal Enter -> Default Settings
mock_output.key = ""
mock_output.selected = "dracula"
cmd_colors({})
assert(#applied_targets == 1 and applied_targets[1] == "Default Settings")

-- 2. Ctrl-A -> ALL sessions (adds session1, session2, plus Default Settings)
fetch_all_sessions = function()
    return { { name = "session1", raw_name = "session1" }, { name = "session2", raw_name = "session2" } }
end
mock_output.key = "ctrl-a"
mock_output.selected = "dracula"
cmd_colors({})
assert(#applied_targets == 4)
assert(applied_targets[2] == "session1" and applied_targets[3] == "session2" and applied_targets[4] == "Default Settings")
''')
        self.assert_lua_passed(result)


if __name__ == "__main__":
    unittest.main()
