# LuaJIT & FFI Script Modernization Guide

This document outlines high-value opportunities to rewrite existing utility scripts or introduce new utilities using **LuaJIT** and its **Foreign Function Interface (FFI)**.

---

## 1. Why LuaJIT + FFI?

| Metric / Capability | Python | PowerShell | Bash / Batch | LuaJIT + FFI |
| :--- | :--- | :--- | :--- | :--- |
| **Cold Startup Time** | ~30–70 ms | ~500–1500 ms | ~100–300 ms (Windows) | **~1–2 ms** |
| **FZF Live Preview** | Noticeable latency | Unusable | Moderate latency | **Instantaneous (60 FPS)** |
| **Native OS API Access** | `ctypes` / `winreg` | Native .NET | Process wrappers (`tasklist`, etc.) | **Zero-overhead C ABI via `ffi.cdef`** |
| **Memory Footprint** | ~15–30 MB | ~50–120 MB | ~5–10 MB | **< 3 MB** |
| **Neovim Integration** | Subprocess / RPC | Not integrated | Subprocess | **Native shared code (embedded LuaJIT)** |

---

## 2. High-Value Candidates to Rewrite

### 2.1. [fkill.bat](file:///home/zliu/test/utils/bin/fkill.bat) $\rightarrow$ `fkill.lua`
* **Current Issue:**
  * In [fkill.bat#L27](file:///home/zliu/test/utils/bin/fkill.bat#L27), FZF runs `--preview="tasklist /fi \"PID eq {2}\" /fo list 2>nul"`.
  * `tasklist.exe` relies on slow WMI/RPC queries taking 150–250 ms *per preview execution*, causing significant stutter when navigating processes.
* **LuaJIT / FFI Solution:**
  * **Windows:** Use `kernel32.dll` via FFI (`CreateToolhelp32Snapshot`, `Process32FirstW` / `Process32NextW`, `OpenProcess`, `QueryFullProcessImageNameW`, and `TerminateProcess`).
  * **Linux:** Read `/proc/<pid>/status` and `/proc/<pid>/cmdline` directly without spawning subshells.
* **Impact:** Process listing and preview latency drop from ~250 ms to $< 1\text{ ms}$, delivering seamless real-time scrolling in `fzf`.

```lua
-- Example Win32 Toolhelp32 FFI snippet
local ffi = require("ffi")
ffi.cdef[[
    typedef void* HANDLE;
    typedef unsigned long DWORD;
    typedef struct {
        DWORD dwSize;
        DWORD cntUsage;
        DWORD th32ProcessID;
        uintptr_t th32DefaultHeapID;
        DWORD th32ModuleID;
        DWORD cntThreads;
        DWORD th32ParentProcessID;
        long pcPriClassBase;
        DWORD dwFlags;
        wchar_t szExeFile[260];
    } PROCESSENTRY32W;
    HANDLE CreateToolhelp32Snapshot(DWORD dwFlags, DWORD th32ProcessID);
    int Process32FirstW(HANDLE hSnapshot, PROCESSENTRY32W* lppe);
    int Process32NextW(HANDLE hSnapshot, PROCESSENTRY32W* lppe);
    int CloseHandle(HANDLE hObject);
]]
```

---

### 2.2. [fssh.py](file:///home/zliu/test/utils/bin/fssh.py) (Host Aggregator & Preview Engine)
* **Current Issue:**
  * [fssh.py](file:///home/zliu/test/utils/bin/fssh.py#L15) supports `--preview-only <HOST>` to render detailed preview cards inside `fzf`.
  * Every cursor movement in `fzf` forks a new Python interpreter.
* **LuaJIT / FFI Solution:**
  * Fast pattern matching for `~/.ssh/config`, `known_hosts`, and `/etc/hosts`.
  * On Windows, query PuTTY sessions directly from registry (`HKCU\Software\SimonTatham\PuTTY\Sessions`) via `advapi32.dll` (`RegOpenKeyExA`, `RegEnumValueA`) without calling Python or `reg.exe`.
* **Impact:** Eliminates Python startup overhead entirely; FZF host preview displays instantaneously.

---

### 2.3. [clean_c_drive.ps1](file:///home/zliu/test/utils/bin/clean_c_drive.ps1) $\rightarrow$ `clean_c_drive.lua`
* **Current Issue:**
  * PowerShell takes ~1 s to initialize, and `Get-ChildItem -Recurse | Measure-Object` incurs high overhead when recursively traversing large directory trees (Temp, Windows Update Cache, WER logs).
* **LuaJIT / FFI Solution:**
  * Traverse directories using `FindFirstFileW` / `FindNextFileW` in `kernel32.dll`.
  * Query and empty the Recycle Bin directly with `SHEmptyRecycleBinW` (`shell32.dll`).
* **Impact:** Fast scanning of 50,000+ files in under 50 ms with negligible memory usage.

---

### 2.4. [osc52-yank.sh](file:///home/zliu/test/utils/bin/osc52-yank.sh) / Clipboard Bridge $\rightarrow$ `clip.lua`
* **Current Issue:**
  * [osc52-yank.sh](file:///home/zliu/test/utils/bin/osc52-yank.sh#L9) forks `cat`, `base64`, `tr`, and `printf`. On Windows/WSL/Git Bash, each fork carries noticeable process creation latency.
* **LuaJIT / FFI Solution:**
  * Pure Lua/FFI Base64 encoding in memory, sending `\033]52;c;<base64>\a` directly to terminal output.
  * Universal cross-platform clipboard provider:
    * **Windows:** Direct `user32.dll` calls (`OpenClipboard`, `SetClipboardData`, `GetClipboardData`).
    * **SSH / Remote:** OSC 52 ANSI sequences.
    * **Linux Local:** Pipe to `wl-copy` / `xclip`.
* **Impact:** Zero-dependency clipboard utility that can also serve as Neovim's `g:clipboard` provider, eliminating the need for `win32yank.exe`.

---

### 2.5. [putty_colors.py](file:///home/zliu/test/utils/bin/putty_colors.py) & [putty_sessions.py](file:///home/zliu/test/utils/bin/putty_sessions.py)
* **Current Issue:**
  * Theme switching and previewing in `putty_colors.py` require Python with `winreg`.
* **LuaJIT / FFI Solution:**
  * Store color presets in clean Lua tables.
  * Apply directly to registry keys using `advapi32.dll` FFI calls.
  * Preview themes in true-color terminal sessions without Python dependency.

---

## 3. Scripts to Retain As-Is (Not Worth Rewriting)

| Script | Reason to Keep As-Is |
| :--- | :--- |
| [dotag.py](file:///home/zliu/test/utils/bin/dotag.py) | The performance bottleneck is external indexing tools (`ctags`, `gtags`, `cscope`), not Python. Python's `ThreadPoolExecutor` is clean and effective. |
| [deploy_gui.py](file:///home/zliu/test/utils/deploy_gui.py) | GUI frameworks (Tkinter/PyQt) are already available in Python. Writing GUIs in LuaJIT FFI requires complex raw Win32 / C bindings. |
| [machine_report.sh](file:///home/zliu/test/utils/bin/machine_report.sh) | Designed as a portable POSIX/Bash audit script to run on remote Linux/BSD systems without needing LuaJIT pre-installed. |

---

## 4. High-Impact New Utilities to Add with LuaJIT/FFI

### 4.1. `winclip.lua` (Unified Zero-Dependency Clipboard)
* **Goal:** A lightweight, single-file clipboard tool for Windows and terminal multiplexers.
* **Capabilities:**
  * Replaces `win32yank.exe` or `clip.exe`.
  * Can be registered directly in Neovim's `init.lua`:
    ```lua
    vim.g.clipboard = {
      name = 'luaclip',
      copy = { ['+'] = 'luajit C:/app/bin/winclip.lua --copy', ['*'] = 'luajit C:/app/bin/winclip.lua --copy' },
      paste = { ['+'] = 'luajit C:/app/bin/winclip.lua --paste', ['*'] = 'luajit C:/app/bin/winclip.lua --paste' },
    }
    ```

### 4.2. `fswatch.lua` (Ultra-Lightweight File Watcher)
* **Goal:** Monitor directory changes and automatically trigger build, test, or [dotag.py](file:///home/zliu/test/utils/bin/dotag.py) runs.
* **Capabilities:**
  * Uses `ReadDirectoryChangesW` on Windows and `sys/inotify.h` on Linux.
  * Zero node.js/Python dependencies, running continuously at $< 5\text{ MB}$ memory.

### 4.3. `termprobe.lua` (Fast Terminal & Console Inspector)
* **Goal:** Query terminal size, cursor coordinates, and RGB color capability without shelling out.
* **Capabilities:**
  * Uses `GetConsoleScreenBufferInfo` / `SetConsoleMode` on Windows and `ioctl(TIOCGWINSZ)` / `termios` on Linux.

### 4.4. `fscp.lua` / `frsync.lua` (Interactive Remote File Transfer)
* **Goal:** Zero-friction remote file transfer (SCP & Rsync) across Linux and Windows.
* **Capabilities:**
  * Aggregates hosts from SSH config, known_hosts, PuTTY sessions (Win32 Registry FFI), and hosts files.
  * Sub-millisecond FZF preview card generator (< 1 ms).
  * Interactive multi-select file picker with auto-fallback to native `scp`, `rsync`, or `pscp.exe`.

### 4.5. `rfe.lua` (Interactive Remote Server Browser & Previewer, alias `rbrowse`)
* **Goal:** Real-time remote file tree browsing with live syntax-highlighted text and terminal image previewing.
* **Capabilities:**
  * Dual-pane TUI running natively on Linux and Windows without external dependencies.
  * Full file and folder icons: Nerd Fonts, Unicode Emoji, and ASCII fallback with dynamic visual column alignment.
  * Live text previewing with head-streaming, syntax highlighting, and smooth viewport scrolling.
  * Live image previewing: Universal 24-bit Truecolor Half-Blocks (`▀`) via ImageMagick (`magick` / `convert`) or WezTerm / iTerm2 inline graphics protocol (`OSC 1337`).
  * In-memory binary image header parser (PNG, JPEG, GIF, BMP) for instant dimension inspection.
  * Persistent SSH multiplexing (`ControlMaster`/`ControlPath`) for sub-10ms directory drill-downs.
  * Offline `--demo` mode and CLI headless preview mode (`--preview <host> <path> [w] [h]`) for integration with `fzf`, `lf`, and `ranger`.


