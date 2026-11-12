"""Run with: python3 -m unittest discover -s tests -p test_rsshfs.py -v

Exercise bin/rsshfs.sh with stub sshfs, findmnt, stat and fusermount3
executables placed first on PATH. The stubs keep a fake mount table in a
temporary directory, so no SSH connections or real mounts are made.
"""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "bin" / "rsshfs.sh"
BASH = shutil.which("bash")

# Each stub records its argv in $STUB_LOG. The fake mount table is the file
# $MOUNTED (one absolute path per line); paths in $STALE fail stat() the way
# a dead FUSE mount does.
STUBS = {
    "sshfs": r'''#!/bin/sh
echo "sshfs $*" >> "$STUB_LOG"
if [ -n "${SSHFS_FAIL:-}" ]; then
    echo "read: Connection reset by peer" >&2
    exit 1
fi
realpath -m -- "$2" >> "$MOUNTED"
''',
    "findmnt": r'''#!/bin/sh
for last in "$@"; do :; done
grep -qxF -- "$(realpath -m -- "$last")" "$MOUNTED"
''',
    "stat": r'''#!/bin/sh
for last in "$@"; do :; done
if grep -qxF -- "$(realpath -m -- "$last")" "$STALE"; then
    echo "stat: cannot statx '$last': Transport endpoint is not connected" >&2
    exit 1
fi
exec /usr/bin/stat "$@"
''',
    "fusermount3": r'''#!/bin/sh
echo "fusermount3 $*" >> "$STUB_LOG"
for last in "$@"; do :; done
if [ -n "${FUSERMOUNT_FAIL:-}" ]; then
    echo "fusermount3: failed to unmount $last: Device or resource busy" >&2
    exit 1
fi
path="$(realpath -m -- "$last")"
for table in "$MOUNTED" "$STALE"; do
    grep -vxF -- "$path" "$table" > "$table.new" || true
    mv "$table.new" "$table"
done
''',
}


