<p align="center">
  <img src="assets/workbench.svg" alt="Workbench — a terminal resting on a workbench" width="760">
</p>

# workbench

Cross-platform dotfiles, editor configs, and command-line tools.

My personal development setup for Windows, Linux, and macOS: a place to keep the tools and settings I use every day, and bring them to another machine.

## What's on the bench

| Area | Configs and tools |
| --- | --- |
| Editors | [Neovim](.config/nvim), [Vim](myvimrc), and [clangd](.config/clangd) |
| Shell & terminal | [Bash](mybashrc), [Starship](.config/starship.toml), [tmux](.tmux.conf), [WezTerm](.wezterm.lua), and [Alacritty](.config/alacritty) |
| Git | [Aliases and defaults](.gitconfig), [tig](.tigrc), and [ignore rules](.config/git/ignore) |
| Files & navigation | [lf](.config/lf), [Yazi](.config/yazi), [ranger](.config/ranger), and [Vifm](.vifm) |
| Remote work | [SSH configuration](.config/ssh/config.base), plus SSH, SCP, and tunnel helpers in [bin/](bin) |
| Debugging | [GDB](.gdbinit), [CGDB](.cgdb/cgdbrc), and Valgrind wrappers in [bin/](bin) |

## Get started

```sh
git clone git@github.com:skyera/workbench.git
cd workbench
```

Choose a deployment method below. These are personal configurations: review the files and destination paths before deploying. The scripts copy configurations into your user directories and may install additional tools or plugins; they do not install every application listed above.

### Linux & macOS

Use Bash to deploy dotfiles and copy utilities to `~/bin`:

```sh
bash deploy.sh --help
bash deploy.sh          # Neovim Lua configuration (default)
bash deploy.sh --vim    # Vimscript configuration for Neovim
```

Keep `~/bin` on your `PATH`. The script backs up changed individual files as `.bak`; directory copies do not provide a full backup.

### Windows

Run from Command Prompt to deploy configurations and copy utilities to `C:\app\bin`:

```cmd
deploy.bat --help
deploy.bat --lua
deploy.bat --vim
```

Lua is the default; `--vim` selects the Vimscript configuration for Neovim. The batch script also accepts `/h`, `/l`, and `/v`. Ensure that `C:\app\bin` is on your `PATH`. It overwrites destination files, so back up existing configurations first.

### Graphical deployment

For a graphical view of source and destination files, run the deployer with Python 3 and Tkinter:

```sh
python deploy_gui.py
```

The GUI includes backup, diff, and restore controls. On systems where Python 3 is named `python3`, use `python3 deploy_gui.py`.

## Everyday tools

The [bin/](bin) directory includes utilities for:

- Finding files and changing directories with interactive TUIs (`fe`, `fcd`, `frg`, `fvim`).
- Connecting to hosts, copying files, inspecting remote processes, and opening tunnels (`fssh`, `fscp`, `fremote`, `fssh_tunnel`).
- Working with Git and source indexes (`fco`, `flog`, `fbr`, `dotag`).
- Managing shell history, processes, clipboard access, and remote mounts (`fhist`, `fkill`, `osc52-yank`, `rsshfs`).
- Inspecting interfaces, DNS records, latency, and open ports (`fnet`).
- Capturing the screen, a window, or a dragged region to PNG, with optional clipboard copy, plus an annotation editor for marking up a capture (`fshot --edit`).

Many tools have platform-specific implementations in shell, batch, Lua, PowerShell, or Python. Check the selected script for its dependencies and options.

### Remote process inspector

`fremote` runs on Windows and Linux clients and inspects Linux remote hosts over
OpenSSH. It reuses SSH aliases, configuration, agents, keys, and jump hosts.
The remote host needs Python 3 and a mounted `/proc`; the collector is streamed
over SSH without installing remote files. Authentication uses keys or an agent
(`BatchMode`); verify access with `ssh HOST` first, including host-key trust.

```sh
fremote centre
fremote centre --sort ram --filter python
fremote -J bastion centre
fremote centre --list
fremote --demo
```

With no host, a built-in picker uses `fssh` host discovery. Use `j`/`k` or arrows
to move, `/` to filter by PID/user/name, `s` to sort, `t` for a process tree,
and `[`/`]` to scroll the inspector. Tabs `1`–`4` show all processes, your
processes, CPU order, or memory order. CPU usage is sampled between snapshots;
100% means one occupied core, and the first sample shows `--`.

Space marks processes. `d` requests SIGTERM and `K` requests SIGKILL; both need
an explicit `y` confirmation and neither attempts elevation. Signalling requires
remote Python 3.9+ and Linux pidfd support. The collector checks process start
time after opening a pidfd to reject reused PIDs. Init and the monitoring session
are protected. Disconnected snapshots remain visible, with process actions
disabled. `r` refreshes a live session or reconnects a failed session; `q` exits.

Deploy `fremote.lua`, `fremote_native.lua`, and `fremote_collector.py` together
with the platform launcher. Existing deploy scripts copy these files from `bin`.

### Network diagnostics

`fnet` inspects adapters, resolves names, pings hosts, and scans TCP ports without
external binaries. Windows uses the ICMP API; Linux uses unprivileged ICMP, which
needs `cap_net_raw` or root. Use `--tcp` to measure handshakes when ICMP is blocked.

```sh
fnet ifaces
fnet dns example.com --reverse
fnet ping example.com -c 4
fnet scan 192.168.1.10 --ports 22,80,443 --open-only
fnet check example.com
```

Add `--json` for machine-readable output, and run `fnet --test` for the self-tests.
Windows adapter listing reports IPv4 only; DNS, ping, and scanning handle IPv6.

## Running tests

With Python 3, LuaJIT, and Git on `PATH`, run:

```sh
python -m unittest discover -s tests -v
```

On Windows, the transfer regression tests also need MinGW GCC/Clang on `PATH`
or an MSVC developer shell. They compile a small native argument-capture fixture
in a temporary directory. The tests use isolated Git repositories and transfer
stubs; they do not connect to SSH servers. Windows junction tests run only on
Windows.

## Personal Git settings

[.gitconfig](.gitconfig) includes `~/.gitconfig.local` for machine-specific overrides, such as your commit identity:

```ini
[user]
    name = Your Name
    email = you@example.com
```

## Further reading

- [CLI power-user guide](cli_power_user_guide.md)
- [Proposed improvements](PROPOSED_IMPROVEMENTS.md)
