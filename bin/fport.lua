#!/usr/bin/env luajit
--[[
  fport.lua - High-Performance Interactive Port & Socket Inspector / Killer TUI
  Powered by LuaJIT & FFI. Single-file, zero external Lua dependencies.
  Runs natively on Windows (iphlpapi.dll + kernel32.dll FFI) and Linux (/proc/net + libc FFI).

  Features:
    - Sub-Millisecond Socket Enumeration: Direct Win32 GetExtendedTcpTable / GetExtendedUdpTable
      FFI on Windows and /proc/net/{tcp,tcp6,udp,udp6} + /proc/<pid>/fd inode mapping on Linux.
    - Dual-Pane Interactive TUI: Live port table on the left; Socket & Process Inspector on the right.
    - Category Tabs: Switch between [1:Listen], [2:All], [3:Estab], and [4:UDP] with Tab / h / l / 1-4.
    - Live Fuzzy & Substring Filtering (/): Filter by port, process name, PID, state, or IP address.
    - Multi-Column Sorting (s): Cycle sort order between Port, PID, Process Name, and Protocol.
    - Process Termination: Press Enter / x (with [y/N] confirmation) or K (immediate) to kill owning PID.
    - CLI Modes: Non-interactive table (--list), rich preview card (--preview), direct kill (-k <port>),
      and automated self-test suite (--test).

  Usage:
    luajit bin/fport.lua [OPTIONS] [PORT_OR_QUERY]
    fport [OPTIONS] [PORT_OR_QUERY]

  Options:
    -l, --list           Print formatted socket table to stdout and exit
    -a, --all            Show all socket states (including ESTABLISHED, TIME_WAIT)
    -k, --kill <PORT>    Terminate process(es) bound to <PORT> and exit
    --preview <PORT|PID> Print rich ANSI details card for a port or PID and exit
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
-- FFI Declarations
--------------------------------------------------------------------------------
if IS_WINDOWS then
    ffi.cdef[[
        typedef void* HANDLE;
        typedef unsigned long DWORD;
        typedef int BOOL;
        typedef unsigned short WORD;
        typedef unsigned char BYTE;
        typedef uintptr_t SIZE_T;
        typedef uintptr_t ULONG_PTR;

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
        unsigned long long GetTickCount64(void);

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
        DWORD QueryFullProcessImageNameA(HANDLE hProcess, DWORD dwFlags, char* lpExeName, DWORD* lpdwSize);
        BOOL K32GetProcessMemoryInfo(HANDLE Process, PROCESS_MEMORY_COUNTERS* ppsmemCounters, DWORD cb);
        DWORD GetLastError(void);

        typedef struct {
            DWORD dwState;
            DWORD dwLocalAddr;
            DWORD dwLocalPort;
            DWORD dwRemoteAddr;
            DWORD dwRemotePort;
            DWORD dwOwningPid;
        } MIB_TCPROW_OWNER_PID;

        typedef struct {
            BYTE ucLocalAddr[16];
            DWORD dwLocalScopeId;
            DWORD dwLocalPort;
            BYTE ucRemoteAddr[16];
            DWORD dwRemoteScopeId;
            DWORD dwRemotePort;
            DWORD dwState;
            DWORD dwOwningPid;
        } MIB_TCP6ROW_OWNER_PID;

        typedef struct {
            DWORD dwLocalAddr;
            DWORD dwLocalPort;
            DWORD dwOwningPid;
        } MIB_UDPROW_OWNER_PID;

        typedef struct {
            BYTE ucLocalAddr[16];
            DWORD dwLocalScopeId;
            DWORD dwLocalPort;
            DWORD dwOwningPid;
        } MIB_UDP6ROW_OWNER_PID;

        DWORD GetExtendedTcpTable(void* pTcpTable, DWORD* pdwSize, BOOL bOrder,
                                  DWORD ulAf, int TableClass, DWORD Reserved);
        DWORD GetExtendedUdpTable(void* pUdpTable, DWORD* pdwSize, BOOL bOrder,
                                  DWORD ulAf, int TableClass, DWORD Reserved);
    ]]
    local msvcrt = ffi.load("msvcrt")
    ffi.cdef[[
        int _kbhit(void);
        int _getch(void);
    ]]
    _G.msvcrt = msvcrt
    _G.iphlpapi = ffi.load("iphlpapi")
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
    ]]
end

--------------------------------------------------------------------------------
-- Styling & Box Drawing
--------------------------------------------------------------------------------
local C = {
    reset       = "\27[0m",
    bold        = "\27[1m",
    dim         = "\27[2m",
    reverse     = "\27[7m",

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

    bg_darkblue = "\27[48;5;24m",
    bg_sel      = "\27[48;5;238m",
    bg_red      = "\27[41m",
}

local BOX = {
    tl = "┌", tr = "┐", bl = "└", br = "┘",
    h = "─", v = "│", vl = "├", vr = "┤",
    tt = "┬", tb = "┴", x = "┼"
}

local WELL_KNOWN_PORTS = {
    [20] = "FTP-Data", [21] = "FTP", [22] = "SSH", [23] = "Telnet",
    [25] = "SMTP", [53] = "DNS", [67] = "DHCP", [68] = "DHCP",
    [80] = "HTTP", [110] = "POP3", [123] = "NTP", [135] = "RPC",
    [137] = "NetBIOS-NS", [138] = "NetBIOS-DGM", [139] = "NetBIOS-SSN",
    [143] = "IMAP", [443] = "HTTPS", [445] = "SMB", [514] = "Syslog",
    [631] = "IPP/CUPS", [993] = "IMAPS", [995] = "POP3S",
    [1433] = "MSSQL", [1521] = "Oracle", [2049] = "NFS",
    [2375] = "Docker", [3000] = "Dev-HTTP", [3306] = "MySQL",
    [3389] = "RDP", [4000] = "Dev-Server", [5000] = "Flask/UPnP",
    [5432] = "PostgreSQL", [5672] = "AMQP", [5900] = "VNC",
    [6006] = "TensorBoard", [6379] = "Redis", [6443] = "K8s-API",
    [7681] = "ttyd", [8000] = "HTTP-Alt", [8080] = "HTTP-Proxy",
    [8443] = "HTTPS-Alt", [8888] = "Jupyter", [9000] = "ttyd/Service",
    [9090] = "Prometheus", [9200] = "Elasticsearch", [27017] = "MongoDB",
}

--------------------------------------------------------------------------------
-- String & Byte Order Helpers
--------------------------------------------------------------------------------
local function ntohs(netshort)
    local low = bit.band(netshort, 0xFF)
    local high = bit.band(bit.rshift(netshort, 8), 0xFF)
    return bit.bor(bit.lshift(low, 8), high)
