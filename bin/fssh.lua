#!/usr/bin/env luajit
--[[
  fssh.lua - Ultra-fast Interactive Fuzzy SSH Server Selector and Connector.
  Powered by LuaJIT & FFI. Sub-millisecond FZF preview response.

  Aggregates servers from:
    1. OpenSSH config (~/.ssh/config, %USERPROFILE%/.ssh/config)
    2. OpenSSH known_hosts (~/.ssh/known_hosts)
    3. PuTTY saved sessions (Windows Registry via Win32 Advapi32 FFI)
    4. Local hosts files (/etc/hosts, %SystemRoot%\System32\drivers\etc\hosts)

  Usage:
    fssh.lua [OPTIONS] [QUERY] [-- SSH_EXTRA_ARGS...]

  Options:
    -p, --preview-only <HOST>   Print detailed preview card for host (used by fzf preview)
    -l, --list                  List aggregated hosts in TSV format (for fzf or pipelines)
    -d, --dry-run               Print the connection command without executing
    -u, --user <USER>           Override SSH user
    --putty                     Connect using PuTTY instead of OpenSSH (Windows only)
    -h, --help                  Show this help message
]]

local ffi = require("ffi")

local OS = ffi.os
local IS_LINUX = (OS == "Linux")
local IS_WINDOWS = (OS == "Windows")

--------------------------------------------------------------------------------
-- FFI Declarations
--------------------------------------------------------------------------------
if not IS_WINDOWS then
    ffi.cdef[[
        int execvp(const char *file, char *const argv[]);
        int isatty(int fd);
    ]]
else
    ffi.cdef[[
        typedef void* HANDLE;
        typedef void* HKEY;
        typedef unsigned long DWORD;
        typedef long LONG;
        typedef unsigned char BYTE;

        LONG RegOpenKeyExA(HKEY hKey, const char* lpSubKey, DWORD ulOptions, DWORD samDesired, HKEY* phkResult);
        LONG RegEnumKeyExA(HKEY hKey, DWORD dwIndex, char* lpName, DWORD* lpcchName, DWORD* lpReserved, char* lpClass, DWORD* lpcchClass, void* lpftLastWriteTime);
        LONG RegQueryValueExA(HKEY hKey, const char* lpValueName, DWORD* lpReserved, DWORD* lpType, BYTE* lpData, DWORD* lpcbData);
        LONG RegCloseKey(HKEY hKey);

        typedef int BOOL;
        typedef struct {
            DWORD dwFileAttributes;
            DWORD ftCreationTime[2];
            DWORD ftLastAccessTime[2];
            DWORD ftLastWriteTime[2];
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

        HANDLE GetStdHandle(DWORD nStdHandle);
        BOOL GetConsoleMode(HANDLE hConsoleHandle, DWORD* lpMode);
        BOOL SetConsoleMode(HANDLE hConsoleHandle, DWORD dwMode);
        BOOL SetConsoleOutputCP(unsigned int wCodePageID);
        BOOL SetConsoleCP(unsigned int wCodePageID);
    ]]

    pcall(function()
        local bit = require("bit")
        ffi.C.SetConsoleOutputCP(65001)
        ffi.C.SetConsoleCP(65001)
        local hOut = ffi.C.GetStdHandle(ffi.cast("DWORD", -11))
        if hOut ~= nil and hOut ~= ffi.cast("HANDLE", -1) then
            local mode = ffi.new("DWORD[1]")
            if ffi.C.GetConsoleMode(hOut, mode) ~= 0 then
                ffi.C.SetConsoleMode(hOut, bit.bor(mode[0], 0x0004))
            end
        end
        local hErr = ffi.C.GetStdHandle(ffi.cast("DWORD", -12))
        if hErr ~= nil and hErr ~= ffi.cast("HANDLE", -1) then
            local mode = ffi.new("DWORD[1]")
            if ffi.C.GetConsoleMode(hErr, mode) ~= 0 then
                ffi.C.SetConsoleMode(hErr, bit.bor(mode[0], 0x0004))
            end
        end
    end)
end

--------------------------------------------------------------------------------
-- ANSI Colors
--------------------------------------------------------------------------------
local C = {
    reset   = "\27[0m",
    bold    = "\27[1m",
    dim     = "\27[2m",
    cyan    = "\27[36m",
    green   = "\27[32m",
    yellow  = "\27[33m",
    blue    = "\27[34m",
    magenta = "\27[35m",
    red     = "\27[31m",
    white   = "\27[37m",
    gray    = "\27[90m",
}

--------------------------------------------------------------------------------
-- Helper Utilities
--------------------------------------------------------------------------------
local function get_home_dir()
    return os.getenv("HOME") or os.getenv("USERPROFILE") or "."
end

local function file_exists(path)
    local f = io.open(path, "r")
    if f then
        f:close()
        return true
    end
    return false
end

local function url_decode(str)
    return (str:gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end))
