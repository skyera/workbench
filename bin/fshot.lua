#!/usr/bin/env luajit
--[[
  fshot.lua - Screen and window capture to PNG without external tools (LuaJIT + FFI).

  Features:
    - Full virtual desktop capture across monitors, including negative coordinates.
    - Region capture in physical pixels (--region X,Y,W,H).
    - Interactive region selection (--select) over a frozen, dimmed desktop with a live
      size readout; Esc or right-click cancels (Windows only).
    - Window capture by title or process substring (--window TEXT), using PrintWindow
      so occluded windows are rendered, with a screen-blit fallback when that fails.
    - PNG encoding in-process: zlib when a zlib library is available, otherwise valid
      stored-deflate blocks, so there is never an external dependency.
    - Optional clipboard copy: native CF_DIB + "PNG" formats on Windows; wl-copy or
      xclip on Linux when installed.
    - Built-in self-test suite (--test) that validates the PNG encoder without a display.

  Usage:
    fshot [--full | --region X,Y,W,H | --window TEXT | --select] [options]
    fshot --list-windows
    fshot --test

  Options:
    --full               Capture the whole virtual desktop (default).
    --region X,Y,W,H     Capture a rectangle in physical pixels.
    --window TEXT        Capture the best visible window matching TEXT by title or
                         process name (Windows only).
    --list-windows       Print visible top-level windows and exit (Windows only).
    --delay MS           Wait MS milliseconds before capturing (to open menus).
    --out PATH           Output file (default: shot-YYYYmmdd-HHMMSS.png); a path ending
                         in a separator writes the default name inside that directory.
    --clip               Also copy the image to the system clipboard.
    --no-file            Do not write a file; requires --clip.
    --no-compress        Store uncompressed deflate blocks even when zlib is available.
    --json               Print a machine-readable summary.
    -h, --help           Show this help message.

  Exit codes:
    0  Success
    1  Capture, encode, write, or clipboard failure
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
        BOOL PrintWindow(HWND hwnd, HDC hdcBlt, UINT nFlags);
        BOOL GetWindowRect(HWND hWnd, RECT* lpRect);
        BOOL IsWindowVisible(HWND hWnd);
        BOOL IsIconic(HWND hWnd);
        int GetWindowTextW(HWND hWnd, wchar_t* lpString, int nMaxCount);
        int GetWindowTextLengthW(HWND hWnd);
        DWORD GetWindowThreadProcessId(HWND hWnd, DWORD* lpdwProcessId);
        BOOL EnumWindows(WNDENUMPROC lpEnumFunc, LPARAM lParam);
        BOOL SetProcessDPIAware(void);
        BOOL SetProcessDpiAwarenessContext(void* value);

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
local GMEM_MOVEABLE = 0x0002
local PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
local FORMAT_MESSAGE_FROM_SYSTEM = 0x00001000
local CP_UTF8 = 65001

local SM_XVIRTUALSCREEN = 76
local SM_YVIRTUALSCREEN = 77
local SM_CXVIRTUALSCREEN = 78
local SM_CYVIRTUALSCREEN = 79

local WS_POPUP = 0x80000000
local WS_EX_TOPMOST = 0x00000008
local WS_EX_TOOLWINDOW = 0x00000080
local WS_EX_LAYERED = 0x00080000
local LWA_ALPHA = 0x00000002
local SW_SHOW = 5
local NULL_BRUSH = 5
local DEFAULT_GUI_FONT = 17
local LOGPIXELSY = 90
local IDC_CROSS = 32515
local ERROR_CLASS_ALREADY_EXISTS = 1410

local WM_DESTROY = 0x0002
local WM_PAINT = 0x000F
local WM_ERASEBKGND = 0x0014
local WM_SETCURSOR = 0x0020
local WM_KEYDOWN = 0x0100
local WM_MOUSEMOVE = 0x0200
local WM_LBUTTONDOWN = 0x0201
local WM_LBUTTONUP = 0x0202
local WM_RBUTTONUP = 0x0205
local VK_ESCAPE = 0x1B

local DT_LEFT = 0x00000000
local DT_CENTER = 0x00000001
local DT_VCENTER = 0x00000004
local DT_SINGLELINE = 0x00000020
local DT_CALCRECT = 0x00000400

local ZPIXMAP = 2
local LSB_FIRST = 0

local PNG_SIGNATURE = "\x89PNG\r\n\x1a\n"
local DEFLATE_BLOCK_MAX = 65535

local USAGE = [[
Usage:
  fshot [--full | --region X,Y,W,H | --window TEXT | --select] [options]
  fshot --list-windows
  fshot --test

Capture:
  --full               Capture the whole virtual desktop (default).
  --region X,Y,W,H     Capture a rectangle in physical pixels (negative origins allowed).
  --window TEXT        Capture the best visible window matching TEXT (Windows only).
  --select, -s         Drag a rectangle to capture it (Windows only).
  --list-windows       List visible top-level windows (Windows only).
  --delay MS           Wait before capturing, so menus can be opened.

Output:
  --out PATH           Output file, or a directory ending in / or \.
  --clip               Also copy the image to the system clipboard.
  --no-file            Do not write a file; requires --clip.
  --no-compress        Use stored deflate blocks instead of zlib compression.
  --json               Print a machine-readable summary.

Other:
  -h, --help           Show this help message.
  --test               Run the automated self-test suite.

Examples:
  fshot
  fshot --region 0,0,1280,720 --out tmp/shot.png
  fshot --window firefox --clip
  fshot --select --clip
  fshot --delay 1500 --window "Save As"
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

--------------------------------------------------------------------------------
-- Windows Region Selector
--------------------------------------------------------------------------------

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

local function win_copy_to_clipboard(image, png, png_size)
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

    local opened = 0
    for attempt = 1, 5 do
        opened = user32.OpenClipboard(nil)
        if opened ~= 0 then
            break
        end
        sleep_ms(50)
    end
    if opened == 0 then
        kernel32.GlobalFree(dib_memory)
        return nil, "cannot open the clipboard after 5 attempts (" .. win_error_message()
            .. ").\n  Another application is holding it; retry in a moment, "
            .. "or drop --clip to write a file only."
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

local function linux_copy_to_clipboard(png, png_size)
    local temporary_path = os.tmpname()
    local file, open_error = io.open(temporary_path, "wb")
    if not file then
        return nil, "cannot create a temporary file for the clipboard: "
            .. tostring(open_error)
    end
    file:write(ffi.string(png, png_size))
    file:close()

    local commands = {
        {
            probe = "command -v wl-copy >/dev/null 2>&1",
            copy = string.format("wl-copy --type image/png < %q", temporary_path),
            name = "wl-copy",
        },
        {
            probe = "command -v xclip >/dev/null 2>&1",
            copy = string.format("xclip -selection clipboard -t image/png -i %q", temporary_path),
            name = "xclip",
        },
    }

    for _, command in ipairs(commands) do
        local available = execute_command(command.probe)
        if available then
            local copied, failure = execute_command(command.copy)
            os.remove(temporary_path)
            if not copied then
                return nil, string.format("%s failed (%s); install a working clipboard tool "
                    .. "or write a file and copy it manually", command.name, tostring(failure))
            end
            return true, nil, {}
        end
    end

    os.remove(temporary_path)
    return nil, "no clipboard tool found.\n  Install wl-clipboard (wl-copy) or xclip, "
        .. "or write a file and copy it manually."
end

local function platform_copy_clipboard(image, png, png_size)
    if IS_WINDOWS then
        return win_copy_to_clipboard(image, png, png_size)
    end
    if IS_LINUX then
        return linux_copy_to_clipboard(png, png_size)
    end
    return nil, "clipboard copy is only implemented for Windows and Linux"
end

--------------------------------------------------------------------------------
-- Command-Line Handling
--------------------------------------------------------------------------------

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

local function parse_options(arguments)
    local options = {
        target = "screen",
        region = nil,
        window_query = nil,
        delay_ms = 0,
        output = nil,
        clipboard = false,
        write_file = true,
        json = false,
        compress = true,
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

    if not options.write_file and options.output then
        return nil, "cannot combine --out with --no-file"
    end

    if not options.write_file and not options.clipboard
        and not options.test and not options.help and not options.list_windows then
        return nil, "--no-file requires --clip, otherwise the capture would be discarded"
    end

    return options
end

local function default_output_path()
    local base = os.date("shot-%Y%m%d-%H%M%S")
    local path = base .. ".png"
    local counter = 1

    while true do
        local existing = io.open(path, "rb")
        if not existing then
            return path
        end
        existing:close()
        path = string.format("%s-%d.png", base, counter)
        counter = counter + 1
    end
end

local function resolve_output_path(requested)
    if not requested then
        return default_output_path()
    end

    local last_character = requested:sub(-1)
    if last_character == "/" or last_character == "\\" then
        return requested .. default_output_path()
    end

    return requested
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

local function write_binary_file(path, data, size)
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

local function json_summary(image, path, size, compressed, elapsed_ms, clipboard_ok)
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
    local options, option_error = parse_options(arguments)
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

    if options.target == "window" then
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

    local png, png_size_or_error, compressed = encode_png(image, options.compress)
    if not png then
        io.stderr:write("fshot: PNG encoding failed: " .. tostring(png_size_or_error) .. "\n")
        return 1
    end

    local png_size = png_size_or_error

    local output_path = nil
    if options.write_file then
        output_path = resolve_output_path(options.output)
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

    local elapsed_ms = now_ms() - started_at

    if options.json then
        print(json_summary(image, output_path, png_size, compressed, elapsed_ms, clipboard_ok))
    else
        local compression = compressed and "zlib" or "stored"
        local summary = string.format("%dx%d  %s  %s  %d ms",
            image.width, image.height, format_bytes(png_size), compression, elapsed_ms)
        if output_path and clipboard_ok then
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
