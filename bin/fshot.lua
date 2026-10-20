#!/usr/bin/env luajit
--[[
  fshot.lua - Screen and window capture to PNG without external tools (LuaJIT + FFI).

  Features:
    - Full virtual desktop capture across monitors, including negative coordinates.
    - Region capture in physical pixels (--region X,Y,W,H).
    - Interactive region selection (--select) over a frozen, dimmed desktop with a live
      size readout; Esc or right-click cancels (Windows only).
    - Annotation editor (--edit) that opens the capture with a rectangle tool, palette,
      line width, undo/redo, and save/copy actions (Windows only).
    - Window capture by title or process substring (--window TEXT), or of the
      foreground window (--active-window), using PrintWindow so occluded windows are
      rendered, with a screen-blit fallback when that fails.
    - PNG encoding in-process: zlib when a zlib library is available, otherwise valid
      stored-deflate blocks, so there is never an external dependency.
    - Optional clipboard copy: native CF_DIB + "PNG" formats on Windows; wl-copy or
      xclip on Linux when installed. --clip-path copies the saved path, or a
      percent-encoded markdown image link, as Unicode text instead.
    - Configurable output directory and filename template via
      ~/.config/fshot/config.lua; FSHOT_DIR and --out override it.
    - Built-in self-test suite (--test) that validates the PNG encoder without a display.

  Usage:
    fshot [--full | --region X,Y,W,H | --window TEXT | --active-window | --select]
          [options]
    fshot --list-windows
    fshot --test

  Options:
    --full               Capture the whole virtual desktop (default).
    --region X,Y,W,H     Capture a rectangle in physical pixels.
    --window TEXT        Capture the best visible window matching TEXT by title or
                         process name (Windows only).
    --active-window, -a  Capture the foreground window (Windows only).
    --list-windows       Print visible top-level windows and exit (Windows only).
    --delay MS           Wait MS milliseconds before capturing (to open menus).
    --out PATH           Output file (default: shot-YYYYmmdd-HHMMSS.png inside the
                         configured directory); a path ending in a separator writes
                         the default name inside that directory.
    --clip               Also copy the image to the system clipboard.
    --clip-path [MODE]   Also copy the saved path as text (plain), or as a
                         percent-encoded markdown image link (md).
    --no-clip            In --edit, do not copy on Enter or Save.
    --no-file            Do not write a file; requires --clip.
    --edit               Open the annotation editor before saving (Windows only).
    --tool rect          Annotation tool (phase 1 only supports rect).
    --color NAME|#RRGGBB Annotation color (default red, #E53935).
    --width N            Annotation line width in image pixels (default 4).
    --no-compress        Store uncompressed deflate blocks even when zlib is available.
    --json               Print a machine-readable summary.
    -h, --help           Show this help message.

  Exit codes:
    0  Success
    1  Capture, config, encode, write, or clipboard failure
    2  Usage error

  Platform notes:
    - Windows: capture, window matching, and clipboard copy are implemented natively.
    - Linux: full-desktop and region capture use X11 (TrueColor 24/32bpp). Wayland is
      not supported directly; use grim/slurp. Clipboard copy needs wl-copy or xclip.
]]

local ffi = require("ffi")
local bit = require("bit")

local OS = ffi.os
local IS_WINDOWS = (OS == "Windows")
local IS_LINUX = (OS == "Linux")

--------------------------------------------------------------------------------
-- FFI Declarations
--------------------------------------------------------------------------------

ffi.cdef[[
    typedef unsigned char Bytef;
    typedef unsigned int uInt;
    typedef unsigned long uLong;
    typedef unsigned long uLongf;
    uLong compressBound(uLong sourceLen);
    int compress2(Bytef* dest, uLongf* destLen, const Bytef* source, uLong sourceLen, int level);
    int uncompress(Bytef* dest, uLongf* destLen, const Bytef* source, uLong sourceLen);
    uLong crc32(uLong crc, const Bytef* buf, uInt len);
    uLong adler32(uLong adler, const Bytef* buf, uInt len);
]]

if IS_WINDOWS then
    ffi.cdef[[
        typedef void* HANDLE;
        typedef void* HWND;
        typedef void* HDC;
        typedef void* HBITMAP;
        typedef void* HGDIOBJ;
        typedef void* HGLOBAL;
        typedef unsigned long DWORD;
        typedef int BOOL;
        typedef unsigned int UINT;
        typedef long LONG;
        typedef unsigned short WORD;
        typedef unsigned char BYTE;
        typedef intptr_t LPARAM;
        typedef intptr_t LRESULT;

        typedef struct {
            LONG left;
            LONG top;
            LONG right;
            LONG bottom;
        } RECT;

        typedef struct {
            LONG biSize;
            LONG biWidth;
            LONG biHeight;
            WORD biPlanes;
            WORD biBitCount;
            DWORD biCompression;
            DWORD biSizeImage;
            LONG biXPelsPerMeter;
            LONG biYPelsPerMeter;
            DWORD biClrUsed;
            DWORD biClrImportant;
        } BITMAPINFOHEADER;

        typedef struct {
            BITMAPINFOHEADER bmiHeader;
            DWORD bmiColors[3];
        } BITMAPINFO;

        typedef int (*WNDENUMPROC)(HWND, LPARAM);
        typedef void* HMONITOR;

        typedef struct {
            DWORD cbSize;
            RECT rcMonitor;
            RECT rcWork;
            DWORD dwFlags;
        } MONITORINFO;

        HDC GetDC(HWND hWnd);
        int ReleaseDC(HWND hWnd, HDC hDC);
        HDC CreateCompatibleDC(HDC hdc);
        HBITMAP CreateCompatibleBitmap(HDC hdc, int cx, int cy);
        HGDIOBJ SelectObject(HDC hdc, HGDIOBJ h);
        BOOL DeleteObject(HGDIOBJ h);
        BOOL DeleteDC(HDC hdc);
        BOOL BitBlt(HDC hdcDest, int x, int y, int cx, int cy, HDC hdcSrc,
                    int x1, int y1, DWORD rop);
        int GetDIBits(HDC hdc, HBITMAP hbm, UINT start, UINT cLines, void* lpvBits,
                      BITMAPINFO* lpbmi, UINT usage);
        int GetSystemMetrics(int nIndex);
        short GetKeyState(int nVirtKey);
        BOOL PrintWindow(HWND hwnd, HDC hdcBlt, UINT nFlags);
        BOOL GetWindowRect(HWND hWnd, RECT* lpRect);
        BOOL GetClientRect(HWND hWnd, RECT* lpRect);
        BOOL AdjustWindowRect(RECT* lpRect, DWORD dwStyle, BOOL bMenu);
        HMONITOR MonitorFromRect(const RECT* lprc, DWORD dwFlags);
        BOOL GetMonitorInfoW(HMONITOR hMonitor, MONITORINFO* lpmi);
        BOOL IsWindowVisible(HWND hWnd);
        BOOL IsIconic(HWND hWnd);
        int GetWindowTextW(HWND hWnd, wchar_t* lpString, int nMaxCount);
        int GetWindowTextLengthW(HWND hWnd);
        DWORD GetWindowThreadProcessId(HWND hWnd, DWORD* lpdwProcessId);
        BOOL EnumWindows(WNDENUMPROC lpEnumFunc, LPARAM lParam);
        BOOL SetProcessDPIAware(void);
        BOOL SetProcessDpiAwarenessContext(void* value);
        HWND GetForegroundWindow(void);
        DWORD GetFullPathNameW(const wchar_t* lpFileName, DWORD nBufferLength,
                               wchar_t* lpBuffer, wchar_t** lpFilePart);
        BOOL CreateDirectoryW(const wchar_t* lpPathName, void* lpSecurityAttributes);

        BOOL OpenClipboard(HWND hWndNewOwner);
        BOOL CloseClipboard(void);
        BOOL EmptyClipboard(void);
        HANDLE SetClipboardData(UINT uFormat, HANDLE hMem);
        UINT RegisterClipboardFormatW(const wchar_t* lpszFormat);

        long DwmGetWindowAttribute(HWND hwnd, DWORD dwAttribute, void* pvAttribute,
                                   DWORD cbAttribute);

        HANDLE GlobalAlloc(UINT uFlags, size_t dwBytes);
        void* GlobalLock(HANDLE hMem);
        BOOL GlobalUnlock(HANDLE hMem);
        HANDLE GlobalFree(HANDLE hMem);
        HANDLE OpenProcess(DWORD dwDesiredAccess, BOOL bInheritHandle, DWORD dwProcessId);
        BOOL CloseHandle(HANDLE hObject);
        DWORD QueryFullProcessImageNameA(HANDLE hProcess, DWORD dwFlags, char* lpExeName,
                                         DWORD* lpdwSize);
        DWORD GetLastError(void);
        DWORD FormatMessageW(DWORD dwFlags, const void* lpSource, DWORD dwMessageId,
                             DWORD dwLanguageId, wchar_t* lpBuffer, DWORD nSize,
                             void* Arguments);
        void Sleep(DWORD dwMilliseconds);
        unsigned long long GetTickCount64(void);
        int MultiByteToWideChar(UINT CodePage, DWORD dwFlags, const char* lpMultiByteStr,
                                int cbMultiByte, wchar_t* lpWideCharStr, int cchWideChar);
        int WideCharToMultiByte(UINT CodePage, DWORD dwFlags, const wchar_t* lpWideCharStr,
                                int cchWideChar, char* lpMultiByteStr, int cbMultiByte,
                                const char* lpDefaultChar, BOOL* lpUsedDefaultChar);
    ]]

    ffi.cdef[[
        typedef unsigned short ATOM;
        typedef void* HINSTANCE;
        typedef void* HICON;
        typedef void* HCURSOR;
        typedef void* HBRUSH;
        typedef void* HFONT;
        typedef void* HPEN;
        typedef void* HMENU;
        typedef uintptr_t WPARAM;

        typedef struct {
            LONG x;
            LONG y;
        } POINT;

        typedef LRESULT (*WNDPROC)(HWND, UINT, WPARAM, LPARAM);

        typedef struct {
            UINT style;
            WNDPROC lpfnWndProc;
            int cbClsExtra;
            int cbWndExtra;
            HINSTANCE hInstance;
            HICON hIcon;
            HCURSOR hCursor;
            HBRUSH hbrBackground;
            const wchar_t* lpszMenuName;
            const wchar_t* lpszClassName;
        } WNDCLASSW;

        typedef struct {
            HWND hwnd;
            UINT message;
            WPARAM wParam;
            LPARAM lParam;
            DWORD time;
            POINT pt;
        } MSG;

        typedef struct {
            HDC hdc;
            BOOL fErase;
            RECT rcPaint;
            BOOL fRestore;
            BOOL fIncUpdate;
            BYTE rgbReserved[32];
        } PAINTSTRUCT;

        typedef struct {
            BYTE BlendOp;
            BYTE BlendFlags;
            BYTE SourceConstantAlpha;
            BYTE AlphaFormat;
        } BLENDFUNCTION;

        ATOM RegisterClassW(const WNDCLASSW* lpWndClass);
        HWND CreateWindowExW(DWORD dwExStyle, const wchar_t* lpClassName,
                             const wchar_t* lpWindowName, DWORD dwStyle, int X, int Y,
                             int nWidth, int nHeight, HWND hWndParent, HMENU hMenu,
                             HINSTANCE hInstance, void* lpParam);
        LRESULT DefWindowProcW(HWND hWnd, UINT Msg, WPARAM wParam, LPARAM lParam);
        BOOL DestroyWindow(HWND hWnd);
        BOOL ShowWindow(HWND hWnd, int nCmdShow);
        BOOL UpdateWindow(HWND hWnd);
        BOOL SetForegroundWindow(HWND hWnd);
        BOOL SetLayeredWindowAttributes(HWND hWnd, DWORD colorKey, BYTE alpha,
                                        DWORD flags);
        BOOL GetMessageW(MSG* lpMsg, HWND hWnd, UINT wMsgFilterMin, UINT wMsgFilterMax);
        BOOL TranslateMessage(const MSG* lpMsg);
        LRESULT DispatchMessageW(const MSG* lpMsg);
        void PostQuitMessage(int nExitCode);
        HWND SetCapture(HWND hWnd);
        BOOL ReleaseCapture(void);
        HCURSOR SetCursor(HCURSOR hCursor);
        HCURSOR LoadCursorW(HINSTANCE hInstance, const wchar_t* lpCursorName);
        HDC BeginPaint(HWND hWnd, PAINTSTRUCT* lpPaint);
        BOOL EndPaint(HWND hWnd, const PAINTSTRUCT* lpPaint);
        BOOL InvalidateRect(HWND hWnd, const RECT* lpRect, BOOL bErase);
        int GetDeviceCaps(HDC hdc, int index);

        HBRUSH CreateSolidBrush(DWORD color);
        HPEN CreatePen(int iStyle, int cWidth, DWORD color);
        HGDIOBJ GetStockObject(int i);
        int FillRect(HDC hDC, const RECT* lprc, HBRUSH hbr);
        int FrameRect(HDC hDC, const RECT* lprc, HBRUSH hbr);
        int Rectangle(HDC hdc, int left, int top, int right, int bottom);
        int SetBkMode(HDC hdc, int mode);
        DWORD SetTextColor(HDC hdc, DWORD color);
        HFONT CreateFontW(int cHeight, int cWidth, int cEscapement, int cOrientation,
                          int cWeight, DWORD bItalic, DWORD bUnderline, DWORD bStrikeOut,
                          DWORD iCharSet, DWORD iOutPrecision, DWORD iClipPrecision,
                          DWORD iQuality, DWORD iPitchAndFamily, const wchar_t* pszFaceName);
        int DrawTextW(HDC hdc, const wchar_t* lpchText, int cchText, RECT* lprc, UINT format);
        HBITMAP CreateDIBSection(HDC hdc, const BITMAPINFO* pbmi, UINT usage,
                                 void** ppvBits, HANDLE hSection, DWORD offset);
        BOOL AlphaBlend(HDC hdcDest, int xoriginDest, int yoriginDest, int wDest, int hDest,
                        HDC hdcSrc, int xoriginSrc, int yoriginSrc, int wSrc, int hSrc,
                        BLENDFUNCTION ftn);
        int SetStretchBltMode(HDC hdc, int mode);
        BOOL StretchBlt(HDC hdcDest, int xDest, int yDest, int wDest, int hDest,
                        HDC hdcSrc, int xSrc, int ySrc, int wSrc, int hSrc,
                        DWORD rop);
    ]]
else
    ffi.cdef[[
        typedef struct _XDisplay Display;

        typedef struct {
            int width;
            int height;
            int xoffset;
            int format;
            char* data;
            int byte_order;
            int bitmap_unit;
            int bitmap_bit_order;
            int bitmap_pad;
            int depth;
            int bytes_per_line;
            int bits_per_pixel;
            unsigned long red_mask;
            unsigned long green_mask;
            unsigned long blue_mask;
        } XImage;

        Display* XOpenDisplay(const char* display_name);
        int XCloseDisplay(Display* display);
        unsigned long XDefaultRootWindow(Display* display);
        XImage* XGetImage(Display* display, unsigned long drawable, int x, int y,
                          unsigned int width, unsigned int height,
                          unsigned long plane_mask, int format);
        int XDestroyImage(XImage* ximage);
        int XGetGeometry(Display* display, unsigned long drawable,
                         unsigned long* root_return, int* x_return, int* y_return,
                         unsigned int* width_return, unsigned int* height_return,
                         unsigned int* border_width_return, unsigned int* depth_return);

        struct timespec {
            long tv_sec;
            long tv_nsec;
        };
        int clock_gettime(int clock_id, struct timespec* tp);
        int usleep(unsigned int usec);
        char* getcwd(char* buffer, size_t size);
        int mkdir(const char* pathname, unsigned int mode);
        char* strerror(int errnum);
    ]]
end

local function load_first_library(names)
    for _, name in ipairs(names) do
        local loaded, library = pcall(ffi.load, name)
        if loaded and library then
            return library
        end
    end
    return nil
end

local zlib = load_first_library({ "z", "zlib1", "zlib" })

local user32, gdi32, kernel32, dwmapi, msimg32, x11

if IS_WINDOWS then
    user32 = ffi.load("user32")
    gdi32 = ffi.load("gdi32")
    kernel32 = ffi.load("kernel32")
    dwmapi = load_first_library({ "dwmapi" })
    msimg32 = load_first_library({ "msimg32" })
elseif IS_LINUX then
    x11 = load_first_library({ "X11" })
end

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local SRCCOPY = 0x00CC0020
local DIB_RGB_COLORS = 0
local BI_RGB = 0
local PW_RENDERFULLCONTENT = 2
local DWMWA_EXTENDED_FRAME_BOUNDS = 9
local CF_DIB = 8
local CF_UNICODETEXT = 13
local GMEM_MOVEABLE = 0x0002
local ERROR_ALREADY_EXISTS = 183
local EEXIST = 17
local PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
local FORMAT_MESSAGE_FROM_SYSTEM = 0x00001000
local CP_UTF8 = 65001

local SM_XVIRTUALSCREEN = 76
local SM_YVIRTUALSCREEN = 77
local SM_CXVIRTUALSCREEN = 78
local SM_CYVIRTUALSCREEN = 79

local WS_POPUP = 0x80000000
local WS_OVERLAPPEDWINDOW = 0x00CF0000
local WS_EX_TOPMOST = 0x00000008
local WS_EX_TOOLWINDOW = 0x00000080
local WS_EX_LAYERED = 0x00080000
local LWA_ALPHA = 0x00000002
local SW_SHOW = 5
local NULL_BRUSH = 5
local DEFAULT_GUI_FONT = 17
local COLORONCOLOR = 3
local MONITOR_DEFAULTTONEAREST = 2
local LOGPIXELSY = 90
local IDC_ARROW = 32512
local IDC_CROSS = 32515
local ERROR_CLASS_ALREADY_EXISTS = 1410

local WM_DESTROY = 0x0002
local WM_SIZE = 0x0005
local WM_CLOSE = 0x0010
local WM_PAINT = 0x000F
local WM_ERASEBKGND = 0x0014
local WM_SETCURSOR = 0x0020
local WM_KEYDOWN = 0x0100
local WM_MOUSEMOVE = 0x0200
local WM_LBUTTONDOWN = 0x0201
local WM_LBUTTONUP = 0x0202
local WM_RBUTTONUP = 0x0205
local VK_RETURN = 0x0D
local VK_ESCAPE = 0x1B
local VK_CONTROL = 0x11
local VK_1 = 0x31
local VK_6 = 0x36
local VK_R = 0x52
local VK_C = 0x43
local VK_S = 0x53
local VK_Y = 0x59
local VK_Z = 0x5A
local VK_OEM_4 = 0xDB
local VK_OEM_6 = 0xDD
local VK_ADD = 0x6B
local VK_SUBTRACT = 0x6D

local DT_LEFT = 0x00000000
local DT_CENTER = 0x00000001
local DT_VCENTER = 0x00000004
local DT_SINGLELINE = 0x00000020
local DT_CALCRECT = 0x00000400
local DT_END_ELLIPSIS = 0x00008000

local ZPIXMAP = 2
local LSB_FIRST = 0

local PNG_SIGNATURE = "\x89PNG\r\n\x1a\n"
local DEFLATE_BLOCK_MAX = 65535

