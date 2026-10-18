"""Run with: python3 -m unittest discover -s tests -v

Exercise the real Lua code with temporary Git repositories and transfer stubs.
No SSH connections or changes to the caller's repository are made.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
LUAJIT = shutil.which("luajit")


@unittest.skipUnless(LUAJIT and shutil.which("git") and os.name == "posix",
                     "requires LuaJIT, Git, and POSIX executable stubs")
class BinRegressions(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="bin-regression-")
        self.addCleanup(self.temp.cleanup)
        self.cwd = Path(self.temp.name)
        self.env = dict(os.environ, HOME=str(self.cwd), LC_ALL="C",
                        PATH=str(self.cwd) + os.pathsep + os.environ["PATH"])
        self.capture = self.cwd / "arguments.json"
        self.env["REVIEW_ARGV_FILE"] = str(self.capture)
        for name in ("rsync", "scp"):
            stub = self.cwd / name
            stub.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, sys\n"
                "with open(os.environ['REVIEW_ARGV_FILE'], 'w') as f:\n"
                "    json.dump(sys.argv[1:], f)\n"
            )
            stub.chmod(0o755)

    def lua(self, name, *args, driver=None):
        command = [LUAJIT, str(ROOT / "bin" / (name + ".lua")), *args]
        source = None
        if driver is not None:
            # Expose the existing local engine to a test driver without changing
            # the production entry point or launching the interactive UI.
            source = (ROOT / "bin" / (name + ".lua")).read_text()
            entry = "main(...)" if name == "fscp" else "main(arg)"
            source = source.rsplit(entry, 1)[0] + driver
            command = [LUAJIT, "-"]
        return subprocess.run(command, input=source, cwd=self.cwd, env=self.env,
                              text=True, capture_output=True, timeout=20)

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.cwd, env=self.env,
                              text=True, capture_output=True, check=True).stdout

    def init_repo(self):
        self.git("init", "-q", "-b", "master")
        self.git("config", "user.name", "Review")
        self.git("config", "user.email", "review@example.invalid")
        (self.cwd / "file").write_text("initial\n")
        self.git("add", "file")
        self.git("commit", "-qm", "initial")

    def test_headless_scp_identity_and_filenames_are_raw_arguments(self):
        key = str(self.cwd / "my key's identity")
        filename = "quarterly report; literal.txt"
        result = self.lua("fscp", "--scp", "-H", "review-host", "-i", key,
                          "-t", "/remote dir", filename)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.capture.read_text()),
                         ["-r", "-i", key, filename, "review-host:/remote dir"])

    def test_headless_rsync_remote_shell_has_no_outer_quotes(self):
        result = self.lua("fscp", "--rsync", "-H", "review-host", "-p", "2222",
                          "quarterly report.txt")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.capture.read_text()),
                         ["-avzP", "-e", "ssh -p 2222", "quarterly report.txt",
                          "review-host:~/"])

    def test_headless_rsync_pull_keeps_identity_quoting_inside_remote_shell(self):
        key = str(self.cwd / "my key")
        result = self.lua("fscp", "--rsync", "--pull", "-H", "review-host",
                          "-i", key, "-t", "/remote dir/report.txt")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.capture.read_text()),
                         ["-avzP", "-e", "ssh -i '" + key + "'",
                          "review-host:/remote dir/report.txt", "./"])

    def test_tui_rsync_upload_and_download_keep_shell_characters_literal(self):
        names = ["quarterly report.txt", "file; touch INJECTED", "a'b.txt",
                 "$(touch INJECTED)", "x&y.txt", "star*.txt"]
        for direction in ("upload", "download"):
            with self.subTest(direction=direction):
                driver = r'''
Term.restore = function() end
Term.enable_raw = function() end
App.refresh_left = function() end
App.refresh_right = function() end
io.read = function() return "" end
App.host_cfg = {name="review-host", source="ssh-config", port="22"}
App.left.dir = "local dir"
App.right.dir = "/remote dir"
'''
                lua_names = "{" + ",".join(json.dumps(n) for n in names) + "}"
                driver += 'App.execute_transfer("' + direction + '", ' + lua_names + ')\n'
                result = self.lua("fscp", driver=driver)
                self.assertEqual(result.returncode, 0, result.stderr)
                if direction == "upload":
                    expected = ["local dir/" + n for n in names] + ["review-host:/remote dir/"]
                else:
                    expected = ["review-host:/remote dir/" + n for n in names] + ["local dir/"]
                self.assertEqual(json.loads(self.capture.read_text()), ["-avzP", *expected])
                self.assertFalse((self.cwd / "INJECTED").exists())

    def test_checkout_rejection_is_an_error_and_success_still_works(self):
        self.init_repo()
        self.git("checkout", "-qb", "other")
        (self.cwd / "file").write_text("other\n")
        self.git("commit", "-qam", "other")
        self.git("checkout", "-q", "master")
        (self.cwd / "file").write_text("dirty\n")
        result = self.lua("fco", "--no-force", "--batch", "other")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("[ERROR] Checkout failed", result.stderr)
        self.assertIn("would be overwritten", result.stderr)
        self.assertNotIn("[SUCCESS]", result.stdout)
        self.assertEqual(self.git("branch", "--show-current").strip(), "master")
        self.assertEqual((self.cwd / "file").read_text(), "dirty\n")

        self.git("restore", "file")
        result = self.lua("fco", "--no-force", "--batch", "other")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[SUCCESS]", result.stdout)
        self.assertEqual(self.git("branch", "--show-current").strip(), "other")

    def test_worktree_and_submodule_failures_preserve_diagnostics(self):
        # Outside a repository, both operations must return failure and Git's
        # actual diagnostic rather than treating pipe closure as success.
        result = self.lua("fco", driver=r'''
local ok, _, out = Git.update_submodules(false)
assert(not ok and out:find("not a git repository", 1, true), out)
ok, _, out = Git.execute_worktree({type="local", name="master"}, "worktree")
assert(not ok and out:find("not a git repository", 1, true), out)
local succeeded, message = Git.run_command("exit 17")
assert(not succeeded and message:find("failed", 1, true), message)
succeeded, message = Git.run_command("printf '%05000d' 0")
assert(succeeded and #message == 5000, "Long command output was truncated")
''')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