end

local function trim(s)
    return (s:gsub("^%s*(.-)%s*$", "%1"))
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

--------------------------------------------------------------------------------
-- Parsers
--------------------------------------------------------------------------------

-- 1. OpenSSH Config Parser (Supports Host, HostName, User, Port, IdentityFile, ProxyJump, Include)
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
                raw_config = {}
            }
            for _, r in ipairs(current_params.raw_config or {}) do
                table.insert(entry.raw_config, r)
            end
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
                    if #valid_aliases > 0 then
                        current_aliases = valid_aliases
                        current_params = {
                            hostname = "",
                            user = "",
                            port = "22",
                            key = "",
                            proxy = "",
                            raw_config = {}
                        }
                    end
                elseif key == "match" then
                    flush_block()
                elseif #current_aliases > 0 then
                    table.insert(current_params.raw_config, line_str)
                    if key == "hostname" then
                        current_params.hostname = val
                    elseif key == "user" then
                        current_params.user = val
                    elseif key == "port" then
                        current_params.port = val
                    elseif key == "identityfile" or key == "identity_file" then
                        current_params.key = val
                    elseif key == "proxyjump" or key == "proxycommand" then
                        current_params.proxy = val
                    end
                end
            end
        end
    end
    f:close()
    flush_block()

    return hosts
end

-- 2. OpenSSH known_hosts Parser
local function parse_known_hosts(filepath)
    local hosts = {}
    local f = io.open(filepath, "r")
    if not f then return hosts end

    for line in f:lines() do
        local line_str = trim(line)
        if line_str ~= "" and not line_str:match("^#") and not line_str:match("^|1|") then
            local first_token = line_str:match("^(%S+)")
            if first_token then
                for entry in first_token:gmatch("[^,]+") do
                    local host_name, port
                    local h_bracket, p_bracket = entry:match("^%[(.+)%]:(%d+)$")
                    if h_bracket then
                        host_name = h_bracket
                        port = p_bracket
                    else
                        host_name = entry
                        port = "22"
                    end

                    if host_name and host_name ~= "" and not host_name:match("^@") then
                        table.insert(hosts, {
                            name = host_name,
                            hostname = host_name,
                            user = "",
                            port = port,
                            key = "",
                            proxy = "",
                            source = "known-hosts",
                            source_file = filepath,
                            raw_config = {}
                        })
                    end
                end
            end
        end
    end
    f:close()
    return hosts
end

