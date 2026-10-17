#!/usr/bin/env luajit
--[[
  fco.lua - High-Performance Git Branch, Tag, Commit & Worktree Quick-Switcher TUI
  Powered by LuaJIT & FFI. Single-file, zero external Lua dependencies.
  Runs natively on Windows (Win32 Console/Process FFI) and Linux/POSIX.

  Features:
    - Instant Ref & Commit Discovery: Fetches local branches, remote branches, tags, and recent commits.
    - Real-Time Fuzzy Search: Sub-millisecond keystroke filtering across refs, commit hashes, and subjects.
    - Dual-Pane Layout: Interactive ref/commit list on left; live commit card & ASCII graph on right.
    - Seamless Switching: Switch to local branches, remote tracking branches, tags, or commits (detached HEAD).
    - Force Checkout (--force / -f): Toggleable via 'f' in TUI or CLI flag to discard local changes.
    - Recursive Submodule Sync (--submodule / -s): Toggleable via 's' in TUI to auto-sync submodules.
    - Git Worktree Creation: Press 'w' on any ref or commit to instantly create a new git worktree.
    - Category Tabs: Switch between [All], [Branches], [Tags], [Remotes], and [Commits] with h / l / Tab.
    - Branch Commits Drill-Down: Press 'c' to view and checkout historical commits on highlighted branch.
    - Dual Mode: Full interactive TUI or non-interactive CLI (--list, --batch, <target>).
    - Automated Self-Test Suite: Run 'luajit bin/fco.lua --test' for regression verification.

  Usage:
    luajit bin/fco.lua [OPTIONS] [TARGET]
    fco [OPTIONS] [TARGET]

  Options:
    -f, --force          Force checkout (git checkout -f) [DEFAULT: ON]
    --no-force           Disable force checkout (normal checkout)
    -s, --submodule      Synchronize submodules after checkout (git submodule update --init --recursive -f) [DEFAULT: ON]
    --no-submodule       Disable submodule synchronization
    -b, --branch         Start filtered to branches only
    -t, --tag            Start filtered to tags only
    -r, --remote         Start filtered to remote branches only
    -c, --commit         Start filtered to commits only
    -l, --list           Print formatted list of branches, tags, and commits and exit
    --batch <TARGET>     Directly checkout TARGET (branch, tag, or commit SHA) in batch mode
    --test               Run automated test suite and exit
    -h, --help           Show this help message

  TUI Keybindings (Vim-Style Dual Mode):
    Normal Mode:
      j / Down, k / Up     Move selection cursor down / up
      h / Left, l / Right  Cycle category tabs left / right (All/Branches/Tags/Remotes/Commits)
      gg / G               Jump to first / last ref
      Ctrl+d / Ctrl+u      Half-page scroll down / up
      Ctrl+e / Ctrl+y      Scroll commit details / graph down / up
      /                    Enter Search Mode (type query to filter)
      n / N                Jump to next / previous match in filtered list
      Enter                Checkout selected branch, tag, or commit (detached HEAD)
      c                    Open branch commit history modal (browse/checkout branch commits)
      f                    Toggle Force Mode (git checkout -f) [Default: ON]
      s                    Toggle Submodule Auto-Sync (git submodule update --init --recursive -f)
      w                    Create Git Worktree for selected ref
      Tab                  Cycle category tab
      Esc                  Clear search filter (or quit if filter empty)
      ?                    Show keyboard help modal
      q / Ctrl+C           Quit
    Search Mode (/):
      Typing (a-z, 0-9)    Live fuzzy filter query
      Backspace            Delete character from query
      Enter                Confirm / lock search query and return to Normal mode
      Esc                  Cancel search, restore previous query, return to Normal mode
      Up / Down, Ctrl+p/n  Navigate candidates while typing
]]

local ffi = require("ffi")
local bit = require("bit")

local OS = ffi.os
local IS_WINDOWS = (OS == "Windows")
local IS_POSIX   = (OS == "Linux" or OS == "OSX" or OS == "BSD" or OS == "POSIX")

--------------------------------------------------------------------------------
-- FFI Declarations
--------------------------------------------------------------------------------
if IS_WINDOWS then
    ffi.cdef[[
        typedef void* HANDLE;
        typedef unsigned long DWORD;
        typedef int BOOL;
        typedef unsigned short WORD;
        typedef const wchar_t* LPCWSTR;
        typedef wchar_t* LPWSTR;

        typedef struct { short X; short Y; } COORD;
        typedef struct { short Left; short Top; short Right; short Bottom; } SMALL_RECT;
        typedef struct {
            COORD dwSize;
            COORD dwCursorPosition;
            unsigned short wAttributes;
            SMALL_RECT srWindow;
            COORD dwMaximumWindowSize;
        } CONSOLE_SCREEN_BUFFER_INFO;

        HANDLE GetStdHandle(DWORD nStdHandle);
        BOOL GetConsoleMode(HANDLE hConsoleHandle, DWORD* lpMode);
        BOOL SetConsoleMode(HANDLE hConsoleHandle, DWORD dwMode);
        BOOL GetConsoleScreenBufferInfo(HANDLE h, CONSOLE_SCREEN_BUFFER_INFO* csbi);
        BOOL SetConsoleOutputCP(unsigned int wCodePageID);
        BOOL SetConsoleCP(unsigned int wCodePageID);
        HANDLE CreateFileA(const char* lpFileName, DWORD dwDesiredAccess, DWORD dwShareMode, void* lpSecurityAttributes, DWORD dwCreationDisposition, DWORD dwFlagsAndAttributes, void* hTemplateFile);
        BOOL CloseHandle(HANDLE hObject);
        void Sleep(DWORD dwMilliseconds);
        DWORD GetCurrentDirectoryA(DWORD nBufferLength, char* lpBuffer);
        unsigned long long GetTickCount64(void);
    ]]
    local msvcrt = ffi.load("msvcrt")
    ffi.cdef[[
        int _kbhit(void);
        int _getch(void);
    ]]
    _G.msvcrt = msvcrt
else
    ffi.cdef[[
        struct termios {
            unsigned int c_iflag, c_oflag, c_cflag, c_lflag;
            unsigned char c_line;
            unsigned char c_cc[32];
            unsigned int c_ispeed, c_ospeed;
        };
        int tcgetattr(int fd, struct termios *termios_p);
        int tcsetattr(int fd, int optional_actions, const struct termios *termios_p);
        struct winsize {
            unsigned short ws_row, ws_col, ws_xpixel, ws_ypixel;
        };
        struct timespec {
            long tv_sec;
            long tv_nsec;
        };
        int clock_gettime(int clk_id, struct timespec *tp);
        int ioctl(int fd, unsigned long request, ...);
        int read(int fd, void *buf, size_t count);
        int isatty(int fd);
        int usleep(unsigned int usec);
        char *getcwd(char *buf, size_t size);
    ]]
end

--------------------------------------------------------------------------------
-- Styling & Color Palette
--------------------------------------------------------------------------------
local C = {
    reset       = "\27[0m",
    bold        = "\27[1m",
    dim         = "\27[2m",
    reverse     = "\27[7m",
    underline   = "\27[4m",

    black       = "\27[30m",
    red         = "\27[31m",
    green       = "\27[32m",
    yellow      = "\27[33m",
    blue        = "\27[34m",
    magenta     = "\27[35m",
    cyan        = "\27[36m",
    white       = "\27[37m",
    gray        = "\27[90m",

    b_black     = "\27[1;30m",
    b_red       = "\27[1;91m",
    b_green     = "\27[1;92m",
    b_yellow    = "\27[1;93m",
    b_blue      = "\27[1;94m",
    b_magenta   = "\27[1;95m",
    b_cyan      = "\27[1;96m",
    b_white     = "\27[1;97m",

    bg_black    = "\27[40m",
    bg_red      = "\27[41m",
    bg_green    = "\27[42m",
    bg_yellow   = "\27[43m",
    bg_blue     = "\27[44m",
    bg_darkblue = "\27[48;5;24m",
    bg_cyan     = "\27[46m",
    bg_gray     = "\27[100m",
    bg_sel      = "\27[48;5;238m",
}

local BOX = {
    tl = "┌", tr = "┐", bl = "└", br = "┘",
    h = "─", v = "│", vl = "├", vr = "┤",
    tt = "┬", tb = "┴", x = "┼"
}

--------------------------------------------------------------------------------
-- Utility & Unicode Formatting Functions
--------------------------------------------------------------------------------
local function get_time_sec()
    if IS_WINDOWS then
        local ok, val = pcall(function() return tonumber(ffi.C.GetTickCount64()) / 1000.0 end)
        if ok and val then return val end
    elseif IS_POSIX then
        local ts = ffi.new("struct timespec")
        if ffi.C.clock_gettime(1, ts) == 0 then -- CLOCK_MONOTONIC
            return tonumber(ts.tv_sec) + tonumber(ts.tv_nsec) / 1e9
        end
    end
    return os.time()
end

local function clean_path(path)
    if not path then return "" end
    return path:gsub("\\", "/")
end

local function utf8_col_width(s)
    if not s then return 0 end
    local clean = s:gsub("\27%[[%?%d;]*[a-zA-Z]", "")
    local width = 0
    local i = 1
    local len = #clean
    while i <= len do
        local b = clean:byte(i)
        if b < 128 then
            width = width + 1
            i = i + 1
        elseif b >= 192 and b < 224 then
            width = width + 1
            i = i + 2
        elseif b >= 224 and b < 240 then
            local b2 = clean:byte(i + 1) or 0
            local b3 = clean:byte(i + 2) or 0
            if b == 0xEF and b2 == 0xB8 and (b3 >= 0x80 and b3 <= 0x8F) then
                -- Zero-width variation selector (e.g. U+FE0F)
            elseif b == 0xE2 and (b2 == 0x94 or b2 == 0x95 or b2 == 0x96 or b2 == 0x97) then
                width = width + 1 -- Box drawing
            elseif (b == 0xE2 and (b2 >= 0x98 and b2 <= 0xBF)) or (b >= 0xE3 and b <= 0xEF) then
                width = width + 2 -- Wide CJK / symbols
            else
                width = width + 1
            end
            i = i + 3
        elseif b >= 240 then
            width = width + 2 -- 4-byte emojis
            i = i + 4
        else
            width = width + 1
            i = i + 1
        end
    end
    return width
end

local function pad_string(s, target_width)
    s = s or ""
    local cur_w = utf8_col_width(s)
    if cur_w < target_width then
        return s .. string.rep(" ", target_width - cur_w)
    else
        return s
    end
end

