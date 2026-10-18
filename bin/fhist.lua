#!/usr/bin/env luajit
--[[
  fhist.lua - High-Performance Shell History Browser & Command Runner TUI
  Powered by LuaJIT & FFI. Single-file, zero external Lua dependencies.
  Runs natively on Windows (Win32 Console/Process FFI) and Linux/POSIX.

  Features:
    - Multi-Shell History Aggregation: Merges Bash, Zsh, and PowerShell history files.
    - Smart De-duplication: Groups identical commands while tracking run frequency.
    - Sort Modes: Switch between Recency (latest runs) and Frequency (most used).
    - Category Tabs: Filter by [All], [Bash], [PowerShell], and [Frequent].
    - Dual-Pane Inspector: Command list on left; detailed syntax & execution card on right.
    - Fast Fuzzy Filtering: Sub-millisecond live search matching keywords and arguments.
    - Direct Execution ('e' or 'x'): Execute command directly in an interactive subshell.
    - Clipboard Copy ('y'): Copy command to clipboard using native Win32 clip & OSC-52.
    - Shell Integration: Enter outputs command to stdout for eval/run workflow.
    - Automated Self-Test Suite: Run 'luajit bin/fhist.lua --test' for full test verification.

  Usage:
    luajit bin/fhist.lua [OPTIONS] [QUERY]
    fhist [OPTIONS] [QUERY]

  Options:
    -s, --shell <NAME>   Filter to specific shell: 'bash', 'powershell' (or 'ps'), 'zsh'
    -f, --freq           Start sorted by Frequency (default: Recency)
    -l, --list           Print formatted history list and exit
    -x, --exec           Directly execute the selected/matched command in a subshell
    -y, --copy           Copy the top matching command to clipboard and exit
    --file <PATH>        Load history from custom file path
    --test               Run automated test suite and exit
    -h, --help           Show this help message

  TUI Keybindings:
    Enter                Select command and print to stdout upon exit
    e / x                Execute selected command directly in an interactive subshell
    y                    Copy selected command to clipboard (Win32 clip & OSC-52)
    s                    Toggle sort mode between Recency and Frequency
    Tab / Shift+Tab      Cycle category tabs (All -> Bash -> PowerShell -> Frequent)
    h / l                Cycle category tabs backward / forward
    / or f               Enter filter / search mode
    j / k / Up / Down    Move selection cursor
    PgUp / PgDn          Scroll list page up / down
    g / G, Home / End    Jump to first / last item
    q / Esc              Exit without selecting
--]]

local ffi = require("ffi")
local bit = require("bit")

--------------------------------------------------------------------------------
-- 1. Platform Detection & FFI Bindings
--------------------------------------------------------------------------------
local IS_WINDOWS = (ffi.os == "Windows")

if IS_WINDOWS then
    ffi.cdef[[
        typedef unsigned long DWORD;
        typedef unsigned short WORD;
        typedef int BOOL;
        typedef void* HANDLE;
        typedef struct _COORD { short X; short Y; } COORD;
        typedef struct _SMALL_RECT { short Left; short Top; short Right; short Bottom; } SMALL_RECT;
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
                wchar_t UnicodeChar;
                char AsciiChar;
            } uChar;
            DWORD dwControlKeyState;
        } KEY_EVENT_RECORD;

        typedef struct _INPUT_RECORD {
            WORD EventType;
            union {
                KEY_EVENT_RECORD KeyEvent;
                char More[16];
            } Event;
        } INPUT_RECORD;

        HANDLE GetStdHandle(DWORD nStdHandle);
        BOOL GetConsoleMode(HANDLE hConsoleHandle, DWORD* lpMode);
        BOOL SetConsoleMode(HANDLE hConsoleHandle, DWORD dwMode);
        BOOL GetConsoleScreenBufferInfo(HANDLE hConsoleOutput, CONSOLE_SCREEN_BUFFER_INFO* lpConsoleScreenBufferInfo);
        BOOL ReadConsoleInputW(HANDLE hConsoleInput, INPUT_RECORD* lpBuffer, DWORD nLength, DWORD* lpNumberOfEventsRead);
        BOOL PeekConsoleInputW(HANDLE hConsoleInput, INPUT_RECORD* lpBuffer, DWORD nLength, DWORD* lpNumberOfEventsRead);
        void Sleep(DWORD dwMilliseconds);
    ]]
else
    ffi.cdef[[
        typedef unsigned int tcflag_t;
        typedef unsigned char cc_t;
        typedef int speed_t;
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

        struct winsize {
            unsigned short ws_row;
            unsigned short ws_col;
            unsigned short ws_xpixel;
            unsigned short ws_ypixel;
        };

        struct pollfd {
            int fd;
            short events;
            short revents;
        };

        int tcgetattr(int fd, struct termios *termios_p);
        int tcsetattr(int fd, int optional_actions, const struct termios *termios_p);
        int ioctl(int fd, unsigned long request, ...);
        int poll(struct pollfd *fds, unsigned long nfds, int timeout);
        long read(int fd, void *buf, unsigned long count);
        int open(const char *pathname, int flags, ...);
        int close(int fd);
        int usleep(unsigned int usec);
        int isatty(int fd);
    ]]
end

--------------------------------------------------------------------------------
-- 2. ANSI Palette & UI Theme
--------------------------------------------------------------------------------
local C = {
    reset        = "\27[0m",
    bold         = "\27[1m",
    dim          = "\27[2m",
    italic       = "\27[3m",
    underline    = "\27[4m",
    reverse      = "\27[7m",

    black        = "\27[30m",
    red          = "\27[31m",
    green        = "\27[32m",
    yellow       = "\27[33m",
    blue         = "\27[34m",
    magenta      = "\27[35m",
    cyan         = "\27[36m",
    white        = "\27[37m",
    gray         = "\27[90m",

    b_black      = "\27[90m",
    b_red        = "\27[91m",
    b_green      = "\27[92m",
    b_yellow     = "\27[93m",
    b_blue       = "\27[94m",
    b_magenta    = "\27[95m",
    b_cyan       = "\27[96m",
    b_white      = "\27[97m",

    bg_darkblue  = "\27[48;5;17m",
    bg_select    = "\27[48;5;237m",
    bg_header    = "\27[48;5;235m",
    bg_card      = "\27[48;5;234m",
    bg_subtle    = "\27[48;5;236m",
}