-- 3. PuTTY Sessions (Direct Windows Registry via Advapi32 FFI or WSL reg.exe)
local function parse_putty_sessions()
    local sessions = {}

    if IS_WINDOWS then
        local HKEY_CURRENT_USER = ffi.cast("HKEY", 0x80000001)
        local KEY_READ = 0x20019
        local phkRoot = ffi.new("HKEY[1]")

        if ffi.C.RegOpenKeyExA(HKEY_CURRENT_USER, "Software\\SimonTatham\\PuTTY\\Sessions", 0, KEY_READ, phkRoot) == 0 then
            local rootKey = phkRoot[0]
            local idx = 0
            local nameBuf = ffi.new("char[260]")
            local nameLen = ffi.new("DWORD[1]")

            while true do
                nameLen[0] = 260
                if ffi.C.RegEnumKeyExA(rootKey, idx, nameBuf, nameLen, nil, nil, nil, nil) ~= 0 then
                    break
                end

                local rawSessionName = ffi.string(nameBuf, nameLen[0])
                local sessionName = url_decode(rawSessionName)

                if sessionName ~= "Default Settings" then
                    local phkSub = ffi.new("HKEY[1]")
                    local subPath = "Software\\SimonTatham\\PuTTY\\Sessions\\" .. rawSessionName
                    if ffi.C.RegOpenKeyExA(HKEY_CURRENT_USER, subPath, 0, KEY_READ, phkSub) == 0 then
                        local subKey = phkSub[0]
                        local valBuf = ffi.new("char[512]")
                        local valLen = ffi.new("DWORD[1]")
                        local valType = ffi.new("DWORD[1]")

                        local function read_str_val(valName, defaultVal)
                            valLen[0] = 512
                            if ffi.C.RegQueryValueExA(subKey, valName, nil, valType, ffi.cast("BYTE*", valBuf), valLen) == 0 then
                                if valType[0] == 4 then -- REG_DWORD
                                    local num = ffi.cast("DWORD*", valBuf)[0]
                                    return tostring(num)
                                else
                                    local str = ffi.string(valBuf)
                                    return (str ~= "") and str or defaultVal
                                end
                            end
                            return defaultVal
                        end

                        local host_val = read_str_val("HostName", sessionName)
                        local user_val = read_str_val("UserName", "")
                        local port_val = read_str_val("PortNumber", "22")
                        local key_val  = read_str_val("PublicKeyFile", "")

                        table.insert(sessions, {
                            name = sessionName,
                            hostname = (host_val ~= "") and host_val or sessionName,
                            user = user_val,
                            port = port_val,
                            key = key_val,
                            proxy = "",
                            source = "putty",
                            source_file = "Registry: PuTTY Sessions",
                            raw_config = {}
                        })
                        ffi.C.RegCloseKey(subKey)
                    end
                end
                idx = idx + 1
            end
            ffi.C.RegCloseKey(rootKey)
        end
    elseif IS_LINUX and file_exists("/proc/version") then
        -- Check if running inside WSL and reg.exe is present
        local vf = io.open("/proc/version", "r")
        if vf then
            local vdata = vf:read("*all") or ""
            vf:close()
            if vdata:lower():find("microsoft") then
                local pipe = io.popen("reg.exe query 'HKCU\\Software\\SimonTatham\\PuTTY\\Sessions' 2>/dev/null")
                if pipe then
                    for line in pipe:lines() do
                        local s_raw = line:match("PuTTY\\Sessions\\(.*)$")
                        if s_raw then
                            local s_name = url_decode(trim(s_raw))
                            if s_name ~= "Default Settings" then
                                table.insert(sessions, {
                                    name = s_name,
                                    hostname = s_name,
                                    user = "",
                                    port = "22",
                                    key = "",
                                    proxy = "",
                                    source = "putty",
                                    source_file = "Registry: PuTTY Sessions",
                                    raw_config = {}
                                })
                            end
                        end
                    end
                    pipe:close()
                end
            end
        end
    end

    return sessions
end

-- 4. /etc/hosts Parser
local function parse_etc_hosts()
    local hosts = {}
    local files_to_check = { "/etc/hosts" }
    local win_dir = os.getenv("SystemRoot") or "C:\\Windows"
    table.insert(files_to_check, win_dir:gsub("\\", "/") .. "/System32/drivers/etc/hosts")

    local ignore = {
        ["localhost"] = true,
        ["broadcasthost"] = true,
        ["ip6-localhost"] = true,
        ["ip6-loopback"] = true,
        ["local"] = true
    }

    for _, path in ipairs(files_to_check) do
        local f = io.open(path, "r")
        if f then
            for line in f:lines() do
                local line_str = trim(line):gsub("^\239\187\191", "")
                if line_str ~= "" and not line_str:match("^#") then
                    local parts = {}
                    for token in line_str:gmatch("%S+") do
                        table.insert(parts, token)
                    end
                    if #parts >= 2 then
                        local ip = parts[1]
                        if not ip:match("^127%.") and ip ~= "::1" and ip ~= "255.255.255.255" and not ip:match("^fe00:") and not ip:match("^ff0") then
                            for i = 2, #parts do
                                local hname = parts[i]
                                if not ignore[hname:lower()] then
                                    table.insert(hosts, {
                                        name = hname,
                                        hostname = ip,
                                        user = "",
                                        port = "22",
                                        key = "",
                                        proxy = "",
                                        source = "etc-hosts",
                                        source_file = path,
                                        raw_config = {}
                                    })
                                end
                            end
                        end
                    end
                end
            end
            f:close()
        end
    end
    return hosts
