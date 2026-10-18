#!/usr/bin/env luajit
-- fremote: Linux remote process inspector over OpenSSH; Windows/Linux client.
local script = (arg and arg[0] or ''):gsub('\\','/')
local directory = script:match('^(.*)/') or '.'
package.path = directory .. '/?.lua;' .. package.path
local native = require('fremote_native')
local Term = native.term
local C = {reset='\27[0m',cyan='\27[96m',green='\27[92m',red='\27[91m',yellow='\27[93m',gray='\27[90m',selected='\27[7m'}

local function clean(s)
    return tostring(s or ''):gsub('[%z\1-\31\127]', ' ')
end

local function hex(s)
    if #s % 2 ~= 0 or s:find('[^%x]') then error('Invalid text in collector response') end
    return (s:gsub('..',function(v) return string.char(tonumber(v,16)) end))
end

-- Measure UTF-8 columns, preserving whole characters when clipping narrow panes.
local function fit(value, width)
    local s,parts,used=clean(value),{},0
    for ch in s:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
        local a,b,c,d=ch:byte(1,4)
        local cp = #ch==1 and a or #ch==2 and (a-192)*64+b-128
            or #ch==3 and (a-224)*4096+(b-128)*64+c-128
            or (a-240)*262144+(b-128)*4096+(c-128)*64+d-128
        local w = ((cp>=0x300 and cp<=0x36f) or (cp>=0xfe00 and cp<=0xfe0f) or cp==0x200d) and 0
            or ((cp>=0x1100 and cp<=0x115f) or (cp>=0x2e80 and cp<=0xa4cf)
            or (cp>=0xac00 and cp<=0xd7af) or (cp>=0xf900 and cp<=0xfaff)
            or (cp>=0xff01 and cp<=0xff60) or cp>=0x1f300) and 2 or 1
        if used+w > width then break end
        parts[#parts+1],used=ch,used+w
    end
    return table.concat(parts)..string.rep(' ',math.max(0,width-used))
end

local function bytes(n)
    local units={'B','KB','MB','GB','TB'}; local i=1
    while n>=1024 and i<#units do n=n/1024; i=i+1 end
    return string.format('%.1f %s',n,units[i])
end

local function identity(p) return p.pid..':'..p.start end
local function shell_quote(s) return "'"..s:gsub("'","'\\''").."'" end

local function new_state(options)
    return {options=options,rows={},visible={},details={},marked={},cursor=1,scroll=1,
        query=options.filter or '',sort=options.sort or 'cpu',tab=1,mode='normal',
        connected=false,ever=false,status='Connecting...',errors='',buffer='',last=0,tree=false,outgoing={}}
end

local function refilter(s)
    local old=s.visible[s.cursor]; local key=old and identity(old)
    local rows={}
    for _,p in ipairs(s.rows) do
        local match=clean(p.pid..' '..p.user..' '..p.name):lower():find(s.query:lower(),1,true)
        if match and (s.tab~=2 or p.uid==s.uid) then rows[#rows+1]=p end
    end
    local sort=s.tab==3 and 'cpu' or s.tab==4 and 'ram' or s.sort
    table.sort(rows,function(a,b)
        local av,bv
        if sort=='ram' then av,bv=a.rss,b.rss
        elseif sort=='name' then av,bv=a.name:lower(),b.name:lower()
        elseif sort=='pid' then av,bv=a.pid,b.pid
        else av,bv=a.cpu,b.cpu end
        if av==bv then return a.pid<b.pid end
        if sort=='name' or sort=='pid' then return av<bv else return av>bv end
    end)
    if s.tree then
        local bypid,children,ordered,seen={},{},{},{}
        for _,p in ipairs(rows) do bypid[p.pid]=p end
        for _,p in ipairs(rows) do
            local parent=bypid[p.ppid] and p.ppid~=p.pid and p.ppid or 0
            children[parent]=children[parent] or {}; table.insert(children[parent],p)
        end
        local function visit(p,depth)
            if seen[p.pid] then return end
            seen[p.pid]=true; p.depth=depth; ordered[#ordered+1]=p
            for _,child in ipairs(children[p.pid] or {}) do visit(child,math.min(depth+1,20)) end
        end
        for _,p in ipairs(children[0] or {}) do visit(p,0) end
        for _,p in ipairs(rows) do visit(p,0) end
        rows=ordered
    end
    s.visible=rows
    s.cursor=math.max(1,math.min(s.cursor,#rows))
    for i,p in ipairs(rows) do if identity(p)==key then s.cursor=i; break end end
    s.scroll=math.max(1,math.min(s.scroll,math.max(1,#rows)))
end

local function consume(s,line)
    line=line:gsub('\r$','')
    local f={}; for field in (line..'\t'):gmatch('(.-)\t') do f[#f+1]=field end
    local kind=f[1]
    if kind=='H' then
        if #f~=8 or f[2]~='1' then error('Unsupported collector protocol; update both fremote files') end
        s.frame={rows={},epoch=tonumber(f[3]),uid=tonumber(f[4]),total=tonumber(f[5]),used=tonumber(f[6]),cpu=tonumber(f[7]),load=hex(f[8])}
        if not s.frame.epoch or not s.frame.uid or not s.frame.total or not s.frame.used or not s.frame.cpu then error('Invalid collector snapshot header') end
    elseif kind=='P' then
        if not s.frame or #f~=12 then error('Process record outside a snapshot') end
        local p={pid=tonumber(f[2]),ppid=tonumber(f[3]),start=tonumber(f[4]),cpu=tonumber(f[5]),rss=tonumber(f[6]),
            threads=tonumber(f[7]),state=clean(f[8]),uid=tonumber(f[9]),elapsed=tonumber(f[10]),user=hex(f[11]),name=hex(f[12])}
        for _,key in ipairs({'pid','ppid','start','cpu','rss','threads','uid','elapsed'}) do
            if not p[key] then error('Invalid process '..key) end
        end
        s.frame.rows[#s.frame.rows+1]=p
    elseif kind=='E' then
        if not s.frame then error('Snapshot terminator without header') end
        local frame=s.frame; s.frame=nil
        s.rows,s.uid,s.total,s.used,s.cpu,s.load,s.epoch=frame.rows,frame.uid,frame.total,frame.used,frame.cpu,frame.load,frame.epoch
        if not s.connected then s.status='Connected to '..s.options.host..'.'; s.status_error=false end
        s.connected,s.ever,s.last=true,true,native.now()
        local alive={}; s.bypid={}
        for _,p in ipairs(s.rows) do alive[identity(p)]=true; s.bypid[p.pid]=p end
        for key in pairs(s.marked) do if not alive[key] then s.marked[key]=nil end end
        for key in pairs(s.details) do if not alive[key] then s.details[key]=nil end end
        refilter(s)
    elseif kind=='D' then
        if #f~=5 or not tonumber(f[2]) or not tonumber(f[3]) then error('Invalid detail record') end
        s.details[f[2]..':'..f[3]]={command=hex(f[4]),cwd=hex(f[5])}
        s.reply=true
    elseif kind=='A' then
        if #f~=4 then error('Invalid action response') end
        s.status='PID '..f[2]..': '..hex(f[4]); s.status_error=false
        s.reply=true
    elseif kind=='X' then
        s.status=hex(f[2] or ''); s.status_error=true
        s.reply=true
    elseif kind=='R' then
        s.reply=true
    elseif line~='' then error('Unexpected collector response: '..clean(line):sub(1,200)) end
end

local function fresh(s)
    return s.connected and native.now()-s.last <= s.options.interval*3+5
end

local function flush_commands(s)
    if s.inflight or not s.child or #s.outgoing==0 then return true end
    local command=table.remove(s.outgoing,1)
    if command:sub(1,7)=='SIGNAL\t' and not fresh(s) then
        s.outgoing={}; s.status='Connection is stale; queued signals were cancelled.'; s.status_error=true
        return nil
    end
    local ok,err=s.child:write(command..'\n')
    if not ok then s.connected=false; s.errors=err; s.status='Connection lost: '..err; s.status_error=true; return nil end
    s.inflight=command
    return true
end

local function send(s,command)
    if not s.child then return nil end
    if #s.outgoing>=512 then s.status='Too many pending commands; wait for the remote collector.'; s.status_error=true; return nil end
    -- One small unacknowledged command at a time keeps Windows pipe writes
    -- bounded even if the remote side stops reading. Coalesce inspector requests.
    if command:sub(1,7)=='DETAIL\t' then
        for i=#s.outgoing,1,-1 do if s.outgoing[i]:sub(1,7)=='DETAIL\t' then table.remove(s.outgoing,i) end end
    end
    s.outgoing[#s.outgoing+1]=command
    return flush_commands(s)
end

local function build_ssh(options,collector)
    local args={'ssh','-T','-o','BatchMode=yes','-o','ConnectTimeout=8','-o','ServerAliveInterval=5','-o','ServerAliveCountMax=2'}
    for _,pair in ipairs({{'-p',options.port},{'-i',options.key},{'-J',options.jump},{'-F',options.config}}) do
        if pair[2] then args[#args+1]=pair[1]; args[#args+1]=pair[2] end
    end
    args[#args+1]='--'; args[#args+1]=options.host
    args[#args+1]='python3 -u -c '..shell_quote(collector)..' '..tostring(options.interval)
    return args
end

local function connect(s,collector)
    if s.child then s.child:close(); s.child=nil end
    s.connected=false; s.errors=''; s.buffer=''; s.frame=nil; s.details={}; s.marked={}; s.requested=nil; s.exit_pending=nil
    s.inflight=nil; s.outgoing={}; s.reply=false
    s.mode='normal'; s.confirm=nil
    s.status='Connecting to '..s.options.host..'...'; s.status_error=false
    s.started=native.now()
    local child,err=native.spawn(build_ssh(s.options,collector))
    s.child=child
    if not child then s.errors=err; s.status=err; s.status_error=true end
end

local function pump(s)
    if not s.child then return end
    local drained=false
    -- Drain bounded chunks each tick so large snapshots cannot freeze keyboard input.
    for _=1,32 do
        local out=s.child:read('stdout'); local err=s.child:read('stderr')
        if err~='' then s.errors=(s.errors..err):sub(-32768) end
        if out=='' and err=='' then drained=true; break end
        s.buffer=s.buffer..out
        while true do
            local pos=s.buffer:find('\n',1,true); if not pos then break end
            local line=s.buffer:sub(1,pos-1); s.buffer=s.buffer:sub(pos+1)
            local ok,why=pcall(consume,s,line)
            if not ok then
                s.errors=tostring(why); s.status='Collector protocol error: '..tostring(why); s.status_error=true
                s.connected=false; s.child:close(); s.child=nil; return
            end
            if s.reply then s.reply=false; s.inflight=nil; flush_commands(s) end
        end
        if #s.buffer>1048576 then
            s.errors='Collector response exceeds 1 MB line limit'; s.connected=false
            s.child:close(); s.child=nil; return
        end
    end
    if not drained then return end
    local exit=s.child:status()
    if exit~=nil then
        -- Exit may race the last read. Drain once more on the next tick.
        if not s.exit_pending then s.exit_pending=true; return end
        s.connected=false; s.frame=nil
        s.status='SSH exited ('..exit..'). '..(s.errors~='' and clean(s.errors) or 'Remote collector stopped.')..' Press r to reconnect.'
        s.status_error=true; s.child:close(); s.child=nil
    elseif not fresh(s) and native.now()-s.started > math.max(15,s.options.interval*3+5) then
        s.connected=false; s.status='No fresh snapshot. Press r to reconnect; process actions disabled.'; s.status_error=true
    end
end

local function request_detail(s)
    local p=s.visible[s.cursor]
    if p and fresh(s) and not s.options.demo then
        local key=identity(p)
        if not s.details[key] and s.requested~=key then
            s.requested=key; send(s,'DETAIL\t'..p.pid..'\t'..p.start)
        end
    end
end

local function begin_signal(s,sig)
    if not fresh(s) or s.options.demo then s.status='Process actions require a fresh live connection.'; s.status_error=true; return end
    local targets={}
    for _,p in ipairs(s.rows) do if s.marked[identity(p)] then targets[#targets+1]=p end end
    if #targets==0 and s.visible[s.cursor] then targets[1]=s.visible[s.cursor] end
    if #targets==0 then return end
    s.confirm={targets=targets,signal=sig}; s.mode='confirm'
end

local function handle(s,key,collector)
    if key=='quit' then return false end
    if s.mode=='confirm' then
        if key=='y' then
            if fresh(s) then
                for _,p in ipairs(s.confirm.targets) do
                    send(s,'SIGNAL\t'..p.pid..'\t'..p.start..'\t'..s.confirm.signal)
                end
            else s.status='Connection is stale; no signal was sent.'; s.status_error=true end
        elseif key~='n' and key~='esc' and key~='q' then return true end
        s.mode='normal'; s.confirm=nil
    elseif s.mode=='search' then
        if key=='enter' or key=='esc' then s.mode='normal'
        elseif key=='backspace' then
            local start=s.query:match('()[%z\1-\127\194-\244][\128-\191]*$')
            s.query=start and s.query:sub(1,start-1) or ''
        elseif #key==1 and key:byte()>=32 then s.query=s.query..key end
        s.previous_query=s.query; s.cursor=1; s.scroll=1; refilter(s)
    elseif s.mode=='help' then s.mode='normal'
    elseif key=='q' then return false
    elseif key=='/' then s.mode='search'; s.previous_query=s.query
    elseif key=='?' then s.mode='help'
    elseif key==']' then s.detail_scroll=(s.detail_scroll or 0)+3
    elseif key=='[' then s.detail_scroll=math.max(0,(s.detail_scroll or 0)-3)
    elseif key=='j' or key=='down' then s.cursor=math.min(#s.visible,s.cursor+1)
    elseif key=='k' or key=='up' then s.cursor=math.max(1,s.cursor-1)
    elseif key=='pgdown' then s.cursor=math.min(#s.visible,s.cursor+10)
    elseif key=='pgup' then s.cursor=math.max(1,s.cursor-10)
    elseif key=='home' or key=='g' then s.cursor=1
    elseif key=='end' or key=='G' then s.cursor=math.max(1,#s.visible)
    elseif key=='s' then
        local sorts={'cpu','ram','pid','name'}
        for i,v in ipairs(sorts) do if s.sort==v then s.sort=sorts[i%#sorts+1]; break end end
        refilter(s)
    elseif key=='tab' or key:match('^[1-4]$') then s.tab=tonumber(key) or s.tab%4+1; refilter(s)
    elseif key=='t' then s.tree=not s.tree; refilter(s)
    elseif key==' ' then local p=s.visible[s.cursor]; if p then local id=identity(p); s.marked[id]=not s.marked[id] end
    elseif key=='d' then begin_signal(s,15)
    elseif key=='K' then begin_signal(s,9)
    elseif key=='r' and not s.options.demo then
        if fresh(s) then send(s,'REFRESH'); s.requested=nil; s.details={}
        else connect(s,collector) end
    end
    s.cursor=math.max(1,s.cursor)
    local selected=s.visible[s.cursor]
    local selected_id=selected and identity(selected)
    if s.detail_selected~=selected_id then s.detail_scroll=0; s.detail_selected=selected_id end
    return true
end

local function wrap(lines,value,width)
    local remaining=clean(value)
    if remaining=='' then lines[#lines+1]=''; return end
    -- Slice only at UTF-8 boundaries; fit determines actual terminal columns.
    while #remaining>0 do
        local chunk=fit(remaining,width):gsub('%s+$','')
        if chunk=='' then break end
        lines[#lines+1]=chunk
        remaining=remaining:sub(#chunk+1):gsub('^%s+','')
    end
end

local function frame(s,cols,rows)
    local lines={}; local w=math.max(1,cols-1)
    if cols<76 or rows<15 then
        return {'fremote - terminal too small','Resize to at least 76 columns x 15 rows.','Press q to quit.'}
    end
    local age=s.ever and math.floor(native.now()-s.last) or 0
    local connection=fresh(s) and 'CONNECTED' or s.ever and 'DISCONNECTED / STALE' or s.child and 'CONNECTING' or 'DISCONNECTED'
    lines[#lines+1]=' FREMOTE | '..clean(s.options.host)..' | '..connection..(s.options.demo and ' | DEMO (actions disabled)' or '')
    lines[#lines+1]=s.ever and string.format(' Updated %s (%ds ago) | CPU %s | RAM %s / %s | Load %s',
        os.date('%H:%M:%S',s.epoch),age,s.cpu<0 and 'sampling...' or string.format('%.1f%%',s.cpu),bytes(s.used),bytes(s.total),s.load)
        or ' Waiting for Linux /proc collector. SSH keys/agent required; Python 3 required remotely.'
    lines[#lines+1]=string.format(' [%sAll] [%sMine] [%sCPU] [%sRAM] | Sort: %s | %s | Filter: %s%s',
        s.tab==1 and '*' or ' ',s.tab==2 and '*' or ' ',s.tab==3 and '*' or ' ',s.tab==4 and '*' or ' ',s.sort,s.tree and 'TREE' or 'LIST',s.query,s.mode=='search' and '_' or '')
    local left=math.floor((w-3)*0.54); local right=w-left-3
    lines[#lines+1]=fit('    PID    CPU%       RAM  NAME',left)..' | '..fit('INSPECTOR',right)
    local info={}; local p=s.visible[s.cursor]
    if s.mode=='confirm' then
        local action=s.confirm.signal==9 and 'SIGKILL (FORCE)' or 'SIGTERM'
        wrap(info,'CONFIRM '..action..' on '..s.options.host,right)
        info[#info+1]=''
        wrap(info,#s.confirm.targets..' selected process(es)',right)
        for i,target in ipairs(s.confirm.targets) do
            if i>4 then wrap(info,'... and '..(#s.confirm.targets-4)..' more',right); break end
            wrap(info,target.pid..' '..target.user..' '..target.name,right)
        end
        info[#info+1]=''; wrap(info,'[y] Send signal   [n/Esc] Cancel',right)
        wrap(info,'Default: cancel. No elevation.',right)
    elseif s.mode=='help' then
        for _,line in ipairs({'j/k or arrows: move','/: filter PID, user, name','1-4 / Tab: category','s: sort CPU/RAM/PID/name','t: tree of matching processes','Space: mark process','d: confirm SIGTERM','K: confirm SIGKILL','r: refresh / reconnect','[ / ]: scroll inspector','q or Ctrl+C: quit','CPU 100% = one core','First CPU sample: unavailable'}) do wrap(info,line,right) end
    elseif not fresh(s) then
        wrap(info,'Process actions disabled until fresh data arrives.',right)
        wrap(info,s.errors~='' and s.errors or s.status,right)
        info[#info+1]=''; wrap(info,'Check: ssh '..s.options.host,right)
        wrap(info,'Remote host needs Linux /proc and python3. Press r to reconnect.',right)
    elseif p then
        local detail=s.details[identity(p)]
        local parent=s.bypid and s.bypid[p.ppid]
        for _,v in ipairs({'PID        '..p.pid,'User       '..p.user,'Parent     '..p.ppid..(parent and ' '..parent.name or ''),'State      '..p.state,
            'Threads    '..p.threads,'Started    '..os.date('%Y-%m-%d %H:%M:%S',s.epoch-p.elapsed)..' (local)',
            'Elapsed    '..p.elapsed..' s','Memory     '..bytes(p.rss),
            'CPU        '..(p.cpu<0 and 'sampling...' or string.format('%.1f%%',p.cpu)), '', 'Command'}) do wrap(info,v,right) end
        wrap(info,detail and detail.command or 'Loading details...',right)
        info[#info+1]=''; info[#info+1]='Working directory'
        wrap(info,detail and detail.cwd or 'Loading details...',right)
    else info={'No matching processes.'} end
    local height=rows-7
    local detail_offset=s.mode=='confirm' and 0 or math.min(s.detail_scroll or 0,math.max(0,#info-height))
    s.scroll=math.max(1,math.min(s.scroll,math.max(1,#s.visible-height+1)))
    if s.cursor<s.scroll then s.scroll=s.cursor elseif s.cursor>=s.scroll+height then s.scroll=s.cursor-height+1 end
    s.scroll=math.max(1,s.scroll)
    for row=1,height do
        local i=s.scroll+row-1; local item=s.visible[i]; local label=''
        if item then
            label=string.format('%s%s%7d %7s %9s  %s%s',i==s.cursor and '>' or ' ',s.marked[identity(item)] and '*' or ' ',item.pid,
                item.cpu<0 and '--' or string.format('%.1f',item.cpu),bytes(item.rss),s.tree and string.rep(' ',item.depth or 0)..'+ ' or '',item.name)
        end
        local a=fit(label,left)
        if item and i==s.cursor then a=C.selected..a..C.reset end
        lines[#lines+1]=a..' | '..fit(info[row+detail_offset] or '',right)
    end
    local count=0; for _,v in pairs(s.marked) do if v then count=count+1 end end
    lines[#lines+1]=string.format(' %d matching / %d processes | %d marked | Refresh %.1fs',#s.visible,#s.rows,count,s.options.interval)
    lines[#lines+1]=s.mode=='confirm' and string.format(' [y] Send %s | [n/Esc] Cancel | %d process(es) on %s',
        s.confirm.signal==9 and 'SIGKILL' or 'SIGTERM',#s.confirm.targets,s.options.host) or clean(s.status)
    lines[#lines+1]=' / Filter  s Sort  t Tree  Space Mark  d Stop  K Force  r Refresh  ? Help  q Quit'
    for i,line in ipairs(lines) do
        if not line:find('\27',1,true) then lines[i]=fit(line,w) end
    end
    return lines
end

local function draw(s)
    local cols,rows=Term.size(); local lines=frame(s,cols,rows)
    local out={}
    if s.draw_cols~=cols or s.draw_rows~=rows then
        out[#out+1]='\27[0m\27[2J'; s.previous_lines={}; s.draw_cols,s.draw_rows=cols,rows
    end
    local previous=s.previous_lines or {}; s.previous_lines=previous
    for i=1,rows do
        local line=lines[i] or ''
        local color=i==1 and (fresh(s) and C.cyan or C.yellow) or i==rows-1 and s.status_error and C.red or ''
        local signature=color..line
        if previous[i]~=signature then
        previous[i]=signature
        -- frame's process row already has one bounded ANSI selection span.
        if line:find('\27',1,true) then
            out[#out+1]=string.format('\27[%d;1H%s\27[0m\27[K',i,line)
        else
            out[#out+1]=string.format('\27[%d;1H%s%s\27[0m\27[K',i,color,fit(line,math.max(0,cols-1)))
        end
        end
    end
    io.write(table.concat(out)); io.flush()
end

local function capture(args,timeout)
    local child,err=native.spawn(args); if not child then return nil,err end
    local out,errors='', ''; local deadline=native.now()+timeout
    while native.now()<deadline do
        local a,b=child:read('stdout'),child:read('stderr'); out=out..a; errors=errors..b
        local code=child:status()
        if code~=nil and a=='' and b=='' then child:close(); if code==0 then return out end; return nil,errors~='' and errors or 'Command exited '..code end
        native.sleep(10)
    end
    child:close(); return nil,'Timed out waiting for '..args[1]..': '..errors
end

local function choose_host()
    local output,err=capture({'luajit',directory..'/fssh.lua','--list'},10)
    if not output then return nil,'Cannot load host picker: '..err end
    local hosts={}
    for line in output:gmatch('[^\r\n]+') do
        local name,dest,port,source=line:match('^([^\t]+)\t([^\t]+)\t([^\t]*)\t([^\t]+)$')
        if name then hosts[#hosts+1]={name=name,host=source=='ssh-config' and name or dest,port=source~='ssh-config' and port~='' and port or nil,source=source} end
    end
    if #hosts==0 then return nil,'No saved hosts found. Run fremote <SSH-host-alias> or add a Host entry to ~/.ssh/config.' end
    local ok,why=Term.init(); if not ok then Term.restore(); return nil,why end
    local cursor,query,selected=1,'',nil
    local success,failure=xpcall(function()
        while true do
            local cols,rows=Term.size(); local filtered={}
            for _,h in ipairs(hosts) do if (h.name..' '..h.host):lower():find(query:lower(),1,true) then filtered[#filtered+1]=h end end
            cursor=math.max(1,math.min(cursor,#filtered))
            local first=math.max(1,cursor-math.max(1,rows-5)+1)
            for y=1,rows do
                local line=''
                if y==1 then line=' FREMOTE | Choose Linux SSH host'
                elseif y==2 then line=' Filter: '..query..'_'
                elseif y==rows then line=' Enter Connect | arrows Move | type Filter | Esc Cancel'
                elseif y>=4 then
                    local i=first+y-4; local h=filtered[i]
                    if h then line=(i==cursor and '> ' or '  ')..h.name..'  '..h.host..'  ['..h.source..']' end
                end
                io.write(string.format('\27[%d;1H%s\27[0m\27[K',y,fit(line,math.max(0,cols-1))))
            end
            io.flush(); local key=Term.key()
            if key=='quit' or key=='esc' then break
            elseif key=='enter' and filtered[cursor] then selected=filtered[cursor]; break
            elseif key=='up' then cursor=math.max(1,cursor-1)
            elseif key=='down' then cursor=math.min(#filtered,cursor+1)
            elseif key=='backspace' then query=query:sub(1,-2)
            elseif key and #key==1 and key:byte()>=32 then query=query..key; cursor=1 end
            native.sleep(30)
        end
    end,debug.traceback)
    Term.restore()
    if not success then return nil,failure end
    return selected
end

local function demo(s)
    consume(s,'H\t1\t'..os.time()..'\t1000\t34359738368\t19756849561\t68.0\t362e3220352e3820342e31')
    consume(s,'P\t18390\t1\t100\t0.0\t8388608\t1\tS\t1000\t12216\t726576696577\t62617368')
    consume(s,'P\t18432\t18390\t101\t142.6\t4509715660\t24\tR\t1000\t12216\t726576696577\t707974686f6e')
    consume(s,'P\t19501\t18390\t102\t38.2\t1181116006\t4\tS\t1000\t1600\t726576696577\t707974686f6e')
    consume(s,'E')
    s.details['18432:101']={command='python train.py --epochs 100 --config configs/large.yaml',cwd='/home/review/project'}
    s.status='Demo data. SSH connections and process actions are disabled.'
end

local HELP=[[
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
    local s=new_state({interval=2,host='demo',demo=true}); demo(s)
    assert(#s.rows==3 and #s.visible==3 and s.visible[1].pid==18432)
    local key=identity(s.visible[s.cursor]); s.sort='pid'; refilter(s)
    assert(identity(s.visible[s.cursor])==key,'Selection must follow process identity')
    s.tree=true; refilter(s); assert(s.visible[1].pid==18390)
    s.query='python'; refilter(s); assert(#s.visible==2)
    s.query='missing'; refilter(s); assert(#s.visible==0 and s.scroll==1)
    assert(not fit('\27[31mBAD',20):find('\27',1,true),'Remote ANSI must be neutralized')
    assert(#frame(s,100,30)==30 and #frame(s,40,10)==3)
    assert(hex('e4b8ad')=='中')
    local ok=pcall(consume,s,'H\t99'); assert(not ok,'Reject invalid protocol')
    print('fremote: ALL TESTS PASSED (protocol, selection, tree, filter, rendering, sanitization)')
end

local function main(args)
    local options={interval=2,sort='cpu'}; local i=1
    local fields={['--interval']='interval',['--sort']='sort',['--filter']='filter',['-p']='port',['-i']='key',['-J']='jump',['-F']='config'}
    while i<=#args do
        local a=args[i]
        if a=='--help' or a=='-h' then print(HELP); return 0
        elseif a=='--test' then self_test(); return 0
        elseif a=='--demo' then options.demo=true
        elseif a=='--list' then options.list=true
        elseif fields[a] then
            if not args[i+1] or args[i+1]=='' then error(a..' requires a value; use --help') end
            i=i+1; options[fields[a]]=args[i]
        elseif a:sub(1,1)=='-' then error('Unknown option '..a..'; use --help')
        elseif options.host then error('Only one host is supported; use --help')
        else options.host=a end
        i=i+1
    end
    options.interval=tonumber(options.interval)
    if not options.interval or options.interval~=options.interval or options.interval<0.2 or options.interval>60 then error('--interval must be between 0.2 and 60 seconds') end
    if not ({cpu=true,ram=true,pid=true,name=true})[options.sort] then error('--sort must be cpu, ram, pid, or name') end
    if options.demo then options.host='demo'
    elseif not options.host then
        if options.list then error('--list requires a host') end
        local host,err=choose_host(); if not host then if err then error(err) end; return 0 end
        options.host=host.host; options.port=options.port or host.port
    end
    if options.host=='' or options.host:sub(1,1)=='-' or options.host:find('[%z\r\n]') then error('Invalid SSH host; use a saved alias or user@hostname') end
    local s=new_state(options)
    local file,err=io.open(directory..'/fremote_collector.py','rb')
    if not file then error('Cannot load remote collector: '..tostring(err)..'. Deploy fremote_collector.py alongside fremote.lua.') end
    local collector=file:read('*a'); file:close()
    local success,result=xpcall(function()
        if options.demo then demo(s) else connect(s,collector) end
        if options.list then
            local deadline=native.now()+20
            while not s.ever and s.child and native.now()<deadline do pump(s); native.sleep(20) end
            if not s.ever then error(s.errors~='' and s.errors or s.status..' No snapshot received. Check ssh HOST and remote python3.') end
            print('PID\tCPU%\tRAM\tUSER\tNAME')
            for _,p in ipairs(s.visible) do print(string.format('%d\t%s\t%s\t%s\t%s',p.pid,p.cpu<0 and '--' or string.format('%.1f',p.cpu),bytes(p.rss),clean(p.user),clean(p.name))) end
            return 0
        end
        local ok,why=Term.init(); if not ok then error(why) end
        while true do
            if options.demo then s.last=native.now() else pump(s); request_detail(s) end
            draw(s)
            local key=Term.key()
            if key and not handle(s,key,collector) then break end
            native.sleep(50)
        end
        return 0
    end,debug.traceback)
    if s.child then s.child:close() end
    Term.restore()
    if not success then error(result,0) end
    return result
end

local ok,result=pcall(main,{...})
if not ok then io.stderr:write('fremote: '..tostring(result)..'\n'); os.exit(1) end
os.exit(result or 0)
