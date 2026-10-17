#!/usr/bin/env luajit
--[[
  fbr.lua - High-Performance Git Branch Manager & Deleter TUI (LuaJIT + FFI)
  Single-file, zero external Lua dependencies. Cross-platform Linux & Windows.

  Features:
    - Real-Time Branch Discovery: Parses local, remote, and tracking branches.
    - Merged Status Detection: Instantly flags merged branches (safe to delete with -d).
    - Multi-Selection Batch Delete: Use Tab to select multiple obsolete branches and delete in one go.
    - Safe & Force Deletion: 'd' for safe delete (git branch -d), 'D' for force delete (git branch -D).
    - Instant Branch Checkout: Press Enter to checkout local or remote tracking branch.
    - Branch Inspector: Right pane shows recent commits, upstream tracking, and ahead/behind counts.
    - Category Tabs: [All], [Local], [Merged], [Remote] with Tab / h / l.
    - Interactive & Non-Interactive: Full interactive TUI or --list CLI mode.
    - Automated Self-Test Suite: Run 'luajit fbr.lua --test'.
]]

local ffi = require("ffi")
local bit = require("bit")

local IS_WINDOWS = (ffi.os == "Windows")

--------------------------------------------------------------------------------
-- 1. FFI Declarations
--------------------------------------------------------------------------------
if IS_WINDOWS then
    ffi.cdef[[
        typedef void* HANDLE;
        typedef unsigned long DWORD;
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
        int _kbhit(void);
        int _getch(void);
    ]]
else
    ffi.cdef[[
        typedef unsigned int tcflag_t;
        typedef unsigned char cc_t;
        typedef unsigned int speed_t;
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
        int read(int fd, void *buf, size_t count);
        int ioctl(int fd, unsigned long request, ...);
        struct winsize {
            unsigned short ws_row;
            unsigned short ws_col;
            unsigned short ws_xpixel;
            unsigned short ws_ypixel;
        };
    ]]
end

--------------------------------------------------------------------------------
-- 2. ANSI Styles
--------------------------------------------------------------------------------
local C = {
    reset        = "\27[0m",
    bold         = "\27[1m",
    dim          = "\27[2m",
    italic       = "\27[3m",
    underline    = "\27[4m",
    inverse      = "\27[7m",

    black        = "\27[30m",
    red          = "\27[31m",
    green        = "\27[32m",
    yellow       = "\27[33m",
    blue         = "\27[34m",
    magenta      = "\27[35m",
    cyan         = "\27[36m",
    white        = "\27[37m",
    gray         = "\27[90m",

    b_black      = "\27[90m",
    b_red        = "\27[91m",
    b_green      = "\27[92m",
    b_yellow     = "\27[93m",
    b_blue       = "\27[94m",
    b_magenta    = "\27[95m",
    b_cyan       = "\27[96m",
    b_white      = "\27[97m",

    bg_darkblue  = "\27[48;5;17m",
    bg_select    = "\27[48;5;237m",
    bg_header    = "\27[48;5;235m",
    bg_card      = "\27[48;5;234m",
    bg_subtle    = "\27[48;5;236m",
    bg_red       = "\27[48;5;52m",
    bg_green     = "\27[48;5;22m",
}

--------------------------------------------------------------------------------
-- 3. Terminal Controller
--------------------------------------------------------------------------------
local Term = {
    initialized = false,
    orig_mode_in = nil,
    orig_mode_out = nil,
    hIn = nil,
    hOut = nil,
    orig_termios = nil,
    tty_fd = -1,
    tty_out = nil,
}

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

function Term.init()
    if Term.initialized then return end
    if IS_WINDOWS then
        Term.hIn = ffi.C.GetStdHandle(-10)   -- STD_INPUT_HANDLE
        Term.hOut = ffi.C.GetStdHandle(-11)  -- STD_OUTPUT_HANDLE
        local mIn = ffi.new("DWORD[1]")
        local mOut = ffi.new("DWORD[1]")
        ffi.C.GetConsoleMode(Term.hIn, mIn)
        ffi.C.GetConsoleMode(Term.hOut, mOut)
        Term.orig_mode_in = mIn[0]
        Term.orig_mode_out = mOut[0]

        local raw_in = bit.band(Term.orig_mode_in, bit.bnot(0x0007))
        raw_in = bit.bor(raw_in, 0x0008) -- ENABLE_WINDOW_INPUT
        local raw_out = bit.bor(Term.orig_mode_out, 0x0004) -- ENABLE_VIRTUAL_TERMINAL_PROCESSING
        ffi.C.SetConsoleMode(Term.hIn, raw_in)
        ffi.C.SetConsoleMode(Term.hOut, raw_out)
    else
        Term.tty_fd = ffi.C.open("/dev/tty", 2)
        if Term.tty_fd < 0 then Term.tty_fd = 0 end
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
    Term.write_tui("\27[?1049h\27[?25l") -- Alternate screen, hide cursor
end

function Term.restore()
    if not Term.initialized then return end
    Term.write_tui("\27[?25h\27[?1049l" .. C.reset)
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
        elseif ch == 3 then return "CTRL_C"
        elseif ch == 4 then return "CTRL_D"
        elseif ch == 21 then return "CTRL_U"
        elseif ch == 32 then return "SPACE"
        end
        return string.char(ch)
    else
        local buf = ffi.new("char[32]")
        local n = ffi.C.read(Term.tty_fd >= 0 and Term.tty_fd or 0, buf, 32)
        if n <= 0 then return "NONE" end
        local seq = ffi.string(buf, n)

        if seq == "\27" then return "ESC"
        elseif seq == "\n" or seq == "\r" then return "ENTER"
        elseif seq == "\t" then return "TAB"
        elseif seq == "\127" or seq == "\8" then return "BACKSPACE"
        elseif seq == "\3" then return "CTRL_C"
        elseif seq == "\4" then return "CTRL_D"
        elseif seq == "\21" then return "CTRL_U"
        elseif seq == " " then return "SPACE"
        elseif seq == "\27[A" or seq == "\27OA" then return "UP"
        elseif seq == "\27[B" or seq == "\27OB" then return "DOWN"
        elseif seq == "\27[C" or seq == "\27OC" then return "RIGHT"
        elseif seq == "\27[D" or seq == "\27OD" then return "LEFT"
        elseif seq == "\27[H" or seq == "\27[1~" then return "HOME"
        elseif seq == "\27[F" or seq == "\27[4~" then return "END"
        elseif seq == "\27[5~" then return "PGUP"
        elseif seq == "\27[6~" then return "PGDN"
        elseif seq == "\27[3~" then return "DELETE"
        elseif seq == "\27[Z" then return "BACKTAB"
        end

        if #seq == 1 then return seq end
        return "UNKNOWN"
    end
