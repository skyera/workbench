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




if __name__ == "__main__":
    unittest.main()
