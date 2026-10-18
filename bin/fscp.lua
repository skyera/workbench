#!/usr/bin/env luajit
--[[
  fscp.lua - Ultra-fast Cross-Platform Dual-Pane TUI & CLI Remote File Transfer Tool.
  Powered by LuaJIT & FFI. Zero external Lua dependencies.
  Runs natively on Windows (Win32 Console & Registry FFI) and Linux/POSIX.

  Modes of Operation:
    1. Dual-Pane Interactive TUI (Default):
       Midnight Commander-style dual directory browser with live multi-selection,
       in-place SSH config editing, host picker, and push/pull transfers.
    2. Headless Direct CLI:
       Directly push local files to a remote host or pull remote files
       using -H/--host, -t/--to, -u, -p, -i, -r/--rsync, -d/--dry-run.
    3. Interactive FZF Wizard (--fzf):
       Fuzzy host selector and multi-file picker pipeline for ultra-fast
       command-line workflows (also used by fpush and fpull).

  Usage:
    fscp [HOST] [REMOTE_PATH] [LOCAL_PATH]   # Launch Dual-Pane TUI (Default)
    fscp --fzf                               # Launch FZF interactive transfer
    fscp [OPTIONS] [LOCAL_FILES...]          # Headless push transfer
    fscp -P [OPTIONS]                        # Headless pull transfer
    fscp --demo                              # Launch TUI in offline demo mode
    fscp --list-hosts                        # List hosts in TSV format
    fscp --test                              # Run verification test suite

  TUI Keybindings:
    Tab             Switch active pane (Local <-> Remote)
    Up / k, Down / j Move cursor
    Enter / l / Right Drill into directory
    Backspace / h / Left Parent directory (..)
    Space           Toggle select file/folder
    a / A           Select all / Deselect all
    u / F5          Upload selected items (Local -> Remote)
    d / F5          Download selected items (Remote -> Local)
    r               Refresh active pane (or force remote re-scan)
    H               Open Host / Server Picker modal
    n               Create new SSH host entry
    e / d           Edit / Delete selected host in Host Picker
    ~               Jump to home directory
    .               Toggle hidden files/folders
    /               Inline filter current pane
    ?               Show help modal
    q / Ctrl+C      Quit
]]

local ffi = require("ffi")
local bit = require("bit")

local OS = ffi.os
local IS_WINDOWS = (OS == "Windows")
local IS_LINUX = (OS == "Linux")

--------------------------------------------------------------------------------
-- FFI Declarations
--------------------------------------------------------------------------------
if IS_WINDOWS then
    ffi.cdef[[
        typedef void* HANDLE;
        typedef void* HKEY;
        typedef unsigned long DWORD;
        typedef long LONG;
        typedef unsigned char BYTE;
        typedef int BOOL;

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

        typedef struct { DWORD dwLowDateTime; DWORD dwHighDateTime; } FILETIME;
        typedef struct { unsigned short wYear, wMonth, wDayOfWeek, wDay, wHour, wMinute, wSecond, wMilliseconds; } SYSTEMTIME;
        typedef struct {
            DWORD dwFileAttributes;
            FILETIME ftCreationTime;
            FILETIME ftLastAccessTime;
            FILETIME ftLastWriteTime;
            DWORD nFileSizeHigh;
            DWORD nFileSizeLow;
            DWORD dwReserved0;
            DWORD dwReserved1;
            char cFileName[260];
            char cAlternateFileName[14];
        } WIN32_FIND_DATAA;

        HANDLE FindFirstFileA(const char* lpFileName, WIN32_FIND_DATAA* lpFindFileData);
        BOOL FindNextFileA(HANDLE hFindFile, WIN32_FIND_DATAA* lpFindFileData);
        BOOL FindClose(HANDLE hFindFile);
        BOOL FileTimeToSystemTime(const FILETIME* lpFileTime, SYSTEMTIME* lpSystemTime);

        LONG RegOpenKeyExA(HKEY hKey, const char* lpSubKey, DWORD ulOptions, DWORD samDesired, HKEY* phkResult);
        LONG RegEnumKeyExA(HKEY hKey, DWORD dwIndex, char* lpName, DWORD* lpcchName, DWORD* lpReserved, char* lpClass, DWORD* lpcchClass, void* lpftLastWriteTime);
        LONG RegQueryValueExA(HKEY hKey, const char* lpValueName, DWORD* lpReserved, DWORD* lpType, BYTE* lpData, DWORD* lpcbData);
        LONG RegCloseKey(HKEY hKey);
        void Sleep(DWORD dwMilliseconds);
        int MultiByteToWideChar(unsigned int CodePage, DWORD dwFlags, const char* src, int len, wchar_t* dest, int capacity);
        DWORD GetLastError(void);
    ]]

    local msvcrt = ffi.load("msvcrt")
    ffi.cdef[[
        int _kbhit(void);
        int _getch(void);
        intptr_t _wspawnvp(int mode, const wchar_t *command, const wchar_t *const *argv);
        int *_errno(void);
        char *strerror(int errnum);
    ]]
    _G.msvcrt = msvcrt
else
    ffi.cdef[[
        struct termios {
            unsigned int c_iflag;
            unsigned int c_oflag;
            unsigned int c_cflag;
            unsigned int c_lflag;
            unsigned char c_line;
            unsigned char c_cc[32];
            unsigned int c_ispeed;
            unsigned int c_ospeed;
        };
        int tcgetattr(int fd, struct termios *termios_p);
        int tcsetattr(int fd, int optional_actions, const struct termios *termios_p);
        struct winsize {
            unsigned short ws_row;
            unsigned short ws_col;
            unsigned short ws_xpixel;
            unsigned short ws_ypixel;
        };
        int ioctl(int fd, unsigned long request, ...);
        int read(int fd, void *buf, size_t count);
        int isatty(int fd);
        int usleep(unsigned int usec);
        int execvp(const char *file, char *const argv[]);
    ]]
end

--------------------------------------------------------------------------------
-- ANSI Colors & Styling
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

    bright_red     = "\27[91m",
    bright_green   = "\27[92m",
    bright_yellow  = "\27[93m",
    bright_blue    = "\27[94m",
    bright_magenta = "\27[95m",
    bright_cyan    = "\27[96m",
    bright_white   = "\27[97m",

    bg_black    = "\27[40m",
    bg_blue     = "\27[44m",
    bg_cyan     = "\27[46m",
    bg_gray     = "\27[100m",
    bg_darkblue = "\27[48;5;24m",
    bg_sel      = "\27[48;5;238m",
}

-- Box drawing characters with ASCII fallback
local BOX_UNICODE = {
    tl = "┌", tr = "┐", bl = "└", br = "┘",
    h = "─", v = "│", vl = "├", vr = "┤",
    tt = "┬", tb = "┴", x = "┼",
    arrow_r = "→", arrow_l = "←",
}

local BOX_ASCII = {
    tl = "+", tr = "+", bl = "+", br = "+",
    h = "-", v = "|", vl = "+", vr = "+",
    tt = "+", tb = "+", x = "+",
    arrow_r = "->", arrow_l = "<-",
}

local BOX = BOX_UNICODE

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
        Term.hErr = ffi.C.GetStdHandle(ffi.cast("DWORD", -12))

        -- Dual stream console initialization (stdout & stderr)
        if Term.hOut ~= nil and Term.hOut ~= ffi.cast("HANDLE", -1) then
            local mode = ffi.new("DWORD[1]")
            if ffi.C.GetConsoleMode(Term.hOut, mode) ~= 0 then
                Term.orig_out_mode = mode[0]
                ffi.C.SetConsoleMode(Term.hOut, bit.bor(mode[0], 0x0004)) -- ENABLE_VIRTUAL_TERMINAL_PROCESSING
            end
        end
        if Term.hErr ~= nil and Term.hErr ~= ffi.cast("HANDLE", -1) then
            local mode = ffi.new("DWORD[1]")
            if ffi.C.GetConsoleMode(Term.hErr, mode) ~= 0 then
                Term.orig_err_mode = mode[0]
                ffi.C.SetConsoleMode(Term.hErr, bit.bor(mode[0], 0x0004)) -- ENABLE_VIRTUAL_TERMINAL_PROCESSING
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
                -- Disable line input and echo input
                local raw_mode = bit.band(mode[0], bit.bnot(bit.bor(0x0002, 0x0004, 0x0008))) -- strip LINE_INPUT, ECHO, WINDOW_INPUT
                ffi.C.SetConsoleMode(Term.hIn, raw_mode)
            end
        end
    else
        Term.orig_termios = ffi.new("struct termios")
        if ffi.C.tcgetattr(0, Term.orig_termios) == 0 then
            local raw = ffi.new("struct termios")
            ffi.copy(raw, Term.orig_termios, ffi.sizeof("struct termios"))
            raw.c_lflag = bit.band(raw.c_lflag, bit.bnot(bit.bor(0x0002, 0x0008, 0x0001))) -- ICANON, ECHO, ISIG
            raw.c_cc[5] = 0 -- VMIN
            raw.c_cc[6] = 1 -- VTIME
            ffi.C.tcsetattr(0, 0, raw)
        end
    end

    -- Switch to alternate screen buffer, hide cursor, disable auto-wrap, clear screen
    io.write("\27[?1049h\27[?25l\27[?7l\27[2J\27[H")
    io.flush()
    Term.is_raw = true
end

function Term.restore()
    if not Term.is_raw then return end
    -- Show cursor, re-enable auto-wrap, switch back from alternate screen buffer
    io.write("\27[?7h\27[?1049l\27[?25h\27[0m")
    io.flush()

    if IS_WINDOWS then
        if Term.orig_in_mode and Term.hIn ~= nil and Term.hIn ~= ffi.cast("HANDLE", -1) then
            ffi.C.SetConsoleMode(Term.hIn, Term.orig_in_mode)
        end
        if Term.orig_out_mode and Term.hOut ~= nil and Term.hOut ~= ffi.cast("HANDLE", -1) then
            ffi.C.SetConsoleMode(Term.hOut, Term.orig_out_mode)
        end
        if Term.orig_err_mode and Term.hErr ~= nil and Term.hErr ~= ffi.cast("HANDLE", -1) then
            ffi.C.SetConsoleMode(Term.hErr, Term.orig_err_mode)
        end
    else
        if Term.orig_termios then
            ffi.C.tcsetattr(0, 0, Term.orig_termios)
        end
    end
    Term.is_raw = false
end