end

--------------------------------------------------------------------------------
-- Aggregation and Deduplication
--------------------------------------------------------------------------------
local function collect_all_hosts()
    local all_hosts = {}
    local seen = {}

    local function add_host(h)
        local key = h.name:lower()
        if not seen[key] then
            seen[key] = true
            table.insert(all_hosts, h)
        end
    end

    -- 1. SSH Config (highest priority)
    for _, cfg_path in ipairs(get_ssh_config_paths()) do
        for _, h in ipairs(parse_ssh_config(cfg_path)) do
            add_host(h)
        end
    end

    -- 2. PuTTY Sessions
    for _, h in ipairs(parse_putty_sessions()) do
        add_host(h)
    end

    -- 3. Known Hosts
    local home = get_home_dir()
    local kp1 = home .. "/.ssh/known_hosts"
    for _, h in ipairs(parse_known_hosts(kp1)) do
        add_host(h)
    end
    local userprofile = os.getenv("USERPROFILE")
    if userprofile then
        local kp2 = userprofile:gsub("\\", "/") .. "/.ssh/known_hosts"
        if kp2 ~= kp1 then
            for _, h in ipairs(parse_known_hosts(kp2)) do
                add_host(h)
            end
        end
    end

    -- 4. /etc/hosts
    for _, h in ipairs(parse_etc_hosts()) do
        add_host(h)
    end

    table.sort(all_hosts, function(a, b)
        return a.name:lower() < b.name:lower()
    end)
    return all_hosts
end

--------------------------------------------------------------------------------
-- Preview Formatter (sub-millisecond live card for FZF)
--------------------------------------------------------------------------------
local function format_preview(h)
    local name = h.name or ""
    local hostname = h.hostname or ""
    local user = h.user or ""
    local port = h.port or "22"
    local key = h.key or ""
    local proxy = h.proxy or ""
    local source = h.source or ""
    local source_file = h.source_file or ""

    local target_str = (user ~= "") and string.format("%s@%s", user, hostname) or hostname

    local cmd_parts = { "ssh" }
    if port ~= "22" and port ~= "" then
        table.insert(cmd_parts, "-p " .. port)
    end
    if key ~= "" then
        table.insert(cmd_parts, "-i " .. key)
    end
    if proxy ~= "" then
        table.insert(cmd_parts, "-J " .. proxy)
    end
    if name ~= hostname then
        table.insert(cmd_parts, name)
    else
        table.insert(cmd_parts, target_str)
    end

    local ssh_cmd = table.concat(cmd_parts, " ")

    local lines = {
        "==================================================",
        string.format("  SSH Server Info: %s", name),
        "==================================================",
        string.format("  Host / Alias:    %s", name),
        string.format("  HostName / IP:   %s", hostname),
        string.format("  User:            %s", (user ~= "") and user or "(default / system user)"),
        string.format("  Port:            %s", port),
    }
    if key ~= "" then
        table.insert(lines, string.format("  IdentityFile:    %s", key))
    end
    if proxy ~= "" then
        table.insert(lines, string.format("  ProxyJump:       %s", proxy))
    end
    table.insert(lines, string.format("  Source:          [%s] %s", source, source_file))
    table.insert(lines, "--------------------------------------------------")
    table.insert(lines, string.format("  Connect Command: %s", ssh_cmd))
    table.insert(lines, "==================================================")

    if h.raw_config and #h.raw_config > 0 then
        table.insert(lines, "\n  Config Block:")
        for _, r in ipairs(h.raw_config) do
            table.insert(lines, "    " .. r)
        end
    end

    return table.concat(lines, "\n")
end

