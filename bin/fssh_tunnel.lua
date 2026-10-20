#!/usr/bin/env luajit
--[[
  fssh_tunnel.lua - High-Performance Interactive SSH Port Forward & Tunnel Manager
  Powered by LuaJIT & FFI. Sub-millisecond pre-flight socket port verification.

  Features:
    1. Host discovery from OpenSSH config, known_hosts, /etc/hosts, and Windows PuTTY sessions (Win32 Registry FFI).
    2. Local Forward (-L), Remote Forward (-R), and Dynamic SOCKS5 Proxy (-D).
    3. Pre-flight port availability verification via C socket FFI (< 0.1 ms) before launching SSH.
    4. Auto-detects port collisions and suggests the next free port.
    5. Built-in service presets (Jupyter, TensorBoard, PostgreSQL, MySQL, Redis, Code-Server, VNC).
    6. Background tunnel tracking with persistent registry (~/.ssh/.fssh_tunnels.json).
    7. Stale tunnel detection & cleanup (checks PID liveness via FFI without subshell overhead).
    8. Interactive FZF tunnel manager to inspect and terminate active tunnels.

  Usage:
    fssh_tunnel.lua [OPTIONS] [HOST]

  Options:
    -L <local_port:remote_host:remote_port>   Local forward: bind local_port, dial remote_host:remote_port
    -R <remote_port:target_host:local_port>   Remote forward: remote binds remote_port, dials local_port
    -D <local_port>                          Dynamic SOCKS5 proxy
    -p, --preset <name>                      Use service preset (jupyter, tensorboard, postgres,
                                             mysql, redis, codeserver, vnc, socks)
    -b, --background                         Run tunnel in background (-f -N) [default for new tunnels]
    -F, --foreground                         Run tunnel in foreground (keep terminal attached)
    -l, --list                               List currently active background tunnels
    --lines                                  Machine-readable TSV of active tunnels
    --json                                   Output active tunnels as JSON
    -k, --kill <PID|all>                     Stop one tunnel, or all of them (asks first)
    -y, --yes                                Skip the confirmation prompt for --kill all
    -m, --manage                             Interactive FZF tunnel manager
    --check-port <port>                      Exit 0 when a local TCP port is free, 1 when occupied
    --hosts                                  List discovered SSH hosts
    -d, --dry-run                            Print SSH command without executing
    -i, --interactive                        Guided setup wizard
    --test                                   Run the built-in self-test suite
    -h, --help                               Show this help message
]]

local ffi = require("ffi")
local bit = require("bit")

local OS = ffi.os
local IS_LINUX = (OS == "Linux")
local IS_WINDOWS = (OS == "Windows")
local IS_OSX = (OS == "OSX")

-- Winsock lives in ws2_32.dll, which is not part of the default ffi.C namespace.
-- Binding it explicitly is what makes socket/bind resolve on Windows.
local winsock = IS_WINDOWS and ffi.load("ws2_32") or nil

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
        typedef unsigned int UINT_PTR;
        typedef UINT_PTR SOCKET;

        LONG RegOpenKeyExA(HKEY hKey, const char* lpSubKey, DWORD ulOptions, DWORD samDesired, HKEY* phkResult);
        LONG RegEnumKeyExA(HKEY hKey, DWORD dwIndex, char* lpName, DWORD* lpcchName, DWORD* lpReserved, char* lpClass, DWORD* lpcchClass, void* lpftLastWriteTime);
        LONG RegQueryValueExA(HKEY hKey, const char* lpValueName, DWORD* lpReserved, DWORD* lpType, BYTE* lpData, DWORD* lpcbData);
        LONG RegCloseKey(HKEY hKey);

        HANDLE OpenProcess(DWORD dwDesiredAccess, BOOL bInheritHandle, DWORD dwProcessId);
        BOOL GetExitCodeProcess(HANDLE hProcess, DWORD* lpExitCode);
        BOOL TerminateProcess(HANDLE hProcess, unsigned int uExitCode);
        BOOL CloseHandle(HANDLE hObject);

        HANDLE GetStdHandle(DWORD nStdHandle);
        BOOL GetConsoleMode(HANDLE hConsoleHandle, DWORD* lpMode);
        BOOL SetConsoleMode(HANDLE hConsoleHandle, DWORD dwMode);
        DWORD GetCurrentProcessId(void);

        typedef struct {
            unsigned short wVersion;
            unsigned short wHighVersion;
            char szDescription[257];
            char szSystemStatus[129];
            unsigned short iMaxSockets;
            unsigned short iMaxUdpDg;
            char *lpVendorInfo;
        } WSADATA;

        int WSAStartup(unsigned short wVersionRequired, WSADATA *lpWSAData);
        int WSACleanup(void);
        int WSAGetLastError(void);
        SOCKET socket(int af, int type, int protocol);
        int closesocket(SOCKET s);
        int bind(SOCKET s, const struct sockaddr *name, int namelen);
        int setsockopt(SOCKET s, int level, int optname, const char *optval, int optlen);
        unsigned short htons(unsigned short hostshort);

        typedef struct {
            DWORD dwLowDateTime;
            DWORD dwHighDateTime;
        } FILETIME;

        BOOL QueryFullProcessImageNameW(HANDLE hProcess, DWORD dwFlags, uint16_t* lpExeName, DWORD* lpdwSize);
        BOOL GetProcessTimes(HANDLE hProcess, FILETIME* lpCreationTime, FILETIME* lpExitTime,
            FILETIME* lpKernelTime, FILETIME* lpUserTime);
    ]]
else
    ffi.cdef[[
        int kill(int pid, int sig);
        int isatty(int fd);
        int getpid(void);

        int socket(int domain, int type, int protocol);
        int close(int fd);
        int bind(int sockfd, const void *addr, unsigned int addrlen);
        int setsockopt(int sockfd, int level, int optname, const void *optval, unsigned int optlen);
        unsigned short htons(unsigned short hostshort);
        int inet_pton(int af, const char *src, void *dst);
    ]]
end

--------------------------------------------------------------------------------
-- ANSI Colors
--------------------------------------------------------------------------------
local C = {
    reset  = "\27[0m",
    bold   = "\27[1m",
    dim    = "\27[2m",
    red    = "\27[31m",
    green  = "\27[32m",
    yellow = "\27[33m",
    blue   = "\27[34m",
    magenta= "\27[35m",
    cyan   = "\27[36m",
    white  = "\27[37m",
    bg_blue= "\27[44m",
}

--------------------------------------------------------------------------------
-- Console & Small Helpers
--------------------------------------------------------------------------------
local ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004
local STD_INPUT_HANDLE = -10
local STD_OUTPUT_HANDLE = -11
local STD_ERROR_HANDLE = -12

-- Tables go to stdout and diagnostics go to stderr; both streams carry ANSI
-- color, so both console handles need virtual terminal processing.
local function enable_virtual_terminal(handle_id)
    local handle = ffi.C.GetStdHandle(handle_id)
    if handle == nil or handle == ffi.cast("HANDLE", -1) then
        return
    end

    local mode = ffi.new("DWORD[1]")
    if ffi.C.GetConsoleMode(handle, mode) == 0 then
        return
    end

    ffi.C.SetConsoleMode(handle, bit.bor(mode[0], ENABLE_VIRTUAL_TERMINAL_PROCESSING))
end

local function setup_console()
    if IS_WINDOWS then
        enable_virtual_terminal(STD_OUTPUT_HANDLE)
        enable_virtual_terminal(STD_ERROR_HANDLE)
    end
end
setup_console()

local function warn(message)
    io.stderr:write(string.format("%s[WARNING]%s %s\n", C.yellow, C.reset, message))
end

local function fail(message)
    io.stderr:write(string.format("%s[ERROR]%s %s\n", C.red, C.reset, message))
end

-- Reads one line, returning "" at end of input so piped runs never index nil.
local function read_line()
    local line = io.read("*l")
    if line == nil then
        return ""
    end
    return line
end

local function is_console_handle(handle_id, file_descriptor)
    if IS_WINDOWS then
        local handle = ffi.C.GetStdHandle(handle_id)
        if handle == nil or handle == ffi.cast("HANDLE", -1) then
            return false
        end

        local mode = ffi.new("DWORD[1]")
        return ffi.C.GetConsoleMode(handle, mode) ~= 0
    end

    return ffi.C.isatty(file_descriptor) == 1
end

local function is_interactive_stdin()
    return is_console_handle(STD_INPUT_HANDLE, 0)
end

local function is_interactive_stdout()
    return is_console_handle(STD_OUTPUT_HANDLE, 1)
end

-- fzf needs a real terminal on both ends; without one it blocks forever
-- waiting for input that will never arrive.
local function is_interactive_terminal()
    return is_interactive_stdin() and is_interactive_stdout()
end

-- Quotes one argument for the shell that os.execute/io.popen will use.
local function shell_quote(text)
    if IS_WINDOWS then
        -- cmd.exe has no single quotes; a doubled "" is an embedded quote.
        return '"' .. tostring(text):gsub('"', '""') .. '"'
    end

    return "'" .. tostring(text):gsub("'", "'\\''") .. "'"
end

-- os.clock() advances while this loop spins; used only to wait for `ssh -f`
-- to publish its child process.
local function sleep_milliseconds(milliseconds)
    local deadline = os.clock() + milliseconds / 1000
    while os.clock() < deadline do
        -- spin
    end
end

--------------------------------------------------------------------------------
-- Sockets & Port Checking via FFI
--------------------------------------------------------------------------------
local AF_INET = 2
local SOCK_STREAM = 1
local SOL_SOCKET = IS_WINDOWS and 0xffff or 1
local SO_REUSEADDR = 2 -- POSIX only; Windows must not use it, see probe_port_windows
local WSAEADDRINUSE = 10048
local EADDRINUSE = 98

local winsock_ready = false
local function init_winsock()
    if winsock_ready then
        return true
    end

    local wsadata = ffi.new("WSADATA")
    local code = winsock.WSAStartup(0x0202, wsadata)
    if code ~= 0 then
        return false, string.format("WSAStartup failed with error %d", code)
    end

    winsock_ready = true
    return true
end

