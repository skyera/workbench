#!/usr/bin/env luajit
--[[
  putty.lua - High-Performance PuTTY Session & Color Scheme Manager (LuaJIT FFI)
  Combines session inspection, export (JSON, OpenSSH config), and 650+ color theme management
  with sub-millisecond FZF live preview and direct Windows Registry modification.

  Usage:
    putty.lua sessions [OPTIONS] [FILTER]
    putty.lua colors [SUBCOMMAND] [THEME] [OPTIONS]
    putty.lua --help

  Session Commands:
    putty.lua sessions                  List all saved PuTTY sessions in aligned table
    putty.lua sessions --json           Export sessions as JSON array
    putty.lua sessions --ssh-config     Export sessions to OpenSSH ~/.ssh/config format
    putty.lua sessions <FILTER>         Filter sessions by name/host

  Color Commands:
    putty.lua colors                    Interactive FZF theme browser with live TrueColor preview
    putty.lua colors list               List all available preset & .reg themes
    putty.lua colors preview <THEME>    Render 24-bit TrueColor swatches in terminal
    putty.lua colors apply <THEME>      Apply theme to session in Registry (default: "Default Settings")
    putty.lua colors apply <THEME> -a   Apply theme to ALL saved sessions
    putty.lua colors export <THEME>     Export theme to Windows Registry .reg patch file
]]

local ffi = require("ffi")
local bit = require("bit")

local OS = ffi.os
local IS_WINDOWS = (OS == "Windows")
local IS_LINUX = (OS == "Linux")

--------------------------------------------------------------------------------
-- FFI Declarations (Win32 Advapi32 Registry API)
--------------------------------------------------------------------------------
if IS_WINDOWS then
    ffi.cdef[[
        typedef void* HKEY;
        typedef unsigned long DWORD;
        typedef long LONG;
        typedef unsigned char BYTE;

        LONG RegOpenKeyExA(HKEY hKey, const char* lpSubKey, DWORD ulOptions, DWORD samDesired, HKEY* phkResult);
        LONG RegEnumKeyExA(HKEY hKey, DWORD dwIndex, char* lpName, DWORD* lpcchName, DWORD* lpReserved, char* lpClass, DWORD* lpcchClass, void* lpftLastWriteTime);
        LONG RegQueryValueExA(HKEY hKey, const char* lpValueName, DWORD* lpReserved, DWORD* lpType, BYTE* lpData, DWORD* lpcbData);
        LONG RegSetValueExA(HKEY hKey, const char* lpValueName, DWORD Reserved, DWORD dwType, const BYTE* lpData, DWORD cbData);
        LONG RegCloseKey(HKEY hKey);

        typedef void* HANDLE;
        typedef int BOOL;
        HANDLE GetStdHandle(DWORD nStdHandle);
        BOOL GetConsoleMode(HANDLE hConsoleHandle, DWORD* lpMode);
        BOOL SetConsoleMode(HANDLE hConsoleHandle, DWORD dwMode);
        BOOL SetConsoleOutputCP(unsigned int wCodePageID);
        BOOL SetConsoleCP(unsigned int wCodePageID);
        DWORD GetFileAttributesA(const char* lpFileName);
        DWORD FormatMessageA(DWORD dwFlags, const void* lpSource, DWORD dwMessageId, DWORD dwLanguageId, char* lpBuffer, DWORD nSize, void* Arguments);
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
    end)
end

local HKEY_CURRENT_USER = ffi.cast("void*", 0x80000001)
local KEY_READ  = 0x20019
local KEY_WRITE = 0x20006
local KEY_ALL_ACCESS = 0xF003F
local REG_SZ = 1
local REG_DWORD = 4

--------------------------------------------------------------------------------
-- Helper Utilities
--------------------------------------------------------------------------------
local function url_decode(str)
    return (str:gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end))
end

local function encode_session_name(name)
    local encoded = {}
    for index = 1, #name do
        local character = name:sub(index, index)
        local byte = name:byte(index)
        local must_escape = byte < 32 or byte > 126
            or character == " " or character == "\\"
            or character == "*" or character == "?"
            or character == "%" or character == "~"
            or (index == 1 and character == ".")

        if must_escape then
            encoded[index] = string.format("%%%02X", byte)
        else
            encoded[index] = character
        end
    end
    return table.concat(encoded)
end

local function trim(s)
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

local function json_quote(value)
    local escaped = value:gsub('[%z\1-\31\\"]', function(character)
        if character == '"' then
            return '\\"'
        end
        if character == "\\" then
            return "\\\\"
        end
        return string.format("\\u%04x", character:byte())
    end)
    return '"' .. escaped .. '"'
end