local USAGE = [[
Usage:
  fshot [--full | --region X,Y,W,H | --window TEXT | --active-window | --select] [options]
  fshot --list-windows
  fshot --test

Capture:
  --full               Capture the whole virtual desktop (default).
  --region X,Y,W,H     Capture a rectangle in physical pixels (negative origins allowed).
  --window TEXT        Capture the best visible window matching TEXT (Windows only).
  --active-window, -a  Capture the foreground window (Windows only).
  --select, -s         Drag a rectangle to capture it (Windows only).
  --list-windows       List visible top-level windows (Windows only).
  --delay MS           Wait before capturing, so menus can be opened.

Output:
  --out PATH           Output file, or a directory ending in / or \.
  --clip               Also copy the image to the system clipboard.
  --clip-path [MODE]   Also copy the saved path as text; MODE is plain (default)
                       or md for a percent-encoded markdown image link.
  --no-clip            In --edit, do not copy on Enter or Save.
  --no-file            Do not write a file; requires --clip.
  --no-compress        Use stored deflate blocks instead of zlib compression.
  --json               Print a machine-readable summary.

Configuration:
  ~/.config/fshot/config.lua may return a table with:
    output_dir  default directory for new captures
    filename    os.date format for the file stem (no path separators)
  FSHOT_DIR overrides output_dir. Without any configuration, captures are
  written to ~/Pictures/shots (created on demand); use --out . to save into
  the current directory.

Editor (--edit, Windows only):
  --tool rect          Annotation tool; phase 1 supports rectangles only.
  --color NAME|#RRGGBB Annotation color (default red, #E53935).
  --width N            Line width in image pixels (default 4).

  The editor opens with the capture fitted to the monitor. Drag to draw a
  rectangle, 1-6 pick a color, [ and ] change width, Ctrl+Z/Ctrl+Y undo and
  redo, C copies without closing, Enter saves and copies, and Esc discards
  (a second Esc confirms when shapes exist).

Other:
  -h, --help           Show this help message.
  --test               Run the automated self-test suite.

Examples:
  fshot
  fshot --region 0,0,1280,720 --out tmp/shot.png
  fshot --window firefox --clip
  fshot --active-window --clip-path
  fshot --select --clip
  fshot --select --edit
  fshot --delay 1500 --window "Save As"
  fshot --out . --clip          # keep the old current-directory behavior
]]

--------------------------------------------------------------------------------
-- Small Helpers
--------------------------------------------------------------------------------

local function to_unsigned(value)
    if value < 0 then
        return value + 4294967296
    end
    return value
end

local function now_ms()
    if IS_WINDOWS then
        return tonumber(kernel32.GetTickCount64())
    end
    local time_spec = ffi.new("struct timespec")
    ffi.C.clock_gettime(1, time_spec)
    return tonumber(time_spec.tv_sec) * 1000 + math.floor(tonumber(time_spec.tv_nsec) / 1000000)
end

local function sleep_ms(milliseconds)
    if milliseconds <= 0 then
        return
    end
    if IS_WINDOWS then
        kernel32.Sleep(milliseconds)
    else
        ffi.C.usleep(milliseconds * 1000)
    end
end

local function format_bytes(size)
    if size >= 1024 * 1024 then
        return string.format("%.1f MB", size / (1024 * 1024))
    end
    if size >= 1024 then
        return string.format("%.1f KB", size / 1024)
    end
    return string.format("%d B", size)
end

local function normalize_selection(anchor_x, anchor_y, cursor_x, cursor_y)
    local left = math.min(anchor_x, cursor_x)
    local top = math.min(anchor_y, cursor_y)
    local right = math.max(anchor_x, cursor_x)
    local bottom = math.max(anchor_y, cursor_y)

    return {
        x = left,
        y = top,
        width = right - left + 1,
        height = bottom - top + 1,
    }
end

local function crop_bgra(pixels, source_width, rectangle)
    local row_size = rectangle.width * 4
    local cropped = ffi.new("uint8_t[?]", row_size * rectangle.height)

    for row = 0, rectangle.height - 1 do
        local source = ((rectangle.y + row) * source_width + rectangle.x) * 4
        ffi.copy(cropped + row * row_size, pixels + source, row_size)
    end

    return cropped
end

local function read_u32_be(buffer, offset)
    return buffer[offset] * 16777216
        + buffer[offset + 1] * 65536
        + buffer[offset + 2] * 256
        + buffer[offset + 3]
end

local function write_u32_be(buffer, offset, value)
    buffer[offset] = bit.band(bit.rshift(value, 24), 0xFF)
    buffer[offset + 1] = bit.band(bit.rshift(value, 16), 0xFF)
    buffer[offset + 2] = bit.band(bit.rshift(value, 8), 0xFF)
    buffer[offset + 3] = bit.band(value, 0xFF)
end

local function wide_to_utf8(wide_text)
    if not IS_WINDOWS then
        return ""
    end

    local length = kernel32.WideCharToMultiByte(CP_UTF8, 0, wide_text, -1, nil, 0, nil, nil)
    if length <= 0 then
        return ""
    end

    local buffer = ffi.new("char[?]", length)
    kernel32.WideCharToMultiByte(CP_UTF8, 0, wide_text, -1, buffer, length, nil, nil)
    return ffi.string(buffer)
end

local function utf8_to_wide(text)
    if not IS_WINDOWS then
        return nil
    end

    local length = kernel32.MultiByteToWideChar(CP_UTF8, 0, text, #text, nil, 0)
    local buffer = ffi.new("wchar_t[?]", length + 1)
    kernel32.MultiByteToWideChar(CP_UTF8, 0, text, #text, buffer, length)
    buffer[length] = 0
    return buffer
end

local function home_directory()
    return os.getenv("HOME") or os.getenv("USERPROFILE") or "."
end

local function join_path(directory, name)
    if directory == "" then
        return name
    end

    -- Keep Windows paths looking native; elsewhere a forward slash is correct.
    local separator = IS_WINDOWS and "\\" or "/"

    local base = directory:gsub("[/\\]+$", "")
    if IS_WINDOWS then
        base = base:gsub("/", "\\")
    end

    return base .. separator .. name:gsub("[/\\]", separator)
end

-- Percent-encode the characters that would break a markdown link target.
local function escape_markdown_target(path)
    local normalized = path:gsub("\\", "/")
    normalized = normalized:gsub("([%%%s%(%)])", function(character)
        return string.format("%%%02X", character:byte())
    end)
    return "![](" .. normalized .. ")"
end

local function absolute_path(path)
    if path == "" then
        return path
    end

    if IS_WINDOWS then
        local wide_path = utf8_to_wide(path)
        if not wide_path then
            return path
        end

        local capacity = 32768 -- Win32 extended-path limit.
        local buffer = ffi.new("wchar_t[?]", capacity)
        local length = kernel32.GetFullPathNameW(wide_path, capacity, buffer, nil)
        if length == 0 or length >= capacity then
            return path
        end
        return wide_to_utf8(buffer)
    end

    if path:sub(1, 1) == "/" then
        return path
    end

    local buffer = ffi.new("char[?]", 4096)
    if ffi.C.getcwd(buffer, 4096) == nil then
        return path
    end

    return ffi.string(buffer) .. "/" .. path
end

local function format_clip_path(path, mode)
    local absolute = absolute_path(path)
    if mode == "md" then
        return escape_markdown_target(absolute)
    end

    return absolute
end

--------------------------------------------------------------------------------
-- Checksums
--------------------------------------------------------------------------------

local CRC_TABLE = ffi.new("uint32_t[256]")
for index = 0, 255 do
    local value = index
    for _ = 1, 8 do
        if bit.band(value, 1) ~= 0 then
            value = bit.bxor(0xEDB88320, bit.rshift(value, 1))
        else
            value = bit.rshift(value, 1)
        end
    end
    CRC_TABLE[index] = value
end

local function crc32_lua(pointer, length)
    local bytes = ffi.cast("const uint8_t*", pointer)
    local crc = -1
    for index = 0, length - 1 do
        local entry = bit.band(bit.bxor(crc, bytes[index]), 0xFF)
        crc = bit.bxor(CRC_TABLE[entry], bit.rshift(crc, 8))
    end
    return to_unsigned(bit.bxor(crc, -1))
end

local function adler32_lua(pointer, length)
    local bytes = ffi.cast("const uint8_t*", pointer)
    local first = 1
    local second = 0
    local index = 0
    while index < length do
        -- 5552 is the largest block that cannot overflow a 32-bit accumulator.
        local block_end = math.min(index + 5552, length)
        while index < block_end do
            first = first + bytes[index]
            second = second + first
            index = index + 1
        end
        first = first % 65521
        second = second % 65521
    end
    return second * 65536 + first
end

local function crc32_memory(pointer, length)
    if zlib then
        return tonumber(zlib.crc32(0, ffi.cast("const Bytef*", pointer), length)) % 4294967296
    end
    return crc32_lua(pointer, length)
end

local function adler32_memory(pointer, length)
    if zlib then
        return tonumber(zlib.adler32(1, ffi.cast("const Bytef*", pointer), length))
    end
    return adler32_lua(pointer, length)
end

--------------------------------------------------------------------------------
-- PNG Encoder
--------------------------------------------------------------------------------

local function build_scanlines(width, height, pixels)
    local source_stride = width * 4
    local row_size = 1 + width * 3
    local raw = ffi.new("uint8_t[?]", row_size * height)
    local position = 0

    for row = 0, height - 1 do
        local source = row * source_stride
        raw[position] = 0 -- PNG filter type 0 (None)
        position = position + 1
        for _ = 0, width - 1 do
            raw[position] = pixels[source + 2]
            raw[position + 1] = pixels[source + 1]
            raw[position + 2] = pixels[source]
            position = position + 3
            source = source + 4
        end
    end

    return raw
end

local function wrap_stored_deflate(raw, raw_size)
    local block_count = math.max(1, math.ceil(raw_size / DEFLATE_BLOCK_MAX))
    local size = 2 + 4 + raw_size + block_count * 5
    local output = ffi.new("uint8_t[?]", size)

    output[0] = 0x78
    output[1] = 0x01

    local source_offset = 0
    local destination = 2
    for block = 1, block_count do
        local length = math.min(DEFLATE_BLOCK_MAX, raw_size - source_offset)
        local is_final = (block == block_count) and 1 or 0
        local complement = bit.band(bit.bnot(length), 0xFFFF)

        output[destination] = is_final
        output[destination + 1] = bit.band(length, 0xFF)
        output[destination + 2] = bit.band(bit.rshift(length, 8), 0xFF)
        output[destination + 3] = bit.band(complement, 0xFF)
        output[destination + 4] = bit.band(bit.rshift(complement, 8), 0xFF)
        ffi.copy(output + destination + 5, raw + source_offset, length)

        source_offset = source_offset + length
        destination = destination + 5 + length
    end

    local checksum = adler32_memory(raw, raw_size)
    output[destination] = math.floor(checksum / 16777216) % 256
    output[destination + 1] = math.floor(checksum / 65536) % 256
    output[destination + 2] = math.floor(checksum / 256) % 256
    output[destination + 3] = checksum % 256

    return output, size
end

local function compress_with_zlib(raw, raw_size)
    local bound = tonumber(zlib.compressBound(raw_size))
    local output = ffi.new("uint8_t[?]", bound)
    local output_size = ffi.new("uLongf[1]", bound)

    local code = zlib.compress2(output, output_size, raw, raw_size, 6)
    if code ~= 0 then
        return nil, string.format("zlib compress2 failed with code %d", code)
    end

    return output, tonumber(output_size[0])
end

local function write_chunk(png, offset, chunk_type, data, data_length)
    write_u32_be(png, offset, data_length)
    ffi.copy(png + offset + 4, chunk_type, 4)
    if data_length > 0 then
        ffi.copy(png + offset + 8, data, data_length)
    end

    -- The CRC covers the chunk type and its data, which are adjacent in the buffer.
    local checksum = crc32_memory(png + offset + 4, data_length + 4)
    write_u32_be(png, offset + 8 + data_length, checksum)

    return offset + 12 + data_length
end

local function encode_png(image, allow_compression)
    local raw = build_scanlines(image.width, image.height, image.pixels)
    local raw_size = ffi.sizeof(raw)

    local idat, idat_size, compressed
    if allow_compression and zlib then
        local compressed_idat, compressed_idat_size = compress_with_zlib(raw, raw_size)
        if not compressed_idat then
            return nil, compressed_idat_size
        end
        idat, idat_size, compressed = compressed_idat, compressed_idat_size, true
    else
        idat, idat_size = wrap_stored_deflate(raw, raw_size)
        compressed = false
    end

    local header = ffi.new("uint8_t[13]")
    write_u32_be(header, 0, image.width)
    write_u32_be(header, 4, image.height)
    header[8] = 8  -- bit depth
    header[9] = 2  -- color type 2: truecolor RGB
    header[10] = 0 -- compression method
    header[11] = 0 -- filter method
    header[12] = 0 -- no interlace

    local total = 8 + (12 + 13) + (12 + idat_size) + 12
    local png = ffi.new("uint8_t[?]", total)
    ffi.copy(png, PNG_SIGNATURE, 8)

    local offset = write_chunk(png, 8, "IHDR", header, 13)
    offset = write_chunk(png, offset, "IDAT", idat, idat_size)
    offset = write_chunk(png, offset, "IEND", nil, 0)
    assert(offset == total, "PNG size accounting mismatch")

    return png, total, compressed
end

local function inspect_png(png, size)
    local info = { chunks = {} }

    for index = 1, 8 do
        if png[index - 1] ~= PNG_SIGNATURE:byte(index) then
            return nil, "PNG signature mismatch"
        end
    end

    local offset = 8
    local idat_parts = {}
    local idat_size = 0
    local saw_end = false

    while offset + 12 <= size do
        local length = read_u32_be(png, offset)
        if offset + 12 + length > size then
            return nil, string.format("chunk at offset %d overruns the file", offset)
        end

        local chunk_type = ffi.string(png + offset + 4, 4)
        local data_offset = offset + 8
        local stored_crc = read_u32_be(png, data_offset + length)
        local computed_crc = crc32_memory(png + offset + 4, length + 4)

        table.insert(info.chunks, {
            type = chunk_type,
            length = length,
            crc_ok = (stored_crc == computed_crc),
        })

        if chunk_type == "IHDR" then
            if length ~= 13 then
                return nil, "IHDR length is not 13"
            end
            info.width = read_u32_be(png, data_offset)
            info.height = read_u32_be(png, data_offset + 4)
            info.depth = png[data_offset + 8]
            info.color_type = png[data_offset + 9]
        elseif chunk_type == "IDAT" then
            table.insert(idat_parts, { offset = data_offset, length = length })
            idat_size = idat_size + length
        elseif chunk_type == "IEND" then
            saw_end = true
            break
        end

        offset = data_offset + length + 4
    end

    if not info.width then
        return nil, "missing IHDR chunk"
    end
    if not saw_end then
        return nil, "missing IEND chunk"
    end

    local idat = ffi.new("uint8_t[?]", math.max(idat_size, 1))
    local position = 0
    for _, part in ipairs(idat_parts) do
        ffi.copy(idat + position, png + part.offset, part.length)
        position = position + part.length
    end

    info.idat = idat
    info.idat_size = idat_size
    return info
end

local function inflate_stored(compressed, compressed_size, expected_size)
    local bytes = ffi.cast("const uint8_t*", compressed)
    if compressed_size < 6 or bytes[0] ~= 0x78 then
        return nil, "missing zlib header"
    end
    if (bytes[0] * 256 + bytes[1]) % 31 ~= 0 then
        return nil, "invalid zlib header check bits"
    end

    local raw = ffi.new("uint8_t[?]", expected_size)
    local source = 2
    local destination = 0

    while true do
        if source >= compressed_size then
            return nil, "truncated deflate stream"
        end

        local header = bytes[source]
        local is_final = bit.band(header, 1)
        local block_type = bit.band(bit.rshift(header, 1), 3)
        source = source + 1

        if block_type ~= 0 then
            return nil, string.format("deflate block type %d is not stored", block_type)
        end

        local length = bytes[source] + bytes[source + 1] * 256
        local complement = bytes[source + 2] + bytes[source + 3] * 256
        source = source + 4

        if bit.band(bit.bxor(length, complement), 0xFFFF) ~= 0xFFFF then
            return nil, "stored block length check failed"
        end
        if destination + length > expected_size then
            return nil, "stored block overruns the expected image size"
        end
        if source + length > compressed_size then
            return nil, "stored block overruns the compressed data"
        end

        ffi.copy(raw + destination, compressed + source, length)
        source = source + length
        destination = destination + length

        if is_final == 1 then
            break
        end
    end

    if destination ~= expected_size then
        return nil, string.format("stored stream produced %d bytes, expected %d",
            destination, expected_size)
    end

    local stored_checksum = read_u32_be(bytes, source)
    local computed_checksum = adler32_memory(raw, expected_size)
    if stored_checksum ~= computed_checksum then
        return nil, string.format("adler32 mismatch: stored %d, computed %d",
            stored_checksum, computed_checksum)
    end

    return raw
end

local function inflate_with_zlib(compressed, compressed_size, expected_size)
    if not zlib then
        return nil, "zlib is not available"
    end

    local raw = ffi.new("uint8_t[?]", expected_size)
    local raw_size = ffi.new("uLongf[1]", expected_size)
    local code = zlib.uncompress(raw, raw_size, compressed, compressed_size)
    if code ~= 0 then
        return nil, string.format("zlib uncompress failed with code %d", code)
    end
    if tonumber(raw_size[0]) ~= expected_size then
        return nil, string.format("zlib produced %d bytes, expected %d",
            tonumber(raw_size[0]), expected_size)
    end

    return raw
end

local function decode_scanlines(raw, width, height)
    local row_size = 1 + width * 3
    local pixels = {}

    for row = 0, height - 1 do
        local base = row * row_size
        if raw[base] ~= 0 then
            return nil, string.format("row %d uses filter %d, expected 0", row, raw[base])
        end
        for column = 0, width - 1 do
            local offset = base + 1 + column * 3
            table.insert(pixels, { r = raw[offset], g = raw[offset + 1], b = raw[offset + 2] })
        end
    end

    return pixels
end

--------------------------------------------------------------------------------
-- Windows Capture
--------------------------------------------------------------------------------

local function win_error_message(code)
    code = code or tonumber(kernel32.GetLastError())
    local buffer = ffi.new("wchar_t[512]")
    local length = kernel32.FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM, nil, code, 0,
        buffer, 512, nil)
    if length > 0 then
        local text = wide_to_utf8(buffer)
        text = text:gsub("[\r\n]+$", "")
        text = text:gsub("%s+$", "")
        if text ~= "" then
            return string.format("Win32 error %d: %s", code, text)
        end
    end
    return string.format("Win32 error %d", code)
end

local function read_dib_pixels(hdc, bitmap, width, height)
    local info = ffi.new("BITMAPINFO")
    info.bmiHeader.biSize = ffi.sizeof("BITMAPINFOHEADER")
    info.bmiHeader.biWidth = width
    info.bmiHeader.biHeight = -height -- negative: top-down rows
    info.bmiHeader.biPlanes = 1
    info.bmiHeader.biBitCount = 32
    info.bmiHeader.biCompression = BI_RGB
    info.bmiHeader.biSizeImage = width * height * 4

    local pixels = ffi.new("uint8_t[?]", width * height * 4)
    local rows = gdi32.GetDIBits(hdc, bitmap, 0, height, pixels, info, DIB_RGB_COLORS)
    if rows ~= height then
        return nil, string.format("GetDIBits returned %d of %d scanlines: %s",
            rows, height, win_error_message())
    end

    return pixels
end

local function win_screen_bounds()
    local x = user32.GetSystemMetrics(SM_XVIRTUALSCREEN)
    local y = user32.GetSystemMetrics(SM_YVIRTUALSCREEN)
    local width = user32.GetSystemMetrics(SM_CXVIRTUALSCREEN)
    local height = user32.GetSystemMetrics(SM_CYVIRTUALSCREEN)

    if width <= 0 or height <= 0 then
        return nil, "Windows reports no desktop surface (is this an interactive session?)"
    end

    return { x = x, y = y, width = width, height = height }
end

local function win_capture_rect(x, y, width, height)
    local screen_dc = user32.GetDC(nil)
    if screen_dc == nil then
        return nil, "GetDC(NULL) failed: " .. win_error_message()
    end

    local memory_dc = gdi32.CreateCompatibleDC(screen_dc)
    if memory_dc == nil then
        user32.ReleaseDC(nil, screen_dc)
        return nil, "CreateCompatibleDC failed: " .. win_error_message()
    end

    local bitmap = gdi32.CreateCompatibleBitmap(screen_dc, width, height)
    if bitmap == nil then
        gdi32.DeleteDC(memory_dc)
        user32.ReleaseDC(nil, screen_dc)
        return nil, string.format("CreateCompatibleBitmap(%dx%d) failed: %s",
            width, height, win_error_message())
    end

    local previous = gdi32.SelectObject(memory_dc, bitmap)
    local blitted = gdi32.BitBlt(memory_dc, 0, 0, width, height, screen_dc, x, y, SRCCOPY)
    local blit_error = (blitted == 0) and win_error_message() or nil
    gdi32.SelectObject(memory_dc, previous)

    local pixels, pixel_error
    if blitted ~= 0 then
        pixels, pixel_error = read_dib_pixels(screen_dc, bitmap, width, height)
    end

    gdi32.DeleteObject(bitmap)
    gdi32.DeleteDC(memory_dc)
    user32.ReleaseDC(nil, screen_dc)

    if blitted == 0 then
        return nil, string.format("BitBlt of %dx%d at %d,%d failed: %s",
            width, height, x, y, blit_error)
    end
    if not pixels then
        return nil, pixel_error
    end

    return {
        width = width,
        height = height,
        pixels = pixels,
        x = x,
        y = y,
        source = "screen",
    }
end

local function win_window_process_name(hwnd)
    local process_id = ffi.new("DWORD[1]")
    user32.GetWindowThreadProcessId(hwnd, process_id)
    if process_id[0] == 0 then
        return "?"
    end

    local handle = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, process_id[0])
    if handle == nil then
        return "?"
    end

    local buffer = ffi.new("char[1024]")
    local size = ffi.new("DWORD[1]", 1024)
    local name = "?"
    if kernel32.QueryFullProcessImageNameA(handle, 0, buffer, size) ~= 0 then
        local path = ffi.string(buffer)
        name = path:match("([^\\/]+)$") or path
    end
    kernel32.CloseHandle(handle)

    return name
