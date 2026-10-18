#!/usr/bin/env luajit
--[[
  fnet.lua - Zero-dependency network diagnostics for Windows and Linux (LuaJIT + FFI).
  Single file, no external binaries: interface discovery, DNS, ICMP ping, and TCP port
  scanning all go through native OS APIs.

  Features:
    - Interfaces: adapter name, type, state, MTU, MAC, IPv4/IPv6 with prefix, gateways.
      * Windows: GetAdaptersInfo (IPv4, MAC, gateway); IPv6 addresses are not reported.
      * Linux:   getifaddrs plus /sys/class/net and /proc/net/route.
    - DNS: forward resolution via getaddrinfo and optional reverse PTR lookups.
    - Ping: ICMP echo with per-packet RTT and loss statistics.
      * Windows: IcmpSendEcho (iphlpapi, no administrator rights needed).
      * Linux:   unprivileged SOCK_DGRAM ICMP, falling back to SOCK_RAW.
      * --tcp:   measure TCP handshake latency when ICMP is blocked or unprivileged.
    - Scan: concurrent non-blocking TCP connect scan via poll() (Linux) or
      select() (Windows, whose WSAPoll delays connect-failure reporting).
    - Check: one-shot diagnosis (resolve, ping, common ports, verdict).
    - --json for interfaces, DNS, ping, and scan output.
    - Built-in self-test suite (--test) with loopback-only network checks.

  Usage:
    fnet ifaces [--json]
    fnet dns HOST [--reverse] [--json]
    fnet ping HOST [-c COUNT] [-w MS] [--tcp] [--port PORT] [--json]
    fnet scan HOST | HOST:PORT [-p SPEC] [-w MS] [-c CONCURRENCY] [--open-only] [--json]
    fnet check HOST [-p SPEC] [-c COUNT] [-w MS] [--tcp]
    fnet --test
    fnet --help

  Options:
    --json          Machine-readable output (no ANSI colors).
    --no-color      Disable ANSI colors (NO_COLOR is also honored).
    --open-only     scan: print only open ports.
    -p, --ports     Comma list or ranges, e.g. 22,80,443 or 1-1024.
    -w, --timeout   Per-probe timeout in milliseconds (default: 1000 ping, 800 scan).
    -c              ping: packet count (default 4); scan: concurrency (default 128).
    -t, --tcp       ping: measure TCP handshake latency instead of ICMP.

  Exit codes:
    0  Success (check: target reachable)
    1  Runtime failure (check: target unreachable)
    2  Usage error
]]

local ffi = require("ffi")
local bit = require("bit")

local OS = ffi.os
local IS_WINDOWS = (OS == "Windows")
local IS_LINUX = (OS == "Linux")

--------------------------------------------------------------------------------
-- Platform Constants
--------------------------------------------------------------------------------

local AF_UNSPEC = 0
local AF_INET = 2
local AF_INET6 = IS_WINDOWS and 23 or 10
local SOCK_STREAM = 1
local SOCK_DGRAM = 2
local SOCK_RAW = 3
local IPPROTO_ICMP = 1

local SOL_SOCKET = IS_WINDOWS and 0xFFFF or 1
local SO_ERROR = IS_WINDOWS and 0x1007 or 4

-- Winsock poll event flags differ from the POSIX values.
local POLLIN = IS_WINDOWS and 0x0300 or 0x0001
local POLLOUT = IS_WINDOWS and 0x0010 or 0x0004

local NI_NAMEREQD = 8

local F_GETFL = 3
local F_SETFL = 4
local O_NONBLOCK = 0x0800
local FIONBIO = 0x8004667E

local IFF_UP = 0x1

local ERROR_BUFFER_OVERFLOW = 111

local ERR_INPROGRESS = IS_WINDOWS and 10036 or 115
local ERR_WOULDBLOCK = IS_WINDOWS and 10035 or 115
local ERR_CONNREFUSED = IS_WINDOWS and 10061 or 111
local ERR_TIMEDOUT = IS_WINDOWS and 10060 or 110
local ERR_HOSTUNREACH = IS_WINDOWS and 10065 or 113
local ERR_NETUNREACH = IS_WINDOWS and 10051 or 101
local ERR_ACCES = IS_WINDOWS and 10013 or 13
local ERR_PERM = IS_WINDOWS and 10013 or 1

local ICMP_ECHO_PAYLOAD = 32
local SCAN_POLL_SLICE_MS = 25

--------------------------------------------------------------------------------
-- FFI Declarations
--------------------------------------------------------------------------------

local net
local iphlpapi
local msvcrt
local INVALID_SOCKET
local INVALID_HANDLE

if IS_WINDOWS then
    ffi.cdef[[
        typedef void* HANDLE;
        typedef unsigned long DWORD;
        typedef int BOOL;
        typedef unsigned char BYTE;
        typedef unsigned int UINT;
        typedef uintptr_t SOCKET;
        typedef int socklen_t;
        typedef unsigned short WORD;

        typedef struct sockaddr {
            unsigned short sa_family;
            char sa_data[14];
        } sockaddr;

        typedef struct sockaddr_in {
            unsigned short sin_family;
            unsigned short sin_port;
            unsigned char sin_addr[4];
            unsigned char sin_zero[8];
        } sockaddr_in;

        typedef struct sockaddr_in6 {
            unsigned short sin6_family;
            unsigned short sin6_port;
            unsigned long sin6_flowinfo;
            unsigned char sin6_addr[16];
            unsigned long sin6_scope_id;
        } sockaddr_in6;

        typedef struct addrinfo {
            int ai_flags;
            int ai_family;
            int ai_socktype;
            int ai_protocol;
            size_t ai_addrlen;
            char* ai_canonname;
            struct sockaddr* ai_addr;
            struct addrinfo* ai_next;
        } addrinfo;

        typedef struct {
            unsigned short wVersion;
            unsigned short wHighVersion;
            char szDescription[257];
            char szSystemStatus[129];
            unsigned short iMaxSockets;
            unsigned short iMaxUdpDg;
            char* lpVendorInfo;
        } WSADATA;

        typedef struct pollfd {
            SOCKET fd;
            short events;
            short revents;
        } pollfd;

        typedef struct timeval {
            long tv_sec;
            long tv_usec;
        } timeval;

        typedef struct fd_set {
            unsigned int fd_count;
            SOCKET fd_array[64];
        } fd_set;

        typedef struct {
            struct _IP_ADDR_STRING* Next;
            char IpAddress[16];
            char IpMask[16];
            DWORD Context;
        } IP_ADDR_STRING;

        typedef struct _IP_ADAPTER_INFO {
            struct _IP_ADAPTER_INFO* Next;
            DWORD ComboIndex;
            char AdapterName[260];
            char Description[132];
            UINT AddressLength;
            BYTE Address[8];
            DWORD Index;
            UINT Type;
            UINT DhcpEnabled;
            void* CurrentIpAddress;
            IP_ADDR_STRING IpAddressList;
            IP_ADDR_STRING GatewayList;
            IP_ADDR_STRING DhcpServer;
            BOOL HaveWmi;
            IP_ADDR_STRING PrimaryWinsServer;
            IP_ADDR_STRING SecondaryWinsServer;
            long long LeaseObtained;
            long long LeaseExpires;
        } IP_ADAPTER_INFO;

        typedef struct {
            unsigned long Address;
            unsigned long Status;
            unsigned long RoundTripTime;
            unsigned short DataSize;
            unsigned short Reserved;
            void* Data;
        } ICMP_ECHO_REPLY;

        int WSAStartup(unsigned short wVersionRequired, WSADATA* lpWSAData);
        int WSACleanup(void);
        int WSAGetLastError(void);
        int getaddrinfo(const char* node, const char* service,
                        const struct addrinfo* hints, struct addrinfo** result);
        void freeaddrinfo(struct addrinfo* result);
        int getnameinfo(const struct sockaddr* addr, socklen_t addrlen,
                        char* host, unsigned int hostlen,
                        char* service, unsigned int servicelen, int flags);
        SOCKET socket(int domain, int type, int protocol);
        int closesocket(SOCKET s);
        int connect(SOCKET s, const struct sockaddr* name, int namelen);
        int getsockopt(SOCKET s, int level, int optname, char* optval, int* optlen);
        int setsockopt(SOCKET s, int level, int optname, const char* optval, int optlen);
        int ioctlsocket(SOCKET s, unsigned long cmd, unsigned long* argp);
        int bind(SOCKET s, const struct sockaddr* name, int namelen);
        int listen(SOCKET s, int backlog);
        int getsockname(SOCKET s, struct sockaddr* name, int* namelen);
        unsigned short htons(unsigned short hostshort);
        unsigned short ntohs(unsigned short netshort);
        int select(int nfds, void* readfds, void* writefds, void* exceptfds,
                   struct timeval* timeout);
        void Sleep(DWORD milliseconds);
        unsigned long long GetTickCount64(void);
        int QueryPerformanceCounter(long long* counter);
        int QueryPerformanceFrequency(long long* frequency);
        unsigned long GetLastError(void);
        HANDLE GetStdHandle(DWORD which);
        BOOL GetConsoleMode(HANDLE handle, DWORD* mode);
        BOOL SetConsoleMode(HANDLE handle, DWORD mode);
        BOOL SetConsoleOutputCP(unsigned int code_page);
        int _isatty(int fd);

        unsigned long GetAdaptersInfo(IP_ADAPTER_INFO* info, unsigned long* size);
        HANDLE IcmpCreateFile(void);
        BOOL IcmpCloseHandle(HANDLE handle);
        DWORD IcmpSendEcho(HANDLE handle, unsigned long destination, void* request,
                           unsigned short request_size, void* request_options,
                           void* reply, DWORD reply_size, DWORD timeout);
    ]]

    msvcrt = ffi.load("msvcrt")
    net = ffi.load("ws2_32")
    iphlpapi = ffi.load("iphlpapi")
    INVALID_SOCKET = ffi.cast("SOCKET", -1)
    INVALID_HANDLE = ffi.cast("HANDLE", -1)
end

