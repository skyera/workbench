"""Run with: python3 -m unittest discover -s tests -v

Run bin/dotag.py against temporary source trees and check the database files
and diagnostics it produces. Nothing outside the temporary trees is touched.
"""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
DOTAG = ROOT / "bin/dotag.py"

HAS_INDEXERS = bool(shutil.which("cscope") and shutil.which("ctags"))
HAS_FD = bool(shutil.which("fd") or shutil.which("fdfind"))
HAS_FIND = bool(shutil.which("find"))


def available_find_methods():
    """Return the --find methods whose external tool is installed."""
    methods = ["py"]
    if HAS_FIND and os.name != "nt":
        methods.append("find")
    if HAS_FD:
        methods.append("fd")
    return methods


@unittest.skipUnless(HAS_INDEXERS, "requires cscope and ctags")
class DotagPy(unittest.TestCase):
    def setUp(self):
        tree = tempfile.TemporaryDirectory(prefix="dotag-py-test-")
        self.addCleanup(tree.cleanup)
        self.tree = Path(tree.name)

    def write_source(self, relative_path, text="int value;\n"):
        """Create a source file inside the temporary tree."""
        target = self.tree / relative_path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")

    def run_dotag(self, *arguments):
        """Run dotag.py in the temporary tree and return the completed process."""
        return subprocess.run(
            [sys.executable, str(DOTAG), *arguments],
            cwd=self.tree,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            encoding="utf-8",
            errors="replace",
            check=False,
        )

    def listed_files(self):
        """Return the file names recorded in cscope.files."""
        content = (self.tree / "cscope.files").read_text(encoding="utf-8")
        return sorted(content.splitlines())

    @unittest.skipIf(os.name == "nt", "needs a filesystem that stores raw byte names")
    def test_non_utf8_file_name_is_skipped_with_warning(self):
        self.write_source("ok.c")
        bad_name = os.path.join(os.fsencode(self.tree), b"caf\xe9.c")
        try:
            with open(bad_name, "wb") as bad_file:
                bad_file.write(b"int bad;\n")
        except OSError:
            self.skipTest("filesystem rejects non-UTF-8 file names")

        for method in available_find_methods():
            with self.subTest(method=method):
                result = self.run_dotag("-c", "-f", method)

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("Traceback", result.stderr)
                self.assertEqual([Path(name).name for name in self.listed_files()], ["ok.c"])
                self.assertTrue((self.tree / "tags").exists())

                # fd never lists such names for an extension filter, so only
                # the methods that see the file can warn about it.
                if method != "fd":
                    self.assertIn("caf\\xe9.c is not valid UTF-8 (skipped)", result.stderr)

    @unittest.skipIf(os.name == "nt", "needs POSIX directory permissions")
    def test_unreadable_directory_is_skipped_with_warning(self):
        if os.geteuid() == 0:
            self.skipTest("root can read every directory")

        self.write_source("src/a.c")
        self.write_source("locked/b.c")
        locked = self.tree / "locked"
        locked.chmod(0)
        self.addCleanup(locked.chmod, 0o755)

        for method in available_find_methods():
            with self.subTest(method=method):
                result = self.run_dotag("-c", "-f", method)

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual([Path(name).name for name in self.listed_files()], ["a.c"])
                self.assertTrue((self.tree / "cscope.out").exists())
                self.assertIn("[WARN]", result.stderr)
                self.assertIn("locked", result.stderr)
                self.assertIn("ermission denied", result.stderr)

    @unittest.skipIf(os.name == "nt", "needs POSIX directory permissions")
    @unittest.skipUnless(HAS_FIND, "requires find")
    def test_find_that_lists_nothing_and_fails_is_an_error(self):
        if os.geteuid() == 0:
            self.skipTest("root can read every directory")

        self.write_source("locked/b.c")
        locked = self.tree / "locked"
        locked.chmod(0)
        self.addCleanup(locked.chmod, 0o755)

        result = self.run_dotag("-c", "-f", "find")

        self.assertEqual(result.returncode, 1)
        self.assertNotIn("Traceback", result.stderr)
        self.assertIn("[ERROR] find failed with exit status 1 and listed no files", result.stderr)

    def test_tree_without_source_files_is_a_clear_error(self):
        (self.tree / "notes.txt").write_text("not a source file\n", encoding="utf-8")

        for method in available_find_methods():
            with self.subTest(method=method):
                result = self.run_dotag("-c", "-f", method)

                self.assertEqual(result.returncode, 1)
                self.assertNotIn("Traceback", result.stderr)
                self.assertIn("[ERROR] no source files found under", result.stderr)
                self.assertIn(f"(find method: {method})", result.stderr)
                self.assertEqual("-I to include" in result.stderr, method == "fd")

                # The indexers must not have run on the empty list.
                self.assertNotIn("cscope: no source files found", result.stderr)
                self.assertFalse((self.tree / "tags").exists())
                self.assertFalse((self.tree / "filenametags").exists())

    def test_unwritable_filenametags_is_a_clear_error(self):
        self.write_source("a.c")

        for method in available_find_methods():
            with self.subTest(method=method):
                # A directory in the way makes opening filenametags for writing fail.
                blocker = self.tree / "filenametags"
                blocker.mkdir(exist_ok=True)
                self.addCleanup(shutil.rmtree, blocker, True)

                result = self.run_dotag("-f", method)

                self.assertEqual(result.returncode, 1)
                self.assertNotIn("Traceback", result.stderr)
                self.assertIn("[ERROR] cannot write filenametags:", result.stderr)
                self.assertIn("run dotag.py with -c", result.stderr)

    def test_missing_dependency_is_a_clear_error(self):
        self.write_source("a.c")
        empty_bin = self.tree / "empty-bin"
        empty_bin.mkdir()

        result = subprocess.run(
            [sys.executable, str(DOTAG), "-f", "py"],
            cwd=self.tree,
            env={**os.environ, "PATH": str(empty_bin)},
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            encoding="utf-8",
            errors="replace",
            check=False,
        )

        self.assertEqual(result.returncode, 1)
        self.assertNotIn("Traceback", result.stderr)
        self.assertIn("[ERROR] Missing required dependencies: cscope, ctags", result.stderr)
        self.assertIn("ensure they are in your PATH", result.stderr)

    @unittest.skipIf(os.name == "nt", "uses a POSIX shell stub")
    def test_fd_failure_is_reported_with_command_and_reason(self):
        self.write_source("a.c")
        stub_dir = self.tree / "stub-bin"
        stub_dir.mkdir()
        stub = stub_dir / "fd"
        stub.write_text("#!/bin/sh\necho 'bad exclude pattern' >&2\nexit 2\n", encoding="utf-8")
        stub.chmod(0o755)

        result = subprocess.run(
            [sys.executable, str(DOTAG), "-f", "fd"],
            cwd=self.tree,
            env={**os.environ, "PATH": f"{stub_dir}{os.pathsep}{os.environ['PATH']}"},
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            encoding="utf-8",
            errors="replace",
            check=False,
        )

        self.assertEqual(result.returncode, 1)
        self.assertNotIn("Traceback", result.stderr)
        self.assertIn("[ERROR] 'fd --type f", result.stderr)
        self.assertIn("failed with exit status 2: bad exclude pattern", result.stderr)


if __name__ == "__main__":
    unittest.main()
