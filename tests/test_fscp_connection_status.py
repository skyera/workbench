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


if __name__ == "__main__":
    unittest.main()
