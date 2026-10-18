"""Connection status transitions without SSH connections or an interactive TUI."""

from pathlib import Path
import shutil
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
LUAJIT = shutil.which("luajit")


@unittest.skipUnless(LUAJIT, "requires LuaJIT")
class ConnectionStatusTests(unittest.TestCase):
    def test_network_success_failure_recovery_and_cached_refresh(self):
        source = (ROOT / "bin/fscp.lua").read_text(encoding="utf-8")
        source = source.rsplit("main(...)", 1)[0]
        driver = r'''
-- Use a resolved directory so refresh does not invoke the home-directory probe.
App.host_cfg = {name="centre", hostname="192.0.2.1", source="ssh-config"}
App.right.dir = "/home/review"
local listing = {{name="report.txt", size=12, is_dir=false}}
local failure = nil
local expected_dir = "/home/review"
list_remote_directory = function(host, dir)
    assert(host == App.host_cfg and dir == expected_dir)
    return listing, failure
end
App.status_msg = "Connecting to centre..."
App.status_color = C.bright_cyan
App.refresh_right(true)
assert(App.connected and App.conn_error == nil)
assert(App.right.items == listing)
assert(App.status_msg == "Connected to centre: /home/review", App.status_msg)
assert(App.status_color == C.bright_green)

failure = "Permission denied (publickey)."
App.active_pane = "right"
App.draw = function() end
App.handle_input("r")
assert(not App.connected and App.conn_error == failure)
assert(#App.right.items == 0 and App.right.cursor == 1)
assert(App.status_msg == "Remote error: " .. failure, App.status_msg)
assert(App.status_color == C.red)

failure = nil
App.handle_input("r")
assert(App.connected and App.conn_error == nil)
assert(App.status_msg == "Connected to centre: /home/review", App.status_msg)
assert(App.status_color == C.bright_green)

expected_dir = "/home/review/reports"
App.right.dir = expected_dir
App.refresh_right(false)
assert(App.status_msg == "Connected to centre: /home/review/reports", App.status_msg)

App.modal = "host_picker"
App.status_msg = "Select a remote server to connect."
App.status_color = C.bright_yellow
App.refresh_right(false)
assert(App.status_msg == "Select a remote server to connect.")
assert(App.status_color == C.bright_yellow)
'''
        result = subprocess.run(
            [LUAJIT, "-"], input=source + driver, capture_output=True,
            text=True, encoding="utf-8", timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_parse_ls_line_active_directory_and_formats(self):
        source = (ROOT / "bin/fscp.lua").read_text(encoding="utf-8")
        source = source.rsplit("main(...)", 1)[0]
        driver = r'''
local lines = {
    "drwxrwxr-x 2 alice Domain Users 4096 2026-10-18 09:30:00 shared_dept",
    "drwxrwxr-x 2 DOMAIN\\alice DOMAIN\\Domain Admins 8192 2026-10-18 09:30:00 admin_dept",
    "drwxr-xr-x 2 user Domain Users 4096 Oct 18  2024 archive_dept",
    "drwxr-xr-x@ 4 user staff 128 Oct 18 09:30 macos_dept",
    "lrwxrwxrwx 1 user group 14 2026-10-18 09:30:00 symlink_dept -> /mnt/target",
    "-rw-r--r-- 1 alice Domain Users 123456 2026-10-18 09:30:00 report.pdf",
}
local items = {}
for _, line in ipairs(lines) do
    local it = parse_ls_line(line)
    if it then table.insert(items, it) end
end
assert(#items == 6, "Expected 6 parsed items, got " .. #items)
assert(items[1].name == "shared_dept" and items[1].is_dir == true)
assert(items[2].name == "admin_dept" and items[2].is_dir == true)
assert(items[3].name == "archive_dept" and items[3].is_dir == true)
assert(items[4].name == "macos_dept" and items[4].is_dir == true)
assert(items[5].name == "symlink_dept" and items[5].is_dir == true)
assert(items[6].name == "report.pdf" and items[6].is_dir == false and items[6].size == 123456)
'''
        result = subprocess.run(
            [LUAJIT, "-"], input=source + driver, capture_output=True,
            text=True, encoding="utf-8", timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_live_remote_command_construction(self):
        source = (ROOT / "bin/fscp.lua").read_text(encoding="utf-8")
        source = source.rsplit("main(...)", 1)[0]
        driver = r'''
local captured = nil
local orig_popen = io.popen
io.popen = function(cmd)
    captured = cmd
    return {
        read = function() return "drwxr-xr-x 2 user group 4096 2026-10-18 09:30 dir1\n__FSCP_EXIT__:0" end,
        close = function() end,
    }
end
local host = {name="node1", hostname="10.0.0.1", user="deploy", port="22", is_demo=false}
local items, err = list_remote_directory(host, "/var/data")
io.popen = orig_popen
assert(err == nil, "Error should be nil: " .. tostring(err))
assert(captured and captured:find("--time-style=+%Y-%m-%d", 1, true), "Command must contain time-style format string")
assert(captured:find("'/var/data/'"), "Remote path must contain trailing slash")
'''
        result = subprocess.run(
            [LUAJIT, "-"], input=source + driver, capture_output=True,
            text=True, encoding="utf-8", timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