local function registry_error(action, status)
    local buffer = ffi.new("char[1024]")
    local length = ffi.C.FormatMessageA(0x1200, nil, status, 0, buffer, 1024, nil)
    local detail = "Windows error " .. tonumber(status)
    if length > 0 then
        detail = detail .. ": " .. trim(ffi.string(buffer, length))
    end
    return action .. " (" .. detail .. ")"
end

local function file_exists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

local function dir_exists(path)
    if not path or #path == 0 then return false end
    if IS_WINDOWS then
        local attr = ffi.C.GetFileAttributesA(path)
        return attr ~= 0xFFFFFFFF and bit.band(attr, 0x10) ~= 0
    else
        local f = io.open(path .. "/.", "r")
        if f then f:close() return true end
        return false
    end
end

local function is_wsl()
    if not IS_LINUX then return false end
    local f = io.open("/proc/version", "r")
    if f then
        local data = f:read("*all"):lower()
        f:close()
        return data:find("microsoft") ~= nil
    end
    return false
end

local function shell_quote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function run_wsl_registry(arguments)
    local command_parts = { "reg.exe" }
    for _, argument in ipairs(arguments) do
        table.insert(command_parts, shell_quote(argument))
    end
    local command = table.concat(command_parts, " ")
    -- Lua 5.1 pipe:close() does not reliably expose the child's exit status.
    local pipe, open_error = io.popen(
        command .. " 2>&1; printf '\\n__PUTTY_REG_STATUS__%d\\n' \"$?\""
    )
    if not pipe then
        return nil, "Could not launch " .. command .. ": " .. tostring(open_error)
    end

    local output = pipe:read("*all")
    pipe:close()
    local body, status = output:match("^(.*)\n__PUTTY_REG_STATUS__(%d+)%s*$")
    if not status then
        return nil, "Could not read exit status for " .. command .. ": " .. trim(output)
    end
    if tonumber(status) ~= 0 then
        return nil, command .. " exited with status " .. status .. ": " .. trim(body)
    end
    return body
end

local function parse_wsl_sessions(output)
    local fields = {
        HostName = "host",
        PortNumber = "port",
        UserName = "user",
        Protocol = "protocol",
        PublicKeyFile = "key_file",
        AgentFwd = "agent_fwd"
    }
    local sessions = {}
    local session = nil
    for line in output:gmatch("[^\n]+") do
        line = line:gsub("\r$", "")
        if line:match("^HKEY_") then
            local raw_name = line:match(
                "^HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY\\Sessions\\([^\\]+)$"
            )
            session = nil
            if raw_name then
                session = {
                    name = url_decode(raw_name),
                    raw_name = raw_name,
                    host = "",
                    port = "22",
                    user = "",
                    protocol = "ssh",
                    key_file = "",
                    agent_fwd = "0"
                }
                table.insert(sessions, session)
            end
        elseif session then
            local name, value_type, value = line:match("^%s+(%S+)%s+REG_(%w+)%s+(.*)$")
            local field = fields[name]
            if field and value_type == "DWORD" then
                local number = tonumber(value)
                if number then
                    session[field] = tostring(number)
                end
            elseif field and value_type == "SZ" then
                session[field] = value
            end
        end
    end
    return sessions
end