local function truncate_string(s, max_width)
    if not s then return "" end
    local cur_w = utf8_col_width(s)
    if cur_w <= max_width then return s end
    if max_width <= 1 then return "…" end
    local clean = s:gsub("\27%[[%?%d;]*[a-zA-Z]", "")
    local res = ""
    local w = 0
    local i = 1
    local len = #clean
    while i <= len and w < max_width - 1 do
        local b = clean:byte(i)
        local step = 1
        local ch_w = 1
        if b < 128 then
            step = 1; ch_w = 1
        elseif b >= 192 and b < 224 then
            step = 2; ch_w = 1
        elseif b >= 224 and b < 240 then
            step = 3
            local b2 = clean:byte(i + 1) or 0
            local b3 = clean:byte(i + 2) or 0
            if b == 0xEF and b2 == 0xB8 and (b3 >= 0x80 and b3 <= 0x8F) then
                ch_w = 0
            elseif (b == 0xE2 and (b2 >= 0x98 and b2 <= 0xBF)) or (b >= 0xE3 and b <= 0xEF) then
                ch_w = 2
            else
                ch_w = 1
            end
        elseif b >= 240 then
            step = 4; ch_w = 2
        end
        if w + ch_w > max_width - 1 then break end
        res = res .. clean:sub(i, i + step - 1)
        w = w + ch_w
        i = i + step
    end
    return res .. "…"
end

-- Subsequence fuzzy matching with prefix/word boundary bonus
local function fuzzy_score(pattern, str)
    if not pattern or #pattern == 0 then return 1 end
    if not str or #str == 0 then return nil end
    pattern = pattern:lower()
    str = str:lower()
    local p_idx = 1
    local p_len = #pattern
    local s_len = #str
    local score = 0
    local last_match = -1
    for s_idx = 1, s_len do
        if p_idx <= p_len and str:byte(s_idx) == pattern:byte(p_idx) then
            if last_match == s_idx - 1 then
                score = score + 10 -- consecutive bonus
            else
                score = score + 2
            end
            if s_idx == 1 or str:sub(s_idx - 1, s_idx - 1):match("[%-_/.]") then
                score = score + 5 -- word boundary bonus
            end
            last_match = s_idx
            p_idx = p_idx + 1
        end
    end
    if p_idx > p_len then return score else return nil end
end

--------------------------------------------------------------------------------
-- Terminal Low-Level Controller
--------------------------------------------------------------------------------
local Term = {
    orig_in_mode = nil,
    orig_out_mode = nil,
    orig_termios = nil,
    hIn = nil,
    hOut = nil,
    is_raw = false,
}

function Term.init()
    if IS_WINDOWS then
        pcall(function()
            ffi.C.SetConsoleOutputCP(65001)
            ffi.C.SetConsoleCP(65001)
        end)
        Term.hIn = ffi.C.GetStdHandle(ffi.cast("DWORD", -10))
        Term.hOut = ffi.C.GetStdHandle(ffi.cast("DWORD", -11))

        if Term.hOut ~= nil and Term.hOut ~= ffi.cast("HANDLE", -1) then
            local mode = ffi.new("DWORD[1]")
            if ffi.C.GetConsoleMode(Term.hOut, mode) ~= 0 then
                Term.orig_out_mode = mode[0]
                ffi.C.SetConsoleMode(Term.hOut, bit.bor(mode[0], 0x0004)) -- ENABLE_VIRTUAL_TERMINAL_PROCESSING
            end
        end
    end
end

function Term.enable_raw()
    if Term.is_raw then return end
    if IS_WINDOWS then
        if Term.hIn ~= nil and Term.hIn ~= ffi.cast("HANDLE", -1) then
            local mode = ffi.new("DWORD[1]")
            if ffi.C.GetConsoleMode(Term.hIn, mode) ~= 0 then
                Term.orig_in_mode = mode[0]
                local raw_mode = bit.band(mode[0], bit.bnot(bit.bor(0x0002, 0x0004))) -- DISABLE LINE & ECHO INPUT
                ffi.C.SetConsoleMode(Term.hIn, raw_mode)
            end
        end
    else
        Term.orig_termios = ffi.new("struct termios")
        if ffi.C.tcgetattr(0, Term.orig_termios) == 0 then
            local raw = ffi.new("struct termios")
            ffi.copy(raw, Term.orig_termios, ffi.sizeof("struct termios"))
            raw.c_lflag = bit.band(raw.c_lflag, bit.bnot(bit.bor(0x0002, 0x0008, 0x0001))) -- ICANON, ECHO, ISIG
            raw.c_cc[5] = 0 -- VTIME = 0 (non-blocking)
            raw.c_cc[6] = 0 -- VMIN  = 0 (non-blocking)
            ffi.C.tcsetattr(0, 0, raw)
        end
    end

    io.write("\27[?1049h\27[?25l\27[?7l\27[2J\27[H")
    io.flush()
    Term.is_raw = true
end

function Term.restore()
    if not Term.is_raw then return end
    io.write("\27[?7h\27[?1049l\27[?25h\27[0m")
    io.flush()

    if IS_WINDOWS then
        if Term.orig_in_mode and Term.hIn ~= nil and Term.hIn ~= ffi.cast("HANDLE", -1) then
            ffi.C.SetConsoleMode(Term.hIn, Term.orig_in_mode)
        end
        if Term.orig_out_mode and Term.hOut ~= nil and Term.hOut ~= ffi.cast("HANDLE", -1) then
            ffi.C.SetConsoleMode(Term.hOut, Term.orig_out_mode)
        end
    else
        if Term.orig_termios then
            ffi.C.tcsetattr(0, 0, Term.orig_termios)
        end
    end
    Term.is_raw = false
end

function Term.get_size()
    local cols, rows = 90, 26
    if IS_WINDOWS then
        local hCon = ffi.C.CreateFileA("CONOUT$", 0xC0000000, 3, nil, 3, 0, nil)
        if hCon ~= nil and hCon ~= ffi.cast("HANDLE", -1) then
            local csbi = ffi.new("CONSOLE_SCREEN_BUFFER_INFO")
            if ffi.C.GetConsoleScreenBufferInfo(hCon, csbi) ~= 0 then
                cols = csbi.srWindow.Right - csbi.srWindow.Left + 1
                rows = csbi.srWindow.Bottom - csbi.srWindow.Top + 1
            end
            ffi.C.CloseHandle(hCon)
        end
    else
        local ws = ffi.new("struct winsize")
        if ffi.C.ioctl(0, 0x5413, ws) == 0 and ws.ws_col > 0 and ws.ws_row > 0 then
            cols = ws.ws_col
            rows = ws.ws_row
        end
    end

    local env_c = tonumber(os.getenv("COLUMNS"))
    local env_r = tonumber(os.getenv("LINES"))
    if env_c and env_c > 20 then cols = env_c end
    if env_r and env_r > 10 then rows = env_r end

    if cols < 65 then cols = 65 end
    if rows < 16 then rows = 16 end
    return cols, rows
end

function Term.read_key()
    if IS_WINDOWS then
        local m = _G.msvcrt
        if m._kbhit() == 0 then return nil end
        local ch = m._getch()
        if ch == 0 or ch == 224 then
            local ch2 = m._getch()
            if ch2 == 72 then return "up"
            elseif ch2 == 80 then return "down"
            elseif ch2 == 75 then return "left"
            elseif ch2 == 77 then return "right"
            elseif ch2 == 71 then return "home"
            elseif ch2 == 79 then return "end"
            elseif ch2 == 73 then return "pageup"
            elseif ch2 == 81 then return "pagedown"
            elseif ch2 == 83 then return "delete"
            else return "ext_" .. ch2 end
        elseif ch == 13 or ch == 10 then return "enter"
        elseif ch == 9 then return "tab"
        elseif ch == 8 or ch == 127 then return "backspace"
        elseif ch == 32 then return "space"
        elseif ch == 27 then return "esc"
        elseif ch == 3 then return "ctrl_c"
        elseif ch == 4 then return "ctrl_d"
        elseif ch == 21 then return "ctrl_u"
        elseif ch == 5 then return "ctrl_e"
        elseif ch == 25 then return "ctrl_y"
        elseif ch == 14 then return "ctrl_n"
        elseif ch == 16 then return "ctrl_p"
        else
            return string.char(ch)
        end
    else
        local buf = ffi.new("char[8]")
        local n = ffi.C.read(0, buf, 8)
        if n <= 0 then return nil end
        local ch = buf[0]
        if ch == 27 then
            if n == 1 then return "esc" end
            if buf[1] == 91 then -- '['
                if buf[2] == 65 then return "up"
                elseif buf[2] == 66 then return "down"
                elseif buf[2] == 67 then return "right"
                elseif buf[2] == 68 then return "left"
                elseif buf[2] == 53 and buf[3] == 126 then return "pageup"
                elseif buf[2] == 54 and buf[3] == 126 then return "pagedown"
                elseif buf[2] == 72 then return "home"
                elseif buf[2] == 70 then return "end"
                elseif buf[2] == 51 and buf[3] == 126 then return "delete"
                end
            end
            return "esc"
        elseif ch == 13 or ch == 10 then return "enter"
        elseif ch == 9 then return "tab"
        elseif ch == 127 or ch == 8 then return "backspace"
        elseif ch == 32 then return "space"
        elseif ch == 3 then return "ctrl_c"
        elseif ch == 4 then return "ctrl_d"
        elseif ch == 21 then return "ctrl_u"
        elseif ch == 5 then return "ctrl_e"
        elseif ch == 25 then return "ctrl_y"
        elseif ch == 14 then return "ctrl_n"
        elseif ch == 16 then return "ctrl_p"
        else
            return string.char(ch)
        end
    end
end

--------------------------------------------------------------------------------
-- Git Operations Engine
--------------------------------------------------------------------------------
local Git = {}

function Git.is_repo()
    local p = io.popen("git rev-parse --is-inside-work-tree 2>nul")
    if not p then return false end
    local out = p:read("*a")
    p:close()
    return (out:find("true") ~= nil)
end

function Git.get_repo_root()
    local p = io.popen("git rev-parse --show-toplevel 2>nul")
    if not p then return "." end
    local line = p:read("*l")
    p:close()
    return clean_path(line or ".")
end

function Git.get_current_head()
    local p = io.popen("git branch --show-current 2>nul")
    if p then
        local line = p:read("*l")
        p:close()
        if line and #line > 0 then return line end
    end
    -- Fallback for detached HEAD
    p = io.popen("git rev-parse --short HEAD 2>nul")
    if p then
        local line = p:read("*l")
        p:close()
        if line and #line > 0 then return "(detached at " .. line .. ")" end
    end
    return "HEAD"
end

function Git.get_head_commit_sha()
    local p = io.popen("git rev-parse HEAD 2>nul")
    if not p then return "" end
    local line = p:read("*l")
    p:close()
    return line or ""
end

function Git.is_valid_commit(target)
    if not target or #target < 4 then return false end
    local cmd = string.format('git rev-parse --verify --quiet "%s^{commit}" 2>nul', target:gsub('"', '\\"'))
    local p = io.popen(cmd)
    if not p then return false end
    local out = p:read("*l")
    local ok = p:close()
    return (ok == true or ok == 0) and out ~= nil and #out >= 40, out
