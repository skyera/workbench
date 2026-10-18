-- Native nonblocking child pipes and terminal support. No shell on the client.
local ffi, bit = require('ffi'), require('bit')
local M = { windows = ffi.os == 'Windows' }
if M.windows then
    ffi.cdef[[
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
    ]]
    M.crt = ffi.load('msvcrt')
else
    if ffi.os ~= 'Linux' then error('fremote currently supports Windows and Linux clients') end
    ffi.cdef[[
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
    ]]
end

local function wide(s)
    local n = ffi.C.MultiByteToWideChar(65001, 8, s, #s, nil, 0)
    if n == 0 then error('Cannot encode process argument as UTF-16') end
    local b = ffi.new('wchar_t[?]', n+1)
    assert(ffi.C.MultiByteToWideChar(65001, 8, s, #s, b, n) ~= 0)
    return b
end

function M.error(code)
    if not M.windows then return ffi.string(ffi.C.strerror(code or ffi.errno())) end
    code = code or ffi.C.GetLastError()
    local b = ffi.new('wchar_t[2048]')
    local n = ffi.C.FormatMessageW(0x1200, nil, code, 0, b, 2048, nil)
    if n == 0 then return 'Windows error ' .. tonumber(code) end
    local size = ffi.C.WideCharToMultiByte(65001, 0, b, n, nil, 0, nil, nil)
    local out = ffi.new('char[?]', size)
    ffi.C.WideCharToMultiByte(65001, 0, b, n, out, size, nil, nil)
    return ffi.string(out, size):gsub('%s+$', '') .. ' (Windows error ' .. tonumber(code) .. ')'
end

function M.quote(s)
    return '"' .. s:gsub('(\\*)"', function(b) return b..b..'\\"' end):gsub('(\\+)$','%1%1') .. '"'
end

function M.now()
    if M.windows then return tonumber(ffi.C.GetTickCount64()) / 1000 end
    local t = ffi.new('struct timespec')
    ffi.C.clock_gettime(1, t)
    return tonumber(t.tv_sec) + tonumber(t.tv_nsec) / 1e9
end

function M.sleep(ms)
    if M.windows then ffi.C.Sleep(ms) else ffi.C.usleep(ms*1000) end
end

local Child = {}; Child.__index = Child
function M.spawn(args)
    local child = setmetatable({}, Child)
    if M.windows then
        local handles = {}
        local function fail(message)
            local reason = M.error()
            for _, h in ipairs(handles) do ffi.C.CloseHandle(h) end
            return nil, message .. ': ' .. reason
        end
        local sa = ffi.new('SECURITY_ATTRIBUTES')
        sa.nLength,sa.bInheritHandle=ffi.sizeof(sa),1
        local function pipe()
            local r,w = ffi.new('HANDLE[1]'),ffi.new('HANDLE[1]')
            if ffi.C.CreatePipe(r,w,sa,0) == 0 then return nil end
            handles[#handles+1], handles[#handles+2] = r[0],w[0]
            return r[0], w[0]
        end
        local input, writer = pipe()
        if not input then return fail('Cannot create stdin pipe') end
        local reader, output = pipe()
        if not reader then return fail('Cannot create stdout pipe') end
        local errreader, errwriter = pipe()
        if not errreader then return fail('Cannot create stderr pipe') end
        for _,h in ipairs({writer,reader,errreader}) do
            if ffi.C.SetHandleInformation(h,1,0) == 0 then return fail('Cannot protect parent pipe') end
        end
        for _,h in ipairs({input,output,errwriter}) do
            local flags=ffi.new('DWORD[1]')
            if ffi.C.GetHandleInformation(h,flags)==0 then return fail('Cannot inspect child pipe') end
            if bit.band(flags[0],1)==0 then
                for _,handle in ipairs(handles) do ffi.C.CloseHandle(handle) end
                return nil,'Child pipe is not inheritable; cannot start SSH safely'
            end
        end
        local si,pi = ffi.new('STARTUPINFOW'),ffi.new('PROCESS_INFORMATION')
        si.cb, si.dwFlags = ffi.sizeof(si), 0x100
        si.hStdInput,si.hStdOutput,si.hStdError = input,output,errwriter
        local quoted = {}; for i,s in ipairs(args) do quoted[i] = M.quote(s) end
        if ffi.C.CreateProcessW(nil,wide(table.concat(quoted,' ')),nil,nil,1,0x08000000,nil,nil,si,pi) == 0 then
            return fail('Cannot launch ' .. args[1] .. '; check installation and PATH')
        end
        ffi.C.CloseHandle(input); ffi.C.CloseHandle(output); ffi.C.CloseHandle(errwriter)
        ffi.C.CloseHandle(pi.hThread)
        child.input,child.output,child.errors,child.process = writer,reader,errreader,pi.hProcess
    else
        -- Pipe closure must produce EPIPE, not terminate the monitoring UI.
        ffi.C.signal(13, ffi.cast('void (*)(int)', 1))
        local pipes = {}
        for i=1,3 do
            local p = ffi.new('int[2]')
            if ffi.C.pipe(p) ~= 0 then
                local err = M.error()
                for _,v in ipairs(pipes) do ffi.C.close(v[0]); ffi.C.close(v[1]) end
                return nil,'Cannot create pipe: '..err
            end
            pipes[i] = p
        end
        local argv,buffers = ffi.new('char *[?]',#args+1),{}
        for i,s in ipairs(args) do
            buffers[i] = ffi.new('char[?]',#s+1,s); argv[i-1] = buffers[i]
        end
        local pid = ffi.C.fork()
        if pid == 0 then
            ffi.C.dup2(pipes[1][0],0); ffi.C.dup2(pipes[2][1],1); ffi.C.dup2(pipes[3][1],2)
            for _,p in ipairs(pipes) do ffi.C.close(p[0]); ffi.C.close(p[1]) end
            ffi.C.execvp(argv[0],argv)
            local msg = 'Cannot launch '..args[1]..': '..M.error()..'\n'
            ffi.C.write(2,msg,#msg); ffi.C._exit(127)
        end
        if pid < 0 then
            local err = M.error()
            for _,p in ipairs(pipes) do ffi.C.close(p[0]); ffi.C.close(p[1]) end
            return nil,'Cannot fork process: '..err
        end
        ffi.C.close(pipes[1][0]); ffi.C.close(pipes[2][1]); ffi.C.close(pipes[3][1])
        child.input,child.output,child.errors,child.pid = pipes[1][1],pipes[2][0],pipes[3][0],pid
        for _,fd in ipairs({child.input,child.output,child.errors}) do
            ffi.C.fcntl(fd,4,ffi.new('int',bit.bor(ffi.C.fcntl(fd,3),0x800)))
        end
    end
    return child
end

function Child:read(stream)
    local fd = stream == 'stderr' and self.errors or self.output
    if fd == nil then return '' end
    local b = ffi.new('char[8192]')
    if M.windows then
        local available,n = ffi.new('DWORD[1]'),ffi.new('DWORD[1]')
        if ffi.C.PeekNamedPipe(fd,nil,0,nil,available,nil) == 0 or available[0] == 0 then return '' end
        if ffi.C.ReadFile(fd,b,math.min(8192,tonumber(available[0])),n,nil) == 0 then return '' end
        return ffi.string(b,n[0])
    end
    local n = tonumber(ffi.C.read(fd,b,8192))
    if n <= 0 then return '' end
    return ffi.string(b,n)
end

function Child:write(s)
    if not self.input then return nil,'Process input is closed' end
    if M.windows then
        local n=ffi.new('DWORD[1]')
        if ffi.C.WriteFile(self.input,s,#s,n,nil) == 0 then return nil,M.error() end
        if tonumber(n[0]) ~= #s then return nil,'Incomplete write to process input' end
    else
        -- Never block the UI if the remote command reader stops consuming.
        local p=ffi.new('struct pollfd[1]',{{self.input,4,0}})
        if ffi.C.poll(p,1,0) < 1 or bit.band(p[0].revents,0x18) ~= 0 then return nil,'Process input is unavailable' end
        local n=tonumber(ffi.C.write(self.input,s,#s))
        if n ~= #s then return nil,'Cannot write process input: '..M.error() end
    end
    return true
end

function Child:status()
    if self.exit ~= nil then return self.exit end
    if M.windows then
        if ffi.C.WaitForSingleObject(self.process,0) ~= 0 then return nil end
        local code=ffi.new('DWORD[1]')
        if ffi.C.GetExitCodeProcess(self.process,code) ~= 0 then self.exit=tonumber(code[0]) end
    else
        local status=ffi.new('int[1]')
        if ffi.C.waitpid(self.pid,status,1) == self.pid then
            self.exit = bit.band(status[0],127) == 0 and bit.rshift(status[0],8) or 128+bit.band(status[0],127)
        end
    end
    return self.exit
end

function Child:close()
    if self.closed then return end
    self.closed=true
    if M.windows then
        if self:status() == nil then ffi.C.TerminateProcess(self.process,1); ffi.C.WaitForSingleObject(self.process,2000) end
        for _,h in ipairs({self.input,self.output,self.errors,self.process}) do ffi.C.CloseHandle(h) end
    else
        if self:status() == nil then ffi.C.kill(self.pid,9); ffi.C.waitpid(self.pid,ffi.new('int[1]'),0) end
        for _,fd in ipairs({self.input,self.output,self.errors}) do ffi.C.close(fd) end
    end
    self.input,self.output,self.errors=nil,nil,nil
end

M.term = {}
local T=M.term
function T.init()
    if M.windows then
        T.modes={}; T.cp={ffi.C.GetConsoleCP(),ffi.C.GetConsoleOutputCP()}
        for _,id in ipairs({-10,-11,-12}) do
            local h=ffi.C.GetStdHandle(ffi.cast('DWORD',id)); local mode=ffi.new('DWORD[1]')
            if ffi.C.GetConsoleMode(h,mode) ~= 0 then
                T.modes[#T.modes+1]={h,tonumber(mode[0])}
                -- _getch must not receive window/focus events.
                local flags = id == -10 and bit.band(mode[0],bit.bnot(0x2+0x4+0x8)) or bit.bor(mode[0],4)
                ffi.C.SetConsoleMode(h,flags)
            elseif id == -10 then return nil,'Interactive mode requires a console; use --list for redirected output' end
        end
        ffi.C.SetConsoleCP(65001); ffi.C.SetConsoleOutputCP(65001)
    else
        if ffi.C.isatty(0) == 0 or ffi.C.isatty(1) == 0 then return nil,'Interactive mode requires a terminal; use --list' end
        T.saved=ffi.new('struct termios')
        if ffi.C.tcgetattr(0,T.saved) ~= 0 then return nil,M.error() end
        local raw=ffi.new('struct termios'); ffi.copy(raw,T.saved,ffi.sizeof(raw))
        raw.c_lflag=bit.band(raw.c_lflag,bit.bnot(0x1+0x2+0x8))
        raw.c_cc[5],raw.c_cc[6]=0,0
        ffi.C.tcsetattr(0,0,raw)
    end
    io.write('\27[?1049h\27[?25l\27[?7l'); io.flush(); T.active=true
    return true
end

function T.restore()
    if T.active then io.write('\27[0m\27[?7h\27[?25h\27[?1049l'); io.flush() end
    if M.windows then
        for _,v in ipairs(T.modes or {}) do ffi.C.SetConsoleMode(v[1],v[2]) end
        if T.cp then ffi.C.SetConsoleCP(T.cp[1]); ffi.C.SetConsoleOutputCP(T.cp[2]) end
    elseif T.saved then ffi.C.tcsetattr(0,0,T.saved) end
    T.active=false
end

function T.size()
    if M.windows then
        local info=ffi.new('CONSOLE_SCREEN_BUFFER_INFO')
        if ffi.C.GetConsoleScreenBufferInfo(ffi.C.GetStdHandle(ffi.cast('DWORD',-11)),info) ~= 0 then
            return info.srWindow.Right-info.srWindow.Left+1, info.srWindow.Bottom-info.srWindow.Top+1
        end
    else
        local ws=ffi.new('struct winsize')
        if ffi.C.ioctl(1,0x5413,ws) == 0 and ws.ws_col > 0 then return tonumber(ws.ws_col),tonumber(ws.ws_row) end
    end
    return 100,30
end

function T.key()
    if M.windows then
        if M.crt._kbhit() == 0 then return nil end
        local c=M.crt._getch()
        if c==0 or c==224 then
            local k=M.crt._getch()
            return ({[72]='up',[80]='down',[73]='pgup',[81]='pgdown',[71]='home',[79]='end'})[k]
        end
        return ({[3]='quit',[13]='enter',[27]='esc',[8]='backspace',[9]='tab'})[c] or string.char(c)
    end
    T.pending=T.pending or ''
    local p=ffi.new('struct pollfd[1]',{{0,1,0}})
    if ffi.C.poll(p,1,0) > 0 then
        local b=ffi.new('char[64]'); local n=tonumber(ffi.C.read(0,b,64))
        if n > 0 then T.pending=T.pending..ffi.string(b,n) end
    end
    if #T.pending == 0 then return nil end
    if T.pending:sub(1,2)=='\27[' then
        local seq=T.pending:match('^\27%[[%d;]*[A-Za-z~]')
        if not seq then return nil end
        T.pending=T.pending:sub(#seq+1)
        return ({['\27[A']='up',['\27[B']='down',['\27[5~']='pgup',['\27[6~']='pgdown',['\27[H']='home',['\27[F']='end'})[seq]
    end
    local c=T.pending:sub(1,1); T.pending=T.pending:sub(2)
    return ({['\3']='quit',['\13']='enter',['\10']='enter',['\27']='esc',['\127']='backspace',['\8']='backspace',['\9']='tab'})[c] or c
end

return M
