#!/usr/bin/env luajit
-- flog.lua - High-Performance Interactive Git Commit & Diff Browser (LuaJIT + FFI)
-- Zero-dependency, flicker-free dual-pane TUI for browsing git commits, stats, and diffs.
--
-- Features:
--   * Cross-platform terminal raw mode via LuaJIT FFI (Windows Kernel32 & POSIX termios)
--   * Flicker-free differential line rendering + DEC Synchronized Output (?2026h/?2026l)
--   * Dual-pane TUI: Commit history list on the left, live colored commit stat + diff on the right
--   * In-memory commit detail cache for zero-latency scrolling through visited commits
--   * Interactive diff scrolling ([ / ] or J / K), branch scope toggle (a), diff view mode (d)
--   * Fuzzy filtering (f or /), copy commit hash to clipboard (y), open commit in $EDITOR (Enter)
--   * Non-interactive CLI modes (--list, --show, --test, --help)

local ffi = require("ffi")
local bit = require("bit")

local IS_WINDOWS = (package.config:sub(1, 1) == "\\")

--------------------------------------------------------------------------------
-- 1. FFI Declarations (Windows & POSIX)
--------------------------------------------------------------------------------
if IS_WINDOWS then
    ffi.cdef[[
        typedef void* HANDLE;
        typedef unsigned long DWORD;
        typedef int BOOL;
        typedef unsigned short WORD;
        typedef short SHORT;
        typedef char CHAR;
        typedef unsigned short WCHAR;

        typedef struct _COORD {
            SHORT X;
            SHORT Y;
        } COORD;

        typedef struct _SMALL_RECT {
            SHORT Left;
            SHORT Top;
            SHORT Right;
            SHORT Bottom;
        } SMALL_RECT;

        typedef struct _CONSOLE_SCREEN_BUFFER_INFO {
            COORD dwSize;
            COORD dwCursorPosition;
            WORD wAttributes;
            SMALL_RECT srWindow;
            COORD dwMaximumWindowSize;
        } CONSOLE_SCREEN_BUFFER_INFO;

        typedef struct _KEY_EVENT_RECORD {
            BOOL bKeyDown;
            WORD wRepeatCount;
            WORD wVirtualKeyCode;
            WORD wVirtualScanCode;
            union {
                WCHAR UnicodeChar;
                CHAR AsciiChar;
            } uChar;
            DWORD dwControlKeyState;
        } KEY_EVENT_RECORD;

        typedef struct _INPUT_RECORD {
            WORD EventType;
            union {
                KEY_EVENT_RECORD KeyEvent;
                unsigned char Padding[16];
            } Event;
        } INPUT_RECORD;

        HANDLE GetStdHandle(DWORD nStdHandle);
        BOOL GetConsoleMode(HANDLE hConsoleHandle, DWORD* lpMode);
        BOOL SetConsoleMode(HANDLE hConsoleHandle, DWORD dwMode);
        BOOL GetConsoleScreenBufferInfo(HANDLE hConsoleOutput, CONSOLE_SCREEN_BUFFER_INFO* lpConsoleScreenBufferInfo);
        BOOL ReadConsoleInputW(HANDLE hConsoleInput, INPUT_RECORD* lpBuffer, DWORD nLength, DWORD* lpNumberOfEventsRead);
        BOOL SetConsoleOutputCP( unsigned int wCodePageID );
        HANDLE CreateFileA(const char* lpFileName, DWORD dwDesiredAccess, DWORD dwShareMode, void* lpSecurityAttributes, DWORD dwCreationDisposition, DWORD dwFlagsAndAttributes, HANDLE hTemplateFile);
        BOOL CloseHandle(HANDLE hObject);
    ]]
else
    ffi.cdef[[
        typedef unsigned int tcflag_t;
        typedef unsigned char cc_t;
        typedef unsigned int speed_t;

        struct winsize {
            unsigned short ws_row;
            unsigned short ws_col;
            unsigned short ws_xpixel;
            unsigned short ws_ypixel;
        };

        int tcgetattr(int fd, void *termios_p);
        int tcsetattr(int fd, int optional_actions, const void *termios_p);
        int ioctl(int fd, unsigned long request, ...);
        long read(int fd, void *buf, size_t count);
        int open(const char *pathname, int flags);
        int close(int fd);

        struct pollfd {
            int fd;
            short events;
            short revents;
        };
        int poll(struct pollfd *fds, unsigned long nfds, int timeout);
    ]]
end

--------------------------------------------------------------------------------
-- 2. ANSI Colors & Box Drawing
--------------------------------------------------------------------------------
local ESC = "\27["
local C = {
    reset     = ESC .. "0m",
    bold      = ESC .. "1m",
    dim       = ESC .. "2m",
    italic    = ESC .. "3m",
    underline = ESC .. "4m",
    reverse   = ESC .. "7m",

    black     = ESC .. "30m",
    red       = ESC .. "31m",
    green     = ESC .. "32m",
    yellow    = ESC .. "33m",
    blue      = ESC .. "34m",
    magenta   = ESC .. "35m",
    cyan      = ESC .. "36m",
    white     = ESC .. "37m",
    gray      = ESC .. "90m",

    b_red     = ESC .. "91m",
    b_green   = ESC .. "92m",
    b_yellow  = ESC .. "93m",
    b_blue    = ESC .. "94m",
    b_magenta = ESC .. "95m",
    b_cyan    = ESC .. "96m",
    b_white   = ESC .. "97m",

    bg_select = ESC .. "48;5;237m",
    bg_header = ESC .. "48;5;235m",
    bg_badge  = ESC .. "48;5;24m",
    bg_add    = ESC .. "48;5;22m",
    bg_del    = ESC .. "48;5;52m",
}