end

local function win_list_windows()
    local windows = {}

    local callback = ffi.cast("WNDENUMPROC", function(hwnd, _)
        if user32.IsWindowVisible(hwnd) == 0 then
            return 1
        end

        local title_length = user32.GetWindowTextLengthW(hwnd)
        if title_length <= 0 then
            return 1
        end

        local title_buffer = ffi.new("wchar_t[?]", title_length + 1)
        user32.GetWindowTextW(hwnd, title_buffer, title_length + 1)
        local title = wide_to_utf8(title_buffer)
        if title == "" then
            return 1
        end

        local bounds = ffi.new("RECT")
        user32.GetWindowRect(hwnd, bounds)

        table.insert(windows, {
            handle = hwnd,
            id = string.format("0x%X", tonumber(ffi.cast("uintptr_t", hwnd))),
            title = title,
            process = win_window_process_name(hwnd),
            width = tonumber(bounds.right - bounds.left),
            height = tonumber(bounds.bottom - bounds.top),
        })

        return 1
    end)

    local enumerated = user32.EnumWindows(callback, 0)
    if enumerated == 0 and #windows == 0 then
        return nil, "EnumWindows failed: " .. win_error_message()
    end

    return windows
end

local function win_capture_window(window)
    if user32.IsIconic(window.handle) ~= 0 then
        return nil, string.format("window %q is minimized; restore it before capturing",
            window.title)
    end

    local bounds = ffi.new("RECT")
    local have_bounds = false
    if dwmapi then
        have_bounds = dwmapi.DwmGetWindowAttribute(window.handle,
            DWMWA_EXTENDED_FRAME_BOUNDS, bounds, ffi.sizeof("RECT")) == 0
    end
    if not have_bounds then
        if user32.GetWindowRect(window.handle, bounds) == 0 then
            return nil, string.format("GetWindowRect failed for %q: %s",
                window.title, win_error_message())
        end
    end

    local x = tonumber(bounds.left)
    local y = tonumber(bounds.top)
    local width = tonumber(bounds.right - bounds.left)
    local height = tonumber(bounds.bottom - bounds.top)
    if width <= 0 or height <= 0 then
        return nil, string.format("window %q has an empty frame (%dx%d); it may be hidden",
            window.title, width, height)
    end

    local screen_dc = user32.GetDC(nil)
    if screen_dc == nil then
        return nil, "GetDC(NULL) failed: " .. win_error_message()
    end

    local memory_dc = gdi32.CreateCompatibleDC(screen_dc)
    if memory_dc == nil then
        user32.ReleaseDC(nil, screen_dc)
        return nil, "CreateCompatibleDC failed: " .. win_error_message()
    end

    local bitmap = gdi32.CreateCompatibleBitmap(screen_dc, width, height)
    if bitmap == nil then
        gdi32.DeleteDC(memory_dc)
        user32.ReleaseDC(nil, screen_dc)
        return nil, string.format("CreateCompatibleBitmap(%dx%d) failed: %s",
            width, height, win_error_message())
    end

    local previous = gdi32.SelectObject(memory_dc, bitmap)
    local warnings = {}
    local rendered = user32.PrintWindow(window.handle, memory_dc, PW_RENDERFULLCONTENT)

    if rendered == 0 then
        local last_error = tonumber(kernel32.GetLastError())
        local reason = (last_error ~= 0) and win_error_message(last_error)
            or "PrintWindow returned 0 without an error code"
        local blitted = gdi32.BitBlt(memory_dc, 0, 0, width, height, screen_dc, x, y, SRCCOPY)
        if blitted == 0 then
            gdi32.SelectObject(memory_dc, previous)
            gdi32.DeleteObject(bitmap)
            gdi32.DeleteDC(memory_dc)
            user32.ReleaseDC(nil, screen_dc)
            return nil, string.format("PrintWindow failed for %q (%s) and the screen fallback failed: %s",
                window.title, reason, win_error_message())
        end
        table.insert(warnings, string.format(
            "PrintWindow failed for %q (%s); captured on-screen pixels instead, "
            .. "which may include overlapping windows", window.title, reason))
    end

    gdi32.SelectObject(memory_dc, previous)
    local pixels, pixel_error = read_dib_pixels(screen_dc, bitmap, width, height)

    gdi32.DeleteObject(bitmap)
    gdi32.DeleteDC(memory_dc)
    user32.ReleaseDC(nil, screen_dc)

    if not pixels then
        return nil, pixel_error
    end

    return {
        width = width,
        height = height,
        pixels = pixels,
        x = x,
        y = y,
        source = "window",
        warnings = warnings,
    }
end

-- Build the same window record win_capture_window() consumes, but for whatever
-- window currently owns the foreground. Capture itself resolves the frame and
-- handles minimized or unrenderable windows with its usual diagnostics.
local function win_active_window()
    local handle = user32.GetForegroundWindow()
    if handle == nil then
        return nil, "no foreground window: the desktop or a secure screen has focus"
    end

    local title_length = user32.GetWindowTextLengthW(handle)
    local title_buffer = ffi.new("wchar_t[?]", title_length + 1)
    if title_length > 0 then
        user32.GetWindowTextW(handle, title_buffer, title_length + 1)
    end

    local title = wide_to_utf8(title_buffer)
    if title == "" then
        title = "(untitled window)"
    end

    return {
        handle = handle,
        id = string.format("0x%X", tonumber(ffi.cast("uintptr_t", handle))),
        title = title,
        process = win_window_process_name(handle),
        width = 0,
        height = 0,
    }
end

--------------------------------------------------------------------------------
-- Windows Region Selector
--------------------------------------------------------------------------------

-- Module-level anchor for the active WNDPROC callback. RegisterClassW stores
-- only a raw pointer, and LuaJIT may collect a callback cdata once its local
-- is no longer referenced, which would panic on the next delivered message.
local active_window_proc

local function win_select_region()
    local bounds, bounds_error = win_screen_bounds()
    if not bounds then
        return nil, bounds_error
    end

    local frozen, capture_error = win_capture_rect(bounds.x, bounds.y,
        bounds.width, bounds.height)
    if not frozen then
        return nil, capture_error
    end

    local width = bounds.width
    local height = bounds.height

    local screen_dc = user32.GetDC(nil)
    if screen_dc == nil then
        return nil, "GetDC(NULL) failed: " .. win_error_message()
    end

    local frozen_bitmap, frozen_dc, previous_frozen
    local back_bitmap, back_dc, previous_back
    local dim_bitmap, dim_dc
    local border_pen, handle_brush, handle_frame_brush, label_brush, hint_brush
    local font, owns_font

    local function release_gdi()
        if back_dc ~= nil and previous_back ~= nil then
            gdi32.SelectObject(back_dc, previous_back)
        end
        if back_dc ~= nil then
            gdi32.DeleteDC(back_dc)
        end
        if back_bitmap ~= nil then
            gdi32.DeleteObject(back_bitmap)
        end
        if frozen_dc ~= nil and previous_frozen ~= nil then
            gdi32.SelectObject(frozen_dc, previous_frozen)
        end
        if dim_dc ~= nil then
            gdi32.DeleteDC(dim_dc)
        end
        if dim_bitmap ~= nil then
            gdi32.DeleteObject(dim_bitmap)
        end
        if frozen_dc ~= nil then
            gdi32.DeleteDC(frozen_dc)
        end
        if frozen_bitmap ~= nil then
            gdi32.DeleteObject(frozen_bitmap)
        end
        if border_pen ~= nil then
            gdi32.DeleteObject(border_pen)
        end
        if handle_brush ~= nil then
            gdi32.DeleteObject(handle_brush)
        end
        if handle_frame_brush ~= nil then
            gdi32.DeleteObject(handle_frame_brush)
        end
        if label_brush ~= nil then
            gdi32.DeleteObject(label_brush)
        end
        if hint_brush ~= nil then
            gdi32.DeleteObject(hint_brush)
        end
        if owns_font and font ~= nil then
            gdi32.DeleteObject(font)
        end
        user32.ReleaseDC(nil, screen_dc)
    end

    local section_info = ffi.new("BITMAPINFO")
    section_info.bmiHeader.biSize = ffi.sizeof("BITMAPINFOHEADER")
    section_info.bmiHeader.biWidth = width
    section_info.bmiHeader.biHeight = -height
    section_info.bmiHeader.biPlanes = 1
    section_info.bmiHeader.biBitCount = 32
    section_info.bmiHeader.biCompression = BI_RGB

    local section_bits = ffi.new("void*[1]")
    frozen_bitmap = gdi32.CreateDIBSection(screen_dc, section_info, DIB_RGB_COLORS,
        section_bits, nil, 0)
    if frozen_bitmap == nil then
        local reason = win_error_message()
        release_gdi()
        return nil, "cannot create the frozen-frame bitmap: " .. reason
    end
    ffi.copy(section_bits[0], frozen.pixels, width * height * 4)

    frozen_dc = gdi32.CreateCompatibleDC(screen_dc)
    if frozen_dc == nil then
        local reason = win_error_message()
        release_gdi()
        return nil, "CreateCompatibleDC failed for the frozen frame: " .. reason
    end
    previous_frozen = gdi32.SelectObject(frozen_dc, frozen_bitmap)

    -- Offscreen frame buffer: every repaint composes a complete frame here and
    -- then presents it with a single BitBlt, so dragging never shows a partial
    -- dim/selection state.
    back_bitmap = gdi32.CreateDIBSection(screen_dc, section_info, DIB_RGB_COLORS,
        ffi.new("void*[1]"), nil, 0)
    if back_bitmap == nil then
        local reason = win_error_message()
        release_gdi()
        return nil, "cannot create the offscreen frame buffer: " .. reason
    end
    back_dc = gdi32.CreateCompatibleDC(screen_dc)
    if back_dc == nil then
        local reason = win_error_message()
        release_gdi()
        return nil, "CreateCompatibleDC failed for the frame buffer: " .. reason
    end
    previous_back = gdi32.SelectObject(back_dc, back_bitmap)

    local dim_info = ffi.new("BITMAPINFO")
    dim_info.bmiHeader.biSize = ffi.sizeof("BITMAPINFOHEADER")
    dim_info.bmiHeader.biWidth = 1
    dim_info.bmiHeader.biHeight = -1
    dim_info.bmiHeader.biPlanes = 1
    dim_info.bmiHeader.biBitCount = 32
    dim_info.bmiHeader.biCompression = BI_RGB

    local dim_bits = ffi.new("void*[1]")
    dim_bitmap = gdi32.CreateDIBSection(screen_dc, dim_info, DIB_RGB_COLORS,
        dim_bits, nil, 0)
    if dim_bitmap ~= nil then
        local dim_pixel = ffi.cast("uint8_t*", dim_bits[0])
        dim_pixel[0] = 0 -- blue
        dim_pixel[1] = 0 -- green
        dim_pixel[2] = 0 -- red
        dim_pixel[3] = 110

        dim_dc = gdi32.CreateCompatibleDC(screen_dc)
        if dim_dc ~= nil then
            gdi32.SelectObject(dim_dc, dim_bitmap)
        end
    end

    local dpi = tonumber(gdi32.GetDeviceCaps(screen_dc, LOGPIXELSY))
    if dpi <= 0 then
        dpi = 96
    end
    local scale = dpi / 96

    local font_face = utf8_to_wide("Segoe UI")
    font = gdi32.CreateFontW(-math.max(12, math.floor(15 * scale)), 0, 0, 0, 400,
        0, 0, 0, 1, 0, 0, 4, 0, font_face)
    if font ~= nil then
        owns_font = true
    else
        font = gdi32.GetStockObject(DEFAULT_GUI_FONT)
    end

    border_pen = gdi32.CreatePen(0, math.max(1, math.floor(2 * scale)), 0x0000A0FF)
    handle_brush = gdi32.CreateSolidBrush(0x00FFFFFF)
    handle_frame_brush = gdi32.CreateSolidBrush(0x00000000)
    label_brush = gdi32.CreateSolidBrush(0x00141414)
    hint_brush = gdi32.CreateSolidBrush(0x001C1C1C)

    local handle_size = math.max(4, math.floor(6 * scale))
    local hint_height = math.max(24, math.floor(30 * scale))
    local cross_cursor = user32.LoadCursorW(nil, ffi.cast("const wchar_t*", IDC_CROSS))

    local state = {
        width = width,
        height = height,
        dragging = false,
        anchor_x = 0,
        anchor_y = 0,
        cursor_x = 0,
        cursor_y = 0,
        selection = nil,
        cancel_reason = nil,
        destroyed = false,
    }

    local function mouse_point(lparam)
        local packed = tonumber(lparam) or 0
        local x = bit.band(packed, 0xFFFF)
        local y = bit.band(bit.rshift(packed, 16), 0xFFFF)
        if x >= 32768 then
            x = x - 65536
        end
        if y >= 32768 then
            y = y - 65536
        end
        x = math.max(0, math.min(width - 1, x))
        y = math.max(0, math.min(height - 1, y))
        return x, y
    end

    local function draw_handles(dc, rectangle)
        local positions = {
            { rectangle.x, rectangle.y },
            { rectangle.x + rectangle.width - handle_size, rectangle.y },
            { rectangle.x, rectangle.y + rectangle.height - handle_size },
            { rectangle.x + rectangle.width - handle_size,
              rectangle.y + rectangle.height - handle_size },
        }

        for _, position in ipairs(positions) do
            local handle_rect = ffi.new("RECT")
            handle_rect.left = position[1]
            handle_rect.top = position[2]
            handle_rect.right = position[1] + handle_size
            handle_rect.bottom = position[2] + handle_size
            user32.FillRect(dc, handle_rect, handle_brush)
            user32.FrameRect(dc, handle_rect, handle_frame_brush)
        end
    end

    local function compose()
        local dc = back_dc
        gdi32.BitBlt(dc, 0, 0, width, height, frozen_dc, 0, 0, SRCCOPY)

        local rectangle
        if state.dragging then
            rectangle = normalize_selection(state.anchor_x, state.anchor_y,
                state.cursor_x, state.cursor_y)
        elseif state.selection then
            rectangle = state.selection
        end

        if rectangle then
            if msimg32 and dim_dc then
                local blend = ffi.new("BLENDFUNCTION")
                blend.BlendOp = 0
                blend.BlendFlags = 0
                blend.SourceConstantAlpha = 255
                blend.AlphaFormat = 1
                msimg32.AlphaBlend(dc, 0, 0, width, height, dim_dc, 0, 0, 1, 1, blend)
            end

            -- Keep the selected area at full brightness.
            gdi32.BitBlt(dc, rectangle.x, rectangle.y, rectangle.width, rectangle.height,
                frozen_dc, rectangle.x, rectangle.y, SRCCOPY)

            local old_pen = gdi32.SelectObject(dc, border_pen)
            local old_brush = gdi32.SelectObject(dc, gdi32.GetStockObject(NULL_BRUSH))
            gdi32.Rectangle(dc, rectangle.x, rectangle.y,
                rectangle.x + rectangle.width, rectangle.y + rectangle.height)
            gdi32.SelectObject(dc, old_pen)
            gdi32.SelectObject(dc, old_brush)

            draw_handles(dc, rectangle)

            local label = utf8_to_wide(string.format("%d x %d",
                rectangle.width, rectangle.height))
            local measure = ffi.new("RECT")
            user32.DrawTextW(dc, label, -1, measure,
                bit.bor(DT_CALCRECT, DT_SINGLELINE, DT_LEFT))

            local text_width = measure.right - measure.left
            local text_height = measure.bottom - measure.top
            local padding = math.max(4, math.floor(6 * scale))
            local label_left = rectangle.x
            local label_top = rectangle.y - text_height - padding * 2 - 2
            if label_top < hint_height then
                label_top = rectangle.y + 2
            end
            if label_left + text_width + padding * 2 > width then
                label_left = width - text_width - padding * 2
            end
            if label_left < 0 then
                label_left = 0
            end

            local label_rect = ffi.new("RECT")
            label_rect.left = label_left
            label_rect.top = label_top
            label_rect.right = label_left + text_width + padding * 2
            label_rect.bottom = label_top + text_height + padding * 2
            user32.FillRect(dc, label_rect, label_brush)

            gdi32.SetBkMode(dc, 1) -- TRANSPARENT
            gdi32.SetTextColor(dc, 0x00FFFFFF)
            gdi32.SelectObject(dc, font)
            local text_rect = ffi.new("RECT")
            text_rect.left = label_rect.left + padding
            text_rect.top = label_rect.top + padding
            text_rect.right = label_rect.right - padding
            text_rect.bottom = label_rect.bottom - padding
            user32.DrawTextW(dc, label, -1, text_rect,
                bit.bor(DT_LEFT, DT_SINGLELINE, DT_VCENTER))
        end

        local hint_rect = ffi.new("RECT")
        hint_rect.left = 0
        hint_rect.top = 0
        hint_rect.right = width
        hint_rect.bottom = hint_height
        user32.FillRect(dc, hint_rect, hint_brush)

        gdi32.SetBkMode(dc, 1)
        gdi32.SetTextColor(dc, 0x00FFFFFF)
        gdi32.SelectObject(dc, font)
        local hint = utf8_to_wide(
            "Left-drag to select      Esc or right-click to cancel")
        user32.DrawTextW(dc, hint, -1, hint_rect,
            bit.bor(DT_CENTER, DT_VCENTER, DT_SINGLELINE))
    end

    local function paint(hwnd)
        local paint_struct = ffi.new("PAINTSTRUCT")
        local dc = user32.BeginPaint(hwnd, paint_struct)
        compose()
        gdi32.BitBlt(dc, 0, 0, width, height, back_dc, 0, 0, SRCCOPY)
        user32.EndPaint(hwnd, paint_struct)
    end

    local function handle_message(hwnd, message, wparam, lparam)
        if message == WM_PAINT then
            paint(hwnd)
            return 0
        elseif message == WM_ERASEBKGND then
            return 1
        elseif message == WM_SETCURSOR then
            if cross_cursor ~= nil then
                user32.SetCursor(cross_cursor)
            end
            return 1
        elseif message == WM_LBUTTONDOWN then
            state.dragging = true
            state.anchor_x, state.anchor_y = mouse_point(lparam)
            state.cursor_x, state.cursor_y = state.anchor_x, state.anchor_y
            user32.SetCapture(hwnd)
            user32.InvalidateRect(hwnd, nil, 0)
            return 0
        elseif message == WM_MOUSEMOVE then
            if state.dragging then
                local next_x, next_y = mouse_point(lparam)
                if next_x ~= state.cursor_x or next_y ~= state.cursor_y then
                    state.cursor_x, state.cursor_y = next_x, next_y
                    user32.InvalidateRect(hwnd, nil, 0)
                end
            end
            return 0
        elseif message == WM_LBUTTONUP then
            if state.dragging then
                state.dragging = false
                user32.ReleaseCapture()
                state.cursor_x, state.cursor_y = mouse_point(lparam)

                local rectangle = normalize_selection(state.anchor_x, state.anchor_y,
                    state.cursor_x, state.cursor_y)
                if rectangle.width >= 2 and rectangle.height >= 2 then
                    state.selection = rectangle
                else
                    state.cancel_reason = string.format(
                        "selection is too small (%dx%d); drag at least 2x2 pixels",
                        rectangle.width, rectangle.height)
                end

                user32.DestroyWindow(hwnd)
            end
            return 0
        elseif message == WM_RBUTTONUP then
            state.cancel_reason = "selection cancelled"
            user32.DestroyWindow(hwnd)
            return 0
        elseif message == WM_KEYDOWN then
            if tonumber(wparam) == VK_ESCAPE then
                state.cancel_reason = "selection cancelled"
                user32.DestroyWindow(hwnd)
                return 0
            end
        elseif message == WM_DESTROY then
            state.destroyed = true
            user32.PostQuitMessage(0)
            return 0
        end

        return user32.DefWindowProcW(hwnd, message, wparam, lparam)
    end

    local function wnd_proc(hwnd, message, wparam, lparam)
        local ok, result = pcall(handle_message, hwnd, message, wparam, lparam)
        if ok then
            return result
        end

        -- Never let a Lua error escape a Win32 callback: report it through the
        -- normal cancellation path so the user sees why the selection ended.
        state.cancel_reason = "selector error: " .. tostring(result)
        if not state.destroyed then
            user32.DestroyWindow(hwnd)
        end
        return 0
    end

    local class_name = utf8_to_wide("FShotRegionSelect")
    local window_title = utf8_to_wide("fshot region select")
    local wnd_proc_pointer = ffi.cast("WNDPROC", wnd_proc)
    active_window_proc = wnd_proc_pointer

    local window_class = ffi.new("WNDCLASSW")
    window_class.style = 0x0003 -- CS_HREDRAW | CS_VREDRAW
    window_class.lpfnWndProc = wnd_proc_pointer
    window_class.hCursor = cross_cursor
    window_class.hbrBackground = hint_brush
    window_class.lpszClassName = class_name

    local atom = user32.RegisterClassW(window_class)
    if atom == 0 then
        local code = tonumber(kernel32.GetLastError())
        if code ~= ERROR_CLASS_ALREADY_EXISTS then
            release_gdi()
            return nil, "RegisterClassW failed: " .. win_error_message(code)
        end
    end

    local hwnd = user32.CreateWindowExW(
        bit.bor(WS_EX_TOPMOST, WS_EX_TOOLWINDOW, WS_EX_LAYERED),
        class_name, window_title, WS_POPUP, bounds.x, bounds.y, width, height,
        nil, nil, nil, nil)
    if hwnd == nil then
        local reason = win_error_message()
        release_gdi()
        return nil, "CreateWindowExW failed: " .. reason
    end

    -- Start fully transparent: paint the complete first frame while hidden from
    -- the compositor, then reveal it in one step. Without this, the window shows
    -- an unpainted surface for a frame before WM_PAINT runs.
    local layered = user32.SetLayeredWindowAttributes(hwnd, 0, 0, LWA_ALPHA) ~= 0

    user32.ShowWindow(hwnd, SW_SHOW)
    pcall(function()
        user32.SetForegroundWindow(hwnd)
    end)

    -- Force the first composed frame while the window is still transparent.
    user32.InvalidateRect(hwnd, nil, 0)
    user32.UpdateWindow(hwnd)

    if layered then
        user32.SetLayeredWindowAttributes(hwnd, 0, 255, LWA_ALPHA)
    end

    local loop_error = nil
    local message = ffi.new("MSG")
    while true do
        local result = user32.GetMessageW(message, nil, 0, 0)
        if result == 0 then
            break
        end
        if result == -1 then
            loop_error = "window message loop failed: " .. win_error_message()
            break
        end
        user32.TranslateMessage(message)
        user32.DispatchMessageW(message)
    end

    if not state.destroyed then
        user32.DestroyWindow(hwnd)
    end

    local selection = state.selection
    local cancel_reason = state.cancel_reason
    release_gdi()

    if not selection then
        return nil, loop_error or cancel_reason or "selection cancelled"
    end

    return {
        width = selection.width,
        height = selection.height,
        pixels = crop_bgra(frozen.pixels, width, selection),
        x = bounds.x + selection.x,
        y = bounds.y + selection.y,
        source = "select",
    }
