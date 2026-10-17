#!/usr/bin/env luajit
--[[
  frg.lua - High-Performance Interactive Ripgrep Search & Code Jump TUI
  Powered by LuaJIT & FFI. Single-file, zero external Lua dependencies.
  Runs natively on Windows and Linux/POSIX with flicker-free differential rendering.

  Features:
    - Live Ripgrep Search (/): Type or edit search patterns interactively inside the TUI.
    - Instant In-Memory Code Preview: Right pane renders surrounding source lines with line numbers
      and match highlighting directly from memory (< 0.1ms per cursor move, zero subprocess overhead).
    - Flicker-Free Rendering: Uses differential row updates (\27[<r>;1H) + DEC Synchronized Output.
    - Windows Drive-Letter Safe Parser: Accurately parses both 'C:\path\file:line:col:text' and
      POSIX 'path/file:line:col:text' vimgrep output.
    - Interactive Search Toggles:
      * [i] Case Mode: Smart -> Ignore (-i) -> Sensitive (-s)
      * [F] Fixed Strings (-F literal vs Regex)
      * [w] Whole Word (-w)
      * [H] Hidden Files (--hidden)
    - Multi-Select & Editor Jump:
      * [Enter] Open highlighted match in $EDITOR / nvim / vim at exact +line
      * [Space / Tab] Multi-select matches to open multiple files in tabs (-p)

  Usage:
    luajit bin/frg.lua [OPTIONS] [PATTERN] [PATH]
    frg [OPTIONS] [PATTERN] [PATH]

  Options:
    -i, --ignore-case    Start with case-insensitive search
    -s, --case-sensitive Start with case-sensitive search
    -F, --fixed-strings  Treat pattern as literal string instead of regex
    -w, --word-regexp    Only match whole words
    -H, --hidden         Search hidden files and directories
    -l, --list           Print matches to stdout and exit (non-interactive)
    --preview <F:LINE>   Print ANSI source context around <FILE>:<LINE> and exit
    --test               Run built-in automated self-test suite and exit
    -h, --help           Show this help message
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
        HANDLE CreateFileA(const char* lpFileName, DWORD dwDesiredAccess, DWORD dwShareMode,
                           void* lpSecurityAttributes, DWORD dwCreationDisposition,
                           DWORD dwFlagsAndAttributes, void* hTemplateFile);
        BOOL CloseHandle(HANDLE hObject);
        void Sleep(DWORD dwMilliseconds);
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
        int ioctl(int fd, unsigned long request, ...);
        int read(int fd, void *buf, size_t count);
        int usleep(unsigned int usec);
    ]]
end

--------------------------------------------------------------------------------
-- Styling & Box Drawing
--------------------------------------------------------------------------------
local C = {
    reset       = "\27[0m",
    bold        = "\27[1m",
    dim         = "\27[2m",

    red         = "\27[31m",
    green       = "\27[32m",
    yellow      = "\27[33m",
    blue        = "\27[34m",
    magenta     = "\27[35m",
    cyan        = "\27[36m",
    white       = "\27[37m",
    gray        = "\27[90m",

    b_red       = "\27[1;91m",
    b_green     = "\27[1;92m",
    b_yellow    = "\27[1;93m",
    b_blue      = "\27[1;94m",
    b_magenta   = "\27[1;95m",
    b_cyan      = "\27[1;96m",
    b_white     = "\27[1;97m",

    bg_darkblue = "\27[48;5;24m",
    bg_sel      = "\27[48;5;238m",
    bg_match    = "\27[48;5;58m",
}

local BOX = {
    tl = "┌", tr = "┐", bl = "└", br = "┘",
    h = "─", v = "│", vl = "├", vr = "┤",
    tt = "┬", tb = "┴", x = "┼"
}

--------------------------------------------------------------------------------
-- String & Width Helpers
--------------------------------------------------------------------------------
local function utf8_col_width(s)
    if not s then return 0 end
    local clean = s:gsub("\27%[[%?%d;]*[a-zA-Z]", "")
    local width = 0
    local i = 1
    local len = #clean
    while i <= len do
        local b = clean:byte(i)
        if b < 128 then
            width = width + 1; i = i + 1
        elseif b >= 192 and b < 224 then
            width = width + 1; i = i + 2
        elseif b >= 224 and b < 240 then
            width = width + 1; i = i + 3
        elseif b >= 240 then
            width = width + 2; i = i + 4
        else
            width = width + 1; i = i + 1
        end
    end
    return width
end

local function pad_string(s, target_width)
    s = s or ""
    local cur_w = utf8_col_width(s)
    if cur_w < target_width then
        return s .. string.rep(" ", target_width - cur_w)
    end
    return s
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
        if b >= 192 and b < 224 then step = 2
        elseif b >= 224 and b < 240 then step = 3
        elseif b >= 240 then step = 4 end
        res = res .. clean:sub(i, i + step - 1)
        w = w + 1
        i = i + step
    end
    return res .. "…"
end

local function fuzzy_score(pattern, str)
    if not pattern or #pattern == 0 then return 1 end
    if not str or #str == 0 then return nil end
    pattern = pattern:lower()
    str = str:lower()
    local sub_start = str:find(pattern, 1, true)
    if sub_start then return 100 - sub_start end
    local p_idx = 1
    local p_len = #pattern
    local s_len = #str
    local score = 0
    local last_match = -1
    for s_idx = 1, s_len do
        if p_idx <= p_len and str:byte(s_idx) == pattern:byte(p_idx) then
            score = score + ((last_match == s_idx - 1) and 10 or 2)
            last_match = s_idx
            p_idx = p_idx + 1
        end
    end
    if p_idx > p_len then return score else return nil end
end

--------------------------------------------------------------------------------
-- Vimgrep Output Parser (Windows C:\... & POSIX Safe)
--------------------------------------------------------------------------------
local function parse_vimgrep_line(line)
    if not line or #line == 0 then return nil end
    line = line:gsub("\r$", "")

    -- Handle Windows drive letter prefix (e.g. C:\path\file.lua:12:5:text)
    local prefix = ""
    local rest = line
    local drive = line:match("^([A-Za-z]:[\\/])")
    if drive then
        prefix = line:sub(1, 2)
        rest = line:sub(3)
    end

    local fpath, lnum, col, text = rest:match("^([^:]+):(%d+):(%d+):(.*)$")
    if fpath and lnum then
        return {
            file = prefix .. fpath,
            line = tonumber(lnum) or 1,
            col  = tonumber(col) or 1,
            text = (text or ""):gsub("^%s+", ""):gsub("\t", "  "),
        }
    end

    -- Fallback for file:line:text (without column)
    fpath, lnum, text = rest:match("^([^:]+):(%d+):(.*)$")
    if fpath and lnum then
        return {
            file = prefix .. fpath,
            line = tonumber(lnum) or 1,
            col  = 1,
            text = (text or ""):gsub("^%s+", ""):gsub("\t", "  "),
        }
    end

    return nil
end

--------------------------------------------------------------------------------
-- Terminal Raw Mode Controller
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
                ffi.C.SetConsoleMode(Term.hOut, bit.bor(mode[0], 0x0004))
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
                local raw_mode = bit.band(mode[0], bit.bnot(bit.bor(0x0002, 0x0004)))
                ffi.C.SetConsoleMode(Term.hIn, raw_mode)
            end
        end
    elseif IS_POSIX then
        Term.orig_termios = ffi.new("struct termios")
        if ffi.C.tcgetattr(0, Term.orig_termios) == 0 then
            local raw = ffi.new("struct termios")
            ffi.copy(raw, Term.orig_termios, ffi.sizeof("struct termios"))
            raw.c_lflag = bit.band(raw.c_lflag, bit.bnot(bit.bor(0x0002, 0x0008, 0x0001)))
            raw.c_cc[5] = 0
            raw.c_cc[6] = 0
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
    elseif IS_POSIX then
        if Term.orig_termios then
            ffi.C.tcsetattr(0, 0, Term.orig_termios)
        end
    end
    Term.is_raw = false
end

function Term.get_size()
    local cols, rows = 100, 28
    if IS_WINDOWS then
        local csbi = ffi.new("CONSOLE_SCREEN_BUFFER_INFO")
        if Term.hOut ~= nil and Term.hOut ~= ffi.cast("HANDLE", -1)
            and ffi.C.GetConsoleScreenBufferInfo(Term.hOut, csbi) ~= 0 then
            cols = csbi.srWindow.Right - csbi.srWindow.Left + 1
            rows = csbi.srWindow.Bottom - csbi.srWindow.Top + 1
        else
            local hCon = ffi.C.CreateFileA("CONOUT$", 0xC0000000, 3, nil, 3, 0, nil)
            if hCon ~= nil and hCon ~= ffi.cast("HANDLE", -1) then
                if ffi.C.GetConsoleScreenBufferInfo(hCon, csbi) ~= 0 then
                    cols = csbi.srWindow.Right - csbi.srWindow.Left + 1
                    rows = csbi.srWindow.Bottom - csbi.srWindow.Top + 1
                end
                ffi.C.CloseHandle(hCon)
            end
        end
    elseif IS_POSIX then
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
    if cols < 72 then cols = 72 end
    if rows < 16 then rows = 16 end
    return cols, rows
end

function Term.sleep_ms(ms)
    if IS_WINDOWS then
        ffi.C.Sleep(ms)
    elseif IS_POSIX then
        ffi.C.usleep(ms * 1000)
    end
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
        elseif ch == 14 then return "ctrl_n"
        elseif ch == 16 then return "ctrl_p"
        else
            return string.char(ch)
        end
    elseif IS_POSIX then
        local buf = ffi.new("char[8]")
        local n = ffi.C.read(0, buf, 8)
        if n <= 0 then return nil end
        local ch = buf[0]
        if ch == 27 then
            if n == 1 then return "esc" end
            if buf[1] == 91 then
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
        elseif ch == 14 then return "ctrl_n"
        elseif ch == 16 then return "ctrl_p"
        else
            return string.char(ch)
        end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Ripgrep Execution & File Context Cache
--------------------------------------------------------------------------------
local Engine = {
    file_cache = {},
}

local function shell_quote(s)
    if IS_WINDOWS then
        return '"' .. tostring(s):gsub('"', '\\"') .. '"'
    else
        return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
    end
end

function Engine.run_rg(pattern, search_path, opts)
    if not pattern or #pattern == 0 then
        return {}
    end
    opts = opts or {}
    local flags = { "--vimgrep", "--color=never", "--max-columns=300", "--max-count=200" }
    if opts.case_mode == "ignore" then
        table.insert(flags, "-i")
    elseif opts.case_mode == "sensitive" then
        table.insert(flags, "-s")
    else
        table.insert(flags, "-S") -- smart-case
    end
    if opts.fixed then table.insert(flags, "-F") end
    if opts.word then table.insert(flags, "-w") end
    if opts.hidden then
        table.insert(flags, "--hidden")
        table.insert(flags, "--glob=!.git")
    end

    local target = (search_path and #search_path > 0) and (" " .. shell_quote(search_path)) or ""
    local err_redir = IS_WINDOWS and " 2>nul" or " 2>/dev/null"
    local cmd = "rg " .. table.concat(flags, " ") .. " -- " .. shell_quote(pattern) .. target .. err_redir

    local results = {}
    local p = io.popen(cmd, "r")
    if not p then return results end
    for line in p:lines() do
        local parsed = parse_vimgrep_line(line)
        if parsed then
            table.insert(results, parsed)
            if #results >= 1000 then break end
        end
    end
    p:close()
    return results
end

function Engine.get_file_lines(filepath)
    if Engine.file_cache[filepath] then
        return Engine.file_cache[filepath]
    end
    local f = io.open(filepath, "r")
    if not f then return nil end
    local lines = {}
    for l in f:lines() do
        lines[#lines + 1] = l:gsub("\r$", ""):gsub("\t", "    ")
        if #lines >= 20000 then break end
    end
    f:close()
    Engine.file_cache[filepath] = lines
    return lines
end

function Engine.detect_editor()
    local ed = os.getenv("EDITOR") or os.getenv("VISUAL")
    if ed and #ed > 0 then return ed end
    local check_cmd = IS_WINDOWS and "where nvim >nul 2>nul" or "command -v nvim >/dev/null 2>&1"
    local ok = os.execute(check_cmd)
    if ok == 0 or ok == true then return "nvim" end
    return "vim"
end

function Engine.open_in_editor(matches)
    if not matches or #matches == 0 then return end
    local editor = Engine.detect_editor()
    if #matches == 1 then
        local m = matches[1]
        local cmd = string.format('%s +%d %s', editor, m.line, shell_quote(m.file))
        os.execute(cmd)
    else
        local seen = {}
        local files = {}
        for _, m in ipairs(matches) do
            if not seen[m.file] then
                seen[m.file] = true
                table.insert(files, shell_quote(m.file))
            end
        end
        local cmd = string.format('%s -p %s', editor, table.concat(files, " "))
        os.execute(cmd)
    end
end

--------------------------------------------------------------------------------
-- Interactive Dual-Pane TUI
--------------------------------------------------------------------------------
local CASE_MODES = { "smart", "ignore", "sensitive" }

local function run_tui(initial_pattern, search_path, init_opts)
    Term.init()
    local state = {
        pattern = initial_pattern or "",
        prev_pattern = initial_pattern or "",
        filter = "",
        prev_filter = "",
        search_path = search_path or "",
        case_idx = (init_opts.case_mode == "ignore" and 2) or (init_opts.case_mode == "sensitive" and 3) or 1,
        fixed = init_opts.fixed or false,
        word = init_opts.word or false,
        hidden = init_opts.hidden or false,
        mode = (#(initial_pattern or "") == 0) and "pattern" or "normal", -- "normal" | "pattern" | "filter" | "help"
        cursor = 1,
        scroll = 1,
        all_matches = {},
        filtered = {},
        selected = {}, -- map of match table -> true
        status_msg = "",
         pending_g = false,
    }

    local function current_opts()
        return {
            case_mode = CASE_MODES[state.case_idx],
            fixed = state.fixed,
            word = state.word,
            hidden = state.hidden,
        }
    end

    local function apply_filter()
        if #state.filter == 0 then
            state.filtered = state.all_matches
        else
            local out = {}
            for _, m in ipairs(state.all_matches) do
                local hay = m.file .. ":" .. m.line .. " " .. m.text
                if fuzzy_score(state.filter, hay) then
                    table.insert(out, m)
                end
            end
            state.filtered = out
        end
        state.cursor = math.min(math.max(1, state.cursor), math.max(1, #state.filtered))
    end

    local function execute_search()
        if #state.pattern > 0 then
            state.all_matches = Engine.run_rg(state.pattern, state.search_path, current_opts())
        else
            state.all_matches = {}
        end
        state.selected = {}
        state.cursor = 1
        state.scroll = 1
        apply_filter()
    end

    if #state.pattern > 0 then
        execute_search()
    end

    local prev_lines = {}
    local prev_cols, prev_rows = 0, 0

    local function render()
        local cols, rows = Term.get_size()
        if cols ~= prev_cols or rows ~= prev_rows then
            prev_lines = {}
            prev_cols, prev_rows = cols, rows
            io.write("\27[2J")
        end

        local left_w = math.floor(cols * 0.48)
        if left_w < 38 then left_w = 38 end
        local right_w = cols - left_w - 3
        if right_w < 24 then right_w = 24 end
        local body_h = rows - 6
        if body_h < 6 then body_h = 6 end

        if state.cursor < state.scroll then
            state.scroll = state.cursor
        elseif state.cursor >= state.scroll + body_h - 1 then
            state.scroll = state.cursor - body_h + 2
        end
        if state.scroll < 1 then state.scroll = 1 end

        local frame_lines = {}

        -- 1. Top Header Bar with Toggle Badges (3 rows)
        local case_lbl = CASE_MODES[state.case_idx]:upper()
        local b_case = C.bg_darkblue .. C.b_white .. " [i]Case:" .. case_lbl .. " " .. C.reset
        local b_fix  = state.fixed  and (C.bg_darkblue .. C.b_yellow .. " [F]Literal:ON " .. C.reset) or (C.gray .. " [F]Regex " .. C.reset)
        local b_word = state.word   and (C.bg_darkblue .. C.b_yellow .. " [w]Word:ON " .. C.reset)    or (C.gray .. " [w]Word:OFF " .. C.reset)
        local b_hid  = state.hidden and (C.bg_darkblue .. C.b_yellow .. " [H]Hidden:ON " .. C.reset)  or (C.gray .. " [H]Hidden:OFF " .. C.reset)

        local pat_disp = (state.mode == "pattern")
            and (C.b_yellow .. "Rg (/): " .. C.b_white .. state.pattern .. "█" .. C.reset)
            or  (C.cyan .. "Rg (/): " .. C.b_white .. (#state.pattern > 0 and state.pattern or C.gray .. "(press / to search)") .. C.reset)
        if #state.filter > 0 or state.mode == "filter" then
            local flt = (state.mode == "filter") and (state.filter .. "█") or state.filter
            pat_disp = pat_disp .. "  " .. C.magenta .. "Filter (f): " .. C.b_white .. flt .. C.reset
        end

        local hdr = string.format("%s frg %s %s  %s %s %s %s  %s[%d matches]%s",
            C.b_cyan, C.reset, pat_disp, b_case, b_fix, b_word, b_hid,
            C.b_green, #state.filtered, C.reset)

        table.insert(frame_lines, BOX.tl .. string.rep(BOX.h, cols - 2) .. BOX.tr)
        table.insert(frame_lines, BOX.v .. pad_string(truncate_string(hdr, cols - 2), cols - 2) .. BOX.v)
        table.insert(frame_lines, BOX.vl .. string.rep(BOX.h, left_w) .. BOX.tt .. string.rep(BOX.h, right_w) .. BOX.vr)

        -- 2. Right Pane: Source Context Preview
        local r_lines = {}
        local sel = state.filtered[state.cursor]
        if state.mode == "help" then
            table.insert(r_lines, C.b_yellow .. " Keyboard Shortcuts (press any key to close)" .. C.reset)
            table.insert(r_lines, C.gray .. " " .. string.rep(BOX.h, math.max(10, right_w - 2)) .. C.reset)
            table.insert(r_lines, " " .. C.b_cyan .. "/                 " .. C.reset .. "Edit Ripgrep search pattern")
            table.insert(r_lines, " " .. C.b_cyan .. "f                 " .. C.reset .. "Fuzzy filter within current matches")
            table.insert(r_lines, " " .. C.b_cyan .. "j / k / Up / Down " .. C.reset .. "Navigate match list")
            table.insert(r_lines, " " .. C.b_cyan .. "gg / G / Home/End " .. C.reset .. "Jump to first / last match")
            table.insert(r_lines, " " .. C.b_cyan .. "Enter             " .. C.reset .. "Open match(es) in $EDITOR / nvim")
            table.insert(r_lines, " " .. C.b_cyan .. "Space / Tab       " .. C.reset .. "Toggle multi-select on match")
            table.insert(r_lines, " " .. C.b_cyan .. "i                 " .. C.reset .. "Cycle Case (Smart/Ignore/Sensitive)")
            table.insert(r_lines, " " .. C.b_cyan .. "F                 " .. C.reset .. "Toggle Fixed-Strings (-F literal)")
            table.insert(r_lines, " " .. C.b_cyan .. "w                 " .. C.reset .. "Toggle Whole-Word (-w)")
            table.insert(r_lines, " " .. C.b_cyan .. "H                 " .. C.reset .. "Toggle Hidden files (--hidden)")
            table.insert(r_lines, " " .. C.b_cyan .. "q / Esc           " .. C.reset .. "Quit frg")
        elseif sel then
            table.insert(r_lines, string.format(" %s%s%s:%s%d:%d%s",
                C.b_cyan, truncate_string(sel.file, math.max(10, right_w - 14)), C.reset,
                C.b_yellow, sel.line, sel.col, C.reset))
            table.insert(r_lines, C.gray .. " " .. string.rep(BOX.h, math.max(10, right_w - 2)) .. C.reset)

            local flines = Engine.get_file_lines(sel.file)
            if flines and #flines > 0 then
                local ctx_rows = body_h - 2
                local half = math.floor(ctx_rows / 2)
                local start_l = math.max(1, sel.line - half)
                local end_l = math.min(#flines, start_l + ctx_rows - 1)
                local code_w = math.max(8, right_w - 9)

                for lno = start_l, end_l do
                    local code = truncate_string(flines[lno] or "", code_w)
                    if lno == sel.line then
                        local row_s = string.format("▸%5d │ %s", lno, code)
                        table.insert(r_lines, C.bg_sel .. C.b_yellow .. pad_string(row_s, right_w) .. C.reset)
                    else
                        local row_s = string.format(" %5s │ %s", tostring(lno), code)
                        table.insert(r_lines, C.gray .. string.format(" %5d │ ", lno) .. C.white .. code .. C.reset)
                    end
                end
            else
                table.insert(r_lines, C.gray .. " (Unable to preview file contents)" .. C.reset)
            end
        else
            if #state.pattern == 0 then
                table.insert(r_lines, C.gray .. " Type a search pattern and press Enter." .. C.reset)
            else
                table.insert(r_lines, C.gray .. " No matches found." .. C.reset)
            end
        end

        -- 3. Render Dual-Pane Body
        local col_hdr = string.format(" %-24s  %s", "FILE:LINE", "MATCH")
        col_hdr = truncate_string(col_hdr, left_w)

        for row = 1, body_h do
            local l_cell = ""
            if row == 1 then
                l_cell = C.b_white .. pad_string(col_hdr, left_w) .. C.reset
            else
                local idx = state.scroll + row - 2
                local item = state.filtered[idx]
                if item then
                    local is_sel = (idx == state.cursor)
                    local is_marked = state.selected[item]
                    local prefix = is_sel and (is_marked and "★" or "▸") or (is_marked and "*" or " ")
                    local loc = string.format("%s:%d", item.file, item.line)
                    local loc_short = truncate_string(loc, 24)
                    local txt_w = math.max(6, left_w - 28)
                    local txt_short = truncate_string(item.text, txt_w)
                    local raw_line = string.format("%s%-24s  %s", prefix, loc_short, txt_short)
                    raw_line = pad_string(truncate_string(raw_line, left_w), left_w)

                    if is_sel then
                        l_cell = C.bg_sel .. C.b_yellow .. raw_line .. C.reset
                    elseif is_marked then
                        l_cell = C.b_green .. raw_line .. C.reset
                    else
                        l_cell = C.cyan .. string.format("%s%-24s  ", prefix, loc_short)
                            .. C.white .. pad_string(txt_short, left_w - 27) .. C.reset
                    end
                else
                    l_cell = string.rep(" ", left_w)
                end
            end

            local r_raw = r_lines[row] or ""
            if utf8_col_width(r_raw) > right_w then
                r_raw = truncate_string(r_raw, right_w)
            end
            local r_cell = pad_string(r_raw, right_w)
            table.insert(frame_lines, BOX.v .. l_cell .. BOX.v .. r_cell .. BOX.v)
        end

        -- 4. Footer Bar (3 rows)
        table.insert(frame_lines, BOX.vl .. string.rep(BOX.h, left_w) .. BOX.tb .. string.rep(BOX.h, right_w) .. BOX.vr)
        local footer
        if state.mode == "pattern" then
            footer = C.b_yellow .. " Search Pattern (/): " .. C.b_white .. state.pattern .. "█"
                .. C.gray .. "   [Enter] Run Search  [Esc] Cancel" .. C.reset
        elseif state.mode == "filter" then
            footer = C.b_magenta .. " Filter Matches (f): " .. C.b_white .. state.filter .. "█"
                .. C.gray .. "   [Enter] Lock Filter  [Esc] Cancel" .. C.reset
        else
            footer = C.gray ..
                " [Enter] Open Editor  [/] Pattern  [f] Filter  [Space/Tab] Multi-Select  [i] Case  [F] Literal  [w] Word  [H] Hidden  [?] Help  [q] Quit"
                .. C.reset
        end
        table.insert(frame_lines, BOX.v .. pad_string(truncate_string(footer, cols - 2), cols - 2) .. BOX.v)
        table.insert(frame_lines, BOX.bl .. string.rep(BOX.h, cols - 2) .. BOX.br)

        local out = { "\27[?2026h" }
        for r = 1, #frame_lines do
            if frame_lines[r] ~= prev_lines[r] then
                table.insert(out, string.format("\27[%d;1H%s", r, frame_lines[r]))
                prev_lines[r] = frame_lines[r]
            end
        end
        if #out > 1 then
            table.insert(out, "\27[?2026l")
            io.write(table.concat(out))
            io.flush()
        end
    end

    local to_open = nil

    Term.enable_raw()
    local ok, err = pcall(function()
        render()
        while true do
            local key = Term.read_key()
            if not key then
                Term.sleep_ms(16)
            else
                if state.mode == "help" then
                    state.mode = "normal"
                    render()
                elseif state.mode == "pattern" then
                    if key == "enter" then
                        state.mode = "normal"
                        execute_search()
                    elseif key == "esc" or key == "ctrl_c" then
                        state.pattern = state.prev_pattern
                        state.mode = "normal"
                    elseif key == "backspace" then
                        if #state.pattern > 0 then
                            state.pattern = state.pattern:sub(1, -2)
                        end
                    elseif key == "down" or key == "ctrl_n" then
                        state.cursor = math.min(math.max(1, #state.filtered), state.cursor + 1)
                    elseif key == "up" or key == "ctrl_p" then
                        state.cursor = math.max(1, state.cursor - 1)
                    elseif #key == 1 and key:byte(1) >= 32 and key:byte(1) <= 126 then
                        state.pattern = state.pattern .. key
                    end
                    render()
                elseif state.mode == "filter" then
                    if key == "enter" then
                        state.mode = "normal"
                    elseif key == "esc" or key == "ctrl_c" then
                        state.filter = state.prev_filter
                        state.mode = "normal"
                        apply_filter()
                    elseif key == "backspace" then
                        if #state.filter > 0 then
                            state.filter = state.filter:sub(1, -2)
                            apply_filter()
                        end
                    elseif key == "down" or key == "ctrl_n" then
                        state.cursor = math.min(math.max(1, #state.filtered), state.cursor + 1)
                    elseif key == "up" or key == "ctrl_p" then
                        state.cursor = math.max(1, state.cursor - 1)
                    elseif #key == 1 and key:byte(1) >= 32 and key:byte(1) <= 126 then
                        state.filter = state.filter .. key
                        apply_filter()
                    end
                    render()
                else
                    -- Normal mode
                    if key == "q" or key == "ctrl_c" then
                        break
                    elseif key == "esc" then
                        if #state.filter > 0 then
                            state.filter = ""
                            apply_filter()
                            render()
                        else
                            break
                        end
                    elseif key == "j" or key == "down" then
                        state.pending_g = false
                        state.cursor = math.min(math.max(1, #state.filtered), state.cursor + 1)
                        render()
                    elseif key == "k" or key == "up" then
                        state.pending_g = false
                        state.cursor = math.max(1, state.cursor - 1)
                        render()
                    elseif key == "g" then
                        if state.pending_g then
                            state.cursor = 1
                            state.pending_g = false
                            render()
                        else
                            state.pending_g = true
                        end
                    elseif key == "G" or key == "end" then
                        state.pending_g = false
                        state.cursor = math.max(1, #state.filtered)
                        render()
                    elseif key == "home" then
                        state.pending_g = false
                        state.cursor = 1
                        render()
                    elseif key == "ctrl_d" or key == "pagedown" then
                        state.pending_g = false
                        state.cursor = math.min(math.max(1, #state.filtered), state.cursor + 10)
                        render()
                    elseif key == "ctrl_u" or key == "pageup" then
                        state.pending_g = false
                        state.cursor = math.max(1, state.cursor - 10)
                        render()
                    elseif key == "/" then
                        state.pending_g = false
                        state.prev_pattern = state.pattern
                        state.mode = "pattern"
                        render()
                    elseif key == "f" then
                        state.pending_g = false
                        state.prev_filter = state.filter
                        state.mode = "filter"
                        render()
                    elseif key == "i" then
                        state.pending_g = false
                        state.case_idx = (state.case_idx % #CASE_MODES) + 1
                        execute_search()
                        render()
                    elseif key == "F" then
                        state.pending_g = false
                        state.fixed = not state.fixed
                        execute_search()
                        render()
                    elseif key == "w" then
                        state.pending_g = false
                        state.word = not state.word
                        execute_search()
                        render()
                    elseif key == "H" then
                        state.pending_g = false
                        state.hidden = not state.hidden
                        execute_search()
                        render()
                    elseif key == "space" or key == "tab" then
                        state.pending_g = false
                        local sel = state.filtered[state.cursor]
                        if sel then
                            if state.selected[sel] then
                                state.selected[sel] = nil
                            else
                                state.selected[sel] = true
                            end
                            state.cursor = math.min(math.max(1, #state.filtered), state.cursor + 1)
                            render()
                        end
                    elseif key == "?" then
                        state.pending_g = false
                        state.mode = "help"
                        render()
                    elseif key == "enter" then
                        local picked = {}
                        for _, m in ipairs(state.filtered) do
                            if state.selected[m] then
                                table.insert(picked, m)
                            end
                        end
                        if #picked == 0 and state.filtered[state.cursor] then
                            table.insert(picked, state.filtered[state.cursor])
                        end
                        if #picked > 0 then
                            to_open = picked
                            break
                        end
                    end
                end
            end
        end
    end)
    Term.restore()
    if not ok then
        io.stderr:write("[frg error] " .. tostring(err) .. "\n")
        os.exit(1)
    end
    if to_open then
        Engine.open_in_editor(to_open)
    end
end

--------------------------------------------------------------------------------
-- CLI Modes & Self-Tests
--------------------------------------------------------------------------------
local function cmd_list(pattern, search_path, opts)
    local results = Engine.run_rg(pattern, search_path, opts)
    for _, r in ipairs(results) do
        print(string.format("%s:%d:%d: %s", r.file, r.line, r.col, r.text))
    end
end

local function cmd_preview(spec)
    Term.init()
    local parsed = parse_vimgrep_line(spec .. ":1:")
    if not parsed then
        print("Invalid preview spec: " .. tostring(spec))
        return
    end
    local flines = Engine.get_file_lines(parsed.file)
    if not flines then
        print("Cannot read file: " .. parsed.file)
        return
    end
    local start_l = math.max(1, parsed.line - 8)
    local end_l = math.min(#flines, parsed.line + 8)
    print(string.format("%s=== %s (line %d) ===%s", C.b_cyan, parsed.file, parsed.line, C.reset))
    for lno = start_l, end_l do
        local prefix = (lno == parsed.line) and (C.b_yellow .. "▸") or " "
        print(string.format("%s %5d │ %s%s", prefix, lno, flines[lno], C.reset))
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

    print("Running frg.lua automated self-tests...")

    local win_p = parse_vimgrep_line([[C:\test\utils\bin\fdu.lua:42:15:  local x = 1]])
    assert_eq("Windows drive-letter file parse", win_p and win_p.file, [[C:\test\utils\bin\fdu.lua]])
    assert_eq("Windows drive-letter line parse", win_p and win_p.line, 42)
    assert_eq("Windows drive-letter col parse",  win_p and win_p.col, 15)
    assert_eq("Windows drive-letter text parse", win_p and win_p.text, "local x = 1")

    local nix_p = parse_vimgrep_line("bin/fport.lua:108:9:function Term.init()")
    assert_eq("POSIX file parse", nix_p and nix_p.file, "bin/fport.lua")
    assert_eq("POSIX line parse", nix_p and nix_p.line, 108)
    assert_eq("POSIX col parse",  nix_p and nix_p.col, 9)

    local flines = Engine.get_file_lines(".gitconfig")
    assert_eq("Engine.get_file_lines reads .gitconfig", type(flines) == "table" and #flines > 5, true)

    local rg_res = Engine.run_rg("autocrlf", ".gitconfig", { case_mode = "smart" })
    assert_eq("Engine.run_rg finds autocrlf in .gitconfig", #rg_res >= 1, true)
    if #rg_res >= 1 then
        assert_eq("Engine.run_rg line number == 2", rg_res[1].line, 2)
    end

    print(string.format("\nSelf-test summary: %d passed, %d failed.", passed, failed))
    if failed > 0 then os.exit(1) end
end

local function show_help()
    print([[
Usage: frg [OPTIONS] [PATTERN] [PATH]

High-Performance Interactive Ripgrep Search & Code Jump TUI (LuaJIT + FFI).

Options:
  -i, --ignore-case    Case-insensitive search
  -s, --case-sensitive Case-sensitive search
  -F, --fixed-strings  Literal string search (disable regex)
  -w, --word-regexp    Match whole words only
  -H, --hidden         Include hidden files and directories
  -l, --list           Print matches to stdout and exit
  --preview <F:LINE>   Print source code context around <FILE>:<LINE>
  --test               Run automated self-test suite
  -h, --help           Show this help message

TUI Keybindings:
  /                    Edit Ripgrep search pattern and re-run search
  f                    Fuzzy-filter current match results
  j / k / Up / Down    Move selection cursor
  Enter                Open match(es) in $EDITOR / nvim at +line
  Space / Tab          Toggle multi-select on match
  i                    Cycle Case mode (Smart -> Ignore -> Sensitive)
  F                    Toggle Literal / Fixed-Strings mode (-F)
  w                    Toggle Whole-Word mode (-w)
  H                    Toggle Hidden files (--hidden)
  ?                    Show keyboard shortcuts help
  q / Esc              Quit]])
end

--------------------------------------------------------------------------------
-- Entrypoint
--------------------------------------------------------------------------------
local args = { ... }
local mode = "tui"
local opts = { case_mode = "smart", fixed = false, word = false, hidden = false }
local positional = {}
local preview_spec = nil

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
    elseif a == "-i" or a == "--ignore-case" then
        opts.case_mode = "ignore"
    elseif a == "-s" or a == "--case-sensitive" then
        opts.case_mode = "sensitive"
    elseif a == "-F" or a == "--fixed-strings" then
        opts.fixed = true
    elseif a == "-w" or a == "--word-regexp" then
        opts.word = true
    elseif a == "-H" or a == "--hidden" then
        opts.hidden = true
    elseif a == "--preview" then
        mode = "preview"
        i = i + 1
        preview_spec = args[i]
    else
        table.insert(positional, a)
    end
    i = i + 1
end

local pattern = positional[1] or ""
local search_path = positional[2] or ""

if mode == "list" then
    cmd_list(pattern, search_path, opts)
elseif mode == "preview" then
    cmd_preview(preview_spec or "")
else
    run_tui(pattern, search_path, opts)
end
