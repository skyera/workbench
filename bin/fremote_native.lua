-- Native nonblocking child pipes and terminal support. No shell on the client.

local ffi, bit = require('ffi'), require('bit')
local native = { windows = ffi.os == 'Windows' }

--------------------------------------------------------------------------------
-- FFI Constants & Platform Settings
--------------------------------------------------------------------------------

local UTF8_CODE_PAGE = 65001
local INVALID_UTF8_IS_ERROR = 8
local FORMAT_MESSAGE_FLAGS = 0x1200 -- FROM_SYSTEM | IGNORE_INSERTS
local HANDLE_FLAG_INHERIT = 1
local STARTF_USESTDHANDLES = 0x100
local CREATE_NO_WINDOW = 0x08000000
local ENABLE_VIRTUAL_TERMINAL_PROCESSING = 4
local DISABLED_WINDOWS_INPUT_MODES = 0x2 + 0x4 + 0x8 -- LINE_INPUT | ECHO_INPUT | WINDOW_INPUT
local STD_INPUT_HANDLE = -10
local STD_OUTPUT_HANDLE = -11
local STD_ERROR_HANDLE = -12

local CLOCK_MONOTONIC = 1
local F_GETFL = 3
local F_SETFL = 4
local O_NONBLOCK = 0x800
local POLLIN = 1
local POLLOUT = 4
local POLL_ERROR_OR_HANGUP = 0x18 -- POLLERR | POLLHUP
local SIGPIPE = 13
local SIGKILL = 9
local WNOHANG = 1
local DISABLED_POSIX_LOCAL_MODES = 0x1 + 0x2 + 0x8 -- ISIG | ICANON | ECHO
local TIOCGWINSZ = 0x5413

--------------------------------------------------------------------------------
-- Platform FFI C Declarations
--------------------------------------------------------------------------------

-- Native declarations remain grouped by platform to preserve their ABI layout.
if native.windows then
    ffi.cdef([[
        typedef void *HANDLE;
        typedef unsigned long DWORD;
        typedef int BOOL;
        typedef struct { DWORD nLength; void *lpSecurityDescriptor; BOOL bInheritHandle; } SECURITY_ATTRIBUTES;
        typedef struct {
            DWORD cb; wchar_t *lpReserved; wchar_t *lpDesktop; wchar_t *lpTitle;
            DWORD dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
            unsigned short wShowWindow, cbReserved2; unsigned char *lpReserved2;
            HANDLE hStdInput, hStdOutput, hStdError;
        } STARTUPINFOW;
        typedef struct { HANDLE hProcess, hThread; DWORD dwProcessId, dwThreadId; } PROCESS_INFORMATION;
        typedef struct { short X, Y; } COORD;
        typedef struct { short Left, Top, Right, Bottom; } SMALL_RECT;
        typedef struct { COORD dwSize, dwCursorPosition; unsigned short wAttributes;
            SMALL_RECT srWindow; COORD dwMaximumWindowSize; } CONSOLE_SCREEN_BUFFER_INFO;
        BOOL CreatePipe(HANDLE *, HANDLE *, SECURITY_ATTRIBUTES *, DWORD);
        BOOL SetHandleInformation(HANDLE, DWORD, DWORD);
        BOOL GetHandleInformation(HANDLE, DWORD *);
        BOOL CreateProcessW(const wchar_t *, wchar_t *, void *, void *, BOOL, DWORD, void *, const wchar_t *, STARTUPINFOW *, PROCESS_INFORMATION *);
        BOOL CloseHandle(HANDLE);
        BOOL ReadFile(HANDLE, void *, DWORD, DWORD *, void *);
        BOOL WriteFile(HANDLE, const void *, DWORD, DWORD *, void *);
        BOOL PeekNamedPipe(HANDLE, void *, DWORD, DWORD *, DWORD *, DWORD *);
        BOOL GetExitCodeProcess(HANDLE, DWORD *);
        DWORD WaitForSingleObject(HANDLE, DWORD);
        BOOL TerminateProcess(HANDLE, unsigned int);
        DWORD GetLastError(void);
        DWORD FormatMessageW(DWORD, const void *, DWORD, DWORD, wchar_t *, DWORD, void *);
        int MultiByteToWideChar(unsigned int, DWORD, const char *, int, wchar_t *, int);
        int WideCharToMultiByte(unsigned int, DWORD, const wchar_t *, int, char *, int, const char *, BOOL *);
        HANDLE GetStdHandle(DWORD);
        BOOL GetConsoleMode(HANDLE, DWORD *);
        BOOL SetConsoleMode(HANDLE, DWORD);
        BOOL GetConsoleScreenBufferInfo(HANDLE, CONSOLE_SCREEN_BUFFER_INFO *);
        unsigned int GetConsoleOutputCP(void);
        unsigned int GetConsoleCP(void);
        BOOL SetConsoleOutputCP(unsigned int);
        BOOL SetConsoleCP(unsigned int);
        unsigned long long GetTickCount64(void);
        void Sleep(DWORD);
        int _kbhit(void);
        int _getch(void);
    ]])
    native.crt = ffi.load('msvcrt')
