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
      * D / K: Force kill (SIGKILL on Linux, TerminateProcess on Windows), confirmed with y / Enter
    - Multi-Column Sorting:
      * s: Cycle sorting order (Memory -> PID -> Name -> Threads)
    - Preserved CLI Modes:
      * fkill <PID>...: Directly kill processes by PID (positive decimal only)
      * fkill <NAME>: Kill processes whose name matches exactly, after confirmation
      * fkill -9 <PID|NAME>: Force kill by PID or name
      * fkill -y <NAME>: Skip the kill-by-name confirmation (for scripts)
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
    -y, --yes            Kill by name without asking for confirmation
    -l, --list           Print formatted process table to stdout and exit
    -p, --preview <PID>  Print rich process details card to stdout and exit
    --fzf                Launch legacy fzf pipeline mode
    --test               Run built-in automated self-test suite and exit
    -h, --help           Show this help message
    --                   Treat every following argument as a PID or name

  Exit status:
    0  every requested process was killed
    1  a kill failed, nothing matched, or the confirmation was declined
    2  invalid command line (nothing was killed)
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
        DWORD GetCurrentProcessId(void);
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
        int getpid(void);
        int isatty(int fd);

        struct pollfd {
            int fd;
            short events;
            short revents;
        };
        int poll(struct pollfd *fds, unsigned long nfds, int timeout);

        /* Sized for glibc's 1024-bit sigset_t; only libc reads its contents. */
        typedef struct { unsigned long bits[16]; } fkill_sigset_t;
        int sigemptyset(fkill_sigset_t *set);
        int sigaddset(fkill_sigset_t *set, int signum);
        int sigismember(const fkill_sigset_t *set, int signum);
        int sigprocmask(int how, const fkill_sigset_t *set, fkill_sigset_t *oldset);
        int sigpending(fkill_sigset_t *set);
        int sigwait(const fkill_sigset_t *set, int *sig);
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
    pending_keys = {}, -- decoded keys not yet returned by Term.read_key
    read_buffer = nil, -- reusable char buffer for POSIX read()
    saved_signal_mask = nil, -- signal mask to put back when the TUI ends
    received_signal = nil, -- entry of TERMINATING_SIGNALS that ended the TUI
}

-- Bytes requested per read(); a paste or key repeat can deliver many keys at once.
local READ_BUFFER_SIZE = 256

local EINTR = 4
local EXIT_FAILURE = 1

local POLLIN = 0x0001

-- How long a key wait may block before the TUI re-checks the terminal size.
-- read() alone would only notice a resize on the next keypress.
local RESIZE_POLL_INTERVAL_MS = 250

-- Waits up to `timeout_ms` for input on `fd`. Returns true when read() should be
-- called (data, hang-up, or a poll error that read() will report precisely) and
-- false when the wait timed out or was interrupted.
local function wait_for_input(fd, timeout_ms)
    local poll_request = ffi.new("struct pollfd[1]")
    poll_request[0].fd = fd
    poll_request[0].events = POLLIN

    local ready_count = ffi.C.poll(poll_request, 1, timeout_ms)
    if ready_count == 0 then
        return false
    end

    if ready_count < 0 and ffi.errno() == EINTR then
        return false
    end

    return true
end

local O_RDWR = 2

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

local SIG_BLOCK = 0
local SIG_SETMASK = 2

-- Shells report "killed by signal N" as exit status 128 + N.
local SIGNAL_EXIT_BASE = 128

-- Signals that would otherwise kill fkill mid-TUI and leave the terminal raw.
local TERMINATING_SIGNALS = {
    { number = 1, name = "SIGHUP" },
    { number = 2, name = "SIGINT" },
    { number = 3, name = "SIGQUIT" },
    { number = 15, name = "SIGTERM" },
}

-- Blocks the terminating signals so they stay pending instead of killing the
-- process. Returns the previous signal mask for restore_signal_mask().
local function block_terminating_signals()
    local blocked = ffi.new("fkill_sigset_t")
    ffi.C.sigemptyset(blocked)
    for _, signal in ipairs(TERMINATING_SIGNALS) do
        ffi.C.sigaddset(blocked, signal.number)
    end

    local previous_mask = ffi.new("fkill_sigset_t")
    ffi.C.sigprocmask(SIG_BLOCK, blocked, previous_mask)
    return previous_mask
end

-- Puts back a mask returned by block_terminating_signals(). Any signal still
-- pending is delivered at this point with its default action.
local function restore_signal_mask(previous_mask)
    if previous_mask then
        ffi.C.sigprocmask(SIG_SETMASK, previous_mask, nil)
    end
end

-- Returns the first blocked terminating signal that is pending, or nil.
-- Polling sigpending() replaces a signal handler, which LuaJIT cannot run safely.
local function pending_terminating_signal()
    local pending = ffi.new("fkill_sigset_t")
    if ffi.C.sigpending(pending) ~= 0 then
        return nil
    end

    for _, signal in ipairs(TERMINATING_SIGNALS) do
        if ffi.C.sigismember(pending, signal.number) == 1 then
            return signal
        end
    end

    return nil
end

-- Switches the terminal to raw mode and the alternate screen.
-- Returns true, or nil plus an error message when there is no terminal to drive.
function Term.init()
    if Term.initialized then return true end
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
        Term.tty_fd = ffi.C.open("/dev/tty", O_RDWR)
        if Term.tty_fd < 0 then Term.tty_fd = 0 end

        -- Without a terminal there are no keys to read and nowhere to draw.
        if ffi.C.isatty(Term.tty_fd) == 0 then
            Term.tty_fd = -1
            return nil, "interactive mode needs a terminal. "
                .. "Use 'fkill --list' or 'fkill <PID>' instead."
        end

        Term.saved_signal_mask = block_terminating_signals()

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
    return true
end

-- Leaves the alternate screen and raw mode. Pass `keep_signals_blocked` when
-- exiting because of a signal: unblocking would deliver it and kill the process
-- before it can report why it stopped.
function Term.restore(keep_signals_blocked)
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

        if not keep_signals_blocked then
            restore_signal_mask(Term.saved_signal_mask)
        end
        Term.saved_signal_mask = nil
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

-- Escape sequences sent by special keys, keyed by their exact bytes.
local ESCAPE_SEQUENCE_KEYS = {
    ["\27[A"] = "UP",
    ["\27OA"] = "UP",
    ["\27[B"] = "DOWN",
    ["\27OB"] = "DOWN",
    ["\27[C"] = "RIGHT",
    ["\27OC"] = "RIGHT",
    ["\27[D"] = "LEFT",
    ["\27OD"] = "LEFT",
    ["\27[H"] = "HOME",
    ["\27[1~"] = "HOME",
    ["\27[F"] = "END",
    ["\27[4~"] = "END",
    ["\27[5~"] = "PGUP",
    ["\27[6~"] = "PGDN",
    ["\27[3~"] = "DELETE",
    ["\27[Z"] = "BACKTAB",
}
local MIN_ESCAPE_SEQUENCE_LENGTH = 3
local MAX_ESCAPE_SEQUENCE_LENGTH = 4

