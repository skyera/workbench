#!/usr/bin/env python
#
# Create cscope, filename, tag database for source code
#
import argparse
import os
import shlex
import shutil
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

FILE_EXTS = (
    ".c",
    ".cpp",
    ".cc",
    ".h",
    ".hpp",
    ".inl",
    ".cs",
    ".java",
    ".mc",
    ".rc",
    ".idl",
    ".js",
    ".ts",
    ".py",
    ".sql",
    ".sh",
    ".lua",
    ".toml",
    ".bat",
    ".sdl",
    ".cu",
    ".cuh",
)

EXCLUDED_DIRS = [
    ".git",
    ".svn",
    ".hg",
    ".vscode",
    ".idea",
    ".settings",
    "__pycache__",
    ".pytest_cache",
    ".mypy_cache",
    ".cache",
    "boost",
    "Omni",
    "Generated",
    "build",
    "_output",
    "dist",
    "out",
    "target",
    "jazz",
    "node_modules",
    "webapp",
    "PythonStandardLibrary",
    "virtualenv",
    "venv",
    ".venv",
    "env",
    "3rdParty",
    "ThirdParty",
    "third_party",
    "OpenThreads",
    "OpenCV",
    "Anaconda",
    "Debug",
    "Release",
    "cudafe1",
]

CSCOPE_FILE_NAME = "cscope.files"
FILENAMETAG_FILE_NAME = "filenametags"


def parse():
    """Parse command line arguments"""
    parser = argparse.ArgumentParser(
        prog="dotag.py", description="generate cscope/tags data", epilog="fast search"
    )
    parser.add_argument(
        "-f",
        "--find",
        choices=["py", "find", "fd"],
        default="fd",
        help="find files method (default: fd)",
    )
    parser.add_argument(
        "-c",
        "--clean",
        action="store_true",
        help="clean old database files before starting",
    )
    parser.add_argument(
        "-I",
        "--no-ignore",
        action="store_true",
        help="don't respect ignore files (.gitignore, etc.) and include hidden files (only for fd method)",
    )
    parser.add_argument(
        "-S",
        "--in-memory-sort",
        action="store_true",
        help="use in-memory sort instead of external sort command (external is now default)",
    )
    args = parser.parse_args()
    return args.find, args.clean, args.no_ignore, not args.in_memory_sort


def write_cscope_files(files):
    """Write files to cscope.files, skipping those with spaces and printing a warning."""
    count = 0
    with open(CSCOPE_FILE_NAME, "w", encoding="utf-8") as cscope_f:
        for f in files:
            if " " in f:
                print(f"{f} has spaces", file=sys.stderr)
                continue
            cscope_f.write(f"{f}\n")
            count += 1
    return count


class FindCmd:
    """Generate find command by using find"""

    def __init__(self, excluded_dirs, file_exts):
        self.excluded_dirs = excluded_dirs
        self.file_exts = file_exts
        self.args = []

    def create(self, find_executable):
        """Create the find arguments list"""
        self.args = [find_executable, "."]

        if self.excluded_dirs:
            self.args.extend(["-type", "d", "("])
            for i, d in enumerate(self.excluded_dirs):
                if i > 0:
                    self.args.append("-or")
                self.args.extend(["-iname", d])
            self.args.extend([")", "-prune", "-or"])

        self.args.extend(["-type", "f", "("])
        for i, ext in enumerate(self.file_exts):
            if i > 0:
                self.args.append("-or")
            self.args.extend(["-iname", f"*{ext}"])
        self.args.extend([")", "-print"])