@unittest.skipUnless(BASH and os.name != "nt", "requires bash on a POSIX host")
class RsshfsTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="rsshfs-test-")
        self.addCleanup(temp.cleanup)
        self.cwd = Path(temp.name)

        stub_dir = self.cwd / "stubs"
        stub_dir.mkdir()
        for name, source in STUBS.items():
            stub = stub_dir / name
            stub.write_text(source, encoding="utf-8")
            stub.chmod(0o755)

        self.log = self.cwd / "stub.log"
        self.mounted = self.cwd / "mounted"
        self.stale = self.cwd / "stale"
        for path in (self.log, self.mounted, self.stale):
            path.write_text("", encoding="utf-8")

        self.env = dict(
            os.environ,
            LC_ALL="C",
            PATH=str(stub_dir) + os.pathsep + os.environ["PATH"],
            STUB_LOG=str(self.log),
            MOUNTED=str(self.mounted),
            STALE=str(self.stale),
        )

    def run_script(self, *args, **extra_env):
        env = dict(self.env, **extra_env)
        return subprocess.run(
            [BASH, str(SCRIPT), *args],
            cwd=self.cwd,
            env=env,
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=30,
        )

    def mark(self, table, path):
        with table.open("a", encoding="utf-8") as handle:
            handle.write(str(path.resolve()) + "\n")

    def calls(self):
        return self.log.read_text(encoding="utf-8").splitlines()

    # -- argument validation ------------------------------------------------

    def test_too_many_arguments_is_rejected_before_mkdir(self):
        result = self.run_script("host", "/srv", "mnt", "extra")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Too many arguments (4); expected at most 3.", result.stderr)
        self.assertFalse((self.cwd / "mnt").exists())
        self.assertEqual(self.calls(), [])

    def test_unknown_option_is_rejected(self):
        result = self.run_script("-x", "mnt")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Unknown option '-x'.", result.stderr)
        self.assertFalse((self.cwd / "mnt").exists())

    def test_unmount_rejects_extra_arguments(self):
        result = self.run_script("-u", "a", "b")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Too many arguments for -u", result.stderr)

    def test_host_colon_dir_form_is_split(self):
        result = self.run_script("user@box:/var/www", "mnt")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Mounting user@box (/var/www) to mnt...", result.stdout)
        self.assertTrue(self.calls()[0].startswith("sshfs user@box:/var/www mnt "))

    def test_host_colon_dir_with_third_argument_is_rejected(self):
        result = self.run_script("box:/a", "/b", "mnt")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Remote directory given twice", result.stderr)

    def test_two_argument_form_mounts_remote_home(self):
        result = self.run_script("box", "mnt")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Mounting box (remote $HOME) to mnt...", result.stdout)
        self.assertTrue(self.calls()[0].startswith("sshfs box: mnt -o reconnect"))
        self.assertIn("Successfully mounted to mnt", result.stdout)

    def test_help_works_without_sshfs_installed(self):
        bin_dir = self.cwd / "minimal-bin"
        bin_dir.mkdir()
        for tool in ("basename", "cat"):
            os.symlink(shutil.which(tool), bin_dir / tool)
        env = dict(self.env, PATH=str(bin_dir))
        result = subprocess.run(
            [BASH, str(SCRIPT), "--help"],
            env=env,
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Usage:", result.stdout)

    # -- mount ---------------------------------------------------------------

    def test_already_mounted_is_a_notice(self):
        (self.cwd / "mnt").mkdir()
        self.mark(self.mounted, self.cwd / "mnt")
        result = self.run_script("box", "mnt")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Notice: 'mnt' is already mounted.", result.stdout)
        self.assertEqual(self.calls(), [])

    def test_stale_mount_is_cleaned_before_mounting(self):
        (self.cwd / "mnt").mkdir()
        self.mark(self.mounted, self.cwd / "mnt")
        self.mark(self.stale, self.cwd / "mnt")
        result = self.run_script("box", "/srv", "mnt")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "Notice: 'mnt' is a stale mount (Transport endpoint is not connected)",
            result.stdout,
        )
        calls = self.calls()
        self.assertEqual(calls[0], "fusermount3 -u -z mnt")
        self.assertTrue(calls[1].startswith("sshfs box:/srv mnt "))
        self.assertIn("Successfully mounted to mnt", result.stdout)

    def test_sshfs_failure_reports_hint_and_exit_status(self):
        result = self.run_script("nosuchhost", "/tmp", "mnt", SSHFS_FAIL="1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("read: Connection reset by peer", result.stderr)
        self.assertIn("Error: sshfs could not mount nosuchhost:/tmp (exit 1).", result.stderr)
        self.assertIn("run 'ssh nosuchhost true'", result.stderr)
        self.assertNotIn("Successfully", result.stdout)

    # -- unmount -------------------------------------------------------------

    def test_unmount_stale_mount_lazily(self):
        (self.cwd / "mnt").mkdir()
        self.mark(self.mounted, self.cwd / "mnt")
        self.mark(self.stale, self.cwd / "mnt")
        result = self.run_script("-u", "mnt")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("is a stale mount", result.stdout)
        self.assertIn("Successfully unmounted mnt.", result.stdout)
        self.assertEqual(self.calls(), ["fusermount3 -u -z mnt"])

    def test_unmount_busy_reports_hint(self):
        (self.cwd / "mnt").mkdir()
        self.mark(self.mounted, self.cwd / "mnt")
        result = self.run_script("-u", "mnt", FUSERMOUNT_FAIL="1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Device or resource busy", result.stderr)
        self.assertIn("Error: Could not unmount 'mnt'", result.stderr)
        self.assertIn("fusermount3 -uz mnt", result.stderr)
        self.assertNotIn("Successfully", result.stdout)

    def test_unmount_missing_directory_and_plain_directory(self):
        missing = self.run_script("-u", "nope")
        self.assertEqual(missing.returncode, 1)
        self.assertIn("Error: Directory 'nope' does not exist.", missing.stderr)

        (self.cwd / "plain").mkdir()
        plain = self.run_script("-u", "plain")
        self.assertEqual(plain.returncode, 0, plain.stderr)
        self.assertIn("Notice: 'plain' is not currently a mountpoint.", plain.stdout)
        self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main()