-- Single bytes that map to a named key instead of a literal character.
local SINGLE_BYTE_KEYS = {
    ["\27"] = "ESC",
    ["\n"] = "ENTER",
    ["\r"] = "ENTER",
    ["\t"] = "TAB",
    ["\127"] = "BACKSPACE",
    ["\8"] = "BACKSPACE",
    ["\2"] = "CTRL_B",
    ["\3"] = "CTRL_C",
    ["\4"] = "CTRL_D",
    ["\5"] = "CTRL_E",
    ["\6"] = "CTRL_F",
    ["\14"] = "CTRL_N",
    ["\16"] = "CTRL_P",
    ["\18"] = "CTRL_R",
    ["\21"] = "CTRL_U",
    ["\23"] = "CTRL_W",
    ["\25"] = "CTRL_Y",
    [" "] = "SPACE",
}

local ESCAPE_BYTE = 27

-- Returns the byte length of the UTF-8 character starting with `lead_byte`.
local function utf8_char_length(lead_byte)
    if lead_byte >= 0xF0 then return 4 end
    if lead_byte >= 0xE0 then return 3 end
    if lead_byte >= 0xC0 then return 2 end
    return 1
end

-- Decodes the key at `position` when it starts with ESC.
-- Returns key name and bytes consumed, or nil when the byte is not ESC.
local function decode_escape_sequence(bytes, position)
    if bytes:byte(position) ~= ESCAPE_BYTE then
        return nil
    end

    for length = MAX_ESCAPE_SEQUENCE_LENGTH, MIN_ESCAPE_SEQUENCE_LENGTH, -1 do
        local key = ESCAPE_SEQUENCE_KEYS[bytes:sub(position, position + length - 1)]
        if key then
            return key, length
        end
    end

    -- Unrecognised CSI / SS3 sequences are swallowed whole so their parameter
    -- bytes are not mistaken for typed characters.
    local control_sequence = bytes:match("^\27%[[0-?]*[ -/]*[@-~]", position)
        or bytes:match("^\27O.", position)
    if control_sequence then
        return "UNKNOWN", #control_sequence
    end

    -- ESC followed directly by another key is an Alt chord, not a request to
    -- leave the current mode. Only a lone ESC counts as the ESC key.
    local next_byte = bytes:byte(position + 1)
    if next_byte and next_byte ~= ESCAPE_BYTE then
        return "UNKNOWN", 1 + utf8_char_length(next_byte)
    end

    return "ESC", 1
end

-- Decodes the non-escape key at `position`. Returns key name and bytes consumed.
local function decode_plain_key(bytes, position)
    local length = utf8_char_length(bytes:byte(position))
    local character = bytes:sub(position, position + length - 1)

    return SINGLE_BYTE_KEYS[character] or character, #character
end

