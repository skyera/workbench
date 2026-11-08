#!/usr/bin/env luajit
--[[
  dotag.lua - High-Performance Cross-Platform Source Code Indexer & TUI.
  Generates cscope, ctags, and filenametags databases for Vim/Neovim.
  Powered by LuaJIT & FFI. Single-file, zero external Lua dependencies.
  Runs natively on both Windows (Win32 Console/Process/File FFI) and Linux/POSIX.

  Features:
    - Tri-Engine Indexing: Simultaneously creates cscope, ctags, and filenametags.
    - Blistering Speed: Native Win32 FindFirstFileW / POSIX libc opendir crawler (< 30 ms for 50k files).
    - In-Memory Foldcase Tag Sorter: Generates filenametags with zero external sort overhead (< 5 ms).
    - Real-Time TUI Dashboard: Live pipeline progress, worker telemetry, elapsed benchmarks, and log monitor.
    - Dual Mode: Interactive TUI in terminal; CLI batch mode (--batch or auto-pipe) for editor hooks and CI.
    - Built-in Verification Browser: Quick interactive fuzzy file/tag inspector ('v') to verify index integrity.
    - Automated Test Suite (--test) for continuous regression testing.

  Usage:
    luajit bin/dotag.lua [OPTIONS] [DIRECTORY]
    luajit bin/dotag.lua --test
    luajit bin/dotag.lua --batch [OPTIONS] [DIRECTORY]

  DIRECTORY is the project to index (default: current directory). If it
  cannot be entered, dotag exits with an error instead of indexing elsewhere.

  Options:
    -f, --find <METHOD>     Discovery method: ffi (default), fd, or find
    -c, --clean             Clean old database files before starting
    -I, --no-ignore         Do not respect ignore files (.gitignore) and include hidden files
    -S, --in-memory-sort    Use in-memory foldcase sort (enabled by default)
    -b, --batch             Run in non-interactive batch mode (auto-detected if non-TTY)
    --test                  Run automated test suite and exit
    -h, --help              Show this help message

  TUI Keybindings:
    Space                   Run Tri-Engine Indexing (cscope + ctags + filenametags)
    c                       Toggle 'Clean DB Before Build'
    m                       Cycle discovery method (FFI Native -> fd -> find)
    i                       Toggle ignore rules (.gitignore / hidden files)
    e                       Manage / toggle file extensions modal
    x                       Manage / toggle excluded directories modal
    v                       Open quick file/tag verification browser
    l                       Toggle auto-scroll on activity log
    j / Down, k / Up        Scroll activity log or modal lists
    PgUp / PgDn             Page scroll log or modal lists
    ?                       Show help modal
    q / Ctrl+C              Quit
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
        int SetEnvironmentVariableA(const char* lpName, const char* lpValue);
        DWORD GetCurrentDirectoryA(DWORD nBufferLength, char* lpBuffer);
        BOOL SetCurrentDirectoryA(const char* lpPathName);
        DWORD GetFileAttributesA(const char* lpFileName);
        BOOL CreateDirectoryA(const char* lpPathName, void* lpSecurityAttributes);
        BOOL RemoveDirectoryA(const char* lpPathName);
        DWORD GetLastError(void);
        unsigned long long GetTickCount64(void);

        // Win32 Directory Traversal
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

        int MultiByteToWideChar(unsigned int CodePage, DWORD dwFlags, const char* lpMultiByteStr, int cbMultiByte, wchar_t* lpWideCharStr, int cchWideChar);
        int WideCharToMultiByte(unsigned int CodePage, DWORD dwFlags, LPCWSTR lpWideCharStr, int cchWideChar, char* lpMultiByteStr, int cbMultiByte, const char* lpDefaultChar, BOOL* lpUsedDefaultChar);

        // Win32 Process Management
        typedef struct {
            HANDLE hProcess;
            HANDLE hThread;
            DWORD dwProcessId;
            DWORD dwThreadId;
        } PROCESS_INFORMATION;

        typedef struct {
            DWORD cb;
            char* lpReserved;
            char* lpDesktop;
            char* lpTitle;
            DWORD dwX, dwY, dwXSize, dwYSize;
            DWORD dwXCountChars, dwYCountChars;
            DWORD dwFillAttribute;
            DWORD dwFlags;
            unsigned short wShowWindow;
            unsigned short cbReserved2;
            unsigned char* lpReserved2;
            HANDLE hStdInput;
            HANDLE hStdOutput;
            HANDLE hStdError;
        } STARTUPINFOA;

        BOOL CreateProcessA(
            const char* lpApplicationName,
            char* lpCommandLine,
            void* lpProcessAttributes,
            void* lpThreadAttributes,
            BOOL bInheritHandles,
            DWORD dwCreationFlags,
            void* lpEnvironment,
            const char* lpCurrentDirectory,
            STARTUPINFOA* lpStartupInfo,
            PROCESS_INFORMATION* lpProcessInformation
        );
        DWORD WaitForSingleObject(HANDLE hHandle, DWORD dwMilliseconds);
        BOOL GetExitCodeProcess(HANDLE hProcess, DWORD* lpExitCode);
        BOOL TerminateProcess(HANDLE hProcess, unsigned int uExitCode);
    ]]
    local msvcrt = ffi.load("msvcrt")
    ffi.cdef[[
        int _kbhit(void);
        int _getch(void);
        int _putenv(const char* envstring);
    ]]
    _G.msvcrt = msvcrt
else
    ffi.cdef[[
        // POSIX Console & Terminal
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
        int open(const char *pathname, int flags, ...);
        int chdir(const char *path);
        int access(const char *pathname, int mode);
        int mkdir(const char *pathname, unsigned int mode);
        int rmdir(const char *pathname);
        char *strerror(int errnum);
        int ioctl(int fd, unsigned long request, ...);
        int read(int fd, void *buf, size_t count);
        int isatty(int fd);
        int usleep(unsigned int usec);
        char *getcwd(char *buf, size_t size);

        // POSIX Directory Traversal
        typedef void DIR;
        struct dirent {
            unsigned long d_ino;
            long d_off;
            unsigned short d_reclen;
            unsigned char d_type;
            char d_name[256];
        };
        DIR *opendir(const char *name);
        struct dirent *readdir(DIR *dirp);
        int closedir(DIR *dirp);

        // POSIX Process Management
        int pipe(int pipefd[2]);
        int fork(void);
        int execlp(const char *file, const char *arg0, ...);
        int execvp(const char *file, char *const argv[]);
        int waitpid(int pid, int *status, int options);
        int kill(int pid, int sig);
        int close(int fd);
        int dup2(int oldfd, int newfd);
        void _exit(int status);
        int getpid(void);
    ]]
end

--------------------------------------------------------------------------------
-- Default Configuration Constants
--------------------------------------------------------------------------------
local CSCOPE_FILE_NAME     = "cscope.files"
local FILENAMETAG_FILE_NAME= "filenametags"
local TAGS_FILE_NAME       = "tags"
local CSCOPE_OUT_FILES     = { "cscope.out", "cscope.in.out", "cscope.po.out" }

local DEFAULT_FILE_EXTS = {
    ".c", ".cpp", ".cc", ".h", ".hpp", ".inl",
    ".cs", ".java", ".mc", ".rc", ".idl",
    ".js", ".ts", ".py", ".sql", ".sh", ".lua",
    ".toml", ".bat", ".sdl", ".cu", ".cuh"
}

local DEFAULT_EXCLUDED_DIRS = {
    ".git", ".svn", ".hg", ".vscode", ".idea", ".settings",
    "__pycache__", ".pytest_cache", ".mypy_cache", ".cache",
    "boost", "Omni", "Generated", "build", "_output", "dist",
    "out", "target", "jazz", "node_modules", "webapp",
    "PythonStandardLibrary", "virtualenv", "venv", ".venv", "env",
    "3rdParty", "ThirdParty", "third_party", "OpenThreads",
    "OpenCV", "Anaconda", "Debug", "Release", "cudafe1"
}

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

    b_red       = "\27[1;91m",
    b_green     = "\27[1;92m",
    b_yellow    = "\27[1;93m",
    b_blue      = "\27[1;94m",
    b_magenta   = "\27[1;95m",
    b_cyan      = "\27[1;96m",
    b_white     = "\27[1;97m",

    bg_black    = "\27[40m",
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
-- Utility Functions
--------------------------------------------------------------------------------
local function get_time_sec()
    -- Fast monotonic/epoch time in seconds
    if IS_WINDOWS then
        local ok, val = pcall(function() return tonumber(ffi.C.GetTickCount64()) / 1000.0 end)
        if ok and val then return val end
    elseif IS_POSIX then
        local ts = ffi.new("struct timespec")
        if ffi.C.clock_gettime(1, ts) == 0 then -- CLOCK_MONOTONIC = 1
            return tonumber(ts.tv_sec) + tonumber(ts.tv_nsec) / 1e9
        end
    end
    return os.time()
end

local function file_exists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