end

local function format_ipv4(dword_addr)
    local a = bit.band(dword_addr, 0xFF)
    local b = bit.band(bit.rshift(dword_addr, 8), 0xFF)
    local c = bit.band(bit.rshift(dword_addr, 16), 0xFF)
    local d = bit.band(bit.rshift(dword_addr, 24), 0xFF)
    return string.format("%d.%d.%d.%d", a, b, c, d)
end

local function format_ipv6(bytes16)
    -- Check all-zeros (::) and loopback (::1)
    local all_zero = true
    local is_loopback = true
    for i = 0, 15 do
        local b = bytes16[i]
        if b ~= 0 then all_zero = false end
        if i < 15 and b ~= 0 then is_loopback = false end
        if i == 15 and b ~= 1 then is_loopback = false end
    end
    if all_zero then return "[::]" end
    if is_loopback then return "[::1]" end

    -- Check IPv4-mapped IPv6 (::ffff:a.b.c.d)
    local v4_mapped = true
    for i = 0, 9 do
        if bytes16[i] ~= 0 then v4_mapped = false; break end
    end
    if v4_mapped and bytes16[10] == 0xFF and bytes16[11] == 0xFF then
        return string.format("[::ffff:%d.%d.%d.%d]", bytes16[12], bytes16[13], bytes16[14], bytes16[15])
    end

    local parts = {}
    for i = 0, 14, 2 do
        local word = bit.bor(bit.lshift(bytes16[i], 8), bytes16[i + 1])
        table.insert(parts, string.format("%x", word))
    end
    return "[" .. table.concat(parts, ":") .. "]"
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
    return clean:sub(1, max_width - 1) .. "…"
end

local function fuzzy_score(pattern, str)
    if not pattern or #pattern == 0 then return 1 end
    if not str or #str == 0 then return nil end
    pattern = pattern:lower()
    str = str:lower()
    -- Exact substring bonus
    local sub_start = str:find(pattern, 1, true)
    if sub_start then
        return 100 - sub_start
    end
    local p_idx = 1
    local p_len = #pattern
    local s_len = #str
    local score = 0
    local last_match = -1
    for s_idx = 1, s_len do
        if p_idx <= p_len and str:byte(s_idx) == pattern:byte(p_idx) then
            if last_match == s_idx - 1 then
                score = score + 10
            else
                score = score + 2
            end
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
    if cols < 70 then cols = 70 end
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
-- Socket & Process Discovery Backend
--------------------------------------------------------------------------------
local TCP_STATES_WIN = {
    [1]  = "CLOSED",
    [2]  = "LISTEN",
    [3]  = "SYN_SENT",
    [4]  = "SYN_RCVD",
    [5]  = "ESTABLISHED",
    [6]  = "FIN_WAIT1",
    [7]  = "FIN_WAIT2",
    [8]  = "CLOSE_WAIT",
    [9]  = "CLOSING",
    [10] = "LAST_ACK",
    [11] = "TIME_WAIT",
    [12] = "DELETE_TCB",
}

local TCP_STATES_LINUX = {
    ["01"] = "ESTABLISHED",
    ["02"] = "SYN_SENT",
    ["03"] = "SYN_RCVD",
    ["04"] = "FIN_WAIT1",
    ["05"] = "FIN_WAIT2",
    ["06"] = "TIME_WAIT",
    ["07"] = "CLOSE",
    ["08"] = "CLOSE_WAIT",
    ["09"] = "LAST_ACK",
    ["0A"] = "LISTEN",
    ["0B"] = "CLOSING",
}

local Backend = {}

