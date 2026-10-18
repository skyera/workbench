"""Local client/protocol checks; no saved SSH hosts are contacted."""

import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LUAJIT = shutil.which("luajit")


def lua_string(value):
    delimiter = "="
    while "]" + delimiter + "]" in str(value):
        delimiter += "="
    return "[" + delimiter + "[" + str(value) + "]" + delimiter + "]"


@unittest.skipUnless(LUAJIT, "requires LuaJIT")
class RemoteClientTests(unittest.TestCase):
    def driver(self, code):
        path = ROOT / "bin/fremote.lua"
        source = path.read_text(encoding="utf-8").rsplit("-- Command-line entry point.", 1)[0]
        source = "arg[0]=" + lua_string(path) + "\n" + source.split("\n", 1)[1] + code
        result = subprocess.run(
            [LUAJIT, "-"],
            input=source,
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_native_pipes_preserve_arguments_stdin_output_and_exit_status(self):
        values = ["%PATH%!TEMP!&|<>^", "", 'a"b', "C:\\space name\\", "café 中"]
        payload = "\t".join(values) + "\n"
        python = """
import sys

arguments = "\\t".join(sys.argv[1:]) + "\\n"
sys.stdout.buffer.write(arguments.encode("utf-8"))
sys.stdout.buffer.write(sys.stdin.buffer.readline())
sys.stderr.write("permission denied\\n")
sys.stdout.buffer.write(b"x" * 20000)
sys.exit(17)
"""
        args = [sys.executable, "-u", "-c", python, *values]
        self.driver(
            "local args={"
            + ",".join(map(lua_string, args))
            + "}\n"
            + "local expected="
            + lua_string(payload)
            + r"""
local child, err = native.spawn(args)
assert(child, err)
assert(child:write('request\n'))
local out, errors = '', ''
local deadline = native.now() + 8
while native.now() < deadline do
    out = out .. child:read('stdout')
    errors = errors .. child:read('stderr')
    if child:status() ~= nil then
        for _ = 1, 10 do
            out = out .. child:read('stdout')
            errors = errors .. child:read('stderr')
        end
        break
    end
    native.sleep(10)
end
assert(child:status() == 17, 'child exit status')
child:close()
child:close()
assert(out == expected .. 'request\n' .. string.rep('x', 20000), 'argv/stdin/large output mismatch')
assert(errors:find('permission denied', 1, true), errors)
"""
        )

    def test_missing_executable_diagnostic(self):
        self.driver(
            r"""
local out, err = capture({ 'fremote-nonexistent-command-97b61' }, 3)
assert(out == nil and err and #err > 0)
assert(err:find('fremote-nonexistent-command-97b61', 1, true), err)
"""
        )

    @unittest.skipUnless(sys.platform.startswith("linux"), "live collector requires Linux")
    def test_live_collector_stream_details_and_disconnect_keep_last_snapshot(self):
        collector = (ROOT / "bin/fremote_collector.py").read_text(encoding="utf-8")
        self.driver(
            "local collector="
            + lua_string(collector)
            + "\n"
            + r"""
local sshargs = build_ssh({ host = 'local-test', interval = 0.2 }, collector)
-- Exercise the exact remote shell command without contacting a saved server.
local args = { '/bin/sh', '-c', sshargs[#sshargs] }
local state = new_state({ interval = 0.2, host = 'local-test' })
state.child = assert(native.spawn(args))
state.started = native.now()
local deadline = native.now() + 5
while not state.ever and native.now() < deadline do
    pump(state)
    native.sleep(10)
end
assert(state.ever and #state.rows > 0 and fresh(state), state.errors)
local selected = state.visible[state.cursor]
request_detail(state)
while not state.details[identity(selected)] and native.now() < deadline do
    pump(state)
    native.sleep(10)
end
assert(state.details[identity(selected)], 'Missing selected process detail')
send(state, 'SIGNAL\t' .. selected.pid .. '\t' .. (selected.start + 1) .. '\t15')
while not state.status_error and native.now() < deadline do
    pump(state)
    native.sleep(10)
end
assert(state.status_error and state.status:find('PID was reused', 1, true), state.status)
assert(send(state, 'QUIT'))
while state.child and native.now() < deadline do
    pump(state)
    native.sleep(10)
end
assert(
    not state.connected and not state.child and #state.rows > 0,
    'Keep last snapshot on disconnect'
)
"""
        )

    def test_ssh_arguments_preserve_config_jump_host_and_remote_script(self):
        self.driver(
            r"""
local args = build_ssh(
    {
        host = 'review@centre',
        interval = 2,
        port = '2222',
        key = 'C:\\my key',
        jump = 'bastion',
        config = 'my config',
    },
    "print('hello')\n"
)
assert(args[1] == 'ssh' and args[#args - 1] == 'review@centre')
assert(args[#args]:find("python3 -u -c '", 1, true) == 1)
assert(args[#args]:find("'\\''", 1, true), 'Quote remote shell single quotes')
local values = {}
for i = 1, #args - 1 do
    values[args[i]] = args[i + 1]
end
assert(values['-i'] == 'C:\\my key' and values['-J'] == 'bastion' and values['-F'] == 'my config')
assert(values['-p'] == '2222')
"""
        )

    @unittest.skipUnless(sys.platform.startswith("linux"), "PTY checks require Linux")
    def test_interactive_filter_resize_and_terminal_restore(self):
        import fcntl
        import pty
        import select
        import struct
        import termios

        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
        process = subprocess.Popen(
            [LUAJIT, str(ROOT / "bin/fremote.lua"), "--demo"],
            stdin=slave,
            stdout=slave,
            stderr=slave,
        )
        os.close(slave)
        output = bytearray()

        def wait_for(marker):
            deadline = time.monotonic() + 5
            while marker not in output and time.monotonic() < deadline:
                if select.select([master], [], [], 0.1)[0]:
                    output.extend(os.read(master, 65536))
            self.assertIn(marker, output)

        try:
            wait_for(b"FREMOTE")
            os.write(master, b"/python\rt")
            wait_for(b"2 matching / 3 processes")
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 10, 40, 0, 0))
            wait_for(b"terminal too small")
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 120, 0, 0))
            os.write(master, b"q")
            process.wait(timeout=5)
            while select.select([master], [], [], 0.1)[0]:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                output.extend(chunk)
            self.assertEqual(process.returncode, 0)
            self.assertIn(b"\x1b[?1049l", output)
            self.assertIn(b"\x1b[?25h", output)
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)
            os.close(master)

    @unittest.skipUnless(sys.platform.startswith("linux"), "local shell fixture requires Linux")
    def test_list_entry_point_with_local_ssh_transport_fixture(self):
        with tempfile.TemporaryDirectory(prefix="fremote-ssh-") as temp:
            stub = Path(temp) / "ssh"
            stub.write_text(
                "#!/usr/bin/env python3\nimport os,sys\n"
                "assert sys.argv[-2] == 'fixture-only'\n"
                "os.execl('/bin/sh', 'sh', '-c', sys.argv[-1])\n",
                encoding="utf-8",
            )
            stub.chmod(0o755)
            env = dict(os.environ, PATH=temp + os.pathsep + os.environ["PATH"])
            result = subprocess.run(
                [LUAJIT, str(ROOT / "bin/fremote.lua"), "fixture-only", "--list"],
                env=env,
                capture_output=True,
                text=True,
                encoding="utf-8",
                timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PID\tCPU%\tRAM\tUSER\tNAME", result.stdout)
            self.assertGreater(len(result.stdout.splitlines()), 1)

    def test_state_selection_confirmation_staleness_and_rendering(self):
        self.driver(
            r"""
local state = new_state({ interval = 2, host = 'centre' })
demo(state)
local writes = {}
state.child = {
    write = function(_, line)
        writes[#writes + 1] = line
        return true
    end,
}
state.status = 'Connected'
begin_signal(state, 15)
assert(state.mode == 'confirm' and state.confirm.targets[1].pid == 18432 and #writes == 0)
handle(state, 'n', '')
assert(state.mode == 'normal' and #writes == 0)
begin_signal(state, 9)
handle(state, 'y', '')
assert(writes[1] == 'SIGNAL\t18432\t101\t9\n')
begin_signal(state, 15)
state.last = native.now() - 20
handle(state, 'y', '')
assert(#writes == 1 and state.status:find('stale', 1, true))
begin_signal(state, 15)
assert(state.mode == 'normal')
local lines = frame(state, 100, 30)
assert(table.concat(lines):find('DISCONNECTED / STALE', 1, true))
state.last = native.now()
state.connected = true
state.query = 'python'
refilter(state)
assert(#state.visible == 2)
handle(state, ' ', '')
assert(state.marked['18432:101'])
state.rows[1].name = 'renamed'
state.sort = 'pid'
refilter(state)
assert(state.visible[state.cursor].pid == 18432)
state.mode = 'search'
state.query = 'café'
handle(state, 'backspace', '')
assert(state.query == 'caf')
handle(state, 'backspace', '')
assert(state.query == 'ca')
state.mode = 'normal'
state.query = ''
refilter(state)
for _, width in ipairs({ 40, 76, 100, 160 }) do
    local frame_lines = frame(state, width, 30)
    for _, line in ipairs(frame_lines) do
        local plain = line:gsub('\27%[[%d;]*m', '')
        assert(#plain <= width - 1 or width < 76, plain)
    end
end
assert(not fit('bad\27[2J\r\nname', 40):find('\27', 1, true))
assert(fit('中a', 3) == '中a')
local snapshot = 'H\t1\t100\t1000\t100\t50\t1\t30'
consume(state, snapshot)
consume(state, 'P\t18432\t1\t999\t0\t1\t1\tS\t1000\t1\t75\t6e')
consume(state, 'E')
assert(not state.marked['18432:101'], 'PID reuse must clear marks')
assert(state.visible[state.cursor].start == 999)
"""
        )

    def test_cli_help_self_test_demo_and_invalid_options(self):
        path = str(ROOT / "bin/fremote.lua")
        for args in (["--help"], ["--test"], ["--demo", "--list"]):
            result = subprocess.run(
                [LUAJIT, path, *args], capture_output=True, text=True, encoding="utf-8", timeout=20
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for args in (["--interval", "0"], ["--sort", "bad"], ["--list"], ["--unknown"], ["-i"]):
            result = subprocess.run(
                [LUAJIT, path, *args], capture_output=True, text=True, encoding="utf-8", timeout=20
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("fremote:", result.stderr)


if __name__ == "__main__":
    unittest.main()
