# Personal Dev Notes

---

## Shell & Terminal Environment

### Bash Config
```bash
export TERM=tmux-256color
export PROMPT_DIRTRIM=2
export NEOVIM_BIN="/home/user/app/nvim-linux-x86_64/bin/nvim"

# autojump: cd first
[[ -s /usr/share/autojump/autojump.sh ]] && source /usr/share/autojump/autojump.sh

# zoxide
eval "$(zoxide init bash)"

alias reload='source ~/.bashrc'
```

### Docker Helper
```bash
dexec() {
    local cid=$(docker ps --format '{{.Names}}' | grep ${USER}|fzf)
    [ -n "$cid" ] && docker exec -it -u ${USER} "$cid" bash
}
```

### Nerd Fonts
```bash
# Linux (Release archive - all variations)
mkdir -p ~/.local/share/fonts
curl -sSLo /tmp/Hack.tar.xz https://github.com/ryanoasis/nerd-fonts/releases/latest/download/Hack.tar.xz
tar -xJf /tmp/Hack.tar.xz -C ~/.local/share/fonts --wildcards "*.ttf"
rm /tmp/Hack.tar.xz
fc-cache -f ~/.local/share/fonts

# Linux (Single font)
curl -fLO https://github.com/ryanoasis/nerd-fonts/raw/HEAD/patched-fonts/Hack/HackNerdFont-Regular.ttf

# macOS (Homebrew)
brew tap homebrew/cask-fonts
brew install --cask font-jetbrains-mono-nerd-font

# Windows
choco install nerd-fonts-hack
```

### Alacritty
Config path: `AppData\Roaming\alacritty\alacritty.toml`
```toml
[env]
TERM = "xterm-256color"
[font]
normal = {family="Hack Nerd Font Mono", style="Regular"}
bold = {family="Hack Nerd Font Mono", style="Bold"}
italic = {family="Hack Nerd Font Mono", style="Italic"}
size = 11.0
```

### WezTerm
```
* Ctrl-Tab: Navigate tabs
* copy inside vim: Press Shift, use mouse to select
* Use mouse to select: copied to clipboard
* export DISPLAY or unset DISPLAY
```

Disable xterm mouse tracking modes:
```bash
printf '\e[?1000l\e[?1002l\e[?1003l\e[?1006l'
```

### tmux
```
:capture-pane                  copy visible content to buffer
:capture-pane -b temp-buffer -S - -E -
:capture-pane -b temp-buffer -S -100
:save-buffer /path/to/your/file.txt

# -S - : capture from start of scrollback history
# -E - : capture to end of history

tmux capture-pane -S - \; save-buffer - \; delete-buffer | xclip -selection clipboard
```

#### Capture Pane to File
```bash
# Save visible content
tmux capture-pane -p > output.txt

# Save full scrollback history
tmux capture-pane -p -S - > output.txt

# Save with ANSI colors / formatting retained
tmux capture-pane -e -p -S - > output.txt
```

From tmux command prompt (`Ctrl+b` then `:`):
```text
capture-pane -S - ; save-buffer output.txt
```

Option & Line Range Explanations:
* **Line Indexing Rules**:
  * `0`: Top line of current visible pane screen.
  * `-N`: Negative line numbers go back into scrollback history (e.g., `-500` captures last 500 lines).
  * `-S -`: Start from beginning of scrollback history.
  * `-E -`: End at bottom of visible pane.
* **Flags**:
  * `-p`: Output directly to stdout (allowing file redirection via `>`).
  * `-S start-line`: Specify starting line.
  * `-E end-line`: Specify ending line (e.g. `-S -1000 -E -200`).
  * `-J`: Join wrapped lines to preserve long lines without artificial breaks.
  * `-e`: Include ANSI color escape codes in output.

Key binding in `~/.tmux.conf`:
```tmux
bind-key P command-prompt -p 'Save pane history to:' -I '~/tmux.log' 'capture-pane -S -; save-buffer "%1"; delete-buffer'
```


### Terminal Images & Video
```
catimg
chafa
timg
feh: X11 image viewer
```

Play video in terminal:
```bash
mpv --no-config --vo=tct <your videofile>
mpv --video-rotate=270
```

### macOS .zprofile
```bash
export DYLD_LIBRARY_PATH="/opt/homebrew/lib/:$DYLD_LIBRARY_PATH"
```

### Termux for Vim
```bash
export TERM=xterm-256color
```

### ttyd
Share a terminal or tmux session over the web.

#### Basic Usage
Start ttyd with basic authentication and write access (allowing clients to type):
```bash
ttyd -W -p 9000 -c admin:admin tmux attach -t test
```

To shut down `ttyd` (if running in the foreground, press `Ctrl+C`; otherwise kill the process):
```bash
killall ttyd
```

#### Startup Script
A helper script is available under `bin/start_ttyd.sh`. It automatically checks if the `test` tmux session exists, creates it if it is missing, and starts `ttyd` as readonly:
```bash
./bin/start_ttyd.sh
```