else
    if ffi.os ~= 'Linux' then
        error('fremote currently supports Windows and Linux clients')
    end
    ffi.cdef([[
        int pipe(int *); int fork(void); int dup2(int, int); int close(int);
        int execvp(const char *, char *const *); void _exit(int);
        void (*signal(int, void (*)(int)))(int);
        long read(int, void *, size_t); long write(int, const void *, size_t);
        int fcntl(int, int, ...); int waitpid(int, int *, int); int kill(int, int);
        char *strerror(int); int usleep(unsigned int); int isatty(int);
        struct pollfd { int fd; short events, revents; };
        int poll(struct pollfd *, unsigned long, int);
        struct timespec { long tv_sec, tv_nsec; };
        int clock_gettime(int, struct timespec *);
        struct termios { unsigned int c_iflag,c_oflag,c_cflag,c_lflag;
            unsigned char c_line,c_cc[32]; unsigned int c_ispeed,c_ospeed; };
        int tcgetattr(int, struct termios *); int tcsetattr(int,int,const struct termios *);
        struct winsize { unsigned short ws_row,ws_col,ws_xpixel,ws_ypixel; };
        int ioctl(int,unsigned long,...);
    ]])
end

--------------------------------------------------------------------------------
-- Platform Utility Helpers
--------------------------------------------------------------------------------

