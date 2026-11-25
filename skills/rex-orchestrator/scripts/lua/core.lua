-- Shared read-side contract, usable with a fake rex table under LuaJIT/Lua 5.1.
local M = {}
function M.persistent(text)
  for _,word in ipairs({"always","don[^ ]*t ask","ask again","persist","remember","session","conversation",
    "all edits","auto mode","accept edits","bypass"}) do
    if text:find(word) then return true end
  end
  return false
end
local json_escapes={
  ['"']='\\"', ['\\']='\\\\', ['\b']='\\b', ['\f']='\\f',
  ['\n']='\\n', ['\r']='\\r', ['\t']='\\t'
}
function M.json_string(s)
  return '"' .. s:gsub('[%z\1-\31\127\\"]',function(c)
    return json_escapes[c] or string.format('\\u%04x',c:byte())
  end) .. '"'
end
function M.tsv(s)
  local escapes={['\\']='\\\\', ['\t']='\\t', ['\n']='\\n', ['\r']='\\r'}
  return (s:gsub('[\\\t\n\r]',escapes))
end
function M.env(k)
  local v=os.getenv(k)
  return v and v~="" and v or nil
end
function M.basename(path)
  return path:gsub("/+$",""):match("([^/]+)$") or "/"
end
function M.dirname(path)
  if path:match("^/+$") then return "/" end
  local parent=path:gsub("/+$",""):match("^(.*)/[^/]+$")
  return parent=="" and "/" or parent or "."
end
-- Rex's JSON replaces invalid UTF-8. A path crosses it byte for byte as Latin-1: to_bytes spells every byte from
-- 0x80 as its two-byte UTF-8 character (always valid), from_bytes reads them back (the shell entry encodes argv so).
function M.to_bytes(s)
  return (s:gsub("[\128-\255]",function(c)
    local b=c:byte()
    return string.char(194+math.floor((b-128)/64),128+(b-128)%64)
  end))
end
function M.from_bytes(s)
  return (s:gsub("[\194\195][\128-\191]",function(c)
    return string.char(c:byte(2)+(c:byte(1)-194)*64)
  end))