if IS_LINUX then
    ffi.cdef[[
        typedef unsigned int socklen_t;

        struct sockaddr {
            unsigned short sa_family;
            char sa_data[14];
        };

        struct sockaddr_in {
            unsigned short sin_family;
            unsigned short sin_port;
            unsigned char sin_addr[4];
            unsigned char sin_zero[8];
        };

        struct sockaddr_in6 {
            unsigned short sin6_family;
            unsigned short sin6_port;
            unsigned int sin6_flowinfo;
            unsigned char sin6_addr[16];
            unsigned int sin6_scope_id;
        };

        struct addrinfo {
            int ai_flags;
            int ai_family;
            int ai_socktype;
            int ai_protocol;
            socklen_t ai_addrlen;
            struct sockaddr* ai_addr;
            char* ai_canonname;
            struct addrinfo* ai_next;
        };

        struct pollfd {
            int fd;
            short events;
            short revents;
        };

        struct timeval {
            long tv_sec;
            long tv_usec;
        };

        struct ifaddrs {
            struct ifaddrs* ifa_next;
            char* ifa_name;
            unsigned int ifa_flags;
            struct sockaddr* ifa_addr;
            struct sockaddr* ifa_netmask;
            struct sockaddr* ifa_ifu;
            void* ifa_data;
        };

        int getaddrinfo(const char* node, const char* service,
                        const struct addrinfo* hints, struct addrinfo** result);
        void freeaddrinfo(struct addrinfo* result);
        int getnameinfo(const struct sockaddr* addr, socklen_t addrlen,
                        char* host, socklen_t hostlen,
                        char* service, socklen_t servicelen, int flags);
        char* gai_strerror(int code);
        int socket(int domain, int type, int protocol);
        int close(int fd);
        int connect(int fd, const struct sockaddr* name, socklen_t namelen);
        int getsockopt(int fd, int level, int optname, void* optval, socklen_t* optlen);
        int setsockopt(int fd, int level, int optname, const void* optval, socklen_t optlen);
        int fcntl(int fd, int cmd, int arg);
        int bind(int fd, const struct sockaddr* name, socklen_t namelen);
        int listen(int fd, int backlog);
        int getsockname(int fd, struct sockaddr* name, socklen_t* namelen);
        unsigned short htons(unsigned short hostshort);
        unsigned short ntohs(unsigned short netshort);
        long sendto(int fd, const void* buf, size_t len, int flags,
                    const struct sockaddr* dest, socklen_t destlen);
        long recvfrom(int fd, void* buf, size_t len, int flags,
                      struct sockaddr* src, socklen_t* srclen);
        int poll(struct pollfd* fds, unsigned long count, int timeout);
        int gettimeofday(struct timeval* tv, void* timezone);
        int usleep(unsigned int microseconds);
        int getifaddrs(struct ifaddrs** result);
        void freeifaddrs(struct ifaddrs* list);
        int isatty(int fd);
        char* strerror(int errnum);
    ]]

    net = ffi.C
end

--------------------------------------------------------------------------------
-- Console & Colors
--------------------------------------------------------------------------------

local COLORS = {
    reset = "\27[0m",
    bold = "\27[1m",
    dim = "\27[2m",
    red = "\27[31m",
    green = "\27[32m",
    yellow = "\27[33m",
    blue = "\27[34m",
    magenta = "\27[35m",
    cyan = "\27[36m",
    white = "\27[37m",
    b_red = "\27[91m",
    b_green = "\27[92m",
    b_yellow = "\27[93m",
    b_blue = "\27[94m",
    b_cyan = "\27[96m",
    b_white = "\27[97m",
    gray = "\27[90m",
}

local C = {}

local function configure_colors(enabled)
    for name in pairs(COLORS) do
        C[name] = enabled and COLORS[name] or ""
    end
end
configure_colors(false)

local function setup_console()
    if not IS_WINDOWS then
        return
    end

    -- Apply UTF-8 code pages and virtual terminal processing to both streams.
    ffi.C.SetConsoleOutputCP(65001)
    local ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004

    for _, handle_id in ipairs({ -11, -12 }) do
        local handle = ffi.C.GetStdHandle(handle_id)
        if handle ~= nil and handle ~= INVALID_HANDLE then
            local mode = ffi.new("DWORD[1]")
            if ffi.C.GetConsoleMode(handle, mode) ~= 0 then
                ffi.C.SetConsoleMode(handle,
                    bit.bor(mode[0], ENABLE_VIRTUAL_TERMINAL_PROCESSING))
            end
        end
    end
end

local function stdout_is_tty()
    if IS_WINDOWS then
        return msvcrt._isatty(1) ~= 0
    end
    return ffi.C.isatty(1) ~= 0
end

--------------------------------------------------------------------------------
-- Generic Helpers
--------------------------------------------------------------------------------

local function die(message, hint, code)
    io.stderr:write("[ERROR] " .. tostring(message) .. "\n")
    if hint then
        io.stderr:write("Hint: " .. tostring(hint) .. "\n")
    end
    os.exit(code or 1)
end

local function usage_error(message)
    die(message, "run 'fnet --help' for usage", 2)
end