local function wide(value)
    local count =
        ffi.C.MultiByteToWideChar(UTF8_CODE_PAGE, INVALID_UTF8_IS_ERROR, value, #value, nil, 0)
    if count == 0 then
        error('Cannot encode process argument as UTF-16')
    end

    local buffer = ffi.new('wchar_t[?]', count + 1)
    assert(
        ffi.C.MultiByteToWideChar(
            UTF8_CODE_PAGE,
            INVALID_UTF8_IS_ERROR,
            value,
            #value,
            buffer,
            count
        ) ~= 0
    )

    return buffer
end

function native.error(code)
    if not native.windows then
        return ffi.string(ffi.C.strerror(code or ffi.errno()))
    end

    code = code or ffi.C.GetLastError()
    local buffer = ffi.new('wchar_t[2048]')
    local count = ffi.C.FormatMessageW(FORMAT_MESSAGE_FLAGS, nil, code, 0, buffer, 2048, nil)
    if count == 0 then
        return 'Windows error ' .. tonumber(code)
    end

    local size = ffi.C.WideCharToMultiByte(UTF8_CODE_PAGE, 0, buffer, count, nil, 0, nil, nil)
    local out = ffi.new('char[?]', size)
    ffi.C.WideCharToMultiByte(UTF8_CODE_PAGE, 0, buffer, count, out, size, nil, nil)

    return ffi.string(out, size):gsub('%s+$', '') .. ' (Windows error ' .. tonumber(code) .. ')'
end

function native.quote(value)
    return '"'
        .. value
            :gsub('(\\*)"', function(backslashes)
                return backslashes .. backslashes .. '\\"'
            end)
            :gsub('(\\+)$', '%1%1')
        .. '"'
end

function native.now()
    if native.windows then
        return tonumber(ffi.C.GetTickCount64()) / 1000
    end

    local clock_time = ffi.new('struct timespec')
    ffi.C.clock_gettime(CLOCK_MONOTONIC, clock_time)

    return tonumber(clock_time.tv_sec) + tonumber(clock_time.tv_nsec) / 1e9
end

function native.sleep(ms)
    if native.windows then
        ffi.C.Sleep(ms)
    else
        ffi.C.usleep(ms * 1000)
    end
end

--------------------------------------------------------------------------------
-- Child Process Ownership & Pipe I/O
--------------------------------------------------------------------------------

local Child = {}
Child.__index = Child

function native.spawn(args)
    local child = setmetatable({}, Child)

    if native.windows then
        local handles = {}

        local function fail(message)
            local reason = native.error()
            for _, handle in ipairs(handles) do
                ffi.C.CloseHandle(handle)
            end
            return nil, message .. ': ' .. reason
        end

        local security_attributes = ffi.new('SECURITY_ATTRIBUTES')
        security_attributes.nLength, security_attributes.bInheritHandle =
            ffi.sizeof(security_attributes), 1

        local function pipe()
            local read_handle, write_handle = ffi.new('HANDLE[1]'), ffi.new('HANDLE[1]')
            if ffi.C.CreatePipe(read_handle, write_handle, security_attributes, 0) == 0 then
                return nil
            end
            handles[#handles + 1], handles[#handles + 2] = read_handle[0], write_handle[0]
            return read_handle[0], write_handle[0]
        end

        local input, writer = pipe()
        if not input then
            return fail('Cannot create stdin pipe')
        end

        local reader, output = pipe()
        if not reader then
            return fail('Cannot create stdout pipe')
        end

        local errreader, errwriter = pipe()
        if not errreader then
            return fail('Cannot create stderr pipe')
        end

        -- Ensure parent ends are not inherited by the child process
        for _, handle in ipairs({ writer, reader, errreader }) do
            if ffi.C.SetHandleInformation(handle, HANDLE_FLAG_INHERIT, 0) == 0 then
                return fail('Cannot protect parent pipe')
            end
        end

        -- Verify child ends are inheritable
        for _, handle in ipairs({ input, output, errwriter }) do
            local flags = ffi.new('DWORD[1]')
            if ffi.C.GetHandleInformation(handle, flags) == 0 then
                return fail('Cannot inspect child pipe')
            end
            if bit.band(flags[0], HANDLE_FLAG_INHERIT) == 0 then
                for _, h in ipairs(handles) do
                    ffi.C.CloseHandle(h)
                end
                return nil, 'Child pipe is not inheritable; cannot start SSH safely'
            end
        end

        local startup_info, process_info = ffi.new('STARTUPINFOW'), ffi.new('PROCESS_INFORMATION')
        startup_info.cb, startup_info.dwFlags = ffi.sizeof(startup_info), STARTF_USESTDHANDLES
        startup_info.hStdInput, startup_info.hStdOutput, startup_info.hStdError =
            input, output, errwriter

        local quoted = {}
        for i, value in ipairs(args) do
            quoted[i] = native.quote(value)
        end

        if
            ffi.C.CreateProcessW(
                nil,
                wide(table.concat(quoted, ' ')),
                nil,
                nil,
                1,
                CREATE_NO_WINDOW,
                nil,
                nil,
                startup_info,
                process_info
            ) == 0
        then
            return fail('Cannot launch ' .. args[1] .. '; check installation and PATH')
        end

        -- Close child ends in parent process
        ffi.C.CloseHandle(input)
        ffi.C.CloseHandle(output)
        ffi.C.CloseHandle(errwriter)
        ffi.C.CloseHandle(process_info.hThread)

        child.input, child.output, child.errors, child.process =
            writer, reader, errreader, process_info.hProcess

    else
        -- Pipe closure must produce EPIPE, not terminate the monitoring UI.
        ffi.C.signal(SIGPIPE, ffi.cast('void (*)(int)', 1))
        local pipes = {}

        for i = 1, 3 do
            local descriptors = ffi.new('int[2]')
            if ffi.C.pipe(descriptors) ~= 0 then
                local err = native.error()
                for _, v in ipairs(pipes) do
                    ffi.C.close(v[0])
                    ffi.C.close(v[1])
                end
                return nil, 'Cannot create pipe: ' .. err
            end
            pipes[i] = descriptors
        end

        local argv, buffers = ffi.new('char *[?]', #args + 1), {}
        for i, value in ipairs(args) do
            buffers[i] = ffi.new('char[?]', #value + 1, value)
            argv[i - 1] = buffers[i]
        end

        local pid = ffi.C.fork()
        if pid == 0 then
            ffi.C.dup2(pipes[1][0], 0)
            ffi.C.dup2(pipes[2][1], 1)
            ffi.C.dup2(pipes[3][1], 2)

            for _, descriptors in ipairs(pipes) do
                ffi.C.close(descriptors[0])
                ffi.C.close(descriptors[1])
            end

            ffi.C.execvp(argv[0], argv)
            local msg = 'Cannot launch ' .. args[1] .. ': ' .. native.error() .. '\n'
            ffi.C.write(2, msg, #msg)
            ffi.C._exit(127)
        end

        if pid < 0 then
            local err = native.error()
            for _, descriptors in ipairs(pipes) do
                ffi.C.close(descriptors[0])
                ffi.C.close(descriptors[1])
            end
            return nil, 'Cannot fork process: ' .. err
        end

        -- Parent process closes unneeded pipe ends
        ffi.C.close(pipes[1][0])
        ffi.C.close(pipes[2][1])
        ffi.C.close(pipes[3][1])

        child.input, child.output, child.errors, child.pid =
            pipes[1][1], pipes[2][0], pipes[3][0], pid

        for _, fd in ipairs({ child.input, child.output, child.errors }) do
            ffi.C.fcntl(fd, F_SETFL, ffi.new('int', bit.bor(ffi.C.fcntl(fd, F_GETFL), O_NONBLOCK)))
        end
    end

    return child
end

function Child:read(stream)
    local fd = stream == 'stderr' and self.errors or self.output
    if fd == nil then
        return ''
    end

    local buffer = ffi.new('char[8192]')

    if native.windows then
        local available, count = ffi.new('DWORD[1]'), ffi.new('DWORD[1]')
        if ffi.C.PeekNamedPipe(fd, nil, 0, nil, available, nil) == 0 or available[0] == 0 then
            return ''
        end
        if ffi.C.ReadFile(fd, buffer, math.min(8192, tonumber(available[0])), count, nil) == 0 then
            return ''
        end
        return ffi.string(buffer, count[0])
    end

    local count = tonumber(ffi.C.read(fd, buffer, 8192))
    if count <= 0 then
        return ''
    end

    return ffi.string(buffer, count)
end

function Child:write(value)
    if not self.input then
        return nil, 'Process input is closed'
    end

    if native.windows then
        local count = ffi.new('DWORD[1]')
        if ffi.C.WriteFile(self.input, value, #value, count, nil) == 0 then
            return nil, native.error()
        end
        if tonumber(count[0]) ~= #value then
            return nil, 'Incomplete write to process input'
        end
    else
        -- Never block the UI if the remote command reader stops consuming.
        local descriptors = ffi.new('struct pollfd[1]', { { self.input, POLLOUT, 0 } })
        if
            ffi.C.poll(descriptors, 1, 0) < 1
            or bit.band(descriptors[0].revents, POLL_ERROR_OR_HANGUP) ~= 0
        then
            return nil, 'Process input is unavailable'
        end

        local count = tonumber(ffi.C.write(self.input, value, #value))
        if count ~= #value then
            return nil, 'Cannot write process input: ' .. native.error()
        end
    end

    return true
end

function Child:status()
    if self.exit ~= nil then
        return self.exit
    end

    if native.windows then
        if ffi.C.WaitForSingleObject(self.process, 0) ~= 0 then
            return nil
        end
        local code = ffi.new('DWORD[1]')
        if ffi.C.GetExitCodeProcess(self.process, code) ~= 0 then
            self.exit = tonumber(code[0])
        end
    else
        local status = ffi.new('int[1]')
        if ffi.C.waitpid(self.pid, status, WNOHANG) == self.pid then
            self.exit = bit.band(status[0], 127) == 0 and bit.rshift(status[0], 8)
                or 128 + bit.band(status[0], 127)
        end
    end

    return self.exit
end

function Child:close()
    if self.closed then
        return
    end
    self.closed = true

    if native.windows then
        if self:status() == nil then
            ffi.C.TerminateProcess(self.process, 1)
            ffi.C.WaitForSingleObject(self.process, 2000)
        end

        for _, handle in ipairs({ self.input, self.output, self.errors, self.process }) do
            ffi.C.CloseHandle(handle)
        end
    else
        if self:status() == nil then
            ffi.C.kill(self.pid, SIGKILL)
            ffi.C.waitpid(self.pid, ffi.new('int[1]'), 0)
        end

        for _, fd in ipairs({ self.input, self.output, self.errors }) do
            ffi.C.close(fd)
        end
    end

    self.input, self.output, self.errors = nil, nil, nil
end

--------------------------------------------------------------------------------
-- Console Terminal Controller (Modes, Sizing & Keyboard Input)
--------------------------------------------------------------------------------

native.term = {}
local terminal = native.term

function terminal.init()
    if native.windows then
        terminal.modes = {}
        terminal.cp = { ffi.C.GetConsoleCP(), ffi.C.GetConsoleOutputCP() }

        for _, id in ipairs({ STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, STD_ERROR_HANDLE }) do
            local handle = ffi.C.GetStdHandle(ffi.cast('DWORD', id))
            local mode = ffi.new('DWORD[1]')

            if ffi.C.GetConsoleMode(handle, mode) ~= 0 then
                terminal.modes[#terminal.modes + 1] = { handle, tonumber(mode[0]) }

                -- _getch must not receive window/focus events.
                local flags = id == STD_INPUT_HANDLE
                        and bit.band(mode[0], bit.bnot(DISABLED_WINDOWS_INPUT_MODES))
                    or bit.bor(mode[0], ENABLE_VIRTUAL_TERMINAL_PROCESSING)
                ffi.C.SetConsoleMode(handle, flags)

            elseif id == STD_INPUT_HANDLE then
                return nil, 'Interactive mode requires a console; use --list for redirected output'
            end
        end

        ffi.C.SetConsoleCP(UTF8_CODE_PAGE)
        ffi.C.SetConsoleOutputCP(UTF8_CODE_PAGE)

    else
        if ffi.C.isatty(0) == 0 or ffi.C.isatty(1) == 0 then
            return nil, 'Interactive mode requires a terminal; use --list'
        end

        terminal.saved = ffi.new('struct termios')
        if ffi.C.tcgetattr(0, terminal.saved) ~= 0 then
            return nil, native.error()
        end

        local raw = ffi.new('struct termios')
        ffi.copy(raw, terminal.saved, ffi.sizeof(raw))
        raw.c_lflag = bit.band(raw.c_lflag, bit.bnot(DISABLED_POSIX_LOCAL_MODES))
        raw.c_cc[5], raw.c_cc[6] = 0, 0
        ffi.C.tcsetattr(0, 0, raw)
    end

    io.write('\27[?1049h\27[?25l\27[?7l')
    io.flush()
    terminal.active = true

    return true
end

function terminal.restore()
    if terminal.active then
        io.write('\27[0m\27[?7h\27[?25h\27[?1049l')
        io.flush()
    end

    if native.windows then
        for _, v in ipairs(terminal.modes or {}) do
            ffi.C.SetConsoleMode(v[1], v[2])
        end
        if terminal.cp then
            ffi.C.SetConsoleCP(terminal.cp[1])
            ffi.C.SetConsoleOutputCP(terminal.cp[2])
        end
    elseif terminal.saved then
        ffi.C.tcsetattr(0, 0, terminal.saved)
    end

    terminal.active = false
end

function terminal.size()
    if native.windows then
        local info = ffi.new('CONSOLE_SCREEN_BUFFER_INFO')
        if
            ffi.C.GetConsoleScreenBufferInfo(
                ffi.C.GetStdHandle(ffi.cast('DWORD', STD_OUTPUT_HANDLE)),
                info
            ) ~= 0
        then
            return info.srWindow.Right - info.srWindow.Left + 1,
                info.srWindow.Bottom - info.srWindow.Top + 1
        end
    else
        local window_size = ffi.new('struct winsize')
        if ffi.C.ioctl(1, TIOCGWINSZ, window_size) == 0 and window_size.ws_col > 0 then
            return tonumber(window_size.ws_col), tonumber(window_size.ws_row)
        end
    end

    return 100, 30
end

function terminal.key()
    if native.windows then
        if native.crt._kbhit() == 0 then
            return nil
        end

        local key_value = native.crt._getch()
        if key_value == 0 or key_value == 224 then
            local scan_code = native.crt._getch()
            return ({
                [72] = 'up',
                [80] = 'down',
                [73] = 'pgup',
                [81] = 'pgdown',
                [71] = 'home',
                [79] = 'end',
            })[scan_code]
        end

        return ({ [3] = 'quit', [13] = 'enter', [27] = 'esc', [8] = 'backspace', [9] = 'tab' })[key_value]
            or string.char(key_value)
    end

    terminal.pending = terminal.pending or ''
    local descriptors = ffi.new('struct pollfd[1]', { { 0, POLLIN, 0 } })

    if ffi.C.poll(descriptors, 1, 0) > 0 then
        local buffer = ffi.new('char[64]')
        local count = tonumber(ffi.C.read(0, buffer, 64))
        if count > 0 then
            terminal.pending = terminal.pending .. ffi.string(buffer, count)
        end
    end

    if #terminal.pending == 0 then
        return nil
    end

    if terminal.pending:sub(1, 2) == '\27[' then
        local escape_sequence = terminal.pending:match('^\27%[[%d;]*[A-Za-z~]')
        if not escape_sequence then
            return nil
        end
        terminal.pending = terminal.pending:sub(#escape_sequence + 1)
        return ({
            ['\27[A'] = 'up',
            ['\27[B'] = 'down',
            ['\27[5~'] = 'pgup',
            ['\27[6~'] = 'pgdown',
            ['\27[H'] = 'home',
            ['\27[F'] = 'end',
        })[escape_sequence]
    end

    local key_value = terminal.pending:sub(1, 1)
    terminal.pending = terminal.pending:sub(2)

    return ({
        ['\3'] = 'quit',
        ['\13'] = 'enter',
        ['\10'] = 'enter',
        ['\27'] = 'esc',
        ['\127'] = 'backspace',
        ['\8'] = 'backspace',
        ['\9'] = 'tab',
    })[key_value] or key_value
end

return native