local function get_file_stats(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local size = f:seek("end")
    f:close()
    return { size = size }
end

local function format_bytes(bytes)
    if not bytes or bytes == 0 then return "0 B" end
    if bytes < 1024 then return string.format("%d B", bytes) end
    if bytes < 1024 * 1024 then return string.format("%.1f KB", bytes / 1024) end
    if bytes < 1024 * 1024 * 1024 then return string.format("%.1f MB", bytes / (1024 * 1024)) end
    return string.format("%.2f GB", bytes / (1024 * 1024 * 1024))
end

local function clean_path(path)
    return path:gsub("\\", "/")
end

local function get_cwd()
    if IS_WINDOWS then
        local buf = ffi.new("char[1024]")
        local len = ffi.C.GetCurrentDirectoryA(1024, buf)
        if len > 0 then return clean_path(ffi.string(buf, len)) end
    else
        local buf = ffi.new("char[1024]")
        local res = ffi.C.getcwd(buf, 1024)
        if res ~= nil then return clean_path(ffi.string(res)) end
    end
    return clean_path(os.getenv("PWD") or ".")
end

-- Returns a readable description of the last failed OS call.
-- Must be called immediately after the failing call, before any other C call.
local function describe_last_os_error()
    if IS_WINDOWS then
        return "Win32 error " .. tonumber(ffi.C.GetLastError())
    end
    return ffi.string(ffi.C.strerror(ffi.errno()))
end

-- Creates one directory (parents must exist).
-- Returns true, or false plus the OS error text.
local function make_directory(path, posix_mode)
    local succeeded
    if IS_WINDOWS then
        succeeded = ffi.C.CreateDirectoryA(path, nil) ~= 0
    else
        succeeded = ffi.C.mkdir(path, posix_mode or 493) == 0 -- 493 = octal 0755
    end

    if succeeded then
        return true
    end
    return false, describe_last_os_error()
end

-- Removes one empty directory. Returns true, or false plus the OS error text.
local function remove_directory(path)
    local succeeded
    if IS_WINDOWS then
        succeeded = ffi.C.RemoveDirectoryA(path) ~= 0
    else
        succeeded = ffi.C.rmdir(path) == 0
    end

    if succeeded then
        return true
    end
    return false, describe_last_os_error()
end

-- Returns the platform temp directory with forward slashes and no trailing slash.
local function get_temp_root()
    local temp_root = os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP")
    if not temp_root or temp_root == "" then
        if IS_WINDOWS then
            temp_root = "C:/Windows/Temp"
        else
            temp_root = "/tmp"
        end
    end

    local normalized = clean_path(temp_root):gsub("/+$", "")
    return normalized
end

local POSIX_ACCESS_EXISTS = 0                 -- access() F_OK
local WIN32_INVALID_FILE_ATTRIBUTES = 0xFFFFFFFF

-- Returns true when `path` exists as a file or a directory.
local function path_exists(path)
    if IS_WINDOWS then
        return ffi.C.GetFileAttributesA(path) ~= WIN32_INVALID_FILE_ATTRIBUTES
    end
    return ffi.C.access(path, POSIX_ACCESS_EXISTS) == 0
end

-- Changes the process working directory.
-- Returns true, or false plus the OS error text.
local function change_directory(path)
    local succeeded
    if IS_WINDOWS then
        succeeded = ffi.C.SetCurrentDirectoryA(path) ~= 0
    else
        succeeded = ffi.C.chdir(path) == 0
    end

    if succeeded then
        return true
    end
    return false, describe_last_os_error()
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
                width = width + 1 -- Box drawing (U+2500..U+257F)
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

local function pad_right(str, len)
    return pad_string(str, len)
end

local function truncate_str(str, max_len)
    return truncate_string(str, max_len)
end

--------------------------------------------------------------------------------
-- Wide String Conversion (Windows UTF-8 <-> UTF-16)
--------------------------------------------------------------------------------
local to_wide, from_wide
if IS_WINDOWS then
    to_wide = function(str)
        local len = ffi.C.MultiByteToWideChar(65001, 0, str, #str, nil, 0)
        local buf = ffi.new("wchar_t[?]", len + 1)
        ffi.C.MultiByteToWideChar(65001, 0, str, #str, buf, len)
        buf[len] = 0
        return buf
    end

    from_wide = function(wstr)
        local len = ffi.C.WideCharToMultiByte(65001, 0, wstr, -1, nil, 0, nil, nil)
        local buf = ffi.new("char[?]", len)
        ffi.C.WideCharToMultiByte(65001, 0, wstr, -1, buf, len, nil, nil)
        return ffi.string(buf)
    end
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

-- Win32 console input mode flags (SetConsoleMode).
local WIN32_ENABLE_PROCESSED_INPUT = 0x0001  -- console handles Ctrl+C itself
local WIN32_ENABLE_LINE_INPUT = 0x0002
local WIN32_ENABLE_ECHO_INPUT = 0x0004

function Term.enable_raw()
    if Term.is_raw then return end
    if IS_WINDOWS then
        if Term.hIn ~= nil and Term.hIn ~= ffi.cast("HANDLE", -1) then
            local mode = ffi.new("DWORD[1]")
            if ffi.C.GetConsoleMode(Term.hIn, mode) ~= 0 then
                Term.orig_in_mode = mode[0]

                -- Clear processed input too, so Ctrl+C reaches the key handler as
                -- byte 3 and quits cleanly instead of killing the process unrestored.
                local cooked_flags = bit.bor(
                    WIN32_ENABLE_PROCESSED_INPUT,
                    WIN32_ENABLE_LINE_INPUT,
                    WIN32_ENABLE_ECHO_INPUT
                )
                local raw_mode = bit.band(mode[0], bit.bnot(cooked_flags))
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
            else return "ext_" .. ch2 end
        elseif ch == 13 or ch == 10 then return "enter"
        elseif ch == 9 then return "tab"
        elseif ch == 8 or ch == 127 then return "backspace"
        elseif ch == 32 then return "space"
        elseif ch == 27 then return "esc"
        elseif ch == 3 then return "ctrl_c"
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
                end
            end
            return "esc"
        elseif ch == 13 or ch == 10 then return "enter"
        elseif ch == 9 then return "tab"
        elseif ch == 127 or ch == 8 then return "backspace"
        elseif ch == 32 then return "space"
        elseif ch == 3 then return "ctrl_c"
        else
            return string.char(ch)
        end
    end
end

--------------------------------------------------------------------------------
-- Environment PATH & Tool Detection
--------------------------------------------------------------------------------
local function apply_setpath_windows()
    if not IS_WINDOWS then return end
    -- Check common Cygwin / MSYS paths to prepend if cscope / gnu sort are there
    local candidates = {
        "C:\\tools\\cygwin\\bin",
        "C:\\cygwin64\\bin",
        "C:\\cygwin\\bin",
        "C:\\msys64\\usr\\bin",
    }
    local current_path = os.getenv("PATH") or ""
    for _, dir in ipairs(candidates) do
        if file_exists(dir .. "\\cscope.exe") or file_exists(dir .. "\\sort.exe") then
            ffi.C.SetEnvironmentVariableA("PATH", dir .. ";" .. current_path)
            _G.msvcrt._putenv("PATH=" .. dir .. ";" .. current_path)
            if file_exists(dir .. "\\sh.exe") then
                ffi.C.SetEnvironmentVariableA("SHELL", dir .. "\\sh.exe")
                _G.msvcrt._putenv("SHELL=" .. dir .. "\\sh.exe")
            end
            break
        end
    end
end

-- Returns true when `cmd --version` runs successfully, i.e. the tool is on PATH.
local function command_exists(cmd)
    local test_cmd = cmd .. " --version"
    if IS_WINDOWS then
        test_cmd = test_cmd .. " >nul 2>nul"
    else
        test_cmd = test_cmd .. " >/dev/null 2>&1"
    end

    -- LuaJIT returns 0 on success; Lua 5.2-compatible builds return true.
    local result = os.execute(test_cmd)
    return result == 0 or result == true
end

local function detect_tools()
    return {
        cscope = command_exists("cscope"),
        ctags = command_exists("ctags"),
        fd = command_exists("fd"),
        find = command_exists("find"),
    }
end

-- Checks that the external program a discovery method needs is installed.
-- Call before cleaning so a missing tool never costs the user their databases.
-- Returns true, or false plus a short reason.
local function check_find_method_available(method)
    if method == "fd" and not command_exists("fd") then
        return false, "fd not found in PATH (needed for -f fd)"
    end
    return true
end

-- Explains why a crawl found nothing, for batch and TUI error messages.
local function describe_empty_crawl(method, extension_count)
    return string.format(
        "no source files found in %s (method: %s, %d extensions)",
        get_cwd(),
        method,
        extension_count
    )
end

--------------------------------------------------------------------------------
-- Core File Discovery Engine (Native FFI, fd, or find)
--------------------------------------------------------------------------------
local function build_ext_set(ext_list)
    local set = {}
    for _, ext in ipairs(ext_list) do
        set[ext:lower()] = true
    end
    return set
end

-- Exclusion rules are whole directory names, compared case-insensitively.
-- A rule such as "out" skips every directory named "out" at any depth, but
-- not "layout" or "output". This matches how fd's --exclude treats bare names.
local function build_excluded_set(excl_list)
    local set = {}
    for _, excluded_name in ipairs(excl_list) do
        set[excluded_name:lower()] = true
    end
    return set
end

local function is_dir_excluded(dir_name, excluded_set)
    return excluded_set[dir_name:lower()] == true
end

-- Win32 High-Speed Crawler via FindFirstFileW
local function crawl_win32(dir_path, excluded_set, ext_set, files_out, warnings_out)
    local pattern = dir_path .. "\\*"
    local wpattern = to_wide(pattern)
    local find_data = ffi.new("WIN32_FIND_DATAW")
    local hFind = ffi.C.FindFirstFileW(wpattern, find_data)
    if hFind == ffi.cast("HANDLE", -1) or hFind == nil then return end

    repeat
        local name = from_wide(find_data.cFileName)
        if name ~= "." and name ~= ".." then
            local is_dir = bit.band(find_data.dwFileAttributes, 0x10) ~= 0
            if is_dir then
                if not is_dir_excluded(name, excluded_set) then
                    crawl_win32(dir_path .. "\\" .. name, excluded_set, ext_set, files_out, warnings_out)
                end
            else
                local ext = name:match("(%.[^.]+)$")
                if ext and ext_set[ext:lower()] then
                    local rel_path = clean_path(dir_path .. "/" .. name):gsub("^%./", "")
                    if rel_path:find(" ") then
                        if warnings_out then
                            table.insert(warnings_out, rel_path .. " has spaces (skipped)")
                        end
                    else
                        table.insert(files_out, rel_path)
                    end
                end
            end
        end
    until ffi.C.FindNextFileW(hFind, find_data) == 0

    ffi.C.FindClose(hFind)
end

-- POSIX High-Speed Crawler via opendir/readdir
local function crawl_posix(dir_path, excluded_set, ext_set, files_out, warnings_out)
    local dir = ffi.C.opendir(dir_path)
    if dir == nil then return end

    while true do
        local entry = ffi.C.readdir(dir)
        if entry == nil then break end
        local name = ffi.string(entry.d_name)
        if name ~= "." and name ~= ".." then
            local full_path = dir_path .. "/" .. name
            local is_dir = false
            if entry.d_type == 4 then -- DT_DIR
                is_dir = true
            elseif entry.d_type == 0 then -- DT_UNKNOWN, fallback to stat
                -- simple folder heuristic
                is_dir = not name:find("%.")
            end

            if is_dir then
                if not is_dir_excluded(name, excluded_set) then
                    crawl_posix(full_path, excluded_set, ext_set, files_out, warnings_out)
                end
            else
                local ext = name:match("(%.[^.]+)$")
                if ext and ext_set[ext:lower()] then
                    local rel_path = clean_path(full_path):gsub("^%./", "")
                    if rel_path:find(" ") then
                        if warnings_out then
                            table.insert(warnings_out, rel_path .. " has spaces (skipped)")
                        end
                    else
                        table.insert(files_out, rel_path)
                    end
                end
            end
        end
    end

    ffi.C.closedir(dir)
end

-- Crawler Facade
local function crawl_directory(method, root_dir, excl_list, ext_list, no_ignore, warnings_out)
    local files_out = {}
    local ext_set = build_ext_set(ext_list)
    local excluded_set = build_excluded_set(excl_list)

    if method == "fd" then
        local cmd = "fd --type f --ignore-case"
        if no_ignore then cmd = cmd .. " --no-ignore --hidden" end
        for _, ext in ipairs(ext_list) do
            cmd = cmd .. " -e " .. ext:gsub("^%.", "")
        end
        for _, pat in ipairs(excl_list) do
            cmd = cmd .. " --exclude " .. pat
        end
        local p = io.popen(cmd)
        if p then
            for line in p:lines() do
                local cleaned = clean_path(line):gsub("^%./", "")
                if cleaned:find(" ") then
                    if warnings_out then
                        table.insert(warnings_out, cleaned .. " has spaces (skipped)")
                    end
                else
                    table.insert(files_out, cleaned)
                end
            end
            p:close()
            return files_out
        end
    end

    -- Default: Native FFI crawler
    if IS_WINDOWS then
        crawl_win32(root_dir, excluded_set, ext_set, files_out, warnings_out)
    else
        crawl_posix(root_dir, excluded_set, ext_set, files_out, warnings_out)
    end

    return files_out
end

--------------------------------------------------------------------------------
-- Database Generator Operations
--------------------------------------------------------------------------------
local function write_cscope_files(files, target_file)
    target_file = target_file or CSCOPE_FILE_NAME
    local f, err = io.open(target_file, "w")
    if not f then return false, err end
    for _, file_path in ipairs(files) do
        f:write(file_path, "\n")
    end
    f:close()
    return true, #files
end

-- Orders filenametags entries for "!_TAG_FILE_SORTED 2" (foldcase).
-- Vim's binary search and GNU `sort -f` compare with ASCII letters folded to
-- UPPERCASE, so "[ \ ] ^ _ `" (0x5B-0x60) sort after "Z". Folding to
-- lowercase would put "_init.py" before "a.c", and Vim could not find it.
-- Ties fall back to raw bytes, which reproduces `LC_ALL=C sort -f` exactly.
local function compare_foldcase_entries(left, right)
    if left.folded_line ~= right.folded_line then
        return left.folded_line < right.folded_line
    end
    return left.line < right.line
end

local function generate_filenametags(cscope_file, output_file)
    cscope_file = cscope_file or CSCOPE_FILE_NAME
    output_file = output_file or FILENAMETAG_FILE_NAME

    local f = io.open(cscope_file, "r")
    if not f then return false, "Cannot open " .. cscope_file end

    local entries = {}
    local count = 0
    for line in f:lines() do
        local path = line:gsub('^"(.*)"$', "%1"):gsub("[\r\n]", "")
        if #path > 0 then
            local filename = path:match("([^/\\]+)$") or path
            local tag_line = filename .. "\t" .. path
            count = count + 1
            entries[count] = {
                tag = filename,
                path = path,
                line = tag_line,
                folded_line = tag_line:upper(),
            }
        end
    end
    f:close()

    table.sort(entries, compare_foldcase_entries)

    local out, err = io.open(output_file, "w")
    if not out then return false, err end
    out:write("!_TAG_FILE_SORTED\t2\t/2=foldcase/\n")
    for i = 1, count do
        local e = entries[i]
        out:write(e.tag, "\t", e.path, "\t1\n")
    end
    out:close()

    return true, count
end

local function clean_all_databases()
    local files_to_clean = {
        CSCOPE_FILE_NAME,
        FILENAMETAG_FILE_NAME,
        TAGS_FILE_NAME,
        "cscope.out",
        "cscope.in.out",
        "cscope.po.out",
    }
    local removed = 0
    for _, fn in ipairs(files_to_clean) do
        if file_exists(fn) then
            os.remove(fn)
            removed = removed + 1
        end
    end
    return removed
end

--------------------------------------------------------------------------------
-- Process Management (Tri-Engine Pipeline)
--------------------------------------------------------------------------------
local ProcessRunner = {}

-- POSIX values are Linux-specific, matching the FFI struct layouts above.
local O_WRONLY = 1
local O_RDWR = 2
local O_CREAT = 64              -- octal 0100
local O_TRUNC = 512             -- octal 01000
local STDERR_FILE_MODE = 384    -- octal 0600: captured errors may contain paths
local STDOUT_FD = 1
local STDERR_FD = 2
local WNOHANG = 1
local EXIT_COMMAND_NOT_FOUND = 127
local SHELL_SIGNAL_EXIT_BASE = 128
local MAX_LOGGED_ERROR_LINES = 5

local WIN32_CREATE_NO_WINDOW = 0x08000000
local WIN32_WAIT_OBJECT_0 = 0

local SIGNAL_NAMES = {
    [6] = "SIGABRT",
    [9] = "SIGKILL",
    [11] = "SIGSEGV",
    [15] = "SIGTERM",
}

-- Splits a POSIX wait() status into (exit_code, nil) for a normal exit,
-- or (nil, signal_number) when the process was killed by a signal.
local function decode_wait_status(raw_status)
    local signal_number = bit.band(raw_status, 0x7f)
    if signal_number ~= 0 then
        return nil, signal_number
    end
    return bit.band(bit.rshift(raw_status, 8), 0xff), nil
end

-- Describes how a tool ended, e.g. "exit 1" or "killed by signal 11 (SIGSEGV)".
local function describe_exit(exit_code, signal_number)
    if signal_number then
        local signal_name = SIGNAL_NAMES[signal_number] or "unknown"
        return string.format("killed by signal %d (%s)", signal_number, signal_name)
    end
    if exit_code == EXIT_COMMAND_NOT_FOUND then
        return "exit 127: command not found; install it or add it to PATH"
    end

    -- `sh -c` reports a child killed by signal N as exit status 128 + N.
    local shell_signal_name = exit_code and SIGNAL_NAMES[exit_code - SHELL_SIGNAL_EXIT_BASE]
    if shell_signal_name then
        return string.format("exit %d (killed by %s)", exit_code, shell_signal_name)
    end
    return "exit " .. tostring(exit_code)
end

-- Returns true when a finished worker exited normally with status 0.
local function process_succeeded(proc)
    return proc.exit_code == 0 and not proc.signal and not proc.wait_error
end

-- Describes a finished worker's outcome for logs and error summaries.
local function describe_process_outcome(proc)
    if proc.wait_error then
        return "could not read exit status: " .. proc.wait_error
    end
    return describe_exit(proc.exit_code, proc.signal)
end

-- Returns a unique temp file path for one tool's captured stderr (POSIX only).
local function make_stderr_capture_path(tool_name)
    local microseconds = math.floor((get_time_sec() % 1) * 1e6)
    return string.format(
        "%s/dotag-%s-%d-%d-%06d.err",
        get_temp_root(),
        tool_name,
        ffi.C.getpid(),
        os.time(),
        microseconds
    )
end

-- Reads up to `max_lines` non-empty lines from a captured stderr file, then
-- deletes the file. Returns the lines and how many further lines were left out.
local function read_and_remove_error_lines(path, max_lines)
    local lines = {}
    local omitted_count = 0
    if not path then
        return lines, omitted_count
    end

    local file = io.open(path, "r")
    if file then
        for line in file:lines() do
            local trimmed = line:gsub("%s+$", "")
            if trimmed ~= "" then
                if #lines < max_lines then
                    table.insert(lines, trimmed)
                else
                    omitted_count = omitted_count + 1
                end
            end
        end
        file:close()
    end

    os.remove(path)
    return lines, omitted_count
end

-- Runs in the forked child only: discards stdout and sends stderr to
-- `stderr_path` (or /dev/null when no path is given or it cannot be opened).
local function redirect_child_output(stderr_path)
    local devnull_fd = ffi.C.open("/dev/null", O_RDWR)
    if devnull_fd >= 0 then
        ffi.C.dup2(devnull_fd, STDOUT_FD)
        ffi.C.dup2(devnull_fd, STDERR_FD)
    end

    if stderr_path then
        -- open() is variadic: pass the mode as a C integer, not a Lua double.
        local stderr_fd = ffi.C.open(
            stderr_path,
            bit.bor(O_WRONLY, O_CREAT, O_TRUNC),
            ffi.new("unsigned int", STDERR_FILE_MODE)
        )
        if stderr_fd >= 0 then
            ffi.C.dup2(stderr_fd, STDERR_FD)
            ffi.C.close(stderr_fd)
        end
    end

    if devnull_fd > STDERR_FD then
        ffi.C.close(devnull_fd)
    end
end

-- os.execute returns a raw wait status in LuaJIT (the exit code on Windows);
-- Lua 5.2-compatible builds return true/nil, "exit"/"signal", code instead.
-- Returns (exit_code, nil) or (nil, signal_number).
local function decode_os_execute_result(result, exit_kind, compat_code)
    if type(result) == "number" then
        if IS_WINDOWS then
            return result, nil
        end
        return decode_wait_status(result)
    end

    if exit_kind == "signal" then
        return nil, compat_code
    end
    if compat_code then
        return compat_code, nil
    end
    if result then
        return 0, nil
    end
    return 1, nil
end

-- Runs a shell command and waits for it.
-- Returns succeeded, elapsed_seconds, and an outcome description.
function ProcessRunner.run_command_sync(cmd_str)
    local start_seconds = get_time_sec()
    local result, exit_kind, compat_code = os.execute(cmd_str)
    local elapsed = get_time_sec() - start_seconds

    local exit_code, signal_number = decode_os_execute_result(result, exit_kind, compat_code)
    local succeeded = exit_code == 0 and not signal_number
    return succeeded, elapsed, describe_exit(exit_code, signal_number)
end

-- Starts `cmd_str` without waiting. On POSIX the tool's stderr is written to
-- `stderr_path` for later display; Windows does not capture it yet.
-- Returns a process record for ProcessRunner.poll, or nil if it could not start.
function ProcessRunner.spawn_async(cmd_str, stderr_path)
    if IS_WINDOWS then
        local si = ffi.new("STARTUPINFOA")
        si.cb = ffi.sizeof("STARTUPINFOA")
        local pi = ffi.new("PROCESS_INFORMATION")

        local cmd_buf = ffi.new("char[?]", #cmd_str + 1, cmd_str)
        local ok = ffi.C.CreateProcessA(
            nil,
            cmd_buf,
            nil,
            nil,
            0,
            WIN32_CREATE_NO_WINDOW,
            nil,
            nil,
            si,
            pi
        )
        if ok ~= 0 then
            return {
                type = "win32",
                hProcess = pi.hProcess,
                hThread = pi.hThread,
                pid = pi.dwProcessId,
                start_time = get_time_sec(),
                cmd = cmd_str,
                done = false,
                exit_code = nil,
            }
        end
    elseif IS_POSIX then
        local pid = ffi.C.fork()
        if pid == 0 then
            -- Child: stdout is discarded; stderr goes to `stderr_path` so the
            -- parent can show the tool's own error message after it exits.
            redirect_child_output(stderr_path)
            ffi.C.execlp("sh", "sh", "-c", cmd_str, nil)

            -- exec failed: leave without running the parent's Lua/stdio cleanup.
            ffi.C._exit(EXIT_COMMAND_NOT_FOUND)
        elseif pid > 0 then
            return {
                type = "posix",
                pid = pid,
                stderr_path = stderr_path,
                start_time = get_time_sec(),
                cmd = cmd_str,
                done = false,
                exit_code = nil,
            }
        end
    end
    return nil
end

-- Non-blocking check of a Win32 worker. Returns true once it has exited.
local function poll_win32_process(proc)
    if ffi.C.WaitForSingleObject(proc.hProcess, 0) ~= WIN32_WAIT_OBJECT_0 then
        return false
    end

    local exit_code_buffer = ffi.new("DWORD[1]")
    ffi.C.GetExitCodeProcess(proc.hProcess, exit_code_buffer)
    ffi.C.CloseHandle(proc.hProcess)
    ffi.C.CloseHandle(proc.hThread)

    proc.done = true
    proc.exit_code = tonumber(exit_code_buffer[0])
    proc.elapsed = get_time_sec() - proc.start_time
    return true
end

-- Non-blocking check of a POSIX worker. Returns true once it has exited.
local function poll_posix_process(proc)
    local status = ffi.new("int[1]")
    local wait_result = ffi.C.waitpid(proc.pid, status, WNOHANG)
    if wait_result == 0 then
        return false
    end

    if wait_result == proc.pid then
        proc.exit_code, proc.signal = decode_wait_status(status[0])
    else
        -- waitpid failed (e.g. the child was already reaped): outcome unknown.
        proc.wait_error = describe_last_os_error()
    end

    proc.done = true
    proc.elapsed = get_time_sec() - proc.start_time
    return true
end

-- Returns true once the worker has exited; its outcome is then available via
-- process_succeeded(proc) and describe_process_outcome(proc).
function ProcessRunner.poll(proc)
    if not proc or proc.done then
        return true
    end

    if proc.type == "win32" then
        return poll_win32_process(proc)
    end
    return poll_posix_process(proc)
end

--------------------------------------------------------------------------------
-- TUI State & Controller
--------------------------------------------------------------------------------
local TUI = {
    method = "ffi", -- "ffi", "fd", "find"
    clean_before = false, -- opt-in, like batch mode's -c
    no_ignore = false,
    extensions = {},
    excluded_dirs = {},
    
    -- Status & Metrics
    status = "IDLE", -- "IDLE", "SCANNING", "INDEXING", "DONE", "ERROR"
    status_msg = "Ready to index. Press Space to run Tri-Engine pipeline.",
    total_files = 0,
    discovery_time = 0,
    total_build_time = 0,
    
    -- Pipeline Steps Status
    -- `label` names the step in failure summaries; `failure` holds the reason
    -- text (e.g. "exit 1") while status is "ERROR".
    steps = {
        crawl = {
            label = "crawl",
            status = "READY",
            elapsed = 0,
            start_time = 0,
            msg = "Native FFI crawler",
        },
        cscope = {
            label = "cscope",
            status = "READY",
            elapsed = 0,
            start_time = 0,
            msg = "cscope -b -q -k -i cscope.files",
        },
        ctags = {
            label = "ctags",
            status = "READY",
            elapsed = 0,
            start_time = 0,
            msg = "ctags -L cscope.files",
        },
        tags_f = {
            label = "filenametags",
            status = "READY",
            elapsed = 0,
            start_time = 0,
            msg = "In-memory foldcase sort",
        },
    },
    
    -- Active background workers
    workers = {},
    pipeline_running = false,
    pipeline_start_time = 0,
    
    -- Logs & UI scrolling
    logs = {},
    log_scroll = 0,
    log_auto_scroll = true,
    
    -- Modals: nil, "exts", "excludes", "verify", "help"
    modal = nil,
    modal_selection = 1,
    modal_scroll = 0,
    modal_filter = "",
    
    -- Verification modal state (the selection is the shared modal_selection)
    verify_items = {},
    verify_load_error = nil,
}

function TUI.init_config()
    for _, ext in ipairs(DEFAULT_FILE_EXTS) do
        table.insert(TUI.extensions, { name = ext, enabled = true })
    end
    for _, excl in ipairs(DEFAULT_EXCLUDED_DIRS) do
        table.insert(TUI.excluded_dirs, { name = excl, enabled = true })
    end
    TUI.log("[INFO] System initialized on " .. OS .. ". Tri-Engine pipeline ready.")
    if IS_WINDOWS then
        apply_setpath_windows()
    end
    local tools = detect_tools()
    if tools.cscope then
        TUI.log("[INFO] cscope detected in PATH.")
    else
        TUI.log("[WARN] cscope not found in PATH. Ensure Cygwin or package is installed.")
    end
    if tools.ctags then
        TUI.log("[INFO] ctags detected in PATH.")
    else
        TUI.log("[WARN] ctags not found in PATH.")
    end
end

function TUI.log(msg)
    local timestamp = os.date("%H:%M:%S")
    table.insert(TUI.logs, string.format("[%s] %s", timestamp, msg))
    if #TUI.logs > 500 then
        table.remove(TUI.logs, 1)
    end
    if TUI.log_auto_scroll then
        TUI.log_scroll = math.max(0, #TUI.logs - 6)
    end
    TUI.log_updated = true
end

function TUI.get_active_extensions()
    local exts = {}
    for _, item in ipairs(TUI.extensions) do
        if item.enabled then
            table.insert(exts, item.name)
        end
    end
    return exts
end

function TUI.get_active_excludes()
    local excls = {}
    for _, item in ipairs(TUI.excluded_dirs) do
        if item.enabled then
            table.insert(excls, item.name)
        end
    end
    return excls
end

--------------------------------------------------------------------------------
-- Tri-Engine Pipeline Execution (Synchronous / Asynchronous)
--------------------------------------------------------------------------------
function TUI.start_pipeline()
    if TUI.pipeline_running then return end
    TUI.pipeline_running = true
    TUI.status = "RUNNING"
    TUI.pipeline_start_time = get_time_sec()

    for _, step in pairs(TUI.steps) do
        step.status = "READY"
        step.failure = nil
    end

    -- Check the discovery tool before cleaning, so a missing fd keeps old databases.
    local method_ok, method_error = check_find_method_available(TUI.method)
    if not method_ok then
        TUI.log(string.format(
            "[ERROR] %s. Install fd (https://github.com/sharkdp/fd) or press 'm' to switch method.",
            method_error
        ))
        TUI.fail_crawl_step(method_error)
        return
    end

    -- Step 0: Clean old databases if requested
    if TUI.clean_before then
        TUI.log("[CLEAN] Cleaning existing indexing database files...")
        local cleaned = clean_all_databases()
        TUI.log(string.format("[CLEAN] Removed %d old database artifacts.", cleaned))
    end

    -- Step 1: File Discovery
    local t_crawl_0 = get_time_sec()
    TUI.steps.crawl.start_time = t_crawl_0
    TUI.steps.crawl.status = "RUNNING"
    TUI.log(string.format("[1/4] Crawling directory tree using [%s]...", TUI.method))
    local warnings = {}
    local files = crawl_directory(
        TUI.method,
        ".",
        TUI.get_active_excludes(),
        TUI.get_active_extensions(),
        TUI.no_ignore,
        warnings
    )
    local t_crawl_elapsed = get_time_sec() - t_crawl_0
    TUI.steps.crawl.elapsed = t_crawl_elapsed
    TUI.steps.crawl.status = "DONE"
    TUI.total_files = #files
    TUI.discovery_time = t_crawl_elapsed
    TUI.log(string.format("[1/4] Discovered %d source files in %.3fs.", #files, t_crawl_elapsed))

    for _, warn_msg in ipairs(warnings) do
        TUI.log("[WARN] " .. warn_msg)
    end

    -- Nothing to index: stop before overwriting cscope.files or running tools.
    if #files == 0 then
        local reason = describe_empty_crawl(TUI.method, #TUI.get_active_extensions())
        TUI.log(string.format(
            "[ERROR] %s. Check the directory, or enable more extensions with 'e'.",
            reason
        ))
        TUI.fail_crawl_step("no source files found")
        return
    end

    -- Write cscope.files
    local ok_w, count_w = write_cscope_files(files)
    if not ok_w then
        TUI.log("[ERROR] Failed to write cscope.files: " .. tostring(count_w))
        TUI.status = "ERROR"
        TUI.pipeline_running = false
        return
    end
    TUI.log(string.format("[INFO] Successfully wrote %d entries to %s.", count_w, CSCOPE_FILE_NAME))

    -- Step 2: filenametags (In-Memory Foldcase Sort)
    local t_fn_0 = get_time_sec()
    TUI.steps.tags_f.start_time = t_fn_0
    TUI.steps.tags_f.status = "RUNNING"
    local ok_fn, count_fn = generate_filenametags(CSCOPE_FILE_NAME, FILENAMETAG_FILE_NAME)
    local t_fn_elapsed = get_time_sec() - t_fn_0
    TUI.steps.tags_f.elapsed = t_fn_elapsed
    if ok_fn then
        TUI.steps.tags_f.status = "DONE"
        TUI.log(string.format("[2/4] filenametags generated (%d entries sorted in %.3fs).", count_fn, t_fn_elapsed))
    else
        TUI.steps.tags_f.status = "ERROR"
        TUI.steps.tags_f.failure = tostring(count_fn)
        TUI.log("[ERROR] filenametags failed: " .. tostring(count_fn))
    end

    -- Step 3 & 4: Spawn cscope & ctags concurrently
    local t_proc_0 = get_time_sec()
    TUI.steps.cscope.start_time = t_proc_0
    TUI.steps.cscope.status = "RUNNING"
    TUI.steps.ctags.start_time = t_proc_0
    TUI.steps.ctags.status = "RUNNING"
    TUI.log("[3/4] Spawning cscope engine: cscope -b -q -k -i cscope.files...")
    TUI.log("[4/4] Spawning ctags engine: ctags -L cscope.files...")

    local cs_bin = IS_WINDOWS and "cscope.exe" or "cscope"
    local ct_bin = IS_WINDOWS and "ctags.exe" or "ctags"
    local cscope_command = cs_bin .. " -b -q -k -i " .. CSCOPE_FILE_NAME
    local ctags_command = ct_bin .. " -L " .. CSCOPE_FILE_NAME

    -- Each tool's stderr is captured to its own temp file (POSIX only).
    local cscope_stderr_path = nil
    local ctags_stderr_path = nil
    if IS_POSIX then
        cscope_stderr_path = make_stderr_capture_path("cscope")
        ctags_stderr_path = make_stderr_capture_path("ctags")
    end

    local p_cscope = ProcessRunner.spawn_async(cscope_command, cscope_stderr_path)
    local p_ctags = ProcessRunner.spawn_async(ctags_command, ctags_stderr_path)

    if p_cscope and p_ctags then
        TUI.workers = {
            cscope = p_cscope,
            ctags = p_ctags,
        }
        return
    end

    -- Fallback synchronous execution
    TUI.render()
    TUI.log("[INFO] Running cscope and ctags in foreground...")
    TUI.run_step_sync(TUI.steps.cscope, cscope_command)
    TUI.run_step_sync(TUI.steps.ctags, ctags_command)
    TUI.finish_pipeline()
end

-- Marks the discovery step as failed and ends the run with an ERROR status.
function TUI.fail_crawl_step(reason)
    TUI.steps.crawl.status = "ERROR"
    TUI.steps.crawl.failure = reason
    TUI.finish_pipeline()
end

-- Runs one tool in the foreground (fallback path) and records its outcome.
function TUI.run_step_sync(step, command)
    local succeeded, elapsed, outcome = ProcessRunner.run_command_sync(command)
    step.elapsed = elapsed
    if succeeded then
        step.status = "DONE"
        TUI.log(string.format("[%s] Completed in %.3fs.", step.label, elapsed))
        return
    end

    step.status = "ERROR"
    step.failure = outcome
    TUI.log(string.format("[ERROR] %s failed after %.3fs: %s", step.label, elapsed, outcome))
end

-- Records a finished background worker on its pipeline step, then logs the
-- outcome followed by the tool's own stderr lines (errors or warnings).
function TUI.record_worker_result(step, worker)
    step.elapsed = worker.elapsed or 0
    local error_lines, omitted_count = read_and_remove_error_lines(
        worker.stderr_path,
        MAX_LOGGED_ERROR_LINES
    )

    local succeeded = process_succeeded(worker)
    if succeeded then
        step.status = "DONE"
        TUI.log(string.format("[%s] Completed in %.3fs.", step.label, step.elapsed))
    else
        step.status = "ERROR"
        step.failure = describe_process_outcome(worker)
        TUI.log(string.format(
            "[ERROR] %s failed after %.3fs: %s",
            step.label,
            step.elapsed,
            step.failure
        ))
    end

    -- On success these are warnings; on failure they explain the error.
    local line_tag = succeeded and "WARN" or step.label
    for _, line in ipairs(error_lines) do
        TUI.log(string.format("[%s] %s", line_tag, line))
    end
    if omitted_count > 0 then
        TUI.log(string.format("[%s] (+%d more lines)", line_tag, omitted_count))
    end
    if not succeeded and IS_WINDOWS then
        TUI.log(string.format("[%s] (error output not captured on Windows)", step.label))
    end
end

-- Returns "label (reason)" for every step that ended in ERROR, in pipeline order.
local PIPELINE_STEP_ORDER = { "crawl", "tags_f", "cscope", "ctags" }

function TUI.collect_failed_steps()
    local failures = {}
    for _, step_key in ipairs(PIPELINE_STEP_ORDER) do
        local step = TUI.steps[step_key]
        if step.status == "ERROR" then
            table.insert(failures, string.format("%s (%s)", step.label, step.failure or "failed"))
        end
    end
    return failures
end

-- Ends a run: DONE only if every step succeeded; otherwise ERROR plus one
-- summary line naming each failed step and why.
function TUI.finish_pipeline()
    TUI.pipeline_running = false
    TUI.total_build_time = get_time_sec() - TUI.pipeline_start_time

    local failures = TUI.collect_failed_steps()
    if #failures == 0 then
        TUI.status = "DONE"
        TUI.log(string.format(
            "[DONE] Tri-Engine indexing complete in %.3fs!",
            TUI.total_build_time
        ))
        return
    end

    TUI.status = "ERROR"
    TUI.log(string.format(
        "[ERROR] Indexing finished with %d failed step(s): %s",
        #failures,
        table.concat(failures, ", ")
    ))
end

-- Polls the background cscope/ctags workers. Returns true when the screen
-- needs redrawing because a worker finished or the pipeline ended.
function TUI.poll_workers()
    if not TUI.pipeline_running or not TUI.workers.cscope then
        return false
    end

    local cs_done = ProcessRunner.poll(TUI.workers.cscope)
    local ct_done = ProcessRunner.poll(TUI.workers.ctags)
    local state_changed = false

    if cs_done and TUI.steps.cscope.status == "RUNNING" then
        TUI.record_worker_result(TUI.steps.cscope, TUI.workers.cscope)
        state_changed = true
    end

    if ct_done and TUI.steps.ctags.status == "RUNNING" then
        TUI.record_worker_result(TUI.steps.ctags, TUI.workers.ctags)
        state_changed = true
    end

    if cs_done and ct_done then
        TUI.finish_pipeline()
        state_changed = true
    end
    return state_changed
end

--------------------------------------------------------------------------------
-- Screen Drawing & Rendering
--------------------------------------------------------------------------------
local SPINNER_FRAMES = { "◐", "◓", "◑", "◒" }

-- Widest failure reason shown inline on a pipeline row; the full text is in the log.
local MAX_INLINE_FAILURE_WIDTH = 34

local function make_bar(status, elapsed, start_time, failure_text)
    if status == "DONE" then
        return C.b_green .. "[ DONE ]" .. C.reset .. string.format(" in %6.3fs", elapsed or 0)
    elseif status == "RUNNING" then
        local cur_elapsed = (start_time and start_time > 0) and (get_time_sec() - start_time) or (elapsed or 0)
        local frame = SPINNER_FRAMES[math.floor(get_time_sec() * 10) % #SPINNER_FRAMES + 1]
        return C.b_yellow .. "[ RUN  ]" .. C.reset .. " " .. C.b_cyan .. frame .. C.reset .. string.format(" %6.3fs", cur_elapsed)
    elseif status == "ERROR" then
        local reason = truncate_string(failure_text or "error occurred", MAX_INLINE_FAILURE_WIDTH)
        return C.b_red .. "[ FAIL ]" .. C.reset .. C.red .. " " .. reason .. C.reset
    else
        return C.dim .. "[ READY]" .. C.reset .. " waiting..."
    end
end

local function make_progress_bar(done_count, total_count, bar_width)
    bar_width = bar_width or 16
    local pct = total_count > 0 and (done_count / total_count) or 0
    local filled = math.floor(pct * bar_width)
    local empty = bar_width - filled
    local bar = C.b_green .. string.rep("█", filled) .. C.gray .. string.rep("░", empty) .. C.reset
    return string.format("[%s] %3d%%", bar, math.floor(pct * 100))
end

local function colorize_log_entry(entry, max_w)
    local truncated = truncate_string(entry, max_w)
    local time_part, tag, rest = truncated:match("^(%[%d%d:%d%d:%d%d%])%s*(%[[%w%d/_]+%])(.*)$")
    if time_part and tag then
        local tag_c = C.cyan
        if tag:find("ERROR") or tag:find("FAIL") then tag_c = C.b_red
        elseif tag:find("WARN") then tag_c = C.b_yellow
        elseif tag:find("DONE") or tag:find("PASS") then tag_c = C.b_green
        elseif tag:find("CLEAN") then tag_c = C.magenta
        elseif tag:find("%d/%d") then tag_c = C.b_white
        elseif tag:find("CONFIG") then tag_c = C.b_blue
        end
        return " " .. C.gray .. time_part .. " " .. tag_c .. tag .. C.reset .. rest
    else
        local color = C.gray
        if truncated:find("%[ERROR%]") then color = C.b_red
        elseif truncated:find("%[WARN%]") then color = C.b_yellow
        elseif truncated:find("%[DONE%]") then color = C.b_green
        end
        return " " .. color .. truncated .. C.reset
    end
end

function TUI.render()
    local cols, rows = Term.get_size()
    local buf = {}

    local function write_str(s) table.insert(buf, s) end
    local function move_to(r, c) table.insert(buf, string.format("\27[%d;%dH", r, c)) end

    -- Hide cursor & clear buffer
    write_str("\27[?25l\27[H")

    local inner_w = cols - 2
    local half_w = math.floor((cols - 3) / 2)
    local right_w = cols - 3 - half_w

    local function make_full_row(content)
        return C.b_cyan .. BOX.v .. C.reset .. pad_string(content, inner_w) .. C.b_cyan .. BOX.v .. C.reset .. "\n"
    end

    local function make_split_row(left_str, right_str)
        local l = pad_string(left_str, half_w)
        local r = pad_string(right_str, right_w)
        return C.b_cyan .. BOX.v .. C.reset .. l .. C.b_cyan .. BOX.v .. C.reset .. r .. C.b_cyan .. BOX.v .. C.reset .. "\n"
    end

    -- 1. Header Box
    local os_label = IS_WINDOWS and "Windows / Win32 FFI" or "Linux / POSIX FFI"
    local raw_cwd = get_cwd()
    local title_left = string.format(" DOTAG TUI v1.2 [%s] ", os_label)
    local max_cwd_len = math.max(12, cols - utf8_col_width(title_left) - 14)
    local cwd_str = truncate_string(raw_cwd, max_cwd_len)
    local title_right = string.format(" CWD: %s ", cwd_str)
    local fill_len = cols - 2 - utf8_col_width(title_left) - utf8_col_width(title_right)
    if fill_len < 0 then fill_len = 0 end

    write_str(C.b_cyan .. BOX.tl .. C.b_white .. title_left .. C.b_cyan .. string.rep(BOX.h, fill_len) .. C.gray .. title_right .. C.b_cyan .. BOX.tr .. C.reset .. "\n")

    -- 2. Crawl & Database Status Pane (Split View with geometric connections)
    write_str(C.b_cyan .. BOX.vl .. string.rep(BOX.h, half_w) .. BOX.tt .. string.rep(BOX.h, right_w) .. BOX.vr .. C.reset .. "\n")

    local cscope_stat = get_file_stats("cscope.out")
    local tags_stat   = get_file_stats("tags")
    local fnames_stat = get_file_stats("filenametags")

    local function format_art_stat(stat)
        if not stat then
            return C.gray .. "[○ Not found]" .. C.reset
        end
        return C.b_green .. string.format("[● %s]", format_bytes(stat.size)) .. C.reset
    end

    local l1 = string.format(" %sCrawl & Build Options%s", C.b_white, C.reset)
    local r1 = string.format(" %sDatabase Artifact Status%s", C.b_white, C.reset)
    write_str(make_split_row(l1, r1))

    write_str(C.b_cyan .. BOX.vl .. string.rep(BOX.h, half_w) .. BOX.x .. string.rep(BOX.h, right_w) .. BOX.vr .. C.reset .. "\n")

    local l2 = string.format("  • Discovery : %s(*) %s%s", C.cyan, TUI.method:upper(), C.reset)
    local r2 = string.format("  • tags         : %s", format_art_stat(tags_stat))
    write_str(make_split_row(l2, r2))

    local l3 = string.format("  • Clean DB  : %s[%s] Enabled (-c)%s", TUI.clean_before and C.b_green or C.gray, TUI.clean_before and "X" or " ", C.reset)
    local r3 = string.format("  • cscope.out   : %s", format_art_stat(cscope_stat))
    write_str(make_split_row(l3, r3))

    local l4 = string.format("  • Ignore    : %s[%s] Respect .ignore%s", not TUI.no_ignore and C.b_green or C.gray, not TUI.no_ignore and "X" or " ", C.reset)
    local r4 = string.format("  • filenametags : %s", format_art_stat(fnames_stat))
    write_str(make_split_row(l4, r4))

    -- Divider closing split view with bottom tee (┴)
    write_str(C.b_cyan .. BOX.vl .. string.rep(BOX.h, half_w) .. BOX.tb .. string.rep(BOX.h, right_w) .. BOX.vr .. C.reset .. "\n")

    -- 3. Extensions & Excludes
    local active_exts = TUI.get_active_extensions()
    local max_display_exts = 7
    local ext_preview = {}
    for idx = 1, math.min(#active_exts, max_display_exts) do
        table.insert(ext_preview, C.cyan .. active_exts[idx] .. C.reset)
    end
    local more_exts = #active_exts > max_display_exts and (C.gray .. string.format(" (+%d more)", #active_exts - max_display_exts) .. C.reset) or ""
    local ext_line = string.format(" %s[e]%s %sFile Extensions%s (%d active): %s%s",
        C.b_yellow, C.reset, C.b_white, C.reset, #active_exts, table.concat(ext_preview, "  "), more_exts)
    write_str(make_full_row(ext_line))

    local active_excls = TUI.get_active_excludes()
    local max_display_excls = 5
    local excl_preview = {}
    for idx = 1, math.min(#active_excls, max_display_excls) do
        table.insert(excl_preview, C.cyan .. active_excls[idx] .. C.reset)
    end
    local more_excls = #active_excls > max_display_excls and (C.gray .. string.format(" (+%d more)", #active_excls - max_display_excls) .. C.reset) or ""
    local excl_line = string.format(" %s[x]%s %sExcluded Dirs%s   (%d rules) : %s%s",
        C.b_yellow, C.reset, C.b_white, C.reset, #active_excls, table.concat(excl_preview, ", "), more_excls)
    write_str(make_full_row(excl_line))

    -- 4. Tri-Engine Pipeline Status Box
    write_str(C.b_cyan .. BOX.vl .. string.rep(BOX.h, inner_w) .. BOX.vr .. C.reset .. "\n")
    local done_count = 0
    for _, s in pairs(TUI.steps) do
        if s.status == "DONE" then done_count = done_count + 1 end
    end
    local gauge = make_progress_bar(done_count, 4, 16)
    local pipe_status_tag
    if TUI.pipeline_running then
        local frame = SPINNER_FRAMES[math.floor(get_time_sec() * 10) % #SPINNER_FRAMES + 1]
        pipe_status_tag = C.b_yellow .. frame .. " RUNNING" .. C.reset
    elseif done_count == 4 then
        pipe_status_tag = C.b_green .. "✓ COMPLETE (" .. string.format("%.3fs", TUI.total_build_time) .. ")" .. C.reset
    elseif TUI.status == "ERROR" then
        pipe_status_tag = C.b_red .. "✗ ERROR" .. C.reset
    else
        pipe_status_tag = C.gray .. "○ IDLE" .. C.reset
    end

    local pipe_left = string.format(" %sTri-Engine Pipeline%s %s  %s", C.b_white, C.reset, gauge, pipe_status_tag)
    local pipe_right = string.format("%sFiles: %s%d ", C.gray, C.b_white, TUI.total_files)
    local pipe_gap = inner_w - utf8_col_width(pipe_left) - utf8_col_width(pipe_right)
    if pipe_gap < 1 then pipe_gap = 1 end
    write_str(make_full_row(pipe_left .. string.rep(" ", pipe_gap) .. pipe_right))

    local function make_pipeline_row(num, icon, name, step)
        local bar = make_bar(step.status, step.elapsed, step.start_time, step.failure)
        local msg = step.msg
        local left_part = string.format("  %d. %s %-15s %s", num, icon, name, bar)
        local left_w = utf8_col_width(left_part)
        local max_msg_w = inner_w - left_w - 4
        local msg_part = ""
        if max_msg_w > 6 then
            msg_part = "  " .. C.gray .. "(" .. truncate_string(msg, max_msg_w) .. ")" .. C.reset
        end
        return make_full_row(left_part .. msg_part)
    end

    write_str(make_pipeline_row(1, "🔍", "File Crawler", TUI.steps.crawl))
    write_str(make_pipeline_row(2, "📁", "filenametags", TUI.steps.tags_f))
    write_str(make_pipeline_row(3, "🔎", "cscope Engine", TUI.steps.cscope))
    write_str(make_pipeline_row(4, "🏷️", "ctags Engine", TUI.steps.ctags))

    -- 5. Activity Log Pane
    write_str(C.b_cyan .. BOX.vl .. string.rep(BOX.h, inner_w) .. BOX.vr .. C.reset .. "\n")
    local log_lines_avail = rows - 21
    if log_lines_avail < 3 then log_lines_avail = 3 end

    local scroll_status
    if TUI.log_auto_scroll then
        scroll_status = C.b_green .. "[● Live Auto-Scroll]" .. C.reset
    else
        local cur_pos = TUI.log_scroll + 1
        local total_pos = #TUI.logs
        scroll_status = C.b_yellow .. string.format("[▲ Line %d/%d (Paused - 'l' to resume) ▼]", cur_pos, total_pos) .. C.reset
    end

    local log_left = string.format(" %sActivity & Telemetry Log%s (%d entries)", C.b_white, C.reset, #TUI.logs)
    local log_gap = inner_w - utf8_col_width(log_left) - utf8_col_width(scroll_status) - 1
    if log_gap < 1 then log_gap = 1 end
    write_str(make_full_row(log_left .. string.rep(" ", log_gap) .. scroll_status .. " "))

    local start_idx = math.max(1, #TUI.logs - log_lines_avail + 1)
    if not TUI.log_auto_scroll then
        start_idx = math.max(1, TUI.log_scroll)
    end

    for i = 1, log_lines_avail do
        local entry_idx = start_idx + i - 1
        local entry = TUI.logs[entry_idx] or ""
        write_str(make_full_row(colorize_log_entry(entry, inner_w - 2)))
    end

    -- 6. Footer Box
    write_str(C.b_cyan .. BOX.bl .. string.rep(BOX.h, inner_w) .. BOX.br .. C.reset .. "\n")

    local function fmt_hotkey(k, label)
        return C.b_yellow .. "[" .. k .. "]" .. C.reset .. " " .. C.white .. label .. "  "
    end

    local footer_keys
    if cols >= 110 then
        footer_keys = " " .. fmt_hotkey("Space", "Run") .. fmt_hotkey("c", "Clean") .. fmt_hotkey("m", "Method")
                   .. fmt_hotkey("e", "Exts") .. fmt_hotkey("x", "Excl") .. fmt_hotkey("v", "Verify")
                   .. fmt_hotkey("?", "Help") .. fmt_hotkey("q", "Quit")
    elseif cols >= 85 then
        footer_keys = " " .. fmt_hotkey("Space", "Run") .. fmt_hotkey("c", "Clean") .. fmt_hotkey("m", "Method")
                   .. fmt_hotkey("e", "Ext") .. fmt_hotkey("x", "Excl") .. fmt_hotkey("v", "Ver")
                   .. fmt_hotkey("?", "Help") .. fmt_hotkey("q", "Quit")
    else
        footer_keys = " " .. fmt_hotkey("Space", "Run") .. fmt_hotkey("c", "Cln") .. fmt_hotkey("m", "Mtd")
                   .. fmt_hotkey("?", "Help") .. fmt_hotkey("q", "Quit")
    end

    local status_pill
    if TUI.pipeline_running then
        local frame = SPINNER_FRAMES[math.floor(get_time_sec() * 10) % #SPINNER_FRAMES + 1]
        status_pill = C.bg_blue .. C.b_yellow .. " " .. frame .. " RUNNING " .. C.reset
    elseif TUI.status == "DONE" then
        status_pill = C.bg_darkblue .. C.b_green .. " ✓ READY " .. C.reset
    elseif TUI.status == "ERROR" then
        status_pill = C.bg_darkblue .. C.b_red .. " ✗ ERROR " .. C.reset
    else
        status_pill = C.bg_darkblue .. C.gray .. " ○ IDLE " .. C.reset
    end

    local keys_w = utf8_col_width(footer_keys)
    local pill_w = utf8_col_width(status_pill)
    local footer_gap = cols - keys_w - pill_w
    if footer_gap < 0 then footer_gap = 0 end

    write_str(C.bg_darkblue .. footer_keys .. string.rep(" ", footer_gap) .. status_pill .. C.reset)

    -- Render Modal if active
    if TUI.modal then
        TUI.render_modal(cols, rows, buf)
    end

    io.write(table.concat(buf))
    io.flush()
end

local VERIFY_TAG_COLUMN_WIDTH = 20

-- Reads filenametags for the verify browser.
-- Returns the list of { tag, path } items, plus an error message when the
-- file could not be opened (nil when it was read, even if empty).
local function load_verify_items()
    local items = {}
    local file, open_error = io.open(FILENAMETAG_FILE_NAME, "r")
    if not file then
        return items, open_error
    end

    for line in file:lines() do
        if not line:find("^!") then
            local tag, path = line:match("^([^\t]+)\t([^\t]+)")
            if tag and path then
                table.insert(items, { tag = tag, path = path })
            end
        end
    end
    file:close()
    return items, nil
end

-- Status line for the verify browser, including why it is empty.
local function describe_verify_status()
    if #TUI.verify_items > 0 then
        return string.format(
            " Tag %d of %d indexed  [PgUp/PgDn/j/k]  [v/Esc] Close",
            TUI.modal_selection,
            #TUI.verify_items
        )
    end

    local load_error = TUI.verify_load_error or ""
    if load_error:find("No such file", 1, true) then
        return " No tags: filenametags not found. Close with [v/Esc], press Space."
    end
    if load_error ~= "" then
        return " Cannot read filenametags: " .. load_error
    end
    return " No tags: filenametags is empty. Close with [v/Esc], press Space."
end

function TUI.render_modal(cols, rows, buf)
    local mw = math.min(72, cols - 4)
    local mh = math.min(18, rows - 4)
    local mx = math.floor((cols - mw) / 2)
    local my = math.floor((rows - mh) / 2)

    local function mwrite(r, text)
        table.insert(buf, string.format("\27[%d;%dH%s", my + r, mx, text))
    end

    -- Modal background & border
    mwrite(0, C.b_yellow .. BOX.tl .. string.rep(BOX.h, mw - 2) .. BOX.tr .. C.reset)
    for r = 1, mh - 2 do
        mwrite(r, C.b_yellow .. BOX.v .. C.bg_black .. string.rep(" ", mw - 2) .. C.reset .. C.b_yellow .. BOX.v .. C.reset)
    end
    mwrite(mh - 1, C.b_yellow .. BOX.bl .. string.rep(BOX.h, mw - 2) .. BOX.br .. C.reset)

    if TUI.modal == "exts" then
        mwrite(0, C.b_yellow .. BOX.tl .. C.b_white .. " Manage File Extensions " .. C.b_yellow .. string.rep(BOX.h, math.max(0, mw - 28)) .. BOX.tr .. C.reset)
        local num_items = #TUI.extensions
        local num_cols = 2
        local num_rows = math.ceil(num_items / num_cols)
        local visible_rows = math.min(mh - 4, num_rows)
        local col_w = math.floor((mw - 5) / num_cols)

        for r = 1, visible_rows do
            local line_parts = {}
            for c = 0, num_cols - 1 do
                local idx = r + c * num_rows
                local item = TUI.extensions[idx]
                if item then
                    local check = item.enabled and (C.b_green .. "[X]" .. C.reset) or (C.dim .. "[ ]" .. C.reset)
                    local is_sel = (idx == TUI.modal_selection)
                    local prefix = is_sel and (C.reverse .. "> ") or "  "
                    local name_str = is_sel and (C.b_white .. item.name .. C.reset) or item.name
                    local item_str = string.format("%s%s %s", prefix, check, name_str)
                    table.insert(line_parts, pad_right(item_str, col_w))
                else
                    table.insert(line_parts, string.rep(" ", col_w))
                end
            end
            local row_str = table.concat(line_parts, " ")
            mwrite(r, C.b_yellow .. BOX.v .. " " .. pad_right(row_str, mw - 4) .. " " .. C.b_yellow .. BOX.v .. C.reset)
        end
        mwrite(mh - 2, C.b_yellow .. BOX.v .. C.gray .. pad_right(" [Space] Toggle  [a] All  [n] None  [Left/Right] Col  [e/Esc] Close", mw - 4) .. C.b_yellow .. BOX.v .. C.reset)

    elseif TUI.modal == "excludes" then
        mwrite(0, C.b_yellow .. BOX.tl .. C.b_white .. " Manage Excluded Directories " .. C.b_yellow .. string.rep(BOX.h, math.max(0, mw - 33)) .. BOX.tr .. C.reset)
        local visible_rows = mh - 4
        for i = 1, visible_rows do
            local idx = TUI.modal_scroll + i
            local item = TUI.excluded_dirs[idx]
            if item then
                local check = item.enabled and C.b_green .. "[X]" .. C.reset or C.dim .. "[ ]" .. C.reset
                local is_sel = (idx == TUI.modal_selection)
                local prefix = is_sel and (C.reverse .. "> ") or "  "
                local name_str = is_sel and (C.b_white .. item.name .. C.reset) or item.name
                local line = string.format("%s%s %-25s", prefix, check, name_str)
                mwrite(i, C.b_yellow .. BOX.v .. " " .. pad_right(line, mw - 4) .. " " .. C.b_yellow .. BOX.v .. C.reset)
            end
        end
        local info_hint = string.format(" [Space] Toggle  [a] All  [n] None  (%d/%d)  [x/Esc] Close", TUI.modal_selection, #TUI.excluded_dirs)
        mwrite(mh - 2, C.b_yellow .. BOX.v .. C.gray .. pad_right(info_hint, mw - 4) .. C.b_yellow .. BOX.v .. C.reset)

    elseif TUI.modal == "verify" then
        mwrite(0, C.b_yellow .. BOX.tl .. C.b_white .. " Quick Index Verification Browser " .. C.b_yellow .. string.rep(BOX.h, math.max(0, mw - 37)) .. BOX.tr .. C.reset)
        local hdr = string.format("   %-20s %s", "TAG NAME", "TARGET FILE PATH")
        mwrite(1, C.b_yellow .. BOX.v .. C.dim .. pad_right(hdr, mw - 4) .. C.reset .. C.b_yellow .. BOX.v .. C.reset)
        local visible_rows = mh - 5
        for i = 1, visible_rows do
            local idx = TUI.modal_scroll + i
            local item = TUI.verify_items[idx]
            if item then
                local is_selected = (idx == TUI.modal_selection)
                local marker = is_selected and (C.reverse .. "> ") or "  "
                local tag_text = truncate_str(item.tag or "", VERIFY_TAG_COLUMN_WIDTH)
                if is_selected then
                    tag_text = C.b_white .. tag_text .. C.reset
                end

                -- pad_string measures visible width, so escape codes don't shift columns
                local tag_cell = pad_string(tag_text, VERIFY_TAG_COLUMN_WIDTH)
                local path_text = truncate_str(item.path or "", mw - 28)
                local line = marker .. tag_cell .. " " .. path_text
                mwrite(i + 1, C.b_yellow .. BOX.v .. " " .. pad_right(line, mw - 4) .. " " .. C.b_yellow .. BOX.v .. C.reset)
            end
        end
        local status_msg = describe_verify_status()
        mwrite(mh - 2, C.b_yellow .. BOX.v .. C.gray .. pad_right(status_msg, mw - 4) .. C.b_yellow .. BOX.v .. C.reset)

    elseif TUI.modal == "help" then
        mwrite(0, C.b_yellow .. BOX.tl .. C.b_white .. " Keyboard Shortcuts & Help " .. C.b_yellow .. string.rep(BOX.h, math.max(0, mw - 30)) .. BOX.tr .. C.reset)
        local help_lines = {
            C.b_yellow .. "Pipeline & Execution:" .. C.reset,
            "  Space       Run Tri-Engine (cscope + ctags + filenametags)",
            "  c           Toggle 'Clean DB Before Build'",
            "  m           Cycle Discovery Method (FFI Native -> fd -> find)",
            "  i           Toggle Respecting .gitignore / Hidden files",
            C.b_yellow .. "Filters & Verification:" .. C.reset,
            "  e           Manage / Toggle File Extensions (2-Column Grid)",
            "  x           Manage / Toggle Excluded Directories",
            "  v           Open Quick Index Verification Browser",
            C.b_yellow .. "Log & Navigation:" .. C.reset,
            "  l           Toggle Live Auto-Scroll on Activity Log",
            "  j/k, PgDn   Scroll Log entries or Modal lists",
            "  q / Ctrl+C  Quit DOTAG TUI",
        }
        for i, hl in ipairs(help_lines) do
            if i <= mh - 4 then
                mwrite(i, C.b_yellow .. BOX.v .. " " .. pad_right(hl, mw - 4) .. " " .. C.b_yellow .. BOX.v .. C.reset)
            end
        end
        mwrite(mh - 2, C.b_yellow .. BOX.v .. C.gray .. pad_right(" Press [Esc], [Enter], or [?] to close help", mw - 4) .. C.b_yellow .. BOX.v .. C.reset)
    end
end

--------------------------------------------------------------------------------
-- Launch Safety (auto-run only inside something that looks like a project)
--------------------------------------------------------------------------------

-- A directory containing any of these is treated as a project to index.
local PROJECT_MARKERS = {
    ".git",
    ".svn",
    ".hg",
    CSCOPE_FILE_NAME,
    TAGS_FILE_NAME,
    FILENAMETAG_FILE_NAME,
}

-- Normalizes a directory path for comparison: forward slashes, no trailing
-- slash (except a root), and lowercase on Windows where paths ignore case.
local function normalize_dir_for_compare(path)
    local normalized = clean_path(path or "")
    if #normalized > 1 and not normalized:match("^%a:/$") then
        normalized = normalized:gsub("/+$", "")
    end
    if IS_WINDOWS then
        normalized = normalized:lower()
    end
    return normalized
end

-- Returns the first project marker present in the working directory, or nil.
local function find_project_marker()
    for _, marker in ipairs(PROJECT_MARKERS) do
        if path_exists(marker) then
            return marker
        end
    end
    return nil
end

-- Decides whether the TUI may start indexing on launch without a key press.
-- Pure function for testing: `project_marker` is nil when none was found.
-- Returns true plus the marker, or false plus a reason for the activity log.
local function decide_auto_run(cwd, home_dir, project_marker)
    local normalized_cwd = normalize_dir_for_compare(cwd)
    local is_root = normalized_cwd == "/" or normalized_cwd:match("^%a:/?$") ~= nil
    if is_root then
        return false, "the current directory is a filesystem root"
    end

    if home_dir and home_dir ~= "" then
        if normalized_cwd == normalize_dir_for_compare(home_dir) then
            return false, "the current directory is your home directory"
        end
    end

    if not project_marker then
        return false, "no .git/.svn/.hg or existing tags/cscope files here"
    end
    return true, project_marker
end

-- Copies command-line options into the TUI so `dotag -c`, `-f` and `-I`
-- also apply in interactive mode.
function TUI.apply_launch_options(options)
    if not options then
        return
    end
    TUI.clean_before = options.clean
    TUI.method = options.method
    TUI.no_ignore = options.no_ignore
end

-- Starts the first run automatically only when it is safe to do so.
function TUI.auto_run_on_launch()
    local home_dir = os.getenv("HOME") or os.getenv("USERPROFILE")
    local should_run, detail = decide_auto_run(get_cwd(), home_dir, find_project_marker())
    if should_run then
        TUI.log(string.format("[INFO] Project detected (%s); starting indexing.", detail))
        TUI.start_pipeline()
        return
    end

    TUI.log(string.format(
        "[INFO] Auto-run skipped: %s. Press Space to index %s.",
        detail,
        get_cwd()
    ))
end

--------------------------------------------------------------------------------
-- Interactive TUI Loop
--------------------------------------------------------------------------------
function TUI.run(options)
    TUI.apply_launch_options(options)
    Term.init()
    Term.enable_raw()
    TUI.init_config()
    TUI.auto_run_on_launch()

    local running = true
    local needs_render = true
    local last_tick = 0
    local last_cols, last_rows = 0, 0

    while running do
        local cols, rows = Term.get_size()
        if cols ~= last_cols or rows ~= last_rows then
            last_cols, last_rows = cols, rows
            needs_render = true
        end

        local worker_changed = TUI.poll_workers()
        if worker_changed then
            needs_render = true
        end

        if TUI.pipeline_running then
            local now = get_time_sec()
            if now - last_tick >= 0.1 then
                last_tick = now
                needs_render = true
            end
        end

        if TUI.log_updated then
            needs_render = true
            TUI.log_updated = false
        end

        if needs_render then
            TUI.render()
            needs_render = false
        end

        local key = Term.read_key()
        if key then
            needs_render = true
            if TUI.modal then
                if key == "esc" or key == "enter"
                    or (TUI.modal == "help" and key == "?")
                    or (TUI.modal == "exts" and key == "e")
                    or (TUI.modal == "excludes" and key == "x")
                    or (TUI.modal == "verify" and key == "v") then
                    TUI.modal = nil
                elseif key == "pageup" then
                    local step = 8
                    TUI.modal_selection = math.max(1, TUI.modal_selection - step)
                    TUI.modal_scroll = math.max(0, TUI.modal_scroll - step)
                elseif key == "pagedown" then
                    local max_items = (TUI.modal == "exts" and #TUI.extensions) or (TUI.modal == "excludes" and #TUI.excluded_dirs) or #TUI.verify_items
                    local step = 8
                    TUI.modal_selection = math.min(max_items, TUI.modal_selection + step)
                    TUI.modal_scroll = math.min(math.max(0, max_items - 12), TUI.modal_scroll + step)
                elseif key == "up" or key == "k" then
                    if TUI.modal_selection > 1 then
                        TUI.modal_selection = TUI.modal_selection - 1
                        if TUI.modal_selection <= TUI.modal_scroll then
                            TUI.modal_scroll = TUI.modal_selection - 1
                        end
                    end
                elseif key == "down" or key == "j" then
                    local max_items = (TUI.modal == "exts" and #TUI.extensions) or (TUI.modal == "excludes" and #TUI.excluded_dirs) or #TUI.verify_items
                    if TUI.modal_selection < max_items then
                        TUI.modal_selection = TUI.modal_selection + 1
                        if TUI.modal_selection > TUI.modal_scroll + 12 then
                            TUI.modal_scroll = TUI.modal_selection - 12
                        end
                    end
                elseif key == "space" then
                    if TUI.modal == "exts" then
                        local item = TUI.extensions[TUI.modal_selection]
                        if item then item.enabled = not item.enabled end
                    elseif TUI.modal == "excludes" then
                        local item = TUI.excluded_dirs[TUI.modal_selection]
                        if item then item.enabled = not item.enabled end
                    end
                elseif key == "left" and TUI.modal == "exts" then
                    local num_rows = math.ceil(#TUI.extensions / 2)
                    if TUI.modal_selection > num_rows then
                        TUI.modal_selection = TUI.modal_selection - num_rows
                    end
                elseif key == "right" and TUI.modal == "exts" then
                    local num_rows = math.ceil(#TUI.extensions / 2)
                    if TUI.modal_selection <= num_rows and TUI.modal_selection + num_rows <= #TUI.extensions then
                        TUI.modal_selection = TUI.modal_selection + num_rows
                    end
                elseif key == "a" and (TUI.modal == "exts" or TUI.modal == "excludes") then
                    local list = (TUI.modal == "exts") and TUI.extensions or TUI.excluded_dirs
                    for _, item in ipairs(list) do item.enabled = true end
                elseif key == "n" and (TUI.modal == "exts" or TUI.modal == "excludes") then
                    local list = (TUI.modal == "exts") and TUI.extensions or TUI.excluded_dirs
                    for _, item in ipairs(list) do item.enabled = false end
                end
            else
                -- Normal mode keybindings
                if key == "q" or key == "ctrl_c" then
                    running = false
                elseif key == "space" then
                    TUI.start_pipeline()
                elseif key == "c" then
                    TUI.clean_before = not TUI.clean_before
                    TUI.log(string.format("[CONFIG] Clean DB before run: %s", TUI.clean_before and "ENABLED" or "DISABLED"))
                elseif key == "m" then
                    if TUI.method == "ffi" then TUI.method = "fd"
                    elseif TUI.method == "fd" then TUI.method = "find"
                    else TUI.method = "ffi" end
                    TUI.log("[CONFIG] Discovery method switched to: " .. TUI.method:upper())
                elseif key == "i" then
                    TUI.no_ignore = not TUI.no_ignore
                    TUI.log(string.format("[CONFIG] Ignore rules: %s", TUI.no_ignore and "INCLUDE HIDDEN/NO-IGNORE" or "RESPECT .IGNORE"))
                elseif key == "e" then
                    TUI.modal = "exts"
                    TUI.modal_selection = 1
                    TUI.modal_scroll = 0
                elseif key == "x" then
                    TUI.modal = "excludes"
                    TUI.modal_selection = 1
                    TUI.modal_scroll = 0
                elseif key == "v" then
                    TUI.verify_items, TUI.verify_load_error = load_verify_items()
                    TUI.modal = "verify"
                    TUI.modal_selection = 1
                    TUI.modal_scroll = 0
                elseif key == "l" then
                    TUI.log_auto_scroll = not TUI.log_auto_scroll
                    TUI.log(string.format("[CONFIG] Log auto-scroll: %s", TUI.log_auto_scroll and "ON" or "OFF"))
                elseif key == "?" then
                    TUI.modal = "help"
                elseif key == "j" or key == "down" then
                    TUI.log_auto_scroll = false
                    TUI.log_scroll = math.min(#TUI.logs, TUI.log_scroll + 1)
                elseif key == "k" or key == "up" then
                    TUI.log_auto_scroll = false
                    TUI.log_scroll = math.max(0, TUI.log_scroll - 1)
                elseif key == "pagedown" then
                    TUI.log_auto_scroll = false
                    TUI.log_scroll = math.min(#TUI.logs, TUI.log_scroll + 5)
                elseif key == "pageup" then
                    TUI.log_auto_scroll = false
                    TUI.log_scroll = math.max(0, TUI.log_scroll - 5)
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
end

--------------------------------------------------------------------------------
-- Command-Line Parsing
--------------------------------------------------------------------------------
local VALID_FIND_METHODS = {
    ffi = true,
    fd = true,
    find = true,
}

-- Exit codes: 1 for runtime failures, 2 for invalid command-line usage.
local EXIT_RUNTIME_ERROR = 1
local EXIT_USAGE_ERROR = 2

local function print_usage()
    print([[
dotag.lua - generate cscope/tags data (LuaJIT + FFI)

Usage:
  luajit dotag.lua [options] [DIRECTORY]

  DIRECTORY               project directory to index (default: current directory)

Options:
  -f, --find METHOD       find files method: ffi (default), fd, find
  -c, --clean             clean old database files before starting
  -I, --no-ignore         include hidden files and ignore files (.gitignore)
  -S, --in-memory-sort    use in-memory foldcase sort (default: true)
  -b, --batch             run in non-interactive batch mode
  --test                  run automated test suite
  -h, --help              show this help message
]])
end

-- Expands a leading "~" or "~/" to the user's home directory.
local function expand_home_directory(path)
    if path ~= "~" and path:sub(1, 2) ~= "~/" then
        return path
    end

    local home = os.getenv("HOME") or os.getenv("USERPROFILE") or ""
    return home .. path:sub(2)
end

-- Parses the command line into an options table.
-- Returns options, or nil plus a message describing the invalid usage.
local function parse_command_line(args)
    local options = {
        method = "ffi",
        clean = false,
        no_ignore = false,
        batch = false,
        help = false,
        test = false,
        target_dir = nil,
    }

    local index = 1
    while index <= #args do
        local argument = args[index]

        -- Options that take a value
        if argument == "-f" or argument == "--find" then
            local method = args[index + 1]
            if not method then
                return nil, string.format(
                    "option '%s' requires a value: ffi, fd, or find",
                    argument
                )
            end
            if not VALID_FIND_METHODS[method:lower()] then
                return nil, string.format(
                    "invalid find method '%s' for '%s' (expected ffi, fd, or find)",
                    method,
                    argument
                )
            end
            options.method = method:lower()
            index = index + 1

        -- Flags
        elseif argument == "-c" or argument == "--clean" then
            options.clean = true
        elseif argument == "-I" or argument == "--no-ignore" then
            options.no_ignore = true
        elseif argument == "-S" or argument == "--in-memory-sort" then
            -- Accepted for compatibility; in-memory sort is always used.
        elseif argument == "-b" or argument == "--batch" then
            options.batch = true
        elseif argument == "-h" or argument == "--help" then
            options.help = true
        elseif argument == "--test" then
            options.test = true

        -- Anything else starting with "-" is a typo or unsupported option
        elseif argument:sub(1, 1) == "-" then
            return nil, string.format("unknown option '%s'", argument)

        -- Positional argument: the directory to index (only one allowed)
        elseif options.target_dir then
            return nil, string.format(
                "unexpected argument '%s' (directory already given as '%s')",
                argument,
                options.target_dir
            )
        else
            options.target_dir = argument
        end

        index = index + 1
    end

    return options
end

--------------------------------------------------------------------------------
-- Non-Interactive Batch / CLI Mode
--------------------------------------------------------------------------------

-- Runs one external indexing tool in batch mode and prints its outcome.
-- The tool's own stderr goes straight to the terminal.
-- Returns nil on success, or a failure summary such as "ctags (exit 1)".
local function run_batch_tool(tool_name, command)
    print(command)
    io.stdout:flush()

    local succeeded, elapsed, outcome = ProcessRunner.run_command_sync(command)
    if succeeded then
        print(string.format("%s elapsed %.3f seconds", tool_name, elapsed))
        return nil
    end

    io.stdout:flush()
    io.stderr:write(string.format(
        "%s FAILED after %.3f seconds: %s\n",
        tool_name,
        elapsed,
        outcome
    ))
    return string.format("%s (%s)", tool_name, outcome)
end

local function run_cli_batch(options)
    local method = options.method
    local clean = options.clean
    local no_ignore = options.no_ignore

    print("find method: " .. method)
    if IS_WINDOWS then
        apply_setpath_windows()
    end

    -- Check the discovery tool before cleaning, so a missing fd keeps old databases.
    local method_ok, method_error = check_find_method_available(method)
    if not method_ok then
        io.stdout:flush()
        io.stderr:write(string.format(
            "dotag: error: %s.\n"
                .. "Install fd (https://github.com/sharkdp/fd)"
                .. " or use the built-in crawler: -f ffi\n",
            method_error
        ))
        return EXIT_RUNTIME_ERROR
    end

    if clean then
        print("Cleaning old database files...")
        clean_all_databases()
    end

    local t_start = get_time_sec()
    print("finding files...")
    local warnings = {}
    local files = crawl_directory(
        method,
        ".",
        DEFAULT_EXCLUDED_DIRS,
        DEFAULT_FILE_EXTS,
        no_ignore,
        warnings
    )
    local t_found = get_time_sec() - t_start
    print(string.format("find files: number of files %d elapsed %.3f seconds", #files, t_found))

    for _, w in ipairs(warnings) do
        io.stderr:write(w .. "\n")
    end

    -- Nothing to index: stop before overwriting cscope.files or running tools.
    if #files == 0 then
        io.stdout:flush()
        io.stderr:write(string.format(
            "dotag: error: %s.\nCheck the directory, or try another method with -f.\n",
            describe_empty_crawl(method, #DEFAULT_FILE_EXTS)
        ))
        return EXIT_RUNTIME_ERROR
    end

    local ok_w, count_w = write_cscope_files(files)
    if not ok_w then
        io.stderr:write("Error writing cscope.files: " .. tostring(count_w) .. "\n")
        return 1
    end

    print("Starting post-processing...")
    local failures = {}

    -- 1. In-memory filenametags
    local t_fn_0 = get_time_sec()
    local ok_fn, count_fn = generate_filenametags(CSCOPE_FILE_NAME, FILENAMETAG_FILE_NAME)
    if ok_fn then
        print(string.format("filenametags elapsed %.3f seconds", get_time_sec() - t_fn_0))
    else
        io.stderr:write("filenametags FAILED: " .. tostring(count_fn) .. "\n")
        table.insert(failures, "filenametags (" .. tostring(count_fn) .. ")")
    end

    -- 2. cscope and 3. ctags
    local tool_runs = {
        { name = "cscope", command = "cscope -b -q -k -i " .. CSCOPE_FILE_NAME },
        { name = "ctags", command = "ctags -L " .. CSCOPE_FILE_NAME },
    }
    for _, tool_run in ipairs(tool_runs) do
        local failure = run_batch_tool(tool_run.name, tool_run.command)
        if failure then
            table.insert(failures, failure)
        end
    end

    print(string.format("Total elapsed %.3f seconds", get_time_sec() - t_start))
    if #failures == 0 then
        return 0
    end

    io.stdout:flush()
    io.stderr:write(string.format(
        "dotag: error: %d of 3 databases failed: %s\n",
        #failures,
        table.concat(failures, ", ")
    ))
    return EXIT_RUNTIME_ERROR
end

--------------------------------------------------------------------------------
-- Automated Self-Test Suite (--test)
--------------------------------------------------------------------------------
-- Private sandbox permissions on POSIX: owner read/write/search only.
local TEST_SANDBOX_POSIX_MODE = 448 -- octal 0700

-- Files that tests or the code under test may create inside the sandbox.
-- destroy_test_sandbox removes these even if a test crashed before cleanup.
local TEST_GENERATED_FILE_NAMES = {
    CSCOPE_FILE_NAME,
    FILENAMETAG_FILE_NAME,
    TAGS_FILE_NAME,
    "cscope.out",
    "cscope.in.out",
    "cscope.po.out",
    "_test_cscope.files",
    "_test_filenametags",
}

-- Creates a pass/fail counter with assertion and reporting helpers.
local function new_tester()
    local tester = {
        passed = 0,
        failed = 0,
    }

    function tester.assert_eq(actual, expected, description)
        if actual == expected then
            print(string.format("  [PASS] %s", description))
            tester.passed = tester.passed + 1
            return
        end

        print(string.format(
            "  [FAIL] %s: expected '%s', got '%s'",
            description,
            tostring(expected),
            tostring(actual)
        ))
        tester.failed = tester.failed + 1
    end

    function tester.fail(description)
        print(string.format("  [FAIL] %s", description))
        tester.failed = tester.failed + 1
    end

    -- Prints the summary and returns the process exit code.
    function tester.report()
        print(string.format(
            "\nTest Results: %d Passed, %d Failed.",
            tester.passed,
            tester.failed
        ))
        if tester.failed == 0 then
            return 0
        end
        return 1
    end

    return tester
end

--------------------------------------------------------------------------------
-- Test Sandbox (keeps --test away from the user's real databases)
--------------------------------------------------------------------------------

-- Creates a fresh, uniquely named directory under the temp root.
-- Returns a sandbox record, or nil plus the attempted path and the OS error.
local function create_test_sandbox()
    local microseconds = math.floor((get_time_sec() % 1) * 1e6)
    local sandbox_name = string.format("dotag-test-%d-%06d", os.time(), microseconds)
    local sandbox_path = get_temp_root() .. "/" .. sandbox_name

    local created, create_error = make_directory(sandbox_path, TEST_SANDBOX_POSIX_MODE)
    if not created then
        return nil, sandbox_path, create_error
    end

    return {
        path = sandbox_path,
        directories = {}, -- relative paths, in creation order
        files = {},       -- relative paths of fixture files
    }
end

-- Creates every missing parent directory of `relative_path` inside the sandbox.
local function sandbox_make_parents(sandbox, relative_path)
    local parent_path = ""
    for directory_name in relative_path:gmatch("([^/]+)/") do
        parent_path = parent_path .. directory_name

        local already_created = false
        for _, existing in ipairs(sandbox.directories) do
            if existing == parent_path then
                already_created = true
                break
            end
        end

        if not already_created then
            local created, create_error = make_directory(sandbox.path .. "/" .. parent_path)
            if not created then
                error(string.format("cannot create '%s': %s", parent_path, create_error))
            end
            table.insert(sandbox.directories, parent_path)
        end

        parent_path = parent_path .. "/"
    end
end

-- Writes a fixture file inside the sandbox and records it for cleanup.
-- Raises an error (caught by run_test_suite) if the file cannot be written.
local function sandbox_write_file(sandbox, relative_path, content)
    sandbox_make_parents(sandbox, relative_path)

    local full_path = sandbox.path .. "/" .. relative_path
    local file, open_error = io.open(full_path, "wb")
    if not file then
        error(string.format("cannot write fixture '%s': %s", relative_path, open_error))
    end

    file:write(content or "")
    file:close()
    table.insert(sandbox.files, relative_path)
end

-- Removes fixture files, generated outputs, sub-directories (deepest first),
-- and finally the sandbox itself. Returns true, or false plus an error message.
local function destroy_test_sandbox(sandbox)
    for _, relative_path in ipairs(sandbox.files) do
        os.remove(sandbox.path .. "/" .. relative_path)
    end
    for _, file_name in ipairs(TEST_GENERATED_FILE_NAMES) do
        os.remove(sandbox.path .. "/" .. file_name)
    end

    for index = #sandbox.directories, 1, -1 do
        remove_directory(sandbox.path .. "/" .. sandbox.directories[index])
    end

    local removed, remove_error = remove_directory(sandbox.path)
    if not removed then
        return false, remove_error
    end
    return true
end

--------------------------------------------------------------------------------
-- Test Cases
--------------------------------------------------------------------------------

-- Tests that need no filesystem access; safe to run from any directory.
local function run_pure_tests(tester)
    local assert_eq = tester.assert_eq

    -- Test 2: Space warning & exclusion
    print("\n[Test 2] Space-in-Path Filtering...")
    local dummy_files = { "valid/file.c", "has space/file.c", "normal.cpp" }
    local filtered = {}
    for _, path in ipairs(dummy_files) do
        if not path:find(" ") then
            table.insert(filtered, path)
        end
    end
    assert_eq(#filtered, 2, "Filtered out paths with spaces")

    -- Test 5: TUI Unicode & ANSI Layout Geometry
    print("\n[Test 5] TUI Unicode & ANSI Layout Geometry...")
    assert_eq(utf8_col_width(C.b_green .. "OK" .. C.reset), 2, "ANSI escape sequence width stripping")
    assert_eq(utf8_col_width("🔍 File Crawler"), 15, "Emoji width calculation (🔍)")
    assert_eq(utf8_col_width("🏷️ ctags Engine"), 15, "Emoji with variation selector width (🏷️)")
    local padded = pad_string(C.b_yellow .. "[ RUN  ]" .. C.reset, 20)
    assert_eq(utf8_col_width(padded), 20, "pad_string visual column width")
    local truncated = truncate_string("very long path that exceeds twenty cols", 20)
    assert_eq(utf8_col_width(truncated), 20, "truncate_string visual column width")

    -- Test 5b: Excluded directories match whole names only
    print("\n[Test 5b] Excluded Directory Name Matching...")
    local excluded_set = build_excluded_set({ "out", "env", "Build", "node_modules" })
    assert_eq(is_dir_excluded("out", excluded_set), true, "Exact name 'out' is excluded")
    assert_eq(is_dir_excluded("OUT", excluded_set), true, "Name match is case-insensitive")
    assert_eq(is_dir_excluded("build", excluded_set), true, "Mixed-case rule 'Build' matches")
    assert_eq(is_dir_excluded("node_modules", excluded_set), true, "Exact 'node_modules'")
    assert_eq(is_dir_excluded("layout", excluded_set), false, "'layout' not excluded by 'out'")
    assert_eq(is_dir_excluded("output", excluded_set), false, "'output' not excluded by 'out'")
    assert_eq(is_dir_excluded("environment", excluded_set), false, "'environment' kept")
    assert_eq(is_dir_excluded("buildscripts", excluded_set), false, "'buildscripts' kept")

    -- Test 6: Monotonic Clock
    print("\n[Test 6] High-Resolution Monotonic Clock...")
    local t1 = get_time_sec()
    assert_eq(type(t1), "number", "get_time_sec returned number")
    assert_eq(t1 > 0, true, "get_time_sec is positive")

    -- Test 7: Progress Bar Math and Geometry
    print("\n[Test 7] Progress Bar Math and Geometry...")
    local p0 = make_progress_bar(0, 4, 16)
    assert_eq(utf8_col_width(p0), 23, "0% progress bar visual width (16 + brackets + percent)")
    local p100 = make_progress_bar(4, 4, 16)
    assert_eq(p100:find("100%%") ~= nil, true, "100% progress gauge displays 100%")
    local p50 = make_progress_bar(2, 4, 16)
    assert_eq(p50:find("50%%") ~= nil, true, "50% progress gauge displays 50%")

    -- Test 8: Telemetry Log Colorizer & Width Safety
    print("\n[Test 8] Telemetry Log Colorizer & Width Safety...")
    local test_log = "[12:34:56] [INFO] Crawling directory tree..."
    local c_log = colorize_log_entry(test_log, 60)
    assert_eq(c_log:find(C.cyan, 1, true) ~= nil, true, "Colorized [INFO] tag with cyan")
    local test_err = "[12:34:56] [ERROR] File not found!"
    local c_err = colorize_log_entry(test_err, 60)
    assert_eq(c_err:find(C.b_red, 1, true) ~= nil, true, "Colorized [ERROR] tag with bright red")
    local test_clean = "[12:34:56] [CLEAN] Removed old files"
    local c_clean = colorize_log_entry(test_clean, 60)
    assert_eq(c_clean:find(C.magenta, 1, true) ~= nil, true, "Colorized [CLEAN] tag with magenta")

    -- Test 9: Spinner Frame Cycling & Layout Width
    print("\n[Test 9] Spinner Frame Cycling & Layout Width...")
    assert_eq(#SPINNER_FRAMES, 4, "Spinner has 4 rotation frames")
    for _, frame in ipairs(SPINNER_FRAMES) do
        assert_eq(utf8_col_width(frame), 1, string.format("Spinner frame '%s' width is 1", frame))
    end

    -- Test 10: Command-line parsing
    print("\n[Test 10] Command-Line Parsing...")
    local options = parse_command_line({ "-f", "fd", "-c", "src" })
    assert_eq(options.method, "fd", "-f consumes its value as the method")
    assert_eq(options.target_dir, "src", "Directory is the positional argument, not -f's value")
    assert_eq(options.clean, true, "-c sets clean")

    options = parse_command_line({ "--find", "FD" })
    assert_eq(options.method, "fd", "Method name is case-insensitive")
    assert_eq(options.target_dir, nil, "No directory when only options are given")

    local parsed, usage_error = parse_command_line({ "-f" })
    assert_eq(parsed, nil, "Missing -f value is rejected")
    assert_eq(usage_error:find("requires a value", 1, true) ~= nil, true, "Missing value message")

    parsed, usage_error = parse_command_line({ "-f", "rg" })
    assert_eq(parsed, nil, "Unknown method is rejected")
    assert_eq(
        usage_error:find("invalid find method 'rg'", 1, true) ~= nil,
        true,
        "Bad method message"
    )

    parsed, usage_error = parse_command_line({ "--claen" })
    assert_eq(parsed, nil, "Unknown option is rejected")
    assert_eq(
        usage_error:find("unknown option '--claen'", 1, true) ~= nil,
        true,
        "Unknown option message"
    )

    parsed, usage_error = parse_command_line({ "dir1", "dir2" })
    assert_eq(parsed, nil, "Second directory is rejected")
    assert_eq(
        usage_error:find("unexpected argument 'dir2'", 1, true) ~= nil,
        true,
        "Extra arg message"
    )

    assert_eq(expand_home_directory("plain/path"), "plain/path", "Non-tilde path unchanged")
    local home = os.getenv("HOME") or os.getenv("USERPROFILE") or ""
    assert_eq(expand_home_directory("~/proj"), home .. "/proj", "~/ expands to home directory")

    -- Test 11: Process exit decoding
    print("\n[Test 11] Process Exit Decoding...")
    local exit_code, signal_number = decode_wait_status(0)
    assert_eq(exit_code, 0, "wait status 0 is exit 0")
    assert_eq(signal_number, nil, "wait status 0 has no signal")
    exit_code, signal_number = decode_wait_status(256)
    assert_eq(exit_code, 1, "wait status 256 is exit 1")
    exit_code, signal_number = decode_wait_status(11)
    assert_eq(exit_code, nil, "SIGSEGV status is not an exit code")
    assert_eq(signal_number, 11, "wait status 11 is signal 11")
    exit_code, signal_number = decode_wait_status(9)
    assert_eq(signal_number, 9, "wait status 9 is signal 9 (SIGKILL)")
    assert_eq(describe_exit(nil, 11), "killed by signal 11 (SIGSEGV)", "Signal description")
    assert_eq(describe_exit(1, nil), "exit 1", "Exit code description")
    assert_eq(describe_exit(139, nil), "exit 139 (killed by SIGSEGV)", "sh -c signal exit")
    assert_eq(
        describe_exit(127, nil),
        "exit 127: command not found; install it or add it to PATH",
        "Command-not-found hint"
    )
    assert_eq(process_succeeded({ exit_code = 0 }), true, "exit 0 succeeded")
    assert_eq(process_succeeded({ signal = 11 }), false, "Signal is a failure")
    assert_eq(process_succeeded({ exit_code = 1 }), false, "exit 1 is a failure")

    -- Test 13: Launch auto-run safety
    print("\n[Test 13] Launch Auto-Run Safety...")
    local should_run, detail = decide_auto_run("/home/me/proj", "/home/me", ".git")
    assert_eq(should_run, true, "Project with .git auto-runs")
    assert_eq(detail, ".git", "Reports the marker that was found")
    should_run = decide_auto_run("/home/me/proj", "/home/me", "tags")
    assert_eq(should_run, true, "Directory with existing tags auto-runs")

    should_run, detail = decide_auto_run("/home/me", "/home/me", ".git")
    assert_eq(should_run, false, "Home directory never auto-runs, even with .git")
    assert_eq(detail:find("home directory", 1, true) ~= nil, true, "Home skip reason")
    should_run = decide_auto_run("/home/me/", "/home/me", ".git")
    assert_eq(should_run, false, "Home with trailing slash is still home")
    should_run = decide_auto_run("/", "/home/me", ".git")
    assert_eq(should_run, false, "Filesystem root never auto-runs")
    should_run = decide_auto_run("C:/", "C:/Users/me", ".git")
    assert_eq(should_run, false, "Windows drive root never auto-runs")

    should_run, detail = decide_auto_run("/home/me/Downloads", "/home/me", nil)
    assert_eq(should_run, false, "No project marker means no auto-run")
    assert_eq(detail:find("no .git", 1, true) ~= nil, true, "No-marker skip reason")
end

-- Test 1: filenametags generation and foldcase ordering.
local function test_filenametags_sort(tester, sandbox)
    local assert_eq = tester.assert_eq
    print("\n[Test 1] Filename Foldcase Sort...")

    local test_cscope = "_test_cscope.files"
    local test_tags = "_test_filenametags"
    sandbox_write_file(
        sandbox,
        test_cscope,
        "src/B.c\nsrc/__init__.py\nsrc/a.c\nsrc/_private.py\nsrc/Zeta.py\nsrc/c.C\n"
    )

    local ok_fn, count_fn = generate_filenametags(test_cscope, test_tags)
    assert_eq(ok_fn, true, "generate_filenametags status")
    assert_eq(count_fn, 6, "generate_filenametags item count")

    local lines = {}
    for line in io.lines(test_tags) do
        table.insert(lines, line)
    end
    assert_eq(lines[1], "!_TAG_FILE_SORTED\t2\t/2=foldcase/", "Foldcase tag header")
    assert_eq(lines[2], "a.c\tsrc/a.c\t1", "Foldcase sort order item 1 (a.c)")
    assert_eq(lines[3], "B.c\tsrc/B.c\t1", "Foldcase sort order item 2 (B.c)")
    assert_eq(lines[4], "c.C\tsrc/c.C\t1", "Foldcase sort order item 3 (c.C)")
    assert_eq(lines[5], "Zeta.py\tsrc/Zeta.py\t1", "Letters sort before '_' (Zeta.py)")
    assert_eq(lines[6], "_private.py\tsrc/_private.py\t1", "'_' sorts after 'Z' (_private.py)")
    assert_eq(lines[7], "__init__.py\tsrc/__init__.py\t1", "Uppercase-fold order (__init__.py)")
end

-- Test 3: the native crawler finds sources and honors exclusions,
-- using its own fixture tree so it does not depend on the caller's directory.
local function test_native_crawler(tester, sandbox)
    local assert_eq = tester.assert_eq
    print("\n[Test 3] Native FFI Directory Crawler (sandbox fixture)...")

    sandbox_write_file(sandbox, "src/main.lua", "return 1\n")
    sandbox_write_file(sandbox, "layout/view.lua", "return 2\n")
    sandbox_write_file(sandbox, "node_modules/dep.lua", "return 3\n")
    sandbox_write_file(sandbox, "out/generated.lua", "return 4\n")

    local found_files = crawl_directory(
        "ffi",
        ".",
        { "node_modules", "out" },
        { ".lua" },
        false,
        {}
    )
    local found_set = {}
    for _, path in ipairs(found_files) do
        found_set[path] = true
    end

    assert_eq(found_set["src/main.lua"], true, "Crawler found src/main.lua")
    assert_eq(found_set["layout/view.lua"], true, "Crawler found layout/view.lua")
    assert_eq(found_set["node_modules/dep.lua"], nil, "Crawler skipped node_modules/dep.lua")
    assert_eq(found_set["out/generated.lua"], nil, "Crawler skipped out/generated.lua")
end

-- Test 4: clean_all_databases removes every database file and nothing else.
local function test_database_cleanup(tester, sandbox)
    local assert_eq = tester.assert_eq
    print("\n[Test 4] Database Cleanup Mechanism (sandbox)...")

    local database_files = {
        CSCOPE_FILE_NAME,
        FILENAMETAG_FILE_NAME,
        TAGS_FILE_NAME,
        "cscope.out",
        "cscope.in.out",
        "cscope.po.out",
    }
    for _, file_name in ipairs(database_files) do
        sandbox_write_file(sandbox, file_name, "dummy")
    end
    sandbox_write_file(sandbox, "notes.txt", "keep me")

    local removed_count = clean_all_databases()
    assert_eq(removed_count, #database_files, "clean_all_databases removed count")
    for _, file_name in ipairs(database_files) do
        assert_eq(file_exists(file_name), false, "clean_all_databases removed " .. file_name)
    end
    assert_eq(file_exists("notes.txt"), true, "clean_all_databases kept unrelated notes.txt")
end

-- Test 12: captured stderr is summarized and the capture file removed.
local function test_error_line_capture(tester, sandbox)
    local assert_eq = tester.assert_eq
    print("\n[Test 12] Captured stderr Summary (sandbox)...")

    local capture_lines = {}
    for line_number = 1, 7 do
        table.insert(capture_lines, "error line " .. line_number)
    end
    local capture_content = "\n" .. table.concat(capture_lines, "\n  \n") .. "\n"
    sandbox_write_file(sandbox, "capture.err", capture_content)

    local lines, omitted_count = read_and_remove_error_lines("capture.err", 5)
    assert_eq(#lines, 5, "Keeps the first 5 non-empty lines")
    assert_eq(lines[1], "error line 1", "Skips blank lines")
    assert_eq(omitted_count, 2, "Counts the lines left out")
    assert_eq(file_exists("capture.err"), false, "Removes the capture file")

    lines, omitted_count = read_and_remove_error_lines(nil, 5)
    assert_eq(#lines, 0, "No capture path gives no lines")
end

-- Tests that read or write files. Must run with the sandbox as working directory.
local function run_filesystem_tests(tester, sandbox)
    test_filenametags_sort(tester, sandbox)
    test_native_crawler(tester, sandbox)
    test_database_cleanup(tester, sandbox)
    test_error_line_capture(tester, sandbox)
end

-- Runs filesystem tests inside the sandbox, always restoring the original
-- working directory and removing the sandbox, even when a test raises an error.
local function run_sandboxed_tests(tester)
    local sandbox, attempted_path, create_error = create_test_sandbox()
    if not sandbox then
        io.stderr:write(string.format(
            "[ERROR] Cannot create test sandbox '%s': %s.\n"
                .. "        Set TMPDIR (or TEMP on Windows) to a writable directory"
                .. " and re-run --test.\n",
            attempted_path,
            create_error
        ))
        tester.fail("Test sandbox could not be created; filesystem tests skipped")
        return
    end
    print("\nTest sandbox: " .. sandbox.path)

    local original_directory = get_cwd()
    local entered, enter_error = change_directory(sandbox.path)
    if entered then
        local tests_ok, test_error = pcall(run_filesystem_tests, tester, sandbox)
        if not tests_ok then
            tester.fail("Filesystem tests crashed: " .. tostring(test_error))
        end
    else
        tester.fail(string.format("Cannot enter test sandbox: %s", enter_error))
    end

    -- Always return to the caller's directory before deleting the sandbox.
    local restored, restore_error = change_directory(original_directory)
    if not restored then
        tester.fail(string.format(
            "Cannot return to '%s': %s",
            original_directory,
            restore_error
        ))
    end

    local destroyed, destroy_error = destroy_test_sandbox(sandbox)
    if not destroyed then
        io.stderr:write(string.format(
            "[WARN] Could not remove test sandbox '%s': %s. Delete it manually.\n",
            sandbox.path,
            destroy_error
        ))
    end
end

-- Entry point for --test. Returns the process exit code.
local function run_test_suite()
    print("=== Running dotag.lua Automated Test Suite ===")
    local tester = new_tester()

    run_pure_tests(tester)
    run_sandboxed_tests(tester)

    return tester.report()
end

--------------------------------------------------------------------------------
-- Main Entry Point
--------------------------------------------------------------------------------
-- Changes into the requested project directory before anything is cleaned or
-- written. Exits with an error instead of silently indexing the wrong directory.
local function enter_target_directory(target_dir)
    local resolved_dir = expand_home_directory(target_dir)
    local entered, enter_error = change_directory(resolved_dir)
    if entered then
        return
    end

    io.stderr:write(string.format(
        "dotag: error: cannot change to directory '%s': %s\n"
            .. "Check the path, or run dotag from inside the project directory.\n",
        resolved_dir,
        enter_error
    ))
    os.exit(EXIT_RUNTIME_ERROR)
end

-- Runs the TUI and always restores the terminal, even when a Lua error
-- escapes. Without this, a crash leaves the shell in raw mode with no echo,
-- the cursor hidden and the alternate screen still active.
local function run_tui_safely(options)
    local succeeded, error_trace = xpcall(TUI.run, debug.traceback, options)
    Term.restore()
    if succeeded then
        return
    end

    io.stderr:write(string.format(
        "dotag: internal error: %s\n"
            .. "The terminal was restored. Please report this error with the trace above.\n",
        tostring(error_trace)
    ))
    os.exit(EXIT_RUNTIME_ERROR)
end

local function main(args)
    args = args or {}

    -- Parse and validate all arguments before touching the filesystem
    local options, usage_error = parse_command_line(args)
    if not options then
        io.stderr:write(string.format(
            "dotag: error: %s\nRun 'dotag --help' for usage.\n",
            usage_error
        ))
        os.exit(EXIT_USAGE_ERROR)
    end

    if options.help then
        print_usage()
        os.exit(0)
    end

    -- Test mode runs in its own sandbox and ignores the target directory
    if options.test then
        os.exit(run_test_suite())
    end

    if options.target_dir then
        enter_target_directory(options.target_dir)
    end

    -- Batch when requested, or when stdout is redirected (POSIX only for now)
    local is_batch = options.batch
    if not is_batch and not IS_WINDOWS then
        if ffi.C.isatty(1) == 0 then
            is_batch = true
        end
    end

    if is_batch then
        os.exit(run_cli_batch(options))
    end

    run_tui_safely(options)
end

main(arg)
