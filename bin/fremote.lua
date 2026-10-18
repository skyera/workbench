#!/usr/bin/env luajit
-- fremote: Linux remote process inspector over OpenSSH; Windows/Linux client.
local script = (arg and arg[0] or ''):gsub('\\', '/')
local directory = script:match('^(.*)/') or '.'
package.path = directory .. '/?.lua;' .. package.path
local native = require('fremote_native')
local terminal = native.term
local colors = {
    reset = '\27[0m',
    cyan = '\27[96m',
    green = '\27[92m',
    red = '\27[91m',
    yellow = '\27[93m',
    gray = '\27[90m',
    selected = '\27[7m',
}

local function clean(value)
    return tostring(value or ''):gsub('[%z\1-\31\127]', ' ')
end

local function hex(encoded_text)
    if #encoded_text % 2 ~= 0 or encoded_text:find('[^%x]') then
        error('Invalid text in collector response')
    end
    return (
        encoded_text:gsub('..', function(v)
            return string.char(tonumber(v, 16))
        end)
    )
end

-- Measure UTF-8 columns, preserving whole characters when clipping narrow panes.
local function fit(value, width)
    local text, characters, used_columns = clean(value), {}, 0
    for character in text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
        local first_byte, second_byte, third_byte, fourth_byte = character:byte(1, 4)
        local codepoint
        if #character == 1 then
            codepoint = first_byte
        elseif #character == 2 then
            codepoint = (first_byte - 192) * 64 + second_byte - 128
        elseif #character == 3 then
            codepoint = (first_byte - 224) * 4096 + (second_byte - 128) * 64 + third_byte - 128
        else
            codepoint = (first_byte - 240) * 262144
                + (second_byte - 128) * 4096
                + (third_byte - 128) * 64
                + fourth_byte
                - 128
        end

        local is_combining = (codepoint >= 0x300 and codepoint <= 0x36f)
            or (codepoint >= 0xfe00 and codepoint <= 0xfe0f)
            or codepoint == 0x200d
        local is_wide = (codepoint >= 0x1100 and codepoint <= 0x115f)
            or (codepoint >= 0x2e80 and codepoint <= 0xa4cf)
            or (codepoint >= 0xac00 and codepoint <= 0xd7af)
            or (codepoint >= 0xf900 and codepoint <= 0xfaff)
            or (codepoint >= 0xff01 and codepoint <= 0xff60)
            or codepoint >= 0x1f300

        local character_width = 1
        if is_combining then
            character_width = 0
        elseif is_wide then
            character_width = 2
        end
        if used_columns + character_width > width then
            break
        end
        characters[#characters + 1], used_columns = character, used_columns + character_width
    end
    return table.concat(characters) .. string.rep(' ', math.max(0, width - used_columns))
end

local function bytes(size)
    local units = { 'B', 'KB', 'MB', 'GB', 'TB' }
    local i = 1
    while size >= 1024 and i < #units do
        size = size / 1024
        i = i + 1
    end
    return string.format('%.1f %s', size, units[i])
end

local function identity(process)
    return process.pid .. ':' .. process.start
end

local function shell_quote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

-- Process state, filtering, and collector protocol.
local function new_state(options)
    return {
        options = options,
        rows = {},
        visible = {},
        details = {},
        marked = {},
        cursor = 1,
        scroll = 1,
        query = options.filter or '',
        sort = options.sort or 'cpu',
        tab = 1,
        mode = 'normal',
        connected = false,
        ever = false,
        status = 'Connecting...',
        errors = '',
        buffer = '',
        last = 0,
        tree = false,
        outgoing = {},
    }
end

local function refilter(state)
    local old = state.visible[state.cursor]
    local key = old and identity(old)
    local rows = {}
    for _, process in ipairs(state.rows) do
        local match = clean(process.pid .. ' ' .. process.user .. ' ' .. process.name)
            :lower()
            :find(state.query:lower(), 1, true)
        if match and (state.tab ~= 2 or process.uid == state.uid) then
            rows[#rows + 1] = process
        end
    end
    local sort = state.tab == 3 and 'cpu' or state.tab == 4 and 'ram' or state.sort
    table.sort(rows, function(left_process, right_process)
        local left_value, right_value
        if sort == 'ram' then
            left_value, right_value = left_process.rss, right_process.rss
        elseif sort == 'name' then
            left_value, right_value = left_process.name:lower(), right_process.name:lower()
        elseif sort == 'pid' then
            left_value, right_value = left_process.pid, right_process.pid
        else
            left_value, right_value = left_process.cpu, right_process.cpu
        end
        if left_value == right_value then
            return left_process.pid < right_process.pid
        end
        if sort == 'name' or sort == 'pid' then
            return left_value < right_value
        else
            return left_value > right_value
        end
    end)
    if state.tree then
        local bypid, children, ordered, seen = {}, {}, {}, {}
        for _, process in ipairs(rows) do
            bypid[process.pid] = process
        end
        for _, process in ipairs(rows) do
            local parent = bypid[process.ppid] and process.ppid ~= process.pid and process.ppid or 0
            children[parent] = children[parent] or {}
            table.insert(children[parent], process)
        end
        local function visit(process, depth)
            if seen[process.pid] then
                return
            end
            seen[process.pid] = true
            process.depth = depth
            ordered[#ordered + 1] = process
            for _, child in ipairs(children[process.pid] or {}) do
                visit(child, math.min(depth + 1, 20))
            end
        end
        for _, process in ipairs(children[0] or {}) do
            visit(process, 0)
        end
        for _, process in ipairs(rows) do
            visit(process, 0)
        end
        rows = ordered
    end
    state.visible = rows
    state.cursor = math.max(1, math.min(state.cursor, #rows))
    for i, process in ipairs(rows) do
        if identity(process) == key then
            state.cursor = i
            break
        end
    end
    state.scroll = math.max(1, math.min(state.scroll, math.max(1, #rows)))
end

local function consume(state, line)
    line = line:gsub('\r$', '')
    local fields = {}
    for field in (line .. '\t'):gmatch('(.-)\t') do
        fields[#fields + 1] = field
    end
    local kind = fields[1]
    if kind == 'H' then
        if #fields ~= 8 or fields[2] ~= '1' then
            error('Unsupported collector protocol; update both fremote files')
        end
        state.frame = {
            rows = {},
            epoch = tonumber(fields[3]),
            uid = tonumber(fields[4]),
            total = tonumber(fields[5]),
            used = tonumber(fields[6]),
            cpu = tonumber(fields[7]),
            load = hex(fields[8]),
        }
        if
            not state.frame.epoch
            or not state.frame.uid
            or not state.frame.total
            or not state.frame.used
            or not state.frame.cpu
        then
            error('Invalid collector snapshot header')
        end
    elseif kind == 'P' then
        if not state.frame or #fields ~= 12 then
            error('Process record outside a snapshot')
        end
        local process = {
            pid = tonumber(fields[2]),
            ppid = tonumber(fields[3]),
            start = tonumber(fields[4]),
            cpu = tonumber(fields[5]),
            rss = tonumber(fields[6]),
            threads = tonumber(fields[7]),
            state = clean(fields[8]),
            uid = tonumber(fields[9]),
            elapsed = tonumber(fields[10]),
            user = hex(fields[11]),
            name = hex(fields[12]),
        }
        for _, key in ipairs({ 'pid', 'ppid', 'start', 'cpu', 'rss', 'threads', 'uid', 'elapsed' }) do
            if not process[key] then
                error('Invalid process ' .. key)
            end
        end
        state.frame.rows[#state.frame.rows + 1] = process
    elseif kind == 'E' then
        if not state.frame then
            error('Snapshot terminator without header')
        end
        local frame = state.frame
        state.frame = nil
        state.rows, state.uid, state.total, state.used, state.cpu, state.load, state.epoch =
            frame.rows, frame.uid, frame.total, frame.used, frame.cpu, frame.load, frame.epoch
        if not state.connected then
            state.status = 'Connected to ' .. state.options.host .. '.'
            state.status_error = false
        end
        state.connected, state.ever, state.last = true, true, native.now()
        local alive = {}
        state.bypid = {}
        for _, process in ipairs(state.rows) do
            alive[identity(process)] = true
            state.bypid[process.pid] = process
        end
        for key in pairs(state.marked) do
            if not alive[key] then
                state.marked[key] = nil
            end
        end
        for key in pairs(state.details) do
            if not alive[key] then
                state.details[key] = nil
            end
        end
        refilter(state)
    elseif kind == 'D' then
        if #fields ~= 5 or not tonumber(fields[2]) or not tonumber(fields[3]) then
            error('Invalid detail record')
        end
        state.details[fields[2] .. ':' .. fields[3]] =
            { command = hex(fields[4]), cwd = hex(fields[5]) }
        state.reply = true
    elseif kind == 'A' then
        if #fields ~= 4 then
            error('Invalid action response')
        end
        state.status = 'PID ' .. fields[2] .. ': ' .. hex(fields[4])
        state.status_error = false
        state.reply = true
    elseif kind == 'X' then
        state.status = hex(fields[2] or '')
        state.status_error = true
        state.reply = true
    elseif kind == 'R' then
        state.reply = true
    elseif line ~= '' then
        error('Unexpected collector response: ' .. clean(line):sub(1, 200))
    end
end

local function fresh(state)
    return state.connected and native.now() - state.last <= state.options.interval * 3 + 5
end

local function flush_commands(state)
    if state.inflight or not state.child or #state.outgoing == 0 then
        return true
    end
    local command = table.remove(state.outgoing, 1)
    if command:sub(1, 7) == 'SIGNAL\t' and not fresh(state) then
        state.outgoing = {}
        state.status = 'Connection is stale; queued signals were cancelled.'
        state.status_error = true
        return nil
    end
    local ok, err = state.child:write(command .. '\n')
    if not ok then
        state.connected = false
        state.errors = err
        state.status = 'Connection lost: ' .. err
        state.status_error = true
        return nil
    end
    state.inflight = command
    return true
end

local function send(state, command)
    if not state.child then
        return nil
    end
    if #state.outgoing >= 512 then
        state.status = 'Too many pending commands; wait for the remote collector.'
        state.status_error = true
        return nil
    end
    -- One small unacknowledged command at a time keeps Windows pipe writes
    -- bounded even if the remote side stops reading. Coalesce inspector requests.
    if command:sub(1, 7) == 'DETAIL\t' then
        for i = #state.outgoing, 1, -1 do
            if state.outgoing[i]:sub(1, 7) == 'DETAIL\t' then
                table.remove(state.outgoing, i)
            end
        end
    end
    state.outgoing[#state.outgoing + 1] = command
    return flush_commands(state)
end

-- SSH connection lifecycle and command dispatch.
local function build_ssh(options, collector)
    local args = {
        'ssh',
        '-T',
        '-o',
        'BatchMode=yes',
        '-o',
        'ConnectTimeout=8',
        '-o',
        'ServerAliveInterval=5',
        '-o',
        'ServerAliveCountMax=2',
    }
    for _, pair in ipairs({
        { '-p', options.port },
        { '-i', options.key },
        { '-J', options.jump },
        { '-F', options.config },
    }) do
        if pair[2] then
            args[#args + 1] = pair[1]
            args[#args + 1] = pair[2]
        end
    end
    args[#args + 1] = '--'
    args[#args + 1] = options.host
    args[#args + 1] = 'python3 -u -c '
        .. shell_quote(collector)
        .. ' '
        .. tostring(options.interval)
    return args
end

local function connect(state, collector)
    if state.child then
        state.child:close()
        state.child = nil
    end
    state.connected = false
    state.errors = ''
    state.buffer = ''
    state.frame = nil
    state.details = {}
    state.marked = {}
    state.requested = nil
    state.exit_pending = nil
    state.inflight = nil
    state.outgoing = {}
    state.reply = false
    state.mode = 'normal'
    state.confirm = nil
    state.status = 'Connecting to ' .. state.options.host .. '...'
    state.status_error = false
    state.started = native.now()
    local child, err = native.spawn(build_ssh(state.options, collector))
    state.child = child
    if not child then
        state.errors = err
        state.status = err
        state.status_error = true
    end
end

local function pump(state)
    if not state.child then
        return
    end
    local drained = false
    -- Drain bounded chunks each tick so large snapshots cannot freeze keyboard input.
    for _ = 1, 32 do
        local out = state.child:read('stdout')
        local err = state.child:read('stderr')
        if err ~= '' then
            state.errors = (state.errors .. err):sub(-32768)
        end
        if out == '' and err == '' then
            drained = true
            break
        end
        state.buffer = state.buffer .. out
        while true do
            local pos = state.buffer:find('\n', 1, true)
            if not pos then
                break
            end
            local line = state.buffer:sub(1, pos - 1)
            state.buffer = state.buffer:sub(pos + 1)
            local ok, why = pcall(consume, state, line)
            if not ok then
                state.errors = tostring(why)
                state.status = 'Collector protocol error: ' .. tostring(why)
                state.status_error = true
                state.connected = false
                state.child:close()
                state.child = nil
                return
            end
            if state.reply then
                state.reply = false
                state.inflight = nil
                flush_commands(state)
            end
        end
        if #state.buffer > 1048576 then
            state.errors = 'Collector response exceeds 1 MB line limit'
            state.connected = false
            state.child:close()
            state.child = nil
            return
        end
    end
    if not drained then
        return
    end
    local exit = state.child:status()
    if exit ~= nil then
        -- Exit may race the last read. Drain once more on the next tick.
        if not state.exit_pending then
            state.exit_pending = true
            return
        end
        state.connected = false
        state.frame = nil
        state.status = 'SSH exited ('
            .. exit
            .. '). '
            .. (state.errors ~= '' and clean(state.errors) or 'Remote collector stopped.')
            .. ' Press r to reconnect.'
        state.status_error = true
        state.child:close()
        state.child = nil
    elseif
        not fresh(state)
        and native.now() - state.started > math.max(15, state.options.interval * 3 + 5)
    then
        state.connected = false
        state.status = 'No fresh snapshot. Press r to reconnect; process actions disabled.'
        state.status_error = true
    end
end

local function request_detail(state)
    local process = state.visible[state.cursor]
    if process and fresh(state) and not state.options.demo then
        local key = identity(process)
        if not state.details[key] and state.requested ~= key then
            state.requested = key
            send(state, 'DETAIL\t' .. process.pid .. '\t' .. process.start)
        end
    end
end

local function begin_signal(state, sig)
    if not fresh(state) or state.options.demo then
        state.status = 'Process actions require a fresh live connection.'
        state.status_error = true
        return
    end
    local targets = {}
    for _, process in ipairs(state.rows) do
        if state.marked[identity(process)] then
            targets[#targets + 1] = process
        end
    end
    if #targets == 0 and state.visible[state.cursor] then
        targets[1] = state.visible[state.cursor]
    end
    if #targets == 0 then
        return
    end
    state.confirm = { targets = targets, signal = sig }
    state.mode = 'confirm'
end

-- Keyboard input and confirmation handling.
local function handle(state, key, collector)
    if key == 'quit' then
        return false
    end
    if state.mode == 'confirm' then
        if key == 'y' then
            if fresh(state) then
                for _, process in ipairs(state.confirm.targets) do
                    send(
                        state,
                        'SIGNAL\t'
                            .. process.pid
                            .. '\t'
                            .. process.start
                            .. '\t'
                            .. state.confirm.signal
                    )
                end
            else
                state.status = 'Connection is stale; no signal was sent.'
                state.status_error = true
            end
        elseif key ~= 'n' and key ~= 'esc' and key ~= 'q' then
            return true
        end
        state.mode = 'normal'
        state.confirm = nil
    elseif state.mode == 'search' then
        if key == 'enter' or key == 'esc' then
            state.mode = 'normal'
        elseif key == 'backspace' then
            local start = state.query:match('()[%z\1-\127\194-\244][\128-\191]*$')
            state.query = start and state.query:sub(1, start - 1) or ''
        elseif #key == 1 and key:byte() >= 32 then
            state.query = state.query .. key
        end
        state.previous_query = state.query
        state.cursor = 1
        state.scroll = 1
        refilter(state)
    elseif state.mode == 'help' then
        state.mode = 'normal'
    elseif key == 'q' then
        return false
    elseif key == '/' then
        state.mode = 'search'
        state.previous_query = state.query
    elseif key == '?' then
        state.mode = 'help'
    elseif key == ']' then
        state.detail_scroll = (state.detail_scroll or 0) + 3
    elseif key == '[' then
        state.detail_scroll = math.max(0, (state.detail_scroll or 0) - 3)
    elseif key == 'j' or key == 'down' then
        state.cursor = math.min(#state.visible, state.cursor + 1)
    elseif key == 'k' or key == 'up' then
        state.cursor = math.max(1, state.cursor - 1)
    elseif key == 'pgdown' then
        state.cursor = math.min(#state.visible, state.cursor + 10)
    elseif key == 'pgup' then
        state.cursor = math.max(1, state.cursor - 10)
    elseif key == 'home' or key == 'g' then
        state.cursor = 1
    elseif key == 'end' or key == 'G' then
        state.cursor = math.max(1, #state.visible)
    elseif key == 's' then
        local sorts = { 'cpu', 'ram', 'pid', 'name' }
        for i, v in ipairs(sorts) do
            if state.sort == v then
                state.sort = sorts[i % #sorts + 1]
                break
            end
        end
        refilter(state)
    elseif key == 'tab' or key:match('^[1-4]$') then
        state.tab = tonumber(key) or state.tab % 4 + 1
        refilter(state)
    elseif key == 't' then
        state.tree = not state.tree
        refilter(state)
    elseif key == ' ' then
        local process = state.visible[state.cursor]
        if process then
            local id = identity(process)
            state.marked[id] = not state.marked[id]
        end
    elseif key == 'd' then
        begin_signal(state, 15)
    elseif key == 'K' then
        begin_signal(state, 9)
    elseif key == 'r' and not state.options.demo then
        if fresh(state) then
            send(state, 'REFRESH')
            state.requested = nil
            state.details = {}
        else
            connect(state, collector)
        end
    end
    state.cursor = math.max(1, state.cursor)
    local selected = state.visible[state.cursor]
    local selected_id = selected and identity(selected)
    if state.detail_selected ~= selected_id then
        state.detail_scroll = 0
        state.detail_selected = selected_id
    end
    return true
end

local function wrap(lines, value, width)
    local remaining = clean(value)
    if remaining == '' then
        lines[#lines + 1] = ''
        return
    end
    -- Slice only at UTF-8 boundaries; fit determines actual terminal columns.
    while #remaining > 0 do
        local chunk = fit(remaining, width):gsub('%s+$', '')
        if chunk == '' then
            break
        end
        lines[#lines + 1] = chunk
        remaining = remaining:sub(#chunk + 1):gsub('^%s+', '')
    end
end

-- Frame construction and incremental rendering.
local function frame(state, cols, rows)
    local lines = {}
    local w = math.max(1, cols - 1)
    if cols < 76 or rows < 15 then
        return {
            'fremote - terminal too small',
            'Resize to at least 76 columns x 15 rows.',
            'Press q to quit.',
        }
    end
    local age = state.ever and math.floor(native.now() - state.last) or 0
    local connection = fresh(state) and 'CONNECTED'
        or state.ever and 'DISCONNECTED / STALE'
        or state.child and 'CONNECTING'
        or 'DISCONNECTED'
    lines[#lines + 1] = ' FREMOTE | '
        .. clean(state.options.host)
        .. ' | '
        .. connection
        .. (state.options.demo and ' | DEMO (actions disabled)' or '')
    lines[#lines + 1] = state.ever
            and string.format(
                ' Updated %s (%ds ago) | CPU %s | RAM %s / %s | Load %s',
                os.date('%H:%M:%S', state.epoch),
                age,
                state.cpu < 0 and 'sampling...' or string.format('%.1f%%', state.cpu),
                bytes(state.used),
                bytes(state.total),
                state.load
            )
        or ' Waiting for Linux /proc collector. SSH keys/agent required; Python 3 required remotely.'
    lines[#lines + 1] = string.format(
        ' [%sAll] [%sMine] [%sCPU] [%sRAM] | Sort: %s | %s | Filter: %s%s',
        state.tab == 1 and '*' or ' ',
        state.tab == 2 and '*' or ' ',
        state.tab == 3 and '*' or ' ',
        state.tab == 4 and '*' or ' ',
        state.sort,
        state.tree and 'TREE' or 'LIST',
        state.query,
        state.mode == 'search' and '_' or ''
    )
    local left = math.floor((w - 3) * 0.54)
    local right = w - left - 3
    lines[#lines + 1] = fit('    PID    CPU%       RAM  NAME', left)
        .. ' | '
        .. fit('INSPECTOR', right)
    local info = {}
    local process = state.visible[state.cursor]
    if state.mode == 'confirm' then
        local action = state.confirm.signal == 9 and 'SIGKILL (FORCE)' or 'SIGTERM'
        wrap(info, 'CONFIRM ' .. action .. ' on ' .. state.options.host, right)
        info[#info + 1] = ''
        wrap(info, #state.confirm.targets .. ' selected process(es)', right)
        for i, target in ipairs(state.confirm.targets) do
            if i > 4 then
                wrap(info, '... and ' .. (#state.confirm.targets - 4) .. ' more', right)
                break
            end
            wrap(info, target.pid .. ' ' .. target.user .. ' ' .. target.name, right)
        end
        info[#info + 1] = ''
        wrap(info, '[y] Send signal   [n/Esc] Cancel', right)
        wrap(info, 'Default: cancel. No elevation.', right)
    elseif state.mode == 'help' then
        for _, line in ipairs({
            'j/k or arrows: move',
            '/: filter PID, user, name',
            '1-4 / Tab: category',
            's: sort CPU/RAM/PID/name',
            't: tree of matching processes',
            'Space: mark process',
            'd: confirm SIGTERM',
            'K: confirm SIGKILL',
            'r: refresh / reconnect',
            '[ / ]: scroll inspector',
            'q or Ctrl+C: quit',
            'CPU 100% = one core',
            'First CPU sample: unavailable',
        }) do
            wrap(info, line, right)
        end
    elseif not fresh(state) then
        wrap(info, 'Process actions disabled until fresh data arrives.', right)
        wrap(info, state.errors ~= '' and state.errors or state.status, right)
        info[#info + 1] = ''
        wrap(info, 'Check: ssh ' .. state.options.host, right)
        wrap(info, 'Remote host needs Linux /proc and python3. Press r to reconnect.', right)
    elseif process then
        local detail = state.details[identity(process)]
        local parent = state.bypid and state.bypid[process.ppid]
        for _, v in ipairs({
            'PID        ' .. process.pid,
            'User       ' .. process.user,
            'Parent     ' .. process.ppid .. (parent and ' ' .. parent.name or ''),
            'State      ' .. process.state,
            'Threads    ' .. process.threads,
            'Started    '
                .. os.date('%Y-%m-%d %H:%M:%S', state.epoch - process.elapsed)
                .. ' (local)',
            'Elapsed    ' .. process.elapsed .. ' s',
            'Memory     ' .. bytes(process.rss),
            'CPU        '
                .. (process.cpu < 0 and 'sampling...' or string.format('%.1f%%', process.cpu)),
            '',
            'Command',
        }) do
            wrap(info, v, right)
        end
        wrap(info, detail and detail.command or 'Loading details...', right)
        info[#info + 1] = ''
        info[#info + 1] = 'Working directory'
        wrap(info, detail and detail.cwd or 'Loading details...', right)
    else
        info = { 'No matching processes.' }
    end
    local height = rows - 7
    local detail_offset = state.mode == 'confirm' and 0
        or math.min(state.detail_scroll or 0, math.max(0, #info - height))
    state.scroll = math.max(1, math.min(state.scroll, math.max(1, #state.visible - height + 1)))
    if state.cursor < state.scroll then
        state.scroll = state.cursor
    elseif state.cursor >= state.scroll + height then
        state.scroll = state.cursor - height + 1
    end
    state.scroll = math.max(1, state.scroll)
    for row = 1, height do
        local i = state.scroll + row - 1
        local item = state.visible[i]
        local label = ''
        if item then
            label = string.format(
                '%s%s%7d %7s %9s  %s%s',
                i == state.cursor and '>' or ' ',
                state.marked[identity(item)] and '*' or ' ',
                item.pid,
                item.cpu < 0 and '--' or string.format('%.1f', item.cpu),
                bytes(item.rss),
                state.tree and string.rep(' ', item.depth or 0) .. '+ ' or '',
                item.name
            )
        end
        local a = fit(label, left)
        if item and i == state.cursor then
            a = colors.selected .. a .. colors.reset
        end
        lines[#lines + 1] = a .. ' | ' .. fit(info[row + detail_offset] or '', right)
    end
    local count = 0
    for _, v in pairs(state.marked) do
        if v then
            count = count + 1
        end
    end
    lines[#lines + 1] = string.format(
        ' %d matching / %d processes | %d marked | Refresh %.1fs',
        #state.visible,
        #state.rows,
        count,
        state.options.interval
    )
    lines[#lines + 1] = state.mode == 'confirm'
            and string.format(
                ' [y] Send %s | [n/Esc] Cancel | %d process(es) on %s',
                state.confirm.signal == 9 and 'SIGKILL' or 'SIGTERM',
                #state.confirm.targets,
                state.options.host
            )
        or clean(state.status)
    lines[#lines + 1] =
        ' / Filter  s Sort  t Tree  Space Mark  d Stop  K Force  r Refresh  ? Help  q Quit'
    for i, line in ipairs(lines) do
        if not line:find('\27', 1, true) then
            lines[i] = fit(line, w)
        end
    end
    return lines
end

local function draw(state)
    local cols, rows = terminal.size()
    local lines = frame(state, cols, rows)
    local out = {}
    if state.draw_cols ~= cols or state.draw_rows ~= rows then
        out[#out + 1] = '\27[0m\27[2J'
        state.previous_lines = {}
        state.draw_cols, state.draw_rows = cols, rows
    end
    local previous = state.previous_lines or {}
    state.previous_lines = previous
    for i = 1, rows do
        local line = lines[i] or ''
        local color = i == 1 and (fresh(state) and colors.cyan or colors.yellow)
            or i == rows - 1 and state.status_error and colors.red
            or ''
        local signature = color .. line
        if previous[i] ~= signature then
            previous[i] = signature
            -- frame's process row already has one bounded ANSI selection span.
            if line:find('\27', 1, true) then
                out[#out + 1] = string.format('\27[%d;1H%s\27[0m\27[K', i, line)
            else
                out[#out + 1] = string.format(
                    '\27[%d;1H%s%s\27[0m\27[K',
                    i,
                    color,
                    fit(line, math.max(0, cols - 1))
                )
            end
        end
    end
    io.write(table.concat(out))
    io.flush()
end

-- Saved-host discovery and picker.
local function capture(args, timeout)
    local child, err = native.spawn(args)
    if not child then
        return nil, err
    end
    local out, errors = '', ''
    local deadline = native.now() + timeout
    while native.now() < deadline do
        local stdout_chunk = child:read('stdout')
        local stderr_chunk = child:read('stderr')
        out = out .. stdout_chunk
        errors = errors .. stderr_chunk
        local code = child:status()
        if code ~= nil and stdout_chunk == '' and stderr_chunk == '' then
            child:close()
            if code == 0 then
                return out
            end
            return nil, errors ~= '' and errors or 'Command exited ' .. code
        end
        native.sleep(10)
    end
    child:close()
    return nil, 'Timed out waiting for ' .. args[1] .. ': ' .. errors
end

local function choose_host()
    local output, err = capture({ 'luajit', directory .. '/fssh.lua', '--list' }, 10)
    if not output then
        return nil, 'Cannot load host picker: ' .. err
    end
    local hosts = {}
    for line in output:gmatch('[^\r\n]+') do
        local name, dest, port, source = line:match('^([^\t]+)\t([^\t]+)\t([^\t]*)\t([^\t]+)$')
        if name then
            hosts[#hosts + 1] = {
                name = name,
                host = source == 'ssh-config' and name or dest,
                port = source ~= 'ssh-config' and port ~= '' and port or nil,
                source = source,
            }
        end
    end
    if #hosts == 0 then
        return nil,
            'No saved hosts found. Run fremote <SSH-host-alias> or add a Host entry to ~/.ssh/config.'
    end
    local ok, why = terminal.init()
    if not ok then
        terminal.restore()
        return nil, why
    end
    local cursor, query, selected = 1, '', nil
    local success, failure = xpcall(function()
        while true do
            local cols, rows = terminal.size()
            local filtered = {}
            for _, h in ipairs(hosts) do
                if (h.name .. ' ' .. h.host):lower():find(query:lower(), 1, true) then
                    filtered[#filtered + 1] = h
                end
            end
            cursor = math.max(1, math.min(cursor, #filtered))
            local first = math.max(1, cursor - math.max(1, rows - 5) + 1)
            for y = 1, rows do
                local line = ''
                if y == 1 then
                    line = ' FREMOTE | Choose Linux SSH host'
                elseif y == 2 then
                    line = ' Filter: ' .. query .. '_'
                elseif y == rows then
                    line = ' Enter Connect | arrows Move | type Filter | Esc Cancel'
                elseif y >= 4 then
                    local i = first + y - 4
                    local h = filtered[i]
                    if h then
                        line = (i == cursor and '> ' or '  ')
                            .. h.name
                            .. '  '
                            .. h.host
                            .. '  ['
                            .. h.source
                            .. ']'
                    end
                end
                io.write(
                    string.format('\27[%d;1H%s\27[0m\27[K', y, fit(line, math.max(0, cols - 1)))
                )
            end
            io.flush()
            local key = terminal.key()
            if key == 'quit' or key == 'esc' then
                break
            elseif key == 'enter' and filtered[cursor] then
                selected = filtered[cursor]
                break
            elseif key == 'up' then
                cursor = math.max(1, cursor - 1)
            elseif key == 'down' then
                cursor = math.min(#filtered, cursor + 1)
            elseif key == 'backspace' then
                query = query:sub(1, -2)
            elseif key and #key == 1 and key:byte() >= 32 then
                query = query .. key
                cursor = 1
            end
            native.sleep(30)
        end
    end, debug.traceback)
    terminal.restore()
    if not success then
        return nil, failure
    end
    return selected
end

local function demo(state)
    consume(
        state,
        'H\t1\t' .. os.time() .. '\t1000\t34359738368\t19756849561\t68.0\t362e3220352e3820342e31'
    )
    consume(state, 'P\t18390\t1\t100\t0.0\t8388608\t1\tS\t1000\t12216\t726576696577\t62617368')
    consume(
        state,
        'P\t18432\t18390\t101\t142.6\t4509715660\t24\tR\t1000\t12216\t726576696577\t707974686f6e'
    )
    consume(
        state,
        'P\t19501\t18390\t102\t38.2\t1181116006\t4\tS\t1000\t1600\t726576696577\t707974686f6e'
    )
    consume(state, 'E')
    state.details['18432:101'] = {
        command = 'python train.py --epochs 100 --config configs/large.yaml',
        cwd = '/home/review/project',
    }
    state.status = 'Demo data. SSH connections and process actions are disabled.'
end

local HELP = [[
Usage: fremote [OPTIONS] [HOST]
Linux remote process inspector using OpenSSH and remote Python 3.
No host: pick a saved host using fssh's host discovery.

  --list                 Print one process snapshot and exit
  --interval SECONDS     Refresh interval, 0.2 to 60 (default 2)
  --sort cpu|ram|pid|name Initial sort (default cpu)
  --filter QUERY         Match process name, user, or PID
  -p PORT  -i KEY         SSH port / identity file
  -J HOST  -F CONFIG      SSH jump host / alternate configuration
  --demo                 Preview without SSH or process actions
  --test                 Run local UI/protocol self-tests
  -h, --help             Show help

Keys: j/k/arrows move, / filter, 1-4 categories, s sort, t tree,
Space mark, d confirm SIGTERM, K confirm SIGKILL, r refresh/reconnect,
[ / ] scroll inspector,
? help, q/Ctrl+C quit. Confirmations default to cancel.
Authentication uses keys or an agent (BatchMode). To diagnose: ssh HOST.
Signals require Linux pidfd support and remote Python 3.9+.
]]

local function self_test()
    local state = new_state({ interval = 2, host = 'demo', demo = true })
    demo(state)
    assert(#state.rows == 3 and #state.visible == 3 and state.visible[1].pid == 18432)
    local key = identity(state.visible[state.cursor])
    state.sort = 'pid'
    refilter(state)
    assert(identity(state.visible[state.cursor]) == key, 'Selection must follow process identity')
    state.tree = true
    refilter(state)
    assert(state.visible[1].pid == 18390)
    state.query = 'python'
    refilter(state)
    assert(#state.visible == 2)
    state.query = 'missing'
    refilter(state)
    assert(#state.visible == 0 and state.scroll == 1)
    assert(not fit('\27[31mBAD', 20):find('\27', 1, true), 'Remote ANSI must be neutralized')
    assert(#frame(state, 100, 30) == 30 and #frame(state, 40, 10) == 3)
    assert(hex('e4b8ad') == '中')
    local ok = pcall(consume, state, 'H\t99')
    assert(not ok, 'Reject invalid protocol')
    print('fremote: ALL TESTS PASSED (protocol, selection, tree, filter, rendering, sanitization)')
end

local function main(args)
    local options = { interval = 2, sort = 'cpu' }
    local i = 1
    local fields = {
        ['--interval'] = 'interval',
        ['--sort'] = 'sort',
        ['--filter'] = 'filter',
        ['-p'] = 'port',
        ['-i'] = 'key',
        ['-J'] = 'jump',
        ['-F'] = 'config',
    }
    while i <= #args do
        local a = args[i]
        if a == '--help' or a == '-h' then
            print(HELP)
            return 0
        elseif a == '--test' then
            self_test()
            return 0
        elseif a == '--demo' then
            options.demo = true
        elseif a == '--list' then
            options.list = true
        elseif fields[a] then
            if not args[i + 1] or args[i + 1] == '' then
                error(a .. ' requires a value; use --help')
            end
            i = i + 1
            options[fields[a]] = args[i]
        elseif a:sub(1, 1) == '-' then
            error('Unknown option ' .. a .. '; use --help')
        elseif options.host then
            error('Only one host is supported; use --help')
        else
            options.host = a
        end
        i = i + 1
    end
    options.interval = tonumber(options.interval)
    if
        not options.interval
        or options.interval ~= options.interval
        or options.interval < 0.2
        or options.interval > 60
    then
        error('--interval must be between 0.2 and 60 seconds')
    end
    if not ({ cpu = true, ram = true, pid = true, name = true })[options.sort] then
        error('--sort must be cpu, ram, pid, or name')
    end
    if options.demo then
        options.host = 'demo'
    elseif not options.host then
        if options.list then
            error('--list requires a host')
        end
        local host, err = choose_host()
        if not host then
            if err then
                error(err)
            end
            return 0
        end
        options.host = host.host
        options.port = options.port or host.port
    end
    if options.host == '' or options.host:sub(1, 1) == '-' or options.host:find('[%z\r\n]') then
        error('Invalid SSH host; use a saved alias or user@hostname')
    end
    local state = new_state(options)
    local file, err = io.open(directory .. '/fremote_collector.py', 'rb')
    if not file then
        error(
            'Cannot load remote collector: '
                .. tostring(err)
                .. '. Deploy fremote_collector.py alongside fremote.lua.'
        )
    end
    local collector = file:read('*a')
    file:close()
    local success, result = xpcall(function()
        if options.demo then
            demo(state)
        else
            connect(state, collector)
        end
        if options.list then
            local deadline = native.now() + 20
            while not state.ever and state.child and native.now() < deadline do
                pump(state)
                native.sleep(20)
            end
            if not state.ever then
                error(
                    state.errors ~= '' and state.errors
                        or state.status
                            .. ' No snapshot received. Check ssh HOST and remote python3.'
                )
            end
            print('PID\tCPU%\tRAM\tUSER\tNAME')
            for _, process in ipairs(state.visible) do
                print(
                    string.format(
                        '%d\t%s\t%s\t%s\t%s',
                        process.pid,
                        process.cpu < 0 and '--' or string.format('%.1f', process.cpu),
                        bytes(process.rss),
                        clean(process.user),
                        clean(process.name)
                    )
                )
            end
            return 0
        end
        local ok, why = terminal.init()
        if not ok then
            error(why)
        end
        while true do
            if options.demo then
                state.last = native.now()
            else
                pump(state)
                request_detail(state)
            end
            draw(state)
            local key = terminal.key()
            if key and not handle(state, key, collector) then
                break
            end
            native.sleep(50)
        end
        return 0
    end, debug.traceback)
    if state.child then
        state.child:close()
    end
    terminal.restore()
    if not success then
        error(result, 0)
    end
    return result
end

-- Command-line entry point.
local ok, result = pcall(main, { ... })
if not ok then
    io.stderr:write('fremote: ' .. tostring(result) .. '\n')
    os.exit(1)
end
os.exit(result or 0)