end
function M.lines(s)
  local a = {}; s=s or ""; local text=s:gsub("\n$", ""); text=text .. "\n"
  for l in text:gmatch("(.-)\n") do a[#a+1]=l end
  return a
end
function M.trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
function M.starts(s, p) return s:sub(1, #p) == p end
function M.below(s, p) return M.starts(s, p .. "/") and #s > #p+1 end
-- Whether an executable file's first bytes are a compiled Mach-O (thin or universal, either byte order).
local machos={}
for _,magic in ipairs({"\206\250\237\254","\207\250\237\254","\254\237\250\206","\254\237\250\207",
  "\202\254\186\190","\202\254\186\191","\190\186\254\202","\191\186\254\202"}) do machos[magic]=true end
function M.compiled(head) return machos[head:sub(1,4)]==true end
-- The node a Node script's #! line runs, if the line has one of three exact shapes, else nil:
--   #!/ABS/PATH/node [OPTIONS]                -> "/ABS/PATH/node"
--   #!/usr/bin/env node [OPTIONS]             -> "node", for the caller to look up in a fixed PATH
--   #!/usr/bin/env -S node [OPTIONS]          -> "node"
-- (nodejs too.) OPTIONS are plain dashed words such as --no-warnings: no "=", no "/", no quotes or "$", so none names a
-- file, sets a value or reads the environment. Anything else, any other env option, assignment, "--", nested env or
-- argument, is not a Node launcher: env's own option and PATH rules are not modelled, so an odd line is never trusted.
local node_names={node=true,nodejs=true}
function M.node_launcher(head)
  if machos[head:sub(1,4)] then return nil end
  -- The kernel needs the newline within its first 512 bytes, or the file falls back to /bin/sh; stay one byte stricter.
  local newline=head:find("\n",1,true)
  if not newline or newline>511 then return nil end
  local line=head:match("^#!([^\n]*)\n")
  -- The kernel splits on space and tab only; any other control byte (\r, \v, \f, NUL, ...) is refused, not split on.
  if not line or line:find("[%z\1-\8\10-\31\127]") then return nil end
  local words={}
  for word in line:gmatch("[^ \t]+") do words[#words+1]=word end
  local first,program,options=words[1] or "",nil,2
  if first=="/usr/bin/env" then
    options=3
    if words[2]=="-S" then options=4; program=words[3] else program=words[2] end
    if not program or not node_names[program] then return nil end
  elseif M.starts(first,"/") and node_names[M.basename(first)] then
    program=first
  else
    return nil
  end
  for i=options,#words do
    if not words[i]:match("^%-%-?[%w][%w%-]*$") then return nil end
  end
  return program
end
function M.region(s)
  local a = {}; for _, l in ipairs(M.lines(s)) do
    if l:find("──────────", 1, true) then a={} else a[#a+1]=l end
  end; return a
end
function M.cursor(s)
  s=M.trim(s)
  for _, c in ipairs({"❯", "›", ">", "⟩"}) do
    if M.starts(s,c) then return (s:sub(#c+1):gsub("^%s*", "")) end
  end
end
function M.background(s)
  local a=M.lines(s); local upper, lower, prompt
  for i,l in ipairs(a) do
    if l:find("──────────",1,true) then upper=lower; lower=i
    elseif not lower and (M.starts(M.trim(l),"❯") or M.starts(M.trim(l),">")) then prompt=i end
  end
  local footer, turn, grok="", "", ""; local join=false
  for i=(lower or prompt or #a)+1,#a do footer=footer .. " " .. a[i] end
  for i=1,(upper or 1)-1 do
    local l=a[i]
    if M.starts(l,"✻") then turn=l; join=true
    elseif l:match("^%S") then turn=""; join=false
    elseif not l:match("%S") then join=false
    elseif join then turn=turn .. " " .. l end
  end
  local i=(upper or 1)-1
  while i>0 and not a[i]:match("%S") do i=i-1 end
  while i>0 and a[i]:match("%S") do grok=a[i]; i=i-1 end
  footer=(footer:gsub("%s+"," ")) .. " "; turn=turn:gsub("%s+"," ")
  local shell_pos, _, shells=footer:find("[^%w](%d+ shells?)[^%w]")
  local task_pos, _, tasks=footer:find("[^%w](%d+ task%(s%))[^%w]")
  if shell_pos and (not task_pos or shell_pos<task_pos) then return shells end
  if task_pos then return tasks end
  local count,word=turn:match("· (%d+) (shells?) still running")
  if count then return count .. " " .. word end
  count=M.trim(grok):match("^▾ Tasks (%d+)$")
  return count and count .. " task(s)" or ""
end
function M.mode(s)
  local last
  for _,l in ipairs(M.region(s)) do
    l=l .. " "
    local last_pos=0
    for _,c in ipairs({"⏵⏵", "⏸"}) do
      local p=1
      while true do
        local i,j=l:find(c .. " [a-z][a-z ]* on ",p)
        if not i then break end
        if i>last_pos then
          last=l:sub(i,j-1)
          last_pos=i
        end
        p=j+1
      end
    end
  end
  return last
end
local function continuation(b) return b and b>=0x80 and b<=0xbf end
function M.utf8_width(text,i)
  local a,b,c,d=text:byte(i,i+3)
  if a<0x80 then return 1 end
  if not continuation(b) then return nil end
  if a>=0xc2 and a<=0xdf then return 2 end
  if not continuation(c) then return nil end
  if a>=0xe0 and a<=0xef and (a~=0xe0 or b>=0xa0) and (a~=0xed or b<0xa0) then return 3 end
  if a>=0xf0 and a<=0xf4 and continuation(d) and (a~=0xf0 or b>=0x90) and (a~=0xf4 or b<=0x8f) then return 4 end
end

-- Raw C1 bytes are controls only when they are outside a valid multibyte character.
local function control_at(text,i)
  local b=text:byte(i)
  if b<32 or b>=127 and b<=159 then return 1,b end
  local width=M.utf8_width(text,i)
  if not width then return 1,nil,b end
  if b==0xc2 and text:byte(i+1)<=0x9f then return width,text:byte(i+1) end
  if width==3 and b==0xe2 then
    local middle,tail=text:byte(i+1,i+2)
    if middle==0x80 and tail>=0xaa and tail<=0xae then return width,0x202a+tail-0xaa end
    if middle==0x81 and tail>=0xa6 and tail<=0xa9 then return width,0x2066+tail-0xa6 end
  end
  return width
end
function M.prompt_control(text)
  local i=1
  while i<=#text do
    local width,code,invalid=control_at(text,i)
    if invalid or (code and code~=9 and code~=10 and code~=13) then return true end
    i=i+width
  end
  return false
end
function M.terminal_text(text)
  local chunks,start,i={},1,1
  while i<=#text do
    local width,code,invalid=control_at(text,i)
    local escaped
    if code or invalid then
      escaped=string.format(width==1 and "\\x%02X" or "\\u%04X",code or invalid)
    elseif text:byte(i)==0x5c then escaped="\\\\" end
    if escaped then
      chunks[#chunks+1]=text:sub(start,i-1)
      chunks[#chunks+1]=escaped
      start=i+width
    end
    i=i+width
  end
  chunks[#chunks+1]=text:sub(start)
  return table.concat(chunks)
end
-- terminal_text for text of several lines: each line escaped and started with INDENT, the line breaks kept.
function M.terminal_lines(text,indent)
  local lines={}
  for line in (text .. "\n"):gmatch("(.-)\n") do lines[#lines+1]=(indent or "") .. M.terminal_text(line) end
  return table.concat(lines,"\n")
end
function M.dir_control(path)
  return path:find("[\t\r\n]")~=nil or M.prompt_control(path)
end
function M.duration(opt, value, die)
  local n,u=value:match("^(%d+)([smh]?)$")
  if not n then die(opt .. " takes a duration such as 90, 90s, 10m or 1h, not '" .. value .. "'") end
  return tonumber(n)*({s=1,m=60,h=3600,[""]=1})[u]
end
function M.new(rex, fs, output)
  local C={rex=rex, fs=fs, session=nil, me="", force=false}
  C.out=(output and output.out) or function(s) io.stdout:write(s .. "\n"); io.stdout:flush() end
  -- Every diagnostic reaches the terminal escaped: notes and refusals carry paths, commands, labels, block ids and
  -- Rex's own errors, any of which can hold terminal controls or line breaks. A note and a raw line are one line each
  -- (a line break shows as \x0A), so nothing they carry can start a line that passes for another diagnostic. Text
  -- meant to span lines (a screen, a tool's stderr) goes through C.lines: every line indented by two spaces.
  local write=(output and output.raw) or function(s) io.stderr:write(s .. "\n"); io.stderr:flush() end
  C.raw=function(s) write(M.terminal_text(s)) end
  function C.lines(s) write(M.terminal_lines(s,"  ")) end
  C.note=(output and output.note) or function(s) write("rex-orchestrator: " .. M.terminal_text(s)) end
  C.finish=(output and output.finish) or function(code) rex.stop(code) end
  function C.die(s,code) C.note(s); C.finish(code or 2) end
  local env=M.env
  C.dir=env("REX_ORCHESTRATOR_STATE_DIR") or ((env("XDG_STATE_HOME") or (env("HOME") and env("HOME") .. "/.local/state")) or "")
  if not env("REX_ORCHESTRATOR_STATE_DIR") and C.dir~="" then C.dir=C.dir .. "/rex-orchestrator" end
  function C.sf(b) return C.dir .. "/" .. b:gsub("[^A-Za-z0-9_-]","_") end
  function C.read(b,suffix) return fs.read(C.sf(b) .. (suffix and "." .. suffix or "")) end
  function C.line(b,suffix,n) return M.lines(C.read(b,suffix))[n] or "" end
  function C.put(path,...) return fs.put(path,table.concat({...},"\n") .. "\n") end
  function C.call(b,method,args)
    if not C.attach() then return nil end
    args=args or {}; args.block_id=b; args.session_id=C.session
    for n=1,3 do
      local r,err=rex.block.call("com.superlogical.terminal",method,args)
      if type(r)=="table" then return r end
      if tostring(err):find("not_found",1,true) then return nil end
      if n<3 then rex.sleep(0.2) end
    end
  end
  function C.attach()
    if C.attached then return true end
    local attached,err=rex.call("session.attach",{session_id=C.session})
    if not attached then return nil,err end
    C.attached=true
    return true
  end
  local function key_event(key)
    local attached,err=C.attach()
    if not attached then return nil,err end
    local args={session_id=C.session,block_id=C.block,key=key}
    key.action="press"
    local pressed,why=rex.call("client.key",args)
    if not pressed then return nil,why end
    key.action="release"
    key.text=""
    local released,release_error=rex.call("client.key",args)
    if not released then return nil,release_error,true end
    return true
  end
  local function plain_key(name)
    return {key=name,mods="",consumed_mods="",text="",unshifted_codepoint=0,composing=false}
  end
  function C.enter()
    return key_event(plain_key("enter"))
  end
  local named_keys={enter="enter",escape="escape",esc="escape",tab="tab",
    up="arrow_up",down="arrow_down",left="arrow_left",right="arrow_right"}
  function C.send_keys(keys)
    local native={}
    for _,name in ipairs(keys) do
      local key
      if named_keys[name] then
        key=plain_key(named_keys[name])
      elseif name:match("^[0-9]$") then
        key=plain_key("digit_" .. name)
        key.text=name
        key.unshifted_codepoint=name:byte()
      elseif name=="ctrl+c" then
        key=plain_key("key_c")
        key.mods="ctrl"
        key.unshifted_codepoint=string.byte("c")
      end
      if not key then
        -- Rex's public key grammar includes layout-dependent chords and physical keys.
        -- Use its parser for those spellings, with the resolved block fixed before "--".
        local args={C.rex_bin,"send-key","-s",C.session,"-b",C.block,"--"}
        for _,input in ipairs(keys) do args[#args+1]=input end
        local result=rex.exec(args)
        if result and result.stderr~="" then C.lines((result.stderr:gsub("\n$",""))) end
        return result and result.ok
      end
      native[#native+1]=key
    end
    for _,key in ipairs(native) do
      local ok,err=key_event(key)
      if not ok then
        if err then C.raw("Error: " .. err) end
        return false
      end
    end
    return true
  end
  function C.resolve(query,kind,session)
    if not query or query=="" or query:sub(1,1)=="-" then return nil,3 end
    kind=kind or "block"
    local args={kinds={kind},queries={query}}
    if kind~="session" then args.scope={session=session or C.session} end
    local last_error
    for n=1,3 do
      local r,err=rex.call("target.resolve",args)
      local item=r and r.results and r.results[1]
      if item then
        local id=type(item.target)=="table" and item.target[kind .. "_id"]
        if item.status=="resolved" and id then return id end
        return nil,3,item
      end
      last_error=err
      if tostring(err):find("method_not_found",1,true) then return nil,1,err end
      if n<3 then rex.sleep(0.2) end
    end
    return nil,1,last_error
  end
  function C.resolve_failed(message,err)
    if type(err)=="string" and err:find("method_not_found",1,true) then
      C.die("this Rex server lacks target.resolve; update Rex",1)
    end
    C.die(message,1)
  end
  function C.init_state()
    if C.dir=="" then C.die("no state dir: set HOME or REX_ORCHESTRATOR_STATE_DIR") end
    if not fs.init(C.dir) then C.die("refusing state dir " .. C.dir .. ": a link, not a directory, or not yours (REX_ORCHESTRATOR_STATE_DIR picks another)") end
  end
  function C.missing_context()
    C.die("REX_SESSION is empty and no session could be resolved from REX_BLOCK; run inside a Rex terminal with REX_BLOCK set (check with: rex whoami --json), or set REX_SESSION explicitly")
  end
  function C.init()
    local context=C.context or {session=env("REX_SESSION"),block=env("REX_BLOCK")}
    local session=context.session~="" and context.session or nil
    local caller=context.block~="" and context.block or nil
    local query=session or caller
    if query then
      local canonical,code,reason
      if session==rex.session_id and session then canonical=session
      else canonical,code,reason=C.resolve(query,"session") end
      if code==1 then C.resolve_failed("rex did not answer for " .. (session and "REX_SESSION " or "REX_BLOCK ") .. query,reason) end
      -- A confirmed missing explicit scope is kept for the same diagnostic as block inspect.
      session=canonical or session
    end
    if not session then C.missing_context() end
    C.session=session
    C.init_state()
    if caller then
      local id,code,reason=C.resolve(caller)
      if id then C.me=id elseif code==3 then C.me=caller
      else C.resolve_failed("rex did not answer for REX_BLOCK " .. caller,reason) end
    end
  end
  local function explain_target(q,item)
    if type(item)~="table" then return end
    -- Quoted as given: the sink escapes it once (a JSON-quoted form would have its escapes escaped again).
    local quoted='"' .. (item.query or q) .. '"'
    if item.status=="ambiguous" then
      C.raw("Error: block target " .. quoted .. " is ambiguous" .. (item.reason and ": " .. item.reason or ""))
      for _,candidate in ipairs(item.candidates or {}) do
        local id=candidate.block_id or candidate.session_id or candidate.window_id or ""
        C.raw("  " .. (candidate.label or "") .. "  …" .. id:sub(-6) .. "  " .. (candidate.where or ""))
      end
    elseif item.status=="not_found" then
      C.raw("Error: block target " .. quoted .. " not found" .. (item.reason and ": " .. item.reason or ""))
    end
  end
  function C.target(q,gone)
    if not q or q=="" then C.die("missing BLOCK") end
    local b,code,reason=C.resolve(q)
    if not b then
      if code==3 then explain_target(q,reason) end
      if code==3 and gone and M.starts(q,"block:") then b=q; C.target_missing=true
      elseif code==3 then C.die("no such block in this session: " .. q)
      else C.resolve_failed("rex did not answer for block " .. q,reason) end
    end
    if b==C.me then C.die("refusing to target your own pane (" .. q .. ")") end
    C.block=b; return b
  end
  function C.need_me()
    if C.me=="" then C.die("REX_BLOCK is not set: run inside a Rex pane, or prefix the call with REX_SESSION=… REX_BLOCK=…") end
  end
  function C.owned(verb)
    C.need_me()
    if not C.force and C.line(C.block,"own",1)~=C.me then
      C.die(verb .. ": " .. C.block .. " was not launched from this pane; pass --force only for a pane the user named")
    end
  end
  function C.root(b)
    local r=C.call(b,"program_status"); if not r then return nil end
    local own=C.line(b,"own",3); local newest={}
    for _,v in ipairs(r.records or {}) do
      if v.id==nil and (v.effective_app or v.app)~=nil and (own=="" or tostring((v.owner or {}).pid)==own) then
        if not newest.updated_at or (v.updated_at or "")>=newest.updated_at then newest=v end
      end
    end
    return newest
  end
  function C.screen(b)
    local r=C.call(b,"format",{format="text",trim=true,unwrap=true})
    return r and type(r.content)=="string" and r.content:gsub("\n+$","") or nil
  end
  function C.exited(b)
    local p=C.call(b,"process")
    if p then
      local w=C.line(b,"own",2)
      return p.last_exit~=nil or p.child==nil or (w~="" and tostring(p.child.pid)~=w)
    end
    if C.gone(b) then return true end
    return nil
  end
  function C.gone(b)
    if not C.attach() then return nil end
    local r=rex.session.list_blocks{session_id=C.session}
    if r and type(r.blocks)=="table" then
      for _,v in ipairs(r.blocks) do if v.block_id==b then return false end end
      return true
    end
    return nil
  end
  function C.close_pane(b)
    for attempt=1,2 do
      local attached,err=C.attach()
      local closed
      if attached then closed,err=rex.call("block.close",{session_id=C.session,block_id=b}) end
      local reason=tostring(err)
      if closed or reason=="not_found" or reason:find("code=not_found",1,true) or
        reason:find("session_not_found",1,true) then return true end
      if attempt==1 then rex.sleep(0.3) end
    end
    return C.gone(b)
  end
  function C.remove_cage(path)
    local result=rex.exec({"/bin/bash",C.script_dir .. "/cage-cleanup.sh",C.dir,path})
    if result and result.stderr~="" then C.lines((result.stderr:gsub("\n$",""))) end
    return result and result.ok
  end
  function C.mark(rec)
    local screen=C.screen(C.block)
    if not screen then return false end
    local path=C.sf(C.block)
    return C.put(path,rec.updated_at or "",M.background(screen)) and fs.unlink(path .. ".hold")
  end
  function C.mark_since(rec)
    local previous=C.read(C.block)
    if not previous then return C.mark(rec) end
    return C.put(C.sf(C.block),rec.updated_at or "",M.lines(previous)[2] or "")
  end
  function C.status(b)
    local r=C.root(b) or {}; local p=C.call(b,"process"); local t=C.call(b,"title")
    local w=C.line(b,"own",2); local alive
    if p then alive=p.last_exit==nil and p.child~=nil and (w=="" or tostring(p.child.pid)==w) end
    local fields={state=r.state,kind=r.kind,msg=r.msg,title=t and t.title or "",alive=alive,
      cwd=p and ((p.foreground or {}).cwd or (p.child or {}).cwd)}
    -- Rex maps JSON null to nil, so encode required null fields explicitly.
    local a={}; for _,key in ipairs({"state","kind","msg","title","alive","cwd"}) do
      local v=fields[key]
      a[#a+1]='"' .. key .. '":' .. (v==nil and "null" or type(v)=="string" and M.json_string(v) or rex.json.encode(v))
    end
    local account=C.line(b,"cage",2)
    if account~="" then a[#a+1]='"account":' .. M.json_string(account) end
    return "{" .. table.concat(a,",") .. "}"
  end
  function C.kind(rec)
    local k=C.line(C.block,"own",4)
    return k~="" and k or ({["claude-code"]="claude",antigravity="agy",["grok-build"]="grok",codex="codex",muse="muse"})[(rec or {}).effective_app or (rec or {}).app] or ""
  end
  function C.pin(screen,rec)
    if not C.read(C.block,"own") or C.caged() or C.kind(rec)~="claude" then return true end
    local now=M.mode(screen); if not now then return true end
    local pin=C.line(C.block,"own",6)
    if pin=="" then
      local a=M.lines(C.read(C.block,"own")); for i=#a+1,7 do a[i]="" end; a[6]=now
      C.put(C.sf(C.block)..".own",unpack(a)); return true
    end
    if now==pin then return true end
    return false,"the permission mode changed from '" .. pin .. "' to '" .. now .. "'"
  end
  function C.stopped() return C.line(C.block,"stopped",1) end
  function C.stop(why) C.put(C.sf(C.block)..".stopped",why); C.note("stopped: " .. why .. "; report it") end
  function C.caged() return C.read(C.block,"cage")~=nil end
  function C.killed(kind)
    return fs.exists(C.dir .. "/disabled" .. (kind and kind~="" and "." .. kind or ""))~=false
  end
  function C.kill(why,kind)
    local path=C.dir .. "/disabled." .. (kind or "claude")
    if not fs.append(path,os.date("!%Y-%m-%dT%H:%M:%SZ") .. " " .. why .. "\n") then C.note("could not write " .. path) end
    write("\27[31mrex-orchestrator: stopped: " .. M.terminal_text(why) .. "; " .. M.terminal_text(path) ..
      " is set: report it, never remove it yourself\27[0m")
  end
  return C
end
return M