--------------------------------------------------------------------------------
-- 3. Terminal Abstraction
--------------------------------------------------------------------------------
local Term = {
    orig_in_mode = nil,
    orig_out_mode = nil,
    orig_termios = nil,
    tty_fd = 0,
    hIn = nil,
    hOut = nil,
    initialized = false,
}

function Term.get_size()
    if IS_WINDOWS then
        local csbi = ffi.new("CONSOLE_SCREEN_BUFFER_INFO")
        if Term.hOut and ffi.C.GetConsoleScreenBufferInfo(Term.hOut, csbi) ~= 0 then
            local cols = csbi.srWindow.Right - csbi.srWindow.Left + 1
            local rows = csbi.srWindow.Bottom - csbi.srWindow.Top + 1
            if cols > 20 and rows > 5 then return cols, rows end
        end
        local h = ffi.C.CreateFileA("CONOUT$", 0x80000000 + 0x40000000, 3, nil, 3, 0, nil)
        if h ~= ffi.cast("HANDLE", -1) then
            local ok = ffi.C.GetConsoleScreenBufferInfo(h, csbi)
            ffi.C.CloseHandle(h)
            if ok ~= 0 then
                local cols = csbi.srWindow.Right - csbi.srWindow.Left + 1
                local rows = csbi.srWindow.Bottom - csbi.srWindow.Top + 1
                if cols > 20 and rows > 5 then return cols, rows end
            end
        end
        return 120, 30
    else
        local ws = ffi.new("struct winsize")
        local TIOCGWINSZ = (ffi.os == "OSX") and 0x40087468 or 0x5413
        if ffi.C.ioctl(Term.tty_fd, TIOCGWINSZ, ws) == 0 and ws.ws_col > 0 and ws.ws_row > 0 then
            return ws.ws_col, ws.ws_row
        end
        return 120, 30
    end
end

function Term.init()
    if Term.initialized then return end
    if IS_WINDOWS then
        ffi.C.SetConsoleOutputCP(65001)
        Term.hIn = ffi.C.GetStdHandle(-10)
        Term.hOut = ffi.C.GetStdHandle(-11)

        local in_mode = ffi.new("DWORD[1]")
        if ffi.C.GetConsoleMode(Term.hIn, in_mode) ~= 0 then
            Term.orig_in_mode = in_mode[0]
            local new_in = bit.band(in_mode[0], bit.bnot(0x0007))
            new_in = bit.bor(new_in, 0x0008)
            ffi.C.SetConsoleMode(Term.hIn, new_in)
        end

        local out_mode = ffi.new("DWORD[1]")
        if ffi.C.GetConsoleMode(Term.hOut, out_mode) ~= 0 then
            Term.orig_out_mode = out_mode[0]
            ffi.C.SetConsoleMode(Term.hOut, bit.bor(out_mode[0], 0x0004))
        end
    else
        local fd = ffi.C.open("/dev/tty", 2)
        if fd >= 0 then Term.tty_fd = fd else Term.tty_fd = 0 end
        Term.orig_termios = ffi.new("unsigned char[64]")
        if ffi.C.tcgetattr(Term.tty_fd, Term.orig_termios) == 0 then
            local raw = ffi.new("unsigned char[64]")
            ffi.copy(raw, Term.orig_termios, 64)
            local lflag_offset = (ffi.os == "OSX") and 24 or 12
            local lflag_ptr = ffi.cast("unsigned int*", raw + lflag_offset)
            local ICANON = (ffi.os == "OSX") and 0x0100 or 0x0002
            local ECHO   = 0x0008
            local ISIG   = (ffi.os == "OSX") and 0x0080 or 0x0001
            lflag_ptr[0] = bit.band(lflag_ptr[0], bit.bnot(bit.bor(ICANON, ECHO, ISIG)))
            ffi.C.tcsetattr(Term.tty_fd, 0, raw)
        end
    end
    io.write("\27[?1049h\27[?25l\27[2J")
    io.flush()
    Term.initialized = true
end

function Term.shutdown()
    if not Term.initialized then return end
    io.write("\27[?25h\27[?1049l" .. C.reset)
    io.flush()
    if IS_WINDOWS then
        if Term.orig_in_mode and Term.hIn then
            ffi.C.SetConsoleMode(Term.hIn, Term.orig_in_mode)
        end
        if Term.orig_out_mode and Term.hOut then
            ffi.C.SetConsoleMode(Term.hOut, Term.orig_out_mode)
        end
    else
        if Term.orig_termios then
            ffi.C.tcsetattr(Term.tty_fd, 0, Term.orig_termios)
        end
        if Term.tty_fd > 2 then
            ffi.C.close(Term.tty_fd)
        end
    end
    Term.initialized = false