#### Shared Collaborative Session
To allow multiple clients (and you locally) to type and collaborate in the same tmux session:
```bash
ttyd -W tmux new -A -s test bash
```

#### Useful Options & Tips
* **Write Access** (essential as ttyd is readonly by default in v1.7.4+):
  Use the `-W` or `--writable` flag to allow client input.
* **Read-Only Mode** (explicitly disable input or omit `-W`):
  ```bash
  ttyd -p 9000 tmux attach -t test
  ```
* **Bind to Localhost Only** (essential if running behind a reverse proxy like Nginx):
  ```bash
  ttyd -W -i 127.0.0.1 -p 9000 tmux attach -t test
  ```
* **Secure with SSL/TLS** (enable HTTPS directly):
  ```bash
  ttyd -W --ssl --ssl-cert cert.pem --ssl-key key.pem -p 9000 bash
  ```
* **Run a Specific Utility** (e.g., share a real-time monitor rather than a shell):
  ```bash
  ttyd -p 9000 htop
  ```
* **Custom Client/UI Options** (configure font size, cursor blink, etc.):
  ```bash
  ttyd -W -t fontSize=14 -t cursorBlink=true bash
  ```

---

## Editors

### Vim
```vim
if exists('g:loaded_webdevicons')
    call webdevicons#refresh()
endif

" Enable mouse in alacritty
set ttymouse=sgr

" Rg search ignoring .gitignore
:Rg --no-ignore <pattern>
```

### Neovim
```
telescope
* <C-q> send all to quickfix
* <M-q> send selected to quickfix
```

### Vim Wiki
```
<leader>ww        goto home
<leader>w<leader>w goto today
```

---

## File Managers

### Ranger
```bash
git clone https://github.com/alexanderjeurissen/ranger_devicons ~/.config/ranger/plugins/ranger_devicons
```

Commands:
```
yp:              copy full path to clipboard
ctrl + n:        open a new tab
ctrl + w:        close current tab
Tab:             switch to next tab
Shift + Tab:     switch to previous tab
Space:           mark file
V:               toggle visual mode selection
uv:              unmark files
h:               goto parent directory (move left)
l:               enter a directory (move right)
yy:              copy files
dd:              cut files
pp:              paste files
o:               open sort menu
i:               preview file
E:               edit file

:filter <pat>
:filter \.c
:reset

# rename files
select files using Space
Type :bulkrename
Edit in text editor, exit

ya:              select files to copy
yy
uy:              unselect files
zd:              set sort_directories_first!
```

#### scope.sh
```bash
# preview image
chafa -c 256 -s "${PV_WIDTH}x${PV_HEIGHT}" "${FILE_PATH}" && exit 4
exit 1;;

# show line number
env COLORTERM=8bit bat --color=always --style="plain,numbers" \
    -- "${FILE_PATH}" && exit 5

# .config/ranger/rifle.conf, may need
label open, has xdg-open = xdg-open "$@"
```

* fzf + ranger: https://github.com/gotbletu/shownotes/blob/master/ranger_file_locate_fzf.md
* https://obaranovskyi.com/environments/better-terminal-file-management-with-ranger

### lf
Config path:
* Linux: `~/.config/lf/lfrc`
* Windows: `C:\Users\xxx\AppData\Local\lf\lfrc`

Tips:
```
* Use winget to install the latest one, not choco
* delete files: press d, then :delete
* :set sortby ctime
* :set dirfirst!
* press z, s keys
* mA, 'A
* copy files: y, p
* :filter , press ENTER, then inpyt .c
* :setfilter clean filter
* man lf
* copy: y
* cut: d
* paste: p
* rename: r
* jump-next: ]
* jump-prev: [
* invert: v
* unselect: u
* 
]
```

#### lfrc snippets
```
map zh set hidden!
map zr set reverse!
map zn set info
map zs set info size
map zt set info time
map za set info size:time
map sn :set sortby natural; set info
map ss :set sortby size; set info size
map st :set sortby time; set info time
map sa :set sortby atime; set info atime
map sc :set sortby ctime; set info ctime
map se :set sortby ext; set info
map gh cd ~
map <space> :toggle; down
```

* https://github.com/gokcehan/lf/wiki/Integrations
* https://github.com/gokcehan/lf/blob/master/doc.md

### vifm
Config path:
* Linux: `~/.vifm/vifmrc`
* Windows: `C:\Users\xxx\AppData\Roaming\Vifm\vifmrc`
* `export TERM=xterm-256color`

### yazi
Install on Windows:
* `cargo build --profile release-windows --locked`
* `winget`

### exa
```bash
exa --tree
```

---

## Search & Find

### fzf

#### Keybindings
* Ctrl + T — Fuzzy-find files
* Ctrl + R — Fuzzy-search command history
* Alt + C — Fuzzy cd into directory

(These require fzf --key-bindings installed.)

#### Shell Integration
```bash
eval "$(fzf --bash)"
```