local function trim(text)
    return (tostring(text):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function fit(text, width)
    text = tostring(text or "")
    if #text <= width then
        return text
    end
    if width <= 3 then
        return text:sub(1, width)
    end
    return text:sub(1, width - 3) .. "..."
end

local function read_file(path)
    local handle = io.open(path, "rb")
    if not handle then
        return nil
    end
    local content = handle:read("*a")
    handle:close()
    return content
end

local function paint(text, color)
    return color .. text .. C.reset
end

local function json_escape(text)
    local escapes = {
        ['"'] = '\\"',
        ["\\"] = "\\\\",
        ["\n"] = "\\n",
        ["\r"] = "\\r",
        ["\t"] = "\\t",
        ["\b"] = "\\b",
        ["\f"] = "\\f",
    }
    local escaped = tostring(text):gsub('[%z\1-\31\\"]', function(character)
        return escapes[character] or string.format("\\u%04x", character:byte())
    end)
    return '"' .. escaped .. '"'
end

local function is_array(value)
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" then
            return false
        end
        count = count + 1
    end
    return count == #value
end

local function json_encode(value)
    local value_type = type(value)

    if value == nil then
        return "null"
    end
    if value_type == "boolean" then
        return value and "true" or "false"
    end
    if value_type == "number" then
        if value % 1 == 0 then
            return string.format("%d", value)
        end
        return string.format("%.3f", value)
    end
    if value_type == "string" then
        return json_escape(value)
    end
    if value_type ~= "table" then
        return "null"
    end

    if is_array(value) then
        local items = {}
        for _, item in ipairs(value) do
            items[#items + 1] = json_encode(item)
        end
        return "[" .. table.concat(items, ",") .. "]"
    end

    local keys = {}
    for key in pairs(value) do
        if type(key) == "string" then
            keys[#keys + 1] = key
        end
    end
    table.sort(keys)

    local fields = {}
    for _, key in ipairs(keys) do
        local item = value[key]
        if item ~= nil then
            fields[#fields + 1] = json_escape(key) .. ":" .. json_encode(item)
        end
    end
    return "{" .. table.concat(fields, ",") .. "}"
end

local function format_ms(value)
    if value == nil then
        return "-"
    end
    if value < 0.005 then
        -- IcmpSendEcho reports sub-millisecond replies as 0.
        return "<1 ms"
    end
    if value < 1 then
        return string.format("%.2f ms", value)
    end
    if value < 100 then
        return string.format("%.1f ms", value)
    end
    return string.format("%.0f ms", value)
end

--------------------------------------------------------------------------------
-- Time & Sleep
--------------------------------------------------------------------------------

local qpc_frequency = 0

if IS_WINDOWS then
    local frequency = ffi.new("long long[1]")
    if ffi.C.QueryPerformanceFrequency(frequency) ~= 0 then
        qpc_frequency = tonumber(frequency[0])
    end
end

local function now_ms()
    if IS_WINDOWS then
        if qpc_frequency > 0 then
            local counter = ffi.new("long long[1]")
            ffi.C.QueryPerformanceCounter(counter)
            return tonumber(counter[0]) * 1000 / qpc_frequency
        end
        return tonumber(ffi.C.GetTickCount64())
    end

    local timeval = ffi.new("struct timeval")
    ffi.C.gettimeofday(timeval, nil)
    return tonumber(timeval.tv_sec) * 1000 + tonumber(timeval.tv_usec) / 1000
end

local function sleep_ms(milliseconds)
    milliseconds = math.max(0, math.floor(milliseconds))
    if IS_WINDOWS then
        ffi.C.Sleep(milliseconds)
    else
        ffi.C.usleep(milliseconds * 1000)
    end
end

--------------------------------------------------------------------------------
-- Error Text
--------------------------------------------------------------------------------

local WINDOWS_ERRORS = {
    [5] = "access denied",
    [8] = "not enough memory",
    [87] = "invalid parameter",
    [111] = "buffer too small",
    [232] = "no network adapters are configured",
    [10013] = "permission denied",
    [10014] = "bad address",
    [10022] = "invalid argument",
    [10038] = "socket operation on a non-socket",
    [10047] = "address family not supported",
    [10049] = "cannot assign requested address",
    [10050] = "network is down",
    [10051] = "network is unreachable",
    [10052] = "network dropped connection",
    [10054] = "connection reset by peer",
    [10060] = "connection timed out",
    [10061] = "connection refused",
    [10064] = "host is down",
    [10065] = "host is unreachable",
    [11001] = "host not found",
    [11002] = "temporary name resolution failure",
    [11003] = "name resolution failure",
    [11004] = "no data of the requested type",
    [11010] = "request timed out",
}

local function errno_text(code)
    code = tonumber(code) or 0
    if IS_WINDOWS then
        return WINDOWS_ERRORS[code] or ("socket error " .. code)
    end

    local message = ffi.C.strerror(code)
    if message == nil then
        return "errno " .. code
    end
    return ffi.string(message)
end

local function gai_error_text(code)
    if IS_WINDOWS then
        return WINDOWS_ERRORS[code] or ("name resolution error " .. tostring(code))
    end
    local message = ffi.C.gai_strerror(code)
    if message == nil then
        return "name resolution error " .. tostring(code)
    end
    return ffi.string(message)
end

local function win_error_text(code)
    return WINDOWS_ERRORS[code] or ("Windows error " .. tostring(code))
end

local function socket_error()
    if IS_WINDOWS then
        return net.WSAGetLastError()
    end
    return ffi.errno()
end

local function classify_error(code)
    if code == 0 then
        return "open"
    end
    if code == ERR_CONNREFUSED then
        return "closed", errno_text(code)
    end
    if code == ERR_TIMEDOUT then
        return "filtered", errno_text(code)
    end
    if code == ERR_HOSTUNREACH or code == ERR_NETUNREACH then
        return "filtered", errno_text(code)
    end
    if code == ERR_ACCES or code == ERR_PERM then
        return "error", errno_text(code)
    end
    return "error", errno_text(code)
end

--------------------------------------------------------------------------------
-- Address Formatting
--------------------------------------------------------------------------------

local function format_ipv4(raw)
    local first, second, third, fourth = raw:byte(1, 4)
    return string.format("%d.%d.%d.%d", first, second, third, fourth)
end

local function format_ipv6(raw)
    local groups = {}
    local first_ten_zero = true
    local bytes = { raw:byte(1, 16) }

    for index = 1, 10 do
        if bytes[index] ~= 0 then
            first_ten_zero = false
            break
        end
    end

    if first_ten_zero and bytes[11] == 0xFF and bytes[12] == 0xFF then
        return string.format("::ffff:%d.%d.%d.%d", bytes[13], bytes[14], bytes[15], bytes[16])
    end

    for index = 0, 7 do
        local high = bytes[index * 2 + 1]
        local low = bytes[index * 2 + 2]
        groups[index + 1] = high * 256 + low
    end

    local best_start, best_length
    local run_start, run_length = nil, 0

    for index = 1, 8 do
        if groups[index] == 0 then
            if run_start == nil then
                run_start = index
                run_length = 0
            end
            run_length = run_length + 1
            if run_length > (best_length or 0) then
                best_start = run_start
                best_length = run_length
            end
        else
            run_start = nil
            run_length = 0
        end
    end

    local parts = {}
    for index = 1, 8 do
        parts[index] = string.format("%x", groups[index])
    end

    if best_length and best_length >= 2 then
        local left = table.concat(parts, ":", 1, best_start - 1)
        local right = table.concat(parts, ":", best_start + best_length, 8)

        if left == "" and right == "" then
            return "::"
        end
        if left == "" then
            return "::" .. right
        end
        if right == "" then
            return left .. "::"
        end
        return left .. "::" .. right
    end

    return table.concat(parts, ":")
end

local function count_mask_bits(mask)
    local bits = 0
    for index = 1, #mask do
        local value = mask:byte(index)
        while value > 0 do
            bits = bits + bit.band(value, 1)
            value = bit.rshift(value, 1)
        end
    end
    return bits
end

local function count_dotted_mask_bits(mask)
    local first, second, third, fourth =
        tostring(mask):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not first then
        return 0
    end

    local bytes = {
        tonumber(first),
        tonumber(second),
        tonumber(third),
        tonumber(fourth),
    }
    return count_mask_bits(string.char(unpack(bytes)))
end

local function format_ipv4_le_hex(hex)
    if type(hex) ~= "string" or #hex ~= 8 then
        return nil
    end
    local first = tonumber(hex:sub(7, 8), 16)
    local second = tonumber(hex:sub(5, 6), 16)
    local third = tonumber(hex:sub(3, 4), 16)
    local fourth = tonumber(hex:sub(1, 2), 16)

    if not (first and second and third and fourth) then
        return nil
    end
    return string.format("%d.%d.%d.%d", first, second, third, fourth)
end

local function format_mac(address, length)
    length = math.min(tonumber(length) or 0, 8)
    if length <= 0 then
        return nil
    end

    local octets = {}
    for index = 0, length - 1 do
        octets[#octets + 1] = string.format("%02X", address[index])
    end
    return table.concat(octets, ":")
end

local function ipv4_to_u32(raw)
    local first, second, third, fourth = raw:byte(1, 4)
    return first + second * 256 + third * 65536 + fourth * 16777216
end

--------------------------------------------------------------------------------
-- Ports & Services
--------------------------------------------------------------------------------

local SERVICE_NAMES = {
    [20] = "ftp-data",
    [21] = "ftp",
    [22] = "ssh",
    [23] = "telnet",
    [25] = "smtp",
    [53] = "dns",
    [67] = "dhcp",
    [80] = "http",
    [110] = "pop3",
    [123] = "ntp",
    [135] = "msrpc",
    [139] = "netbios",
    [143] = "imap",
    [161] = "snmp",
    [389] = "ldap",
    [443] = "https",
    [445] = "smb",
    [465] = "smtps",
    [514] = "syslog",
    [587] = "submission",
    [631] = "ipp",
    [636] = "ldaps",
    [993] = "imaps",
    [995] = "pop3s",
    [1080] = "socks",
    [1433] = "mssql",
    [1521] = "oracle",
    [1723] = "pptp",
    [2049] = "nfs",
    [2181] = "zookeeper",
    [2375] = "docker",
    [2376] = "docker-tls",
    [3000] = "dev-http",
    [3306] = "mysql",
    [3389] = "rdp",
    [5000] = "dev-http",
    [5432] = "postgres",
    [5672] = "amqp",
    [5900] = "vnc",
    [5985] = "winrm",
    [5986] = "winrm-tls",
    [6379] = "redis",
    [8000] = "dev-http",
    [8080] = "http-alt",
    [8443] = "https-alt",
    [8888] = "dev-http",
    [9000] = "dev-http",
    [9090] = "prometheus",
    [9200] = "elasticsearch",
    [11211] = "memcached",
    [27017] = "mongodb",
}

local DEFAULT_SCAN_PORTS = {
    21, 22, 23, 25, 53, 80, 110, 143, 443, 445,
    3306, 3389, 5432, 5900, 6379, 8000, 8080, 8443, 9000, 27017,
}

local function service_name(port)
    return SERVICE_NAMES[port]
end

local function parse_ports(specification)
    if specification == nil or trim(specification) == "" then
        return nil, "empty port specification"
    end

    local ports = {}
    local seen = {}

    for chunk in tostring(specification):gmatch("[^,]+") do
        chunk = trim(chunk)
        local first, last = chunk:match("^(%d+)%-(%d+)$")

        if first then
            first, last = tonumber(first), tonumber(last)
            if not first or not last or first < 1 or last > 65535 or first > last then
                return nil, string.format(
                    "invalid port range '%s' (use ascending values within 1-65535)", chunk)
            end
            for port = first, last do
                if not seen[port] then
                    seen[port] = true
                    ports[#ports + 1] = port
                end
            end
        else
            local port = chunk:match("^%d+$") and tonumber(chunk)
            if not port or port < 1 or port > 65535 then
                return nil, string.format(
                    "invalid port '%s' (valid range is 1-65535)", chunk)
            end
            if not seen[port] then
                seen[port] = true
                ports[#ports + 1] = port
            end
        end
    end

    if #ports == 0 then
        return nil, "no ports specified"
    end

    table.sort(ports)
    return ports
end

--------------------------------------------------------------------------------
-- Sockets & Name Resolution
--------------------------------------------------------------------------------

local wsa_initialized = false

local function init_wsa()
    if not IS_WINDOWS or wsa_initialized then
        return true
    end

    local data = ffi.new("WSADATA")
    local result = net.WSAStartup(0x0202, data)
    if result ~= 0 then
        return false, "WSAStartup failed: " .. errno_text(result)
    end
    wsa_initialized = true
    return true
end

local function open_socket(family, socket_type)
    local initialized, startup_error = init_wsa()
    if not initialized then
        return nil, startup_error
    end

    local fd = net.socket(family, socket_type or SOCK_STREAM, 0)

    if IS_WINDOWS then
        if fd == INVALID_SOCKET then
            return nil, net.WSAGetLastError()
        end
        return fd
    end

    if fd < 0 then
        return nil, ffi.errno()
    end
    return fd
end

local function close_socket(fd)
    if IS_WINDOWS then
        net.closesocket(fd)
    else
        net.close(fd)
    end
end

local function set_nonblocking(fd)
    if IS_WINDOWS then
        local enabled = ffi.new("unsigned long[1]", 1)
        return net.ioctlsocket(fd, FIONBIO, enabled) == 0
    end

    local flags = net.fcntl(fd, F_GETFL, 0)
    if flags < 0 then
        return false
    end
    return net.fcntl(fd, F_SETFL, bit.bor(flags, O_NONBLOCK)) == 0
end

-- Waits for non-blocking connects to settle.
-- Windows WSAPoll does not report failed connects until the TCP retry timer expires,
-- so select() is used there: writable means connected, exceptional means failed.
-- Returns a table keyed by item index; a true value means the socket is ready.
local function wait_for_connections(items, timeout_ms)
    local ready = {}
    if #items == 0 then
        return ready
    end

    if IS_WINDOWS then
        local write_set = ffi.new("fd_set")
        local except_set = ffi.new("fd_set")
        write_set.fd_count = 0
        except_set.fd_count = 0

        for index, item in ipairs(items) do
            if index > 64 then
                break
            end
            write_set.fd_array[index - 1] = item.fd
            write_set.fd_count = write_set.fd_count + 1
            except_set.fd_array[index - 1] = item.fd
            except_set.fd_count = except_set.fd_count + 1
        end

        local timeout = ffi.new("struct timeval")
        timeout.tv_sec = math.floor(timeout_ms / 1000)
        timeout.tv_usec = (timeout_ms % 1000) * 1000

        local result = net.select(0, nil, write_set, except_set, timeout)
        if result <= 0 then
            return ready
        end

        local function contains(set, socket)
            for index = 0, tonumber(set.fd_count) - 1 do
                if set.fd_array[index] == socket then
                    return true
                end
            end
            return false
        end

        for index, item in ipairs(items) do
            if contains(write_set, item.fd) or contains(except_set, item.fd) then
                ready[index] = true
            end
        end
        return ready
    end

    local descriptors = ffi.new("struct pollfd[?]", #items)
    for index, item in ipairs(items) do
        descriptors[index - 1].fd = item.fd
        descriptors[index - 1].events = POLLOUT
        descriptors[index - 1].revents = 0
    end

    local result = net.poll(descriptors, #items, timeout_ms)
    if result > 0 then
        for index = 1, #items do
            ready[index] = descriptors[index - 1].revents ~= 0
        end
    end
    return ready
end

local function wait_for_readable(fd, timeout_ms)
    local descriptor = ffi.new("struct pollfd[1]")
    descriptor[0].fd = fd
    descriptor[0].events = POLLIN
    descriptor[0].revents = 0
    return net.poll(descriptor, 1, timeout_ms) > 0
end

local function get_socket_error(fd)
    local value = ffi.new("int[1]", 0)
    local length = ffi.new("int[1]", ffi.sizeof("int"))
    local result = net.getsockopt(fd, SOL_SOCKET, SO_ERROR, ffi.cast("char*", value), length)
    if result ~= 0 then
        return 0
    end
    return tonumber(value[0])
end

-- Returns the sockaddr storage and its length. Callers cast the storage at the
-- call site so the cdata stays alive for the duration of the system call.
local function make_sockaddr(entry, port)
    if entry.family == AF_INET then
        local address = ffi.new("struct sockaddr_in")
        address.sin_family = AF_INET
        address.sin_port = net.htons(port or 0)
        ffi.copy(address.sin_addr, entry.bytes, 4)
        return address, ffi.sizeof("struct sockaddr_in")
    end

    local address = ffi.new("struct sockaddr_in6")
    address.sin6_family = AF_INET6
    address.sin6_port = net.htons(port or 0)
    ffi.copy(address.sin6_addr, entry.bytes, 16)
    address.sin6_scope_id = entry.scope or 0
    return address, ffi.sizeof("struct sockaddr_in6")
end

local function sockaddr_to_entry(address)
    local family = tonumber(address.sa_family)

    if family == AF_INET then
        local ipv4 = ffi.cast("struct sockaddr_in*", address)
        local raw = ffi.string(ipv4.sin_addr, 4)
        return {
            family = AF_INET,
            address = format_ipv4(raw),
            bytes = raw,
        }
    end

    if family == AF_INET6 then
        local ipv6 = ffi.cast("struct sockaddr_in6*", address)
        local raw = ffi.string(ipv6.sin6_addr, 16)
        return {
            family = AF_INET6,
            address = format_ipv6(raw),
            bytes = raw,
            scope = tonumber(ipv6.sin6_scope_id),
        }
    end

    return nil
end

local function resolve_host(host, family)
    local initialized, startup_error = init_wsa()
    if not initialized then
        return nil, startup_error
    end

    local hints = ffi.new("struct addrinfo")
    hints.ai_family = family or AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM

    local result = ffi.new("struct addrinfo*[1]")
    local started = now_ms()
    local code = net.getaddrinfo(host, nil, hints, result)

    if code ~= 0 then
        return nil, gai_error_text(code), now_ms() - started
    end

    local entries = {}
    local seen = {}
    local node = result[0]

    while node ~= nil do
        if node.ai_addr ~= nil then
            local entry = sockaddr_to_entry(node.ai_addr)
            if entry and not seen[entry.address] then
                seen[entry.address] = true
                entries[#entries + 1] = entry
            end
        end
        node = node.ai_next
    end

    net.freeaddrinfo(result[0])

    if #entries == 0 then
        return nil, "no addresses returned", now_ms() - started
    end

    return entries, nil, now_ms() - started
end

local function reverse_lookup(entry)
    local address, address_length = make_sockaddr(entry, 0)
    local host_buffer = ffi.new("char[256]")
    local code = net.getnameinfo(ffi.cast("struct sockaddr*", address), address_length,
        host_buffer, 256, nil, 0, NI_NAMEREQD)

    if code ~= 0 then
        return nil
    end
    return ffi.string(host_buffer)
end

local function split_target(target)
    target = tostring(target)

    local bracketed_host, bracketed_port = target:match("^%[(.+)%]:(%d+)$")
    if bracketed_host then
        return bracketed_host, tonumber(bracketed_port)
    end

    local bracketed = target:match("^%[(.+)%]$")
    if bracketed then
        return bracketed, nil
    end

    local host, port = target:match("^([^:]+):(%d+)$")
    if host then
        return host, tonumber(port)
    end
    return target, nil
end

--------------------------------------------------------------------------------
-- TCP Probes
--------------------------------------------------------------------------------

local function tcp_connect(entry, port, timeout_ms)
    local fd, error_code = open_socket(entry.family, SOCK_STREAM)
    if not fd then
        return false, "error", errno_text(error_code), 0
    end

    set_nonblocking(fd)
    local address, address_length = make_sockaddr(entry, port)
    local started = now_ms()
    local result = net.connect(fd, ffi.cast("struct sockaddr*", address), address_length)

    if result ~= 0 then
        local code = socket_error()
        if code ~= ERR_WOULDBLOCK and code ~= ERR_INPROGRESS then
            close_socket(fd)
            local state, note = classify_error(code)
            return false, state, note, now_ms() - started
        end

        local ready = wait_for_connections({ { fd = fd } }, timeout_ms)
        local code_after = get_socket_error(fd)
        local elapsed = now_ms() - started
        close_socket(fd)

        if ready[1] then
            if code_after == 0 then
                return true, "open", nil, elapsed
            end
            local state, note = classify_error(code_after)
            return false, state, note, elapsed
        end

        if code_after ~= 0 then
            local state, note = classify_error(code_after)
            return false, state, note, elapsed
        end

        return false, "filtered", "no response within timeout", elapsed
    end

    local elapsed = now_ms() - started
    close_socket(fd)
    return true, "open", nil, elapsed
end

local function scan_ports(entry, ports, options)
    local results = {}
    local pending = {}
    local next_index = 1
    local maximum_concurrency = IS_WINDOWS and 64 or 512
    local concurrency = math.max(1, math.min(options.concurrency or 128,
        maximum_concurrency))
    local timeout_ms = options.timeout_ms or 800

    local function record(item, state, note, latency)
        close_socket(item.fd)
        results[#results + 1] = {
            port = item.port,
            state = state,
            note = note,
            latency_ms = latency or (now_ms() - item.started),
        }
    end

    while next_index <= #ports or #pending > 0 do
        while next_index <= #ports and #pending < concurrency do
            local port = ports[next_index]
            next_index = next_index + 1

            local fd, error_code = open_socket(entry.family, SOCK_STREAM)
            if not fd then
                results[#results + 1] = {
                    port = port,
                    state = "error",
                    note = errno_text(error_code),
                }
            else
                set_nonblocking(fd)
                local address, address_length = make_sockaddr(entry, port)
                local started = now_ms()
                local result = net.connect(fd, ffi.cast("struct sockaddr*", address),
                    address_length)

                if result == 0 then
                    close_socket(fd)
                    results[#results + 1] = {
                        port = port,
                        state = "open",
                        latency_ms = now_ms() - started,
                    }
                else
                    local code = socket_error()
                    if code == ERR_WOULDBLOCK or code == ERR_INPROGRESS then
                        pending[#pending + 1] = {
                            fd = fd,
                            port = port,
                            started = started,
                        }
                    else
                        close_socket(fd)
                        local state, note = classify_error(code)
                        results[#results + 1] = {
                            port = port,
                            state = state,
                            note = note,
                        }
                    end
                end
            end
        end

        if #pending > 0 then
            local ready = wait_for_connections(pending, SCAN_POLL_SLICE_MS)
            local current_time = now_ms()
            local remaining = {}

            for index, item in ipairs(pending) do
                if ready[index] then
                    local code = get_socket_error(item.fd)
                    if code == 0 then
                        record(item, "open", nil, current_time - item.started)
                    else
                        local state, note = classify_error(code)
                        record(item, state, note, current_time - item.started)
                    end
                elseif current_time - item.started >= timeout_ms then
                    local code = get_socket_error(item.fd)
                    if code ~= 0 then
                        local state, note = classify_error(code)
                        record(item, state, note, current_time - item.started)
                    else
                        record(item, "filtered", "no response within timeout",
                            current_time - item.started)
                    end
                else
                    remaining[#remaining + 1] = item
                end
            end

            pending = remaining
        end
    end

    table.sort(results, function(left, right)
        return left.port < right.port
    end)
    return results
end

--------------------------------------------------------------------------------
-- ICMP Ping
--------------------------------------------------------------------------------

local function icmp_checksum(buffer, length)
    local sum = 0
    local index = 0

    while index + 1 < length do
        sum = sum + buffer[index] * 256 + buffer[index + 1]
        sum = bit.band(sum, 0xFFFF) + bit.rshift(sum, 16)
        index = index + 2
    end

    if length % 2 == 1 then
        sum = sum + buffer[length - 1] * 256
        sum = bit.band(sum, 0xFFFF) + bit.rshift(sum, 16)
    end

    while bit.rshift(sum, 16) > 0 do
        sum = bit.band(sum, 0xFFFF) + bit.rshift(sum, 16)
    end

    return bit.band(bit.bnot(sum), 0xFFFF)
end

local function build_echo_request(sequence, identifier)
    local size = 8 + ICMP_ECHO_PAYLOAD
    local packet = ffi.new("uint8_t[?]", size)

    packet[0] = 8
    packet[1] = 0
    packet[4] = math.floor(identifier / 256) % 256
    packet[5] = identifier % 256
    packet[6] = math.floor(sequence / 256) % 256
    packet[7] = sequence % 256

    for index = 8, size - 1 do
        packet[index] = bit.band(index * 7 + sequence, 0xFF)
    end

    local checksum = icmp_checksum(packet, size)
    packet[2] = math.floor(checksum / 256) % 256
    packet[3] = checksum % 256
    return packet, size
end

local function parse_icmp_reply(buffer, length)
    if length < 8 then
        return nil
    end

    local offset = 0
    if bit.rshift(buffer[0], 4) == 4 then
        offset = bit.band(buffer[0], 0x0F) * 4
    end

    if length < offset + 8 then
        return nil
    end

    return {
        kind = buffer[offset],
        sequence = buffer[offset + 6] * 256 + buffer[offset + 7],
        ttl = offset > 0 and buffer[8] or nil,
    }
end

local function icmp_permission_error(code)
    return string.format("cannot open an ICMP socket: %s", errno_text(code)),
        "run with sudo, grant cap_net_raw to LuaJIT "
        .. "(sudo setcap cap_net_raw+ep \"$(command -v luajit)\"), "
        .. "or use 'fnet ping HOST --tcp'"
end

local function ping_posix(entry, options)
    local fd = net.socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
    if fd < 0 then
        fd = net.socket(AF_INET, SOCK_RAW, IPPROTO_ICMP)
    end
    if fd < 0 then
        local message, hint = icmp_permission_error(ffi.errno())
        return nil, message, hint
    end

    local identifier = 0x464E
    local replies = {}

    for sequence = 1, options.count do
        local packet, packet_size = build_echo_request(sequence, identifier)
        local address, address_length = make_sockaddr(entry, 0)
        local started = now_ms()
        local sent = net.sendto(fd, packet, packet_size, 0,
            ffi.cast("struct sockaddr*", address), address_length)
        local outcome = { sequence = sequence, ok = false }

        if sent ~= packet_size then
            outcome.note = "send failed: " .. errno_text(ffi.errno())
        else
            local deadline = started + options.timeout_ms
            while now_ms() < deadline do
                local wait_ms = math.max(1, math.floor(deadline - now_ms()))

                if wait_for_readable(fd, wait_ms) then
                    local buffer = ffi.new("uint8_t[512]")
                    local received = net.recvfrom(fd, buffer, 512, 0, nil, nil)
                    if received > 0 then
                        local reply = parse_icmp_reply(buffer, received)
                        if reply and reply.kind == 0 and reply.sequence == sequence then
                            outcome.ok = true
                            outcome.rtt_ms = now_ms() - started
                            outcome.ttl = reply.ttl
                            break
                        end
                    end
                end
            end

            if not outcome.ok then
                outcome.note = "timeout"
            end
        end

        replies[#replies + 1] = outcome

        if sequence < options.count then
            local remaining = options.interval_ms - (now_ms() - started)
            if remaining > 0 then
                sleep_ms(remaining)
            end
        end
    end

    close_socket(fd)
    return replies
end

local function ping_windows(entry, options)
    local handle = iphlpapi.IcmpCreateFile()
    if handle == nil or handle == INVALID_HANDLE then
        local code = ffi.C.GetLastError()
        return nil, "IcmpCreateFile failed: " .. win_error_text(code)
    end

    local payload = ffi.new("uint8_t[32]")
    local pattern = "fnet-icmp-payload"
    for index = 0, 31 do
        payload[index] = pattern:byte((index % #pattern) + 1)
    end

    -- IcmpSendEcho requires room for the reply structure, the echoed payload,
    -- and the ICMP/IP headers; a tight sizeof(reply) + payload buffer fails
    -- with IP_GENERAL_FAILURE (11050) on Windows 10/11.
    local reply_size = ffi.sizeof("ICMP_ECHO_REPLY") + ICMP_ECHO_PAYLOAD + 256
    local destination = ipv4_to_u32(entry.bytes)
    local replies = {}

    for sequence = 1, options.count do
        local reply_buffer = ffi.new("uint8_t[?]", reply_size)
        local started = now_ms()

        local count = iphlpapi.IcmpSendEcho(
            handle,
            destination,
            payload,
            32,
            nil,
            reply_buffer,
            reply_size,
            math.max(1, math.floor(options.timeout_ms))
        )

        local outcome = { sequence = sequence, ok = false }

        if tonumber(count) > 0 then
            local reply = ffi.cast("ICMP_ECHO_REPLY*", reply_buffer)
            if reply.Status == 0 then
                outcome.ok = true
                outcome.rtt_ms = tonumber(reply.RoundTripTime)
            else
                outcome.note = "ICMP status " .. tonumber(reply.Status)
            end
        else
            local code = ffi.C.GetLastError()
            outcome.note = (code == 11010) and "timeout"
                or ("timeout (" .. win_error_text(code) .. ")")
        end

        replies[#replies + 1] = outcome

        if sequence < options.count then
            local remaining = options.interval_ms - (now_ms() - started)
            if remaining > 0 then
                sleep_ms(remaining)
            end
        end
    end

    iphlpapi.IcmpCloseHandle(handle)
    return replies
end

local function ping_host(entry, options)
    if entry.family ~= AF_INET then
        return nil, "the ICMP engine supports IPv4 only",
            "resolve an IPv4 address or measure handshakes with 'fnet ping HOST --tcp'"
    end

    if IS_WINDOWS then
        return ping_windows(entry, options)
    end
    return ping_posix(entry, options)
end

local function summarize_replies(replies)
    local received, minimum, maximum, total = 0, nil, nil, 0

    for _, reply in ipairs(replies) do
        if reply.ok then
            received = received + 1
            local rtt = reply.rtt_ms or 0
            minimum = minimum and math.min(minimum, rtt) or rtt
            maximum = maximum and math.max(maximum, rtt) or rtt
            total = total + rtt
        end
    end

    return {
        sent = #replies,
        received = received,
        loss_percent = #replies > 0 and (#replies - received) * 100 / #replies or 0,
        min_ms = minimum,
        avg_ms = received > 0 and total / received or nil,
        max_ms = maximum,
    }
end

--------------------------------------------------------------------------------
-- Interface Discovery
--------------------------------------------------------------------------------

local ADAPTER_TYPES = {
    [6] = "ethernet",
    [23] = "ppp",
    [24] = "loopback",
    [53] = "virtual",
    [71] = "wireless",
    [131] = "tunnel",
}

local function adapter_type(numeric_type)
    return ADAPTER_TYPES[numeric_type] or ("type-" .. tostring(numeric_type))
end

local function windows_interface_head(adapter, field)
    local base = ffi.cast("uint8_t*", adapter)
    return ffi.cast("IP_ADDR_STRING*", base + ffi.offsetof("IP_ADAPTER_INFO", field))
end

local function windows_interfaces()
    local size = ffi.new("unsigned long[1]", 0)
    local code = iphlpapi.GetAdaptersInfo(nil, size)

    if code ~= ERROR_BUFFER_OVERFLOW then
        return {}, "GetAdaptersInfo failed: " .. win_error_text(code)
    end
    if size[0] == 0 then
        return {}, nil
    end

    local buffer = ffi.new("uint8_t[?]", size[0])
    code = iphlpapi.GetAdaptersInfo(ffi.cast("IP_ADAPTER_INFO*", buffer), size)
    if code ~= 0 then
        return {}, "GetAdaptersInfo failed: " .. win_error_text(code)
    end

    local entries = {}
    local adapter = ffi.cast("IP_ADAPTER_INFO*", buffer)

    while adapter ~= nil do
        local entry = {
            name = ffi.string(adapter.Description),
            type = adapter_type(tonumber(adapter.Type)),
            state = "down",
            mtu = nil,
            mac = format_mac(adapter.Address, tonumber(adapter.AddressLength)),
            ipv4 = {},
            ipv6 = {},
            gateways = {},
        }

        local address_node = windows_interface_head(adapter, "IpAddressList")
        while address_node ~= nil do
            local address = ffi.string(address_node.IpAddress)
            local mask = ffi.string(address_node.IpMask)
            if address ~= "" and address ~= "0.0.0.0" then
                entry.ipv4[#entry.ipv4 + 1] = {
                    address = address,
                    prefix = count_dotted_mask_bits(mask),
                }
            end
            address_node = address_node.Next
        end

        local gateway_node = windows_interface_head(adapter, "GatewayList")
        while gateway_node ~= nil do
            local address = ffi.string(gateway_node.IpAddress)
            if address ~= "" and address ~= "0.0.0.0" then
                entry.gateways[#entry.gateways + 1] = address
            end
            gateway_node = gateway_node.Next
        end

        if #entry.ipv4 > 0 or #entry.ipv6 > 0 then
            entry.state = "up"
        end

        if entry.name == "" then
            entry.name = ffi.string(adapter.AdapterName)
        end

        entries[#entries + 1] = entry
        adapter = adapter.Next
    end

    return entries, nil
end

local function read_sysfs(interface_name, file_name)
    local content = read_file("/sys/class/net/" .. interface_name .. "/" .. file_name)
    if not content then
        return nil
    end
    return trim(content)
end

local function interface_type(name)
    if name == "lo" then
        return "loopback"
    end
    if name:match("^wl") or name:match("^wlan") then
        return "wireless"
    end
    if name:match("^en") or name:match("^eth") then
        return "ethernet"
    end
    if name:match("^br") or name:match("^virbr") or name:match("^docker")
        or name:match("^veth") then
        return "bridge"
    end
    if name:match("^tun") or name:match("^tap") or name:match("^wg")
        or name:match("^ppp") then
        return "tunnel"
    end
    return "other"
end

local function prefix_from_sockaddr(address)
    local family = tonumber(address.sa_family)
    if family == AF_INET then
        local ipv4 = ffi.cast("struct sockaddr_in*", address)
        return count_mask_bits(ffi.string(ipv4.sin_addr, 4))
    end
    if family == AF_INET6 then
        local ipv6 = ffi.cast("struct sockaddr_in6*", address)
        return count_mask_bits(ffi.string(ipv6.sin6_addr, 16))
    end
    return 0
end

local function parse_proc_net_route(text)
    local gateways = {}

    for line in tostring(text):gmatch("[^\n]+") do
        local interface_name, destination, gateway, flags =
            line:match("^(%S+)%s+(%x+)%s+(%x+)%s+(%x+)%s+%d+%s+%d+%s+%d+%s+(%x+)")

        if interface_name and destination == "00000000" then
            local numeric_flags = tonumber(flags, 16)
            if numeric_flags and bit.band(numeric_flags, 0x0003) == 0x0003 then
                local formatted = format_ipv4_le_hex(gateway)
                if formatted then
                    gateways[interface_name] = formatted
                end
            end
        end
    end

    return gateways
end

local function linux_interfaces()
    local head = ffi.new("struct ifaddrs*[1]")

    if ffi.C.getifaddrs(head) ~= 0 then
        return {}, "getifaddrs failed: " .. errno_text(ffi.errno())
    end

    local by_name = {}
    local order = {}
    local node = head[0]

    while node ~= nil do
        local name = ffi.string(node.ifa_name)
        local entry = by_name[name]

        if not entry then
            entry = {
                name = name,
                type = interface_type(name),
                state = "down",
                mtu = tonumber(read_sysfs(name, "mtu")),
                mac = read_sysfs(name, "address"),
                ipv4 = {},
                ipv6 = {},
                gateways = {},
            }
            by_name[name] = entry
            order[#order + 1] = entry
        end

        if bit.band(tonumber(node.ifa_flags), IFF_UP) ~= 0 then
            entry.state = "up"
        end

        local address = node.ifa_addr
        if address ~= nil then
            local family = tonumber(address.sa_family)
            local prefix = node.ifa_netmask ~= nil
                and prefix_from_sockaddr(node.ifa_netmask) or 0

            if family == AF_INET then
                local ipv4 = ffi.cast("struct sockaddr_in*", address)
                entry.ipv4[#entry.ipv4 + 1] = {
                    address = format_ipv4(ffi.string(ipv4.sin_addr, 4)),
                    prefix = prefix,
                }
            elseif family == AF_INET6 then
                local ipv6 = ffi.cast("struct sockaddr_in6*", address)
                entry.ipv6[#entry.ipv6 + 1] = {
                    address = format_ipv6(ffi.string(ipv6.sin6_addr, 16)),
                    prefix = prefix,
                }
            end
        end

        node = node.ifa_next
    end

    ffi.C.freeifaddrs(head[0])

    local route_file = read_file("/proc/net/route")
    if route_file then
        local gateways = parse_proc_net_route(route_file)
        for name, gateway in pairs(gateways) do
            local entry = by_name[name]
            if entry then
                entry.gateways[#entry.gateways + 1] = gateway
            end
        end
    end

    table.sort(order, function(left, right)
        return left.name < right.name
    end)
    return order, nil
end

local function collect_interfaces()
    if IS_WINDOWS then
        return windows_interfaces()
    end
    if IS_LINUX then
        return linux_interfaces()
    end
    return {}, "unsupported platform: " .. OS
end

local function first_address(entry)
    if #entry.ipv4 > 0 then
        local address = entry.ipv4[1]
        return string.format("%s/%d", address.address, address.prefix)
    end
    if #entry.ipv6 > 0 then
        local address = entry.ipv6[1]
        return string.format("%s/%d", address.address, address.prefix)
    end
    return "-"
end

local function all_addresses(entry)
    local addresses = {}
    for _, address in ipairs(entry.ipv4) do
        addresses[#addresses + 1] = string.format("%s/%d", address.address, address.prefix)
    end
    for _, address in ipairs(entry.ipv6) do
        addresses[#addresses + 1] = string.format("%s/%d", address.address, address.prefix)
    end
    return addresses
end

--------------------------------------------------------------------------------
-- Output Helpers
--------------------------------------------------------------------------------

local function print_json(payload)
    print(json_encode(payload))
end

local function family_label(family)
    if family == AF_INET then
        return "IPv4"
    end
    if family == AF_INET6 then
        return "IPv6"
    end
    return tostring(family)
end

local function format_port_list(ports, limit)
    local shown = {}
    for index = 1, math.min(#ports, limit or #ports) do
        shown[#shown + 1] = tostring(ports[index])
    end
    local text = table.concat(shown, ",")
    if limit and #ports > limit then
        text = text .. ",...(" .. #ports .. " total)"
    end
    return text
end

--------------------------------------------------------------------------------
-- Command: ifaces
--------------------------------------------------------------------------------

local function cmd_ifaces(options)
    local interfaces, error_message = collect_interfaces()
    if error_message then
        die(error_message, "check that the network stack is available")
    end

    if options.json then
        print_json({ interfaces = interfaces })
        return
    end

    local show_mtu = false
    for _, entry in ipairs(interfaces) do
        if entry.mtu then
            show_mtu = true
            break
        end
    end

    print(paint("  Network interfaces", C.b_cyan))

    local header_format = show_mtu
        and "  %-3s %-26s %-10s %-6s %-6s %-17s %-22s %s"
        or "  %-3s %-26s %-10s %-6s %-17s %-22s %s"
    if show_mtu then
        print(string.format(header_format,
            "#", "IFACE", "TYPE", "STATE", "MTU", "MAC", "ADDRESS", "GATEWAY"))
    else
        print(string.format(header_format,
            "#", "IFACE", "TYPE", "STATE", "MAC", "ADDRESS", "GATEWAY"))
    end

    local row_format = show_mtu
        and "  %-3s %-26s %-10s %s %-6s %-17s %-22s %s"
        or "  %-3s %-26s %-10s %s %-17s %-22s %s"

    for index, entry in ipairs(interfaces) do
        local addresses = all_addresses(entry)
        if #addresses == 0 then
            addresses = { "-" }
        end

        local gateway = #entry.gateways > 0 and table.concat(entry.gateways, ", ") or "-"
        local mtu_text = entry.mtu and tostring(entry.mtu) or "-"
        local state_color = entry.state == "up" and C.green or C.yellow
        local state_text = paint(string.format("%-6s", entry.state), state_color)
        local mac_text = entry.mac or "-"

        if show_mtu then
            print(string.format(row_format, tostring(index), fit(entry.name, 26),
                fit(entry.type, 10), state_text, mtu_text, mac_text,
                fit(addresses[1], 22), gateway))
        else
            print(string.format(row_format, tostring(index), fit(entry.name, 26),
                fit(entry.type, 10), state_text, mac_text,
                fit(addresses[1], 22), gateway))
        end

        for extra_index = 2, #addresses do
            if show_mtu then
                print(string.format(row_format, "", "", "", string.rep(" ", 6), "",
                    "", fit(addresses[extra_index], 22), ""))
            else
                print(string.format(row_format, "", "", "", string.rep(" ", 6),
                    "", fit(addresses[extra_index], 22), ""))
            end
        end
    end

    print(string.format("  %s%d interface(s)%s", C.gray, #interfaces, C.reset))
end

--------------------------------------------------------------------------------
-- Command: dns
--------------------------------------------------------------------------------

local function cmd_dns(host, options)
    local entries, error_message, elapsed = resolve_host(host, AF_UNSPEC)
    if not entries then
        die(string.format("cannot resolve '%s': %s", host, tostring(error_message)),
            "check the hostname, DNS settings, and network connection")
    end

    if options.reverse then
        for _, entry in ipairs(entries) do
            entry.ptr = reverse_lookup(entry)
        end
    end

    if options.json then
        local addresses = {}
        for _, entry in ipairs(entries) do
            addresses[#addresses + 1] = {
                address = entry.address,
                family = family_label(entry.family),
                scope = entry.scope,
                ptr = entry.ptr,
            }
        end

        print_json({
            host = host,
            elapsed_ms = elapsed,
            addresses = addresses,
        })
        return
    end

    print(string.format("  %sHost%s      %s", C.b_cyan, C.reset, host))
    print(string.format("  %sElapsed%s   %s", C.b_cyan, C.reset, format_ms(elapsed)))
    print(string.format("  %-45s %-7s %s", "ADDRESS", "FAMILY", options.reverse and "PTR" or ""))

    for _, entry in ipairs(entries) do
        print(string.format("  %-45s %-7s %s",
            entry.address, family_label(entry.family),
            options.reverse and (entry.ptr or "-") or ""))
    end
end

--------------------------------------------------------------------------------
-- Command: ping
--------------------------------------------------------------------------------

local function run_ping(host, options)
    if options.tcp then
        local entries, error_message = resolve_host(host, AF_UNSPEC)
        if not entries then
            die(string.format("cannot resolve '%s': %s", host, tostring(error_message)),
                "check the hostname and network connection")
        end

        local replies = {}
        for sequence = 1, options.count do
            local started = now_ms()
            local ok, state, note, elapsed = tcp_connect(entries[1], options.port,
                options.timeout_ms)
            replies[#replies + 1] = {
                sequence = sequence,
                ok = ok,
                rtt_ms = ok and elapsed or nil,
                note = ok and nil or (state .. ": " .. tostring(note)),
            }
            if sequence < options.count and options.interval_ms > 0 then
                local remaining = options.interval_ms - (now_ms() - started)
                if remaining > 0 then
                    sleep_ms(remaining)
                end
            end
        end

        return entries[1], replies
    end

    local entries, error_message = resolve_host(host, AF_INET)
    if not entries then
        die(string.format("cannot resolve '%s': %s", host, tostring(error_message)),
            "check the hostname and network connection")
    end

    local replies, message, hint = ping_host(entries[1], options)
    if not replies then
        die(message, hint)
    end
    return entries[1], replies
end

local function cmd_ping(host, options)
    local entry, replies = run_ping(host, options)
    local summary = summarize_replies(replies)

    if options.json then
        print_json({
            host = host,
            address = entry.address,
            mode = options.tcp and "tcp" or "icmp",
            port = options.tcp and options.port or nil,
            sent = summary.sent,
            received = summary.received,
            loss_percent = summary.loss_percent,
            rtt_ms = {
                min = summary.min_ms,
                avg = summary.avg_ms,
                max = summary.max_ms,
            },
            replies = replies,
        })
        return
    end

    local mode = options.tcp and ("TCP port " .. options.port) or "ICMP"
    print(string.format("%sPING %s (%s)%s via %s: %d packet(s), timeout %d ms",
        C.b_cyan, host, entry.address, C.reset, mode,
        options.count, math.floor(options.timeout_ms)))

    for _, reply in ipairs(replies) do
        if reply.ok then
            local ttl = reply.ttl and (" ttl=" .. tostring(reply.ttl)) or ""
            print(string.format("  64 bytes from %s: seq=%d time=%s%s",
                entry.address, reply.sequence, format_ms(reply.rtt_ms), ttl))
        else
            print(string.format("  %sRequest timeout for seq=%d (%s)%s",
                C.yellow, reply.sequence, tostring(reply.note or "no reply"), C.reset))
        end
    end

    print(string.format("%s--- statistics ---%s", C.gray, C.reset))
    print(string.format("  %d sent, %d received, %.1f%% loss",
        summary.sent, summary.received, summary.loss_percent))

    if summary.received > 0 then
        print(string.format("  rtt min/avg/max = %s/%s/%s",
            format_ms(summary.min_ms),
            format_ms(summary.avg_ms),
            format_ms(summary.max_ms)))
    end
end

--------------------------------------------------------------------------------
-- Command: scan
--------------------------------------------------------------------------------

local STATE_COLORS = {
    open = "b_green",
    closed = "red",
    filtered = "yellow",
    error = "magenta",
}

local function cmd_scan(target, options)
    local host, inline_port = split_target(target)
    local ports = options.ports

    if not ports then
        if inline_port then
            ports = { inline_port }
        else
            ports = DEFAULT_SCAN_PORTS
        end
    end

    if inline_port and options.ports then
        usage_error(string.format(
            "port %d in target conflicts with --ports %s", inline_port, options.ports_text))
    end

    local entries, error_message = resolve_host(host, AF_UNSPEC)
    if not entries then
        die(string.format("cannot resolve '%s': %s", host, tostring(error_message)),
            "check the hostname and network connection")
    end

    local entry = entries[1]
    local started = now_ms()
    local results = scan_ports(entry, ports, options)
    local elapsed = now_ms() - started

    local counts = { open = 0, closed = 0, filtered = 0, error = 0 }
    for _, result in ipairs(results) do
        counts[result.state] = (counts[result.state] or 0) + 1
    end

    if options.json then
        print_json({
            target = host,
            address = entry.address,
            ports = results,
            elapsed_ms = elapsed,
            summary = counts,
        })
        return
    end

    print(string.format("  %sTarget%s   %s (%s)", C.b_cyan, C.reset, host, entry.address))
    print(string.format("  %sPorts%s    %s (%d)", C.b_cyan, C.reset,
        format_port_list(ports, 24), #ports))
    print(string.format("  %-6s %-9s %-14s %s", "PORT", "STATE", "SERVICE", "LATENCY"))

    for _, result in ipairs(results) do
        if not options.open_only or result.state == "open" then
            local state = string.format("%-9s", result.state)
            local color = C[STATE_COLORS[result.state] or "white"] or C.white
            print(string.format("  %-6d %s %-14s %s",
                result.port,
                paint(state, color),
                service_name(result.port) or "-",
                result.state == "open" and format_ms(result.latency_ms) or "-"))
        end
    end

    if options.open_only and counts.open == 0 then
        print(string.format("  %sNo open ports found.%s", C.yellow, C.reset))
    end

    print(string.format("  %d open, %d closed, %d filtered, %d error in %s",
        counts.open, counts.closed, counts.filtered, counts.error, format_ms(elapsed)))
    if counts.filtered > 0 then
        print(string.format("  %sfiltered = no response within %d ms%s",
            C.gray, math.floor(options.timeout_ms), C.reset))
    end
end

--------------------------------------------------------------------------------
-- Command: check
--------------------------------------------------------------------------------

local function cmd_check(target, options)
    local host, inline_port = split_target(target)
    local ports = options.ports

    if inline_port and options.ports then
        usage_error(string.format(
            "port %d in target conflicts with --ports %s", inline_port, options.ports_text))
    end

    if not ports then
        ports = inline_port and { inline_port } or { 22, 80, 443 }
    end

    local entries, error_message, resolve_elapsed = resolve_host(host, AF_UNSPEC)
    if not entries then
        die(string.format("cannot resolve '%s': %s", host, tostring(error_message)),
            "check the hostname and network connection")
    end

    local ipv4_entry
    for _, entry in ipairs(entries) do
        if entry.family == AF_INET then
            ipv4_entry = ipv4_entry or entry
        end
    end

    local replies, ping_summary, ping_skipped
    if ipv4_entry then
        local ping_options = {
            count = options.count,
            timeout_ms = options.timeout_ms,
            interval_ms = options.interval_ms,
            port = options.port,
        }

        if options.tcp then
            replies = {}
            for sequence = 1, ping_options.count do
                local ok, state, note, elapsed =
                    tcp_connect(ipv4_entry, ping_options.port, ping_options.timeout_ms)
                replies[#replies + 1] = {
                    sequence = sequence,
                    ok = ok,
                    rtt_ms = ok and elapsed or nil,
                    note = ok and nil or (state .. ": " .. tostring(note)),
                }
            end
        else
            replies = ping_host(ipv4_entry, ping_options)
        end

        if replies then
            ping_summary = summarize_replies(replies)
        else
            ping_skipped = "ICMP unavailable"
        end
    else
        ping_skipped = "no IPv4 address"
    end

    local scan_started = now_ms()
    local results = scan_ports(entries[1], ports, options)
    local scan_elapsed = now_ms() - scan_started

    local open_count = 0
    local port_parts = {}
    for _, result in ipairs(results) do
        if result.state == "open" then
            open_count = open_count + 1
        end
        port_parts[#port_parts + 1] = string.format("%d %s", result.port, result.state)
    end

    local reachable = open_count > 0
        or (ping_summary ~= nil and ping_summary.received > 0)

    if options.json then
        local addresses = {}
        for _, entry in ipairs(entries) do
            addresses[#addresses + 1] = {
                address = entry.address,
                family = family_label(entry.family),
            }
        end

        print_json({
            host = host,
            addresses = addresses,
            ping = ping_summary,
            ping_skipped = ping_skipped,
            ports = results,
            reachable = reachable,
            verdict = reachable and "reachable" or "unreachable",
            elapsed_ms = resolve_elapsed + scan_elapsed,
        })

        if not reachable then
            os.exit(1)
        end
        return
    end

    print(string.format("%sfnet check %s%s", C.b_cyan, host, C.reset))
    print(string.format("  [1/3] Resolve   %s (%d address(es), %s)",
        entries[1].address, #entries, format_ms(resolve_elapsed)))

    if ping_summary then
        print(string.format("  [2/3] Ping      %d/%d replies, avg %s",
            ping_summary.received, ping_summary.sent,
            format_ms(ping_summary.avg_ms)))
    else
        print(string.format("  [2/3] Ping      %sskipped (%s)%s",
            C.yellow, tostring(ping_skipped), C.reset))
    end

    print(string.format("  [3/3] Ports     %s (%s)",
        table.concat(port_parts, ", "), format_ms(scan_elapsed)))

    if reachable then
        print(string.format("%s  Verdict: reachable%s", C.b_green, C.reset))
        return
    end

    print(string.format("%s  Verdict: unreachable (no ICMP replies, no open ports)%s",
        C.b_red, C.reset))
    print(string.format("%s  Hints: verify the address, check VPN/firewall rules, "
        .. "and retry with --tcp or a wider --ports range.%s", C.gray, C.reset))
    os.exit(1)
end

--------------------------------------------------------------------------------
-- Self-Tests
--------------------------------------------------------------------------------

local function run_tests()
    local passed, failed, skipped = 0, 0, 0

    local function skip(name, reason)
        skipped = skipped + 1
        print(string.format("  [SKIP] %s (%s)", name, tostring(reason)))
    end

    local function check(name, condition, detail)
        if condition then
            passed = passed + 1
            print(string.format("  [PASS] %s", name))
        else
            failed = failed + 1
            print(string.format("  [FAIL] %s%s", name, detail and (": " .. detail) or ""))
        end
    end

    local function equal(name, actual, expected)
        check(name, actual == expected,
            string.format("expected '%s', got '%s'", tostring(expected), tostring(actual)))
    end

    print("Running fnet.lua automated self-tests...")

    -- Text and JSON helpers.
    equal("trim removes surrounding whitespace", trim("  hello \t"), "hello")
    equal("json escapes quotes and newlines", json_escape('a"b\nc'), '"a\\"b\\nc"')
    equal("json encodes arrays", json_encode({ 1, 2, 3 }), "[1,2,3]")
    equal("json encodes objects with sorted keys", json_encode({ b = 2, a = 1 }),
        '{"a":1,"b":2}')

    -- Address formatting.
    equal("format_ipv4", format_ipv4("\192\168\1\42"), "192.168.1.42")
    equal("format_ipv6 ::", format_ipv6(string.rep("\0", 16)), "::")
    equal("format_ipv6 ::1",
        format_ipv6(string.rep("\0", 15) .. "\1"), "::1")
    local documentation_address = string.char(0x20, 0x01, 0x0d, 0xb8)
        .. string.rep("\0", 11) .. "\1"
    equal("format_ipv6 2001:db8::1", format_ipv6(documentation_address), "2001:db8::1")
    equal("format_ipv6 mapped",
        format_ipv6(string.rep("\0", 10) .. "\255\255\192\168\1\1"),
        "::ffff:192.168.1.1")
    equal("format_ipv4_le_hex", format_ipv4_le_hex("0101A8C0"), "192.168.1.1")
    equal("count_dotted_mask_bits /24", count_dotted_mask_bits("255.255.255.0"), 24)
    equal("count_dotted_mask_bits /32", count_dotted_mask_bits("255.255.255.255"), 32)
    equal("count_mask_bits /8", count_mask_bits("\255\0\0\0"), 8)

    -- Ports and services.
    local ports = parse_ports("22,80,443")
    equal("parse_ports count", #ports, 3)
    equal("parse_ports order", table.concat(ports, ","), "22,80,443")

    local range = parse_ports("1-5,4")
    equal("parse_ports range dedup", table.concat(range, ","), "1,2,3,4,5")

    local invalid_port = parse_ports("70000")
    equal("parse_ports rejects out-of-range", invalid_port, nil)
    local inverted_range = parse_ports("90-80")
    equal("parse_ports rejects inverted range", inverted_range, nil)
    local invalid_text = parse_ports("abc")
    equal("parse_ports rejects text", invalid_text, nil)

    equal("service_name 22", service_name(22), "ssh")
    equal("service_name unknown", service_name(64999), nil)

    -- Route parsing.
    local route_fixture = table.concat({
        "Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT",
        "eth0\t00000000\t0101A8C0\t0003\t0\t0\t100\t00000000\t0\t0\t0",
        "eth0\t0001A8C0\t00000000\t0001\t0\t0\t100\t00FFFFFF\t0\t0\t0",
    }, "\n")
    local gateways = parse_proc_net_route(route_fixture)
    equal("parse_proc_net_route default gateway", gateways.eth0, "192.168.1.1")

    -- ICMP checksum: a valid packet must checksum to zero.
    local packet, packet_size = build_echo_request(7, 0x464E)
    equal("icmp checksum verifies", icmp_checksum(packet, packet_size), 0)
    equal("icmp echo type", packet[0], 8)

    local reply_packet = ffi.new("uint8_t[32]")
    reply_packet[0] = 0
    reply_packet[6] = 0
    reply_packet[7] = 9
    local parsed = parse_icmp_reply(reply_packet, 32)
    equal("parse_icmp_reply sequence", parsed and parsed.sequence, 9)
    equal("parse_icmp_reply kind", parsed and parsed.kind, 0)

    -- Clock monotonicity.
    local first_time = now_ms()
    sleep_ms(5)
    local second_time = now_ms()
    check("now_ms is monotonic", second_time > first_time,
        string.format("%.3f -> %.3f", first_time, second_time))

    -- Live loopback checks.
    local entries, resolve_error = resolve_host("localhost", AF_UNSPEC)
    check("resolve localhost", entries ~= nil and #entries > 0, resolve_error)

    local interfaces, interface_error = collect_interfaces()
    check("interface discovery returns entries", #interfaces > 0, interface_error)

    local loopback_entries = resolve_host("127.0.0.1", AF_INET)
    if loopback_entries then
        local listener, listener_port, listener_error = (function()
            local fd, error_code = open_socket(AF_INET, SOCK_STREAM)
            if not fd then
                return nil, nil, errno_text(error_code)
            end

            local address = ffi.new("struct sockaddr_in")
            address.sin_family = AF_INET
            address.sin_port = net.htons(0)
            ffi.copy(address.sin_addr, "\127\0\0\1", 4)

            local bound = net.bind(fd, ffi.cast("struct sockaddr*", address),
                ffi.sizeof("struct sockaddr_in"))
            if bound ~= 0 then
                local code = socket_error()
                close_socket(fd)
                return nil, nil, errno_text(code)
            end

            if net.listen(fd, 32) ~= 0 then
                local code = socket_error()
                close_socket(fd)
                return nil, nil, errno_text(code)
            end

            local length = ffi.new("socklen_t[1]", ffi.sizeof("struct sockaddr_in"))
            net.getsockname(fd, ffi.cast("struct sockaddr*", address), length)
            return fd, tonumber(net.ntohs(address.sin_port))
        end)()

        if listener then
            local open_results = scan_ports(loopback_entries[1], { listener_port },
                { timeout_ms = 500, concurrency = 4 })
            equal("loopback scan finds open listener", open_results[1].state, "open")

            local probe_ok, probe_state, probe_note =
                tcp_connect(loopback_entries[1], listener_port, 500)
            check("tcp_connect reports the open listener", probe_ok and probe_state == "open",
                tostring(probe_state) .. " " .. tostring(probe_note))

            close_socket(listener)

            local closed_results = scan_ports(loopback_entries[1], { listener_port },
                { timeout_ms = 500, concurrency = 4 })
            check("loopback scan reports closed port", closed_results[1].state ~= "open",
                closed_results[1].state)
        else
            check("loopback listener setup", false, listener_error)
        end
    else
        check("resolve 127.0.0.1", false, "IPv4 loopback resolution failed")
    end

    local ping_entries = resolve_host("127.0.0.1", AF_INET)
    if ping_entries then
        local replies, ping_message = ping_host(ping_entries[1], {
            count = 1,
            timeout_ms = 500,
            interval_ms = 0,
        })
        if replies then
            check("loopback ICMP ping replies", replies[1].ok, replies[1].note)
        else
            skip("loopback ICMP ping", ping_message)
        end
    end

    print(string.format("\nSelf-test summary: %d passed, %d failed, %d skipped.",
        passed, failed, skipped))
    if failed > 0 then
        os.exit(1)
    end
end

--------------------------------------------------------------------------------
-- Help
--------------------------------------------------------------------------------

local function show_help()
    print([[
Usage: fnet <command> [options]

Zero-dependency network diagnostics for Windows and Linux (LuaJIT + FFI).

Commands:
  ifaces                 List interfaces: type, state, MTU, MAC, addresses, gateways
  dns HOST               Resolve HOST and show addresses (optionally reverse PTR)
  ping HOST              ICMP echo with RTT and loss statistics
  scan HOST[:PORT]       Concurrent TCP connect scan
  check HOST             Resolve, ping, and probe common ports with a verdict

Options:
  --json                 Machine-readable output (disables colors)
  --no-color             Disable ANSI colors (NO_COLOR is also honored)
  -c, --count N          ping: packets to send (default 4); scan: concurrency (128)
  -w, --timeout MS       Per-probe timeout in milliseconds (ping default 1000, scan 800)
  -p, --ports SPEC       Comma list or ranges: 22,80,443 or 1-1024
  -t, --tcp              ping/check: measure TCP handshake instead of ICMP
  --port PORT            ping/check --tcp: target port (default 443)
  --open-only            scan: print only open ports
  --reverse              dns: add reverse PTR lookups
  --test                 Run the automated self-test suite
  -h, --help             Show this help message

Examples:
  fnet ifaces
  fnet dns example.com --reverse
  fnet ping 127.0.0.1 -c 4
  fnet ping example.com --tcp --port 443
  fnet scan 192.168.1.10 --ports 22,80,443
  fnet scan 192.168.1.0:445 --timeout 300
  fnet scan example.com -p 1-1024 -c 256 --open-only
  fnet check example.com

Notes:
  Linux ICMP needs cap_net_raw (or sudo). Use --tcp when unavailable.
  Windows interface listing reports IPv4 only; DNS and scan handle IPv6.
  Scan concurrency is capped at 64 on Windows (fd_set limit).]])

end

--------------------------------------------------------------------------------
-- Entrypoint
--------------------------------------------------------------------------------

local function copy_list(source, first_index)
    local result = {}
    for index = first_index, #source do
        result[#result + 1] = source[index]
    end
    return result
end

local function split_option(value)
    local name, inline = tostring(value):match("^(%-%-[%w%-]+)=(.*)$")
    if name then
        return name, inline
    end
    return value, nil
end

local function read_number(value, option_name)
    local number = tonumber(value)
    if not number then
        usage_error(string.format("%s expects a number, got '%s'", option_name,
            tostring(value)))
    end
    return number
end

local function command_options(arguments, defaults)
    local options = defaults or {}
    local positional = {}
    local index = 1

    while index <= #arguments do
        local name, inline = split_option(arguments[index])

        if name == "-c" or name == "--count" then
            local value = inline or arguments[index + 1]
            options.count = math.floor(read_number(value, name))
            index = index + (inline and 0 or 1)
        elseif name == "-w" or name == "--timeout" then
            local value = inline or arguments[index + 1]
            options.timeout_ms = math.floor(read_number(value, name))
            index = index + (inline and 0 or 1)
        elseif name == "-p" or name == "--ports" then
            local value = inline or arguments[index + 1]
            if value == nil then
                usage_error(name .. " expects a port specification")
            end
            options.ports_text = value
            local ports, error_message = parse_ports(value)
            if not ports then
                usage_error(string.format("%s: %s", name, error_message))
            end
            options.ports = ports
            index = index + (inline and 0 or 1)
        elseif name == "--port" then
            local value = inline or arguments[index + 1]
            local port = math.floor(read_number(value, name))
            if port < 1 or port > 65535 then
                usage_error(string.format("%s must be within 1-65535", name))
            end
            options.port = port
            index = index + (inline and 0 or 1)
        elseif name == "--tcp" or name == "-t" then
            options.tcp = true
        elseif name == "--open-only" then
            options.open_only = true
        elseif name == "--reverse" then
            options.reverse = true
        elseif name == "--json" then
            options.json = true
        elseif name == "--no-color" then
            options.color = false
        elseif name == "--help" or name == "-h" then
            show_help()
            os.exit(0)
        elseif name:sub(1, 1) == "-" and name ~= "-" then
            usage_error("unknown option: " .. name)
        else
            positional[#positional + 1] = arguments[index]
        end

        index = index + 1
    end

    return options, positional
end

local function main(arguments)
    setup_console()

    local global = {
        json = false,
        color = nil,
    }
    local cleaned = {}

    for _, value in ipairs(arguments) do
        if value == "--json" then
            global.json = true
        elseif value == "--no-color" then
            global.color = false
        elseif value == "--color" then
            global.color = true
        else
            cleaned[#cleaned + 1] = value
        end
    end

    local enable_color = global.color ~= false
        and not global.json
        and os.getenv("NO_COLOR") == nil
        and stdout_is_tty()
    configure_colors(enable_color)

    local command = cleaned[1]

    if command == nil then
        show_help()
        os.exit(2)
    end
    if command == "-h" or command == "--help" then
        show_help()
        os.exit(0)
    end
    if command == "--test" then
        run_tests()
        os.exit(0)
    end
    if command:sub(1, 1) == "-" then
        usage_error("unknown option: " .. command)
    end

    local arguments_rest = copy_list(cleaned, 2)
    local base = {
        json = global.json,
        color = global.color,
        count = 4,
        timeout_ms = 1000,
        interval_ms = 1000,
        tcp = false,
        port = 443,
    }

    if command == "ifaces" or command == "interfaces" then
        local options, positional = command_options(arguments_rest, base)
        if #positional > 0 then
            usage_error("ifaces takes no positional arguments")
        end
        cmd_ifaces(options)
        return
    end

    if command == "dns" or command == "resolve" then
        local options, positional = command_options(arguments_rest, base)
        if #positional ~= 1 then
            usage_error("usage: fnet dns HOST [--reverse] [--json]")
        end
        cmd_dns(positional[1], options)
        return
    end

    if command == "ping" then
        base.timeout_ms = 1000
        local options, positional = command_options(arguments_rest, base)
        if #positional ~= 1 then
            usage_error("usage: fnet ping HOST [-c COUNT] [-w MS] [--tcp] [--port PORT]")
        end
        if options.count < 1 or options.count > 100 then
            usage_error("count must be between 1 and 100")
        end
        if options.timeout_ms < 1 then
            usage_error("timeout must be at least 1 ms")
        end
        cmd_ping(positional[1], options)
        return
    end

    if command == "scan" then
        base.timeout_ms = 800
        base.concurrency = 128
        local options, positional = command_options(arguments_rest, base)
        if #positional ~= 1 then
            usage_error("usage: fnet scan HOST[:PORT] [-p SPEC] [-t MS] [-c CONCURRENCY]")
        end
        options.concurrency = options.count
        if options.concurrency < 1 or options.concurrency > 512 then
            usage_error("concurrency must be between 1 and 512")
        end
        if options.timeout_ms < 1 then
            usage_error("timeout must be at least 1 ms")
        end
        cmd_scan(positional[1], options)
        return
    end

    if command == "check" then
        local options, positional = command_options(arguments_rest, base)
        if #positional ~= 1 then
            usage_error("usage: fnet check HOST [-p SPEC] [-c COUNT] [-t MS] [--tcp]")
        end
        if options.count < 1 or options.count > 100 then
            usage_error("count must be between 1 and 100")
        end
        cmd_check(positional[1], options)
        return
    end

    usage_error("unknown command: " .. command)
end

main({ ... })
