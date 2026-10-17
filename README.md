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
- Connecting to hosts, copying files, and opening tunnels (`fssh`, `fscp`, `fssh_tunnel`).
- Working with Git and source indexes (`fco`, `flog`, `fbr`, `dotag`).
- Managing shell history, processes, clipboard access, and remote mounts (`fhist`, `fkill`, `osc52-yank`, `rsshfs`).

Many tools have platform-specific implementations in shell, batch, Lua, PowerShell, or Python. Check the selected script for its dependencies and options.

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