if IS_WINDOWS then
    local AF_INET  = 2
    local AF_INET6 = 23
    local TCP_TABLE_OWNER_PID_ALL = 5
    local UDP_TABLE_OWNER_PID     = 1
    local TH32CS_SNAPPROCESS      = 0x00000002
    local PROCESS_TERMINATE       = 0x0001
    local PROCESS_QUERY_LIMITED_INFORMATION = 0x1000

    function Backend.get_process_map()
        local map = {
            [0] = { pid = 0, name = "Idle", ppid = 0, threads = 0 },
            [4] = { pid = 4, name = "System", ppid = 0, threads = 0 },
        }
        local hSnap = ffi.C.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
        if hSnap == nil or hSnap == ffi.cast("HANDLE", -1) then
            return map
        end
        local pe = ffi.new("PROCESSENTRY32")
        pe.dwSize = ffi.sizeof("PROCESSENTRY32")
        if ffi.C.Process32First(hSnap, pe) ~= 0 then
            repeat
                local pid = tonumber(pe.th32ProcessID)
                map[pid] = {
                    pid = pid,
                    name = ffi.string(pe.szExeFile),
                    ppid = tonumber(pe.th32ParentProcessID),
                    threads = tonumber(pe.cntThreads),
                }
            until ffi.C.Process32Next(hSnap, pe) == 0
        end
        ffi.C.CloseHandle(hSnap)
        return map
    end

    function Backend.get_process_details(pid, proc_map)
        proc_map = proc_map or Backend.get_process_map()
        local base = proc_map[pid] or { pid = pid, name = "Unknown", ppid = 0, threads = 0 }
        local exe_path = (pid == 4) and "NT Kernel & System" or "Access Denied / Protected"
        local rss_mb = 0

        if pid > 4 then
            local hProc = ffi.C.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid)
            if hProc ~= nil and hProc ~= ffi.cast("HANDLE", 0) then
                local buf = ffi.new("char[1024]")
                local sz = ffi.new("DWORD[1]", 1024)
                if ffi.C.QueryFullProcessImageNameA(hProc, 0, buf, sz) ~= 0 then
                    exe_path = ffi.string(buf, sz[0])
                end
                local pmc = ffi.new("PROCESS_MEMORY_COUNTERS")
                pmc.cb = ffi.sizeof("PROCESS_MEMORY_COUNTERS")
                if ffi.C.K32GetProcessMemoryInfo(hProc, pmc, pmc.cb) ~= 0 then
                    rss_mb = tonumber(pmc.WorkingSetSize) / (1024 * 1024)
                end
                ffi.C.CloseHandle(hProc)
            end
        end

        return {
            pid = pid,
            name = base.name,
            ppid = base.ppid,
            threads = base.threads,
            exe = exe_path,
            rss_mb = rss_mb,
        }
    end

    local function fetch_table(fn, af, table_class)
        local size = ffi.new("DWORD[1]", 0)
        local ret = fn(nil, size, 1, af, table_class, 0)
        if ret ~= 122 and ret ~= 0 then -- 122 = ERROR_INSUFFICIENT_BUFFER
            return nil
        end
        for _ = 1, 3 do
            local alloc_sz = size[0] + 4096
            local buf = ffi.new("BYTE[?]", alloc_sz)
            size[0] = alloc_sz
            ret = fn(buf, size, 1, af, table_class, 0)
            if ret == 0 then
                return buf
            elseif ret ~= 122 then
                return nil
            end
        end
        return nil
    end

    function Backend.get_sockets()
        local proc_map = Backend.get_process_map()
        local sockets = {}
        local iphlp = _G.iphlpapi

        -- 1. TCP IPv4
        local tcp4_buf = fetch_table(iphlp.GetExtendedTcpTable, AF_INET, TCP_TABLE_OWNER_PID_ALL)
        if tcp4_buf then
            local num = ffi.cast("DWORD*", tcp4_buf)[0]
            local rows = ffi.cast("MIB_TCPROW_OWNER_PID*", tcp4_buf + 4)
            for i = 0, num - 1 do
                local r = rows[i]
                local lport = ntohs(r.dwLocalPort)
                local rport = ntohs(r.dwRemotePort)
                local state = TCP_STATES_WIN[tonumber(r.dwState)] or "UNKNOWN"
                if state == "DELETE_TCB" then state = "TIME_WAIT" end
                local pid = tonumber(r.dwOwningPid)
                local pname = (proc_map[pid] and proc_map[pid].name) or tostring(pid)
                local lip = format_ipv4(r.dwLocalAddr)
                local rip = format_ipv4(r.dwRemoteAddr)
                table.insert(sockets, {
                    proto = "TCP",
                    port = lport,
                    local_ip = lip,
                    local_addr = lip .. ":" .. lport,
                    remote_ip = rip,
                    remote_port = rport,
                    remote_addr = (state == "LISTEN") and "0.0.0.0:*" or (rip .. ":" .. rport),
                    state = state,
                    pid = pid,
                    process = pname,
                })
            end
        end

        -- 2. TCP IPv6
        local tcp6_buf = fetch_table(iphlp.GetExtendedTcpTable, AF_INET6, TCP_TABLE_OWNER_PID_ALL)
        if tcp6_buf then
            local num = ffi.cast("DWORD*", tcp6_buf)[0]
            local rows = ffi.cast("MIB_TCP6ROW_OWNER_PID*", tcp6_buf + 4)
            for i = 0, num - 1 do
                local r = rows[i]
                local lport = ntohs(r.dwLocalPort)
                local rport = ntohs(r.dwRemotePort)
                local state = TCP_STATES_WIN[tonumber(r.dwState)] or "UNKNOWN"
                if state == "DELETE_TCB" then state = "TIME_WAIT" end
                local pid = tonumber(r.dwOwningPid)
                local pname = (proc_map[pid] and proc_map[pid].name) or tostring(pid)
                local lip = format_ipv6(r.ucLocalAddr)
                local rip = format_ipv6(r.ucRemoteAddr)
                table.insert(sockets, {
                    proto = "TCP6",
                    port = lport,
                    local_ip = lip,
                    local_addr = lip .. ":" .. lport,
                    remote_ip = rip,
                    remote_port = rport,
                    remote_addr = (state == "LISTEN") and "[::]:*" or (rip .. ":" .. rport),
                    state = state,
                    pid = pid,
                    process = pname,
                })
            end
        end

        -- 3. UDP IPv4
        local udp4_buf = fetch_table(iphlp.GetExtendedUdpTable, AF_INET, UDP_TABLE_OWNER_PID)
        if udp4_buf then
            local num = ffi.cast("DWORD*", udp4_buf)[0]
            local rows = ffi.cast("MIB_UDPROW_OWNER_PID*", udp4_buf + 4)
            for i = 0, num - 1 do
                local r = rows[i]
                local lport = ntohs(r.dwLocalPort)
                local pid = tonumber(r.dwOwningPid)
                local pname = (proc_map[pid] and proc_map[pid].name) or tostring(pid)
                local lip = format_ipv4(r.dwLocalAddr)
                table.insert(sockets, {
                    proto = "UDP",
                    port = lport,
                    local_ip = lip,
                    local_addr = lip .. ":" .. lport,
                    remote_ip = "*",
                    remote_port = 0,
                    remote_addr = "*:*",
                    state = "BOUND",
                    pid = pid,
                    process = pname,
                })
            end
        end

        -- 4. UDP IPv6
        local udp6_buf = fetch_table(iphlp.GetExtendedUdpTable, AF_INET6, UDP_TABLE_OWNER_PID)
        if udp6_buf then
            local num = ffi.cast("DWORD*", udp6_buf)[0]
            local rows = ffi.cast("MIB_UDP6ROW_OWNER_PID*", udp6_buf + 4)
            for i = 0, num - 1 do
                local r = rows[i]
                local lport = ntohs(r.dwLocalPort)
                local pid = tonumber(r.dwOwningPid)
                local pname = (proc_map[pid] and proc_map[pid].name) or tostring(pid)
                local lip = format_ipv6(r.ucLocalAddr)
                table.insert(sockets, {
                    proto = "UDP6",
                    port = lport,
                    local_ip = lip,
                    local_addr = lip .. ":" .. lport,
                    remote_ip = "*",
                    remote_port = 0,
                    remote_addr = "*:*",
                    state = "BOUND",
                    pid = pid,
                    process = pname,
                })
            end
        end

        return sockets, proc_map
    end

    function Backend.kill_process(pid)
        if not pid or pid <= 4 then
            return false, "Cannot terminate system process (PID " .. tostring(pid) .. ")"
        end
        local hProc = ffi.C.OpenProcess(PROCESS_TERMINATE, 0, pid)
        if hProc == nil or hProc == ffi.cast("HANDLE", 0) then
            local err = ffi.C.GetLastError()
            return false, string.format("OpenProcess failed (Win32 Error %d - try Administrator)", err)
        end
        local ok = ffi.C.TerminateProcess(hProc, 1)
        local err = ffi.C.GetLastError()
        ffi.C.CloseHandle(hProc)
        if ok ~= 0 then
            return true
        else
            return false, string.format("TerminateProcess failed (Win32 Error %d)", err)
        end
    end
