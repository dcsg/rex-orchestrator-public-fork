-- Pure Lua 5.1 tests: a fake Rex API, virtual event loop and in-memory state.
local root=arg[1] or "."
local dir=root .. "/skills/rex-orchestrator/scripts/lua/"
local M=dofile(dir .. "core.lua")
local Approval=dofile(dir .. "approval.lua")
local Commands=dofile(dir .. "commands.lua")
local pass=0
local function eq(a,b,label)
  if a~=b then error((label or "check") .. ": got [" .. tostring(a) .. "], expected [" .. tostring(b) .. "]",0) end
  pass=pass+1
end
local function json(v)
  if type(v)=="string" then return '"' .. v:gsub('[%z\1-\31\\"]',function(c)
    return ({['"']='\\"',['\\']='\\\\',['\n']='\\n',['\r']='\\r',['\t']='\\t'})[c] or string.format('\\u%04x',c:byte()) end) .. '"'
  elseif type(v)~="table" then return tostring(v) end
  local a={}; for k,w in pairs(v) do a[#a+1]=json(k) .. ":" .. json(w) end; table.sort(a); return "{" .. table.concat(a,",") .. "}"
end
local original_time,original_getenv=os.time,os.getenv
local orch,child="block:orch","block:child"
local function fixture(name)
  local f=assert(io.open(root .. "/tests/harness/fixtures/" .. name .. ".txt")); local s=f:read("*a"); f:close(); return s
end
local function test(options)
  options=options or {}
  local now,seq=1000,0
  local env={HOME="/home/test",REX_SESSION="session:test",REX_BLOCK=orch,REX_ORCHESTRATOR_STATE_DIR="/state"}
  for k,v in pairs(options.env or {}) do env[k]=v end
  os.getenv=function(k) return env[k] end
  os.time=function() return math.floor(now) end
  local files=options.files or {}; local timers,handlers,out,notes,calls={},{},{},{},{}
  local r={app="claude-code",state="working",updated_at="new"}
  local current={rec=options.rec or r,screen=options.screen or fixture("bg/live-idle"),process=options.process or {child={pid=42,cwd="/work"}}}
  local fs={}
  function fs.init() return not options.bad_state end
  function fs.read(p) return files[p] end
  function fs.put(p,s) files[p]=s; return not options.bad_write end
  function fs.remove(p) files[p]=nil end
  function fs.append(p,s) files[p]=(files[p] or "") .. s; return true end
  function fs.exists(p) return files[p]~=nil end
  function fs.canonical(p)
    if p=="/missing" then return nil end
    if p=="/tmp/work" then return "/private/tmp/work" end
    return p=="/" and "/" or (p=="/work" or p=="/home/test" or p=="/private/tmp/work") and p or nil
  end
  function fs.real(p) if p:find("link",1,true) then return nil end; return p end
  function fs.plain(p) return not p:find("hardlink",1,true) end
  function fs.prefix() return true end
  function fs.pid_alive() return not options.dead_owner end
  function fs.lock()
    if options.lock_busy then return nil,2 end
    return function() options.released=true end
  end
  local rex={session={},block={},json={encode=json}}
  function rex.stop(code) error({stop=code},0) end
  function rex.sleep(n) now=now+n end
  function rex.exec() return {ok=false} end
  function rex.call(method,a)
    calls[#calls+1]=method
    if method=="server.status" then return not options.server_down and {} or nil end
    if method=="session.attach" then return {} end
    if method=="client.key" then
      if a.key.action=="press" then options.presses=(options.presses or 0)+1 end
      return {}
    end
    if method=="target.resolve" then
      if options.resolve_error then return nil,"offline" end
      local q=a.queries[1]
      if a.kinds[1]=="session" then return {results={{status="resolved",target={session_id="session:test"}}}} end
      if q==orch or q=="self" then return {results={{status="resolved",target={block_id=orch}}}} end
      if q==child or q=="child" then return {results={{status="resolved",target={block_id=child}}}} end
      return {results={{status="not_found"}}}
    end
  end
  function rex.session.list_blocks()
    calls[#calls+1]="list_blocks"
    if options.list_error then return nil end
    return {blocks=options.blocks or {{block_id=child,flavor="terminal",label="task"}}}
  end
  function rex.block.call(_,method,a)
    calls[#calls+1]=method
    if options.throw==method then error("test callback error") end
    if options.fail and options.fail[method] then return nil,"offline" end
    if method=="program_status" then return {records=current.records or {current.rec}} end
    if method=="process" then return current.process end
    if method=="format" then return {content=current.screen} end
    if method=="title" then return {title="child title"} end
  end
  function rex.on(name,fn) handlers[name]=fn end
  function rex.after(delay,fn)
    seq=seq+1; local t={at=now+delay,fn=fn,seq=seq}; timers[#timers+1]=t
    function t:cancel() self.cancelled=true end
    return t
  end
  function rex.every(delay,fn)
    local t=rex.after(delay,fn); t.period=delay; return t
  end
  local C=M.new(rex,fs,{out=function(s) out[#out+1]=s end,
    note=function(s) notes[#notes+1]=s end,raw=function(s) notes[#notes+1]=s end})
  local A=Approval(C,M); local commands=Commands(C,M,A)
  local function run(command,args,events)
    for _,e in ipairs(events or {}) do
      rex.after(e.at,function()
        for k,v in pairs(e.set or {}) do current[k]=v end
        if e.fault then options.throw=e.fault end
        if e.name and handlers[e.name] then
          local ctx={session_id=e.session or "session:test"}
          if not e.no_ctx_block then ctx.block_id=e.block or child end
          handlers[e.name](ctx,{block_id=e.block or child,session_id=ctx.session_id})
        end
      end)
    end
    local ok,err=pcall(function()
      C.init(); commands[command](args or {})
      while true do
        table.sort(timers,function(a,b) return a.at<b.at or a.at==b.at and a.seq<b.seq end)
        local t=table.remove(timers,1); if not t then break end
        if not t.cancelled then now=t.at; t.fn(); if t.period and not t.cancelled then t.at=now+t.period; timers[#timers+1]=t end end
        if now>100000 then error("unbounded timer") end
      end
    end)
    if not ok and type(err)~="table" then error(err,0) end
    return {code=ok and 0 or err.stop,out=table.concat(out,"\n"),notes=table.concat(notes,"\n"),calls=calls,files=files,elapsed=now-1000,C=C,A=A,current=current}
  end
  return run,C,A,fs
end
local function count(a,s) local n=0; for _,v in ipairs(a) do if v==s then n=n+1 end end; return n end
-- Background footer/turn-line parsing, including transcript false positives and narrow captures.
local expected={
  ["live-idle"]="",["live-1-shell"]="1",["live-1-shell-narrow"]="1",["live-shell-ended"]="",
  ["live-1-shell-more-footer-rows"]="1",["helper-timeout-line"]="",["claude-2shells"]="2",
  ["claude-ran1"]="",["claude-ran2-and-1running"]="1",["claude-reply-mentions-2-shell-scripts"]="",
  ["claude-reply-mentions-tasks"]="",["claude-1shell-many-footer-rows"]="1",["claude-1shell-bottom-blank-rows"]="1",
  ["claude-11shells-eol"]="11",["claude-v2shell"]="",["agy-1task"]="1",["agy-idle"]="",
  ["real-layout-reply-mentions-2-shell-scripts"]="",["real-layout-reply-mentions-1-shell"]="",
  ["real-layout-prompt-echo-3-shells"]="",["live-1-shell-20col"]="1",["live-shell-ended-20col"]="",
  ["live-shell-ended-20col-noresume"]="",["narrow-1-shell-more-footer-rows"]="1",["claude-reply-says-still-running"]="",
  ["claude-old-turn-line-then-reply"]="",["grok-1task"]="1",["grok-working-1task"]="1",["grok-woken-turn"]="",
  ["grok-done"]="",["grok-after-woken"]="",["grok-reply-mentions-tasks"]="",["claude-1shell-26col"]="1",
  ["claude-1shell-22col"]="1",["claude-1shell-16col"]="1",["claude-1shell-80x9"]="1",["claude-1shell-80x7"]=""}
for name,want in pairs(expected) do eq(M.background(fixture("bg/" .. name)):match("^(%d+)") or "",want,"background " .. name) end
local run,C,A=test()
eq(M.duration("--timeout","008m",C.die),480)
for _,v in ipairs({"-1","1.5","","1d","1M"," 1","1sfoo"}) do
  local r=test() -- the command parser must return public exit 2
  eq(r("wait",{child,"--timeout",v}).code,2,"duration " .. v)
end
for _,v in ipairs({"notes.txt","src/app.lua","sub/ñandú/a.txt"}) do eq(A.names(v),true,v) end
for _,v in ipairs({"AGENTS.md","sub/claude.md",".envrc","a/.git/config","agentſ.md","lefthooK.yml","bunﬁg.toml","ñandú.txt","a\tb"}) do eq(A.names(v),false,v) end
for _,app in ipairs({"claude-code","antigravity","codex"}) do
  eq(A.msg_path(app,"approve Write: /work/a.txt"),app=="claude-code" and "/work/a.txt" or nil)
end
eq(A.msg_path("claude-code","approve Write: /work/a.txt\n"),nil)
eq(A.msg_path("claude-code","approve Write: /work/a\194\133.txt"),nil)
eq(A.msg_path("antigravity","Approve EditFile: Write: /work/a…"),"/work/a…")
eq(A.msg_path("claude-code","approve Write: /work/a…"),nil)
eq(A.dialog(fixture("dialog/claude-write-file"),"claude-code","/work/new.txt",false),"new.txt")
eq(A.dialog(fixture("dialog/claude-write-file"),"claude-code","/work/other.txt",false),nil)
eq(A.dialog(fixture("dialog/claude-edit-file"),"claude-code","/work/existing.txt",false),"existing.txt")
eq(A.dialog(fixture("dialog/claude-bash-prompt"),"claude-code","/work/c.txt",false),nil)
local cl=fixture("dialog/claude-write-file")
for _,v in ipairs({"Yes, allow once","Yes, always","Yes, accept edits","Yes, and don’t ask again"}) do
  eq(A.dialog(cl:gsub("1%. Yes\n","1. " .. v .. "\n"),"claude-code","/work/new.txt",false),nil,v)
end
local ap="/private/tmp/claude-501/-Users-alice/00000000-0000-4000-8000-00000000000"
eq(A.dialog(fixture("dialog/agy-create-file-cut"),"antigravity",ap,true),"")
eq(A.dialog(fixture("dialog/agy-edit-file-cut"),"antigravity",ap,true),"")
eq(A.dialog(fixture("dialog/agy-create-file-cut"),"antigravity",ap .. "0/scratc",false),nil)
-- Main command contract and unknown reads.
for _,cmd in ipairs({"status","screen","wait"}) do
  eq(test()(cmd,{}).code,2,cmd .. " missing")
  eq(test()(cmd,{"self"}).code,2,cmd .. " self")
  eq(test({resolve_error=true})(cmd,{child}).code,1,cmd .. " RPC failure")
end
eq(test({bad_state=true})("status",{child}).code,2)
eq(test({env={REX_BLOCK="",REX_SESSION=""}})("ls",{}).code,2)
eq(test({env={REX_BLOCK=""}})("status",{child}).code,0)
eq(test()("screen",{child,"0"}).out,"")
eq(test({screen="first\nsecond\n\n  \n"})("screen",{child,"1"}).out,"second")
eq(test({screen="first\nsecond"})("screen",{child,""}).out,"first\nsecond")
eq(test()("screen",{child,"x"}).code,2)
eq(test({fail={format=true}})("screen",{child}).code,1)
local st=test({fail={program_status=true,process=true,title=true}})("status",{child})
eq(st.out,'{"state":null,"kind":null,"msg":null,"title":"","alive":null,"cwd":null}')
local d={app="claude-code",state="done",updated_at="new"}
eq(test({rec=d})("wait",{child}).out,"done")
local r=test({rec=d,files={["/state/block_child"]="new\n\n"}})("wait",{child,"--timeout","0"})
eq(r.code,124); eq(r.out,"timeout (state=done, no new report since send/keys)")
eq(test({rec=d})("wait",{"block:missing"}).code,0) -- unresolved full IDs still get evidence from process/status
local b={app="claude-code",state="blocked",kind="permission",msg="approve Write: /work/a.txt",updated_at="new"}
r=test({rec=b})("wait",{child}); eq(r.code,10); eq(r.out,"blocked permission approve Write: /work/a.txt")
r=test({rec={app="muse",state="error",msg="oops",updated_at="new"}})("wait",{child}); eq(r.code,11); eq(r.out,"error oops")
r=test({process={last_exit={code=0}}})("wait",{child}); eq(r.code,12); eq(r.out,"exited")
r=test()("wait",{child,"--timeout","2"}); eq(r.code,124); eq(r.out,"timeout (state=working)")
r=test()("wait",{child,"--timeout","12"}); eq(count(r.calls,"program_status"),5)
r=test({throw="process"})("wait",{child}); eq(r.code,1); eq(r.notes:find("test callback error",1,true)~=nil,true)
r=test({rec=d,screen=fixture("bg/live-1-shell")})("wait",{child},{{at=0.25,fault="format"}}); eq(r.code,1); eq(r.elapsed,0.5)
r=test()("wait",{child,"--timeout","1"},{{at=1.5,fault="process"}}); eq(r.code,1); eq(r.elapsed,2)
r=test({list_error=true,server_down=true,fail={process=true}})("wait",{child}); eq(r.code,1)
-- Unrelated events do not trigger reads. The startup and safety snapshots recover lost events.
r=test()("wait",{child,"--timeout","30"},{
  {at=1.5,name="terminal.program_status_changed",block="block:other",set={rec=d}},
  {at=2,name="terminal.program_status_changed",session="session:other"},
  {at=3,name="terminal.program_status_changed",no_ctx_block=true}})
eq(r.code,0); eq(r.elapsed,3); eq(count(r.calls,"program_status"),3)
r=test()("wait",{child,"--timeout","30"},{{at=0.5,set={rec=d}}})
eq(r.code,0); eq(r.elapsed,1)
r=test()("wait",{child,"--timeout","30"},{{at=1.5,set={rec=d}}})
eq(r.code,0); eq(r.elapsed,5)
for _,name in ipairs({"block_closed","terminal.child_exited"}) do
  r=test()("wait",{child,"--timeout","30"},{{at=1,name=name}}); eq(r.code,12); eq(r.elapsed,1)
end
r=test()("wait",{child,"--timeout","30"},{
  {at=1,name="session_destroyed",session="session:other",no_ctx_block=true},
  {at=2,name="session_destroyed",no_ctx_block=true}})
eq(r.code,12); eq(r.elapsed,2)
r=test({records={}})("wait",{child,"--timeout","1"}); eq(r.code,124)
r=test({rec={app="codex",state="idle",updated_at="new"}})("wait",{child}); eq(r.elapsed,8); eq(r.out,"idle")
r=test()("wait",{child},{{at=1,name="terminal.program_status_changed",set={rec={app="codex",state="idle",updated_at="newer"}}}})
eq(r.out,"idle"); eq(r.elapsed,1)
local basefiles={["/state/block_child"]="old\n\n"}
r=test({rec=d,screen=fixture("bg/claude-1shell-many-footer-rows"),files=basefiles})("wait",{child,"--timeout","1"})
eq(r.code,124); eq(r.files["/state/block_child.hold"]~=nil,true)
r=test({rec=d,screen=fixture("bg/claude-1shell-many-footer-rows"),files=basefiles})("wait",{child,"--ignore-background"})
eq(r.code,0); eq(r.files["/state/block_child.hold"],nil)
r=test({rec=d,screen=fixture("bg/claude-1shell-many-footer-rows")})("wait",{child,"--bg-max","1"})
eq(r.code,0); eq(r.notes:find("background work still running",1,true)~=nil,true)
r=test({rec=d,screen=fixture("bg/claude-1shell-many-footer-rows")})("wait",{child},{{at=1,set={screen=fixture("bg/live-idle")}}})
eq(r.code,0); eq(r.elapsed,21)
r=test({rec=d,screen=fixture("bg/claude-1shell-many-footer-rows")})("wait",{child,"--timeout","22"},{
  {at=1,set={screen=fixture("bg/live-idle")}},
  {at=20.9,set={rec={app="claude-code",state="working",updated_at="later"}}}})
eq(r.code,124); eq(r.out,"timeout (state=working)")
eq(M.mode("──────────\n⏸ manual mode on · ⏵⏵ accept edits on"),"⏵⏵ accept edits on")
-- Stale Claude prompt recovery and permission-mode pin.
r=test({rec=b,files={["/state/block_child"]="new\n\n"}})("wait",{child,"--timeout","20"})
eq(r.code,10); eq(r.elapsed,11)
local own=orch .. "\n42\n\nclaude\n/work\n⏸ manual mode on\n/bin/claude\n"
for _,dirarg in ipairs({"/","/home/test","/missing"}) do eq(test()("wait",{child,"--approve-in",dirarg}).code,2) end
eq(test()("wait",{child,"--approve-in","/work"}).code,2)
r=test({files={["/state/block_child.own"]=own},screen="──────────\n⏵⏵ accept edits on "})("wait",{child,"--approve-in","/work"})
eq(r.code,10); eq(r.out,"stopped"); eq(r.files["/state/block_child.stopped"]~=nil,true)
local opts={rec={app="claude-code",state="blocked",kind="permission",msg="approve Write: /work/new.txt",updated_at="new"},
  files={["/state/block_child.own"]=own},screen=cl}
r=test(opts)("wait",{child,"--approve-in","/work","--timeout","1"})
eq(r.code,124); eq(opts.presses,1); eq(opts.released,true)
local r2=test(opts)("wait",{child,"--approve-in","/work","--timeout","1"})
eq(opts.presses,1,"duplicate approval after retry")
for _,name in ipairs({"AGENTS.md",".env","sub/../a.txt","link.txt","hardlink.txt"}) do
  local o={files={["/state/block_child.own"]=own},screen=cl:gsub("new%.txt",name),rec={app="claude-code",state="blocked",kind="permission",msg="approve Write: /work/" .. name,updated_at="new"}}
  local z=test(o)("wait",{child,"--approve-in","/work"}); eq(z.code,10); eq(o.presses,nil,name)
end
local o={files={["/state/block_child.own"]=own,["/state/disabled.claude"]="stop"},screen=cl,rec=opts.rec}
eq(test(o)("wait",{child,"--approve-in","/work"}).code,10); eq(o.presses,nil)
o={files={["/state/block_child.own"]=own,["/state/block_child.cage"]="cage\n"},screen=cl,rec=opts.rec}
eq(test(o)("wait",{child,"--approve-in","/work"}).code,10); eq(o.presses,nil)
-- Root record ownership and child exclusion.
run,C,A=test(); C.init()
local current=run("status",{child}).current
current.records={{app="claude-code",state="done",id="sub",updated_at="z"},{app="claude-code",state="working",updated_at="a"}}
eq(C.root(child).state,"working")
-- Listing keeps owned labels, ignores dead writers and non-terminals.
r=test({rec=d,files={["/state/block_child.own"]=own}})("ls",{})
eq(r.code,0); eq(r.out:find('"mine":true',1,true)~=nil,true)
eq(test({rec={}})("ls",{}).out,"")
eq(test({list_error=true})("ls",{}).code,1)
os.time,os.getenv=original_time,original_getenv
print("Lua unit: " .. pass .. " passed")
