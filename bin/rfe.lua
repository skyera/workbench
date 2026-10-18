#!/usr/bin/env luajit
--[=[
  rfe.lua - Ultra-fast Interactive Remote Server Browser & Previewer.
  Powered by LuaJIT & FFI. Single-file, zero external Lua dependencies.
  Runs natively on Linux/POSIX and Windows (Win32 Console & Registry FFI).

  Features:
    - Dual-Pane TUI: Left = Remote Directory Tree, Right = Real-Time Preview
    - Full File & Folder Icons: Nerd Fonts (default), Unicode Emoji, and ASCII fallback
    - Live Text Preview: Syntax-highlighted text/code with line numbers and smooth scrolling
    - Live Image Preview: Dual-mode rendering:
        * Universal Truecolor Half-Blocks (▀) via ImageMagick/chafa (works in all truecolor terminals)
        * WezTerm / iTerm2 OSC 1337 & Kitty inline graphics protocols via in-memory FFI Base64
    - Fast Image Header Parser: In-memory binary dimension reader for PNG, JPEG, GIF, BMP
    - SSH Connection Multiplexing: ControlMaster/ControlPath socket reuse for < 10ms queries
    - Offline Demo Mode (--demo): Browse a simulated remote filesystem without an SSH server
    - CLI Preview Mode (--preview): For instant integration into fzf, lf, and ranger

  Usage:
    luajit rfe.lua [OPTIONS] [USER@HOST[:REMOTE_PATH]]
    luajit rfe.lua --demo
    luajit rfe.lua --preview <HOST> <REMOTE_PATH> [WIDTH] [HEIGHT]
    luajit rfe.lua --list <HOST> <REMOTE_PATH>
    luajit rfe.lua --test

  Options:
    -H, --host <HOST>       Remote SSH host (or saved PuTTY session)
    -u, --user <USER>       Remote SSH username
    -p, --port <PORT>       Remote SSH port
    -i, --identity <KEY>    Path to SSH private key
    -e, --engine <ENGINE>   Image engine: auto (default), ffi, chafa, magick, python
    --icons <MODE>          Icon mode: nerd (default), emoji, ascii, or none
    --protocol <MODE>       Image protocol: blocks (default) or graphics (OSC 1337)
    --demo                  Start in simulated demo mode
    --preview               Headless preview mode for fzf/lf/ranger
    --list                  List remote directory as TSV
    --test                  Run automated test suite
    -h, --help              Show this help message

  Keybindings:
    j / Down, k / Up        Navigate file tree
    Enter / l / Right       Drill into directory / open item
    h / Backspace / Left    Go to parent directory (..)
    J / K, PageDown/Up      Scroll preview pane up/down
    Tab                     Toggle focus between file tree and preview pane
    I                       Cycle icon mode: Nerd -> Emoji -> ASCII -> None
    e                       Cycle image engine (Auto -> FFI -> Chafa -> Magick -> Python)
    i                       Toggle image rendering mode (Half-Blocks <-> Graphics Protocol)
    /                       Inline fuzzy filter current directory
    d                       Download selected file locally via SCP
    r                       Refresh current remote directory and cache
    ~                       Jump to remote home directory ($HOME)
    ?                       Show keyboard help modal
    q / Ctrl+C              Quit
]=]

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
        void Sleep(DWORD dwMilliseconds);

        LONG RegOpenKeyExA(HKEY hKey, const char* lpSubKey, DWORD ulOptions, DWORD samDesired, HKEY* phkResult);
        LONG RegEnumKeyExA(HKEY hKey, DWORD dwIndex, char* lpName, DWORD* lpcchName, DWORD* lpReserved, char* lpClass, DWORD* lpcchClass, void* lpftLastWriteTime);
        LONG RegQueryValueExA(HKEY hKey, const char* lpValueName, DWORD* lpReserved, DWORD* lpType, BYTE* lpData, DWORD* lpcbData);
        LONG RegCloseKey(HKEY hKey);
    ]]
    local msvcrt = ffi.load("msvcrt")
    ffi.cdef[[
        int _kbhit(void);
        int _getch(void);
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
    ]]
end

--------------------------------------------------------------------------------
-- ANSI Colors & Styling
--------------------------------------------------------------------------------
local C = {
    reset       = "\27[0m",
    bold        = "\27[1m",
    dim         = "\27[2m",
    italic      = "\27[3m",
    underline   = "\27[4m",
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
    bg_darkgray = "\27[48;5;236m",
    bg_sel      = "\27[48;5;238m",
    bg_header   = "\27[48;5;24m",
}

-- Box drawing characters
local BOX = {
    tl = "┌", tr = "┐", bl = "└", br = "┘",
    h = "─", v = "│", vl = "├", vr = "┤",
    tt = "┬", tb = "┴", x = "┼",
    arrow_r = "▸",
}

--------------------------------------------------------------------------------
-- Helpers & Utilities
--------------------------------------------------------------------------------
local function trim(s)
    return (s:gsub("^%s*(.-)%s*$", "%1"))
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

local function format_size(bytes)
    if not bytes or bytes < 0 then return "-" end
    if bytes < 1024 then
        return string.format("%d B", bytes)
    elseif bytes < 1024 * 1024 then
        return string.format("%.1f KB", bytes / 1024)
    elseif bytes < 1024 * 1024 * 1024 then
        return string.format("%.1f MB", bytes / (1024 * 1024))
    else
        return string.format("%.2f GB", bytes / (1024 * 1024 * 1024))
    end
end

local function parse_size_bytes(size_str)
    if not size_str then return 0 end
    local n = tonumber(size_str)
    if n then return n end
    local num, unit = size_str:match("^([%d%.]+)%s*([KkMmGgTt]?[Bb]?)$")
    if not num then return 0 end
    n = tonumber(num) or 0
    unit = unit:upper()
    if unit:find("K") then return math.floor(n * 1024)
    elseif unit:find("M") then return math.floor(n * 1024 * 1024)
    elseif unit:find("G") then return math.floor(n * 1024 * 1024 * 1024)
    elseif unit:find("T") then return math.floor(n * 1024 * 1024 * 1024 * 1024)
    end
    return math.floor(n)
end

local function get_home_dir()
    return os.getenv("HOME") or os.getenv("USERPROFILE") or "."
end

