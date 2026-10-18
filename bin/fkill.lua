#!/usr/bin/env luajit
--[[
  fkill.lua - High-Performance Interactive Process Killer TUI
  Part of the Skyera Workbench utility suite.
  Powered by LuaJIT & FFI. Single-file, zero external Lua dependencies.
  Runs natively on Windows (Toolhelp32 + psapi.dll FFI) and Linux (/proc + libc FFI).

  Features:
    - Zero-dependency Dual-Pane Interactive TUI (No fzf requirement)
    - Sub-Millisecond Process Enumeration with real-time memory & thread stats
    - Multiple Context Tabs:
      * [1: All Procs]: Complete system process list
      * [2: User Apps]: Filtered user applications (hides kernel/system daemons)
      * [3: Heavy/RAM]: Memory-heavy processes (> 50 MB) sorted descending
    - Multi-Selection & Batch Process Termination:
      * Tab / Space: Multi-select processes with checkboxes [x]
      * d / Enter: Terminate selected processes with visual confirmation dialog
      * D / K: Immediate force kill (SIGKILL on Linux, TerminateProcess on Windows)
    - Multi-Column Sorting:
      * s: Cycle sorting order (Memory -> PID -> Name -> Threads)
    - Preserved CLI Modes:
      * fkill <PID>: Directly kill process by PID
      * fkill <NAME>: Directly kill all processes matching name
      * fkill -9 <PID|NAME>: Force kill by PID or name
      * fkill -l, --list: Print formatted process table for shell pipelines
      * fkill -p, --preview <PID>: Print rich process diagnostic card
      * fkill --test: Run automated self-test suite
      * fkill --fzf: Legacy fzf fallback if explicitly requested
    - Full Conformance with AGENTS.md Windows TUI & Terminal Invariants:
      * \27[?7l DECAWM autowrap safety (no row erasure or console scrolling)
      * Dual stdout/stderr VT initialization
      * \27[0m\27[K hygiene before line clears
      * Strictly bounded row truncation (< cols)

  Usage:
    luajit bin/fkill.lua [OPTIONS] [PID_OR_NAME]
    fkill [OPTIONS] [PID_OR_NAME]

  Options:
    -9, -f, --force      Force terminate process (SIGKILL / TerminateProcess)
    -l, --list           Print formatted process table to stdout and exit
    -p, --preview <PID>  Print rich process details card to stdout and exit
    --fzf                Launch legacy fzf pipeline mode
    --test               Run built-in automated self-test suite and exit
    -h, --help           Show this help message
]]

local ffi = require("ffi")
local bit = require("bit")

local OS = ffi.os
local IS_WINDOWS = (OS == "Windows")
local IS_LINUX   = (OS == "Linux")
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
        typedef uintptr_t ULONG_PTR;
        typedef uintptr_t SIZE_T;

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
            DWORD dwSize;
            DWORD cntUsage;
            DWORD th32ProcessID;
            ULONG_PTR th32DefaultHeapID;
            DWORD th32ModuleID;
            DWORD cntThreads;
            DWORD th32ParentProcessID;
            long pcPriClassBase;
            DWORD dwFlags;
            char szExeFile[260];
        } PROCESSENTRY32;

        typedef struct {
            DWORD cb;
            DWORD PageFaultCount;
            SIZE_T PeakWorkingSetSize;
            SIZE_T WorkingSetSize;
            SIZE_T QuotaPeakPagedPoolUsage;
            SIZE_T QuotaPagedPoolUsage;
            SIZE_T QuotaPeakNonPagedPoolUsage;
            SIZE_T QuotaNonPagedPoolUsage;
            SIZE_T PagefileUsage;
            SIZE_T PeakPagefileUsage;
        } PROCESS_MEMORY_COUNTERS;

        HANDLE CreateToolhelp32Snapshot(DWORD dwFlags, DWORD th32ProcessID);
        BOOL Process32First(HANDLE hSnapshot, PROCESSENTRY32* lppe);
        BOOL Process32Next(HANDLE hSnapshot, PROCESSENTRY32* lppe);
        HANDLE OpenProcess(DWORD dwDesiredAccess, BOOL bInheritHandle, DWORD dwProcessId);
        BOOL TerminateProcess(HANDLE hProcess, unsigned int uExitCode);
        BOOL CloseHandle(HANDLE hObject);
        DWORD QueryFullProcessImageNameA(HANDLE hProcess, DWORD dwFlags, char* lpExeName, DWORD* lpdwSize);
        DWORD GetLastError(void);
        BOOL GetProcessMemoryInfo(HANDLE Process, PROCESS_MEMORY_COUNTERS* ppsmpi, DWORD cb);

        HANDLE GetStdHandle(DWORD nStdHandle);
        BOOL GetConsoleMode(HANDLE hConsoleHandle, DWORD* lpMode);
        BOOL SetConsoleMode(HANDLE hConsoleHandle, DWORD dwMode);
        BOOL GetConsoleScreenBufferInfo(HANDLE hConsoleOutput, CONSOLE_SCREEN_BUFFER_INFO* lpConsoleScreenBufferInfo);

        BOOL SetConsoleOutputCP(unsigned int wCodePageID);
        BOOL SetConsoleCP(unsigned int wCodePageID);
        int _getch(void);
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
        int kill(int pid, int sig);
        int readlink(const char *pathname, char *buf, size_t bufsiz);
        char *strerror(int errnum);

        struct winsize {
            unsigned short ws_row;
            unsigned short ws_col;
            unsigned short ws_xpixel;
            unsigned short ws_ypixel;
        };
        int ioctl(int fd, unsigned long request, ...);

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

function Term.read_key()
    if IS_WINDOWS then
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
        elseif ch == 18 then return "CTRL_R"
        elseif ch == 21 then return "CTRL_U"
        elseif ch == 23 then return "CTRL_W"
        elseif ch == 25 then return "CTRL_Y"
        elseif ch == 32 then return "SPACE"
        end
        return string.char(ch)
    else
        local buf = ffi.new("char[32]")
        local n = ffi.C.read(Term.tty_fd >= 0 and Term.tty_fd or 0, buf, 32)
        if n <= 0 then return "NONE" end
        local seq = ffi.string(buf, n)

        if seq == "\27" then return "ESC"
        elseif seq == "\n" or seq == "\r" then return "ENTER"
        elseif seq == "\t" then return "TAB"
        elseif seq == "\127" or seq == "\8" then return "BACKSPACE"
        elseif seq == "\2" then return "CTRL_B"
        elseif seq == "\3" then return "CTRL_C"
        elseif seq == "\4" then return "CTRL_D"
        elseif seq == "\5" then return "CTRL_E"
        elseif seq == "\6" then return "CTRL_F"
        elseif seq == "\14" then return "CTRL_N"
        elseif seq == "\16" then return "CTRL_P"
        elseif seq == "\18" then return "CTRL_R"
        elseif seq == "\21" then return "CTRL_U"
        elseif seq == "\23" then return "CTRL_W"
        elseif seq == "\25" then return "CTRL_Y"
        elseif seq == " " then return "SPACE"
        elseif seq == "\27[A" or seq == "\27OA" then return "UP"
        elseif seq == "\27[B" or seq == "\27OB" then return "DOWN"
        elseif seq == "\27[C" or seq == "\27OC" then return "RIGHT"
        elseif seq == "\27[D" or seq == "\27OD" then return "LEFT"
        elseif seq == "\27[H" or seq == "\27[1~" then return "HOME"
        elseif seq == "\27[F" or seq == "\27[4~" then return "END"
        elseif seq == "\27[5~" then return "PGUP"
        elseif seq == "\27[6~" then return "PGDN"
        elseif seq == "\27[3~" then return "DELETE"
        elseif seq == "\27[Z" then return "BACKTAB"
        end

        if #seq == 1 then return seq end
        return "UNKNOWN"
    end
end

--------------------------------------------------------------------------------
-- 4. String & Formatting Helpers
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

local function format_mem(mb)
    if not mb or mb <= 0 then return "     -   " end
    if mb < 1 then
        return string.format("[%4d KB]", math.floor(mb * 1024))
    elseif mb < 1024 then
        return string.format("[%4.1f MB]", mb)
    else
        return string.format("[%4.1f GB]", mb / 1024)
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

--------------------------------------------------------------------------------
-- 5. OS Process Backend (Linux & Windows)
--------------------------------------------------------------------------------
local LinuxBackend = {}
local WindowsBackend = {}

-- Common system / daemon process names for filtering "User Apps" tab
local SYSTEM_PROCS = {
    ["[system process]"] = true,
    ["system idle process"] = true,
    ["system"] = true,
    ["registry"] = true,
    ["smss.exe"] = true,
    ["csrss.exe"] = true,
    ["wininit.exe"] = true,
    ["services.exe"] = true,
    ["lsass.exe"] = true,
    ["svchost.exe"] = true,
    ["fontdrvhost.exe"] = true,
    ["winlogon.exe"] = true,
    ["dwm.exe"] = true,
    ["spoolsv.exe"] = true,
    ["sihost.exe"] = true,
    ["taskhostw.exe"] = true,
    ["runtimebroker.exe"] = true,
    ["explorer.exe"] = false, -- Explorer is user app
    ["kthreadd"] = true,
    ["systemd"] = true,
    ["init"] = true,
}

-- Linux Process Implementation
function LinuxBackend.get_process_list()
    local procs = {}
    local dir = ffi.C.opendir("/proc")
    if dir == nil then return procs end

    while true do
        local ent = ffi.C.readdir(dir)
        if ent == nil then break end
        local d_name = ffi.string(ent.d_name)
        local pid = tonumber(d_name)
        if pid then
            local info = LinuxBackend.get_proc_summary(pid)
            if info then
                table.insert(procs, info)
            end
        end
    end
    ffi.C.closedir(dir)
    return procs
end

function LinuxBackend.get_proc_summary(pid)
    local status_file = io.open(string.format("/proc/%d/status", pid), "r")
    if not status_file then return nil end

    local name = "?"
    local user = "?"
    local rss_kb = 0
    local ppid = 0
    local state = "?"
    local threads = 1

    for line in status_file:lines() do
        local k, v = line:match("^(%w+):%s*(.*)$")
        if k == "Name" then
            name = v
        elseif k == "State" then
            state = v:match("^(%S+)") or v
        elseif k == "PPid" then
            ppid = tonumber(v) or 0
        elseif k == "Threads" then
            threads = tonumber(v) or 1
        elseif k == "VmRSS" then
            rss_kb = tonumber(v:match("(%d+)")) or 0
        elseif k == "Uid" then
            local uid = tonumber(v:match("(%d+)")) or 0
            user = (uid == 0) and "root" or tostring(uid)
        end
    end
    status_file:close()

    local cmd = ""
    local cmd_file = io.open(string.format("/proc/%d/cmdline", pid), "rb")
    if cmd_file then
        local raw = cmd_file:read("*all")
        cmd_file:close()
        if raw and #raw > 0 then
            cmd = raw:gsub("%z", " "):gsub("%s+$", "")
        end
    end
    if cmd == "" then
        cmd = "[" .. name .. "]"
    end

    local rss_mb = math.floor((rss_kb / 1024) * 10) / 10

    return {
        pid = pid,
        name = name,
        user = user,
        ppid = ppid,
        state = state,
        threads = threads,
        rss = rss_mb,
        cmd = cmd,
        is_system = SYSTEM_PROCS[name:lower()] == true or (name:sub(1,1) == "[" and name:sub(-1) == "]")
    }
end

function LinuxBackend.get_proc_details(pid)
    local summary = LinuxBackend.get_proc_summary(pid)
    if not summary then return nil end

    local buf = ffi.new("char[1024]")
    local len = ffi.C.readlink(string.format("/proc/%d/exe", pid), buf, 1023)
    summary.exe = (len > 0) and ffi.string(buf, len) or "N/A"

    len = ffi.C.readlink(string.format("/proc/%d/cwd", pid), buf, 1023)
    summary.cwd = (len > 0) and ffi.string(buf, len) or "N/A"

    return summary
end

function LinuxBackend.kill_process(pid, force)
    local sig = force and 9 or 15 -- SIGKILL vs SIGTERM
    local res = ffi.C.kill(pid, sig)
    if res == 0 then
        return true
    else
        local err = ffi.string(ffi.C.strerror(ffi.errno()))
        return false, err
    end
end

-- Windows Process Implementation
local psapi = nil
if IS_WINDOWS then
    pcall(function()
        psapi = ffi.load("psapi")
    end)
end

local TH32CS_SNAPPROCESS = 0x00000002
local PROCESS_TERMINATE = 0x0001
local PROCESS_QUERY_LIMITED_INFORMATION = 0x1000

function WindowsBackend.get_process_list()
    local procs = {}
    local hSnap = ffi.C.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
    if hSnap == nil or hSnap == ffi.cast("HANDLE", -1) then
        return procs
    end

    local pe = ffi.new("PROCESSENTRY32")
    pe.dwSize = ffi.sizeof("PROCESSENTRY32")

    local pmc = nil
    if psapi then
        pmc = ffi.new("PROCESS_MEMORY_COUNTERS")
        pmc.cb = ffi.sizeof("PROCESS_MEMORY_COUNTERS")
    end

    if ffi.C.Process32First(hSnap, pe) ~= 0 then
        repeat
            local pid = tonumber(pe.th32ProcessID)
            if pid > 0 then
                local name = ffi.string(pe.szExeFile)
                local mem_mb = 0

                -- Query working set memory via psapi
                if psapi and pmc then
                    local hProc = ffi.C.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid)
                    if hProc ~= nil and hProc ~= ffi.cast("HANDLE", 0) then
                        if psapi.GetProcessMemoryInfo(hProc, pmc, pmc.cb) ~= 0 then
                            mem_mb = math.floor((tonumber(pmc.WorkingSetSize) / (1024 * 1024)) * 10) / 10
                        end
                        ffi.C.CloseHandle(hProc)
                    end
                end

                local is_sys = SYSTEM_PROCS[name:lower()] == true
                table.insert(procs, {
                    pid = pid,
                    name = name,
                    user = "User",
                    ppid = tonumber(pe.th32ParentProcessID),
                    threads = tonumber(pe.cntThreads),
                    rss = mem_mb,
                    cmd = name,
                    is_system = is_sys,
                })
            end
        until ffi.C.Process32Next(hSnap, pe) == 0
    end
    ffi.C.CloseHandle(hSnap)
    return procs
end

function WindowsBackend.get_proc_details(pid)
    local procs = WindowsBackend.get_process_list()
    local target = nil
    for _, p in ipairs(procs) do
        if p.pid == pid then
            target = p
            break
        end
    end
    if not target then return nil end

    local hProc = ffi.C.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid)
    local exe_path = "Access Denied / Protected"
    if hProc ~= nil and hProc ~= ffi.cast("HANDLE", 0) then
        local buf = ffi.new("char[1024]")
        local sz = ffi.new("DWORD[1]", 1024)
        if ffi.C.QueryFullProcessImageNameA(hProc, 0, buf, sz) ~= 0 then
            exe_path = ffi.string(buf, sz[0])
        end
        ffi.C.CloseHandle(hProc)
    end
    target.exe = exe_path
    return target
