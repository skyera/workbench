#!/usr/bin/env luajit
--[[
  fe.lua - Ultra-Fast Fuzzy File Finder & Multi-Tab Editor Launcher
  Part of the Skyera Workbench utility suite.
  Powered by LuaJIT & FFI. Single-file, zero external Lua dependencies.
  Runs natively on Windows and Linux/macOS with differential flicker-free rendering.

  Features:
    - High-speed file discovery:
      * Tier 1: Git repository files (git ls-files --cached --others --exclude-standard)
      * Tier 2: fd / fdfind if installed
      * Tier 3: Native Win32 FindFirstFileW / POSIX opendir FFI directory crawler
    - Multiple Context Tabs:
      * [Files]: Full project / directory tree
      * [Git]: Modified, staged, and untracked files (git status --porcelain)
      * [Recent]: Most recently modified files in the working tree
    - Dual-Pane TUI Layout:
      * Left Pane: File list with size pills, icons, and multi-selection checkboxes
      * Right Pane: In-memory file inspector with line numbers and binary detection (< 0.1ms)
    - Editor Launcher:
      * Enter: Open in $EDITOR / nvim / vim (multiple files opened as tabs: -p)
      * o: Open multiple files in vertical splits (-O)
      * Tab / Space: Multi-select files for batch editing
    - Conforms to AGENTS.md Windows TUI & Terminal Invariants (DECAWM autowrap safety,
      escaped cmd.exe quoting, \27[0m\27[K hygiene, and bounded row truncation).

  Usage:
    luajit bin/fe.lua [OPTIONS] [QUERY]
    fe [OPTIONS] [QUERY]

  Options:
    -g, --git            Start on [Git] modified files tab
    -r, --recent         Start on [Recent] files tab
    -a, --all            Include hidden files (dotfiles)
    -l, --list           Print matching files to stdout and exit (non-interactive)
    -p, --preview <FILE> Print rich file preview card to stdout and exit
    --test               Run built-in automated self-test suite and exit
    -h, --help           Show this help message
]]

local ffi = require("ffi")
local bit = require("bit")

local OS = ffi.os
local IS_WINDOWS = (OS == "Windows")
local IS_POSIX   = (OS == "Linux" or OS == "OSX" or OS == "BSD" or OS == "POSIX")

--------------------------------------------------------------------------------
-- 1. ANSI Colors & Styling
--------------------------------------------------------------------------------
local C = {
    reset       = "\27[0m",
    bold        = "\27[1m",
    dim         = "\27[2m",
    italic      = "\27[3m",
    underline   = "\27[4m",
    inverse     = "\27[7m",

    black       = "\27[30m",
    red         = "\27[31m",
    green       = "\27[32m",
    yellow      = "\27[33m",
    blue        = "\27[34m",
    magenta     = "\27[35m",
    cyan        = "\27[36m",
    white       = "\27[37m",
    gray        = "\27[90m",

    b_black     = "\27[90m",
    b_red       = "\27[91m",
    b_green     = "\27[92m",
    b_yellow    = "\27[93m",
    b_blue      = "\27[94m",
    b_magenta   = "\27[95m",
    b_cyan      = "\27[96m",
    b_white     = "\27[97m",

    bg_header   = "\27[48;5;236m",
    bg_select   = "\27[48;5;238m",
    bg_match    = "\27[48;5;240m",
    bg_red      = "\27[41m",
    bg_green    = "\27[42m",
}

--------------------------------------------------------------------------------
-- 2. FFI Declarations
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
            WORD wAttributes;
            SMALL_RECT srWindow;
            COORD dwMaximumWindowSize;
        } CONSOLE_SCREEN_BUFFER_INFO;

        typedef struct {
            DWORD dwLowDateTime;
            DWORD dwHighDateTime;
        } FILETIME;

        typedef struct {
            DWORD dwFileAttributes;
            FILETIME ftCreationTime;
            FILETIME ftLastAccessTime;
            FILETIME ftLastWriteTime;
            DWORD nFileSizeHigh;
            DWORD nFileSizeLow;
            DWORD dwReserved0;
            DWORD dwReserved1;
            wchar_t cFileName[260];
            wchar_t cAlternateFileName[14];
        } WIN32_FIND_DATAW;

        HANDLE GetStdHandle(DWORD nStdHandle);
        BOOL GetConsoleMode(HANDLE hConsoleHandle, DWORD* lpMode);
        BOOL SetConsoleMode(HANDLE hConsoleHandle, DWORD dwMode);
        BOOL GetConsoleScreenBufferInfo(HANDLE hConsoleOutput, CONSOLE_SCREEN_BUFFER_INFO* lpConsoleScreenBufferInfo);

        HANDLE FindFirstFileW(LPCWSTR lpFileName, WIN32_FIND_DATAW* lpFindFileData);
        BOOL FindNextFileW(HANDLE hFindFile, WIN32_FIND_DATAW* lpFindFileData);
        BOOL FindClose(HANDLE hFindFile);

        int MultiByteToWideChar(unsigned int CodePage, DWORD dwFlags, const char* lpMultiByteStr, int cbMultiByte, wchar_t* lpWideCharStr, int cchWideChar);
        int WideCharToMultiByte(unsigned int CodePage, DWORD dwFlags, LPCWSTR lpWideCharStr, int cchWideChar, char* lpMultiByteStr, int cbMultiByte, const char* lpDefaultChar, BOOL* lpUsedDefaultChar);

        BOOL SetConsoleOutputCP(unsigned int wCodePageID);
        BOOL SetConsoleCP(unsigned int wCodePageID);
        int _getch(void);
        int _kbhit(void);
        void Sleep(DWORD dwMilliseconds);
        DWORD GetFileAttributesW(LPCWSTR lpFileName);
    ]]
else
    ffi.cdef[[
        typedef struct DIR DIR;
        struct dirent {
            unsigned long  d_ino;
            long           d_off;
            unsigned short d_reclen;
            unsigned char  d_type;
            char           d_name[256];
        };
        DIR *opendir(const char *name);
        struct dirent *readdir(DIR *dirp);
        int closedir(DIR *dirp);

        struct winsize {
            unsigned short ws_row;
            unsigned short ws_col;
            unsigned short ws_xpixel;
            unsigned short ws_ypixel;
        };
        int ioctl(int fd, unsigned long request, ...);

        struct pollfd {
            int fd;
            short events;
            short revents;
        };
        int poll(struct pollfd *fds, unsigned long nfds, int timeout);

        typedef unsigned char cc_t;
        typedef unsigned int speed_t;
        typedef unsigned int tcflag_t;
        struct termios {
            tcflag_t c_iflag;
            tcflag_t c_oflag;
            tcflag_t c_cflag;
            tcflag_t c_lflag;
            cc_t c_line;
            cc_t c_cc[32];
            speed_t c_ispeed;
            speed_t c_ospeed;
        };
        int tcgetattr(int fd, struct termios *termios_p);
        int tcsetattr(int fd, int optional_actions, const struct termios *termios_p);
        int open(const char *pathname, int flags, ...);
        int close(int fd);
        long read(int fd, void *buf, unsigned long count);
    ]]
end

--------------------------------------------------------------------------------
-- 3. Terminal Control & Raw Mode
--------------------------------------------------------------------------------
local Term = {
    initialized = false,
    orig_mode_in = nil,
    orig_mode_out = nil,
    orig_termios = nil,
    hIn = nil,
    hOut = nil,
    tty_fd = -1,
    tty_out = nil,
}

function Term.write_tui(s)
    if not Term.tty_out then
        if IS_WINDOWS then
            Term.tty_out = io.stderr
        else
            Term.tty_out = io.open("/dev/tty", "w") or io.stderr
        end
    end
    Term.tty_out:write(s)
    Term.tty_out:flush()
end