end

function Term.read_key()
    if IS_WINDOWS then
        local ir = ffi.new("INPUT_RECORD[1]")
        local read_cnt = ffi.new("DWORD[1]")
        while true do
            if ffi.C.ReadConsoleInputW(Term.hIn, ir, 1, read_cnt) == 0 then
                return "QUIT"
            end
            if ir[0].EventType == 1 and ir[0].Event.KeyEvent.bKeyDown ~= 0 then
                local ke = ir[0].Event.KeyEvent
                local vk = ke.wVirtualKeyCode
                local ch = ke.uChar.UnicodeChar
                local ctrl = bit.band(ke.dwControlKeyState, 0x0008 + 0x0004) ~= 0

                if vk == 0x26 then return "UP"
                elseif vk == 0x28 then return "DOWN"
                elseif vk == 0x25 then return "LEFT"
                elseif vk == 0x27 then return "RIGHT"
                elseif vk == 0x21 then return "PGUP"
                elseif vk == 0x22 then return "PGDN"
                elseif vk == 0x24 then return "HOME"
                elseif vk == 0x23 then return "END"
                elseif vk == 0x1B then return "ESC"
                elseif vk == 0x0D then return "ENTER"
                elseif vk == 0x08 then return "BACKSPACE"
                elseif vk == 0x09 then return "TAB"
                elseif vk == 0x2E then return "DELETE"
                elseif vk == 0x74 then return "F5"
                end

                if ctrl then
                    if vk == 0x43 then return "CTRL_C"
                    elseif vk == 0x4E then return "DOWN"
                    elseif vk == 0x50 then return "UP"
                    elseif vk == 0x55 then return "CTRL_U"
                    elseif vk == 0x44 then return "PGDN"
                    elseif vk == 0x42 then return "PGUP"
                    end
                end

                if ch >= 32 and ch < 127 then
                    return string.char(ch)
                elseif ch == 3 then
                    return "CTRL_C"
                end
            end
        end
    else
        local buf = ffi.new("unsigned char[8]")
        local n = ffi.C.read(Term.tty_fd, buf, 1)
        if n <= 0 then return "QUIT" end
        local b = buf[0]
        if b == 3 then return "CTRL_C"
        elseif b == 13 or b == 10 then return "ENTER"
        elseif b == 127 or b == 8 then return "BACKSPACE"
        elseif b == 9 then return "TAB"
        elseif b == 14 then return "DOWN"
        elseif b == 16 then return "UP"
        elseif b == 21 then return "CTRL_U"
        elseif b == 4 then return "PGDN"
        elseif b == 2 then return "PGUP"
        elseif b == 27 then
            local pfd = ffi.new("struct pollfd[1]")
            pfd[0].fd = Term.tty_fd
            pfd[0].events = 1
            if ffi.C.poll(pfd, 1, 25) <= 0 then
                return "ESC"
            end
            local n2 = ffi.C.read(Term.tty_fd, buf, 6)
            if n2 <= 0 then return "ESC" end
            local seq = ffi.string(buf, n2)
            if seq == "[A" or seq == "OA" then return "UP"
            elseif seq == "[B" or seq == "OB" then return "DOWN"
            elseif seq == "[C" or seq == "OC" then return "RIGHT"
            elseif seq == "[D" or seq == "OD" then return "LEFT"
            elseif seq == "[5~" then return "PGUP"
            elseif seq == "[6~" then return "PGDN"
            elseif seq == "[H" or seq == "[1~" then return "HOME"
            elseif seq == "[F" or seq == "[4~" then return "END"
            elseif seq == "[3~" then return "DELETE"
            end
            return "ESC"
        elseif b >= 32 and b < 127 then
            return string.char(b)
        end
    end
    return ""
end