else
    -- Linux / POSIX Backend
    local function parse_hex_ipv4(hex_ip)
        local n = tonumber(hex_ip, 16) or 0
        return format_ipv4(n)
    end

    local function build_inode_pid_map()
        local inode_map = {}
        local proc_map = {}
        local dir = ffi.C.opendir("/proc")
        if dir == nil then return inode_map, proc_map end

        local buf = ffi.new("char[256]")
        while true do
            local ent = ffi.C.readdir(dir)
            if ent == nil then break end
            local d_name = ffi.string(ent.d_name)
            local pid = tonumber(d_name)
            if pid then
                local comm_f = io.open(string.format("/proc/%d/comm", pid), "r")
                local pname = comm_f and comm_f:read("*l") or tostring(pid)
                if comm_f then comm_f:close() end
                proc_map[pid] = { pid = pid, name = pname, ppid = 0, threads = 1 }

                local fd_path = string.format("/proc/%d/fd", pid)
                local fd_dir = ffi.C.opendir(fd_path)
                if fd_dir ~= nil then
                    while true do
                        local fd_ent = ffi.C.readdir(fd_dir)
                        if fd_ent == nil then break end
                        local fd_name = ffi.string(fd_ent.d_name)
                        if fd_name ~= "." and fd_name ~= ".." then
                            local link_Len = ffi.C.readlink(fd_path .. "/" .. fd_name, buf, 255)
                            if link_Len > 0 then
                                local target = ffi.string(buf, link_Len)
                                local ino = target:match("^socket:%[(%d+)%]$")
                                if ino then
                                    inode_map[ino] = pid
                                end
                            end
                        end
                    end
                    ffi.C.closedir(fd_dir)
                end
            end
        end
        ffi.C.closedir(dir)
        return inode_map, proc_map
    end

    local function parse_proc_net(path, proto, is_v6, inode_map, proc_map, out)
        local f = io.open(path, "r")
        if not f then return end
        local first = true
        for line in f:lines() do
            if first then
                first = false
            else
                local l_hex, l_port_hex, r_hex, r_port_hex, st_hex, ino =
                    line:match("^%s*%d+:%s+([0-9A-Fa-f]+):([0-9A-Fa-f]+)%s+([0-9A-Fa-f]+):([0-9A-Fa-f]+)%s+([0-9A-Fa-f]+)%s+%S+%s+%S+%s+%S+%s+%d+%s+%d+%s+(%d+)")
                if l_hex and l_port_hex then
                    local lport = tonumber(l_port_hex, 16) or 0
                    local rport = tonumber(r_port_hex, 16) or 0
                    local lip = is_v6 and "[::]" or parse_hex_ipv4(l_hex)
                    local rip = is_v6 and "[::]" or parse_hex_ipv4(r_hex)
                    local state = proto:find("^UDP") and "BOUND" or (TCP_STATES_LINUX[st_hex:upper()] or "UNKNOWN")
                    local pid = inode_map[ino] or 0
                    local pname = (proc_map[pid] and proc_map[pid].name) or (pid > 0 and tostring(pid) or "-")
                    table.insert(out, {
                        proto = proto,
                        port = lport,
                        local_ip = lip,
                        local_addr = lip .. ":" .. lport,
                        remote_ip = rip,
                        remote_port = rport,
                        remote_addr = (state == "LISTEN" or state == "BOUND") and "*:*" or (rip .. ":" .. rport),
                        state = state,
                        pid = pid,
                        process = pname,
                    })
                end
            end
        end
        f:close()
    end

    function Backend.get_sockets()
        local inode_map, proc_map = build_inode_pid_map()
        local sockets = {}
        parse_proc_net("/proc/net/tcp",  "TCP",  false, inode_map, proc_map, sockets)
        parse_proc_net("/proc/net/tcp6", "TCP6", true,  inode_map, proc_map, sockets)
        parse_proc_net("/proc/net/udp",  "UDP",  false, inode_map, proc_map, sockets)
        parse_proc_net("/proc/net/udp6", "UDP6", true,  inode_map, proc_map, sockets)
        return sockets, proc_map
    end

    function Backend.get_process_details(pid, proc_map)
        if not pid or pid <= 0 then
            return { pid = 0, name = "Kernel / Unknown", ppid = 0, threads = 0, exe = "N/A", rss_mb = 0 }
        end
        local name = (proc_map and proc_map[pid] and proc_map[pid].name) or tostring(pid)
        local ppid, threads, rss_kb = 0, 1, 0
        local sf = io.open(string.format("/proc/%d/status", pid), "r")
        if sf then
            for line in sf:lines() do
                local k, v = line:match("^(%w+):%s*(.*)$")
                if k == "Name" then name = v
                elseif k == "PPid" then ppid = tonumber(v) or 0
                elseif k == "Threads" then threads = tonumber(v) or 1
                elseif k == "VmRSS" then rss_kb = tonumber(v:match("(%d+)")) or 0
                end
            end
            sf:close()
        end
        local buf = ffi.new("char[1024]")
        local len = ffi.C.readlink(string.format("/proc/%d/exe", pid), buf, 1023)
        local exe = (len > 0) and ffi.string(buf, len) or "Permission Denied / Kernel"
        return {
            pid = pid,
            name = name,
            ppid = ppid,
            threads = threads,
            exe = exe,
            rss_mb = rss_kb / 1024.0,
        }
    end

    function Backend.kill_process(pid, sig)
        if not pid or pid <= 1 then
            return false, "Cannot terminate PID " .. tostring(pid)
        end
        sig = sig or 15
        local res = ffi.C.kill(pid, sig)
        if res == 0 then
            return true
        else
            return false, ffi.string(ffi.C.strerror(ffi.errno()))
        end
    end
end

--------------------------------------------------------------------------------
-- Filtering, Categorization & Sorting
--------------------------------------------------------------------------------
local TABS = {
    { id = "listen", label = "1:Listen" },
    { id = "all",    label = "2:All"    },
    { id = "estab",  label = "3:Estab"  },
    { id = "udp",    label = "4:UDP"    },
}

local SORT_MODES = { "port", "pid", "process", "proto" }

local function matches_tab(sock, tab_id)
    if tab_id == "all" then
        return true
    elseif tab_id == "listen" then
        return sock.state == "LISTEN"
    elseif tab_id == "estab" then
        return sock.proto:find("^TCP") ~= nil and sock.state ~= "LISTEN"
    elseif tab_id == "udp" then
        return sock.proto:find("^UDP") ~= nil
    end
    return true
end

-- A digits-only query is an exact port or PID lookup. Treating it as fuzzy
-- text used to pull in unrelated rows ("45678" also matched a row whose digits
-- happened to appear in order), which is dangerous next to the kill key.
local function parse_numeric_query(query)
    local lowered = query:lower()
    local prefix, value = lowered:match("^(%a+):(%d+)$")
    if prefix == "port" or prefix == "pid" then
        return prefix, tonumber(value)
    end
    if lowered:match("^%d+$") then
        return "port_or_pid", tonumber(lowered)
    end
    return nil, nil