function Term.init()
    if Term.initialized then return end
    if IS_WINDOWS then
        pcall(function()
            ffi.C.SetConsoleOutputCP(65001)
            ffi.C.SetConsoleCP(65001)
        end)
        Term.hIn = ffi.C.GetStdHandle(-10)   -- STD_INPUT_HANDLE
        Term.hOut = ffi.C.GetStdHandle(-11)  -- STD_OUTPUT_HANDLE
        local hErr = ffi.C.GetStdHandle(-12) -- STD_ERROR_HANDLE
        local mIn = ffi.new("DWORD[1]")
        local mOut = ffi.new("DWORD[1]")
        local mErr = ffi.new("DWORD[1]")
        ffi.C.GetConsoleMode(Term.hIn, mIn)
        ffi.C.GetConsoleMode(Term.hOut, mOut)
        ffi.C.GetConsoleMode(hErr, mErr)
        Term.orig_mode_in = mIn[0]
        Term.orig_mode_out = mOut[0]

        local raw_in = bit.band(Term.orig_mode_in, bit.bnot(0x0007)) -- Disable ECHO, LINE_INPUT, PROCESSED_INPUT
        local raw_out = bit.bor(Term.orig_mode_out, 0x0004) -- ENABLE_VIRTUAL_TERMINAL_PROCESSING
        local raw_err = bit.bor(mErr[0], 0x0004)
        ffi.C.SetConsoleMode(Term.hIn, raw_in)
        ffi.C.SetConsoleMode(Term.hOut, raw_out)
        ffi.C.SetConsoleMode(hErr, raw_err)
    else
        Term.tty_fd = ffi.C.open("/dev/tty", 2)
        if Term.tty_fd < 0 then Term.tty_fd = 0 end
        Term.orig_termios = ffi.new("struct termios")
        ffi.C.tcgetattr(Term.tty_fd, Term.orig_termios)

        local raw = ffi.new("struct termios")
        ffi.C.tcgetattr(Term.tty_fd, raw)
        raw.c_lflag = bit.band(raw.c_lflag, bit.bnot(0x00000008 + 0x00000002 + 0x00000001 + 0x00008000))
        raw.c_iflag = bit.band(raw.c_iflag, bit.bnot(0x00000001 + 0x00000002 + 0x00000004 + 0x00000400))
        raw.c_cc[5] = 0 -- VTIME
        raw.c_cc[6] = 1 -- VMIN
        ffi.C.tcsetattr(Term.tty_fd, 0, raw)
    end
    Term.initialized = true
    -- Alternate screen, disable autowrap (\27[?7l), clear screen, hide cursor
    Term.write_tui("\27[?1049h\27[?7l\27[2J\27[H\27[?25l")
end

function Term.restore()
    if not Term.initialized then return end
    -- Show cursor, restore autowrap (\27[?7h), exit alternate screen
    Term.write_tui("\27[?25h\27[?7h\27[?1049l" .. C.reset)
    if IS_WINDOWS then
        if Term.orig_mode_in and Term.hIn then
            ffi.C.SetConsoleMode(Term.hIn, Term.orig_mode_in)
        end
        if Term.orig_mode_out and Term.hOut then
            ffi.C.SetConsoleMode(Term.hOut, Term.orig_mode_out)
        end
    else
        if Term.orig_termios and Term.tty_fd >= 0 then
            ffi.C.tcsetattr(Term.tty_fd, 0, Term.orig_termios)
            if Term.tty_fd ~= 0 then ffi.C.close(Term.tty_fd) end
        end
        if Term.tty_out and Term.tty_out ~= io.stderr then
            pcall(function() Term.tty_out:close() end)
            Term.tty_out = nil
        end
    end
    Term.initialized = false
end

function Term.get_size()
    if IS_WINDOWS then
        local csbi = ffi.new("CONSOLE_SCREEN_BUFFER_INFO")
        if ffi.C.GetConsoleScreenBufferInfo(Term.hOut or ffi.C.GetStdHandle(-11), csbi) ~= 0 then
            local cols = csbi.srWindow.Right - csbi.srWindow.Left + 1
            local rows = csbi.srWindow.Bottom - csbi.srWindow.Top + 1
            return math.max(cols, 40), math.max(rows, 10)
        end
    else
        local ws = ffi.new("struct winsize")
        local TIOCGWINSZ = 0x5413
        if ffi.os == "OSX" then TIOCGWINSZ = 0x40087468 end
        if ffi.C.ioctl(Term.tty_fd >= 0 and Term.tty_fd or 0, TIOCGWINSZ, ws) == 0 then
            if ws.ws_col > 0 and ws.ws_row > 0 then
                return ws.ws_col, ws.ws_row
            end
        end
    end
    return 80, 24
end

Term.key_queue = {}

function Term.read_key()
    if #Term.key_queue > 0 then
        return table.remove(Term.key_queue, 1)
    end

    if IS_WINDOWS then
        if ffi.C._kbhit() == 0 then
            ffi.C.Sleep(50)
            return "NONE"
        end
        local ch = ffi.C._getch()
        if ch == 0 or ch == 224 then
            local ch2 = ffi.C._getch()
            if ch2 == 72 then return "UP"
            elseif ch2 == 80 then return "DOWN"
            elseif ch2 == 75 then return "LEFT"
            elseif ch2 == 77 then return "RIGHT"
            elseif ch2 == 71 then return "HOME"
            elseif ch2 == 79 then return "END"
            elseif ch2 == 73 then return "PGUP"
            elseif ch2 == 81 then return "PGDN"
            elseif ch2 == 83 then return "DELETE"
            end
            return "UNKNOWN"
        end
        if ch == 13 or ch == 10 then return "ENTER"
        elseif ch == 27 then return "ESC"
        elseif ch == 8 then return "BACKSPACE"
        elseif ch == 9 then return "TAB"
        elseif ch == 2 then return "CTRL_B"
        elseif ch == 3 then return "CTRL_C"
        elseif ch == 4 then return "CTRL_D"
        elseif ch == 5 then return "CTRL_E"
        elseif ch == 6 then return "CTRL_F"
        elseif ch == 14 then return "CTRL_N"
        elseif ch == 16 then return "CTRL_P"
        elseif ch == 21 then return "CTRL_U"
        elseif ch == 23 then return "CTRL_W"
        elseif ch == 25 then return "CTRL_Y"
        elseif ch == 32 then return "SPACE"
        end
        return string.char(ch)
    else
        local pfd = ffi.new("struct pollfd[1]")
        pfd[0].fd = Term.tty_fd >= 0 and Term.tty_fd or 0
        pfd[0].events = 1 -- POLLIN
        local pr = ffi.C.poll(pfd, 1, 50)
        if pr <= 0 then
            return "NONE"
        end

        local buf = ffi.new("char[128]")
        local n = ffi.C.read(Term.tty_fd >= 0 and Term.tty_fd or 0, buf, 128)
        if n <= 0 then return "NONE" end

        local i = 0
        while i < n do
            if buf[i] == 27 then -- ESC or escape sequence
                if i + 1 >= n then
                    table.insert(Term.key_queue, "ESC")
                    i = i + 1
                elseif buf[i + 1] == 91 or buf[i + 1] == 79 then -- '[' or 'O'
                    if i + 2 < n then
                        local c = buf[i + 2]
                        local k = nil
                        local adv = 3
                        if c == 65 then k = "UP"
                        elseif c == 66 then k = "DOWN"
                        elseif c == 67 then k = "RIGHT"
                        elseif c == 68 then k = "LEFT"
                        elseif c == 72 then k = "HOME"
                        elseif c == 70 then k = "END"
                        elseif c == 90 then k = "BACKTAB"
                        elseif c == 49 and i + 3 < n and buf[i + 3] == 126 then k = "HOME"; adv = 4
                        elseif c == 52 and i + 3 < n and buf[i + 3] == 126 then k = "END"; adv = 4
                        elseif c == 51 and i + 3 < n and buf[i + 3] == 126 then k = "DELETE"; adv = 4
                        elseif c == 53 and i + 3 < n and buf[i + 3] == 126 then k = "PGUP"; adv = 4
                        elseif c == 54 and i + 3 < n and buf[i + 3] == 126 then k = "PGDN"; adv = 4
                        end
                        if k then
                            table.insert(Term.key_queue, k)
                            i = i + adv
                        else
                            table.insert(Term.key_queue, "ESC")
                            i = i + 1
                        end
                    else
                        table.insert(Term.key_queue, "ESC")
                        i = i + 1
                    end
                else
                    table.insert(Term.key_queue, "ESC")
                    i = i + 1
                end
            else
                local b = buf[i]
                local k = nil
                if b == 13 then
                    k = "ENTER"
                    if i + 1 < n and buf[i + 1] == 10 then
                        i = i + 1
                    end
                elseif b == 10 then
                    k = "ENTER"
                elseif b == 127 or b == 8 then
                    k = "BACKSPACE"
                elseif b == 9 then
                    k = "TAB"
                elseif b == 2 then
                    k = "CTRL_B"
                elseif b == 3 then
                    k = "CTRL_C"
                elseif b == 4 then
                    k = "CTRL_D"
                elseif b == 5 then
                    k = "CTRL_E"
                elseif b == 6 then
                    k = "CTRL_F"
                elseif b == 14 then
                    k = "CTRL_N"
                elseif b == 16 then
                    k = "CTRL_P"
                elseif b == 21 then
                    k = "CTRL_U"
                elseif b == 23 then
                    k = "CTRL_W"
                elseif b == 25 then
                    k = "CTRL_Y"
                elseif b == 32 then
                    k = "SPACE"
                elseif b >= 32 and b <= 126 then
                    k = string.char(b)
                end
                if k then
                    table.insert(Term.key_queue, k)
                end
                i = i + 1
            end
        end

        if #Term.key_queue > 0 then
            return table.remove(Term.key_queue, 1)
        end
        return "NONE"
    end
end

--------------------------------------------------------------------------------
-- 4. String & Parsing Helpers
--------------------------------------------------------------------------------
local function trim(s)
    if not s then return "" end
    return s:match("^%s*(.-)%s*$") or ""
end

local function delete_word(s)
    if not s or #s == 0 then return "" end
    s = s:gsub("%s+$", "")
    s = s:gsub("/+$", "")
    s = s:gsub("[^%s/]+$", "")
    return s
end

local function pad_right(s, w)
    local len = #s
    if len >= w then return s:sub(1, w) end
    return s .. string.rep(" ", w - len)
end

local function pad_left(s, w)
    local len = #s
    if len >= w then return s:sub(1, w) end
    return string.rep(" ", w - len) .. s
end

local function truncate(s, max_w)
    if not s then return "" end
    if #s <= max_w then return s end
    if max_w <= 1 then return s:sub(1, max_w) end
    return s:sub(1, max_w - 1) .. "…"
end

local function visible_width(s)
    if not s or #s == 0 then return 0 end
    local plain = s:gsub("\27%[[%d;]*[a-zA-Z]", ""):gsub("\27%[[%?%d]*[a-zA-Z]", "")
    local len = 0
    for _ in plain:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        len = len + 1
    end
    return len
end

local function pad_to_width(s, w)
    local vw = visible_width(s)
    if vw < w then
        return s .. string.rep(" ", w - vw)
    end
    return s
end

local function truncate_path(path, max_w)
    local vw = visible_width(path)
    if vw <= max_w then return path end
    local target = max_w - 1
    local tail = ""
    local cur_w = 0
    for i = #path, 1, -1 do
        local b = path:byte(i)
        if b < 0x80 or b >= 0xC0 then
            cur_w = cur_w + 1
            if cur_w > target then break end
        end
        tail = path:sub(i, i) .. tail
    end
    return "…" .. tail
end

local SYNTAX_KEYWORDS = {
    -- Lua
    ["local"] = true, ["function"] = true, ["return"] = true, ["if"] = true,
    ["then"] = true, ["else"] = true, ["elseif"] = true, ["end"] = true,
    ["for"] = true, ["while"] = true, ["do"] = true, ["repeat"] = true,
    ["until"] = true, ["break"] = true, ["nil"] = true, ["not"] = true,
    -- Python
    ["def"] = true, ["class"] = true, ["import"] = true, ["from"] = true,
    ["as"] = true, ["try"] = true, ["except"] = true, ["finally"] = true,
    ["with"] = true, ["in"] = true, ["is"] = true, ["lambda"] = true,
    ["yield"] = true, ["raise"] = true, ["pass"] = true, ["continue"] = true,
    ["async"] = true, ["await"] = true, ["self"] = true, ["None"] = true,
    ["True"] = true, ["False"] = true, ["elif"] = true,
    -- JS / TS / C / C++ / Go / Rust
    ["const"] = true, ["let"] = true, ["var"] = true, ["export"] = true,
    ["default"] = true, ["struct"] = true, ["enum"] = true, ["typedef"] = true,
    ["int"] = true, ["char"] = true, ["void"] = true, ["bool"] = true,
    ["fn"] = true, ["pub"] = true, ["mut"] = true, ["impl"] = true,
    ["use"] = true, ["mod"] = true, ["package"] = true, ["type"] = true,
    -- Shell
    ["fi"] = true, ["esac"] = true, ["case"] = true, ["echo"] = true,
    ["exit"] = true,
}

local function highlight_syntax(line, ext)
    if not line or #line == 0 then return "" end
    ext = (ext or ""):lower()

    -- Check for full-line comments
    local trimmed = line:match("^%s*(.-)$") or ""
    if trimmed:sub(1, 2) == "--" or trimmed:sub(1, 2) == "//" or (trimmed:sub(1, 1) == "#" and ext ~= "c" and ext ~= "cpp" and ext ~= "h") then
        return C.gray .. C.italic .. line .. C.reset
    end

    local out = {}
    local i = 1
    local len = #line

    while i <= len do
        local c = line:sub(i, i)

        -- Strings: double quotes, single quotes, backticks
        if c == '"' or c == "'" or (c == '`' and (ext == "js" or ext == "ts" or ext == "go")) then
            local quote = c
            local s_start = i
            i = i + 1
            while i <= len do
                local cur = line:sub(i, i)
                if cur == '\\' then
                    i = i + 2
                elseif cur == quote then
                    i = i + 1
                    break
                else
                    i = i + 1
                end
            end
            table.insert(out, C.b_green .. line:sub(s_start, i - 1) .. C.reset)

        -- Line Comments
        elseif (c == '-' and line:sub(i, i + 1) == "--") or (c == '/' and line:sub(i, i + 1) == "//") or (c == '#' and ext ~= "c" and ext ~= "cpp" and ext ~= "h") then
            table.insert(out, C.gray .. C.italic .. line:sub(i) .. C.reset)
            break

        -- Python decorator @decorator
        elseif c == '@' and (ext == "py" or ext == "pyw") then
            local dec_start = i
            i = i + 1
            while i <= len and line:sub(i, i):match("[%w_]") do
                i = i + 1
            end
            table.insert(out, C.b_yellow .. line:sub(dec_start, i - 1) .. C.reset)

        -- Identifiers / Keywords
        elseif c:match("[%a_]") then
            local id_start = i
            while i <= len and line:sub(i, i):match("[%w_]") do
                i = i + 1
            end
            local word = line:sub(id_start, i - 1)
            if SYNTAX_KEYWORDS[word] then
                if word == "self" then
                    table.insert(out, C.b_cyan .. word .. C.reset)
                else
                    table.insert(out, C.bold .. C.b_magenta .. word .. C.reset)
                end
            else
                table.insert(out, word)
            end

        -- Numbers
        elseif c:match("%d") then
            local num_start = i
            while i <= len and line:sub(i, i):match("[%x%.xX_]") do
                i = i + 1
            end
            table.insert(out, C.b_yellow .. line:sub(num_start, i - 1) .. C.reset)

        -- Operators / Punctuation
        elseif c:match("[%+%-/%*%%=<>!~%^&|]") then
            table.insert(out, C.b_cyan .. c .. C.reset)
            i = i + 1
        else
            table.insert(out, c)
            i = i + 1
        end
    end

    return table.concat(out)
end

local function format_size(bytes)
    if not bytes or bytes < 0 then return "   0 B" end
    if bytes < 1024 then
        return string.format("%4d B", bytes)
    elseif bytes < 1024 * 1024 then
        return string.format("%4.1f KB", bytes / 1024)
    elseif bytes < 1024 * 1024 * 1024 then
        return string.format("%4.1f MB", bytes / (1024 * 1024))
    else
        return string.format("%4.1f GB", bytes / (1024 * 1024 * 1024))
    end
end

local function fuzzy_score(pattern, str)
    if not pattern or #pattern == 0 then return 100 end
    pattern = pattern:lower()
    str = str:lower()

    if str:find(pattern, 1, true) then
        return 1000 - (#str - #pattern)
    end

    local p_idx = 1
    local p_len = #pattern
    local s_len = #str
    local score = 0
    local last_match = 0

    for s_idx = 1, s_len do
        if p_idx <= p_len and str:byte(s_idx) == pattern:byte(p_idx) then
            score = score + 10
            if s_idx == last_match + 1 then
                score = score + 15
            end
            last_match = s_idx
            p_idx = p_idx + 1
        end
    end

    if p_idx > p_len then
        return score
    end
    return nil
end

local function get_extension(path)
    return path:match("%.([%w_%-]+)$") or ""
end

local EXT_COLORS = {
    lua   = C.b_blue,
    py    = C.b_yellow,
    sh    = C.b_green,
    bash  = C.b_green,
    bat   = C.b_magenta,
    cmd   = C.b_magenta,
    ps1   = C.b_cyan,
    c     = C.b_cyan,
    cpp   = C.b_cyan,
    h     = C.cyan,
    hpp   = C.cyan,
    rs    = C.b_red,
    go    = C.b_cyan,
    js    = C.yellow,
    ts    = C.b_blue,
    json  = C.yellow,
    toml  = C.magenta,
    yaml  = C.magenta,
    yml   = C.magenta,
    md    = C.b_white,
    txt   = C.white,
    html  = C.b_red,
    css   = C.b_blue,
}

local function get_ext_color(ext)
    return EXT_COLORS[ext:lower()] or C.gray
end

--------------------------------------------------------------------------------
-- 5. Subprocess & Git Engine
--------------------------------------------------------------------------------
local Engine = {}

function Engine.exec(cmd)
    local devnull = IS_WINDOWS and "2>nul" or "2>/dev/null"
    local full_cmd = cmd .. " " .. devnull
    local p = io.popen(full_cmd, "r")
    if not p then return "" end
    local out = p:read("*a")
    p:close()
    return out or ""
end

local _git_info_cached = nil

function Engine.get_git_info()
    if _git_info_cached ~= nil then
        return _git_info_cached
    end

    local raw = Engine.exec("git rev-parse --is-inside-work-tree --show-toplevel --abbrev-ref HEAD 2>/dev/null")
    local lines = {}
    for line in raw:gmatch("[^\r\n]+") do
        table.insert(lines, trim(line))
    end

    if #lines >= 1 and lines[1] == "true" then
        local top = lines[2] or ""
        local repo = top:match("([^/\\]+)$") or (top ~= "" and top or "workspace")
        local branch = lines[3] or "HEAD"
        if branch == "HEAD" or #branch == 0 then
            local short_sha = trim(Engine.exec("git rev-parse --short HEAD 2>/dev/null"))
            branch = #short_sha > 0 and short_sha or "detached"
        end
        _git_info_cached = {
            is_git = true,
            repo_name = repo,
            branch_name = branch,
            toplevel = top,
        }
    else
        local cwd = Engine.exec(IS_WINDOWS and "cd" or "pwd")
        cwd = trim(cwd):gsub("\\", "/")
        local folder = cwd:match("([^/]+)$") or "workspace"
        _git_info_cached = {
            is_git = false,
            repo_name = folder,
            branch_name = "",
            toplevel = "",
        }
    end

    return _git_info_cached
end

function Engine.is_inside_git_repo()
    return Engine.get_git_info().is_git
end

function Engine.get_repo_name()
    return Engine.get_git_info().repo_name
end

function Engine.get_git_branch()
    return Engine.get_git_info().branch_name
end

local function to_wide(str)
    if not IS_WINDOWS then return str end
    local len = ffi.C.MultiByteToWideChar(65001, 0, str, #str, nil, 0)
    local buf = ffi.new("wchar_t[?]", len + 1)
    ffi.C.MultiByteToWideChar(65001, 0, str, #str, buf, len)
    buf[len] = 0
    return buf
end

local function from_wide(wstr)
    if not IS_WINDOWS then return wstr end
    local len = ffi.C.WideCharToMultiByte(65001, 0, wstr, -1, nil, 0, nil, nil)
    local buf = ffi.new("char[?]", len)
    ffi.C.WideCharToMultiByte(65001, 0, wstr, -1, buf, len, nil, nil)
    return ffi.string(buf, len - 1)
end

-- Cross-platform directory check
function Engine.is_dir(path)
    if not path or #path == 0 then return false end
    if IS_WINDOWS then
        local wpath = to_wide(path)
        local attr = ffi.C.GetFileAttributesW(wpath)
        return (attr ~= 0xFFFFFFFF and bit.band(attr, 0x10) ~= 0)
    else
        local d = ffi.C.opendir(path)
        if d ~= nil then
            ffi.C.closedir(d)
            return true
        end
    end
    return false
end

-- Fast file size & line count query
function Engine.get_file_stat(filepath)
    if not filepath or #filepath == 0 or Engine.is_dir(filepath) then
        return { size = 0, lines = 0, is_binary = false, unreadable = false, is_dir = true }
    end
    local f = io.open(filepath, "rb")
    if not f then
        return { size = 0, lines = 0, is_binary = false, unreadable = true }
    end
    local size = f:seek("end") or 0
    f:seek("set", 0)

    -- Check first 1024 bytes for null character to identify binary files
    local head = f:read(1024) or ""
    local is_binary = (head:find("%z") ~= nil)

    local lines = 0
    if not is_binary and size < 1024 * 1024 * 5 then -- Don't count lines on >5MB files
        f:seek("set", 0)
        pcall(function()
            for _ in f:lines() do
                lines = lines + 1
            end
        end)
    end
    f:close()

    return {
        size = size,
        lines = lines,
        is_binary = is_binary,
        unreadable = false,
    }
end

-- Read preview lines from file
function Engine.get_file_preview(filepath, max_lines)
    max_lines = max_lines or 60
    if not filepath or #filepath == 0 then
        return { "  (No file selected)" }, 0, false
    end

    if Engine.is_dir(filepath) then
        return {
            string.format("  [Directory / Submodule: %s]", filepath),
            "  (Directory contents hidden from file preview)",
        }, 0, false
    end

    local f = io.open(filepath, "rb")
    if not f then
        return { "  (Cannot open file: file not found or permission denied)" }, 0, false
    end

    local head = f:read(1024) or ""
    if head:find("%z") then
        local size = f:seek("end") or 0
        f:close()
        return {
            string.format("  [Binary File: %s]", filepath),
            string.format("  Size: %s", format_size(size)),
            "  (Binary content is hidden from preview)",
        }, size, true
    end

    f:seek("set", 0)
    local lines = {}
    local count = 0
    local read_ok, read_err = pcall(function()
        for line in f:lines() do
            count = count + 1
            if count <= max_lines then
                table.insert(lines, (line:gsub("\r$", "")))
            end
        end
    end)
    f:close()

    if not read_ok then
        return {
            string.format("  (Error reading file: %s)", tostring(read_err):gsub("^.-:%s*", "")),
        }, 0, false
    end

    return lines, count, false
end

function Engine.get_file_size(item)
    if not item then return 0 end
    if item.size == nil then
        local f = io.open(item.path, "rb")
        item.size = f and f:seek("end") or 0
        if f then f:close() end
    end
    return item.size
end

-- Heavy directory names to prune during recursive directory traversal
local IGNORED_DIRS = {
    [".git"] = true,
    ["node_modules"] = true,
    [".cache"] = true,
    ["__pycache__"] = true,
    [".venv"] = true,
    ["venv"] = true,
    [".cargo"] = true,
    ["target"] = true,
    ["build"] = true,
    ["dist"] = true,
    [".vs"] = true,
    [".idea"] = true,
    [".vscode"] = true,
    ["obj"] = true,
    ["bin/obj"] = true,
    [".antigravitycli"] = true,
}

-- Fallback native scanner using FFI
function Engine.scan_native(base_dir, max_files)
    max_files = max_files or 50000
    local files = {}

    local function scan_dir(dir_path, depth)
        if depth > 10 or #files >= max_files then return end
        if IS_WINDOWS then
            local pattern = (dir_path == "" or dir_path == ".") and "*.*" or (dir_path .. "\\*.*")
            local wpattern = to_wide(pattern)
            local find_data = ffi.new("WIN32_FIND_DATAW")
            local handle = ffi.C.FindFirstFileW(wpattern, find_data)
            if handle == ffi.cast("HANDLE", -1) or handle == nil then return end

            repeat
                local name = from_wide(find_data.cFileName)
                if name ~= "." and name ~= ".." then
                    local is_dir = bit.band(find_data.dwFileAttributes, 0x00000010) ~= 0
                    local rel_path = (dir_path == "" or dir_path == ".") and name or (dir_path .. "/" .. name)
                    rel_path = rel_path:gsub("\\", "/")

                    if is_dir then
                        if not IGNORED_DIRS[name] then
                            scan_dir(rel_path, depth + 1)
                        end
                    else
                        local size = tonumber(find_data.nFileSizeLow) + tonumber(find_data.nFileSizeHigh) * 4294967296
                        table.insert(files, {
                            path = rel_path,
                            name = name,
                            size = size,
                            ext = get_extension(name),
                        })
                    end
                end
            until ffi.C.FindNextFileW(handle, find_data) == 0
            ffi.C.FindClose(handle)
        else
            local d_name = (dir_path == "" or dir_path == ".") and "." or dir_path
            local dir = ffi.C.opendir(d_name)
            if dir == nil then return end

            while true do
                local entry = ffi.C.readdir(dir)
                if entry == nil then break end
                local name = ffi.string(entry.d_name)
                if name ~= "." and name ~= ".." then
                    local is_dir = (entry.d_type == 4) -- DT_DIR
                    local rel_path = (dir_path == "" or dir_path == ".") and name or (dir_path .. "/" .. name)

                    if is_dir then
                        if not IGNORED_DIRS[name] then
                            scan_dir(rel_path, depth + 1)
                        end
                    else
                        table.insert(files, {
                            path = rel_path,
                            name = name,
                            size = nil, -- Resolved lazily
                            ext = get_extension(name),
                        })
                    end
                end
            end
            ffi.C.closedir(dir)
        end
    end

    scan_dir(".", 1)
    return files
end

-- Primary discovery function
function Engine.load_files(include_hidden)
    local files = {}
    local seen = {}

    -- 1. If inside a git repository, git ls-files is fastest and respects .gitignore
    if Engine.is_inside_git_repo() then
        local raw = Engine.exec("git ls-files --cached --others --exclude-standard")
        for line in raw:gmatch("[^\r\n]+") do
            line = trim(line)
            if #line > 0 and not seen[line] then
                seen[line] = true
                local name = line:match("([^/\\]+)$") or line
                table.insert(files, {
                    path = line:gsub("\\", "/"),
                    name = name,
                    size = nil, -- Resolved lazily on-demand
                    ext = get_extension(name),
                    is_git = true,
                })
            end
        end
        if #files > 0 then
            return files
        end
    end

    -- 2. Try fd / fdfind
    local fd_cmd = nil
    if #Engine.exec("fd --version 2>/dev/null") > 0 then
        fd_cmd = "fd --type f" .. (include_hidden and " --hidden" or "") .. " --exclude .git --exclude node_modules --exclude target"
    elseif #Engine.exec("fdfind --version 2>/dev/null") > 0 then
        fd_cmd = "fdfind --type f" .. (include_hidden and " --hidden" or "") .. " --exclude .git --exclude node_modules --exclude target"
    end

    if fd_cmd then
        local raw = Engine.exec(fd_cmd)
        for line in raw:gmatch("[^\r\n]+") do
            line = trim(line):gsub("^%./", "")
            if #line > 0 and not seen[line] then
                seen[line] = true
                local name = line:match("([^/\\]+)$") or line
                table.insert(files, {
                    path = line:gsub("\\", "/"),
                    name = name,
                    size = nil, -- Resolved lazily on-demand
                    ext = get_extension(name),
                })
            end
        end
        if #files > 0 then
            return files
        end
    end

    -- 3. Native fallback FFI scan
    return Engine.scan_native(".", 30000)
end

-- Load modified / untracked files from git
function Engine.load_git_files()
    local git_files = {}
    if not Engine.is_inside_git_repo() then
        return git_files
    end

    local raw = Engine.exec("git status --porcelain=v1 -unormal")
    for line in raw:gmatch("[^\r\n]+") do
        local status, fpath = line:match("^(..)%s+(.*)$")
        if status and fpath then
            fpath = trim(fpath)
            -- Handle renamed files "old -> new"
            if fpath:find("%->") then
                fpath = fpath:match("%->%s*(.*)$")
            end
            fpath = fpath:gsub('^"', ''):gsub('"$', '')
            local name = fpath:match("([^/\\]+)$") or fpath

            local stat_label = "[Modified]"
            if status:find("?") then stat_label = "[Untracked]"
            elseif status:find("A") then stat_label = "[Added   ]"
            elseif status:find("D") then stat_label = "[Deleted ]"
            elseif status:find("R") then stat_label = "[Renamed ]"
            end

            table.insert(git_files, {
                path = fpath:gsub("\\", "/"),
                name = name,
                size = nil, -- Resolved lazily on-demand
                ext = get_extension(name),
                git_status = stat_label,
            })
        end
    end
    return git_files
end

-- Load recent files (sorted by committer/mtime)
function Engine.load_recent_files(all_files)
    local recent = {}
    local seen = {}

    if Engine.is_inside_git_repo() then
        local raw = Engine.exec("git log -n 50 --name-only --format=\"\"")
        for line in raw:gmatch("[^\r\n]+") do
            line = trim(line)
            if #line > 0 and not seen[line] then
                seen[line] = true
                local name = line:match("([^/\\]+)$") or line
                table.insert(recent, {
                    path = line:gsub("\\", "/"),
                    name = name,
                    size = nil, -- Resolved lazily on-demand
                    ext = get_extension(name),
                })
            end
        end
    end

    if #recent == 0 and all_files then
        -- Fallback: first 30 files from all_files
        for i = 1, math.min(30, #all_files) do
            table.insert(recent, all_files[i])
        end
    end

    return recent
end

-- Editor detection
function Engine.get_editor_cmd()
    local ed = os.getenv("EDITOR") or os.getenv("VISUAL")
    if ed and #ed > 0 then
        return ed
    end
    -- Check common editor binaries
    local checks = IS_WINDOWS and { "nvim.exe", "vim.exe", "code.cmd" } or { "nvim", "vim", "vi", "nano" }
    for _, bin_name in ipairs(checks) do
        local check_cmd = IS_WINDOWS and ("where " .. bin_name) or ("command -v " .. bin_name)
        if #Engine.exec(check_cmd) > 0 then
            return bin_name:gsub("%.exe$", ""):gsub("%.cmd$", "")
        end
    end
    return IS_WINDOWS and "notepad.exe" or "vi"
end

--------------------------------------------------------------------------------
-- 6. Interactive TUI Engine
--------------------------------------------------------------------------------
local TABS = { "files", "git", "recent" }
local TAB_LABELS = {
    files = "All Files",
    git = "Git Changes",
    recent = "Recent",
}

local function run_tui(init_opts)
    init_opts = init_opts or {}
    Term.init()

    local state = {
        files = nil,
        git_files = nil,
        recent_files = nil,
        filtered = {},
        repo_name = Engine.get_repo_name(),
        branch_name = Engine.get_git_branch(),
        filter = init_opts.filter or "",
        prev_filter = "",
        mode = "normal", -- "normal", "filter"
        tab_idx = init_opts.start_tab or 1,
        cursor = 1,
        prev_cursor = 1,
        scroll = 1,
        selected_set = {}, -- { [filepath] = true }
        cached_previews = {},
        status_msg = "",
        status_type = "ok",
        preview_scroll = 0,
        pending_op = nil,
        body_h = 10,
    }

    local function get_current_tab_list()
        local tab = TABS[state.tab_idx]
        if tab == "git" then
            if not state.git_files then
                state.git_files = Engine.load_git_files()
            end
            return state.git_files
        elseif tab == "recent" then
            if not state.recent_files then
                if not state.files then
                    state.files = Engine.load_files(init_opts.show_all)
                end
                state.recent_files = Engine.load_recent_files(state.files)
            end
            return state.recent_files
        else
            if not state.files then
                state.files = Engine.load_files(init_opts.show_all)
            end
            return state.files
        end
    end

    local function refresh_data()
        state.files = nil
        state.git_files = nil
        state.recent_files = nil
        state.cached_previews = {}
        get_current_tab_list()
    end

    local function apply_filter()
        local src = get_current_tab_list() or {}

        if #state.filter > 0 then
            local list = {}
            for _, item in ipairs(src) do
                local s1 = fuzzy_score(state.filter, item.name)
                local s2 = fuzzy_score(state.filter, item.path)
                local s = math.max(s1 or 0, s2 or 0)
                if s > 0 then
                    table.insert(list, { item = item, score = s })
                end
            end
            table.sort(list, function(a, b) return a.score > b.score end)
            state.filtered = {}
            for _, it in ipairs(list) do
                table.insert(state.filtered, it.item)
            end
        else
            state.filtered = src
        end

        state.cursor = math.max(1, math.min(state.cursor, #state.filtered))
    end

    get_current_tab_list()
    apply_filter()

    local prev_lines = {}
    local prev_cols = 0
    local prev_rows = 0

    local function render()
        local cols, rows = Term.get_size()
        if cols ~= prev_cols or rows ~= prev_rows then
            prev_lines = {}
            prev_cols = cols
            prev_rows = rows
            Term.write_tui("\27[2J\27[H")
        end

        local frame_lines = {}
        local function add_line(s)
            frame_lines[#frame_lines + 1] = s
        end

        local cur_item = state.filtered[state.cursor]

        -- 1. Header Line
        local head_str = string.format(" %s%s⚡ fe%s %s[%s]%s │ Dir: %s%s%s │ Branch: %s%s%s",
            C.b_cyan, C.bold, C.reset,
            C.b_yellow, TAB_LABELS[TABS[state.tab_idx]], C.reset,
            C.b_white, state.repo_name, C.reset,
            C.b_green .. C.bold, state.branch_name, C.reset)
        add_line(C.bg_header .. pad_right(head_str, math.max(1, cols - 1)) .. C.reset)

        -- 2. Subheader Tabs & Filter
        local tabs_str = ""
        for i, t in ipairs(TABS) do
            local cnt = (t == "git" and state.git_files and #state.git_files)
                     or (t == "recent" and state.recent_files and #state.recent_files)
                     or (t == "files" and state.files and #state.files)
            local label = cnt and string.format("%s (%d)", TAB_LABELS[t], cnt) or TAB_LABELS[t]

            if i == state.tab_idx then
                tabs_str = tabs_str .. C.inverse .. C.b_cyan .. "[" .. label .. "]" .. C.reset .. " "
            else
                tabs_str = tabs_str .. C.gray .. "[" .. label .. "]" .. C.reset .. " "
            end
        end

        local filter_disp
        if state.mode == "filter" then
            filter_disp = C.b_yellow .. C.bold .. "Filter (/): " .. C.b_white .. state.filter .. "█" .. C.reset .. C.gray .. " [Enter:Lock  Tab:Select]" .. C.reset
        else
            if #state.filter > 0 then
                filter_disp = C.bold .. "Filter: " .. C.b_white .. state.filter .. C.reset .. C.gray .. " (Esc to clear, / to edit)" .. C.reset
            else
                filter_disp = C.bold .. "Filter (/): " .. C.gray .. "(press / to filter)" .. C.reset
            end
        end

        local sub_l = " " .. filter_disp
        local sub_r = tabs_str .. " "
        local sub_space = cols - (#filter_disp:gsub("\27%[[%d;]*m", "") + #tabs_str:gsub("\27%[[%d;]*m", "") + 4)
        if sub_space < 1 then sub_space = 1 end
        add_line(sub_l .. string.rep(" ", sub_space) .. sub_r)

        -- 3. Pane Geometry
        local body_h = math.max(4, rows - 5)
        state.body_h = body_h
        local left_w = math.floor(cols * 0.48)
        if cols < 90 then left_w = cols - 2 end
        -- Enforce strict 1-column safety buffer before right terminal edge
        local right_w = math.max(0, cols - left_w - 4)

        if state.cursor ~= state.prev_cursor then
            state.preview_scroll = 0
            state.prev_cursor = state.cursor
        end

        -- Adjust scroll viewport
        if #state.filtered <= body_h then
            state.scroll = 1
        elseif state.scroll > #state.filtered - body_h + 1 then
            state.scroll = math.max(1, #state.filtered - body_h + 1)
        end
        if state.cursor < state.scroll then
            state.scroll = state.cursor
        elseif state.cursor >= state.scroll + body_h then
            state.scroll = state.cursor - body_h + 1
        end

        -- Header divider
        local raw_hdr = pad_to_width(string.format("  %-3s  %-8s  %s", "SEL", "SIZE", "FILE PATH"), left_w)
        local list_hdr = C.b_blue .. C.bold .. raw_hdr .. C.reset
        local scroll_hint = (state.preview_scroll > 0) and string.format(" (+%d lines)", state.preview_scroll) or ""
        local right_title = cur_item and truncate(" 📄 PREVIEW: " .. cur_item.path .. scroll_hint, math.max(10, right_w - 2)) or " 📄 FILE PREVIEW"
        local right_hdr = (cols >= 90) and (C.b_white .. C.bold .. right_title .. C.reset) or ""
        local hdr_sep = (cols >= 90) and (C.gray .. "│" .. C.reset) or ""
        add_line(list_hdr .. " " .. hdr_sep .. " " .. right_hdr)

        -- Pre-load preview lines for right pane
        local r_lines = {}
        if cols >= 90 and cur_item then
            if not state.cached_previews[cur_item.path] then
                local lines, total_lines, is_binary = Engine.get_file_preview(cur_item.path, 300)
                state.cached_previews[cur_item.path] = {
                    lines = lines,
                    total_lines = total_lines,
                    is_binary = is_binary,
                }
            end

            local prev_data = state.cached_previews[cur_item.path]
            local meta_str = string.format("  Size: %s │ Lines: %d", format_size(Engine.get_file_size(cur_item)), prev_data.total_lines)
            if cur_item.git_status then
                meta_str = meta_str .. " │ Status: " .. cur_item.git_status
            end
            table.insert(r_lines, C.gray .. truncate(meta_str, math.max(4, right_w - 4)) .. C.reset)
            table.insert(r_lines, C.gray .. string.rep("─", math.max(1, right_w - 2)) .. C.reset)

            if prev_data.is_binary then
                table.insert(r_lines, "")
                table.insert(r_lines, C.b_yellow .. "  [Binary File]" .. C.reset)
                table.insert(r_lines, C.gray .. "  Binary file contents are hidden from live preview." .. C.reset)
            elseif #prev_data.lines == 0 then
                table.insert(r_lines, "")
                table.insert(r_lines, C.gray .. "  (Empty file)" .. C.reset)
            else
                local prev_offset = state.preview_scroll or 0
                for row_idx = 1, math.max(1, body_h - 2) do
                    local l_idx = prev_offset + row_idx
                    local line_txt = prev_data.lines[l_idx]
                    if line_txt then
                        local line_num = string.format("%4d │ ", l_idx)
                        local avail_w = math.max(4, right_w - 9)
                        local clean_line = line_txt:gsub("\t", "    ")
                        local disp_line = truncate(clean_line, avail_w)
                        local hl_line = highlight_syntax(disp_line, cur_item.ext)
                        table.insert(r_lines, C.gray .. line_num .. C.reset .. hl_line .. C.reset)
                    end
                end
            end
        end

        -- 4. Body Rows
        for row = 1, body_h do
            local idx = state.scroll + row - 1
            local item = state.filtered[idx]
            local padded_l

            if item then
                local is_cur = (idx == state.cursor)
                local bg = is_cur and C.bg_select or ""
                local ptr = is_cur and (C.b_cyan .. "▸" .. C.reset .. bg) or " "

                -- Checkbox
                local is_checked = (state.selected_set[item.path] == true)
                local chk = is_checked and (C.b_green .. "[x]" .. C.reset .. bg) or (C.gray .. "[ ]" .. C.reset .. bg)

                -- Size pill
                local sz_str = string.format("[%s]", format_size(Engine.get_file_size(item)))
                local sz_pill = C.b_blue .. sz_str .. C.reset .. bg

                -- File name & relative path
                local name_w = math.max(8, left_w - 18)
                local raw_path = truncate_path(item.path, name_w)
                local path_disp = pad_to_width(raw_path, name_w)

                local ext_color = get_ext_color(item.ext)
                local name_col = is_cur and (C.b_white .. C.bold) or ext_color
                local item_disp = name_col .. path_disp

                local l_str = string.format("%s%s %s %s  %s", bg, ptr, chk, sz_pill, item_disp)
                padded_l = pad_to_width(l_str, left_w) .. C.reset
            elseif row == 1 and #state.filtered == 0 then
                local no_match = "  (No files match current filter)"
                padded_l = C.gray .. pad_to_width(no_match, left_w) .. C.reset
            else
                padded_l = string.rep(" ", left_w)
            end

            local r_str = r_lines[row] or ""
            local sep_char = (cols >= 90) and (C.gray .. "│" .. C.reset) or ""
            add_line(padded_l .. " " .. sep_char .. " " .. r_str)
        end

        -- 5. Footer & Status Line
        local footer_sep = string.rep("─", math.max(1, cols - 1))
        add_line(C.gray .. footer_sep .. C.reset)

        local sel_cnt = 0
        for _ in pairs(state.selected_set) do sel_cnt = sel_cnt + 1 end
        local sel_indicator = (sel_cnt > 0) and string.format("%s(%d selected)%s ", C.b_green, sel_cnt, C.gray) or ""

        local status_disp
        if #state.status_msg > 0 then
            local col = (state.status_type == "ok") and C.b_green or C.b_red
            status_disp = col .. C.bold .. " " .. state.status_msg .. C.reset
        elseif state.pending_op == "z" then
            status_disp = string.format(" %s%sz-%s (press %sz%s:center  %st%s:top  %sb%s:bottom)",
                sel_indicator, C.b_yellow, C.gray, C.b_cyan, C.gray, C.b_cyan, C.gray, C.b_cyan, C.reset)
        elseif state.mode == "filter" then
            status_disp = string.format(" %s%sEnter%s:Lock filter  %sTab%s:Select & down  %s↑/↓/^N/^P%s:Move  %sEsc%s:Normal mode",
                sel_indicator,
                C.b_yellow, C.gray, C.b_green, C.gray, C.b_cyan, C.gray, C.b_red, C.reset)
        else
            status_disp = string.format(" %s%sEnter%s:Edit(tabs)  %so%s:Split  %sTab/Space%s:Select  %sj/k/^d/^u%s:Move  %s/%s:Filter  %sq%s:Quit",
                sel_indicator,
                C.b_yellow, C.gray, C.b_cyan, C.gray, C.b_green, C.gray, C.b_yellow, C.gray, C.b_cyan, C.gray, C.b_red, C.reset)
        end
        add_line(status_disp)

        -- Differential rendering
        local diff_buf = { "\27[?2026h" }
        for r = 1, #frame_lines do
            if frame_lines[r] ~= prev_lines[r] then
                diff_buf[#diff_buf + 1] = string.format("\27[%d;1H%s%s\27[K", r, frame_lines[r], C.reset)
                prev_lines[r] = frame_lines[r]
            end
        end
        if #prev_lines > #frame_lines then
            for r = #frame_lines + 1, #prev_lines do
                diff_buf[#diff_buf + 1] = string.format("\27[%d;1H%s\27[K", r, C.reset)
                prev_lines[r] = nil
            end
        end
        diff_buf[#diff_buf + 1] = "\27[?2026l"
        if #diff_buf > 2 then
            Term.write_tui(table.concat(diff_buf))
        end
    end

    local function launch_editor(split_key)
        local targets = {}
        for p in pairs(state.selected_set) do
            table.insert(targets, p)
        end
        if #targets == 0 and state.filtered[state.cursor] then
            table.insert(targets, state.filtered[state.cursor].path)
        end

        if #targets > 0 then
            Term.restore()
            local ed = Engine.get_editor_cmd()
            local args = {}
            local is_vim = ed:match("[n]?vim") or ed:match("/vi$") or ed == "vi" or ed:match("vi%.exe$")
            if is_vim then
                table.insert(args, '-c "syntax on"')
            end
            if #targets > 1 then
                if split_key == "o" then
                    table.insert(args, "-O") -- Vertical splits
                else
                    table.insert(args, "-p") -- Tabs
                end
            end
            for _, p in ipairs(targets) do
                table.insert(args, string.format('"%s"', p))
            end
            local cmd = ed .. " " .. table.concat(args, " ")
            os.execute(cmd)
            os.exit(0)
        end
    end

    -- Event loop
    while true do
        render()
        local key = Term.read_key()
        if key ~= "NONE" then
            state.status_msg = ""

            if key == "CTRL_C" or (key == "q" and state.mode ~= "filter") then
                Term.restore()
                os.exit(0)
            end

            -- Filter input mode
            if state.mode == "filter" then
                if key == "ESC" then
                    state.mode = "normal"
                elseif key == "ENTER" then
                    state.mode = "normal"
                elseif key == "TAB" then
                    local item = state.filtered[state.cursor]
                    if item then
                        if state.selected_set[item.path] then
                            state.selected_set[item.path] = nil
                        else
                            state.selected_set[item.path] = true
                        end
                    end
                    state.cursor = math.min(math.max(1, #state.filtered), state.cursor + 1)
                elseif key == "BACKTAB" then
                    local item = state.filtered[state.cursor]
                    if item then
                        if state.selected_set[item.path] then
                            state.selected_set[item.path] = nil
                        else
                            state.selected_set[item.path] = true
                        end
                    end
                    state.cursor = math.max(1, state.cursor - 1)
                elseif key == "SPACE" then
                    state.filter = state.filter .. " "
                    apply_filter()
                elseif key == "BACKSPACE" then
                    state.filter = state.filter:sub(1, math.max(0, #state.filter - 1))
                    apply_filter()
                elseif key == "CTRL_U" then
                    state.filter = ""
                    apply_filter()
                elseif key == "CTRL_W" then
                    state.filter = delete_word(state.filter)
                    apply_filter()
                elseif key == "CTRL_N" or key == "DOWN" then
                    state.cursor = math.min(math.max(1, #state.filtered), state.cursor + 1)
                elseif key == "CTRL_P" or key == "UP" then
                    state.cursor = math.max(1, state.cursor - 1)
                elseif #key == 1 then
                    state.filter = state.filter .. key
                    apply_filter()
                end

            -- Normal navigation mode
            else
                if state.pending_op == "z" then
                    if key == "z" then
                        state.scroll = math.max(1, math.min(math.max(1, #state.filtered - state.body_h + 1), state.cursor - math.floor(state.body_h / 2)))
                    elseif key == "t" then
                        state.scroll = math.max(1, math.min(math.max(1, #state.filtered - state.body_h + 1), state.cursor))
                    elseif key == "b" then
                        state.scroll = math.max(1, math.min(math.max(1, #state.filtered - state.body_h + 1), state.cursor - state.body_h + 1))
                    end
                    state.pending_op = nil
                elseif key == "z" then
                    state.pending_op = "z"
                elseif key == "ESC" then
                    if #state.filter > 0 then
                        state.filter = ""
                        apply_filter()
                    else
                        Term.restore()
                        os.exit(0)
                    end
                elseif key == "/" then
                    state.prev_filter = state.filter
                    state.mode = "filter"
                elseif key == "j" or key == "DOWN" or key == "CTRL_N" then
                    state.cursor = math.min(math.max(1, #state.filtered), state.cursor + 1)
                elseif key == "k" or key == "UP" or key == "CTRL_P" then
                    state.cursor = math.max(1, state.cursor - 1)
                elseif key == "CTRL_D" then
                    local half = math.max(1, math.floor(state.body_h / 2))
                    state.cursor = math.min(math.max(1, #state.filtered), state.cursor + half)
                elseif key == "CTRL_U" then
                    local half = math.max(1, math.floor(state.body_h / 2))
                    state.cursor = math.max(1, state.cursor - half)
                elseif key == "CTRL_F" or key == "PGDN" then
                    local page = math.max(1, state.body_h)
                    state.cursor = math.min(math.max(1, #state.filtered), state.cursor + page)
                elseif key == "CTRL_B" or key == "PGUP" then
                    local page = math.max(1, state.body_h)
                    state.cursor = math.max(1, state.cursor - page)
                elseif key == "H" then
                    state.cursor = math.max(1, math.min(#state.filtered, state.scroll))
                elseif key == "M" then
                    state.cursor = math.max(1, math.min(#state.filtered, state.scroll + math.floor((state.body_h - 1) / 2)))
                elseif key == "L" then
                    state.cursor = math.max(1, math.min(#state.filtered, state.scroll + state.body_h - 1))
                elseif key == "CTRL_E" then
                    local cur = state.filtered[state.cursor]
                    local p_lines = (cur and state.cached_previews[cur.path] and state.cached_previews[cur.path].lines) or {}
                    if state.preview_scroll + 1 < #p_lines then
                        state.preview_scroll = state.preview_scroll + 1
                    end
                elseif key == "CTRL_Y" then
                    state.preview_scroll = math.max(0, state.preview_scroll - 1)
                elseif key == "g" or key == "HOME" then
                    state.cursor = 1
                elseif key == "G" or key == "END" then
                    state.cursor = math.max(1, #state.filtered)
                elseif key == "h" or key == "LEFT" then
                    state.tab_idx = (state.tab_idx == 1) and #TABS or (state.tab_idx - 1)
                    apply_filter()
                elseif key == "l" or key == "RIGHT" then
                    state.tab_idx = (state.tab_idx == #TABS) and 1 or (state.tab_idx + 1)
                    apply_filter()
                elseif key == "TAB" or key == "SPACE" then
                    local item = state.filtered[state.cursor]
                    if item then
                        if state.selected_set[item.path] then
                            state.selected_set[item.path] = nil
                        else
                            state.selected_set[item.path] = true
                        end
                    end
                    state.cursor = math.min(math.max(1, #state.filtered), state.cursor + 1)
                elseif key == "ENTER" or key == "o" then
                    launch_editor(key)
                end
            end
        end
    end
end

--------------------------------------------------------------------------------
-- 7. Automated Self-Tests
--------------------------------------------------------------------------------
local function run_tests()
    print("Running fe.lua automated self-tests...")
    local passed = 0
    local failed = 0

    local function assert_eq(test_name, actual, expected)
        if actual == expected then
            passed = passed + 1
            print(string.format("  [PASS] %s", test_name))
        else
            failed = failed + 1
            print(string.format("  [FAIL] %s: expected %s, got %s", test_name, tostring(expected), tostring(actual)))
        end
    end

    -- Test 1: Helper utilities
    assert_eq("trim removes whitespace", trim("  hello world  \n"), "hello world")
    assert_eq("pad_right pads accurately", pad_right("abc", 6), "abc   ")
    assert_eq("format_size for bytes", format_size(500), " 500 B")
    assert_eq("format_size for KB", format_size(2048), " 2.0 KB")
    assert_eq("get_extension gets lua", get_extension("foo/bar.lua"), "lua")
    assert_eq("get_extension empty for none", get_extension("foo/bar"), "")

    -- Test 2: Fuzzy scoring
    assert_eq("fuzzy_score finds exact match", (fuzzy_score("fe", "fe.lua") or 0) > 0, true)
    assert_eq("fuzzy_score nil on mismatch", fuzzy_score("xyz", "fe.lua"), nil)

    -- Test 3: Truncate helper
    assert_eq("truncate short string unchanged", truncate("hello", 10), "hello")
    assert_eq("truncate exact length unchanged", truncate("hello", 5), "hello")
    assert_eq("truncate long string with ellipsis", truncate("hello world", 6), "hello…")

    -- Test 4: Git repository check
    assert_eq("is_inside_git_repo returns boolean", type(Engine.is_inside_git_repo()), "boolean")
    assert_eq("get_repo_name returns string", type(Engine.get_repo_name()), "string")
    assert_eq("get_git_branch returns string", type(Engine.get_git_branch()), "string")

    -- Test 5: File previewer
    local prev_lines, total, is_bin = Engine.get_file_preview("bin/fbr.lua", 10)
    assert_eq("get_file_preview returns table", type(prev_lines), "table")
    assert_eq("fbr.lua is not binary", is_bin, false)
    assert_eq("total lines > 0", total > 0, true)

    -- Directory preview safety test (reproducing and preventing Linux EISDIR crash)
    local dir_lines, dir_total, dir_bin = Engine.get_file_preview("bin", 10)
    assert_eq("get_file_preview on directory returns table", type(dir_lines), "table")
    assert_eq("get_file_preview on directory has directory message", dir_lines[1]:find("Directory") ~= nil, true)
    assert_eq("get_file_preview on directory is not binary", dir_bin, false)

    local non_lines, _, _ = Engine.get_file_preview("nonexistent_path_xyz", 10)
    assert_eq("get_file_preview on nonexistent file handles gracefully", type(non_lines), "table")

    -- Test 6: Editor resolution
    local ed = Engine.get_editor_cmd()
    assert_eq("get_editor_cmd returns non-empty string", #ed > 0, true)

    -- Test 7: Terminal width bounds
    local function utf8_vis(s)
        local plain = s:gsub("\27%[[%d;]*[a-zA-Z]", ""):gsub("\27%[[%?%d]*[a-zA-Z]", "")
        local len = 0
        for i = 1, #plain do
            local b = plain:byte(i)
            if b < 0x80 or b >= 0xC0 then len = len + 1 end
        end
        return len
    end

    for _, c_w in ipairs({ 80, 90, 100, 120 }) do
        local l_w = math.floor(c_w * 0.48)
        if c_w < 90 then l_w = c_w - 2 end
        local r_w = math.max(0, c_w - l_w - 4)
        if c_w >= 90 then
            local test_path = "a/very/deeply/nested/path/to/some/awesome/source/file/that/might/overflow.lua"
            local meta_str = string.format("  Size: %s │ Lines: %d", format_size(1024), 50)
            local test_r_line = truncate(meta_str, math.max(4, r_w - 4))
            local test_full = string.rep("x", l_w) .. " │ " .. test_r_line
            assert_eq(string.format("cols %d right pane line strictly <= cols - 1", c_w), utf8_vis(test_full) <= c_w - 1, true)
        end
    end

    -- Test 8: Visual width and padding
    assert_eq("visible_width strips ANSI", visible_width("\27[31mhello\27[0m"), 5)
    assert_eq("visible_width counts UTF-8 correctly", visible_width("foo…bar"), 7)
    assert_eq("pad_to_width pads accurately", visible_width(pad_to_width("abc", 10)), 10)
    assert_eq("pad_to_width with ANSI", visible_width(pad_to_width("\27[32mhello\27[0m", 12)), 12)

    -- Test 9: Path truncation
    assert_eq("truncate_path short unchanged", truncate_path("test.py", 15), "test.py")
    assert_eq("truncate_path long fits width", visible_width(truncate_path("long/path/to/some/script.py", 12)), 12)

    -- Test 10: Syntax highlighting
    local py_hl = highlight_syntax("def main(self):", "py")
    assert_eq("highlight_syntax highlights python keyword", py_hl:find("def") ~= nil and py_hl:find("\27%[") ~= nil, true)
    local py_comm = highlight_syntax("# A comment", "py")
    assert_eq("highlight_syntax highlights python comment", py_comm:find("\27%[90m") ~= nil, true)

    -- Test 11: Lazy file size and git info
    local test_item = { path = "bin/fe.lua" }
    local sz1 = Engine.get_file_size(test_item)
    assert_eq("get_file_size returns positive integer", sz1 > 0, true)
    assert_eq("get_file_size caches size on item table", test_item.size == sz1, true)
    local git_inf = Engine.get_git_info()
    assert_eq("get_git_info returns table with is_git", type(git_inf.is_git), "boolean")
    assert_eq("get_git_info returns repo_name", type(git_inf.repo_name), "string")
    -- Test 12: Delete word helper
    assert_eq("delete_word removes trailing file name", delete_word("bin/fe.lua"), "bin/")
    assert_eq("delete_word removes trailing slash and directory", delete_word("bin/"), "")
    assert_eq("delete_word removes trailing word with space", delete_word("foo bar"), "foo ")
    assert_eq("delete_word with trailing spaces", delete_word("foo bar   "), "foo ")
    assert_eq("delete_word empty string", delete_word(""), "")

    print(string.format("\nSelf-test summary: %d passed, %d failed.", passed, failed))
    if failed > 0 then os.exit(1) end
end

local function show_help()
    print([[
fe.lua - Ultra-Fast Fuzzy File Finder & Multi-Tab Editor Launcher

Usage:
  luajit fe.lua [OPTIONS] [QUERY]
  fe [OPTIONS] [QUERY]

Options:
  -g, --git            Start on [Git Changes] tab
  -r, --recent         Start on [Recent] files tab
  -a, --all            Include hidden files
  -l, --list           Print matching files to stdout and exit
  -p, --preview <FILE> Print rich file preview card to stdout and exit
  --test               Run built-in automated self-tests and exit
  -h, --help           Show this help message

Interactive Controls:
  j / k, Up / Down, ^N / ^P   Move cursor down / up (also ^N / ^P in filter)
  ^d / ^u                     Half-page scroll down / up
  ^f / ^b, PgDn / PgUp        Full-page scroll down / up
  H / M / L                   Jump to High (top), Middle, Low of visible screen
  g / G, Home / End           Jump to first / last file (or gg)
  zz / zt / zb                Center / Top / Bottom align cursor in view
  ^e / ^y                     Scroll file preview pane down / up
  h / l, Left / Right         Switch context tabs ([All Files], [Git Changes], [Recent])
  Tab / Space                 Toggle multi-select checkbox [x] (also in filter mode)
  Enter                       In filter: lock filter; In normal: open in editor (tabs: -p)
  o                           Open selected file(s) in vertical splits (-O)
  /                           Filter / search files (^W delete word, ^U clear)
  q / Esc                     Exit / Clear filter]])
end

--------------------------------------------------------------------------------
-- 8. Entrypoint
--------------------------------------------------------------------------------
local args = { ... }
local opts = {
    mode = "tui",
    start_tab = 1,
    filter = "",
    show_all = false,
}

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
        opts.mode = "list"
    elseif a == "-g" or a == "--git" then
        opts.start_tab = 2 -- Git Changes
    elseif a == "-r" or a == "--recent" then
        opts.start_tab = 3 -- Recent
    elseif a == "-a" or a == "--all" then
        opts.show_all = true
    elseif a == "-p" or a == "--preview" then
        opts.mode = "preview"
        opts.preview_file = args[i + 1]
        i = i + 1
    else
        opts.filter = a
    end
    i = i + 1
end

if opts.mode == "list" then
    local files = (opts.start_tab == 2) and Engine.load_git_files() or Engine.load_files(opts.show_all)
    for _, f in ipairs(files) do
        if #opts.filter == 0 or fuzzy_score(opts.filter, f.path) then
            print(f.path)
        end
    end
elseif opts.mode == "preview" then
    if not opts.preview_file then
        io.stderr:write("Error: --preview requires a file path argument.\n")
        os.exit(1)
    end
    local lines, total, is_bin = Engine.get_file_preview(opts.preview_file, 50)
    print(C.b_cyan .. "File: " .. C.b_white .. opts.preview_file .. C.reset)
    print(C.gray .. "Total lines: " .. total .. C.reset)
    local ext = get_extension(opts.preview_file)
    for _, l in ipairs(lines) do
        print(highlight_syntax(l, ext))
    end
else
    run_tui(opts)
end