end

--------------------------------------------------------------------------------
-- Windows Annotation Editor
--------------------------------------------------------------------------------

-- Clipboard and output helpers live with the command-line code below; the
-- forward declarations keep them visible to the editor's nested closures.
local win_copy_to_clipboard, resolve_output_path, write_binary_file, copy_saved_path

local EDITOR_PALETTE = {
    { name = "red", hex = "#E53935" },
    { name = "orange", hex = "#FB8C00" },
    { name = "yellow", hex = "#FDD835" },
    { name = "green", hex = "#43A047" },
    { name = "blue", hex = "#1E88E5" },
    { name = "black", hex = "#000000" },
}

local EDITOR_WIDTHS = { 2, 4, 6, 8, 12 }

-- Grouped so the editor's nested window procedures stay well under LuaJIT's
-- 60-upvalue limit; each message/key constant would otherwise cost one each.
local EDITOR_KEYS = {
    WM_PAINT = WM_PAINT,
    WM_ERASEBKGND = WM_ERASEBKGND,
    WM_SIZE = WM_SIZE,
    WM_SETCURSOR = WM_SETCURSOR,
    WM_LBUTTONDOWN = WM_LBUTTONDOWN,
    WM_MOUSEMOVE = WM_MOUSEMOVE,
    WM_LBUTTONUP = WM_LBUTTONUP,
    WM_RBUTTONUP = WM_RBUTTONUP,
    WM_KEYDOWN = WM_KEYDOWN,
    WM_CLOSE = WM_CLOSE,
    WM_DESTROY = WM_DESTROY,
    VK_ESCAPE = VK_ESCAPE,
    VK_RETURN = VK_RETURN,
    VK_CONTROL = VK_CONTROL,
    VK_1 = VK_1,
    VK_6 = VK_6,
    VK_R = VK_R,
    VK_C = VK_C,
    VK_S = VK_S,
    VK_Y = VK_Y,
    VK_Z = VK_Z,
    VK_OEM_4 = VK_OEM_4,
    VK_OEM_6 = VK_OEM_6,
    VK_ADD = VK_ADD,
    VK_SUBTRACT = VK_SUBTRACT,
    DT_LEFT = DT_LEFT,
    DT_CENTER = DT_CENTER,
    DT_VCENTER = DT_VCENTER,
    DT_SINGLELINE = DT_SINGLELINE,
    DT_END_ELLIPSIS = DT_END_ELLIPSIS,
}

local COLOR_NAMES = {
    red = "#E53935",
    orange = "#FB8C00",
    yellow = "#FDD835",
    green = "#43A047",
    blue = "#1E88E5",
    black = "#000000",
    white = "#FFFFFF",
}

-- Parse "#RRGGBB" or a palette name into a Win32 COLORREF (0x00BBGGRR).
local function parse_color(text)
    if not text or text == "" then
        return nil, "--color requires #RRGGBB or a color name"
    end

    local value = COLOR_NAMES[text:lower()] or text
    local red, green, blue = value:match("^#(%x%x)(%x%x)(%x%x)$")
    if not red then
        return nil, string.format(
            "invalid color %q: use #RRGGBB or one of red, orange, yellow, green, blue, black, white",
            text)
    end

    return tonumber(red, 16) + tonumber(green, 16) * 256 + tonumber(blue, 16) * 65536
end

local function color_to_hex(color)
    local red = color % 256
    local green = math.floor(color / 256) % 256
    local blue = math.floor(color / 65536) % 256
    return string.format("#%02X%02X%02X", red, green, blue)
end

for _, entry in ipairs(EDITOR_PALETTE) do
    entry.colorref = parse_color(entry.hex)
end

-- Largest scale that fits the image without ever upscaling past 1:1.
local function fit_scale(image_width, image_height, available_width, available_height)
    if image_width <= 0 or image_height <= 0
        or available_width <= 0 or available_height <= 0 then
        return 1
    end

    return math.min(1, available_width / image_width, available_height / image_height)
end