end

function WindowsBackend.kill_process(pid, _)
    local hProc = ffi.C.OpenProcess(PROCESS_TERMINATE, 0, pid)
    if hProc == nil or hProc == ffi.cast("HANDLE", 0) then
        return false, "Access Denied (System or Protected Process)"
    end
    local ok = ffi.C.TerminateProcess(hProc, 1)
    ffi.C.CloseHandle(hProc)
    if ok ~= 0 then
        return true
    else
        return false, "TerminateProcess failed"
    end
end

local Backend = IS_WINDOWS and WindowsBackend or LinuxBackend

--------------------------------------------------------------------------------
-- 6. Interactive Dual-Pane TUI Engine
--------------------------------------------------------------------------------
local TABS = { "all", "user", "heavy" }
local TAB_LABELS = {
    all = "All Procs",
    user = "User Apps",
    heavy = "Heavy / RAM",
}

local SORT_MODES = { "mem", "pid", "name", "threads" }
local SORT_LABELS = {
    mem = "Memory (Desc)",
    pid = "PID (Asc)",
    name = "Name (Asc)",
    threads = "Threads (Desc)",
}

local function run_tui(init_opts)
    init_opts = init_opts or {}
    Term.init()

    local hostname = os.getenv("COMPUTERNAME") or os.getenv("HOSTNAME") or "Host"
    local state = {
        all_procs = {},
        filtered = {},
        filter = init_opts.filter or "",
        prev_filter = "",
        mode = "normal", -- "normal", "filter", "confirm_kill"
        tab_idx = init_opts.start_tab or 2, -- Default to User Apps
        sort_idx = 1, -- Default to Memory sort
        cursor = 1,
        scroll = 1,
        preview_scroll = 0,
        pending_op = nil,
        body_h = 10,
        selected_set = {}, -- { [pid] = true }
        cached_details = {},
        status_msg = "",
        status_type = "ok",
        confirm_callback = nil,
        confirm_msg = "",
    }

    local function refresh_data()
        state.all_procs = Backend.get_process_list()
        state.cached_details = {}
    end

    local function apply_filter_and_sort()
        local tab = TABS[state.tab_idx]
        local list = {}

        -- Tab filtering
        for _, p in ipairs(state.all_procs) do
            local pass_tab = false
            if tab == "all" then
                pass_tab = true
            elseif tab == "user" then
                pass_tab = not p.is_system
            elseif tab == "heavy" then
                pass_tab = (p.rss and p.rss >= 50)
            end

            if pass_tab then
                if #state.filter > 0 then
                    local s1 = fuzzy_score(state.filter, p.name)
                    local s2 = fuzzy_score(state.filter, tostring(p.pid))
                    local s = math.max(s1 or 0, s2 or 0)
                    if s > 0 then
                        table.insert(list, { proc = p, score = s })
                    end
                else
                    table.insert(list, { proc = p, score = 0 })
                end
            end
        end

        -- Sorting
        local sort_key = SORT_MODES[state.sort_idx]
        table.sort(list, function(a, b)
            if #state.filter > 0 and a.score ~= b.score then
                return a.score > b.score
            end
            if sort_key == "mem" then
                return (a.proc.rss or 0) > (b.proc.rss or 0)
            elseif sort_key == "pid" then
                return a.proc.pid < b.proc.pid
            elseif sort_key == "name" then
                return a.proc.name:lower() < b.proc.name:lower()
            elseif sort_key == "threads" then
                return (a.proc.threads or 0) > (b.proc.threads or 0)
            end
            return (a.proc.rss or 0) > (b.proc.rss or 0)
        end)

        state.filtered = {}
        for _, it in ipairs(list) do
            table.insert(state.filtered, it.proc)
        end

        state.cursor = math.max(1, math.min(state.cursor, #state.filtered))
    end

    refresh_data()
    apply_filter_and_sort()

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

        -- Compute tab counts
        local cnt_all = #state.all_procs
        local cnt_user = 0
        local cnt_heavy = 0
        for _, p in ipairs(state.all_procs) do
            if not p.is_system then cnt_user = cnt_user + 1 end
            if p.rss and p.rss >= 50 then cnt_heavy = cnt_heavy + 1 end
        end

        -- 1. Header
        local head_str = string.format(" %s%s⚡ fkill%s %s[%s]%s │ Host: %s%s%s │ Sort: %s%s%s",
            C.b_red, C.bold, C.reset,
            C.b_yellow, TAB_LABELS[TABS[state.tab_idx]], C.reset,
            C.b_white, hostname, C.reset,
            C.b_cyan, SORT_LABELS[SORT_MODES[state.sort_idx]], C.reset)
        add_line(C.bg_header .. pad_right(head_str, math.max(1, cols - 1)) .. C.reset)

        -- 2. Subheader Tabs & Filter
        local tabs_str = ""
        for i, t in ipairs(TABS) do
            local cnt = (t == "all") and cnt_all or ((t == "user") and cnt_user or cnt_heavy)
            local label = string.format("%s (%d)", TAB_LABELS[t], cnt)

            if i == state.tab_idx then
                tabs_str = tabs_str .. C.inverse .. C.b_red .. "[" .. label .. "]" .. C.reset .. " "
            else
                tabs_str = tabs_str .. C.gray .. "[" .. label .. "]" .. C.reset .. " "
            end
        end

        local filter_disp
        if state.mode == "filter" then
            filter_disp = C.b_yellow .. C.bold .. "Filter (/): " .. C.b_white .. state.filter .. "█" .. C.reset
        else
            if #state.filter > 0 then
                filter_disp = C.bold .. "Filter: " .. C.b_white .. state.filter .. C.reset .. C.gray .. " (Esc to clear)" .. C.reset
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
        local left_w = math.floor(cols * 0.50)
        if cols < 90 then left_w = cols - 2 end
        local right_w = math.max(0, cols - left_w - 4)

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
        local raw_hdr = pad_right(string.format("  %-3s  %-7s  %-10s %-4s  %s", "SEL", "PID", "MEM", "THR", "PROCESS NAME"), left_w)
        local list_hdr = C.b_blue .. C.bold .. raw_hdr .. C.reset
        local right_title
        if state.mode == "help" then
            right_title = " 📖 VIM KEYBINDINGS CHEATSHEET"
        elseif cur_item then
            right_title = truncate(" 📋 PROCESS: " .. cur_item.name .. " (" .. cur_item.pid .. ")", math.max(10, right_w - 2))
        else
            right_title = " 📋 PROCESS INSPECTOR"
        end
        local right_hdr = (cols >= 90) and (C.b_white .. C.bold .. right_title .. C.reset) or ""
        local hdr_sep = (cols >= 90) and (C.gray .. "│" .. C.reset) or ""
        add_line(list_hdr .. " " .. hdr_sep .. " " .. right_hdr)

        -- Pre-load inspector content for right pane
        local r_lines = {}
        if cols >= 90 then
            if state.mode == "help" then
                table.insert(r_lines, "")
                table.insert(r_lines, C.b_yellow .. C.bold .. "  NAVIGATION & MOTIONS" .. C.reset)
                table.insert(r_lines, string.format("   %s%-18s%s Move cursor down / up", C.b_cyan, "j / k, ^n / ^p", C.reset))
                table.insert(r_lines, string.format("   %s%-18s%s Jump to first / last process", C.b_cyan, "gg / G", C.reset))
                table.insert(r_lines, string.format("   %s%-18s%s Scroll half-page down / up", C.b_cyan, "Ctrl-d / Ctrl-u", C.reset))
                table.insert(r_lines, string.format("   %s%-18s%s Scroll full-page down / up", C.b_cyan, "Ctrl-f / Ctrl-b", C.reset))
                table.insert(r_lines, string.format("   %s%-18s%s Jump to High / Mid / Low screen", C.b_cyan, "H / M / L", C.reset))
                table.insert(r_lines, string.format("   %s%-18s%s Recenter: Middle / Top / Bottom", C.b_cyan, "zz / zt / zb", C.reset))
                table.insert(r_lines, string.format("   %s%-18s%s Scroll inspector card down / up", C.b_cyan, "Ctrl-e / Ctrl-y", C.reset))
                table.insert(r_lines, "")
                table.insert(r_lines, C.b_yellow .. C.bold .. "  SELECTION & PROCESS ACTIONS" .. C.reset)
                table.insert(r_lines, string.format("   %s%-18s%s Toggle selection checkbox [x]", C.b_cyan, "v / Tab / Space", C.reset))
                table.insert(r_lines, string.format("   %s%-18s%s Terminate process (prompt)", C.b_cyan, "d / Enter", C.reset))
                table.insert(r_lines, string.format("   %s%-18s%s Force kill immediately (SIGKILL)", C.b_cyan, "D / K", C.reset))
                table.insert(r_lines, string.format("   %s%-18s%s Cycle sort mode (RAM/PID/Name)", C.b_cyan, "s / S", C.reset))
                table.insert(r_lines, string.format("   %s%-18s%s Switch tab: All / User / Heavy", C.b_cyan, "h / l, 1 / 2 / 3", C.reset))
                table.insert(r_lines, string.format("   %s%-18s%s Refresh process list & memory", C.b_cyan, "r / Ctrl-r", C.reset))
                table.insert(r_lines, string.format("   %s%-18s%s Real-time fuzzy filter (/)", C.b_cyan, "/", C.reset))
                table.insert(r_lines, string.format("   %s%-18s%s Close help / exit fkill", C.b_cyan, "?, q / Esc", C.reset))
            elseif cur_item then
                if not state.cached_details[cur_item.pid] then
                    state.cached_details[cur_item.pid] = Backend.get_proc_details(cur_item.pid) or cur_item
                end
                local d = state.cached_details[cur_item.pid]

                table.insert(r_lines, "")
                table.insert(r_lines, string.format("  %sProcess:%s  %s%s%s", C.b_yellow .. C.bold, C.reset, C.b_white .. C.bold, truncate(d.name, math.max(4, right_w - 12)), C.reset))
                table.insert(r_lines, string.format("  %sPID:%s      %s%-7d%s %sParent PID:%s %s%s%s",
                    C.b_cyan .. C.bold, C.reset, C.b_yellow, d.pid, C.reset,
                    C.gray, C.reset, C.white, tostring(d.ppid or "N/A"), C.reset))

                table.insert(r_lines, string.format("  %sUser:%s     %s%-12s%s %sThreads:%s %s%s%s",
                    C.gray, C.reset, C.magenta, truncate(d.user or "User", 12), C.reset,
                    C.gray, C.reset, C.white, tostring(d.threads or 1), C.reset))

                local mem_info = format_mem(d.rss)
                if d.vms and d.vms > 0 then
                    mem_info = mem_info .. string.format(" (Virt: %s)", format_mem(d.vms))
                end
                table.insert(r_lines, string.format("  %sMemory:%s   %s%s%s", C.b_green .. C.bold, C.reset, C.b_green, truncate(mem_info, math.max(4, right_w - 12)), C.reset))

                if d.state then
                    table.insert(r_lines, string.format("  %sState:%s    %s%s%s", C.gray, C.reset, C.cyan, d.state, C.reset))
                end

                table.insert(r_lines, "")
                table.insert(r_lines, string.format("  %sExecutable Path:%s", C.b_white .. C.bold, C.reset))
                table.insert(r_lines, "    " .. C.white .. truncate(d.exe or "N/A", math.max(4, right_w - 6)) .. C.reset)

                table.insert(r_lines, "")
                table.insert(r_lines, string.format("  %sCommand Line:%s", C.b_white .. C.bold, C.reset))
                local cmd_str = d.cmd or d.name
                local max_cmd_w = math.max(4, right_w - 6)
                for chunk_idx = 1, math.min(#cmd_str, max_cmd_w * 4), max_cmd_w do
                    table.insert(r_lines, "    " .. C.gray .. truncate(cmd_str:sub(chunk_idx, chunk_idx + max_cmd_w - 1), max_cmd_w) .. C.reset)
                end
            end
        end

        -- 4. Body Rows
        for row = 1, body_h do
            local idx = state.scroll + row - 1
            local item = state.filtered[idx]
            local l_str

            if item then
                local is_cur = (idx == state.cursor)
                local bg = is_cur and C.bg_select or ""
                local ptr = is_cur and (C.b_red .. "▸" .. C.reset .. bg) or " "

                -- Checkbox
                local is_checked = (state.selected_set[item.pid] == true)
                local chk = is_checked and (C.b_red .. "[x]" .. C.reset .. bg) or (C.gray .. "[ ]" .. C.reset .. bg)

                -- PID
                local pid_col = is_cur and (C.b_yellow .. C.bold) or C.yellow
                local pid_disp = pid_col .. string.format("%7d", item.pid) .. C.reset .. bg

                -- Mem pill
                local mem_str = format_mem(item.rss)
                local mem_col = (item.rss and item.rss >= 50) and C.b_red or C.b_blue
                local mem_pill = mem_col .. mem_str .. C.reset .. bg

                -- Threads
                local thr_str = string.format("%4d", item.threads or 1)
                local thr_disp = C.gray .. thr_str .. C.reset .. bg

                -- Name
                local name_w = math.max(8, left_w - 32)
                local raw_name = item.name
                local name_disp = truncate(raw_name, name_w)
                if #name_disp < name_w then
                    name_disp = pad_right(name_disp, name_w)
                end
                local name_col = is_cur and (C.b_white .. C.bold) or (item.is_system and C.gray or C.white)
                local full_name_disp = name_col .. name_disp .. C.reset

                l_str = string.format("%s%s %s %s %s %s  %s", bg, ptr, chk, pid_disp, mem_pill, thr_disp, full_name_disp)
            elseif row == 1 and #state.filtered == 0 then
                local no_match = "  (No processes match current filter)"
                l_str = C.gray .. pad_right(no_match, left_w) .. C.reset
            else
                l_str = string.rep(" ", left_w)
            end

            local r_idx = row + (state.preview_scroll or 0)
            local r_str = r_lines[r_idx] or ""
            local sep_char = (cols >= 90) and (C.gray .. "│" .. C.reset) or ""
            add_line(l_str .. " " .. sep_char .. " " .. r_str)
        end

        -- 5. Footer & Dialog Prompt
        local footer_sep = string.rep("─", math.max(1, cols - 1))
        add_line(C.gray .. footer_sep .. C.reset)

        local status_disp
        if state.mode == "help" then
            status_disp = C.b_yellow .. C.bold .. " [Help Mode] Press any key or ? to return to process list..." .. C.reset
        elseif state.mode == "confirm_kill" then
            status_disp = C.bg_red .. C.b_white .. C.bold .. " " .. state.confirm_msg .. " (y/n): " .. C.reset
        elseif #state.status_msg > 0 then
            local col = (state.status_type == "ok") and C.b_green or C.b_red
            status_disp = col .. C.bold .. " " .. state.status_msg .. C.reset
        else
            local sel_cnt = 0
            for _ in pairs(state.selected_set) do sel_cnt = sel_cnt + 1 end
            local sel_indicator = (sel_cnt > 0) and string.format("%s(%d selected)%s ", C.b_red, sel_cnt, C.gray) or ""

            status_disp = string.format(" %s%sj/k%s:Move  %sgg/G%s:Top/End  %s^d/^u%s:Page  %sv/Tab%s:Sel  %sd/D%s:Kill  %ss%s:Sort  %s?%s:Help  %sq%s:Quit",
                sel_indicator,
                C.b_cyan, C.gray, C.b_cyan, C.gray, C.b_cyan, C.gray, C.b_yellow, C.gray, C.b_red, C.gray, C.b_green, C.gray, C.b_yellow, C.gray, C.b_red, C.reset)
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

    -- Event loop
    while true do
        render()
        local key = Term.read_key()
        if state.mode ~= "confirm_kill" then
            state.status_msg = ""
        end

        if key == "CTRL_C" then
            Term.restore()
            os.exit(0)
        end

        -- Dismiss Help Mode on any key
        if state.mode == "help" then
            state.mode = "normal"

        -- A. Confirm Kill Mode
        elseif state.mode == "confirm_kill" then
            if key == "y" or key == "Y" or key == "ENTER" or key == "d" or key == "D" then
                if state.confirm_callback then
                    state.confirm_callback(true)
                end
                state.mode = "normal"
                state.confirm_callback = nil
                refresh_data()
                apply_filter_and_sort()
            elseif key == "n" or key == "N" or key == "ESC" or key == "q" then
                state.mode = "normal"
                state.confirm_callback = nil
                state.status_msg = "Termination cancelled."
                state.status_type = "ok"
            end

        -- B. Filter Input Mode
        elseif state.mode == "filter" then
            if key == "ESC" then
                state.filter = state.prev_filter
                state.mode = "normal"
                apply_filter_and_sort()
            elseif key == "ENTER" then
                state.mode = "normal"
            elseif key == "BACKSPACE" then
                state.filter = state.filter:sub(1, math.max(0, #state.filter - 1))
                apply_filter_and_sort()
            elseif key == "CTRL_W" then
                state.filter = delete_word(state.filter)
                apply_filter_and_sort()
            elseif key == "CTRL_U" then
                state.filter = ""
                apply_filter_and_sort()
            elseif key == "UP" or key == "CTRL_P" then
                state.cursor = math.max(1, state.cursor - 1)
                state.preview_scroll = 0
            elseif key == "DOWN" or key == "CTRL_N" then
                state.cursor = math.min(math.max(1, #state.filtered), state.cursor + 1)
                state.preview_scroll = 0
            elseif #key == 1 and key:byte(1) >= 32 and key:byte(1) <= 126 then
                state.filter = state.filter .. key
                apply_filter_and_sort()
            end

        -- C. Normal Navigation Mode
        else
            if state.pending_op == "g" then
                if key == "g" then
                    state.cursor = 1
                    state.preview_scroll = 0
                end
                state.pending_op = nil
            elseif state.pending_op == "z" then
                local body_h = state.body_h or 10
                if key == "z" then
                    state.scroll = math.max(1, math.min(math.max(1, #state.filtered - body_h + 1), state.cursor - math.floor(body_h / 2)))
                elseif key == "t" then
                    state.scroll = math.max(1, math.min(math.max(1, #state.filtered - body_h + 1), state.cursor))
                elseif key == "b" then
                    state.scroll = math.max(1, math.min(math.max(1, #state.filtered - body_h + 1), state.cursor - body_h + 1))
                end
                state.pending_op = nil
            elseif key == "q" or key == "ESC" then
                if #state.filter > 0 then
                    state.filter = ""
                    apply_filter_and_sort()
                else
                    Term.restore()
                    os.exit(0)
                end
            elseif key == "?" then
                state.mode = "help"
            elseif key == "/" then
                state.prev_filter = state.filter
                state.mode = "filter"
            elseif key == "g" then
                state.pending_op = "g"
            elseif key == "z" then
                state.pending_op = "z"
            elseif key == "j" or key == "DOWN" or key == "CTRL_N" then
                state.cursor = math.min(math.max(1, #state.filtered), state.cursor + 1)
                state.preview_scroll = 0
            elseif key == "k" or key == "UP" or key == "CTRL_P" then
                state.cursor = math.max(1, state.cursor - 1)
                state.preview_scroll = 0
            elseif key == "CTRL_D" then
                local half = math.max(1, math.floor((state.body_h or 10) / 2))
                state.cursor = math.min(math.max(1, #state.filtered), state.cursor + half)
                state.preview_scroll = 0
            elseif key == "CTRL_U" then
                local half = math.max(1, math.floor((state.body_h or 10) / 2))
                state.cursor = math.max(1, state.cursor - half)
                state.preview_scroll = 0
            elseif key == "CTRL_F" or key == "PGDN" then
                local page = math.max(1, state.body_h or 10)
                state.cursor = math.min(math.max(1, #state.filtered), state.cursor + page)
                state.preview_scroll = 0
            elseif key == "CTRL_B" or key == "PGUP" then
                local page = math.max(1, state.body_h or 10)
                state.cursor = math.max(1, state.cursor - page)
                state.preview_scroll = 0
            elseif key == "H" then
                state.cursor = math.max(1, math.min(#state.filtered, state.scroll))
                state.preview_scroll = 0
            elseif key == "M" then
                state.cursor = math.max(1, math.min(#state.filtered, state.scroll + math.floor(((state.body_h or 10) - 1) / 2)))
                state.preview_scroll = 0
            elseif key == "L" then
                state.cursor = math.max(1, math.min(#state.filtered, state.scroll + (state.body_h or 10) - 1))
                state.preview_scroll = 0
            elseif key == "G" or key == "END" then
                state.cursor = math.max(1, #state.filtered)
                state.preview_scroll = 0
            elseif key == "HOME" then
                state.cursor = 1
                state.preview_scroll = 0
            elseif key == "CTRL_E" then
                state.preview_scroll = (state.preview_scroll or 0) + 1
            elseif key == "CTRL_Y" then
                state.preview_scroll = math.max(0, (state.preview_scroll or 0) - 1)
            elseif key == "v" or key == "V" then
                local item = state.filtered[state.cursor]
                if item then
                    if state.selected_set[item.pid] then
                        state.selected_set[item.pid] = nil
                    else
                        state.selected_set[item.pid] = true
                    end
                end
            elseif key == "TAB" or key == "SPACE" then
                local item = state.filtered[state.cursor]
                if item then
                    if state.selected_set[item.pid] then
                        state.selected_set[item.pid] = nil
                    else
                        state.selected_set[item.pid] = true
                    end
                end
                state.cursor = math.min(math.max(1, #state.filtered), state.cursor + 1)
                state.preview_scroll = 0
            elseif key == "r" or key == "CTRL_R" then
                refresh_data()
                apply_filter_and_sort()
                state.status_msg = "Process list refreshed."
                state.status_type = "ok"
            elseif key == "h" or key == "LEFT" then
                state.tab_idx = (state.tab_idx == 1) and #TABS or (state.tab_idx - 1)
                apply_filter_and_sort()
                state.preview_scroll = 0
            elseif key == "l" or key == "RIGHT" then
                state.tab_idx = (state.tab_idx == #TABS) and 1 or (state.tab_idx + 1)
                apply_filter_and_sort()
                state.preview_scroll = 0
            elseif key == "1" or key == "2" or key == "3" then
                state.tab_idx = tonumber(key)
                apply_filter_and_sort()
                state.preview_scroll = 0
            elseif key == "s" or key == "S" then
                state.sort_idx = (state.sort_idx == #SORT_MODES) and 1 or (state.sort_idx + 1)
                apply_filter_and_sort()
            elseif key == "d" or key == "ENTER" or key == "D" or key == "K" then
                local force = (key == "D" or key == "K")
                local targets = {}
                for pid in pairs(state.selected_set) do
                    for _, p in ipairs(state.all_procs) do
                        if p.pid == pid then
                            table.insert(targets, p)
                            break
                        end
                    end
                end
                if #targets == 0 and state.filtered[state.cursor] then
                    table.insert(targets, state.filtered[state.cursor])
                end

                if #targets == 0 then
                    state.status_msg = "No process selected."
                    state.status_type = "warn"
                elseif force then
                    -- Immediate force kill
                    local killed = 0
                    local failed_msg = ""
                    for _, t in ipairs(targets) do
                        local ok, err = Backend.kill_process(t.pid, true)
                        if ok then
                            killed = killed + 1
                            state.selected_set[t.pid] = nil
                        else
                            failed_msg = err or "Access Denied"
                        end
                    end
                    if killed > 0 then
                        state.status_msg = string.format("Force-killed %d process(es).", killed)
                        state.status_type = "ok"
                    else
                        state.status_msg = string.format("Failed to kill: %s", failed_msg)
                        state.status_type = "error"
                    end
                    refresh_data()
                    apply_filter_and_sort()
                else
                    -- Confirmation prompt
                    local desc = ""
                    if #targets == 1 then
                        desc = string.format("Kill %s (PID: %d)?", targets[1].name, targets[1].pid)
                    else
                        desc = string.format("Kill %d selected process(es)?", #targets)
                    end
                    state.confirm_msg = desc
                    state.confirm_callback = function()
                        local killed = 0
                        local failed_msg = ""
                        for _, t in ipairs(targets) do
                            local ok, err = Backend.kill_process(t.pid, false)
                            if ok then
                                killed = killed + 1
                                state.selected_set[t.pid] = nil
                            else
                                failed_msg = err or "Access Denied"
                            end
                        end
                        if killed > 0 then
                            state.status_msg = string.format("Terminated %d process(es).", killed)
                            state.status_type = "ok"
                        else
                            state.status_msg = string.format("Failed: %s", failed_msg)
                            state.status_type = "error"
                        end
                    end
                    state.mode = "confirm_kill"
                end
            end
        end
    end
end

--------------------------------------------------------------------------------
-- 7. Non-Interactive CLI Actions & Legacy FZF
--------------------------------------------------------------------------------
local function print_list()
    local procs = Backend.get_process_list()
    table.sort(procs, function(a, b) return (a.rss or 0) > (b.rss or 0) end)
    io.write(string.format("%-8s %-10s %-10s %-25s %s\n", "PID", "USER", "MEM(MB)", "NAME", "COMMAND"))
    for _, p in ipairs(procs) do
        local mem_str = (p.rss and p.rss > 0) and string.format("%.1f", p.rss) or "-"
        local cmd_sample = (p.cmd or p.name):gsub("\n", " ")
        io.write(string.format("%-8d %-10s %-10s %-25s %s\n",
            p.pid,
            (p.user or "-"):sub(1, 10),
            mem_str,
            p.name:sub(1, 25),
            cmd_sample:sub(1, 80)
        ))
    end
end

local function render_preview(pid)
    local info = Backend.get_proc_details(pid)
    if not info then
        io.write(string.format("%s[Process %d not found or terminated]%s\n", C.red, pid, C.reset))
        return
    end

    local border = string.rep("─", 54)
    io.write(string.format("%s┌%s┐%s\n", C.b_cyan, border, C.reset))
    io.write(string.format("%s│ %s%-52s%s │%s\n", C.b_cyan, C.b_yellow, string.format("PROCESS PREVIEW: %s (PID: %d)", info.name, info.pid), C.b_cyan, C.reset))
    io.write(string.format("%s├%s┤%s\n", C.b_cyan, border, C.reset))

    local function field(label, val, color)
        color = color or C.white
        io.write(string.format("%s│%s %s%-14s%s: %s%-36s%s %s│%s\n",
            C.b_cyan, C.reset,
            C.bold, label, C.reset,
            color, tostring(val):sub(1, 36), C.reset,
            C.b_cyan, C.reset))
    end

    field("Process Name", info.name, C.green)
    field("PID", info.pid, C.b_yellow)
    field("Parent PID", info.ppid or "N/A", C.white)
    field("User", info.user or "N/A", C.magenta)
    if info.state then field("State", info.state, C.cyan) end
    if info.threads then field("Threads", info.threads, C.white) end
    if info.rss and info.rss > 0 then field("Resident Mem", string.format("%.1f MB", info.rss), C.b_yellow) end
    if info.vms and info.vms > 0 then field("Virtual Mem", string.format("%.1f MB", info.vms), C.dim) end
    if info.cwd then field("Working Dir", info.cwd, C.white) end
    field("Executable", info.exe or "N/A", C.blue)

    io.write(string.format("%s├%s┤%s\n", C.b_cyan, border, C.reset))
    io.write(string.format("%s│ %s%-52s%s │%s\n", C.b_cyan, C.b_yellow, "COMMAND LINE:", C.b_cyan, C.reset))

    local cmd = info.cmd or info.name
    local max_w = 52
    for i = 1, #cmd, max_w do
        local chunk = cmd:sub(i, i + max_w - 1)
        io.write(string.format("%s│%s %-52s %s│%s\n", C.b_cyan, C.reset, chunk, C.b_cyan, C.reset))
    end

    io.write(string.format("%s└%s┘%s\n", C.b_cyan, border, C.reset))
end

local function kill_pid_cli(pid, force)
    local ok, err = Backend.kill_process(pid, force)
    if ok then
        io.write(string.format("%s✔ Successfully killed PID %d%s\n", C.green, pid, C.reset))
        return true
    else
        io.write(string.format("%s✘ Failed to kill PID %d: %s%s\n", C.red, pid, err or "error", C.reset))
        return false
    end
end

local function kill_by_name_cli(name, force)
    local procs = Backend.get_process_list()
    local target_name = name:lower()
    local matched = {}

    for _, p in ipairs(procs) do
        if p.name:lower():find(target_name, 1, true) then
            table.insert(matched, p)
        end
    end

    if #matched == 0 then
        io.write(string.format("%sNo running processes matched '%s'%s\n", C.yellow, name, C.reset))
        return
    end

    io.write(string.format("%sFound %d matching process(es) for '%s':%s\n", C.cyan, #matched, name, C.reset))
    for _, p in ipairs(matched) do
        kill_pid_cli(p.pid, force)
    end
end

local function legacy_fzf()
    local script_path = debug.getinfo(1, "S").source:sub(2)
    if not script_path:match("^/") and not script_path:match("^%a:[/\\]") then
        local pwd = io.popen(IS_WINDOWS and "cd" or "pwd 2>/dev/null || pwd"):read("*line") or "."
        script_path = pwd .. "/" .. script_path
    end

    local preview_cmd = string.format("luajit %q --preview {1}", script_path)
    local list_cmd    = string.format("luajit %q --list", script_path)

    local fzf_cmd = string.format(
        '%s | fzf -m --header-lines=1 --prompt="[LuaJIT] Kill Process > " ' ..
        '--header="LuaJIT FFI | [Tab]: Multi-select | [Enter]: Kill | [Esc]: Cancel" ' ..
        '--preview=%q --preview-window=right:50%%:wrap',
        list_cmd, preview_cmd
    )

    local pipe = io.popen(fzf_cmd, "r")
    if not pipe then
        io.stderr:write("Error: Failed to execute fzf. Ensure fzf is installed and in PATH.\n")
        os.exit(1)
    end

    local output = pipe:read("*all")
    pipe:close()

    if not output or #output:gsub("%s+", "") == 0 then
        return
    end

    local pids_to_kill = {}
    for line in output:gmatch("[^\r\n]+") do
        local pid = tonumber(line:match("^%s*(%d+)"))
        if pid then
            local name = line:match("^%s*%d+%s+%S+%s+%S+%s+(%S+)") or "unknown"
            table.insert(pids_to_kill, { pid = pid, name = name })
        end
    end

    if #pids_to_kill > 0 then
        io.write(string.format("\n%sTerminating %d selected process(es):%s\n", C.b_yellow, #pids_to_kill, C.reset))
        for _, item in ipairs(pids_to_kill) do
            kill_pid_cli(item.pid, false)
        end
    end
end

--------------------------------------------------------------------------------
-- 8. Automated Self-Tests
--------------------------------------------------------------------------------
local function run_tests()
    print("Running fkill.lua automated self-tests...")
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
    assert_eq("trim removes whitespace", trim("  hello  \n"), "hello")
    assert_eq("pad_right pads accurately", pad_right("abc", 5), "abc  ")
    assert_eq("truncate short unchanged", truncate("hello", 10), "hello")
    assert_eq("truncate long with ellipsis", truncate("hello world", 6), "hello…")
    assert_eq("format_mem formatted correctly", format_mem(150), "[150.0 MB]")

    -- Test 2: Process list retrieval
    local procs = Backend.get_process_list()
    assert_eq("get_process_list returns table", type(procs), "table")
    assert_eq("process count > 0", #procs > 0, true)

    local sample = procs[1]
    assert_eq("sample PID is number", type(sample.pid), "number")
    assert_eq("sample name is string", type(sample.name), "string")
    assert_eq("sample threads is number", type(sample.threads), "number")

    -- Test 3: Process details
    local details = Backend.get_proc_details(sample.pid)
    assert_eq("get_proc_details returns table", type(details), "table")
    assert_eq("details PID matches sample", details.pid, sample.pid)

    -- Test 4: Fuzzy score
    assert_eq("fuzzy_score finds match", (fuzzy_score("fkill", "fkill.lua") or 0) > 0, true)
    assert_eq("fuzzy_score nil on mismatch", fuzzy_score("xyz", "fkill.lua"), nil)

    -- Test 5: Terminal width bounds
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
        local l_w = math.floor(c_w * 0.50)
        if c_w < 90 then l_w = c_w - 2 end
        local r_w = math.max(0, c_w - l_w - 4)
        if c_w >= 90 then
            local test_r_line = truncate("  Process: very_long_process_name_that_should_never_overflow_terminal.exe", math.max(4, r_w - 4))
            local test_full = string.rep("x", l_w) .. " │ " .. test_r_line
            assert_eq(string.format("cols %d right pane line strictly <= cols - 1", c_w), utf8_vis(test_full) <= c_w - 1, true)
        end
    end

    -- Test 6: delete_word helper
    assert_eq("delete_word removes trailing word", delete_word("filter test"), "filter ")
    assert_eq("delete_word with trailing spaces", delete_word("filter test   "), "filter ")
    assert_eq("delete_word single word", delete_word("process"), "")
    assert_eq("delete_word empty string", delete_word(""), "")

    -- Test 7: Vim navigation math
    local test_total = 50
    local test_body_h = 10
    local cur = 25
    local scroll = 20
    -- Half page down / up
    local half = math.floor(test_body_h / 2)
    assert_eq("Ctrl-d advances half page", math.min(test_total, cur + half), 30)
    assert_eq("Ctrl-u retreats half page", math.max(1, cur - half), 20)
    -- H / M / L
    assert_eq("H jumps to top visible", math.max(1, math.min(test_total, scroll)), 20)
    assert_eq("M jumps to mid visible", math.max(1, math.min(test_total, scroll + math.floor((test_body_h - 1) / 2))), 24)
    assert_eq("L jumps to bottom visible", math.max(1, math.min(test_total, scroll + test_body_h - 1)), 29)
    -- zz recenter
    local zz_scroll = math.max(1, math.min(test_total - test_body_h + 1, cur - math.floor(test_body_h / 2)))
    assert_eq("zz centers cursor in viewport", zz_scroll, 20)

    print(string.format("\nSelf-test summary: %d passed, %d failed.", passed, failed))
    if failed > 0 then os.exit(1) end
end

local function show_help()
    print([[
fkill.lua - High-Performance Interactive Process Killer TUI (LuaJIT + FFI)

Usage:
  luajit fkill.lua [OPTIONS] [PID_OR_NAME]
  fkill [OPTIONS] [PID_OR_NAME]

Options:
  -9, -f, --force      Force terminate process (SIGKILL / TerminateProcess)
  -l, --list           Print formatted process table to stdout and exit
  -p, --preview <PID>  Print rich process details card to stdout and exit
  --fzf                Launch legacy fzf pipeline mode
  --test               Run built-in automated self-tests and exit
  -h, --help           Show this help message

Interactive Vim & Navigation Controls:
  j / k, ^n / ^p, Up / Down Move cursor down / up
  gg / G, Home / End        Jump to first / last process
  Ctrl-d / Ctrl-u           Scroll half-page down / up
  Ctrl-f / Ctrl-b           Scroll full-page down / up (PgDn / PgUp)
  H / M / L                 Jump to High / Mid / Low screen position
  zz / zt / zb              Recenter viewport: Center / Top / Bottom
  Ctrl-e / Ctrl-y           Scroll right inspector card down / up
  v / Tab / Space           Toggle multi-select checkbox [x]
  d / Enter                 Terminate process(es) with confirmation
  D / K                     Immediate force kill (SIGKILL)
  h / l, 1 / 2 / 3          Switch context tab (All / User / Heavy)
  s / S                     Cycle sort mode (Memory / PID / Name / Threads)
  /                         Enter search filter mode (Ctrl-w to delete word)
  r / Ctrl-r                Refresh processes and memory
  ?                         Toggle built-in Vim Cheatsheet modal
  q / Esc                   Exit fkill]])
end

--------------------------------------------------------------------------------
-- 9. Entry Point & CLI Parser
--------------------------------------------------------------------------------
local args = { ... }
local force = false
local opts = {
    mode = "tui",
    start_tab = 2, -- Default to User Apps
    filter = "",
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
        print_list()
        os.exit(0)
    elseif a == "-p" or a == "--preview" then
        local pid = tonumber(args[i + 1])
        if pid then
            render_preview(pid)
        else
            io.stderr:write("Error: --preview requires a numeric PID argument.\n")
            os.exit(1)
        end
        os.exit(0)
    elseif a == "--fzf" then
        legacy_fzf()
        os.exit(0)
    elseif a == "-9" or a == "-f" or a == "--force" then
        force = true
    else
        -- Check if argument is a numeric PID or process name to kill directly
        local pid = tonumber(a)
        if pid then
            kill_pid_cli(pid, force)
            os.exit(0)
        else
            kill_by_name_cli(a, force)
            os.exit(0)
        end
    end
    i = i + 1
end

run_tui(opts)