--------------------------------------------------------------------------------
-- 4. String & Formatting Utilities
--------------------------------------------------------------------------------
local function trim(s)
    if not s then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function pad_right(s, width)
    s = tostring(s or "")
    if #s >= width then
        if width <= 1 then return s:sub(1, width) end
        return s:sub(1, width - 1) .. "…"
    end
    return s .. string.rep(" ", width - #s)
end

local function fuzzy_score(query, text)
    if not query or #query == 0 then return 1 end
    if not text or #text == 0 then return nil end
    local q = query:lower()
    local t = text:lower()
    local plain_pos = t:find(q, 1, true)
    if plain_pos then
        return 200 - plain_pos
    end
    local qi = 1
    local qlen = #q
    local score = 0
    local consec = 0
    for ti = 1, #t do
        if t:byte(ti) == q:byte(qi) then
            qi = qi + 1
            consec = consec + 1
            score = score + 10 + consec * 5
            if qi > qlen then return score end
        else
            consec = 0
        end
    end
    return nil
end

local function shell_quote(arg)
    arg = tostring(arg or "")
    if IS_WINDOWS then
        return '"' .. arg:gsub('"', '\\"') .. '"'
    else
        return "'" .. arg:gsub("'", "'\\''") .. "'"
    end
end

--------------------------------------------------------------------------------
-- 5. Git Log & Diff Engine
--------------------------------------------------------------------------------
local Engine = {
    detail_cache = {},
}

-- Parse a tab-separated git log line:
--   <hash>\t<date>\t<author>\t<refs>\t<subject>
local function parse_git_log_line(raw)
    if not raw or #raw == 0 then return nil end
    raw = raw:gsub("\r$", "")
    local h, d, a, r, s = raw:match("^([^\t]+)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
    if not h then return nil end
    local refs = trim(r)
    refs = refs:gsub("^%(", ""):gsub("%)$", "")
    return {
        hash = trim(h),
        date = trim(d),
        author = trim(a),
        refs = refs,
        subject = trim(s),
    }
end

-- Colorize a single diff / commit detail line for terminal display
local function colorize_diff_line(line, width)
    line = (line or ""):gsub("\r$", ""):gsub("\t", "    ")
    local clipped = width and pad_right(line, width) or line

    if line:match("^commit [0-9a-fA-F]+") then
        return C.b_yellow .. C.bold .. clipped .. C.reset
    elseif line:match("^Author:") or line:match("^Date:") or line:match("^Merge:") then
        return C.cyan .. clipped .. C.reset
    elseif line:match("^diff %-%-git ") or line:match("^index ") or line:match("^new file ") or line:match("^deleted file ") then
        return C.b_yellow .. C.bold .. clipped .. C.reset
    elseif line:match("^%-%-%- ") or line:match("^%+%+%+ ") then
        return C.bold .. C.b_white .. clipped .. C.reset
    elseif line:match("^@@ .* @@") then
        local hdr, rest = clipped:match("^(@@ .- @@)(.*)$")
        if hdr then
            return C.b_cyan .. hdr .. C.reset .. C.gray .. rest .. C.reset
        end
        return C.b_cyan .. clipped .. C.reset
    elseif line:sub(1, 1) == "+" then
        return C.b_green .. clipped .. C.reset
    elseif line:sub(1, 1) == "-" then
        return C.b_red .. clipped .. C.reset
    elseif line:match("^ [^|]+|%s*%d+") then
        -- git --stat line: " path/to/file | 12 ++++----"
        local lhs, plus, minus = clipped:match("^([^|]+|%s*%d+%s*)(%+*)(%-*.*)$")
        if lhs then
            return C.white .. lhs .. C.b_green .. plus .. C.b_red .. minus .. C.reset
        end
        return C.white .. clipped .. C.reset
    elseif line:match("^ %d+ files? changed") then
        return C.b_cyan .. clipped .. C.reset
    end
    return C.white .. clipped .. C.reset
end

function Engine.fetch_commits(opts)
    opts = opts or {}
    local limit = opts.limit or 300
    local all_flag = opts.all and "--all " or ""
    local path_arg = (opts.path and #opts.path > 0) and (" -- " .. shell_quote(opts.path)) or ""

    -- Place each % placeholder without pairing on the same variable name;
    -- using %x09 separates placeholders cleanly.
    local fmt = "%h%x09%ad%x09%an%x09%d%x09%s"
    local cmd
    if IS_WINDOWS then
        cmd = string.format('git log -n %d %s--date=short --pretty="format:%s"%s 2>nul', limit, all_flag, fmt, path_arg)
    else
        cmd = string.format("git log -n %d %s--date=short --pretty='format:%s'%s 2>/dev/null", limit, all_flag, fmt, path_arg)
    end

    local commits = {}
    local p = io.popen(cmd, "r")
    if not p then return commits end
    for line in p:lines() do
        local c = parse_git_log_line(line)
        if c then
            table.insert(commits, c)
        end
    end
    p:close()
    return commits
end

-- view_mode: "full" (stat + patch), "stat" (stat only), "files" (name-status only)
function Engine.get_commit_details(hash, view_mode)
    if not hash or #hash == 0 then return {} end
    view_mode = view_mode or "full"
    local key = hash .. ":" .. view_mode
    if Engine.detail_cache[key] then
        return Engine.detail_cache[key]
    end

    local flags = "--stat --patch"
    if view_mode == "stat" then
        flags = "--stat"
    elseif view_mode == "files" then
        flags = "--name-status"
    end

    local cmd
    if IS_WINDOWS then
        cmd = string.format('git show --no-color %s %s 2>nul', flags, shell_quote(hash))
    else
        cmd = string.format("git show --no-color %s %s 2>/dev/null", flags, shell_quote(hash))
    end

    local lines = {}
    local p = io.popen(cmd, "r")
    if p then
        local count = 0
        for line in p:lines() do
            count = count + 1
            if count <= 1500 then
                table.insert(lines, (line:gsub("\r$", "")))
            else
                table.insert(lines, "... (diff truncated at 1,500 lines; press Enter to open full commit in $EDITOR)")
                break
            end
        end
        p:close()
    end

    Engine.detail_cache[key] = lines
    return lines
end

function Engine.copy_to_clipboard(text)
    if not text or #text == 0 then return false end
    if IS_WINDOWS then
        local p = io.popen("clip", "w")
        if p then
            p:write(text)
            p:close()
            return true
        end
    else
        local cmds = { "pbcopy", "xclip -selection clipboard", "xsel --clipboard --input" }
        for _, cmd in ipairs(cmds) do
            local check = os.execute("command -v " .. cmd:match("^%S+") .. " >/dev/null 2>&1")
            if check == 0 or check == true then
                local p = io.popen(cmd, "w")
                if p then
                    p:write(text)
                    p:close()
                    return true
                end
            end
        end
    end
    return false
end

function Engine.detect_editor()
    local ed = os.getenv("EDITOR") or os.getenv("VISUAL")
    if ed and #ed > 0 then return ed end
    local check_cmd = IS_WINDOWS and "where nvim >nul 2>nul" or "command -v nvim >/dev/null 2>&1"
    local ok = os.execute(check_cmd)
    if ok == 0 or ok == true then return "nvim" end
    return "vim"
end

function Engine.open_commit_in_editor(hash)
    if not hash or #hash == 0 then return end
    local editor = Engine.detect_editor()
    local tmp = os.tmpname()
    if IS_WINDOWS and not tmp:match("^[A-Za-z]:") then
        local temp_dir = os.getenv("TEMP") or "."
        tmp = temp_dir .. "\\flog_" .. hash .. ".diff"
    else
        tmp = tmp .. ".diff"
    end
    local cmd_dump = string.format("git show --stat --patch %s > %s", shell_quote(hash), shell_quote(tmp))
    os.execute(cmd_dump)
    os.execute(string.format("%s %s", editor, shell_quote(tmp)))
    os.remove(tmp)
end

--------------------------------------------------------------------------------
-- 6. Interactive Dual-Pane TUI
--------------------------------------------------------------------------------
local VIEW_MODES = { "full", "stat", "files" }
local VIEW_LABELS = { full = "Stat+Diff", stat = "Stat Only", files = "Files Only" }

local function run_tui(init_opts)
    Term.init()
    local state = {
        path = init_opts.path or "",
        limit = init_opts.limit or 300,
        all = init_opts.all or false,
        view_idx = 1,
        filter = init_opts.filter or "",
        prev_filter = "",
        mode = "normal", -- "normal" | "filter" | "help"
        cursor = 1,
        scroll = 1,
        diff_scroll = 1,
        all_commits = {},
        filtered = {},
        status_msg = "",
        pending_g = false,
    }

    local function apply_filter()
        if #state.filter == 0 then
            state.filtered = state.all_commits
        else
            local out = {}
            for _, c in ipairs(state.all_commits) do
                local hay = c.hash .. " " .. c.date .. " " .. c.author .. " " .. c.refs .. " " .. c.subject
                if fuzzy_score(state.filter, hay) then
                    table.insert(out, c)
                end
            end
            state.filtered = out
        end
        state.cursor = math.min(math.max(1, state.cursor), math.max(1, #state.filtered))
        state.diff_scroll = 1
    end

    local function reload_commits()
        Engine.detail_cache = {}
        state.all_commits = Engine.fetch_commits({
            limit = state.limit,
            all = state.all,
            path = state.path,
        })
        apply_filter()
    end

    reload_commits()

    local prev_lines = {}
    local prev_cols, prev_rows = 0, 0

    local function render()
        local cols, rows = Term.get_size()
        if cols ~= prev_cols or rows ~= prev_rows then
            prev_lines = {}
            prev_cols, prev_rows = cols, rows
            io.write("\27[2J")
        end

        local left_w = math.floor(cols * 0.46)
        if left_w < 38 then left_w = 38 end
        local right_w = cols - left_w - 3
        if right_w < 24 then right_w = 24 end
        local body_h = rows - 6
        if body_h < 4 then body_h = 4 end

        local frame_lines = {}
        local function add_line(s)
            frame_lines[#frame_lines + 1] = s .. "\27[K"
        end

        -- 1. Header Bar
        local view_mode = VIEW_MODES[state.view_idx]
        local scope_badge = state.all and (C.b_green .. "All Branches" .. C.reset .. C.bg_header) or (C.b_cyan .. "Current Branch" .. C.reset .. C.bg_header)
        local path_badge = (#state.path > 0) and (" │ Path: " .. C.b_yellow .. state.path .. C.reset .. C.bg_header) or ""
        local hdr_left = string.format(" %s%s⚡ flog%s%s │ %d/%d commits │ Scope: %s │ View: %s%s%s%s",
            C.bg_header, C.b_cyan .. C.bold, C.reset, C.bg_header,
            #state.filtered, #state.all_commits,
            scope_badge,
            C.b_magenta, VIEW_LABELS[view_mode], C.reset .. C.bg_header,
            path_badge)
        add_line(hdr_left .. string.rep(" ", math.max(0, cols - 65)) .. C.reset)

        -- 2. Filter & Controls Bar
        local flt_box
        if state.mode == "filter" then
            flt_box = string.format("%sFilter (/): %s%s█%s", C.b_yellow .. C.bold, C.b_white, state.filter, C.reset)
        else
            local flt_disp = (#state.filter > 0) and (C.b_yellow .. state.filter .. C.reset) or (C.gray .. "(press / to filter commits)" .. C.reset)
            flt_box = string.format("%sFilter (/):%s %s", C.bold, C.reset, flt_disp)
        end
        local toggles = string.format("%s[a]%sAll:%s  %s[d]%sView:%s  %s[J/K]%sScroll Diff",
            C.b_cyan, C.gray, state.all and (C.b_green .. "ON" .. C.reset) or (C.gray .. "OFF" .. C.reset),
            C.b_cyan, C.gray, C.b_magenta .. VIEW_LABELS[view_mode] .. C.reset,
            C.b_cyan, C.gray)
        add_line(string.format(" %s   │   %s", flt_box, toggles))

        -- 3. Column Headers
        local l_hdr = pad_right(" HASH     DATE        COMMIT SUBJECT", left_w)
        local cur_commit = state.filtered[state.cursor]
        local r_title = " COMMIT DETAILS & DIFF PREVIEW"
        if cur_commit then
            r_title = string.format(" COMMIT %s — %s (%s)", cur_commit.hash, cur_commit.author, cur_commit.date)
        end
        local r_hdr = pad_right(r_title, right_w)
        add_line(C.bold .. C.b_blue .. l_hdr .. C.reset .. " " .. C.gray .. "│" .. C.reset .. " " .. C.bold .. C.b_magenta .. r_hdr .. C.reset)

        -- Adjust Left Scroll Window
        if state.cursor < state.scroll then
            state.scroll = state.cursor
        elseif state.cursor >= state.scroll + body_h then
            state.scroll = state.cursor - body_h + 1
        end

        -- Prepare Right Preview Pane Lines
        local preview_lines = {}
        if state.mode == "help" then
            preview_lines = {
                C.b_cyan .. C.bold .. "Keyboard Shortcuts:" .. C.reset,
                "",
                "  " .. C.b_yellow .. "j / k / ↑ / ↓" .. C.reset .. "    Move selection cursor through commits",
                "  " .. C.b_yellow .. "g / G / Home/End" .. C.reset .. " Jump to top / bottom commit",
                "  " .. C.b_yellow .. "PgUp / PgDn" .. C.reset .. "      Page up / down commit list",
                "  " .. C.b_yellow .. "J / K or ] / [" .. C.reset .. "   Scroll right-hand diff preview down / up",
                "  " .. C.b_yellow .. "0" .. C.reset .. "                Reset diff preview scroll to top",
                "  " .. C.b_yellow .. "/ or f" .. C.reset .. "           Fuzzy-filter commits by hash/author/subject/ref",
                "  " .. C.b_yellow .. "Enter / o" .. C.reset .. "        Open selected commit diff in $EDITOR / nvim",
                "  " .. C.b_yellow .. "y" .. C.reset .. "                Copy commit hash to system clipboard",
                "  " .. C.b_yellow .. "a" .. C.reset .. "                Toggle --all branches vs current branch",
                "  " .. C.b_yellow .. "d" .. C.reset .. "                Cycle preview mode (Stat+Diff / Stat / Files)",
                "  " .. C.b_yellow .. "r / F5" .. C.reset .. "           Reload git commit history",
                "  " .. C.b_yellow .. "q / Esc" .. C.reset .. "          Quit flog",
            }
        elseif cur_commit then
            local raw_details = Engine.get_commit_details(cur_commit.hash, view_mode)
            local max_scroll = math.max(1, #raw_details - body_h + 1)
            if state.diff_scroll > max_scroll then state.diff_scroll = max_scroll end
            if state.diff_scroll < 1 then state.diff_scroll = 1 end

            for idx = state.diff_scroll, math.min(#raw_details, state.diff_scroll + body_h - 1) do
                table.insert(preview_lines, colorize_diff_line(raw_details[idx], right_w))
            end
        else
            preview_lines = {
                "",
                "  " .. C.gray .. "No commits match current filter." .. C.reset,
            }
        end

        -- 4. Body Rows
        local subj_w = math.max(12, left_w - 22)
        for row = 1, body_h do
            local idx = state.scroll + row - 1
            local c = state.filtered[idx]
            local l_str

            if c then
                local is_cur = (idx == state.cursor)
                local bg = is_cur and C.bg_select or ""
                local ptr = is_cur and (C.b_cyan .. "▸" .. C.reset .. bg) or " "

                local hash_str = pad_right(c.hash, 8)
                local date_str = pad_right(c.date, 10)
                local ref_prefix = (#c.refs > 0) and ("[" .. c.refs .. "] ") or ""
                local full_subj = pad_right(ref_prefix .. c.subject, subj_w)

                local hash_col = is_cur and (C.b_yellow .. C.bold) or C.yellow
                local date_col = C.gray
                local subj_col = is_cur and (C.b_white .. C.bold) or C.white

                l_str = string.format("%s%s%s%s%s %s%s%s %s%s%s",
                    bg, ptr,
                    hash_col, hash_str, C.reset .. bg,
                    date_col, date_str, C.reset .. bg,
                    subj_col, full_subj, C.reset)
            else
                l_str = string.rep(" ", left_w)
            end

            local r_str = preview_lines[row] or ""
            add_line(l_str .. " " .. C.gray .. "│" .. C.reset .. " " .. r_str)
        end

        -- 5. Separator & Footer
        add_line(C.gray .. string.rep("─", cols) .. C.reset)
        local footer
        if #state.status_msg > 0 then
            footer = " " .. C.b_yellow .. state.status_msg .. C.reset
        else
            footer = string.format(" %s↑/↓%s:Select  %sEnter%s:Edit Diff  %sJ/K%s:Scroll Diff  %s/%s:Filter  %sy%s:Copy Hash  %sa%s:All  %sd%s:View  %s?%s:Help  %sq%s:Quit",
                C.b_cyan, C.gray, C.b_green, C.gray, C.b_cyan, C.gray, C.b_yellow, C.gray, C.b_cyan, C.gray, C.b_cyan, C.gray, C.b_cyan, C.gray, C.b_cyan, C.gray, C.b_red, C.gray)
        end
        add_line(footer .. C.reset)

        -- Differential Output with DEC Synchronized Update
        local diff_buf = { "\27[?2026h" }
        for r = 1, #frame_lines do
            if frame_lines[r] ~= prev_lines[r] then
                diff_buf[#diff_buf + 1] = string.format("\27[%d;1H%s", r, frame_lines[r])
                prev_lines[r] = frame_lines[r]
            end
        end
        diff_buf[#diff_buf + 1] = "\27[?2026l"
        if #diff_buf > 2 then
            io.write(table.concat(diff_buf))
            io.flush()
        end
    end

    -- Event Loop
    while true do
        render()
        local key = Term.read_key()
        state.status_msg = ""

        if key == "CTRL_C" or key == "QUIT" then
            break
        end

        if state.mode == "help" then
            state.mode = "normal"
        elseif state.mode == "filter" then
            if key == "ESC" then
                state.filter = state.prev_filter
                state.mode = "normal"
                apply_filter()
            elseif key == "ENTER" then
                state.mode = "normal"
            elseif key == "BACKSPACE" then
                state.filter = state.filter:sub(1, math.max(0, #state.filter - 1))
                apply_filter()
            elseif key == "CTRL_U" then
                state.filter = ""
                apply_filter()
            elseif key == "UP" then
                state.cursor = math.max(1, state.cursor - 1)
                state.diff_scroll = 1
            elseif key == "DOWN" then
                state.cursor = math.min(math.max(1, #state.filtered), state.cursor + 1)
                state.diff_scroll = 1
            elseif #key == 1 then
                state.filter = state.filter .. key
                apply_filter()
            end
        else
            -- Normal Mode
            if key ~= "g" then state.pending_g = false end

            if key == "q" or key == "ESC" then
                break
            elseif key == "j" or key == "DOWN" then
                state.cursor = math.min(math.max(1, #state.filtered), state.cursor + 1)
                state.diff_scroll = 1
            elseif key == "k" or key == "UP" then
                state.cursor = math.max(1, state.cursor - 1)
                state.diff_scroll = 1
            elseif key == "PGDN" then
                local _, rows = Term.get_size()
                state.cursor = math.min(math.max(1, #state.filtered), state.cursor + math.max(1, rows - 8))
                state.diff_scroll = 1
            elseif key == "PGUP" then
                local _, rows = Term.get_size()
                state.cursor = math.max(1, state.cursor - math.max(1, rows - 8))
                state.diff_scroll = 1
            elseif key == "J" or key == "]" then
                state.diff_scroll = state.diff_scroll + 5
            elseif key == "K" or key == "[" then
                state.diff_scroll = math.max(1, state.diff_scroll - 5)
            elseif key == "0" then
                state.diff_scroll = 1
            elseif key == "HOME" then
                state.cursor = 1
                state.diff_scroll = 1
            elseif key == "END" or key == "G" then
                state.cursor = math.max(1, #state.filtered)
                state.diff_scroll = 1
            elseif key == "g" then
                if state.pending_g then
                    state.cursor = 1
                    state.diff_scroll = 1
                    state.pending_g = false
                else
                    state.pending_g = true
                end
            elseif key == "/" or key == "f" then
                state.prev_filter = state.filter
                state.mode = "filter"
            elseif key == "a" then
                state.all = not state.all
                reload_commits()
                state.status_msg = "Scope: " .. (state.all and "All Branches (--all)" or "Current Branch")
            elseif key == "d" then
                state.view_idx = (state.view_idx % #VIEW_MODES) + 1
                state.diff_scroll = 1
                state.status_msg = "Diff view: " .. VIEW_LABELS[VIEW_MODES[state.view_idx]]
            elseif key == "r" or key == "F5" then
                reload_commits()
                state.status_msg = "Reloaded git commit history."
            elseif key == "y" then
                local cur = state.filtered[state.cursor]
                if cur then
                    if Engine.copy_to_clipboard(cur.hash) then
                        state.status_msg = "Copied commit hash to clipboard: " .. cur.hash
                    else
                        state.status_msg = "Commit hash: " .. cur.hash
                    end
                end
            elseif key == "?" then
                state.mode = "help"
            elseif key == "ENTER" or key == "o" then
                local cur = state.filtered[state.cursor]
                if cur then
                    Term.shutdown()
                    Engine.open_commit_in_editor(cur.hash)
                    Term.init()
                    prev_lines = {}
                end
            end
        end
    end

    Term.shutdown()
end

--------------------------------------------------------------------------------
-- 7. CLI Non-Interactive Modes & Self-Tests
--------------------------------------------------------------------------------
local function cmd_list(opts)
    local commits = Engine.fetch_commits(opts)
    for _, c in ipairs(commits) do
        local ref_str = (#c.refs > 0) and (C.b_cyan .. " (" .. c.refs .. ")" .. C.reset) or ""
        print(string.format("%s%-8s%s %s%-10s%s %s%-16s%s%s %s",
            C.b_yellow, c.hash, C.reset,
            C.gray, c.date, C.reset,
            C.green, pad_right(c.author, 16), C.reset,
            ref_str,
            c.subject))
    end
end

local function cmd_show(hash, view_mode)
    if not hash or #hash == 0 then
        io.stderr:write("Usage: flog --show <COMMIT_HASH>\n")
        os.exit(1)
    end
    local lines = Engine.get_commit_details(hash, view_mode or "full")
    if #lines == 0 then
        io.stderr:write(string.format("[ERROR] Commit not found: %s\n", hash))
        os.exit(1)
    end
    for _, l in ipairs(lines) do
        print(colorize_diff_line(l))
    end
end

local function run_tests()
    local passed, failed = 0, 0
    local function assert_eq(name, actual, expected)
        if actual == expected then
            passed = passed + 1
            print(string.format("  [PASS] %s", name))
        else
            failed = failed + 1
            print(string.format("  [FAIL] %s: expected '%s', got '%s'", name, tostring(expected), tostring(actual)))
        end
    end

    print("Running flog.lua automated self-tests...")

    local sample = "e2233de\t2026-10-17\tZhi Liu\t (HEAD -> master, origin/master)\tAdd frg interactive TUI"
    local parsed = parse_git_log_line(sample)
    assert_eq("parse_git_log_line hash", parsed and parsed.hash, "e2233de")
    assert_eq("parse_git_log_line date", parsed and parsed.date, "2026-10-17")
    assert_eq("parse_git_log_line author", parsed and parsed.author, "Zhi Liu")
    assert_eq("parse_git_log_line refs", parsed and parsed.refs, "HEAD -> master, origin/master")
    assert_eq("parse_git_log_line subject", parsed and parsed.subject, "Add frg interactive TUI")

    local add_colored = colorize_diff_line("+local x = 42", 40)
    assert_eq("colorize_diff_line highlights additions", add_colored:find("\27%[92m") ~= nil, true)

    local del_colored = colorize_diff_line("-local x = 41", 40)
    assert_eq("colorize_diff_line highlights deletions", del_colored:find("\27%[91m") ~= nil, true)

    local commits = Engine.fetch_commits({ limit = 5 })
    assert_eq("Engine.fetch_commits returns commits from current repo", #commits >= 1, true)
    if #commits >= 1 then
        local details = Engine.get_commit_details(commits[1].hash, "stat")
        assert_eq("Engine.get_commit_details fetches commit summary", #details >= 3, true)
    end

    print(string.format("\nSelf-test summary: %d passed, %d failed.", passed, failed))
    if failed > 0 then os.exit(1) end
end

local function show_help()
    print([[
Usage: flog [OPTIONS] [PATH]

High-Performance Interactive Git Commit & Diff Browser TUI (LuaJIT + FFI).

Options:
  -a, --all            Show commits across all branches and tags
  -n, --limit <N>      Maximum number of commits to load (default: 300)
  -l, --list           Print formatted commit history and exit
  --show <HASH>        Print colorized commit summary and diff for <HASH>
  --test               Run automated self-test suite
  -h, --help           Show this help message

TUI Keybindings:
  j / k / Up / Down    Move selection cursor through commits
  J / K or ] / [       Scroll right-hand diff preview pane down / up
  0                    Reset diff preview scroll to top
  / or f               Fuzzy-filter commits by hash, author, ref, or message
  Enter / o            Open selected commit diff in $EDITOR / nvim
  y                    Copy selected commit hash to system clipboard
  a                    Toggle All Branches (--all) vs Current Branch
  d                    Cycle preview view (Stat+Diff -> Stat Only -> Files Only)
  r / F5               Reload git commit history
  ?                    Show keyboard shortcuts help
  q / Esc              Quit]])
end

--------------------------------------------------------------------------------
-- 8. Entrypoint
--------------------------------------------------------------------------------
local args = { ... }
local mode = "tui"
local opts = { limit = 300, all = false, path = "", filter = "" }
local show_hash = nil

local i = 1
while i <= #args do
    local a = args[i]
    if a == "-h" or a == "--help" then
        show_help()
        os.exit(0)
    elseif a == "--test" then
        run_tests()
        os.exit(0)
    elseif a == "-l" or a == "--list" then
        mode = "list"
    elseif a == "-a" or a == "--all" then
        opts.all = true
    elseif a == "-n" or a == "--limit" then
        i = i + 1
        opts.limit = tonumber(args[i]) or 300
    elseif a == "--show" then
        mode = "show"
        i = i + 1
        show_hash = args[i]
    else
        opts.path = a
    end
    i = i + 1
end

if mode == "list" then
    cmd_list(opts)
elseif mode == "show" then
    cmd_show(show_hash)
else
    run_tui(opts)
end