local function normalize_remote_path(p)
    if not p then return "~" end
    if IS_WINDOWS then
        local local_home = get_home_dir()
        if local_home and #local_home > 0 then
            local norm_p = p:gsub("\\", "/")
            local norm_home = local_home:gsub("\\", "/")
            if norm_p:sub(1, #norm_home) == norm_home then
                local sub = norm_p:sub(#norm_home + 1):gsub("^/", "")
                if #sub == 0 then return "~" else return "~/" .. sub end
            end
        end
        local user_sub = p:gsub("\\", "/"):match("^[A-Za-z]:/Users/[^/]+/(.*)$")
        if user_sub then
            return "~/" .. user_sub
        end
    end
    return p
end

local function file_exists(path)
    local f = io.open(path, "rb")
    if f then
        f:close()
        return true
    end
    return false
end

local function read_file(path, max_bytes)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data
    if max_bytes then
        data = f:read(max_bytes)
    else
        data = f:read("*a")
    end
    f:close()
    return data
end

-- String visual column width calculation (considering emojis & Nerd Font glyphs)
local function utf8_col_width(s)
    local clean = s:gsub("\27%[[%d;]*[mK]", "")
    local width = 0
    local i = 1
    local len = #clean
    while i <= len do
        local b = clean:byte(i)
        if b < 128 then
            width = width + 1
            i = i + 1
        elseif b >= 192 and b < 224 then
            -- 2-byte UTF-8
            width = width + 1
            i = i + 2
        elseif b >= 224 and b < 240 then
            -- 3-byte UTF-8 (Common CJK or basic symbols)
            local b2 = clean:byte(i+1) or 0
            -- Block elements (U+2580..U+259F) and Box Drawing (U+2500..U+257F) are strictly 1-column wide
            if b == 0xE2 and (b2 == 0x94 or b2 == 0x95 or b2 == 0x96 or b2 == 0x97) then
                width = width + 1
            -- Check for wide CJK or wide emoji blocks
            elseif (b == 0xE2 and (b2 >= 0x98 and b2 <= 0xBF)) or (b >= 0xE3 and b <= 0xEF) then
                width = width + 2
            else
                width = width + 1
            end
            i = i + 3
        elseif b >= 240 then
            -- 4-byte UTF-8 (Emoji / Supplementary)
            width = width + 2
            i = i + 4
        else
            i = i + 1
        end
    end
    return width
end

local function pad_string(s, target_width)
    local cur_w = utf8_col_width(s)
    if cur_w < target_width then
        return s .. string.rep(" ", target_width - cur_w)
    else
        return s
    end
end

local function truncate_string(s, max_width)
    local cur_w = utf8_col_width(s)
    if cur_w <= max_width then return s end
    if max_width <= 1 then return "…" end
    local clean = s:gsub("\27%[[%d;]*[mK]", "")
    local res = ""
    local w = 0
    local i = 1
    local len = #clean
    while i <= len and w < max_width - 1 do
        local b = clean:byte(i)
        local step = 1
        local char_w = 1
        if b >= 192 and b < 224 then step = 2
        elseif b >= 224 and b < 240 then step = 3; char_w = 1
        elseif b >= 240 then step = 4; char_w = 2
        end
        if w + char_w > max_width - 1 then break end
        res = res .. clean:sub(i, i + step - 1)
        w = w + char_w
        i = i + step
    end
    return res .. "…" .. string.rep(" ", math.max(0, max_width - w - 1))
end

--------------------------------------------------------------------------------
-- Fast In-Memory Base64 Encoder / Decoder via FFI & bitwise operations
--------------------------------------------------------------------------------
local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_MAP = {}
for i = 1, 64 do
    B64_MAP[B64_CHARS:byte(i)] = i - 1
end

local function base64_encode(data)
    if not data or #data == 0 then return "" end
    local len = #data
    local ptr = ffi.cast("const uint8_t*", data)
    local out = {}
    local n = math.floor(len / 3) * 3

    for i = 0, n - 1, 3 do
        local b0 = ptr[i]
        local b1 = ptr[i + 1]
        local b2 = ptr[i + 2]
        local c0 = bit.rshift(b0, 2)
        local c1 = bit.bor(bit.lshift(bit.band(b0, 0x03), 4), bit.rshift(b1, 4))
        local c2 = bit.bor(bit.lshift(bit.band(b1, 0x0F), 2), bit.rshift(b2, 6))
        local c3 = bit.band(b2, 0x3F)
        table.insert(out, string.char(
            B64_CHARS:byte(c0 + 1),
            B64_CHARS:byte(c1 + 1),
            B64_CHARS:byte(c2 + 1),
            B64_CHARS:byte(c3 + 1)
        ))
    end

    local rem = len - n
    if rem == 1 then
        local b0 = ptr[n]
        local c0 = bit.rshift(b0, 2)
        local c1 = bit.lshift(bit.band(b0, 0x03), 4)
        table.insert(out, string.char(
            B64_CHARS:byte(c0 + 1),
            B64_CHARS:byte(c1 + 1),
            61, 61
        ))
    elseif rem == 2 then
        local b0 = ptr[n]
        local b1 = ptr[n + 1]
        local c0 = bit.rshift(b0, 2)
        local c1 = bit.bor(bit.lshift(bit.band(b0, 0x03), 4), bit.rshift(b1, 4))
        local c2 = bit.lshift(bit.band(b1, 0x0F), 2)
        table.insert(out, string.char(
            B64_CHARS:byte(c0 + 1),
            B64_CHARS:byte(c1 + 1),
            B64_CHARS:byte(c2 + 1),
            61
        ))
    end

    return table.concat(out)
end

local function base64_decode(s)
    if not s or #s == 0 then return "" end
    local out = {}
    local b0, b1, b2, b3
    local count = 0
    local len = #s
    for i = 1, len do
        local val = B64_MAP[s:byte(i)]
        if val then
            count = count + 1
            if count == 1 then
                b0 = val
            elseif count == 2 then
                b1 = val
            elseif count == 3 then
                b2 = val
            elseif count == 4 then
                b3 = val
                table.insert(out, string.char(
                    bit.bor(bit.lshift(b0, 2), bit.rshift(b1, 4)),
                    bit.bor(bit.lshift(bit.band(b1, 0x0F), 4), bit.rshift(b2, 2)),
                    bit.bor(bit.lshift(bit.band(b2, 0x03), 6), b3)
                ))
                count = 0
            end
        end
    end
    if count == 2 then
        table.insert(out, string.char(bit.bor(bit.lshift(b0, 2), bit.rshift(b1, 4))))
    elseif count == 3 then
        table.insert(out, string.char(
            bit.bor(bit.lshift(b0, 2), bit.rshift(b1, 4)),
            bit.bor(bit.lshift(bit.band(b1, 0x0F), 4), bit.rshift(b2, 2))
        ))
    end
    return table.concat(out)
end

--------------------------------------------------------------------------------
-- Image Header Parser (In-Memory Binary Extraction via FFI)
--------------------------------------------------------------------------------
local ImageParser = {}

function ImageParser.parse_header(data)
    if not data or #data < 10 then return nil end
    local ptr = ffi.cast("const uint8_t*", data)
    local len = #data

    -- 1. PNG (\137PNG\r\n\026\n)
    if len >= 24 and ptr[0] == 0x89 and ptr[1] == 0x50 and ptr[2] == 0x4E and ptr[3] == 0x47 then
        local w = bit.bor(bit.lshift(ptr[16], 24), bit.lshift(ptr[17], 16), bit.lshift(ptr[18], 8), ptr[19])
        local h = bit.bor(bit.lshift(ptr[20], 24), bit.lshift(ptr[21], 16), bit.lshift(ptr[22], 8), ptr[23])
        local bit_depth = ptr[24]
        local color_type = ptr[25]
        local color_desc = "sRGB"
        if color_type == 0 then color_desc = "Grayscale"
        elseif color_type == 2 then color_desc = "RGB Truecolor"
        elseif color_type == 3 then color_desc = "Indexed Palette"
        elseif color_type == 4 then color_desc = "Grayscale+Alpha"
        elseif color_type == 6 then color_desc = "RGBA Truecolor"
        end
        return {
            format = "PNG",
            width = w,
            height = h,
            bit_depth = bit_depth,
            color_desc = color_desc,
        }
    end

    -- 2. GIF (GIF87a or GIF89a)
    if len >= 10 and ptr[0] == 0x47 and ptr[1] == 0x49 and ptr[2] == 0x46 then
        local w = ptr[6] + bit.lshift(ptr[7], 8)
        local h = ptr[8] + bit.lshift(ptr[9], 8)
        return {
            format = "GIF",
            width = w,
            height = h,
            bit_depth = 8,
            color_desc = "Indexed Palette",
        }
    end

    -- 3. BMP (BM)
    if len >= 26 and ptr[0] == 0x42 and ptr[1] == 0x4D then
        local w = ptr[18] + bit.lshift(ptr[19], 8) + bit.lshift(ptr[20], 16) + bit.lshift(ptr[21], 24)
        local h = ptr[22] + bit.lshift(ptr[23], 8) + bit.lshift(ptr[24], 16) + bit.lshift(ptr[25], 24)
        local bpp = ptr[28] + bit.lshift(ptr[29], 8)
        return {
            format = "BMP",
            width = w,
            height = math.abs(h),
            bit_depth = bpp,
            color_desc = bpp == 32 and "RGBA" or (bpp == 24 and "RGB" or "Indexed"),
        }
    end

    -- 4. JPEG (0xFF 0xD8)
    if len >= 4 and ptr[0] == 0xFF and ptr[1] == 0xD8 then
        local i = 2
        while i < len - 8 do
            if ptr[i] == 0xFF then
                local m = ptr[i + 1]
                -- SOF0, SOF1, SOF2 markers
                if m == 0xC0 or m == 0xC1 or m == 0xC2 then
                    local h = bit.bor(bit.lshift(ptr[i + 5], 8), ptr[i + 6])
                    local w = bit.bor(bit.lshift(ptr[i + 7], 8), ptr[i + 8])
                    local precision = ptr[i + 4]
                    return {
                        format = "JPEG",
                        width = w,
                        height = h,
                        bit_depth = precision,
                        color_desc = "YCbCr / sRGB",
                    }
                elseif m == 0xD9 or m == 0xDA then
                    break
                else
                    local seg_len = bit.bor(bit.lshift(ptr[i + 2], 8), ptr[i + 3])
                    i = i + 2 + seg_len
                end
            else
                i = i + 1
            end
        end
    end

    -- 5. WebP (RIFF .... WEBP)
    if len >= 30 and ptr[0] == 0x52 and ptr[1] == 0x49 and ptr[2] == 0x46 and ptr[3] == 0x46
       and ptr[8] == 0x57 and ptr[9] == 0x45 and ptr[10] == 0x42 and ptr[11] == 0x50 then
        -- VP8 chunk
        if ptr[12] == 0x56 and ptr[13] == 0x50 and ptr[14] == 0x38 and ptr[15] == 0x20 then
            local w = bit.band(ptr[26] + bit.lshift(ptr[27], 8), 0x3FFF)
            local h = bit.band(ptr[28] + bit.lshift(ptr[29], 8), 0x3FFF)
            return {
                format = "WebP",
                width = w,
                height = h,
                bit_depth = 8,
                color_desc = "sRGB (Lossy)",
            }
        elseif ptr[12] == 0x56 and ptr[13] == 0x50 and ptr[14] == 0x38 and ptr[15] == 0x4C then
            -- VP8L (Lossless)
            local b0 = ptr[21]
            local b1 = ptr[22]
            local b2 = ptr[23]
            local b3 = ptr[24]
            local w = 1 + bit.band(b0 + bit.lshift(bit.band(b1, 0x3F), 8), 0x3FFF)
            local h = 1 + bit.band(bit.rshift(b1, 6) + bit.lshift(b2, 2) + bit.lshift(bit.band(b3, 0x0F), 10), 0x3FFF)
            return {
                format = "WebP",
                width = w,
                height = h,
                bit_depth = 8,
                color_desc = "sRGB (Lossless)",
            }
        end
    end

    return nil
end

--------------------------------------------------------------------------------
-- File & Folder Icon Classification Engine
--------------------------------------------------------------------------------
local IconEngine = {
    mode = "nerd", -- "nerd", "emoji", "ascii", "none"
}

local EXT_ICONS = {
    -- Programming languages
    lua   = { nerd = " ", emoji = "🌙 ", color = C.bright_cyan },
    py    = { nerd = " ", emoji = "🐍 ", color = C.bright_yellow },
    pyw   = { nerd = " ", emoji = "🐍 ", color = C.bright_yellow },
    ipynb = { nerd = " ", emoji = "🐍 ", color = C.bright_yellow },
    sh    = { nerd = " ", emoji = "⚡ ", color = C.bright_green },
    bash  = { nerd = " ", emoji = "⚡ ", color = C.bright_green },
    zsh   = { nerd = " ", emoji = "⚡ ", color = C.bright_green },
    fish  = { nerd = " ", emoji = "⚡ ", color = C.bright_green },
    bat   = { nerd = " ", emoji = "⚡ ", color = C.bright_green },
    cmd   = { nerd = " ", emoji = "⚡ ", color = C.bright_green },
    ps1   = { nerd = " ", emoji = "⚡ ", color = C.bright_green },
    c     = { nerd = " ", emoji = "📜 ", color = C.bright_blue },
    h     = { nerd = " ", emoji = "📜 ", color = C.bright_blue },
    cpp   = { nerd = " ", emoji = "📜 ", color = C.bright_blue },
    hpp   = { nerd = " ", emoji = "📜 ", color = C.bright_blue },
    cc    = { nerd = " ", emoji = "📜 ", color = C.bright_blue },
    rs    = { nerd = " ", emoji = "🦀 ", color = C.bright_red },
    go    = { nerd = " ", emoji = "🐹 ", color = C.bright_cyan },
    js    = { nerd = " ", emoji = "🌐 ", color = C.bright_yellow },
    ts    = { nerd = " ", emoji = "🌐 ", color = C.bright_blue },
    jsx   = { nerd = " ", emoji = "🌐 ", color = C.bright_yellow },
    tsx   = { nerd = " ", emoji = "🌐 ", color = C.bright_blue },
    html  = { nerd = " ", emoji = "🌐 ", color = C.bright_red },
    css   = { nerd = " ", emoji = "🎨 ", color = C.bright_blue },
    scss  = { nerd = " ", emoji = "🎨 ", color = C.bright_magenta },
    php   = { nerd = " ", emoji = "🐘 ", color = C.bright_magenta },
    rb    = { nerd = " ", emoji = "💎 ", color = C.bright_red },
    java  = { nerd = " ", emoji = "☕ ", color = C.bright_red },
    kt    = { nerd = " ", emoji = "☕ ", color = C.bright_yellow },
    cs    = { nerd = " ", emoji = "🔷 ", color = C.bright_green },

    -- Images
    png   = { nerd = " ", emoji = "🖼  ", color = C.bright_magenta },
    jpg   = { nerd = " ", emoji = "🖼  ", color = C.bright_magenta },
    jpeg  = { nerd = " ", emoji = "🖼  ", color = C.bright_magenta },
    gif   = { nerd = " ", emoji = "🖼  ", color = C.bright_magenta },
    bmp   = { nerd = " ", emoji = "🖼  ", color = C.bright_magenta },
    webp  = { nerd = " ", emoji = "🖼  ", color = C.bright_magenta },
    svg   = { nerd = " ", emoji = "🎨 ", color = C.bright_yellow },
    ico   = { nerd = " ", emoji = "🖼  ", color = C.bright_cyan },
    tiff  = { nerd = " ", emoji = "🖼  ", color = C.bright_magenta },

    -- Config / Data
    json  = { nerd = " ", emoji = "⚙  ", color = C.bright_yellow },
    yaml  = { nerd = " ", emoji = "⚙  ", color = C.bright_yellow },
    yml   = { nerd = " ", emoji = "⚙  ", color = C.bright_yellow },
    toml  = { nerd = " ", emoji = "⚙  ", color = C.bright_yellow },
    xml   = { nerd = " ", emoji = "⚙  ", color = C.bright_yellow },
    conf  = { nerd = " ", emoji = "⚙  ", color = C.bright_white },
    ini   = { nerd = " ", emoji = "⚙  ", color = C.bright_white },
    env   = { nerd = " ", emoji = "🔒 ", color = C.bright_yellow },
    sql   = { nerd = " ", emoji = "🗄  ", color = C.bright_magenta },

    -- Documents
    md    = { nerd = " ", emoji = "📝 ", color = C.bright_white },
    txt   = { nerd = " ", emoji = "📄 ", color = C.bright_white },
    pdf   = { nerd = " ", emoji = "📕 ", color = C.bright_red },
    log   = { nerd = " ", emoji = "📋 ", color = C.gray },

    -- Archives
    zip   = { nerd = " ", emoji = "📦 ", color = C.bright_red },
    tar   = { nerd = " ", emoji = "📦 ", color = C.bright_red },
    gz    = { nerd = " ", emoji = "📦 ", color = C.bright_red },
    bz2   = { nerd = " ", emoji = "📦 ", color = C.bright_red },
    xz    = { nerd = " ", emoji = "📦 ", color = C.bright_red },
    ["7z"]= { nerd = " ", emoji = "📦 ", color = C.bright_red },
    rar   = { nerd = " ", emoji = "📦 ", color = C.bright_red },

    -- Executable / Binary
    exe   = { nerd = " ", emoji = "🔧 ", color = C.bright_green },
    dll   = { nerd = " ", emoji = "🔧 ", color = C.bright_red },
    so    = { nerd = " ", emoji = "🔧 ", color = C.bright_red },
    bin   = { nerd = " ", emoji = "🔧 ", color = C.bright_red },
}

function IconEngine.get(name, is_dir, is_symlink, is_exec)
    local mode = IconEngine.mode
    if mode == "none" then return "", 0 end

    if mode == "ascii" then
        if is_dir then
            return (name == ".." and "[..]  " or "[DIR] "), 6
        elseif is_symlink then
            return "[@]   ", 6
        elseif is_exec then
            return "[*]   ", 6
        end
        local ext = (name:match("%.([%w_%-]+)$") or ""):lower()
        if EXT_ICONS[ext] then
            if ext == "png" or ext == "jpg" or ext == "jpeg" or ext == "gif" or ext == "bmp" or ext == "webp" then
                return "[IMG] ", 6
            elseif ext == "lua" or ext == "py" or ext == "sh" or ext == "c" or ext == "cpp" or ext == "rs" or ext == "go" or ext == "js" or ext == "ts" then
                return "[SRC] ", 6
            elseif ext == "md" or ext == "txt" or ext == "log" then
                return "[TXT] ", 6
            elseif ext == "zip" or ext == "tar" or ext == "gz" or ext == "7z" then
                return "[ARC] ", 6
            end
        end
        return "[   ] ", 6
    end

    -- Graphical modes: "nerd" or "emoji"
    local is_emoji = (mode == "emoji")

    if is_dir then
        if name == ".." then
            return (is_emoji and (C.bright_yellow .. "📁 " .. C.reset) or (C.bright_yellow .. "  " .. C.reset)), 3
        else
            return (is_emoji and (C.bright_blue .. "📁 " .. C.reset) or (C.bright_blue .. "  " .. C.reset)), 3
        end
    end

    if is_symlink then
        return (is_emoji and (C.bright_cyan .. "🔗 " .. C.reset) or (C.bright_cyan .. "  " .. C.reset)), 3
    end

    local ext = (name:match("%.([%w_%-]+)$") or ""):lower()
    local mapped = EXT_ICONS[ext]
    if mapped then
        local glyph = is_emoji and mapped.emoji or mapped.nerd
        return (mapped.color .. glyph .. C.reset), 3
    end

    if is_exec then
        return (is_emoji and (C.bright_green .. "🔧 " .. C.reset) or (C.bright_green .. "  " .. C.reset)), 3
    end

    return (is_emoji and (C.gray .. "📄 " .. C.reset) or (C.gray .. "  " .. C.reset)), 3
end

function IconEngine.cycle()
    if IconEngine.mode == "nerd" then
        IconEngine.mode = "emoji"
    elseif IconEngine.mode == "emoji" then
        IconEngine.mode = "ascii"
    elseif IconEngine.mode == "ascii" then
        IconEngine.mode = "none"
    else
        IconEngine.mode = "nerd"
    end
    return IconEngine.mode
end

--------------------------------------------------------------------------------
-- Terminal Controller
--------------------------------------------------------------------------------
local Term = {
    orig_termios = nil,
    hIn = nil,
    hOut = nil,
    orig_in_mode = nil,
    orig_out_mode = nil,
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

function Term.enable_raw()
    if Term.is_raw then return end
    if IS_WINDOWS then
        if Term.hIn ~= nil and Term.hIn ~= ffi.cast("HANDLE", -1) then
            local mode = ffi.new("DWORD[1]")
            if ffi.C.GetConsoleMode(Term.hIn, mode) ~= 0 then
                Term.orig_in_mode = mode[0]
                local raw_mode = bit.band(mode[0], bit.bnot(bit.bor(0x0002, 0x0004))) -- DISABLE LINE_INPUT & ECHO
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
            raw.c_cc[6] = 1 -- VTIME (100ms timeout)
            ffi.C.tcsetattr(0, 0, raw)
        end
    end

    io.write("\27[?1049h\27[?25l\27[2J\27[H")
    io.flush()
    Term.is_raw = true
end

function Term.restore()
    if not Term.is_raw then return end
    io.write("\27[?1049l\27[?25h")
    io.flush()

    if IS_WINDOWS then
        if Term.hIn ~= nil and Term.orig_in_mode ~= nil then
            ffi.C.SetConsoleMode(Term.hIn, Term.orig_in_mode)
        end
        if Term.hOut ~= nil and Term.orig_out_mode ~= nil then
            ffi.C.SetConsoleMode(Term.hOut, Term.orig_out_mode)
        end
    else
        if Term.orig_termios ~= nil then
            ffi.C.tcsetattr(0, 0, Term.orig_termios)
        end
    end
    Term.is_raw = false
end

function Term.get_size()
    if IS_WINDOWS then
        if Term.hOut ~= nil and Term.hOut ~= ffi.cast("HANDLE", -1) then
            local csbi = ffi.new("CONSOLE_SCREEN_BUFFER_INFO")
            if ffi.C.GetConsoleScreenBufferInfo(Term.hOut, csbi) ~= 0 then
                local w = csbi.srWindow.Right - csbi.srWindow.Left + 1
                local h = csbi.srWindow.Bottom - csbi.srWindow.Top + 1
                if w > 0 and h > 0 then return w, h end
            end
        end
    else
        local ws = ffi.new("struct winsize")
        -- TIOCGWINSZ = 0x5413 on Linux
        if ffi.C.ioctl(0, 0x5413, ws) == 0 then
            if ws.ws_col > 0 and ws.ws_row > 0 then
                return tonumber(ws.ws_col), tonumber(ws.ws_row)
            end
        end
    end
    return 100, 30 -- safe fallback
end

function Term.read_key()
    Term.key_queue = Term.key_queue or {}
    if #Term.key_queue > 0 then
        return table.remove(Term.key_queue, 1)
    end

    if IS_WINDOWS then
        if _G.msvcrt._kbhit() == 0 then
            ffi.C.Sleep(20)
            return nil
        end
        local ch = _G.msvcrt._getch()
        if ch == 0 or ch == 224 then
            local ch2 = _G.msvcrt._getch()
            if ch2 == 72 then return "up"
            elseif ch2 == 80 then return "down"
            elseif ch2 == 75 then return "left"
            elseif ch2 == 77 then return "right"
            elseif ch2 == 73 then return "page_up"
            elseif ch2 == 81 then return "page_down"
            elseif ch2 == 71 then return "home"
            elseif ch2 == 79 then return "end"
            end
        elseif ch == 13 then return "enter"
        elseif ch == 27 then return "escape"
        elseif ch == 8 then return "backspace"
        elseif ch == 9 then return "tab"
        elseif ch == 3 then return "ctrl_c"
        elseif ch == 4 then return "ctrl_d"
        elseif ch == 21 then return "ctrl_u"
        elseif ch == 23 then return "ctrl_w"
        elseif ch == 2 then return "ctrl_b"
        elseif ch == 6 then return "ctrl_f"
        elseif ch >= 32 and ch <= 126 then
            return string.char(ch)
        end
        return nil
    else
        local buf = ffi.new("char[64]")
        local n = ffi.C.read(0, buf, 64)
        if n == 0 then
            -- EOF on stdin (e.g. piped input or closed stream)
            return "q"
        end
        if n < 0 then return nil end

        local i = 0
        while i < n do
            if buf[i] == 27 and i + 2 < n and buf[i+1] == 91 then
                local code = buf[i+2]
                local k = nil
                local adv = 3
                if code == 65 then k = "up"
                elseif code == 66 then k = "down"
                elseif code == 67 then k = "right"
                elseif code == 68 then k = "left"
                elseif code == 72 then k = "home"
                elseif code == 70 then k = "end"
                elseif code == 53 and i + 3 < n and buf[i+3] == 126 then k = "page_up"; adv = 4
                elseif code == 54 and i + 3 < n and buf[i+3] == 126 then k = "page_down"; adv = 4
                end
                if k then
                    table.insert(Term.key_queue, k)
                    i = i + adv
                else
                    table.insert(Term.key_queue, "escape")
                    i = i + 1
                end
            else
                local b = buf[i]
                local k = nil
                if b == 10 or b == 13 then k = "enter"
                elseif b == 27 then k = "escape"
                elseif b == 127 or b == 8 then k = "backspace"
                elseif b == 9 then k = "tab"
                elseif b == 3 then k = "ctrl_c"
                elseif b == 4 then k = "ctrl_d"
                elseif b == 21 then k = "ctrl_u"
                elseif b == 23 then k = "ctrl_w"
                elseif b == 2 then k = "ctrl_b"
                elseif b == 6 then k = "ctrl_f"
                elseif b >= 32 and b <= 126 then
                    k = string.char(b)
                end
                if k then table.insert(Term.key_queue, k) end
                i = i + 1
            end
        end

        if #Term.key_queue > 0 then
            return table.remove(Term.key_queue, 1)
        end
        return nil
    end
end

--------------------------------------------------------------------------------
-- Fast Syntax Tokenizer & Highlighter for Text / Code Preview
--------------------------------------------------------------------------------
local Syntax = {}

local KEYWORDS = {
    ["function"] = true, ["local"] = true, ["return"] = true, ["if"] = true,
    ["then"] = true, ["else"] = true, ["elseif"] = true, ["end"] = true,
    ["for"] = true, ["while"] = true, ["do"] = true, ["repeat"] = true,
    ["until"] = true, ["break"] = true, ["nil"] = true, ["true"] = true,
    ["false"] = true, ["and"] = true, ["or"] = true, ["not"] = true,
    ["def"] = true, ["class"] = true, ["import"] = true, ["from"] = true,
    ["export"] = true, ["default"] = true, ["const"] = true, ["let"] = true,
    ["var"] = true, ["struct"] = true, ["enum"] = true, ["typedef"] = true,
    ["int"] = true, ["char"] = true, ["void"] = true, ["unsigned"] = true,
    ["float"] = true, ["double"] = true, ["bool"] = true, ["fn"] = true,
    ["pub"] = true, ["mut"] = true, ["impl"] = true, ["use"] = true,
    ["mod"] = true, ["select"] = true, ["insert"] = true, ["update"] = true,
    ["delete"] = true,
}

function Syntax.highlight_line(line, ext)
    if not line or #line == 0 then return "" end

    -- Check for full-line comments
    local trimmed = line:match("^%s*(.-)$") or ""
    if trimmed:sub(1, 2) == "--" or trimmed:sub(1, 2) == "//" or trimmed:sub(1, 1) == "#" or trimmed:sub(1, 1) == ";" then
        return C.gray .. C.italic .. line .. C.reset
    end

    local out = {}
    local i = 1
    local len = #line

    while i <= len do
        local c = line:sub(i, i)

        -- Strings
        if c == '"' or c == "'" or (c == '`' and (ext == "js" or ext == "ts" or ext == "go")) then
            local quote = c
            local s_start = i
            i = i + 1
            while i <= len do
                local cur = line:sub(i, i)
                if cur == '\\' then
                    i = i + 2
                elseif cur == quote then
                    i = i + 1
                    break
                else
                    i = i + 1
                end
            end
            table.insert(out, C.bright_green .. line:sub(s_start, i - 1) .. C.reset)

        -- Line Comments
        elseif (c == '-' and line:sub(i, i+1) == "--") or (c == '/' and line:sub(i, i+1) == "//") or (c == '#' and ext ~= "c" and ext ~= "cpp") then
            table.insert(out, C.gray .. C.italic .. line:sub(i) .. C.reset)
            break

        -- Identifiers / Keywords
        elseif c:match("[%a_]") then
            local id_start = i
            while i <= len and line:sub(i, i):match("[%w_]") do
                i = i + 1
            end
            local word = line:sub(id_start, i - 1)
            if KEYWORDS[word] then
                table.insert(out, C.bold .. C.bright_magenta .. word .. C.reset)
            else
                table.insert(out, word)
            end

        -- Numbers
        elseif c:match("%d") then
            local num_start = i
            while i <= len and line:sub(i, i):match("[%x%.xX_]") do
                i = i + 1
            end
            table.insert(out, C.bright_yellow .. line:sub(num_start, i - 1) .. C.reset)

        -- Operators / Punctuation
        elseif c:match("[%+%-/%*%%=<>!~%^&|]") then
            table.insert(out, C.bright_cyan .. c .. C.reset)
            i = i + 1
        else
            table.insert(out, c)
            i = i + 1
        end
    end

    return table.concat(out)
end

--------------------------------------------------------------------------------
-- Windows Native In-Process Image Rendering via LuaJIT FFI (GDI+ & Shlwapi)
--------------------------------------------------------------------------------
local GdiPlusRenderer = {
    initialized = false,
    available = false,
    token = nil,
    gdiplus = nil,
    shlwapi = nil,
}

if IS_WINDOWS then
    local ok = pcall(function()
        ffi.cdef[[
            typedef struct {
                unsigned int GdiplusVersion;
                void* DebugEventCallback;
                int SuppressBackgroundThread;
                int SuppressExternalCodecs;
            } GdiplusStartupInput;

            typedef struct {
                unsigned int Width;
                unsigned int Height;
                int Stride;
                int PixelFormat;
                void* Scan0;
                unsigned int Reserved;
            } GdiplusBitmapData;

            typedef struct {
                int X;
                int Y;
                int Width;
                int Height;
            } GdiplusRect;

            typedef struct IStreamVtbl {
                void* QueryInterface;
                void* AddRef;
                unsigned long (*Release)(void* This);
            } IStreamVtbl;

            typedef struct IStream {
                IStreamVtbl* lpVtbl;
            } IStream;

            int GdiplusStartup(unsigned long* token, const GdiplusStartupInput* input, void* output);
            void GdiplusShutdown(unsigned long token);
            int GdipCreateBitmapFromStream(IStream* stream, void** bitmap);
            int GdipGetImageWidth(void* image, unsigned int* width);
            int GdipGetImageHeight(void* image, unsigned int* height);
            int GdipCreateBitmapFromScan0(int width, int height, int stride, int format, unsigned char* scan0, void** bitmap);
            int GdipGetImageGraphicsContext(void* image, void** graphics);
            int GdipGraphicsClear(void* graphics, unsigned int color);
            int GdipSetInterpolationMode(void* graphics, int interpolationMode);
            int GdipDrawImageRectRectI(void* graphics, void* image, int dstx, int dsty, int dstwidth, int dstheight, int srcx, int srcy, int srcwidth, int srcheight, int srcUnit, void* imageAttributes, void* callback, void* callbackData);
            int GdipBitmapLockBits(void* bitmap, const GdiplusRect* rect, unsigned int flags, int format, GdiplusBitmapData* lockedBitmapData);
            int GdipBitmapUnlockBits(void* bitmap, GdiplusBitmapData* lockedBitmapData);
            int GdipDeleteGraphics(void* graphics);
            int GdipDisposeImage(void* image);

            IStream* SHCreateMemStream(const unsigned char* pInit, unsigned int cbInit);
        ]]
        GdiPlusRenderer.gdiplus = ffi.load("gdiplus.dll")
        GdiPlusRenderer.shlwapi = ffi.load("shlwapi.dll")
        GdiPlusRenderer.available = true
    end)
    if not ok then
        GdiPlusRenderer.available = false
    end
end

function GdiPlusRenderer.ensure_init()
    if not GdiPlusRenderer.available then return false end
    if GdiPlusRenderer.initialized then return true end

    local token = ffi.new("unsigned long[1]")
    local input = ffi.new("GdiplusStartupInput", { 1, nil, 0, 0 })
    local st = GdiPlusRenderer.gdiplus.GdiplusStartup(token, input, nil)
    if st == 0 then
        GdiPlusRenderer.token = token
        GdiPlusRenderer.initialized = true
        return true
    end
    return false
end

function GdiPlusRenderer.shutdown()
    if GdiPlusRenderer.initialized and GdiPlusRenderer.token then
        pcall(function()
            GdiPlusRenderer.gdiplus.GdiplusShutdown(GdiPlusRenderer.token[0])
        end)
        GdiPlusRenderer.initialized = false
        GdiPlusRenderer.token = nil
    end
end

function GdiPlusRenderer.render_half_blocks(data, w, h)
    if not GdiPlusRenderer.ensure_init() then return nil end
    if not data or #data < 10 then return nil end

    local gdi = GdiPlusRenderer.gdiplus
    local shl = GdiPlusRenderer.shlwapi

    local stream = shl.SHCreateMemStream(ffi.cast("const unsigned char*", data), #data)
    if stream == nil then return nil end

    local pSrc = ffi.new("void*[1]")
    local st = gdi.GdipCreateBitmapFromStream(stream, pSrc)
    if st ~= 0 or pSrc[0] == nil then
        pcall(function() stream.lpVtbl.Release(stream) end)
        return nil
    end

    local srcW = ffi.new("unsigned int[1]")
    local srcH = ffi.new("unsigned int[1]")
    gdi.GdipGetImageWidth(pSrc[0], srcW)
    gdi.GdipGetImageHeight(pSrc[0], srcH)

    if srcW[0] == 0 or srcH[0] == 0 then
        gdi.GdipDisposeImage(pSrc[0])
        pcall(function() stream.lpVtbl.Release(stream) end)
        return nil
    end

    local scale = math.min(w / srcW[0], (h * 2) / srcH[0])
    local fit_w = math.max(1, math.floor(srcW[0] * scale))
    local fit_h = math.max(1, math.floor(srcH[0] * scale))
    local actual_h = math.min(h, math.max(1, math.ceil(fit_h / 2)))
    local actual_pixel_h = actual_h * 2

    local PixelFormat24bppRGB = 0x21808

    local pDst = ffi.new("void*[1]")
    st = gdi.GdipCreateBitmapFromScan0(fit_w, actual_pixel_h, 0, PixelFormat24bppRGB, nil, pDst)
    if st ~= 0 or pDst[0] == nil then
        gdi.GdipDisposeImage(pSrc[0])
        pcall(function() stream.lpVtbl.Release(stream) end)
        return nil
    end

    local pGfx = ffi.new("void*[1]")
    st = gdi.GdipGetImageGraphicsContext(pDst[0], pGfx)
    if st ~= 0 or pGfx[0] == nil then
        gdi.GdipDisposeImage(pDst[0])
        gdi.GdipDisposeImage(pSrc[0])
        pcall(function() stream.lpVtbl.Release(stream) end)
        return nil
    end

    -- Clear background with dark slate (ARGB 0xFF181818) so transparency composites cleanly
    gdi.GdipGraphicsClear(pGfx[0], 0xFF181818)

    -- InterpolationModeHighQualityBicubic = 7
    gdi.GdipSetInterpolationMode(pGfx[0], 7)

    -- Scale and resample image directly into destination buffer
    st = gdi.GdipDrawImageRectRectI(pGfx[0], pSrc[0], 0, 0, fit_w, actual_pixel_h, 0, 0, srcW[0], srcH[0], 2, nil, nil, nil)
    gdi.GdipDeleteGraphics(pGfx[0])
    gdi.GdipDisposeImage(pSrc[0])
    pcall(function() stream.lpVtbl.Release(stream) end)

    if st ~= 0 then
        gdi.GdipDisposeImage(pDst[0])
        return nil
    end

    -- Lock bitmap bits for fast direct memory pointer reading
    local rect = ffi.new("GdiplusRect", { 0, 0, fit_w, actual_pixel_h })
    local bmpData = ffi.new("GdiplusBitmapData")
    -- ImageLockModeRead = 1
    st = gdi.GdipBitmapLockBits(pDst[0], rect, 1, PixelFormat24bppRGB, bmpData)
    if st ~= 0 or bmpData.Scan0 == nil then
        gdi.GdipDisposeImage(pDst[0])
        return nil
    end

    local lines = {}
    local ptr = ffi.cast("const uint8_t*", bmpData.Scan0)
    local stride = bmpData.Stride

    for row = 0, actual_h - 1 do
        local row_buf = {}
        local row1_offset = (row * 2) * stride
        local row2_offset = (row * 2 + 1) * stride
        for col = 0, fit_w - 1 do
            -- GDI+ 24bpp is BGR byte order
            local col_offset = col * 3
            local b1 = ptr[row1_offset + col_offset]
            local g1 = ptr[row1_offset + col_offset + 1]
            local r1 = ptr[row1_offset + col_offset + 2]
            local b2 = ptr[row2_offset + col_offset]
            local g2 = ptr[row2_offset + col_offset + 1]
            local r2 = ptr[row2_offset + col_offset + 2]
            table.insert(row_buf, string.format("\27[38;2;%d;%d;%dm\27[48;2;%d;%d;%dm▀", r1, g1, b1, r2, g2, b2))
        end
        table.insert(row_buf, C.reset)
        table.insert(lines, table.concat(row_buf))
    end

    gdi.GdipBitmapUnlockBits(pDst[0], bmpData)
    gdi.GdipDisposeImage(pDst[0])

    return lines
end

--------------------------------------------------------------------------------
-- Image Terminal Rendering Engine (Half-Blocks & Graphics Protocol)
--------------------------------------------------------------------------------
local ImageRenderer = {
    protocol = "blocks", -- "blocks" (Universal Half-Blocks) or "graphics" (OSC 1337)
    preferred_engine = "auto", -- "auto", "ffi", "chafa", "magick", "python"
    last_engine = "None",
    cache = {},
}

local ENGINES = { "auto", "ffi", "chafa", "magick", "python" }

function ImageRenderer.cycle_engine()
    local cur = (ImageRenderer.preferred_engine or "auto"):lower()
    for idx, e in ipairs(ENGINES) do
        if e == cur then
            local nxt = ENGINES[(idx % #ENGINES) + 1]
            ImageRenderer.preferred_engine = nxt
            ImageRenderer.cache = {}
            return nxt
        end
    end
    ImageRenderer.preferred_engine = "auto"
    ImageRenderer.cache = {}
    return "auto"
end

-- Detect file extension based on magic bytes or path
local function detect_image_ext(path_or_bytes)
    if type(path_or_bytes) == "string" and #path_or_bytes >= 4 then
        if path_or_bytes:sub(1, 4) == "\137PNG" then return ".png" end
        if path_or_bytes:sub(1, 3) == "\255\216\255" then return ".jpg" end
        if path_or_bytes:sub(1, 4) == "GIF8" then return ".gif" end
        if path_or_bytes:sub(1, 2) == "BM" then return ".bmp" end
        if path_or_bytes:sub(1, 4) == "RIFF" and path_or_bytes:sub(9, 12) == "WEBP" then return ".webp" end
        local ext = path_or_bytes:match("%.([%w_%-]+)$")
        if ext then return "." .. ext:lower() end
    end
    return ".png"
end

-- Render downscaled image to 24-bit half-blocks via FFI, Chafa, ImageMagick (magick), or Python Pillow
function ImageRenderer.render_half_blocks(image_path_or_bytes, w, h)
    if w < 2 or h < 2 then return { " [Window too small for image preview] " }, "None" end

    local pref = (ImageRenderer.preferred_engine or "auto"):lower()

    -- 0. Windows Native In-Process FFI Engine (GDI+ via shlwapi/gdiplus)
    if (pref == "auto" or pref == "ffi") and IS_WINDOWS and GdiPlusRenderer.available then
        local raw_data = nil
        local is_file = type(image_path_or_bytes) == "string" and #image_path_or_bytes < 1024
            and not image_path_or_bytes:find("[\0\r\n]") and file_exists(image_path_or_bytes)
        if is_file then
            local f = io.open(image_path_or_bytes, "rb")
            if f then
                raw_data = f:read("*a")
                f:close()
            end
        elseif type(image_path_or_bytes) == "string" then
            raw_data = image_path_or_bytes
        end

        if raw_data and #raw_data > 0 then
            local ffi_lines = GdiPlusRenderer.render_half_blocks(raw_data, w, h)
            if ffi_lines and #ffi_lines > 0 then
                ImageRenderer.last_engine = "FFI/GDI+"
                return ffi_lines, "FFI/GDI+"
            end
        end
        if pref == "ffi" then
            ImageRenderer.last_engine = "None"
            return { " [FFI/GDI+: Failed to decode image format in memory] " }, "None"
        end
    elseif pref == "ffi" then
        ImageRenderer.last_engine = "None"
        return { " [FFI Engine unavailable: Requires Windows GDI+] " }, "None"
    end

    local null_dev = IS_WINDOWS and "2>nul" or "2>/dev/null"
    local ext = detect_image_ext(image_path_or_bytes)
    local tmp_file = nil
    local src_file = image_path_or_bytes
    if type(image_path_or_bytes) == "string" and #image_path_or_bytes > 0 and image_path_or_bytes:sub(1, 4) ~= "\137PNG" and file_exists(image_path_or_bytes) then
        src_file = image_path_or_bytes
    else
        local tmp_dir = IS_WINDOWS and (os.getenv("TEMP") or ".") or "/tmp"
        tmp_file = string.format("%s/rb_prev_%d_%d%s", tmp_dir, os.time(), math.random(1000, 9999), ext)
        local f = io.open(tmp_file, "wb")
        if f then
            f:write(image_path_or_bytes)
            f:close()
            src_file = tmp_file
        else
            return { " [Failed to create preview cache] " }, "None"
        end
    end

    local lines = {}

    -- 1. Try Chafa (if pref is "auto" or "chafa")
    if pref == "auto" or pref == "chafa" then
        local chafa_cmd = string.format("chafa --format symbols --symbols vhalf --colors full -s %dx%d %s %s",
            w, h, shell_escape(src_file), null_dev)
        local pipe = io.popen(chafa_cmd, "r")
        if pipe then
            local chafa_out = pipe:read("*a")
            pipe:close()
            if chafa_out and #chafa_out > 0 then
                for l in chafa_out:gmatch("([^\r\n]+)") do
                    local clean = l:gsub("\27%[[%d;?]*%a", "")
                    if #clean > 0 then
                        table.insert(lines, l .. C.reset)
                    end
                end
                if #lines > 0 then
                    if tmp_file then os.remove(tmp_file) end
                    ImageRenderer.last_engine = "Chafa"
                    return lines, "Chafa"
                end
            end
        end
        if pref == "chafa" then
            if tmp_file then os.remove(tmp_file) end
            ImageRenderer.last_engine = "None"
            return { " [Chafa engine requested but failed or 'chafa' not in PATH] " }, "None"
        end
    end

    -- 2. Try ImageMagick (if pref is "auto" or "magick")
    local raw_rgb = nil
    local engine_used = nil
    if pref == "auto" or pref == "magick" then
        local magick_cmd = IS_WINDOWS and "magick.exe" or "magick"
        local resize_arg = IS_WINDOWS and string.format("-resize %dx%d!", w, h * 2) or string.format("-resize %dx%d\\!", w, h * 2)
        local conv_cmd = string.format("%s %s %s -depth 8 rgb:- %s",
            magick_cmd, shell_escape(src_file), resize_arg, null_dev)
        local pipe = io.popen(conv_cmd, "r")
        if pipe then
            raw_rgb = pipe:read("*a")
            pipe:close()
            if raw_rgb and #raw_rgb > 0 then
                engine_used = "ImageMagick"
            end
        end

        -- If on Unix and magick failed, try convert
        if (not raw_rgb or #raw_rgb == 0) and not IS_WINDOWS then
            conv_cmd = string.format("convert %s -resize %dx%d\\! -depth 8 rgb:- 2>/dev/null",
                shell_escape(src_file), w, h * 2)
            pipe = io.popen(conv_cmd, "r")
            if pipe then
                raw_rgb = pipe:read("*a")
                pipe:close()
                if raw_rgb and #raw_rgb > 0 then
                    engine_used = "ImageMagick"
                end
            end
        end

        if pref == "magick" and (not raw_rgb or #raw_rgb == 0) then
            if tmp_file then os.remove(tmp_file) end
            ImageRenderer.last_engine = "None"
            return { " [ImageMagick engine requested but failed or 'magick' not in PATH] " }, "None"
        end
    end

    -- 3. Try Python Pillow (if pref is "auto" or "python")
    if (not raw_rgb or #raw_rgb == 0) and (pref == "auto" or pref == "python") then
        local py_script = string.format(
            "import sys; from PIL import Image; img=Image.open(r'%s').convert('RGB').resize((%d,%d)); sys.stdout.buffer.write(img.tobytes())",
            src_file:gsub("'", "\\'"), w, h * 2
        )
        local py_cmd = string.format('python -c "%s" %s', py_script, null_dev)
        local pipe = io.popen(py_cmd, "rb")
        if pipe then
            raw_rgb = pipe:read("*a")
            pipe:close()
            if raw_rgb and #raw_rgb > 0 then
                engine_used = "Python/Pillow"
            end
        end
        if (not raw_rgb or #raw_rgb == 0) and not IS_WINDOWS then
            py_cmd = string.format('python3 -c "%s" %s', py_script, null_dev)
            pipe = io.popen(py_cmd, "rb")
            if pipe then
                raw_rgb = pipe:read("*a")
                pipe:close()
                if raw_rgb and #raw_rgb > 0 then
                    engine_used = "Python/Pillow"
                end
            end
        end

        if pref == "python" and (not raw_rgb or #raw_rgb == 0) then
            if tmp_file then os.remove(tmp_file) end
            ImageRenderer.last_engine = "None"
            return { " [Python/Pillow engine requested but failed or PIL not installed] " }, "None"
        end
    end

    if tmp_file then os.remove(tmp_file) end

    local expected_bytes = w * (h * 2) * 3
    if raw_rgb and #raw_rgb >= expected_bytes then
        local ptr = ffi.cast("const uint8_t*", raw_rgb)
        for row = 0, h - 1 do
            local row_buf = {}
            for col = 0, w - 1 do
                local idx1 = (row * 2 * w + col) * 3
                local idx2 = ((row * 2 + 1) * w + col) * 3
                local r1, g1, b1 = ptr[idx1], ptr[idx1 + 1], ptr[idx1 + 2]
                local r2, g2, b2 = ptr[idx2], ptr[idx2 + 1], ptr[idx2 + 2]
                table.insert(row_buf, string.format("\27[38;2;%d;%d;%dm\27[48;2;%d;%d;%dm▀", r1, g1, b1, r2, g2, b2))
            end
            table.insert(row_buf, C.reset)
            table.insert(lines, table.concat(row_buf))
        end
        ImageRenderer.last_engine = engine_used or "ImageMagick"
        return lines, engine_used or "ImageMagick"
    end

    -- Fallback simple placeholder card
    table.insert(lines, C.gray .. "┌" .. string.rep("─", w - 2) .. "┐" .. C.reset)
    local msg = IS_WINDOWS and " [Image: Install chafa ('winget install chafa') for Half-Block Rendering] "
        or " [Image: Install chafa or ImageMagick ('magick') for Half-Block Rendering] "
    local pad = math.max(0, math.floor((w - #msg) / 2))
    table.insert(lines, C.gray .. "│" .. string.rep(" ", pad) .. C.bright_yellow .. msg .. C.gray .. string.rep(" ", math.max(0, w - 2 - pad - #msg)) .. "│" .. C.reset)
    for _ = 1, h - 3 do
        table.insert(lines, C.gray .. "│" .. string.rep(" ", w - 2) .. "│" .. C.reset)
    end
    table.insert(lines, C.gray .. "└" .. string.rep("─", w - 2) .. "┘" .. C.reset)
    ImageRenderer.last_engine = "None"
    return lines, "None"
end

-- Detect terminal native graphics protocol support
function ImageRenderer.detect_graphics_protocol()
    local term_prog = os.getenv("TERM_PROGRAM") or ""
    local term = os.getenv("TERM") or ""
    local wez_pane = os.getenv("WEZTERM_PANE")
    local kitty_pid = os.getenv("KITTY_PID") or os.getenv("KITTY_WINDOW_ID")

    if term_prog == "WezTerm" or wez_pane ~= nil or term_prog:find("iTerm") then
        return "iterm2"
    elseif term_prog == "ghostty" or kitty_pid ~= nil or term:find("kitty") then
        return "kitty"
    end
    return "iterm2" -- default fallback for graphics
end

-- Generate WezTerm / iTerm2 OSC 1337 inline graphics escape code
function ImageRenderer.render_osc1337(data, w, h)
    local b64 = base64_encode(data)
    return string.format("\27]1337;File=inline=1;width=%dcell;height=%dcell;preserveAspectRatio=1:%s\007", w, h, b64)
end

-- Generate Kitty Graphics Protocol chunked escape code
function ImageRenderer.render_kitty(data, w, h)
    local b64 = base64_encode(data)
    local CHUNK_SIZE = 4096
    local len = #b64
    local num_chunks = math.ceil(len / CHUNK_SIZE)
    if num_chunks <= 1 then
        return string.format("\27_Ga=T,f=100,c=%d,r=%d,m=0;%s\27\\", w, h, b64)
    end
    local chunks = {}
    for i = 1, num_chunks do
        local start_idx = (i - 1) * CHUNK_SIZE + 1
        local end_idx = math.min(i * CHUNK_SIZE, len)
        local chunk = b64:sub(start_idx, end_idx)
        local is_last = (i == num_chunks)
        local m = is_last and 0 or 1
        if i == 1 then
            table.insert(chunks, string.format("\27_Ga=T,f=100,c=%d,r=%d,m=%d;%s\27\\", w, h, m, chunk))
        else
            table.insert(chunks, string.format("\27_Gm=%d;%s\27\\", m, chunk))
        end
    end
    return table.concat(chunks)
end

-- Universal graphics protocol dispatcher
function ImageRenderer.render_graphics(data, w, h)
    local proto = ImageRenderer.protocol:lower()
    if proto == "kitty" then
        return ImageRenderer.render_kitty(data, w, h), "Kitty"
    elseif proto == "iterm" or proto == "wezterm" or proto == "osc1337" then
        return ImageRenderer.render_osc1337(data, w, h), "WezTerm/OSC-1337"
    else
        local detected = ImageRenderer.detect_graphics_protocol()
        if detected == "kitty" then
            return ImageRenderer.render_kitty(data, w, h), "Kitty"
        else
            return ImageRenderer.render_osc1337(data, w, h), "WezTerm/OSC-1337"
        end
    end
end

--------------------------------------------------------------------------------
-- Offline Simulated Demo Filesystem (For --demo and unit testing)
--------------------------------------------------------------------------------
local DemoFS = {}

-- Embedded 32x32 genuine valid concentric circle PNG
local DEMO_PNG_B64 = "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgEAIAAACsiDHgAAAAIGNIUk0AAHomAACAhAAA+gAAAIDoAAB1MAAA6mAAADqYAAAXcJy6UTwAAAAGYktHRP///////wlY99wAAAAHdElNRQfqCQ0TECt8b97QAAAAJXRFWHRkYXRlOmNyZWF0ZQAyMDI2LTA5LTEzVDE5OjE2OjQzKzAwOjAwbeiOYAAAACV0RVh0ZGF0ZTptb2RpZnkAMjAyNi0wOS0xM1QxOToxNjo0MyswMDowMBy1NtwAAAAodEVYdGRhdGU6dGltZXN0YW1wADIwMjYtMDktMTNUMTk6MTY6NDMrMDA6MDBLoBcDAAADpElEQVRYw+2Yb0wTdxzGHxxp5XpAoGCF8UfYNP5BhjQCabGMmYXGgkZpkCmxvNGlcaLdeKOGNyOLI2FgIFq3ZRtkKKiwOAUj0S1WbE0TKdKAKNVJaf1T5E+AawsHC3vRZBqT5e7SYw0Jz+vn9zzfz+9yd7+7oNxcrdZux5LVikAPsAwQ6AGWAQI9gL8K5iuIEAl6qfe3tMYZTKk5o2vLOirSq+OvGAsja4g/XwvHdZ7caNpS7tgtbzNE2+pVX/eonQqZ1eOmPyKf+9Mb5M9jVKANvj6rLU6RkvozpRsyW2uTuCY0DJjVuqGWvm5Kq6X18zuE5/4ngNiIcMlwctMPmvxtURBDBJc/u4gxuCEpOdTY3jX6YmLSlfAX+6Wc74HYqPAYe0JTm2bvtr95GN0nMURw+TJ9+YsCIDgU3D77RdPPmp2KcB6G/g81/aLZpQjzdfEMUJwlFeurQEKIqcUDgAgCTBdnScX6b3kDIEIFvVRM6ZrM5tqN7KYg0/IKgcShu73A+qSFh0Di47vnATIlL4PN+tI1mc21m4hQgZWK4QFgy6U4gymN3eiSFXWXgbiZG61AiFKeCkCIDUDILvk+IG7+hhmQCOvus+y9zdTLCiBnYu2xjuOMu56SlwFErDuiZnJGJB2RAuTmPAWL3hM8AKSfjL9g+pzJJW6rOMom7V//bxXljL3nmXpZAURWE7dGCCZXyKfyWC4AIQXyAoben4h7I24eAMa/8mxfNcPk8t40jnAB8LYbbzH06jy50TQPAJYKR5Gskck1Vlh5mgvA2J7KKobecsdueRsPAHc+ePKj6ksmF9XXeQ+YeFx/kck58bS+C6CsnQxXwBBlq1NV8gBg2emQyQbZOAHXQlkx4BQq8wHvdaMJwAwsgPeK8VfA+Z5yK+CaK1OwyepRO3NkVh4APFN0KvmqwWYu0tnYYVC9nR2APTlbDjwaCpIC9vXZBwCqv5PVG6BhwKzWPWNz2OZwlGixdE9qdfCABsl+FWeNwQ1JS183pT3Mxs4BgP5+XiU8U1La+HsXtXjz+w7VtH5+h1DPM4BPL0YnXybYS4oaL99ZgBdzEPEwtRuzCPNlLvr3wBuMxGHl1bP5g59wuTfeVcOQ+TNdv/La2YLBHF8m1wS/PinfFhEmsFKr06/Gm0zrFE8/PNhRk14Zf8mkifyO+GNk5Xi5Z/sqr+Ubx37ZOUOE7bTqVE+R82PZA880nUq+9KeXN4BAacn/VlkGCLSWPMA/SVJk1a13bcIAAAAASUVORK5CYII="

local DEMO_PNG_BYTES = base64_decode(DEMO_PNG_B64)

DemoFS["/"] = {
    { name = "..", is_dir = true, size = 4096, mtime = "2026-09-13 10:00", perms = "drwxr-xr-x" },
    { name = "etc", is_dir = true, size = 4096, mtime = "2026-09-13 09:30", perms = "drwxr-xr-x" },
    { name = "home", is_dir = true, size = 4096, mtime = "2026-09-13 10:15", perms = "drwxr-xr-x" },
    { name = "var", is_dir = true, size = 4096, mtime = "2026-09-13 11:00", perms = "drwxr-xr-x" },
    { name = "opt", is_dir = true, size = 4096, mtime = "2026-09-12 18:20", perms = "drwxr-xr-x" },
}

DemoFS["/home"] = {
    { name = "..", is_dir = true, size = 4096, mtime = "2026-09-13 10:00", perms = "drwxr-xr-x" },
    { name = "user", is_dir = true, size = 4096, mtime = "2026-09-13 10:15", perms = "drwxr-xr-x" },
}

DemoFS["/home/user"] = {
    { name = "..", is_dir = true, size = 4096, mtime = "2026-09-13 10:00", perms = "drwxr-xr-x" },
    { name = "app", is_dir = true, size = 4096, mtime = "2026-09-13 11:20", perms = "drwxr-xr-x" },
    { name = "avatar.png", is_dir = false, size = #DEMO_PNG_BYTES, mtime = "2026-09-13 11:15", perms = "-rw-r--r--" },
    { name = ".bashrc", is_dir = false, size = 3771, mtime = "2026-09-10 14:02", perms = "-rw-r--r--" },
}

DemoFS["/home/user/app"] = {
    { name = "..", is_dir = true, size = 4096, mtime = "2026-09-13 10:15", perms = "drwxr-xr-x" },
    { name = "assets", is_dir = true, size = 4096, mtime = "2026-09-13 11:30", perms = "drwxr-xr-x" },
    { name = "server.lua", is_dir = false, size = 4120, mtime = "2026-09-13 11:58", perms = "-rw-r--r--" },
    { name = "package.json", is_dir = false, size = 1240, mtime = "2026-09-12 18:20", perms = "-rw-r--r--" },
    { name = "README.md", is_dir = false, size = 2850, mtime = "2026-09-10 14:02", perms = "-rw-r--r--" },
    { name = "docker-compose.yml", is_dir = false, size = 840, mtime = "2026-09-11 16:45", perms = "-rw-r--r--" },
    { name = "deploy.sh", is_dir = false, size = 1520, mtime = "2026-09-13 08:12", perms = "-rwxr-xr-x", is_exec = true },
    { name = "current_build", is_dir = false, is_symlink = true, size = 12, mtime = "2026-09-13 08:00", perms = "lrwxrwxrwx" },
}

DemoFS["/home/user/app/assets"] = {
    { name = "..", is_dir = true, size = 4096, mtime = "2026-09-13 11:20", perms = "drwxr-xr-x" },
    { name = "logo.png", is_dir = false, size = #DEMO_PNG_BYTES, mtime = "2026-09-08 12:00", perms = "-rw-r--r--" },
}

DemoFS["/var/log"] = {
    { name = "..", is_dir = true, size = 4096, mtime = "2026-09-13 10:00", perms = "drwxr-xr-x" },
    { name = "syslog.log", is_dir = false, size = 18450, mtime = "2026-09-13 12:05", perms = "-rw-r-----" },
    { name = "nginx.log", is_dir = false, size = 9520, mtime = "2026-09-13 11:45", perms = "-rw-r--r--" },
}

local DemoContent = {
    ["/home/user/.bashrc"] = [[
# ~/.bashrc: executed by bash(1) for non-login shells.
export PATH="$HOME/bin:$PATH"
export EDITOR="vim"
alias ll='ls -la'
alias rfe='rfe.sh'
alias rbrowse='rfe.sh'
]],

    ["/home/user/avatar.png"] = DEMO_PNG_BYTES,

    ["/home/user/app/server.lua"] = [[
local ffi = require("ffi")
local http = require("http_server")

-- Initialize server application
local function start_server(port)
    local app = http.create()
    app:use(http.logger())

    app:get("/api/health", function(req, res)
        return res:json({
            status = "healthy",
            uptime = 84200,
            version = "2.4.0",
        })
    end)

    app:get("/api/users", function(req, res)
        return res:json({
            users = {
                { id = 1, name = "Alice", role = "Admin" },
                { id = 2, name = "Bob", role = "Developer" },
            }
        })
    end)

    print("[INFO] Listening on port " .. port)
    app:listen(port)
end

start_server(8080)
]],

    ["/home/user/app/README.md"] = [[
# Production Web Service

High-performance asynchronous HTTP microservice powered by LuaJIT.

## Quick Start
```bash
./deploy.sh --prod
```

## Features
- Zero-allocation buffer streaming
- In-memory metrics & health check endpoint
- Dual-platform support: Linux & Windows
- Built-in live telemetry on `:9090`
]],

    ["/home/user/app/package.json"] = [[
{
  "name": "web-service",
  "version": "2.4.0",
  "description": "High performance LuaJIT server",
  "main": "server.lua",
  "scripts": {
    "start": "luajit server.lua",
    "test": "luajit test.lua"
  },
  "dependencies": {
    "ffi": "*"
  }
}
]],

    ["/var/log/syslog.log"] = [[
Sep 13 12:00:01 prod-srv01 systemd[1]: Starting Daily apt download activities...
Sep 13 12:00:05 prod-srv01 kernel: [ 4512.182012] TCP: request_sock_TCP: Possible SYN flooding on port 8080. Sending cookies.
Sep 13 12:01:22 prod-srv01 sshd[4912]: Accepted publickey for user from 192.168.1.50 port 52314 ssh2
Sep 13 12:01:23 prod-srv01 systemd[1]: Started Session 14 of User user.
Sep 13 12:05:00 prod-srv01 rfe[5012]: Multiplexed SSH connection verified: socket active.
]],
}

DemoContent["/home/user/avatar.png"] = DEMO_PNG_BYTES
DemoContent["/home/user/app/assets/logo.png"] = DEMO_PNG_BYTES

--------------------------------------------------------------------------------
-- Remote Connection & Directory Crawler
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Remote Host Discovery & Aggregator Engine (SSH Config, Known Hosts, PuTTY, Hosts)
--------------------------------------------------------------------------------
local HostManager = {}

local function url_decode(str)
    return str:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
end

function HostManager.get_ssh_config_paths()
    local home = get_home_dir()
    local paths = {
        home .. "/.ssh/config",
        "/etc/ssh/ssh_config",
    }
    if IS_WINDOWS then
        local up = os.getenv("USERPROFILE")
        if up and up ~= home then table.insert(paths, up .. "/.ssh/config") end
    end
    return paths
end

function HostManager.parse_ssh_config(filepath)
    local hosts = {}
    if not file_exists(filepath) then return hosts end
    local f = io.open(filepath, "r")
    if not f then return hosts end

    local current_aliases = {}
    local current_params = {}

    local function flush_block()
        for _, alias in ipairs(current_aliases) do
            local entry = {
                name = alias,
                hostname = current_params.hostname or alias,
                user = current_params.user or "",
                port = current_params.port or "22",
                key = current_params.key or "",
                source = "ssh-config",
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
                if key == "host" then
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
                    end
                end
            end
        end
    end
    flush_block()
    f:close()
    return hosts
end

function HostManager.parse_known_hosts(filepath)
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
                            source = "known_hosts",
                        })
                    end
                end
            end
        end
    end
    f:close()
    return hosts
end

function HostManager.parse_putty_sessions_win32()
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
                        ffi.C.RegCloseKey(hSub)
                        if r_host ~= "" then
                            table.insert(hosts, {
                                name = decoded,
                                hostname = r_host,
                                user = r_user,
                                port = r_port,
                                key = "",
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

function HostManager.parse_hosts_file()
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
                            source = "hosts",
                        })
                    end
                end
            end
        end
    end
    f:close()
    return hosts
end

function HostManager.aggregate()
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

    -- 1. SSH config
    for _, path in ipairs(HostManager.get_ssh_config_paths()) do
        for _, h in ipairs(HostManager.parse_ssh_config(path)) do
            add_host(h)
        end
    end

    -- 2. Windows PuTTY sessions
    if IS_WINDOWS then
        for _, h in ipairs(HostManager.parse_putty_sessions_win32()) do
            add_host(h)
        end
    end

    -- 3. Known hosts
    local home = get_home_dir()
    for _, h in ipairs(HostManager.parse_known_hosts(home .. "/.ssh/known_hosts")) do
        add_host(h)
    end

    -- 4. /etc/hosts
    for _, h in ipairs(HostManager.parse_hosts_file()) do
        add_host(h)
    end

    -- Always include simulated demo host
    table.insert(all_hosts, {
        name = "[SIMULATED DEMO]",
        hostname = "prod-srv01.internal",
        user = "dev",
        port = "22",
        is_demo = true,
        source = "demo",
    })

    return all_hosts
end

local Crawler = {
    dir_cache = {},
    preview_cache = {},
}

function Crawler.get_ssh_cmd(host_cfg)
    local parts = { "ssh", "-o", "ConnectTimeout=5", "-o", "BatchMode=yes" }
    if not IS_WINDOWS then
        local socket_dir = get_home_dir() .. "/.ssh"
        parts[#parts+1] = "-o"
        parts[#parts+1] = "ControlMaster=auto"
        parts[#parts+1] = "-o"
        parts[#parts+1] = "ControlPath=" .. socket_dir .. "/rfe-%r@%h:%p"
        parts[#parts+1] = "-o"
        parts[#parts+1] = "ControlPersist=60s"
    end
    if host_cfg.port and host_cfg.port ~= "22" and host_cfg.port ~= "" then
        parts[#parts+1] = "-p"
        parts[#parts+1] = tostring(host_cfg.port)
    end
    if host_cfg.key and host_cfg.key ~= "" then
        parts[#parts+1] = "-i"
        parts[#parts+1] = shell_escape(host_cfg.key)
    end
    local target = host_cfg.hostname or host_cfg.name
    if host_cfg.user and host_cfg.user ~= "" then
        target = host_cfg.user .. "@" .. target
    end
    parts[#parts+1] = target
    return table.concat(parts, " ")
end

local MONTH_NAMES = {
    Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6,
    Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12,
}

local function parse_ls_line(line)
    if not line or line == "" then
        return nil
    end

    if line:match("^total%s+%d+") or line:match("^ls:") or line:match("^PWD:") then
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

    name = name:gsub("[\r\n]+$", "")
    local link_target = name:match("^(.-)%s+%->%s+(.*)$")
    local clean_name = link_target or name
    local is_symlink = (perms:sub(1, 1) == "l")
    local is_dir = (perms:sub(1, 1) == "d") or is_symlink
    local is_exec = (perms:find("x") ~= nil)
    local ext = (clean_name:match("%.([%w_%-]+)$") or ""):lower()
    local is_img = (ext == "png" or ext == "jpg" or ext == "jpeg" or ext == "gif" or ext == "bmp" or ext == "webp")

    return {
        name = clean_name,
        raw_name = name,
        is_dir = is_dir,
        is_symlink = is_symlink,
        is_exec = is_exec,
        is_image = is_img,
        size = is_dir and 0 or tonumber(size or 0),
        mtime = (date and time) and (date .. " " .. time) or "-",
        perms = perms,
    }
end

function Crawler.list_directory(host_cfg, remote_dir)
    remote_dir = normalize_remote_path(remote_dir)
    if not remote_dir or remote_dir == "" then remote_dir = "~" end
    local cache_key = (host_cfg.hostname or host_cfg.name or "demo") .. ":" .. remote_dir
    if Crawler.dir_cache[cache_key] then
        local entry = Crawler.dir_cache[cache_key]
        return entry.items, entry.resolved_dir, nil
    end

    if host_cfg.is_demo then
        local demo_path = remote_dir
        if demo_path == "~" or demo_path == "" then
            demo_path = "/home/user"
        end
        local list = DemoFS[demo_path] or DemoFS["/home/user"] or DemoFS["/"]
        local items = {}
        for _, it in ipairs(list) do
            local ext = (it.name:match("%.([%w_%-]+)$") or ""):lower()
            local is_img = (ext == "png" or ext == "jpg" or ext == "jpeg" or ext == "gif" or ext == "bmp" or ext == "webp")
            table.insert(items, {
                name = it.name,
                is_dir = it.is_dir,
                is_symlink = it.is_symlink or false,
                is_exec = it.is_exec or false,
                is_image = is_img,
                size = it.size,
                mtime = it.mtime,
                perms = it.perms,
            })
        end
        local res_entry = { items = items, resolved_dir = demo_path }
        Crawler.dir_cache[cache_key] = res_entry
        if demo_path ~= remote_dir then
            Crawler.dir_cache[(host_cfg.hostname or host_cfg.name or "demo") .. ":" .. demo_path] = res_entry
        end
        return items, demo_path, nil
    end

    local ssh_base = Crawler.get_ssh_cmd(host_cfg)
    local esc_dir = shell_escape(remote_dir)
    local remote_sh = string.format([=[d=%s; if [ -z "$d" ] || [ "$d" = "~" ]; then cd ~ 2>/dev/null || cd /; elif [ "${d#\~/}" != "$d" ]; then sub="${d#\~/}"; cd ~/"$sub" 2>/dev/null || cd ~/"${sub}s" 2>/dev/null || cd ~/"$sub"* 2>/dev/null || cd "$d" 2>/dev/null || cd /; else cd "$d" 2>/dev/null || cd "${d}s" 2>/dev/null || cd "$d"* 2>/dev/null || cd /; fi; echo "PWD:$(pwd)"; LC_ALL=C ls -la --time-style=+%%Y-%%m-%%d\ %%H:%%M:%%S . 2>/dev/null || LC_ALL=C ls -la .]=], esc_dir)
    local full_cmd = string.format("%s %s", ssh_base, shell_escape(remote_sh))

    local pipe = io.popen(full_cmd, "r")
    if not pipe then return nil, nil, "Failed to execute SSH command" end

    local resolved_dir = nil
    local items = {}
    for line in pipe:lines() do
        local pwd_match = line:match("^PWD:(.-)[\r\n]*$")
        if pwd_match and pwd_match ~= "" then
            resolved_dir = pwd_match
        else
            local it = parse_ls_line(line)
            if it then
                table.insert(items, it)
            end
        end
    end
    pipe:close()

    local final_dir = resolved_dir or remote_dir
    -- Ensure parent dir entry '..' is always present unless at root
    if final_dir ~= "/" then
        local has_parent = false
        for _, it in ipairs(items) do
            if it.name == ".." then has_parent = true break end
        end
        if not has_parent then
            table.insert(items, 1, {
                name = "..",
                raw_name = "..",
                is_dir = true,
                is_symlink = false,
                is_exec = true,
                is_image = false,
                size = 0,
                mtime = "-",
                perms = "drwxr-xr-x",
            })
        end
    end

    -- Sort: directories first, then alphabetically
    table.sort(items, function(a, b)
        if a.name == ".." then return true end
        if b.name == ".." then return false end
        if a.is_dir and not b.is_dir then return true end
        if not a.is_dir and b.is_dir then return false end
        return a.name:lower() < b.name:lower()
    end)

    local final_dir = resolved_dir or remote_dir
    local res_entry = { items = items, resolved_dir = final_dir }
    Crawler.dir_cache[cache_key] = res_entry
    if final_dir ~= remote_dir then
        Crawler.dir_cache[(host_cfg.hostname or host_cfg.name or "demo") .. ":" .. final_dir] = res_entry
    end
    return items, final_dir, nil
end

function Crawler.get_file_preview(host_cfg, remote_path, is_image)
    remote_path = normalize_remote_path(remote_path)
    local cache_key = (host_cfg.hostname or host_cfg.name or "demo") .. ":" .. remote_path
    if Crawler.preview_cache[cache_key] then
        return Crawler.preview_cache[cache_key]
    end

    if host_cfg.is_demo then
        local content = DemoContent[remote_path] or "File content not simulated in demo mode."
        Crawler.preview_cache[cache_key] = content
        return content
    end

    local ssh_base = Crawler.get_ssh_cmd(host_cfg)
    local esc_path = shell_escape(remote_path)
    local cmd
    if is_image then
        cmd = string.format("%s %s", ssh_base, shell_escape(string.format([=[p=%s; if [ "${p#\~/}" != "$p" ]; then p=~/"${p#\~/}"; fi; base64 -w 0 "$p" 2>/dev/null || base64 "$p" 2>/dev/null || cat "$p" 2>/dev/null]=], esc_path)))
    else
        cmd = string.format("%s %s", ssh_base, shell_escape(string.format([=[p=%s; if [ "${p#\~/}" != "$p" ]; then p=~/"${p#\~/}"; fi; head -n 250 "$p" 2>/dev/null]=], esc_path)))
    end

    local pipe = io.popen(cmd, "r")
    if not pipe then return "Failed to retrieve remote preview" end
    local content = pipe:read("*a")
    pipe:close()

    if is_image and content and #content > 0 then
        if content:sub(1, 4) ~= "\137PNG" and content:sub(1, 3) ~= "\255\216\255" and content:sub(1, 4) ~= "GIF8" and content:sub(1, 2) ~= "BM" and content:sub(1, 4) ~= "RIFF" then
            local decoded = base64_decode(content)
            if decoded and #decoded > 0 then
                content = decoded
            end
        end
    end

    Crawler.preview_cache[cache_key] = content
    return content
end

--------------------------------------------------------------------------------
-- Interactive Dual-Pane TUI Application
--------------------------------------------------------------------------------
local App = {
    running = true,
    term_w = 100,
    term_h = 30,

    host_cfg = {
        name = "demo",
        hostname = "prod-srv01.internal",
        user = "dev",
        is_demo = true,
    },
    connected = false,

    current_dir = "/home/user",
    show_hidden = false, -- Default: hide hidden files/folders (.xxx)
    items = {},
    filtered_items = {},
    cursor = 1,
    scroll_top = 1,

    filter_text = "",
    filter_mode = false,

    focus = "left", -- "left" (file tree) or "right" (preview)
    preview_scroll = 0,

    status_msg = "Ready. Press [?] for keybindings.",
    status_color = C.bright_cyan,

    modal = nil, -- "help", "download", etc.
}

function App.update_filter()
    local res = {}
    local q = (App.filter_text ~= "") and App.filter_text:lower() or nil
    local hidden_count = 0
    for _, it in ipairs(App.items) do
        local is_hidden = (it.name:sub(1, 1) == "." and it.name ~= "..")
        if is_hidden then
            hidden_count = hidden_count + 1
        end
        if App.show_hidden or not is_hidden then
            if not q or it.name:lower():find(q, 1, true) then
                table.insert(res, it)
            end
        end
    end
    App.filtered_items = res
    App.hidden_count = hidden_count
    App.cursor = math.max(1, math.min(App.cursor, #App.filtered_items))
end

function App.load_dir(dir_path)
    local items, resolved_dir, err = Crawler.list_directory(App.host_cfg, dir_path)
    if resolved_dir and resolved_dir ~= "" then
        App.current_dir = resolved_dir
    else
        App.current_dir = dir_path
    end
    if not items or #items == 0 then
        App.items = { { name = "..", raw_name = "..", is_dir = true, size = 0, mtime = "-", perms = "drwxr-xr-x" } }
        App.status_msg = err or ("Directory empty or inaccessible: " .. App.current_dir)
        App.status_color = C.bright_yellow
    else
        App.items = items
        App.update_filter()
        local hidden_hint = (not App.show_hidden and (App.hidden_count or 0) > 0)
            and string.format(" (%d hidden; press '.' to show)", App.hidden_count) or ""
        App.status_msg = string.format("Browsing: %s (%d items%s)", App.current_dir, #App.filtered_items, hidden_hint)
        App.status_color = C.bright_cyan
    end
    App.cursor = 1
    App.scroll_top = 1
    App.preview_scroll = 0
    App.update_filter()
end

function App.get_selected_item()
    if #App.filtered_items == 0 then return nil end
    return App.filtered_items[App.cursor]
end

function App.drill_down()
    local it = App.get_selected_item()
    if not it then return end

    if it.is_dir then
        if it.name == ".." then
            local parent = App.current_dir:match("^(.*)/[^/]+$")
            if not parent or parent == "" then parent = "/" end
            App.load_dir(parent)
        else
            local next_dir = (App.current_dir == "/") and ("/" .. it.name) or (App.current_dir .. "/" .. it.name)
            App.load_dir(next_dir)
        end
    else
        App.status_msg = string.format("Inspecting: %s (%s)", it.name, format_size(it.size))
        App.status_color = C.bright_green
    end
end

function App.go_parent()
    if App.current_dir == "/" then
        App.status_msg = "Already at root directory (/)"
        App.status_color = C.gray
        return
    end
    local parent = App.current_dir:match("^(.*)/[^/]+$")
    if not parent or parent == "" then parent = "/" end
    App.load_dir(parent)
end

function App.draw()
    local w, h = Term.get_size()
    App.term_w = w
    App.term_h = h

    local buf = {}
    table.insert(buf, "\27[H")

    local host_str
    if not App.connected then
        host_str = "[No Server Connected]"
    elseif App.host_cfg.is_demo then
        host_str = "[DEMO: simulated-server]"
    else
        host_str = string.format("[%s@%s]", App.host_cfg.user or "root", App.host_cfg.hostname)
    end
    local header_text = string.format(" %s%srfe v1.0%s │ %s%s%s │ Dir: %s%s%s │ Icons: %s%s%s ",
        C.bold, C.bright_cyan, C.reset,
        C.bright_green, host_str, C.reset,
        C.bright_yellow, App.current_dir, C.reset,
        C.bright_magenta, IconEngine.mode:upper(), C.reset
    )
    local rem_h = math.max(0, w - utf8_col_width(header_text))
    table.insert(buf, string.format("\27[1;1H%s%s%s%s\27[K", header_text, C.gray, BOX.h:rep(rem_h), C.reset))

    -- Geometry
    local content_h = h - 5
    if content_h < 4 then content_h = 4 end
    local left_w = math.floor(w * 0.44)
    if left_w < 32 then left_w = 32 end
    if left_w > w - 30 then left_w = w - 30 end
    local right_w = w - left_w - 3

    -- Border Header
    local left_accent = (App.focus == "left") and (C.bold .. C.bright_cyan) or C.gray
    local right_accent = (App.focus == "right") and (C.bold .. C.bright_cyan) or C.gray

    local left_title = truncate_string(" Remote Files: " .. App.current_dir .. " ", left_w - 2)
    local sel_it = App.get_selected_item()
    local right_title = sel_it and truncate_string(" Preview: " .. sel_it.name .. " ", right_w - 2) or " Preview "

    table.insert(buf, string.format("\27[2;1H%s%s%s%s%s%s%s%s\27[K",
        left_accent, BOX.tl, pad_string(left_title, left_w), BOX.tt,
        right_accent, pad_string(right_title, right_w), BOX.tr, C.reset
    ))

    -- Adjust Left List Scroll
    if App.cursor < App.scroll_top then
        App.scroll_top = App.cursor
    elseif App.cursor >= App.scroll_top + content_h then
        App.scroll_top = App.cursor - content_h + 1
    end

    -- Pre-fetch preview content for right pane
    local preview_lines = {}
    if sel_it then
        local remote_file_path = (App.current_dir == "/") and ("/" .. sel_it.name) or (App.current_dir .. "/" .. sel_it.name)
        if sel_it.is_dir then
            table.insert(preview_lines, C.bold .. C.bright_blue .. "Directory Summary" .. C.reset)
            table.insert(preview_lines, C.gray .. "──────────────────────────────────────" .. C.reset)
            table.insert(preview_lines, string.format("Name:        %s", sel_it.name))
            table.insert(preview_lines, string.format("Permissions: %s", sel_it.perms))
            table.insert(preview_lines, string.format("Modified:    %s", sel_it.mtime))
            table.insert(preview_lines, "")
            table.insert(preview_lines, C.dim .. "Press [Enter] or [l] to explore this folder." .. C.reset)
        elseif sel_it.is_image then
            local data = Crawler.get_file_preview(App.host_cfg, remote_file_path, true)
            local hdr = ImageParser.parse_header(data)
            local fmt = hdr and hdr.format or "Image"
            local res = hdr and string.format("%d × %d px", hdr.width, hdr.height) or "Unknown"
            local col = hdr and hdr.color_desc or "Color"

            if ImageRenderer.protocol == "blocks" then
                local img_h = content_h - 4
                if img_h > 2 then
                    local rendered_blocks, engine = ImageRenderer.render_half_blocks(data, right_w - 4, img_h)
                    local eng_label = string.format("%sEngine:%s %s%s%s", C.bold, C.reset, C.bright_cyan, engine or "Auto", C.reset)
                    if right_w >= 65 then
                        table.insert(preview_lines, string.format("%sFormat:%s %s  │  %sSize:%s %s  │  %sRes:%s %s  │  %s",
                            C.bold, C.reset, fmt, C.bold, C.reset, format_size(sel_it.size), C.bold, C.reset, res, eng_label))
                    else
                        table.insert(preview_lines, string.format("%sFormat:%s %s  │  %sSize:%s %s  │  %s",
                            C.bold, C.reset, fmt, C.bold, C.reset, format_size(sel_it.size), eng_label))
                    end
                    table.insert(preview_lines, C.gray .. string.rep("─", right_w - 2) .. C.reset)
                    for _, l in ipairs(rendered_blocks) do
                        table.insert(preview_lines, l)
                    end
                end
            else
                local gfx, proto_name = ImageRenderer.render_graphics(data, right_w - 4, content_h - 4)
                table.insert(preview_lines, string.format("%sFormat:%s %s  │  %sSize:%s %s  │  %sRes:%s %s  │  %sProtocol:%s %s%s%s",
                    C.bold, C.reset, fmt, C.bold, C.reset, format_size(sel_it.size), C.bold, C.reset, res, C.bold, C.reset, C.bright_magenta, proto_name, C.reset))
                table.insert(preview_lines, C.gray .. string.rep("─", right_w - 2) .. C.reset)
                table.insert(preview_lines, C.dim .. string.format("[Hardware Pixel Graphics: %s]", proto_name) .. C.reset)
                App.pending_graphic = {
                    x = left_w + 3,
                    y = 6,
                    data = gfx,
                }
            end
        else
            -- Text file preview
            local data = Crawler.get_file_preview(App.host_cfg, remote_file_path, false)
            local ext = (sel_it.name:match("%.([%w_%-]+)$") or ""):lower()
            table.insert(preview_lines, string.format("%sSize:%s %s  │  %sPerms:%s %s  │  %sModified:%s %s",
                C.bold, C.reset, format_size(sel_it.size), C.bold, C.reset, sel_it.perms, C.bold, C.reset, sel_it.mtime))
            table.insert(preview_lines, C.gray .. string.rep("─", right_w - 2) .. C.reset)

            local line_idx = 1
            for l in (data .. "\n"):gmatch("([^\r\n]*)\r?\n") do
                local highlighted = Syntax.highlight_line(l, ext)
                table.insert(preview_lines, string.format("%s%3d%s %s│%s %s", C.gray, line_idx, C.reset, C.gray, C.reset, highlighted))
                line_idx = line_idx + 1
            end
        end
    end

    -- 2. Render Rows
    for r = 1, content_h do
        local item_idx = App.scroll_top + r - 1
        local it = App.filtered_items[item_idx]

        local left_cell = ""
        if it then
            local is_cur = (item_idx == App.cursor)
            local cur_arrow = is_cur and (C.bold .. C.bright_yellow .. BOX.arrow_r .. " " .. C.reset) or "  "
            local icon_str, icon_w = IconEngine.get(it.name, it.is_dir, it.is_symlink, it.is_exec)
            local size_str = it.is_dir and "<DIR>" or format_size(it.size)

            -- Format column widths
            local name_max_w = left_w - 18 - icon_w
            if name_max_w < 8 then name_max_w = 8 end
            local name_disp = truncate_string(it.name, name_max_w)
            local name_pad = string.rep(" ", math.max(0, name_max_w - utf8_col_width(name_disp)))

            local size_pad = string.rep(" ", math.max(0, 8 - #size_str)) .. size_str
            local row_color = is_cur and (C.bold .. C.bg_sel) or (it.is_dir and C.bright_blue or C.white)

            left_cell = string.format("%s%s%s%s%s%s%s", cur_arrow, icon_str, row_color, name_disp, name_pad, size_pad, C.reset)
        end
        left_cell = pad_string(left_cell, left_w)

        -- Right cell from preview_lines
        local prev_line_idx = App.preview_scroll + r
        local right_cell = preview_lines[prev_line_idx] or ""
        right_cell = pad_string(right_cell, right_w)

        table.insert(buf, string.format("\27[%d;1H%s%s%s%s%s%s%s%s%s%s\27[K",
            r + 2,
            left_accent, BOX.v, C.reset,
            left_cell,
            C.gray, BOX.v, C.reset,
            right_cell,
            right_accent, BOX.v .. C.reset
        ))
    end

    -- 3. Bottom Pane Border
    table.insert(buf, string.format("\27[%d;1H%s%s%s%s%s%s%s\27[K",
        content_h + 3,
        left_accent, BOX.bl, BOX.h:rep(left_w), BOX.tb,
        right_accent, BOX.h:rep(right_w), BOX.br .. C.reset
    ))

    -- 4. Status Bar
    local stat_text = App.filter_mode and (C.bold .. C.bright_yellow .. " FILTER: " .. App.filter_text .. "█" .. C.reset)
        or (App.status_color .. " " .. App.status_msg .. C.reset)
    table.insert(buf, string.format("\27[%d;1H%s\27[K", content_h + 4, pad_string(stat_text, w)))

    -- 5. Footer Keybindings Guide
    local hidden_state = App.show_hidden and "ON" or ((App.hidden_count or 0) > 0 and string.format("OFF (%d)", App.hidden_count) or "OFF")
    local footer = string.format(" [Enter/l] Open [h] Up [Tab/w] Focus [j/k/g/G] Move [H] Server [.] Hidden:%s [I] Icons [e] %s [/] Filter [?] Help [q] Quit ",
        hidden_state,
        (ImageRenderer.preferred_engine or "auto"):upper()
    )
    table.insert(buf, string.format("\27[%d;1H%s%s%s%s\27[K",
        content_h + 5,
        C.bg_gray, C.bold .. C.bright_white, pad_string(footer, w), C.reset
    ))

    io.write(table.concat(buf))
    if App.pending_graphic then
        local g = App.pending_graphic
        io.write(string.format("\27[%d;%dH%s", g.y, g.x, g.data))
        App.pending_graphic = nil
    end
    io.flush()

    if App.modal == "help" then
        App.draw_help_modal()
    elseif App.modal == "host_picker" then
        App.draw_host_picker_modal()
    end
end

function App.open_host_picker()
    local hosts = HostManager.aggregate()
    App.modal_data = {
        hosts = hosts,
        filtered = hosts,
        cursor = 1,
        filter = "",
    }
    App.modal = "host_picker"
end

function App.draw_host_picker_modal()
    local w, h = App.term_w, App.term_h
    local mw = math.min(84, w - 4)
    local mh = math.min(18, h - 4)
    if mh < 8 then mh = 8 end
    local mx = math.floor((w - mw) / 2)
    local my = math.floor((h - mh) / 2)

    local d = App.modal_data or {}
    local hosts = d.filtered or d.hosts or {}
    local cur = d.cursor or 1
    local filter_str = d.filter or ""

    local lines = {}
    local nav_hint = App.connected and " [↑/↓ / j/k] Navigate   [Enter] Connect   [/] Filter   [Esc] Cancel"
        or " [↑/↓ / j/k] Navigate   [Enter] Connect   [Type] Filter   [Esc/q] Quit"
    table.insert(lines, BOX.v .. pad_string(nav_hint, mw - 2) .. BOX.v)

    local filter_prompt = (filter_str ~= "") and (" Filter: " .. filter_str .. "█") or " Filter: _ (Type to filter, or press Enter to connect)"
    table.insert(lines, BOX.v .. C.bright_yellow .. pad_string(filter_prompt, mw - 2) .. C.reset .. C.bright_cyan .. BOX.v)

    table.insert(lines, BOX.vl .. BOX.h:rep(mw - 2) .. BOX.vr)
    local header_row = string.format("   %-18s %-22s %-8s %-5s %s", "NAME", "HOST / IP", "USER", "PORT", "SOURCE")
    table.insert(lines, BOX.v .. C.bold .. pad_string(header_row, mw - 2) .. C.reset .. C.bright_cyan .. BOX.v)
    table.insert(lines, BOX.vl .. BOX.h:rep(mw - 2) .. BOX.vr)

    local view_h = mh - 7
    if view_h < 3 then view_h = 3 end
    local scroll = math.max(1, cur - view_h + 1)

    for i = 1, view_h do
        local idx = scroll + i - 1
        local h_entry = hosts[idx]
        if h_entry then
            local is_cur = (idx == cur)
            local prefix = is_cur and (BOX.arrow_r .. " ") or "  "
            local src_tag = string.format("[%s]", h_entry.source or "ssh")
            local desc = string.format("%s%-18s %-22s %-8s %-5s %s",
                prefix,
                h_entry.name:sub(1, 18),
                (h_entry.hostname or ""):sub(1, 22),
                (h_entry.user ~= "" and h_entry.user or "-"):sub(1, 8),
                (h_entry.port or "22"):sub(1, 5),
                src_tag
            )
            local line_col = is_cur and (C.bold .. C.bg_sel .. C.bright_yellow) or (h_entry.is_demo and C.bright_magenta or C.white)
            table.insert(lines, BOX.v .. line_col .. pad_string(desc, mw - 2) .. C.reset .. C.bright_cyan .. BOX.v)
        else
            table.insert(lines, BOX.v .. string.rep(" ", mw - 2) .. BOX.v)
        end
    end

    local esc_hint = App.connected
        and string.format(" Total: %d server(s) | [Enter] Connect | [Esc] Cancel", #hosts)
        or string.format(" Total: %d server(s) | [Enter] Connect | [Esc/q] Quit", #hosts)
    table.insert(lines, BOX.v .. pad_string(esc_hint, mw - 2) .. BOX.v)
    table.insert(lines, BOX.bl .. BOX.h:rep(mw - 2) .. BOX.br)

    local modal_buf = {}
    for i, line in ipairs(lines) do
        table.insert(modal_buf, string.format("\27[%d;%dH%s%s%s",
            my + i - 1, mx, C.bold .. C.bright_cyan, line, C.reset
        ))
    end
    io.write(table.concat(modal_buf))
    io.flush()
end

function App.draw_help_modal()
    local w, h = App.term_w, App.term_h
    local mw = math.min(72, w - 4)

    local lines = {
        C.bold .. C.bright_cyan .. "               rfe.lua - Keyboard Controls Guide            " .. C.reset,
        C.gray .. string.rep("─", mw - 4) .. C.reset,
        string.format("  %s%-18s%s %s", C.bold .. C.yellow, "j, Down / k, Up", C.reset, "Navigate files / scroll preview"),
        string.format("  %s%-18s%s %s", C.bold .. C.yellow, "g / Home, G / End", C.reset, "Jump to first / last item (or top/bottom)"),
        string.format("  %s%-18s%s %s", C.bold .. C.yellow, "Ctrl-d / Ctrl-u", C.reset, "Jump 10 items / lines down / up"),
        string.format("  %s%-18s%s %s", C.bold .. C.yellow, "Tab / w / Ctrl-w", C.reset, "Switch focus (File Tree <-> Preview)"),
        string.format("  %s%-18s%s %s", C.bold .. C.yellow, "Enter, l, Right", C.reset, "Drill down into folder / inspect item"),
        string.format("  %s%-18s%s %s", C.bold .. C.yellow, "h, Backspace", C.reset, "Navigate to parent folder (..)"),
        string.format("  %s%-18s%s %s", C.bold .. C.yellow, "H, s", C.reset, "Open Server Selector to switch host"),
        string.format("  %s%-18s%s %s", C.bold .. C.yellow, ".", C.reset, "Toggle hidden files/folders (.xxx)"),
        string.format("  %s%-18s%s %s", C.bold .. C.yellow, "J / K, PgDn/PgUp", C.reset, "Scroll preview content smoothly"),
        string.format("  %s%-18s%s %s", C.bold .. C.yellow, "I", C.reset, "Cycle icon mode (Nerd -> Emoji -> ASCII -> None)"),
        string.format("  %s%-18s%s %s", C.bold .. C.yellow, "e", C.reset, "Cycle image engine (Auto -> FFI -> Chafa -> Magick -> Python)"),
        string.format("  %s%-18s%s %s", C.bold .. C.yellow, "i", C.reset, "Toggle image renderer (Half-Blocks / OSC 1337)"),
        string.format("  %s%-18s%s %s", C.bold .. C.yellow, "/", C.reset, "Inline fuzzy filter current directory"),
        string.format("  %s%-18s%s %s", C.bold .. C.yellow, "d", C.reset, "Download selected file/folder via SCP"),
        string.format("  %s%-18s%s %s", C.bold .. C.yellow, "r", C.reset, "Refresh remote directory and clear cache"),
        string.format("  %s%-18s%s %s", C.bold .. C.yellow, "~", C.reset, "Jump to remote user home directory"),
        string.format("  %s%-18s%s %s", C.bold .. C.yellow, "? / Esc / q", C.reset, "Close this help dialog / Quit application"),
    }

    local mh = #lines + 2
    local mx = math.floor((w - mw) / 2)
    local my = math.floor((h - mh) / 2)

    local modal_buf = {}
    table.insert(modal_buf, string.format("\27[%d;%dH%s┌%s┐%s", my, mx, C.bold .. C.bright_cyan, string.rep("─", mw - 2), C.reset))
    for idx, l in ipairs(lines) do
        table.insert(modal_buf, string.format("\27[%d;%dH%s│%s %s %s│%s",
            my + idx, mx, C.bold .. C.bright_cyan, C.reset, pad_string(l, mw - 4), C.bold .. C.bright_cyan, C.reset))
    end
    table.insert(modal_buf, string.format("\27[%d;%dH%s└%s┘%s", my + #lines + 1, mx, C.bold .. C.bright_cyan, string.rep("─", mw - 2), C.reset))
    io.write(table.concat(modal_buf))
    io.flush()
end

function App.handle_key(key)
    if not key then return end

    if App.modal == "help" then
        if key == "escape" or key == "?" or key == "q" or key == "enter" then
            App.modal = nil
        end
    elseif App.modal == "host_picker" then
        local d = App.modal_data
        if key == "escape" or key == "ctrl_c" or (not App.connected and key == "q") then
            if not App.connected then
                App.running = false
            else
                App.modal = nil
            end
        elseif key == "up" or key == "k" then
            if d.cursor > 1 then d.cursor = d.cursor - 1 end
        elseif key == "down" or key == "j" then
            if d.cursor < #d.filtered then d.cursor = d.cursor + 1 end
        elseif key == "page_up" or key == "ctrl_u" or key == "ctrl_b" then
            d.cursor = math.max(1, d.cursor - 10)
        elseif key == "page_down" or key == "ctrl_d" or key == "ctrl_f" then
            d.cursor = math.min(#d.filtered, d.cursor + 10)
        elseif (key == "g" and #d.filter == 0) or key == "home" then
            d.cursor = 1
        elseif (key == "G" and #d.filter == 0) or key == "end" then
            d.cursor = math.max(1, #d.filtered)
        elseif key == "enter" then
            local chosen = d.filtered[d.cursor]
            if chosen then
                App.host_cfg = chosen
                App.connected = true
                App.modal = nil
                Crawler.dir_cache = {}
                Crawler.preview_cache = {}
                if chosen.is_demo then
                    App.load_dir("/home/user")
                else
                    App.load_dir("~")
                end
                App.status_msg = string.format("Connected to %s (%s)", chosen.name, chosen.hostname)
                App.status_color = C.bright_green
            end
        elseif key == "backspace" then
            if #d.filter > 0 then
                d.filter = d.filter:sub(1, -2)
                local res = {}
                local q = d.filter:lower()
                for _, h in ipairs(d.hosts) do
                    if h.name:lower():find(q, 1, true) or (h.hostname and h.hostname:lower():find(q, 1, true)) then
                        table.insert(res, h)
                    end
                end
                d.filtered = res
                d.cursor = math.max(1, math.min(d.cursor, #res))
            end
        elseif #key == 1 and key:byte(1) >= 32 and key:byte(1) <= 126 then
            d.filter = d.filter .. key
            local res = {}
            local q = d.filter:lower()
            for _, h in ipairs(d.hosts) do
                if h.name:lower():find(q, 1, true) or (h.hostname and h.hostname:lower():find(q, 1, true)) then
                    table.insert(res, h)
                end
            end
            d.filtered = res
            d.cursor = 1
        end
    elseif App.filter_mode then
        if key == "enter" or key == "escape" then
            App.filter_mode = false
        elseif key == "backspace" then
            if #App.filter_text > 0 then
                App.filter_text = App.filter_text:sub(1, -2)
                App.update_filter()
            else
                App.filter_mode = false
            end
        elseif #key == 1 then
            App.filter_text = App.filter_text .. key
            App.update_filter()
        end
    else
        -- Normal navigation mode
        if key == "q" or key == "ctrl_c" then
            App.running = false
        elseif key == "up" or key == "k" then
            if App.focus == "right" then
                App.preview_scroll = math.max(0, App.preview_scroll - 1)
            else
                if App.cursor > 1 then
                    App.cursor = App.cursor - 1
                    App.preview_scroll = 0
                end
            end
        elseif key == "down" or key == "j" then
            if App.focus == "right" then
                App.preview_scroll = App.preview_scroll + 1
            else
                if App.cursor < #App.filtered_items then
                    App.cursor = App.cursor + 1
                    App.preview_scroll = 0
                end
            end
        elseif key == "page_up" or key == "K" or key == "ctrl_u" or key == "ctrl_b" then
            if App.focus == "left" then
                App.cursor = math.max(1, App.cursor - 10)
                App.preview_scroll = 0
            else
                App.preview_scroll = math.max(0, App.preview_scroll - 10)
            end
        elseif key == "page_down" or key == "J" or key == "ctrl_d" or key == "ctrl_f" then
            if App.focus == "left" then
                App.cursor = math.min(#App.filtered_items, App.cursor + 10)
                App.preview_scroll = 0
            else
                App.preview_scroll = App.preview_scroll + 10
            end
        elseif key == "home" or key == "g" then
            if App.focus == "left" then
                App.cursor = 1
                App.preview_scroll = 0
            else
                App.preview_scroll = 0
            end
        elseif key == "end" or key == "G" then
            if App.focus == "left" then
                App.cursor = math.max(1, #App.filtered_items)
                App.preview_scroll = 0
            else
                App.preview_scroll = 9999
            end
        elseif key == "enter" or key == "l" or key == "right" then
            App.drill_down()
        elseif key == "backspace" or key == "h" or key == "left" then
            App.go_parent()
        elseif key == "tab" or key == "w" or key == "ctrl_w" then
            App.focus = (App.focus == "left") and "right" or "left"
        elseif key == "H" or key == "s" then
            App.open_host_picker()
        elseif key == "." then
            App.show_hidden = not App.show_hidden
            App.update_filter()
            local count = App.hidden_count or 0
            if App.show_hidden then
                App.status_msg = string.format("Showing hidden files and folders (%d revealed).", count)
                App.status_color = C.bright_yellow
            else
                App.status_msg = string.format("Hidden files/folders are now hidden (%d hidden).", count)
                App.status_color = C.gray
            end
        elseif key == "I" then
            local new_m = IconEngine.cycle()
            App.status_msg = "Icon Mode toggled to: " .. new_m:upper()
            App.status_color = C.bright_magenta
        elseif key == "i" then
            ImageRenderer.protocol = (ImageRenderer.protocol == "blocks") and "graphics" or "blocks"
            App.status_msg = "Image Renderer toggled to: " .. ImageRenderer.protocol:upper()
            App.status_color = C.bright_yellow
        elseif key == "e" then
            local eng = ImageRenderer.cycle_engine()
            Crawler.preview_cache = {}
            App.status_msg = "Image engine set to: " .. eng:upper()
            App.status_color = C.bright_cyan
        elseif key == "/" then
            App.filter_mode = true
            App.filter_text = ""
        elseif key == "r" then
            Crawler.dir_cache = {}
            Crawler.preview_cache = {}
            App.load_dir(App.current_dir)
            App.status_msg = "Refreshed remote directory & cleared preview cache."
            App.status_color = C.bright_green
        elseif key == "~" then
            App.load_dir(App.host_cfg.is_demo and "/home/user" or "~")
        elseif key == "d" then
            local sel = App.get_selected_item()
            if sel then
                App.status_msg = string.format("[Download] Run 'scp %s:%s/%s .' to pull locally.",
                    App.host_cfg.hostname, App.current_dir, sel.name)
                App.status_color = C.bright_yellow
            end
        elseif key == "?" then
            App.modal = "help"
        end
    end
end

function App.run()
    Term.init()
    Term.enable_raw()
    if App.connected then
        App.load_dir(App.current_dir)
    end

    while App.running do
        App.term_w, App.term_h = Term.get_size()
        App.draw()
        local key = Term.read_key()
        if key then
            App.handle_key(key)
        end
    end

    Term.restore()
    if GdiPlusRenderer and GdiPlusRenderer.shutdown then
        GdiPlusRenderer.shutdown()
    end
end

--------------------------------------------------------------------------------
-- Automated Self-Test Suite (--test)
--------------------------------------------------------------------------------
local function run_tests()
    print(C.bold .. C.bright_cyan .. "=== Running rfe.lua Automated Self-Tests ===" .. C.reset)

    -- 1. Base64 Encode & Decode
    local test_str = "LuaJIT FFI Remote Browser 2026!"
    local enc = base64_encode(test_str)
    local dec = base64_decode(enc)
    assert(dec == test_str, "Base64 roundtrip failed")
    print(C.bright_green .. "  [PASS] In-Memory Base64 FFI roundtrip" .. C.reset)

    -- 2. PNG Header Parser
    local png_hdr = ImageParser.parse_header(DEMO_PNG_BYTES)
    assert(png_hdr ~= nil, "Failed to parse DEMO_PNG_BYTES")
    assert(png_hdr.format == "PNG", "Format should be PNG")
    assert(png_hdr.width == 32 and png_hdr.height == 32, "PNG dimensions should be 32x32")
    print(C.bright_green .. string.format("  [PASS] ImageParser PNG dimensions: %dx%d (%s)", png_hdr.width, png_hdr.height, png_hdr.color_desc) .. C.reset)

    -- 3. BMP Header Parser Test
    local fake_bmp = string.char(
        0x42, 0x4D, 0, 0, 0, 0, 0, 0, 0, 0, 54, 0, 0, 0, 40, 0, 0, 0,
        64, 0, 0, 0, -- Width = 64
        48, 0, 0, 0, -- Height = 48
        1, 0, 24, 0   -- 24 bpp
    )
    local bmp_hdr = ImageParser.parse_header(fake_bmp)
    assert(bmp_hdr and bmp_hdr.format == "BMP" and bmp_hdr.width == 64 and bmp_hdr.height == 48, "BMP parser failed")
    print(C.bright_green .. "  [PASS] ImageParser BMP dimensions: 64x48 (24-bit)" .. C.reset)

    -- 4. Icon Engine Verification across Modes
    local old_mode = IconEngine.mode
    IconEngine.mode = "nerd"
    local n_icon = IconEngine.get("server.lua", false, false, false)
    assert(n_icon:find(""), "Nerd font Lua icon expected")

    IconEngine.mode = "emoji"
    local e_icon = IconEngine.get("server.lua", false, false, false)
    assert(e_icon:find("🌙"), "Emoji Lua icon expected")

    local img_icon = IconEngine.get("avatar.png", false, false, false)
    assert(img_icon:find("🖼"), "Emoji Image icon expected")

    IconEngine.mode = "ascii"
    local a_icon = IconEngine.get("dir", true, false, false)
    assert(a_icon:find("%[DIR%]"), "ASCII DIR icon expected")

    IconEngine.mode = old_mode
    print(C.bright_green .. "  [PASS] IconEngine mappings: Nerd Font, Emoji, ASCII fallback" .. C.reset)

    -- 5. Syntax Tokenizer
    local h_line = Syntax.highlight_line("local function start_server(port) -- init", "lua")
    assert(h_line:find("\27%["), "Syntax line should contain ANSI codes")
    print(C.bright_green .. "  [PASS] Syntax tokenizer keyword & comment formatting" .. C.reset)

    -- 6. Demo Filesystem Listing
    local demo_host = { is_demo = true, name = "demo", hostname = "demo" }
    local items, err = Crawler.list_directory(demo_host, "/home/user/app")
    assert(items and #items > 0, "Demo listing failed: " .. tostring(err))
    assert(items[1].name == "..", "First entry should be parent directory ..")
    print(C.bright_green .. string.format("  [PASS] Demo filesystem traversal: found %d items in /home/user/app", #items) .. C.reset)

    -- 7. Shell Escape Test
    assert(shell_escape("normal_path") == "normal_path", "Safe path should not be quoted")
    local esc = shell_escape("path with spaces & 'quotes'")
    assert(esc:find("path with spaces"), "Escaped path should contain original content")
    print(C.bright_green .. "  [PASS] Shell quote escaping and path hygiene" .. C.reset)

    -- 8. Terminal Size Query Test
    Term.init()
    local tw, th = Term.get_size()
    assert(tw > 0 and th > 0, "Terminal dimensions must be > 0")
    print(C.bright_green .. string.format("  [PASS] Terminal low-level FFI dimension probe: %dx%d", tw, th) .. C.reset)

    -- 9. Host Discovery & Aggregation Test
    local discovered = HostManager.aggregate()
    assert(#discovered > 0, "HostManager should discover at least 1 host")
    local has_demo = false
    for _, h in ipairs(discovered) do
        if h.is_demo then has_demo = true; break end
    end
    assert(has_demo, "HostManager must include simulated demo host")
    print(C.bright_green .. string.format("  [PASS] HostManager aggregated %d servers (SSH config, known_hosts, hosts)", #discovered) .. C.reset)

    -- 10. Hidden File Filter & Toggle Test
    App.host_cfg = { is_demo = true, name = "demo", hostname = "demo" }
    App.show_hidden = false
    App.load_dir("/home/user")
    local found_bashrc_hidden = false
    for _, it in ipairs(App.filtered_items) do
        if it.name == ".bashrc" then found_bashrc_hidden = true break end
    end
    assert(not found_bashrc_hidden, ".bashrc should be hidden when show_hidden is false")
    assert(App.filtered_items[1].name == "..", "Parent directory .. must always remain visible")

    App.show_hidden = true
    App.update_filter()
    local found_bashrc_visible = false
    for _, it in ipairs(App.filtered_items) do
        if it.name == ".bashrc" then found_bashrc_visible = true break end
    end
    assert(found_bashrc_visible, ".bashrc must appear when show_hidden is true")
    App.show_hidden = false -- Reset
    print(C.bright_green .. "  [PASS] Hidden file filtering & toggle verification (.bashrc hidden/shown, .. preserved)" .. C.reset)

    -- 11. Remote Home Resolution & Dynamic Working Directory Test
    local home_items, resolved_home, h_err = Crawler.list_directory(demo_host, "~")
    assert(resolved_home == "/home/user", "Directory '~' must resolve to '/home/user', got: " .. tostring(resolved_home))
    assert(#home_items > 0, "Resolved home directory must contain items")
    App.load_dir("~")
    assert(App.current_dir == "/home/user", "App.current_dir must update to '/home/user', got: " .. tostring(App.current_dir))
    print(C.bright_green .. "  [PASS] Remote Home directory resolution: '~' -> " .. resolved_home .. C.reset)

    -- 12. Startup Server Selector & Modal State Test
    App.modal = nil
    App.connected = false
    App.open_host_picker()
    assert(App.modal == "host_picker", "open_host_picker must activate host_picker modal")
    assert(App.modal_data and #App.modal_data.hosts > 0, "Host picker modal must contain discovered servers")
    App.modal = nil -- Reset
    print(C.bright_green .. string.format("  [PASS] Startup Server Selector modal activation (%d servers ready)", #App.modal_data.hosts) .. C.reset)

    -- 13. ImageRenderer Multi-Engine Half-Block Rendering
    assert(utf8_col_width("▀▀▀▀▀") == 5, "Half-block character ▀ must have single-column width (5)")
    local rendered_blocks, engine = ImageRenderer.render_half_blocks(DEMO_PNG_BYTES, 24, 10)
    assert(rendered_blocks and #rendered_blocks > 0, "ImageRenderer should render preview lines")
    assert(engine ~= nil and engine ~= "None", "ImageRenderer should report an active engine")
    print(C.bright_green .. string.format("  [PASS] ImageRenderer multi-engine half-blocks: %d lines rendered via %s", #rendered_blocks, engine) .. C.reset)

    -- 14. Native In-Process FFI Image Rendering Verification
    if IS_WINDOWS and GdiPlusRenderer.available then
        local ffi_lines = GdiPlusRenderer.render_half_blocks(DEMO_PNG_BYTES, 24, 10)
        assert(ffi_lines and #ffi_lines > 0, "GdiPlusRenderer should render half-block lines from DEMO_PNG_BYTES")
        assert(ffi_lines[1]:find("▀"), "GdiPlusRenderer output lines must contain half-block character ▀")
        print(C.bright_green .. string.format("  [PASS] GdiPlusRenderer native in-process FFI: %d lines rendered in RAM", #ffi_lines) .. C.reset)
    else
        print(C.gray .. "  [SKIP] GdiPlusRenderer native FFI (Non-Windows platform)" .. C.reset)
    end

    -- 15. Explicit Image Engine Selection & Cycling Verification
    local orig_engine = ImageRenderer.preferred_engine
    ImageRenderer.preferred_engine = "ffi"
    local ffi_res, ffi_eng = ImageRenderer.render_half_blocks(DEMO_PNG_BYTES, 24, 10)
    if IS_WINDOWS and GdiPlusRenderer.available then
        assert(ffi_eng == "FFI/GDI+", "Available forced FFI engine must report 'FFI/GDI+'")
        assert(ffi_res and #ffi_res > 0, "Available forced FFI engine must render preview lines")
    else
        assert(ffi_eng == "None", "Unavailable forced FFI engine must report 'None'")
        assert(ffi_res and ffi_res[1] and ffi_res[1]:find("unavailable", 1, true),
            "Unavailable forced FFI engine must explain the Windows GDI+ requirement")
        print(C.gray .. "  [PASS] Forced FFI engine reports that Windows GDI+ is unavailable" .. C.reset)
    end

    local c1 = ImageRenderer.cycle_engine()
    assert(c1 == "chafa" and ImageRenderer.preferred_engine == "chafa", "Cycling engine should transition to 'chafa'")
    local c2 = ImageRenderer.cycle_engine()
    assert(c2 == "magick" and ImageRenderer.preferred_engine == "magick", "Cycling engine should transition to 'magick'")
    local c3 = ImageRenderer.cycle_engine()
    assert(c3 == "python" and ImageRenderer.preferred_engine == "python", "Cycling engine should transition to 'python'")
    local c4 = ImageRenderer.cycle_engine()
    assert(c4 == "auto" and ImageRenderer.preferred_engine == "auto", "Cycling engine should wrap back to 'auto'")
    ImageRenderer.preferred_engine = orig_engine
    print(C.bright_green .. "  [PASS] ImageRenderer explicit engine selection & cycle transitions" .. C.reset)

    -- 16. Real Pixel Graphics Protocol Escape Sequences (WezTerm / iTerm2 OSC 1337 & Kitty)
    local osc_code = ImageRenderer.render_osc1337(DEMO_PNG_BYTES, 30, 15)
    assert(osc_code:find("^\27%]1337;File=inline=1;width=30cell;height=15cell;preserveAspectRatio=1:"), "OSC 1337 format must match specification")
    assert(osc_code:find("\007$"), "OSC 1337 format must terminate with BEL \\007")

    local kitty_code = ImageRenderer.render_kitty(DEMO_PNG_BYTES, 30, 15)
    assert(kitty_code:find("^\27_Ga=T,f=100,c=30,r=15"), "Kitty protocol format must match specification")
    assert(kitty_code:find("\27\\$"), "Kitty protocol must terminate with ST \\27\\\\")

    local detected_proto = ImageRenderer.detect_graphics_protocol()
    assert(detected_proto == "iterm2" or detected_proto == "kitty", "detect_graphics_protocol must detect terminal protocol")
    local gfx_out, gfx_name = ImageRenderer.render_graphics(DEMO_PNG_BYTES, 30, 15)
    assert(gfx_out and #gfx_out > 0 and gfx_name ~= nil, "render_graphics must produce valid output")
    print(C.bright_green .. string.format("  [PASS] Real Pixel Graphics Protocols: WezTerm/iTerm2 OSC 1337 & Kitty (Active: %s)", gfx_name) .. C.reset)

    -- 17. Remote Directory Listing Parser (Domain Users, Symlinks, European & POSIX Dates)
    local test_lines = {
        "drwxrwxr-x 2 alice Domain Users 4096 2026-10-18 09:30:00 shared_dept",
        "drwxrwxr-x 2 DOMAIN\\alice DOMAIN\\Domain Admins 8192 2026-10-18 09:30:00 admin_dept",
        "drwxr-xr-x 2 user Domain Users 4096 Oct 18  2024 archive_dept",
        "drwxr-xr-x@ 4 user staff 128 Oct 18 09:30 macos_dept",
        "lrwxrwxrwx 1 user group 14 2026-10-18 09:30:00 symlink_dir -> /mnt/target",
        "-rw-r--r-- 1 alice Domain Users 123456 2026-10-18 09:30:00 report.pdf",
    }
    local parsed = {}
    for _, l in ipairs(test_lines) do
        local it = parse_ls_line(l)
        if it then table.insert(parsed, it) end
    end
    assert(#parsed == 6, "Expected 6 parsed items from diverse ls formats, got " .. #parsed)
    assert(parsed[1].name == "shared_dept" and parsed[1].is_dir == true, "Domain Users folder must parse as directory")
    assert(parsed[2].name == "admin_dept" and parsed[2].is_dir == true, "Domain Admins folder must parse as directory")
    assert(parsed[3].name == "archive_dept" and parsed[3].is_dir == true, "Older 2024 folder must parse as directory")
    assert(parsed[4].name == "macos_dept" and parsed[4].is_dir == true, "macOS @ ACL folder must parse as directory")
    assert(parsed[5].name == "symlink_dir" and parsed[5].is_dir == true and parsed[5].is_symlink == true, "Symlink directory must be marked is_dir")
    assert(parsed[6].name == "report.pdf" and parsed[6].is_dir == false and parsed[6].size == 123456, "Regular file must parse size")
    print(C.bright_green .. "  [PASS] Remote Listing Parser: Domain Users, Symlinks, POSIX & European dates" .. C.reset)

    -- 18. Vim Key Navigation & Pane Focus Switching (w, ctrl_w, g, G, ctrl_d, ctrl_u)
    App.modal = nil
    App.focus = "left"
    App.cursor = 1
    App.filtered_items = {
        { name = "item1", is_dir = false },
        { name = "item2", is_dir = false },
        { name = "item3", is_dir = false },
        { name = "item4", is_dir = false },
        { name = "item5", is_dir = false },
    }
    App.handle_key("w")
    assert(App.focus == "right", "'w' should switch focus to right preview pane")
    App.handle_key("ctrl_w")
    assert(App.focus == "left", "'ctrl_w' should switch focus back to left file list")
    App.handle_key("G")
    assert(App.cursor == 5, "'G' should move cursor to last item")
    App.handle_key("g")
    assert(App.cursor == 1, "'g' should move cursor to first item")
    App.handle_key("ctrl_d")
    assert(App.cursor == 5, "'ctrl_d' should advance cursor")
    App.handle_key("ctrl_u")
    assert(App.cursor == 1, "'ctrl_u' should jump cursor up")
    -- Test right preview pane scrolling with Vim keys
    App.focus = "right"
    App.preview_scroll = 0
    App.handle_key("j")
    assert(App.preview_scroll == 1, "'j' in right pane should scroll preview down 1 line")
    App.handle_key("k")
    assert(App.preview_scroll == 0, "'k' in right pane should scroll preview up 1 line")
    App.handle_key("ctrl_d")
    assert(App.preview_scroll == 10, "'ctrl_d' in right pane should scroll preview down 10 lines")
    App.handle_key("ctrl_u")
    assert(App.preview_scroll == 0, "'ctrl_u' in right pane should scroll preview up 10 lines")
    App.handle_key("G")
    assert(App.preview_scroll == 9999, "'G' in right pane should jump to preview bottom")
    App.handle_key("g")
    assert(App.preview_scroll == 0, "'g' in right pane should jump to preview top")
    App.focus = "left"
    print(C.bright_green .. "  [PASS] Vim Key Navigation & Pane Focus: w, ctrl_w, g, G, ctrl_d, ctrl_u" .. C.reset)

    print(C.bold .. C.bright_green .. "\nALL 18 TESTS PASSED SUCCESSFULLY!" .. C.reset)
    return true
end

--------------------------------------------------------------------------------
-- CLI Argument Parsing & Dispatcher
--------------------------------------------------------------------------------
local function print_help()
    print([=[
rfe.lua - Fast Interactive Remote Server Browser & Previewer (LuaJIT + FFI)

Usage:
  luajit rfe.lua [OPTIONS] [USER@HOST[:REMOTE_PATH]]
  luajit rfe.lua --demo
  luajit rfe.lua --preview <HOST> <REMOTE_PATH> [WIDTH] [HEIGHT]
  luajit rfe.lua --list <HOST> <REMOTE_PATH>
  luajit rfe.lua --test

Options:
  -H, --host <HOST>       Remote SSH host
  -u, --user <USER>       Remote SSH username
  -p, --port <PORT>       Remote SSH port (default: 22)
  -i, --identity <KEY>    Path to SSH private key
  -e, --engine <ENGINE>   Image engine: auto (default), ffi, chafa, magick, python
  --icons <MODE>          Icon style: nerd (default), emoji, ascii, none
  --protocol <MODE>       Image protocol: blocks (default) or graphics (OSC 1337)
  --demo                  Start in simulated offline demo mode
  --preview               Headless preview mode for fzf/lf/ranger
  --list                  List remote directory as TSV
  --test                  Run automated test suite
  -h, --help              Show this help message
]=])
end

local function main(args)
    local target_arg = nil
    local target_path = nil
    local explicit_demo = false
    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "--help" or a == "-h" then
            print_help()
            return
        elseif a == "--test" then
            run_tests()
            return
        elseif a == "--demo" then
            explicit_demo = true
            App.host_cfg.is_demo = true
        elseif a == "-a" or a == "--all" or a == "--hidden" then
            App.show_hidden = true
        elseif a == "--picker" then
            Term.init()
            App.term_w, App.term_h = Term.get_size()
            App.open_host_picker()
            App.draw_host_picker_modal()
            io.write("\n\n")
            return
        elseif (a == "-e" or a == "--engine") and i < #args then
            i = i + 1
            ImageRenderer.preferred_engine = args[i]:lower()
        elseif a == "--icons" and i < #args then
            i = i + 1
            IconEngine.mode = args[i]:lower()
        elseif a == "--protocol" and i < #args then
            i = i + 1
            ImageRenderer.protocol = args[i]:lower()
        elseif a == "--preview" then
            -- Headless preview mode
            local host = args[i + 1] or "demo"
            local path = args[i + 2] or "/home/user/app/server.lua"
            local pw = tonumber(args[i + 3]) or 80
            local ph = tonumber(args[i + 4]) or 24
            if host:find(":") then
                local h, p = host:match("^([^:]+):(.+)$")
                if h and p then
                    pw = tonumber(path) or 80
                    ph = tonumber(args[i + 3]) or 24
                    host = h
                    path = p
                end
            end
            local cfg = { hostname = host, is_demo = (host == "demo") }
            local ext = (path:match("%.([%w_%-]+)$") or ""):lower()
            local is_img = (ext == "png" or ext == "jpg" or ext == "jpeg" or ext == "gif" or ext == "bmp" or ext == "webp")
            local content = Crawler.get_file_preview(cfg, path, is_img)

            if is_img then
                local hdr = ImageParser.parse_header(content)
                local res = hdr and string.format("%d×%d px", hdr.width, hdr.height) or "Unknown"
                local proto = (ImageRenderer.protocol or "blocks"):lower()
                if proto == "graphics" or proto == "iterm" or proto == "wezterm" or proto == "kitty" then
                    local gfx, proto_name = ImageRenderer.render_graphics(content, pw, ph - 2)
                    print(string.format("%s[Image Preview: %s · %s · %s · Protocol: %s%s%s]%s",
                        C.bold .. C.bright_magenta, path, res, format_size(#content), C.bright_cyan, proto_name, C.bright_magenta, C.reset))
                    io.write(gfx .. "\n")
                    io.flush()
                else
                    local blocks, engine = ImageRenderer.render_half_blocks(content, pw, ph - 2)
                    print(string.format("%s[Image Preview: %s · %s · %s · Engine: %s%s%s]%s",
                        C.bold .. C.bright_magenta, path, res, format_size(#content), C.bright_cyan, engine or "None", C.bright_magenta, C.reset))
                    for _, l in ipairs(blocks) do print(l) end
                end
            else
                local l_num = 1
                for l in (content .. "\n"):gmatch("([^\r\n]*)\r?\n") do
                    if l_num > ph then break end
                    print(string.format("%s%3d%s │ %s", C.gray, l_num, C.reset, Syntax.highlight_line(l, ext)))
                    l_num = l_num + 1
                end
            end
            return
        elseif a == "--list" then
            local host = args[i + 1] or "demo"
            local path = args[i + 2] or "/"
            local cfg = { hostname = host, is_demo = (host == "demo") }
            local items, err = Crawler.list_directory(cfg, path)
            if not items then
                print("Error: " .. tostring(err))
                return
            end
            for _, it in ipairs(items) do
                print(string.format("%s\t%s\t%s\t%s", it.perms, format_size(it.size), it.mtime, it.name))
            end
            return
        elseif a == "-H" or a == "--host" then
            i = i + 1
            App.host_cfg.hostname = args[i]
            App.host_cfg.is_demo = false
        elseif a == "-u" or a == "--user" then
            i = i + 1
            App.host_cfg.user = args[i]
        elseif a == "-p" or a == "--port" then
            i = i + 1
            App.host_cfg.port = args[i]
        elseif a == "-i" or a == "--identity" then
            i = i + 1
            App.host_cfg.key = args[i]
        elseif not a:find("^%-") then
            if not target_arg then
                target_arg = a
            elseif not target_path then
                target_path = a
            end
        end
        i = i + 1
    end

    if target_arg then
        if target_arg:find("@") then
            local u, rem = target_arg:match("^([^@]+)@(.+)$")
            App.host_cfg.user = u
            target_arg = rem
        end
        if target_arg:find(":") then
            local h, p = target_arg:match("^([^:]+):(.+)$")
            App.host_cfg.hostname = h
            App.current_dir = normalize_remote_path(p)
        else
            App.host_cfg.hostname = target_arg
            App.current_dir = normalize_remote_path(target_path or "~")
        end
        App.host_cfg.is_demo = false
        App.connected = true
    elseif explicit_demo then
        App.current_dir = "/home/user"
        App.host_cfg.is_demo = true
        App.connected = true
    else
        -- Default startup: show server selector dialog immediately
        App.current_dir = "~"
        App.connected = false
        App.open_host_picker()
        App.status_msg = "Please select a server to connect..."
        App.status_color = C.bright_yellow
    end

    -- Run Interactive TUI
    App.run()
end

main({ ... })
