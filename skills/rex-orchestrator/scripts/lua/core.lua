-- Shared read-side contract, usable with a fake rex table under LuaJIT/Lua 5.1.
local M = {}
function M.lines(s)
  local a = {}; s=s or ""; local text=s:gsub("\n$", ""); text=text .. "\n"
  for l in text:gmatch("(.-)\n") do a[#a+1]=l end
  return a
end
function M.trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
function M.starts(s, p) return s:sub(1, #p) == p end
function M.below(s, p) return M.starts(s, p .. "/") and #s > #p+1 end
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
    local last_pos=0
    for _,c in ipairs({"⏵⏵", "⏸"}) do
      local p=1
      while true do
        local i,j=l:find(c .. " [a-z][a-z ]* on",p)
        if not i then break end
        if i>last_pos and (j==#l or l:sub(j+1,j+1)==" ") then
          last=l:sub(i,j)
          last_pos=i
        end
        p=j+1
      end
    end
  end
  return last
end
function M.duration(opt, value, die)
  local n,u=value:match("^(%d+)([smh]?)$")
  if not n then die(opt .. " takes a duration such as 90, 90s, 10m or 1h, not '" .. value .. "'") end
  return tonumber(n)*({s=1,m=60,h=3600,[""]=1})[u]
end
function M.new(rex, fs, output)
  local C={rex=rex, fs=fs, session=nil, me="", force=false}
  C.out=(output and output.out) or function(s) io.stdout:write(s .. "\n"); io.stdout:flush() end
  C.note=(output and output.note) or function(s) io.stderr:write("rex-orchestrator: " .. s .. "\n"); io.stderr:flush() end
  function C.die(s,code) C.note(s); rex.stop(code or 2) end
  local function env(k) local v=os.getenv(k); return v and v~="" and v or nil end
  C.dir=env("REX_ORCHESTRATOR_STATE_DIR") or ((env("XDG_STATE_HOME") or (env("HOME") and env("HOME") .. "/.local/state")) or "")
  if not env("REX_ORCHESTRATOR_STATE_DIR") and C.dir~="" then C.dir=C.dir .. "/rex-orchestrator" end
  function C.sf(b) return C.dir .. "/" .. b:gsub("[^A-Za-z0-9_-]","_") end
  function C.read(b,suffix) return fs.read(C.sf(b) .. (suffix and "." .. suffix or "")) end
  function C.line(b,suffix,n) return M.lines(C.read(b,suffix))[n] or "" end
  function C.put(path,...) return fs.put(path,table.concat({...},"\n") .. "\n") end
  function C.call(b,method,args)
    args=args or {}; args.block_id=b; args.session_id=C.session
    for n=1,3 do
      local r,err=rex.block.call("com.superlogical.terminal",method,args)
      if type(r)=="table" then return r end
      if tostring(err):find("not_found",1,true) then return nil end
      if n<3 then rex.sleep(0.2) end
    end
  end
  function C.resolve(query,kind)
    if not query or query=="" or query:sub(1,1)=="-" then return nil,3 end
    local args={kinds={kind or "block"},queries={query}}
    if kind~="session" then args.scope={session=C.session} end
    for n=1,3 do
      local r=rex.call("target.resolve",args)
      local item=r and r.results and r.results[1]
      if item then
        if item.status=="resolved" and type(item.target)=="table" then return item.target[(kind or "block") .. "_id"] end
        return nil,3
      end
      if n<3 then rex.sleep(0.2) end
    end
    return nil,1
  end
  function C.init()
    local session=env("REX_SESSION")
    if not session and env("REX_BLOCK") then session=C.resolve(env("REX_BLOCK"),"session") end
    if not session then C.die("REX_SESSION is empty and no session could be resolved from REX_BLOCK; run inside a Rex terminal with REX_BLOCK set (check with: rex whoami --json), or set REX_SESSION explicitly") end
    -- The RPCs and event payloads use canonical session IDs. Rex's CLI also accepts labels and block IDs.
    C.session=M.starts(session,"session:") and session or C.resolve(session,"session") or session
    if C.dir=="" then C.die("no state dir: set HOME or REX_ORCHESTRATOR_STATE_DIR") end
    if not fs.init(C.dir) then C.die("refusing state dir " .. C.dir .. ": a link, not a directory, or not yours (REX_ORCHESTRATOR_STATE_DIR picks another)") end
    if env("REX_BLOCK") then
      local id,code=C.resolve(env("REX_BLOCK"))
      if id then C.me=id elseif code==3 then C.me=env("REX_BLOCK")
      else C.die("rex did not answer for REX_BLOCK " .. env("REX_BLOCK"),1) end
    end
  end
  function C.target(q,gone)
    if not q or q=="" then C.die("missing BLOCK") end
    local b,code=C.resolve(q)
    if not b then
      if code==3 and gone and M.starts(q,"block:") then b=q
      elseif code==3 then C.die("no such block in this session: " .. q)
      else C.die("rex did not answer for block " .. q,1) end
    end
    if b==C.me then C.die("refusing to target your own pane (" .. q .. ")") end
    C.block=b; return b
  end
  function C.owned()
    if C.me=="" then C.die("REX_BLOCK is not set: run inside a Rex pane, or prefix the call with REX_SESSION=… REX_BLOCK=…") end
    if not C.force and C.line(C.block,"own",1)~=C.me then
      C.die("wait --approve-in: " .. C.block .. " was not launched from this pane; pass --force only for a pane the user named")
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
    local r=rex.session.list_blocks{session_id=C.session}
    if r and type(r.blocks)=="table" then
      for _,v in ipairs(r.blocks) do if v.block_id==b then return nil end end
      return true
    end
    return nil
  end
  function C.status(b)
    local r=C.root(b) or {}; local p=C.call(b,"process"); local t=C.call(b,"title")
    local w=C.line(b,"own",2); local alive
    if p then alive=p.last_exit==nil and p.child~=nil and (w=="" or tostring(p.child.pid)==w) end
    local fields={state=r.state,kind=r.kind,msg=r.msg,title=t and t.title or "",alive=alive,
      cwd=p and ((p.foreground or {}).cwd or (p.child or {}).cwd)}
    -- Rex maps JSON null to nil, so encode required null fields explicitly.
    local a={}; for _,key in ipairs({"state","kind","msg","title","alive","cwd"}) do
      a[#a+1]='"' .. key .. '":' .. (fields[key]==nil and "null" or rex.json.encode(fields[key]))
    end
    local account=C.line(b,"cage",2)
    if account~="" then a[#a+1]='"account":' .. rex.json.encode(account) end
    return "{" .. table.concat(a,",") .. "}"
  end
  function C.kind(rec)
    local k=C.line(C.block,"own",4)
    return k~="" and k or ({["claude-code"]="claude",antigravity="agy",["grok-build"]="grok",codex="codex",muse="muse"})[(rec or {}).effective_app or (rec or {}).app] or ""
  end
  function C.pin(screen,rec)
    if not C.read(C.block,"own") or C.read(C.block,"cage") or C.kind(rec)~="claude" then return true end
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
  function C.killed(kind) return fs.exists(C.dir .. "/disabled" .. (kind and kind~="" and "." .. kind or "")) end
  function C.kill(why)
    if not fs.append(C.dir .. "/disabled.claude",os.date("!%Y-%m-%dT%H:%M:%SZ") .. " " .. why .. "\n") then C.note("could not write " .. C.dir .. "/disabled.claude") end
    C.note("\27[31mstopped: " .. why .. "; " .. C.dir .. "/disabled.claude is set: report it, never remove it yourself\27[0m")
  end
  return C
end
return M