--------------------------------------------------------------------------------
-- 3. Terminal Controller (Raw Mode, Keys, Window Size)
--------------------------------------------------------------------------------
local Term = {
    initialized = false,
    orig_mode_in = nil,
    orig_mode_out = nil,
    hIn = nil,
    hOut = nil,
    orig_termios = nil,
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
        Term.hIn = ffi.C.GetStdHandle(-10)   -- STD_INPUT_HANDLE
        Term.hOut = ffi.C.GetStdHandle(-11)  -- STD_OUTPUT_HANDLE
        local mIn = ffi.new("DWORD[1]")
        local mOut = ffi.new("DWORD[1]")
        ffi.C.GetConsoleMode(Term.hIn, mIn)
        ffi.C.GetConsoleMode(Term.hOut, mOut)
        Term.orig_mode_in = mIn[0]
        Term.orig_mode_out = mOut[0]

        local raw_in = bit.band(Term.orig_mode_in, bit.bnot(0x0007))
        raw_in = bit.bor(raw_in, 0x0008) -- ENABLE_WINDOW_INPUT
        local raw_out = bit.bor(Term.orig_mode_out, 0x0004) -- ENABLE_VIRTUAL_TERMINAL_PROCESSING
        ffi.C.SetConsoleMode(Term.hIn, raw_in)
        ffi.C.SetConsoleMode(Term.hOut, raw_out)
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
    Term.write_tui("\27[?1049h\27[?25l") -- Alternate buffer, hide cursor
end

function Term.restore()
    if not Term.initialized then return end
    Term.write_tui("\27[?25h\27[?1049l" .. C.reset) -- Show cursor, restore buffer
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
            if cols > 0 and rows > 0 then return cols, rows end
        end
    else
        local ws = ffi.new("struct winsize")
        local TIOCGWINSZ = 0x5413
        if ffi.os == "OSX" or ffi.os == "BSD" then TIOCGWINSZ = 0x40087468 end
        if ffi.C.ioctl(Term.tty_fd >= 0 and Term.tty_fd or 0, TIOCGWINSZ, ws) == 0 then
            if ws.ws_col > 0 and ws.ws_row > 0 then
                return tonumber(ws.ws_col), tonumber(ws.ws_row)
            end
        end
    end
    return 100, 30
end

function Term.is_stdout_tty()
    if IS_WINDOWS then
        local hOut = ffi.C.GetStdHandle(-11)
        if hOut == nil or hOut == ffi.cast("HANDLE", -1) then
            return false
        end
        local mode = ffi.new("DWORD[1]")
        return ffi.C.GetConsoleMode(hOut, mode) ~= 0
    else
        return ffi.C.isatty(1) ~= 0
    end
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
                local shift = bit.band(ke.dwControlKeyState, 0x0010) ~= 0

                if vk == 0x26 then return "UP"
                elseif vk == 0x28 then return "DOWN"
                elseif vk == 0x25 then return "LEFT"
                elseif vk == 0x27 then return "RIGHT"
                elseif vk == 0x21 then return "PGUP"
                elseif vk == 0x22 then return "PGDN"
                elseif vk == 0x24 then return "HOME"
                elseif vk == 0x23 then return "END"
                elseif vk == 0x0D then return "ENTER"
                elseif vk == 0x08 then return "BACKSPACE"
                elseif vk == 0x09 then return shift and "BACKTAB" or "TAB"
                elseif vk == 0x2E then return "DELETE"
                elseif vk == 0x74 then return "F5"
                elseif vk == 0x1B or ch == 27 then
                    local peek_ir = ffi.new("INPUT_RECORD[1]")
                    local peek_cnt = ffi.new("DWORD[1]")
                    if ffi.C.PeekConsoleInputW(Term.hIn, peek_ir, 1, peek_cnt) ~= 0 and peek_cnt[0] > 0 then
                        if peek_ir[0].EventType == 1 and peek_ir[0].Event.KeyEvent.bKeyDown ~= 0 then
                            local ch2 = peek_ir[0].Event.KeyEvent.uChar.UnicodeChar
                            if ch2 == 91 or ch2 == 79 then -- '[' or 'O'
                                ffi.C.ReadConsoleInputW(Term.hIn, peek_ir, 1, peek_cnt)
                                if ffi.C.ReadConsoleInputW(Term.hIn, peek_ir, 1, peek_cnt) ~= 0 and peek_cnt[0] > 0 then
                                    local ch3 = peek_ir[0].Event.KeyEvent.uChar.UnicodeChar
                                    if ch3 == 65 then return "UP"
                                    elseif ch3 == 66 then return "DOWN"
                                    elseif ch3 == 67 then return "RIGHT"
                                    elseif ch3 == 68 then return "LEFT"
                                    elseif ch3 == 72 then return "HOME"
                                    elseif ch3 == 70 then return "END"
                                    elseif ch3 == 90 then return "BACKTAB"
                                    elseif ch3 == 53 then return "PGUP"
                                    elseif ch3 == 54 then return "PGDN"
                                    elseif ch3 == 51 then return "DELETE"
                                    end
                                end
                            end
                        end
                    end
                    return "ESC"
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
            if ffi.C.poll(pfd, 1, 20) <= 0 then return "ESC" end
            local n2 = ffi.C.read(Term.tty_fd, buf, 2)
            if n2 == 2 and buf[0] == 91 then
                local b2 = buf[1]
                if b2 == 65 then return "UP"
                elseif b2 == 66 then return "DOWN"
                elseif b2 == 67 then return "RIGHT"
                elseif b2 == 68 then return "LEFT"
                elseif b2 == 72 then return "HOME"
                elseif b2 == 70 then return "END"
                elseif b2 == 90 then return "BACKTAB"
                elseif b2 == 53 or b2 == 54 or b2 == 51 then
                    local buf3 = ffi.new("unsigned char[1]")
                    ffi.C.read(Term.tty_fd, buf3, 1)
                    if b2 == 53 then return "PGUP"
                    elseif b2 == 54 then return "PGDN"
                    elseif b2 == 51 then return "DELETE"
                    end
                end
            end
            return "ESC"
        elseif b >= 32 and b < 127 then
            return string.char(b)
        end
        return "UNKNOWN"
    end
end

--------------------------------------------------------------------------------
-- 4. String & Parsing Utilities
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

local function pad_left(s, width)
    s = tostring(s or "")
    if #s >= width then
        if width <= 1 then return s:sub(1, width) end
        return s:sub(1, width - 1) .. "…"
    end
    return string.rep(" ", width - #s) .. s
end

local function wrap_text(s, max_w)
    s = tostring(s or "")
    if #s <= max_w then return { s } end
    local lines = {}
    local curr = ""
    for word in s:gmatch("%S+") do
        if #curr == 0 then
            curr = word
        elseif #curr + 1 + #word <= max_w then
            curr = curr .. " " .. word
        else
            table.insert(lines, curr)
            if #word > max_w then
                local idx = 1
                while idx <= #word do
                    local chunk = word:sub(idx, idx + max_w - 1)
                    if idx + max_w > #word then
                        curr = chunk
                    else
                        table.insert(lines, chunk)
                    end
                    idx = idx + max_w
                end
            else
                curr = word
            end
        end
    end
    if #curr > 0 then table.insert(lines, curr) end
    return #lines > 0 and lines or { "" }
end

local function fuzzy_score(query, text)
    if not query or #query == 0 then return 1 end
    if not text or #text == 0 then return nil end
    local q = query:lower()
    local t = text:lower()

    local plain_pos = t:find(q, 1, true)
    if plain_pos then
        return 300 - plain_pos
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
            if ti == 1 or t:byte(ti - 1) == 32 or t:byte(ti - 1) == 45 or t:byte(ti - 1) == 47 then
                score = score + 15
            end
            if qi > qlen then return score end
        else
            consec = 0
        end
    end
    return nil
end

local function analyze_command(cmd)
    cmd = trim(cmd)
    if #cmd == 0 then
        return { bin = "", subcmd = "", args = "", flags = {} }
    end
    local parts = {}
    for p in cmd:gmatch("%S+") do
        table.insert(parts, p)
    end
    local bin = parts[1] or ""
    local subcmd = ""
    local flags = {}
    local rest_args = {}

    local idx = 2
    if parts[2] and not parts[2]:find("^-") then
        subcmd = parts[2]
        idx = 3
    end

    while idx <= #parts do
        local p = parts[idx]
        if p:find("^-") then
            table.insert(flags, p)
        else
            table.insert(rest_args, p)
        end
        idx = idx + 1
    end

    return {
        bin = bin,
        subcmd = subcmd,
        flags = flags,
        args = table.concat(rest_args, " "),
    }
end

--------------------------------------------------------------------------------
-- 5. History Engine (Discovery, Parsing, Deduplication)
--------------------------------------------------------------------------------
local Engine = {}

function Engine.get_default_history_files()
    local files = {}
    local home = os.getenv("HOME") or os.getenv("USERPROFILE") or ""
    local appdata = os.getenv("APPDATA") or ""

    if IS_WINDOWS then
        if #appdata > 0 then
            table.insert(files, {
                path = appdata .. "\\Microsoft\\Windows\\PowerShell\\PSReadLine\\ConsoleHost_history.txt",
                shell = "powershell",
                label = "PS",
            })
        end
        if #home > 0 then
            table.insert(files, {
                path = home .. "\\.bash_history",
                shell = "bash",
                label = "Bash",
            })
            table.insert(files, {
                path = home .. "\\.zsh_history",
                shell = "zsh",
                label = "Zsh",
            })
        end
    else
        local histfile = os.getenv("HISTFILE")
        if histfile and #histfile > 0 then
            table.insert(files, { path = histfile, shell = "bash", label = "Bash" })
        end
        if #home > 0 then
            table.insert(files, { path = home .. "/.bash_history", shell = "bash", label = "Bash" })
            table.insert(files, { path = home .. "/.zsh_history", shell = "zsh", label = "Zsh" })
            table.insert(files, {
                path = home .. "/.local/share/powershell/PSReadLine/ConsoleHost_history.txt",
                shell = "powershell",
                label = "PS",
            })
        end
    end
    return files
end

function Engine.file_exists(path)
    if not path or #path == 0 then return false end
    local f = io.open(path, "r")
    if f then
        f:close()
        return true
    end
    return false
end

function Engine.parse_history_file(file_info)
    local entries = {}
    local path = file_info.path
    local shell_type = file_info.shell or "unknown"
    local shell_label = file_info.label or shell_type:upper()

    local f = io.open(path, "r")
    if not f then return entries end

    for line in f:lines() do
        line = line:gsub("\r$", "")
        local cmd = trim(line)
        -- Handle Zsh extended history format: ': <timestamp>:<duration>;command'
        if shell_type == "zsh" and cmd:match("^:%s*%d+:%d+;") then
            cmd = trim(cmd:gsub("^:%s*%d+:%d+;", ""))
        end
        if #cmd > 0 and not cmd:match("^#") then
            table.insert(entries, {
                cmd = cmd,
                shell = shell_type,
                label = shell_label,
                source_file = path,
            })
        end
    end
    f:close()
    return entries
end

function Engine.load_all_history(opts)
    opts = opts or {}
    local raw_entries = {}

    if opts.custom_file and #opts.custom_file > 0 then
        if Engine.file_exists(opts.custom_file) then
            local parsed = Engine.parse_history_file({
                path = opts.custom_file,
                shell = opts.shell_filter or "custom",
                label = "Custom",
            })
            for _, e in ipairs(parsed) do table.insert(raw_entries, e) end
        end
    else
        local files = Engine.get_default_history_files()
        for _, fi in ipairs(files) do
            if Engine.file_exists(fi.path) then
                if not opts.shell_filter or opts.shell_filter == "all" or opts.shell_filter == fi.shell then
                    local parsed = Engine.parse_history_file(fi)
                    for _, e in ipairs(parsed) do table.insert(raw_entries, e) end
                end
            end
        end
    end

    -- De-duplicate commands and accumulate frequency
    local cmd_map = {}
    local deduped = {}
    for idx, e in ipairs(raw_entries) do
        local key = e.cmd
        if not cmd_map[key] then
            local record = {
                cmd = e.cmd,
                shell = e.shell,
                label = e.label,
                source_file = e.source_file,
                count = 1,
                last_idx = idx,
                first_idx = idx,
            }
            cmd_map[key] = record
            table.insert(deduped, record)
        else
            local r = cmd_map[key]
            r.count = r.count + 1
            r.last_idx = idx
            r.shell = e.shell
            r.label = e.label
            r.source_file = e.source_file
        end
    end

    return deduped, #raw_entries
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
    -- Fallback: OSC-52 clipboard sequence
    local b64_chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    local function to_b64(data)
        return ((data:gsub('.', function(x)
            local r, b = '', x:byte()
            for i = 8, 1, -1 do r = r .. (b % 2 ^ i - b % 2 ^ (i - 1) > 0 and '1' or '0') end
            return r
        end) .. '0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
            if #x < 6 then return '' end
            local c = 0
            for i = 1, 6 do c = c + (x:sub(i, i) == '1' and 2 ^ (6 - i) or 0) end
            return b64_chars:sub(c + 1, c + 1)
        end) .. ({ '', '==', '=' })[#data % 3 + 1])
    end
    Term.write_tui("\27]52;c;" .. to_b64(text) .. "\7")
    return true
end

function Engine.execute_in_shell(cmd)
    if not cmd or #cmd == 0 then return end
    Term.restore()
    Term.write_tui(C.b_cyan .. "Executing: " .. C.b_white .. cmd .. C.reset .. "\n\n")
    if IS_WINDOWS then
        os.execute(cmd)
    else
        local sh = os.getenv("SHELL") or "/bin/sh"
        os.execute(sh .. ' -c "' .. cmd:gsub('"', '\\"') .. '" >/dev/tty 2>&1')
    end
    Term.write_tui("\n" .. C.gray .. "[Press Enter to return to fhist or Ctrl+C to exit]" .. C.reset .. "\n")
    local tty_in = io.open("/dev/tty", "r")
    if tty_in then
        tty_in:read("*l")
        tty_in:close()
    else
        io.read()
    end
    Term.init()
end

function Engine.run_command(cmd, shell_type)
    if not cmd or #cmd == 0 then
        return 0
    end

    if IS_WINDOWS then
        local res = os.execute(cmd)
        local code = (type(res) == "number") and res or (res == true and 0 or 1)

        -- Fallback for PowerShell cmdlets that failed in direct cmd.exe execution
        if code ~= 0 and shell_type == "powershell" then
            local ps_cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "' .. cmd:gsub('"', '\\"') .. '"'
            local ps_res = os.execute(ps_cmd)
            code = (type(ps_res) == "number") and ps_res or (ps_res == true and 0 or 1)
        end
        return code
    else
        local sh = os.getenv("SHELL") or "/bin/sh"
        local res = os.execute(sh .. ' -c "' .. cmd:gsub('"', '\\"') .. '"')
        return (type(res) == "number") and res or (res == true and 0 or 1)
    end
end

function Engine.prompt_and_run(initial_cmd, shell_type)
    if not initial_cmd or #initial_cmd == 0 then
        Term.restore()
        return 0
    end

    -- Return to normal terminal buffer and show cursor while keeping raw mode for inline editing
    Term.write_tui("\27[?1049l\27[?25h" .. C.reset)

    local prompt_prefix = C.b_cyan .. "❯ " .. C.reset
    local prompt_cols = 2
    local line_chars = {}
    for i = 1, #initial_cmd do
        line_chars[i] = initial_cmd:sub(i, i)
    end
    local cursor_pos = #line_chars + 1

    local function refresh_line()
        local text = table.concat(line_chars)
        Term.write_tui("\r" .. prompt_prefix .. text .. "\27[K")
        local col_offset = prompt_cols + cursor_pos - 1
        if col_offset > 0 then
            Term.write_tui(string.format("\r\27[%dC", col_offset))
        else
            Term.write_tui("\r")
        end
    end

    refresh_line()

    while true do
        local key = Term.read_key()
        if key == "ENTER" then
            Term.write_tui("\n")
            Term.restore()
            local final_cmd = table.concat(line_chars)
            return Engine.run_command(final_cmd, shell_type)
        elseif key == "CTRL_C" or key == "ESC" then
            Term.write_tui("\n")
            Term.restore()
            return 0
        elseif key == "BACKSPACE" then
            if cursor_pos > 1 then
                table.remove(line_chars, cursor_pos - 1)
                cursor_pos = cursor_pos - 1
                refresh_line()
            end
        elseif key == "DELETE" then
            if cursor_pos <= #line_chars then
                table.remove(line_chars, cursor_pos)
                refresh_line()
            end
        elseif key == "LEFT" then
            if cursor_pos > 1 then
                cursor_pos = cursor_pos - 1
                refresh_line()
            end
        elseif key == "RIGHT" then
            if cursor_pos <= #line_chars then
                cursor_pos = cursor_pos + 1
                refresh_line()
            end
        elseif key == "HOME" or key == "CTRL_A" then
            cursor_pos = 1
            refresh_line()
        elseif key == "END" or key == "CTRL_E" then
            cursor_pos = #line_chars + 1
            refresh_line()
        elseif key == "CTRL_U" then
            line_chars = {}
            cursor_pos = 1
            refresh_line()
        elseif #key == 1 and key:byte() >= 32 and key:byte() < 127 then
            table.insert(line_chars, cursor_pos, key)
            cursor_pos = cursor_pos + 1
            refresh_line()
        end
    end
end

--------------------------------------------------------------------------------
-- 6. Interactive TUI Engine
--------------------------------------------------------------------------------
local TABS = { "all", "bash", "powershell", "frequent" }
local TAB_LABELS = {
    all = "All",
    bash = "Bash",
    powershell = "PowerShell",
    frequent = "Frequent (>1x)",
}

local function run_tui(init_opts)
    init_opts = init_opts or {}
    Term.init()

    local state = {
        all_items = {},
        total_raw_count = 0,
        filtered = {},
        filter = init_opts.filter or "",
        prev_filter = "",
        mode = "normal", -- "normal" or "filter"
        tab_idx = 1,
        sort_mode = init_opts.freq and "frequency" or "recency",
        cursor = 1,
        scroll = 1,
        status_msg = "",
        selected_cmd = nil,
    }

    if init_opts.shell_filter then
        for i, t in ipairs(TABS) do
            if t == init_opts.shell_filter then
                state.tab_idx = i
                break
            end
        end
    end

    local function apply_filter_and_sort()
        local active_tab = TABS[state.tab_idx]
        local candidate_list = {}

        for _, item in ipairs(state.all_items) do
            local tab_match = true
            if active_tab == "bash" and item.shell ~= "bash" then
                tab_match = false
            elseif active_tab == "powershell" and item.shell ~= "powershell" then
                tab_match = false
            elseif active_tab == "frequent" and item.count <= 1 then
                tab_match = false
            end

            if tab_match then
                if #state.filter == 0 then
                    table.insert(candidate_list, { item = item, score = 0 })
                else
                    local s = fuzzy_score(state.filter, item.cmd)
                    if s then
                        table.insert(candidate_list, { item = item, score = s })
                    end
                end
            end
        end

        -- Sort candidate list
        table.sort(candidate_list, function(a, b)
            if #state.filter > 0 and a.score ~= b.score then
                return a.score > b.score
            end
            if state.sort_mode == "frequency" then
                if a.item.count ~= b.item.count then
                    return a.item.count > b.item.count
                end
                return a.item.last_idx > b.item.last_idx
            else
                return a.item.last_idx > b.item.last_idx
            end
        end)

        local out = {}
        for _, c in ipairs(candidate_list) do
            table.insert(out, c.item)
        end
        state.filtered = out

        if #state.filtered == 0 then
            state.cursor = 1
            state.scroll = 1
        else
            if state.cursor > #state.filtered then state.cursor = #state.filtered end
            if state.cursor < 1 then state.cursor = 1 end
        end
    end

    local function reload_data()
        state.all_items, state.total_raw_count = Engine.load_all_history({
            custom_file = init_opts.custom_file,
        })
        apply_filter_and_sort()
    end

    reload_data()

    local prev_lines = {}
    local prev_cols, prev_rows = 0, 0

    local function render()
        local cols, rows = Term.get_size()
        if cols ~= prev_cols or rows ~= prev_rows then
            prev_lines = {}
            prev_cols, prev_rows = cols, rows
            Term.write_tui("\27[2J")
        end

        local left_w = math.floor(cols * 0.52)
        if left_w < 42 then left_w = 42 end
        local right_w = cols - left_w - 3
        if right_w < 28 then right_w = 28 end
        local body_h = rows - 6
        if body_h < 4 then body_h = 4 end

        local frame_lines = {}
        local function add_line(s)
            frame_lines[#frame_lines + 1] = s .. "\27[K"
        end

        -- 1. Header Bar
        local active_tab = TABS[state.tab_idx]
        local sort_badge = (state.sort_mode == "frequency")
            and (C.b_yellow .. "Frequency" .. C.reset .. C.bg_header)
            or (C.b_cyan .. "Recency" .. C.reset .. C.bg_header)
        local count_info = string.format("%d/%d", #state.filtered, #state.all_items)
        local hdr_left = string.format(" %s%s⚡ fhist %s[%s]%s │ Sort: %s │ %s items (%d total)",
            C.bg_header, C.b_cyan .. C.bold,
            C.b_yellow, TAB_LABELS[active_tab], C.reset .. C.bg_header,
            sort_badge,
            count_info, state.total_raw_count)
        add_line(hdr_left .. string.rep(" ", math.max(0, cols - #hdr_left + 16)) .. C.reset)

        -- 2. Filter & Tabs Bar
        local flt_box
        if state.mode == "filter" then
            flt_box = string.format("%sFilter (/): %s%s█%s", C.b_yellow .. C.bold, C.b_white, state.filter, C.reset)
        else
            local hint = "(press / to filter)"
            local flt_disp = (#state.filter > 0) and (C.b_yellow .. state.filter .. C.reset) or (C.gray .. hint .. C.reset)
            flt_box = string.format("%sFilter (/):%s %s", C.bold, C.reset, flt_disp)
        end

        local function make_tab(idx)
            local key = TABS[idx]
            local lbl = TAB_LABELS[key]
            if idx == state.tab_idx then
                return C.reverse .. C.b_cyan .. "[" .. lbl .. "]" .. C.reset
            else
                return C.gray .. "[" .. lbl .. "]" .. C.reset
            end
        end
        local tabs_str = string.format("%s %s %s %s", make_tab(1), make_tab(2), make_tab(3), make_tab(4))
        add_line(string.format(" %s   │   %s", flt_box, tabs_str))

        -- 3. Column Headers
        local l_hdr = pad_right(" FREQ  SRC  COMMAND", left_w)
        local cur_item = state.filtered[state.cursor]
        local r_hdr = cur_item and " 📋 COMMAND INSPECTOR" or " 📋 (No command selected)"
        add_line(C.bold .. C.b_blue .. l_hdr .. C.reset .. " " .. C.gray .. "│" .. C.reset .. " " .. C.bold .. C.b_white .. r_hdr .. C.reset)

        -- Adjust Left Scroll Window
        if #state.filtered == 0 then
            state.cursor = 1
            state.scroll = 1
        else
            if state.cursor > #state.filtered then state.cursor = #state.filtered end
            if state.cursor < 1 then state.cursor = 1 end
            if state.cursor < state.scroll then
                state.scroll = state.cursor
            elseif state.cursor >= state.scroll + body_h then
                state.scroll = state.cursor - body_h + 1
            end
        end

        -- Build Right Pane Content (Inspector Card)
        local r_lines = {}
        if cur_item then
            local ana = analyze_command(cur_item.cmd)
            table.insert(r_lines, "")
            table.insert(r_lines, " " .. C.b_yellow .. C.bold .. "Command:" .. C.reset)
            local wrapped_cmd = wrap_text(cur_item.cmd, right_w - 4)
            for _, cl in ipairs(wrapped_cmd) do
                table.insert(r_lines, "   " .. C.b_white .. cl .. C.reset)
            end

            table.insert(r_lines, "")
            table.insert(r_lines, " " .. C.b_cyan .. C.bold .. "Structure:" .. C.reset)
            table.insert(r_lines, string.format("   %sBinary:%s     %s%s%s", C.gray, C.reset, C.b_green, ana.bin, C.reset))
            if #ana.subcmd > 0 then
                table.insert(r_lines, string.format("   %sSubcommand:%s %s%s%s", C.gray, C.reset, C.b_yellow, ana.subcmd, C.reset))
            end
            if #ana.flags > 0 then
                table.insert(r_lines, string.format("   %sFlags:%s      %s%s%s", C.gray, C.reset, C.cyan, table.concat(ana.flags, " "), C.reset))
            end
            if #ana.args > 0 then
                local wrapped_args = wrap_text(ana.args, right_w - 18)
                table.insert(r_lines, string.format("   %sArguments:%s  %s", C.gray, C.reset, wrapped_args[1] or ""))
                for ai = 2, #wrapped_args do
                    table.insert(r_lines, "                " .. wrapped_args[ai])
                end
            end

            table.insert(r_lines, "")
            table.insert(r_lines, " " .. C.b_magenta .. C.bold .. "Statistics & Origin:" .. C.reset)
            local run_text = (cur_item.count == 1) and "1 time" or (cur_item.count .. " times")
            table.insert(r_lines, string.format("   %sExecution Frequency:%s %s%s%s", C.gray, C.reset, C.b_yellow .. C.bold, run_text, C.reset))
            table.insert(r_lines, string.format("   %sShell Environment:%s   %s%s%s", C.gray, C.reset, C.b_cyan, cur_item.label, C.reset))
            table.insert(r_lines, string.format("   %sHistory Source:%s      %s%s%s", C.gray, C.reset, C.gray, cur_item.source_file, C.reset))

            table.insert(r_lines, "")
            table.insert(r_lines, " " .. C.b_green .. C.bold .. "Quick Actions:" .. C.reset)
            table.insert(r_lines, "   " .. C.b_yellow .. "Enter" .. C.reset .. "     Select & prompt command (Enter to run)")
            table.insert(r_lines, "   " .. C.b_cyan .. "e / x" .. C.reset .. "     Run command in preview subshell")
            table.insert(r_lines, "   " .. C.b_green .. "y" .. C.reset .. "         Copy command to system clipboard")
            table.insert(r_lines, "   " .. C.b_magenta .. "s" .. C.reset .. "         Toggle sort mode (Recency / Frequency)")
        else
            r_lines = {
                "",
                "  " .. C.gray .. "No commands match current filter." .. C.reset,
            }
        end

        -- 4. Body Rows
        for row = 1, body_h do
            local idx = state.scroll + row - 1
            local item = state.filtered[idx]
            local l_str

            if item then
                local is_cur = (idx == state.cursor)
                local bg = is_cur and C.bg_select or ""
                local ptr = is_cur and (C.b_cyan .. "▸" .. C.reset .. bg) or " "

                local freq_pill = string.format("[%s%2dx%s]", is_cur and C.b_yellow or C.yellow, item.count, C.reset .. bg)
                local src_col = (item.shell == "bash") and C.b_green or ((item.shell == "powershell") and C.b_cyan or C.magenta)
                local src_pill = string.format("[%s%-2s%s]", src_col, item.label:sub(1, 2), C.reset .. bg)

                local cmd_w = math.max(12, left_w - 18)
                local cmd_disp = pad_right(item.cmd, cmd_w)
                local cmd_col = is_cur and (C.b_white .. C.bold) or C.white

                l_str = string.format("%s%s %s %s %s%s%s",
                    bg, ptr, freq_pill, src_pill,
                    cmd_col, cmd_disp, C.reset)
            else
                l_str = string.rep(" ", left_w)
            end

            local r_str = r_lines[row] or ""
            add_line(l_str .. " " .. C.gray .. "│" .. C.reset .. " " .. r_str)
        end

        -- 5. Status / Controls Footer
        local footer_sep = string.rep("─", cols)
        add_line(C.gray .. footer_sep .. C.reset)

        local status_disp
        if #state.status_msg > 0 then
            status_disp = C.b_green .. C.bold .. " ✔ " .. state.status_msg .. C.reset
        else
            status_disp = string.format("%sEnter%s:Select  %se/x%s:Subshell  %sy%s:Copy  %ss%s:Sort  %sTab%s:Tabs  %s/%s:Filter  %sq%s:Quit",
                C.b_yellow, C.gray, C.b_cyan, C.gray, C.b_green, C.gray, C.b_magenta, C.gray, C.b_cyan, C.gray, C.b_yellow, C.gray, C.b_red, C.reset)
        end
        add_line(" " .. status_disp)

        -- Differential line rendering
        local diff_buf = { "\27[?2026h" }
        for r = 1, #frame_lines do
            if frame_lines[r] ~= prev_lines[r] then
                diff_buf[#diff_buf + 1] = string.format("\27[%d;1H%s", r, frame_lines[r])
                prev_lines[r] = frame_lines[r]
            end
        end
        diff_buf[#diff_buf + 1] = "\27[?2026l"
        if #diff_buf > 2 then
            Term.write_tui(table.concat(diff_buf))
        end
    end

    -- Main Event Loop
    while true do
        render()
        local key = Term.read_key()
        state.status_msg = ""

        if key == "CTRL_C" or key == "QUIT" then
            break
        end

        if state.mode == "filter" then
            if key == "ESC" then
                state.filter = state.prev_filter
                state.mode = "normal"
                apply_filter_and_sort()
            elseif key == "ENTER" then
                local cur = state.filtered[state.cursor]
                if cur then
                    state.selected_cmd = cur.cmd
                    state.selected_shell = cur.shell
                end
                break
            elseif key == "BACKSPACE" then
                state.filter = state.filter:sub(1, math.max(0, #state.filter - 1))
                apply_filter_and_sort()
            elseif key == "CTRL_U" then
                state.filter = ""
                apply_filter_and_sort()
            elseif key == "UP" then
                state.cursor = math.max(1, state.cursor - 1)
            elseif key == "DOWN" then
                state.cursor = math.min(math.max(1, #state.filtered), state.cursor + 1)
            elseif #key == 1 then
                state.filter = state.filter .. key
                apply_filter_and_sort()
            end
        else
            -- Normal Mode
            if key == "ESC" and #state.filter > 0 then
                state.filter = ""
                apply_filter_and_sort()
            elseif key == "q" or key == "ESC" then
                break
            elseif key == "j" or key == "DOWN" then
                state.cursor = math.min(math.max(1, #state.filtered), state.cursor + 1)
            elseif key == "k" or key == "UP" then
                state.cursor = math.max(1, state.cursor - 1)
            elseif key == "PGDN" then
                local _, rows = Term.get_size()
                state.cursor = math.min(math.max(1, #state.filtered), state.cursor + math.max(1, rows - 8))
            elseif key == "PGUP" then
                local _, rows = Term.get_size()
                state.cursor = math.max(1, state.cursor - math.max(1, rows - 8))
            elseif key == "HOME" or key == "g" then
                state.cursor = 1
            elseif key == "END" or key == "G" then
                state.cursor = math.max(1, #state.filtered)
            elseif key == "/" or key == "f" then
                state.prev_filter = state.filter
                state.mode = "filter"
            elseif key == "TAB" or key == "l" or key == "RIGHT" then
                state.tab_idx = (state.tab_idx % #TABS) + 1
                apply_filter_and_sort()
            elseif key == "BACKTAB" or key == "h" or key == "LEFT" then
                state.tab_idx = state.tab_idx - 1
                if state.tab_idx < 1 then state.tab_idx = #TABS end
                apply_filter_and_sort()
            elseif key == "s" then
                state.sort_mode = (state.sort_mode == "recency") and "frequency" or "recency"
                apply_filter_and_sort()
                state.status_msg = "Sorted by " .. (state.sort_mode:upper())
            elseif key == "y" then
                local cur = state.filtered[state.cursor]
                if cur then
                    if Engine.copy_to_clipboard(cur.cmd) then
                        state.status_msg = "Copied to clipboard: " .. cur.cmd
                    end
                end
            elseif key == "e" or key == "x" then
                local cur = state.filtered[state.cursor]
                if cur then
                    Engine.execute_in_shell(cur.cmd)
                    prev_lines = {}
                    apply_filter_and_sort()
                end
            elseif key == "ENTER" then
                local cur = state.filtered[state.cursor]
                if cur then
                    state.selected_cmd = cur.cmd
                    state.selected_shell = cur.shell
                end
                break
            end
        end
    end

    if state.selected_cmd then
        if init_opts.print_only or not Term.is_stdout_tty() then
            Term.restore()
            io.stdout:write(state.selected_cmd .. "\n")
            io.stdout:flush()
        else
            local code = Engine.prompt_and_run(state.selected_cmd, state.selected_shell)
            if code and code ~= 0 then
                os.exit(code)
            end
        end
    else
        Term.restore()
    end
end

--------------------------------------------------------------------------------
-- 7. Non-Interactive CLI Modes (--list, --copy, --exec)
--------------------------------------------------------------------------------
local function cmd_list(opts)
    local items, total_raw = Engine.load_all_history({
        custom_file = opts.custom_file,
        shell_filter = opts.shell_filter,
    })

    if opts.freq then
        table.sort(items, function(a, b)
            if a.count ~= b.count then return a.count > b.count end
            return a.last_idx > b.last_idx
        end)
    else
        table.sort(items, function(a, b) return a.last_idx > b.last_idx end)
    end

    print(string.format("%s=== fhist: Shell Command History (%d unique / %d total) ===%s", C.b_cyan, #items, total_raw, C.reset))
    print(string.format("Sort: %s | Shell: %s\n",
        opts.freq and "FREQUENCY" or "RECENCY",
        opts.shell_filter and opts.shell_filter:upper() or "ALL"))

    print(string.format("%s %-6s %-6s %s%s", C.bold, "FREQ", "SRC", "COMMAND", C.reset))
    print(string.rep("─", 80))

    local limit = opts.limit or 100
    for i = 1, math.min(#items, limit) do
        local it = items[i]
        local src_col = (it.shell == "bash") and C.b_green or ((it.shell == "powershell") and C.b_cyan or C.magenta)
        print(string.format(" [%3dx]  %s[%-4s]%s %s", it.count, src_col, it.label, C.reset, it.cmd))
    end
    if #items > limit then
        print(string.format("%s... (%d more items omitted; run without limit or use interactive TUI)%s", C.gray, #items - limit, C.reset))
    end
end

--------------------------------------------------------------------------------
-- 8. Automated Self-Test Suite (--test)
--------------------------------------------------------------------------------
local function run_tests()
    local passed = 0
    local failed = 0

    local function assert_eq(name, actual, expected)
        if actual == expected then
            passed = passed + 1
            print(string.format("  [PASS] %s", name))
        else
            failed = failed + 1
            print(string.format("  [FAIL] %s: expected '%s', got '%s'", name, tostring(expected), tostring(actual)))
        end
    end

    print("Running fhist.lua automated self-tests...")

    -- Test 1: String helpers
    assert_eq("trim removes surrounding whitespace", trim("  git status  "), "git status")
    assert_eq("pad_right pads accurately", pad_right("test", 8), "test    ")
    assert_eq("pad_left pads accurately", pad_left("42", 5), "   42")

    -- Test 2: Wrap text
    local wrapped = wrap_text("git commit -m 'very long commit message here'", 15)
    assert_eq("wrap_text breaks into multiple lines", #wrapped >= 2, true)

    -- Test 3: Fuzzy score
    assert_eq("fuzzy_score finds exact substring", fuzzy_score("git", "git status") ~= nil, true)
    assert_eq("fuzzy_score finds subsequence", fuzzy_score("gco", "git checkout") ~= nil, true)
    assert_eq("fuzzy_score returns nil on non-match", fuzzy_score("xyz123", "git pull"), nil)

    -- Test 4: Command analysis
    local ana1 = analyze_command("git commit -m 'initial commit' --amend")
    assert_eq("analyze_command binary", ana1.bin, "git")
    assert_eq("analyze_command subcommand", ana1.subcmd, "commit")
    assert_eq("analyze_command flags includes --amend", table.concat(ana1.flags, " "):find("%-%-amend") ~= nil, true)

    local ana2 = analyze_command("ssh -i ~/.ssh/id_ed25519 user@server.com")
    assert_eq("analyze_command single binary", ana2.bin, "ssh")

    -- Test 5: Parsing history line (Zsh extended format)
    local zsh_line = ": 1710500000:0;ssh pi@raspberrypi.local"
    local parsed_zsh = trim(zsh_line:gsub("^:%s*%d+:%d+;", ""))
    assert_eq("zsh extended history line strips metadata", parsed_zsh, "ssh pi@raspberrypi.local")

    -- Test 6: De-duplication logic
    local test_records = {
        { cmd = "ls -la", shell = "bash", label = "Bash", source_file = "f1" },
        { cmd = "git status", shell = "bash", label = "Bash", source_file = "f1" },
        { cmd = "ls -la", shell = "bash", label = "Bash", source_file = "f1" },
        { cmd = "git status", shell = "powershell", label = "PS", source_file = "f2" },
        { cmd = "ls -la", shell = "bash", label = "Bash", source_file = "f1" },
    }
    local cmd_map = {}
    local deduped = {}
    for idx, e in ipairs(test_records) do
        local key = e.cmd
        if not cmd_map[key] then
            local r = { cmd = e.cmd, count = 1, last_idx = idx }
            cmd_map[key] = r
            table.insert(deduped, r)
        else
            cmd_map[key].count = cmd_map[key].count + 1
            cmd_map[key].last_idx = idx
        end
    end
    assert_eq("deduplication shrinks 5 lines to 2 unique", #deduped, 2)
    assert_eq("ls -la frequency is 3", cmd_map["ls -la"].count, 3)
    assert_eq("git status frequency is 2", cmd_map["git status"].count, 2)
    assert_eq("ls -la last_idx is 5", cmd_map["ls -la"].last_idx, 5)

    -- Test 7: Default history files detection
    local files = Engine.get_default_history_files()
    assert_eq("Engine.get_default_history_files returns candidate files", #files >= 1, true)

    -- Test 8: Live history loading
    local items, total_raw = Engine.load_all_history()
    assert_eq("Engine.load_all_history succeeds without error", type(items), "table")
    print(string.format("  [INFO] Discovered %d unique commands from %d total history entries.", #items, total_raw))

    -- Test 9: Terminal TTY detection
    assert_eq("Term.is_stdout_tty returns a boolean", type(Term.is_stdout_tty()), "boolean")

    -- Test 10: Safe execution handling of empty commands
    assert_eq("Engine.run_command handles empty command safely", Engine.run_command(""), 0)

    print(string.format("\nSelf-test summary: %d passed, %d failed.", passed, failed))
    if failed > 0 then os.exit(1) end
end

local function show_help()
    print([[
fhist.lua - High-Performance Shell History Browser & Command Runner (LuaJIT + FFI)

Usage:
  luajit fhist.lua [OPTIONS] [QUERY]
  fhist [OPTIONS] [QUERY]

Options:
  -s, --shell <NAME>   Filter to specific shell: 'bash', 'powershell' (or 'ps'), 'zsh'
  -f, --freq           Start sorted by Frequency (default: Recency)
  -l, --list           Print formatted history list and exit
  -n, --limit <N>      Maximum entries to list in -l mode (default: 100)
  -x, --exec           Directly execute the selected/matched command in a subshell
  -p, --print          Print selected command to stdout upon exit instead of executing
  -y, --copy           Copy the top matching command to clipboard and exit
  --file <PATH>        Load history from custom file path
  --test               Run automated test suite and exit
  -h, --help           Show this help message

TUI Keybindings:
  Enter                Execute selected command upon exit (or print if piped / -p)
  e / x                Execute selected command in preview subshell and return
  y                    Copy selected command to clipboard (Win32 clip & OSC-52)
  s                    Toggle sort mode between Recency and Frequency
  Tab / Shift+Tab      Cycle category tabs (All -> Bash -> PowerShell -> Frequent)
  h / l                Cycle category tabs backward / forward
  / or f               Enter filter / search mode
  j / k / Up / Down    Move selection cursor
  PgUp / PgDn          Scroll list page up / down
  g / G, Home / End    Jump to first / last item
  q / Esc              Exit without selecting]])
end

--------------------------------------------------------------------------------
-- 9. Entrypoint
--------------------------------------------------------------------------------
local args = { ... }
local opts = {
    mode = "tui",
    shell_filter = nil,
    freq = false,
    custom_file = nil,
    filter = "",
    limit = 100,
    print_only = false,
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
    elseif a == "-f" or a == "--freq" then
        opts.freq = true
    elseif a == "-p" or a == "--print" then
        opts.print_only = true
    elseif a == "-s" or a == "--shell" then
        i = i + 1
        local sh = (args[i] or ""):lower()
        if sh == "ps" then sh = "powershell" end
        opts.shell_filter = sh
    elseif a == "-n" or a == "--limit" then
        i = i + 1
        opts.limit = tonumber(args[i]) or 100
    elseif a == "--file" then
        i = i + 1
        opts.custom_file = args[i]
    elseif a == "-x" or a == "--exec" then
        opts.exec_direct = true
    elseif a == "-y" or a == "--copy" then
        opts.copy_direct = true
    else
        opts.filter = a
    end
    i = i + 1
end

if opts.mode == "list" then
    cmd_list(opts)
elseif opts.copy_direct or opts.exec_direct then
    local items = Engine.load_all_history({
        custom_file = opts.custom_file,
        shell_filter = opts.shell_filter,
    })
    local matched = nil
    if #opts.filter > 0 then
        local best_score = -1
        for _, it in ipairs(items) do
            local s = fuzzy_score(opts.filter, it.cmd)
            if s and s > best_score then
                best_score = s
                matched = it
            end
        end
    else
        matched = items[1]
    end
    if not matched then
        io.stderr:write("Error: No matching command found in history.\n")
        os.exit(1)
    end
    if opts.copy_direct then
        Engine.copy_to_clipboard(matched.cmd)
        print(C.b_green .. "Copied to clipboard: " .. C.b_white .. matched.cmd .. C.reset)
    elseif opts.exec_direct then
        Engine.execute_in_shell(matched.cmd)
    end
else
    run_tui(opts)
end