function Term.get_size()
    local cols, rows = 100, 30
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

    if cols < 60 then cols = 60 end
    if rows < 15 then rows = 15 end
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
            elseif ch2 == 63 then return "f5"
            else return "unknown_ext_" .. ch2 end
        elseif ch == 13 or ch == 10 then
            return "enter"
        elseif ch == 9 then
            return "tab"
        elseif ch == 8 or ch == 127 then
            return "backspace"
        elseif ch == 32 then
            return "space"
        elseif ch == 27 then
            -- Check if another char follows (escape sequence) with short wait buffer
            local timeout = 0
            while m._kbhit() == 0 and timeout < 8 do
                ffi.C.Sleep(2)
                timeout = timeout + 1
            end
            if m._kbhit() ~= 0 then
                local next_ch = m._getch()
                if next_ch == 91 then -- '['
                    timeout = 0
                    while m._kbhit() == 0 and timeout < 8 do
                        ffi.C.Sleep(2)
                        timeout = timeout + 1
                    end
                    if m._kbhit() ~= 0 then
                        local code = m._getch()
                        if code == 65 then return "up"
                        elseif code == 66 then return "down"
                        elseif code == 67 then return "right"
                        elseif code == 68 then return "left"
                        elseif code == 72 then return "home"
                        elseif code == 70 then return "end"
                        end
                    end
                end
            end
            return "esc"
        elseif ch == 3 then
            return "ctrl_c"
        elseif ch == 4 then
            return "ctrl_d"
        elseif ch == 5 then
            return "ctrl_e"
        elseif ch == 14 then
            return "ctrl_n"
        elseif ch == 19 then
            return "ctrl_s"
        else
            return string.char(ch)
        end
    else
        local buf = ffi.new("char[16]")
        local n = ffi.C.read(0, buf, 16)
        if n <= 0 then return nil end
        local ch = buf[0]
        if ch == 27 then
            if n == 1 then return "esc" end
            if buf[1] == 91 then -- '['
                local code = buf[2]
                if code == 65 then return "up"
                elseif code == 66 then return "down"
                elseif code == 67 then return "right"
                elseif code == 68 then return "left"
                elseif code == 72 then return "home"
                elseif code == 70 then return "end"
                elseif code == 49 and buf[3] == 53 and buf[4] == 126 then return "f5" -- [15~
                elseif code == 53 and buf[3] == 126 then return "pageup" -- [5~
                elseif code == 54 and buf[3] == 126 then return "pagedown" -- [6~
                elseif code == 51 and buf[3] == 126 then return "delete" -- [3~
                end
            end
            return "esc"
        elseif ch == 10 or ch == 13 then
            return "enter"
        elseif ch == 9 then
            return "tab"
        elseif ch == 127 or ch == 8 then
            return "backspace"
        elseif ch == 32 then
            return "space"
        elseif ch == 3 then
            return "ctrl_c"
        elseif ch == 4 then
            return "ctrl_d"
        elseif ch == 5 then
            return "ctrl_e"
        elseif ch == 14 then
            return "ctrl_n"
        elseif ch == 19 then
            return "ctrl_s"
        else
            return string.char(ch)
        end
    end
end

--------------------------------------------------------------------------------
-- Helpers & Formatters
--------------------------------------------------------------------------------
local function get_home_dir()
    return os.getenv("HOME") or os.getenv("USERPROFILE") or "."
end

local function file_exists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

local function trim(s)
    if not s then return "" end
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

local function normalize_path(p)
    if not p or p == "" then return "." end
    p = p:gsub("\\", "/")
    p = p:gsub("/+", "/")
    if p:len() > 1 and p:sub(-1) == "/" and not p:match("^%a:/$") then
        p = p:sub(1, -2)
    end
    return p
end

local function get_parent_dir(p)
    p = normalize_path(p)
    if IS_WINDOWS and p:match("^%a:/?$") then
        return p -- at drive root
    end
    if p == "/" or p == "." or p == ".." then
        return ".."
    end
    local parent = p:match("^(.*)/[^/]+$")
    if not parent or parent == "" then
        if IS_WINDOWS and p:match("^%a:") then
            return p:sub(1, 2) .. "/"
        end
        return "/"
    end
    return parent
end

local function format_size(bytes)
    if bytes == nil or bytes < 0 then return "-" end
    if bytes < 1024 then
        return string.format("%d B", bytes)
    elseif bytes < 1024 * 1024 then
        return string.format("%.1f KB", bytes / 1024)
    elseif bytes < 1024 * 1024 * 1024 then
        return string.format("%.1f MB", bytes / (1024 * 1024))
    else
        return string.format("%.1f GB", bytes / (1024 * 1024 * 1024))
    end
end

local function pad_string(s, width, align_right)
    s = s or ""
    local len = #s
    if len > width then
        if width <= 3 then return s:sub(1, width) end
        return s:sub(1, width - 2) .. ".."
    end
    local padding = string.rep(" ", width - len)
    if align_right then
        return padding .. s
    else
        return s .. padding
    end
end

local function utf8_col_width(s)
    local clean = (s or ""):gsub("\27%[[%d;]*%a", "")
    local len = 0
    for i = 1, #clean do
        local b = clean:byte(i)
        if b < 0x80 or b >= 0xC0 then len = len + 1 end
    end
    return len
end

local function pad_ansi_box(s, width)
    local w = utf8_col_width(s)
    if w < width then return s .. string.rep(" ", width - w) else return s end
end

local function get_file_icon(name, is_dir)
    if BOX == BOX_ASCII then
        return is_dir and (C.bright_blue .. "[DIR] " .. C.reset) or "      "
    end
    if is_dir then
        if name == ".." then
            return C.bright_yellow .. "📁 " .. C.reset
        else
            return C.bright_blue .. "📁 " .. C.reset
        end
    end
    local ext = (name:match("%.([%w_%-]+)$") or ""):lower()
    if ext == "lua" then return C.bright_cyan .. "🌙 " .. C.reset
    elseif ext == "py" or ext == "pyw" then return C.bright_yellow .. "🐍 " .. C.reset
    elseif ext == "sh" or ext == "bat" or ext == "cmd" or ext == "ps1" then return C.bright_green .. "⚡ " .. C.reset
    elseif ext == "md" or ext == "txt" or ext == "doc" or ext == "pdf" then return C.bright_white .. "📝 " .. C.reset
    elseif ext == "json" or ext == "yaml" or ext == "yml" or ext == "toml" or ext == "conf" or ext == "ini" or ext == "sql" then return C.bright_yellow .. "⚙  " .. C.reset
    elseif ext == "zip" or ext == "tar" or ext == "gz" or ext == "7z" or ext == "rar" or ext == "xz" then return C.bright_red .. "📦 " .. C.reset
    elseif ext == "png" or ext == "jpg" or ext == "jpeg" or ext == "gif" or ext == "svg" or ext == "ico" then return C.bright_magenta .. "🖼 " .. C.reset
    elseif ext == "c" or ext == "cpp" or ext == "h" or ext == "hpp" or ext == "rs" or ext == "go" or ext == "js" or ext == "ts" or ext == "html" or ext == "css" then return C.bright_blue .. "📜 " .. C.reset
    elseif ext == "exe" or ext == "dll" or ext == "so" or ext == "bin" then return C.bright_red .. "🔧 " .. C.reset
    else return C.gray .. "📄 " .. C.reset end
end

local function shell_escape(s)
    if not s:find("[^%w_%-%.%/:]") then
        return s
    end
    if IS_WINDOWS then
        return '"' .. s:gsub('"', '\\"') .. '"'
    else
        return "'" .. s:gsub("'", "'\\''") .. "'"
    end
end

local function shell_command(args)
    local escaped = {}
    for i, value in ipairs(args) do escaped[i] = shell_escape(value) end
    return table.concat(escaped, " ")
end

-- The Windows CRT joins spawn arguments into a command line. Escape quotes and
-- trailing backslashes for its argv parser, without invoking cmd.exe.
local function windows_quote_arg(value)
    return '"' .. value:gsub('(\\*)"', function(slashes)
        return slashes .. slashes .. '\\"'
    end):gsub('(\\+)$', '%1%1') .. '"'
end

local function run_transfer(args)
    if not IS_WINDOWS then return os.execute(shell_command(args)) end

    local function to_wide(value)
        local size = ffi.C.MultiByteToWideChar(65001, 8, value, #value, nil, 0)
        if size == 0 then
            return nil, string.format("Cannot encode transfer argument as UTF-16 (Windows error %d).", ffi.C.GetLastError())
        end
        local buf = ffi.new("wchar_t[?]", size + 1)
        ffi.C.MultiByteToWideChar(65001, 8, value, #value, buf, size)
        return buf
    end

    -- Transfer tools are executables. An explicit suffix prevents PATH lookup
    -- from selecting a batch script and reintroducing shell expansion.
    local executable = args[1]
    if not executable:lower():match("%.exe$") then executable = executable .. ".exe" end
    local command, err = to_wide(executable)
    if not command then return nil, err end
    local argv = ffi.new("const wchar_t *[?]", #args + 1)
    local buffers = {} -- Keep all UTF-16 strings alive until the child exits.
    for i, value in ipairs(args) do
        buffers[i], err = to_wide(windows_quote_arg(value))
        if not buffers[i] then return nil, err end
        argv[i - 1] = buffers[i]
    end
    io.flush()
    local status = tonumber(msvcrt._wspawnvp(0, command, argv)) -- _P_WAIT
    if status == -1 then
        return nil, string.format("Cannot launch %s: %s. Check that the executable is installed and on PATH.",
            executable, ffi.string(msvcrt.strerror(msvcrt._errno()[0])))
    end
    return status
end

--------------------------------------------------------------------------------
-- Directory Listing Output Parser
--------------------------------------------------------------------------------
local MONTH_NAMES = {
    Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6,
    Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12,
}

local function parse_ls_line(line)
    if not line or line == "" then
        return nil
    end

    if line:match("^total%s+%d+") or line:match("^ls:") or line:match("^__FSCP_EXIT__") then
        return nil
    end

    -- Match permissions column (including ACL '+', SELinux '.', and macOS '@')
    local perms, rest = line:match("^([%-%a][%-%a%w%+%.%@]+)%s+(.*)$")
    if not perms or not rest then
        return nil
    end

    -- Look for timestamps from the right side to avoid breaking on spaces
    -- in user or group names (e.g., Active Directory 'Domain Users').
    local before_date, date, time, name = rest:match("^(.-)%s+(%d%d%d%d%-%d%d%-%d%d)%s+([%d:]+)%s+(.*)$")
    local size = nil

    if before_date then
        size = before_date:match("(%d+)%s*$")
    else
        -- Fallback: standard POSIX 'Mon DD HH:MM' or 'Mon DD YYYY'
        before_date, date, time, name = rest:match("^(.-)%s+([A-Z][a-z][a-z]%s+%d+)%s+([%d:]+)%s+(.*)$")
        if before_date and MONTH_NAMES[date:sub(1, 3)] then
            size = before_date:match("(%d+)%s*$")
        else
            -- Fallback: European 'DD Mon HH:MM' or 'DD Mon YYYY'
            before_date, date, time, name = rest:match("^(.-)%s+(%d+%s+[A-Z][a-z][a-z])%s+([%d:]+)%s+(.*)$")
            local mon = date and date:match("[A-Z][a-z][a-z]")
            if before_date and mon and MONTH_NAMES[mon] then
                size = before_date:match("(%d+)%s*$")
            else
                return nil
            end
        end
    end

    if not name or name == "." then
        return nil
    end

    local link_target = name:match("^(.-)%s+%->%s+(.*)$")
    local clean_name = link_target or name
    local is_symlink = (perms:sub(1, 1) == "l")
    local is_dir = (perms:sub(1, 1) == "d") or is_symlink

    return {
        name = clean_name,
        is_dir = is_dir,
        size = is_dir and 0 or tonumber(size or 0),
        mtime = (date and time) and (date .. " " .. time) or "-",
    }
end

--------------------------------------------------------------------------------
-- Local Filesystem Scanner (FFI Win32 / POSIX)
--------------------------------------------------------------------------------
local function list_local_directory(dir_path)
    dir_path = normalize_path(dir_path)
    local items = {}

    if IS_WINDOWS then
        local search_pattern = dir_path .. "/*"
        local find_data = ffi.new("WIN32_FIND_DATAA")
        local hFind = ffi.C.FindFirstFileA(search_pattern, find_data)
        local st = ffi.new("SYSTEMTIME")

        if hFind ~= nil and hFind ~= ffi.cast("HANDLE", -1) then
            repeat
                local name = ffi.string(find_data.cFileName)
                if name ~= "." then
                    local is_dir = (bit.band(find_data.dwFileAttributes, 0x10) ~= 0)
                    local size = tonumber(find_data.nFileSizeHigh) * 4294967296 + tonumber(find_data.nFileSizeLow)
                    ffi.C.FileTimeToSystemTime(find_data.ftLastWriteTime, st)
                    local mtime = string.format("%04d-%02d-%02d %02d:%02d", st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute)

                    table.insert(items, {
                        name = name,
                        is_dir = is_dir,
                        size = is_dir and 0 or size,
                        mtime = mtime,
                    })
                end
            until ffi.C.FindNextFileA(hFind, find_data) == 0
            ffi.C.FindClose(hFind)
        end
    else
        local cmd = string.format("LC_ALL=C ls -la '%s' 2>/dev/null", dir_path:gsub("'", "'\\''"))
        local pipe = io.popen(cmd, "r")
        if pipe then
            for line in pipe:lines() do
                local it = parse_ls_line(line)
                if it then
                    table.insert(items, it)
                end
            end
            pipe:close()
        end
    end

    -- Ensure parent dir entry '..' is always present unless at drive/root
    local has_parent = false
    for _, it in ipairs(items) do
        if it.name == ".." then has_parent = true break end
    end
    if not has_parent and dir_path ~= "/" and not dir_path:match("^%a:/?$") then
        table.insert(items, 1, {
            name = "..",
            is_dir = true,
            size = 0,
            mtime = "-",
        })
    end

    -- Sort: '..' first, then directories alphabetically, then files alphabetically
    table.sort(items, function(a, b)
        if a.name == ".." then return true end
        if b.name == ".." then return false end
        if a.is_dir ~= b.is_dir then
            return a.is_dir -- directories first
        end
        return a.name:lower() < b.name:lower()
    end)

    return items
end

--------------------------------------------------------------------------------
-- Host Aggregation & Ad-hoc Connection Parsing
--------------------------------------------------------------------------------
local function get_ssh_target(host_cfg)
    if not host_cfg then return "" end
    if host_cfg.source == "ssh-config" then
        return host_cfg.name
    end
    local target = host_cfg.hostname or host_cfg.name or ""
    if host_cfg.user and host_cfg.user ~= "" and not target:find("@") then
        target = host_cfg.user .. "@" .. target
    end
    return target
end

local function url_decode(str)
    if not str then return "" end
    return (str:gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end))
end

local function expand_glob(pattern)
    local results = {}
    if not pattern:find("[*?]") then
        if file_exists(pattern) then
            table.insert(results, pattern)
        end
        return results
    end

    if IS_WINDOWS then
        local dir = pattern:match("^(.*)[/\\]") or "."
        local find_data = ffi.new("WIN32_FIND_DATAA")
        local hFind = ffi.C.FindFirstFileA(pattern, find_data)
        if hFind ~= nil and hFind ~= ffi.cast("HANDLE", -1) then
            repeat
                local name = ffi.string(find_data.cFileName)
                if name ~= "." and name ~= ".." then
                    table.insert(results, dir .. "/" .. name)
                end
            until ffi.C.FindNextFileA(hFind, find_data) == 0
            ffi.C.FindClose(hFind)
        end
    else
        local pipe = io.popen(string.format("ls -1d %s 2>/dev/null", pattern))
        if pipe then
            for f in pipe:lines() do
                local fname = trim(f)
                if fname ~= "" and file_exists(fname) then
                    table.insert(results, fname)
                end
            end
            pipe:close()
        end
    end
    return results
end

local function parse_host_string(str)
    if not str or str == "" then return nil end
    local s = str:gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" or s:find("^@") or s:find(":$") or s:find("@$") then return nil end
    local user, host, port = s:match("^([^@]+)@([^:]+):?(%d*)$")
    if not host then
        host, port = s:match("^([^:]+):?(%d*)$")
        user = ""
    end
    if not host or host == "" or host:find("@") then return nil end
    return {
        name = "[Direct Connect]",
        raw_input = s,
        hostname = host,
        user = user or "",
        port = (port and port ~= "") and port or "22",
        source = "custom",
        is_demo = false,
    }
end

local function save_host_to_ssh_config(alias, hostname, user, port, key, filepath)
    filepath = filepath or (get_home_dir() .. "/.ssh/config")
    local f, err = io.open(filepath, "a")
    if not f then return false, err end
    f:write(string.format("\nHost %s\n    HostName %s\n", alias, hostname))
    if user and user ~= "" then f:write(string.format("    User %s\n", user)) end
    if port and port ~= "" and port ~= "22" then f:write(string.format("    Port %s\n", port)) end
    if key and key ~= "" then f:write(string.format("    IdentityFile %s\n", key)) end
    f:close()
    return true
end

local function delete_host_from_ssh_config(target_alias, filepath)
    filepath = filepath or (get_home_dir() .. "/.ssh/config")
    if not file_exists(filepath) then return false, "Config file does not exist" end

    local f, err = io.open(filepath, "r")
    if not f then return false, err end

    local lines = {}
    for line in f:lines() do
        table.insert(lines, line)
    end
    f:close()

    local new_lines = {}
    local in_target_block = false
    local found = false
    local target_lower = target_alias:lower()

    for i = 1, #lines do
        local line = lines[i]
        local trimmed = trim(line)
        local is_comment = trimmed:match("^#")

        if not is_comment and trimmed ~= "" then
            local k, v = trimmed:match("^([%w_]+)%s*=?%s*(.*)$")
            if k and k:lower() == "host" then
                local aliases = {}
                local has_target = false
                for a in v:gmatch("%S+") do
                    if a:lower() == target_lower then
                        has_target = true
                    else
                        table.insert(aliases, a)
                    end
                end

                if has_target then
                    found = true
                    if #aliases > 0 then
                        local indent = line:match("^(%s*)") or ""
                        table.insert(new_lines, indent .. "Host " .. table.concat(aliases, " "))
                        in_target_block = false
                    else
                        in_target_block = true
                    end
                else
                    in_target_block = false
                    table.insert(new_lines, line)
                end
            elseif k and (k:lower() == "match" or k:lower() == "include") then
                in_target_block = false
                table.insert(new_lines, line)
            else
                if not in_target_block then
                    table.insert(new_lines, line)
                end
            end
        else
            if not in_target_block then
                table.insert(new_lines, line)
            end
        end
    end

    if not found then
        return false, "Host alias not found in config"
    end

    local cleaned = {}
    local prev_blank = false
    for _, l in ipairs(new_lines) do
        local is_blank = (trim(l) == "")
        if not (is_blank and prev_blank) then
            table.insert(cleaned, l)
        end
        prev_blank = is_blank
    end

    local tmp_path = filepath .. ".fscp_tmp." .. tostring(os.time())
    local out, werr = io.open(tmp_path, "w")
    if not out then return false, werr end
    for _, l in ipairs(cleaned) do
        out:write(l .. "\n")
    end
    out:close()

    local ren_ok, ren_err = os.rename(tmp_path, filepath)
    if not ren_ok then
        local rf = io.open(tmp_path, "r")
        local wf = io.open(filepath, "w")
        if rf and wf then
            wf:write(rf:read("*a"))
            rf:close()
            wf:close()
            os.remove(tmp_path)
            return true
        end
        return false, ren_err
    end
    return true
end

local function update_host_in_ssh_config(old_alias, new_alias, hostname, user, port, key, filepath)
    filepath = filepath or (get_home_dir() .. "/.ssh/config")
    if not file_exists(filepath) then
        return save_host_to_ssh_config(new_alias, hostname, user, port, key, filepath)
    end

    local f, err = io.open(filepath, "r")
    if not f then return false, err end

    local lines = {}
    for line in f:lines() do
        table.insert(lines, line)
    end
    f:close()

    local new_lines = {}
    local in_target_block = false
    local found = false
    local target_lower = old_alias:lower()

    local function emit_new_block()
        table.insert(new_lines, string.format("Host %s", new_alias))
        table.insert(new_lines, string.format("    HostName %s", hostname))
        if user and user ~= "" then
            table.insert(new_lines, string.format("    User %s", user))
        end
        if port and port ~= "" and port ~= "22" then
            table.insert(new_lines, string.format("    Port %s", port))
        end
        if key and key ~= "" then
            table.insert(new_lines, string.format("    IdentityFile %s", key))
        end
        table.insert(new_lines, "")
    end

    for i = 1, #lines do
        local line = lines[i]
        local trimmed = trim(line)
        local is_comment = trimmed:match("^#")

        if not is_comment and trimmed ~= "" then
            local k, v = trimmed:match("^([%w_]+)%s*=?%s*(.*)$")
            if k and k:lower() == "host" then
                local aliases = {}
                local has_target = false
                for a in v:gmatch("%S+") do
                    if a:lower() == target_lower then
                        has_target = true
                    else
                        table.insert(aliases, a)
                    end
                end

                if has_target then
                    found = true
                    if #aliases > 0 then
                        local indent = line:match("^(%s*)") or ""
                        table.insert(new_lines, indent .. "Host " .. table.concat(aliases, " "))
                        emit_new_block()
                        in_target_block = false
                    else
                        emit_new_block()
                        in_target_block = true
                    end
                else
                    in_target_block = false
                    table.insert(new_lines, line)
                end
            elseif k and (k:lower() == "match" or k:lower() == "include") then
                in_target_block = false
                table.insert(new_lines, line)
            else
                if not in_target_block then
                    table.insert(new_lines, line)
                end
            end
        else
            if not in_target_block then
                table.insert(new_lines, line)
            end
        end
    end

    if not found then
        return save_host_to_ssh_config(new_alias, hostname, user, port, key, filepath)
    end

    local cleaned = {}
    local prev_blank = false
    for _, l in ipairs(new_lines) do
        local is_blank = (trim(l) == "")
        if not (is_blank and prev_blank) then
            table.insert(cleaned, l)
        end
        prev_blank = is_blank
    end

    local tmp_path = filepath .. ".fscp_tmp." .. tostring(os.time())
    local out, werr = io.open(tmp_path, "w")
    if not out then return false, werr end
    for _, l in ipairs(cleaned) do
        out:write(l .. "\n")
    end
    out:close()

    local ren_ok, ren_err = os.rename(tmp_path, filepath)
    if not ren_ok then
        local rf = io.open(tmp_path, "r")
        local wf = io.open(filepath, "w")
        if rf and wf then
            wf:write(rf:read("*a"))
            rf:close()
            wf:close()
            os.remove(tmp_path)
            return true
        end
        return false, ren_err
    end
    return true
end

local function remove_from_known_hosts(hostname)
    if not hostname or hostname == "" then return false, "No hostname provided" end
    local home = get_home_dir()
    local path = home .. "/.ssh/known_hosts"
    if not file_exists(path) then return false, "known_hosts file not found" end

    pcall(function()
        os.execute(string.format("ssh-keygen -R %s >/dev/null 2>&1", shell_escape(hostname)))
    end)

    local f = io.open(path, "r")
    if not f then return true end
    local lines = {}
    local removed = false
    local q = hostname:lower()
    for line in f:lines() do
        local host_part = line:match("^(%S+)")
        local match = false
        if host_part then
            for single in host_part:gmatch("[^,]+") do
                local h = single:match("^%[(.-)%]:%d+$") or single
                if h:lower() == q then
                    match = true
                    removed = true
                    break
                end
            end
        end
        if not match then
            table.insert(lines, line)
        end
    end
    f:close()

    if removed then
        local out = io.open(path, "w")
        if out then
            for _, l in ipairs(lines) do out:write(l .. "\n") end
            out:close()
        end
    end
    return true
end

local function delete_host_entry(h)
    if not h then return false, "No host selected" end
    if h.is_demo then
        return false, "Built-in demo server cannot be deleted."
    end
    if h.is_form_launcher then
        return false, "Built-in launcher cannot be deleted."
    end

    if h.source == "ssh-config" then
        local path = h.source_file or (get_home_dir() .. "/.ssh/config")
        return delete_host_from_ssh_config(h.name, path)
    elseif h.source == "known-hosts" then
        return remove_from_known_hosts(h.hostname or h.name)
    elseif h.source == "hosts-file" then
        return false, "Host is in /etc/hosts (read-only system file). Edit with 'sudo nano /etc/hosts'."
    else
        local ok, err = delete_host_from_ssh_config(h.name, get_home_dir() .. "/.ssh/config")
        if ok then return true end
        return false, "Cannot delete host of source: " .. tostring(h.source)
    end
end

local function get_ssh_config_paths()
    local paths = {}
    local seen = {}
    local home = get_home_dir()

    local p1 = home .. "/.ssh/config"
    if file_exists(p1) and not seen[p1] then
        table.insert(paths, p1)
        seen[p1] = true
    end

    local userprofile = os.getenv("USERPROFILE")
    if userprofile then
        local p2 = userprofile:gsub("\\", "/") .. "/.ssh/config"
        if file_exists(p2) and not seen[p2] then
            table.insert(paths, p2)
            seen[p2] = true
        end
    end
    return paths
end

local function parse_ssh_config(filepath, visited)
    visited = visited or {}
    local hosts = {}
    if visited[filepath] or not file_exists(filepath) then
        return hosts
    end
    visited[filepath] = true

    local f = io.open(filepath, "r")
    if not f then return hosts end

    local current_aliases = {}
    local current_params = {}

    local function flush_block()
        if #current_aliases == 0 then return end
        local explicit_host = current_params.hostname or ""
        for _, alias in ipairs(current_aliases) do
            local entry = {
                name = alias,
                hostname = (explicit_host ~= "") and explicit_host or alias,
                user = current_params.user or "",
                port = current_params.port or "22",
                key = current_params.key or "",
                proxy = current_params.proxy or "",
                source = "ssh-config",
                source_file = filepath,
            }
            table.insert(hosts, entry)
        end
        current_aliases = {}
        current_params = {}
    end

    for line in f:lines() do
        local line_str = trim(line)
        if line_str ~= "" and not line_str:match("^#") then
            local k, v = line_str:match("^([%w_]+)%s*=?%s*(.*)$")
            if k and v then
                local key = k:lower()
                local val = trim(v):gsub('^["\']', ''):gsub('["\']$', '')

                if key == "include" then
                    flush_block()
                    for pattern in val:gmatch("%S+") do
                        local expanded = pattern:gsub("^~", get_home_dir())
                        if not expanded:match("^/") and not expanded:match("^%a:") then
                            local dir = filepath:match("^(.*)[/\\]") or (get_home_dir() .. "/.ssh")
                            expanded = dir .. "/" .. expanded
                        end
                        for _, inc_file in ipairs(expand_glob(expanded)) do
                            local sub_hosts = parse_ssh_config(inc_file, visited)
                            for _, sh in ipairs(sub_hosts) do
                                table.insert(hosts, sh)
                            end
                        end
                    end
                elseif key == "host" then
                    flush_block()
                    local valid_aliases = {}
                    for alias in val:gmatch("%S+") do
                        if not alias:find("[*?]") then
                            table.insert(valid_aliases, alias)
                        end
                    end
                    current_aliases = valid_aliases
                elseif #current_aliases > 0 then
                    if key == "hostname" then
                        current_params.hostname = val
                    elseif key == "user" then
                        current_params.user = val
                    elseif key == "port" then
                        current_params.port = val
                    elseif key == "identityfile" then
                        current_params.key = val:gsub("^~", get_home_dir())
                    elseif key == "proxyjump" then
                        current_params.proxy = val
                    end
                end
            end
        end
    end
    flush_block()
    f:close()
    return hosts
end

local function parse_known_hosts(filepath)
    local hosts = {}
    if not file_exists(filepath) then return hosts end
    local f = io.open(filepath, "r")
    if not f then return hosts end

    for line in f:lines() do
        local line_str = trim(line)
        if line_str ~= "" and not line_str:match("^#") and not line_str:match("^|1|") then
            local host_part = line_str:match("^(%S+)")
            if host_part then
                for single_host in host_part:gmatch("[^,]+") do
                    local host, port = single_host:match("^%[(.-)%]:(%d+)$")
                    if not host then
                        host = single_host
                        port = "22"
                    end
                    if host ~= "" and not host:find("[*?]") then
                        table.insert(hosts, {
                            name = host,
                            hostname = host,
                            user = "",
                            port = port,
                            key = "",
                            source = "known-hosts",
                            source_file = filepath,
                        })
                    end
                end
            end
        end
    end
    f:close()
    return hosts
end

local function parse_putty_sessions_win32()
    local hosts = {}
    if not IS_WINDOWS then return hosts end

    pcall(function()
        local HKEY_CURRENT_USER = ffi.cast("void*", 0x80000001)
        local phkResult = ffi.new("HKEY[1]")
        local subkey = "Software\\SimonTatham\\PuTTY\\Sessions"
        if ffi.C.RegOpenKeyExA(HKEY_CURRENT_USER, subkey, 0, 0x20019, phkResult) == 0 then
            local hKey = phkResult[0]
            local dwIndex = 0
            local name_buf = ffi.new("char[256]")
            local name_len = ffi.new("DWORD[1]")
            while true do
                name_len[0] = 256
                if ffi.C.RegEnumKeyExA(hKey, dwIndex, name_buf, name_len, nil, nil, nil, nil) ~= 0 then
                    break
                end
                local raw_name = ffi.string(name_buf, name_len[0])
                local decoded = url_decode(raw_name)
                if decoded ~= "Default Settings" then
                    local phkSub = ffi.new("HKEY[1]")
                    if ffi.C.RegOpenKeyExA(hKey, raw_name, 0, 0x20019, phkSub) == 0 then
                        local hSub = phkSub[0]
                        local data_buf = ffi.new("char[256]")
                        local data_len = ffi.new("DWORD[1]", 256)
                        local dword_val = ffi.new("DWORD[1]")
                        local dword_len = ffi.new("DWORD[1]", 4)

                        local r_host, r_user, r_port, r_key = "", "", "22", ""
                        if ffi.C.RegQueryValueExA(hSub, "HostName", nil, nil, ffi.cast("BYTE*", data_buf), data_len) == 0 then
                            r_host = trim(ffi.string(data_buf))
                        end
                        data_len[0] = 256
                        if ffi.C.RegQueryValueExA(hSub, "UserName", nil, nil, ffi.cast("BYTE*", data_buf), data_len) == 0 then
                            r_user = trim(ffi.string(data_buf))
                        end
                        if ffi.C.RegQueryValueExA(hSub, "PortNumber", nil, nil, ffi.cast("BYTE*", dword_val), dword_len) == 0 then
                            r_port = tostring(dword_val[0])
                        end
                        data_len[0] = 256
                        if ffi.C.RegQueryValueExA(hSub, "PublicKeyFile", nil, nil, ffi.cast("BYTE*", data_buf), data_len) == 0 then
                            r_key = trim(ffi.string(data_buf))
                        end
                        ffi.C.RegCloseKey(hSub)
                        if r_host ~= "" then
                            table.insert(hosts, {
                                name = decoded,
                                hostname = r_host,
                                user = r_user,
                                port = r_port,
                                key = r_key,
                                source = "putty",
                            })
                        end
                    end
                end
                dwIndex = dwIndex + 1
            end
            ffi.C.RegCloseKey(hKey)
        end
    end)
    return hosts
end

local function parse_hosts_file()
    local hosts = {}
    local path = IS_WINDOWS and "C:\\Windows\\System32\\drivers\\etc\\hosts" or "/etc/hosts"
    if not file_exists(path) then return hosts end
    local f = io.open(path, "r")
    if not f then return hosts end

    for line in f:lines() do
        local line_str = trim(line):gsub("^\239\187\191", "")
        if line_str ~= "" and not line_str:match("^#") then
            local ip, names = line_str:match("^(%S+)%s+(.+)$")
            if ip and not ip:match("^fe80") and not ip:match("^fe00") and not ip:match("^ff%x%x") and not ip:match("^::1") and ip ~= "127.0.0.1" and ip ~= "localhost" then
                for n in names:gmatch("%S+") do
                    if not n:match("^#") and n ~= "localhost" and not n:match("^ip6%-") then
                        table.insert(hosts, {
                            name = n,
                            hostname = ip,
                            user = "",
                            port = "22",
                            key = "",
                            source = "hosts-file",
                        })
                    end
                end
            end
        end
    end
    f:close()
    return hosts
end

local function aggregate_ssh_hosts()
    local all_hosts = {}
    local seen = {}

    local function add_host(h)
        if not h.name or h.name == "" or h.name:find("[*?]") then return end
        local key = (h.name .. "|" .. (h.hostname or "") .. "|" .. (h.port or "22")):lower()
        if not seen[key] and not seen[h.name:lower()] then
            seen[key] = true
            seen[h.name:lower()] = true
            table.insert(all_hosts, h)
        end
    end

    -- 1. SSH Config (supports Include, multiple hosts, keys)
    for _, path in ipairs(get_ssh_config_paths()) do
        for _, h in ipairs(parse_ssh_config(path)) do
            add_host(h)
        end
    end

    -- 2. Windows PuTTY sessions
    if IS_WINDOWS then
        for _, h in ipairs(parse_putty_sessions_win32()) do
            add_host(h)
        end
    end

    -- 3. Known hosts
    local home = get_home_dir()
    for _, h in ipairs(parse_known_hosts(home .. "/.ssh/known_hosts")) do
        add_host(h)
    end

    -- 4. /etc/hosts or Windows hosts file
    for _, h in ipairs(parse_hosts_file()) do
        add_host(h)
    end

    return all_hosts
end

--------------------------------------------------------------------------------
-- Remote Filesystem Scanner (SSH / Demo Engine)
--------------------------------------------------------------------------------
local DemoFS = {
    ["/"] = {
        { name = "etc", is_dir = true, size = 4096, mtime = "2026-09-01 10:00" },
        { name = "home", is_dir = true, size = 4096, mtime = "2026-09-05 12:00" },
        { name = "var", is_dir = true, size = 4096, mtime = "2026-09-10 14:00" },
        { name = "tmp", is_dir = true, size = 4096, mtime = "2026-09-13 04:00" },
    },
    ["/etc"] = {
        { name = "nginx", is_dir = true, size = 4096, mtime = "2026-09-01 10:05" },
        { name = "hosts", is_dir = false, size = 250, mtime = "2026-08-20 08:30" },
        { name = "resolv.conf", is_dir = false, size = 120, mtime = "2026-08-20 08:30" },
    },
    ["/etc/nginx"] = {
        { name = "nginx.conf", is_dir = false, size = 3200, mtime = "2026-09-01 10:10" },
        { name = "conf.d", is_dir = true, size = 4096, mtime = "2026-09-01 10:15" },
    },
    ["/home"] = {
        { name = "user", is_dir = true, size = 4096, mtime = "2026-09-05 12:05" },
    },
    ["/home/user"] = {
        { name = "app", is_dir = true, size = 4096, mtime = "2026-09-11 16:20" },
        { name = ".bashrc", is_dir = false, size = 3771, mtime = "2026-09-05 12:10" },
        { name = "README.md", is_dir = false, size = 1450, mtime = "2026-09-12 09:15" },
        { name = "config.yaml", is_dir = false, size = 890, mtime = "2026-09-12 11:30" },
    },
    ["/home/user/app"] = {
        { name = "server.js", is_dir = false, size = 18450, mtime = "2026-09-11 16:25" },
        { name = "package.json", is_dir = false, size = 1240, mtime = "2026-09-11 16:22" },
        { name = "public", is_dir = true, size = 4096, mtime = "2026-09-11 16:30" },
    },
    ["/var"] = {
        { name = "log", is_dir = true, size = 4096, mtime = "2026-09-13 01:00" },
        { name = "www", is_dir = true, size = 4096, mtime = "2026-09-10 14:05" },
    },
    ["/var/www"] = {
        { name = "html", is_dir = true, size = 4096, mtime = "2026-09-10 14:10" },
    },
    ["/var/www/html"] = {
        { name = "index.html", is_dir = false, size = 4280, mtime = "2026-09-10 14:12" },
        { name = "app.js", is_dir = false, size = 32800, mtime = "2026-09-11 15:40" },
        { name = "style.css", is_dir = false, size = 12100, mtime = "2026-09-08 11:20" },
        { name = "robots.txt", is_dir = false, size = 320, mtime = "2026-08-25 09:10" },
    },
    ["/tmp"] = {
        { name = "backup_20260912.tar.gz", is_dir = false, size = 5242880, mtime = "2026-09-12 23:00" },
        { name = "test.sql", is_dir = false, size = 45000, mtime = "2026-09-13 03:30" },
    },
}
DemoFS["~"] = DemoFS["/home/user"]
DemoFS["~/app"] = DemoFS["/home/user/app"]

local remote_cache = {}

local function list_remote_directory(host_cfg, remote_dir)
    remote_dir = normalize_path(remote_dir)
    if remote_dir == "" then remote_dir = "/" end

    -- Check in-memory cache
    local cache_key = (host_cfg.hostname or host_cfg.name) .. ":" .. remote_dir
    if remote_cache[cache_key] then
        return remote_cache[cache_key], nil
    end

    local items = {}

    -- Demo Mode Handler
    if host_cfg.is_demo or host_cfg.name == "demo" then
        local demo_list = DemoFS[remote_dir] or DemoFS["/home/user"] or {}
        for _, it in ipairs(demo_list) do
            table.insert(items, {
                name = it.name,
                is_dir = it.is_dir,
                size = it.size,
                mtime = it.mtime,
            })
        end
    else
        -- Live SSH Remote Directory Listing
        local ssh_args = {}
        if host_cfg.source ~= "ssh-config" and host_cfg.port and host_cfg.port ~= "22" and host_cfg.port ~= "" then
            table.insert(ssh_args, "-p " .. host_cfg.port)
        end
        if host_cfg.key and host_cfg.key ~= "" then
            table.insert(ssh_args, "-i " .. shell_escape(host_cfg.key))
        end
        local target = get_ssh_target(host_cfg)

        local remote_path_arg
        if remote_dir == "~" or remote_dir == "" then
            remote_path_arg = "~/"
        elseif remote_dir:sub(1, 2) == "~/" then
            local sub = remote_dir:sub(3):gsub("'", "'\\''")
            if sub:sub(-1) ~= "/" then
                sub = sub .. "/"
            end
            remote_path_arg = "~/'" .. sub .. "'"
        else
            local p = remote_dir:gsub("'", "'\\''")
            if p:sub(-1) ~= "/" then
                p = p .. "/"
            end
            remote_path_arg = "'" .. p .. "'"
        end
        local remote_sh = string.format("(LC_ALL=C ls -la --time-style=+%Y-%m-%d\\ %H:%M:%S %s); echo \"\n__FSCP_EXIT__:$?\"", remote_path_arg)
        local cmd = string.format("ssh -n -o ConnectTimeout=4 -o BatchMode=yes -o StrictHostKeyChecking=accept-new %s \"%s\" \"%s\" 2>&1",
            table.concat(ssh_args, " "),
            target,
            remote_sh:gsub('"', '\\"')
        )

        local pipe = io.popen(cmd, "r")
        if not pipe then
            return {}, "Failed to execute SSH command"
        end

        local output = pipe:read("*a")
        pipe:close()

        local exit_code = output:match("__FSCP_EXIT__:(%d+)")
        local clean_output = output:gsub("\n?__FSCP_EXIT__:%d+\n?", "")

        -- Fallback for non-GNU ls (BSD / macOS / Busybox) where --time-style is not supported
        if exit_code and exit_code ~= "0" then
            if clean_output:find("time%-style") or clean_output:find("unrecognized option") or clean_output:find("illegal option") then
                local fallback_sh = string.format("(LC_ALL=C ls -la %s); echo \"\n__FSCP_EXIT__:$?\"", remote_path_arg)
                local fallback_cmd = string.format("ssh -n -o ConnectTimeout=4 -o BatchMode=yes -o StrictHostKeyChecking=accept-new %s \"%s\" \"%s\" 2>&1",
                    table.concat(ssh_args, " "),
                    target,
                    fallback_sh:gsub('"', '\\"')
                )
                local fb_pipe = io.popen(fallback_cmd, "r")
                if fb_pipe then
                    local fb_out = fb_pipe:read("*a")
                    fb_pipe:close()
                    local fb_code = fb_out:match("__FSCP_EXIT__:(%d+)")
                    if fb_code == "0" then
                        exit_code = "0"
                        clean_output = fb_out:gsub("\n?__FSCP_EXIT__:%d+\n?", "")
                    end
                end
            end
        end

        if exit_code and exit_code ~= "0" then
            local err_line = nil
            for l in clean_output:gmatch("[^\r\n]+") do
                local trimmed = trim(l)
                if trimmed ~= "" and not trimmed:match("^Warning:") and not trimmed:match("^debug") then
                    err_line = trimmed
                    break
                end
            end
            return {}, err_line or ("SSH connection failed (exit code " .. exit_code .. ")")
        end

        for line in clean_output:gmatch("[^\r\n]+") do
            local it = parse_ls_line(line)
            if it then
                table.insert(items, it)
            end
        end
    end

    -- Add '..' if not at root
    if remote_dir ~= "/" then
        local has_parent = false
        for _, it in ipairs(items) do
            if it.name == ".." then has_parent = true break end
        end
        if not has_parent then
            table.insert(items, 1, {
                name = "..",
                is_dir = true,
                size = 0,
                mtime = "-",
            })
        end
    end

    -- Sort items: '..' first, then directories alphabetically, then files alphabetically
    table.sort(items, function(a, b)
        if a.name == ".." then return true end
        if b.name == ".." then return false end
        if a.is_dir ~= b.is_dir then
            return a.is_dir
        end
        return a.name:lower() < b.name:lower()
    end)

    remote_cache[cache_key] = items
    return items, nil
end

--------------------------------------------------------------------------------
-- Dual-Pane Application State & Engine
--------------------------------------------------------------------------------
local App = {
    running = true,
    active_pane = "left", -- "left" (local) or "right" (remote)
    term_w = 100,
    term_h = 30,
    status_msg = "Ready. Press [?] for help, [Tab] to switch panes.",
    status_color = C.gray,
    show_hidden = false, -- Default: hide hidden files/folders (.xxx)
    connected = true,
    conn_error = nil,

    -- Host config
    host_cfg = {
        name = "demo",
        hostname = "demo-server",
        user = "user",
        port = "22",
        is_demo = true,
    },

    -- Modal states
    modal = nil, -- nil, "confirm_transfer", "host_picker", "help", "filter"
    modal_data = {},

    left = {
        title = "LOCAL",
        dir = ".",
        items = {},
        cursor = 1,
        scroll_top = 1,
        selected = {},
        filter = "",
    },

    right = {
        title = "REMOTE",
        dir = "~",
        items = {},
        cursor = 1,
        scroll_top = 1,
        selected = {},
        filter = "",
    },
}

function App.refresh_left()
    App.left.items = list_local_directory(App.left.dir)
    if App.left.cursor > #App.left.items then App.left.cursor = math.max(1, #App.left.items) end
end

function App.refresh_right(force_network)
    if force_network then
        remote_cache = {}
        if not App.host_cfg.is_demo and (App.right.dir == "~" or App.right.dir == "") then
            local target = get_ssh_target(App.host_cfg)
            local ssh_args = {}
            if App.host_cfg.source ~= "ssh-config" and App.host_cfg.port and App.host_cfg.port ~= "22" and App.host_cfg.port ~= "" then
                table.insert(ssh_args, "-p " .. App.host_cfg.port)
            end
            if App.host_cfg.key and App.host_cfg.key ~= "" then
                table.insert(ssh_args, "-i " .. shell_escape(App.host_cfg.key))
            end
            local pwd_cmd = string.format("ssh -n -q -o ConnectTimeout=4 -o BatchMode=yes -o StrictHostKeyChecking=accept-new %s \"%s\" \"pwd\"",
                table.concat(ssh_args, " "), target)
            local p = io.popen(pwd_cmd, "r")
            if p then
                local real_home = p:read("*l")
                p:close()
                if real_home and real_home:match("^/[^%s]+") then
                    App.right.dir = trim(real_home)
                end
            end
        end
    end
    local items, err = list_remote_directory(App.host_cfg, App.right.dir)
    if err then
        App.connected = false
        App.conn_error = err
        App.right.items = {}
        App.right.cursor = 1
        App.status_msg = "Remote error: " .. err
        App.status_color = C.red
    else
        App.connected = true
        App.conn_error = nil
        if force_network or (not App.modal and not App.host_cfg.is_demo) then
            App.status_msg = "Connected to " .. get_ssh_target(App.host_cfg) .. ": " .. App.right.dir
            App.status_color = C.bright_green
        end
        App.right.items = items
        if App.right.cursor > #App.right.items then App.right.cursor = math.max(1, #App.right.items) end
    end
end

function App.get_filtered_items(pane)
    local filtered = {}
    local query = (pane.filter and pane.filter ~= "") and pane.filter:lower() or nil
    for _, it in ipairs(pane.items) do
        local is_hidden = (it.name:sub(1, 1) == "." and it.name ~= "..")
        if App.show_hidden or not is_hidden then
            if not query or it.name == ".." or it.name:lower():find(query, 1, true) then
                table.insert(filtered, it)
            end
        end
    end
    return filtered
end

function App.get_selected_count(pane)
    local count = 0
    local total_bytes = 0
    for _, it in ipairs(pane.items) do
        if pane.selected[it.name] and it.name ~= ".." then
            count = count + 1
            total_bytes = total_bytes + (it.size or 0)
        end
    end
    return count, total_bytes
end

--------------------------------------------------------------------------------
-- Rendering Subsystem (Double-Buffered Flicker-Free ANSI)
--------------------------------------------------------------------------------
function App.draw()
    local w, h = Term.get_size()
    App.term_w = w
    App.term_h = h

    local buf = {}
    table.insert(buf, "\27[H") -- move to top-left

    -- 1. Top Header Bar
    local target_display = get_ssh_target(App.host_cfg)
    if App.host_cfg.source ~= "ssh-config" and App.host_cfg.port and App.host_cfg.port ~= "22" then
        target_display = target_display .. ":" .. App.host_cfg.port
    end
    local host_display
    if App.host_cfg.is_demo then
        host_display = C.bright_yellow .. "[DEMO MODE: Simulated Server]" .. C.reset
    elseif App.connected then
        host_display = C.bright_green .. string.format("[Connected: %s]", target_display) .. C.reset
    else
        host_display = C.bright_red .. string.format("[Disconnected: %s]", target_display) .. C.reset
    end

    local styled_title = string.format(" %s%sFSCP-TUI v1.0%s | %s ", C.bold, C.bright_cyan, C.reset, host_display)
    local rem_len = math.max(0, w - utf8_col_width(styled_title))
    table.insert(buf, string.format("\27[1;1H%s%s%s%s\27[0m\27[K", styled_title, C.cyan, BOX.h:rep(rem_len), C.reset))

    -- 2. Pane Geometry
    local content_h = h - 5
    if content_h < 4 then content_h = 4 end

    local half_w = math.floor((w - 3) / 2)
    local right_w = w - 3 - half_w

    -- Pane Titles
    local left_is_active = (App.active_pane == "left")
    local left_accent = left_is_active and (C.bold .. C.bright_cyan) or C.gray
    local right_accent = (not left_is_active) and (C.bold .. C.bright_cyan) or C.gray

    local left_sel_n, left_sel_b = App.get_selected_count(App.left)
    local right_sel_n, right_sel_b = App.get_selected_count(App.right)

    local left_title_text = string.format(" Local: %s ", App.left.dir)
    if left_sel_n > 0 then left_title_text = left_title_text .. string.format("(%d sel, %s) ", left_sel_n, format_size(left_sel_b)) end
    left_title_text = pad_string(left_title_text, half_w)

    local right_title_text = string.format(" Remote: %s ", App.right.dir)
    if right_sel_n > 0 then right_title_text = right_title_text .. string.format("(%d sel, %s) ", right_sel_n, format_size(right_sel_b)) end
    right_title_text = pad_string(right_title_text, right_w)

    table.insert(buf, string.format("\27[2;1H%s%s%s%s%s%s%s\27[0m\27[K",
        left_accent, BOX.tl, left_title_text:sub(1, half_w), BOX.tt,
        right_accent, right_title_text:sub(1, right_w), BOX.tr .. C.reset
    ))

    -- 3. Pane Rows
    local left_items = App.get_filtered_items(App.left)
    local right_items = App.get_filtered_items(App.right)

    -- Adjust scrolling
    if App.left.cursor < App.left.scroll_top then
        App.left.scroll_top = App.left.cursor
    elseif App.left.cursor >= App.left.scroll_top + content_h then
        App.left.scroll_top = App.left.cursor - content_h + 1
    end
    if App.right.cursor < App.right.scroll_top then
        App.right.scroll_top = App.right.cursor
    elseif App.right.cursor >= App.right.scroll_top + content_h then
        App.right.scroll_top = App.right.cursor - content_h + 1
    end

    for row = 1, content_h do
        local cur_y = 2 + row
        -- Left Pane Column
        local l_idx = App.left.scroll_top + row - 1
        local l_item = left_items[l_idx]
        local l_str = ""
        if l_item then
            local is_cur = (left_is_active and l_idx == App.left.cursor)
            local is_sel = App.left.selected[l_item.name]
            local prefix = is_sel and (C.bright_yellow .. "[*]" .. C.reset) or "   "
            local cur_arrow = is_cur and ">" or " "
            local type_icon = get_file_icon(l_item.name, l_item.is_dir)
            local size_str = pad_string(l_item.is_dir and "-" or format_size(l_item.size), 7, true)
            local date_str = ""
            local icon_w = (BOX == BOX_ASCII) and 6 or 3
            local meta_w = 13 + icon_w
            if half_w >= 48 then
                date_str = " " .. pad_string(l_item.mtime or "-", 16)
                meta_w = meta_w + 17
            elseif half_w >= 36 then
                local short_date = (l_item.mtime and l_item.mtime:match("(%d%d%-%d%d)")) or (l_item.mtime and l_item.mtime:sub(1, 5)) or "-"
                date_str = " " .. pad_string(short_date, 5)
                meta_w = meta_w + 6
            end
            local avail_name_w = math.max(6, half_w - meta_w)
            local name_disp = pad_string(l_item.name, avail_name_w)
            local line_color = is_cur and (C.reverse .. C.bold) or (l_item.is_dir and C.bright_white or C.white)
            l_str = string.format("%s%s %s%s%s %s%s", cur_arrow, prefix, type_icon, line_color, name_disp .. C.reset, size_str, date_str)
        else
            l_str = string.rep(" ", half_w)
        end

        -- Right Pane Column
        local r_str = ""
        if not App.host_cfg.is_demo and not App.connected then
            if row == 2 then
                local fail_title = "   [!] Unable to connect to " .. target_display
                r_str = pad_string(C.bright_red .. fail_title .. C.reset, right_w)
            elseif row == 3 then
                local err_short = (App.conn_error or "Connection failed"):sub(1, math.max(10, right_w - 15))
                r_str = pad_string("   " .. C.red .. "Error: " .. err_short .. C.reset, right_w)
            elseif row == 5 then
                r_str = pad_string("   " .. C.gray .. "Press 'r' to retry connection" .. C.reset, right_w)
            elseif row == 6 then
                r_str = pad_string("   " .. C.gray .. "Press 'H' to select another server" .. C.reset, right_w)
            else
                r_str = string.rep(" ", right_w)
            end
        else
            local r_idx = App.right.scroll_top + row - 1
            local r_item = right_items[r_idx]
            if r_item then
                local is_cur = ((not left_is_active) and r_idx == App.right.cursor)
                local is_sel = App.right.selected[r_item.name]
                local prefix = is_sel and (C.bright_yellow .. "[*]" .. C.reset) or "   "
                local cur_arrow = is_cur and ">" or " "
                local type_icon = get_file_icon(r_item.name, r_item.is_dir)
                local size_str = pad_string(r_item.is_dir and "-" or format_size(r_item.size), 7, true)
                local date_str = ""
                local icon_w = (BOX == BOX_ASCII) and 6 or 3
                local meta_w = 13 + icon_w
                if right_w >= 48 then
                    date_str = " " .. pad_string(r_item.mtime or "-", 16)
                    meta_w = meta_w + 17
                elseif right_w >= 36 then
                    local short_date = (r_item.mtime and r_item.mtime:match("(%d%d%-%d%d)")) or (r_item.mtime and r_item.mtime:sub(1, 5)) or "-"
                    date_str = " " .. pad_string(short_date, 5)
                    meta_w = meta_w + 6
                end
                local avail_name_w = math.max(6, right_w - meta_w)
                local name_disp = pad_string(r_item.name, avail_name_w)
                local line_color = is_cur and (C.reverse .. C.bold) or (r_item.is_dir and C.bright_white or C.white)
                r_str = string.format("%s%s %s%s%s %s%s", cur_arrow, prefix, type_icon, line_color, name_disp .. C.reset, size_str, date_str)
            else
                r_str = string.rep(" ", right_w)
            end
        end

        table.insert(buf, string.format("\27[%d;1H%s%s%s%s%s\27[0m\27[K",
            cur_y,
            left_accent .. BOX.v .. C.reset,
            l_str,
            left_accent .. BOX.v .. right_accent,
            r_str,
            BOX.v .. C.reset
        ))
    end

    -- 4. Pane Bottom Borders
    local btm_y = content_h + 3
    table.insert(buf, string.format("\27[%d;1H%s%s%s%s%s%s\27[0m\27[K",
        btm_y,
        left_accent, BOX.bl, BOX.h:rep(half_w), BOX.tb,
        right_accent, BOX.h:rep(right_w) .. BOX.br .. C.reset
    ))

    -- 5. Status / Message Line
    local stat_y = content_h + 4
    table.insert(buf, string.format("\27[%d;1H%s%s%s\27[0m\27[K",
        stat_y,
        App.status_color, pad_string(" " .. App.status_msg, w), C.reset
    ))

    -- 6. Keyboard Guide Footer Bar
    local foot_y = content_h + 5
    local keyguide = string.format(" [Tab] Switch  [Space] Select  [H] Host/IP  [.] Hidden:%s  [u] Upload  [d] Download  [r] Refresh  [?] Help  [q] Quit ",
        App.show_hidden and "ON" or "OFF"
    )
    table.insert(buf, string.format("\27[%d;1H%s%s%s%s\27[0m\27[K",
        foot_y,
        C.bg_gray, C.bold .. C.bright_white, pad_string(keyguide, w), C.reset
    ))

    -- Render in one atomic write
    io.write(table.concat(buf))
    io.flush()

    -- 7. Modals Overlay Rendering (if active)
    if App.modal == "confirm_transfer" then
        App.draw_confirm_modal()
    elseif App.modal == "host_picker" then
        App.draw_host_picker_modal()
    elseif App.modal == "new_host_form" then
        App.draw_new_host_modal()
    elseif App.modal == "confirm_delete_host" then
        App.draw_confirm_delete_host_modal()
    elseif App.modal == "help" then
        App.draw_help_modal()
    end
end

function App.draw_confirm_modal()
    local w, h = App.term_w, App.term_h
    local mw = math.min(68, w - 6)
    local mh = 11
    local mx = math.floor((w - mw) / 2)
    local my = math.floor((h - mh) / 2)

    local d = App.modal_data
    local is_upload = (d.direction == "upload")
    local title = is_upload and " Confirm Upload (Local -> Remote) " or " Confirm Download (Remote -> Local) "
    local target_dest = is_upload and (App.host_cfg.hostname .. ":" .. App.right.dir) or App.left.dir

    local lines = {
        BOX.tl .. pad_string(title, mw - 2) .. BOX.tr,
        BOX.v .. pad_string(" Direction : " .. (is_upload and "Upload to Remote Host" or "Download to Local Drive"), mw - 2) .. BOX.v,
        BOX.v .. pad_string(" Target    : " .. target_dest, mw - 2) .. BOX.v,
        BOX.v .. pad_string(string.format(" Selection : %d item(s) (%s)", d.count, format_size(d.bytes)), mw - 2) .. BOX.v,
        BOX.v .. pad_string(" Method    : rsync -avzP (fallback: scp -r)", mw - 2) .. BOX.v,
        BOX.v .. pad_string(" Sample    : " .. (d.items[1] or ""), mw - 2) .. BOX.v,
        BOX.v .. BOX.h:rep(mw - 2) .. BOX.v,
        BOX.v .. pad_string(" Execute transfer now? [Y]es / [N]o", mw - 2) .. BOX.v,
        BOX.bl .. BOX.h:rep(mw - 2) .. BOX.br,
    }

    local modal_buf = {}
    for i, line in ipairs(lines) do
        table.insert(modal_buf, string.format("\27[%d;%dH%s%s%s%s",
            my + i - 1, mx, C.bold, C.bright_yellow, line, C.reset
        ))
    end
    io.write(table.concat(modal_buf))
    io.flush()
end

function App.draw_confirm_delete_host_modal()
    local w, h = App.term_w, App.term_h
    local mw = math.min(74, w - 4)
    local mh = 11
    local mx = math.floor((w - mw) / 2)
    local my = math.floor((h - mh) / 2)

    local d = App.modal_data
    local target = d.target or {}
    local src_file = target.source_file or ((target.source == "ssh-config") and "~/.ssh/config" or target.source)

    local lines = {
        BOX.tl .. pad_string(" Confirm Delete Host ", mw - 2) .. BOX.tr,
        BOX.v .. pad_string(" Are you sure you want to delete this host configuration?", mw - 2) .. BOX.v,
        BOX.v .. BOX.h:rep(mw - 2) .. BOX.v,
        BOX.v .. pad_string(string.format("   Alias   : %s", target.name or "-"), mw - 2) .. BOX.v,
        BOX.v .. pad_string(string.format("   Host/IP : %s", target.hostname or "-"), mw - 2) .. BOX.v,
        BOX.v .. pad_string(string.format("   Port    : %s", target.port or "22"), mw - 2) .. BOX.v,
        BOX.v .. pad_string(string.format("   Source  : [%s] %s", target.source or "-", src_file), mw - 2) .. BOX.v,
        BOX.v .. BOX.h:rep(mw - 2) .. BOX.v,
        BOX.v .. C.bold .. C.bright_yellow .. pad_string(" [y] Confirm Delete      [n / q / Esc] Cancel", mw - 2) .. C.reset .. C.bright_cyan .. BOX.v,
        BOX.bl .. BOX.h:rep(mw - 2) .. BOX.br,
    }

    local modal_buf = {}
    for i, line in ipairs(lines) do
        table.insert(modal_buf, string.format("\27[%d;%dH%s%s%s%s",
            my + i - 1, mx, C.bold, C.bright_cyan, line, C.reset
        ))
    end
    io.write(table.concat(modal_buf))
    io.flush()
end

function App.draw_help_modal()
    local w, h = App.term_w, App.term_h
    local mw = math.min(72, w - 4)
    local mh = 18
    local mx = math.floor((w - mw) / 2)
    local my = math.floor((h - mh) / 2)

    local help_lines = {
        BOX.tl .. pad_string(" FSCP-TUI Keybindings & Guide ", mw - 2) .. BOX.tr,
        BOX.v .. pad_string(" Tab                   Switch active pane (Left <-> Right)", mw - 2) .. BOX.v,
        BOX.v .. pad_string(" Up / k, Down / j      Move cursor up / down", mw - 2) .. BOX.v,
        BOX.v .. pad_string(" Enter / l / Right     Enter selected directory", mw - 2) .. BOX.v,
        BOX.v .. pad_string(" Backspace / h / Left  Go up to parent directory (..)", mw - 2) .. BOX.v,
        BOX.v .. pad_string(" Space                 Toggle multi-select on current item", mw - 2) .. BOX.v,
        BOX.v .. pad_string(" .                     Toggle hidden files/folders (default: OFF)", mw - 2) .. BOX.v,
        BOX.v .. pad_string(" a / A                 Select ALL / Deselect ALL items", mw - 2) .. BOX.v,
        BOX.v .. pad_string(" u / F5                Upload selected items (Local -> Remote)", mw - 2) .. BOX.v,
        BOX.v .. pad_string(" d / F5                Download selected items (Remote -> Local)", mw - 2) .. BOX.v,
        BOX.v .. pad_string(" r                     Refresh directory contents", mw - 2) .. BOX.v,
        BOX.v .. pad_string(" ~                     Jump directly to Home directory", mw - 2) .. BOX.v,
        BOX.v .. pad_string(" H                     Open Host Picker (Switch Remote Host)", mw - 2) .. BOX.v,
        BOX.v .. pad_string(" /                     Filter items in current pane", mw - 2) .. BOX.v,
        BOX.v .. pad_string(" q / Esc / Ctrl+C      Quit application", mw - 2) .. BOX.v,
        BOX.v .. BOX.h:rep(mw - 2) .. BOX.v,
        BOX.v .. pad_string(" Press any key to close this help window...", mw - 2) .. BOX.v,
        BOX.bl .. BOX.h:rep(mw - 2) .. BOX.br,
    }

    local modal_buf = {}
    for i, line in ipairs(help_lines) do
        table.insert(modal_buf, string.format("\27[%d;%dH%s%s%s%s",
            my + i - 1, mx, C.bold, C.bright_cyan, line, C.reset
        ))
    end
    io.write(table.concat(modal_buf))
    io.flush()
end

function App.draw_host_picker_modal()
    local w, h = App.term_w, App.term_h
    local mw = math.min(88, w - 4)
    local mh = math.min(18, h - 4)
    local mx = math.floor((w - mw) / 2)
    local my = math.floor((h - mh) / 2)

    local d = App.modal_data
    local hosts = d.filtered or d.hosts or {}
    local cur = d.cursor or 1
    local filter_str = d.filter or ""

    local lines = {
        BOX.tl .. pad_string(" Connect to Remote Server ", mw - 2) .. BOX.tr,
        BOX.v .. pad_string(" [↑/↓] Navigate  [Enter] Connect  [e] Edit  [d/Del] Delete  [n] New  [Esc] Cancel", mw - 2) .. BOX.v,
    }

    local filter_prompt = (filter_str ~= "") and (" Filter / IP: " .. filter_str .. "_  [Del / Ctrl+D to delete]") or " Filter / IP: _ (Type to filter, or press 'e' to edit, 'd/Del' to delete, 'n' for form)"
    table.insert(lines, BOX.v .. pad_string(filter_prompt, mw - 2) .. BOX.v)

    table.insert(lines, BOX.v .. BOX.h:rep(mw - 2) .. BOX.v)
    table.insert(lines, BOX.v .. pad_string(string.format("   %-18s %-26s %-10s %-6s %s", "NAME", "HOST / IP", "USER", "PORT", "SOURCE"), mw - 2) .. BOX.v)
    table.insert(lines, BOX.v .. BOX.h:rep(mw - 2) .. BOX.v)

    local view_h = mh - 7
    if view_h < 4 then view_h = 4 end
    local scroll = math.max(1, cur - view_h + 1)

    for i = 1, view_h do
        local idx = scroll + i - 1
        local h_entry = hosts[idx]
        if h_entry then
            local is_cur = (idx == cur)
            local prefix = is_cur and "> " or "  "
            local src_tag = string.format("[%s]", h_entry.source or "ssh")
            local desc = string.format("%s%-18s %-26s %-10s %-6s %s",
                prefix,
                h_entry.name:sub(1, 18),
                (h_entry.hostname or ""):sub(1, 26),
                (h_entry.user ~= "" and h_entry.user or "-"):sub(1, 10),
                (h_entry.port or "22"):sub(1, 6),
                src_tag
            )
            local line_col = is_cur and (C.reverse .. C.bold) or C.bright_white
            table.insert(lines, BOX.v .. line_col .. pad_string(desc, mw - 2) .. C.reset .. C.bright_cyan .. BOX.v)
        else
            table.insert(lines, BOX.v .. string.rep(" ", mw - 2) .. BOX.v)
        end
    end

    table.insert(lines, BOX.v .. BOX.h:rep(mw - 2) .. BOX.v)
    table.insert(lines, BOX.v .. pad_string(string.format(" Total: %d option(s) | [Enter] Connect | [e] Edit | [d] Delete | [n] New", #hosts), mw - 2) .. BOX.v)
    table.insert(lines, BOX.bl .. BOX.h:rep(mw - 2) .. BOX.br)

    local modal_buf = {}
    for i, line in ipairs(lines) do
        table.insert(modal_buf, string.format("\27[%d;%dH%s%s%s%s",
            my + i - 1, mx, C.bold, C.bright_cyan, line, C.reset
        ))
    end
    io.write(table.concat(modal_buf))
    io.flush()
end

function App.draw_new_host_modal()
    local w, h = App.term_w, App.term_h
    local mw = math.min(78, w - 4)
    local mh = 17
    local mx = math.floor((w - mw) / 2)
    local my = math.floor((h - mh) / 2)

    local d = App.modal_data
    local f_idx = d.field or 1

    local function field_line(num, label, val, is_active, hint)
        local prefix = is_active and "> " or "  "
        local cur_mark = is_active and "_" or ""
        local text = string.format("%s%d. %-12s: [ %s%s ]%s", prefix, num, label, val or "", cur_mark, hint or "")
        local col = is_active and (C.bold .. C.bright_yellow) or C.bright_white
        return BOX.v .. col .. pad_string(text, mw - 2) .. C.reset .. C.bright_cyan .. BOX.v
    end

    local function check_line(num, label, checked, is_active, hint)
        local prefix = is_active and "> " or "  "
        local box_char = checked and "[X]" or "[ ]"
        local text = string.format("%s%d. %s %s%s", prefix, num, box_char, label, hint or "")
        local col = is_active and (C.bold .. C.bright_yellow) or C.bright_white
        return BOX.v .. col .. pad_string(text, mw - 2) .. C.reset .. C.bright_cyan .. BOX.v
    end

    local title = d.is_edit and string.format(" Edit Remote Host: [ %s ] ", d.original_alias or d.alias or "Host") or " New Remote Connection (Guided Form) "
    local subtitle = d.is_edit and " Modify connection details, or press [Esc] to return." or " Fill in connection details, or press [Esc] to return."

    local lines = {
        BOX.tl .. pad_string(title, mw - 2) .. BOX.tr,
        BOX.v .. pad_string(subtitle, mw - 2) .. BOX.v,
        BOX.v .. BOX.h:rep(mw - 2) .. BOX.v,
        field_line(1, "Host / IP", d.host, f_idx == 1, " (Required, e.g. 192.168.1.50)"),
        field_line(2, "Port", d.port, f_idx == 2, " (Default: 22)"),
        field_line(3, "User", d.user, f_idx == 3, " (Optional)"),
        field_line(4, "SSH Key", d.key, f_idx == 4, " (Optional, e.g. ~/.ssh/id_ed25519)"),
        field_line(5, "Remote Dir", d.dir, f_idx == 5, " (Default: ~)"),
        check_line(6, "Save to ~/.ssh/config", d.save, f_idx == 6, " (Space to toggle)"),
        field_line(7, "Host Alias", d.alias, f_idx == 7, d.save and " (Alias in ssh config)" or " (Enable #6 to save)"),
        BOX.v .. BOX.h:rep(mw - 2) .. BOX.v,
    }

    if d.error and d.error ~= "" then
        table.insert(lines, BOX.v .. C.bright_red .. pad_string(" Error: " .. d.error, mw - 2) .. C.reset .. C.bright_cyan .. BOX.v)
    else
        table.insert(lines, BOX.v .. pad_string(" [Tab/Down] Next   [Up] Prev   [Ctrl+S] Save   [Enter] Save & Connect", mw - 2) .. BOX.v)
    end
    table.insert(lines, BOX.bl .. BOX.h:rep(mw - 2) .. BOX.br)

    local modal_buf = {}
    for i, line in ipairs(lines) do
        table.insert(modal_buf, string.format("\27[%d;%dH%s%s%s%s",
            my + i - 1, mx, C.bold, C.bright_cyan, line, C.reset
        ))
    end
    io.write(table.concat(modal_buf))
    io.flush()
end

--------------------------------------------------------------------------------
-- Rsync & SSH Helpers
--------------------------------------------------------------------------------
local function ensure_cwrsync_fstab()
    if not IS_WINDOWS then return end
    local fstab_path = "C:/ProgramData/chocolatey/lib/rsync/tools/etc/fstab"
    if not file_exists(fstab_path) then
        local etc_dir = "C:/ProgramData/chocolatey/lib/rsync/tools/etc"
        if file_exists(etc_dir .. "/nsswitch.conf") then
            local f = io.open(fstab_path, "w")
            if f then
                f:write("none /cygdrive cygdrive binary,posix=0,user,noacl 0 0\n")
                f:close()
            end
        end
    end
end

local function get_rsync_ssh_cmd(port, key)
    local ssh_opts = {}
    local ssh_bin = "ssh"

    if IS_WINDOWS then
        local candidates = {
            "C:/ProgramData/chocolatey/lib/rsync/tools/bin/ssh.exe",
            "C:/ProgramData/chocolatey/bin/ssh.exe",
            "C:/tools/cwrsync/bin/ssh.exe",
            "C:/cygwin64/bin/ssh.exe",
        }
        for _, c in ipairs(candidates) do
            if file_exists(c) then
                ssh_bin = c
                break
            end
        end

        if ssh_bin ~= "ssh" then
            table.insert(ssh_opts, "-o UserKnownHostsFile=~/.ssh/known_hosts")
            table.insert(ssh_opts, "-o StrictHostKeyChecking=accept-new")
        end
    end

    if port ~= "22" and port ~= "" then
        table.insert(ssh_opts, "-p " .. port)
    end
    if key ~= "" then
        table.insert(ssh_opts, "-i " .. shell_escape(key))
    end

    if ssh_bin ~= "ssh" or #ssh_opts > 0 then
        return string.format("%s %s", ssh_bin, table.concat(ssh_opts, " "))
    end
    return nil
end

local _rsync_cached_avail = nil
local function is_rsync_available()
    if _rsync_cached_avail ~= nil then
        return _rsync_cached_avail
    end
    if IS_WINDOWS then
        local candidates = {
            "C:/ProgramData/chocolatey/bin/rsync.exe",
            "C:/ProgramData/chocolatey/lib/rsync/tools/bin/rsync.exe",
            "C:/tools/cwrsync/bin/rsync.exe",
            "C:/cygwin64/bin/rsync.exe",
        }
        for _, c in ipairs(candidates) do
            if file_exists(c) then
                _rsync_cached_avail = true
                return true
            end
        end
        local p = io.popen("where rsync 2>nul", "r")
        if p then
            local res = p:read("*line")
            p:close()
            if res and res ~= "" then
                _rsync_cached_avail = true
                return true
            end
        end
    else
        local p = io.popen("which rsync 2>/dev/null", "r")
        if p then
            local res = p:read("*line")
            p:close()
            if res and res ~= "" then
                _rsync_cached_avail = true
                return true
            end
        end
    end
    _rsync_cached_avail = false
    return false
end

--------------------------------------------------------------------------------
-- FZF Pipeline & Preview Helpers
--------------------------------------------------------------------------------
local function format_preview(h, is_rsync)
    local tool = "scp"
    if is_rsync then
        tool = "rsync"
    elseif IS_WINDOWS and h.source == "putty" then
        tool = "pscp"
    end

    local lines = {}
    table.insert(lines, string.format("%s%s=== Target Remote Host: %s ===%s", C.bold, C.bright_cyan, h.name, C.reset))
    table.insert(lines, "")
    table.insert(lines, string.format("  %sHostname / IP :%s %s", C.bright_yellow, C.reset, h.hostname or h.name))
    table.insert(lines, string.format("  %sRemote User   :%s %s", C.bright_yellow, C.reset, (h.user and h.user ~= "" and h.user or string.format("%s(default)%s", C.dim, C.reset))))
    table.insert(lines, string.format("  %sPort          :%s %s", C.bright_yellow, C.reset, h.port or "22"))
    if h.key and h.key ~= "" then
        table.insert(lines, string.format("  %sIdentity Key  :%s %s", C.bright_yellow, C.reset, h.key))
    end
    table.insert(lines, string.format("  %sSource        :%s %s%s%s", C.bright_yellow, C.reset, C.bright_magenta, h.source or "unknown", C.reset))
    if h.source_file and h.source_file ~= "" then
        table.insert(lines, string.format("  %sConfig File   :%s %s%s%s", C.dim, C.reset, C.dim, h.source_file, C.reset))
    end
    table.insert(lines, string.format("  %sTransfer Tool :%s %s%s%s", C.bright_yellow, C.reset, C.bold .. C.bright_green, tool, C.reset))
    table.insert(lines, "")
    table.insert(lines, string.format("%s%sAvailable Actions:%s", C.bold, C.bright_white, C.reset))
    table.insert(lines, string.format("  %s* Push (Upload)  :%s Upload selected files to %s:~/", C.bright_green, C.reset, h.name))
    table.insert(lines, string.format("  %s* Pull (Download):%s Download remote files to current directory", C.bright_green, C.reset))
    return table.concat(lines, "\n")
end

local function run_fzf_host_picker(hosts, is_rsync, pull_mode)
    local script_path = debug.getinfo(1, "S").source:sub(2)
    if not script_path:match("^/") and not script_path:match("^%a:[/\\]") then
        local pwd = io.popen(IS_WINDOWS and "cd" or "pwd 2>/dev/null || pwd"):read("*line") or "."
        script_path = pwd .. "/" .. script_path
    end

    local rsync_flag = is_rsync and " -r" or " --scp"
    local preview_cmd = string.format("luajit %q --preview-only {1}%s", script_path, rsync_flag)

    local tool_label = is_rsync and "rsync" or (IS_WINDOWS and "scp / pscp" or "scp")
    local mode_prefix = pull_mode and "fpull" or "fpush"

    local fzf_cmd = string.format(
        'luajit %q --list-hosts | fzf --prompt="[%s] Remote Host > " --delimiter="\t" --with-nth=1,2,3,4 ' ..
        '--layout=reverse --height=50%% --border --preview=%q --preview-window=right:50%%:wrap ' ..
        '--header="LuaJIT FFI | Tool: %s | ENTER: Select Host | ESC: Cancel"',
        script_path, mode_prefix, preview_cmd, tool_label
    )

    local pipe = io.popen(fzf_cmd, "r")
    if not pipe then
        io.stderr:write("Error: fzf is not installed or failed to launch.\n")
        return nil
    end

    local output = pipe:read("*line")
    pipe:close()

    if output and output ~= "" then
        local key = output:match("^[^\t]+")
        for _, h in ipairs(hosts) do
            if h.name == key then
                return h
            end
        end
    end
    return nil
end

local function run_fzf_file_picker()
    local preview_cmd
    if IS_WINDOWS then
        preview_cmd = "if exist {} ( dir /b /a {} 2>nul || type {} 2>nul )"
    else
        preview_cmd = "if [ -d {} ]; then ls -la --color=always {}; else head -n 40 {} 2>/dev/null || file {}; fi"
    end

    local list_cmd
    if IS_WINDOWS then
        list_cmd = "dir /b /a-d 2>nul"
    else
        list_cmd = "find . -maxdepth 3 -not -path '*/.*' 2>/dev/null | sed 's|^\\./||'"
    end

    local fzf_cmd = string.format(
        '%s | fzf -m --prompt="[fscp] Select File(s) to Send > " ' ..
        '--layout=reverse --height=55%% --border --preview=%q --preview-window=right:50%%:wrap ' ..
        '--header="TAB: Multi-select | ENTER: Confirm | ESC: Cancel"',
        list_cmd, preview_cmd
    )

    local pipe = io.popen(fzf_cmd, "r")
    if not pipe then return {} end

    local selected = {}
    for line in pipe:lines() do
        local l = trim(line)
        if l ~= "" then
            table.insert(selected, l)
        end
    end
    pipe:close()
    return selected
end

local function run_fzf_remote_file_picker(host, override_user, override_port, override_key)
    local name = host.name
    local hostname = host.hostname or host.name
    local config_user = host.user or ""
    local user = (override_user ~= "") and override_user or config_user
    local port = (override_port ~= "") and override_port or (host.port or "22")
    local key = (override_key ~= "") and override_key or (host.key or "")
    local source = host.source or ""

    local target_host = (source == "ssh-config") and name or hostname
    local host_str = (user ~= "" and user ~= config_user) and string.format("%s@%s", user, target_host) or target_host
    if source ~= "ssh-config" and user ~= "" and not host_str:find("@") then
        host_str = string.format("%s@%s", user, target_host)
    end

    local ssh_cmd_parts = { "ssh", "-o", "ConnectTimeout=4", "-o", "BatchMode=yes" }
    if port ~= "22" and port ~= "" then
        table.insert(ssh_cmd_parts, "-p")
        table.insert(ssh_cmd_parts, port)
    end
    if key ~= "" then
        table.insert(ssh_cmd_parts, "-i")
        table.insert(ssh_cmd_parts, shell_escape(key))
    end
    table.insert(ssh_cmd_parts, host_str)
    local ssh_base = table.concat(ssh_cmd_parts, " ")

    local current_remote_dir = "."

    while true do
        local dir_display = (current_remote_dir == ".") and "~/" or (current_remote_dir .. "/")
        local remote_cmd
        if IS_WINDOWS then
            local escaped_dir = current_remote_dir:gsub('"', '\\"')
            remote_cmd = string.format('%s "ls -1ap \\"%s\\" 2>/dev/null"', ssh_base, escaped_dir)
        else
            remote_cmd = string.format("%s 'ls -1ap %s 2>/dev/null'", ssh_base, shell_escape(current_remote_dir))
        end

        local pipe = io.popen(remote_cmd, "r")
        local lines = {}
        if pipe then
            for l in pipe:lines() do
                local item = trim(l)
                if item ~= "" and item ~= "./" then
                    table.insert(lines, item)
                end
            end
            pipe:close()
        end

        if #lines == 0 then
            return nil
        end

        local candidates = { string.format("[PULL CURRENT FOLDER: %s]", dir_display) }
        for _, it in ipairs(lines) do
            table.insert(candidates, it)
        end

        local input_data = table.concat(candidates, "\n")
        local fzf_prompt = string.format("[fpull] %s:%s > ", name, dir_display)
        local fzf_cmd = string.format(
            'fzf --prompt=%q --layout=reverse --height=60%% --border ' ..
            '--header="ENTER: Navigate / Select | ESC: Manual Path"',
            fzf_prompt
        )

        local fzf_pipe
        if IS_WINDOWS then
            local tmp_path = os.getenv("TEMP") or "."
            local tmp_file = tmp_path .. "\\fscp_remote_list.tmp"
            local f = io.open(tmp_file, "w")
            if f then
                f:write(input_data)
                f:close()
                fzf_pipe = io.popen(string.format('type "%s" | %s', tmp_file, fzf_cmd), "r")
            end
        else
            fzf_pipe = io.popen(string.format('printf %%s %s | %s', shell_escape(input_data), fzf_cmd), "r")
        end

        if not fzf_pipe then return nil end

        local selection = fzf_pipe:read("*line")
        fzf_pipe:close()

        if not selection or trim(selection) == "" then
            return nil
        end
        selection = trim(selection)

        if selection:find("^%[PULL CURRENT FOLDER:") then
            return (current_remote_dir == ".") and "~/" or current_remote_dir
        elseif selection == "../" then
            if current_remote_dir == "." or current_remote_dir == "" then
                current_remote_dir = ".."
            elseif current_remote_dir == ".." then
                current_remote_dir = "../.."
            else
                current_remote_dir = current_remote_dir:match("^(.*)/[^/]+$") or "."
            end
        elseif selection:sub(-1) == "/" then
            local sub_dir = selection:sub(1, -2)
            if current_remote_dir == "." then
                current_remote_dir = sub_dir
            else
                current_remote_dir = current_remote_dir .. "/" .. sub_dir
            end
        else
            if current_remote_dir == "." then
                return selection
            else
                return current_remote_dir .. "/" .. selection
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Headless CLI Transfer Engine
--------------------------------------------------------------------------------
local function execute_headless_transfer(host, local_files, remote_path, pull_mode, use_rsync, override_user, override_port, override_key, dry_run)
    local name = host.name
    local hostname = host.hostname or host.name
    local config_user = host.user or ""
    local user = (override_user and override_user ~= "") and override_user or config_user
    local port = (override_port and override_port ~= "") and override_port or (host.port or "22")
    local key = (override_key and override_key ~= "") and override_key or (host.key or "")
    local source = host.source or ""

    remote_path = (remote_path and remote_path ~= "") and remote_path or "~/"
    local tag = pull_mode and "[fpull]" or "[fpush]"

    -- PuTTY Windows PSCP mode
    if IS_WINDOWS and (source == "putty" and not use_rsync) then
        local pscp_bin = "pscp.exe"
        local p_cmd = { pscp_bin, "-load", name, "-r" }
        if user ~= "" and user ~= config_user then
            table.insert(p_cmd, "-l")
            table.insert(p_cmd, user)
        end
        if port ~= "22" and port ~= "" then
            table.insert(p_cmd, "-P")
            table.insert(p_cmd, port)
        end
        if key ~= "" then
            table.insert(p_cmd, "-i")
            table.insert(p_cmd, key)
        end

        if pull_mode then
            local remote_spec = string.format("%s:%s", name, remote_path)
            table.insert(p_cmd, remote_spec)
            table.insert(p_cmd, ".")
        else
            for _, f in ipairs(local_files) do
                table.insert(p_cmd, f)
            end
            table.insert(p_cmd, string.format("%s:%s", name, remote_path))
        end

        if dry_run then
            print(string.format("Dry run (pscp): %s", shell_command(p_cmd)))
            return
        end
        print(string.format("%s%s Tool: %spscp (PuTTY)%s", C.bright_cyan, tag, C.bold, C.reset))
        print(string.format("%s%s Executing: %s%s", C.bright_cyan, tag, shell_command(p_cmd), C.reset))
        local status, err = run_transfer(p_cmd)
        if err then io.stderr:write(err .. "\n") end
        os.exit(status or 1)
        return
    end

    -- Construct Remote Host String
    local target_host = (source == "ssh-config") and name or hostname
    local host_str = (user ~= "" and user ~= config_user) and string.format("%s@%s", user, target_host) or target_host
    if source ~= "ssh-config" and user ~= "" and not host_str:find("@") then
        host_str = string.format("%s@%s", user, target_host)
    end

    local cmd = {}

    if use_rsync then
        ensure_cwrsync_fstab()
        cmd = { "rsync", "-avzP" }
        local ssh_e = get_rsync_ssh_cmd(port, key)
        if ssh_e then
            table.insert(cmd, "-e")
            table.insert(cmd, ssh_e)
        end

        if pull_mode then
            table.insert(cmd, string.format("%s:%s", host_str, remote_path))
            table.insert(cmd, "./")
        else
            for _, f in ipairs(local_files) do
                table.insert(cmd, f)
            end
            table.insert(cmd, string.format("%s:%s", host_str, remote_path))
        end
    else
        -- Standard SCP
        cmd = { "scp", "-r" }
        if port ~= "22" and port ~= "" then
            table.insert(cmd, "-P")
            table.insert(cmd, port)
        end
        if key ~= "" then
            table.insert(cmd, "-i")
            table.insert(cmd, key)
        end

        if pull_mode then
            table.insert(cmd, string.format("%s:%s", host_str, remote_path))
            table.insert(cmd, ".")
        else
            for _, f in ipairs(local_files) do
                table.insert(cmd, f)
            end
            table.insert(cmd, string.format("%s:%s", host_str, remote_path))
        end
    end

    local tool_name = use_rsync and "rsync" or "scp"

    if dry_run then
        print(string.format("Dry run (%s): %s", tool_name, shell_command(cmd)))
        return
    end

    print(string.format("%s%s Tool: %s%s%s", C.bright_cyan, tag, C.bold, tool_name, C.reset))
    print(string.format("%s%s Executing: %s%s", C.bright_cyan, tag, shell_command(cmd), C.reset))

    if not IS_WINDOWS then
        local c_args = ffi.new("const char*[?]", #cmd + 1)
        for i, a in ipairs(cmd) do
            c_args[i - 1] = a
        end
        c_args[#cmd] = nil
        ffi.C.execvp(cmd[1], ffi.cast("char* const*", c_args))
    else
        local status, err = run_transfer(cmd)
        if err then io.stderr:write(err .. "\n") end
        os.exit(status or 1)
    end
end

--------------------------------------------------------------------------------
-- Transfer Execution Engine (Rsync & SCP Bridge)
--------------------------------------------------------------------------------
function App.execute_transfer(direction, items)
    Term.restore()
    io.write("\27[2J\27[H")
    io.flush()

    local is_upload = (direction == "upload")
    local transfer_status, transfer_error = 0, nil
    print(C.bold .. C.bright_cyan .. "============================================================" .. C.reset)
    print(string.format("%s%s Starting %s: %d item(s)%s",
        C.bold, C.bright_yellow, is_upload and "UPLOAD (Local -> Remote)" or "DOWNLOAD (Remote -> Local)", #items, C.reset
    ))
    print(C.bold .. C.bright_cyan .. "============================================================" .. C.reset)

    if App.host_cfg.is_demo or App.host_cfg.name == "demo" then
        print("\n" .. C.bright_yellow .. "[DEMO MODE NOTICE]" .. C.reset)
        print("Simulating transfer:")
        for _, it in ipairs(items) do
            print(string.format("  -> %s %s", is_upload and "Uploading" or "Downloading", it))
        end
        print("\n" .. C.bright_green .. "Demo transfer simulated successfully!" .. C.reset)
    else
        local host = get_ssh_target(App.host_cfg)
        local source = App.host_cfg.source or ""
        local use_rsync = is_rsync_available()
        local port = (App.host_cfg.source ~= "ssh-config" and App.host_cfg.port and App.host_cfg.port ~= "22") and App.host_cfg.port or ""
        local key = (App.host_cfg.key and App.host_cfg.key ~= "") and App.host_cfg.key or ""

        -- PuTTY Windows PSCP mode
        if IS_WINDOWS and (source == "putty" and not use_rsync) then
            local p_cmd = { "pscp.exe", "-load", App.host_cfg.name, "-r" }
            if App.host_cfg.user and App.host_cfg.user ~= "" then
                table.insert(p_cmd, "-l")
                table.insert(p_cmd, App.host_cfg.user)
            end
            if port ~= "" then
                table.insert(p_cmd, "-P")
                table.insert(p_cmd, port)
            end
            if key ~= "" then
                table.insert(p_cmd, "-i")
                table.insert(p_cmd, key)
            end

            if not is_upload then
                for _, it in ipairs(items) do
                    local remote_src = string.format("%s:%s/%s", App.host_cfg.name, App.right.dir, it)
                    table.insert(p_cmd, remote_src)
                end
                table.insert(p_cmd, App.left.dir)
            else
                for _, it in ipairs(items) do
                    table.insert(p_cmd, App.left.dir .. "/" .. it)
                end
                table.insert(p_cmd, string.format("%s:%s/", App.host_cfg.name, App.right.dir))
            end

            print("\nExecuting PSCP command:")
            print(C.gray .. shell_command(p_cmd) .. C.reset .. "\n")
            transfer_status, transfer_error = run_transfer(p_cmd)
        elseif use_rsync then
            ensure_cwrsync_fstab()
            local r_cmd = { "rsync", "-avzP" }
            local ssh_e = get_rsync_ssh_cmd(port, key)
            if ssh_e then
                table.insert(r_cmd, "-e")
                table.insert(r_cmd, ssh_e)
            end

            if not is_upload then
                for _, it in ipairs(items) do
                    local remote_src = string.format("%s:%s/%s", host, App.right.dir, it)
                    table.insert(r_cmd, remote_src)
                end
                table.insert(r_cmd, App.left.dir .. "/")
            else
                for _, it in ipairs(items) do
                    table.insert(r_cmd, App.left.dir .. "/" .. it)
                end
                table.insert(r_cmd, string.format("%s:%s/", host, App.right.dir))
            end

            print("\nExecuting Rsync command:")
            print(C.gray .. shell_command(r_cmd) .. C.reset .. "\n")
            transfer_status, transfer_error = run_transfer(r_cmd)
        else
            local cmd = { "scp", "-r" }
            if port ~= "" then
                table.insert(cmd, "-P")
                table.insert(cmd, port)
            end
            if key ~= "" then
                table.insert(cmd, "-i")
                table.insert(cmd, key)
            end
            if is_upload then
                for _, it in ipairs(items) do
                    table.insert(cmd, App.left.dir .. "/" .. it)
                end
                table.insert(cmd, string.format("%s:%s/", host, App.right.dir))
            else
                for _, it in ipairs(items) do
                    table.insert(cmd, string.format("%s:%s/%s", host, App.right.dir, it))
                end
                table.insert(cmd, App.left.dir)
            end

            print("\nExecuting SCP command:")
            print(C.gray .. shell_command(cmd) .. C.reset .. "\n")
            transfer_status, transfer_error = run_transfer(cmd)
        end
        if transfer_status == 0 then
            print("\nTransfer process finished with exit code: 0")
        else
            transfer_error = transfer_error or string.format("Transfer failed (process status %s). Review the command output above.", tostring(transfer_status))
            io.stderr:write(transfer_error .. "\n")
        end
    end

    print("\n" .. C.bright_white .. "Press [Enter] to return to FSCP-TUI..." .. C.reset)
    io.read()

    Term.enable_raw()
    App.refresh_left()
    App.refresh_right(true)
    App.status_msg = transfer_error or "Transfer complete. Directory views refreshed."
    App.status_color = transfer_error and C.bright_red or C.bright_green
end

--------------------------------------------------------------------------------
-- User Input & Event Dispatcher
--------------------------------------------------------------------------------
function App.handle_input(key)
    if not key then return end

    -- Modals Handling
    if App.modal == "help" then
        App.modal = nil
        return
    elseif App.modal == "confirm_transfer" then
        if key == "y" or key == "Y" or key == "enter" then
            local d = App.modal_data
            App.modal = nil
            App.execute_transfer(d.direction, d.items)
        elseif key == "n" or key == "N" or key == "esc" or key == "q" then
            App.modal = nil
            App.status_msg = "Transfer cancelled."
            App.status_color = C.yellow
        end
        return
    elseif App.modal == "confirm_delete_host" then
        local target = App.modal_data and App.modal_data.target
        local prev_cur = App.modal_data and App.modal_data.prev_cursor or 1
        if key == "y" or key == "Y" or key == "enter" then
            local ok, err = delete_host_entry(target)
            local hosts = aggregate_ssh_hosts()
            table.insert(hosts, 1, {
                name = "[+] New Form",
                hostname = "(press 'n' for form dialog)",
                user = "-",
                port = "22",
                source = "form",
                is_form_launcher = true,
            })
            table.insert(hosts, 2, {
                name = "[Demo Server]",
                hostname = "demo-server.local",
                user = "user",
                port = "22",
                source = "demo",
                is_demo = true,
            })
            local next_cur = math.min(math.max(1, prev_cur), #hosts)
            App.modal = "host_picker"
            App.modal_data = {
                hosts = hosts,
                filtered = hosts,
                cursor = next_cur,
                filter = "",
            }
            if ok then
                App.status_msg = string.format("Successfully deleted host '%s'.", target and (target.name or target.hostname) or "")
                App.status_color = C.bright_green
            else
                App.status_msg = "Delete failed: " .. (err or "unknown error")
                App.status_color = C.bright_red
            end
        elseif key == "n" or key == "N" or key == "esc" or key == "q" or key == "Q" then
            local hosts = aggregate_ssh_hosts()
            table.insert(hosts, 1, {
                name = "[+] New Form",
                hostname = "(press 'n' for form dialog)",
                user = "-",
                port = "22",
                source = "form",
                is_form_launcher = true,
            })
            table.insert(hosts, 2, {
                name = "[Demo Server]",
                hostname = "demo-server.local",
                user = "user",
                port = "22",
                source = "demo",
                is_demo = true,
            })
            local next_cur = math.min(math.max(1, prev_cur), #hosts)
            App.modal = "host_picker"
            App.modal_data = {
                hosts = hosts,
                filtered = hosts,
                cursor = next_cur,
                filter = "",
            }
            App.status_msg = "Host deletion cancelled."
            App.status_color = C.yellow
        end
        return
    elseif App.modal == "host_picker" then
        local d = App.modal_data
        local filtered = d.filtered or d.hosts or {}
        local cur = d.cursor or 1
        local total = #filtered

        local function update_filter()
            local q = (d.filter or ""):gsub("^%s+", ""):gsub("%s+$", "")
            local res = {}
            if q == "" then
                res = d.hosts
            else
                local q_lower = q:lower()
                for _, h in ipairs(d.hosts) do
                    if (h.name:lower():find(q_lower, 1, true) or (h.hostname and h.hostname:lower():find(q_lower, 1, true)) or (h.user and h.user:lower():find(q_lower, 1, true))) then
                        table.insert(res, h)
                    end
                end

                local custom = parse_host_string(q)
                if custom then
                    local is_dup = false
                    for _, existing in ipairs(res) do
                        if existing.hostname and existing.hostname:lower() == custom.hostname:lower() and
                           (existing.user or ""):lower() == (custom.user or ""):lower() and
                           tostring(existing.port or "22") == tostring(custom.port or "22") then
                            is_dup = true
                            break
                        end
                    end
                    if not is_dup then
                        if #res == 0 then
                            table.insert(res, 1, custom)
                        else
                            table.insert(res, custom)
                        end
                    end
                end
            end
            d.filtered = res
            d.cursor = 1
        end

        if key == "up" or key == "k" then
            d.cursor = math.max(1, cur - 1)
        elseif key == "down" or key == "j" then
            d.cursor = math.min(total, cur + 1)
        elseif key == "pageup" then
            d.cursor = math.max(1, cur - 10)
        elseif key == "pagedown" then
            d.cursor = math.min(total, cur + 10)
        elseif (key == "n" and (not d.filter or d.filter == "")) or key == "ctrl_n" then
            App.modal = "new_host_form"
            App.modal_data = {
                field = 1,
                host = (d.filter or ""):gsub("^%s+", ""):gsub("%s+$", ""),
                port = "22",
                user = "",
                key = "",
                dir = "~",
                save = false,
                alias = "",
                is_edit = false,
                error = nil,
            }
        elseif (key == "e" and (not d.filter or d.filter == "")) or key == "ctrl_e" then
            local sel = filtered[cur]
            if sel then
                if sel.is_form_launcher then
                    App.modal = "new_host_form"
                    App.modal_data = {
                        field = 1,
                        host = "",
                        port = "22",
                        user = "",
                        key = "",
                        dir = "~",
                        save = false,
                        alias = "",
                        is_edit = false,
                        error = nil,
                    }
                elseif sel.is_demo then
                    App.status_msg = "Demo server is built-in and cannot be edited."
                    App.status_color = C.yellow
                else
                    App.modal = "new_host_form"
                    App.modal_data = {
                        field = 1,
                        host = sel.hostname or "",
                        port = sel.port or "22",
                        user = sel.user or "",
                        key = sel.key or "",
                        dir = "~",
                        save = true,
                        alias = sel.name or "",
                        is_edit = true,
                        original_alias = sel.name or "",
                        original_file = sel.source_file or (get_home_dir() .. "/.ssh/config"),
                        error = nil,
                    }
                end
            end
        elseif (key == "d" and (not d.filter or d.filter == "")) or key == "delete" or key == "ctrl_d" then
            local sel = filtered[cur]
            if sel then
                if sel.is_form_launcher or sel.is_demo then
                    App.status_msg = "Built-in action cannot be deleted."
                    App.status_color = C.yellow
                elseif sel.source == "hosts-file" then
                    App.status_msg = "Cannot delete /etc/hosts entry (read-only system file)."
                    App.status_color = C.yellow
                else
                    App.modal = "confirm_delete_host"
                    App.modal_data = {
                        target = sel,
                        prev_cursor = cur,
                    }
                end
            end
        elseif key == "enter" or key == "l" or key == "right" then
            local sel = filtered[cur]
            if sel then
                if sel.is_form_launcher then
                    App.modal = "new_host_form"
                    App.modal_data = {
                        field = 1,
                        host = (d.filter or ""):gsub("^%s+", ""):gsub("%s+$", ""),
                        port = "22",
                        user = "",
                        key = "",
                        dir = "~",
                        save = false,
                        alias = "",
                        is_edit = false,
                        error = nil,
                    }
                else
                    App.host_cfg = sel
                    App.modal = nil
                    App.active_pane = "right"
                    App.right.dir = sel.is_demo and "/home/user" or "~"
                    remote_cache = {}
                    local target_name = (sel.name and sel.name ~= "") and sel.name or sel.hostname
                    App.status_msg = "Connecting to " .. target_name .. "..."
                    App.status_color = C.bright_cyan
                    App.draw()
                    App.refresh_right(true)
                end
            end
        elseif key == "backspace" then
            if d.filter and #d.filter > 0 then
                d.filter = d.filter:sub(1, -2)
                update_filter()
            end
        elseif key == "esc" then
            if d.filter and #d.filter > 0 then
                d.filter = ""
                update_filter()
            else
                App.modal = nil
                App.status_msg = "Switched to Demo Mode. Press [H] to pick SSH host."
                App.status_color = C.yellow
            end
        elseif key:len() == 1 and (key:match("[%w_%-%.%@%:]") or key == "@" or key == ":") then
            d.filter = (d.filter or "") .. key
            update_filter()
        end
        return
    elseif App.modal == "new_host_form" then
        local d = App.modal_data
        local max_fields = d.save and 7 or 6
        if key == "esc" then
            local hosts = aggregate_ssh_hosts()
            table.insert(hosts, 1, {
                name = "[+] New Form",
                hostname = "(press 'n' for form dialog)",
                user = "-",
                port = "22",
                source = "form",
                is_form_launcher = true,
            })
            table.insert(hosts, 2, {
                name = "[Demo Server]",
                hostname = "demo-server.local",
                user = "user",
                port = "22",
                source = "demo",
                is_demo = true,
            })
            App.modal = "host_picker"
            App.modal_data = {
                hosts = hosts,
                filtered = hosts,
                cursor = 1,
                filter = "",
            }
        elseif key == "tab" or key == "down" then
            d.field = (d.field % max_fields) + 1
            d.error = nil
        elseif key == "up" then
            d.field = d.field - 1
            if d.field < 1 then d.field = max_fields end
            d.error = nil
        elseif key == "space" and d.field == 6 then
            d.save = not d.save
            if d.save and (not d.alias or d.alias == "") then
                d.alias = d.host or ""
            end
        elseif key == "enter" or key == "ctrl_s" then
            local host_val = (d.host or ""):gsub("^%s+", ""):gsub("%s+$", "")
            if host_val == "" then
                d.error = "Host / IP cannot be empty."
                d.field = 1
            else
                local port_val = (d.port or ""):gsub("^%s+", ""):gsub("%s+$", "")
                if port_val == "" then port_val = "22" end
                local user_val = (d.user or ""):gsub("^%s+", ""):gsub("%s+$", "")
                local key_val = (d.key or ""):gsub("^%s+", ""):gsub("%s+$", "")
                local dir_val = (d.dir or ""):gsub("^%s+", ""):gsub("%s+$", "")
                if dir_val == "" then dir_val = "~" end
                local alias_val = (d.alias or ""):gsub("^%s+", ""):gsub("%s+$", "")
                if alias_val == "" then alias_val = host_val end

                if d.save then
                    if d.is_edit and d.original_alias then
                        update_host_in_ssh_config(d.original_alias, alias_val, host_val, user_val, port_val, key_val, d.original_file)
                    else
                        save_host_to_ssh_config(alias_val, host_val, user_val, port_val, key_val)
                    end
                end

                if key == "ctrl_s" then
                    local hosts = aggregate_ssh_hosts()
                    table.insert(hosts, 1, {
                        name = "[+] New Form",
                        hostname = "(press 'n' for form dialog)",
                        user = "-",
                        port = "22",
                        source = "form",
                        is_form_launcher = true,
                    })
                    table.insert(hosts, 2, {
                        name = "[Demo Server]",
                        hostname = "demo-server.local",
                        user = "user",
                        port = "22",
                        source = "demo",
                        is_demo = true,
                    })
                    App.modal = "host_picker"
                    App.modal_data = {
                        hosts = hosts,
                        filtered = hosts,
                        cursor = 1,
                        filter = "",
                    }
                    App.status_msg = string.format("Host '%s' saved to configuration.", alias_val)
                    App.status_color = C.bright_green
                else
                    App.host_cfg = {
                        name = alias_val,
                        hostname = host_val,
                        user = user_val,
                        port = port_val,
                        key = (key_val ~= "") and key_val or nil,
                        source = d.save and "ssh-config" or "custom",
                        is_demo = false,
                    }
                    App.modal = nil
                    App.active_pane = "right"
                    App.right.dir = dir_val
                    remote_cache = {}
                    App.status_msg = "Connecting to " .. App.host_cfg.name .. "..."
                    App.status_color = C.bright_cyan
                    App.draw()
                    App.refresh_right(true)
                end
            end
        elseif key == "backspace" then
            d.error = nil
            if d.field == 1 then d.host = (d.host or ""):sub(1, -2)
            elseif d.field == 2 then d.port = (d.port or ""):sub(1, -2)
            elseif d.field == 3 then d.user = (d.user or ""):sub(1, -2)
            elseif d.field == 4 then d.key = (d.key or ""):sub(1, -2)
            elseif d.field == 5 then d.dir = (d.dir or ""):sub(1, -2)
            elseif d.field == 7 then d.alias = (d.alias or ""):sub(1, -2)
            end
        elseif key:len() == 1 then
            d.error = nil
            if d.field == 1 and (key:match("[%w_%-%.%@%:]") or key == "@" or key == ":") then
                d.host = (d.host or "") .. key
            elseif d.field == 2 and key:match("%d") then
                d.port = (d.port or "") .. key
            elseif d.field == 3 and key:match("[%w_%-%.]") then
                d.user = (d.user or "") .. key
            elseif d.field == 4 and (key:match("[%w_%-%./~]") or key == "/" or key == "~") then
                d.key = (d.key or "") .. key
            elseif d.field == 5 and (key:match("[%w_%-%./~]") or key == "/" or key == "~") then
                d.dir = (d.dir or "") .. key
            elseif d.field == 7 and key:match("[%w_%-%.]") then
                d.alias = (d.alias or "") .. key
            end
        end
        return
    end

    -- Normal TUI Key Navigation
    local cur_pane = (App.active_pane == "left") and App.left or App.right
    local other_pane = (App.active_pane == "left") and App.right or App.left
    local items = App.get_filtered_items(cur_pane)

    if key == "tab" then
        App.active_pane = (App.active_pane == "left") and "right" or "left"
        App.status_msg = "Switched to " .. ((App.active_pane == "left") and "Local" or "Remote") .. " pane."
        App.status_color = C.gray
    elseif key == "up" or key == "k" then
        if cur_pane.cursor > 1 then
            cur_pane.cursor = cur_pane.cursor - 1
        end
    elseif key == "down" or key == "j" then
        if cur_pane.cursor < #items then
            cur_pane.cursor = cur_pane.cursor + 1
        end
    elseif key == "pageup" then
        cur_pane.cursor = math.max(1, cur_pane.cursor - 15)
    elseif key == "pagedown" then
        cur_pane.cursor = math.min(#items, cur_pane.cursor + 15)
    elseif key == "home" then
        cur_pane.cursor = 1
    elseif key == "end" then
        cur_pane.cursor = math.max(1, #items)
    elseif key == "enter" or key == "l" or key == "right" then
        local it = items[cur_pane.cursor]
        if it and it.is_dir then
            if it.name == ".." then
                cur_pane.dir = get_parent_dir(cur_pane.dir)
            else
                cur_pane.dir = normalize_path(cur_pane.dir .. "/" .. it.name)
            end
            cur_pane.cursor = 1
            cur_pane.scroll_top = 1
            cur_pane.selected = {}
            if App.active_pane == "left" then
                App.refresh_left()
            else
                App.refresh_right(false)
            end
        elseif it and not it.is_dir then
            App.status_msg = string.format("File: %s (%s, %s)", it.name, format_size(it.size), it.mtime or "-")
            App.status_color = C.bright_cyan
        end
    elseif key == "backspace" or key == "h" or key == "left" then
        cur_pane.dir = get_parent_dir(cur_pane.dir)
        cur_pane.cursor = 1
        cur_pane.scroll_top = 1
        cur_pane.selected = {}
        if App.active_pane == "left" then
            App.refresh_left()
        else
            App.refresh_right(false)
        end
    elseif key == "space" then
        local it = items[cur_pane.cursor]
        if it and it.name ~= ".." then
            cur_pane.selected[it.name] = not cur_pane.selected[it.name]
            if cur_pane.cursor < #items then
                cur_pane.cursor = cur_pane.cursor + 1
            end
        end
    elseif key == "a" then
        -- Select all items
        for _, it in ipairs(items) do
            if it.name ~= ".." then
                cur_pane.selected[it.name] = true
            end
        end
        App.status_msg = "Selected all items in active pane."
        App.status_color = C.yellow
    elseif key == "A" then
        -- Clear selection
        cur_pane.selected = {}
        App.status_msg = "Selection cleared."
        App.status_color = C.gray
    elseif key == "u" or (App.active_pane == "left" and key == "f5") then
        -- Upload from Left to Right
        local sel_items = {}
        local sel_bytes = 0
        for _, it in ipairs(App.left.items) do
            if App.left.selected[it.name] and it.name ~= ".." then
                table.insert(sel_items, it.name)
                sel_bytes = sel_bytes + (it.size or 0)
            end
        end
        if #sel_items == 0 then
            local hovered = App.left.items[App.left.cursor]
            if hovered and hovered.name ~= ".." then
                table.insert(sel_items, hovered.name)
                sel_bytes = hovered.size or 0
            end
        end
        if #sel_items > 0 then
            App.modal = "confirm_transfer"
            App.modal_data = {
                direction = "upload",
                items = sel_items,
                count = #sel_items,
                bytes = sel_bytes,
            }
        else
            App.status_msg = "No files or folders selected to upload."
            App.status_color = C.yellow
        end
    elseif key == "d" or (App.active_pane == "right" and key == "f5") then
        -- Download from Right to Left
        local sel_items = {}
        local sel_bytes = 0
        for _, it in ipairs(App.right.items) do
            if App.right.selected[it.name] and it.name ~= ".." then
                table.insert(sel_items, it.name)
                sel_bytes = sel_bytes + (it.size or 0)
            end
        end
        if #sel_items == 0 then
            local hovered = App.right.items[App.right.cursor]
            if hovered and hovered.name ~= ".." then
                table.insert(sel_items, hovered.name)
                sel_bytes = hovered.size or 0
            end
        end
        if #sel_items > 0 then
            App.modal = "confirm_transfer"
            App.modal_data = {
                direction = "download",
                items = sel_items,
                count = #sel_items,
                bytes = sel_bytes,
            }
        else
            App.status_msg = "No files or folders selected to download."
            App.status_color = C.yellow
        end
    elseif key == "r" then
        if App.active_pane == "left" then
            App.refresh_left()
            App.status_msg = "Local directory refreshed."
            App.status_color = C.green
        else
            local target_name = get_ssh_target(App.host_cfg)
            App.status_msg = "Reconnecting and refreshing " .. target_name .. "..."
            App.status_color = C.bright_cyan
            App.draw()
            App.refresh_right(true)
        end
    elseif key == "~" then
        cur_pane.dir = get_home_dir()
        cur_pane.cursor = 1
        cur_pane.scroll_top = 1
        if App.active_pane == "left" then App.refresh_left() else App.refresh_right(false) end
    elseif key == "." then
        App.show_hidden = not App.show_hidden
        App.status_msg = App.show_hidden and "Showing hidden files and folders." or "Hidden files/folders are now hidden."
        App.status_color = App.show_hidden and C.bright_yellow or C.gray
        local left_items = App.get_filtered_items(App.left)
        if App.left.cursor > #left_items then App.left.cursor = math.max(1, #left_items) end
        local right_items = App.get_filtered_items(App.right)
        if App.right.cursor > #right_items then App.right.cursor = math.max(1, #right_items) end
    elseif key == "H" then
        local hosts = aggregate_ssh_hosts()
        table.insert(hosts, 1, {
            name = "[+] New Form",
            hostname = "(press 'n' for form dialog)",
            user = "-",
            port = "22",
            source = "form",
            is_form_launcher = true,
        })
        table.insert(hosts, 2, {
            name = "[Demo Server]",
            hostname = "demo-server.local",
            user = "user",
            port = "22",
            source = "demo",
            is_demo = true,
        })
        App.modal = "host_picker"
        App.modal_data = {
            hosts = hosts,
            filtered = hosts,
            cursor = 1,
            filter = "",
        }
    elseif key == "?" then
        App.modal = "help"
    elseif key == "q" or key == "ctrl_c" then
        App.running = false
    end
end

--------------------------------------------------------------------------------
-- Main Entrypoint & Lifecycle
--------------------------------------------------------------------------------
local function main(...)
    local args = { ... }

    -- Invocation detection: fpush, fpull, or fscp
    local invoked_name = (arg and arg[0]) or ""
    local is_fpush = invoked_name:match("push") ~= nil
    local is_fpull = invoked_name:match("pull") ~= nil

    local mode_pull = is_fpull
    local force_fzf = false
    local force_tui = false
    local is_demo = false
    local is_ascii = false
    local dry_run = false
    local is_rsync = is_rsync_available()

    local cli_host = nil
    local cli_remote_path = nil
    local cli_local_path = "."
    local override_user = ""
    local override_port = ""
    local override_key = ""
    local local_files = {}

    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "--test" then
            print(C.bold .. C.bright_cyan .. "[TEST] Running FSCP Unified Verification Suite..." .. C.reset)
            -- 1. Test local listing
            local local_items = list_local_directory(".")
            assert(#local_items > 0, "Local items count should be > 0")
            print(string.format("  [PASS] list_local_directory('.'): found %d items", #local_items))

            -- 2. Test remote demo listing
            local demo_cfg = { name = "demo", is_demo = true }
            local remote_items, err = list_remote_directory(demo_cfg, "/home/user/app")
            assert(#remote_items > 0, "Remote items count should be > 0")
            assert(not err, "Remote listing should not error")
            print(string.format("  [PASS] list_remote_directory(demo, '/home/user/app'): found %d items", #remote_items))
            local home_items = list_remote_directory(demo_cfg, "~")
            assert(#home_items > 0, "Remote home listing should find items")
            local app_items = list_remote_directory(demo_cfg, "~/app")
            assert(#app_items > 0, "Remote subpath ~/app should find items")
            print("  [PASS] list_remote_directory tilde resolution tests")

            -- 3. Test host aggregation
            local hosts = aggregate_ssh_hosts()
            assert(#hosts > 0, "aggregate_ssh_hosts() should find hosts")
            print(string.format("  [PASS] aggregate_ssh_hosts(): found %d host(s)", #hosts))

            -- 4. Test format_size
            assert(format_size(500) == "500 B", "format_size 500 B failed")
            assert(format_size(2048) == "2.0 KB", "format_size 2.0 KB failed")
            assert(format_size(1048576) == "1.0 MB", "format_size 1.0 MB failed")
            print("  [PASS] format_size unit tests")

            -- 5. Test parent dir logic
            assert(get_parent_dir("/var/www/html") == "/var/www", "Parent dir failed")
            assert(get_parent_dir("C:/test/utils") == "C:/test", "Parent dir Windows failed")
            print("  [PASS] get_parent_dir unit tests")

            -- 6. Test App selection and state
            App.left.items = local_items
            local target_item = (local_items[1].name == "..") and local_items[2] or local_items[1]
            App.left.selected[target_item.name] = true
            local count, bytes = App.get_selected_count(App.left)
            assert(count == 1, "Selection count should be 1")
            print(string.format("  [PASS] Selection engine: 1 item (%s: %s)", target_item.name, format_size(bytes)))

            -- 7. Test hidden items filtering
            App.show_hidden = false
            local filtered_off = App.get_filtered_items(App.left)
            for _, it in ipairs(filtered_off) do
                assert(it.name == ".." or it.name:sub(1, 1) ~= ".", "Hidden item should not appear when show_hidden is false: " .. it.name)
            end
            App.show_hidden = true
            local filtered_on = App.get_filtered_items(App.left)
            assert(#filtered_on >= #filtered_off, "Show hidden ON should have >= items than OFF")
            App.show_hidden = false
            print("  [PASS] Hidden items filtering tests")

            -- 8. Test UTF-8 width and ANSI box alignment
            local test_str = C.bold .. C.bright_cyan .. "FSCP-TUI v1.0" .. C.reset .. " ── Dual-Pane"
            assert(utf8_col_width(test_str) == 26, "Visible width should be 26, got " .. utf8_col_width(test_str))
            local padded = pad_ansi_box(test_str, 40)
            assert(utf8_col_width(padded) == 40, "Padded string should have width 40")
            print("  [PASS] UTF-8 column width and alignment tests")

            -- 9. Test get_file_icon for directories, extensions, and ASCII fallback
            local prev_box = BOX
            BOX = BOX_UNICODE
            local dir_icon = get_file_icon("bin", true)
            assert(dir_icon:find("📁"), "Directory icon should contain folder emoji")
            local dot_dir_icon = get_file_icon("..", true)
            assert(dot_dir_icon:find("📁"), "Parent dir icon should contain folder emoji")
            assert(get_file_icon("test.lua", false):find("🌙"), "Lua icon should be crescent moon")
            assert(get_file_icon("test.py", false):find("🐍"), "Python icon should be snake")
            assert(get_file_icon("test.sh", false):find("⚡"), "Shell icon should be lightning")
            assert(get_file_icon("test.md", false):find("📝"), "Markdown icon should be memo")
            assert(get_file_icon("test.json", false):find("⚙"), "Config icon should be gear")
            assert(get_file_icon("test.zip", false):find("📦"), "Archive icon should be package")
            assert(get_file_icon("test.png", false):find("🖼"), "Image icon should be frame")
            assert(get_file_icon("test.c", false):find("📜"), "C source icon should be scroll")
            assert(get_file_icon("test.exe", false):find("🔧"), "Exe icon should be wrench")
            assert(get_file_icon("unknown.xyz", false):find("📄"), "Default icon should be document")

            BOX = BOX_ASCII
            assert(get_file_icon("bin", true):find("%[DIR%]"), "ASCII dir icon should contain [DIR]")
            assert(get_file_icon("test.lua", false) == "      ", "ASCII file icon should be 6 spaces")
            BOX = prev_box
            print("  [PASS] File and folder icons classification tests")

            -- 10. Test parse_host_string for ad-hoc IP/host connections
            local h1 = parse_host_string("192.168.1.100")
            assert(h1 and h1.hostname == "192.168.1.100" and h1.user == "" and h1.port == "22", "Plain IP parsing failed")
            local h2 = parse_host_string("root@10.0.0.5")
            assert(h2 and h2.hostname == "10.0.0.5" and h2.user == "root" and h2.port == "22", "User@IP parsing failed")
            local h3 = parse_host_string("admin@aws.corp.net:2222")
            assert(h3 and h3.hostname == "aws.corp.net" and h3.user == "admin" and h3.port == "2222", "User@host:port parsing failed")
            local h4 = parse_host_string("host.internal:8022")
            assert(h4 and h4.hostname == "host.internal" and h4.user == "" and h4.port == "8022", "Host:port parsing failed")
            assert(parse_host_string("") == nil, "Empty string should return nil")
            assert(parse_host_string("   ") == nil, "Whitespace string should return nil")
            assert(parse_host_string("@") == nil, "@ should return nil")
            assert(parse_host_string("user@") == nil, "Trailing @ should return nil")
            assert(parse_host_string(":22") == nil, "Missing host should return nil")
            assert(parse_host_string("user@host:") == nil, "Trailing colon should return nil")
            print("  [PASS] Ad-hoc host and IP parsing unit tests")

            -- 11. Test get_ssh_target alias preservation
            local ssh_cfg_host = { name = "my-box", hostname = "192.168.1.10", user = "admin", port = "22", source = "ssh-config" }
            assert(get_ssh_target(ssh_cfg_host) == "my-box", "SSH config host must preserve alias name as target")
            local custom_host = { name = "[Direct Connect]", hostname = "10.0.0.1", user = "root", port = "22", source = "custom" }
            assert(get_ssh_target(custom_host) == "root@10.0.0.1", "Custom host must include user@hostname")
            print("  [PASS] get_ssh_target alias and host resolution unit tests")

            -- 12. Test expand_glob
            local glob_res = expand_glob("bin/fscp*")
            assert(#glob_res >= 1, "expand_glob('bin/fscp*') should find at least 1 matching file")
            print("  [PASS] expand_glob pattern matching tests")

            -- 13. Test new_host_form modal state initialization and validation
            App.modal = "new_host_form"
            App.modal_data = {
                field = 1,
                host = "192.168.1.99",
                port = "2222",
                user = "admin",
                key = "~/.ssh/id_ed25519",
                dir = "/srv",
                save = false,
                alias = "my-box",
            }
            assert(App.modal_data.field == 1, "Field index should be 1")
            assert(App.modal_data.host == "192.168.1.99", "Host should match")
            assert(App.modal_data.port == "2222", "Port should match")
            assert(App.modal_data.key == "~/.ssh/id_ed25519", "SSH Key should match")
            App.modal = nil
            print("  [PASS] Hybrid new connection form state with SSH key tests")

            -- 14. Test SSH config create, in-place update, and delete
            local tmp_cfg = "/tmp/test_ssh_config_" .. tostring(os.time())
            local init_content = "# Base SSH Config\nInclude ~/.ssh/config.base\n\nHost existing-node\n    HostName 10.0.0.1\n    User admin\n"
            local cf = io.open(tmp_cfg, "w")
            cf:write(init_content)
            cf:close()

            local saved = save_host_to_ssh_config("new-node", "10.0.0.2", "deploy", "2200", "~/.ssh/key2", tmp_cfg)
            assert(saved, "save_host_to_ssh_config failed")
            local hosts_after_save = parse_ssh_config(tmp_cfg)
            assert(#hosts_after_save == 2, "Expected 2 hosts after save, got " .. #hosts_after_save)

            local updated = update_host_in_ssh_config("new-node", "renamed-node", "10.0.0.3", "root", "22", "", tmp_cfg)
            assert(updated, "update_host_in_ssh_config failed")
            local hosts_after_upd = parse_ssh_config(tmp_cfg)
            local found_renamed = false
            for _, h in ipairs(hosts_after_upd) do
                if h.name == "renamed-node" and h.hostname == "10.0.0.3" then found_renamed = true end
            end
            assert(found_renamed, "Renamed host not found in config")

            local deleted = delete_host_from_ssh_config("renamed-node", tmp_cfg)
            assert(deleted, "delete_host_from_ssh_config failed")
            local hosts_after_del = parse_ssh_config(tmp_cfg)
            assert(#hosts_after_del == 1, "Expected 1 host after delete, got " .. #hosts_after_del)
            assert(hosts_after_del[1].name == "existing-node", "Remaining host should be existing-node")
            os.remove(tmp_cfg)
            print("  [PASS] SSH config create, in-place edit, and delete lifecycle tests")

            -- 15. Test Modal rendering execution
            App.term_w, App.term_h = 100, 30
            App.modal = "host_picker"
            App.modal_data = { hosts = hosts, filtered = hosts, cursor = 1, filter = "" }
            App.draw()
            assert(App.modal == "host_picker", "host_picker modal state preserved")

            App.modal = "confirm_delete_host"
            App.modal_data = { target = { name = "test-node", hostname = "10.0.0.99", source = "ssh-config" }, prev_cursor = 1 }
            App.draw()
            assert(App.modal == "confirm_delete_host", "confirm_delete_host modal state preserved")

            App.modal = "new_host_form"
            App.modal_data = { field = 1, host = "test", port = "22", user = "u", key = "", dir = "~", save = false, alias = "t" }
            App.draw()
            assert(App.modal == "new_host_form", "new_host_form modal state preserved")
            App.modal = nil
            print("  [PASS] Modal rendering execution (host_picker, confirm_delete_host, new_host_modal) tests")

            -- 16. Test Delete confirmation cancellation and execution event flow
            App.modal = "confirm_delete_host"
            App.modal_data = { target = { name = "dummy", source = "ssh-config" }, prev_cursor = 2 }
            App.handle_input("n")
            assert(App.modal == "host_picker", "'n' should cancel delete and return to host_picker")
            assert(App.status_msg:find("cancelled"), "Status should indicate cancellation")

            -- 17. Test format_preview
            local prev_card = format_preview({ name = "testbox", hostname = "10.0.0.1", user = "admin", port = "22", source = "ssh-config" }, true)
            assert(prev_card:find("testbox"), "Preview card must contain host name")
            assert(prev_card:find("rsync"), "Preview card must show rsync tool")
            print("  [PASS] format_preview card generation unit tests")

            -- 18. Test is_rsync_available
            local r_avail = is_rsync_available()
            assert(type(r_avail) == "boolean", "is_rsync_available must return boolean")
            print(string.format("  [PASS] is_rsync_available(): %s", tostring(r_avail)))

            -- 19. Test parse_ls_line for Active Directory domain groups and various formats
            local ad_line = "drwxrwxr-x 2 alice Domain Users 4096 2026-10-18 09:30:00 shared_dept"
            local ad_item = parse_ls_line(ad_line)
            assert(ad_item ~= nil, "Domain Users directory must not be nil")
            assert(ad_item.name == "shared_dept", "Name must be shared_dept")
            assert(ad_item.is_dir == true, "Must be directory")

            local both_domain = "drwxrwxr-x 2 DOMAIN\\alice DOMAIN\\Domain Admins 8192 2026-10-18 09:30:00 admin_dept"
            local bd_item = parse_ls_line(both_domain)
            assert(bd_item and bd_item.name == "admin_dept" and bd_item.is_dir == true)

            local old_file = "drwxr-xr-x 2 user Domain Users 4096 Oct 18  2024 archive_dept"
            local old_item = parse_ls_line(old_file)
            assert(old_item and old_item.name == "archive_dept" and old_item.is_dir == true)

            local macos_line = "drwxr-xr-x@ 4 user staff 128 Oct 18 09:30 macos_dept"
            local macos_item = parse_ls_line(macos_line)
            assert(macos_item and macos_item.name == "macos_dept" and macos_item.is_dir == true)

            local symlink_line = "lrwxrwxrwx 1 user group 14 2026-10-18 09:30:00 symlink_dept -> /mnt/target"
            local sym_item = parse_ls_line(symlink_line)
            assert(sym_item and sym_item.name == "symlink_dept" and sym_item.is_dir == true)
            print("  [PASS] parse_ls_line Active Directory, domain groups, and format tests")

            print(C.bold .. C.bright_green .. "[ALL TESTS PASSED SUCCESSFULLY]" .. C.reset)
            return
        elseif a == "--snapshot" then
            App.term_w, App.term_h = 98, 22
            App.host_cfg = {
                name = "dev-server",
                hostname = "dev-server.local",
                user = "zliu",
                port = "22",
                is_demo = true,
            }
            App.left.dir = "C:/test/utils"
            App.right.dir = "/var/www/html"
            App.refresh_left()
            App.refresh_right(false)
            for _, it in ipairs(App.left.items) do
                if it.name == "deploy.sh" or it.name == "notes.md" then
                    App.left.selected[it.name] = true
                end
                if it.name == "deploy_gui.py" then
                    App.left.cursor = _
                end
            end
            for _, it in ipairs(App.right.items) do
                if it.name == "app.js" then
                    App.right.selected[it.name] = true
                end
            end
            App.status_msg = "Ready. 2 local files selected (45.4 KB). Press 'u' to upload."
            App.status_color = C.bright_yellow
            App.draw()
            return
        elseif a == "-l" or a == "--list-hosts" then
            local all_hosts = aggregate_ssh_hosts()
            for _, h in ipairs(all_hosts) do
                local dest = (h.user and h.user ~= "") and (h.user .. "@" .. (h.hostname or h.name)) or (h.hostname or h.name)
                print(string.format("%s\t%s\t%s\t%s", h.name, dest, h.port or "22", h.source or "unknown"))
            end
            return
        elseif a == "--preview-only" and i + 1 <= #args then
            i = i + 1
            local target = args[i]:lower():gsub('^["\']', ''):gsub('["\']$', '')
            local all_hosts = aggregate_ssh_hosts()
            for _, h in ipairs(all_hosts) do
                if h.name:lower() == target or (h.hostname and h.hostname:lower() == target) then
                    print(format_preview(h, is_rsync))
                    return
                end
            end
            print("Host: " .. target)
            return
        elseif a == "-h" or a == "--help" then
            print([[fscp - Fast Dual-Pane TUI & CLI Remote File Transfer Tool (LuaJIT FFI)

Usage:
  fscp [HOST] [REMOTE_PATH] [LOCAL_PATH]   # Launch Dual-Pane TUI (Default)
  fscp --fzf                               # Launch FZF interactive transfer
  fscp [OPTIONS] [LOCAL_FILES...]          # Headless push transfer
  fscp -P [OPTIONS]                        # Headless pull transfer

Interactive TUI Options:
  --demo                      Launch TUI in simulated offline demo mode
  --ascii                     Use ASCII box characters instead of Unicode
  --tui                       Explicitly force Dual-Pane TUI mode

Interactive FZF Options:
  --fzf                       Launch FZF fuzzy host and file selector pipeline

Direct CLI & Headless Options:
  -H, --host <HOST>           Specify target remote host
  -t, --to <REMOTE_PATH>      Specify remote directory or destination path
  -P, --pull                  Pull mode (download remote files to local directory)
      --push                  Push mode (upload local files to remote destination)
  -r, --rsync                 Use rsync (-avzP) for transfer
      --scp, --no-rsync       Force standard SCP / PuTTY PSCP
  -u, --user <USER>           Override remote SSH username
  -p, --port <PORT>           Override remote SSH port
  -i, --identity <KEY>        Specify SSH private key file
  -d, --dry-run               Print command without executing
  -l, --list-hosts            List all configured hosts in TSV format
  --preview-only <HOST>       Print host preview card (for FZF)
  --test                      Run comprehensive automated test suite
  --snapshot                  Dump TUI layout snapshot
  -h, --help                  Show this help message

TUI Keybindings:
  Tab            Switch active pane (Local <-> Remote)
  Up / Down      Move cursor (or k / j)
  Enter / Right  Drill into directory
  Backspace/Left Parent directory (..)
  Space          Toggle multi-select on file/folder
  a / A          Select All / Deselect All
  u / F5         Upload to remote current directory
  d / F5         Download to local current directory
  r              Refresh active pane
  H              Open Host / Server Picker
  n              Add new SSH connection form
  ?              Help screen
  q              Quit
]])
            return
        elseif a == "--demo" then
            is_demo = true
            force_tui = true
        elseif a == "--ascii" then
            BOX = BOX_ASCII
            force_tui = true
        elseif a == "--tui" then
            force_tui = true
        elseif a == "--fzf" then
            force_fzf = true
        elseif a == "-r" or a == "--rsync" then
            is_rsync = true
        elseif a == "--scp" or a == "--no-rsync" then
            is_rsync = false
        elseif a == "-P" or a == "--pull" then
            mode_pull = true
        elseif a == "--push" then
            mode_pull = false
        elseif (a == "-t" or a == "--to") and i + 1 <= #args then
            i = i + 1
            cli_remote_path = args[i]
        elseif (a == "-H" or a == "--host") and i + 1 <= #args then
            i = i + 1
            cli_host = args[i]
        elseif (a == "-u" or a == "--user") and i + 1 <= #args then
            i = i + 1
            override_user = args[i]
        elseif (a == "-p" or a == "--port") and i + 1 <= #args then
            i = i + 1
            override_port = args[i]
        elseif (a == "-i" or a == "--identity") and i + 1 <= #args then
            i = i + 1
            override_key = args[i]
        elseif a == "-d" or a == "--dry-run" then
            dry_run = true
        elseif not a:match("^-") then
            table.insert(local_files, a)
        end
        i = i + 1
    end

    if dry_run and (not cli_host or trim(cli_host) == "") then
        io.stderr:write("Error: --dry-run requires a host. Use --host <HOST> (or -H <HOST>).\n")
        os.exit(1)
    end

    local all_hosts = aggregate_ssh_hosts()

    -- Execution Dispatching:
    -- 1. Direct Headless CLI Transfer
    if dry_run or (cli_host and (#local_files > 0 or (mode_pull and cli_remote_path))) then
        local target = nil
        for _, h in ipairs(all_hosts) do
            if h.name:lower() == cli_host:lower() or (h.hostname and h.hostname:lower() == cli_host:lower()) then
                target = h
                break
            end
        end
        if not target then
            local parsed = parse_host_string(cli_host)
            if parsed then
                parsed.name = cli_host
                target = parsed
            else
                target = {
                    name = cli_host,
                    hostname = cli_host,
                    user = override_user,
                    port = override_port ~= "" and override_port or "22",
                    key = override_key ~= "" and override_key or nil,
                    source = "custom",
                }
            end
        end
        execute_headless_transfer(target, local_files, cli_remote_path, mode_pull, is_rsync, override_user, override_port, override_key, dry_run)
        return
    end

    -- 2. Interactive FZF Pipeline (invoked via --fzf or fpush/fpull without TUI flags)
    if force_fzf or ((is_fpush or is_fpull) and not force_tui and #local_files == 0) then
        local selected_host = nil
        if cli_host then
            for _, h in ipairs(all_hosts) do
                if h.name:lower() == cli_host:lower() or (h.hostname and h.hostname:lower() == cli_host:lower()) then
                    selected_host = h
                    break
                end
            end
        end
        if not selected_host then
            selected_host = run_fzf_host_picker(all_hosts, is_rsync, mode_pull)
        end
        if not selected_host then return end

        if mode_pull then
            if not cli_remote_path or cli_remote_path == "" then
                if not dry_run and (IS_WINDOWS or ffi.C.isatty(0) ~= 0) then
                    local picked = run_fzf_remote_file_picker(selected_host, override_user, override_port, override_key)
                    if picked and picked ~= "" then
                        cli_remote_path = picked
                    end
                end
                if not cli_remote_path or cli_remote_path == "" then
                    cli_remote_path = "~/"
                end
            end
        else
            if #local_files == 0 then
                local_files = run_fzf_file_picker()
                if #local_files == 0 then
                    print("No files selected. Aborted.")
                    return
                end
            end
            if not cli_remote_path or cli_remote_path == "" then
                cli_remote_path = "~/"
            end
        end

        execute_headless_transfer(selected_host, local_files, cli_remote_path, mode_pull, is_rsync, override_user, override_port, override_key, dry_run)
        return
    end

    -- 3. Dual-Pane Interactive TUI (Default Mode!)
    -- Resolve positional arguments for TUI: [HOST] [REMOTE_PATH] [LOCAL_PATH]
    if #local_files > 0 and not cli_host then
        cli_host = local_files[1]
        if local_files[2] then cli_remote_path = local_files[2] end
        if local_files[3] then cli_local_path = local_files[3] end
    end

    Term.init()

    -- Configure Initial Remote Host
    if is_demo or cli_host == "demo" then
        App.host_cfg = {
            name = "demo",
            hostname = "demo-server",
            user = "user",
            port = "22",
            is_demo = true,
        }
    elseif cli_host then
        local found_cfg = nil
        for _, h in ipairs(all_hosts) do
            if h.name:lower() == cli_host:lower() or (h.hostname and h.hostname:lower() == cli_host:lower()) then
                found_cfg = h
                break
            end
        end
        if found_cfg then
            App.host_cfg = found_cfg
        else
            local parsed = parse_host_string(cli_host)
            if parsed then
                parsed.name = cli_host
                App.host_cfg = parsed
            else
                App.host_cfg = {
                    name = cli_host,
                    hostname = cli_host,
                    user = override_user,
                    port = override_port ~= "" and override_port or "22",
                    key = override_key ~= "" and override_key or nil,
                    source = "custom",
                    is_demo = false,
                }
            end
        end
    else
        -- No host provided: aggregate all saved sessions and show server picker at start
        local available_hosts = aggregate_ssh_hosts()
        table.insert(available_hosts, 1, {
            name = "[+] New Form",
            hostname = "(press 'n' for form dialog)",
            user = "-",
            port = "22",
            source = "form",
            is_form_launcher = true,
        })
        table.insert(available_hosts, 2, {
            name = "[Demo Server]",
            hostname = "demo-server.local",
            user = "user",
            port = "22",
            source = "demo",
            is_demo = true,
        })
        App.host_cfg = available_hosts[2]
        App.modal = "host_picker"
        App.modal_data = {
            hosts = available_hosts,
            filtered = available_hosts,
            cursor = 1,
            filter = "",
        }
        App.status_msg = "Select a remote server to connect, or press [Esc] for Demo Mode."
        App.status_color = C.bright_yellow
    end

    if cli_remote_path and cli_remote_path ~= "" then
        App.right.dir = cli_remote_path
    elseif App.host_cfg.is_demo then
        App.right.dir = "/home/user"
    end
    if cli_local_path and cli_local_path ~= "" then
        App.left.dir = cli_local_path
    end

    App.refresh_left()
    if not App.modal and not App.host_cfg.is_demo then
        App.status_msg = "Connecting to " .. get_ssh_target(App.host_cfg) .. "..."
        App.status_color = C.bright_cyan
        App.refresh_right(true)
    else
        App.refresh_right(false)
    end

    Term.enable_raw()

    -- Safe Execution Loop
    local ok, err = xpcall(function()
        while App.running do
            App.draw()
            local key = nil
            while not key and App.running do
                key = Term.read_key()
                if not key then
                    if IS_WINDOWS then
                        ffi.C.Sleep(20)
                    else
                        ffi.C.usleep(20000)
                    end
                end
            end
            App.handle_input(key)
        end
    end, debug.traceback)

    Term.restore()

    if not ok then
        io.stderr:write("FSCP Error: " .. tostring(err) .. "\n")
    end
end

main(...)