end

--------------------------------------------------------------------------------
-- 4. String & Parsing Helpers
--------------------------------------------------------------------------------
local function trim(s)
    if not s then return "" end
    return s:match("^%s*(.-)%s*$") or ""
end

local function pad_right(s, w)
    local len = #s
    if len >= w then return s:sub(1, w) end
    return s .. string.rep(" ", w - len)
end

local function pad_left(s, w)
    local len = #s
    if len >= w then return s:sub(1, w) end
    return string.rep(" ", w - len) .. s
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
-- 5. Git Engine
--------------------------------------------------------------------------------
local Engine = {}

function Engine.exec_git(args)
    local devnull = IS_WINDOWS and "2>nul" or "2>/dev/null"
    local cmd = "git " .. args .. " " .. devnull
    local p = io.popen(cmd, "r")
    if not p then return "" end
    local out = p:read("*a")
    p:close()
    return out or ""
end

function Engine.is_inside_git_repo()
    local res = Engine.exec_git("rev-parse --is-inside-work-tree")
    return trim(res) == "true"
end

function Engine.get_repo_name()
    local res = Engine.exec_git("rev-parse --show-toplevel")
    res = trim(res)
    if #res == 0 then return "git" end
    return res:match("([^/\\]+)$") or res
end

-- Parse a line of 'git branch -vv --sort=-committerdate'
function Engine.parse_branch_line(line, merged_set)
    merged_set = merged_set or {}
    line = line:gsub("\r$", "")
    if #line == 0 then return nil end

    local is_head = false
    local rest = line
    if line:sub(1, 2) == "* " then
        is_head = true
        rest = line:sub(3)
    elseif line:sub(1, 2) == "  " or line:sub(1, 2) == "+ " then
        rest = line:sub(3)
    end

    -- Format: <name> <sha> [<tracking>] <subject>
    local name, after_name = rest:match("^(%S+)%s+(.*)$")
    if not name then return nil end
    if name:find("^%(") then return nil end -- (HEAD detached at ...)

    local sha, after_sha = after_name:match("^(%x+)%s+(.*)$")
    sha = sha or ""
    after_sha = after_sha or after_name

    local tracking = nil
    local ahead = nil
    local behind = nil
    local gone = false
    local subject = after_sha

    if after_sha:sub(1, 1) == "[" then
        local track_info, rem = after_sha:match("^%[([^%]]+)%]%s*(.*)$")
        if track_info then
            subject = rem or ""
            local t_name = track_info:match("^([^:]+)")
            tracking = trim(t_name)

            if track_info:find("gone") then
                gone = true
            end
            local ah = track_info:match("ahead (%d+)")
            if ah then ahead = tonumber(ah) end
            local bh = track_info:match("behind (%d+)")
            if bh then behind = tonumber(bh) end
        end
    end

    local is_merged = (merged_set[name] == true)

    return {
        name = name,
        is_head = is_head,
        is_remote = false,
        is_merged = is_merged,
        sha = sha,
        tracking = tracking,
        ahead = ahead,
        behind = behind,
        gone = gone,
        subject = trim(subject),
    }
end