end

function Git.resolve_commit(target)
    local ok, full_sha = Git.is_valid_commit(target)
    if not ok then return nil end
    local cmd = string.format('git log -1 --format="%%h\t%%cr\t%%an\t%%s" %s 2>nul', full_sha)
    local p = io.popen(cmd)
    if not p then return full_sha, full_sha:sub(1, 7), "commit", "", "" end
    local line = p:read("*l")
    p:close()
    if line then
        local short_sha, date, author, subj = line:match("^([^\t]+)\t([^\t]*)\t([^\t]*)\t(.*)$")
        return full_sha, short_sha or full_sha:sub(1, 7), subj or "", author or "", date or ""
    end
    return full_sha, full_sha:sub(1, 7), "commit", "", ""
end

function Git.fetch_recent_commits(limit)
    limit = limit or 50
    local head_sha = Git.get_head_commit_sha()
    local cmd = string.format('git log -%d --format="%%H\t%%h\t%%cr\t%%an\t%%s" 2>nul', limit)
    local p = io.popen(cmd)
    if not p then return {} end
    local items = {}
    for line in p:lines() do
        local h, s, d, a, subj = line:match("^([^\t]+)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
        if h and s then
            table.insert(items, {
                type = "commit",
                name = s,
                sha = s,
                full_ref = h,
                date = d or "",
                author = a or "",
                subject = subj or "",
                is_head = (h == head_sha),
            })
        end
    end
    p:close()
    return items
end

function Git.fetch_branch_commits(ref_name, limit)
    limit = limit or 30
    local cmd = string.format('git log -%d --format="%%H\t%%h\t%%cr\t%%an\t%%s" %s 2>nul', limit, ref_name)
    local p = io.popen(cmd)
    if not p then return {} end
    local items = {}
    for line in p:lines() do
        local h, s, d, a, subj = line:match("^([^\t]+)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
        if h and s then
            table.insert(items, {
                type = "commit",
                name = s,
                sha = s,
                full_ref = h,
                date = d or "",
                author = a or "",
                subject = subj or "",
            })
        end
    end
    p:close()
    return items
end

function Git.get_dirty_status()
    local dirty = false
    local modified_count = 0
    local untracked_count = 0
    local p = io.popen("git status --porcelain 2>nul")
    if p then
        for line in p:lines() do
            local code = line:sub(1, 2)
            if code == "??" then
                untracked_count = untracked_count + 1
            else
                modified_count = modified_count + 1
                dirty = true
            end
        end
        p:close()
    end
    return dirty, modified_count, untracked_count
end

function Git.parse_ref_type(full_ref)
    if full_ref:find("^refs/heads/") then
        return "local"
    elseif full_ref:find("^refs/tags/") then
        return "tag"
    elseif full_ref:find("^refs/remotes/") then
        return "remote"
    end
    return "other"
end

function Git.fetch_all_refs()
    local items = {}
    local current_head = Git.get_current_head()

    -- 1. Local branches
    local p1 = io.popen('git branch --list --sort=-committerdate --format="%(refname)	%(refname:short)	%(objectname:short)	%(committerdate:relative)	%(subject)" 2>nul')
    if p1 then
        for line in p1:lines() do
            local f_ref, s_name, sha, date_rel, subj = line:match("^([^\t]+)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
            if f_ref and s_name then
                table.insert(items, {
                    type = "local",
                    name = s_name,
                    full_ref = f_ref,
                    sha = sha or "",
                    date = date_rel or "",
                    subject = subj or "",
                    is_head = (s_name == current_head),
                })
            end
        end
        p1:close()
    end

    -- 2. Remote branches
    local p2 = io.popen('git branch -r --sort=-committerdate --format="%(refname)	%(refname:short)	%(objectname:short)	%(committerdate:relative)	%(subject)" 2>nul')
    if p2 then
        for line in p2:lines() do
            local f_ref, s_name, sha, date_rel, subj = line:match("^([^\t]+)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
            if f_ref and s_name and not f_ref:find("/HEAD$") and s_name ~= "origin" and not s_name:find("/HEAD$") then
                table.insert(items, {
                    type = "remote",
                    name = s_name,
                    full_ref = f_ref,
                    sha = sha or "",
                    date = date_rel or "",
                    subject = subj or "",
                    is_head = false,
                })
            end
        end
        p2:close()
    end

    -- 3. Tags
    local p3 = io.popen('git tag -l --sort=-creatordate --format="%(refname)	%(refname:short)	%(objectname:short)	%(creatordate:relative)	%(subject)" 2>nul')
    if p3 then
        for line in p3:lines() do
            local f_ref, s_name, sha, date_rel, subj = line:match("^([^\t]+)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
            if f_ref and s_name then
                table.insert(items, {
                    type = "tag",
                    name = s_name,
                    full_ref = f_ref,
                    sha = sha or "",
                    date = date_rel or "",
                    subject = subj or "",
                    is_head = false,
                })
            end
        end
        p3:close()
    end

    -- 4. Recent commits
    local recent_commits = Git.fetch_recent_commits(50)
    for _, c in ipairs(recent_commits) do
        table.insert(items, c)
    end

    return items
end

function Git.get_commit_details(ref_name, is_commit)
    local info = {
        hash = "",
        author = "",
        email = "",
        date = "",
        subject = "",
        body = {},
        stat = {},
        graph = {},
        display_lines = {},
    }

    -- 1. Metadata
    local cmd_meta = string.format('git log -1 --format="%%H\t%%an\t%%ae\t%%ar\t%%s" %s 2>nul', ref_name)
    local p_meta = io.popen(cmd_meta)
    if p_meta then
        local line = p_meta:read("*l")
        if line then
            local h, a, e, d, s = line:match("^([^\t]+)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
            info.hash = h or ""
            info.author = a or ""
            info.email = e or ""
            info.date = d or ""
            info.subject = s or ""
        end
        p_meta:close()
    end

    -- 2. Diffstat & Changed files
    local cmd_stat = string.format('git show --stat --color=never --format= %s 2>nul', ref_name)
    local p_stat = io.popen(cmd_stat)
    if p_stat then
        for line in p_stat:lines() do
            if #line > 0 then
                table.insert(info.stat, line)
            end
        end
        p_stat:close()
    end

    -- 3. Recent commit graph
    local cmd_graph = string.format('git log -7 --graph --oneline --color=never %s 2>nul', ref_name)
    local p_graph = io.popen(cmd_graph)
    if p_graph then
        for line in p_graph:lines() do
            table.insert(info.graph, line)
        end
        p_graph:close()
    end

    -- 4. Build unified display lines based on whether this is a commit or branch
    if is_commit then
        if #info.stat > 0 then
            table.insert(info.display_lines, C.b_yellow .. "Changed Files & Diffstat:" .. C.reset)
            for _, s in ipairs(info.stat) do
                if s:find("changed") then
                    table.insert(info.display_lines, " " .. C.b_cyan .. s:gsub("^%s+", "") .. C.reset)
                else
                    table.insert(info.display_lines, " " .. C.white .. s .. C.reset)
                end
            end
            table.insert(info.display_lines, "")
        end
        if #info.graph > 0 then
            table.insert(info.display_lines, C.b_yellow .. "Commit Context & Ancestry:" .. C.reset)
            for _, g in ipairs(info.graph) do
                table.insert(info.display_lines, " " .. C.cyan .. g .. C.reset)
            end
        end
    else
        -- Branch or Tag: Prioritize recent graph then latest commit diffstat
        if #info.graph > 0 then
            table.insert(info.display_lines, C.b_yellow .. "Recent Commits on Branch:" .. C.reset)
            for _, g in ipairs(info.graph) do
                table.insert(info.display_lines, " " .. C.cyan .. g .. C.reset)
            end
        end
        if #info.stat > 0 then
            table.insert(info.display_lines, "")
            table.insert(info.display_lines, C.b_yellow .. "Head Commit Changed Files:" .. C.reset)
            for _, s in ipairs(info.stat) do
                if s:find("changed") then
                    table.insert(info.display_lines, " " .. C.b_cyan .. s:gsub("^%s+", "") .. C.reset)
                else
                    table.insert(info.display_lines, " " .. C.white .. s .. C.reset)
                end
            end
        end
    end

    return info
end

function Git.build_checkout_cmd(item, force)
    local flag = force and "-f" or ""
    if item.type == "tag" then
        return string.format("git checkout %s tags/%s", flag, item.name):gsub("%s+", " ")
    elseif item.type == "commit" then
        return string.format("git checkout %s %s", flag, item.sha or item.name):gsub("%s+", " ")
    elseif item.type == "remote" then
        local local_branch = item.name:gsub("^[^/]+/", "")
        return string.format("git checkout %s %s", flag, local_branch):gsub("%s+", " ")
    else
        return string.format("git checkout %s %s", flag, item.name):gsub("%s+", " ")
    end
end

function Git.execute_checkout(item, force)
    local cmd = Git.build_checkout_cmd(item, force)
    local p = io.popen(cmd .. " 2>&1")
    local out = p and p:read("*a") or ""
    local ok = p and p:close()
    return (ok == true or ok == 0), cmd, out
end

function Git.build_submodule_cmd(force)
    if force then
        return "git submodule update --init --recursive -f"
    else
        return "git submodule update --init --recursive"
    end
end

function Git.update_submodules(force)
    local cmd = Git.build_submodule_cmd(force)
    local p = io.popen(cmd .. " 2>&1")
    local out = p and p:read("*a") or ""
    local ok = p and p:close()
    return (ok == true or ok == 0), cmd, out
end

function Git.execute_worktree(item, path)
    local target = item.name
    if item.type == "remote" then
        target = item.name:gsub("^[^/]+/", "")
    end
    local cmd = string.format('git worktree add "%s" %s', path, target)
    local p = io.popen(cmd .. " 2>&1")
    local out = p and p:read("*a") or ""
    local ok = p and p:close()
    return (ok == true or ok == 0), cmd, out
end

--------------------------------------------------------------------------------
-- TUI State & Controller
--------------------------------------------------------------------------------
local TUI = {
    items = {},
    filtered_items = {},
    selection = 1,
    scroll = 0,
    query = "",
    saved_query = "",
    mode = "normal", -- "normal", "search"
    g_pending = false,
    preview_scroll = 0,
    filter_tab = "all", -- "all", "branches", "tags", "remotes"
    force = true,
    submodule = false,
    dirty = false,
    modified_count = 0,
    untracked_count = 0,
    repo_root = "",
    current_head = "",
    preview_cache = {},
    status_msg = "Ready. j/k: Nav, /: Search, Enter: Switch, f: Force, s: Submodule.",
    status_color = C.gray,
    modal = nil, -- nil, "worktree", "help", "commits"
    modal_selection = 1,
    modal_scroll = 0,
    branch_commits = {},
    worktree_input = "",
}

function TUI.init(initial_filter, initial_force, initial_submodule)
    if not Git.is_repo() then
        io.stderr:write("Error: Not a git repository (or any of the parent directories).\n")
        os.exit(1)
    end
    TUI.repo_root = Git.get_repo_root()
    TUI.current_head = Git.get_current_head()
    TUI.dirty, TUI.modified_count, TUI.untracked_count = Git.get_dirty_status()
    if initial_force ~= nil then
        TUI.force = initial_force
    else
        TUI.force = true
    end
    if initial_submodule ~= nil then
        TUI.submodule = initial_submodule
    else
        TUI.submodule = false
    end
    TUI.mode = "normal"
    TUI.saved_query = ""
    TUI.g_pending = false
    TUI.preview_scroll = 0
    if initial_filter then TUI.filter_tab = initial_filter end
    TUI.reload_refs()
end

function TUI.reload_refs()
    TUI.items = Git.fetch_all_refs()
    TUI.filter_and_rank()
end

function TUI.filter_and_rank()
    local res = {}
    local q = TUI.query:lower()
    for _, it in ipairs(TUI.items) do
        local tab_match = true
        if TUI.filter_tab == "branches" and it.type ~= "local" then tab_match = false end
        if TUI.filter_tab == "tags" and it.type ~= "tag" then tab_match = false end
        if TUI.filter_tab == "remotes" and it.type ~= "remote" then tab_match = false end
        if TUI.filter_tab == "commits" and it.type ~= "commit" then tab_match = false end
        if TUI.filter_tab == "all" and it.type == "commit" and #q == 0 then tab_match = false end

        if tab_match then
            if #q == 0 then
                table.insert(res, { item = it, score = 0 })
            else
                local s1 = fuzzy_score(q, it.name) or -1
                local s2 = fuzzy_score(q, it.subject) or -1
                local max_score = math.max(s1, s2)
                if max_score > 0 then
                    table.insert(res, { item = it, score = max_score })
                end
            end
        end
    end

    if #q > 0 then
        table.sort(res, function(a, b)
            if a.score == b.score then
                return a.item.name < b.item.name
            end
            return a.score > b.score
        end)
    end

    TUI.filtered_items = {}
    for i, r in ipairs(res) do
        table.insert(TUI.filtered_items, r.item)
    end

    if TUI.selection > #TUI.filtered_items then
        TUI.selection = math.max(1, #TUI.filtered_items)
    end
    if TUI.selection < 1 and #TUI.filtered_items > 0 then
        TUI.selection = 1
    end
end

function TUI.cycle_tab_forward()
    if TUI.filter_tab == "all" then TUI.filter_tab = "branches"
    elseif TUI.filter_tab == "branches" then TUI.filter_tab = "tags"
    elseif TUI.filter_tab == "tags" then TUI.filter_tab = "remotes"
    elseif TUI.filter_tab == "remotes" then TUI.filter_tab = "commits"
    else TUI.filter_tab = "all" end
    TUI.selection = 1
    TUI.preview_scroll = 0
    TUI.filter_and_rank()
end

function TUI.cycle_tab_backward()
    if TUI.filter_tab == "all" then TUI.filter_tab = "commits"
    elseif TUI.filter_tab == "commits" then TUI.filter_tab = "remotes"
    elseif TUI.filter_tab == "remotes" then TUI.filter_tab = "tags"
    elseif TUI.filter_tab == "tags" then TUI.filter_tab = "branches"
    else TUI.filter_tab = "all" end
    TUI.selection = 1
    TUI.preview_scroll = 0
    TUI.filter_and_rank()
end

function TUI.next_match()
    if #TUI.filtered_items == 0 then return end
    if TUI.selection < #TUI.filtered_items then
        TUI.selection = TUI.selection + 1
    else
        TUI.selection = 1 -- wrap around to top
    end
    TUI.preview_scroll = 0
end

function TUI.prev_match()
    if #TUI.filtered_items == 0 then return end
    if TUI.selection > 1 then
        TUI.selection = TUI.selection - 1
    else
        TUI.selection = #TUI.filtered_items -- wrap around to bottom
    end
    TUI.preview_scroll = 0
end

function TUI.get_active_preview()
    local item = TUI.filtered_items[TUI.selection]
    if not item then return nil end
    if not TUI.preview_cache[item.full_ref] then
        TUI.preview_cache[item.full_ref] = Git.get_commit_details(item.full_ref, item.type == "commit")
    end
    return item, TUI.preview_cache[item.full_ref]
end

--------------------------------------------------------------------------------
-- TUI Rendering Engine
--------------------------------------------------------------------------------
function TUI.render()
    local cols, rows = Term.get_size()
    local buf = {}

    local function write_str(s) table.insert(buf, s) end

    -- Hide cursor & clear screen
    write_str("\27[?25l\27[H")

    local inner_w = cols - 2
    local left_w = math.max(34, math.floor(cols * 0.44))
    local right_w = cols - 3 - left_w

    local function make_full_row(content)
        return C.b_cyan .. BOX.v .. C.reset .. pad_string(content, inner_w) .. C.b_cyan .. BOX.v .. C.reset .. "\n"
    end

    local function make_split_row(l_content, r_content)
        local l = pad_string(l_content, left_w)
        local r = pad_string(r_content, right_w)
        return C.b_cyan .. BOX.v .. C.reset .. l .. C.b_cyan .. BOX.v .. C.reset .. r .. C.b_cyan .. BOX.v .. C.reset .. "\n"
    end

    -- 1. Header Box
    local title_left = " FCO v1.0 [Branch & Tag Switcher] "
    local repo_short = truncate_string(TUI.repo_root, 30)
    local title_right = string.format(" Repo: %s ", repo_short)
    local fill_len = cols - 2 - utf8_col_width(title_left) - utf8_col_width(title_right)
    if fill_len < 0 then fill_len = 0 end

    write_str(C.b_cyan .. BOX.tl .. C.b_white .. title_left .. C.b_cyan .. string.rep(BOX.h, fill_len) .. C.gray .. title_right .. C.b_cyan .. BOX.tr .. C.reset .. "\n")

    -- 2. Status & Force Mode Banner
    local dirty_badge
    if TUI.dirty then
        dirty_badge = C.b_yellow .. string.format("[DIRTY: %d modified]", TUI.modified_count) .. C.reset
    else
        dirty_badge = C.b_green .. "[CLEAN]" .. C.reset
    end

    local force_badge
    if TUI.force then
        force_badge = C.bg_red .. C.b_white .. " [FORCE: ON] " .. C.reset
    else
        force_badge = C.gray .. "[FORCE: OFF]" .. C.reset
    end

    local sub_badge
    if TUI.submodule then
        sub_badge = C.bg_blue .. C.b_white .. " [SUBMODULE: ON] " .. C.reset
    else
        sub_badge = C.gray .. "[SUBMODULE: OFF]" .. C.reset
    end

    local head_color = TUI.current_head:find("^%(detached") and C.b_magenta or C.b_green
    local head_disp = string.format(" HEAD: %s%s%s  %s", head_color, TUI.current_head, C.reset, dirty_badge)
    local badges = force_badge .. " " .. sub_badge
    local head_gap = inner_w - utf8_col_width(head_disp) - utf8_col_width(badges) - 1
    if head_gap < 1 then head_gap = 1 end
    write_str(make_full_row(head_disp .. string.rep(" ", head_gap) .. badges .. " "))

    -- Split separator
    write_str(C.b_cyan .. BOX.vl .. string.rep(BOX.h, left_w) .. BOX.tt .. string.rep(BOX.h, right_w) .. BOX.vr .. C.reset .. "\n")

    -- 3. Left Header: Search Input & Tabs; Right Header: Commit Meta
    local search_disp
    if TUI.mode == "search" then
        search_disp = string.format(" Search: %s/%s%s█%s", C.b_yellow, TUI.query, C.reverse, C.reset)
    else
        if #TUI.query > 0 then
            search_disp = string.format(" Search: %s[%s]%s %s(/ edit, Esc clr)%s", C.b_yellow, TUI.query, C.reset, C.gray, C.reset)
        else
            search_disp = string.format(" Search: %s[/ to search]%s", C.gray, C.reset)
        end
    end
    local cur_item, cur_preview = TUI.get_active_preview()
    local is_commit_sel = (cur_item and cur_item.type == "commit")
    local right_header = is_commit_sel
        and (C.b_white .. " Commit Details & Changed Files" .. C.reset)
        or (C.b_white .. " Ref Details & Commit Graph" .. C.reset)
    write_str(make_split_row(search_disp, right_header))

    local function make_tab(label, key, active)
        if active then
            return C.reverse .. C.b_cyan .. "[" .. label .. "]" .. C.reset
        else
            return C.gray .. "[" .. label .. "]" .. C.reset
        end
    end

    local tabs_disp = string.format(" %s %s %s %s %s",
        make_tab("All", "all", TUI.filter_tab == "all"),
        make_tab("Branches", "branches", TUI.filter_tab == "branches"),
        make_tab("Tags", "tags", TUI.filter_tab == "tags"),
        make_tab("Remotes", "remotes", TUI.filter_tab == "remotes"),
        make_tab("Commits", "commits", TUI.filter_tab == "commits")
    )
    local r_hash_disp = ""
    if cur_item and cur_preview then
        local head_tag = cur_item.is_head and (C.b_green .. " (HEAD)" .. C.reset) or ""
        if cur_item.type == "commit" then
            local date_str = (#cur_item.date > 0) and ("  " .. C.gray .. cur_item.date .. C.reset) or ""
            r_hash_disp = string.format(" Commit: %s%s%s%s%s",
                C.b_yellow, cur_item.sha, C.reset, head_tag, date_str)
        else
            r_hash_disp = string.format(" Ref: %s%s%s  Commit: %s%s%s%s",
                C.b_cyan, truncate_string(cur_item.name, 18), C.reset,
                C.b_yellow, cur_item.sha, C.reset, head_tag)
        end
    else
        r_hash_disp = C.gray .. " (No ref selected)" .. C.reset
    end
    write_str(make_split_row(tabs_disp, r_hash_disp))

    write_str(C.b_cyan .. BOX.vl .. string.rep(BOX.h, left_w) .. BOX.x .. string.rep(BOX.h, right_w) .. BOX.vr .. C.reset .. "\n")

    -- 4. Main Body: List on Left, Preview on Right
    local list_lines_avail = rows - 12
    if list_lines_avail < 4 then list_lines_avail = 4 end

    -- Adjust scrolling
    if TUI.selection <= TUI.scroll then
        TUI.scroll = TUI.selection - 1
    elseif TUI.selection > TUI.scroll + list_lines_avail then
        TUI.scroll = TUI.selection - list_lines_avail
    end

    for i = 1, list_lines_avail do
        local idx = TUI.scroll + i
        local it = TUI.filtered_items[idx]
        local l_line = ""

        if it then
            local badge = ""
            if it.type == "local" then
                badge = C.b_green .. "[LOCAL ]" .. C.reset
            elseif it.type == "tag" then
                badge = C.b_magenta .. "[TAG   ]" .. C.reset
            elseif it.type == "remote" then
                badge = C.b_blue .. "[REMOTE]" .. C.reset
            elseif it.type == "commit" then
                badge = C.b_yellow .. "[COMMIT]" .. C.reset
            end

            local head_marker = it.is_head and (C.b_green .. "* " .. C.reset) or "  "
            local is_sel = (idx == TUI.selection)
            local sel_cursor = is_sel and (C.reverse .. "> ") or "  "

            local max_name_len = left_w - 24
            if max_name_len < 8 then max_name_len = 8 end
            local name_disp
            if it.type == "commit" then
                name_disp = truncate_string(it.sha .. " " .. it.subject, max_name_len)
            else
                name_disp = truncate_string(it.name, max_name_len)
            end
            if is_sel then
                name_disp = C.b_white .. name_disp .. C.reset
            end

            local date_disp = C.gray .. truncate_string(it.date, 10) .. C.reset
            l_line = string.format("%s%s%s %-12s %s", sel_cursor, head_marker, badge, name_disp, date_disp)
        else
            l_line = ""
        end

        -- Right column content
        local r_line = ""
        if cur_preview then
            if i == 1 then
                r_line = string.format(" Author: %s%s%s <%s>", C.b_white, cur_preview.author, C.reset, cur_preview.email)
            elseif i == 2 then
                r_line = string.format(" Date:   %s%s%s", C.gray, cur_preview.date, C.reset)
            elseif i == 3 then
                r_line = string.format(" Subj:   %s%s%s", C.white, truncate_string(cur_preview.subject, right_w - 10), C.reset)
            elseif i == 4 then
                if TUI.preview_scroll > 0 then
                    local scroll_info = string.format(" [▲ +%d]", TUI.preview_scroll)
                    local bar_len = right_w - 2 - utf8_col_width(scroll_info)
                    if bar_len < 2 then bar_len = 2 end
                    r_line = C.dim .. string.rep("─", bar_len) .. C.reset .. C.b_yellow .. scroll_info .. C.reset
                else
                    r_line = C.dim .. string.rep("─", right_w - 2) .. C.reset
                end
            else
                local line_idx = (i - 4) + TUI.preview_scroll
                local entry = (cur_preview.display_lines and cur_preview.display_lines[line_idx]) or (cur_preview.graph and cur_preview.graph[line_idx])
                if entry then
                    r_line = " " .. truncate_string(entry, right_w - 4)
                end
            end
        end

        write_str(make_split_row(l_line, r_line))
    end

    -- Bottom border of split view
    write_str(C.b_cyan .. BOX.vl .. string.rep(BOX.h, left_w) .. BOX.tb .. string.rep(BOX.h, right_w) .. BOX.vr .. C.reset .. "\n")

    -- 5. Status / Warning Line
    local total_count = #TUI.filtered_items
    local pos_info = string.format(" Showing %d of %d items ", total_count, #TUI.items)
    local mode_badge = (TUI.mode == "search")
        and (C.bg_yellow .. C.black .. " [SEARCH] " .. C.reset)
        or (C.bg_blue .. C.b_white .. " [NORMAL] " .. C.reset)
    local stat_left = " " .. mode_badge .. " " .. TUI.status_color .. TUI.status_msg .. C.reset
    local stat_gap = inner_w - utf8_col_width(stat_left) - utf8_col_width(pos_info) - 1
    if stat_gap < 1 then stat_gap = 1 end
    write_str(make_full_row(stat_left .. string.rep(" ", stat_gap) .. C.gray .. pos_info .. C.reset))

    -- 6. Footer Box
    write_str(C.b_cyan .. BOX.bl .. string.rep(BOX.h, inner_w) .. BOX.br .. C.reset .. "\n")

    local function fmt_hotkey(k, label)
        return C.b_yellow .. "[" .. k .. "]" .. C.reset .. " " .. C.white .. label .. "  "
    end

    local footer_keys
    if TUI.mode == "search" then
        footer_keys = " " .. fmt_hotkey("Enter", "Apply") .. fmt_hotkey("Esc", "Cancel")
                   .. fmt_hotkey("Up/Down", "Select") .. fmt_hotkey("Ctrl+p/n", "Nav")
    else
        if cols >= 120 then
            footer_keys = " " .. fmt_hotkey("Enter", "Checkout") .. fmt_hotkey("j/k", "Nav")
                       .. fmt_hotkey("/", "Search") .. fmt_hotkey("n/N", "Match")
                       .. fmt_hotkey("c", "Commits")
                       .. fmt_hotkey("f", "Force") .. fmt_hotkey("s", "Sub")
                       .. fmt_hotkey("h/l", "Tabs") .. fmt_hotkey("w", "Worktree")
                       .. fmt_hotkey("?", "Help") .. fmt_hotkey("q", "Quit")
        elseif cols >= 95 then
            footer_keys = " " .. fmt_hotkey("Enter", "Checkout") .. fmt_hotkey("j/k", "Nav")
                       .. fmt_hotkey("/", "Search") .. fmt_hotkey("c", "Commits")
                       .. fmt_hotkey("f", "Force") .. fmt_hotkey("s", "Sub")
                       .. fmt_hotkey("w", "Worktree") .. fmt_hotkey("q", "Quit")
        else
            footer_keys = " " .. fmt_hotkey("Enter", "Switch") .. fmt_hotkey("j/k", "Nav")
                       .. fmt_hotkey("/", "Search") .. fmt_hotkey("c", "Commits")
                       .. fmt_hotkey("f", "Force") .. fmt_hotkey("q", "Quit")
        end
    end

    local force_pill
    if TUI.force then
        force_pill = C.bg_red .. C.b_white .. " FORCE: ON " .. C.reset
    else
        force_pill = C.bg_darkblue .. C.gray .. " FORCE: OFF " .. C.reset
    end

    local sub_pill
    if TUI.submodule then
        sub_pill = C.bg_blue .. C.b_white .. " SUB: ON " .. C.reset
    else
        sub_pill = C.bg_darkblue .. C.gray .. " SUB: OFF " .. C.reset
    end

    local pills = force_pill .. " " .. sub_pill
    local keys_w = utf8_col_width(footer_keys)
    local pill_w = utf8_col_width(pills)
    local footer_gap = cols - keys_w - pill_w
    if footer_gap < 0 then footer_gap = 0 end

    write_str(C.bg_darkblue .. footer_keys .. string.rep(" ", footer_gap) .. pills .. C.reset)

    -- Render Modal if open
    if TUI.modal then
        TUI.render_modal(cols, rows, buf)
    end

    io.write(table.concat(buf))
    io.flush()
end

function TUI.render_modal(cols, rows, buf)
    local mw = math.min(74, cols - 4)
    local mh = math.min(22, rows - 2)
    local mx = math.floor((cols - mw) / 2)
    local my = math.floor((rows - mh) / 2)

    local function mwrite(r, text)
        table.insert(buf, string.format("\27[%d;%dH%s", my + r, mx, text))
    end

    mwrite(0, C.b_yellow .. BOX.tl .. string.rep(BOX.h, mw - 2) .. BOX.tr .. C.reset)
    for r = 1, mh - 2 do
        mwrite(r, C.b_yellow .. BOX.v .. C.bg_black .. string.rep(" ", mw - 2) .. C.reset .. C.b_yellow .. BOX.v .. C.reset)
    end
    mwrite(mh - 1, C.b_yellow .. BOX.bl .. string.rep(BOX.h, mw - 2) .. BOX.br .. C.reset)

    if TUI.modal == "worktree" then
        mwrite(0, C.b_yellow .. BOX.tl .. C.b_white .. " Create Git Worktree " .. C.b_yellow .. string.rep(BOX.h, math.max(0, mw - 24)) .. BOX.tr .. C.reset)
        local cur_item = TUI.filtered_items[TUI.selection]
        local ref_name = cur_item and cur_item.name or "HEAD"
        mwrite(2, C.b_yellow .. BOX.v .. " " .. C.white .. "Target Ref: " .. C.b_cyan .. ref_name .. C.reset)
        mwrite(4, C.b_yellow .. BOX.v .. " " .. C.white .. "Worktree Directory Path:" .. C.reset)
        mwrite(5, C.b_yellow .. BOX.v .. " " .. C.b_yellow .. "> " .. C.b_white .. TUI.worktree_input .. "_" .. C.reset)
        mwrite(mh - 2, C.b_yellow .. BOX.v .. C.gray .. pad_string(" [Enter] Create  [Esc] Cancel", mw - 4) .. C.b_yellow .. BOX.v .. C.reset)

    elseif TUI.modal == "commits" then
        local ref_label = truncate_string(TUI.branch_commits_ref or "Branch", 24)
        local modal_title = string.format(" Recent Commits on %s ", ref_label)
        local title_pad = mw - 2 - utf8_col_width(modal_title)
        if title_pad < 0 then title_pad = 0 end
        mwrite(0, C.b_yellow .. BOX.tl .. C.b_white .. modal_title .. C.b_yellow .. string.rep(BOX.h, title_pad) .. BOX.tr .. C.reset)

        local avail = mh - 4
        if avail < 2 then avail = 2 end

        if #TUI.branch_commits == 0 then
            mwrite(2, C.b_yellow .. BOX.v .. " " .. C.gray .. pad_string("No commits found for this ref.", mw - 4) .. " " .. C.b_yellow .. BOX.v .. C.reset)
        else
            -- Scroll calculation
            if TUI.modal_selection <= TUI.modal_scroll then
                TUI.modal_scroll = TUI.modal_selection - 1
            elseif TUI.modal_selection > TUI.modal_scroll + avail then
                TUI.modal_scroll = TUI.modal_selection - avail
            end

            for row = 1, avail do
                local idx = TUI.modal_scroll + row
                local c = TUI.branch_commits[idx]
                if c then
                    local is_sel = (idx == TUI.modal_selection)
                    local cursor = is_sel and (C.reverse .. "> ") or "  "
                    local head_marker = c.is_head and (C.b_green .. "* " .. C.reset) or "  "
                    local sha_disp = C.b_yellow .. c.sha .. C.reset
                    local date_disp = C.gray .. truncate_string(c.date, 10) .. C.reset
                    local author_disp = C.cyan .. truncate_string(c.author, 10) .. C.reset

                    local fixed_w = 2 + 2 + 7 + 1 + 10 + 1 + 10 + 1
                    local max_subj_w = (mw - 4) - fixed_w
                    if max_subj_w < 10 then max_subj_w = 10 end
                    local subj_disp = truncate_string(c.subject, max_subj_w)
                    if is_sel then subj_disp = C.b_white .. subj_disp .. C.reset end

                    local line_content = string.format("%s%s%s %-10s %-10s %s", cursor, head_marker, sha_disp, date_disp, author_disp, subj_disp)
                    mwrite(row, C.b_yellow .. BOX.v .. " " .. pad_string(line_content, mw - 4) .. " " .. C.b_yellow .. BOX.v .. C.reset)
                else
                    mwrite(row, C.b_yellow .. BOX.v .. string.rep(" ", mw - 2) .. BOX.v .. C.reset)
                end
            end
        end

        local count_info = string.format("(%d/%d)", TUI.modal_selection, #TUI.branch_commits)
        local hint_text = string.format(" [Enter] Checkout  [j/k] Nav  [Esc] Close %s", count_info)
        mwrite(mh - 2, C.b_yellow .. BOX.v .. C.gray .. pad_string(hint_text, mw - 4) .. C.b_yellow .. BOX.v .. C.reset)

    elseif TUI.modal == "help" then
        mwrite(0, C.b_yellow .. BOX.tl .. C.b_white .. " Keyboard Shortcuts & Help " .. C.b_yellow .. string.rep(BOX.h, math.max(0, mw - 30)) .. BOX.tr .. C.reset)
        local lines = {
            C.b_yellow .. "Vim Navigation (Normal Mode):" .. C.reset,
            "  j / Down, k / Up   Move selection cursor down / up",
            "  h / Left, l / Right  Cycle tabs (All -> Branches -> Tags -> Remotes -> Commits)",
            "  gg / G, Home / End Jump to first / last ref or commit",
            "  Ctrl+d / Ctrl+u    Half-page scroll down / up",
            "  Ctrl+e / Ctrl+y    Scroll commit preview & graph down / up",
            C.b_yellow .. "Search & Filtering:" .. C.reset,
            "  /                  Enter Search Mode (live fuzzy filtering)",
            "  n / N              Jump to next / previous match in list",
            "  Enter (in Search)  Lock search and return to Normal Mode",
            "  Esc                Cancel search mode, or clear active filter",
            C.b_yellow .. "Actions & Checkout:" .. C.reset,
            "  Enter              Checkout selected branch, tag, or commit",
            "  c                  Browse & checkout commits of selected branch",
            "  f                  Toggle Force Mode (git checkout -f) [Default: ON]",
            "  s                  Toggle Submodule Auto-Sync (--init --recursive -f)",
            "  w                  Create Git Worktree for selected ref",
            "  q / Ctrl+C         Quit FCO",
        }
        for i, l in ipairs(lines) do
            if i <= mh - 4 then
                mwrite(i, C.b_yellow .. BOX.v .. " " .. pad_string(l, mw - 4) .. " " .. C.b_yellow .. BOX.v .. C.reset)
            end
        end
        mwrite(mh - 2, C.b_yellow .. BOX.v .. C.gray .. pad_string(" Press [Esc], [Enter], or [?] to close", mw - 4) .. C.b_yellow .. BOX.v .. C.reset)
    end
end

--------------------------------------------------------------------------------
-- Interactive TUI Run Loop
--------------------------------------------------------------------------------
function TUI.run()
    Term.init()
    Term.enable_raw()

    local running = true
    local needs_render = true
    local checkout_target = nil
    local checkout_force = false
    local checkout_submodule = false

    while running do
        if needs_render then
            TUI.render()
            needs_render = false
        end

        local key = Term.read_key()
        if key then
            needs_render = true

            if TUI.modal == "worktree" then
                if key == "esc" then
                    TUI.modal = nil
                elseif key == "enter" then
                    if #TUI.worktree_input > 0 then
                        local item = TUI.filtered_items[TUI.selection]
                        if item then
                            Term.restore()
                            print(C.b_cyan .. "[FCO] Creating git worktree at '" .. TUI.worktree_input .. "'..." .. C.reset)
                            local ok, cmd, out = Git.execute_worktree(item, TUI.worktree_input)
                            if ok then
                                print(C.b_green .. "[SUCCESS] Worktree created: " .. TUI.worktree_input .. C.reset)
                            else
                                print(C.b_red .. "[ERROR] Worktree creation failed:\n" .. out .. C.reset)
                            end
                            os.exit(ok and 0 or 1)
                        end
                    end
                    TUI.modal = nil
                elseif key == "backspace" then
                    if #TUI.worktree_input > 0 then
                        TUI.worktree_input = TUI.worktree_input:sub(1, -2)
                    end
                elseif #key == 1 and key:byte(1) >= 32 and key:byte(1) <= 126 then
                    TUI.worktree_input = TUI.worktree_input .. key
                end

            elseif TUI.modal == "commits" then
                if key == "esc" or key == "q" then
                    TUI.modal = nil
                elseif key == "j" or key == "down" then
                    if TUI.modal_selection < #TUI.branch_commits then
                        TUI.modal_selection = TUI.modal_selection + 1
                    end
                elseif key == "k" or key == "up" then
                    if TUI.modal_selection > 1 then
                        TUI.modal_selection = TUI.modal_selection - 1
                    end
                elseif key == "home" or key == "g" then
                    TUI.modal_selection = 1
                elseif key == "end" or key == "G" then
                    TUI.modal_selection = math.max(1, #TUI.branch_commits)
                elseif key == "pagedown" or key == "ctrl_d" then
                    TUI.modal_selection = math.min(#TUI.branch_commits, TUI.modal_selection + 6)
                elseif key == "pageup" or key == "ctrl_u" then
                    TUI.modal_selection = math.max(1, TUI.modal_selection - 6)
                elseif key == "enter" then
                    local c_item = TUI.branch_commits[TUI.modal_selection]
                    if c_item then
                        checkout_target = c_item
                        checkout_force = TUI.force
                        checkout_submodule = TUI.submodule
                        running = false
                    end
                end

            elseif TUI.modal == "help" then
                if key == "esc" or key == "enter" or key == "?" or key == "q" then
                    TUI.modal = nil
                end

            elseif TUI.mode == "search" then
                if key == "enter" then
                    TUI.mode = "normal"
                    TUI.status_msg = "Search locked. [j/k] Nav, [n/N] Next/Prev match, [Esc] Clear."
                    TUI.status_color = C.b_green

                elseif key == "esc" then
                    TUI.query = TUI.saved_query
                    TUI.filter_and_rank()
                    TUI.mode = "normal"
                    TUI.status_msg = "Search cancelled."
                    TUI.status_color = C.gray

                elseif key == "backspace" then
                    if #TUI.query > 0 then
                        TUI.query = TUI.query:sub(1, -2)
                        TUI.filter_and_rank()
                    end

                elseif key == "up" or key == "ctrl_p" then
                    if TUI.selection > 1 then
                        TUI.selection = TUI.selection - 1
                        TUI.preview_scroll = 0
                    end

                elseif key == "down" or key == "ctrl_n" then
                    if TUI.selection < #TUI.filtered_items then
                        TUI.selection = TUI.selection + 1
                        TUI.preview_scroll = 0
                    end

                elseif #key == 1 and key:byte(1) >= 32 and key:byte(1) <= 126 then
                    TUI.query = TUI.query .. key
                    TUI.filter_and_rank()
                end

            else
                -- Normal mode: Full Vim Keybindings
                local is_g_key = (key == "g")
                if not is_g_key then
                    TUI.g_pending = false
                end

                if key == "q" or key == "ctrl_c" then
                    running = false

                elseif key == "/" then
                    TUI.saved_query = TUI.query
                    TUI.mode = "search"
                    TUI.status_msg = "-- SEARCH -- Type query to filter. [Enter] Confirm, [Esc] Cancel."
                    TUI.status_color = C.b_yellow

                elseif key == "j" or key == "down" then
                    if TUI.selection < #TUI.filtered_items then
                        TUI.selection = TUI.selection + 1
                        TUI.preview_scroll = 0
                    end

                elseif key == "k" or key == "up" then
                    if TUI.selection > 1 then
                        TUI.selection = TUI.selection - 1
                        TUI.preview_scroll = 0
                    end

                elseif key == "h" or key == "left" then
                    TUI.cycle_tab_backward()

                elseif key == "l" or key == "right" or key == "tab" then
                    TUI.cycle_tab_forward()

                elseif key == "g" then
                    if TUI.g_pending then
                        TUI.selection = 1
                        TUI.preview_scroll = 0
                        TUI.g_pending = false
                    else
                        TUI.g_pending = true
                    end

                elseif key == "G" or key == "end" then
                    TUI.selection = math.max(1, #TUI.filtered_items)
                    TUI.preview_scroll = 0

                elseif key == "home" then
                    TUI.selection = 1
                    TUI.preview_scroll = 0

                elseif key == "ctrl_d" or key == "pagedown" then
                    TUI.selection = math.min(#TUI.filtered_items, TUI.selection + 8)
                    TUI.preview_scroll = 0

                elseif key == "ctrl_u" or key == "pageup" then
                    TUI.selection = math.max(1, TUI.selection - 8)
                    TUI.preview_scroll = 0

                elseif key == "ctrl_e" then
                    TUI.preview_scroll = TUI.preview_scroll + 1

                elseif key == "ctrl_y" then
                    TUI.preview_scroll = math.max(0, TUI.preview_scroll - 1)

                elseif key == "n" then
                    TUI.next_match()

                elseif key == "N" then
                    TUI.prev_match()

                elseif key == "esc" then
                    if #TUI.query > 0 then
                        TUI.query = ""
                        TUI.filter_and_rank()
                        TUI.status_msg = "Search filter cleared."
                        TUI.status_color = C.gray
                    else
                        running = false
                    end

                elseif key == "f" then
                    TUI.force = not TUI.force
                    if TUI.force then
                        TUI.status_msg = "Force Mode ENABLED (will run 'git checkout -f')"
                        TUI.status_color = C.b_yellow
                    else
                        TUI.status_msg = "Force Mode DISABLED"
                        TUI.status_color = C.gray
                    end

                elseif key == "s" then
                    TUI.submodule = not TUI.submodule
                    if TUI.submodule then
                        TUI.status_msg = "Submodule Sync ENABLED (git submodule update --init --recursive -f)"
                        TUI.status_color = C.b_cyan
                    else
                        TUI.status_msg = "Submodule Sync DISABLED"
                        TUI.status_color = C.gray
                    end

                elseif key == "?" then
                    TUI.modal = "help"

                elseif key == "c" then
                    local item = TUI.filtered_items[TUI.selection]
                    if item then
                        local target_ref = (item.type == "commit") and item.sha or item.full_ref
                        TUI.branch_commits = Git.fetch_branch_commits(target_ref, 50)
                        TUI.branch_commits_ref = item.name
                        TUI.modal_selection = 1
                        TUI.modal_scroll = 0
                        TUI.modal = "commits"
                    end

                elseif key == "w" then
                    local item = TUI.filtered_items[TUI.selection]
                    if item then
                        local base = item.name:gsub("^[^/]+/", ""):gsub("[^%w%-_]", "-")
                        TUI.worktree_input = "../" .. base
                        TUI.modal = "worktree"
                    end

                elseif key == "enter" then
                    local item = TUI.filtered_items[TUI.selection]
                    if item then
                        checkout_target = item
                        checkout_force = TUI.force
                        checkout_submodule = TUI.submodule
                        running = false
                    end
                end
            end
        end

        if IS_WINDOWS then
            ffi.C.Sleep(20)
        else
            ffi.C.usleep(20000)
        end
    end

    Term.restore()

    -- Perform checkout if selected
    if checkout_target then
        print(C.b_cyan .. "[FCO] Running: " .. Git.build_checkout_cmd(checkout_target, checkout_force) .. C.reset)
        local ok, cmd, out = Git.execute_checkout(checkout_target, checkout_force)
        if ok then
            local desc = checkout_target.name
            if checkout_target.type == "commit" then
                desc = checkout_target.sha .. " (" .. truncate_string(checkout_target.subject, 40) .. ") [detached HEAD]"
            end
            print(C.b_green .. "[SUCCESS] Checked out: " .. desc .. C.reset)
            if #out > 0 then
                io.write(out)
            end
            if checkout_submodule then
                print(C.b_cyan .. "[FCO] Synchronizing submodules: " .. Git.build_submodule_cmd(checkout_force) .. C.reset)
                local s_ok, s_cmd, s_out = Git.update_submodules(checkout_force)
                if s_ok then
                    print(C.b_green .. "[SUCCESS] Submodules synchronized." .. C.reset)
                    if #s_out > 0 then io.write(s_out) end
                else
                    print(C.b_red .. "[WARNING] Submodule synchronization returned warnings/errors:\n" .. s_out .. C.reset)
                end
            end
        else
            print(C.b_red .. "[ERROR] Checkout failed:\n" .. out .. C.reset)
            if not checkout_force and TUI.dirty then
                print(C.b_yellow .. "[HINT] Your working tree has local modifications. Re-run with '--force' or '-f' to discard local changes." .. C.reset)
            end
            os.exit(1)
        end
    end
end

--------------------------------------------------------------------------------
-- Non-Interactive CLI / Batch Mode
--------------------------------------------------------------------------------
local function run_cli_list(force, filter_type, submodule)
    local items = Git.fetch_all_refs()
    local dirty, mod, untrk = Git.get_dirty_status()
    local current_head = Git.get_current_head()

    print(string.format("%s=== FCO: Branches & Tags for %s ===%s", C.b_cyan, Git.get_repo_root(), C.reset))
    print(string.format("Current HEAD: %s%s%s | Working Tree: %s",
        C.b_green, current_head, C.reset,
        dirty and (C.b_yellow .. string.format("[DIRTY: %d modified]", mod) .. C.reset) or (C.b_green .. "[CLEAN]" .. C.reset)))
    print(string.format("Force Mode: %s | Submodules: %s | Filter: %s\n",
        force and (C.b_red .. "ENABLED" .. C.reset) or (C.gray .. "DISABLED" .. C.reset),
        submodule and (C.b_cyan .. "ENABLED" .. C.reset) or (C.gray .. "DISABLED" .. C.reset),
        filter_type and (C.cyan .. filter_type:upper() .. C.reset) or (C.gray .. "ALL" .. C.reset)))

    print(string.format("%-10s %-32s %-10s %-16s %s", "TYPE", "NAME", "COMMIT", "DATE", "SUBJECT"))
    print(string.rep("─", 90))

    for _, it in ipairs(items) do
        local match = true
        if filter_type == "branches" and it.type ~= "local" then match = false end
        if filter_type == "tags" and it.type ~= "tag" then match = false end
        if filter_type == "remotes" and it.type ~= "remote" then match = false end
        if filter_type == "commits" and it.type ~= "commit" then match = false end

        if match then
            local head_tag = it.is_head and "*" or " "
            local type_color = (it.type == "local" and C.b_green) or (it.type == "tag" and C.b_magenta) or (it.type == "commit" and C.b_yellow) or C.b_blue
            local type_label = string.format("%s[%s]%s", type_color, it.type:upper(), C.reset)
            local raw_name = (it.type == "commit") and (it.sha .. " " .. it.subject) or it.name
            local name_disp = truncate_string(head_tag .. " " .. raw_name, 30)
            local subj_disp = truncate_string(it.subject, 32)
            print(string.format("%-18s %-32s %-10s %-16s %s",
                type_label, name_disp, it.sha, truncate_string(it.date, 14), subj_disp))
        end
    end
end

local function run_cli_checkout(target_name, force, submodule)
    local items = Git.fetch_all_refs()
    local matched = nil

    -- 1. Exact match
    for _, it in ipairs(items) do
        if it.name == target_name or it.name:lower() == target_name:lower() or (it.sha and it.sha:lower() == target_name:lower()) then
            matched = it
            break
        end
    end

    -- 2. Fuzzy match fallback
    if not matched then
        for _, it in ipairs(items) do
            if it.name:find(target_name, 1, true) then
                matched = it
                break
            end
        end
    end

    -- 3. Direct commit SHA check fallback
    if not matched then
        local is_commit, full_sha = Git.is_valid_commit(target_name)
        if is_commit then
            local full_sha_res, short_sha, subj, auth, dt = Git.resolve_commit(full_sha)
            matched = {
                type = "commit",
                name = short_sha,
                sha = short_sha,
                full_ref = full_sha_res,
                subject = subj or "",
                author = auth or "",
                date = dt or "",
            }
        end
    end

    if not matched then
        io.stderr:write(string.format("Error: Branch, tag, or commit '%s' not found.\n", target_name))
        os.exit(1)
    end

    print(string.format("[FCO] Switching to %s '%s' (force=%s, submodule=%s)...", matched.type, matched.name, tostring(force), tostring(submodule)))
    local ok, cmd, out = Git.execute_checkout(matched, force)
    if ok then
        local desc = matched.name
        if matched.type == "commit" then
            desc = matched.sha .. " (" .. truncate_string(matched.subject, 40) .. ") [detached HEAD]"
        end
        print(C.b_green .. "[SUCCESS] Checked out: " .. desc .. C.reset)
        if #out > 0 then io.write(out) end
        if submodule then
            print(C.b_cyan .. "[FCO] Synchronizing submodules: " .. Git.build_submodule_cmd(force) .. C.reset)
            local s_ok, s_cmd, s_out = Git.update_submodules(force)
            if s_ok then
                print(C.b_green .. "[SUCCESS] Submodules synchronized." .. C.reset)
                if #s_out > 0 then io.write(s_out) end
            else
                io.stderr:write(C.b_red .. "[WARNING] Submodule synchronization returned warnings/errors:\n" .. s_out .. C.reset .. "\n")
            end
        end
        os.exit(0)
    else
        io.stderr:write(C.b_red .. "[ERROR] Checkout failed:\n" .. out .. C.reset .. "\n")
        if not force then
            io.stderr:write(C.b_yellow .. "[HINT] Use '--force' or '-f' to discard local changes and overwrite.\n" .. C.reset)
        end
        os.exit(1)
    end
end

--------------------------------------------------------------------------------
-- Automated Self-Test Suite (--test)
--------------------------------------------------------------------------------
local function run_test_suite()
    print("=== Running fco.lua Automated Test Suite ===")
    local passed = 0
    local failed = 0

    local function assert_eq(actual, expected, desc)
        if actual == expected then
            print(string.format("  [PASS] %s", desc))
            passed = passed + 1
        else
            print(string.format("  [FAIL] %s: expected '%s', got '%s'", desc, tostring(expected), tostring(actual)))
            failed = failed + 1
        end
    end

    -- Test 1: Fuzzy Matching Algorithm
    print("\n[Test 1] Fuzzy Search Algorithm...")
    local s1 = fuzzy_score("mstr", "master")
    assert_eq(s1 ~= nil and s1 > 0, true, "Fuzzy matches 'mstr' in 'master'")
    local s2 = fuzzy_score("v01", "v0.0.1")
    assert_eq(s2 ~= nil and s2 > 0, true, "Fuzzy matches 'v01' in 'v0.0.1'")
    local s3 = fuzzy_score("xyz", "master")
    assert_eq(s3, nil, "Fuzzy returns nil for non-matching query")
    local s_pref = fuzzy_score("doc", "docker-compose")
    local s_sub  = fuzzy_score("doc", "undocumented")
    assert_eq(s_pref > s_sub, true, "Word boundary match ranks higher than mid-word match")

    -- Test 2: Ref Type Classification
    print("\n[Test 2] Git Ref Type Classification...")
    assert_eq(Git.parse_ref_type("refs/heads/master"), "local", "refs/heads/* is local")
    assert_eq(Git.parse_ref_type("refs/heads/feature/login"), "local", "refs/heads/feature/* is local")
    assert_eq(Git.parse_ref_type("refs/tags/v1.0.0"), "tag", "refs/tags/* is tag")
    assert_eq(Git.parse_ref_type("refs/remotes/origin/master"), "remote", "refs/remotes/* is remote")

    -- Test 3: Checkout Command Construction
    print("\n[Test 3] Checkout Command Construction...")
    local local_item  = { type = "local", name = "master" }
    local tag_item    = { type = "tag", name = "v0.0.1" }
    local rem_item    = { type = "remote", name = "origin/track/master" }
    local commit_item = { type = "commit", name = "a1b2c3d", sha = "a1b2c3d" }

    assert_eq(Git.build_checkout_cmd(local_item, false), "git checkout master", "Normal local checkout")
    assert_eq(Git.build_checkout_cmd(local_item, true), "git checkout -f master", "Force local checkout")
    assert_eq(Git.build_checkout_cmd(tag_item, false), "git checkout tags/v0.0.1", "Normal tag checkout")
    assert_eq(Git.build_checkout_cmd(tag_item, true), "git checkout -f tags/v0.0.1", "Force tag checkout")
    assert_eq(Git.build_checkout_cmd(rem_item, false), "git checkout track/master", "Remote branch stripped to local name")
    assert_eq(Git.build_checkout_cmd(rem_item, true), "git checkout -f track/master", "Force remote branch stripped to local name")
    assert_eq(Git.build_checkout_cmd(commit_item, false), "git checkout a1b2c3d", "Normal commit checkout")
    assert_eq(Git.build_checkout_cmd(commit_item, true), "git checkout -f a1b2c3d", "Force commit checkout")

    -- Test 4: Unicode Layout & Column Geometry
    print("\n[Test 4] Unicode Layout & Column Geometry...")
    assert_eq(utf8_col_width("test"), 4, "ASCII column width")
    assert_eq(utf8_col_width(C.b_green .. "master" .. C.reset), 6, "ANSI stripped column width")
    assert_eq(utf8_col_width(pad_string("master", 10)), 10, "pad_string width")
    local trunc = truncate_string("very long branch name that exceeds limit", 15)
    assert_eq(utf8_col_width(trunc), 15, "truncate_string visual width")

    -- Test 5: Git Repository Detection
    print("\n[Test 5] Git Repository Status...")
    local is_repo = Git.is_repo()
    assert_eq(is_repo, true, "Current directory is detected as git repository")
    local head = Git.get_current_head()
    assert_eq(#head > 0, true, "Successfully retrieved current HEAD branch")

    -- Test 6: Submodule Command Construction & Default State
    print("\n[Test 6] Submodule Command Construction & Defaults...")
    assert_eq(Git.build_submodule_cmd(true), "git submodule update --init --recursive -f", "Force submodule update command")
    assert_eq(Git.build_submodule_cmd(false), "git submodule update --init --recursive", "Non-force submodule update command")
    local orig_sub = TUI.submodule
    TUI.init(nil, true, nil)
    assert_eq(TUI.submodule, false, "Submodule sync is disabled by default (checkout only)")
    TUI.init(nil, true, true)
    assert_eq(TUI.submodule, true, "Submodule sync can be enabled via initial parameter")
    TUI.submodule = orig_sub

    -- Test 7: Vim Navigation & Tab Cycling Logic
    print("\n[Test 7] Vim Navigation & Tab Cycling...")
    local orig_items = TUI.items
    local orig_tab = TUI.filter_tab
    local orig_query = TUI.query
    TUI.items = {
        { name = "master", type = "local", subject = "" },
        { name = "develop", type = "local", subject = "" },
        { name = "v1.0", type = "tag", subject = "" },
        { name = "origin/master", type = "remote", subject = "" },
        { name = "abc1234", type = "commit", sha = "abc1234", subject = "test commit" },
    }
    TUI.filter_tab = "all"
    TUI.query = ""
    TUI.filter_and_rank()
    assert_eq(#TUI.filtered_items, 4, "All tabs shows 4 ref items (excluding raw commits until queried)")

    TUI.cycle_tab_forward()
    assert_eq(TUI.filter_tab, "branches", "Tab cycle forward: branches")
    assert_eq(#TUI.filtered_items, 2, "Branches tab shows 2 items")

    TUI.cycle_tab_forward()
    assert_eq(TUI.filter_tab, "tags", "Tab cycle forward: tags")
    assert_eq(#TUI.filtered_items, 1, "Tags tab shows 1 item")

    TUI.cycle_tab_forward()
    assert_eq(TUI.filter_tab, "remotes", "Tab cycle forward: remotes")
    assert_eq(#TUI.filtered_items, 1, "Remotes tab shows 1 item")

    TUI.cycle_tab_forward()
    assert_eq(TUI.filter_tab, "commits", "Tab cycle forward: commits")
    assert_eq(#TUI.filtered_items, 1, "Commits tab shows 1 item")

    TUI.cycle_tab_backward()
    assert_eq(TUI.filter_tab, "remotes", "Tab cycle backward: remotes")

    -- Test 8: Search Mode & Match Cycling
    print("\n[Test 8] Search Mode & Match Cycling...")
    TUI.filter_tab = "all"
    TUI.query = "master"
    TUI.filter_and_rank()
    assert_eq(#TUI.filtered_items, 2, "Search for 'master' filters to 2 items")
    TUI.selection = 1
    TUI.next_match()
    assert_eq(TUI.selection, 2, "next_match advances selection")
    TUI.next_match()
    assert_eq(TUI.selection, 1, "next_match wraps around to 1")
    TUI.prev_match()
    assert_eq(TUI.selection, 2, "prev_match wraps around to end")

    -- Test 9: Git Commit Resolution & Verification
    print("\n[Test 9] Git Commit Resolution & Verification...")
    local ok_c, head_sha = Git.is_valid_commit("HEAD")
    assert_eq(ok_c, true, "Git.is_valid_commit('HEAD') resolves true")
    assert_eq(head_sha ~= nil and #head_sha >= 40, true, "HEAD resolves to full SHA")
    local invalid_c = Git.is_valid_commit("invalid_nonexistent_sha_012345")
    assert_eq(invalid_c, false, "Invalid commit SHA returns false")
    local commits = Git.fetch_recent_commits(5)
    assert_eq(#commits > 0, true, "Git.fetch_recent_commits retrieves commits")
    assert_eq(commits[1].type, "commit", "First fetched item has type 'commit'")
    local c_details = Git.get_commit_details("HEAD", true)
    assert_eq(#c_details.display_lines > 0, true, "Commit details has display_lines for preview pane")
    assert_eq(type(c_details.stat), "table", "Commit details has stat table")

    -- Test 10: Color Palette Completeness & Search Mode Badge
    print("\n[Test 10] Color Palette & Search Mode Safety...")
    assert_eq(type(C.b_black), "string", "C.b_black is defined as string")
    assert_eq(type(C.black), "string", "C.black is defined as string")
    assert_eq(type(C.bg_yellow), "string", "C.bg_yellow is defined as string")
    local search_badge = C.bg_yellow .. C.black .. " [SEARCH] " .. C.reset
    assert_eq(#search_badge > 0, true, "Search badge concatenates cleanly without nil error")
    local normal_badge = C.bg_blue .. C.b_white .. " [NORMAL] " .. C.reset
    assert_eq(#normal_badge > 0, true, "Normal badge concatenates cleanly without nil error")

    -- Test 11: TUI Full Render Execution in Normal, Search & Modal Modes
    print("\n[Test 11] TUI Full Render in Search & Normal Mode...")
    local orig_io_write = io.write
    local orig_io_flush = io.flush
    local captured = {}
    io.write = function(s) table.insert(captured, s) end
    io.flush = function() end

    TUI.items = orig_items or Git.fetch_all_refs()
    TUI.filter_and_rank()
    TUI.mode = "normal"
    local ok_norm, err_norm = pcall(TUI.render)
    assert_eq(ok_norm, true, "TUI.render() succeeds in Normal mode")

    TUI.mode = "search"
    TUI.query = "feat"
    local ok_srch, err_srch = pcall(TUI.render)
    assert_eq(ok_srch, true, "TUI.render() succeeds in Search mode ('/' keypress)")

    TUI.modal = "commits"
    TUI.branch_commits = Git.fetch_recent_commits(5)
    local ok_modal, err_modal = pcall(TUI.render)
    assert_eq(ok_modal, true, "TUI.render() succeeds in Commits Modal")
    TUI.modal = nil

    io.write = orig_io_write
    io.flush = orig_io_flush

    -- Restore state
    TUI.items = orig_items
    TUI.filter_tab = orig_tab
    TUI.query = orig_query
    TUI.mode = "normal"
    if orig_items and #orig_items > 0 then TUI.filter_and_rank() end

    print(string.format("\nTest Results: %d Passed, %d Failed.", passed, failed))
    return failed == 0 and 0 or 1
end

--------------------------------------------------------------------------------
-- Main Entry Point
--------------------------------------------------------------------------------
local function main(args)
    args = args or {}

    local force = true
    local submodule = false
    local list_mode = false
    local initial_filter = nil
    local target = nil
    local is_batch = false

    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "--test" then
            os.exit(run_test_suite())
        elseif a == "-f" or a == "--force" then
            force = true
        elseif a == "--no-force" then
            force = false
        elseif a == "-s" or a == "--submodule" then
            submodule = true
        elseif a == "--no-submodule" then
            submodule = false
        elseif a == "-l" or a == "--list" then
            list_mode = true
        elseif a == "-b" or a == "--branch" then
            initial_filter = "branches"
        elseif a == "-t" or a == "--tag" then
            initial_filter = "tags"
        elseif a == "-r" or a == "--remote" then
            initial_filter = "remotes"
        elseif a == "-c" or a == "--commit" then
            initial_filter = "commits"
        elseif a == "--batch" then
            is_batch = true
            i = i + 1
            target = args[i]
        elseif a == "-h" or a == "--help" then
            print([[
fco.lua - High-Performance Git Branch, Tag, Commit & Worktree Switcher (LuaJIT + FFI)

Usage:
  luajit fco.lua [OPTIONS] [TARGET]
  fco [OPTIONS] [TARGET]

TARGET can be a branch name, tag name, or commit SHA (e.g. 7-40 hex chars).

Options:
  -f, --force          Force checkout (git checkout -f) [DEFAULT: ON]
  --no-force           Disable force checkout (normal checkout)
  -s, --submodule      Synchronize submodules after checkout (git submodule update --init --recursive -f) [DEFAULT: ON]
  --no-submodule       Disable submodule synchronization
  -b, --branch         Start filtered to branches only
  -t, --tag            Start filtered to tags only
  -r, --remote         Start filtered to remote branches only
  -c, --commit         Start filtered to recent commits only
  -l, --list           Print formatted list of branches, tags, and commits and exit
  --batch <TARGET>     Directly checkout TARGET in batch mode
  --test               Run automated test suite and exit
  -h, --help           Show this help message

TUI Controls (Vim-Style Dual Mode):
  j / Down, k / Up     Move selection cursor down / up
  h / Left, l / Right  Cycle category tabs left / right (All -> Branches -> Tags -> Remotes -> Commits)
  gg / G, Home / End   Jump to first / last ref or commit
  Ctrl+d / Ctrl+u      Half-page scroll down / up
  Ctrl+e / Ctrl+y      Scroll commit preview & graph down / up
  /                    Enter Search Mode (type query to filter)
  Enter                Confirm search (in Search mode) or Checkout (in Normal mode)
  n / N                Jump to next / previous match in filtered list
  Esc                  Cancel search mode, or clear active search filter
  c                    Browse & checkout commits of selected branch
  f                    Toggle Force Mode (git checkout -f) [Default: ON]
  s                    Toggle Submodule Auto-Sync (--init --recursive -f)
  w                    Create Git Worktree for selected ref
  q / Ctrl+C           Quit
]])
            os.exit(0)
        elseif not a:find("^-") and not target then
            target = a
        end
        i = i + 1
    end

    if list_mode then
        run_cli_list(force, initial_filter, submodule)
        os.exit(0)
    end

    if target or is_batch then
        if not target then
            io.stderr:write("Error: --batch requires a target branch, tag, or commit.\n")
            os.exit(1)
        end
        run_cli_checkout(target, force, submodule)
        os.exit(0)
    end

    -- Non-TTY check (auto fallback to list mode if redirected)
    if not IS_WINDOWS and ffi.C.isatty(1) == 0 then
        run_cli_list(force, initial_filter, submodule)
        os.exit(0)
    end

    -- Interactive TUI mode
    TUI.init(initial_filter, force, submodule)
    TUI.run()
end

main(arg)