--------------------------------------------------------------------------------
-- Preset Themes (22 RGB entries for Colour0..Colour21)
--------------------------------------------------------------------------------
local PRESET_THEMES = {
    ["dracula"] = {
        name = "Dracula",
        author = "Zeno Rocha",
        colors = {
            "248,248,242", "255,255,255", "40,42,54", "68,71,90",
            "40,42,54", "248,248,242", "0,0,0", "98,114,164",
            "255,85,85", "255,110,110", "80,250,123", "105,255,148",
            "241,250,140", "255,255,165", "189,147,249", "214,172,255",
            "255,121,198", "255,146,223", "139,233,253", "164,255,255",
            "191,191,191", "255,255,255"
        }
    },
    ["nord"] = {
        name = "Nord",
        author = "Arctic Ice Studio",
        colors = {
            "216,222,233", "235,238,245", "46,52,64", "59,66,82",
            "46,52,64", "216,222,233", "59,66,82", "76,86,106",
            "191,97,106", "191,97,106", "163,190,140", "163,190,140",
            "235,203,139", "235,203,139", "129,161,193", "136,192,208",
            "180,142,173", "180,142,173", "136,192,208", "143,188,187",
            "229,233,240", "236,239,244"
        }
    },
    ["onedark"] = {
        name = "One Dark",
        author = "Atom",
        colors = {
            "171,178,191", "220,223,228", "40,44,52", "62,68,81",
            "40,44,52", "82,139,255", "40,44,52", "92,99,112",
            "224,108,117", "224,108,117", "152,195,121", "152,195,121",
            "229,192,123", "229,192,123", "97,175,239", "97,175,239",
            "198,120,221", "198,120,221", "86,182,194", "86,182,194",
            "171,178,191", "255,255,255"
        }
    },
    ["gruvbox-dark"] = {
        name = "Gruvbox Dark",
        author = "morhetz",
        colors = {
            "235,219,178", "251,241,199", "40,40,40", "60,56,54",
            "40,40,40", "235,219,178", "40,40,40", "146,131,116",
            "204,36,29", "251,73,52", "152,151,26", "184,187,38",
            "215,153,33", "250,189,47", "69,133,136", "131,165,152",
            "177,98,134", "211,134,155", "104,157,106", "142,192,124",
            "168,153,132", "235,219,178"
        }
    },
    ["tokyonight"] = {
        name = "Tokyo Night",
        author = "folke",
        colors = {
            "192,202,245", "205,214,244", "26,27,38", "36,40,59",
            "26,27,38", "192,202,245", "21,22,30", "65,72,104",
            "247,118,142", "247,118,142", "158,206,106", "158,206,106",
            "224,175,104", "224,175,104", "122,162,247", "122,162,247",
            "187,154,247", "187,154,247", "125,207,255", "125,207,255",
            "169,177,214", "192,202,245"
        }
    },
    ["catppuccin-mocha"] = {
        name = "Catppuccin Mocha",
        author = "Catppuccin Org",
        colors = {
            "205,214,244", "245,224,220", "30,30,46", "49,50,68",
            "30,30,46", "245,224,220", "69,71,90", "88,91,112",
            "243,139,168", "243,139,168", "166,227,161", "166,227,161",
            "249,226,175", "249,226,175", "137,180,250", "137,180,250",
            "245,194,231", "245,194,231", "148,226,213", "148,226,213",
            "186,194,222", "166,173,200"
        }
    },
    ["solarized-dark"] = {
        name = "Solarized Dark",
        author = "Ethan Schoonover",
        colors = {
            "131,148,150", "147,161,161", "0,43,54", "7,54,66",
            "0,43,54", "131,148,150", "7,54,66", "0,43,54",
            "220,50,47", "203,75,22", "133,153,0", "88,110,117",
            "181,137,0", "101,123,131", "38,139,210", "131,148,150",
            "211,54,130", "108,113,196", "42,161,152", "147,161,161",
            "238,232,213", "253,246,227"
        }
    },
    ["solarized-light"] = {
        name = "Solarized Light",
        author = "Ethan Schoonover",
        colors = {
            "101,123,131", "88,110,117", "253,246,227", "238,232,213",
            "253,246,227", "101,123,131", "7,54,66", "0,43,54",
            "220,50,47", "203,75,22", "133,153,0", "88,110,117",
            "181,137,0", "101,123,131", "38,139,210", "131,148,150",
            "211,54,130", "108,113,196", "42,161,152", "147,161,161",
            "238,232,213", "253,246,227"
        }
    },
    ["monokai"] = {
        name = "Monokai Pro",
        author = "Wimer Hazenberg",
        colors = {
            "252,252,250", "255,255,255", "45,42,46", "64,61,65",
            "45,42,46", "252,252,250", "45,42,46", "114,110,115",
            "255,97,136", "255,97,136", "169,220,118", "169,220,118",
            "255,216,102", "255,216,102", "252,152,103", "252,152,103",
            "171,157,242", "171,157,242", "120,220,232", "120,220,232",
            "252,252,250", "255,255,255"
        }
    }
}

--------------------------------------------------------------------------------
-- Theme Discovery (.config/putty/themes)
--------------------------------------------------------------------------------
local function parse_reg_file(filepath)
    local f = io.open(filepath, "r")
    if not f then return nil end
    local colors = {}
    for line in f:lines() do
        local idx, rgb = line:match('"Colour(%d+)"="([^"]+)"')
        if idx and rgb then
            colors[tonumber(idx) + 1] = rgb
        end
    end
    f:close()
    if #colors >= 22 then
        return colors
    end
    return nil
end

local function get_repo_dir()
    local src = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/")
    if not src:match("^/") and not src:match("^%a:/") then
        local p = io.popen(IS_WINDOWS and "cd" or "pwd")
        local pwd = p and p:read("*line") or "."
        if p then p:close() end
        src = pwd:gsub("\\", "/") .. "/" .. src
    end
    local dir = src:match("^(.*)/bin/") or src:match("^(.*)/[^/]+$") or "."
    return dir
end