-- struct sockaddr_in (16 bytes) for 127.0.0.1, in network byte order.
local function build_loopback_sockaddr(port, convert_port)
    local raw_addr = ffi.new("uint8_t[16]")
    ffi.cast("uint16_t*", raw_addr)[0] = AF_INET
    ffi.cast("uint16_t*", raw_addr + 2)[0] = convert_port(port)
    ffi.cast("uint32_t*", raw_addr + 4)[0] = 0x0100007F
    return raw_addr
end

-- A probe socket must NOT set SO_REUSEADDR on Windows: there the flag lets bind
-- succeed on a port another process already listens on, so every occupied port
-- would be reported as free.
local function probe_port_windows(port)
    local ready, ready_error = init_winsock()
    if not ready then
        return false, ready_error
    end

    local sock = winsock.socket(AF_INET, SOCK_STREAM, 0)
    if sock == ffi.cast("SOCKET", -1) then
        return false, string.format("socket() failed with error %d", winsock.WSAGetLastError())
    end

    local addr = build_loopback_sockaddr(port, winsock.htons)
    local result = winsock.bind(sock, ffi.cast("const struct sockaddr*", addr), 16)
    local bind_error = (result == 0) and 0 or winsock.WSAGetLastError()
    winsock.closesocket(sock)

    if result == 0 then
        return true
    end

    if bind_error == WSAEADDRINUSE then
        return false
    end

    return false, string.format("bind() failed with error %d", bind_error)
end

-- SO_REUSEADDR is harmless here: it ignores TIME_WAIT remnants (which ssh can
-- reuse too) but never hides a live listener.
local function probe_port_posix(port)
    local sock = ffi.C.socket(AF_INET, SOCK_STREAM, 0)
    if sock < 0 then
        return false, "socket() failed"
    end

    local reuse = ffi.new("int[1]", 1)
    ffi.C.setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, reuse, ffi.sizeof("int"))

    local addr = build_loopback_sockaddr(port, ffi.C.htons)
    local result = ffi.C.bind(sock, ffi.cast("const void*", addr), 16)
    local bind_errno = (result == 0) and 0 or ffi.errno()
    ffi.C.close(sock)

    if result == 0 then
        return true
    end

    if bind_errno == EADDRINUSE then
        return false
    end

    return false, string.format("bind() failed with errno %d", bind_errno)
end

-- Returns true when free, false with no message when occupied, and false plus a
-- diagnostic when the probe itself could not run.
local function is_port_free(port)
    port = tonumber(port)
    if not port or port < 1 or port > 65535 then
        return false, string.format("invalid port %s", tostring(port))
    end

    if IS_WINDOWS then
        return probe_port_windows(port)
    end

    return probe_port_posix(port)
end

-- Finds the next free port, or nil plus a diagnostic when probing fails.
local function find_next_free_port(base_port)
    base_port = tonumber(base_port) or 8080
    local last_candidate = math.min(base_port + 100, 65535)

    for candidate = base_port, last_candidate do
        local free, probe_error = is_port_free(candidate)
        if free then
            return candidate
        end

        if probe_error then
            return nil, probe_error
        end
    end

    return nil
end

--------------------------------------------------------------------------------
-- Process Liveness, Identity & Termination via FFI
--------------------------------------------------------------------------------
local PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
local SYNCHRONIZE = 0x00100000
local PROCESS_TERMINATE = 0x0001
local STILL_ACTIVE = 259
local EPERM = 1

local function is_process_alive(pid)
    pid = tonumber(pid)
    if not pid or pid <= 0 then
        return false
    end

    if IS_WINDOWS then
        local handle = ffi.C.OpenProcess(bit.bor(PROCESS_QUERY_LIMITED_INFORMATION, SYNCHRONIZE), 0, pid)
        if handle == nil or handle == ffi.cast("HANDLE", 0) then
            return false
        end

        local code = ffi.new("DWORD[1]")
        local alive = false
        if ffi.C.GetExitCodeProcess(handle, code) ~= 0 then
            alive = (code[0] == STILL_ACTIVE)
        end
        ffi.C.CloseHandle(handle)
        return alive
    end

    -- Signal 0 tests existence; EPERM still means "running, owned by someone else".
    if ffi.C.kill(pid, 0) == 0 then
        return true
    end

    return ffi.errno() == EPERM
end

local function read_file_head(path, limit)
    local handle = io.open(path, "rb")
    if not handle then
        return nil
    end

    local content = handle:read(limit or 4096) or ""
    handle:close()
    return content
end

local function windows_process_image(pid)
    local handle = ffi.C.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid)
    if handle == nil or handle == ffi.cast("HANDLE", 0) then
        return nil
    end

    local buffer = ffi.new("uint16_t[260]")
    local size = ffi.new("DWORD[1]", 260)
    local ok = ffi.C.QueryFullProcessImageNameW(handle, 0, buffer, size)
    ffi.C.CloseHandle(handle)
    if ok == 0 or size[0] == 0 then
        return nil
    end

    -- The path is UTF-16LE; these are executable paths, so low bytes suffice.
    local characters = {}
    for index = 0, size[0] - 1 do
        local code = buffer[index]
        if code == 0 then
            break
        end
        characters[#characters + 1] = string.char(code < 128 and code or 63)
    end

    return table.concat(characters)
end

local function posix_process_cmdline(pid)
    local content = read_file_head(string.format("/proc/%d/cmdline", pid), 8192)
    if content and content ~= "" then
        return (content:gsub("%z", " "))
    end

    -- macOS and the BSDs have no /proc; ask ps instead.
    local pipe = io.popen(string.format("ps -o command= -p %d 2>/dev/null", pid))
    if not pipe then
        return nil
    end

    local line = pipe:read("*l")
    pipe:close()
    return line
end

-- Identifies one specific process instance, not just a PID: a recycled PID has
-- a different start time, which is what makes --kill safe against reuse.
local function process_start_token(pid)
    if IS_WINDOWS then
        local handle = ffi.C.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid)
        if handle == nil or handle == ffi.cast("HANDLE", 0) then
            return nil
        end

        local creation = ffi.new("FILETIME")
        local exit_time = ffi.new("FILETIME")
        local kernel_time = ffi.new("FILETIME")
        local user_time = ffi.new("FILETIME")
        local ok = ffi.C.GetProcessTimes(handle, creation, exit_time, kernel_time, user_time)
        ffi.C.CloseHandle(handle)
        if ok == 0 then
            return nil
        end

        -- Hex keeps the full 64-bit timestamp exact; a Lua number would round it.
        return string.format("%08x%08x", creation.dwHighDateTime, creation.dwLowDateTime)
    end

    local stat = read_file_head(string.format("/proc/%d/stat", pid), 1024)
    if stat then
        local fields = stat:match(".*%)%s*(.*)$")
        if fields then
            local index = 0
            for token in fields:gmatch("%S+") do
                index = index + 1
                if index == 20 then -- starttime is field 22 of the whole line
                    return token
                end
            end
        end
        return nil
    end

    -- macOS and the BSDs: ps has no /proc equivalent.
    local pipe = io.popen(string.format("ps -o lstart= -p %d 2>/dev/null", pid))
    if not pipe then
        return nil
    end

    local line = pipe:read("*l")
    pipe:close()
    return line
end

-- Returns "ssh", another executable name, or nil when it cannot be determined.
local function process_image_name(pid)
    if IS_WINDOWS then
        local path = windows_process_image(pid)
        if not path then
            return nil
        end
        return path:match("([^/\\]+)$") or path
    end

    local cmdline = posix_process_cmdline(pid)
    if not cmdline or cmdline == "" then
        return nil
    end

    local command = cmdline:match("^%s*(%S+)") or cmdline
    return command:match("([^/\\]+)$") or command
end

local function is_ssh_image(image_name)
    if not image_name then
        return false
    end

    local name = image_name:lower()
    return name == "ssh" or name == "ssh.exe"
end

-- "active"     - alive and unmistakably our ssh tunnel
-- "unverified" - alive, but the executable cannot be inspected (permissions)
-- "foreign"    - alive, but not the ssh process recorded here (recycled PID)
-- "dead"       - no such process
local function classify_tunnel_process(entry)
    local pid = tonumber(entry and entry.pid) or 0
    if not is_process_alive(pid) then
        return "dead"
    end

    local image_name = process_image_name(pid)
    if not image_name then
        return "unverified"
    end

    if not is_ssh_image(image_name) then
        return "foreign"
    end

    -- The recorded start time rejects a recycled PID that now runs some other
    -- ssh session.
    if entry.start_time and entry.start_time ~= "" then
        local current_start = process_start_token(pid)
        if current_start and current_start ~= entry.start_time then
            return "foreign"
        end
    end

    -- A matching forward spec rejects ssh sessions that are not this tunnel.
    if not IS_WINDOWS and entry.spec and entry.spec ~= "" then
        local cmdline = posix_process_cmdline(pid)
        if cmdline and not cmdline:find(entry.spec, 1, true) then
            return "foreign"
        end
    end

    return "active"
end

local function kill_process(pid)
    pid = tonumber(pid)
    if not pid or pid <= 0 then
        return false
    end

    if IS_WINDOWS then
        local handle = ffi.C.OpenProcess(PROCESS_TERMINATE, 0, pid)
        if handle == nil or handle == ffi.cast("HANDLE", 0) then
            return false
        end

        local result = ffi.C.TerminateProcess(handle, 1)
        ffi.C.CloseHandle(handle)
        return result ~= 0
    end

    return (ffi.C.kill(pid, 15) == 0) or (ffi.C.kill(pid, 9) == 0)
end