#### Environment
```bash
export FZF_DEFAULT_COMMAND="fd --follow --hidden --ignore-file ~/.fdignore"
# on Windows: fd --no-ignore-vcs --type file --follow --hidden --ignore-file c:\users\zliu\.fdignore

export FZF_DEFAULT_OPTS="--preview 'bat --color=always {}'"

export FZF_DEFAULT_COMMAND="fd --hidden --strip-cwd-prefix --exclude .git"
export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
export FZF_ALT_C_COMMAND="fd --type=d --hidden --strip-cwd-prefix --exclude .git"
```

#### Completions
```bash
# Use fd for listing path candidates
_fzf_compgen_path() {
  fd --hidden --exclude .git . "$1"
}

# Use fd for directory completion
_fzf_compgen_dir() {
  fd --type=d --hidden --exclude .git . "$1"
}
```

#### Theme
```bash
fg="#CBE0F0"
bg="#011628"
bg_highlight="#143652"
purple="#B388FF"
blue="#06BCE4"
cyan="#2CF9ED"

export FZF_DEFAULT_OPTS="--color=fg:${fg},bg:${bg},hl:${purple},fg+:${fg},bg+:${bg_highlight},hl+:${purple},info:${blue},prompt:${cyan},pointer:${cyan},marker:${cyan},spinner:${cyan},header:${cyan}"
```

#### cheat.sh + fzf
```bash
fzfc() {
    curl -ks cht\.sh/$(
      curl -ks cht\.sh/:list | \
      IFS=+ fzf --preview 'curl -ks http://cht.sh{}' -q "$*"); }
```

### fd
```
* exclude files or directories:
    --exclude(-E) .git
    -E /mnt/external-drive
* skip file types: fd -E '*.bak'
* delete files: fd -H 'xxxx' -tf -X rm
* in git repos: not search in .gitignore; to disable it, use -I (--no-ignore)
* search all files/dirs: -HI
* exclude patterns in ignore files:
    ~/.fdignore
    ~/.config/fd/ignore
    %APPDATA%\fd\ignore (Windows)
```

Example `.fdignore`:
```
*.bak
```

### ripgrep
```
* RIPGREP_CONFIG_PATH
* $HOME/.ripgreprc
* .config/git/ignore
```

Example `.ripgreprc`:
```
--type-add
web:*.{html,css,js}*

--glob=!.git/*
--smart-case
```

### find
```bash
# Arguments
-type [f|d|l]      # f: file, d: directory, l: symlink
-name, -iname      # match filename (-i: case-insensitive). ALWAYS quote wildcards!
-path              # match full path pattern
-maxdepth N        # limit search depth
-size [+-]N        # match size (e.g. +10M, -1k)
-mtime [+-]N       # match modification time in days (e.g. -7: last 7 days)
-empty             # match empty files/directories
-delete            # delete matching items (CAUTION: runs immediately)
-exec <cmd> {} \;  # run command once per file ({} is placeholder)
-exec <cmd> {} +   # run command in batches (faster)
-print0            # print null-terminated (use with xargs -0)
-prune             # skip a directory entirely (used with -path)

# Examples
find . -type f -name "*.py"                   # Standard search
find . -maxdepth 1 -type f                    # Search current dir only
find . \( -name "*.py" -o -name "*.sh" \)     # OR filter
find . -type f ! -name "*.git*"               # NOT filter
find . -type d -empty -delete                 # Delete empty directories
find . -path "./.git" -prune -o -print        # Prune (skip) .git folder
find . -type f -name "*.txt" -print0 | xargs -0 rm   # Handle spaces safely

# Content search inside found files
find . -type f -name "*.py" -exec grep -H "TODO" {} \;
```

### grep
```bash
# Options
-E, -e        # -E: extended regex; -e: specify pattern (useful for multiple or starting with -)
-i            # ignore case
-C, -A, -B    # -C: Context, -A: After, -B: Before (show lines around the match)
-n            # show line number
-w            # whole word (match only exact word)
-v            # invert match (show lines that do NOT match)
-o            # only matching part (show only the matched string, not the whole line)
-F            # fixed strings (faster, no regex parsing)
-I            # ignore binary files
-r, -R        # recursive search (-R follows symlinks)
-l, -L        # -l: files WITH matches; -L: files WITHOUT matches

# Recursive with filters
grep -rI --exclude-dir={.git,node_modules} --include="*.c" "pattern" .

# Advanced logic
grep "foo" file | grep "bar"          # AND logic
grep -E "foo|bar" file                # OR logic
grep -r -L "Copyright" **/*.c         # find files WITHOUT match

# Examples
grep -r -E "foo|bar" **/*.c
find . -name "*.c" | xargs grep "TODO"
grep -rn --include="*.c" "TODO"
grep -rE "(TODO|FIXME|BUG)" --include="*.c"  # find TODOs in C files

# Pro Tip: Standard vs Pro
# Standard: grep -r "TODO" .
# Pro:      grep -rI --exclude-dir=.git --include="*.c" -w "TODO" .
```

