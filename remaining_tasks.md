# Remaining Workbench Improvements & Roadmap Status

*Generated: 2026-10-17*

This document outlines the remaining modernization tasks, legacy script retirements, deployment synchronizations, and proposed zero-dependency utilities for the workbench repository.

---

## 1. High-Priority Modernizations: Standalone TUI Upgrades

### `fcd.lua` — Dual-Pane Interactive Directory Jumper

* **Current Implementation**:
  - [`bin/fcd.lua`](bin/fcd.lua) (19.4 KB) crawls recent and pinned directories, but delegates interactive selection to an external `fzf` subshell via `io.popen`.
* **Limitations**:
  - Hard dependency on `fzf` being installed in the path.
  - No directory content preview or disk usage breakdown.
  - Subprocess pipe overhead on Windows `cmd.exe`.
* **Proposed Design**:
  - **Left Pane**: Interactive directory tree with indentation, folder icon indicators, depth indicators, and pinned bookmarks.
  - **Right Pane**: Instant in-memory directory preview card (item count, total directory size, last modified timestamp, and list of child files/subfolders).
  - **Keybindings**: Standard Vim navigation (`j`/`k`, `Enter` to drill down, `Backspace` to parent, `Tab` to select, `/` to filter, `q` to quit).
  - **Shell Integration**: Preserve stdout output so `fcd` functions (`cd "$(fcd -l)"` in Bash and `fcd.bat` in Windows) continue to work seamlessly.
* **Verification Strategy**:
  - Automated tests via `luajit bin/fcd.lua --test`.
  - Validate non-interactive stdout output mode (`fcd -l`) for shell wrappers.

---

## 2. Deployment Script Synchronization

### [`deploy.bat`](deploy.bat) & [`deploy.sh`](deploy.sh) Gaps

During repository auditing, several key configuration files were found to be missing from the automated deployment scripts:

| Configuration File | Missing Deployment Target | Action Required |
| :--- | :--- | :--- |
| **`.wezterm.lua`** | `%USERPROFILE%\.wezterm.lua` / `$HOME/.wezterm.lua` | Add file copy step to both `deploy.bat` and `deploy.sh`. |
| **`.config/starship.toml`** | `%USERPROFILE%\.config\starship.toml` / `$HOME/.config/starship.toml` | Add folder creation and copy step to `deploy.bat` and `deploy.sh`. |
| **New Binary Wrappers** | Linux `/usr/local/bin` or `~/bin` | Update `deploy.sh` to apply `chmod +x` to [`fe`](bin/fe), [`fe.sh`](bin/fe.sh), [`fbr.sh`](bin/fbr.sh), [`fhist.sh`](bin/fhist.sh), [`fco.sh`](bin/fco.sh), [`fkill`](bin/fkill), [`fkill.sh`](bin/fkill.sh), [`fscp.sh`](bin/fscp.sh). |

---

## 3. Legacy Script Retirement (Superseded by LuaJIT FFI)

The following older Python and PowerShell scripts are now obsolete and can be safely retired:

| Legacy Script | Superseded By | Reason & Action |
| :--- | :--- | :--- |
| ~~**`bin/fssh.py`** (24.5 KB)~~<br>~~**`bin/fssh.ps1`**~~ | [`bin/fssh.lua`](bin/fssh.lua) (30.8 KB) | **Retired**: Removed `fssh.py` and `fssh.ps1`, eliminated Python fallbacks in `fssh.bat` and `fssh.sh`, added automated `--test` suite. |
| **[`bin/dotag.py`](bin/dotag.py)** (15.2 KB) | [`bin/dotag.lua`](bin/dotag.lua) (81.6 KB) | Native LuaJIT implementation has full feature parity with zero Python dependencies. Remove `dotag.py`. |
| ~~**`bin/clean_c_drive.ps1`** (4.4 KB)~~ | [`bin/clean_c_drive.lua`](bin/clean_c_drive.lua) (21.4 KB) | **Retired**: Removed `clean_c_drive.ps1`, eliminated PowerShell fallback in `clean_c_drive.bat`, added dual-stream console VT init and automated `--test` suite. |

---

## 4. Proposed Zero-Dependency Utilities (Phase 3)

### 1. `winclip.lua` / `clip.lua` — Universal Clipboard Bridge
* **Problem**: Windows `clip.exe` strips formatting and has non-zero exit lag; PowerShell `Get-Clipboard` has ~1s cold-start; SSH/tmux sessions often break clipboard access.
* **Solution**:
  - **Windows**: Direct Win32 `user32.dll` FFI (`OpenClipboard`, `GetClipboardData`, `SetClipboardData`, `EmptyClipboard`). Zero subprocess spawn overhead (< 1 ms).
  - **Terminal / Remote**: Emit OSC 52 ANSI escape sequences for bidirectional clipboard synchronization over SSH, WezTerm, Alacritty, and Neovim.
  - **Linux**: Fallback to `wl-copy` (Wayland) and `xclip` (X11).

### 2. `sync_folder.lua` — Ultra-Fast Folder Synchronization
* **Problem**: [`bin/sync_folder.ps1`](bin/sync_folder.ps1) relies on Windows PowerShell and lacks streaming progress or cross-platform POSIX support.
* **Solution**:
  - Native LuaJIT tool with Win32 Robocopy streaming engine on Windows.
  - Rsync bridge on Linux/POSIX.
  - Sub-second directory tree diff comparison via Win32 FFI `FindFirstFileA` / POSIX `opendir`.

### 3. `fswatch.lua` — Lightweight Background File Watcher
* **Problem**: Modern file watchers (e.g., `chokidar`, `watchexec`) require heavy Node.js or Rust runtimes.
* **Solution**:
  - Windows: Win32 `ReadDirectoryChangesW` asynchronous I/O completion port via FFI.
  - Linux: Linux kernel `sys/inotify.h` FFI.
  - Features: Debounced triggering, glob pattern matching, and minimal CPU footprint (< 0.1%).

---

## Summary of Shipped Work to Date
- [x] **`fkill.lua`**: Native zero-dependency dual-pane TUI process manager with real-time statistics, process tree hierarchy, and Vim navigation. *(Shipped `706d2a6`, `2439011`)*
- [x] **Redundant Git Scripts**: Retired `gbd.bat`, `gcb.bat`, `gcbf.bat`, and `gdbf.bat` in favor of `fbr` and `fco`. *(Shipped `2368724`)*
- [x] **PuTTY Management**: Fixed theme discovery (618+ themes in ~79 ms) and retired legacy `putty_colors.py` / `putty_sessions.py`. *(Shipped `fa79270`)*
- [x] **`fscp.lua` Consolidation**: Unified `fscp_tui.lua` and `fscp.lua` into a single Dual-Pane TUI default tool with `--fzf` mode and headless CLI support. *(Shipped `91fea9b`)*
- [x] **`fssh` Modernization**: Retired legacy `fssh.py` and `fssh.ps1`, streamlined wrappers to native `fssh.lua`, added automated test suite. *(Shipped `b9a1f0e`)*
- [x] **`clean_c_drive.ps1` Retirement**: Removed legacy PowerShell script, streamlined `clean_c_drive.bat` to `clean_c_drive.lua`, added dual-stream console init and automated `--test` suite. *(Completed)*