--------------------------------------------------------------------------------
-- Presets
--------------------------------------------------------------------------------
local PRESETS = {
    jupyter = {
        name = "Jupyter Lab / Notebook",
        mode = "L",
        local_port = 8888,
        remote_host = "127.0.0.1",
        remote_port = 8888,
        desc = "Web browser at http://localhost:8888",
    },
    tensorboard = {
        name = "TensorBoard",
        mode = "L",
        local_port = 6006,
        remote_host = "127.0.0.1",
        remote_port = 6006,
        desc = "Web browser at http://localhost:6006",
    },
    postgres = {
        name = "PostgreSQL Database",
        mode = "L",
        local_port = 5432,
        remote_host = "127.0.0.1",
        remote_port = 5432,
        desc = "psql -h localhost -p 5432",
    },
    mysql = {
        name = "MySQL / MariaDB",
        mode = "L",
        local_port = 3306,
        remote_host = "127.0.0.1",
        remote_port = 3306,
        desc = "mysql -h 127.0.0.1 -P 3306",
    },
    redis = {
        name = "Redis Cache",
        mode = "L",
        local_port = 6379,
        remote_host = "127.0.0.1",
        remote_port = 6379,
        desc = "redis-cli -p 6379",
    },
    codeserver = {
        name = "code-server (VS Code in Browser)",
        mode = "L",
        local_port = 8080,
        remote_host = "127.0.0.1",
        remote_port = 8080,
        desc = "Web browser at http://localhost:8080",
    },
    vnc = {
        name = "VNC Remote Desktop",
        mode = "L",
        local_port = 5901,
        remote_host = "127.0.0.1",
        remote_port = 5901,
        desc = "VNC client connecting to localhost:5901",
    },
    socks = {
        name = "Dynamic SOCKS5 Proxy",
        mode = "D",
        local_port = 1080,
        desc = "Configure browser/proxy to socks5://127.0.0.1:1080",
    },
}

local PRESET_ORDER = {
    "jupyter", "tensorboard", "postgres", "mysql", "redis", "codeserver", "vnc", "socks",
}

--------------------------------------------------------------------------------
-- Host Discovery (SSH Config, PuTTY Registry, Hosts)
--------------------------------------------------------------------------------
local function get_home()
    return os.getenv("HOME") or os.getenv("USERPROFILE") or "/root"
end