### xargs
```bash
# Parallel Processing (use 4 cores)
find . -name "*.log" | xargs -P 4 -I {} gzip {}

# Interactive Confirmation
find . -name "*.tmp" | xargs -p rm

# Search content in specific files only
find . -type f \( -name "*.env" -o -name "*.config" \) | xargs grep "API_KEY"

# Kill processes by keyword
pgrep -f python | xargs kill -9

# Run multiple commands per item
find . -name "*.sh" | xargs -I {} sh -c 'chmod +x {}; cp {} ~/bin/'

# Download from a list
cat urls.txt | xargs -n 1 curl -O

# Safe handling of spaces (with find -print0)
find . -type f -name "*.txt" -print0 | xargs -0 rm

# Batch copy using target flag (fastest)
find . -name "*.jpg" | xargs cp -t /backup/
```

---

## Version Control

### git
```bash
# Manual .gitconfig location:
# Linux/macOS: ~/.gitconfig
# Windows:     C:\Users\<User>\.gitconfig

# 1. Set your identity once on each machine:
# git config --global user.name "Zhigang"
# git config --global user.email "your-email@example.com"

# 2. Link your repo config (aliases, settings):
# git config --global include.path "C:/test/utils/.gitconfig"

# generate a merge commit
git merge --no-ff <branch>

# reset staging area to match latest commit
git reset --hard

# move branch tip to commit, delete all commits after it
git reset --hard <commit>

# reset current branch to match its remote tracking branch without typing the branch name
git reset --hard @{u}

# recover from submodule issues
git clean -fd
git checkout -f <branch>
```

#### Line Endings (`core.autocrlf`)

LF (`\n`) is the usual Linux line ending; CRLF (`\r\n`) is the traditional Windows line ending.

For text files eligible for normalization, unless `.gitattributes` specifies otherwise:

| Value | When staging (`git add`) | When checking out |
|-------|-------------------------|-------------------|
| `input` | Normalize CRLF to LF | No line-ending conversion |
| `true` | Normalize CRLF to LF | Convert normalized text to CRLF |
| `false` | No automatic conversion | No automatic conversion |

**Recommended for my Linux/Windows workflow:** keep `core.autocrlf=input` on both systems.

```gitconfig
[core]
    autocrlf = input
```

With `input`, a new CRLF text file is staged and committed as LF, while the working file stays CRLF. If the repository already has LF and only the working file's line endings differ, staging normally produces no change to commit. Files already tracked with CRLF are normally preserved by ordinary `git add`; setting `input` does not retroactively normalize them.

To explicitly normalize an existing file, stage it again and inspect the result:

```bash
git add --renormalize path/to/file
git diff --cached -- path/to/file
```

This normalizes the staged content according to the active attributes and configuration without rewriting the working file. Binary files and files marked `-text` are excluded.

For a shared repository policy, commit these rules in `.gitattributes`:

```gitattributes
* text=auto eol=lf
*.bat text eol=crlf
*.cmd text eol=crlf
```

These rules store normalized text as LF in Git, check general text files out as LF, and check Windows batch files out as CRLF. Simple LF-only batch files can run in `cmd.exe`, but CRLF is the compatibility choice. Configure the editor to save general code as LF and batch files as CRLF.

`core.eol` chooses checkout line endings for normalized text when attributes do not specify them, but `core.autocrlf=input` or `true` overrides it. Thus `core.eol=lf` is redundant alongside `autocrlf=input`; explicit `.gitattributes` rules take precedence.

Inspect the effective settings and a file's line endings:

```bash
git config --show-origin --get core.autocrlf
git ls-files --eol -- path/to/file
git check-attr text eol -- path/to/file
```

Example output from `git ls-files --eol` for a normalized file with CRLF in the working tree:

```text
i/lf    w/crlf  attr/                  path/to/file
```

`i/lf` describes the index (staged content); `w/crlf` describes the working file.

