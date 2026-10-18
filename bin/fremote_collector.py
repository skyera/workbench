"""Linux /proc collector streamed by fremote over an existing OpenSSH session.

Protocol v1: tab-separated ASCII records; text fields use UTF-8 hex encoding.
No remote files are created. stdin accepts DETAIL, SIGNAL, REFRESH, and QUIT.
"""

import os
import select
import signal
import sys
import time

if sys.platform.startswith("linux"):
    import pwd


def text(value):
    return str(value).encode("utf-8", "replace").hex()


def emit(*fields):
    print("\t".join(map(str, fields)), flush=True)


def process_stat(pid):
    with open("/proc/%d/stat" % pid, encoding="utf-8", errors="replace") as stream:
        raw = stream.read()
    end = raw.rfind(")")
    fields = raw[end + 2 :].split()
    return {
        "pid": pid,
        "name": raw[raw.find("(") + 1 : end],
        "state": fields[0],
        "ppid": int(fields[1]),
        "ticks": int(fields[11]) + int(fields[12]),
        "threads": int(fields[17]),
        "start": int(fields[19]),
        "rss": max(0, int(fields[21])) * os.sysconf("SC_PAGE_SIZE"),
    }


class Collector:
    def __init__(self):
        self.previous = {}
        self.previous_time = None
        self.previous_cpu = None
        self.users = {}
        self.hz = os.sysconf("SC_CLK_TCK")

    def snapshot(self):
        now = time.monotonic()
        elapsed = now - self.previous_time if self.previous_time is not None else None
        with open("/proc/uptime") as stream:
            uptime = float(stream.read().split()[0])
        with open("/proc/stat") as stream:
            cpu = list(map(int, stream.readline().split()[1:9]))
        busy = -1.0
        if self.previous_cpu is not None:
            delta = sum(cpu) - sum(self.previous_cpu)
            idle = (cpu[3] + cpu[4]) - (self.previous_cpu[3] + self.previous_cpu[4])
            busy = 100 * (delta - idle) / delta if delta > 0 else 0.0
        memory = {}
        with open("/proc/meminfo") as stream:
            for line in stream:
                key, value = line.split(":", 1)
                memory[key] = int(value.split()[0]) * 1024
        processes, current = [], {}
        for entry in os.listdir("/proc"):
            if not entry.isdigit():
                continue
            try:
                row = process_stat(int(entry))
                uid = os.stat("/proc/" + entry).st_uid
                if uid not in self.users:
                    try:
                        self.users[uid] = pwd.getpwuid(uid).pw_name
                    except KeyError:
                        self.users[uid] = str(uid)
                identity = (row["pid"], row["start"])
                previous = self.previous.get(identity)
                usage = -1.0
                if previous is not None and elapsed:
                    elapsed_cpu_seconds = (row["ticks"] - previous) / self.hz
                    usage = max(0.0, 100 * elapsed_cpu_seconds / elapsed)
                current[identity] = row["ticks"]
                processes.append((row, uid, self.users[uid], usage))
            except (OSError, ValueError, IndexError):
                # Processes can exit between directory enumeration and stat.
                continue
        emit(
            "H",
            1,
            int(time.time()),
            os.getuid(),
            memory["MemTotal"],
            memory["MemTotal"] - memory.get("MemAvailable", memory.get("MemFree", 0)),
            "%.1f" % busy,
            text(" ".join("%.2f" % n for n in os.getloadavg())),
        )
        for row, uid, user, usage in processes:
            emit(
                "P",
                row["pid"],
                row["ppid"],
                row["start"],
                "%.1f" % usage,
                row["rss"],
                row["threads"],
                row["state"],
                uid,
                int(max(0, uptime - row["start"] / self.hz)),
                text(user),
                text(row["name"]),
            )
        emit("E")
        self.previous, self.previous_time, self.previous_cpu = current, now, cpu

    def command(self, line):
        fields = line.rstrip("\n").split("\t")
        action = fields[0]
        if action == "QUIT":
            return False
        if action == "REFRESH":
            self.snapshot()
            emit("R")
            return True
        try:
            if action not in ("DETAIL", "SIGNAL") or len(fields) != (
                4 if action == "SIGNAL" else 3
            ):
                raise ValueError("Invalid collector command")
            pid, start = int(fields[1]), int(fields[2])
            if pid <= 0 or start < 0:
                raise ValueError("Invalid process identity")
            row = process_stat(pid)
            if row["start"] != start:
                raise ValueError("PID was reused; refresh and select the process again")
            if action == "DETAIL":
                try:
                    with open("/proc/%d/cmdline" % pid, "rb") as stream:
                        cmd = (
                            stream.read(65536)
                            .replace(b"\0", b" ")
                            .decode("utf-8", "replace")
                            .strip()
                        )
                    cmd = cmd or "[" + row["name"] + "]"
                except OSError as error:
                    cmd = "Cannot read command: " + str(error)
                try:
                    cwd = os.readlink("/proc/%d/cwd" % pid)
                except OSError as error:
                    cwd = "Cannot read working directory: " + str(error)
                emit("D", pid, start, text(cmd), text(cwd))
            else:
                sig = int(fields[3])
                if sig not in (signal.SIGTERM, signal.SIGKILL):
                    raise ValueError("Only SIGTERM and SIGKILL are supported")
                if pid in (1, os.getpid(), os.getppid()):
                    raise ValueError("Refusing to signal init or this monitoring session")
                if not hasattr(os, "pidfd_open") or not hasattr(signal, "pidfd_send_signal"):
                    raise RuntimeError(
                        "Safe signalling requires Linux pidfd support and Python 3.9+; use your SSH shell instead"
                    )
                fd = os.pidfd_open(pid)
                try:
                    # Validate after opening: pidfd binds the signal to this process.
                    if process_stat(pid)["start"] != start:
                        raise ValueError("PID was reused; refresh and select the process again")
                    signal.pidfd_send_signal(fd, sig)
                finally:
                    os.close(fd)
                emit(
                    "A",
                    pid,
                    start,
                    text("Sent " + signal.Signals(sig).name + "; awaiting next snapshot"),
                )
        except (OSError, ValueError, RuntimeError) as error:
            message = str(error)
            if isinstance(error, PermissionError):
                message += ". Check process ownership; no elevation was attempted"
            emit("X", text(action + ": " + message))
        return True


def main():
    if not sys.platform.startswith("linux"):
        raise RuntimeError("fremote requires a Linux remote host with /proc mounted")
    interval = float(sys.argv[1]) if len(sys.argv) > 1 else 2.0
    if not 0.2 <= interval <= 60:
        raise ValueError("Refresh interval must be between 0.2 and 60 seconds")
    collector = Collector()
    collector.snapshot()
    deadline = time.monotonic() + interval
    pending = b""
    while True:
        ready, _, _ = select.select([sys.stdin], [], [], max(0, deadline - time.monotonic()))
        if ready:
            data = os.read(sys.stdin.fileno(), 4096)
            if not data:
                return
            pending += data
            if len(pending) > 16384:
                raise ValueError("Collector command exceeds protocol limit")
            while b"\n" in pending:
                line, pending = pending.split(b"\n", 1)
                if not collector.command(line.decode("ascii")):
                    return
        if time.monotonic() >= deadline:
            collector.snapshot()
            deadline = time.monotonic() + interval


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        pass
    except Exception as error:
        print("fremote collector: " + str(error), file=sys.stderr)
        sys.exit(1)