local function parse_ssh_config(path)
    local hosts = {}
    local f = io.open(path, "r")
    if not f then return hosts end

    -- Directives apply to every pattern on the Host line, not just the last.
    local current_entries = {}
    for line in f:lines() do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed ~= "" and not trimmed:match("^#") then
            local key, value = trimmed:match("^(%S+)%s+(.*)$")
            if key then
                key = key:lower()
                if key == "host" then
                    current_entries = {}
                    for pattern in value:gmatch("%S+") do
                        if not pattern:match("[%*%?]") then
                            local entry = { name = pattern, source = "ssh_config", hostname = pattern }
                            hosts[#hosts + 1] = entry
                            current_entries[#current_entries + 1] = entry
                        end
                    end
                else
                    for _, entry in ipairs(current_entries) do
                        if key == "hostname" then
                            entry.hostname = value
                        elseif key == "user" then
                            entry.user = value
                        elseif key == "port" then
                            entry.port = tonumber(value)
                        end
                    end
                end
            end
        end
    end
    f:close()
    return hosts
end

local function parse_known_hosts(path)
    local hosts = {}
    local f = io.open(path, "r")
    if not f then return hosts end

    for line in f:lines() do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed ~= "" and not trimmed:match("^#") and not trimmed:match("^|1|") then
            local entry = trimmed:match("^(%S+)")
            if entry then
                for h in entry:gmatch("[^,]+") do
                    local clean = h:match("^%[(.-)%]:%d+$") or h
                    if clean ~= "" and not clean:match("^%d+%.%d+%.%d+%.%d+$") then
                        table.insert(hosts, { name = clean, hostname = clean, source = "known_hosts" })
                    end
                end
            end
        end
    end
    f:close()
    return hosts
end

local function parse_putty_sessions()
    local hosts = {}
    if not IS_WINDOWS then return hosts end

    local HKEY_CURRENT_USER = ffi.cast("HKEY", 0x80000001)
    local KEY_READ = 0x20019
    local phkResult = ffi.new("HKEY[1]")
    local subkey = "Software\\SimonTatham\\PuTTY\\Sessions"

    if ffi.C.RegOpenKeyExA(HKEY_CURRENT_USER, subkey, 0, KEY_READ, phkResult) == 0 then
        local hKey = phkResult[0]
        local dwIndex = 0
        local nameBuf = ffi.new("char[260]")
        local nameLen = ffi.new("DWORD[1]")

        while true do
            nameLen[0] = 260
            local res = ffi.C.RegEnumKeyExA(hKey, dwIndex, nameBuf, nameLen, nil, nil, nil, nil)
            if res ~= 0 then break end

            local session_raw = ffi.string(nameBuf, nameLen[0])
            local session_name = session_raw:gsub("%%20", " ")
            if session_name ~= "Default%20Settings" and session_name ~= "Default Settings" then
                -- Query HostName from inside this session key
                local sessionHKey = ffi.new("HKEY[1]")
                local sessionSubkey = subkey .. "\\" .. session_raw
                local host_name = session_name
                local user_name = nil

                if ffi.C.RegOpenKeyExA(HKEY_CURRENT_USER, sessionSubkey, 0, KEY_READ, sessionHKey) == 0 then
                    local dataBuf = ffi.new("BYTE[260]")
                    local dataLen = ffi.new("DWORD[1]")
                    dataLen[0] = 260
                    if ffi.C.RegQueryValueExA(sessionHKey[0], "HostName", nil, nil, dataBuf, dataLen) == 0 and dataLen[0] > 1 then
                        local hval = ffi.string(dataBuf, dataLen[0] - 1)
                        if hval ~= "" then host_name = hval end
                    end
                    dataLen[0] = 260
                    if ffi.C.RegQueryValueExA(sessionHKey[0], "UserName", nil, nil, dataBuf, dataLen) == 0 and dataLen[0] > 1 then
                        local uval = ffi.string(dataBuf, dataLen[0] - 1)
                        if uval ~= "" then user_name = uval end
                    end
                    ffi.C.RegCloseKey(sessionHKey[0])
                end

                table.insert(hosts, {
                    name = session_name,
                    hostname = host_name,
                    user = user_name,
                    source = "putty",
                })
            end
            dwIndex = dwIndex + 1
        end
        ffi.C.RegCloseKey(hKey)
    end
    return hosts
end

local function get_all_hosts()
    local seen = {}
    local result = {}
    local home = get_home()

    -- Built without nil holes: ipairs stops at the first nil, which used to
    -- skip /etc/ssh/ssh_config on Linux.
    local files = { home .. "/.ssh/config" }
    local profile = os.getenv("USERPROFILE")
    if IS_WINDOWS and profile and profile ~= "" then
        files[#files + 1] = profile .. "/.ssh/config"
    end
    files[#files + 1] = "/etc/ssh/ssh_config"

    for _, path in ipairs(files) do
        for _, host_entry in ipairs(parse_ssh_config(path)) do
            if not seen[host_entry.name] then
                seen[host_entry.name] = true
                result[#result + 1] = host_entry
            end
        end
    end

    for _, h in ipairs(parse_putty_sessions()) do
        if not seen[h.name] then
            seen[h.name] = true
            table.insert(result, h)
        end
    end

    local kh_files = { home .. "/.ssh/known_hosts" }
    if profile and profile ~= "" then
        kh_files[#kh_files + 1] = profile .. "/.ssh/known_hosts"
    end

    for _, path in ipairs(kh_files) do
        for _, h in ipairs(parse_known_hosts(path)) do
            if not seen[h.name] then
                seen[h.name] = true
                table.insert(result, h)
            end
        end
    end

    return result
end

--------------------------------------------------------------------------------
-- Registry Store for Active Tunnels (~/.ssh/.fssh_tunnels.json)
--------------------------------------------------------------------------------
local registry_path_override = nil -- tests point this at a temp file
local TUNNEL_FIELDS = {
    "pid", "host", "mode", "local_port", "remote_host", "remote_port",
    "spec", "started_at", "start_time", "desc",
}
local NUMBER_FIELDS = { pid = true, local_port = true, remote_port = true }

local function get_registry_path()
    if registry_path_override then
        return registry_path_override
    end

    return get_home() .. "/.ssh/.fssh_tunnels.json"
end

local JSON_ESCAPES = {
    ['"'] = '\\"',
    ["\\"] = "\\\\",
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
}

local function json_escape(text)
    return (tostring(text):gsub('[%z\1-\31\\"]', function(character)
        return JSON_ESCAPES[character] or string.format("\\u%04x", character:byte())
    end))
end

-- One registry object. JSON escaping is used instead of Lua's %q, whose
-- \9-style control escapes are not valid JSON.
local function serialize_tunnel(tunnel)
    local fields = {}
    for _, key in ipairs(TUNNEL_FIELDS) do
        local value = tunnel[key]
        if NUMBER_FIELDS[key] then
            fields[#fields + 1] = string.format('"%s": %d', key, tonumber(value) or 0)
        else
            fields[#fields + 1] = string.format('"%s": "%s"', key, json_escape(value or ""))
        end
    end

    return "  {" .. table.concat(fields, ", ") .. "}"
end

local function serialize_json(list)
    if #list == 0 then
        return "[]"
    end

    local objects = {}
    for _, tunnel in ipairs(list) do
        objects[#objects + 1] = serialize_tunnel(tunnel)
    end

    return "[\n" .. table.concat(objects, ",\n") .. "\n]"
end

--------------------------------------------------------------------------------
-- Minimal RFC 8259 JSON Reader
--------------------------------------------------------------------------------
local json_reader = {}
json_reader.__index = json_reader

local function new_json_reader(text)
    return setmetatable({ text = text, position = 1, length = #text }, json_reader)
end

function json_reader:skip_whitespace()
    while self.position <= self.length do
        local character = self.text:sub(self.position, self.position)
        if character ~= " " and character ~= "\t" and character ~= "\n" and character ~= "\r" then
            return
        end

        self.position = self.position + 1
    end
end

function json_reader:fail(message)
    local line = 1
    for _ in self.text:sub(1, self.position):gmatch("\n") do
        line = line + 1
    end

    error(string.format("%s at line %d (offset %d)", message, line, self.position), 0)
end

function json_reader:peek()
    return self.text:sub(self.position, self.position)
end

function json_reader:decode_hex4()
    local digits = self.text:sub(self.position, self.position + 3)
    if not digits:match("^%x%x%x%x$") then
        self:fail("invalid \\u escape")
    end

    self.position = self.position + 4
    return tonumber(digits, 16)
end

local function utf8_encode(code_point)
    if code_point < 0x80 then
        return string.char(code_point)
    end

    if code_point < 0x800 then
        return string.char(
            0xC0 + math.floor(code_point / 0x40),
            0x80 + code_point % 0x40)
    end

    return string.char(
        0xE0 + math.floor(code_point / 0x1000),
        0x80 + math.floor(code_point / 0x40) % 0x40,
        0x80 + code_point % 0x40)
end

function json_reader:parse_string()
    self.position = self.position + 1 -- opening quote
    local pieces = {}

    while true do
        if self.position > self.length then
            self:fail("unterminated string")
        end

        local character = self:peek()
        self.position = self.position + 1

        if character == '"' then
            return table.concat(pieces)
        end

        if character ~= "\\" then
            pieces[#pieces + 1] = character
        else
            local escape = self:peek()
            self.position = self.position + 1
            if escape == '"' or escape == "\\" or escape == "/" then
                pieces[#pieces + 1] = escape
            elseif escape == "b" then
                pieces[#pieces + 1] = "\b"
            elseif escape == "f" then
                pieces[#pieces + 1] = "\f"
            elseif escape == "n" then
                pieces[#pieces + 1] = "\n"
            elseif escape == "r" then
                pieces[#pieces + 1] = "\r"
            elseif escape == "t" then
                pieces[#pieces + 1] = "\t"
            elseif escape == "u" then
                local code_point = self:decode_hex4()
                local low_marker = self.text:sub(self.position, self.position + 1)
                if code_point >= 0xD800 and code_point <= 0xDBFF and low_marker == "\\u" then
                    self.position = self.position + 2
                    local low = self:decode_hex4()
                    code_point = 0x10000 + (code_point - 0xD800) * 0x400 + (low - 0xDC00)
                end
                pieces[#pieces + 1] = utf8_encode(code_point)
            else
                self:fail("invalid escape sequence")
            end
        end
    end
end

function json_reader:parse_number()
    local start = self.position
    while self.position <= self.length do
        if not self:peek():match("^[-%d%.eE+]") then
            break
        end
        self.position = self.position + 1
    end

    local literal = self.text:sub(start, self.position - 1)
    local value = tonumber(literal)
    if not value then
        self:fail(string.format("invalid number '%s'", literal))
    end

    return value
end

function json_reader:parse_array()
    self.position = self.position + 1 -- opening bracket
    local items = {}
    self:skip_whitespace()

    if self:peek() == "]" then
        self.position = self.position + 1
        return items
    end

    while true do
        items[#items + 1] = self:parse_value()
        self:skip_whitespace()

        local character = self:peek()
        self.position = self.position + 1
        if character == "]" then
            return items
        end

        if character ~= "," then
            self:fail("expected ',' or ']' in array")
        end

        self:skip_whitespace()
    end
end

function json_reader:parse_object()
    self.position = self.position + 1 -- opening brace
    local object = {}
    self:skip_whitespace()

    if self:peek() == "}" then
        self.position = self.position + 1
        return object
    end

    while true do
        if self:peek() ~= '"' then
            self:fail("expected a quoted key")
        end

        local key = self:parse_string()
        self:skip_whitespace()

        if self:peek() ~= ":" then
            self:fail("expected ':' after key")
        end

        self.position = self.position + 1
        self:skip_whitespace()
        object[key] = self:parse_value()
        self:skip_whitespace()

        local character = self:peek()
        self.position = self.position + 1
        if character == "}" then
            return object
        end

        if character ~= "," then
            self:fail("expected ',' or '}' in object")
        end

        self:skip_whitespace()
    end
end

function json_reader:parse_value()
    self:skip_whitespace()
    local character = self:peek()

    if character == "{" then
        return self:parse_object()
    end
    if character == "[" then
        return self:parse_array()
    end
    if character == '"' then
        return self:parse_string()
    end
    if character == "" then
        self:fail("unexpected end of input")
    end
    if self.text:sub(self.position, self.position + 3) == "true" then
        self.position = self.position + 4
        return true
    end
    if self.text:sub(self.position, self.position + 4) == "false" then
        self.position = self.position + 5
        return false
    end
    if self.text:sub(self.position, self.position + 3) == "null" then
        self.position = self.position + 4
        return nil
    end

    return self:parse_number()
end

-- Returns the decoded list, plus a parse error string when the content is bad.
local function deserialize_json(content)
    if not content or content == "" then
        return {}
    end

    local reader = new_json_reader(content)
    local ok, decoded = pcall(function()
        local value = reader:parse_value()
        reader:skip_whitespace()
        if reader.position <= reader.length then
            reader:fail("trailing data after the JSON value")
        end
        return value
    end)

    if not ok then
        return {}, tostring(decoded)
    end

    if type(decoded) ~= "table" then
        return {}, "registry must be a JSON array of tunnel objects"
    end

    local items = {}
    for _, raw_entry in ipairs(decoded) do
        if type(raw_entry) == "table" and tonumber(raw_entry.pid) then
            local entry = {}
            for _, key in ipairs(TUNNEL_FIELDS) do
                if NUMBER_FIELDS[key] then
                    entry[key] = tonumber(raw_entry[key]) or 0
                else
                    entry[key] = (raw_entry[key] ~= nil) and tostring(raw_entry[key]) or ""
                end
            end
            items[#items + 1] = entry
        end
    end

    return items
end

local function ensure_directory(path)
    if IS_WINDOWS then
        local windows_path = path:gsub("/", "\\")
        os.execute(string.format('if not exist "%s" mkdir "%s"', windows_path, windows_path))
        return
    end

    os.execute(string.format("mkdir -p %s 2>/dev/null", shell_quote(path)))
end

-- Replaces the registry atomically: write a temp file, then rename it into place.
local function write_registry(list)
    local path = get_registry_path()
    local directory = path:match("^(.*)[/\\][^/\\]*$")
    if directory then
        ensure_directory(directory)
    end

    local temporary_path = path .. ".tmp"
    local handle, open_error = io.open(temporary_path, "wb")
    if not handle then
        return false, string.format("cannot write %s (%s)", temporary_path, tostring(open_error))
    end

    local written, write_error = handle:write(serialize_json(list) .. "\n")
    handle:close()
    if not written then
        os.remove(temporary_path)
        return false, string.format("cannot write %s (%s)", temporary_path, tostring(write_error))
    end

    os.remove(path) -- Windows will not rename onto an existing file
    local renamed, rename_error = os.rename(temporary_path, path)
    if not renamed then
        return false, string.format("cannot replace %s (%s)", path, tostring(rename_error))
    end

    return true
end

local function load_active_tunnels(clean_stale)
    local path = get_registry_path()
    local handle = io.open(path, "rb")
    if not handle then
        return {}
    end

    local content = handle:read("*a") or ""
    handle:close()

    local entries, parse_error = deserialize_json(content)
    if parse_error then
        warn(string.format("%s is not valid JSON (%s); treating it as an empty list", path, parse_error))
    end

    local active = {}
    local stale_count = 0

    for _, entry in ipairs(entries) do
        local state = classify_tunnel_process(entry)
        if state == "active" then
            active[#active + 1] = entry
        elseif state == "unverified" then
            entry.unverified = true
            active[#active + 1] = entry
        else
            stale_count = stale_count + 1
        end
    end

    if clean_stale and stale_count > 0 then
        local saved, save_error = write_registry(active)
        if not saved then
            warn(string.format("dropped %d stale tunnel record(s) but could not update the registry: %s",
                stale_count, save_error))
        end
    end

    return active
end

local function save_tunnel_entry(entry)
    local list = load_active_tunnels(true)
    list[#list + 1] = entry

    return write_registry(list)
end

local function remove_tunnel_entry(pid)
    local list = load_active_tunnels(false)
    local updated = {}
    for _, tunnel in ipairs(list) do
        if tunnel.pid ~= pid then
            updated[#updated + 1] = tunnel
        end
    end

    return write_registry(updated)
end

--------------------------------------------------------------------------------
-- CLI Commands & Actions
--------------------------------------------------------------------------------
local function tunnel_line(tunnel)
    local local_side = string.format("127.0.0.1:%d", tunnel.local_port or 0)
    local remote_side
    if tunnel.mode == "D" then
        remote_side = "SOCKS5 Proxy"
    else
        remote_side = string.format("%s:%d", tunnel.remote_host or "127.0.0.1", tunnel.remote_port or 0)
    end

    return string.format("%d\t%s\t-%s\t%s\t%s\t%s",
        tunnel.pid, tunnel.host, tunnel.mode, local_side, remote_side, tunnel.started_at or "")
end

local function print_active_lines()
    for _, tunnel in ipairs(load_active_tunnels(true)) do
        print(tunnel_line(tunnel))
    end
end

local function print_active_tunnels(as_json)
    local tunnels = load_active_tunnels(true)
    if as_json then
        print(serialize_json(tunnels))
        return
    end

    if #tunnels == 0 then
        local message = string.format("No active SSH tunnels registered in %s", get_registry_path())
        print(string.format("%s[INFO]%s %s", C.yellow, C.reset, message))
        return
    end

    local border = string.format("%s+-------+--------------------+------+-------------------+-------------------+---------------------+%s",
        C.dim, C.reset)
    print(string.format("\n%s%sACTIVE SSH TUNNELS%s", C.bold, C.cyan, C.reset))
    print(border)
    print(string.format("%s| %-5s | %-18s | %-4s | %-17s | %-17s | %-19s |%s",
        C.bold, "PID", "HOST", "MODE", "LOCAL SIDE", "REMOTE SIDE", "STARTED AT", C.reset))
    print(border)

    for _, tunnel in ipairs(tunnels) do
        local local_side = string.format("127.0.0.1:%d", tunnel.local_port or 0)
        local remote_side
        if tunnel.mode == "D" then
            remote_side = "SOCKS5 Proxy"
        else
            remote_side = string.format("%s:%d", tunnel.remote_host or "127.0.0.1", tunnel.remote_port or 0)
        end

        -- Flag rows whose process could not be inspected, so a recycled PID is
        -- never mistaken for a verified tunnel.
        local host_label = tunnel.host
        if tunnel.unverified then
            host_label = host_label .. " (?)"
        end

        print(string.format("| %s%-5d%s | %-18.18s | %s%-4s%s | %-17.17s | %-17.17s | %-19.19s |",
            C.green, tunnel.pid, C.reset,
            host_label,
            C.yellow, string.format("-%s", tunnel.mode), C.reset,
            local_side,
            remote_side,
            tunnel.started_at ~= "" and tunnel.started_at or "-"))
    end

    print(border)
    print(string.format("Total: %d active tunnel(s). Run %s'fssh_tunnel -k <PID>'%s to stop a tunnel.\n",
        #tunnels, C.bold, C.reset))
end

-- Refuses to signal anything that is not the ssh process recorded here.
local function terminate_tunnel(entry)
    local state = classify_tunnel_process(entry)
    if state == "unverified" then
        fail(string.format("PID %d cannot be inspected (permission denied), so it is not killed. "
            .. "Stop it manually if it is yours.", entry.pid))
        return false
    end

    if state ~= "active" then
        local image_name = process_image_name(entry.pid) or "not running"
        fail(string.format("PID %d is %s, not the ssh tunnel for %s; refusing to kill it. "
            .. "Use 'fkill' to manage other processes.", entry.pid, image_name, entry.host))
        return false
    end

    if not kill_process(entry.pid) then
        fail(string.format("PID %d could not be terminated (it may have exited or belong to another user).",
            entry.pid))
        return false
    end

    print(string.format("✔ Terminated tunnel [PID: %d, Host: %s, Port: %d]",
        entry.pid, entry.host, entry.local_port or 0))

    local saved, save_error = remove_tunnel_entry(entry.pid)
    if not saved then
        warn(string.format("the tunnel stopped, but its registry entry could not be removed: %s", save_error))
    end

    return true
end

local function kill_tunnels(target, assume_yes)
    local tunnels = load_active_tunnels(true)
    if target == "all" and #tunnels == 0 then
        print("No active tunnels found to kill.")
        return true
    end

    local victims = {}
    if target == "all" then
        if not assume_yes then
            if not is_interactive_stdin() then
                fail("--kill all needs confirmation; re-run with --yes in a script.")
                return false
            end

            io.write(string.format("Terminate %d tunnel(s)? [y/N]: ", #tunnels))
            local answer = read_line()
            if not answer:lower():match("^y") then
                print("Aborted.")
                return false
            end
        end

        victims = tunnels
    else
        local pid = tonumber(target)
        if not pid then
            fail(string.format("Invalid PID: %s", tostring(target)))
            return false
        end

        for _, tunnel in ipairs(tunnels) do
            if tunnel.pid == pid then
                victims[1] = tunnel
                break
            end
        end

        if #victims == 0 then
            if not is_process_alive(pid) then
                fail(string.format("PID %d is not running.", pid))
                remove_tunnel_entry(pid)
                return false
            end

            fail(string.format("PID %d (%s) is not a registered tunnel; refusing to kill it. "
                .. "Use 'fkill' to manage other processes.", pid, process_image_name(pid) or "unknown"))
            return false
        end
    end

    local killed = 0
    for _, victim in ipairs(victims) do
        if terminate_tunnel(victim) then
            killed = killed + 1
        end
    end

    if target == "all" then
        print(string.format("Done. %d tunnel(s) killed.", killed))
    end

    return killed > 0
end

--------------------------------------------------------------------------------
-- Interactive Tunnel Manager (FZF)
--------------------------------------------------------------------------------
local function fzf_available()
    local pipe = io.popen(IS_WINDOWS and "where fzf 2>nul" or "command -v fzf 2>/dev/null")
    if not pipe then
        return false
    end

    local found = pipe:read("*l")
    pipe:close()
    return found ~= nil and found ~= ""
end

local function get_temporary_path(prefix)
    local directory = os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
    directory = directory:gsub("[/\\]+$", "")
    return string.format("%s/%s_%d_%04d.txt", directory, prefix, os.time(), math.random(0, 9999))
end

-- fzf reads its candidates from a file by redirection: both shells handle
-- `< file`, while cmd.exe's `type` fails under _popen and leaves fzf showing an
-- empty list. Every fzf call must go through here.
local function build_fzf_command(list_path, prompt, visible_fields, header)
    local parts = {
        "fzf",
        string.format("--delimiter=%s", shell_quote("\t")),
        string.format("--with-nth=%s", visible_fields),
        string.format("--prompt=%s", shell_quote(prompt)),
    }

    if header then
        parts[#parts + 1] = string.format("--header=%s", shell_quote(header))
    end

    parts[#parts + 1] = string.format("< %s", shell_quote(list_path))
    return table.concat(parts, " ")
end

local function build_manager_command(list_path)
    return build_fzf_command(list_path, "Tunnel > ", "1,2,3,4,5,6",
        "[ACTIVE SSH TUNNELS] ENTER: Inspect | ESC: Exit")
end

local function open_local_endpoint(port)
    if not port or port <= 0 then
        fail("this tunnel has no local port to open.")
        return false
    end

    local url = string.format("http://localhost:%d", port)
    print(string.format("Opening %s ...", url))

    local command
    if IS_WINDOWS then
        command = string.format('start "" %s', shell_quote(url))
    elseif IS_OSX then
        command = string.format("open %s", shell_quote(url))
    else
        command = string.format("xdg-open %s >/dev/null 2>&1 &", shell_quote(url))
    end

    os.execute(command)
    return true
end

local function run_interactive_manager()
    local tunnels = load_active_tunnels(true)
    if #tunnels == 0 then
        print(string.format("%s[INFO]%s No active SSH tunnels running.", C.yellow, C.reset))
        return true
    end

    if not fzf_available() then
        fail("fzf is required for --manage but was not found on PATH. "
            .. "Install fzf, or use '--list', '--kill <PID>' and '--lines' instead.")
        return false
    end

    if not is_interactive_terminal() then
        fail("--manage needs an interactive terminal. "
            .. "Use '--lines' for scripting or '--kill <PID>' to stop a tunnel.")
        return false
    end

    local lines = {}
    for _, tunnel in ipairs(tunnels) do
        lines[#lines + 1] = tunnel_line(tunnel)
    end

    local temporary_path = get_temporary_path("fssh_tunnels")
    local handle = io.open(temporary_path, "wb")
    if not handle then
        fail(string.format("cannot create a temporary tunnel list at %s", temporary_path))
        return false
    end

    handle:write(table.concat(lines, "\n") .. "\n")
    handle:close()

    local command = build_manager_command(temporary_path)

    local pipe = io.popen(command)
    if not pipe then
        os.remove(temporary_path)
        fail("could not start fzf.")
        return false
    end

    local selected = pipe:read("*l")
    pipe:close()
    os.remove(temporary_path)

    if not selected or selected == "" then
        return true
    end

    local pid = tonumber(selected:match("^(%d+)"))
    if not pid then
        fail(string.format("could not read a PID from the fzf selection: %s", selected))
        return false
    end

    for _, tunnel in ipairs(tunnels) do
        if tunnel.pid == pid then
            print(string.format("\nTunnel PID %d (%s, local %d)", pid, tunnel.host, tunnel.local_port or 0))
            print("  [1] Open the local endpoint in a browser")
            print("  [2] Kill the tunnel")
            print("  [3] Cancel")
            io.write("Select option [1-3]: ")

            local option = read_line()
            if option == "1" then
                return open_local_endpoint(tunnel.local_port)
            end
            if option == "2" then
                return kill_tunnels(pid, true)
            end
            return true
        end
    end

    fail(string.format("PID %d is no longer registered; nothing to do.", pid))
    return false
end--------------------------------------------------------------------------------
-- Tunnel Launcher Execution
--------------------------------------------------------------------------------
-- Pure helpers, covered by the --test suite.
local function build_forward_spec(mode, local_port, remote_host, remote_port)
    if mode == "D" then
        return tostring(local_port)
    end

    if mode == "R" then
        -- The remote side binds remote_port and dials back to local_port.
        return string.format("%d:%s:%d", remote_port, remote_host, local_port)
    end

    return string.format("%d:%s:%d", local_port, remote_host, remote_port)
end

local function build_ssh_arguments(params)
    local mode = params.mode or "L"
    local local_port = tonumber(params.local_port)
    local remote_host = params.remote_host or "127.0.0.1"
    local remote_port = tonumber(params.remote_port)
    local spec = build_forward_spec(mode, local_port, remote_host, remote_port)

    local arguments = { "ssh" }
    if params.background ~= false then
        table.insert(arguments, "-f") -- go to the background before running
        table.insert(arguments, "-N") -- no remote command
    end

    table.insert(arguments, "-o ExitOnForwardFailure=yes")
    table.insert(arguments, "-o ServerAliveInterval=60")
    table.insert(arguments, "-o ServerAliveCountMax=3")
    table.insert(arguments, string.format("-%s %s", mode, spec))
    table.insert(arguments, params.host)

    return table.concat(arguments, " "), spec
end

local function exit_code_from_status(status)
    if status == true then
        return 0
    end
    if status == false then
        return 1
    end

    local raw = tonumber(status) or 1
    if IS_WINDOWS or raw < 256 then
        return raw
    end

    -- POSIX os.execute returns a wait status; report the exit code inside it.
    local exit_code = math.floor(raw / 256) % 256
    if exit_code ~= 0 then
        return exit_code
    end

    return raw
end

local function list_ssh_pids()
    local pids = {}
    local pipe
    if IS_WINDOWS then
        pipe = io.popen('tasklist /fi "IMAGENAME eq ssh.exe" /fo csv /nh 2>nul')
    else
        pipe = io.popen("pgrep -x ssh 2>/dev/null")
    end

    if not pipe then
        return pids
    end

    for line in pipe:lines() do
        local pid_text = IS_WINDOWS and line:match('"ssh%.exe","(%d+)"') or line:match("^(%d+)")
        if pid_text then
            pids[#pids + 1] = tonumber(pid_text)
        end
    end
    pipe:close()

    return pids
end

local function pids_to_set(pid_list)
    local set = {}
    for _, pid in ipairs(pid_list) do
        set[pid] = true
    end
    return set
end

-- ssh -f forks after authenticating, so poll briefly for the child it left
-- behind rather than guessing from an unsorted process list.
local function find_new_ssh_pid(previous_pids, spec)
    for _ = 1, 10 do
        for _, pid in ipairs(list_ssh_pids()) do
            if not previous_pids[pid] then
                local cmdline = IS_WINDOWS and nil or posix_process_cmdline(pid)
                if not cmdline or not spec or spec == "" or cmdline:find(spec, 1, true) then
                    return pid
                end
            end
        end

        sleep_milliseconds(100)
    end

    return nil
end

local function validate_forward_host(name)
    if not name or name == "" then
        return false, "missing target host"
    end

    if name:find("[%s\"'&|<>,;%%%$]") then
        return false, string.format(
            "target host '%s' contains characters that cannot be passed to ssh", name)
    end

    return true
end

local function launch_tunnel(params)
    local host = params.host
    local mode = params.mode or "L"
    local local_port = tonumber(params.local_port)
    local remote_host = params.remote_host or "127.0.0.1"
    local remote_port = tonumber(params.remote_port)
    local background = (params.background ~= false)
    local dry_run = params.dry_run

    if not host or host == "" then
        fail("Missing remote host.")
        return false
    end

    -- -R listens on the remote host, so there is no local port to probe.
    if local_port and mode ~= "R" then
        local free, probe_error = is_port_free(local_port)
        if probe_error then
            fail(string.format("Cannot check local port %d: %s", local_port, probe_error))
            return false
        end

        if free then
            print(string.format("✔ %sPre-flight socket check:%s Local port %s%d%s is FREE on 127.0.0.1",
                C.dim, C.reset, C.green, local_port, C.reset))
        else
            warn(string.format("Local port %d is already OCCUPIED on 127.0.0.1!", local_port))

            local next_free, next_error = find_next_free_port(local_port + 1)
            if not next_free then
                fail(next_error
                    and string.format("Cannot probe for a free port: %s", next_error)
                    or "Could not find a free port.")
                return false
            end

            print(string.format("  Next available port found: %s%d%s",
                C.bold .. C.green, next_free, C.reset))
            if not params.auto_accept then
                if not is_interactive_stdin() then
                    fail(string.format("Port %d is busy and no answer can be read from stdin; "
                        .. "choose a free port with -L explicitly.", local_port))
                    return false
                end

                io.write(string.format("  Switch local port to %d? [Y/n]: ", next_free))
                local answer = read_line()
                if not (answer == "" or answer:lower():match("^y")) then
                    fail(string.format("Port %d cannot be bound; aborted.", local_port))
                    return false
                end
            end

            local_port = next_free
        end
    elseif mode == "R" then
        print(string.format("%s[INFO]%s -R: the remote side binds port %s and dials localhost:%d, "
            .. "so no local port check is needed.", C.dim, C.reset, tostring(remote_port), local_port or 0))
    end

    local full_cmd, spec = build_ssh_arguments({
        host = host,
        mode = mode,
        local_port = local_port,
        remote_host = remote_host,
        remote_port = remote_port,
        background = background,
    })

    if dry_run then
        print(string.format("\n%s[DRY-RUN] SSH Command:%s", C.yellow, C.reset))
        print("  " .. full_cmd)
        return true
    end

    print(string.format("\n🚀 %sLaunching SSH Tunnel (%s) to %s%s%s...",
        C.bold, (mode == "D" and "SOCKS5" or ("-" .. mode)), C.cyan, host, C.reset))
    print(string.format("   Command: %s%s%s", C.dim, full_cmd, C.reset))

    local existing_pids = background and pids_to_set(list_ssh_pids()) or {}
    local status = os.execute(full_cmd)
    local exit_code = exit_code_from_status(status)
    if exit_code ~= 0 then
        fail(string.format("SSH tunnel command failed with exit code %d.", exit_code))
        return false
    end

    if not background then
        print(string.format("\n%s✔ Foreground tunnel session closed.%s\n", C.green, C.reset))
        return true
    end

    local pid = find_new_ssh_pid(existing_pids, spec)
    if not pid then
        warn("the tunnel is running, but its process could not be identified, so it was not recorded. "
            .. "It will not appear in --list and cannot be stopped with --kill.")
    else
        local saved, save_error = save_tunnel_entry({
            pid = pid,
            host = host,
            mode = mode,
            local_port = local_port or 0,
            remote_host = remote_host,
            remote_port = remote_port or 0,
            spec = spec,
            started_at = os.date("%Y-%m-%d %H:%M:%S"),
            start_time = process_start_token(pid) or "",
            desc = params.desc or "",
        })
        if not saved then
            warn(string.format("the tunnel is running (PID %d) but could not be recorded: %s",
                pid, save_error))
        end
    end

    print(string.format("\n%s✔ Tunnel established successfully!%s", C.green .. C.bold, C.reset))
    if pid then
        print(string.format("  Process ID : %s%d%s", C.cyan, pid, C.reset))
    end
    if mode == "D" then
        print(string.format("  SOCKS5 Endpoint: %ssocks5://127.0.0.1:%d%s", C.yellow, local_port, C.reset))
    elseif mode == "L" then
        print(string.format("  Local Endpoint : %shttp://localhost:%d%s (Forwarded to %s:%d)",
            C.yellow, local_port, C.reset, remote_host, remote_port))
    else
        print(string.format("  Remote Endpoint: %s%s:%d%s (Forwarded to localhost:%d)",
            C.yellow, remote_host, remote_port, C.reset, local_port))
    end
    print(string.format("  Run %s'fssh_tunnel -l'%s or %s'fssh_tunnel -m'%s to manage active tunnels.\n",
        C.bold, C.reset, C.bold, C.reset))

    return true
end

--------------------------------------------------------------------------------
-- Interactive Wizard Mode
--------------------------------------------------------------------------------
local function run_interactive_wizard(default_host)
    print(string.format([[
%s%s================================================================
  fssh_tunnel - SSH Port Forward & Tunnel Manager (LuaJIT FFI)
================================================================%s]], C.cyan, C.bold, C.reset))

    local hosts = get_all_hosts()
    local host = default_host

    if not host then
        if #hosts == 0 then
            io.write("Enter remote SSH host/IP: ")
            host = read_line()
        else
            local host_entries = {}
            for _, candidate in ipairs(hosts) do
                host_entries[#host_entries + 1] = string.format("%s\t(%s) [%s]",
                    candidate.name, candidate.hostname or candidate.name, candidate.source)
            end

            local selected = nil
            local has_fzf = fzf_available() and is_interactive_terminal()
            if has_fzf then
                local temporary_path = get_temporary_path("fssh_hosts")
                local handle = io.open(temporary_path, "wb")
                if handle then
                    handle:write(table.concat(host_entries, "\n") .. "\n")
                    handle:close()

                    local pipe = io.popen(build_fzf_command(
                        temporary_path, "Select Host > ", "1,2"))
                    if pipe then
                        selected = pipe:read("*l")
                        pipe:close()
                    end
                    os.remove(temporary_path)
                end
            end

            if selected and selected ~= "" then
                host = selected:match("^(%S+)")
            else
                if not fzf_available() then
                    warn("fzf is not installed; falling back to manual host entry.")
                elseif not is_interactive_terminal() then
                    warn("no interactive terminal for the host picker; enter the host manually.")
                end
                io.write("Enter remote SSH host/IP: ")
                host = read_line()
            end
        end
    end

    if not host or host == "" then
        print("No host selected. Exiting.")
        return false
    end

    print(string.format("Target Host: %s%s%s\n", C.green .. C.bold, host, C.reset))

    print("Select Forwarding Mode:")
    print("  [1] Local Forward (-L)  [Remote Service -> Localhost]")
    print("  [2] Remote Forward (-R) [Remote Port -> Localhost]")
    print("  [3] Dynamic SOCKS5 (-D) [SOCKS Proxy via Remote Host]")
    io.write("Choice [1-3, default 1]: ")
    local mode_choice = read_line()
    local mode = "L"
    if mode_choice == "2" then
        mode = "R"
    elseif mode_choice == "3" then
        mode = "D"
    end

    local local_port = 8080
    local remote_host = "127.0.0.1"
    local remote_port = 8080
    local desc = ""

    if mode == "D" then
        io.write("Enter Local SOCKS5 Port [default 1080]: ")
        local_port = tonumber(read_line()) or 1080
        desc = "SOCKS5 Proxy"
    elseif mode == "R" then
        io.write("Enter Remote Bind Port [default 9000]: ")
        remote_port = tonumber(read_line()) or 9000
        io.write(string.format("Enter Local Target Port [default %d]: ", remote_port))
        local_port = tonumber(read_line()) or remote_port
        desc = "Remote Forward"
    else
        print("\nChoose Service Preset (or Custom):")
        local preset_keys = { "jupyter", "tensorboard", "postgres", "mysql", "redis",
            "codeserver", "vnc", "socks" }
        for index, key in ipairs(preset_keys) do
            local preset = PRESETS[key]
            print(string.format("  [%d] %-14s (Port %d) - %s",
                index, preset.name, preset.local_port, preset.desc))
        end
        print("  [0] Custom Port Configuration")
        io.write(string.format("Choice [0-%d, default 0]: ", #preset_keys))

        local preset_choice = tonumber(read_line())
        if preset_choice and preset_choice >= 1 and preset_choice <= #preset_keys then
            local preset = PRESETS[preset_keys[preset_choice]]
            mode = preset.mode or mode
            local_port = preset.local_port
            remote_host = preset.remote_host or "127.0.0.1"
            remote_port = preset.remote_port or preset.local_port
            desc = preset.name
        else
            io.write("Enter Local Port [default 8080]: ")
            local_port = tonumber(read_line()) or 8080

            io.write("Enter Remote Target Host [default 127.0.0.1]: ")
            local entered_host = read_line()
            if entered_host ~= "" then
                remote_host = entered_host
            end

            io.write(string.format("Enter Remote Port [default %d]: ", local_port))
            remote_port = tonumber(read_line()) or local_port
            desc = "Custom Forward"
        end
    end

    print("\nRun mode:")
    print("  [1] Background (Detached, persistent)")
    print("  [2] Foreground (Attached to this terminal)")
    io.write("Choice [1-2, default 1]: ")
    local background = (read_line() ~= "2")

    if mode ~= "D" then
        local host_ok, host_error = validate_forward_host(remote_host)
        if not host_ok then
            fail(host_error)
            return false
        end
    end

    return launch_tunnel({
        host = host,
        mode = mode,
        local_port = local_port,
        remote_host = remote_host,
        remote_port = remote_port,
        background = background,
        desc = desc,
    })
end

--------------------------------------------------------------------------------
-- CLI Argument Parsing
--------------------------------------------------------------------------------
local function print_help()
    print([[
fssh_tunnel.lua - High-Performance Interactive SSH Port Forward & Tunnel Manager (LuaJIT FFI)

Usage:
  fssh_tunnel.lua [OPTIONS] [HOST]

Options:
  -L <local_port:remote_host:remote_port>  Local forward (e.g. 8888:127.0.0.1:8888 or 8888:8888)
  -R <remote_port:target_host:local_port>  Remote forward (e.g. 9000:127.0.0.1:3000)
  -D <port>                Dynamic SOCKS5 proxy on local port (e.g. 1080)
  -p, --preset <name>      Quick preset (jupyter, tensorboard, postgres, mysql, redis,
                           codeserver, vnc, socks)
  -b, --background         Run in background (default for tunnels)
  -F, --foreground         Run in foreground
  -l, --list               List currently active background tunnels
  --lines                  Machine-readable TSV of active tunnels
  --json                   Output active tunnels list as JSON
  -k, --kill <PID|all>     Stop one tunnel, or all of them (asks first)
  -y, --yes                Skip the confirmation prompt for --kill all
  -m, --manage             Interactive FZF tunnel manager
  --check-port <port>      Exit 0 when a local TCP port is free, 1 when occupied
  --hosts                  List all discovered SSH hosts
  -d, --dry-run            Show SSH command without running
  -i, --interactive        Run guided setup wizard
  --test                   Run the built-in self-test suite
  -h, --help               Show this help message

Presets:
  jupyter     Local 8888 -> Remote 127.0.0.1:8888
  tensorboard Local 6006 -> Remote 127.0.0.1:6006
  postgres    Local 5432 -> Remote 127.0.0.1:5432
  mysql       Local 3306 -> Remote 127.0.0.1:3306
  redis       Local 6379 -> Remote 127.0.0.1:6379
  codeserver  Local 8080 -> Remote 127.0.0.1:8080
  vnc         Local 5901 -> Remote 127.0.0.1:5901
  socks       Dynamic SOCKS5 proxy on port 1080

Examples:
  fssh_tunnel.lua -L 8888:localhost:8888 gpu-box
  fssh_tunnel.lua -R 9000:127.0.0.1:3000 jump-host
  fssh_tunnel.lua -p jupyter gpu-box
  fssh_tunnel.lua -D 1080 dev-server
  fssh_tunnel.lua -l
  fssh_tunnel.lua -l --json
  fssh_tunnel.lua -k 12345
  fssh_tunnel.lua -k all --yes
  fssh_tunnel.lua -m

Notes:
  -R takes the port the REMOTE host binds first and the LOCAL target last.
  --kill only stops processes that are verified to be ssh tunnels.
]])
end

local function parse_forward_spec(spec)
    -- Formats:
    -- 1. <first_port>:<target_host>:<third_port>
    -- 2. <first_port>:<third_port> (implies 127.0.0.1)
    local first_port, host, third_port = spec:match("^(%d+):([^:]+):(%d+)$")
    if first_port and host and third_port then
        return tonumber(first_port), host, tonumber(third_port)
    end

    first_port, third_port = spec:match("^(%d+):(%d+)$")
    if first_port and third_port then
        return tonumber(first_port), "127.0.0.1", tonumber(third_port)
    end

    return nil, nil, nil
end

-- -L: first field is the local bind port, third is the remote target port.
-- -R: first field is the port the remote host binds, third is the local target.
local function apply_forward_argument(params, mode, raw_spec)
    local first_port, host, third_port = parse_forward_spec(raw_spec)
    if not first_port then
        return false, string.format("Invalid -%s spec '%s'. Expected %s.",
            mode,
            tostring(raw_spec),
            mode == "R" and "<remote_port:target_host:local_port> or <remote_port:local_port>"
                or "<local_port:remote_host:remote_port> or <local_port:remote_port>")
    end

    local host_ok, host_error = validate_forward_host(host)
    if not host_ok then
        return false, host_error
    end

    params.mode = mode
    params.remote_host = host
    if mode == "R" then
        params.remote_port = first_port
        params.local_port = third_port
    else
        params.local_port = first_port
        params.remote_port = third_port
    end

    return true
end

local run_tests -- defined after main; --test dispatches to it

local function main(argv)
    argv = argv or arg or {}
    if #argv == 0 then
        return run_interactive_wizard()
    end

    local params = {
        background = true,
        dry_run = false,
    }
    local assume_yes = false
    for _, value in ipairs(argv) do
        if value == "-y" or value == "--yes" then
            assume_yes = true
        end
    end

    local index = 1
    while index <= #argv do
        local argument = argv[index]
        if argument == "-h" or argument == "--help" then
            print_help()
            return true
        elseif argument == "--test" then
            return run_tests()
        elseif argument == "-l" or argument == "--list" then
            print_active_tunnels(argv[index + 1] == "--json")
            return true
        elseif argument == "--lines" then
            print_active_lines()
            return true
        elseif argument == "--json" then
            print_active_tunnels(true)
            return true
        elseif argument == "-m" or argument == "--manage" then
            return run_interactive_manager()
        elseif argument == "-k" or argument == "--kill" then
            index = index + 1
            local target = argv[index]
            if not target then
                fail("-k needs a PID or 'all'.")
                io.stderr:write("  Examples: fssh_tunnel -k 12345   |   fssh_tunnel -k all --yes\n")
                return false
            end
            return kill_tunnels(target, assume_yes)
        elseif argument == "--check-port" then
            index = index + 1
            local port = tonumber(argv[index])
            if not port then
                fail("--check-port needs a port number.")
                return false
            end

            local free, probe_error = is_port_free(port)
            if probe_error then
                fail(string.format("Cannot check port %d: %s", port, probe_error))
                return false
            end

            if free then
                print(string.format("Port %d is FREE", port))
                return true
            end

            print(string.format("Port %d is OCCUPIED", port))
            return false
        elseif argument == "--hosts" then
            for _, host in ipairs(get_all_hosts()) do
                print(string.format("%-24s\t%-24s\t[%s]", host.name, host.hostname or host.name, host.source))
            end
            return true
        elseif argument == "-i" or argument == "--interactive" then
            local host = argv[index + 1]
            if host and host:sub(1, 1) == "-" then
                host = nil
            end
            return run_interactive_wizard(host)
        elseif argument == "-b" or argument == "--background" then
            params.background = true
        elseif argument == "-F" or argument == "--foreground" then
            params.background = false
        elseif argument == "-d" or argument == "--dry-run" then
            params.dry_run = true
        elseif argument == "-y" or argument == "--yes" then
            assume_yes = true
        elseif argument == "-L" or argument == "-R" then
            index = index + 1
            local applied, apply_error = apply_forward_argument(params, argument:sub(2), argv[index] or "")
            if not applied then
                fail(apply_error)
                return false
            end
        elseif argument == "-D" then
            index = index + 1
            local port = tonumber(argv[index])
            if not port or port < 1 or port > 65535 then
                fail("Invalid -D port; expected 1-65535.")
                return false
            end
            params.mode = "D"
            params.local_port = port
        elseif argument == "-p" or argument == "--preset" then
            index = index + 1
            local name = (argv[index] or ""):lower()
            local preset = PRESETS[name]
            if not preset then
                fail(string.format("Unknown preset '%s'. Available presets: %s",
                    name, table.concat(PRESET_ORDER, ", ")))
                return false
            end

            params.mode = preset.mode
            params.local_port = preset.local_port
            params.remote_host = preset.remote_host
            params.remote_port = preset.remote_port
            params.desc = preset.name
        elseif argument:sub(1, 1) == "-" and argument ~= "-" then
            fail(string.format("Unknown option: %s", argument))
            io.stderr:write("Run 'fssh_tunnel --help' for usage.\n")
            return false
        elseif params.host then
            fail(string.format("Unexpected argument '%s'; the host is already '%s'.",
                argument, params.host))
            return false
        else
            params.host = argument
        end

        index = index + 1
    end

    if not params.host then
        return run_interactive_wizard()
    end

    if not params.mode then
        return run_interactive_wizard(params.host)
    end

    return launch_tunnel(params)
end

--------------------------------------------------------------------------------
-- Self-Test Suite (--test)
--------------------------------------------------------------------------------
local test_results = { passed = 0, failed = 0, skipped = 0, failures = {} }

local function check(description, condition, detail)
    if condition then
        test_results.passed = test_results.passed + 1
        print(string.format("  %s✔%s %s", C.green, C.reset, description))
        return
    end

    test_results.failed = test_results.failed + 1
    test_results.failures[#test_results.failures + 1] = description
    print(string.format("  %s✖%s %s%s", C.red, C.reset, description,
        detail and string.format(" (%s)", tostring(detail)) or ""))
end

local function skip(description, reason)
    test_results.skipped = test_results.skipped + 1
    print(string.format("  %s-%s %s (skipped: %s)", C.yellow, C.reset, description, reason))
end

local function current_process_id()
    if IS_WINDOWS then
        return tonumber(ffi.C.GetCurrentProcessId())
    end

    return tonumber(ffi.C.getpid())
end

-- Binds a throwaway listener so the port probe can be tested against a real
-- occupied port. Returns a release function, or nil when binding failed.
local function bind_test_listener(port)
    if IS_WINDOWS then
        local sock = winsock.socket(AF_INET, SOCK_STREAM, 0)
        if sock == ffi.cast("SOCKET", -1) then
            return nil
        end

        local addr = build_loopback_sockaddr(port, winsock.htons)
        if winsock.bind(sock, ffi.cast("const struct sockaddr*", addr), 16) ~= 0 then
            winsock.closesocket(sock)
            return nil
        end

        return function()
            winsock.closesocket(sock)
        end
    end

    local fd = ffi.C.socket(AF_INET, SOCK_STREAM, 0)
    if fd < 0 then
        return nil
    end

    local addr = build_loopback_sockaddr(port, ffi.C.htons)
    if ffi.C.bind(fd, ffi.cast("const void*", addr), 16) ~= 0 then
        ffi.C.close(fd)
        return nil
    end

    return function()
        ffi.C.close(fd)
    end
end

local function find_free_test_port()
    for candidate = 46100, 46200 do
        if is_port_free(candidate) then
            return candidate
        end
    end

    return nil
end

run_tests = function()
    print(string.format("%sfssh_tunnel self-tests%s\n", C.bold, C.reset))

    print("Forward spec parsing")
    local first_port, host, third_port = parse_forward_spec("8888:127.0.0.1:80")
    check("three-field spec is parsed",
        first_port == 8888 and host == "127.0.0.1" and third_port == 80,
        string.format("%s %s %s", tostring(first_port), tostring(host), tostring(third_port)))

    first_port, host, third_port = parse_forward_spec("9000:9000")
    check("two-field spec implies loopback",
        first_port == 9000 and host == "127.0.0.1" and third_port == 9000)
    check("garbage spec is rejected", parse_forward_spec("9000") == nil)

    local remote_params = {}
    local applied, apply_error = apply_forward_argument(remote_params, "R", "9000:127.0.0.1:3000")
    check("-R parses the remote bind port first",
        applied and remote_params.remote_port == 9000 and remote_params.local_port == 3000,
        apply_error or string.format("remote_port=%s local_port=%s",
            tostring(remote_params.remote_port), tostring(remote_params.local_port)))

    local local_params = {}
    apply_forward_argument(local_params, "L", "8888:127.0.0.1:80")
    check("-L keeps the local bind port first",
        local_params.local_port == 8888 and local_params.remote_port == 80)

    check("-L rejects a malformed spec", apply_forward_argument({}, "L", "nope") == false)
    check("-L rejects a host with shell metacharacters",
        apply_forward_argument({}, "L", "80:foo bar:80") == false)

    print("\nSSH command construction")
    local local_command, local_spec = build_ssh_arguments({
        host = "gpu-box", mode = "L", local_port = 8888,
        remote_host = "127.0.0.1", remote_port = 8888, background = true,
    })
    check("local forward spec", local_spec == "8888:127.0.0.1:8888", local_spec)
    check("background mode detaches",
        local_command:find("-f -N", 1, true) ~= nil, local_command)

    local remote_command, remote_spec = build_ssh_arguments({
        host = "jump", mode = "R", local_port = 3000,
        remote_host = "127.0.0.1", remote_port = 9000, background = true,
    })
    check("remote forward spec keeps the remote port first",
        remote_spec == "9000:127.0.0.1:3000", remote_spec)
    check("remote forward command matches the spec",
        remote_command:find("-R 9000:127.0.0.1:3000", 1, true) ~= nil, remote_command)

    local dynamic_command, dynamic_spec = build_ssh_arguments({
        host = "dev", mode = "D", local_port = 1080, background = false,
    })
    check("dynamic forward spec is a bare port", dynamic_spec == "1080", dynamic_spec)
    check("foreground mode keeps the terminal",
        dynamic_command:find("-f", 1, true) == nil, dynamic_command)

    print("\nExit status handling")
    check("success is exit code 0", exit_code_from_status(true) == 0)
    if IS_WINDOWS then
        check("Windows exit codes pass through", exit_code_from_status(255) == 255)
    else
        check("POSIX wait status decodes to the exit code", exit_code_from_status(255 * 256) == 255)
    end

    print("\nRegistry JSON")
    local tricky_entry = {
        pid = 4242,
        host = "gpu{box}\"quoted\"",
        mode = "L",
        local_port = 8888,
        remote_host = "127.0.0.1",
        remote_port = 8888,
        spec = "8888:127.0.0.1:8888",
        started_at = "2026-10-20 10:00:00",
        desc = "tab\there, brace } and quote \" and newline\nend",
    }
    local encoded = serialize_json({ tricky_entry })
    check("encoded JSON escapes quotes", encoded:find('\\"', 1, true) ~= nil, encoded)
    check("encoded JSON has no raw control characters",
        encoded:find("[\1-\8\11\12\14-\31]") == nil)

    local decoded, decode_error = deserialize_json(encoded)
    check("registry round-trips complex strings",
        decode_error == nil and #decoded == 1
            and decoded[1].desc == tricky_entry.desc
            and decoded[1].host == tricky_entry.host,
        decode_error or (decoded[1] and decoded[1].desc))

    local escaped, escaped_error = deserialize_json('[{"pid": 7, "host": "h", "desc": "\\u00e9\\u4e2d"}]')
    check("JSON reader decodes \\u escapes",
        escaped_error == nil and #escaped == 1 and escaped[1].desc == "\195\169\228\184\173",
        escaped_error or (escaped[1] and escaped[1].desc))

    local broken, broken_error = deserialize_json('[{"pid": 1,}}')
    check("malformed JSON is reported, not swallowed",
        #broken == 0 and broken_error ~= nil, broken_error)

    check("empty registry decodes to an empty list", #deserialize_json("") == 0)

    print("\nRegistry file")
    local previous_override = registry_path_override
    local test_registry = get_temporary_path("fssh_tunnel_test")
    os.remove(test_registry)
    registry_path_override = test_registry

    local saved, save_error = write_registry({ tricky_entry })
    check("registry writes to disk", saved, save_error)

    local handle = io.open(test_registry, "rb")
    local written = handle and handle:read("*a") or ""
    if handle then
        handle:close()
    end
    local reloaded, reload_error = deserialize_json(written)
    check("registry file re-reads identically",
        reload_error == nil and #reloaded == 1 and reloaded[1].desc == tricky_entry.desc,
        reload_error or (reloaded[1] and reloaded[1].desc))

    local empty_saved = write_registry({})
    local empty_handle = io.open(test_registry, "rb")
    local empty_content = empty_handle and empty_handle:read("*a") or ""
    if empty_handle then
        empty_handle:close()
    end
    check("empty registry writes a valid array",
        empty_saved and empty_content:match("^%[%]\n?$") ~= nil, empty_content)

    registry_path_override = previous_override
    os.remove(test_registry)
    os.remove(test_registry .. ".tmp")

    print("\nProcess identity")
    check("a bogus PID is reported as dead",
        classify_tunnel_process({ pid = 2147483647 }) == "dead")
    check("a non-ssh process is not a tunnel",
        classify_tunnel_process({ pid = current_process_id() }) == "foreign",
        process_image_name(current_process_id()))

    local own_pid = current_process_id()
    local first_start = process_start_token(own_pid)
    local second_start = process_start_token(own_pid)
    check("process start time is stable for one instance",
        first_start ~= nil and first_start == second_start,
        string.format("%s vs %s", tostring(first_start), tostring(second_start)))
    check("a recycled PID with a new start time is rejected",
        classify_tunnel_process({ pid = own_pid, start_time = "0123456789abcdef" }) == "foreign")

    print("\nPort probe")
    local test_port = find_free_test_port()
    if test_port then
        local release = bind_test_listener(test_port)
        if release then
            local occupied, probe_error = is_port_free(test_port)
            check("occupied port is detected", occupied == false and probe_error == nil,
                probe_error or tostring(occupied))

            release()
            check("released port reports free", is_port_free(test_port) == true)
        else
            skip("occupied port is detected", "could not bind a test socket")
        end
    else
        skip("occupied port is detected", "no free port in 46100-46200")
    end

    check("invalid port is rejected with a reason",
        select(2, is_port_free(70000)) ~= nil)

    print("\nfzf commands")
    local picker_template = build_fzf_command("list.txt", "p > ", "1,2")
    check("fzf commands read the list by redirection",
        picker_template:find("< ", 1, true) ~= nil
            and picker_template:find("type ", 1, true) == nil
            and picker_template:find("cat ", 1, true) == nil,
        picker_template)

    local host_list = get_temporary_path("fssh_tunnel_hosts")
    local host_handle = io.open(host_list, "wb")
    if host_handle then
        host_handle:write("centre\t(centre.local) [putty]\n")
        host_handle:write("pi4\t(raspberrypi.local) [putty]\n")
        host_handle:close()

        local picker_command = build_fzf_command(host_list, "Select Host > ", "1,2")
        if fzf_available() then
            local pipe = io.popen(picker_command .. " --filter=centre 2>&1")
            local output = pipe and pipe:read("*a") or ""
            if pipe then
                pipe:close()
            end
            check("host picker receives the discovered hosts",
                output:find("centre", 1, true) ~= nil, output)
        else
            skip("host picker receives the discovered hosts", "fzf is not installed")
        end

        os.remove(host_list)
    else
        skip("host picker receives the discovered hosts", "cannot create a temporary list")
    end

    print("\nfzf manager pipeline")
    local manager_list = get_temporary_path("fssh_tunnel_fzf")
    local list_handle = io.open(manager_list, "wb")
    if list_handle then
        list_handle:write("111\tgpu-box\t-L\t127.0.0.1:8888\t127.0.0.1:8888\t2026-10-20 10:00:00\n")
        list_handle:write("222\tdb-01\t-R\t127.0.0.1:5432\t127.0.0.1:6000\t2026-10-20 10:01:00\n")
        list_handle:close()

        local manager_command = build_manager_command(manager_list)
        if fzf_available() then
            local pipe = io.popen(manager_command .. " --filter=gpu 2>&1")
            local output = pipe and pipe:read("*a") or ""
            if pipe then
                pipe:close()
            end
            check("fzf manager pipeline selects a tunnel",
                output:find("gpu-box", 1, true) ~= nil, output)
        else
            skip("fzf manager pipeline selects a tunnel", "fzf is not installed")
        end

        os.remove(manager_list)
    else
        skip("fzf manager pipeline selects a tunnel", "cannot create a temporary list")
    end

    print(string.format("\n%d passed, %d failed, %d skipped",
        test_results.passed, test_results.failed, test_results.skipped))

    if test_results.failed > 0 then
        print("Failed checks:")
        for _, description in ipairs(test_results.failures) do
            print("  - " .. description)
        end
        return false
    end

    return true
end

--------------------------------------------------------------------------------
-- Entry Point
--------------------------------------------------------------------------------
local function run()
    if main(arg) == false then
        os.exit(1)
    end
end

run()