end

local function matches_query(sock, query)
    if not query or #query == 0 then
        return true
    end

    local kind, number = parse_numeric_query(query)
    if kind == "port" then
        return sock.port == number
    elseif kind == "pid" then
        return sock.pid == number
    elseif kind == "port_or_pid" then
        return sock.port == number or sock.pid == number
    end

    local hay = string.format("%d %s %s %s %d %s",
        sock.port, sock.proto, sock.local_addr, sock.state, sock.pid, sock.process)
    return fuzzy_score(query, hay) ~= nil
end

local function filter_and_sort(sockets, tab_id, query, sort_mode)
    local out = {}
    for _, s in ipairs(sockets) do
        if matches_tab(s, tab_id) and matches_query(s, query) then
            table.insert(out, s)
        end
    end

    table.sort(out, function(a, b)
        if sort_mode == "pid" then
            if a.pid ~= b.pid then return a.pid < b.pid end
        elseif sort_mode == "process" then
            local pa, pb = a.process:lower(), b.process:lower()
            if pa ~= pb then return pa < pb end
        elseif sort_mode == "proto" then
            if a.proto ~= b.proto then return a.proto < b.proto end
        end
        if a.port ~= b.port then return a.port < b.port end
        if a.proto ~= b.proto then return a.proto < b.proto end
        return a.pid < b.pid
    end)

    return out
end

