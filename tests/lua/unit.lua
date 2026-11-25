-- Pure Lua 5.1 tests: a fake Rex API, virtual event loop and in-memory state.
local root=arg[1] or "."
local dir=root .. "/skills/rex-orchestrator/scripts/lua/"
local M=dofile(dir .. "core.lua")
local Approval=dofile(dir .. "approval.lua")
local Commands=dofile(dir .. "commands.lua")
local Input=dofile(dir .. "input.lua")
local Mutations=dofile(dir .. "mutations.lua")
local Registry=dofile(dir .. "registry.lua")
local Close=dofile(dir .. "close.lua")
local Orphans=dofile(dir .. "orphans.lua")
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
  function fs.read_file(path)
    if options.unreadable==path then return nil,path .. ": Permission denied" end
    if not files[path] then return nil,"not_file" end
    return fs.read(path)
  end
  function fs.put(p,s) files[p]=s; return not options.bad_write end
  function fs.remove(p) files[p]=nil end
  function fs.unlink(p) files[p]=nil; return true end
  function fs.mkdir() return true end
  function fs.remove_state(path)
    for p in pairs(files) do if p==path or M.starts(p,path .. ".") then files[p]=nil end end
    return true
  end
  function fs.claim_paths(dir)
    local paths={}
    for p in pairs(files) do
      if M.starts(p,dir .. "/") and p:match("%.json$") then paths[#paths+1]=p end
    end
    table.sort(paths)
    return paths
  end
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
  function fs.pid_alive(pid) return pid~="99999999" and not options.dead_owner end
  function fs.lock()
    if options.lock_busy then return nil,2 end
    return function() options.released=true end
  end
  local rex={session={},block={},json={encode=json,decode=function(s) return (options.decoded or {})[s] end}}
  function rex.stop(code) error({stop=code},0) end
  function rex.sleep(n) now=now+n end
  function rex.exec(a)
    if a[2]=="send-key" then
      options.key_args=a
      return {ok=not options.fail_keys,stderr=""}
    end
    return {ok=false,stderr=""}
  end
  function rex.call(method,a)
    calls[#calls+1]=method
    if method=="server.status" then return not options.server_down and {} or nil end
    if method=="session.attach" then return {} end
    if method=="block.close" then
      if options.close_error then return nil,"offline" end
      options.closed=a.block_id
      return {}
    end
    if method=="client.key" then
      options.key_events=options.key_events or {}
      options.key_events[#options.key_events+1]={key=a.key.key,action=a.key.action,text=a.key.text,mods=a.key.mods}
      if options.fail_keys then return nil,"write failed" end
      if a.key.action=="press" then options.presses=(options.presses or 0)+1 end
      return {}
    end
    if method=="target.resolve" then
      if a.scope and a.scope.session==options.gone_session then return nil,"code=session_not_found" end
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
    if method=="write" then
      options.typed=a.data
      if options.typed_screen then current.screen=options.typed_screen end
      if options.typed_record then current.rec=options.typed_record end
      return {bytes_written=#a.data}
    end
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
  local args=dofile(dir .. "arguments.lua")(C,M)
  local A=Approval(C,M); local commands=Commands(C,M,A,args)
  C.rex_bin="/fixture/rex"
  C.script_dir="/fixture"
  local registry=Registry(C,M)
  for name,fn in pairs(Mutations(C,M,Input(M),registry,args,Close(C,M,registry))) do commands[name]=fn end
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
      if command=="claims" then C.init_state() else C.init() end
      commands[command](args or {})
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
-- Every note, refusal and raw diagnostic reaches the terminal escaped at the sink, whatever the caller put in it.
do
  local written={}
  local sink=M.new({stop=function() end},{},{raw=function(text) written[#written+1]=text end,finish=function() end})
  local path="/tmp/x\27]0;title\7/\226\128\174y\tz\\w"
  sink.note("no such directory: " .. path)
  sink.die("clone: no such REPO: " .. path)
  sink.raw("Error: " .. path .. "\nrex-orchestrator: forged")
  local want="/tmp/x\\x1B]0;title\\x07/\\u202Ey\\x09z\\\\w"
  eq(written[1],"rex-orchestrator: no such directory: " .. want)
  eq(written[2],"rex-orchestrator: clone: no such REPO: " .. want)
  -- A raw line stays one line: an embedded line break can't start a forged diagnostic.
  eq(written[3],"Error: " .. want .. "\\x0Arex-orchestrator: forged")
  eq(sink.note("two\nlines"),nil); eq(written[4],"rex-orchestrator: two\\x0Alines")
  -- Text meant to span lines (a screen tail, a tool's stderr) keeps its lines, each one indented.
  sink.lines("first " .. path .. "\nrex-orchestrator: forged\n")
  eq(written[5],"  first " .. want .. "\n  rex-orchestrator: forged\n  ")
  for _,text in ipairs(written) do
    eq(text:gsub("\n",""):find("[%c\128-\159]"),nil,"raw control in " .. text)
    for line in (text .. "\n"):gmatch("(.-)\n") do
      eq(M.starts(line,"rex-orchestrator: forged"),false,"forged line in " .. text)
    end
  end
end
-- A compiled executable, by its first bytes: thin or universal Mach-O, either byte order.
for _,magic in ipairs({"\207\250\237\254\7\0\0\1","\206\250\237\254","\254\237\250\207","\254\237\250\206",
  "\202\254\186\190\0\0\0\2","\202\254\186\191","\190\186\254\202","\191\186\254\202"}) do
  eq(M.compiled(magic),true,"compiled " .. M.terminal_text(magic)); eq(M.node_launcher(magic),nil)
end
for _,head in ipairs({"#!/bin/sh\n","echo x\n","","\127ELF"}) do eq(M.compiled(head),false) end
-- The only Node launchers the cage takes: three exact #! shapes with plain dashed options.
for _,case in ipairs({
  {"#!/usr/bin/env node\n","node"},
  {"#!/usr/bin/env nodejs\n","nodejs"},
  {"#!/usr/bin/env node --no-warnings\n","node"},
  {"#!/usr/bin/env -S node --no-warnings --stack-size\n","node"},
  {"#!/opt/homebrew/bin/node\n","/opt/homebrew/bin/node"},
  {"#!/usr/local/bin/nodejs -r\n","/usr/local/bin/nodejs"},
  {"#! /opt/node/bin/node --enable-source-maps\nrest","/opt/node/bin/node"},
}) do eq(M.node_launcher(case[1]),case[2],"node launcher " .. case[1]) end
-- Everything else is not one, so the cage skips it: other interpreters, no #!, every env option, assignment, "--",
-- "-", nested env, long-looking words (macOS env reads --P as -P), arguments that name a file, set or expand a value.
for _,head in ipairs({
  "no shebang\n", "#!\n", "#!/bin/bash\n", "#!/usr/bin/env bash\n", "#!/usr/bin/env python3\n", "#!/usr/bin/env\n",
  "#!node\n", "#!./node\n", "#!bin/node\n", "#!/usr/bin/nodeish\n", "#!/bin/env node\n", "#!/usr/bin/env.sh node\n",
  "#!/usr/bin/env --P/some/dir node\n", "#!/usr/bin/env --iP /d node\n", "#!/usr/bin/env --P /d node\n",
  "#!/usr/bin/env --split-string=node\n", "#!/usr/bin/env --unset=PATH node\n", "#!/usr/bin/env --ignore-environment node\n",
  "#!/usr/bin/env PATH=/d node\n", "#!/usr/bin/env PATH=.:/opt/homebrew/bin node\n", "#!/usr/bin/env FOO=1 node\n",
  "#!/usr/bin/env -P /d node\n", "#!/usr/bin/env -P/d node\n", "#!/usr/bin/env -i node\n", "#!/usr/bin/env - node\n",
  "#!/usr/bin/env -u PATH node\n", "#!/usr/bin/env -uX node\n", "#!/usr/bin/env -v node\n", "#!/usr/bin/env -- node\n",
  "#!/usr/bin/env -S -P /d node\n", "#!/usr/bin/env -S PATH=/d node\n", "#!/usr/bin/env -S 'node --x'\n",
  "#!/usr/bin/env -Snode\n", "#!/usr/bin/env -S node $HOME\n", "#!/usr/bin/env -S -S node\n",
  "#!/usr/bin/env env node\n", "#!/usr/bin/env /usr/bin/env node\n", "#!/usr/bin/env PATH=/d -P /p node\n",
  "#!/usr/bin/env node /tmp/other.js\n", "#!/usr/bin/env node other.js\n", "#!/usr/bin/env node --require=x\n",
  "#!/usr/bin/env node --title \"x\"\n", "#!/usr/bin/env node -\n", "#!/usr/bin/env node --\n",
  "#!/opt/node/bin/node /tmp/x.js\n", "#!/opt/node/bin/node script.js\n", "#!/opt/node/bin/node --a=b\n",
  "#!/opt/node/bin/node $X\n", "#!/opt/node/bin/node 'x'\n",
  -- The kernel runs a #! line only with its newline in the first 512 bytes, and splits on space and tab alone: an
  -- overlong line or one the kernel would split differently falls back to /bin/sh, so neither is a Node launcher.
  "#!/usr/bin/env node" .. string.rep(" -a", 200) .. "\n", "#!/usr/bin/env node", "#!/abs/node\v-x\n",
  "#!/abs/node\f-x\n", "#!/usr/bin/env node\r\n", "#!/usr/bin/env node\0-x\n", "#!/usr/bin/env\vnode\n",
}) do eq(M.node_launcher(head),nil,"not a node launcher: " .. M.terminal_text(head)) end
-- The longest line the kernel still runs stays accepted up to one byte under its limit.
eq(M.node_launcher("#!/usr/bin/env node" .. string.rep(" -a", 163) .. "\n"),"node","node launcher at 509 bytes")
eq(M.node_launcher("#!/usr/bin/env node\t--no-warnings\n"),"node","node launcher with a tab")
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
eq(M.mode("──────────\n⏸ manual mode on then looks onyx"),"⏸ manual mode on")
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
o={files={["/state/block_child.own"]=own,["/state/disabled"]=""},screen=cl,rec=opts.rec}
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

-- Phase 2 uses the same fixtures and state files that the Bash launcher produces.
local function owned(options)
  options=options or {}
  options.files=options.files or {}
  options.files["/state/block_child.own"]=own
  return options
end
local function done_record(now)
  return {app="claude-code",state="done",updated_at=now or "new"}
end
local rule="────────────────────"
local function composer(text)
  return rule .. "\n❯ " .. text .. "\n" .. rule .. "\n⏸ manual mode on"
end
local input=Input(M)
eq(input.dialog(cl),true)
eq(input.dialog(rule .. "\n› 1. Continue\n   2. No",true),true)
eq(input.dialog("› type Do you want to make a change?"),false)
eq(input.dialog("› 1. Review hooks"),true)
eq(not not input.one_time("Continue without trusting"),true)
eq(not not input.one_time("Yes, allow for this session"),false)
eq(not not input.one_time("No, remember"),false)
eq(input.picked(cl,"enter"),"Yes")
eq(input.picked(rule .. "\n  1. Yes,\n     allow for this session","1"),"Yes, allow for this session")
eq(input.typed_shown(composer("a complete prompt"),"a complete prompt","claude-code"),true)
eq(input.typed_shown(composer("different text"),"a complete prompt","claude-code"),false)
eq(input.typed_shown("› [Pasted Content 50 chars]","a long message","codex"),true)

for _,verb in ipairs({"send","keys","close"}) do
  local args={child,"enter"}
  eq(test()(verb,args).code,2,verb .. " requires ownership")
  eq(test(owned())(verb,{"self","enter"}).code,2,verb .. " refuses self")
end
for _,text in ipairs({"","    ","!whoami","  !whoami","7"," /PERM","/m","x\27[0m","x\127","x\194\155","x\155","x\3"}) do
  o=owned({rec=d})
  r=test(o)("send",{child,text}); eq(r.code,2,text); eq(o.typed,nil)
end
o=owned({rec=d,screen=composer(""),typed_screen=composer("-sample text"),
  files={["/work/input"]="-sample\ntext\n\0",["/state/block_child.hold"]="old hold"}})
r=test(o)("send",{child,"-f","/work/input"})
eq(r.code,0); eq(o.typed,"-sample text"); eq(o.presses,1); eq(r.files["/state/block_child"],"new\n\n")
eq(r.files["/state/block_child.hold"],nil)
o=owned({rec=d,unreadable="/work/locked"})
eq(test(o)("send",{child,"-f","/work/locked"}).code,1); eq(o.typed,nil)
eq(M.prompt_control("emoji 🦊 and 中文\t\n\r"),false)
for _,case in ipairs({
  {"\224\130\155",[[\xE0\x82\x9B]]},
  {"\240\128\130\155",[[\xF0\x80\x82\x9B]]},
  {"\237\160\128",[[\xED\xA0\x80]]},
  {"\244\144\128\128",[[\xF4\x90\x80\x80]]},
  {"\192\155",[[\xC0\x9B]]},
  {"\240\159\166",[[\xF0\x9F\xA6]]},
  {"\027 then " .. [[\x1B]],[[\x1B then \\x1B]]},
  {"emoji 🦊 and 中文\194\155",[[emoji 🦊 and 中文\u009B]]}
}) do eq(M.terminal_text(case[1]),case[2]) end
eq(M.prompt_control("\224\130\155"),true)
eq(M.prompt_control("\193\191"),true) -- Overlong DEL without a raw C1 byte.
eq(M.prompt_control("\237\160\191"),true)
eq(M.prompt_control("\245\191\191\191"),true)
for byte=0xaa,0xae do eq(M.prompt_control("one" .. string.char(0xe2,0x80,byte) .. "two"),true) end
for byte=0xa6,0xa9 do eq(M.prompt_control("one" .. string.char(0xe2,0x81,byte) .. "two"),true) end
eq(M.prompt_control("\226\128\169"),false) -- U+2029 is outside the rejected bidi range.
eq(M.terminal_text("\226\129\166"),[[\u2066]])
for _,text in ipairs({"bad \193\191","bidi \226\128\174"}) do
  o=owned({rec=d,screen=composer("")})
  r=test(o)("send",{child,text})
  eq(r.code,2); eq(o.typed,nil)
end
o=owned({rec=d,screen=composer(""),typed_screen=composer("different")})
r=test(o)("send",{child,"a prompt not visible"})
eq(r.code,4); eq(o.typed,"a prompt not visible"); eq(o.presses,nil)
o=owned({rec=d,screen=composer(""),typed_screen=cl,typed_record=opts.rec})
r=test(o)("send",{child,"typed before dialog"})
eq(r.code,4); eq(o.typed,"typed before dialog"); eq(o.presses,nil)
o=owned({rec=d,screen=composer(""),bad_write=true})
eq(test(o)("send",{child,"refuse when state write fails"}).code,1); eq(o.typed,nil)
o=owned({rec=d,process={child={pid=99}}})
eq(test(o)("send",{child,"refuse replacement process"}).code,12); eq(o.typed,nil)
o=owned({rec=d,files={["/state/disabled.claude"]=""}})
eq(test(o)("send",{child,"disabled Claude"}).code,2); eq(o.typed,nil)
o=owned({rec=d,screen="──────────\n⏵⏵ accept edits on"})
r=test(o)("keys",{child,"tab"}); eq(r.code,2); eq(r.files["/state/block_child.stopped"]~=nil,true); eq(o.presses,nil)
for _,keys in ipairs({{"2"},{"enter","down"},{"shift+Tab"},{"[Slash]"}}) do
  o=owned({rec=opts.rec,screen=cl})
  local args={child}; for _,key in ipairs(keys) do args[#args+1]=key end
  r=test(o)("keys",args); eq(r.code,2); eq(o.presses,nil); eq(o.key_args,nil)
end
for _,key in ipairs({"shift+tab","s-tab","SHIFT-Tab","Shift+[Tab]","ctrl+Shift+Tab","s+[TAB]",
  "backtab","btab","shift+backtab","ctrl+b>tab",">"}) do
  o=owned({rec={app="claude-code",state="idle",updated_at="new"},screen=composer("")})
  r=test(o)("keys",{child,key}); eq(r.code,2,key); eq(o.key_events,nil); eq(o.key_args,nil)
end
o=owned({rec=opts.rec,screen=cl,files={["/state/block_child"]="prior\n7 shells\n",["/state/block_child.hold"]="hold"}})
r=test(o)("keys",{child,"enter"})
eq(r.code,0); eq(o.presses,1); eq(r.files["/state/block_child"],"new\n7 shells\n"); eq(r.files["/state/block_child.hold"],"hold")
o=owned({rec=d,files={["/state/disabled"]=""}})
r=test(o)("keys",{child,"escape","ctrl+c"})
eq(r.code,0); eq(o.presses,2); eq(o.key_events[3].mods,"ctrl")
o=owned({rec=done_record(),screen=composer("")})
eq(test(o)("keys",{child,"shift+left","[Slash]"}).code,0)
eq(table.concat(o.key_args," "),"/fixture/rex send-key -s session:test -b block:child -- shift+left [Slash]")

local claim_path="/state/registry/block_child.json"
local stale_path="/state/registry/block_stale.json"
local live={block=child,label="task\tname",session="session:test",kind="claude",pid=42,canonical_dir="/work"}
local dead={block="block:stale",session="session:test",pid=99999999}
local claim_json='{"block":"block:child","label":"task\\tname"}'
o=owned({env={REX_SESSION="",REX_BLOCK=""},files={[claim_path]=claim_json .. "\n",[stale_path]="dead"},
  decoded={[claim_json .. "\n"]=live,dead=dead}})
r=test(o)("claims",{})
eq(r.code,0); eq(r.out,"block:child\ttask\\tname\tsession:test\tclaude\t42\t/work"); eq(r.files[stale_path],nil)
r=test(o)("claims",{"--json"}); eq(r.out,claim_json)
eq(test()("claims",{"--unknown"}).code,2)
local lost_session={block=child,session="session:gone",pid=42}
r=test({gone_session=lost_session.session,files={[claim_path]="gone"},decoded={gone=lost_session}})("claims",{})
eq(r.code,0); eq(r.files[claim_path],nil)
r=test({files={[claim_path]="bad"}})("claims",{}); eq(r.code,1); eq(r.files[claim_path],"bad")
o=owned({files={[claim_path]=claim_json,["/state/block_child.hold"]="active"},close_error=true})
r=test(o)("close",{child})
eq(r.code,1); eq(r.files[claim_path],claim_json); eq(r.files["/state/block_child.hold"],"active")
o.close_error=false
r=test(o)("close",{child})
eq(r.code,0); eq(o.closed,child); eq(r.files[claim_path],nil); eq(r.files["/state/block_child.hold"],nil)
o={files={["/state/block_missing.own"]=own}}
eq(test(o)("close",{"block:missing"}).code,0); eq(o.closed,nil)

local LaunchDialog=dofile(dir .. "launch_dialog.lua")
os.getenv=function(k) return k=="HOME" and "/logical/home" or nil end
local trust_files={}
local dialog=LaunchDialog({fs={
  canonical=function(path) return path=="/logical/home" and "/physical/home" or path end,
  read=function(path) return trust_files[path] end
}},M,Input(M))
local physical,logical="/physical/home/tasks/current","/logical/home/tasks/current"
local function names(region,width)
  return dialog.dir_named(region,width or 0,physical,logical)
end
eq(names(physical),true); eq(names("Workspace: " .. logical),true)
eq(names("~/tasks/current"),true); eq(names("/physical/home/tasks/cur\n  rent"),true)
eq(names("/physical/home/…/current"),true); eq(names("/physical/home/…/wrong"),false)
eq(names(physical .. "-other"),false); eq(names("/physical/home/tasks"),false)
eq(names("/physical/home/tasks",20),true); eq(names("/physical/home/tasks",21),false)
eq(names("/physical/home/tasks/cur\n\nrent"),false)
local function trust(kind,name)
  local region=table.concat(M.region(fixture("launch/" .. name)),"\n")
  return not not dialog.trust_shown(kind,dialog.flat(region)),not not dialog.trust_selected(kind,dialog.flat(region),region)
end
local shown,selected=trust("claude","claude-trust-80x9-down")
eq(shown,true); eq(selected,true)
shown,selected=trust("claude","claude-trust-26x40")
eq(shown,true); eq(selected,false)
shown,selected=trust("claude","claude-trust-26x40-down")
eq(shown,true); eq(selected,true)
shown,selected=trust("muse","muse-trust-inline")
eq(shown,true); eq(selected,true)
shown,selected=trust("agy","agy-trust-25x30")
eq(shown,true); eq(selected,true)
shown,selected=trust("grok","grok-trust")
eq(shown,true); eq(selected,true)
shown,selected=trust("codex","codex-trust-19x30")
eq(shown,true); eq(selected,true)
eq(not not dialog.hooks(fixture("launch/codex-hooks-80x5")),true)
eq(dialog.trust_selected("grok","","Yes, proceed    y\nNo, quit    n now"),false)
eq(not not dialog.trust_shown("agy","",{state="blocked",msg="Trust this folder?"}),true)
local function ready(kind,name,state)
  local screen=fixture("launch/" .. name)
  return dialog.ready(kind,screen,table.concat(M.region(screen),"\n"),state and {state=state})
end
eq(ready("claude","claude-ready","idle"),true)
eq(ready("claude","claude-ready","working"),false)
eq(ready("agy","agy-ready","done"),true)
eq(ready("muse","muse-trust","idle"),false)
eq(ready("codex","codex-ready-19x30","working"),true)
eq(ready("codex","codex-ready-80x6",nil),false)
eq(ready("codex","codex-trust-80x6","working"),false)
for _,name in ipairs({"\t","\n","\r","\127","\194\133","\155","❯","›","⟩",">",
  "trust AND continue","Yes, I trust this folder","Do you trust","Yes, proceed","No, quit"}) do
  eq(dialog.safe_trust_dir("/work/" .. name),false,name)
end
eq(dialog.safe_trust_dir("/work/project-β"),true)
local docs={fs={
    read=function(path) return trust_files[path] end
  },rex={exec=function() return {ok=true,stdout="/work/repo\n"} end}}
trust_files["/logical/home/.codex/config.toml"]=[[
[projects."/work/repo"]
trust_level = "trusted"
[projects."/work"]
trust_level = "trusted"
[projects."/work/repo/sibling"]
trust_level = "trusted"]]
local above=LaunchDialog(docs,M,Input(M)).trusted_above({kind="codex",dir="/work/repo/current",logical="/work/repo/current"})
eq(above["/work"],true); eq(above["/work/repo"],nil); eq(above["/work/repo/sibling"],nil)

local Clone=dofile(dir .. "clone.lua")
local function clone_test(race)
  local exists,removed=false,0
  local commands={}
  local run=Clone({git="/usr/bin/git",fs={
    exists=function() return exists end,
    canonical=function() return "/repo" end,
    test=function() return true end,
    mkdir=function() return true end,
    mkdir_new=function()
      if exists then return false end
      exists=true; return true
    end,
    remove_tree=function()
      removed=removed+1; exists=race; return true
    end
  },rex={
    exec=function(args)
      commands[#commands+1]=table.concat(args," ")
      return {ok=args[1]~="/bin/cp",stdout="",stderr=""}
    end
  },die=function(message,code) error({message=message,code=code or 2},0) end,
    note=function() end,raw=function() end,out=function(out) commands.out=out end},M)
  local ok,err=pcall(run,{"/repo","/dest","-b","new"})
  return commands,removed,ok,err
end
local commands,removed,ok,err=clone_test(false)
eq(ok,true); eq(removed,1); eq(commands[3],"/usr/bin/git clone --local -- /repo /dest")
eq(commands[4],"/usr/bin/git -C /dest switch -c new"); eq(commands.out,"/dest")
commands,removed,ok,err=clone_test(true)
eq(ok,false); eq(removed,1); eq(#commands,2); eq(err.code,2)

local Launch=dofile(dir .. "launch.lua")
local function run_launch(args,opts,recovery)
  opts=opts or {}
  local fake={session="session:test",me=orch,dir="/state",journal="/tmp/launch-id/state",fs={},
    rex={layout={},session={},json={}}}
  local saved,observed={},{}
  local F,R=fake.fs,fake.rex
  function fake.die(text,code) error({text=text,code=code or 2},0) end
  function fake.note(text) observed.note=text end
  function fake.raw() end
  function fake.lines() end
  function fake.out(text) observed.output=text end
  function fake.finish(code) return fake.die("",code) end
  function fake.put(path,...)
    saved[path]={...}
    return true
  end
  function fake.need_me() end
  function fake.killed(kind) return opts.kill==(kind or "global") end
  function fake.attach() return true end
  function fake.resolve() return orch end
  function fake.root() return opts.root or {app="claude-code",state="idle"} end
  function fake.call(_,method)
    if method=="process" then return {child={pid=42}} end
  end
  function fake.screen() return '⏸ manual mode on' end
  function fake.exited() return false end
  function fake.mark() return true end
  function fake.sf() return "/state/block_child" end
  function fake.close_pane() return opts.close end
  function fake.remove_cage(path) observed.removed_cage=path; return true end
  function F.canonical(path) return path end
  F.logical=F.canonical
  function F.read_file() return opts.allowlist end
  function F.read(path) return opts.files and opts.files[path] end
  function F.executable(cmd) if not opts.missing then return "/agents/" .. cmd end end
  function F.test(_,path) observed.account=path; return opts.credential end
  function F.remove_state(path) observed.removed_state=path; return true end
  function R.json.encode(t) return json(t) end
  function R.json.decode() return opts.recover end
  function R.layout.block(spec) observed.layout=spec; return spec end
  function R.session.new_window(spec) observed.window=spec; return {block_ids={child},window_id="window:test"} end
  function R.session.list_blocks() return {blocks=opts.blocks or {}} end
  function R.session.set_block_label() return true end
  function R.session.set_window_label() return true end
  function R.sleep() end
  local cage={secrets="/credentials",profile="/cage.sb"}
  function cage.build(_,_,cfg,reserved)
    observed.chosen=cfg.account
    if not opts.cage then return nil,opts.cage_code or 1 end
    reserved(opts.cage.home)
    return opts.cage
  end
  function cage.overlap() return opts.overlap end
  function cage.override() return opts.override end
  local registry={identity=function() return {} end,check=function() return true end}
  function registry.acquire() return function() observed.released=true end end
  function registry.add() observed.claim=true; return true end
  function registry.remove(block) observed.removed_claim=block end
  local env={HOME="/home/test",PWD="/work",CLAUDE_CONFIG_DIR=opts.caller_account}
  os.getenv=function(key) return env[key] end
  local parser=Input(M)
  local launch=Launch(fake,M,LaunchDialog(fake,M,parser),parser,cage,registry)
  local passed,value=pcall(recovery and launch.recover or launch.launch,args)
  if not passed and type(value)~="table" then error(value,0) end
  return value or {code=0},observed,saved
end
eq(run_launch({"--nope"}).code,2)
eq(run_launch({"--ratio","3.2"}).code,2)
eq(run_launch({"--ratio","100"}).code,2)
eq(run_launch({"--ratio","100","--tab","target"}).code,0)
eq(run_launch({"--split","upper"}).code,2)
eq(run_launch({"--timeout","bad"}).code,2)
eq(run_launch({"--account","UPPER"}).code,2)
eq(run_launch({"--account","one","--no-cage"}).code,2)
eq(run_launch({"--account","one"}).code,2)
local reply,seen,state=run_launch({"--account","one","--tab","target","--label","-sample"},{
  credential=true,cage={home="/state/cage/claude.test",wrapper="/state/cage/claude.test/bin/claude",meta={},
    account="one",why="chosen with --account"}
})
eq(reply.code,0); eq(seen.chosen,"one"); eq(seen.account,"/credentials/claude-one.env")
eq(seen.window.window_label,"-sample.launch-launch-id"); eq(seen.claim,true); eq(seen.released,true)
eq(seen.output,child); eq(state["/state/block_child.own"][1],orch)
eq(not not state["/tmp/launch-id/state"][1]:find('"block":"block:child"',1,true),true)
-- A caged launch records the executable its cage runs, not the PATH match the cage skipped.
reply,seen,state=run_launch({"--agent","codex","--tab","target"},{
  cage={home="/state/cage/codex.test",wrapper="/state/cage/codex.test/bin/codex",meta={},bin="/release/bin/codex"}})
eq(reply.code,0); eq(state["/state/block_child.own"][7],"/release/bin/codex")
-- REX_ORCHESTRATOR_CAGE_<AGENT>_BIN stands in for a missing PATH match only when the child is caged.
reply,seen=run_launch({"--agent","claude","--tab","target"},{missing=true,override="/opt/claude"})
eq(reply.code,2); eq(not not reply.text:find("applies to caged launches only",1,true),true); eq(seen.window,nil)
reply=run_launch({"--agent","claude","--tab","target"},{missing=true})
eq(reply.code,2)
reply,seen,state=run_launch({"--agent","claude","--tab","target"},{missing=true,override="/opt/claude",
  cage={home="/state/cage/claude.test",wrapper="/state/cage/claude.test/bin/claude",meta={},bin="/opt/claude"}})
eq(reply.code,0); eq(state["/state/block_child.own"][7],"/opt/claude")
eq(run_launch({"--cage"}).code,2)
eq(run_launch({}, {cage_code=2}).code,2)
eq(run_launch({}, {cage={home="/state/cage/x"},overlap="/work"}).code,2)
eq(run_launch({}, {kill="global"}).code,2)
eq(run_launch({"--no-cage"}, {kill="claude"}).code,2)
eq(run_launch({"--dir","-"}).code,2)
eq(run_launch({"--trust","--dir","/work/❯"}).code,2)
eq(run_launch({"--no-cage","--tab","t"}, {allowlist="claude:claude",caller_account="/home/test/.claude-claude"}).code,0)
eq(run_launch({"--no-cage","--tab","t"}, {allowlist="claude:default",caller_account="/"}).code,0)
local recorded={session="session:test",owner=orch,tag="task.launch-id",cage="/state/cage/test"}
reply,seen,state=run_launch({}, {files={["/tmp/launch-id/state"]="fixture"},recover=recorded,
  blocks={{label=recorded.tag,block_id=child}},close=true},true)
eq(reply.code,0); eq(seen.removed_claim,child); eq(seen.removed_state,"/state/block_child")
eq(seen.removed_cage,recorded.cage)
reply,seen,state=run_launch({}, {files={["/tmp/launch-id/state"]="fixture"},recover=recorded,
  blocks={{label=recorded.tag,block_id=child}},close=false},true)
eq(reply.code,0); eq(seen.removed_claim,nil); eq(seen.removed_cage,nil)
eq(state["/state/block_child.own"][1],orch); eq(state["/state/block_child.cage"][1],"test")

-- launch refuses a caged DIR in a protected location however its path is cased: the home volume and the cage's own
-- path matching ignore case, so ~/.CODEX is ~/.codex.
do
  os.getenv=function(key) return ({HOME="/Users/test"})[key] end
  local fs={canonical=function(path) return path end,ondisk=function() return nil end}
  local K=dofile(dir .. "launch_cage.lua")({rex={},fs=fs,script_dir="/opt/skills/rex-orchestrator/scripts",dir="/state"},M)
  for _,case in ipairs({{"/Users/test/.CODEX/proj","/Users/test/.codex*"},{"/Users/test/.Claude-work/x","/Users/test/.claude*"},
    {"/Users/test/.GROK","/Users/test/.grok*"},{"/Users/test/.gemini/x","/Users/test/.gemini*"},
    {"/Users/test/.SSH/keys","/Users/test/.ssh"},{"/USERS/TEST","/Users/test"},{"/users","/Users"},
    {"/Users/test/LIBRARY","/Users/test/Library"},{"/Users/test/.Local/Bin/x","/Users/test/.local/bin"},
    {"/Users/test/.config/REX-orchestrator/Cage-Secrets/x","/Users/test/.config/rex-orchestrator/cage-secrets"},
    {"/Users/test/Library/Application Support/rex/x","/Users/test/Library/Application Support/rex"},
    {"/Users/test/Library/application support/REX","/Users/test/Library/Application Support/rex"},
    {"/Users/test/Library/Application Support","/Users/test/Library/Application Support/rex"},
    {"/Users/test/Library/Application Support/rexish",nil},
    {"/Users/test/projects/x",nil},{"/Users/test/.codexish-notes",  "/Users/test/.codex*"}}) do
    eq(K.overlap(case[1]),case[2],"overlap " .. case[1])
  end
end

-- Paths cross Rex's JSON byte for byte as Latin-1.
do
  local raw="/tmp/\255x/\195\169/\128\194"
  local wire=M.to_bytes(raw)
  eq(wire:gsub("[\194\195][\128-\191]",""):find("[\128-\255]"),nil,"the wire form is two-byte UTF-8 only")
  eq(M.from_bytes(wire),raw,"a non-UTF-8 path survives the round trip")
  eq(M.to_bytes("/plain/ascii"),"/plain/ascii","ASCII is unchanged")
end

-- Orphan decisions: only a gone orchestrator pane makes an orphan; close only finished turns, after the grace period.
do
  local base={owner="block:o",session="session:s",here="session:s",me="block:me",block="block:c",presence="gone",
    gone_for=700,grace=600,max_wait=7200}
  local function case(over)
    local t={}
    for k,v in pairs(base) do t[k]=v end
    for k,v in pairs(over or {}) do t[k]=v end
    return (Orphans.decide(t))
  end
  eq(case(),"check","a gone orchestrator's child past the grace period is checked")
  eq(case{checked=true,background="",state="done"},"close","done orphan closes")
  eq(case{checked=true,background="",state="idle"},"close","idle orphan closes")
  eq(case{checked=true,background="",state="error"},"close","errored orphan closes")
  eq(case{checked=true,exited=true,state="working"},"close","exited orphan closes")
  eq(case{checked=true,state="working"},"wait","working orphan waits")
  eq(case{checked=true,state="blocked"},"wait","blocked orphan waits")
  eq(case{checked=true},"wait","an orphan without a status waits")
  eq(case{checked=true,state="done",background="1 shell"},"wait","background work holds a done orphan")
  eq(case{checked=true,state="done"},"wait","a done orphan whose screen can't be read waits")
  eq(case{checked=true,state="working",gone_for=600+7200},"expire","the maximum wait leaves a busy orphan open")
  eq(case{checked=true,state="working",gone_for=600+7199},"wait","the maximum wait counts from the end of the grace period")
  eq(case{expired=true,checked=true,state="done"},"expired","an orphan left open stays open")
  eq(case{gone_for=599},"grace","the grace period holds a finished orphan")
  eq(case{gone_for=0,grace=0},"check","a zero grace period checks at once")
  eq(case{presence="present"},"skip","an open orchestrator pane makes no orphan")
  eq(case{presence=false},"skip","an orchestrator Rex can't check makes no orphan")
  eq(case{session=""},"skip","a record without a session is never an orphan")
  eq(case{session="session:other"},"skip","a record of another session is never an orphan")
  eq(case{owner=""},"skip","a missing ownership record is never an orphan")
  eq(case{owner="garbage"},"skip","an unreadable ownership record is never an orphan")
  eq(case{block="block:me"},"skip","the calling pane is never closed")
  eq(case{owner="block:me"},"skip","the caller's own children are not orphans")
  eq(case{block="block:o"},"skip","the orchestrator itself is never closed")
  eq(case{keep=true,checked=true,state="done"},"keep","REX_ORCHESTRATOR_ORPHANS=keep keeps orphans")
  eq(case{policy="keep",checked=true,state="done"},"keep","an opted-out launch keeps its orphans")
  eq(case{disabled=true,checked=true,state="done"},"keep","the kill switch keeps orphans")
  local env={}
  local function getenv(k) return env[k] end
  local s,bad=Orphans.settings(getenv)
  eq(s.keep,false,"orphans close by default"); eq(s.grace,600,"default grace"); eq(s.max_wait,7200,"default maximum wait"); eq(bad,nil)
  env={REX_ORCHESTRATOR_ORPHANS="keep",REX_ORCHESTRATOR_ORPHAN_GRACE="0",REX_ORCHESTRATOR_ORPHAN_MAX_WAIT="3h"}
  s,bad=Orphans.settings(getenv)
  eq(s.keep,true,"opt-out"); eq(s.grace,0,"zero grace"); eq(s.max_wait,10800,"hours"); eq(bad,nil)
  env={REX_ORCHESTRATOR_ORPHANS="maybe"}
  s,bad=Orphans.settings(getenv)
  eq(s.keep,true,"an unknown policy keeps orphans"); eq(bad,"REX_ORCHESTRATOR_ORPHANS takes close or keep, not 'maybe'")
  env={REX_ORCHESTRATOR_ORPHAN_GRACE="soon"}
  s,bad=Orphans.settings(getenv)
  eq(s.grace,600,"a bad grace keeps the default")
  eq(bad,"REX_ORCHESTRATOR_ORPHAN_GRACE takes a duration such as 0, 90s, 10m or 2h, not 'soon'")
end

-- The sweep against a fake Rex: presence on consecutive checks, the saved first sighting, close and watcher starts.
do
  local function sweep_fixture(o)
    o=o or {}
    local now=5000
    local files,daemons,closed,sleeps={},{},{},0
    local env=o.env or {}
    os.time=function() return now end
    local blocks=o.blocks or {"block:o","block:c"}
    local states=o.states or {["block:c"]="done"}
    local fs={}
    function fs.own_paths(dir)
      local list,watch={},{}
      for p in pairs(files) do
        if M.starts(p,dir .. "/watch/") then watch[#watch+1]=p
        elseif M.starts(p,dir .. "/") and p:match("%.own$") then list[#list+1]=p end
      end
      table.sort(list); table.sort(watch)
      return list,watch
    end
    function fs.lock(path) if o.locked and o.locked[path] then return nil,2 end; return function() end end
    function fs.read(p) return files[p] end
    function fs.put(p,t) files[p]=t; return true end
    function fs.unlink(p) files[p]=nil; return true end
    function fs.mkdir() return true end
    function fs.exists(p) return files[p]~=nil end
    function fs.daemon(lock,log,tries,argv) daemons[#daemons+1]={lock=lock,tries=tries,argv=argv}; return true end
    local rex={session={},block={},json={encode=json}}
    function rex.sleep(n) sleeps=sleeps+n; now=now+n; if o.after_sleep then blocks=o.after_sleep end end
    function rex.call(method,a)
      if method=="session.attach" then return {} end
      if method=="server.status" then return {host_id="host:a"} end
      if method=="target.resolve" then
        if o.resolve_error then return nil,"offline" end
        local q=a.queries[1]
        if a.kinds[1]=="block" then
          local s=a.scope and a.scope.session
          if (o.block_found or {})[q] then return {results={{status="resolved",target={block_id=q}}}} end
          if (o.live_sessions or {})[s] or s=="session:s" then return {results={{status="not_found",query=q}}} end
          return nil,"code=session_not_found"
        end
        if (o.live_sessions or {})[q] or q=="session:s" then
          return {results={{status="resolved",target={session_id=q}}}}
        end
        return {results={{status="not_found",query=q}}}
      end
    end
    function rex.session.list_blocks()
      if o.list_error then return nil end
      local list={}
      for _,id in ipairs(blocks) do list[#list+1]={block_id=id} end
      return {blocks=list}
    end
    function rex.block.call(_,method,a)
      if method=="process" then
        return {child={pid=tonumber(M.lines(files["/state/" .. a.block_id:gsub(":","_") .. ".own"])[2])}}
      end
      if method=="program_status" then return {records={{app="claude-code",state=states[a.block_id],updated_at="t"}}} end
      if method=="format" then
        if o.screen==false then return nil,"offline" end
        return {content=o.screen or ""}
      end
    end
    local saved=os.getenv
    os.getenv=function(k) if k=="REX_ORCHESTRATOR_STATE_DIR" then return "/state" end return env[k] end
    local notes={}
    local C=M.new(rex,fs,{out=function() end,note=function(t) notes[#notes+1]=t end,raw=function(t) notes[#notes+1]=t end})
    local W=Orphans.new(C,M,function(b,missing) closed[#closed+1]=b .. (missing and " missing" or ""); files["/state/" .. b:gsub(":","_") .. ".own"]=nil; return true end)
    os.getenv=saved
    C.session="session:s"; C.me=o.me or "block:me"; C.script_dir="/scripts"; C.rex_bin="/bin/rex"
    local default={"block:o","42","","claude","/w","","/bin/claude","session:s","close",o.grace or "600",o.max_wait or "7200"}
    for block,record in pairs(o.records or {["block:c"]=default}) do
      files["/state/" .. block:gsub(":","_") .. ".own"]=table.concat(record,"\n") .. "\n"
    end
    for path,text in pairs(o.files or {}) do files[path]=text end
    return {W=W,files=files,daemons=daemons,closed=closed,notes=notes,
      sleeps=function() return sleeps end,advance=function(n) now=now+n end,set=function(b) blocks=b end,
      state=function(b,s) states[b]=s end}
  end
  -- Present: nothing closes; the orchestrator's watcher is started when its heartbeat is stale.
  local f=sweep_fixture()
  local r=f.W.sweep()
  eq(#f.closed,0,"a present orchestrator keeps its child"); eq(r.remaining,1,"its child is still watched")
  eq(#f.daemons,0,"a watcher's sweep starts no watcher")
  r=f.W.scan()
  eq(#f.daemons,1,"a call starts a missing watcher"); eq(f.daemons[1].tries,1,"a call tries the watcher lock once")
  eq(f.daemons[1].argv[3],"do","the watcher is a rex do script"); eq(f.daemons[1].argv[2],"--autostart=false","the watcher never starts a server")
  eq(r.status["block:c"],nil,"a live orchestrator's child is no orphan")
  f=sweep_fixture{files={["/state/watch/block_o.alive"]="4995\n"}}
  f.W.scan()
  eq(#f.daemons,0,"a fresh heartbeat means a watcher runs")
  f=sweep_fixture{me="block:o"}
  f.W.scan(); eq(#f.daemons,1,"the caller's own calls restart its watcher")
  -- A call only looks: no close, no recheck, no mark; the watcher of a gone pane is started.
  f=sweep_fixture{blocks={"block:c"},grace="0"}
  r=f.W.scan()
  eq(#f.closed,0,"a call closes nothing"); eq(f.sleeps(),0,"a call never sleeps"); eq(f.files["/state/watch/block_o.gone"],nil,"nor marks")
  eq(r.status["block:c"],"grace","a pane not yet confirmed gone shows the grace period"); eq(#f.daemons,1,"the orphan's watcher is started")
  f=sweep_fixture{blocks={"block:c"},grace="600",files={["/state/watch/block_o.gone"]="4500\n4990\n"}}
  eq(f.W.scan().status["block:c"],"grace","within its own grace period")
  f=sweep_fixture{blocks={"block:c"},grace="300",files={["/state/watch/block_o.gone"]="4500\n4990\n"}}
  eq(f.W.scan().status["block:c"],"waiting","past its grace period, waiting for its watcher")
  f=sweep_fixture{blocks={"block:c"},files={["/state/block_c.orphan"]="expired\n"}}
  r=f.W.scan(); eq(r.status["block:c"],"expired","left open"); eq(#f.daemons,0,"no watcher for an orphan left open")
  f=sweep_fixture{blocks={"block:c"},files={["/state/disabled"]=""}}
  r=f.W.scan(); eq(r.status["block:c"],"kept","the kill switch"); eq(#f.daemons,0,"the kill switch starts no watcher from a call")
  f=sweep_fixture{blocks={"block:c"},env={REX_ORCHESTRATOR_ORPHANS="keep"}}
  r=f.W.scan(); eq(r.status["block:c"],"grace","a call's keep changes no child's state"); eq(#f.daemons,0,"and starts no watcher")
  f=sweep_fixture{blocks={"block:c"},records={["block:c"]={"block:o","42","","claude","/w","","/bin/claude","session:s","keep"}}}
  r=f.W.scan(); eq(r.status["block:c"],"kept","launched with keep"); eq(#f.daemons,0,"no watcher for a child launched with keep")
  f.set({"block:o","block:c"}); f.W.scan(); eq(#f.daemons,0,"nor while its orchestrator lives")
  f=sweep_fixture{list_error=true}
  f.W.scan(); eq(#f.daemons,0,"no block list, nothing started")
  -- A pane missing once, then back: not gone, nothing saved.
  f=sweep_fixture{blocks={"block:c"},after_sleep={"block:o","block:c"}}
  r=f.W.sweep()
  eq(#f.closed,0,"one missed check is not gone"); eq(f.files["/state/watch/block_o.gone"],nil,"no sighting is saved")
  eq(f.sleeps(),1,"a missing pane is checked again after a second")
  -- Gone on two checks: the first sighting is saved and the grace period runs.
  f=sweep_fixture{blocks={"block:c"}}
  r=f.W.sweep()
  eq(#f.closed,0,"the grace period holds the orphan"); eq(r.status["block:c"],"grace","ls shows the grace period")
  eq(f.files["/state/watch/block_o.gone"],"5000\n5001\n","the first sighting and the confirming check are saved")
  f.advance(299); f.W.sweep(); f.advance(299); r=f.W.sweep()
  eq(f.sleeps(),1,"a saved sighting needs no recheck"); eq(#f.closed,0,"still in the grace period")
  f.advance(1); r=f.W.sweep()
  eq(f.closed[1],"block:c","a finished orphan closes when the grace period ends")
  eq(f.notes[#f.notes],"closed block:c, an orphan (its orchestrator block:o's pane is gone): done","the close is reported")
  -- A mark nothing confirmed for longer than O.stale is a new first sighting with two new checks.
  f=sweep_fixture{blocks={"block:c"},grace="0",files={["/state/watch/block_o.gone"]="1000\n1000\n"}}
  r=f.W.sweep()
  eq(f.sleeps(),1,"a stale mark is checked twice again"); eq(f.files["/state/watch/block_o.gone"],"5000\n5001\n","and restarts")
  f=sweep_fixture{blocks={"block:c"},grace="600",files={["/state/watch/block_o.gone"]="4000\n4900\n"}}
  r=f.W.sweep()
  eq(f.sleeps(),0,"a recently confirmed mark needs no recheck"); eq(r.status["block:c"],nil,"and its grace period has run")
  eq(f.closed[1],"block:c","so the orphan closes"); eq(f.files["/state/watch/block_o.gone"],"4000\n5000\n","the mark is confirmed again")
  f=sweep_fixture{blocks={"block:c"},grace="0",files={["/state/watch/block_o.gone"]="junk\n"}}
  f.W.sweep(); eq(f.sleeps(),1,"a broken mark starts over")
  f=sweep_fixture{blocks={"block:c"},grace="0",after_sleep={"block:o","block:c"},files={["/state/watch/block_o.gone"]="1000\n1000\n"}}
  f.W.sweep(); eq(f.files["/state/watch/block_o.gone"],nil,"a stale mark is removed when the pane is found"); eq(#f.closed,0)
  -- A working orphan waits and then closes; the pane coming back cancels everything.
  f=sweep_fixture{blocks={"block:c"},grace="0",states={["block:c"]="working"}}
  r=f.W.sweep()
  eq(r.status["block:c"],"waiting","a working orphan waits"); eq(#f.closed,0)
  f.state("block:c","blocked"); f.W.sweep(); eq(#f.closed,0,"a blocked orphan waits")
  f.set({"block:o","block:c"}); r=f.W.sweep()
  eq(f.files["/state/watch/block_o.gone"],nil,"a pane that comes back cancels the orphan"); eq(r.status["block:c"],nil)
  f.set({"block:c"}); f.state("block:c","done"); f.W.sweep()
  eq(f.closed[1],"block:c","a gone orchestrator's done child closes at grace 0")
  -- The child's own limits count, never the sweeping process's: a child launched with 1h is not closed by a sweep
  -- run with a zero grace period, nor is the grace saved with the first sighting.
  f=sweep_fixture{blocks={"block:c"},grace="3600",env={REX_ORCHESTRATOR_ORPHAN_GRACE="0",REX_ORCHESTRATOR_ORPHAN_MAX_WAIT="0"}}
  r=f.W.sweep(); f.advance(60); r=f.W.sweep()
  eq(#f.closed,0,"a sweep's own grace never applies to another launch's child"); eq(r.status["block:c"],"grace")
  for _=1,13 do f.advance(290); f.W.sweep() end
  eq(f.closed[1],"block:c","the child's own grace period ends")
  f=sweep_fixture{blocks={"block:c"},records={["block:c"]={"block:o","42","","claude","/w","","/bin/claude","session:s","close"}},
    env={REX_ORCHESTRATOR_ORPHAN_GRACE="0"}}
  r=f.W.sweep(); eq(r.status["block:c"],"grace","a record without limits takes the defaults, not the caller's")
  -- A closed child pane is cleaned up as missing.
  f=sweep_fixture{blocks={},grace="0"}
  f.W.sweep(); eq(f.closed[1],"block:c missing","an orphan whose pane is already closed is cleaned up")
  -- Background work holds a done orphan.
  f=sweep_fixture{blocks={"block:c"},grace="0",screen=fixture("bg/live-1-shell")}
  r=f.W.sweep(); eq(r.status["block:c"],"waiting","background work holds the orphan"); eq(#f.closed,0)
  f=sweep_fixture{blocks={"block:c"},grace="0",screen=false}
  r=f.W.sweep(); eq(r.status["block:c"],"waiting","an unreadable screen holds a done orphan"); eq(#f.closed,0)
  -- The maximum wait marks the orphan left open, and it stays open after its turn ends.
  f=sweep_fixture{blocks={"block:c"},grace="0",max_wait="10",
    states={["block:c"]="working"}}
  f.W.sweep(); f.advance(10); r=f.W.sweep()
  eq(r.status["block:c"],"expired","the maximum wait leaves the orphan open"); eq(f.files["/state/block_c.orphan"],"expired\n")
  eq(r.remaining,0,"an orphan left open is no longer watched"); eq(r.left,1,"it is counted as left open")
  f.state("block:c","done"); f.W.sweep(); eq(#f.closed,0,"an orphan left open is never closed")
  -- Kill switch, opt-out, another session, a missing session, another orchestrator.
  f=sweep_fixture{blocks={"block:c"},grace="0",files={["/state/disabled"]=""}}
  r=f.W.sweep(); eq(r.status["block:c"],"kept","the kill switch keeps the orphan"); eq(#f.closed,0)
  f.W.watcher=true; r=f.W.sweep("block:o")
  eq(r.remaining,1,"a running watcher keeps watching a child the kill switch holds")
  f=sweep_fixture{blocks={"block:c"},grace="0",env={REX_ORCHESTRATOR_ORPHANS="keep"}}
  r=f.W.sweep(); eq(r.status["block:c"],"kept","the opt-out keeps the orphan"); eq(#f.closed,0)
  f=sweep_fixture{blocks={"block:c"},grace="0",
    records={["block:c"]={"block:o","42","","claude","/w","","/bin/claude","session:s","keep","0"}}}
  r=f.W.sweep(); eq(r.status["block:c"],"kept","a launch's opt-out keeps the orphan"); eq(#f.closed,0)
  eq(r.remaining,0,"a child launched with keep is never watched")
  f.set({"block:o","block:c"}); r=f.W.sweep(); eq(r.remaining,0,"nor while its orchestrator lives")
  f=sweep_fixture{blocks={"block:c"},grace="0",
    records={["block:c"]={"block:o","42","","claude","/w","","/bin/claude","session:other","close","0"},
      ["block:d"]={"block:o","43","","claude","/w","","/bin/claude"},
      ["block:e"]={"block:p","44","","claude","/w","","/bin/claude","session:s","close","0"}},
    states={["block:c"]="done",["block:d"]="done",["block:e"]="done"}}
  f.set({"block:c","block:d","block:e","block:p"})
  r=f.W.sweep()
  eq(#f.closed,0,"other sessions, sessionless records and live orchestrators are untouched")
  eq(r.remaining,1,"only the live orchestrator's child in this session is counted")
  -- Watch files of an orchestrator no record names are removed once no watcher holds the lock.
  f=sweep_fixture{files={["/state/watch/block_x.lock"]="",["/state/watch/block_x.log"]="old\n",
    ["/state/watch/block_o.lock"]="",["/state/watch/block_o.log"]="mine\n"},records={}}
  f.W.scan()
  eq(f.files["/state/watch/block_x.log"],nil,"an orchestrator without children loses its watch files")
  eq(f.files["/state/watch/block_x.lock"],nil); eq(f.files["/state/watch/block_o.log"],nil)
  f=sweep_fixture{files={["/state/watch/block_x.lock"]="",["/state/watch/block_x.log"]="old\n",
    ["/state/watch/block_o.log"]="mine\n"},locked={["/state/watch/block_x.lock"]=true}}
  f.W.scan()
  eq(f.files["/state/watch/block_x.log"],"old\n","a running watcher keeps its files")
  eq(f.files["/state/watch/block_o.log"],"mine\n","an orchestrator with children keeps its files")
  -- Records of a session the server no longer has are forgotten (state only, nothing closed), two per call, once the
  -- session and the block are both missed on looks a minute apart.
  local dead=function(s,host) return {"block:o","42","","claude","/w","","/bin/claude",s,"close","0","0",host} end
  f=sweep_fixture{records={["block:c"]=dead("session:s","host:a"),["block:d"]=dead("session:gone","host:a"),
    ["block:e"]=dead("session:gone","host:b"),["block:f"]=dead("session:gone",""),["block:g"]=dead("session:live","host:a"),
    ["block:h"]=dead("session:gone","host:a"),["block:i"]=dead("session:gone","host:a")},live_sessions={["session:live"]=true}}
  f.W.scan()
  eq(#f.closed,0,"a first miss forgets nothing"); eq(f.files["/state/block_d.forget"],"5000\n","it is saved")
  f.advance(59); f.W.scan(); eq(#f.closed,0,"nor a second miss within a minute")
  f.advance(1); f.W.scan()
  eq(table.concat(f.closed,","),"block:d missing,block:h missing","a gone session's records go, two per call, as already closed")
  eq(f.files["/state/block_e.own"]~=nil and f.files["/state/block_f.own"]~=nil and f.files["/state/block_g.own"]~=nil,true,
    "another server's, a hostless and a live session's records stay")
  f.W.scan(); eq(f.closed[3],"block:i missing","the next call goes on")
  f=sweep_fixture{records={["block:d"]=dead("session:gone","host:a")},files={["/state/block_d.forget"]="1000\n"},
    block_found={["block:d"]=true}}
  f.W.scan(); eq(#f.closed,0,"a child whose block Rex still finds is kept")
  eq(f.files["/state/block_d.forget"],nil,"and its first miss is dropped")
  f=sweep_fixture{records={["block:d"]=dead("session:gone","host:a")},files={["/state/block_d.forget"]="1000\n"},
    live_sessions={["session:gone"]=true}}
  f.W.scan(); eq(#f.closed,0,"a session found again keeps its child"); eq(f.files["/state/block_d.forget"],nil)
  f=sweep_fixture{records={["block:d"]=dead("session:gone","host:a")},files={["/state/disabled"]="",["/state/block_d.forget"]="1000\n"}}
  f.W.scan(); eq(#f.closed,0,"the kill switch keeps a gone session's records")
  f=sweep_fixture{records={["block:d"]=dead("session:gone","host:a")},resolve_error=true,
    files={["/state/block_d.forget"]="1000\n"}}
  f.W.scan(); eq(#f.closed,0,"a session Rex can't check is kept")
  eq(f.files["/state/block_d.forget"],"1000\n","and its first miss stays for a later look")
  -- Rex can't list the blocks: nothing is decided.
  f=sweep_fixture{list_error=true,grace="0"}
  r=f.W.sweep(); eq(#f.closed,0,"no block list, no close"); eq(r.remaining,1,"no block list, still watched")
  -- A watcher sweeps only its orchestrator and reports when it may stop.
  f=sweep_fixture{blocks={"block:c"},grace="0",states={["block:c"]="working"}}
  f.W.watcher=true
  r=f.W.sweep("block:o")
  eq(r.gone,true,"the watcher learns its orchestrator is gone"); eq(r.deadline,5000+0+7200+60,"and when it may stop")
  eq(#f.daemons,0,"a watcher starts no watcher")
  os.time=original_time
end

os.time,os.getenv=original_time,original_getenv
print("Lua unit: " .. pass .. " passed")