class FdCmd:
    def __init__(self, excluded_dirs, file_exts, no_ignore=False):
        self.excluded_dirs = excluded_dirs
        self.file_exts = file_exts
        self.fd_cmd = ["fd", "--type", "f", "--ignore-case"]
        if no_ignore:
            self.fd_cmd.extend(["--no-ignore", "--hidden"])

    def build_cmd(self):
        for ext in self.file_exts:
            self.fd_cmd.extend(["-e", ext.lstrip(".")])

        for pat in self.excluded_dirs:
            self.fd_cmd.extend(["--exclude", pat])

    def run_fd(self):
        print("Running fd")
        print(" ".join(shlex.quote(x) for x in self.fd_cmd))

        result = subprocess.run(
            self.fd_cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            print(result.stderr, file=sys.stderr)
            sys.exit(1)

        files = result.stdout.splitlines()
        return write_cscope_files(files)


def get_files():
    excluded_names = {excl.lower() for excl in EXCLUDED_DIRS}

    for root, dirs, file_names in os.walk("."):
        # Prune excluded directories in-place to prevent os.walk from descending.
        # Names must match exactly (case-insensitive), as with the 'find' and 'fd'
        # methods; substring matching would also drop dirs like "layout" or "output".
        dirs[:] = [d for d in dirs if d.lower() not in excluded_names]

        for file_name in file_names:
            path = os.path.join(root, file_name)
            if not os.path.islink(path):
                _, ext = os.path.splitext(file_name)
                if ext.lower() in FILE_EXTS:
                    yield path


def gnu_find_files():
    find_executable = shutil.which("find")
    if os.name == "nt":
        if not find_executable:
            print("Error: 'find' command not found.", file=sys.stderr)
            sys.exit(1)
        try:
            result = subprocess.run(
                [find_executable, "--version"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
            if "GNU findutils" not in result.stdout:
                print(
                    "Error: 'find' is not GNU find. On Windows, ensure Git Bash or Cygwin is in your PATH.",
                    file=sys.stderr,
                )
                sys.exit(1)
        except Exception as e:
            print(f"Error checking 'find' version: {e}", file=sys.stderr)
            sys.exit(1)

    cmd = FindCmd(EXCLUDED_DIRS, FILE_EXTS)
    cmd.create(find_executable)

    # For logging, we can use shlex.join (Python 3.8+) or subprocess.list2cmdline
    if hasattr(shlex, "join"):
        print(shlex.join(cmd.args))
    else:
        print(" ".join(shlex.quote(arg) for arg in cmd.args))

    # On Windows, Cygwin/MSYS find.exe might try to expand globs itself if it thinks
    # it's in a non-POSIX shell. We disable this by setting the noglob environment variable.
    env = os.environ.copy()
    env["CYGWIN"] = "noglob"
    env["MSYS"] = "noglob"

    result = subprocess.run(
        cmd.args, check=True, stdout=subprocess.PIPE, text=True, env=env
    )
    files = result.stdout.splitlines()
    return write_cscope_files(files)


def fd_files(no_ignore=False):
    cmd = FdCmd(EXCLUDED_DIRS, FILE_EXTS, no_ignore)
    cmd.build_cmd()
    return cmd.run_fd()


def py_find_files():
    files = get_files()
    return write_cscope_files(files)


def log_cpu(msg, start):
    elapsed = time.time() - start
    print(f"{msg} elapsed {elapsed:.3f} seconds")


def collect_files(find_method, no_ignore=False):
    print("finding files...")
    start = time.time()
    if find_method == "py":
        num_files = py_find_files()
    elif find_method == "find":
        num_files = gnu_find_files()
    else:
        num_files = fd_files(no_ignore)

    log_cpu(f"find files: number of files {num_files}", start)


def run_cscope():
    start = time.time()
    cmd = ["cscope", "-b", "-q", "-k", "-i", CSCOPE_FILE_NAME]
    print(" ".join(cmd))
    
    # Resolve cscope location to ensure it calls sibling binaries (like Cygwin sort)
    cscope_path = shutil.which("cscope")
    env = os.environ.copy()
    if cscope_path:
        cscope_dir = os.path.dirname(cscope_path)
        env["PATH"] = cscope_dir + os.pathsep + env.get("PATH", "")
        
        # Override SHELL to use sibling sh.exe if on Windows to prevent
        # cross-environment path translation errors (e.g. MSYS2 bash not understanding
        # Cygwin temp paths like /cygdrive/c/...).
        if os.name == "nt":
            sh_path = os.path.join(cscope_dir, "sh.exe")
            if os.path.exists(sh_path):
                env["SHELL"] = sh_path
        
    subprocess.run(cmd, check=True, env=env)
    log_cpu("cscope", start)


def foldcase_sort_key(line):
    """Sort key equal to GNU `LC_ALL=C sort -f`: ASCII-only fold to upper case, by bytes."""
    return line.encode("utf-8").upper()


def create_filenametags(use_external_sort=False, sort_executable="sort"):
    start = time.time()
    if use_external_sort:
        print(f"creating filenametags (external {sort_executable} -f)...")
    else:
        print("creating filenametags (in-memory sort)...")

    if not os.path.exists(CSCOPE_FILE_NAME):
        print(
            f"[ERROR] {CSCOPE_FILE_NAME} not found. Cannot create filenametags.",
            file=sys.stderr,
        )
        return

    if use_external_sort:
        # Generate raw tag lines and pipe them to 'sort -f'
        try:
            # Create the tag entries as a byte string for the pipe
            tag_entries = []
            with open(CSCOPE_FILE_NAME, "r", encoding="utf-8") as f:
                for line in f:
                    path = line.strip().strip('"')
                    name = Path(path).name
                    tag_entries.append(f"{name}\t{path}\t1\n")

            input_data = "".join(tag_entries).encode("utf-8")

            # Run sort -f and capture output
            # Force the C locale: locale collation ignores punctuation and would
            # disagree with the in-memory sort and the foldcase header below.
            sort_env = os.environ.copy()
            sort_env["LC_ALL"] = "C"

            result = subprocess.run(
                [sort_executable, "-f"],
                input=input_data,
                stdout=subprocess.PIPE,
                env=sort_env,
                check=True,
            )

            with open(FILENAMETAG_FILE_NAME, "w", encoding="utf-8") as f:
                f.write("!_TAG_FILE_SORTED\t2\t/2=foldcase/\n")
                f.write(result.stdout.decode("utf-8"))
        except subprocess.CalledProcessError as e:
            print(f"[ERROR] External sort failed: {e}", file=sys.stderr)
            return
    else:
        lines = []
        with open(CSCOPE_FILE_NAME, "r", encoding="utf-8") as f:
            for line in f:
                path = line.strip().strip('"')
                name = Path(path).name
                lines.append(f"{name}\t{path}\t1\n")

        lines.sort(key=foldcase_sort_key)

        with open(FILENAMETAG_FILE_NAME, "w", encoding="utf-8") as f:
            f.write("!_TAG_FILE_SORTED\t2\t/2=foldcase/\n")
            f.writelines(lines)

    log_cpu("filenametags", start)


def create_tags():
    start = time.time()
    cmd = ["ctags", "-L", CSCOPE_FILE_NAME]
    print(" ".join(cmd))
    subprocess.run(cmd, check=True)
    log_cpu("ctags", start)


def log_find_method(find_method):
    print("find method:", find_method)


def check_dependencies(find_method):
    """Verify that required tools are installed."""
    tools = ["cscope", "ctags"]
    if find_method == "fd":
        tools.append("fd")
    elif find_method == "find":
        tools.append("find")

    missing = []
    for tool in tools:
        if shutil.which(tool) is None:
            # Special check for find on Windows to avoid the built-in Windows find.exe
            if tool == "find" and os.name == "nt":
                continue  # gnu_find_files already has a robust check
            missing.append(tool)

    if missing:
        print(
            f"[ERROR] Missing required dependencies: {', '.join(missing)}",
            file=sys.stderr,
        )
        print("Please install them and ensure they are in your PATH.", file=sys.stderr)
        sys.exit(1)


def check_sort_version():
    """Verify that 'sort' is the GNU version, especially on Windows."""
    sort_cmd = "sort.exe" if os.name == "nt" else "sort"
    # Use shutil.which to ensure we respect the updated os.environ['PATH']
    executable = shutil.which(sort_cmd)
    if not executable:
        return None

    try:
        result = subprocess.run(
            [executable, "--version"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        if "GNU coreutils" in result.stdout:
            return executable
    except (FileNotFoundError, subprocess.CalledProcessError):
        pass
    return None


def try_apply_setpath():
    """Try to find and run setpath.bat, applying its PATH changes to os.environ."""
    script_dir = os.path.dirname(os.path.realpath(__file__))
    setpath_bat = os.path.join(script_dir, "setpath.bat")

    if not os.path.exists(setpath_bat):
        print(f"[ERROR] {setpath_bat} not found.", file=sys.stderr)
        sys.exit(1)

    # Run the batch file and capture the environment changes
    try:
        result = subprocess.run(
            f'"{setpath_bat}" >nul && set',
            shell=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        if result.returncode == 0:
            for line in result.stdout.splitlines():
                try:
                    if "=" in line:
                        key, value = line.split("=", 1)
                        if key.upper() == "PATH":
                            os.environ["PATH"] = value
                except ValueError:
                    continue
    except Exception as e:
        print(f"[ERROR] Failed to execute setpath.bat: {e}", file=sys.stderr)


def main():
    find_method, clean, no_ignore, sort_external = parse()
    log_find_method(find_method)

    sort_executable = check_sort_version()
    if os.name == "nt" and not sort_executable:
        print(
            "[INFO] GNU sort not found. Attempting to run setpath.bat...",
            file=sys.stderr,
        )
        try_apply_setpath()
        sort_executable = check_sort_version()
        if not sort_executable:
            print(
                "[ERROR] GNU sort not found even after running setpath.bat. Quitting.",
                file=sys.stderr,
            )
            sys.exit(1)
        print("[INFO] GNU sort detected after environment update.")

    # Default to "sort" if not on NT or if check_sort_version failed but we didn't exit
    if not sort_executable:
        sort_executable = "sort"

    check_dependencies(find_method)

    # Cleanup old database files to prevent tool-level state conflicts
    if clean:
        print("Cleaning old database files...")
        for f in [
            CSCOPE_FILE_NAME,
            "cscope.out",
            "cscope.in.out",
            "cscope.po.out",
            "tags",
            FILENAMETAG_FILE_NAME,
        ]:
            if os.path.exists(f):
                try:
                    os.remove(f)
                except OSError:
                    pass

    start = time.time()

    # 1. Collect files (Sequential, as it creates the base file)
    collect_files(find_method, no_ignore)

    # 2. Run post-processing tasks in parallel
    print("Starting post-processing (parallel)...")
    with ThreadPoolExecutor() as executor:
        futures = [
            executor.submit(run_cscope),
            executor.submit(create_filenametags, sort_external, sort_executable),
            executor.submit(create_tags),
        ]
        # Wait for all tasks to complete and raise exceptions if any occurred
        for future in futures:
            future.result()

    log_cpu("Total", start)


if __name__ == "__main__":
    main()