References: [Git configuration](https://git-scm.com/docs/git-config#Documentation/git-config.txt-coreautoCRLF), [Git attributes](https://git-scm.com/docs/gitattributes#_checking_out_and_checking_in).

#### Add, Commit, Push Workflow
```bash
# Stage all changes in the current directory
git add .

# Stage a specific file
git add path/to/file.txt

# Stage interactively (hunk by hunk)
git add -p

# Commit with a message
git commit -m "feat: add user authentication"

# Stage and commit all tracked files in one step
git commit -am "fix: resolve null pointer exception"

# Amend the last commit (message or additional changes)
git commit --amend -m "feat: add user authentication and session management"
git commit --amend --no-edit   # keep the same message

# Push to the default remote and branch
git push

# Push a new local branch to remote for the first time
git push -u origin feature-branch

# Force push (use with caution — rewrites remote history)
git push --force-with-lease

# Typical daily workflow
git add .
git commit -m "describe your change"
git push
```

* **`.gitmessage` template:** Put a commit message template in the repo root and reference it via `git config commit.template .gitmessage` for consistent formatting.
* **Good commit messages:** Use imperative mood (`Add` not `Added`), keep the subject under 50 chars, and leave a blank line before the body if you add details.

### git diff with meld
```bash
git config --global diff.tool meld
git config --global difftool.meld.cmd 'meld "$LOCAL" "$REMOTE"'
git config --global difftool.prompt false  # Optional: skips the "Launch meld?" prompt

git difftool commit1 commit2      # open file by file
git difftool -d commit1 commit2  # compare directory
git difftool -d main feature-branch

git diff commit1 commit2          # without meld
git difftool -d commit            # compare to working tree
```

### fzf-git.sh
```bash
source fzf-git.sh/fzf-git.sh
```
```
C-GF  look for git files
C-GB  look for git branches
C-GT  looks for git tags
C-GR  look for git remotes
C-GH  look for git commit hashes
C-GS  look for git stashes
C-GL  look for git reflogs
C-GW  look for git worktrees
C-GE  look for git for-each-ref
```

### forgit

On older Bash versions (like Bash 4.4 on Ubuntu 18.04), `builtin export` in POSIX mode still outputs environment variables prefixed with `declare -x ` instead of `export `. This causes `forgit`'s compatibility check to output a false warning:
```text
[Warn] Config options have to be exported in future versions of forgit.
[Warn] Please update your config accordingly:
[Warn]   export FORGIT_INSTALL_DIR
```

To fix this, update the export check in `forgit.plugin.zsh` (located in `$HOME/.local/share/forgit/forgit.plugin.zsh`) to also match `declare -x`:
```diff
-    if ! builtin export | command grep -Eq "(^$var=|^export $var=)"; then
+    if ! builtin export | command grep -Eq "(^$var=|^export $var=|^declare -x $var=)"; then
```

---

## Debugging & Profiling

### gdb

#### TUI
```
https://sourceware.org/gdb/current/onlinedocs/gdb.html/TUI-Keys.html
* ctrl-x a : enter /exit TUI mode
* ctrl-x 1 : Use TUI with only one window
* ctrl-x 2 : use TUI with 2 windows
* ctrl-x o : change active window
* ctrl-L : refresh screen

https://beej.us/guide/bggdb/
info win
fs next
fs src : focus set to src window
layout src : src on top, command window on bottom
layout asm : assembly on top
layout split : 3 windows, source, assembly, command

tui enable/disable
focus cmd
layout next
```

#### Keybindings
```
Ctrl-p prev commandline
Ctrl-n next commandline
Ctrl-b move cursor backward
Ctrl-f move cursor forward
Alt-b move cursor one word backward
Alt-f move cursor one word forward
Ctrl-r search, select prev command
```

#### Commands
```
set substitute-path /build/project ~/dev/project
thread apply all bt
info line *xxxx
```

#### Reverse Debugging
```
record full
reverse-next
reverse-continue
```

### gdb Server / Remote

#### .gdbinit
```text
set substitute-path /build/project ~/dev/project

define connect-target
    echo "connect to remote target\n"
    target extended-remote <ip>:1234
end

symbol-file /host/...myapp

# Auto connect
connect-target

set remote exec-file /server/.../myapp
set args arg1 arg2
break main
```

#### Server
```bash
gdbserver :1234 ./myapp arg1 arg2
gdbserver --multi :1234
```

#### Host
```text
target remote <target-ip>:1234
target extended-remote <target-ip>:1234
set substitute-path /build/project ~/dev/project
set remote exec-file ./myapp
set args arg1 arg2
run arg1 arg2
show substitute-path
```

### Valgrind

#### Options
```
--leak-check=full
--track-origins=yes        # track origin of uninitialized values
--show-leak-kinds=all
--show-reachable=yes
--log-file=<filename>
--gen-suppressions=all
--suppressions=<filename>
```

#### Shell Helpers
```bash
valg-save() {
    local output_file="valgrind_$(date +%Y%m%d_%H%M%S).log"
    valgrind --leak-check=full --show-leak-kinds=all --track-origins=yes --log-file="$output_file" "$@"
    echo "Valgrind output saved to: $output_file"
}

valgrind_exe() {
    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    local LOGFILE="valgrind_${ts}.log"
    echo "Valgrind output saved to: $LOGFILE"
    local VALGRIND_OPTS="--leak-check=full --show-leak-kinds=all --track-origins=yes --log-file=$LOGFILE"
    valgrind $VALGRIND_OPTS "$@"
}

export VALGRIND_OPTS="--leak-check=full --show-leak-kinds=all --track-origins=yes --log-file=valgrind_$(date +"%Y%m%d%H%M%S").log --error-exitcode=1"
```

#### Tools
```bash
valgrind --tool=callgrind ./myapp
kcachegrind callgrind.out.<pid>

valgrind --tool=massif ./my_program
ms_print massif.out.<pid>
```

#### Fast Valgrind
```bash
valgrind --leak-check=full --show-leak-kinds=definite,possible \
         --undef-value-errors=no --track-origins=no \
         --fair-sched=try \
         ./your_program
```

#### Valgrind + gdb
```bash
valgrind -q --vgdb-error=0 ./exe
gdb ./exe
(gdb) target remote | vgdb --pid=<XXXX>
(gdb) monitor leak_check
```

#### Launch Valgrind Inside gdb
```text
1. set remote exec-file ./ex
2. set sysroot /
3. target extended-remote | vgdb --multi --vargs -q
```

### AddressSanitizer
```bash
gcc -fsanitize=address -g

# append to CXXFLAGS in Makefile
CXXFLAGS += $(SANITIZER_FLAGS)
make SANITIZER_FLAGS="-fsanitize=address -fsanitize=undefined"
```

---

## Build & Compile

### C/C++
```bash
# demangle symbols
nm -C x.o
nm x.o | c++filt

strace
strings -a x.o | egrep "GCC"

LD_DEBUG
* libs Show how libs are searched, loaded
```

#### Include/Library Paths
```bash
export CPLUS_INCLUDE_PATH="$HOME/test/doctest/doctest:$HOME/test/nanobench/src/include:$HOME/test/FakeIt/single_header/doctest:$HOME/test/json/single_include:$HOME/test/stb:$HOME/test/LuaBridge/Source:$HOME/test/LuaBridge/Source/LuaBridge:$HOME/test/luajit/src:$CPLUS_INCLUDE_PATH"
export LIBRARY_PATH="$HOME/test/luajit/src:$LIBRARY_PATH"
```

### Static Lua Linking
```bash
g++ a.cpp /path/liblua.a -ldl
```

### Python on Windows
To run Python scripts directly (e.g., `myscript.py` or `myscript`) using the version of Python currently in your `PATH`.

#### File Association (assoc and ftype)
Run in Command Prompt as **Administrator**:
```cmd
:: Link .py extension to a file type name
assoc .py=Python.File

:: Use 'python' from PATH to open these files
:: "%1" is the script path, "%*" passes all arguments
ftype Python.File=python "%1" %*
```

#### Registry Settings
Key for file type: `HKEY_CLASSES_ROOT\.py` -> `@="Python.File"`

Key for execution command: `HKEY_CLASSES_ROOT\Python.File\shell\open\command`
Value: `python "%1" %*`

*Note: Using `python` instead of a full path ensures it uses whatever `python` is first in your `PATH`.*

#### PATHEXT (for extension-less execution)
Add `; .PY; .PYW` to the `PATHEXT` system environment variable to run scripts by just typing their name (e.g., `myscript`).

### Python
```bash
pip install termcolor
```

### DearPyGui on x201
```bash
export LIBGL_ALWAYS_SOFTWARE=1
```

---

## Networking & Remote

### SSH Config
```
Host *
  ServerAliveInterval 60
```

### SSH Server Config
```
/etc/ssh/sshd_config
X11Forwarding yes
X11DisplayOffset 10
X11UseLocalhost yes
ClientAliveInterval 60
ClientAliveCountMax 3

sudo systemctl restart sshd
```

### SSH Port Forwarding

#### Local Port Forwarding (`ssh -L`)
Forward a local port through an SSH connection to a remote destination (e.g. reach a target SSH server via a jump host):
```bash
# Forward local port 2222 through jump host to destination SSH port 22:
ssh -g -N -L 2222:192.168.1.100:22 user@jump-host

# Options:
# -L [bind_address:]local_port:target_host:target_port
# -g : Gateway mode (allows remote/LAN hosts to connect to local forwarded port)
# -N : Do not execute a remote command (port forwarding only)
# -f : Run in background

# Example with GatewayPorts option:
ssh -o GatewayPorts=yes -N -L 0.0.0.0:8888:192.168.1.38:22 user@jump-host
```

#### Remote / Reverse Port Forwarding (`ssh -R`)
Forward a port from the remote server back to the local machine:
```bash
# Expose local SSH (port 22) on remote server's port 2222:
ssh -R 2222:localhost:22 user@remote-server
```

### sshfs
```bash
sshfs -o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3 \
      -o cache=yes -o kernel_cache -o Ciphers=aes128-ctr \
      pi@192.168.1.13: mypi
```

### X Server / DISPLAY
```
MobaXterm, local terminal: echo $DISPLAY
Windows IP
export DISPLAY=<ip>:1.0 inside docker
```

### PiVPN
```bash
pivpn -d
```
```
Iptables MASQUERADE rule is not set
Iptables FORWARD rule is not set
Save the current iptables rules (Debian/Ubuntu)
sudo iptables-save | sudo tee /etc/iptables/rules.v4
sudo apt update
sudo apt install iptables-persistent
```

### Windows Port Forwarding (PortProxy & Firewall)
Native Windows kernel-level forwarding (no client/software needed, stays active in background):

```cmd
:: 1. Add PortProxy rule (listen on Windows port 2222, forward to target SSH server)
netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=2222 connectaddress=192.168.1.100 connectport=22

:: 2. Allow incoming traffic through Windows Firewall (Run CMD as Administrator)
netsh advfirewall firewall add rule name="SSH_PortProxy_2222" dir=in action=allow protocol=TCP localport=2222

:: 3. View active forwarding rules
netsh interface portproxy show v4tov4

:: 4. Delete the rule when finished
netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=2222
netsh advfirewall firewall delete rule name="SSH_PortProxy_2222"
```

---

## System & Docker

### Linux
```bash
# -----------------------------------------------------------------------------
# Remote Desktop & VNC Server Setup (Ubuntu 24.04 / Debian - e.g. centre1)
# Independent concurrent sessions: VNC on :1 (5901), XRDP on :10 (3389)
# -----------------------------------------------------------------------------

# 1. Install desktop environment & servers
sudo apt update
sudo apt install -y xrdp xorgxrdp tigervnc-standalone-server tigervnc-common xfce4 xfce4-goodies
sudo adduser xrdp ssl-cert
echo "xfce4-session" > ~/.xsession

# 2. Fix headless boot freeze (Plymouth deadlock)
# Headless machines have no physical monitor; GDM never tells Plymouth to quit,
# causing plymouth-quit-wait.service to hang forever and timing out xrdp on boot.
sudo systemctl mask plymouth-quit-wait.service

# 3. XRDP systemd boot override (start after network-online & multi-user)
sudo mkdir -p /etc/systemd/system/xrdp.service.d
sudo tee /etc/systemd/system/xrdp.service.d/override.conf << 'EOF'
[Unit]
After=multi-user.target network-online.target xrdp-sesman.service
Wants=network-online.target
EOF

# 4. Isolate XRDP D-Bus session (allows simultaneous VNC + RDP without conflict)
# In /etc/xrdp/startwm.sh, insert before 'test -x /etc/X11/Xsession':
sudo sed -i '/test -x \/etc\/X11\/Xsession/i \
# Isolate D-Bus and session variables to prevent collision with concurrent VNC/local sessions\n\
unset DBUS_SESSION_BUS_ADDRESS\n\
unset SESSION_MANAGER\n\
export XDG_SESSION_TYPE=x11\n\
export XDG_CURRENT_DESKTOP=XFCE\n\
export DESKTOP_SESSION=xfce\n' /etc/xrdp/startwm.sh

# 5. Suppress Polkit color manager authentication popups on remote login
sudo tee /etc/polkit-1/rules.d/45-xrdp-colord.rules << 'EOF'
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.color-manager.create-device" ||
         action.id == "org.freedesktop.color-manager.create-profile" ||
         action.id == "org.freedesktop.color-manager.delete-device" ||
         action.id == "org.freedesktop.color-manager.delete-profile" ||
         action.id == "org.freedesktop.color-manager.modify-device" ||
         action.id == "org.freedesktop.color-manager.modify-profile") &&
        subject.isInGroup("sudo")) {
        return polkit.Result.YES;
    }
});
EOF

# 6. TigerVNC setup (Display :1, Port 5901)
vncpasswd
mkdir -p ~/.vnc
cat << 'EOF' > ~/.vnc/config
session=xfce
geometry=1920x1080
localhost=no
alwaysshared
securitytypes=VncAuth,TLSVnc
EOF

cat << 'EOF' > ~/.vnc/xstartup
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
export XDG_SESSION_TYPE=x11
export XDG_CURRENT_DESKTOP=XFCE
[ -r /home/$USER/.Xresources ] && xrdb /home/$USER/.Xresources
exec startxfce4
EOF
chmod +x ~/.vnc/xstartup

echo ":1=$USER" | sudo tee -a /etc/tigervnc/vncserver.users
sudo systemctl daemon-reload
sudo systemctl enable --now tigervncserver@:1.service xrdp-sesman xrdp

# 7. Verify
ss -tlpn | grep -E "3389|5901"
systemctl is-system-running

# core dumps
sudo sysctl -w kernel.core_pattern=core
ulimit -c unlimited
# /etc/sysctl.conf:
#     kernel.core_pattern = core
#     sudo sysctl -p

fortune | cowsay
lsof
```

### Disk Space
```bash
du -h ~ | sort -hr | head -n 10
```

### Docker
```bash
# Run with bind mounts
docker run ... \
  --mount type=bind,src=${HOME},dst=${HOME},bind-propagation=rshared \
  -e HOME=${HOME} \
  --workdir ${HOME} \
  --name=${CONTAINER_NAME} \
  ${IMAGE_NAME}:${TAG} sleep infinity
```

---

## Testing
```
* Test invalid inputs, edge cases: throw exception, return error code
* Assert invariants
* Use mock/stubs to simulate errors
* Test boundary values
* Performance, stress test
* Check memory errors: valgrind AddressSanitizer
```

---

## Windows File Operations

### Robocopy Folder Synchronization

Robocopy (Robust File Copy) is a built-in Windows command-line tool for synchronizing folders.

#### Option 1: One-Way Update (Safer — Adds/Updates Only, No Deletions)
Use this to copy new and changed files from source to destination, leaving existing destination files untouched:

```cmd
robocopy C:\path\to\notebooks G:\notebooks /E /Z /R:3 /W:5 /MT:8
```

* `/E` — Copy subdirectories, including empty ones.
* `/Z` — Restartable mode (survives interruptions).
* `/R:3 /W:5` — Retry 3 times, wait 5 seconds between retries.
* `/MT:8` — Use 8 threads for faster copying.

#### Option 2: True Mirror (Destination = Exact Copy of Source)
Use `/MIR` to make the destination an exact clone. **This will delete files in the destination that are not in the source.**

```cmd
robocopy C:\path\to\notebooks G:\notebooks /MIR /Z /R:3 /W:5 /MT:8
```

⚠️ **Warning:** `/MIR` can destroy data. If you accidentally swap source/destination or point to an empty folder, it will wipe the other side. Always run a dry run first.

#### Dry Run (Preview What Would Happen)
Before running either command, preview the actions with `/L`:

```cmd
robocopy C:\path\to\notebooks G:\notebooks /MIR /L
```

This lists what would be copied/deleted without actually doing anything.

#### Full Practical Command (with Logging)
```cmd
robocopy C:\path\to\notebooks G:\notebooks /E /Z /R:3 /W:5 /MT:8 /LOG:G:\notebooks-sync.log /NP /NDL
```

#### Google Drive Backup (Mirror)
```cmd
robocopy Notebooks "g:\My Drive\Notebooks" /MIR /Z /R:3 /W:5 /MT:8
```

⚠️ **Warning:** `/MIR` is destructive — it deletes files in the destination that are not in the source. Always run with `/L` first to preview.

* `/LOG` — Write output to a log file.
* `/NP` — No progress indicator (cleaner logs).
* `/NDL` — Don't log directory names (cleaner logs).

### Rsync (Linux/WSL/macOS)

`rsync` is the standard Unix tool for fast, incremental file transfers and synchronization.

#### Basic Local Sync (One-Way, Add/Update Only)
```bash
rsync -av /path/to/notebooks/ /mnt/g/notebooks/
```

* `-a` — Archive mode (preserves permissions, timestamps, symlinks, etc.).
* `-v` — Verbose output.
* **Trailing slash on source** is important: `src/` copies *contents*; `src` copies the folder itself.

#### True Mirror (Delete Extra Files in Destination)
```bash
rsync -av --delete /path/to/notebooks/ /mnt/g/notebooks/
```

* `--delete` — Remove files in the destination that no longer exist in the source.

⚠️ **Warning:** `--delete` is destructive. A typo or empty source can wipe the destination. Test with `--dry-run` first.

#### Dry Run (Preview)
```bash
rsync -av --delete --dry-run /path/to/notebooks/ /mnt/g/notebooks/
```

* `--dry-run` (`-n`) — Shows what would happen without making any changes.

#### Common Useful Flags

| Flag | Meaning |
|------|---------|
| `-z` | Compress data during transfer (good for network). |
| `-P` | Show progress and allow resuming partial files. |
| `--exclude='*.tmp'` | Exclude files matching pattern. |
| `--exclude-from='exclude.txt'` | Read exclude patterns from a file. |
| `-e ssh` | Use SSH for remote transfers (default if remote path uses `:`). |
| `--progress` | Show per-file progress. |
| `-h` | Human-readable sizes in output. |
| `--stats` | Show transfer statistics at the end. |
| `-n` | Dry run (same as `--dry-run`). |

#### Remote Sync Over SSH
```bash
# Push local to remote
rsync -avz /path/to/notebooks/ user@server:/backup/notebooks/

# Pull remote to local
rsync -avz user@server:/backup/notebooks/ /path/to/notebooks/
```

#### Full Practical Command (with Logging)
```bash
rsync -avh --delete --progress --exclude='*.tmp' \
      /path/to/notebooks/ /mnt/g/notebooks/ | tee /tmp/rsync-log.txt
```

#### Rsync vs Robocopy Quick Reference

| Feature | Robocopy (Windows) | Rsync (Unix) |
|---------|-------------------|--------------|
| One-way update | `/E` | `-av` |
| True mirror | `/MIR` | `-av --delete` |
| Dry run | `/L` | `-n` or `--dry-run` |
| Multithreaded | `/MT:N` | Single-threaded (use `parallel` for multiple files) |
| Resume interrupted | `/Z` | Built-in (`-P`) |
| Remote sync | No native | Native via SSH |
| Preserve attributes | Yes | Yes (`-a`) |
| Network compression | No | Yes (`-z`) |

---

## Help & References
```bash
tldr <command>

curl cheat.sh/git
curl cheat.sh/ssh
```