local function win_edit_image(image, options)
    if not IS_WINDOWS then
        return nil, "the annotation editor is only implemented on Windows"
    end

    local image_width = image.width
    local image_height = image.height
    local color_index = 1
    local width_index = 2
    for index, entry in ipairs(EDITOR_PALETTE) do
        if entry.colorref == options.editor_color then
            color_index = index
            break
        end
    end
    for index, width in ipairs(EDITOR_WIDTHS) do
        if width == options.editor_width then
            width_index = index
            break
        end
    end

    local screen_dc = user32.GetDC(nil)
    if screen_dc == nil then
        return nil, "GetDC(NULL) failed: " .. win_error_message()
    end

    local dpi = tonumber(gdi32.GetDeviceCaps(screen_dc, LOGPIXELSY))
    if dpi <= 0 then
        dpi = 96
    end
    local ui = dpi / 96
    local toolbar_height = math.max(34, math.floor(38 * ui))
    local status_height = math.max(22, math.floor(26 * ui))

    local image_bitmap, image_dc, previous_image
    local font, owns_font
    local background_brush, toolbar_brush, status_brush, button_brush, active_brush
    local ring_brush, image_border_brush
    local swatch_brushes = {}

    local function release_resources()
        if image_dc ~= nil and previous_image ~= nil then
            gdi32.SelectObject(image_dc, previous_image)
        end
        if image_dc ~= nil then
            gdi32.DeleteDC(image_dc)
        end
        if image_bitmap ~= nil then
            gdi32.DeleteObject(image_bitmap)
        end
        for _, brush in ipairs(swatch_brushes) do
            gdi32.DeleteObject(brush)
        end
        if background_brush ~= nil then
            gdi32.DeleteObject(background_brush)
        end
        if toolbar_brush ~= nil then
            gdi32.DeleteObject(toolbar_brush)
        end
        if status_brush ~= nil then
            gdi32.DeleteObject(status_brush)
        end
        if button_brush ~= nil then
            gdi32.DeleteObject(button_brush)
        end
        if active_brush ~= nil then
            gdi32.DeleteObject(active_brush)
        end
        if ring_brush ~= nil then
            gdi32.DeleteObject(ring_brush)
        end
        if image_border_brush ~= nil then
            gdi32.DeleteObject(image_border_brush)
        end
        if owns_font and font ~= nil then
            gdi32.DeleteObject(font)
        end
        user32.ReleaseDC(nil, screen_dc)
    end

    local image_info = ffi.new("BITMAPINFO")
    image_info.bmiHeader.biSize = ffi.sizeof("BITMAPINFOHEADER")
    image_info.bmiHeader.biWidth = image_width
    image_info.bmiHeader.biHeight = -image_height
    image_info.bmiHeader.biPlanes = 1
    image_info.bmiHeader.biBitCount = 32
    image_info.bmiHeader.biCompression = BI_RGB

    local image_bits = ffi.new("void*[1]")
    image_bitmap = gdi32.CreateDIBSection(screen_dc, image_info, DIB_RGB_COLORS,
        image_bits, nil, 0)
    if image_bitmap == nil then
        local reason = win_error_message()
        release_resources()
        return nil, "cannot create the editor bitmap: " .. reason
    end
    ffi.copy(image_bits[0], image.pixels, image_width * image_height * 4)

    image_dc = gdi32.CreateCompatibleDC(screen_dc)
    if image_dc == nil then
        local reason = win_error_message()
        release_resources()
        return nil, "CreateCompatibleDC failed for the editor image: " .. reason
    end
    previous_image = gdi32.SelectObject(image_dc, image_bitmap)

    local font_face = utf8_to_wide("Segoe UI")
    font = gdi32.CreateFontW(-math.max(12, math.floor(15 * ui)), 0, 0, 0, 400,
        0, 0, 0, 1, 0, 0, 4, 0, font_face)
    if font ~= nil then
        owns_font = true
    else
        font = gdi32.GetStockObject(DEFAULT_GUI_FONT)
    end

    background_brush = gdi32.CreateSolidBrush(0x00202020)
    toolbar_brush = gdi32.CreateSolidBrush(0x00342F2F)
    status_brush = gdi32.CreateSolidBrush(0x002A2525)
    button_brush = gdi32.CreateSolidBrush(0x004A4343)
    active_brush = gdi32.CreateSolidBrush(0x006E5A5A)
    ring_brush = gdi32.CreateSolidBrush(0x00FFFFFF)
    image_border_brush = gdi32.CreateSolidBrush(0x00787878)
    for index, entry in ipairs(EDITOR_PALETTE) do
        swatch_brushes[index] = gdi32.CreateSolidBrush(entry.colorref)
    end

    -- Place the editor on the monitor that owned the capture.
    local monitor_rect = ffi.new("RECT")
    monitor_rect.left = image.x or 0
    monitor_rect.top = image.y or 0
    monitor_rect.right = monitor_rect.left + image_width
    monitor_rect.bottom = monitor_rect.top + image_height

    local monitor_info = ffi.new("MONITORINFO")
    monitor_info.cbSize = ffi.sizeof("MONITORINFO")
    local monitor = user32.MonitorFromRect(monitor_rect, MONITOR_DEFAULTTONEAREST)

    local work = {
        x = 0,
        y = 0,
        width = user32.GetSystemMetrics(0),
        height = user32.GetSystemMetrics(1),
    }
    if monitor ~= nil and user32.GetMonitorInfoW(monitor, monitor_info) ~= 0 then
        work.x = monitor_info.rcWork.left
        work.y = monitor_info.rcWork.top
        work.width = monitor_info.rcWork.right - monitor_info.rcWork.left
        work.height = monitor_info.rcWork.bottom - monitor_info.rcWork.top
    end

    local margin_x = math.floor(24 * ui)
    local margin_y = math.floor(20 * ui)

    -- Reserve room for the title bar and borders so the fitted window stays
    -- inside the work area instead of hanging off the bottom edge.
    local frame_rect = ffi.new("RECT")
    frame_rect.left = 0
    frame_rect.top = 0
    frame_rect.right = 1000
    frame_rect.bottom = 1000
    user32.AdjustWindowRect(frame_rect, WS_OVERLAPPEDWINDOW, 0)
    local frame_width = frame_rect.right - frame_rect.left - 1000
    local frame_height = frame_rect.bottom - frame_rect.top - 1000

    local available_width = math.max(1, work.width - 2 * margin_x - frame_width)
    local available_height = math.max(1,
        work.height - toolbar_height - status_height - 2 * margin_y - frame_height)

    local initial_scale = fit_scale(image_width, image_height,
        available_width, available_height)
    local initial_display_width = math.max(1, math.floor(image_width * initial_scale + 0.5))
    local initial_display_height = math.max(1, math.floor(image_height * initial_scale + 0.5))
    local initial_client_width = math.max(initial_display_width + 2 * margin_x,
        math.floor(660 * ui))
    local initial_client_height = toolbar_height + initial_display_height + status_height
        + 2 * margin_y

    local window_rect = ffi.new("RECT")
    window_rect.left = 0
    window_rect.top = 0
    window_rect.right = initial_client_width
    window_rect.bottom = initial_client_height
    user32.AdjustWindowRect(window_rect, WS_OVERLAPPEDWINDOW, 0)
    local window_width = window_rect.right - window_rect.left
    local window_height = window_rect.bottom - window_rect.top
    local window_x = work.x + math.floor((work.width - window_width) / 2)
    local window_y = work.y + math.floor((work.height - window_height) / 2)
    window_x = math.max(work.x, math.min(window_x, work.x + work.width - window_width))
    window_y = math.max(work.y, math.min(window_y, work.y + work.height - window_height))

    local state = {
        client_width = initial_client_width,
        client_height = initial_client_height,
        scale = initial_scale,
        display_width = initial_display_width,
        display_height = initial_display_height,
        ox = 0,
        oy = 0,
        annotations = {},
        undo_stack = {},
        redo_stack = {},
        buttons = {},
        dragging = false,
        start_x = 0,
        start_y = 0,
        current_x = 0,
        current_y = 0,
        last_x = 0,
        last_y = 0,
        color_index = color_index,
        color = options.editor_color,
        width_index = width_index,
        width_px = options.editor_width,
        discard_armed = false,
        status = string.format(
            "Rect  %s  %d px   |   drag to draw   |   Ctrl+Z undo   |   Enter save+copy   |   Esc discard",
            color_to_hex(options.editor_color), options.editor_width),
        status_is_error = false,
        result = nil,
        fatal = nil,
        destroyed = false,
        back_bitmap = nil,
        back_dc = nil,
        previous_back = nil,
    }

    local hwnd

    local function set_status(text, is_error)
        state.status = tostring(text):gsub("%s+", " ")
        state.status_is_error = is_error or false
        if hwnd ~= nil and not state.destroyed then
            user32.InvalidateRect(hwnd, nil, 0)
        end
    end

    local function copy_annotations()
        local copied = {}
        for index, annotation in ipairs(state.annotations) do
            copied[index] = {
                x = annotation.x,
                y = annotation.y,
                width = annotation.width,
                height = annotation.height,
                color = annotation.color,
                line_width = annotation.line_width,
            }
        end
        return copied
    end

    local function undo()
        if #state.undo_stack == 0 then
            set_status("Nothing to undo")
            return
        end
        table.insert(state.redo_stack, copy_annotations())
        state.annotations = table.remove(state.undo_stack)
        set_status(string.format("Undo  (%d shape%s)", #state.annotations,
            #state.annotations == 1 and "" or "s"))
    end

    local function redo()
        if #state.redo_stack == 0 then
            set_status("Nothing to redo")
            return
        end
        table.insert(state.undo_stack, copy_annotations())
        state.annotations = table.remove(state.redo_stack)
        set_status(string.format("Redo  (%d shape%s)", #state.annotations,
            #state.annotations == 1 and "" or "s"))
    end

    local function adjust_width(delta)
        state.width_index = math.max(1, math.min(#EDITOR_WIDTHS,
            state.width_index + delta))
        state.width_px = EDITOR_WIDTHS[state.width_index]
        set_status(string.format("Line width  %d px", state.width_px))
    end

    local function to_rect(rectangle)
        local rect = ffi.new("RECT")
        rect.left = rectangle.left
        rect.top = rectangle.top
        rect.right = rectangle.right
        rect.bottom = rectangle.bottom
        return rect
    end

    local function draw_text(dc, text, rect, color, format)
        gdi32.SetBkMode(dc, 1) -- TRANSPARENT
        gdi32.SetTextColor(dc, color)
        gdi32.SelectObject(dc, font)
        user32.DrawTextW(dc, utf8_to_wide(text), -1, rect, format)
    end

    local function draw_annotation(dc, annotation, origin_x, origin_y, scale)
        local left = origin_x + annotation.x * scale
        local top = origin_y + annotation.y * scale
        local right = origin_x + (annotation.x + annotation.width) * scale
        local bottom = origin_y + (annotation.y + annotation.height) * scale
        local pen_width = math.max(1, math.floor(annotation.line_width * scale + 0.5))

        local pen = gdi32.CreatePen(0, pen_width, annotation.color)
        if pen == nil then
            return
        end
        local old_pen = gdi32.SelectObject(dc, pen)
        local old_brush = gdi32.SelectObject(dc, gdi32.GetStockObject(NULL_BRUSH))
        gdi32.Rectangle(dc, math.floor(left + 0.5), math.floor(top + 0.5),
            math.floor(right + 0.5), math.floor(bottom + 0.5))
        gdi32.SelectObject(dc, old_pen)
        gdi32.SelectObject(dc, old_brush)
        gdi32.DeleteObject(pen)
    end

    local function update_layout()
        local client_width = math.max(1, state.client_width)
        local client_height = math.max(1, state.client_height)
        local area_top = toolbar_height
        local area_height = math.max(1, client_height - toolbar_height - status_height)

        state.scale = fit_scale(image_width, image_height,
            math.max(1, client_width - 2 * margin_x),
            math.max(1, area_height - 2 * margin_y))
        state.display_width = math.max(1, math.floor(image_width * state.scale + 0.5))
        state.display_height = math.max(1, math.floor(image_height * state.scale + 0.5))
        state.ox = math.floor((client_width - state.display_width) / 2)
        state.oy = area_top + math.floor((area_height - state.display_height) / 2)

        state.buttons = {}
        local cursor_x = math.floor(10 * ui)
        local cursor_y = math.floor(7 * ui)
        local button_height = math.max(18, toolbar_height - 2 * cursor_y)

        local function push_button(id, label, width)
            table.insert(state.buttons, {
                id = id,
                label = label,
                rect = {
                    left = cursor_x,
                    top = cursor_y,
                    right = cursor_x + width,
                    bottom = cursor_y + button_height,
                },
            })
            cursor_x = cursor_x + width + math.floor(6 * ui)
        end

        push_button("tool_rect", "Rect", math.floor(58 * ui))

        local swatch_size = math.max(12, button_height - math.floor(6 * ui))
        local swatch_pad = math.floor(3 * ui)
        for index = 1, #EDITOR_PALETTE do
            table.insert(state.buttons, {
                id = "color",
                index = index,
                rect = {
                    left = cursor_x,
                    top = cursor_y + swatch_pad,
                    right = cursor_x + swatch_size,
                    bottom = cursor_y + swatch_pad + swatch_size,
                },
            })
            cursor_x = cursor_x + swatch_size + math.floor(5 * ui)
        end

        cursor_x = cursor_x + math.floor(8 * ui)
        push_button("width_down", "-", math.floor(26 * ui))
        push_button("width_up", "+", math.floor(26 * ui))
        push_button("undo", "Undo", math.floor(54 * ui))
        push_button("copy", "Copy", math.floor(54 * ui))
        push_button("save", "Save", math.floor(54 * ui))
    end

    local function release_back_buffer()
        if state.back_dc ~= nil and state.previous_back ~= nil then
            gdi32.SelectObject(state.back_dc, state.previous_back)
        end
        if state.back_dc ~= nil then
            gdi32.DeleteDC(state.back_dc)
            state.back_dc = nil
        end
        if state.back_bitmap ~= nil then
            gdi32.DeleteObject(state.back_bitmap)
            state.back_bitmap = nil
        end
    end

    local function create_back_buffer()
        release_back_buffer()
        local width = math.max(1, state.client_width)
        local height = math.max(1, state.client_height)

        local back_info = ffi.new("BITMAPINFO")
        back_info.bmiHeader.biSize = ffi.sizeof("BITMAPINFOHEADER")
        back_info.bmiHeader.biWidth = width
        back_info.bmiHeader.biHeight = -height
        back_info.bmiHeader.biPlanes = 1
        back_info.bmiHeader.biBitCount = 32
        back_info.bmiHeader.biCompression = BI_RGB

        state.back_bitmap = gdi32.CreateDIBSection(screen_dc, back_info,
            DIB_RGB_COLORS, ffi.new("void*[1]"), nil, 0)
        if state.back_bitmap == nil then
            state.fatal = "cannot create the editor frame buffer: " .. win_error_message()
            return false
        end

        state.back_dc = gdi32.CreateCompatibleDC(screen_dc)
        if state.back_dc == nil then
            state.fatal = "CreateCompatibleDC failed for the editor frame buffer: "
                .. win_error_message()
            return false
        end
        state.previous_back = gdi32.SelectObject(state.back_dc, state.back_bitmap)
        return true
    end

    local function draw_swatch_ring(dc, button)
        local rect = to_rect(button.rect)
        user32.FrameRect(dc, rect, ring_brush)
    end

    local function draw_toolbar(dc)
        local bar = ffi.new("RECT")
        bar.left = 0
        bar.top = 0
        bar.right = state.client_width
        bar.bottom = toolbar_height
        user32.FillRect(dc, bar, toolbar_brush)

        for _, button in ipairs(state.buttons) do
            local rect = to_rect(button.rect)
            if button.id == "color" then
                user32.FillRect(dc, rect, swatch_brushes[button.index])
                if button.index == state.color_index then
                    draw_swatch_ring(dc, button)
                end
            else
                local active = button.id == "tool_rect"
                user32.FillRect(dc, rect, active and active_brush or button_brush)
                draw_text(dc, button.label, rect,
                    active and 0x00FFFFFF or 0x00D8D8D8,
                    bit.bor(EDITOR_KEYS.DT_CENTER, EDITOR_KEYS.DT_VCENTER,
                        EDITOR_KEYS.DT_SINGLELINE))
            end
        end
    end

    local function draw_status(dc)
        local bar = ffi.new("RECT")
        bar.left = 0
        bar.top = state.client_height - status_height
        bar.right = state.client_width
        bar.bottom = state.client_height
        user32.FillRect(dc, bar, status_brush)

        local text_rect = ffi.new("RECT")
        text_rect.left = math.floor(10 * ui)
        text_rect.top = bar.top
        text_rect.right = state.client_width - math.floor(10 * ui)
        text_rect.bottom = bar.bottom
        draw_text(dc, state.status, text_rect,
            state.status_is_error and 0x008080FF or 0x00E2E2E2,
            bit.bor(EDITOR_KEYS.DT_LEFT, EDITOR_KEYS.DT_VCENTER,
                EDITOR_KEYS.DT_SINGLELINE, EDITOR_KEYS.DT_END_ELLIPSIS))
    end

    local function compose()
        local dc = state.back_dc
        if dc == nil then
            return
        end

        local full = ffi.new("RECT")
        full.left = 0
        full.top = 0
        full.right = state.client_width
        full.bottom = state.client_height
        user32.FillRect(dc, full, background_brush)

        gdi32.SetStretchBltMode(dc, COLORONCOLOR)
        if state.scale >= 0.999 then
            gdi32.BitBlt(dc, state.ox, state.oy, state.display_width, state.display_height,
                image_dc, 0, 0, SRCCOPY)
        else
            gdi32.StretchBlt(dc, state.ox, state.oy, state.display_width,
                state.display_height, image_dc, 0, 0, image_width, image_height, SRCCOPY)
        end

        local image_rect = ffi.new("RECT")
        image_rect.left = state.ox
        image_rect.top = state.oy
        image_rect.right = state.ox + state.display_width
        image_rect.bottom = state.oy + state.display_height
        user32.FrameRect(dc, image_rect, image_border_brush)

        for _, annotation in ipairs(state.annotations) do
            draw_annotation(dc, annotation, state.ox, state.oy, state.scale)
        end

        if state.dragging then
            local rectangle = normalize_selection(state.start_x, state.start_y,
                state.current_x, state.current_y)
            draw_annotation(dc, {
                x = rectangle.x,
                y = rectangle.y,
                width = rectangle.width,
                height = rectangle.height,
                color = state.color,
                line_width = state.width_px,
            }, state.ox, state.oy, state.scale)
        end

        draw_toolbar(dc)
        draw_status(dc)
    end

    local function paint(paint_hwnd)
        local paint_struct = ffi.new("PAINTSTRUCT")
        local dc = user32.BeginPaint(paint_hwnd, paint_struct)
        if state.back_dc ~= nil then
            compose()
            gdi32.BitBlt(dc, 0, 0, state.client_width, state.client_height,
                state.back_dc, 0, 0, SRCCOPY)
        end
        user32.EndPaint(paint_hwnd, paint_struct)
    end

    local function flatten_image()
        local flat_info = ffi.new("BITMAPINFO")
        flat_info.bmiHeader.biSize = ffi.sizeof("BITMAPINFOHEADER")
        flat_info.bmiHeader.biWidth = image_width
        flat_info.bmiHeader.biHeight = -image_height
        flat_info.bmiHeader.biPlanes = 1
        flat_info.bmiHeader.biBitCount = 32
        flat_info.bmiHeader.biCompression = BI_RGB

        local flat_bits = ffi.new("void*[1]")
        local flat_bitmap = gdi32.CreateDIBSection(screen_dc, flat_info, DIB_RGB_COLORS,
            flat_bits, nil, 0)
        if flat_bitmap == nil then
            return nil, "cannot create the flattened image: " .. win_error_message()
        end
        ffi.copy(flat_bits[0], image.pixels, image_width * image_height * 4)

        local flat_dc = gdi32.CreateCompatibleDC(screen_dc)
        if flat_dc == nil then
            local reason = win_error_message()
            gdi32.DeleteObject(flat_bitmap)
            return nil, "CreateCompatibleDC failed for the flattened image: " .. reason
        end
        local previous = gdi32.SelectObject(flat_dc, flat_bitmap)

        for _, annotation in ipairs(state.annotations) do
            draw_annotation(flat_dc, annotation, 0, 0, 1)
        end

        gdi32.SelectObject(flat_dc, previous)
        local pixels = ffi.new("uint8_t[?]", image_width * image_height * 4)
        local rows = gdi32.GetDIBits(flat_dc, flat_bitmap, 0, image_height, pixels,
            flat_info, DIB_RGB_COLORS)
        gdi32.DeleteDC(flat_dc)
        gdi32.DeleteObject(flat_bitmap)

        if rows ~= image_height then
            return nil, string.format("GetDIBits returned %d of %d rows", rows, image_height)
        end
        return pixels
    end

    local function encode_annotated()
        local pixels, flatten_error = flatten_image()
        if not pixels then
            return nil, flatten_error
        end

        local png, size_or_error, compressed = encode_png({
            width = image_width,
            height = image_height,
            pixels = pixels,
        }, options.compress)
        if not png then
            return nil, "PNG encoding failed: " .. tostring(size_or_error)
        end

        return png, size_or_error, compressed, pixels
    end

    local function copy_current()
        local png, png_size, _compressed, pixels = encode_annotated()
        if not png then
            set_status(png_size, true)
            return false
        end

        local copied, clipboard_error, warnings = win_copy_to_clipboard({
            width = image_width,
            height = image_height,
            pixels = pixels,
        }, png, png_size)
        if not copied then
            io.stderr:write("fshot: " .. tostring(clipboard_error) .. "\n")
            set_status(clipboard_error, true)
            return false
        end

        for _, warning in ipairs(warnings or {}) do
            io.stderr:write("fshot: warning: " .. warning .. "\n")
        end
        set_status(string.format("Copied %dx%d to clipboard", image_width, image_height))
        return true
    end

    local function accept()
        local started = now_ms()
        local png, png_size, compressed, pixels = encode_annotated()
        if not png then
            set_status(png_size, true)
            return
        end

        local result = nil
        local output_path = nil
        if options.write_file then
            local path_error
            output_path, path_error = resolve_output_path(options.output, options)
            if not output_path then
                io.stderr:write("fshot: " .. path_error .. "\n")
                set_status(path_error, true)
                return
            end

            local written, write_error = write_binary_file(output_path, png, png_size)
            if not written then
                io.stderr:write("fshot: " .. write_error .. "\n")
                set_status(write_error, true)
                return
            end
            result = {
                path = output_path,
                copied = false,
                path_copied = false,
                bytes = png_size,
                compressed = compressed,
                elapsed_ms = 0,
            }
        end

        local copied = false
        if options.clipboard then
            local clipboard_ok, clipboard_error, warnings = win_copy_to_clipboard({
                width = image_width,
                height = image_height,
                pixels = pixels,
            }, png, png_size)
            if not clipboard_ok then
                io.stderr:write("fshot: " .. tostring(clipboard_error) .. "\n")
                if result then
                    -- The file is already on disk; keep the editor open so the
                    -- user can retry, and close with a successful file result.
                    result.elapsed_ms = now_ms() - started
                    state.result = result
                    set_status(
                        "Clipboard failed; the file was saved. Esc closes the editor.",
                        true)
                else
                    set_status(clipboard_error, true)
                end
                return
            end

            for _, warning in ipairs(warnings or {}) do
                io.stderr:write("fshot: warning: " .. warning .. "\n")
            end
            copied = true
        end

        local path_copied = false
        if options.clip_path then
            local copied_path, path_copy_error = copy_saved_path(output_path, options.clip_path)
            if not copied_path then
                io.stderr:write("fshot: " .. tostring(path_copy_error) .. "\n")
                if result then
                    result.elapsed_ms = now_ms() - started
                    state.result = result
                    set_status("Path copy failed; the file was saved. Esc closes the editor.",
                        true)
                else
                    set_status(path_copy_error, true)
                end
                return
            end
            path_copied = true
        end

        if result == nil then
            result = {
                path = nil,
                copied = false,
                path_copied = false,
                bytes = png_size,
                compressed = compressed,
                elapsed_ms = 0,
            }
        end
        result.copied = copied
        result.path_copied = path_copied
        result.elapsed_ms = now_ms() - started
        state.result = result
        user32.DestroyWindow(hwnd)
    end

    local function request_close()
        if #state.annotations > 0 and not state.discard_armed then
            state.discard_armed = true
            set_status(string.format(
                "Press Esc again to discard %d annotation%s without saving",
                #state.annotations, #state.annotations == 1 and "" or "s"))
            return
        end
        user32.DestroyWindow(hwnd)
    end

    local function handle_toolbar_click(x, y)
        for _, button in ipairs(state.buttons) do
            local rect = button.rect
            if x >= rect.left and x < rect.right and y >= rect.top and y < rect.bottom then
                state.discard_armed = false
                if button.id == "color" then
                    state.color_index = button.index
                    state.color = EDITOR_PALETTE[button.index].colorref
                    set_status(string.format("Color  %s", EDITOR_PALETTE[button.index].hex))
                elseif button.id == "width_down" then
                    adjust_width(-1)
                elseif button.id == "width_up" then
                    adjust_width(1)
                elseif button.id == "undo" then
                    undo()
                elseif button.id == "copy" then
                    copy_current()
                elseif button.id == "save" then
                    accept()
                end
                return true
            end
        end
        return false
    end

    local function mouse_x(lparam)
        local packed = tonumber(lparam) or 0
        local value = bit.band(packed, 0xFFFF)
        if value >= 32768 then
            value = value - 65536
        end
        return value
    end

    local function mouse_y(lparam)
        local packed = tonumber(lparam) or 0
        local value = bit.band(bit.rshift(packed, 16), 0xFFFF)
        if value >= 32768 then
            value = value - 65536
        end
        return value
    end

    local function client_to_image(x, y)
        local image_x = (x - state.ox) / state.scale
        local image_y = (y - state.oy) / state.scale
        image_x = math.max(0, math.min(image_width, image_x))
        image_y = math.max(0, math.min(image_height, image_y))
        return image_x, image_y
    end

    local function over_image(x, y)
        return x >= state.ox and x < state.ox + state.display_width
            and y >= state.oy and y < state.oy + state.display_height
    end

    -- Load the cursors before the window procedure that references them;
    -- a later local would resolve to a nil global inside the closure and hide
    -- the pointer with SetCursor(NULL).
    local cross_cursor = user32.LoadCursorW(nil, ffi.cast("const wchar_t*", IDC_CROSS))
    local arrow_cursor = user32.LoadCursorW(nil, ffi.cast("const wchar_t*", IDC_ARROW))

    local function handle_message(message_hwnd, message, wparam, lparam)
        if message == EDITOR_KEYS.WM_PAINT then
            paint(message_hwnd)
            return 0
        elseif message == EDITOR_KEYS.WM_ERASEBKGND then
            return 1
        elseif message == EDITOR_KEYS.WM_SIZE then
            local client_rect = ffi.new("RECT")
            if user32.GetClientRect(message_hwnd, client_rect) ~= 0 then
                state.client_width = math.max(1, client_rect.right - client_rect.left)
                state.client_height = math.max(1, client_rect.bottom - client_rect.top)
                create_back_buffer()
                update_layout()
                user32.InvalidateRect(message_hwnd, nil, 0)
            end
            return 0
        elseif message == EDITOR_KEYS.WM_SETCURSOR then
            local cursor = over_image(state.last_x, state.last_y)
            user32.SetCursor(cursor and cross_cursor or arrow_cursor)
            return 1
        elseif message == EDITOR_KEYS.WM_LBUTTONDOWN then
            local x = mouse_x(lparam)
            local y = mouse_y(lparam)
            state.last_x, state.last_y = x, y
            if y < toolbar_height then
                handle_toolbar_click(x, y)
                return 0
            end
            if y >= state.client_height - status_height then
                return 0
            end
            if not over_image(x, y) then
                return 0
            end

            state.discard_armed = false
            state.dragging = true
            state.start_x, state.start_y = client_to_image(x, y)
            state.current_x, state.current_y = state.start_x, state.start_y
            user32.SetCursor(cross_cursor)
            user32.SetCapture(message_hwnd)
            user32.InvalidateRect(message_hwnd, nil, 0)
            return 0
        elseif message == EDITOR_KEYS.WM_MOUSEMOVE then
            local x = mouse_x(lparam)
            local y = mouse_y(lparam)
            state.last_x, state.last_y = x, y
            if state.dragging then
                user32.SetCursor(cross_cursor)
                local next_x, next_y = client_to_image(x, y)
                if next_x ~= state.current_x or next_y ~= state.current_y then
                    state.current_x, state.current_y = next_x, next_y
                    user32.InvalidateRect(message_hwnd, nil, 0)
                end
            elseif over_image(x, y) then
                user32.SetCursor(cross_cursor)
            else
                user32.SetCursor(arrow_cursor)
            end
            return 0
        elseif message == EDITOR_KEYS.WM_LBUTTONUP then
            if state.dragging then
                state.dragging = false
                user32.ReleaseCapture()
                state.current_x, state.current_y = client_to_image(mouse_x(lparam), mouse_y(lparam))

                local rectangle = normalize_selection(state.start_x, state.start_y,
                    state.current_x, state.current_y)
                if rectangle.width >= 2 and rectangle.height >= 2 then
                    table.insert(state.undo_stack, copy_annotations())
                    state.redo_stack = {}
                    table.insert(state.annotations, {
                        x = rectangle.x,
                        y = rectangle.y,
                        width = rectangle.width,
                        height = rectangle.height,
                        color = state.color,
                        line_width = state.width_px,
                    })
                    set_status(string.format("Rect  %dx%d  %s  %d px",
                        rectangle.width, rectangle.height,
                        color_to_hex(state.color), state.width_px))
                else
                    set_status("Shape too small; drag at least 2x2 image pixels", true)
                end

                user32.InvalidateRect(message_hwnd, nil, 0)
            end
            return 0
        elseif message == EDITOR_KEYS.WM_RBUTTONUP then
            if state.dragging then
                state.dragging = false
                user32.ReleaseCapture()
                set_status("Shape cancelled")
                user32.InvalidateRect(message_hwnd, nil, 0)
            end
            return 0
        elseif message == EDITOR_KEYS.WM_KEYDOWN then
            local key = tonumber(wparam)
            if key == EDITOR_KEYS.VK_ESCAPE then
                if state.dragging then
                    state.dragging = false
                    user32.ReleaseCapture()
                    set_status("Shape cancelled")
                    user32.InvalidateRect(message_hwnd, nil, 0)
                    return 0
                end
                request_close()
                return 0
            end

            state.discard_armed = false
            local control = bit.band(user32.GetKeyState(EDITOR_KEYS.VK_CONTROL), 0x8000) ~= 0

            if key == EDITOR_KEYS.VK_RETURN then
                accept()
            elseif key == EDITOR_KEYS.VK_Z and control then
                undo()
            elseif key == EDITOR_KEYS.VK_Y and control then
                redo()
            elseif key == EDITOR_KEYS.VK_C and not control then
                copy_current()
            elseif key == EDITOR_KEYS.VK_S and control then
                accept()
            elseif key == EDITOR_KEYS.VK_OEM_4 or key == EDITOR_KEYS.VK_SUBTRACT then
                adjust_width(-1)
            elseif key == EDITOR_KEYS.VK_OEM_6 or key == EDITOR_KEYS.VK_ADD then
                adjust_width(1)
            elseif key >= EDITOR_KEYS.VK_1 and key <= EDITOR_KEYS.VK_6 then
                state.color_index = key - EDITOR_KEYS.VK_1 + 1
                state.color = EDITOR_PALETTE[state.color_index].colorref
                set_status(string.format("Color  %s", EDITOR_PALETTE[state.color_index].hex))
            elseif key == EDITOR_KEYS.VK_R then
                set_status("Tool  Rect")
            end

            user32.InvalidateRect(message_hwnd, nil, 0)
            return 0
        elseif message == EDITOR_KEYS.WM_CLOSE then
            request_close()
            return 0
        elseif message == EDITOR_KEYS.WM_DESTROY then
            state.destroyed = true
            user32.PostQuitMessage(0)
            return 0
        end

        return user32.DefWindowProcW(message_hwnd, message, wparam, lparam)
    end

    local function wnd_proc(message_hwnd, message, wparam, lparam)
        local ok, result = pcall(handle_message, message_hwnd, message, wparam, lparam)
        if ok then
            return result
        end

        -- Never let a Lua error escape a Win32 callback. Report it and close so
        -- the caller can print the real reason instead of hanging.
        state.fatal = "editor error: " .. tostring(result)
        if not state.destroyed then
            user32.DestroyWindow(message_hwnd)
        end
        return 0
    end

    local class_name = utf8_to_wide("FShotAnnotationEditor")
    local window_title = utf8_to_wide(string.format("fshot editor - %dx%d",
        image_width, image_height))

    -- Anchor the callback for the whole message loop (see active_window_proc).
    local wnd_proc_pointer = ffi.cast("WNDPROC", wnd_proc)
    active_window_proc = wnd_proc_pointer
    local window_class = ffi.new("WNDCLASSW")
    window_class.style = 0x0003 -- CS_HREDRAW | CS_VREDRAW
    window_class.lpfnWndProc = wnd_proc_pointer
    window_class.hCursor = arrow_cursor
    window_class.hbrBackground = background_brush
    window_class.lpszClassName = class_name

    local atom = user32.RegisterClassW(window_class)
    if atom == 0 then
        local code = tonumber(kernel32.GetLastError())
        if code ~= ERROR_CLASS_ALREADY_EXISTS then
            release_resources()
            return nil, "RegisterClassW failed: " .. win_error_message(code)
        end
    end

    hwnd = user32.CreateWindowExW(
        bit.bor(WS_EX_TOPMOST, WS_EX_TOOLWINDOW, WS_EX_LAYERED),
        class_name, window_title, WS_OVERLAPPEDWINDOW,
        window_x, window_y, window_width, window_height,
        nil, nil, nil, nil)
    if hwnd == nil then
        local reason = win_error_message()
        release_resources()
        return nil, "CreateWindowExW failed: " .. reason
    end

    local client_rect = ffi.new("RECT")
    user32.GetClientRect(hwnd, client_rect)
    state.client_width = math.max(1, client_rect.right - client_rect.left)
    state.client_height = math.max(1, client_rect.bottom - client_rect.top)
    if not create_back_buffer() then
        local reason = state.fatal
        user32.DestroyWindow(hwnd)
        release_resources()
        return nil, reason
    end
    update_layout()

    -- Same reveal discipline as the selector: compose the first frame while the
    -- layered window is fully transparent, then fade it in.
    local layered = user32.SetLayeredWindowAttributes(hwnd, 0, 0, LWA_ALPHA) ~= 0
    user32.ShowWindow(hwnd, SW_SHOW)
    pcall(function()
        user32.SetForegroundWindow(hwnd)
    end)
    user32.InvalidateRect(hwnd, nil, 0)
    user32.UpdateWindow(hwnd)
    if layered then
        user32.SetLayeredWindowAttributes(hwnd, 0, 255, LWA_ALPHA)
    end

    local loop_error = nil
    local message = ffi.new("MSG")
    while true do
        local result = user32.GetMessageW(message, nil, 0, 0)
        if result == 0 then
            break
        end
        if result == -1 then
            loop_error = "window message loop failed: " .. win_error_message()
            break
        end
        user32.TranslateMessage(message)
        user32.DispatchMessageW(message)
    end

    if not state.destroyed then
        user32.DestroyWindow(hwnd)
    end

    release_back_buffer()
    release_resources()

    if state.fatal then
        return nil, state.fatal
    end
    if loop_error then
        return nil, loop_error
    end
    if not state.result then
        return nil, "edit cancelled"
    end

    return state.result
end

--------------------------------------------------------------------------------
-- X11 Capture
--------------------------------------------------------------------------------

local x11_destroy_image
if IS_LINUX and x11 then
    pcall(function()
        x11_destroy_image = x11.XDestroyImage
    end)
end

local function x11_open_display()
    if not x11 then
        return nil, "libX11 could not be loaded; install the X11 client library "
            .. "or capture with an external tool"
    end

    local display = x11.XOpenDisplay(nil)
    if display == nil then
        if os.getenv("WAYLAND_DISPLAY") then
            return nil, "Wayland session detected and no X display is available.\n"
                .. "  Screen capture needs the XDG portal; try "
                .. "'grim -g \"$(slurp)\" out.png' or run under XWayland."
        end
        return nil, "cannot open the X display (is DISPLAY set and X11 running?)"
    end

    return display
end

local function x11_screen_bounds()
    local display, display_error = x11_open_display()
    if not display then
        return nil, display_error
    end

    local root = x11.XDefaultRootWindow(display)
    local root_return = ffi.new("unsigned long[1]")
    local x_return = ffi.new("int[1]")
    local y_return = ffi.new("int[1]")
    local width_return = ffi.new("unsigned int[1]")
    local height_return = ffi.new("unsigned int[1]")
    local border_return = ffi.new("unsigned int[1]")
    local depth_return = ffi.new("unsigned int[1]")

    local ok = x11.XGetGeometry(display, root, root_return, x_return, y_return,
        width_return, height_return, border_return, depth_return)
    x11.XCloseDisplay(display)

    if ok == 0 then
        return nil, "XGetGeometry failed on the root window"
    end

    return {
        x = tonumber(x_return[0]),
        y = tonumber(y_return[0]),
        width = tonumber(width_return[0]),
        height = tonumber(height_return[0]),
    }
end

local function channel_extractor(mask)
    mask = tonumber(mask)
    if mask == 0 then
        return 0, 0
    end

    local shift = 0
    while bit.band(mask, 1) == 0 do
        mask = bit.rshift(mask, 1)
        shift = shift + 1
    end

    return shift, mask
end

local function scale_channel(value, maximum)
    if maximum == 0 then
        return 0
    end
    return math.floor(value * 255 / maximum + 0.5)
end

local function x11_capture_rect(x, y, width, height)
    local display, display_error = x11_open_display()
    if not display then
        return nil, display_error
    end

    if x < 0 or y < 0 then
        x11.XCloseDisplay(display)
        return nil, string.format("X11 cannot capture at a negative origin (%d,%d)", x, y)
    end

    local root = x11.XDefaultRootWindow(display)
    local image = x11.XGetImage(display, root, x, y, width, height,
        ffi.cast("unsigned long", -1), ZPIXMAP)
    if image == nil then
        x11.XCloseDisplay(display)
        return nil, string.format("XGetImage failed for %dx%d at %d,%d "
            .. "(is the region inside the screen?)", width, height, x, y)
    end

    local bits_per_pixel = tonumber(image.bits_per_pixel)
    local bytes_per_line = tonumber(image.bytes_per_line)
    local byte_order = tonumber(image.byte_order)

    if bits_per_pixel ~= 32 and bits_per_pixel ~= 24 then
        if x11_destroy_image then
            x11_destroy_image(image)
        end
        x11.XCloseDisplay(display)
        return nil, string.format("unsupported X11 visual: %d bits per pixel "
            .. "(need 24 or 32); use a 24-bit TrueColor display", bits_per_pixel)
    end

    local pixels = ffi.new("uint8_t[?]", width * height * 4)
    local red_shift, red_max = channel_extractor(image.red_mask)
    local green_shift, green_max = channel_extractor(image.green_mask)
    local blue_shift, blue_max = channel_extractor(image.blue_mask)
    local destination = 0

    if bits_per_pixel == 32 then
        local words = ffi.cast("const uint32_t*", image.data)
        local words_per_line = bytes_per_line / 4
        for row = 0, height - 1 do
            for column = 0, width - 1 do
                local value = tonumber(words[row * words_per_line + column])
                if byte_order ~= LSB_FIRST then
                    value = bit.bswap(value)
                end
                local red = scale_channel(bit.band(bit.rshift(value, red_shift), red_max), red_max)
                local green = scale_channel(bit.band(bit.rshift(value, green_shift), green_max), green_max)
                local blue = scale_channel(bit.band(bit.rshift(value, blue_shift), blue_max), blue_max)
                pixels[destination] = blue
                pixels[destination + 1] = green
                pixels[destination + 2] = red
                pixels[destination + 3] = 255
                destination = destination + 4
            end
        end
    else
        local bytes = ffi.cast("const uint8_t*", image.data)
        for row = 0, height - 1 do
            local line = row * bytes_per_line
            for column = 0, width - 1 do
                local offset = line + column * 3
                local red, green, blue
                if byte_order == LSB_FIRST then
                    blue, green, red = bytes[offset], bytes[offset + 1], bytes[offset + 2]
                else
                    red, green, blue = bytes[offset], bytes[offset + 1], bytes[offset + 2]
                end
                pixels[destination] = blue
                pixels[destination + 1] = green
                pixels[destination + 2] = red
                pixels[destination + 3] = 255
                destination = destination + 4
            end
        end
    end

    -- XDestroyImage is exported by libX11 in practice; if a build hides it, the
    -- one-shot process exit reclaims the image rather than failing the capture.
    if x11_destroy_image then
        x11_destroy_image(image)
    end
    x11.XCloseDisplay(display)

    return {
        width = width,
        height = height,
        pixels = pixels,
        x = x,
        y = y,
        source = "screen",
    }
end

--------------------------------------------------------------------------------
-- Platform Dispatch
--------------------------------------------------------------------------------

local function platform_prepare()
    if not IS_WINDOWS then
        return
    end

    -- DPI awareness must be set before any device context exists, otherwise GDI
    -- captures a scaled, blurry virtual screen.
    local applied = pcall(function()
        return user32.SetProcessDpiAwarenessContext(ffi.cast("void*", -4))
    end)
    if not applied then
        pcall(function()
            return user32.SetProcessDPIAware()
        end)
    end
end

local function platform_screen_bounds()
    if IS_WINDOWS then
        return win_screen_bounds()
    end
    if IS_LINUX then
        return x11_screen_bounds()
    end
    return nil, "capture is only implemented for Windows and Linux"
end

local function platform_capture_rect(x, y, width, height)
    if IS_WINDOWS then
        return win_capture_rect(x, y, width, height)
    end
    if IS_LINUX then
        return x11_capture_rect(x, y, width, height)
    end
    return nil, "capture is only implemented for Windows and Linux"
end

local function platform_list_windows()
    if IS_WINDOWS then
        return win_list_windows()
    end
    return nil, "window listing and window capture are only implemented on Windows; "
        .. "use --region with the window geometry instead"
end

local function platform_capture_window(window)
    if IS_WINDOWS then
        return win_capture_window(window)
    end
    return nil, "window capture is only implemented on Windows; "
        .. "use --region with the window geometry instead"
end

local function platform_active_window()
    if IS_WINDOWS then
        return win_active_window()
    end
    return nil, "--active-window is only implemented on Windows; "
        .. "use --window TEXT or --region X,Y,W,H instead"
end

local function platform_select_region()
    if IS_WINDOWS then
        return win_select_region()
    end
    return nil, "interactive region selection is only implemented on Windows; "
        .. "use --region X,Y,W,H instead"
end

--------------------------------------------------------------------------------
-- Capture Targeting
--------------------------------------------------------------------------------

local function capture_region(x, y, width, height)
    local bounds, bounds_error = platform_screen_bounds()
    if not bounds then
        return nil, bounds_error
    end

    local left = math.max(x, bounds.x)
    local top = math.max(y, bounds.y)
    local right = math.min(x + width, bounds.x + bounds.width)
    local bottom = math.min(y + height, bounds.y + bounds.height)

    if right <= left or bottom <= top then
        return nil, string.format("region %d,%d %dx%d lies outside the screen (%d,%d %dx%d)",
            x, y, width, height, bounds.x, bounds.y, bounds.width, bounds.height)
    end

    local warnings = {}
    if left ~= x or top ~= y or right ~= x + width or bottom ~= y + height then
        table.insert(warnings, string.format(
            "region clamped to %d,%d %dx%d to fit the screen",
            left, top, right - left, bottom - top))
    end

    local image, capture_error = platform_capture_rect(left, top, right - left, bottom - top)
    if not image then
        return nil, capture_error
    end

    image.warnings = warnings
    return image
end

local function describe_window_candidates(windows, limit)
    if #windows == 0 then
        return "No visible top-level windows were found (is this an interactive desktop session?)."
    end

    local lines = { "Visible windows:" }
    for index = 1, math.min(#windows, limit) do
        local window = windows[index]
        table.insert(lines, string.format("  %-24s %s", window.process or "?", window.title))
    end
    if #windows > limit then
        table.insert(lines, string.format("  ... and %d more (run --list-windows)",
            #windows - limit))
    end

    return table.concat(lines, "\n")
end

local function resolve_window(query)
    local windows, list_error = platform_list_windows()
    if not windows then
        return nil, list_error, 0
    end

    local needle = query:lower()
    local matches = {}
    for _, window in ipairs(windows) do
        local title = window.title:lower()
        local process = (window.process or ""):lower()
        local score = nil

        if title == needle then
            score = 100
        elseif title:sub(1, #needle) == needle then
            score = 80
        elseif title:find(needle, 1, true) then
            score = 60
        elseif process == needle then
            score = 50
        elseif process:find(needle, 1, true) then
            score = 40
        end

        if score then
            table.insert(matches, { window = window, score = score })
        end
    end

    if #matches == 0 then
        return nil, string.format("no visible window matches %q.\n%s",
            query, describe_window_candidates(windows, 5)), #windows
    end

    table.sort(matches, function(first, second)
        return first.score > second.score
    end)

    return matches[1].window, nil, #matches
end

--------------------------------------------------------------------------------
-- Clipboard
--------------------------------------------------------------------------------

local function win_global_from_bytes(data, length)
    local memory = kernel32.GlobalAlloc(GMEM_MOVEABLE, length)
    if memory == nil then
        return nil, "GlobalAlloc(" .. length .. " bytes) failed: " .. win_error_message()
    end

    local pointer = kernel32.GlobalLock(memory)
    if pointer == nil then
        kernel32.GlobalFree(memory)
        return nil, "GlobalLock failed: " .. win_error_message()
    end

    ffi.copy(pointer, data, length)
    kernel32.GlobalUnlock(memory)
    return memory
end

-- The clipboard is a single-owner resource; retry briefly when another process
-- holds it, then explain which flag could be dropped instead of failing blind.
local function win_open_clipboard(flag_name)
    for attempt = 1, 5 do
        if user32.OpenClipboard(nil) ~= 0 then
            return true
        end
        sleep_ms(50)
    end

    return nil, "cannot open the clipboard after 5 attempts (" .. win_error_message()
        .. ").\n  Another application is holding it; retry in a moment, "
        .. "or drop " .. flag_name .. " to write a file only."
end

function win_copy_to_clipboard(image, png, png_size)
    local stride = image.width * 4
    local dib_size = ffi.sizeof("BITMAPINFOHEADER") + stride * image.height
    local dib_memory = kernel32.GlobalAlloc(GMEM_MOVEABLE, dib_size)
    if dib_memory == nil then
        return nil, "GlobalAlloc(" .. dib_size .. " bytes for CF_DIB) failed: "
            .. win_error_message()
    end

    local dib_pointer = kernel32.GlobalLock(dib_memory)
    if dib_pointer == nil then
        kernel32.GlobalFree(dib_memory)
        return nil, "GlobalLock failed for CF_DIB: " .. win_error_message()
    end

    local header = ffi.cast("BITMAPINFOHEADER*", dib_pointer)
    header.biSize = ffi.sizeof("BITMAPINFOHEADER")
    header.biWidth = image.width
    header.biHeight = image.height -- positive: bottom-up rows, as CF_DIB requires
    header.biPlanes = 1
    header.biBitCount = 32
    header.biCompression = BI_RGB
    header.biSizeImage = stride * image.height

    local header_size = ffi.sizeof("BITMAPINFOHEADER")
    local source_stride = image.width * 4
    local destination = ffi.cast("uint8_t*", dib_pointer) + header_size
    for row = 0, image.height - 1 do
        local source_row = image.height - 1 - row
        ffi.copy(destination + row * source_stride,
            image.pixels + source_row * source_stride, source_stride)
    end
    kernel32.GlobalUnlock(dib_memory)

    local opened, open_error = win_open_clipboard("--clip")
    if not opened then
        kernel32.GlobalFree(dib_memory)
        return nil, open_error
    end

    local warnings = {}
    if user32.EmptyClipboard() == 0 then
        local reason = win_error_message()
        user32.CloseClipboard()
        kernel32.GlobalFree(dib_memory)
        return nil, "EmptyClipboard failed: " .. reason
    end

    if user32.SetClipboardData(CF_DIB, dib_memory) == nil then
        local reason = win_error_message()
        user32.CloseClipboard()
        kernel32.GlobalFree(dib_memory)
        return nil, "SetClipboardData(CF_DIB) failed: " .. reason
    end

    -- Ownership of dib_memory now belongs to the clipboard; do not free it.
    local png_memory, png_error = win_global_from_bytes(png, png_size)
    if png_memory then
        local png_format = user32.RegisterClipboardFormatW(utf8_to_wide("PNG"))
        if png_format == 0 then
            kernel32.GlobalFree(png_memory)
            table.insert(warnings, "the CF_DIB image was copied, but the PNG clipboard "
                .. "format could not be registered: " .. win_error_message())
        elseif user32.SetClipboardData(png_format, png_memory) == nil then
            kernel32.GlobalFree(png_memory)
            table.insert(warnings, "the CF_DIB image was copied, but the PNG clipboard "
                .. "format was rejected: " .. win_error_message())
        end
    else
        table.insert(warnings, "the CF_DIB image was copied, but preparing the PNG "
            .. "clipboard format failed: " .. png_error)
    end

    user32.CloseClipboard()
    return true, nil, warnings
end

function win_copy_text_to_clipboard(text)
    local wide_text = utf8_to_wide(text)
    if not wide_text then
        return nil, "the text could not be converted to UTF-16"
    end

    -- ffi.sizeof includes the terminating NUL that utf8_to_wide appends.
    local memory, memory_error = win_global_from_bytes(wide_text, ffi.sizeof(wide_text))
    if not memory then
        return nil, memory_error
    end

    local opened, open_error = win_open_clipboard("--clip-path")
    if not opened then
        kernel32.GlobalFree(memory)
        return nil, open_error
    end

    if user32.EmptyClipboard() == 0 then
        local reason = win_error_message()
        user32.CloseClipboard()
        kernel32.GlobalFree(memory)
        return nil, "EmptyClipboard failed: " .. reason
    end

    if user32.SetClipboardData(CF_UNICODETEXT, memory) == nil then
        local reason = win_error_message()
        user32.CloseClipboard()
        kernel32.GlobalFree(memory)
        return nil, "SetClipboardData(CF_UNICODETEXT) failed: " .. reason
    end

    -- Ownership of memory now belongs to the clipboard; do not free it.
    user32.CloseClipboard()
    return true
end

local function execute_command(command)
    local first, second, third = os.execute(command)
    if first == 0 or first == true then
        return true, nil
    end

    local detail
    if type(second) == "string" then
        detail = second
        if third then
            detail = detail .. " (" .. tostring(third) .. ")"
        end
    else
        detail = tostring(first)
    end

    return false, detail
end

local LINUX_CLIPBOARD_TOOLS = {
    {
        name = "wl-copy",
        probe = "command -v wl-copy >/dev/null 2>&1",
        commands = {
            image = "wl-copy --type image/png < %q",
            text = "wl-copy < %q",
        },
    },
    {
        name = "xclip",
        probe = "command -v xclip >/dev/null 2>&1",
        commands = {
            image = "xclip -selection clipboard -t image/png -i %q",
            text = "xclip -selection clipboard < %q",
        },
    },
}

-- Both payload kinds go through a temporary file so the data never has to be
-- escaped into a shell command line.
local function linux_copy_to_clipboard(data, size, kind)
    local temporary_path = os.tmpname()
    local file, open_error = io.open(temporary_path, "wb")
    if not file then
        return nil, "cannot create a temporary file for the clipboard: "
            .. tostring(open_error)
    end
    file:write(ffi.string(data, size))
    file:close()

    for _, tool in ipairs(LINUX_CLIPBOARD_TOOLS) do
        if execute_command(tool.probe) then
            local copied, failure = execute_command(
                string.format(tool.commands[kind], temporary_path))
            os.remove(temporary_path)
            if not copied then
                return nil, string.format("%s failed (%s); install a working clipboard tool "
                    .. "or write a file and copy it manually", tool.name, tostring(failure))
            end
            return true, nil, {}
        end
    end

    os.remove(temporary_path)
    return nil, "no clipboard tool found.\n  Install wl-clipboard (wl-copy) or xclip, "
        .. "or write a file and copy it manually."
end

local function copy_text_to_clipboard(text)
    if IS_WINDOWS then
        return win_copy_text_to_clipboard(text)
    end
    if IS_LINUX then
        return linux_copy_to_clipboard(text, #text, "text")
    end
    return nil, "clipboard copy is only implemented for Windows and Linux"
end

local function platform_copy_clipboard(image, png, png_size)
    if IS_WINDOWS then
        return win_copy_to_clipboard(image, png, png_size)
    end
    if IS_LINUX then
        return linux_copy_to_clipboard(png, png_size, "image")
    end
    return nil, "clipboard copy is only implemented for Windows and Linux"
end

-- Copy the saved file path (or a markdown link to it) as clipboard text.
function copy_saved_path(path, mode)
    if not path or not mode then
        return true
    end

    return copy_text_to_clipboard(format_clip_path(path, mode))
end

--------------------------------------------------------------------------------
-- Command-Line Handling
--------------------------------------------------------------------------------

local DEFAULT_FILENAME_TEMPLATE = "shot-%Y%m%d-%H%M%S"
local DEFAULT_OUTPUT_DIRECTORY = join_path(home_directory(), "Pictures/shots")

local CONFIG_KEYS = {
    output_dir = true,
    filename = true,
}

local function config_file_path()
    return join_path(home_directory(), ".config/fshot/config.lua")
end

local function validate_config(config, path)
    if type(config) ~= "table" then
        return nil, string.format("config %q must return a table", path)
    end

    for key in pairs(config) do
        if not CONFIG_KEYS[key] then
            return nil, string.format(
                "invalid config %q: unknown key %q (valid keys: output_dir, filename)",
                path, tostring(key))
        end
    end

    if config.output_dir ~= nil
        and (type(config.output_dir) ~= "string" or config.output_dir == "") then
        return nil, string.format(
            "invalid config %q: output_dir must be a non-empty string", path)
    end

    if config.filename ~= nil then
        if type(config.filename) ~= "string" or config.filename == "" then
            return nil, string.format(
                "invalid config %q: filename must be a non-empty os.date format", path)
        end

        if config.filename:find("[/\\]") then
            return nil, string.format(
                "invalid config %q: filename %q must not contain path separators; "
                .. "use output_dir for the directory", path, config.filename)
        end

        local renderable, render_error = pcall(os.date, config.filename)
        if not renderable then
            return nil, string.format(
                "invalid config %q: filename %q is not a valid os.date format (%s)",
                path, config.filename, tostring(render_error))
        end
    end

    return config
end

local function arguments_skip_config(arguments)
    for _, argument in ipairs(arguments) do
        if argument == "-h" or argument == "--help" or argument == "--test"
            or argument == "--list-windows" then
            return true
        end
    end

    return false
end

local function load_config()
    local path = config_file_path()
    local handle = io.open(path, "rb")
    if not handle then
        return {}
    end
    handle:close()

    local chunk, load_error = loadfile(path)
    if not chunk then
        return nil, string.format("cannot load config %q: %s", path, load_error)
    end

    local executed, result = pcall(chunk)
    if not executed then
        return nil, string.format("config %q raised an error: %s", path, tostring(result))
    end

    return validate_config(result, path)
end

local function create_single_directory(path)
    if IS_WINDOWS then
        local wide_path = utf8_to_wide(path)
        if not wide_path then
            return nil, "the path could not be converted to UTF-16"
        end

        if kernel32.CreateDirectoryW(wide_path, nil) ~= 0 then
            return true
        end

        local code = tonumber(kernel32.GetLastError())
        if code == ERROR_ALREADY_EXISTS then
            return true
        end

        return nil, win_error_message(code)
    end

    if ffi.C.mkdir(path, 493) == 0 then -- 0755
        return true
    end

    local code = ffi.errno()
    if code == EEXIST then
        return true
    end

    return nil, string.format("errno %d: %s", code, ffi.string(ffi.C.strerror(code)))
end

local function split_path_components(path)
    local separator = IS_WINDOWS and "\\" or "/"
    local normalized = path:gsub("[\\/]", separator)
    local prefix = ""

    if IS_WINDOWS then
        local drive = normalized:match("^(%a:)")
        if drive then
            prefix = drive
            normalized = normalized:sub(3)
        end
    end

    if normalized:sub(1, 1) == separator then
        prefix = prefix .. separator
        normalized = normalized:sub(2)
    end

    local pattern_separator = (separator == "\\") and "\\\\" or separator
    local components = {}
    for component in normalized:gmatch("[^" .. pattern_separator .. "]+") do
        table.insert(components, component)
    end

    return components, prefix, separator
end

-- Create every missing level of a directory path. Existing directories are
-- success; the first real failure is reported with its native error text.
local function ensure_directory(path)
    if path == "" or path == "." then
        return true
    end

    local components, prefix, separator = split_path_components(path)
    local current = prefix

    for _, component in ipairs(components) do
        if component ~= "." then
            local candidate = current .. component
            local created, create_error = create_single_directory(candidate)
            if not created then
                return nil, string.format("cannot create %q: %s", candidate, create_error)
            end

            current = candidate .. separator
        end
    end

    return true
end

local function parse_region(text)
    if not text:match("^%-?%d+,%-?%d+,%-?%d+,%-?%d+$") then
        return nil, string.format("invalid region %q: expected X,Y,W,H "
            .. "(for example 0,0,1920,1080)", text)
    end

    local values = {}
    for value in text:gmatch("%-?%d+") do
        table.insert(values, tonumber(value))
    end

    local width = values[3]
    local height = values[4]
    if width <= 0 or height <= 0 then
        return nil, string.format("invalid region %q: width and height must be positive",
            text)
    end

    return { x = values[1], y = values[2], width = width, height = height }
end

local function parse_options(arguments, config)
    config = config or {}

    local options = {
        target = "screen",
        region = nil,
        window_query = nil,
        delay_ms = 0,
        output = nil,
        output_dir = os.getenv("FSHOT_DIR") or config.output_dir
            or DEFAULT_OUTPUT_DIRECTORY,
        filename_template = config.filename or DEFAULT_FILENAME_TEMPLATE,
        clipboard = false,
        clipboard_set = false,
        clip_path = nil,
        write_file = true,
        json = false,
        compress = true,
        edit = false,
        tool = "rect",
        editor_color = EDITOR_PALETTE[1].colorref,
        editor_width = EDITOR_WIDTHS[2],
        list_windows = false,
        test = false,
        help = false,
    }

    local index = 1
    while index <= #arguments do
        local argument = arguments[index]

        if argument == "-h" or argument == "--help" then
            options.help = true
        elseif argument == "--test" then
            options.test = true
        elseif argument == "--full" then
            options.target = "screen"
            options.region = nil
            options.window_query = nil
        elseif argument == "--region" then
            index = index + 1
            if not arguments[index] then
                return nil, "--region requires X,Y,W,H"
            end
            local region, region_error = parse_region(arguments[index])
            if not region then
                return nil, region_error
            end
            options.target = "region"
            options.region = region
            options.window_query = nil
        elseif argument == "--window" then
            index = index + 1
            if not arguments[index] or arguments[index] == "" then
                return nil, "--window requires a title or process substring"
            end
            options.target = "window"
            options.window_query = arguments[index]
            options.region = nil
        elseif argument == "--active-window" or argument == "-a" then
            options.target = "active"
            options.region = nil
            options.window_query = nil
        elseif argument == "--select" or argument == "-s" then
            options.target = "select"
            options.region = nil
            options.window_query = nil
        elseif argument == "--delay" then
            index = index + 1
            local delay = tonumber(arguments[index])
            if not delay or delay < 0 or delay ~= math.floor(delay) then
                return nil, string.format("invalid --delay %q: expected milliseconds",
                    tostring(arguments[index]))
            end
            options.delay_ms = delay
        elseif argument == "--out" then
            index = index + 1
            if not arguments[index] or arguments[index] == "" then
                return nil, "--out requires a path"
            end
            options.output = arguments[index]
        elseif argument == "--clip" then
            options.clipboard = true
            options.clipboard_set = true
        elseif argument == "--clip-path" then
            local mode = arguments[index + 1]
            if mode == nil or mode:sub(1, 1) == "-" then
                options.clip_path = "plain"
            elseif mode == "plain" or mode == "md" then
                options.clip_path = mode
                index = index + 1
            else
                return nil, string.format(
                    "invalid --clip-path mode %q: expected plain or md", mode)
            end
        elseif argument == "--no-clip" then
            options.clipboard = false
            options.clipboard_set = true
        elseif argument == "--edit" then
            options.edit = true
        elseif argument == "--tool" then
            index = index + 1
            if not arguments[index] then
                return nil, "--tool requires a name (phase 1: rect)"
            end
            if arguments[index] ~= "rect" then
                return nil, string.format(
                    "unsupported --tool %q: phase 1 implements rectangles only",
                    arguments[index])
            end
            options.tool = arguments[index]
        elseif argument == "--color" then
            index = index + 1
            local editor_color, color_error = parse_color(arguments[index])
            if not editor_color then
                return nil, color_error
            end
            options.editor_color = editor_color
        elseif argument == "--width" then
            index = index + 1
            local width = tonumber(arguments[index])
            if not width or width < 1 or width > 64 or width ~= math.floor(width) then
                return nil, string.format("invalid --width %q: expected 1-64 pixels",
                    tostring(arguments[index]))
            end
            options.editor_width = width
        elseif argument == "--no-file" then
            options.write_file = false
        elseif argument == "--json" then
            options.json = true
        elseif argument == "--no-compress" then
            options.compress = false
        elseif argument == "--list-windows" then
            options.list_windows = true
        else
            return nil, string.format("unknown option %q (see --help)", argument)
        end

        index = index + 1
    end

    -- The editor saves and copies on accept by default (Greenshot behavior);
    -- --no-clip opts out and --no-file keeps only the clipboard copy. A path
    -- copy takes the clipboard instead of the image, so the paths never fight.
    if options.edit and not options.clipboard_set then
        options.clipboard = (options.clip_path == nil)
    end

    if options.edit and not IS_WINDOWS then
        return nil, "--edit is only implemented on Windows"
    end

    if options.target == "active" and not IS_WINDOWS then
        return nil, "--active-window is only implemented on Windows; "
            .. "use --window TEXT or --region X,Y,W,H instead"
    end

    if not options.write_file and options.output then
        return nil, "cannot combine --out with --no-file"
    end

    if options.clip_path and not options.write_file then
        return nil, "--clip-path needs a saved file; drop --no-file, "
            .. "or use --clip for image-only copies"
    end

    if options.clip_path and options.clipboard_set and options.clipboard then
        return nil, "cannot combine --clip (image) with --clip-path (text): "
            .. "both replace the clipboard contents"
    end

    if not options.write_file and not options.clipboard
        and not options.test and not options.help and not options.list_windows then
        return nil, "--no-file requires --clip (or --edit without --no-clip), "
            .. "otherwise the capture would be discarded"
    end

    return options
end

local function default_output_path(directory, filename_template)
    local base = os.date(filename_template or DEFAULT_FILENAME_TEMPLATE)
    local candidate = join_path(directory, base .. ".png")
    local counter = 1

    while true do
        local existing = io.open(candidate, "rb")
        if not existing then
            return candidate
        end
        existing:close()
        candidate = join_path(directory, string.format("%s-%d.png", base, counter))
        counter = counter + 1
    end
end

function resolve_output_path(requested, options)
    options = options or {}
    local filename_template = options.filename_template or DEFAULT_FILENAME_TEMPLATE

    if requested then
        local last_character = requested:sub(-1)
        if last_character == "/" or last_character == "\\" then
            local created, create_error = ensure_directory(requested)
            if not created then
                return nil, create_error
            end

            return default_output_path(requested, filename_template)
        end

        return requested
    end

    local directory = options.output_dir or DEFAULT_OUTPUT_DIRECTORY
    local created, create_error = ensure_directory(directory)
    if not created then
        return nil, create_error
    end

    return default_output_path(directory, filename_template)
end

local function describe_write_error(path, raw_error)
    local message = tostring(raw_error or "write failed")
    local path_prefix = path .. ": "
    if message:sub(1, #path_prefix) == path_prefix then
        message = message:sub(#path_prefix + 1)
    end
    if message:find("No such file or directory", 1, true) then
        message = message .. " (check that the parent directory exists)"
    end
    return string.format("cannot write %q: %s", path, message)
end

function write_binary_file(path, data, size)
    local file, open_error = io.open(path, "wb")
    if not file then
        return false, describe_write_error(path, open_error)
    end

    local written, write_error = file:write(ffi.string(data, size))
    if not written then
        file:close()
        return false, describe_write_error(path, write_error)
    end

    local closed, close_error = file:close()
    if closed == nil then
        return false, describe_write_error(path, close_error)
    end

    return true
end

local function json_summary(image, path, size, compressed, elapsed_ms, clipboard_ok,
                            path_copied)
    local fields = {
        string.format('"path":%s', path and string.format("%q", path) or "null"),
        string.format('"width":%d', image.width),
        string.format('"height":%d', image.height),
        string.format('"x":%d', image.x or 0),
        string.format('"y":%d', image.y or 0),
        string.format('"bytes":%d', size),
        string.format('"compressed":%s', compressed and "true" or "false"),
        string.format('"source":"%s"', image.source or "screen"),
        string.format('"elapsed_ms":%d', elapsed_ms),
        string.format('"clipboard":%s', clipboard_ok and "true" or "false"),
        string.format('"clip_path":%s', path_copied and "true" or "false"),
    }
    return "{" .. table.concat(fields, ",") .. "}"
end

--------------------------------------------------------------------------------
-- Self-Tests
--------------------------------------------------------------------------------

local function run_tests()
    local passed, failed, skipped = 0, 0, 0

    local function check(name, condition, detail)
        if condition then
            passed = passed + 1
            print(string.format("  [PASS] %s", name))
        else
            failed = failed + 1
            print(string.format("  [FAIL] %s%s", name, detail and (": " .. detail) or ""))
        end
    end

    local function skip(name, reason)
        skipped = skipped + 1
        print(string.format("  [SKIP] %s (%s)", name, reason))
    end

    print("Running fshot.lua automated self-tests...")

    local crc_input = ffi.new("uint8_t[9]")
    ffi.copy(crc_input, "123456789", 9)
    check("crc32(\"123456789\") == 0xCBF43926",
        crc32_memory(crc_input, 9) == 0xCBF43926,
        string.format("got 0x%08X", crc32_memory(crc_input, 9)))
    check("crc32 (pure Lua fallback) == 0xCBF43926",
        crc32_lua(crc_input, 9) == 0xCBF43926,
        string.format("got 0x%08X", crc32_lua(crc_input, 9)))

    local adler_input = ffi.new("uint8_t[9]")
    ffi.copy(adler_input, "Wikipedia", 9)
    check("adler32(\"Wikipedia\") == 0x11E60398",
        adler32_memory(adler_input, 9) == 0x11E60398,
        string.format("got 0x%08X", adler32_memory(adler_input, 9)))
    check("adler32 (pure Lua fallback) == 0x11E60398",
        adler32_lua(adler_input, 9) == 0x11E60398,
        string.format("got 0x%08X", adler32_lua(adler_input, 9)))

    if zlib then
        local mixed = ffi.new("uint8_t[4096]")
        for index = 0, 4095 do
            mixed[index] = (index * 37 + 11) % 256
        end
        local native_crc = tonumber(zlib.crc32(0, ffi.cast("const Bytef*", mixed), 4096))
        local native_adler = tonumber(zlib.adler32(1, ffi.cast("const Bytef*", mixed), 4096))
        check("native and pure Lua crc32 agree over 4096 bytes",
            crc32_lua(mixed, 4096) == native_crc % 4294967296)
        check("native and pure Lua adler32 agree over 4096 bytes",
            adler32_lua(mixed, 4096) == native_adler)
    end

    local forward = normalize_selection(100, 120, 299, 249)
    check("normalize_selection handles a forward drag",
        forward.x == 100 and forward.y == 120 and forward.width == 200
            and forward.height == 130,
        string.format("got %d,%d %dx%d", forward.x, forward.y,
            forward.width, forward.height))

    local reverse = normalize_selection(299, 249, 100, 120)
    check("normalize_selection handles a reverse drag",
        reverse.x == 100 and reverse.y == 120 and reverse.width == 200
            and reverse.height == 130,
        string.format("got %d,%d %dx%d", reverse.x, reverse.y,
            reverse.width, reverse.height))

    local single_pixel = normalize_selection(7, 9, 7, 9)
    check("normalize_selection reports a single-pixel drag as 1x1",
        single_pixel.width == 1 and single_pixel.height == 1)

    local red_colorref = parse_color("#E53935")
    check("parse_color decodes #RRGGBB into COLORREF", red_colorref == 0x003539E5,
        string.format("got 0x%08X", red_colorref or 0))
    check("parse_color accepts palette names case-insensitively",
        parse_color("RED") == red_colorref)

    local bad_color, bad_color_error = parse_color("chartreuse")
    check("parse_color rejects unknown names with guidance",
        bad_color == nil and tostring(bad_color_error):find("#RRGGBB", 1, true) ~= nil,
        tostring(bad_color_error))

    check("color_to_hex round-trips a COLORREF",
        color_to_hex(red_colorref) == "#E53935", color_to_hex(red_colorref))

    check("fit_scale never upscales a small image", fit_scale(200, 100, 400, 400) == 1)
    check("fit_scale fits by width", fit_scale(400, 200, 200, 200) == 0.5)
    check("fit_scale fits by height", fit_scale(400, 400, 200, 100) == 0.25)
    check("fit_scale guards zero-sized inputs", fit_scale(0, 0, 100, 100) == 1)

    local crop_source = ffi.new("uint8_t[?]", 4 * 3 * 4)
    for row = 0, 2 do
        for column = 0, 3 do
            local offset = (row * 4 + column) * 4
            crop_source[offset] = row * 10 + column
            crop_source[offset + 1] = row * 10 + column + 1
            crop_source[offset + 2] = row * 10 + column + 2
            crop_source[offset + 3] = 255
        end
    end
    local cropped = crop_bgra(crop_source, 4, { x = 1, y = 1, width = 2, height = 2 })
    check("crop_bgra extracts the requested rectangle",
        cropped[0] == 11 and cropped[1] == 12 and cropped[2] == 13
            and cropped[4] == 12 and cropped[5] == 13 and cropped[6] == 14
            and cropped[8] == 21 and cropped[9] == 22 and cropped[10] == 23,
        string.format("got %d,%d,%d / %d,%d,%d / %d,%d,%d",
            cropped[0], cropped[1], cropped[2],
            cropped[4], cropped[5], cropped[6],
            cropped[8], cropped[9], cropped[10]))

    local region, region_error = parse_region("10,20,30,40")
    check("parse_region accepts 10,20,30,40",
        region and region.x == 10 and region.y == 20 and region.width == 30
            and region.height == 40,
        region_error)

    local negative_region = parse_region("-1920,0,1920,1080")
    check("parse_region accepts a negative origin",
        negative_region and negative_region.x == -1920, "negative origins are valid")

    local bad_region, bad_region_error = parse_region("1,2,3")
    check("parse_region rejects a short region",
        bad_region == nil and type(bad_region_error) == "string")

    local zero_region, zero_region_error = parse_region("0,0,0,10")
    check("parse_region rejects zero width",
        zero_region == nil and type(zero_region_error) == "string")

    local joined_path = join_path("C:/Users/me/shots/", "shot.png")
    if IS_WINDOWS then
        check("join_path produces native separators",
            joined_path == "C:\\Users\\me\\shots\\shot.png", joined_path)
    else
        check("join_path keeps POSIX separators",
            joined_path == "C:/Users/me/shots/shot.png", joined_path)
    end

    local markdown_link = format_clip_path("shot one.png", "md")
    local markdown_suffix = "shot%20one.png)"
    check("format_clip_path builds a percent-encoded markdown link",
        markdown_link:sub(1, 4) == "![]("
            and markdown_link:sub(-#markdown_suffix) == markdown_suffix,
        markdown_link)

    local plain_path = format_clip_path("shot one.png", "plain")
    check("format_clip_path returns an absolute native path",
        plain_path ~= "shot one.png"
            and (plain_path:find("/", 1, true) ~= nil
                or plain_path:find("\\", 1, true) ~= nil),
        plain_path)

    local validated_config, validated_config_error = validate_config(
        { output_dir = "tmp/shots", filename = "shot-%Y%m%d" }, "test")
    check("validate_config accepts output_dir and filename",
        validated_config ~= nil and validated_config.output_dir == "tmp/shots",
        validated_config_error)

    local unknown_config, unknown_config_error = validate_config({ outputdir = "tmp" }, "test")
    check("validate_config rejects unknown keys with the valid list",
        unknown_config == nil
            and tostring(unknown_config_error):find("unknown key", 1, true) ~= nil
            and tostring(unknown_config_error):find("output_dir", 1, true) ~= nil,
        tostring(unknown_config_error))

    local separator_config, separator_config_error = validate_config(
        { filename = "a/b" }, "test")
    check("validate_config rejects path separators in filename",
        separator_config == nil
            and tostring(separator_config_error):find("separator", 1, true) ~= nil,
        tostring(separator_config_error))

    local clip_path_options = parse_options({ "--clip-path", "md" }, {})
    check("parse_options accepts --clip-path md",
        clip_path_options ~= nil and clip_path_options.clip_path == "md")

    local conflict_options, conflict_error = parse_options({ "--clip", "--clip-path" }, {})
    check("parse_options rejects --clip with --clip-path",
        conflict_options == nil
            and tostring(conflict_error):find("cannot combine", 1, true) ~= nil,
        tostring(conflict_error))

    local no_file_options, no_file_error = parse_options({ "--clip-path", "--no-file" }, {})
    check("parse_options rejects --clip-path with --no-file",
        no_file_options == nil
            and tostring(no_file_error):find("saved file", 1, true) ~= nil,
        tostring(no_file_error))

    if IS_WINDOWS then
        local active_options = parse_options({ "--active-window" }, {})
        check("parse_options maps --active-window to the active target",
            active_options ~= nil and active_options.target == "active")

        local edit_clip_options = parse_options({ "--edit", "--clip-path" }, {})
        check("--edit with --clip-path copies the path instead of the image",
            edit_clip_options ~= nil and edit_clip_options.clip_path == "plain"
                and edit_clip_options.clipboard == false)
    else
        skip("--active-window and --edit parsing", "Windows only")
    end

    local test_width, test_height = 4, 3
    local source = ffi.new("uint8_t[?]", test_width * test_height * 4)
    local expected = {}
    for row = 0, test_height - 1 do
        for column = 0, test_width - 1 do
            local red = (column * 60 + 20) % 256
            local green = (row * 90 + 30) % 256
            local blue = (column * 20 + row * 40 + 50) % 256
            local offset = (row * test_width + column) * 4
            source[offset] = blue
            source[offset + 1] = green
            source[offset + 2] = red
            source[offset + 3] = 255
            table.insert(expected, { r = red, g = green, b = blue })
        end
    end

    local test_image = {
        width = test_width,
        height = test_height,
        pixels = source,
    }

    local stored_png, stored_size = encode_png(test_image, false)
    check("stored-deflate PNG encodes", stored_png ~= nil and stored_size > 60)
    if not stored_png then
        print(string.format("\nSelf-test summary: %d passed, %d failed, %d skipped.",
            passed, failed, skipped))
        return 1
    end

    local inspected, inspect_error = inspect_png(stored_png, stored_size)
    check("PNG parses", inspected ~= nil, inspect_error)

    if inspected then
        check("IHDR dimensions and color type",
            inspected.width == test_width and inspected.height == test_height
                and inspected.depth == 8 and inspected.color_type == 2,
            string.format("width=%s height=%s depth=%s color=%s",
                tostring(inspected.width), tostring(inspected.height),
                tostring(inspected.depth), tostring(inspected.color_type)))

        local chunk_types = {}
        local all_crcs_ok = true
        for _, chunk in ipairs(inspected.chunks) do
            table.insert(chunk_types, chunk.type)
            if not chunk.crc_ok then
                all_crcs_ok = false
            end
        end
        check("PNG chunk CRCs are valid", all_crcs_ok)
        check("PNG chunk order is IHDR, IDAT, IEND",
            table.concat(chunk_types, ",") == "IHDR,IDAT,IEND",
            table.concat(chunk_types, ","))

        local raw, raw_error = inflate_stored(inspected.idat, inspected.idat_size,
            test_height * (1 + test_width * 3))
        check("stored IDAT inflates with a valid adler32", raw ~= nil, raw_error)

        if raw then
            local decoded, decode_error = decode_scanlines(raw, test_width, test_height)
            local matches = decoded ~= nil
            if decoded then
                for index = 1, #expected do
                    local actual = decoded[index]
                    local wanted = expected[index]
                    if actual.r ~= wanted.r or actual.g ~= wanted.g
                        or actual.b ~= wanted.b then
                        matches = false
                        break
                    end
                end
            end
            check("decoded pixels match the source image", matches, decode_error)
        end

        if zlib then
            local compressed_png, compressed_size = encode_png(test_image, true)
            local compressed_info, compressed_error = inspect_png(compressed_png or ffi.new("uint8_t[1]"),
                compressed_size or 0)
            check("zlib-compressed PNG encodes and parses",
                compressed_info ~= nil and compressed_info.idat_size < inspected.idat_size,
                compressed_error)

            if compressed_info then
                local compressed_raw, compressed_raw_error = inflate_with_zlib(
                    compressed_info.idat, compressed_info.idat_size,
                    test_height * (1 + test_width * 3))
                check("zlib IDAT decompresses to the expected size",
                    compressed_raw ~= nil, compressed_raw_error)
            end
        else
            skip("zlib-compressed PNG", "no zlib library found; stored blocks used instead")
        end
    end

    local temporary_path = os.tmpname()
    local write_ok, write_error = write_binary_file(temporary_path, stored_png, stored_size)
    if write_ok then
        local handle = io.open(temporary_path, "rb")
        local content = handle and handle:read("*a") or ""
        if handle then
            handle:close()
        end
        os.remove(temporary_path)
        check("PNG writes to disk and reads back byte-for-byte",
            #content == stored_size and content:sub(1, 8) == PNG_SIGNATURE)
    else
        check("PNG writes to disk and reads back byte-for-byte", false, write_error)
    end

    local image, capture_error = capture_region(0, 0, 16, 16)
    if image then
        check("live capture returns 16x16 pixels",
            image.width == 16 and image.height == 16)
        local live_png, live_size = encode_png(image, false)
        check("live capture encodes to PNG", live_png ~= nil and live_size > 60)
    else
        skip("live screen capture", tostring(capture_error))
    end

    print(string.format("\nSelf-test summary: %d passed, %d failed, %d skipped.",
        passed, failed, skipped))
    if failed > 0 then
        return 1
    end
    return 0
end

--------------------------------------------------------------------------------
-- Entry Point
--------------------------------------------------------------------------------

local function main(arguments)
    -- Help, self-tests, and window listing must stay usable while the user is
    -- fixing a broken config, so they do not load it at all.
    local config = {}
    if not arguments_skip_config(arguments) then
        local config_error
        config, config_error = load_config()
        if not config then
            io.stderr:write("fshot: " .. config_error .. "\n")
            return 1
        end
    end

    local options, option_error = parse_options(arguments, config)
    if not options then
        io.stderr:write("fshot: " .. option_error .. "\n")
        io.stderr:write("Try 'fshot --help' for usage.\n")
        return 2
    end

    if options.help then
        print(USAGE)
        return 0
    end

    if options.test then
        return run_tests()
    end

    platform_prepare()

    if options.list_windows then
        local windows, list_error = platform_list_windows()
        if not windows then
            io.stderr:write("fshot: " .. list_error .. "\n")
            return 1
        end
        if #windows == 0 then
            print("No visible top-level windows found.")
            return 0
        end

        print(string.format("%-13s %-24s %-11s %s", "WINDOW", "PROCESS", "SIZE", "TITLE"))
        print(string.format("%-13s %-24s %-11s %s", "------", "-------", "----", "-----"))
        for _, window in ipairs(windows) do
            print(string.format("%-13s %-24s %4dx%-6d %s",
                window.id, window.process or "?", window.width, window.height, window.title))
        end
        return 0
    end

    if options.delay_ms > 0 then
        io.stderr:write(string.format("fshot: capturing in %d ms...\n", options.delay_ms))
        sleep_ms(options.delay_ms)
    end

    local started_at = now_ms()
    local image, capture_error

    if options.target == "active" then
        local window, window_error = platform_active_window()
        if not window then
            io.stderr:write("fshot: " .. window_error .. "\n")
            return 1
        end
        image, capture_error = platform_capture_window(window)
    elseif options.target == "window" then
        local window, window_error, match_count = resolve_window(options.window_query)
        if not window then
            io.stderr:write("fshot: " .. window_error .. "\n")
            return 1
        end
        if match_count > 1 then
            io.stderr:write(string.format(
                "fshot: %d windows matched %q; capturing %q (%s)\n",
                match_count, options.window_query, window.title, window.process or "?"))
        end
        image, capture_error = platform_capture_window(window)
    elseif options.target == "region" then
        image, capture_error = capture_region(options.region.x, options.region.y,
            options.region.width, options.region.height)
    elseif options.target == "select" then
        image, capture_error = platform_select_region()
        -- Dragging is user time, not capture latency; time the work after release.
        started_at = now_ms()
    else
        local bounds, bounds_error = platform_screen_bounds()
        if not bounds then
            io.stderr:write("fshot: " .. bounds_error .. "\n")
            return 1
        end
        image, capture_error = capture_region(bounds.x, bounds.y,
            bounds.width, bounds.height)
    end

    if not image then
        io.stderr:write("fshot: " .. capture_error .. "\n")
        return 1
    end

    for _, warning in ipairs(image.warnings or {}) do
        io.stderr:write("fshot: warning: " .. warning .. "\n")
    end

    if options.edit then
        local result, edit_error = win_edit_image(image, options)
        if not result then
            io.stderr:write("fshot: " .. tostring(edit_error) .. "\n")
            return 1
        end

        if options.json then
            print(json_summary(image, result.path, result.bytes, result.compressed,
                result.elapsed_ms, result.copied, result.path_copied))
        else
            local compression = result.compressed and "zlib" or "stored"
            local summary = string.format("%dx%d  %s  %s  %d ms",
                image.width, image.height, format_bytes(result.bytes), compression,
                result.elapsed_ms)
            if result.path and result.path_copied then
                local copied_kind = (options.clip_path == "md") and "markdown" or "path"
                print(string.format("%s  %s  (%s copied)",
                    result.path, summary, copied_kind))
            elseif result.path and result.copied then
                print(string.format("%s  %s  (also copied to clipboard)",
                    result.path, summary))
            elseif result.path then
                print(string.format("%s  %s", result.path, summary))
            else
                print(string.format("copied to clipboard  %s", summary))
            end
        end
        return 0
    end

    local png, png_size_or_error, compressed = encode_png(image, options.compress)
    if not png then
        io.stderr:write("fshot: PNG encoding failed: " .. tostring(png_size_or_error) .. "\n")
        return 1
    end

    local png_size = png_size_or_error

    local output_path = nil
    if options.write_file then
        local path_error
        output_path, path_error = resolve_output_path(options.output, options)
        if not output_path then
            io.stderr:write("fshot: " .. path_error .. "\n")
            io.stderr:write("fshot: set a writable directory with --out, FSHOT_DIR, "
                .. "or ~/.config/fshot/config.lua\n")
            return 1
        end

        local write_ok, write_error = write_binary_file(output_path, png, png_size)
        if not write_ok then
            io.stderr:write("fshot: " .. write_error .. "\n")
            return 1
        end
    end

    local clipboard_ok = false
    if options.clipboard then
        local copied, clipboard_error, clipboard_warnings = platform_copy_clipboard(
            image, png, png_size)
        if not copied then
            io.stderr:write("fshot: " .. tostring(clipboard_error) .. "\n")
            if output_path then
                io.stderr:write(string.format(
                    "fshot: the image was still written to %s\n", output_path))
            end
            return 1
        end
        clipboard_ok = true
        for _, warning in ipairs(clipboard_warnings or {}) do
            io.stderr:write("fshot: warning: " .. warning .. "\n")
        end
    end

    local path_copied = false
    if options.clip_path then
        local copied_path, path_copy_error = copy_saved_path(output_path, options.clip_path)
        if not copied_path then
            io.stderr:write("fshot: " .. tostring(path_copy_error) .. "\n")
            if output_path then
                io.stderr:write(string.format(
                    "fshot: the image was still written to %s\n", output_path))
            end
            return 1
        end
        path_copied = true
    end

    local elapsed_ms = now_ms() - started_at

    if options.json then
        print(json_summary(image, output_path, png_size, compressed, elapsed_ms,
            clipboard_ok, path_copied))
    else
        local compression = compressed and "zlib" or "stored"
        local summary = string.format("%dx%d  %s  %s  %d ms",
            image.width, image.height, format_bytes(png_size), compression, elapsed_ms)
        if output_path and path_copied then
            local copied_kind = (options.clip_path == "md") and "markdown" or "path"
            print(string.format("%s  %s  (%s copied)", output_path, summary, copied_kind))
        elseif output_path and clipboard_ok then
            print(string.format("%s  %s  (also copied to clipboard)", output_path, summary))
        elseif output_path then
            print(string.format("%s  %s", output_path, summary))
        else
            print(string.format("copied to clipboard  %s", summary))
        end
    end

    return 0
end

local exit_code = main({ ... })
os.exit(exit_code)