local function count_by_tab(sockets)
    local counts = { listen = 0, all = #sockets, estab = 0, udp = 0 }
    for _, s in ipairs(sockets) do
        if s.state == "LISTEN" then counts.listen = counts.listen + 1 end
        if s.proto:find("^TCP") and s.state ~= "LISTEN" then counts.estab = counts.estab + 1 end
        if s.proto:find("^UDP") then counts.udp = counts.udp + 1 end
    end
    return counts
end

--------------------------------------------------------------------------------
-- Interactive Dual-Pane TUI
--------------------------------------------------------------------------------
local function run_tui(initial_query, start_all)
    Term.init()
    local sockets, proc_map = Backend.get_sockets()
    local proc_cache = {}

    local state = {
        tab_idx = start_all and 2 or 1,
        sort_idx = 1,
        query = initial_query or "",
        prev_query = "",
        mode = "normal", -- "normal" | "search" | "confirm_kill" | "help"
        cursor = 1,
        scroll = 1,
        status_msg = "",
        status_is_err = false,
        pending_g = false,
        filtered = {},
        counts = count_by_tab(sockets),
    }

    local function get_proc_info(pid)
        if not proc_cache[pid] then
            proc_cache[pid] = Backend.get_process_details(pid, proc_map)
        end
        return proc_cache[pid]
    end

    local function refresh_data(msg, is_err)
        sockets, proc_map = Backend.get_sockets()
        proc_cache = {}
        state.counts = count_by_tab(sockets)
        local tab_id = TABS[state.tab_idx].id
        local sort_mode = SORT_MODES[state.sort_idx]
        state.filtered = filter_and_sort(sockets, tab_id, state.query, sort_mode)
        if state.cursor > #state.filtered then
            state.cursor = math.max(1, #state.filtered)
        end
        if msg then
            state.status_msg = msg
            state.status_is_err = is_err or false
        end
    end

    local function refilter()
        local tab_id = TABS[state.tab_idx].id
        local sort_mode = SORT_MODES[state.sort_idx]
        state.filtered = filter_and_sort(sockets, tab_id, state.query, sort_mode)
        state.cursor = math.min(math.max(1, state.cursor), math.max(1, #state.filtered))
    end

    refilter()

    local prev_lines = {}
    local prev_cols, prev_rows = 0, 0

    local function render()
        local cols, rows = Term.get_size()
        if cols ~= prev_cols or rows ~= prev_rows then
            prev_lines = {}
            prev_cols, prev_rows = cols, rows
            io.write("\27[2J")
        end

        local left_w = math.floor(cols * 0.52)
        if left_w < 38 then left_w = 38 end
        local right_w = cols - left_w - 3
        if right_w < 20 then right_w = 20 end
        local body_h = rows - 6
        if body_h < 6 then body_h = 6 end

        if state.cursor < state.scroll then
            state.scroll = state.cursor
        elseif state.cursor >= state.scroll + body_h - 1 then
            state.scroll = state.cursor - body_h + 2
        end
        if state.scroll < 1 then state.scroll = 1 end

        local frame_lines = {}

        -- 1. Top Header Bar with Category Tabs (3 rows)
        local tab_str = ""
        for i, t in ipairs(TABS) do
            local cnt = state.counts[t.id] or 0
            local label = string.format(" %s (%d) ", t.label, cnt)
            if i == state.tab_idx then
                tab_str = tab_str .. C.bg_darkblue .. C.b_white .. label .. C.reset .. " "
            else
                tab_str = tab_str .. C.gray .. label .. C.reset .. " "
            end
        end
        local title = C.b_cyan .. " fport " .. C.reset .. C.dim .. "Port & Socket Inspector  " .. C.reset .. tab_str
        table.insert(frame_lines, BOX.tl .. string.rep(BOX.h, cols - 2) .. BOX.tr)
        table.insert(frame_lines, BOX.v .. pad_string(title, cols - 2) .. BOX.v)

        -- 2. Search & Sort Bar
        local search_prefix = (state.mode == "search")
            and (C.b_yellow .. " Filter (/): " .. C.b_white .. state.query .. "█" .. C.reset)
            or  (C.cyan .. " Filter (/): " .. C.white .. (#state.query > 0 and state.query or C.gray .. "(none)") .. C.reset)
        local sort_badge = string.format("%sSort: [%s ▲]  Shown: %d%s ",
            C.yellow, SORT_MODES[state.sort_idx]:upper(), #state.filtered, C.reset)
        local sort_w = utf8_col_width(sort_badge)
        local filter_line = pad_string(search_prefix, math.max(10, cols - 2 - sort_w)) .. sort_badge
        table.insert(frame_lines, BOX.vl .. string.rep(BOX.h, left_w) .. BOX.tt .. string.rep(BOX.h, right_w) .. BOX.vr)

        -- 3. Prepare Right-Pane Inspector Lines
        local r_lines = {}
        local sel = state.filtered[state.cursor]
        if state.mode == "help" then
            table.insert(r_lines, C.b_yellow .. " Keyboard Shortcuts (press any key to close)" .. C.reset)
            table.insert(r_lines, C.gray .. " " .. string.rep(BOX.h, math.max(10, right_w - 2)) .. C.reset)
            table.insert(r_lines, " " .. C.b_cyan .. "j / k / Up / Down " .. C.reset .. "Move selection cursor")
            table.insert(r_lines, " " .. C.b_cyan .. "gg / G / Home/End " .. C.reset .. "Jump to first / last entry")
            table.insert(r_lines, " " .. C.b_cyan .. "Ctrl+d / Ctrl+u   " .. C.reset .. "Scroll down / up 10 rows")
            table.insert(r_lines, " " .. C.b_cyan .. "Tab / h / l / 1-4 " .. C.reset .. "Switch category tab")
            table.insert(r_lines, " " .. C.b_cyan .. "/                 " .. C.reset .. "Filter (digits = exact port/PID, text = fuzzy)")
            table.insert(r_lines, " " .. C.b_cyan .. "s                 " .. C.reset .. "Cycle sort column")
            table.insert(r_lines, " " .. C.b_cyan .. "r                 " .. C.reset .. "Refresh socket table (FFI)")
            table.insert(r_lines, " " .. C.b_cyan .. "x / Enter / Del   " .. C.reset .. "Kill process (with [y/N] prompt)")
            table.insert(r_lines, " " .. C.b_cyan .. "K                 " .. C.reset .. "Force kill process immediately")
            table.insert(r_lines, " " .. C.b_cyan .. "Esc               " .. C.reset .. "Clear filter or quit")
            table.insert(r_lines, " " .. C.b_cyan .. "q / Ctrl+C        " .. C.reset .. "Quit fport")
        elseif sel then
            local svc = WELL_KNOWN_PORTS[sel.port]
            local port_disp = svc and string.format("%d (%s)", sel.port, svc) or tostring(sel.port)
            local st_color = (sel.state == "LISTEN") and C.b_green
                or (sel.state == "ESTABLISHED" and C.b_cyan or C.yellow)

            table.insert(r_lines, C.b_cyan .. " Socket Details" .. C.reset)
            table.insert(r_lines, C.gray .. " " .. string.rep(BOX.h, math.max(10, right_w - 2)) .. C.reset)
            table.insert(r_lines, string.format(" %sPort       :%s %s%s%s", C.gray, C.reset, C.b_yellow, port_disp, C.reset))
            table.insert(r_lines, string.format(" %sProtocol   :%s %s", C.gray, C.reset, sel.proto))
            table.insert(r_lines, string.format(" %sState      :%s %s%s%s", C.gray, C.reset, st_color, sel.state, C.reset))
            table.insert(r_lines, string.format(" %sLocal Bind :%s %s", C.gray, C.reset, sel.local_addr))
            table.insert(r_lines, string.format(" %sRemote Peer:%s %s", C.gray, C.reset, sel.remote_addr))
            table.insert(r_lines, "")

            local pinfo = get_proc_info(sel.pid)
            table.insert(r_lines, C.b_cyan .. " Owning Process" .. C.reset)
            table.insert(r_lines, C.gray .. " " .. string.rep(BOX.h, math.max(10, right_w - 2)) .. C.reset)
            table.insert(r_lines, string.format(" %sProcess    :%s %s%s%s", C.gray, C.reset, C.b_white, pinfo.name, C.reset))
            table.insert(r_lines, string.format(" %sPID        :%s %d  (PPID: %d)", C.gray, C.reset, pinfo.pid, pinfo.ppid))
            table.insert(r_lines, string.format(" %sThreads    :%s %d", C.gray, C.reset, pinfo.threads))
            if pinfo.rss_mb and pinfo.rss_mb > 0 then
                table.insert(r_lines, string.format(" %sMemory RSS :%s %.2f MB", C.gray, C.reset, pinfo.rss_mb))
            end
            table.insert(r_lines, string.format(" %sExecutable :%s %s", C.gray, C.reset,
                truncate_string(pinfo.exe or "N/A", math.max(10, right_w - 15))))
            table.insert(r_lines, "")

            -- Sibling sockets for same PID
            if sel.pid > 0 then
                local siblings = {}
                for _, s in ipairs(sockets) do
                    if s.pid == sel.pid then
                        table.insert(siblings, s)
                    end
                end
                table.insert(r_lines, string.format("%s All Sockets for PID %d (%d)%s", C.b_cyan, sel.pid, #siblings, C.reset))
                table.insert(r_lines, C.gray .. " " .. string.rep(BOX.h, math.max(10, right_w - 2)) .. C.reset)
                for i = 1, math.min(#siblings, 8) do
                    local sb = siblings[i]
                    local line_s = string.format(" • %-4s %-18s %s", sb.proto, sb.local_addr, sb.state)
                    table.insert(r_lines, truncate_string(line_s, right_w - 1))
                end
                if #siblings > 8 then
                    table.insert(r_lines, string.format(" %s... and %d more%s", C.gray, #siblings - 8, C.reset))
                end
            end
        else
            table.insert(r_lines, C.gray .. " No socket selected." .. C.reset)
        end

        -- 4. Render Dual-Pane Body (rows - 6 rows)
        local col_hdr = string.format(" %-5s %-6s %-17s %-7s %s", "PROTO", "PORT", "LOCAL ADDR", "PID", "PROCESS")
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
                    local prefix = is_sel and "▸" or " "
                    local addr_short = truncate_string(item.local_addr, 17)
                    local proc_w = math.max(6, left_w - 39)
                    local proc_short = truncate_string(item.process, proc_w)
                    local raw_line = string.format("%s%-5s %-6d %-17s %-7d %s",
                        prefix, item.proto, item.port, addr_short, item.pid, proc_short)
                    raw_line = pad_string(truncate_string(raw_line, left_w), left_w)
                    if is_sel then
                        l_cell = C.bg_sel .. C.b_yellow .. raw_line .. C.reset
                    else
                        local p_col = (item.state == "LISTEN") and C.green
                            or (item.proto:find("^UDP") and C.magenta or C.white)
                        l_cell = p_col .. raw_line .. C.reset
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

        -- 5. Footer / Filter & Keybindings Bar (3 rows)
        table.insert(frame_lines, BOX.vl .. string.rep(BOX.h, left_w) .. BOX.tb .. string.rep(BOX.h, right_w) .. BOX.vr)
        local footer
        if state.mode == "confirm_kill" and sel then
            footer = C.bg_red .. C.b_white ..
                string.format(" Kill process '%s' (PID %d) on port %d? Press [y] to confirm, [n/Esc] to cancel ",
                    sel.process, sel.pid, sel.port) .. C.reset
        elseif #state.status_msg > 0 then
            local col = state.status_is_err and C.b_red or C.b_green
            footer = " " .. col .. state.status_msg .. C.reset .. "  " .. filter_line
        else
            local hints = C.gray .. " [j/k] Move  [Tab/1-4] Tab  [/] Filter  [s] Sort  [r] Refresh  [x/Enter] Kill  [?] Help  [q] Quit" .. C.reset
            footer = (#state.query > 0 or state.mode == "search") and filter_line or hints
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
                elseif state.mode == "confirm_kill" then
                    if key == "y" or key == "Y" or key == "enter" then
                        local sel = state.filtered[state.cursor]
                        state.mode = "normal"
                        if sel then
                            local killed, kerr = Backend.kill_process(sel.pid)
                            if killed then
                                Term.sleep_ms(80)
                                refresh_data(string.format("Terminated %s (PID %d)", sel.process, sel.pid), false)
                            else
                                state.status_msg = kerr or "Failed to terminate process"
                                state.status_is_err = true
                            end
                        end
                    else
                        state.mode = "normal"
                        state.status_msg = "Kill cancelled"
                        state.status_is_err = false
                    end
                    render()
                elseif state.mode == "search" then
                    if key == "enter" then
                        state.mode = "normal"
                    elseif key == "esc" or key == "ctrl_c" then
                        state.query = state.prev_query
                        state.mode = "normal"
                        refilter()
                    elseif key == "backspace" then
                        if #state.query > 0 then
                            state.query = state.query:sub(1, -2)
                            refilter()
                        end
                    elseif key == "down" or key == "ctrl_n" then
                        state.cursor = math.min(#state.filtered, state.cursor + 1)
                    elseif key == "up" or key == "ctrl_p" then
                        state.cursor = math.max(1, state.cursor - 1)
                    elseif #key == 1 and key:byte(1) >= 32 and key:byte(1) <= 126 then
                        state.query = state.query .. key
                        refilter()
                    end
                    render()
                else
                    -- Normal Mode
                    if key == "q" or key == "ctrl_c" then
                        break
                    elseif key == "esc" then
                        if #state.query > 0 then
                            state.query = ""
                            refilter()
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
                    elseif key == "tab" or key == "l" or key == "right" then
                        state.pending_g = false
                        state.tab_idx = (state.tab_idx % #TABS) + 1
                        state.cursor = 1
                        refilter()
                        render()
                    elseif key == "h" or key == "left" then
                        state.pending_g = false
                        state.tab_idx = ((state.tab_idx - 2) % #TABS) + 1
                        state.cursor = 1
                        refilter()
                        render()
                    elseif key == "1" or key == "2" or key == "3" or key == "4" then
                        state.pending_g = false
                        state.tab_idx = tonumber(key)
                        state.cursor = 1
                        refilter()
                        render()
                    elseif key == "s" then
                        state.pending_g = false
                        state.sort_idx = (state.sort_idx % #SORT_MODES) + 1
                        refilter()
                        render()
                    elseif key == "r" then
                        state.pending_g = false
                        refresh_data("Refreshed socket table", false)
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
                    elseif key == "x" or key == "enter" or key == "delete" then
                        state.pending_g = false
                        if state.filtered[state.cursor] then
                            state.mode = "confirm_kill"
                            render()
                        end
                    elseif key == "K" then
                        state.pending_g = false
                        local sel = state.filtered[state.cursor]
                        if sel then
                            local killed, kerr = Backend.kill_process(sel.pid)
                            if killed then
                                Term.sleep_ms(80)
                                refresh_data(string.format("Terminated %s (PID %d)", sel.process, sel.pid), false)
                            else
                                state.status_msg = kerr or "Failed to terminate process"
                                state.status_is_err = true
                            end
                            render()
                        end
                    end
                end
            end
        end
    end)
    Term.restore()
    if not ok then
        io.stderr:write("[fport error] " .. tostring(err) .. "\n")
        os.exit(1)
    end
end

--------------------------------------------------------------------------------
-- Non-Interactive CLI Commands
--------------------------------------------------------------------------------
local function cmd_list(query, show_all)
    Term.init()
    local sockets = Backend.get_sockets()
    local tab_id = show_all and "all" or "listen"
    local list = filter_and_sort(sockets, tab_id, query, "port")
    print(string.format("%-6s %-7s %-24s %-22s %-12s %-8s %s",
        "PROTO", "PORT", "LOCAL ADDRESS", "REMOTE ADDRESS", "STATE", "PID", "PROCESS"))
    print(string.format("%-6s %-7s %-24s %-22s %-12s %-8s %s",
        "-----", "------", "------------------------", "----------------------", "-----------", "-------", "------------------"))
    for _, s in ipairs(list) do
        print(string.format("%-6s %-7d %-24s %-22s %-12s %-8d %s",
            s.proto, s.port, s.local_addr, s.remote_addr, s.state, s.pid, s.process))
    end
end

local function cmd_preview(target)
    Term.init()
    local sockets, proc_map = Backend.get_sockets()
    local kind, number = parse_numeric_query(target)
    local matches = {}
    for _, s in ipairs(sockets) do
        local hit
        if kind == "port" then
            hit = (s.port == number)
        elseif kind == "pid" then
            hit = (s.pid == number)
        elseif kind == "port_or_pid" then
            hit = (s.port == number or s.pid == number)
        else
            hit = s.process:lower():find(target:lower(), 1, true) ~= nil
        end
        if hit then
            table.insert(matches, s)
        end
    end
    if #matches == 0 then
        print("No active sockets matching: " .. tostring(target))
        return
    end
    local first = matches[1]
    local pinfo = Backend.get_process_details(first.pid, proc_map)
    local svc = WELL_KNOWN_PORTS[first.port]
    print(C.b_cyan .. "==========================================================" .. C.reset)
    print(string.format("  %sPort & Socket Details  (:%d)%s", C.b_yellow, first.port, C.reset))
    print(C.b_cyan .. "==========================================================" .. C.reset)
    print(string.format("  Port        : %d%s", first.port, svc and (" (" .. svc .. ")") or ""))
    print(string.format("  Protocol    : %s", first.proto))
    print(string.format("  State       : %s", first.state))
    print(string.format("  Local Bind  : %s", first.local_addr))
    print(string.format("  Remote Peer : %s", first.remote_addr))
    print(C.gray .. "----------------------------------------------------------" .. C.reset)
    print(string.format("  Process     : %s%s%s", C.b_white, pinfo.name, C.reset))
    print(string.format("  PID         : %d  (Parent PID: %d)", pinfo.pid, pinfo.ppid))
    print(string.format("  Threads     : %d", pinfo.threads))
    if pinfo.rss_mb and pinfo.rss_mb > 0 then
        print(string.format("  Memory (RSS): %.2f MB", pinfo.rss_mb))
    end
    print(string.format("  Executable  : %s", pinfo.exe or "N/A"))
    print(C.b_cyan .. "==========================================================" .. C.reset)
end

local function cmd_kill_port(target)
    local port_num = tonumber(target)
    if not port_num then
        io.stderr:write("[ERROR] Invalid port number: " .. tostring(target) .. "\n")
        os.exit(1)
    end
    local sockets = Backend.get_sockets()
    local pids = {}
    for _, s in ipairs(sockets) do
        if s.port == port_num and s.pid > 4 then
            pids[s.pid] = s.process
        end
    end
    local count = 0
    for pid, pname in pairs(pids) do
        count = count + 1
        local ok, err = Backend.kill_process(pid)
        if ok then
            print(string.format("[OK] Terminated %s (PID %d) on port %d", pname, pid, port_num))
        else
            io.stderr:write(string.format("[ERROR] Failed to kill %s (PID %d): %s\n", pname, pid, tostring(err)))
            os.exit(1)
        end
    end
    if count == 0 then
        io.stderr:write(string.format("No user process found bound to port %d.\n", port_num))
        os.exit(1)
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

    print("Running fport.lua automated self-tests...")
    assert_eq("ntohs(0x5000) == 80", ntohs(0x5000), 80)
    assert_eq("ntohs(0x2823) == 9000", ntohs(0x2823), 9000)
    assert_eq("format_ipv4(0x0100007F) == 127.0.0.1", format_ipv4(0x0100007F), "127.0.0.1")
    assert_eq("format_ipv4(0) == 0.0.0.0", format_ipv4(0), "0.0.0.0")

    local ipv6_zero = ffi.new("unsigned char[16]")
    assert_eq("format_ipv6(::) == [::]", format_ipv6(ipv6_zero), "[::]")
    ipv6_zero[15] = 1
    assert_eq("format_ipv6(::1) == [::1]", format_ipv6(ipv6_zero), "[::1]")

    local sockets, proc_map = Backend.get_sockets()
    assert_eq("Socket enumeration returns table", type(sockets), "table")
    assert_eq("Process map returns table", type(proc_map), "table")
    assert_eq("Active sockets > 0", #sockets > 0, true)

    local listen_list = filter_and_sort(sockets, "listen", "", "port")
    assert_eq("Listen filter returns table", type(listen_list), "table")

    -- Synthetic rows prove the matcher never widens a numeric query.
    local fixtures = {
        { proto = "TCP", port = 45678, pid = 4336, process = "python.exe",
          local_addr = "127.0.0.1:45678", state = "LISTEN" },
        { proto = "TCP6", port = 42050, pid = 1728, process = "OneDrive.Sync.Service.exe",
          local_addr = "[::1]:42050", state = "LISTEN" },
    }
    local hits = filter_and_sort(fixtures, "all", "45678", "port")
    assert_eq("digits-only query matches exactly one port", #hits, 1)
    assert_eq("digits-only query picks the right port", hits[1] and hits[1].port, 45678)

    hits = filter_and_sort(fixtures, "all", "4336", "port")
    assert_eq("digits-only query also matches an exact PID", #hits, 1)
    assert_eq("digits-only query picks the right PID", hits[1] and hits[1].pid, 4336)

    hits = filter_and_sort(fixtures, "all", "42050", "port")
    assert_eq("port query does not match unrelated rows", #hits, 1)
    assert_eq("port query keeps the bound row", hits[1] and hits[1].port, 42050)

    hits = filter_and_sort(fixtures, "all", "port:42050", "port")
    assert_eq("port: prefix matches that port", #hits, 1)
    assert_eq("port: prefix ignores PIDs", hits[1] and hits[1].pid, 1728)

    hits = filter_and_sort(fixtures, "all", "pid:4336", "port")
    assert_eq("pid: prefix matches that PID", #hits, 1)
    assert_eq("pid: prefix ignores ports", hits[1] and hits[1].port, 45678)

    hits = filter_and_sort(fixtures, "all", "onedrive", "port")
    assert_eq("text queries still match the process name", #hits, 1)
    assert_eq("text query keeps case-insensitive matching", hits[1] and hits[1].process,
        "OneDrive.Sync.Service.exe")

    print(string.format("\nSelf-test summary: %d passed, %d failed.", passed, failed))
    if failed > 0 then os.exit(1) end
end

local function show_help()
    print([[
Usage: fport [OPTIONS] [PORT_OR_QUERY]

High-Performance Interactive Port & Socket Inspector / Killer TUI (LuaJIT + FFI).

Options:
  -l, --list           Print formatted port table to stdout and exit
  -a, --all            Include all TCP states (ESTABLISHED, TIME_WAIT) and UDP sockets
  -k, --kill <PORT>    Terminate process(es) listening/bound on <PORT>
  --preview <PORT|PID> Print detailed ANSI socket & process card for a port or PID
  --test               Run automated self-test suite
  -h, --help           Show this help message

Search behavior:
  A digits-only query matches a port or a PID exactly; use port:N or pid:N to
  pick one explicitly. Any other text is fuzzy-matched against the row.
  Examples:  fport --list 5173     fport --list pid:4336     fport --list node

TUI Keybindings:
  j / k / Up / Down    Navigate socket list
  Tab / h / l / 1-4    Switch category tabs ([1:Listen], [2:All], [3:Estab], [4:UDP])
  /                    Live filter by port, process name, PID, or address
  s                    Cycle sort column (Port, PID, Process, Protocol)
  r                    Refresh socket table immediately
  x / Enter / Del      Terminate owning process (with [y/N] confirmation)
  K                    Force terminate owning process immediately
  q / Esc              Quit]])
end

--------------------------------------------------------------------------------
-- Entrypoint
--------------------------------------------------------------------------------
local args = { ... }
local mode = "tui"
local show_all = false
local target_arg = nil

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
        show_all = true
    elseif a == "-k" or a == "--kill" then
        mode = "kill"
        i = i + 1
        target_arg = args[i]
    elseif a == "--preview" then
        mode = "preview"
        i = i + 1
        target_arg = args[i]
    else
        target_arg = a
    end
    i = i + 1
end

if mode == "list" then
    cmd_list(target_arg, show_all)
elseif mode == "preview" then
    cmd_preview(target_arg or "")
elseif mode == "kill" then
    cmd_kill_port(target_arg)
else
    run_tui(target_arg, show_all)
end