local _THEME_CACHE = nil

local function load_all_themes()
    if _THEME_CACHE then return _THEME_CACHE end
    local themes = {}
    for k, v in pairs(PRESET_THEMES) do
        themes[k] = { name = v.name, author = v.author, colors = v.colors, source = "preset" }
    end

    local base_dir = get_repo_dir()
    local candidates = {
        base_dir .. "/.config/putty/themes",
        os.getenv("APPDATA") and (os.getenv("APPDATA"):gsub("\\", "/") .. "/putty/themes") or nil,
        os.getenv("HOME") and (os.getenv("HOME") .. "/.config/putty/themes") or nil,
    }

    for _, cdir in ipairs(candidates) do
        if cdir and dir_exists(cdir) then
            local cmd
            if IS_WINDOWS then
                cmd = string.format('dir /s /b /a-d "%s\\*.reg" 2>nul', cdir:gsub("/", "\\"))
            else
                cmd = string.format('find %q -type f -name "*.reg" 2>/dev/null', cdir)
            end
            local pipe = io.popen(cmd)
            if pipe then
                for reg_path in pipe:lines() do
                    reg_path = trim(reg_path)
                    if #reg_path > 0 then
                        local bname = reg_path:match("([^/\\]+)%.reg$")
                        if bname then
                            local key = bname:gsub("^%d+%.%s*", ""):lower():gsub("[^%w%-_]", "-"):gsub("%-+", "-")
                            if not themes[key] then
                                local colors = parse_reg_file(reg_path)
                                if colors then
                                    local sub = reg_path:find("AlexAkulov") and "AlexAkulov" or (reg_path:find("iTerm2") and "iTerm2" or "custom")
                                    themes[key] = {
                                        name = bname:gsub("^%d+%.%s*", ""),
                                        author = sub,
                                        colors = colors,
                                        source = sub,
                                        path = reg_path
                                    }
                                end
                            end
                        end
                    end
                end
                pipe:close()
            end
        end
    end
    _THEME_CACHE = themes
    return themes
end

--------------------------------------------------------------------------------
-- Session Reader & Writer (Windows Registry / WSL / Linux)
--------------------------------------------------------------------------------
local function fetch_all_sessions()
    local sessions = {}

    if IS_WINDOWS then
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

                local rawSession = ffi.string(nameBuf, nameLen[0])
                local sessionName = url_decode(rawSession)

                local phkSub = ffi.new("HKEY[1]")
                local subPath = "Software\\SimonTatham\\PuTTY\\Sessions\\" .. rawSession
                if ffi.C.RegOpenKeyExA(HKEY_CURRENT_USER, subPath, 0, KEY_READ, phkSub) == 0 then
                    local subKey = phkSub[0]
                    local valBuf = ffi.new("char[512]")
                    local valLen = ffi.new("DWORD[1]")
                    local valType = ffi.new("DWORD[1]")

                    local function get_val(valName, defaultVal)
                        valLen[0] = 512
                        if ffi.C.RegQueryValueExA(subKey, valName, nil, valType, ffi.cast("BYTE*", valBuf), valLen) == 0 then
                            if valType[0] == REG_DWORD then
                                return tostring(ffi.cast("DWORD*", valBuf)[0])
                            else
                                local str = ffi.string(valBuf)
                                return (str ~= "") and str or defaultVal
                            end
                        end
                        return defaultVal
                    end

                    table.insert(sessions, {
                        name = sessionName,
                        raw_name = rawSession,
                        host = get_val("HostName", ""),
                        port = get_val("PortNumber", "22"),
                        user = get_val("UserName", ""),
                        protocol = get_val("Protocol", "ssh"),
                        key_file = get_val("PublicKeyFile", ""),
                        agent_fwd = get_val("AgentFwd", "0"),
                    })
                    ffi.C.RegCloseKey(subKey)
                end
                idx = idx + 1
            end
            ffi.C.RegCloseKey(rootKey)
        end
    elseif is_wsl() then
        local output, err = run_wsl_registry({
            "query", "HKCU\\Software\\SimonTatham\\PuTTY\\Sessions", "/s"
        })
        if not output then
            return nil, err
        end
        sessions = parse_wsl_sessions(output)
    else
        -- Linux / Unix ~/.putty/sessions
        local pdir = os.getenv("HOME") .. "/.putty/sessions"
        local pipe = io.popen(string.format("ls -1 %q 2>/dev/null", pdir))
        if pipe then
            for item in pipe:lines() do
                local sessionName = url_decode(item)
                local full = pdir .. "/" .. item
                local s = { name = sessionName, raw_name = item, host = "", port = "22", user = "", protocol = "ssh", key_file = "" }
                local f = io.open(full, "r")
                if f then
                    for line in f:lines() do
                        local k, v = line:match("^([^=]+)=(.*)$")
                        if k == "HostName" then s.host = v
                        elseif k == "PortNumber" then s.port = v
                        elseif k == "UserName" then s.user = v
                        elseif k == "PublicKeyFile" then s.key_file = v
                        end
                    end
                    f:close()
                end
                table.insert(sessions, s)
            end
            pipe:close()
        end
    end

    table.sort(sessions, function(a, b) return a.name:lower() < b.name:lower() end)
    return sessions
