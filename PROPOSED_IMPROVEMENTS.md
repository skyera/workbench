# Proposed Improvements for Workbench

Based on the codebase review, here are the suggested enhancements categorized by area.

## 1. Deployment & Infrastructure
- [ ] **Sync `deploy.sh` with Repository**: Update the script to include missing files like `.wezterm.lua`, `.gdbinit`, and `.config/yazi/yazi.toml`.
- [x] **Tool Installer Script**: Create `bin/install-tools.sh` to automate the installation of dependencies (`fd`, `rg`, `bat`, `delta`, `eza`, `zoxide`, `yazi`) across different Linux distributions via GitHub releases, source, or package managers.

## 2. Shell & CLI Enhancements (`mybashrc`)
- [ ] **Enhanced Git Aliases**: Add more advanced aliases for `delta` (e.g., side-by-side diff toggles) and `forgit` integrations.
- [ ] **FZF Process Manager**: A smarter `fkill` with more details and multi-select capabilities.
- [ ] **Directory History**: Integrate `zoxide` more deeply with an interactive `zi` command.

## 3. Neovim Modernization (`.config/nvim`)
- [ ] **Enable Treesitter**: Fix and enable the `nvim-treesitter` configuration for superior syntax highlighting.
- [ ] **Add LSP Support**: Integrate `nvim-lspconfig` and `mason.nvim` for IDE-like features (autocompletion, go-to-definition) for C++, Python, and Lua.
- [ ] **Telescope Extensions**: Add `telescope-fzf-native` for significantly faster searching performance.

## 4. Debugging & Git
- [x] **GDB Dashboard**: Enhance `.gdbinit` by integrating [gdb-dashboard](https://github.com/cyrus-and/gdb-dashboard) for a visual debugging interface.
- [x] **Git-Fuzzy Script**: Add a `bin/git-fuzzy` script that uses FZF to browse branches, commits, and stashes interactively.

## 5. Terminal (`.wezterm.lua`)
- [x] **Performance & UI Tweaks**: Fixed `update-status` layout thrashing loop, enabled Kitty keyboard protocol, added tmux-style leader bindings (`LEADER` + `hjkl`/`x`/`z`/`1-9`), updated Windows default shell to PowerShell, and refined Gruvbox tab bar colors.
