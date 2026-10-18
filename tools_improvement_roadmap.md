# Workbench Tools Improvement & Modernization Roadmap

*Generated: 2026-10-17*

This document provides a comprehensive audit of the command-line tools and utilities in [`bin/`](bin/), their current implementation status, technical limitations, and prioritized recommendations for modernizing them into the high-performance LuaJIT + FFI architecture.

---

## 1. High-Priority Modernizations: Standalone TUI Upgrades

These utilities currently fork external `fzf` subshells via `io.popen` rather than using the repository's native, zero-dependency dual-pane TUI engine.

| Tool | Current State | Defect / Limitation | Recommended Improvement |
| :--- | :--- | :--- | :--- |
| **[`fkill`](bin/fkill.lua)** | Calls external `fzf` via subshell | Hard dependency on `fzf.exe`; slower process preview generation via subprocess piping. | **Build standalone dual-pane TUI** (similar to [`fport`](bin/fport.lua)):<br>• Left pane: Process tree with PID, user, memory, CPU, and command line.<br>• Right pane: Instant in-memory process environment, open handles, loaded modules, and parent/child hierarchy.<br>• Interactive controls: `Enter` to terminate, `9`/`D` to force kill (SIGKILL), multi-select batch kill with `Tab`. |
| **[`fcd`](bin/fcd.lua)** | Calls external `fzf` via subshell | Requires `fzf` installed on the host to jump directories interactively. | **Add standalone built-in TUI mode**:<br>• Left pane: Directory tree with depth indentation and subfolder count.<br>• Right pane: Instant file preview card, permissions, disk usage, and child file drill-down.<br>• Retains stdout piping (`fcd() { cd "$(fcd -l)" }`) for non-interactive shell integration. |
| **[`fscp`](bin/fscp.lua)** vs **[`fscp_tui`](bin/fscp_tui.lua)** | Two split implementations | [`fscp.lua`](bin/fscp.lua) (41 KB) relies on `fzf`, while [`fscp_tui.lua`](bin/fscp_tui.lua) (128 KB) has a full TUI. Dual-maintenance overhead. | **Consolidate into a single `fscp.lua`**:<br>• Default to the full interactive dual-pane TUI.<br>• Support `--fzf` or pipeline fallback for scripting. |

---

## 2. Redundant Legacy Scripts Ready for Consolidation

These older batch, shell, and Python scripts have already been superseded by modern LuaJIT tools and can be safely redirected or cleaned up.

| Script | Status | Superseded By | Recommendation |
| :--- | :--- | :--- | :--- |
| **[`gbd.bat`](bin/gbd.bat)** & **[`gdbf.bat`](bin/gdbf.bat)** | Retired | [`fbr.bat`](bin/fbr.bat) / [`fbr.lua`](bin/fbr.lua) | Removed in favor of native [`fbr`](bin/fbr.lua) branch manager. |
| **[`gcb.bat`](bin/gcb.bat)** & **[`gcbf.bat`](bin/gcbf.bat)** | Retired | [`fco.bat`](bin/fco.bat) / [`fco.lua`](bin/fco.lua) | Removed in favor of native [`fco`](bin/fco.lua) checkout selector. |
| **[`putty_colors.py`](bin/putty_colors.py)** & **[`putty_sessions.py`](bin/putty_sessions.py)** | Retired | [`putty.lua`](bin/putty.lua) (Win32 Registry FFI) | Removed in favor of native Win32 FFI [`putty.lua`](bin/putty.lua). |
| **[`sync_folder.ps1`](bin/sync_folder.ps1)** | PowerShell script (~1s cold start) | None yet | Rewrite into **`sync_folder.lua`** using native Win32 FFI and Robocopy streaming. |

---

## 3. Deployment Script Gaps ([`deploy.bat`](deploy.bat) & [`deploy.sh`](deploy.sh))

The following configuration files in the repository are currently omitted during automated deployment:

1. **`.wezterm.lua`**:
   - Neither [`deploy.bat`](deploy.bat) nor [`deploy.sh`](deploy.sh) deploys `.wezterm.lua` to `%USERPROFILE%\.wezterm.lua` or `$HOME/.wezterm.lua`.
2. **`.config/starship.toml`**:
   - [`deploy.bat`](deploy.bat) does not deploy Starship prompt config to `%USERPROFILE%\.config\starship.toml`.
3. **New Binary Executables**:
   - Ensure [`deploy.sh`](deploy.sh) applies `chmod +x` to all newly created wrappers ([`fe`](bin/fe), [`fe.sh`](bin/fe.sh), [`fbr.sh`](bin/fbr.sh), [`fhist.sh`](bin/fhist.sh), [`fco.sh`](bin/fco.sh)).

---

## 4. Prioritized Implementation Roadmap

### Phase 1: High-Impact Upgrades
- [x] **Modernize `fkill.lua`**: Implement native zero-dependency dual-pane TUI with real-time process monitoring, memory/CPU statistics, and process tree visualization. *(Shipped)*
- [ ] **Synchronize Deployment Scripts**: Add `.wezterm.lua` and `.config/starship.toml` to [`deploy.bat`](deploy.bat) and [`deploy.sh`](deploy.sh).

### Phase 2: Consolidation & Legacy Cleanup
- [x] **Retire Redundant Git Scripts**: Removed legacy `gbd.bat`, `gcb.bat`, `gcbf.bat`, and `gdbf.bat` (fully replaced by `fbr` and `fco`).
- [x] **Retire Legacy PuTTY Python Scripts**: Removed `putty_colors.py` and `putty_sessions.py`, updated launchers to native `putty.lua`.
- [ ] **Merge `fscp.lua` and `fscp_tui.lua`**: Unify into a single, cohesive tool.
- [ ] **Modernize `fcd.lua`**: Add standalone TUI mode while maintaining shell pipeline compatibility.

### Phase 3: New Zero-Dependency Utilities
- [ ] **`winclip.lua` / `clip.lua`**: Unified clipboard bridge (direct Win32 `user32.dll` on Windows, OSC 52 over SSH/tmux, `wl-copy`/`xclip` on Linux).
- [ ] **`fswatch.lua`**: Ultra-lightweight background file watcher using Win32 `ReadDirectoryChangesW` and Linux `sys/inotify.h`.
- [ ] **`sync_folder.lua`**: Fast folder synchronization tool replacing [`sync_folder.ps1`](bin/sync_folder.ps1).