end

local function apply_colors_to_session(session_name, colors, raw_session)
    raw_session = raw_session or encode_session_name(session_name)

    if IS_WINDOWS then
        local phkSub = ffi.new("HKEY[1]")
        local subPath = "Software\\SimonTatham\\PuTTY\\Sessions\\" .. raw_session
        local status = ffi.C.RegOpenKeyExA(
            HKEY_CURRENT_USER, subPath, 0, KEY_WRITE, phkSub
        )
        if status ~= 0 then
            return false, registry_error("Could not open registry key " .. subPath, status)
        end
        local subKey = phkSub[0]
        for i = 0, 21 do
            local valName = "Colour" .. i
            local valStr = colors[i + 1]
            status = ffi.C.RegSetValueExA(
                subKey, valName, 0, REG_SZ,
                ffi.cast("const BYTE*", valStr), #valStr + 1
            )
            if status ~= 0 then
                ffi.C.RegCloseKey(subKey)
                return false, registry_error("Could not write " .. valName, status)
            end
        end
        status = ffi.C.RegCloseKey(subKey)
        if status ~= 0 then
            return false, registry_error("Could not close registry key " .. subPath, status)
        end
        return true
    elseif is_wsl() then
        local reg_path = string.format([[HKCU\Software\SimonTatham\PuTTY\Sessions\%s]], raw_session)
        for i = 0, 21 do
            local output, err = run_wsl_registry({
                "add", reg_path, "/v", "Colour" .. i,
                "/t", "REG_SZ", "/d", colors[i + 1], "/f"
            })
            if not output then
                return false, err
            end
        end
        return true
    else
        -- Linux ~/.putty/sessions
        local pdir = os.getenv("HOME") .. "/.putty/sessions"
        os.execute(string.format("mkdir -p %q", pdir))
        local target = pdir .. "/" .. raw_session
        local lines = {}
        local f = io.open(target, "r")
        if f then
            for line in f:lines() do
                if not line:match("^Colour%d+=") then
                    table.insert(lines, line)
                end
            end
            f:close()
        end
        for i = 0, 21 do
            table.insert(lines, string.format("Colour%d=%s", i, colors[i + 1]))
        end
        local out = io.open(target, "w")
        if out then
            out:write(table.concat(lines, "\n") .. "\n")
            out:close()
            return true
        end
        return false, "Failed to write ~/.putty/sessions file"
    end
end

--------------------------------------------------------------------------------
-- TrueColor ANSI Terminal Rendering
--------------------------------------------------------------------------------
local function bg_rgb(rgb_str)
    local r, g, b = rgb_str:match("(%d+),(%d+),(%d+)")
    return string.format("\27[48;2;%s;%s;%sm", r or 0, g or 0, b or 0)
end

local function fg_rgb(rgb_str)
    local r, g, b = rgb_str:match("(%d+),(%d+),(%d+)")
    return string.format("\27[38;2;%s;%s;%sm", r or 0, g or 0, b or 0)
end