-- Splits raw terminal input into key names, so several keys delivered by one
-- read() (key repeat, fast typing, paste) are all kept. Returns a list of keys.
local function decode_keys(bytes)
    local keys = {}
    local position = 1

    while position <= #bytes do
        local key, consumed = decode_escape_sequence(bytes, position)
        if not key then
            key, consumed = decode_plain_key(bytes, position)
        end

        keys[#keys + 1] = key
        position = position + consumed
    end

    return keys
end

-- Blocks until a key is available and returns its name. Returns "EOF" when the
-- terminal is gone, "SIGNAL" when a terminating signal arrived (details in
-- Term.received_signal) and "NONE" when the read should simply be retried.
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
        if #Term.pending_keys == 0 then
            Term.read_buffer = Term.read_buffer or ffi.new("char[?]", READ_BUFFER_SIZE)
            Term.received_signal = pending_terminating_signal()
            if Term.received_signal then
                return "SIGNAL"
            end

            local input_fd = Term.tty_fd >= 0 and Term.tty_fd or 0
            if not wait_for_input(input_fd, RESIZE_POLL_INTERVAL_MS) then
                return "NONE"
            end

            local byte_count = ffi.C.read(input_fd, Term.read_buffer, READ_BUFFER_SIZE)

            if byte_count == 0 then
                return "EOF"
            end

            if byte_count < 0 then
                -- An interrupted read is retried; any other error (such as EIO
                -- after the terminal hangs up) will never recover.
                if ffi.errno() == EINTR then return "NONE" end
                return "EOF"
            end

            Term.pending_keys = decode_keys(ffi.string(Term.read_buffer, byte_count))
        end

        return table.remove(Term.pending_keys, 1) or "NONE"
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

-- Returns the number of terminal cells `s` occupies: colour codes take none and
-- each UTF-8 character takes one (fkill draws no double-width glyphs).
local function display_width(s)
    local plain = s:gsub("\27%[[%d;]*m", "")
    local _, continuation_byte_count = plain:gsub("[\128-\191]", "")
    return #plain - continuation_byte_count
end

-- Returns the first `char_count` UTF-8 characters of plain text `s`, never
-- splitting a multi-byte character.
local function utf8_prefix(s, char_count)
    local chars_seen = 0

    for index = 1, #s do
        local byte = s:byte(index)
        local starts_character = byte < 0x80 or byte >= 0xC0
        if starts_character then
            if chars_seen == char_count then
                return s:sub(1, index - 1)
            end
            chars_seen = chars_seen + 1
        end
    end

    return s
end

-- Pads `s` with spaces to `w` terminal cells. Never truncates: cutting a styled
-- string by bytes can split a colour code, and autowrap is off so an over-long
-- line is clipped by the terminal instead.
local function pad_right(s, w)
    local missing_cells = w - display_width(s)
    if missing_cells <= 0 then
        return s
    end

    return s .. string.rep(" ", missing_cells)
end

-- Shortens plain text `s` to at most `max_w` cells, ending with an ellipsis.
local function truncate(s, max_w)
    if not s then return "" end
    if display_width(s) <= max_w then return s end
    if max_w <= 1 then return utf8_prefix(s, max_w) end
    return utf8_prefix(s, max_w - 1) .. "…"
end

-- Replaces control bytes (including ESC) with "?" so text taken from another
-- process cannot move the cursor or restyle the screen.
local function sanitize_for_display(s)
    return (s:gsub("[%z\1-\31\127]", "?"))
end

-- Width in cells of every format_mem() result, so the MEM column stays aligned.
local MEM_COLUMN_WIDTH = 10

-- Largest value that "%5.1f" still prints in five characters.
local FIVE_DIGIT_LIMIT = 999.95

-- Formats a size in megabytes as a fixed-width pill such as "[372.2 MB]".
local function format_mem(mb)
    if not mb or mb <= 0 then
        return pad_right("     -", MEM_COLUMN_WIDTH)
    end

    if mb < 1 then
        return string.format("[%5d KB]", math.floor(mb * 1024))
    end

    -- Values that would print as "1000.0" need the next unit to keep five digits.
    if mb < FIVE_DIGIT_LIMIT then
        return string.format("[%5.1f MB]", mb)
    end

    local gb = mb / 1024
    if gb < FIVE_DIGIT_LIMIT then
        return string.format("[%5.1f GB]", gb)
    end

    return string.format("[%5.0f GB]", gb)
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

-- kthreadd is the parent of every Linux kernel thread.
local KTHREADD_PID = 2

-- Returns true for kthreadd and its children, which are not user applications.
local function is_kernel_thread(pid, ppid)
    return pid == KTHREADD_PID or ppid == KTHREADD_PID
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
            name = sanitize_for_display(v)
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
            cmd = sanitize_for_display(raw:gsub("%z", " "):gsub("%s+$", ""))
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
        is_system = SYSTEM_PROCS[name:lower()] == true or is_kernel_thread(pid, ppid),
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

-- Used when the terminal is too narrow for the full labels and a filter field.
local TAB_SHORT_LABELS = {
    all = "All",
    user = "User",
    heavy = "Heavy",
}

local SORT_MODES = { "mem", "pid", "name", "threads" }
local SORT_LABELS = {
    mem = "Memory (Desc)",
    pid = "PID (Asc)",
    name = "Name (Asc)",
    threads = "Threads (Desc)",
}

local FORCE_KILL_LABEL = IS_WINDOWS and "FORCE kill" or "FORCE kill (SIGKILL)"

-- Fixed cells of a process row before the name: pointer, checkbox, PID, memory
-- pill and thread count with their separators (1+1+3+1+7+1+10+1+4+2).
local LIST_FIXED_COLUMNS_WIDTH = 31

local HELP_KEY_COLUMN_WIDTH = 18

local HELP_SECTIONS = {
    {
        title = "NAVIGATION & MOTIONS",
        bindings = {
            { "j / k, ^n / ^p", "Move cursor down / up" },
            { "gg / G", "Jump to first / last process" },
            { "Ctrl-d / Ctrl-u", "Scroll half-page down / up" },
            { "Ctrl-f / Ctrl-b", "Scroll full-page down / up" },
            { "H / M / L", "Jump to High / Mid / Low screen" },
            { "zz / zt / zb", "Recenter: Middle / Top / Bottom" },
            { "Ctrl-e / Ctrl-y", "Scroll inspector card down / up" },
        },
    },
    {
        title = "SELECTION & PROCESS ACTIONS",
        bindings = {
            { "v / Tab / Space", "Toggle selection checkbox [x]" },
            { "d / Enter", "Terminate process (prompt)" },
            { "D / K", "Force kill (SIGKILL), asks y / Enter" },
            { "s / S", "Cycle sort mode (RAM/PID/Name)" },
            { "h / l, 1 / 2 / 3", "Switch tab: All / User / Heavy" },
            { "r / Ctrl-r", "Refresh process list & memory" },
            { "/", "Filter by name, PID or command" },
            { "?, q / Esc", "Close help / exit fkill" },
        },
    },
}

-- Returns the styled lines of the keybinding cheatsheet, one per screen row.
local function build_help_lines()
    local lines = {}

    for _, section in ipairs(HELP_SECTIONS) do
        lines[#lines + 1] = ""
        lines[#lines + 1] = C.b_yellow .. C.bold .. "  " .. section.title .. C.reset

        for _, binding in ipairs(section.bindings) do
            local keys = pad_right(binding[1], HELP_KEY_COLUMN_WIDTH)
            lines[#lines + 1] = "   " .. C.b_cyan .. keys .. C.reset .. " " .. binding[2]
        end
    end

    return lines
end

-- Kills each process in `targets` with `kill_process(pid, force)`.
-- Returns the list of PIDs that were signalled and a list of failures, each
-- { pid, name, reason }, so no individual error is lost in a batch.
local function kill_targets(targets, force, kill_process)
    local killed_pids = {}
    local failures = {}

    for _, target in ipairs(targets) do
        local ok, err = kill_process(target.pid, force)
        if ok then
            killed_pids[#killed_pids + 1] = target.pid
        else
            failures[#failures + 1] = {
                pid = target.pid,
                name = target.name,
                reason = err or "unknown error",
            }
        end
    end

    return killed_pids, failures
end

-- Builds the confirmation question for killing `targets`.
local function describe_kill_prompt(targets, force)
    local verb = force and FORCE_KILL_LABEL or "Kill"
    if #targets == 1 then
        return string.format("%s %s (PID: %d)?", verb, targets[1].name, targets[1].pid)
    end

    return string.format("%s %d selected process(es)?", verb, #targets)
end

-- Builds the status line after a kill. Returns the message and its status type
-- ("ok" or "error"). The first failure is always named with its system error.
local function describe_kill_result(killed_count, failures, force)
    local done_verb = force and "Force-killed" or "Terminated"
    if #failures == 0 then
        return string.format("%s %d process(es).", done_verb, killed_count), "ok"
    end

    local first = failures[1]
    local detail = string.format("PID %d (%s): %s", first.pid, first.name, first.reason)
    if #failures > 1 then
        detail = detail .. string.format(" (+%d more failed)", #failures - 1)
    end

    if killed_count == 0 and #failures == 1 then
        return "Failed to kill " .. detail, "error"
    end

    return string.format("%s %d, failed %d: %s", done_verb, killed_count, #failures, detail), "error"
end

-- Returns true when `key` answers "yes" to the kill prompt. A force kill needs
-- y or Enter; repeating the kill key (dd) only confirms a normal kill, so a
-- doubled K or D can never SIGKILL by accident.
local function is_confirm_key(key, is_force)
    if key == "y" or key == "Y" or key == "ENTER" then
        return true
    end

    return not is_force and (key == "d" or key == "D")
end

-- Limits a pane scroll offset so the last page of `line_count` lines stays in
-- view. Returns 0 when everything fits in `visible_rows`.
local function clamp_pane_scroll(scroll, line_count, visible_rows)
    local max_scroll = math.max(0, line_count - visible_rows)
    return math.max(0, math.min(scroll, max_scroll))
end

-- Returns a title suffix such as "  [6-14 of 14]" naming the visible lines of a
-- scrolled pane, or "" when all `line_count` lines fit in `visible_rows`.
local function describe_scroll_position(scroll, line_count, visible_rows)
    if line_count <= visible_rows then
        return ""
    end

    local first_line = scroll + 1
    local last_line = math.min(scroll + visible_rows, line_count)
    return string.format("  [%d-%d of %d]", first_line, last_line, line_count)
end

-- Score for a filter found literally in the command line. It sits below a name
-- substring match (about 1000) and above any realistic fuzzy name match.
local COMMAND_LINE_MATCH_SCORE = 700

-- Returns how well `proc` matches the filter text; 0 means no match. The name
-- and PID match fuzzily; the command line must contain the text literally,
-- because a fuzzy match against a long command line matches almost anything.
local function filter_match_score(filter, proc)
    local name_score = fuzzy_score(filter, proc.name) or 0
    local pid_score = fuzzy_score(filter, tostring(proc.pid)) or 0

    local command_score = 0
    local command_line = proc.cmd or ""
    if command_line:lower():find(filter:lower(), 1, true) then
        command_score = COMMAND_LINE_MATCH_SCORE
    end

    return math.max(name_score, pid_score, command_score)
end

-- Cells around the filter field on line 2: one leading space and one space
-- before the tab strip.
local SUBHEADER_MARGIN_WIDTH = 2

-- Narrowest filter field that still shows the "/ to filter" hint. Below this the
-- tab strip switches to short labels.
local MIN_FILTER_FIELD_WIDTH = 11

-- Narrowest field in which typing is still usable ("/", three characters and
-- the cursor). Below this the filter takes the whole line while typing.
local MIN_TYPING_FIELD_WIDTH = 5

local FILTER_CURSOR = "█"

-- Returns the styled tab strip, e.g. "[All Procs (328)] [User Apps (205)] ...",
-- with the active tab highlighted. `labels` maps tab ids to their captions.
local function build_tab_strip(tab_counts, active_index, labels)
    local tabs = {}

    for index, tab_id in ipairs(TABS) do
        local caption = string.format("[%s (%d)]", labels[tab_id], tab_counts[tab_id])
        local style = C.gray
        if index == active_index then
            style = C.inverse .. C.b_red
        end

        tabs[#tabs + 1] = style .. caption .. C.reset
    end

    return table.concat(tabs, " ")
end

-- Shortens `filter` to `cells` by keeping its end behind a leading ellipsis, so
-- the characters being typed stay visible. The filter is ASCII-only (the input
-- handler accepts printable ASCII), so bytes and cells are the same here.
local function fit_filter_tail(filter, cells)
    if #filter <= cells then
        return filter
    end

    if cells <= 0 then
        return ""
    end

    return "…" .. filter:sub(#filter - cells + 2)
end

-- Returns the filter text while the user is typing, always ending in the cursor.
local function build_typing_filter(filter, available_cells)
    local prompt = "Filter (/): "
    if available_cells < #prompt + 4 then
        prompt = "/"
    end

    local text_cells = available_cells - #prompt - 1
    if text_cells < 0 then
        return ""
    end

    local shown = fit_filter_tail(filter, text_cells)
    return C.b_yellow .. C.bold .. prompt .. C.b_white .. shown .. FILTER_CURSOR .. C.reset
end

-- Returns the filter text for an applied (non-empty) filter outside typing mode.
local function build_applied_filter(filter, available_cells)
    local prompt = "Filter: "
    local hint = " (Esc to clear)"
    if #prompt + #filter + #hint <= available_cells then
        return C.bold .. prompt .. C.b_white .. filter .. C.reset .. C.gray .. hint .. C.reset
    end

    local text_cells = available_cells - #prompt
    if text_cells < 1 then
        return ""
    end

    return C.bold .. prompt .. C.b_white .. fit_filter_tail(filter, text_cells) .. C.reset
end

-- Returns the hint shown when no filter is set: the longest variant that fits.
local function build_idle_filter(available_cells)
    local prompt = "Filter (/): "
    local hint = "(press / to filter)"
    if #prompt + #hint <= available_cells then
        return C.bold .. prompt .. C.gray .. hint .. C.reset
    end

    local short_hint = "/ to filter"
    if #short_hint <= available_cells then
        return C.gray .. short_hint .. C.reset
    end

    return ""
end

-- Returns the styled filter text that fits `available_cells` for the given
-- input mode ("filter" while typing) and filter string.
local function build_filter_display(mode, filter, available_cells)
    if mode == "filter" then
        return build_typing_filter(filter, available_cells)
    end

    if #filter > 0 then
        return build_applied_filter(filter, available_cells)
    end

    return build_idle_filter(available_cells)
end

-- Builds line 2: filter text on the left, tab strip right-aligned. The tabs are
-- shown whole and the filter text shrinks to the cells that remain. The one
-- exception is typing on a terminal too narrow for both: the tabs are hidden
-- until typing ends, because the text being typed must stay visible.
local function build_subheader_line(cols, state, tab_counts)
    local line_width = math.max(1, cols - 1)
    local tabs = build_tab_strip(tab_counts, state.tab_idx, TAB_LABELS)
    local needed_width = display_width(tabs) + SUBHEADER_MARGIN_WIDTH + MIN_FILTER_FIELD_WIDTH
    if needed_width > line_width then
        tabs = build_tab_strip(tab_counts, state.tab_idx, TAB_SHORT_LABELS)
    end

    local filter_width = math.max(0, line_width - display_width(tabs) - SUBHEADER_MARGIN_WIDTH)
    if state.mode == "filter" and filter_width < MIN_TYPING_FIELD_WIDTH then
        return " " .. build_typing_filter(state.filter, line_width - 1)
    end

    local filter_text = build_filter_display(state.mode, state.filter, filter_width)
    local gap_width = filter_width - display_width(filter_text)

    return " " .. filter_text .. string.rep(" ", gap_width) .. " " .. tabs
end

local function run_tui(init_opts)
    init_opts = init_opts or {}

    local terminal_ready, terminal_error = Term.init()
    if not terminal_ready then
        io.stderr:write("fkill: " .. terminal_error .. "\n")
        os.exit(EXIT_FAILURE)
    end

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
        confirm_is_force = false,
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
                    local score = filter_match_score(state.filter, p)
                    if score > 0 then
                        table.insert(list, { proc = p, score = score })
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
        local head_str = string.format(" %s%sfkill%s %s[%s]%s │ Host: %s%s%s │ Sort: %s%s%s",
            C.b_red, C.bold, C.reset,
            C.b_yellow, TAB_LABELS[TABS[state.tab_idx]], C.reset,
            C.b_white, hostname, C.reset,
            C.b_cyan, SORT_LABELS[SORT_MODES[state.sort_idx]], C.reset)
        add_line(C.bg_header .. pad_right(head_str, math.max(1, cols - 1)) .. C.reset)

        -- 2. Subheader Tabs & Filter
        local tab_counts = { all = cnt_all, user = cnt_user, heavy = cnt_heavy }
        add_line(build_subheader_line(cols, state, tab_counts))

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
        -- Below 90 columns there is no right pane, so help takes over the list.
        local show_help_in_list = (state.mode == "help" and cols < 90)
        local list_help_lines = show_help_in_list and build_help_lines() or {}

        -- Pre-load inspector content for right pane
        local r_lines = {}
        if cols >= 90 then
            if state.mode == "help" then
                r_lines = build_help_lines()
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

        -- Column header. Built after the pane content so it can show which lines
        -- of a scrolled inspector or cheatsheet are visible.
        local pane_lines = show_help_in_list and list_help_lines or r_lines
        state.preview_scroll = clamp_pane_scroll(state.preview_scroll, #pane_lines, body_h)
        local scroll_hint = describe_scroll_position(state.preview_scroll, #pane_lines, body_h)

        local raw_hdr = string.format("  %-3s %7s %-10s %4s  %s", "SEL", "PID", "MEM", "THR", "PROCESS NAME")
        if show_help_in_list then
            raw_hdr = "  VIM KEYBINDINGS CHEATSHEET" .. scroll_hint
        end
        local list_hdr = C.b_blue .. C.bold .. pad_right(raw_hdr, left_w) .. C.reset

        local right_title
        if state.mode == "help" then
            right_title = " VIM KEYBINDINGS CHEATSHEET"
        elseif cur_item then
            right_title = " PROCESS: " .. cur_item.name .. " (" .. cur_item.pid .. ")"
        else
            right_title = " PROCESS INSPECTOR"
        end
        local title_width = math.max(10, right_w - 2 - #scroll_hint)
        right_title = truncate(right_title, title_width) .. scroll_hint

        local right_hdr = (cols >= 90) and (C.b_white .. C.bold .. right_title .. C.reset) or ""
        local hdr_sep = (cols >= 90) and (C.gray .. "│" .. C.reset) or ""
        add_line(list_hdr .. " " .. hdr_sep .. " " .. right_hdr)

        -- 4. Body Rows
        for row = 1, body_h do
            local idx = state.scroll + row - 1
            local item = state.filtered[idx]
            local l_str

            if show_help_in_list then
                l_str = pad_right(list_help_lines[row + state.preview_scroll] or "", left_w)
            elseif item then
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
                local name_w = math.max(8, left_w - LIST_FIXED_COLUMNS_WIDTH)
                local name_disp = pad_right(truncate(item.name, name_w), name_w)
                local name_col = is_cur and (C.b_white .. C.bold) or (item.is_system and C.gray or C.white)
                local full_name_disp = name_col .. name_disp .. C.reset

                l_str = string.format("%s%s %s %s %s %s  %s", bg, ptr, chk, pid_disp, mem_pill, thr_disp, full_name_disp)
            elseif row == 1 and #state.filtered == 0 then
                local no_match = "  (No processes match current filter)"
                l_str = C.gray .. pad_right(no_match, left_w) .. C.reset
            else
                l_str = string.rep(" ", left_w)
            end

            local r_idx = row + state.preview_scroll
            local r_str = r_lines[r_idx] or ""
            local sep_char = (cols >= 90) and (C.gray .. "│" .. C.reset) or ""
            add_line(l_str .. " " .. sep_char .. " " .. r_str)
        end

        -- 5. Footer & Dialog Prompt
        local footer_sep = string.rep("─", math.max(1, cols - 1))
        add_line(C.gray .. footer_sep .. C.reset)

        local status_disp
        if state.mode == "help" then
            status_disp = C.b_yellow .. C.bold .. " [Help Mode] j/k or Ctrl-e/Ctrl-y scroll, any other key returns..." .. C.reset
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

        -- An idle tick: repaint (which picks up a resize) without touching state,
        -- so status messages and pending vim operators survive it.
        while key == "NONE" do
            render()
            key = Term.read_key()
        end

        if state.mode ~= "confirm_kill" then
            state.status_msg = ""
        end

        if key == "CTRL_C" then
            Term.restore()
            os.exit(0)
        end

        if key == "SIGNAL" then
            local signal = Term.received_signal
            Term.restore(true)
            io.stderr:write(string.format("fkill: received %s; terminal restored.\n", signal.name))
            os.exit(SIGNAL_EXIT_BASE + signal.number)
        end

        if key == "EOF" then
            Term.restore()
            io.stderr:write("fkill: terminal input closed; exiting.\n")
            os.exit(EXIT_FAILURE)
        end

        -- Help Mode: scroll keys move the cheatsheet, any other key closes it.
        -- The renderer clamps the offset to the cheatsheet's length.
        if state.mode == "help" then
            if key == "CTRL_E" or key == "j" or key == "DOWN" then
                state.preview_scroll = state.preview_scroll + 1
            elseif key == "CTRL_Y" or key == "k" or key == "UP" then
                state.preview_scroll = math.max(0, state.preview_scroll - 1)
            else
                state.mode = "normal"
                state.preview_scroll = 0
            end

        -- A. Confirm Kill Mode
        elseif state.mode == "confirm_kill" then
            if is_confirm_key(key, state.confirm_is_force) then
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
                state.preview_scroll = 0
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
                else
                    state.confirm_msg = describe_kill_prompt(targets, force)
                    state.confirm_is_force = force
                    state.confirm_callback = function()
                        local killed_pids, failures = kill_targets(targets, force, Backend.kill_process)
                        for _, killed_pid in ipairs(killed_pids) do
                            state.selected_set[killed_pid] = nil
                        end

                        state.status_msg, state.status_type =
                            describe_kill_result(#killed_pids, failures, force)
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

local EXIT_OK = 0
local EXIT_USAGE = 2

-- Largest PID any supported kernel hands out (signed 32-bit pid_t / DWORD range).
local MAX_PID = 2147483647

-- Linux truncates the "Name:" field of /proc/<pid>/status to this many characters.
local LINUX_NAME_MAX_LENGTH = 15

-- How many near-miss names to suggest when an exact name match finds nothing.
local MAX_NAME_SUGGESTIONS = 5

-- Returns the PID of this fkill process, so name matching can skip it.
local function current_pid()
    if IS_WINDOWS then
        return tonumber(ffi.C.GetCurrentProcessId())
    end

    return ffi.C.getpid()
end

-- Classifies one positional CLI argument.
-- Returns { kind = "pid", pid = n } or { kind = "name", name = s }, or nil plus an
-- error message. Only plain positive decimals count as PIDs: kill() gives 0 and
-- negative values group-wide and system-wide meanings that must never be reachable.
local function classify_target(text)
    if text == "" then
        return nil, "empty PID or process name"
    end

    if not text:match("^%d+$") then
        return { kind = "name", name = text }
    end

    local pid = tonumber(text)
    if pid < 1 then
        return nil, string.format("invalid PID '%s': PIDs start at 1", text)
    end

    if pid > MAX_PID then
        return nil, string.format("invalid PID '%s': larger than the maximum PID %d", text, MAX_PID)
    end

    return { kind = "pid", pid = pid }
end

-- Returns true when `process_name` is the process the user named. The match is
-- exact and case-insensitive; a substring match would kill unrelated processes.
local function process_name_matches(process_name, wanted_name)
    local actual = process_name:lower()
    local wanted = wanted_name:lower()
    if actual == wanted then
        return true
    end

    if IS_WINDOWS then
        return actual == wanted .. ".exe"
    end

    local is_truncated_by_kernel = #wanted > LINUX_NAME_MAX_LENGTH
    return is_truncated_by_kernel and actual == wanted:sub(1, LINUX_NAME_MAX_LENGTH)
end

-- Returns the processes in `procs` named `name`, never including `own_pid`.
local function find_processes_by_name(procs, name, own_pid)
    local matched = {}

    for _, proc in ipairs(procs) do
        if proc.pid ~= own_pid and process_name_matches(proc.name, name) then
            table.insert(matched, proc)
        end
    end

    return matched
end

-- Returns up to MAX_NAME_SUGGESTIONS distinct process names containing `name`,
-- used to guide the user after an exact match found nothing.
local function suggest_similar_names(procs, name, own_pid)
    local wanted = name:lower()
    local seen = {}
    local suggestions = {}

    for _, proc in ipairs(procs) do
        local is_candidate = proc.pid ~= own_pid and not seen[proc.name]
        if is_candidate and proc.name:lower():find(wanted, 1, true) then
            seen[proc.name] = true
            table.insert(suggestions, proc.name)
        end

        if #suggestions >= MAX_NAME_SUGGESTIONS then break end
    end

    return suggestions
end

-- Asks a yes/no question on stdin. Returns true or false, or nil when stdin is
-- closed (non-interactive use), so the caller can explain how to proceed.
local function confirm_on_stdin(question)
    io.write(question .. " [y/N]: ")
    io.flush()

    local answer = io.read("*line")
    if answer == nil then
        io.write("\n")
        io.flush()
        return nil
    end

    answer = trim(answer):lower()
    return answer == "y" or answer == "yes"
end

-- Kills one PID. Reports success on stdout and the system error on stderr.
-- Returns true when the process was signalled.
local function kill_pid_cli(pid, force)
    local ok, err = Backend.kill_process(pid, force)
    if ok then
        io.write(string.format("%s✔ Successfully killed PID %d%s\n", C.green, pid, C.reset))
        return true
    end

    io.stderr:write(string.format(
        "%s✘ Failed to kill PID %d: %s%s\n",
        C.red, pid, err or "unknown error", C.reset
    ))
    return false
end

-- Explains on stderr that no process is named exactly `name`.
local function report_no_name_match(procs, name, own_pid)
    io.stderr:write(string.format("fkill: no running process is named exactly '%s'\n", name))

    local suggestions = suggest_similar_names(procs, name, own_pid)
    if #suggestions > 0 then
        io.stderr:write("Similar names: " .. table.concat(suggestions, ", ") .. "\n")
    end
end

-- Kills every process named exactly `name` after listing them and, unless
-- `assume_yes` is set, asking for confirmation. Returns a process exit code.
local function kill_by_name_cli(name, force, assume_yes)
    local own_pid = current_pid()
    local procs = Backend.get_process_list()
    local matched = find_processes_by_name(procs, name, own_pid)

    if #matched == 0 then
        report_no_name_match(procs, name, own_pid)
        return EXIT_FAILURE
    end

    io.write(string.format("%sFound %d process(es) named '%s':%s\n", C.cyan, #matched, name, C.reset))
    for _, proc in ipairs(matched) do
        io.write(string.format("  %-8d %s\n", proc.pid, truncate(proc.cmd or proc.name, 70)))
    end

    if not assume_yes then
        local confirmed = confirm_on_stdin(string.format("Kill %d process(es)?", #matched))
        if confirmed == nil then
            io.stderr:write("fkill: no confirmation available on stdin; nothing was killed. "
                .. "Use -y to kill by name without a prompt.\n")
            return EXIT_FAILURE
        end

        if not confirmed then
            io.stderr:write("fkill: cancelled; nothing was killed.\n")
            return EXIT_FAILURE
        end
    end

    local exit_code = EXIT_OK
    for _, proc in ipairs(matched) do
        if not kill_pid_cli(proc.pid, force) then
            exit_code = EXIT_FAILURE
        end
    end

    return exit_code
end

-- Kills every validated target from the command line. Keeps going after a
-- failure so one dead PID does not hide the others. Returns a process exit code.
local function kill_targets_cli(targets, force, assume_yes)
    local exit_code = EXIT_OK

    for _, target in ipairs(targets) do
        local target_exit_code = EXIT_OK
        if target.kind == "pid" then
            if not kill_pid_cli(target.pid, force) then
                target_exit_code = EXIT_FAILURE
            end
        else
            target_exit_code = kill_by_name_cli(target.name, force, assume_yes)
        end

        exit_code = math.max(exit_code, target_exit_code)
    end

    return exit_code
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

-- Explains why a dash-prefixed argument was rejected. Signal numbers and
-- negative PIDs get their own message because `kill -15 <pid>` is a common habit.
local function describe_unknown_option(option)
    if option:match("^%-%d+$") then
        return string.format(
            "unsupported option '%s': fkill takes no signal numbers or negative PIDs "
                .. "(use -9 to force kill)",
            option
        )
    end

    return string.format("unknown option '%s' (use -- before a process name that starts with '-')", option)
end

-- Validates `text` as a kill target and appends it to `targets`.
-- Returns true, or nil plus an error message.
local function add_target(targets, text)
    local target, err = classify_target(text)
    if not target then
        return nil, err
    end

    table.insert(targets, target)
    return true
end

-- Parses the command line without side effects, so nothing is killed unless
-- every argument is valid. Returns an options table:
--   { action = "tui"|"help"|"test"|"list"|"preview"|"fzf"|"kill",
--     force, assume_yes, targets, preview_pid }
-- or nil plus an error message.
local function parse_cli(args)
    local opts = {
        action = "tui",
        force = false,
        assume_yes = false,
        targets = {},
    }
    local only_targets_remain = false
    local index = 1

    while index <= #args do
        local arg = args[index]
        local ok, err = true, nil

        -- Kill targets
        if only_targets_remain or arg:sub(1, 1) ~= "-" then
            ok, err = add_target(opts.targets, arg)
        elseif arg == "--" then
            only_targets_remain = true

        -- Modifiers
        elseif arg == "-9" or arg == "-f" or arg == "--force" then
            opts.force = true
        elseif arg == "-y" or arg == "--yes" then
            opts.assume_yes = true

        -- Standalone actions: the first one wins, as before
        elseif arg == "-h" or arg == "--help" then
            opts.action = "help"
            return opts
        elseif arg == "--test" then
            opts.action = "test"
            return opts
        elseif arg == "-l" or arg == "--list" then
            opts.action = "list"
            return opts
        elseif arg == "--fzf" then
            opts.action = "fzf"
            return opts
        elseif arg == "-p" or arg == "--preview" then
            local preview = classify_target(args[index + 1] or "")
            if not preview or preview.kind ~= "pid" then
                return nil, string.format("%s requires a numeric PID argument", arg)
            end
            opts.action = "preview"
            opts.preview_pid = preview.pid
            return opts
        else
            ok, err = nil, describe_unknown_option(arg)
        end

        if not ok then
            return nil, err
        end
        index = index + 1
    end

    if #opts.targets > 0 then
        opts.action = "kill"
    elseif opts.force or opts.assume_yes then
        return nil, "-9/--force and -y/--yes need a PID or process name to kill"
    end

    return opts
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

    -- Test 8: CLI target validation (nothing here may ever reach kill())
    assert_eq("target plain PID accepted", classify_target("1234").pid, 1234)
    assert_eq("target name classified as name", classify_target("bash").kind, "name")
    assert_eq("target PID 0 rejected", classify_target("0"), nil)
    assert_eq("target PID 000 rejected", classify_target("000"), nil)
    assert_eq("target oversized PID rejected", classify_target("99999999999"), nil)
    assert_eq("target empty rejected", classify_target(""), nil)
    assert_eq("target hex is a name, not a PID", classify_target("0x10").kind, "name")
    assert_eq("target exponent is a name, not a PID", classify_target("1e3").kind, "name")
    assert_eq("target fraction is a name, not a PID", classify_target("1.9").kind, "name")

    -- Test 9: CLI parser
    assert_eq("parse no args opens TUI", parse_cli({}).action, "tui")
    assert_eq("parse -1 rejected", parse_cli({ "-1" }), nil)
    assert_eq("parse -15 PID rejected", parse_cli({ "-15", "1234" }), nil)
    assert_eq("parse unknown option rejected", parse_cli({ "--bogus" }), nil)
    assert_eq("parse PID 0 rejected", parse_cli({ "0" }), nil)
    assert_eq("parse bad target rejects whole line", parse_cli({ "1234", "0" }), nil)
    assert_eq("parse lone -9 rejected", parse_cli({ "-9" }), nil)
    assert_eq("parse lone -y rejected", parse_cli({ "-y" }), nil)
    assert_eq("parse --preview without PID rejected", parse_cli({ "--preview", "abc" }), nil)
    assert_eq("parse --preview PID", parse_cli({ "-p", "42" }).preview_pid, 42)
    assert_eq("parse --list", parse_cli({ "--list" }).action, "list")

    local kill_opts = parse_cli({ "1234", "bash", "-9", "-y" })
    assert_eq("parse kill action", kill_opts.action, "kill")
    assert_eq("parse force after target honored", kill_opts.force, true)
    assert_eq("parse yes after target honored", kill_opts.assume_yes, true)
    assert_eq("parse collects every target", #kill_opts.targets, 2)

    local dash_opts = parse_cli({ "--", "-odd-name" })
    assert_eq("parse -- allows dash-prefixed name", dash_opts.targets[1].name, "-odd-name")
    assert_eq("parse -- never yields negative PID", parse_cli({ "--", "-1" }).targets[1].kind, "name")

    -- Test 10: exact process-name matching
    assert_eq("name match exact", process_name_matches("bash", "bash"), true)
    assert_eq("name match ignores case", process_name_matches("Bash", "bASH"), true)
    assert_eq("name match rejects substring", process_name_matches("bash", "a"), false)
    assert_eq("name match rejects prefix", process_name_matches("luajit", "lua"), false)

    local fake_procs = {
        { pid = 10, name = "luajit" },
        { pid = 11, name = "luajit" },
        { pid = 12, name = "lua" },
    }
    assert_eq("find by name excludes own PID", #find_processes_by_name(fake_procs, "luajit", 10), 1)
    assert_eq("find by name is exact", find_processes_by_name(fake_procs, "lua", 10)[1].pid, 12)
    assert_eq("suggestions list distinct names", #suggest_similar_names(fake_procs, "lu", 10), 2)

    -- Test 14: display width and fixed-width columns
    local styled = C.b_red .. C.bold .. "fkill" .. C.reset .. " │ é"
    assert_eq("display_width ignores colour codes and counts UTF-8 chars", display_width(styled), 9)
    assert_eq("pad_right pads styled text by cells", display_width(pad_right(styled, 20)), 20)
    assert_eq("pad_right never truncates", pad_right("abcdef", 3), "abcdef")
    assert_eq("truncate keeps UTF-8 characters whole", truncate("ééééé", 3), "éé…")
    assert_eq("truncate result fits the width", display_width(truncate("ééééé", 3)), 3)
    assert_eq("truncate leaves fitting UTF-8 text alone", truncate("ééé", 3), "ééé")

    for _, megabytes in ipairs({ 0, 0.5, 2.3, 98.4, 372.2, 999.96, 1023.9, 20480, 2000000 }) do
        assert_eq(string.format("format_mem(%s) is %d cells", megabytes, MEM_COLUMN_WIDTH),
            #format_mem(megabytes), MEM_COLUMN_WIDTH)
    end

    local list_header = string.format("  %-3s %7s %-10s %4s  %s", "SEL", "PID", "MEM", "THR", "")
    assert_eq("list header matches row fixed width", #list_header, LIST_FIXED_COLUMNS_WIDTH)

    for _, help_line in ipairs(build_help_lines()) do
        if display_width(help_line) > 78 then
            assert_eq("help line fits an 80-column terminal", help_line, "<= 78 cells")
        end
    end
    assert_eq("help lines cover both sections", #build_help_lines(), 19)

    -- Test 15: process text sanitising and kernel threads
    assert_eq("sanitize strips ESC sequences", sanitize_for_display("a\27[2Jb\7"), "a?[2Jb?")
    assert_eq("sanitize keeps UTF-8 text", sanitize_for_display("café --flag"), "café --flag")
    assert_eq("kthreadd is a kernel thread", is_kernel_thread(2, 0), true)
    assert_eq("child of kthreadd is a kernel thread", is_kernel_thread(57, 2), true)
    assert_eq("init child is not a kernel thread", is_kernel_thread(900, 1), false)

    -- Test 16: line 2 always fits and always shows every tab whole
    local sub_counts = { all = 328, user = 205, heavy = 22 }
    local sub_states = {
        { mode = "normal", filter = "", tab_idx = 2 },
        { mode = "normal", filter = "claude", tab_idx = 1 },
        { mode = "normal", filter = string.rep("x", 100), tab_idx = 3 },
        { mode = "filter", filter = "", tab_idx = 2 },
        { mode = "filter", filter = string.rep("y", 95) .. "_tail", tab_idx = 2 },
    }
    local overflow_count = 0
    local clipped_tab_count = 0
    local lost_cursor_count = 0
    for sub_cols = 40, 200 do
        for _, sub_state in ipairs(sub_states) do
            local line = build_subheader_line(sub_cols, sub_state, sub_counts)
            local plain = line:gsub("\27%[[%d;]*m", "")
            if display_width(line) > sub_cols - 1 then
                overflow_count = overflow_count + 1
            end
            local shows_first_tab = plain:find("[All", 1, true) ~= nil
            local shows_last_tab = plain:find("(22)]", 1, true) ~= nil
            local tabs_hidden_for_typing = sub_state.mode == "filter" and not shows_first_tab
            if not tabs_hidden_for_typing and not (shows_first_tab and shows_last_tab) then
                clipped_tab_count = clipped_tab_count + 1
            end
            if sub_state.mode == "filter" and not plain:find("█", 1, true) then
                lost_cursor_count = lost_cursor_count + 1
            end
        end
    end
    assert_eq("subheader never exceeds cols - 1 (40..200)", overflow_count, 0)
    assert_eq("subheader never shows a clipped tab strip", clipped_tab_count, 0)
    assert_eq("subheader 40 cols typing hides tabs for the filter",
        (build_subheader_line(40, sub_states[4], sub_counts):gsub("\27%[[%d;]*m", "")), " Filter (/): █")
    assert_eq("subheader keeps the typing cursor visible", lost_cursor_count, 0)

    local function plain_subheader(sub_cols, sub_state)
        return (build_subheader_line(sub_cols, sub_state, sub_counts):gsub("\27%[[%d;]*m", ""))
    end
    assert_eq("subheader 120 cols keeps full hint",
        plain_subheader(120, sub_states[1]):find("Filter (/): (press / to filter)", 1, true), 2)
    assert_eq("subheader 80 cols uses short hint",
        plain_subheader(80, sub_states[1]):find("/ to filter", 1, true), 2)
    assert_eq("subheader 80 cols keeps full tab labels",
        plain_subheader(80, sub_states[1]):find("[Heavy / RAM (22)]", 1, true) ~= nil, true)
    assert_eq("subheader 60 cols uses short tab labels",
        plain_subheader(60, sub_states[1]):find("[Heavy (22)]", 1, true) ~= nil, true)
    assert_eq("subheader long typed filter keeps its tail",
        plain_subheader(80, sub_states[5]):find("_tail█", 1, true) ~= nil, true)
    assert_eq("fit_filter_tail exact width", display_width(fit_filter_tail("abcdefghij", 5)), 5)

    -- Test 17: blocked terminating signals are detected instead of killing fkill
    if not IS_WINDOWS then
        local previous_mask = block_terminating_signals()
        assert_eq("no signal pending at start", pending_terminating_signal(), nil)

        for _, signal in ipairs(TERMINATING_SIGNALS) do
            ffi.C.kill(ffi.C.getpid(), signal.number)
            local detected = pending_terminating_signal()
            assert_eq(signal.name .. " detected while blocked", detected and detected.name, signal.name)

            -- Consume the signal so it is not delivered when the mask is restored.
            local only_this_signal = ffi.new("fkill_sigset_t")
            ffi.C.sigemptyset(only_this_signal)
            ffi.C.sigaddset(only_this_signal, signal.number)
            ffi.C.sigwait(only_this_signal, ffi.new("int[1]"))
        end

        assert_eq("no signal pending after consuming", pending_terminating_signal(), nil)
        restore_signal_mask(previous_mask)
    end

    -- Test 18: filter matches name, PID and command line, in that priority
    local script_proc = { pid = 4321, name = "python3", cmd = "python3 /opt/jobs/Report_Job.py --fast" }
    local named_proc = { pid = 77, name = "report_job", cmd = "/usr/bin/report_job" }
    local fuzzy_proc = { pid = 88, name = "rxexpxoxrxt", cmd = "/usr/bin/other" }
    assert_eq("filter finds script name in command line", filter_match_score("report_job", script_proc) > 0, true)
    assert_eq("filter command line match ignores case", filter_match_score("REPORT_job", script_proc) > 0, true)
    assert_eq("filter name match outranks command line match",
        filter_match_score("report_job", named_proc) > filter_match_score("report_job", script_proc), true)
    assert_eq("filter command line match outranks fuzzy name match",
        filter_match_score("report", script_proc) > filter_match_score("report", fuzzy_proc), true)
    assert_eq("filter fuzzy name match still works", filter_match_score("report", fuzzy_proc) > 0, true)
    assert_eq("filter rejects scattered letters in command line", filter_match_score("pjfx", script_proc), 0)
    assert_eq("filter treats pattern characters literally", filter_match_score("jobs/Rep.rt", script_proc), 0)
    assert_eq("filter still matches PID", filter_match_score("4321", script_proc) > 0, true)
    assert_eq("filter no match is zero", filter_match_score("zzzz", script_proc), 0)
    assert_eq("filter tolerates missing command line", filter_match_score("zz", { pid = 1, name = "init" }), 0)

    -- Test 19: pane scroll clamping and position hint
    assert_eq("scroll clamps to 0 when content fits", clamp_pane_scroll(30, 8, 10), 0)
    assert_eq("scroll clamps to the last page", clamp_pane_scroll(30, 14, 9), 5)
    assert_eq("scroll keeps an in-range offset", clamp_pane_scroll(3, 14, 9), 3)
    assert_eq("scroll never goes negative", clamp_pane_scroll(-4, 14, 9), 0)
    assert_eq("scroll with empty pane", clamp_pane_scroll(2, 0, 9), 0)
    assert_eq("scroll hint empty when content fits", describe_scroll_position(0, 9, 9), "")
    assert_eq("scroll hint at the top", describe_scroll_position(0, 14, 9), "  [1-9 of 14]")
    assert_eq("scroll hint at the bottom", describe_scroll_position(5, 14, 9), "  [6-14 of 14]")

    -- Test 11: key decoding keeps every key from one read()
    local function decoded(bytes)
        return table.concat(decode_keys(bytes), ",")
    end
    assert_eq("keys repeated j all kept", decoded("jjj"), "j,j,j")
    assert_eq("keys pasted text all kept", decoded("bash"), "b,a,s,h")
    assert_eq("keys two arrows in one read", decoded("\27[A\27[B"), "UP,DOWN")
    assert_eq("keys arrow then letter", decoded("\27OAj"), "UP,j")
    assert_eq("keys four-byte sequence", decoded("\27[5~\27[6~"), "PGUP,PGDN")
    assert_eq("keys lone ESC", decoded("\27"), "ESC")
    assert_eq("keys double ESC", decoded("\27\27"), "ESC,ESC")
    assert_eq("keys Alt chord is not ESC", decoded("\27q"), "UNKNOWN")
    assert_eq("keys unknown CSI swallowed whole", decoded("\27[1;5Aj"), "UNKNOWN,j")
    assert_eq("keys control bytes named", decoded("\r\t \127\4"), "ENTER,TAB,SPACE,BACKSPACE,CTRL_D")
    assert_eq("keys UTF-8 char stays one key", #decode_keys("é/"), 2)
    assert_eq("keys empty input", #decode_keys(""), 0)

    -- Test 12: kill result reporting keeps every failure
    local function fake_kill(pid)
        if pid == 1 then
            return false, "Operation not permitted"
        end
        return true
    end
    local kill_list = {
        { pid = 100, name = "sleep" },
        { pid = 1, name = "systemd" },
        { pid = 101, name = "sleep" },
    }
    local killed_pids, kill_failures = kill_targets(kill_list, false, fake_kill)
    assert_eq("kill_targets counts successes", #killed_pids, 2)
    assert_eq("kill_targets records failure PID", kill_failures[1].pid, 1)
    assert_eq("kill_targets records failure reason", kill_failures[1].reason, "Operation not permitted")

    assert_eq("result mixed names the failure",
        (describe_kill_result(2, kill_failures, false)),
        "Terminated 2, failed 1: PID 1 (systemd): Operation not permitted")
    assert_eq("result all failed names the failure",
        (describe_kill_result(0, kill_failures, true)),
        "Failed to kill PID 1 (systemd): Operation not permitted")
    assert_eq("result failure is an error", select(2, describe_kill_result(2, kill_failures, false)), "error")
    assert_eq("result success", (describe_kill_result(3, {}, true)), "Force-killed 3 process(es).")

    -- Test 13: kill confirmation
    assert_eq("prompt normal single", describe_kill_prompt({ kill_list[1] }, false), "Kill sleep (PID: 100)?")
    assert_eq("prompt force says FORCE", describe_kill_prompt(kill_list, true):find("FORCE kill", 1, true), 1)
    assert_eq("confirm y accepts force", is_confirm_key("y", true), true)
    assert_eq("confirm Enter accepts force", is_confirm_key("ENTER", true), true)
    assert_eq("confirm doubled K rejected", is_confirm_key("K", true), false)
    assert_eq("confirm doubled D rejected for force", is_confirm_key("D", true), false)
    assert_eq("confirm dd accepts normal kill", is_confirm_key("d", false), true)

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
  -y, --yes            Kill by name without asking for confirmation
  -l, --list           Print formatted process table to stdout and exit
  -p, --preview <PID>  Print rich process details card to stdout and exit
  --fzf                Launch legacy fzf pipeline mode
  --test               Run built-in automated self-tests and exit
  -h, --help           Show this help message
  --                   Treat every following argument as a PID or name

Direct kill:
  fkill 1234 5678      Kill by PID (positive decimal numbers only)
  fkill firefox        Kill processes named exactly 'firefox', after confirmation
  fkill -9 -y firefox  Force kill by name without a prompt (for scripts)

Exit status:
  0 killed everything requested; 1 a kill failed, nothing matched, or the
  confirmation was declined; 2 invalid command line (nothing was killed).

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
  D / K                     Force kill (SIGKILL), confirmed with y / Enter
  h / l, 1 / 2 / 3          Switch context tab (All / User / Heavy)
  s / S                     Cycle sort mode (Memory / PID / Name / Threads)
  /                         Filter by name, PID or command line (Ctrl-w deletes a word)
  r / Ctrl-r                Refresh processes and memory
  ?                         Toggle built-in Vim Cheatsheet modal
  q / Esc                   Exit fkill]])
end

--------------------------------------------------------------------------------
-- 9. Entry Point & CLI Parser
--------------------------------------------------------------------------------
local cli_opts, cli_error = parse_cli({ ... })
if not cli_opts then
    io.stderr:write(string.format("fkill: %s\nTry 'fkill --help' for usage.\n", cli_error))
    os.exit(EXIT_USAGE)
end

if cli_opts.action == "help" then
    show_help()
    os.exit(EXIT_OK)
elseif cli_opts.action == "test" then
    run_tests()
    os.exit(EXIT_OK)
elseif cli_opts.action == "list" then
    print_list()
    os.exit(EXIT_OK)
elseif cli_opts.action == "preview" then
    render_preview(cli_opts.preview_pid)
    os.exit(EXIT_OK)
elseif cli_opts.action == "fzf" then
    legacy_fzf()
    os.exit(EXIT_OK)
elseif cli_opts.action == "kill" then
    os.exit(kill_targets_cli(cli_opts.targets, cli_opts.force, cli_opts.assume_yes))
end

local opts = {
    start_tab = 2, -- Default to User Apps
    filter = "",
}
-- Restores the terminal before reporting a crash, so the traceback is readable
-- and the shell is not left in raw mode on the alternate screen.
local function report_tui_crash(err)
    Term.restore()
    io.stderr:write("fkill: internal error; terminal restored.\n")
    io.stderr:write(debug.traceback(tostring(err), 2) .. "\n")
end

if not xpcall(run_tui, report_tui_crash, opts) then
    os.exit(EXIT_FAILURE)
end