--------------------------------------------------------------------------------
-- Interactive FZF Runner
--------------------------------------------------------------------------------
local function run_fzf_interactive(hosts)
    local script_path = debug.getinfo(1, "S").source:sub(2)
    if not script_path:match("^/") and not script_path:match("^%a:[/\\]") then
        local pwd = io.popen(IS_WINDOWS and "cd" or "pwd 2>/dev/null || pwd"):read("*line") or "."
        script_path = pwd .. "/" .. script_path
    end

    local list_cmd    = string.format("luajit %q -l", script_path)
    local preview_cmd = string.format("luajit %q -p {1}", script_path)

    local fzf_cmd = string.format(
        '%s | fzf --prompt="[LuaJIT] SSH Host > " --delimiter="\t" --with-nth=1,2,3,4 ' ..
        '--layout=reverse --height=50%% --border --preview=%q --preview-window=right:55%%:wrap ' ..
        '--header="LuaJIT FFI | ENTER: Connect | ESC: Cancel"',
        list_cmd, preview_cmd
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

--------------------------------------------------------------------------------
-- Execution & Connection Engine
--------------------------------------------------------------------------------
local function build_connection_command(selected_host, override_user, extra_args, use_putty)
    local name = selected_host.name
    local hostname = selected_host.hostname
    local config_user = selected_host.user or ""
    local user = (override_user and override_user ~= "") and override_user or config_user
    local port = selected_host.port or "22"
    local key = selected_host.key or ""
    local source = selected_host.source or ""

    -- PuTTY mode (only when explicitly requested via --putty)
    if use_putty then
        local putty_bin = "putty"
        local p_cmd = { putty_bin, "-load", name }
        if user ~= "" and user ~= config_user then
            table.insert(p_cmd, "-l")
            table.insert(p_cmd, user)
        end
        return p_cmd, true
    end

    -- Standard OpenSSH
    local cmd = { "ssh" }
    if source ~= "ssh-config" and port ~= "22" and port ~= "" then
        table.insert(cmd, "-p")
        table.insert(cmd, port)
    end
    if source ~= "ssh-config" and key ~= "" then
        table.insert(cmd, "-i")
        table.insert(cmd, key)
    end

    if source == "ssh-config" then
        if user ~= "" and user ~= config_user then
            table.insert(cmd, string.format("%s@%s", user, name))
        else
            table.insert(cmd, name)
        end
    else
        if user ~= "" then
            table.insert(cmd, string.format("%s@%s", user, hostname))
        else
            table.insert(cmd, hostname)
        end
    end

    for _, a in ipairs(extra_args or {}) do
        table.insert(cmd, a)
    end

    return cmd, false
end

local function connect(selected_host, override_user, extra_args, dry_run, use_putty)
    local name = selected_host.name
    local hostname = selected_host.hostname
    local config_user = selected_host.user or ""
    local user = (override_user ~= "") and override_user or config_user
    local source = selected_host.source or ""

    -- Prompt user if missing (only in interactive mode, not during dry-run or piped stdin)
    local is_interactive = not dry_run and (IS_WINDOWS or ffi.C.isatty(0) ~= 0)
    if user == "" and source ~= "ssh-config" and is_interactive then
        local default_user = os.getenv("USER") or os.getenv("USERNAME") or "root"
        io.write(string.format("[fssh] No user configured for '%s'. Enter remote user [%s]: ", name, default_user))
        io.flush()
        local entered = io.read("*line")
        if not entered then return end
        entered = trim(entered)
        user = (entered ~= "") and entered or default_user
        override_user = user
    end

    local cmd, is_putty = build_connection_command(selected_host, override_user, extra_args, use_putty)

    if dry_run then
        print("Dry run: " .. table.concat(cmd, " "))
        return
    end

    if is_putty then
        print(string.format("[fssh] Launching PuTTY session: %s...", name))
        os.execute(table.concat(cmd, " "))
        return
    end

    print(string.format("[fssh] [%s %s FFI] Connecting to %s (%s)...", (jit and jit.version or "LuaJIT"), ffi.os, name, hostname))

    if not IS_WINDOWS then
        local c_args = ffi.new("const char*[?]", #cmd + 1)
        for i, a in ipairs(cmd) do
            c_args[i - 1] = a
        end
        c_args[#cmd] = nil
        ffi.C.execvp(cmd[1], ffi.cast("char* const*", c_args))
    else
        os.execute(table.concat(cmd, " "))
    end
end

--------------------------------------------------------------------------------
-- CLI Entry Point
--------------------------------------------------------------------------------
local function main(args)
    -- 0. Test Suite
    if #args >= 1 and args[1] == "--test" then
        print(C.bold .. C.cyan .. "[TEST] Running fssh.lua Automated Test Suite..." .. C.reset)

        -- 1. Test host collection
        local all_hosts = collect_all_hosts()
        assert(#all_hosts > 0, "collect_all_hosts should discover at least 1 host")
        print(string.format("  [PASS] collect_all_hosts(): discovered %d hosts", #all_hosts))

        -- 2. Test format_preview
        local sample_host = all_hosts[1]
        local preview = format_preview(sample_host)
        assert(preview and preview:find(sample_host.name, 1, true), "Preview card must contain host name")
        for _, name in ipairs({ "review-host", "build.example", "node[1]", "load%test" }) do
            local fixture = { name = name, hostname = "192.0.2.1", source = "ssh-config" }
            local card = format_preview(fixture)
            assert(card:find(name, 1, true), "Preview card must contain literal host name: " .. name)
        end
        print("  [PASS] format_preview(): renders preview card")

        -- 3. Test build_connection_command (OpenSSH config alias)
        local ssh_alias_host = { name = "web-prod", hostname = "10.0.0.1", user = "admin", port = "22", source = "ssh-config" }
        local c1 = build_connection_command(ssh_alias_host, "", {}, false)
        assert(table.concat(c1, " ") == "ssh web-prod", "OpenSSH config host should use alias name: " .. table.concat(c1, " "))
        print("  [PASS] build_connection_command(ssh-config): preserves alias")

        -- 4. Test build_connection_command (User override on ssh-config)
        local c2 = build_connection_command(ssh_alias_host, "deploy", {}, false)
        assert(table.concat(c2, " ") == "ssh deploy@web-prod", "User override failed: " .. table.concat(c2, " "))
        print("  [PASS] build_connection_command(user override): uses user@alias")

        -- 5. Test build_connection_command (Custom host with non-standard port and key)
        local custom_host = { name = "remote-node", hostname = "192.168.1.50", user = "root", port = "2222", key = "~/.ssh/id_ed25519", source = "custom" }
        local c3 = build_connection_command(custom_host, "", {}, false)
        assert(table.concat(c3, " ") == "ssh -p 2222 -i ~/.ssh/id_ed25519 root@192.168.1.50", "Custom host command failed: " .. table.concat(c3, " "))
        print("  [PASS] build_connection_command(custom host): formats port, key, user@hostname")

        -- 6. Test build_connection_command with extra arguments and commands
        local c4 = build_connection_command(ssh_alias_host, "", { "-v", "-L", "8080:localhost:80", "df -h" }, false)
        assert(table.concat(c4, " ") == "ssh web-prod -v -L 8080:localhost:80 df -h", "Extra args failed: " .. table.concat(c4, " "))
        print("  [PASS] build_connection_command(extra args): passes flags and remote commands")

        -- 7. Test PuTTY command formatting
        local putty_host = { name = "pi5-session", hostname = "pi5.local", user = "pi", port = "22", source = "putty" }
        local c5, is_p = build_connection_command(putty_host, "", {}, true)
        assert(is_p == true, "Should identify PuTTY mode when use_putty is true")
        assert(table.concat(c5, " ") == "putty -load pi5-session", "PuTTY command failed: " .. table.concat(c5, " "))

        local c5_def, is_p_def = build_connection_command(putty_host, "", {}, false)
        assert(is_p_def == false, "Default for putty host should be in-terminal OpenSSH")
        assert(table.concat(c5_def, " ") == "ssh pi@pi5.local", "Default command for putty host should be ssh: " .. table.concat(c5_def, " "))

        local c6 = build_connection_command(putty_host, "root", {}, true)
        assert(table.concat(c6, " ") == "putty -load pi5-session -l root", "PuTTY user override failed: " .. table.concat(c6, " "))
        print("  [PASS] build_connection_command(putty): formats -load and -l overrides, defaults to OpenSSH")

        -- 8. Test dry-run execution
        local dry_ran = false
        local old_print = print
        print = function(s)
            if s and s:find("^Dry run: ssh web%-prod") then dry_ran = true end
        end
        connect(ssh_alias_host, "", {}, true, false)
        print = old_print
        assert(dry_ran, "connect dry-run should output command without error")
        print("  [PASS] connect(dry_run): prints command string")

        print(C.bold .. C.green .. "[ALL TESTS PASSED SUCCESSFULLY]" .. C.reset)
        return
    end

    local all_hosts = collect_all_hosts()

    -- 1. Preview Only mode (used by fzf live preview)
    if #args >= 2 and (args[1] == "-p" or args[1] == "--preview-only") then
        local target = args[2]:lower():gsub('^["\']', ''):gsub('["\']$', '')
        for _, h in ipairs(all_hosts) do
            if h.name:lower() == target or h.hostname:lower() == target then
                print(format_preview(h))
                return
            end
        end
        for _, h in ipairs(all_hosts) do
            if h.name:lower():find(target, 1, true) or h.hostname:lower():find(target, 1, true) then
                print(format_preview(h))
                return
            end
        end
        print("Host: " .. target)
        return
    end

    -- 2. List mode
    if #args >= 1 and (args[1] == "-l" or args[1] == "--list") then
        for _, h in ipairs(all_hosts) do
            local dest = (h.user ~= "") and (h.user .. "@" .. h.hostname) or h.hostname
            print(string.format("%s\t%s\t%s\t%s", h.name, dest, h.port, h.source))
        end
        return
    end

    -- 3. Options Parsing
    local dry_run = false
    local use_putty = false
    local override_user = ""
    local query = nil
    local extra_ssh_args = {}

    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "-h" or a == "--help" then
            print([[fssh.lua - Fast Interactive SSH Selector (LuaJIT FFI)
Usage:
  fssh.lua [OPTIONS] [QUERY] [-- SSH_EXTRA_ARGS...]

Options:
  -p, --preview-only <HOST>   Print detailed preview card for host (used by fzf)
  -l, --list                  List aggregated hosts in TSV format
  -d, --dry-run               Print the ssh command without executing
  -u, --user <USER>           Override SSH user
  --putty                     Connect using PuTTY instead of OpenSSH (Windows)
  --test                      Run automated self-tests
  -h, --help                  Show this help message
]])
            return
        elseif a == "-d" or a == "--dry-run" then
            dry_run = true
        elseif a == "--putty" then
            use_putty = true
        elseif (a == "-u" or a == "--user") and i + 1 <= #args then
            i = i + 1
            override_user = args[i]
        elseif a == "--" then
            for j = i + 1, #args do
                table.insert(extra_ssh_args, args[j])
            end
            break
        elseif not query and not a:match("^-") then
            query = a
        else
            table.insert(extra_ssh_args, a)
        end
        i = i + 1
    end

    local selected_host = nil

    if query then
        local q_lower = query:lower()
        for _, h in ipairs(all_hosts) do
            if h.name:lower() == q_lower then
                selected_host = h
                break
            end
        end
        if not selected_host then
            for _, h in ipairs(all_hosts) do
                if h.name:lower():find(q_lower, 1, true) or h.hostname:lower():find(q_lower, 1, true) then
                    selected_host = h
                    break
                end
            end
        end
        if not selected_host then
            io.stderr:write(string.format("[ERROR] No configured host matches '%s'.\n", query))
            os.exit(1)
        end
    else
        if #all_hosts == 0 then
            print("No SSH hosts found in ~/.ssh/config, ~/.ssh/known_hosts, or PuTTY sessions.")
            return
        end
        selected_host = run_fzf_interactive(all_hosts)
    end

    if not selected_host then
        return
    end

    connect(selected_host, override_user, extra_ssh_args, dry_run, use_putty)
end

main({...})