local function render_preview(theme_key, theme_info, raw_mode)
    local colors = theme_info.colors
    local border = string.rep("─", 52)
    local reset = "\27[0m"

    if raw_mode then
        io.write(string.format("\27[1;36m┌%s┐%s\n", border, reset))
        io.write(string.format("\27[1;36m│ %-50s │%s\n", string.format("THEME: %s [%s]", theme_info.name, theme_info.author or "preset"), reset))
        io.write(string.format("\27[1;36m├%s┤%s\n", border, reset))
    else
        io.write(string.format("\n\27[1;33m=== PuTTY Theme Preview: %s (%s) ===\27[0m\n\n", theme_info.name, theme_info.author or "preset"))
    end

    -- Swatches: Normal 8 (Colour6..13)
    io.write("  Standard: ")
    local norm_idx = { 7, 9, 11, 13, 15, 17, 19, 21 } -- Colour6, 8, 10, 12, 14, 16, 18, 20
    for _, idx in ipairs(norm_idx) do
        io.write(string.format("%s   %s ", bg_rgb(colors[idx]), reset))
    end
    io.write("\n")

    -- Swatches: Bright 8 (Colour7..14)
    io.write("  Bright:   ")
    local brt_idx = { 8, 10, 12, 14, 16, 18, 20, 22 } -- Colour7, 9, 11, 13, 15, 17, 19, 21
    for _, idx in ipairs(brt_idx) do
        io.write(string.format("%s   %s ", bg_rgb(colors[idx]), reset))
    end
    io.write("\n\n")

    -- Context box: simulated terminal window using theme background/foreground
    local fg = colors[1] -- Colour0: Default Foreground
    local bg = colors[3] -- Colour2: Default Background
    local cur = colors[6]-- Colour5: Cursor Colour

    io.write("  Simulated Terminal Window:\n")
    local line1 = "  user@server:~$ ls -la /var/log/nginx              "
    local line2 = "  drwxr-xr-x 2 root root 4096 Sep 12 19:00 .        "
    local line3 = "  -rw-r--r-- 1 root root  512 Sep 12 19:00 access.log"

    io.write(string.format("  %s%s┌%s┐%s\n", bg_rgb(bg), fg_rgb(fg), border, reset))
    io.write(string.format("  %s%s│ %-50s │%s\n", bg_rgb(bg), fg_rgb(fg), line1, reset))
    io.write(string.format("  %s%s│ %-50s │%s\n", bg_rgb(bg), fg_rgb(fg), line2, reset))
    io.write(string.format("  %s%s│ %-50s%s %s│%s\n", bg_rgb(bg), fg_rgb(fg), line3, bg_rgb(cur), bg_rgb(bg), reset))
    io.write(string.format("  %s%s└%s┘%s\n", bg_rgb(bg), fg_rgb(fg), border, reset))

    if raw_mode then
        io.write(string.format("\27[1;36m└%s┘%s\n", border, reset))
    else
        io.write("\n")
    end
end

--------------------------------------------------------------------------------
-- Subcommand: SESSIONS
--------------------------------------------------------------------------------
local function render_ssh_config(sessions)
    local lines = { "# Generated from PuTTY Saved Sessions by putty.lua", "" }
    for _, session in ipairs(sessions) do
        if session.name ~= "Default Settings" and session.host and session.host ~= "" then
            local fields = {
                { "Host", session.name },
                { "HostName", session.host },
                { "User", session.user },
                { "Port", session.port ~= "22" and session.port or nil },
                { "IdentityFile", session.key_file }
            }
            for _, field in ipairs(fields) do
                local keyword, value = field[1], field[2]
                if value and value ~= "" then
                    if value:find("%c") then
                        return nil, string.format(
                            "Cannot export %s for session %s: control characters are not "
                                .. "supported in SSH config values. Edit the saved value first.",
                            keyword, json_quote(session.name)
                        )
                    end
                    local quoted = '"' .. value:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
                    local indentation = keyword == "Host" and "" or "    "
                    table.insert(lines, indentation .. keyword .. " " .. quoted)
                end
            end
            table.insert(lines, "")
        end
    end
    return table.concat(lines, "\n") .. "\n"
end

