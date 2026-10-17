#!/usr/bin/env luajit
--[[
  fdu.lua - High-Performance Interactive Disk Usage Analyzer TUI
  Powered by LuaJIT & FFI. Single-file, zero external Lua dependencies.
  Runs natively on Windows (Win32 FindFirstFileW FFI) and Linux/POSIX (dirent + lstat FFI).

  Features:
    - Single-Pass Tree Scanner: Traverses directory tree via native OS FFI, skipping symlink/reparse
      loops, and caches all subtree sizes in memory for 0ms drill-down and parent navigation.
    - Dual-Pane Interactive TUI:
      * Left Pane: Visual usage bar chart, human-readable size, percentage, and entry name.
      * Right Pane: Detailed item inspector + live preview of top largest children inside folders.
    - Instant Drill-Down & Navigation: Enter/l/Right to enter folder, Backspace/h/Left/- to go up.
    - Safe Deletion (d / x / Del): Delete build artifacts, caches, or files with [y/N] confirmation
      and automatic parent size recalculation.
    - CLI Modes: Non-interactive summary chart (--list), top-N limit (-n <N>), and self-tests (--test).

  Usage:
    luajit bin/fdu.lua [OPTIONS] [PATH]
    fdu [OPTIONS] [PATH]

  Options:
    -l, --list           Print formatted disk usage table for PATH and exit
    -n, --top <N>        Limit --list output to top N entries (default: 25)
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

        HANDLE FindFirstFileW(LPCWSTR lpFileName, WIN32_FIND_DATAW* lpFindFileData);
        BOOL FindNextFileW(HANDLE hFindFile, WIN32_FIND_DATAW* lpFindFileData);
        BOOL FindClose(HANDLE hFindFile);
        BOOL DeleteFileW(LPCWSTR lpFileName);
        BOOL RemoveDirectoryW(LPCWSTR lpPathName);
        DWORD GetFileAttributesW(LPCWSTR lpFileName);
        BOOL SetFileAttributesW(LPCWSTR lpFileName, DWORD dwFileAttributes);
        DWORD GetFullPathNameW(LPCWSTR lpFileName, DWORD nBufferLength, LPWSTR lpBuffer, LPWSTR* lpFilePart);

        int MultiByteToWideChar(unsigned int CodePage, DWORD dwFlags, const char* lpMultiByteStr,
                                int cbMultiByte, wchar_t* lpWideCharStr, int cchWideChar);
        int WideCharToMultiByte(unsigned int CodePage, DWORD dwFlags, LPCWSTR lpWideCharStr,
                                int cchWideChar, char* lpMultiByteStr, int cbMultiByte,
                                const char* lpDefaultChar, BOOL* lpUsedDefaultChar);

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
        int unlink(const char *pathname);
        int rmdir(const char *pathname);
        char *realpath(const char *path, char *resolved_path);
        void free(void *ptr);

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
    bg_red      = "\27[41m",
}

local BOX = {
    tl = "┌", tr = "┐", bl = "└", br = "┘",
    h = "─", v = "│", vl = "├", vr = "┤",
    tt = "┬", tb = "┴", x = "┼"
}

--------------------------------------------------------------------------------
-- Formatting & String Helpers
--------------------------------------------------------------------------------
local function format_bytes(bytes)
    bytes = tonumber(bytes) or 0
    if bytes < 1024 then
        return string.format("%d B", bytes)
    elseif bytes < 1024 * 1024 then
        return string.format("%.1f KB", bytes / 1024.0)
    elseif bytes < 1024 * 1024 * 1024 then
        return string.format("%.2f MB", bytes / (1024.0 * 1024.0))
    else
        return string.format("%.2f GB", bytes / (1024.0 * 1024.0 * 1024.0))
    end
end

local function format_bar(ratio, width)
    ratio = math.max(0, math.min(1, tonumber(ratio) or 0))
    local filled = math.floor(ratio * width + 0.5)
    if ratio > 0 and filled == 0 then filled = 1 end
    return string.rep("█", filled) .. string.rep("░", width - filled)
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
-- Fast FFI Filesystem Scanner & Deleter
--------------------------------------------------------------------------------
local FS = {}

local FILE_ATTRIBUTE_READONLY      = 0x0001
local FILE_ATTRIBUTE_DIRECTORY     = 0x0010
local FILE_ATTRIBUTE_REPARSE_POINT = 0x0400

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

function FS.resolve_path(path)
    path = (path and #path > 0) and path or "."
    if IS_WINDOWS then
        local wpath = to_wide(path)
        local buf = ffi.new("wchar_t[1024]")
        local len = ffi.C.GetFullPathNameW(wpath, 1024, buf, nil)
        if len > 0 then
            local full = from_wide(buf)
            if #full > 3 then
                full = full:gsub("[\\/]+$", "")
            end
            return full
        end
        return path
    else
        local resolved = ffi.C.realpath(path, nil)
        if resolved ~= nil then
            local s = ffi.string(resolved)
            ffi.C.free(resolved)
            return s
        end
        return path
    end
end

local function basename_of(path)
    local clean = path:gsub("[\\/]+$", "")
    return clean:match("([^\\/]+)$") or path
end

function FS.scan_tree(root_path)
    local sep = IS_WINDOWS and "\\" or "/"
    root_path = FS.resolve_path(root_path)

    local function scan_node_win32(dir_path, name, parent, depth)
        local node = {
            name = name,
            path = dir_path,
            is_dir = true,
            size = 0,
            files = 0,
            dirs = 0,
            children = {},
            parent = parent,
        }
        if depth > 32 then return node end

        local pattern = dir_path .. "\\*"
        local find_data = ffi.new("WIN32_FIND_DATAW")
        local hFind = ffi.C.FindFirstFileW(to_wide(pattern), find_data)
        if hFind == nil or hFind == ffi.cast("HANDLE", -1) then
            return node
        end

        repeat
            local fname = from_wide(find_data.cFileName)
            if fname ~= "." and fname ~= ".." then
                local attrs = find_data.dwFileAttributes
                local is_reparse = (bit.band(attrs, FILE_ATTRIBUTE_REPARSE_POINT) ~= 0)
                local is_dir = (bit.band(attrs, FILE_ATTRIBUTE_DIRECTORY) ~= 0)
                local child_path = dir_path .. sep .. fname

                if is_dir and not is_reparse then
                    local child = scan_node_win32(child_path, fname, node, depth + 1)
                    table.insert(node.children, child)
                    node.size = node.size + child.size
                    node.files = node.files + child.files
                    node.dirs = node.dirs + 1 + child.dirs
                elseif not is_dir then
                    local fsize = (tonumber(find_data.nFileSizeHigh) * 4294967296.0) + tonumber(find_data.nFileSizeLow)
                    table.insert(node.children, {
                        name = fname,
                        path = child_path,
                        is_dir = false,
                        size = fsize,
                        files = 1,
                        dirs = 0,
                        children = nil,
                        parent = node,
                    })
                    node.size = node.size + fsize
                    node.files = node.files + 1
                end
            end
        until ffi.C.FindNextFileW(hFind, find_data) == 0

        ffi.C.FindClose(hFind)
        return node
    end

    local function scan_node_posix(dir_path, name, parent, depth)
        local node = {
            name = name,
            path = dir_path,
            is_dir = true,
            size = 0,
            files = 0,
            dirs = 0,
            children = {},
            parent = parent,
        }
        if depth > 32 then return node end

        local d = ffi.C.opendir(dir_path)
        if d == nil then return node end

        while true do
            local ent = ffi.C.readdir(d)
            if ent == nil then break end
            local fname = ffi.string(ent.d_name)
            if fname ~= "." and fname ~= ".." then
                local child_path = (dir_path == "/") and ("/" .. fname) or (dir_path .. "/" .. fname)
                if ent.d_type == 4 then -- DT_DIR (do not follow DT_LNK == 10)
                    local child = scan_node_posix(child_path, fname, node, depth + 1)
                    table.insert(node.children, child)
                    node.size = node.size + child.size
                    node.files = node.files + child.files
                    node.dirs = node.dirs + 1 + child.dirs
                elseif ent.d_type == 8 or ent.d_type == 0 then
                    local f = io.open(child_path, "rb")
                    local fsize = 0
                    if f then
                        fsize = f:seek("end") or 0
                        f:close()
                    end
                    table.insert(node.children, {
                        name = fname,
                        path = child_path,
                        is_dir = false,
                        size = fsize,
                        files = 1,
                        dirs = 0,
                        children = nil,
                        parent = node,
                    })
                    node.size = node.size + fsize
                    node.files = node.files + 1
                end
            end
        end
        ffi.C.closedir(d)
        return node
    end

    local root_name = basename_of(root_path)
    if IS_WINDOWS then
        return scan_node_win32(root_path, root_name, nil, 0)
    else
        return scan_node_posix(root_path, root_name, nil, 0)
    end
end

function FS.delete_entry(target_node)
    if not target_node or not target_node.path then
        return false, "Invalid entry"
    end

    if IS_WINDOWS then
        local function del_win32(path, is_dir)
            local wpath = to_wide(path)
            if not is_dir then
                local attrs = ffi.C.GetFileAttributesW(wpath)
                if attrs ~= 0xFFFFFFFF and bit.band(attrs, FILE_ATTRIBUTE_READONLY) ~= 0 then
                    ffi.C.SetFileAttributesW(wpath, bit.band(attrs, bit.bnot(FILE_ATTRIBUTE_READONLY)))
                end
                return ffi.C.DeleteFileW(wpath) ~= 0
            end

            local find_data = ffi.new("WIN32_FIND_DATAW")
            local hFind = ffi.C.FindFirstFileW(to_wide(path .. "\\*"), find_data)
            if hFind ~= nil and hFind ~= ffi.cast("HANDLE", -1) then
                repeat
                    local fname = from_wide(find_data.cFileName)
                    if fname ~= "." and fname ~= ".." then
                        local child_path = path .. "\\" .. fname
                        local child_dir = (bit.band(find_data.dwFileAttributes, FILE_ATTRIBUTE_DIRECTORY) ~= 0)
                        local is_reparse = (bit.band(find_data.dwFileAttributes, FILE_ATTRIBUTE_REPARSE_POINT) ~= 0)
                        if child_dir and not is_reparse then
                            del_win32(child_path, true)
                        elseif child_dir and is_reparse then
                            ffi.C.RemoveDirectoryW(to_wide(child_path))
                        else
                            del_win32(child_path, false)
                        end
                    end
                until ffi.C.FindNextFileW(hFind, find_data) == 0
                ffi.C.FindClose(hFind)
            end
            return ffi.C.RemoveDirectoryW(wpath) ~= 0
        end

        local ok = del_win32(target_node.path, target_node.is_dir)
        if not ok then
            return false, "Failed to delete (file in use or access denied)"
        end
    else
        local function del_posix(path, is_dir)
            if not is_dir then
                return ffi.C.unlink(path) == 0
            end
            local d = ffi.C.opendir(path)
            if d ~= nil then
                while true do
                    local ent = ffi.C.readdir(d)
                    if ent == nil then break end
                    local fname = ffi.string(ent.d_name)
                    if fname ~= "." and fname ~= ".." then
                        local child_path = path .. "/" .. fname
                        if ent.d_type == 4 then
                            del_posix(child_path, true)
                        else
                            ffi.C.unlink(child_path)
                        end
                    end
                end
                ffi.C.closedir(d)
            end
            return ffi.C.rmdir(path) == 0
        end

        local ok = del_posix(target_node.path, target_node.is_dir)
        if not ok then
            return false, "Failed to delete entry"
        end
    end

    -- Subtract deleted size & counts from ancestor nodes
    local parent = target_node.parent
    if parent and parent.children then
        for i, ch in ipairs(parent.children) do
            if ch == target_node then
                table.remove(parent.children, i)
                break
            end
        end
        local p = parent
        while p do
            p.size = math.max(0, p.size - target_node.size)
            p.files = math.max(0, p.files - target_node.files)
            p.dirs = math.max(0, p.dirs - (target_node.is_dir and (1 + target_node.dirs) or 0))
            p._top_sub = nil
            p = p.parent
        end
    end

    return true
end

--------------------------------------------------------------------------------
-- Sorting & Filtering
--------------------------------------------------------------------------------
local SORT_MODES = { "size", "files", "name" }

local function filter_and_sort_children(node, query, sort_mode)
    local out = {}
    if not node or not node.children then return out end
    for _, ch in ipairs(node.children) do
        if not query or #query == 0 or fuzzy_score(query, ch.name) then
            table.insert(out, ch)
        end
    end
    table.sort(out, function(a, b)
        if sort_mode == "files" then
            if a.files ~= b.files then return a.files > b.files end
        elseif sort_mode == "name" then
            if a.is_dir ~= b.is_dir then return a.is_dir end
            return a.name:lower() < b.name:lower()
        end
        if a.size ~= b.size then return a.size > b.size end
        return a.name:lower() < b.name:lower()
    end)
    return out
end

--------------------------------------------------------------------------------
-- Interactive Dual-Pane TUI
--------------------------------------------------------------------------------
local function run_tui(start_path)
    Term.init()
    io.write("Scanning directory tree...\r")
    io.flush()
    local root_node = FS.scan_tree(start_path or ".")

    local state = {
        cur_node = root_node,
        cursor = 1,
        scroll = 1,
        history = {}, -- stack of { node, cursor, scroll }
        sort_idx = 1,
        query = "",
        prev_query = "",
        mode = "normal", -- "normal" | "search" | "confirm_del" | "help"
        status_msg = "",
        status_is_err = false,
        pending_g = false,
        items = {},
    }

    local function refresh_items()
        state.items = filter_and_sort_children(state.cur_node, state.query, SORT_MODES[state.sort_idx])
        state.cursor = math.min(math.max(1, state.cursor), math.max(1, #state.items))
    end

    refresh_items()

    local prev_lines = {}
    local prev_cols, prev_rows = 0, 0

    local function render()
        local cols, rows = Term.get_size()
        if cols ~= prev_cols or rows ~= prev_rows then
            prev_lines = {}
            prev_cols, prev_rows = cols, rows
            io.write("\27[2J")
        end

        local left_w = math.floor(cols * 0.56)
        if left_w < 42 then left_w = 42 end
        local right_w = cols - left_w - 3
        if right_w < 22 then right_w = 22 end
        local body_h = rows - 6
        if body_h < 6 then body_h = 6 end

        if state.cursor < state.scroll then
            state.scroll = state.cursor
        elseif state.cursor >= state.scroll + body_h - 1 then
            state.scroll = state.cursor - body_h + 2
        end
        if state.scroll < 1 then state.scroll = 1 end

        local frame_lines = {}

        -- 1. Header Bar (3 rows)
        local total_str = format_bytes(state.cur_node.size)
        local path_disp = truncate_string(state.cur_node.path, math.max(20, cols - 48))
        local hdr = string.format("%s fdu %s %s%s%s  %s[Total: %s | %d files, %d dirs]%s",
            C.b_cyan, C.reset, C.b_yellow, path_disp, C.reset,
            C.b_green, total_str, state.cur_node.files, state.cur_node.dirs, C.reset)
        table.insert(frame_lines, BOX.tl .. string.rep(BOX.h, cols - 2) .. BOX.tr)
        table.insert(frame_lines, BOX.v .. pad_string(hdr, cols - 2) .. BOX.v)
        table.insert(frame_lines, BOX.vl .. string.rep(BOX.h, left_w) .. BOX.tt .. string.rep(BOX.h, right_w) .. BOX.vr)

        -- 2. Right Pane Inspector
        local r_lines = {}
        local sel = state.items[state.cursor]
        if state.mode == "help" then
            table.insert(r_lines, C.b_yellow .. " Keyboard Shortcuts (press any key to close)" .. C.reset)
            table.insert(r_lines, C.gray .. " " .. string.rep(BOX.h, math.max(10, right_w - 2)) .. C.reset)
            table.insert(r_lines, " " .. C.b_cyan .. "j / k / Up / Down " .. C.reset .. "Move cursor")
            table.insert(r_lines, " " .. C.b_cyan .. "Enter / l / Right " .. C.reset .. "Enter selected directory")
            table.insert(r_lines, " " .. C.b_cyan .. "Bksp / h / Left/- " .. C.reset .. "Go up to parent directory")
            table.insert(r_lines, " " .. C.b_cyan .. "gg / G / Home/End " .. C.reset .. "Jump to top / bottom")
            table.insert(r_lines, " " .. C.b_cyan .. "/                 " .. C.reset .. "Filter entries by name")
            table.insert(r_lines, " " .. C.b_cyan .. "s                 " .. C.reset .. "Cycle sort (Size/Files/Name)")
            table.insert(r_lines, " " .. C.b_cyan .. "d / x / Del       " .. C.reset .. "Delete item (with [y/N] prompt)")
            table.insert(r_lines, " " .. C.b_cyan .. "r                 " .. C.reset .. "Rescan current directory tree")
            table.insert(r_lines, " " .. C.b_cyan .. "q / Esc           " .. C.reset .. "Quit fdu")
        elseif sel then
            local parent_sz = math.max(1, state.cur_node.size)
            local pct = (state.cur_node.size > 0) and ((sel.size / parent_sz) * 100.0) or 0.0
            table.insert(r_lines, C.b_cyan .. " Entry Inspector" .. C.reset)
            table.insert(r_lines, C.gray .. " " .. string.rep(BOX.h, math.max(10, right_w - 2)) .. C.reset)
            table.insert(r_lines, string.format(" %sName       :%s %s%s%s", C.gray, C.reset,
                sel.is_dir and C.b_cyan or C.b_white, sel.name .. (sel.is_dir and "/" or ""), C.reset))
            table.insert(r_lines, string.format(" %sType       :%s %s", C.gray, C.reset,
                sel.is_dir and "Directory" or "File"))
            table.insert(r_lines, string.format(" %sSize       :%s %s%s%s (%.1f%%)", C.gray, C.reset,
                C.b_yellow, format_bytes(sel.size), C.reset, pct))
            if sel.is_dir then
                table.insert(r_lines, string.format(" %sContents   :%s %d files, %d dirs",
                    C.gray, C.reset, sel.files, sel.dirs))
            end
            table.insert(r_lines, string.format(" %sFull Path  :%s %s", C.gray, C.reset,
                truncate_string(sel.path, math.max(10, right_w - 15))))
            table.insert(r_lines, "")

            if sel.is_dir and sel.children and #sel.children > 0 then
                if not sel._top_sub then
                    sel._top_sub = filter_and_sort_children(sel, "", "size")
                end
                local top_sub = sel._top_sub
                table.insert(r_lines, string.format("%s Top Items Inside (%d)%s", C.b_cyan, #top_sub, C.reset))
                table.insert(r_lines, C.gray .. " " .. string.rep(BOX.h, math.max(10, right_w - 2)) .. C.reset)
                for i = 1, math.min(9, #top_sub) do
                    local ch = top_sub[i]
                    local sub_ratio = (sel.size > 0) and (ch.size / sel.size) or 0
                    local bar = format_bar(sub_ratio, 6)
                    local label = ch.name .. (ch.is_dir and "/" or "")
                    local line_s = string.format(" %s %9s  %s", bar, format_bytes(ch.size), label)
                    table.insert(r_lines, truncate_string(line_s, right_w - 1))
                end
            end
        else
            table.insert(r_lines, C.gray .. " Directory is empty." .. C.reset)
        end

        -- 3. Render Dual-Pane Body (rows - 6 rows)
        local col_hdr = string.format(" %-10s %10s %6s  %s", "USAGE", "SIZE", "SHARE", "NAME")
        col_hdr = truncate_string(col_hdr, left_w)
        local parent_total = math.max(1, state.cur_node.size)

        for row = 1, body_h do
            local l_cell = ""
            if row == 1 then
                l_cell = C.b_white .. pad_string(col_hdr, left_w) .. C.reset
            else
                local idx = state.scroll + row - 2
                local item = state.items[idx]
                if item then
                    local is_sel = (idx == state.cursor)
                    local prefix = is_sel and "▸" or " "
                    local ratio = (state.cur_node.size > 0) and (item.size / parent_total) or 0
                    local bar = format_bar(ratio, 10)
                    local sz_str = format_bytes(item.size)
                    local pct_str = string.format("%5.1f%%", ratio * 100.0)
                    local name_w = math.max(8, left_w - 32)
                    local disp_name = item.name .. (item.is_dir and "/" or "")
                    disp_name = truncate_string(disp_name, name_w)
                    local raw_line = string.format("%s%s %10s %6s  %s",
                        prefix, bar, sz_str, pct_str, disp_name)
                    raw_line = pad_string(truncate_string(raw_line, left_w), left_w)

                    if is_sel then
                        l_cell = C.bg_sel .. C.b_yellow .. raw_line .. C.reset
                    else
                        local col = item.is_dir and C.b_cyan or C.white
                        if ratio >= 0.40 then col = C.b_red
                        elseif ratio >= 0.20 then col = C.yellow end
                        l_cell = col .. raw_line .. C.reset
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
        if state.mode == "confirm_del" and sel then
            footer = C.bg_red .. C.b_white ..
                string.format(" Delete '%s' (%s)? Press [y] to confirm, [n/Esc] to cancel ",
                    sel.name, format_bytes(sel.size)) .. C.reset
        elseif state.mode == "search" then
            footer = C.b_yellow .. " Filter (/): " .. C.b_white .. state.query .. "█" .. C.reset
        elseif #state.status_msg > 0 then
            local col = state.status_is_err and C.b_red or C.b_green
            footer = " " .. col .. state.status_msg .. C.reset
        else
            local sort_lbl = SORT_MODES[state.sort_idx]:upper()
            footer = C.gray .. string.format(
                " [j/k] Move  [Enter/l] Open  [Bksp/h] Up  [/] Filter  [s] Sort:%s  [d] Delete  [r] Rescan  [?] Help  [q] Quit",
                sort_lbl) .. C.reset
        end
        table.insert(frame_lines, BOX.v .. pad_string(truncate_string(footer, cols - 2), cols - 2) .. BOX.v)
        table.insert(frame_lines, BOX.bl .. string.rep(BOX.h, cols - 2) .. BOX.br)

        -- Emit only changed lines wrapped in DEC Synchronized Update
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

    Term.enable_raw()
    local ok, err = pcall(function()
        render()
        while true do
            local key = Term.read_key()
            if not key then
                Term.sleep_ms(16)
            else
                state.status_msg = ""
                if state.mode == "help" then
                    state.mode = "normal"
                    render()
                elseif state.mode == "confirm_del" then
                    if key == "y" or key == "Y" then
                        local sel = state.items[state.cursor]
                        state.mode = "normal"
                        if sel then
                            local freed_str = format_bytes(sel.size)
                            local del_ok, del_err = FS.delete_entry(sel)
                            if del_ok then
                                refresh_items()
                                state.status_msg = string.format("Deleted '%s' (freed %s)", sel.name, freed_str)
                                state.status_is_err = false
                            else
                                state.status_msg = del_err or "Delete failed"
                                state.status_is_err = true
                            end
                        end
                    else
                        state.mode = "normal"
                        state.status_msg = "Delete cancelled"
                        state.status_is_err = false
                    end
                    render()
                elseif state.mode == "search" then
                    if key == "enter" then
                        state.mode = "normal"
                    elseif key == "esc" or key == "ctrl_c" then
                        state.query = state.prev_query
                        state.mode = "normal"
                        refresh_items()
                    elseif key == "backspace" then
                        if #state.query > 0 then
                            state.query = state.query:sub(1, -2)
                            refresh_items()
                        end
                    elseif key == "down" or key == "ctrl_n" then
                        state.cursor = math.min(math.max(1, #state.items), state.cursor + 1)
                    elseif key == "up" or key == "ctrl_p" then
                        state.cursor = math.max(1, state.cursor - 1)
                    elseif #key == 1 and key:byte(1) >= 32 and key:byte(1) <= 126 then
                        state.query = state.query .. key
                        refresh_items()
                    end
                    render()
                else
                    -- Normal Mode
                    if key == "q" or key == "ctrl_c" then
                        break
                    elseif key == "esc" then
                        if #state.query > 0 then
                            state.query = ""
                            refresh_items()
                            render()
                        else
                            break
                        end
                    elseif key == "j" or key == "down" then
                        state.pending_g = false
                        state.cursor = math.min(math.max(1, #state.items), state.cursor + 1)
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
                        state.cursor = math.max(1, #state.items)
                        render()
                    elseif key == "home" then
                        state.pending_g = false
                        state.cursor = 1
                        render()
                    elseif key == "ctrl_d" or key == "pagedown" then
                        state.pending_g = false
                        state.cursor = math.min(math.max(1, #state.items), state.cursor + 10)
                        render()
                    elseif key == "ctrl_u" or key == "pageup" then
                        state.pending_g = false
                        state.cursor = math.max(1, state.cursor - 10)
                        render()
                    elseif key == "enter" or key == "l" or key == "right" then
                        state.pending_g = false
                        local sel = state.items[state.cursor]
                        if sel and sel.is_dir then
                            table.insert(state.history, {
                                node = state.cur_node,
                                cursor = state.cursor,
                                scroll = state.scroll,
                            })
                            state.cur_node = sel
                            state.cursor = 1
                            state.scroll = 1
                            state.query = ""
                            refresh_items()
                            render()
                        end
                    elseif key == "backspace" or key == "h" or key == "left" or key == "-" then
                        state.pending_g = false
                        if #state.history > 0 then
                            local prev = table.remove(state.history)
                            state.cur_node = prev.node
                            state.query = ""
                            refresh_items()
                            state.cursor = math.min(prev.cursor, math.max(1, #state.items))
                            state.scroll = prev.scroll
                            render()
                        elseif state.cur_node.parent then
                            state.cur_node = state.cur_node.parent
                            state.cursor = 1
                            state.scroll = 1
                            state.query = ""
                            refresh_items()
                            render()
                        end
                    elseif key == "s" then
                        state.pending_g = false
                        state.sort_idx = (state.sort_idx % #SORT_MODES) + 1
                        refresh_items()
                        render()
                    elseif key == "r" then
                        state.pending_g = false
                        state.cur_node = FS.scan_tree(state.cur_node.path)
                        state.history = {}
                        refresh_items()
                        state.status_msg = "Rescanned directory tree"
                        state.status_is_err = false
                        render()
                    elseif key == "/" then
                        state.pending_g = false
                        state.prev_query = state.query
                        state.mode = "search"
                        render()
                    elseif key == "?" then
                        state.pending_g = false
                        state.mode = "help"
                        render()
                    elseif key == "d" or key == "x" or key == "delete" then
                        state.pending_g = false
                        if state.items[state.cursor] then
                            state.mode = "confirm_del"
                            render()
                        end
                    end
                end
            end
        end
    end)
    Term.restore()
    if not ok then
        io.stderr:write("[fdu error] " .. tostring(err) .. "\n")
        os.exit(1)
    end
end

--------------------------------------------------------------------------------
-- CLI Summary & Self-Tests
--------------------------------------------------------------------------------
local function cmd_list(target_path, top_n)
    Term.init()
    top_n = tonumber(top_n) or 25
    local root = FS.scan_tree(target_path or ".")
    local items = filter_and_sort_children(root, "", "size")
    local total = math.max(1, root.size)

    print(string.format("%sDisk Usage:%s %s  (%s total, %d files, %d dirs)",
        C.b_cyan, C.reset, root.path, format_bytes(root.size), root.files, root.dirs))
    print(string.rep("-", 78))
    print(string.format("%-12s  %10s  %7s  %8s  %s", "USAGE", "SIZE", "SHARE", "FILES", "NAME"))
    print(string.format("%-12s  %10s  %7s  %8s  %s", "------------", "----------", "-------", "--------", "------------------------------"))

    for i = 1, math.min(top_n, #items) do
        local it = items[i]
        local ratio = (root.size > 0) and (it.size / total) or 0
        local bar = format_bar(ratio, 12)
        local name_disp = it.name .. (it.is_dir and "/" or "")
        print(string.format("%s  %10s  %6.1f%%  %8d  %s",
            bar, format_bytes(it.size), ratio * 100.0, it.files, name_disp))
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

    print("Running fdu.lua automated self-tests...")
    assert_eq("format_bytes(512) == '512 B'", format_bytes(512), "512 B")
    assert_eq("format_bytes(2048) == '2.0 KB'", format_bytes(2048), "2.0 KB")
    assert_eq("format_bytes(5242880) == '5.00 MB'", format_bytes(5242880), "5.00 MB")
    assert_eq("format_bar(0.5, 10) width == 10", utf8_col_width(format_bar(0.5, 10)), 10)

    local tree = FS.scan_tree(".")
    assert_eq("scan_tree returns directory node", tree.is_dir, true)
    assert_eq("scan_tree finds files > 0", tree.files > 0, true)
    assert_eq("scan_tree computes total size > 0", tree.size > 0, true)

    local sorted = filter_and_sort_children(tree, "", "size")
    assert_eq("filter_and_sort_children returns non-empty list", #sorted > 0, true)
    if #sorted >= 2 then
        assert_eq("children sorted descending by size", sorted[1].size >= sorted[2].size, true)
    end

    print(string.format("\nSelf-test summary: %d passed, %d failed.", passed, failed))
    if failed > 0 then os.exit(1) end
end

local function show_help()
    print([[
Usage: fdu [OPTIONS] [PATH]

High-Performance Interactive Disk Usage Analyzer TUI (LuaJIT + FFI).

Options:
  -l, --list           Print formatted disk usage table for PATH and exit
  -n, --top <N>        Limit --list output to top N entries (default: 25)
  --test               Run automated self-test suite
  -h, --help           Show this help message

TUI Keybindings:
  j / k / Up / Down    Move selection cursor
  Enter / l / Right    Drill down into highlighted directory
  Bksp / h / Left / -  Go up to parent directory
  /                    Filter entries in current directory by name
  s                    Cycle sort column (Size, Files, Name)
  d / x / Del          Delete selected file or directory (with [y/N] prompt)
  r                    Rescan current directory tree
  ?                    Show keyboard shortcuts help
  q / Esc              Quit]])
end

--------------------------------------------------------------------------------
-- Entrypoint
--------------------------------------------------------------------------------
local args = { ... }
local mode = "tui"
local top_n = 25
local target_path = "."

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
    elseif a == "-n" or a == "--top" then
        i = i + 1
        top_n = tonumber(args[i]) or 25
    else
        target_path = a
    end
    i = i + 1
end

if mode == "list" then
    cmd_list(target_path, top_n)
else
    run_tui(target_path)
end