function Engine.parse_ref_line(line, merged_set)
    merged_set = merged_set or {}
    line = line:gsub("\r$", "")
    if #line == 0 then return nil end

    local head_mark, name, sha, tracking, track_info, subject = line:match("^([^|]*)|([^|]+)|([^|]*)|([^|]*)|([^|]*)|(.*)$")
    if not name then return nil end

    local is_head = (head_mark == "*")
    local ahead = nil
    local behind = nil
    local gone = false

    if track_info and #track_info > 0 then
        if track_info:find("gone") then
            gone = true
        end
        local ah = track_info:match("ahead (%d+)")
        if ah then ahead = tonumber(ah) end
        local bh = track_info:match("behind (%d+)")
        if bh then behind = tonumber(bh) end
    end

    return {
        name = name,
        is_head = is_head,
        is_remote = false,
        is_merged = (merged_set[name] == true),
        sha = sha or "",
        tracking = (#tracking > 0) and tracking or nil,
        ahead = ahead,
        behind = behind,
        gone = gone,
        subject = trim(subject or ""),
    }
end

function Engine.load_local_branches()
    local branches = {}
    local merged_set = {}

    -- 1. Merged branches into HEAD (1 fast git call)
    local merged_raw = Engine.exec_git("branch --merged")
    for line in merged_raw:gmatch("[^\r\n]+") do
        line = trim(line:gsub("^%*%s*", ""))
        if #line > 0 then
            merged_set[line] = true
        end
    end

    -- 2. Local branches via fast for-each-ref (1 fast git call)
    local local_raw = Engine.exec_git('for-each-ref --format="%(HEAD)|%(refname:short)|%(objectname:short)|%(upstream:short)|%(upstream:track)|%(subject)" --sort=-committerdate refs/heads/')
    local head_branch = nil
    for line in local_raw:gmatch("[^\r\n]+") do
        local b = Engine.parse_ref_line(line, merged_set)
        if b then
            table.insert(branches, b)
            if b.is_head then
                head_branch = b.name
            end
        end
    end

    return branches, head_branch, merged_set
end

function Engine.load_remote_branches()
    local remotes = {}
    -- Single fast git call for all remote branches
    local remote_raw = Engine.exec_git('for-each-ref --format="%(refname:short)|%(objectname:short)|%(subject)" --sort=-committerdate refs/remotes/')
    for line in remote_raw:gmatch("[^\r\n]+") do
        local rname, sha, subj = line:match("^([^|]+)|([^|]*)|(.*)$")
        if rname and not rname:find("%->") and rname:find("/") then
            table.insert(remotes, {
                name = rname,
                is_head = false,
                is_remote = true,
                is_merged = false,
                sha = sha or "",
                tracking = nil,
                ahead = nil,
                behind = nil,
                gone = false,
                subject = trim(subj or ""),
            })
        end
    end
    return remotes
end

function Engine.load_all_branches(include_remotes)
    local local_b, head_branch, merged_set = Engine.load_local_branches()
    local all_b = {}
    for _, b in ipairs(local_b) do table.insert(all_b, b) end
    if include_remotes then
        local remotes = Engine.load_remote_branches()
        for _, b in ipairs(remotes) do table.insert(all_b, b) end
    end
    return all_b, head_branch, merged_set
end

function Engine.get_branch_log(branch_name, limit)
    limit = limit or 5
    local raw = Engine.exec_git(string.format("log -n %d --format='%%h|%%an|%%cr|%%s' %s", limit, branch_name))
    local commits = {}
    for line in raw:gmatch("[^\r\n]+") do
        local h, author, date, subj = line:match("^([^|]+)|([^|]+)|([^|]+)|(.*)$")
        if h then
            table.insert(commits, {
                hash = h,
                author = author,
                date = date,
                subject = subj,
            })
        end
    end
    return commits
end

function Engine.checkout(branch)
    if not branch then return false, "No branch selected" end
    Term.restore()
    local cmd
    if branch.is_remote then
        local local_name = branch.name:gsub("^[^/]+/", "")
        cmd = string.format("git checkout %s 2>&1", local_name)
    else
        cmd = string.format("git checkout %s 2>&1", branch.name)
    end
    print(C.b_cyan .. "Running: " .. C.b_white .. cmd .. C.reset .. "\n")
    local p = io.popen(cmd)
    local out = p and p:read("*a") or ""
    if p then p:close() end
    print(out)
    return true, out
end

function Engine.delete_branch(branch, force)
    if not branch then return false, "No branch specified" end
    if branch.is_head then
        return false, "Cannot delete currently checked out branch: " .. branch.name
    end
    if branch.is_remote then
        return false, "Remote branches are protected and cannot be deleted (local only): " .. branch.name
    end

    local flag = force and "-D" or "-d"
    local cmd = string.format("git branch %s %s 2>&1", flag, branch.name)

    local p = io.popen(cmd)
    local out = p and p:read("*a") or ""
    if p then p:close() end
    out = trim(out)

    local success = out:find("Deleted branch") ~= nil
    return success, out
end

--------------------------------------------------------------------------------
-- 6. Interactive TUI Engine
--------------------------------------------------------------------------------
local TABS = { "local", "merged", "remote", "all" }
local TAB_LABELS = {
    ["local"] = "Local",
    merged = "Merged",
    remote = "Remote",
    all = "All",
}

local function run_tui(init_opts)
    init_opts = init_opts or {}
    if not Engine.is_inside_git_repo() then
        io.stderr:write(C.b_red .. "Error: Not inside a Git repository.\n" .. C.reset)
        os.exit(1)
    end

    Term.init()

    local state = {
        all_branches = {},
        filtered = {},
        head_branch = "",
        repo_name = Engine.get_repo_name(),
        filter = init_opts.filter or "",
        prev_filter = "",
        mode = "normal", -- "normal", "filter", "confirm_delete", "new_branch"
        tab_idx = init_opts.start_tab or 1,
        cursor = 1,
        scroll = 1,
        status_msg = "",
        status_type = "ok", -- "ok", "error", "warn"
        selected_set = {},  -- Multi-selection map: { [branch_name] = true }
        remotes_loaded = false,
        cached_logs = {},
        confirm_callback = nil,
        input_buf = "",
        input_prompt = "",
    }

    local function refresh_data(include_remotes)
        if include_remotes == nil then
            include_remotes = (state.tab_idx == 3 or state.tab_idx == 4)
        end
        state.all_branches, state.head_branch = Engine.load_all_branches(include_remotes)
        if include_remotes then
            state.remotes_loaded = true
        end
        state.cached_logs = {}
    end

    local function apply_filter()
        local tab = TABS[state.tab_idx]
        local list = {}

        for _, b in ipairs(state.all_branches) do
            local pass_tab = false
            if tab == "all" then
                pass_tab = true
            elseif tab == "local" then
                pass_tab = not b.is_remote
            elseif tab == "merged" then
                pass_tab = (not b.is_remote) and b.is_merged and (not b.is_head)
            elseif tab == "remote" then
                pass_tab = b.is_remote
            end

            if pass_tab then
                if #state.filter > 0 then
                    local s1 = fuzzy_score(state.filter, b.name)
                    local s2 = fuzzy_score(state.filter, b.subject)
                    local s = math.max(s1 or 0, s2 or 0)
                    if s > 0 then
                        table.insert(list, { b = b, score = s })
                    end
                else
                    table.insert(list, { b = b, score = 0 })
                end
            end
        end

        if #state.filter > 0 then
            table.sort(list, function(a, b) return a.score > b.score end)
        end

        state.filtered = {}
        for _, it in ipairs(list) do
            table.insert(state.filtered, it.b)
        end

        state.cursor = math.max(1, math.min(state.cursor, #state.filtered))
    end

    refresh_data()
    apply_filter()

    local prev_lines = {}

    local function render()
        local cols, rows = Term.get_size()
        local frame_lines = {}
        local function add_line(s)
            frame_lines[#frame_lines + 1] = s
        end

        local cur_item = state.filtered[state.cursor]

        -- Compute merged count for tab label
        local merged_cnt = 0
        local local_cnt = 0
        local remote_cnt = 0
        for _, b in ipairs(state.all_branches) do
            if not b.is_remote then
                local_cnt = local_cnt + 1
                if b.is_merged and not b.is_head then
                    merged_cnt = merged_cnt + 1
                end
            else
                remote_cnt = remote_cnt + 1
            end
        end

        -- 1. Header
        local head_str = string.format(" %s%s⚡ fbr%s %s[%s]%s │ Repo: %s%s%s │ Current: %s%s%s",
            C.b_cyan, C.bold, C.reset,
            C.b_yellow, TAB_LABELS[TABS[state.tab_idx]], C.reset,
            C.b_white, state.repo_name, C.reset,
            C.b_green .. C.bold, state.head_branch or "detached", C.reset)
        add_line(C.bg_header .. pad_right(head_str, cols) .. C.reset)

        -- 2. Subheader Tabs & Filter
        local tabs_str = ""
        for i, t in ipairs(TABS) do
            local label = TAB_LABELS[t]
            if t == "merged" then label = string.format("Merged (%d)", merged_cnt)
            elseif t == "local" then label = string.format("Local (%d)", local_cnt)
            elseif t == "remote" then label = string.format("Remote (%d)", remote_cnt)
            end

            if i == state.tab_idx then
                tabs_str = tabs_str .. C.inverse .. C.b_cyan .. "[" .. label .. "]" .. C.reset .. " "
            else
                tabs_str = tabs_str .. C.gray .. "[" .. label .. "]" .. C.reset .. " "
            end
        end

        local filter_disp
        if state.mode == "filter" then
            filter_disp = C.b_yellow .. C.bold .. "Filter (/): " .. C.b_white .. state.filter .. "█" .. C.reset
        else
            if #state.filter > 0 then
                filter_disp = C.bold .. "Filter: " .. C.b_white .. state.filter .. C.reset .. C.gray .. " (Esc to clear)" .. C.reset
            else
                filter_disp = C.bold .. "Filter (/): " .. C.gray .. "(press / to filter)" .. C.reset
            end
        end

        local sub_l = " " .. filter_disp
        local sub_r = tabs_str .. " "
        local sub_space = cols - (#filter_disp:gsub("\27%[[%d;]*m", "") + #tabs_str:gsub("\27%[[%d;]*m", "") + 4)
        if sub_space < 1 then sub_space = 1 end
        add_line(sub_l .. string.rep(" ", sub_space) .. sub_r)

        -- 3. Pane Geometry
        local body_h = math.max(4, rows - 5)
        local left_w = math.floor(cols * 0.52)
        if cols < 90 then left_w = cols - 2 end
        local right_w = cols - left_w - 3

        -- Adjust scroll viewport
        if state.cursor < state.scroll then
            state.scroll = state.cursor
        elseif state.cursor >= state.scroll + body_h then
            state.scroll = state.cursor - body_h + 1
        end

        -- Header divider
        local raw_hdr = pad_right(string.format("  %-3s  %-8s %-8s   %s", "SEL", "TYPE", "STATUS", "BRANCH NAME"), left_w)
        local list_hdr = C.b_blue .. C.bold .. raw_hdr .. C.reset
        local right_hdr = (cols >= 90) and (C.b_white .. C.bold .. " 📋 BRANCH INSPECTOR" .. C.reset) or ""
        local hdr_sep = (cols >= 90) and (C.gray .. "│" .. C.reset) or ""
        add_line(list_hdr .. " " .. hdr_sep .. " " .. right_hdr)

        -- Pre-load inspector content for right pane
        local r_lines = {}
        if cols >= 90 and cur_item then
            table.insert(r_lines, "")
            table.insert(r_lines, string.format("  %sBranch:%s   %s%s%s", C.b_yellow .. C.bold, C.reset, C.b_white .. C.bold, cur_item.name, C.reset))
            if cur_item.is_head then
                table.insert(r_lines, string.format("  %sRole:%s     %s★ Currently Checked Out (HEAD)%s", C.b_cyan .. C.bold, C.reset, C.b_green .. C.bold, C.reset))
            else
                table.insert(r_lines, string.format("  %sRole:%s     %s", C.b_cyan .. C.bold, C.reset, cur_item.is_remote and (C.magenta .. "Remote Tracking Branch" .. C.reset) or "Local Branch"))
            end

            -- Upstream tracking
            if cur_item.tracking then
                local track_str = cur_item.tracking
                if cur_item.ahead or cur_item.behind then
                    track_str = track_str .. " ("
                    if cur_item.ahead and cur_item.ahead > 0 then track_str = track_str .. C.b_green .. "↑" .. cur_item.ahead .. C.reset .. " " end
                    if cur_item.behind and cur_item.behind > 0 then track_str = track_str .. C.b_red .. "↓" .. cur_item.behind .. C.reset end
                    track_str = trim(track_str) .. ")"
                else
                    track_str = track_str .. " " .. C.b_green .. "(up to date)" .. C.reset
                end
                table.insert(r_lines, string.format("  %sTracking:%s %s", C.gray, C.reset, track_str))
            end

            -- Merged status
            if cur_item.is_merged then
                table.insert(r_lines, string.format("  %sMerged:%s   %s✔ Merged into HEAD (safe to delete)%s", C.b_green .. C.bold, C.reset, C.b_green, C.reset))
            elseif not cur_item.is_head and not cur_item.is_remote then
                table.insert(r_lines, string.format("  %sMerged:%s   %sUnmerged commits present%s", C.yellow, C.reset, C.yellow, C.reset))
            end

            table.insert(r_lines, "")
            table.insert(r_lines, string.format("  %sRecent Commits on this Branch:%s", C.b_white .. C.bold, C.reset))

            if not state.cached_logs[cur_item.name] then
                state.cached_logs[cur_item.name] = Engine.get_branch_log(cur_item.name, 6)
            end
            local logs = state.cached_logs[cur_item.name] or {}
            if #logs == 0 then
                table.insert(r_lines, "    " .. C.gray .. "(No commits or branch ref not found)" .. C.reset)
            else
                for _, c in ipairs(logs) do
                    local msg_w = math.max(10, right_w - 28)
                    local msg_disp = pad_right(c.subject, msg_w)
                    table.insert(r_lines, string.format("    %s•%s %s%s%s %s%s%s %s",
                        C.b_blue, C.reset,
                        C.yellow, c.hash, C.reset,
                        C.white, msg_disp, C.reset,
                        C.gray .. "(" .. c.date .. ")" .. C.reset))
                end
            end
        end

        -- 4. Body Rows
        for row = 1, body_h do
            local idx = state.scroll + row - 1
            local item = state.filtered[idx]
            local l_str

            if item then
                local is_cur = (idx == state.cursor)
                local bg = is_cur and C.bg_select or ""
                local ptr = is_cur and (C.b_cyan .. "▸" .. C.reset .. bg) or " "

                -- Checkbox
                local is_checked = (state.selected_set[item.name] == true)
                local chk = is_checked and (C.b_green .. "[x]" .. C.reset .. bg) or (C.gray .. "[ ]" .. C.reset .. bg)

                -- Head star / icon
                local head_part = item.is_head and (C.b_green .. "* " .. C.reset .. bg) or "  "

                -- Type pill
                local type_pill
                if item.is_remote then
                    type_pill = C.magenta .. "[Remote]" .. C.reset .. bg
                else
                    type_pill = C.b_blue .. "[Local ]" .. C.reset .. bg
                end

                -- Status pill
                local status_pill
                if item.is_head then
                    status_pill = C.b_green .. "[HEAD  ]" .. C.reset .. bg
                elseif item.is_merged then
                    status_pill = C.green .. "[Merged]" .. C.reset .. bg
                elseif item.ahead and item.ahead > 0 then
                    status_pill = C.b_yellow .. string.format("[+%2d   ]", item.ahead) .. C.reset .. bg
                else
                    status_pill = C.gray .. "[Active]" .. C.reset .. bg
                end

                local name_w = math.max(8, left_w - 24)
                local rest_w = math.max(1, name_w - 2)
                local raw_name = item.name
                if #raw_name > rest_w then raw_name = raw_name:sub(1, rest_w) end
                local rest_disp = pad_right(raw_name, rest_w)
                local name_col
                if is_cur then
                    name_col = C.b_white .. C.bold
                elseif item.is_head then
                    name_col = C.b_green .. C.bold
                elseif item.is_merged then
                    name_col = C.green
                else
                    name_col = C.white
                end
                local name_disp = head_part .. name_col .. rest_disp .. C.reset

                l_str = string.format("%s%s %s %s %s %s",
                    bg, ptr, chk, type_pill, status_pill,
                    name_disp)
            elseif row == 1 and #state.filtered == 0 then
                local no_match = "  (No branches in this category or matching filter)"
                l_str = C.gray .. pad_right(no_match, left_w) .. C.reset
            else
                l_str = string.rep(" ", left_w)
            end

            local r_str = r_lines[row] or ""
            local sep_char = (cols >= 90) and (C.gray .. "│" .. C.reset) or ""
            add_line(l_str .. " " .. sep_char .. " " .. r_str)
        end

        -- 5. Footer & Dialog Prompt
        local footer_sep = string.rep("─", cols)
        add_line(C.gray .. footer_sep .. C.reset)

        local status_disp
        if state.mode == "confirm_delete" then
            status_disp = C.bg_red .. C.b_white .. C.bold .. " " .. state.input_prompt .. " (y/n): " .. C.reset
        elseif state.mode == "new_branch" then
            status_disp = C.b_yellow .. C.bold .. " " .. state.input_prompt .. ": " .. C.b_white .. state.input_buf .. "█" .. C.reset
        elseif #state.status_msg > 0 then
            local icon = (state.status_type == "ok") and "✔ " or "✖ "
            local col = (state.status_type == "ok") and C.b_green or C.b_red
            status_disp = col .. C.bold .. " " .. icon .. state.status_msg .. C.reset
        else
            local sel_cnt = 0
            for _ in pairs(state.selected_set) do sel_cnt = sel_cnt + 1 end
            local sel_indicator = (sel_cnt > 0) and string.format("%s(%d selected)%s ", C.b_green, sel_cnt, C.gray) or ""

            status_disp = string.format(" %s%sEnter%s:Checkout  %sd%s:Delete  %sD%s:Force-Delete  %sTab%s:Select  %sn%s:New  %ss%s:Sort  %s/%s:Filter  %sq%s:Quit",
                sel_indicator,
                C.b_yellow, C.gray, C.b_red, C.gray, C.b_magenta, C.gray, C.b_cyan, C.gray, C.b_green, C.gray, C.b_yellow, C.gray, C.b_cyan, C.gray, C.b_red, C.reset)
        end
        add_line(status_disp)

        -- Differential line rendering
        local diff_buf = { "\27[?2026h" }
        for r = 1, #frame_lines do
            if frame_lines[r] ~= prev_lines[r] then
                diff_buf[#diff_buf + 1] = string.format("\27[%d;1H%s", r, frame_lines[r])
                prev_lines[r] = frame_lines[r]
            end
        end
        diff_buf[#diff_buf + 1] = "\27[?2026l"
        if #diff_buf > 2 then
            Term.write_tui(table.concat(diff_buf))
        end
    end

    -- Main Event Loop
    while true do
        render()
        local key = Term.read_key()
        if state.mode ~= "confirm_delete" and state.mode ~= "new_branch" then
            state.status_msg = ""
        end

        if key == "CTRL_C" then
            break
        end

        -- A. Confirm Delete Mode
        if state.mode == "confirm_delete" then
            if key == "y" or key == "Y" or key == "ENTER" or key == "d" or key == "D" then
                if state.confirm_callback then
                    state.confirm_callback(true)
                end
                state.mode = "normal"
                state.confirm_callback = nil
                refresh_data()
                apply_filter()
            elseif key == "n" or key == "N" or key == "ESC" or key == "q" then
                state.mode = "normal"
                state.confirm_callback = nil
                state.status_msg = "Deletion cancelled."
                state.status_type = "ok"
            end

        -- B. New Branch Input Mode
        elseif state.mode == "new_branch" then
            if key == "ESC" then
                state.mode = "normal"
                state.input_buf = ""
                state.status_msg = "Branch creation cancelled."
            elseif key == "ENTER" then
                local bname = trim(state.input_buf)
                if #bname > 0 then
                    Term.restore()
                    local cmd = "git checkout -b " .. bname
                    local ok = os.execute(cmd)
                    Term.init()
                    if ok == 0 or ok == true then
                        state.status_msg = "Created and checked out: " .. bname
                        state.status_type = "ok"
                    else
                        state.status_msg = "Failed to create branch: " .. bname
                        state.status_type = "error"
                    end
                    refresh_data()
                    apply_filter()
                end
                state.mode = "normal"
                state.input_buf = ""
            elseif key == "BACKSPACE" then
                state.input_buf = state.input_buf:sub(1, math.max(0, #state.input_buf - 1))
            elseif #key == 1 then
                state.input_buf = state.input_buf .. key
            end

        -- C. Search / Filter Mode
        elseif state.mode == "filter" then
            if key == "ESC" then
                state.filter = state.prev_filter
                state.mode = "normal"
                apply_filter()
            elseif key == "ENTER" then
                state.mode = "normal"
            elseif key == "BACKSPACE" then
                state.filter = state.filter:sub(1, math.max(0, #state.filter - 1))
                apply_filter()
            elseif key == "CTRL_U" then
                state.filter = ""
                apply_filter()
            elseif key == "UP" then
                state.cursor = math.max(1, state.cursor - 1)
            elseif key == "DOWN" then
                state.cursor = math.min(math.max(1, #state.filtered), state.cursor + 1)
            elseif #key == 1 then
                state.filter = state.filter .. key
                apply_filter()
            end

        -- D. Normal Mode
        else
            if key == "q" or key == "ESC" then
                break
            elseif key == "j" or key == "DOWN" then
                state.cursor = math.min(math.max(1, #state.filtered), state.cursor + 1)
            elseif key == "k" or key == "UP" then
                state.cursor = math.max(1, state.cursor - 1)
            elseif key == "PGDN" then
                local _, rows = Term.get_size()
                state.cursor = math.min(math.max(1, #state.filtered), state.cursor + math.max(1, rows - 7))
            elseif key == "PGUP" then
                local _, rows = Term.get_size()
                state.cursor = math.max(1, state.cursor - math.max(1, rows - 7))
            elseif key == "g" or key == "HOME" then
                state.cursor = 1
            elseif key == "G" or key == "END" then
                state.cursor = math.max(1, #state.filtered)
            elseif key == "/" or key == "f" then
                state.prev_filter = state.filter
                state.mode = "filter"
            elseif key == "h" or key == "LEFT" then
                state.tab_idx = state.tab_idx - 1
                if state.tab_idx < 1 then state.tab_idx = #TABS end
                if (state.tab_idx == 3 or state.tab_idx == 4) and not state.remotes_loaded then
                    refresh_data(true)
                end
                apply_filter()
            elseif key == "l" or key == "RIGHT" then
                state.tab_idx = (state.tab_idx % #TABS) + 1
                if (state.tab_idx == 3 or state.tab_idx == 4) and not state.remotes_loaded then
                    refresh_data(true)
                end
                apply_filter()
            elseif key == "TAB" or key == "SPACE" then
                -- Toggle multi-selection on current item
                local cur = state.filtered[state.cursor]
                if cur and cur.is_remote then
                    state.status_msg = "Remote branches are read-only (local deletion only)."
                    state.status_type = "warn"
                elseif cur and not cur.is_head then
                    if state.selected_set[cur.name] then
                        state.selected_set[cur.name] = nil
                    else
                        state.selected_set[cur.name] = true
                    end
                elseif cur and cur.is_head then
                    state.status_msg = "Cannot select active HEAD branch."
                    state.status_type = "warn"
                end

            -- Checkout
            elseif key == "ENTER" then
                local cur = state.filtered[state.cursor]
                if cur then
                    if cur.is_head then
                        state.status_msg = "Already on " .. cur.name
                        state.status_type = "ok"
                    else
                        local ok, msg = Engine.checkout(cur)
                        break
                    end
                end

            -- Safe Delete ('d')
            elseif key == "d" then
                local to_delete = {}
                for name in pairs(state.selected_set) do
                    table.insert(to_delete, name)
                end
                if #to_delete == 0 and state.filtered[state.cursor] then
                    table.insert(to_delete, state.filtered[state.cursor].name)
                end

                local cur = state.filtered[state.cursor]
                if #to_delete == 0 then
                    state.status_msg = "No branch selected to delete."
                    state.status_type = "warn"
                elseif #to_delete == 1 and to_delete[1] == state.head_branch then
                    state.status_msg = "Cannot delete currently checked out branch (HEAD)."
                    state.status_type = "error"
                elseif #to_delete == 1 and cur and cur.is_remote then
                    state.status_msg = "Remote branches are protected and cannot be deleted (local only)."
                    state.status_type = "warn"
                else
                    state.mode = "confirm_delete"
                    state.input_prompt = string.format("Safe delete %d branch(es): %s [y/d/Enter: confirm, n/Esc: cancel]", #to_delete, table.concat(to_delete, ", "))
                    state.confirm_callback = function(confirmed)
                        if not confirmed then return end
                        local success_cnt = 0
                        local last_err = ""
                        for _, bname in ipairs(to_delete) do
                            local ok, res = Engine.delete_branch({ name = bname, is_head = (bname == state.head_branch), is_remote = false }, false)
                            if ok then
                                success_cnt = success_cnt + 1
                                state.selected_set[bname] = nil
                            else
                                last_err = res
                            end
                        end
                        if success_cnt == #to_delete then
                            state.status_msg = string.format("Deleted %d local branch(es).", success_cnt)
                            state.status_type = "ok"
                        elseif success_cnt > 0 then
                            state.status_msg = string.format("Deleted %d/%d branch(es). %s (use 'D' to force)", success_cnt, #to_delete, last_err)
                            state.status_type = "warn"
                        else
                            state.status_msg = string.format("Failed to delete: %s (use 'D' to force)", last_err)
                            state.status_type = "error"
                        end
                    end
                end

            -- Force Delete ('D')
            elseif key == "D" then
                local to_delete = {}
                for name in pairs(state.selected_set) do
                    table.insert(to_delete, name)
                end
                if #to_delete == 0 and state.filtered[state.cursor] then
                    table.insert(to_delete, state.filtered[state.cursor].name)
                end

                local cur = state.filtered[state.cursor]
                if #to_delete == 0 then
                    state.status_msg = "No branch selected to force delete."
                    state.status_type = "warn"
                elseif #to_delete == 1 and to_delete[1] == state.head_branch then
                    state.status_msg = "Cannot delete currently checked out branch (HEAD)."
                    state.status_type = "error"
                elseif #to_delete == 1 and cur and cur.is_remote then
                    state.status_msg = "Remote branches are protected and cannot be deleted (local only)."
                    state.status_type = "warn"
                else
                    state.mode = "confirm_delete"
                    state.input_prompt = string.format("FORCE delete (-D) %d branch(es): %s [y/D/Enter: confirm, n/Esc: cancel]", #to_delete, table.concat(to_delete, ", "))
                    state.confirm_callback = function(confirmed)
                        if not confirmed then return end
                        local success_cnt = 0
                        local last_err = ""
                        for _, bname in ipairs(to_delete) do
                            local ok, res = Engine.delete_branch({ name = bname, is_head = (bname == state.head_branch), is_remote = false }, true)
                            if ok then
                                success_cnt = success_cnt + 1
                                state.selected_set[bname] = nil
                            else
                                last_err = res
                            end
                        end
                        if success_cnt == #to_delete then
                            state.status_msg = string.format("Force-deleted %d local branch(es).", success_cnt)
                            state.status_type = "ok"
                        else
                            state.status_msg = string.format("Force-deleted %d/%d branch(es). %s", success_cnt, #to_delete, last_err)
                            state.status_type = "error"
                        end
                    end
                end

            -- New Branch ('n')
            elseif key == "n" then
                state.mode = "new_branch"
                state.input_prompt = "New branch name"
                state.input_buf = ""

            -- Refresh ('r')
            elseif key == "r" then
                refresh_data()
                apply_filter()
                state.status_msg = "Branch list refreshed."
                state.status_type = "ok"
            end
        end
    end

    Term.restore()
end

--------------------------------------------------------------------------------
-- 7. Non-Interactive CLI Mode (--list)
--------------------------------------------------------------------------------
local function cmd_list(opts)
    if not Engine.is_inside_git_repo() then
        io.stderr:write("Error: Not inside a Git repository.\n")
        os.exit(1)
    end

    local branches, head_branch = Engine.load_all_branches()
    print(string.format("%s=== Git Branches for %s (Current: %s) ===%s\n",
        C.b_cyan, Engine.get_repo_name(), head_branch or "detached", C.reset))

    printf = function(fmt, ...) print(string.format(fmt, ...)) end

    print(string.format("%s %-4s %-8s %-10s %-30s %s%s",
        C.bold, "HEAD", "TYPE", "STATUS", "BRANCH NAME", "TRACKING / SUBJECT", C.reset))
    print(string.rep("─", 80))

    local show_all = (opts.start_tab == 4 or opts.show_all)
    local show_remote = (opts.start_tab == 3 or opts.show_remote)
    local count = 0

    for _, b in ipairs(branches) do
        local pass = false
        if show_all then
            pass = true
        elseif show_remote then
            pass = b.is_remote
        else
            pass = not b.is_remote -- Local only by default
        end

        if pass then
            count = count + 1
            local head_mark = b.is_head and (C.b_green .. " *  " .. C.reset) or "    "
            local type_str = b.is_remote and (C.magenta .. "Remote" .. C.reset) or (C.b_blue .. "Local " .. C.reset)
            local status_str
            if b.is_head then
                status_str = C.b_green .. "HEAD" .. C.reset
            elseif b.is_merged then
                status_str = C.green .. "Merged" .. C.reset
            elseif b.ahead and b.ahead > 0 then
                status_str = C.b_yellow .. "+" .. b.ahead .. " ahd" .. C.reset
            else
                status_str = C.gray .. "Active" .. C.reset
            end

            local name_disp = b.name
            if b.is_head then name_disp = C.b_white .. C.bold .. name_disp .. C.reset end

            local detail = b.tracking and ("[" .. b.tracking .. "] ") or ""
            detail = detail .. (b.subject or "")
            if #detail > 35 then detail = detail:sub(1, 32) .. "..." end

            print(string.format("%s %-8s %-10s %-30s %s",
                head_mark, type_str, status_str, name_disp, C.gray .. detail .. C.reset))
        end
    end

    if not show_all and not show_remote then
        print(string.format("\n%s(Local branches shown. Use 'fbr -l -a' to include remote branches)%s", C.gray, C.reset))
    end
end

--------------------------------------------------------------------------------
-- 8. Automated Self-Test Suite (--test)
--------------------------------------------------------------------------------
local function run_tests()
    local passed = 0
    local failed = 0

    local function assert_eq(name, actual, expected)
        if actual == expected then
            passed = passed + 1
            print(string.format("  [PASS] %s", name))
        else
            failed = failed + 1
            print(string.format("  [FAIL] %s: expected '%s', got '%s'", name, tostring(expected), tostring(actual)))
        end
    end

    print("Running fbr.lua automated self-tests...")

    -- Test 1: String helpers
    assert_eq("trim removes surrounding whitespace", trim("  feat/branch  "), "feat/branch")
    assert_eq("pad_right pads string accurately", pad_right("main", 8), "main    ")

    -- Test 2: Fuzzy score
    assert_eq("fuzzy_score finds exact match", fuzzy_score("hist", "feat/fhist") ~= nil, true)
    assert_eq("fuzzy_score returns nil on non-match", fuzzy_score("xyz123", "master"), nil)

    -- Test 3: Parse branch line (regular local branch)
    local l1 = "  feat/fhist 0f2e2aa [origin/feat/fhist: ahead 1] feat: add fhist interactive TUI"
    local b1 = Engine.parse_branch_line(l1, {})
    assert_eq("b1 name is feat/fhist", b1.name, "feat/fhist")
    assert_eq("b1 is_head is false", b1.is_head, false)
    assert_eq("b1 tracking is origin/feat/fhist", b1.tracking, "origin/feat/fhist")
    assert_eq("b1 ahead is 1", b1.ahead, 1)

    -- Test 4: Parse active branch line with HEAD marker
    local l2 = "* master 6df5a02 [origin/master] feat(bin): add install-tools.sh"
    local b2 = Engine.parse_branch_line(l2, { master = true })
    assert_eq("b2 name is master", b2.name, "master")
    assert_eq("b2 is_head is true", b2.is_head, true)
    assert_eq("b2 is_merged is true", b2.is_merged, true)
    assert_eq("b2 tracking is origin/master", b2.tracking, "origin/master")

    -- Test 5: Parse branch with gone upstream
    local l3 = "  obsolete-branch 1234567 [origin/obsolete: gone] old commit"
    local b3 = Engine.parse_branch_line(l3, { ["obsolete-branch"] = true })
    assert_eq("b3 gone is true", b3.gone, true)
    assert_eq("b3 is_merged is true", b3.is_merged, true)

    -- Test 6: Safety check - cannot delete HEAD branch
    local ok_del, err_del = Engine.delete_branch({ name = "master", is_head = true }, false)
    assert_eq("delete_branch prevents deleting HEAD", ok_del, false)

    -- Test 7: Safety check - cannot delete remote branch
    local ok_remote, err_remote = Engine.delete_branch({ name = "origin/master", is_remote = true }, false)
    assert_eq("delete_branch prevents deleting remote branch", ok_remote, false)

    -- Test 7b: Deleting local branch with slashes
    os.execute(IS_WINDOWS and "git branch test/del-slash-branch master >nul 2>nul" or "git branch test/del-slash-branch master >/dev/null 2>&1")
    local ok_slash, msg_slash = Engine.delete_branch({ name = "test/del-slash-branch", is_remote = false, is_head = false }, false)
    assert_eq("delete_branch allows deleting local branch with slash", ok_slash, true)

    -- Test 8: Git repo detection
    assert_eq("Engine.is_inside_git_repo returns boolean", type(Engine.is_inside_git_repo()), "boolean")

    -- Test 9: Fast ref line parsing
    local r1 = "*|master|35336cd|origin/master|[ahead 1, behind 2]|feat: commit"
    local parsed_ref = Engine.parse_ref_line(r1, { master = true })
    assert_eq("parse_ref_line name is master", parsed_ref.name, "master")
    assert_eq("parse_ref_line is_head is true", parsed_ref.is_head, true)
    assert_eq("parse_ref_line ahead is 1", parsed_ref.ahead, 1)
    assert_eq("parse_ref_line behind is 2", parsed_ref.behind, 2)
    assert_eq("parse_ref_line is_merged is true", parsed_ref.is_merged, true)

    -- Test 10: Live branches loading (fast local and full with remotes)
    local local_b, head_l = Engine.load_local_branches()
    assert_eq("Engine.load_local_branches returns list", type(local_b), "table")
    local all_b, head_a = Engine.load_all_branches(true)
    assert_eq("Engine.load_all_branches(true) returns list", type(all_b), "table")
    print(string.format("  [INFO] Discovered %d local branches, %d total branches (HEAD: %s).", #local_b, #all_b, tostring(head_l)))

    -- Test 11: Divider alignment verification
    local test_cols = 100
    local test_left_w = math.floor(test_cols * 0.52)
    local test_raw_hdr = pad_right(string.format("  %-3s  %-8s %-8s   %s", "SEL", "TYPE", "STATUS", "BRANCH NAME"), test_left_w)
    assert_eq("header visible width equals left_w", #test_raw_hdr, test_left_w)

    local test_name_w = math.max(8, test_left_w - 24)
    local test_rest_w = math.max(1, test_name_w - 2)
    local test_branch_disp = pad_right("test-branch", test_rest_w)
    local test_body_plain = " " .. " " .. "[ ]" .. " " .. "[Local ]" .. " " .. "[Active]" .. " " .. "* " .. test_branch_disp
    assert_eq("body row visible width equals left_w", #test_body_plain, test_left_w)

    local test_empty = string.rep(" ", test_left_w)
    assert_eq("empty row width equals left_w", #test_empty, test_left_w)

    print(string.format("\nSelf-test summary: %d passed, %d failed.", passed, failed))
    if failed > 0 then os.exit(1) end
end

local function show_help()
    print([[
fbr.lua - High-Performance Git Branch Manager & Deleter TUI (LuaJIT + FFI)

Usage:
  luajit fbr.lua [OPTIONS] [QUERY]
  fbr [OPTIONS] [QUERY]

Options:
  -l, --list           Print formatted branch table and exit (local branches only by default)
  -m, --merged         Start pre-filtered on Merged branches (safe to delete)
  -r, --remote         Start on Remote branches tab
  -a, --all            Include both Local and Remote branches
  --test               Run automated test suite and exit
  -h, --help           Show this help message

TUI Keybindings:
  Enter                Checkout selected branch
  d                    Safe delete selected branch(es) (git branch -d)
  D                    Force delete selected branch(es) (git branch -D)
  Tab / Space          Toggle multi-selection checkbox [x] for batch actions
  n                    Create a new branch from current HEAD
  r                    Refresh branch list from repository
  / or f               Enter live search / filter mode
  h / l, Left / Right  Switch category tabs (Local -> Merged -> Remote -> All)
  j / k, Up / Down     Move selection cursor down / up
  PgUp / PgDn          Page scroll
  g / G, Home / End    Jump to first / last branch
  q / Esc              Exit]])
end

--------------------------------------------------------------------------------
-- 9. Entrypoint
--------------------------------------------------------------------------------
local args = { ... }
local opts = {
    mode = "tui",
    start_tab = 1, -- 1: Local, 2: Merged, 3: Remote, 4: All
    filter = "",
    show_all = false,
    show_remote = false,
}

local i = 1
while i <= #args do
    local a = args[i]
    if a == "-h" or a == "--help" then
        show_help()
        os.exit(0)
    elseif a == "--test" then
        run_tests()
        os.exit(0)
    elseif a == "-l" or a == "--list" then
        opts.mode = "list"
    elseif a == "-m" or a == "--merged" then
        opts.start_tab = 2 -- Merged
    elseif a == "-r" or a == "--remote" then
        opts.start_tab = 3 -- Remote
        opts.show_remote = true
    elseif a == "-a" or a == "--all" then
        opts.start_tab = 4 -- All
        opts.show_all = true
    else
        opts.filter = a
    end
    i = i + 1
end

if opts.mode == "list" then
    cmd_list(opts)
else
    run_tui(opts)
end