local function cmd_sessions(args)
    local as_json = false
    local as_ssh = false
    local filter = nil

    for _, a in ipairs(args) do
        if a == "--json" then as_json = true
        elseif a == "--ssh-config" then as_ssh = true
        elseif a == "-h" or a == "--help" then
            print([[putty.lua sessions - View & Export PuTTY Sessions
Usage:
  putty.lua sessions                  Aligned table view
  putty.lua sessions <FILTER>         Filter sessions by name or host
  putty.lua sessions --json           Export as JSON
  putty.lua sessions --ssh-config     Export as OpenSSH config
]])
            return
        elseif not a:match("^-") then
            filter = a:lower()
        end
    end

    local sessions, session_error = fetch_all_sessions()
    if not sessions then
        io.stderr:write("Error: " .. session_error .. "\n")
        return false
    end
    if filter then
        local filtered = {}
        for _, s in ipairs(sessions) do
            if s.name:lower():find(filter, 1, true) or (s.host and s.host:lower():find(filter, 1, true)) then
                table.insert(filtered, s)
            end
        end
        sessions = filtered
    end

    if as_json then
        io.write("[\n")
        for i, s in ipairs(sessions) do
            local comma = (i < #sessions) and "," or ""
            io.write(string.format(
                '  {"name": %s, "host": %s, "port": %s, "user": %s, '
                    .. '"protocol": %s, "key_file": %s}%s\n',
                json_quote(s.name),
                json_quote(s.host or ""),
                json_quote(s.port or "22"),
                json_quote(s.user or ""),
                json_quote(s.protocol or "ssh"),
                json_quote(s.key_file or ""),
                comma
            ))
        end
        io.write("]\n")
        return
    end

    if as_ssh then
        local config, export_error = render_ssh_config(sessions)
        if not config then
            io.stderr:write("Error: " .. export_error .. "\n")
            return false
        end
        io.write(config)
        return
    end

    -- Tabular view
    local header_fmt = "%-24s %-26s %-6s %-14s %-6s %s\n"
    io.write(string.format("\27[1;36m" .. header_fmt .. "\27[0m", "SESSION NAME", "HOSTNAME / IP", "PORT", "USER", "PROTO", "KEY FILE"))
    io.write(string.rep("─", 88) .. "\n")
    for _, s in ipairs(sessions) do
        local h = (s.host and s.host ~= "") and s.host or "-"
        local u = (s.user and s.user ~= "") and s.user or "-"
        local k = (s.key_file and s.key_file ~= "") and s.key_file:match("([^/\\]+)$") or "-"
        io.write(string.format(header_fmt,
            s.name:sub(1, 24),
            h:sub(1, 26),
            s.port or "22",
            u:sub(1, 14),
            s.protocol or "ssh",
            k:sub(1, 14)
        ))
    end
    io.write(string.format("\n\27[2mTotal sessions: %d [Powered by %s %s FFI]\27[0m\n", #sessions, (jit and jit.version or "LuaJIT"), ffi.os))
end

--------------------------------------------------------------------------------
-- Subcommand: COLORS
--------------------------------------------------------------------------------
local function cmd_colors(args)
    local themes = load_all_themes()
    local sub = args[1]

    if sub == "list" then
        io.write(string.format("%-28s %-16s %s\n", "THEME KEY", "AUTHOR / SOURCE", "DISPLAY NAME"))
        io.write(string.rep("─", 65) .. "\n")
        local sorted_keys = {}
        for k in pairs(themes) do table.insert(sorted_keys, k) end
        table.sort(sorted_keys)
        for _, k in ipairs(sorted_keys) do
            local t = themes[k]
            io.write(string.format("%-28s %-16s %s\n", k, t.author or "preset", t.name))
        end
        io.write(string.format("\n\27[2mTotal available themes: %d\27[0m\n", #sorted_keys))
        return

    elseif sub == "preview" then
        local raw = false
        local t_key = nil
        for i = 2, #args do
            if args[i] == "--raw" then raw = true
            elseif not t_key then t_key = args[i]:lower() end
        end
        if not t_key then
            io.stderr:write("Usage: putty.lua colors preview <THEME> [--raw]\n")
            return
        end
        local t = themes[t_key]
        if not t then
            -- Partial match search
            for k, v in pairs(themes) do
                if k:find(t_key, 1, true) then t = v t_key = k break end
            end
        end
        if not t then
            io.stderr:write(string.format("Error: Theme '%s' not found. Run 'putty.lua colors list' to view.\n", t_key))
            return
        end
        render_preview(t_key, t, raw)
        return

    elseif sub == "apply" then
        local t_key = nil
        local session_name = "Default Settings"
        local apply_all = false

        local i = 2
        while i <= #args do
            local a = args[i]
            if a == "-s" or a == "--session" then
                i = i + 1
                session_name = args[i]
            elseif a == "-a" or a == "--all" then
                apply_all = true
            elseif not t_key and not a:match("^-") then
                t_key = a:lower()
            end
            i = i + 1
        end

        if not t_key then
            io.stderr:write("Usage: putty.lua colors apply <THEME> [-s SESSION] [-a / --all]\n")
            return
        end

        local t = themes[t_key]
        if not t then
            for k, v in pairs(themes) do
                if k:find(t_key, 1, true) then t = v break end
            end
        end
        if not t then
            io.stderr:write(string.format("Error: Unknown theme '%s'.\n", t_key))
            return
        end

        if apply_all then
            local sessions, session_error = fetch_all_sessions()
            if not sessions then
                io.stderr:write("Error: " .. session_error .. "\n")
                return false
            end
            local seen = {}
            for _, s in ipairs(sessions) do seen[s.name] = true end
            if not seen["Default Settings"] then table.insert(sessions, { name = "Default Settings" }) end

            io.write(string.format("Applying theme '%s' to %d PuTTY session(s)...\n", t.name, #sessions))
            local count = 0
            for _, s in ipairs(sessions) do
                local ok, err = apply_colors_to_session(s.name, t.colors, s.raw_name)
                if ok then
                    count = count + 1
                else
                    io.stderr:write(string.format("Error: session '%s': %s\n", s.name, err))
                end
            end
            io.write(string.format("Updated %d of %d session(s).\n", count, #sessions))
            if count ~= #sessions then
                return false
            end
        else
            io.write(string.format("Applying theme '%s' to session '%s'... ", t.name, session_name))
            local ok, err = apply_colors_to_session(session_name, t.colors)
            if ok then
                io.write("\27[32m✔ Done!\27[0m\n")
            else
                io.write(string.format("\27[31m✘ Failed: %s\27[0m\n", err or "unknown error"))
            end
        end
        return

    elseif sub == "export" then
        local t_key = nil
        local session_name = "Default Settings"
        local out_file = nil

        local i = 2
        while i <= #args do
            local a = args[i]
            if a == "-s" or a == "--session" then
                i = i + 1
                session_name = args[i]
            elseif a == "-o" or a == "--output" then
                i = i + 1
                out_file = args[i]
            elseif not t_key and not a:match("^-") then
                t_key = a:lower()
            end
            i = i + 1
        end

        if not t_key then
            io.stderr:write("Usage: putty.lua colors export <THEME> [-s SESSION] [-o FILE]\n")
            return
        end

        local t = themes[t_key]
        if not t then
            io.stderr:write(string.format("Error: Theme '%s' not found.\n", t_key))
            return
        end

        out_file = out_file or (t_key .. ".reg")
        local f = io.open(out_file, "w")
        if not f then
            io.stderr:write(string.format("Error opening output file: %s\n", out_file))
            return
        end

        f:write("Windows Registry Editor Version 5.00\n\n")
        f:write(string.format(
            "[HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY\\Sessions\\%s]\n",
            encode_session_name(session_name)
        ))
        for idx = 0, 21 do
            f:write(string.format('"Colour%d"="%s"\n', idx, t.colors[idx + 1]))
        end
        f:close()
        io.write(string.format("Exported '%s' theme for session '%s' to %s\n", t.name, session_name, out_file))
        return
    end

    -- Default: Interactive FZF theme selector
    local script_path = debug.getinfo(1, "S").source:sub(2)
    if not script_path:match("^/") and not script_path:match("^%a:[/\\]") then
        local pwd = io.popen(IS_WINDOWS and "cd" or "pwd 2>/dev/null || pwd"):read("*line") or "."
        script_path = pwd .. "/" .. script_path
    end

    local preview_cmd = string.format("luajit %q colors preview {1} --raw", script_path)
    local list_cmd    = string.format("luajit %q colors list", script_path)

    local fzf_cmd = string.format(
        '%s | fzf --header-lines=2 --prompt="[LuaJIT] PuTTY Theme > " ' ..
        '--layout=reverse --height=65%% --border --preview=%q --preview-window=right:55%%:wrap ' ..
        '--header="LuaJIT FFI (650+ Themes) | ENTER: Apply to Default Settings | ESC: Cancel"',
        list_cmd, preview_cmd
    )

    local pipe = io.popen(fzf_cmd, "r")
    if not pipe then
        io.stderr:write("Error: fzf is not installed or failed to launch.\n")
        return
    end
    local selected = pipe:read("*line")
    pipe:close()

    if selected and selected ~= "" then
        local theme_key = selected:match("^(%S+)")
        if theme_key and themes[theme_key] then
            io.write(string.format("\nApply '%s' to [1] Default Settings or [2] ALL sessions? [1/2]: ", themes[theme_key].name))
            io.flush()
            local choice = io.read("*line")
            if choice == "2" then
                cmd_colors({ "apply", theme_key, "-a" })
            else
                cmd_colors({ "apply", theme_key, "-s", "Default Settings" })
            end
        end
    end
end

--------------------------------------------------------------------------------
-- CLI Entry Point
--------------------------------------------------------------------------------
local function main(args)
    local cmd = args[1]
    if cmd == "sessions" then
        local sub_args = {}
        for i = 2, #args do table.insert(sub_args, args[i]) end
        cmd_sessions(sub_args)
    elseif cmd == "colors" or cmd == "themes" then
        local sub_args = {}
        for i = 2, #args do table.insert(sub_args, args[i]) end
        cmd_colors(sub_args)
    elseif cmd == "-h" or cmd == "--help" or cmd == "help" then
        print([[putty.lua - PuTTY Session & Color Scheme Manager (LuaJIT FFI)
Usage:
  putty.lua sessions [OPTIONS] [FILTER]
  putty.lua colors [SUBCOMMAND] [THEME] [OPTIONS]

Commands:
  sessions                  List and export saved PuTTY sessions
  colors                    Browse, preview, apply, and export 650+ color themes
]])
    else
        -- No subcommand provided: if TTY, show interactive menu
        cmd_colors({})
    end
end

main({...})
