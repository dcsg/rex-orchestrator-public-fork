return function(C, M, A)
  local R=C.rex
  local commands={}
  function commands.status(args)
    C.target(args[1])
    C.out(C.status(C.block))
  end
  function commands.screen(args)
    C.target(args[1])
    local n=args[2]
    if not n or n=="" then n="60" end
    if not n:match("^%d+$") then C.die("screen: LINES takes a whole number, not '" .. n .. "'") end
    local text=C.screen(C.block)
    if not text then C.die("rex could not capture " .. C.block,1) end
    local a=M.lines(text); while #a>0 and not a[#a]:match("%S") do a[#a]=nil end
    for i=math.max(1,#a-tonumber(n)+1),#a do C.out(a[i]) end
  end
  function commands.ls()
    local r=R.session.list_blocks{session_id=C.session}
    if not r then C.die("rex could not list the blocks",1) end
    if type(r.blocks)~="table" then C.die("rex returned a block list that isn't JSON",1) end
    local known={claude=true,codex=true,grok=true,agy=true,muse=true}
    for _,b in ipairs(r.blocks) do
      local id=b.block_id
      if id and id~=C.me and (b.flavor or ""):find("terminal",1,true) then
        local p=C.call(id,"process")
        if p and p.last_exit==nil and p.child then
          local rec=C.root(id) or {}; local live=next(rec)~=nil
          local owner=(rec.owner or {}).pid
          if live and owner then
            live=C.fs.pid_alive(owner) or tostring((p.child or {}).pid)==tostring(owner) or tostring((p.foreground or {}).pid)==tostring(owner)
          end
          local function agent(v) return known[((v or {}).argv0 or ""):match("([^/]*)$")] end
          if live or agent(p.foreground) or agent(p.child) then
            local json=C.status(id)
            local mine=C.me~="" and C.line(id,"own",1)==C.me
            C.out(id .. "\t" .. json:sub(1,-2) .. ',"label":' .. M.json_string(M.tsv(b.label or "")) .. ',"mine":' .. tostring(mine) .. '}')
          end
        end
      end
    end
  end
  function commands.wait(args)
    local timeout,ignore,bgmax,approve=600,false,300,""
    if args[1]=="--force" then C.force=true; table.remove(args,1) end
    local q=args[1]; if not q or q=="" then C.die("missing BLOCK") end
    local i=2
    local function value()
      local v=args[i+1]; if not v or v=="" then C.die(args[i] .. " needs a value") end
      return v
    end
    while i<=#args do
      local k=args[i]
      if k=="--timeout" then timeout=M.duration(k,value(),C.die); i=i+2
      elseif k=="--bg-max" then bgmax=M.duration(k,value(),C.die); i=i+2
      elseif k=="--ignore-background" then ignore=true; i=i+1
      elseif k=="--force" then C.force=true; i=i+1
      elseif k=="--approve-in" then
        local v=value(); approve=C.fs.canonical(v)
        if not approve then C.die("wait: no such directory: " .. v) end
        local home=M.env("HOME")
        for _,f in ipairs({"/","/Users",home or "/",(home or "") .. "/Library",(home or "") .. "/Repos"}) do
          if approve==(C.fs.canonical(f) or "") then C.die("wait: --approve-in " .. v .. " is too broad; give the task's own directory") end
        end
        i=i+2
      else C.die("wait: unknown option " .. k) end
    end
    C.target(q,true)
    if approve~="" then C.owned() end
    local sf=C.sf(C.block)
    if approve~="" and C.read(C.block,"cage") then
      C.note("wait: --approve-in is ignored for a caged block (its prompts go to the user)"); approve=""
    end
    local mark=M.lines(C.read(C.block)); local since,bgbase=mark[1] or "",mark[2] or ""
    local held,held_at,bg_gone=(C.read(C.block,"hold") or ""):match("^(%S+)%s+(%d+)%s*(%d*)")
    held=held or ""; held_at=tonumber(held_at); bg_gone=tonumber(bg_gone)
    local rec,state,upd,bg=nil,"","",""
    local worked,idle_at,since_at=false,nil,os.time()
    local screen_timer,retry_timer,idle_timer,stale_timer
    local function hold_text() return held .. " " .. (held_at or "") .. " " .. (bg_gone or "") end
    local saved=hold_text()
    local function save()
      local t=hold_text()
      if saved~=t then saved=t; if not C.put(sf .. ".hold",t) then C.note("could not save the hold") end end
    end
    local result={}
    local function stop(code)
      result.code=code
      error(result,0)
    end
    local function guard(fn)
      return function(...)
        local ok,err=pcall(fn,...)
        if ok then return end
        if err==result then R.stop(result.code) end
        C.die("wait: " .. tostring(err),1)
      end
    end
    local function after(delay,fn) return R.after(delay,guard(fn)) end
    local function every(delay,fn) return R.every(delay,guard(fn)) end
    local function finish(text,code)
      save()
      if code~=124 then C.fs.remove(sf .. ".hold") end
      C.out(text)
      stop(code)
    end
    local function turn_over()
      if ignore then return true end
      local screen=C.screen(C.block); if not screen then return false end
      bg=M.background(screen)
      local base=tonumber((bgbase:match("^(%d+) "))) or 0
      local count=tonumber((bg:match("^(%d+) "))) or 0
      local now=os.time()
      if bg~="" and count>base then
        if held~=upd then held=upd; held_at=now end
        bg_gone=nil
        if now-(held_at or now)>=bgmax then C.note("background work still running after " .. bgmax .. "s (" .. bg .. ")"); return true end
        return false
      end
      bg=""
      if held=="" or held~=upd then return true end
      if (rec.effective_app or rec.app)=="grok-build" then
        local s=C.screen(C.block); if not s then return false end
        if table.concat(M.region(s)," "):gsub("%s+"," "):find("Ctrl+c:cancel",1,true) then bg_gone=nil; return false end
      end
      bg_gone=bg_gone or now
      return now-bg_gone>=20
    end
    local evaluate
    local function later_retry()
      if retry_timer then return end
      retry_timer=after(0.5,function() retry_timer=nil; evaluate(true,true) end)
    end
    local function stale_check()
      if stale_timer then return end
      stale_timer=after(math.max(0,11-(os.time()-since_at)),function()
        stale_timer=nil
        evaluate(true,true)
      end)
    end
    local function visuals(on)
      if on and not screen_timer then screen_timer=every(0.5,function() evaluate(false,false) end)
      elseif not on and screen_timer then screen_timer:cancel(); screen_timer=nil end
    end
    evaluate=function(refresh,process)
      if process then
        local ex=C.exited(C.block)
        if ex then finish("exited",12) end
        if ex==nil then
          if not R.call("server.status") then
            C.note("rex did not answer for block " .. C.block)
            stop(1)
          end
          later_retry()
        end
      end
      if refresh then rec=C.root(C.block); if not rec then later_retry() end end
      if not rec then return end
      if approve~="" and C.stopped()=="" then
        local scr=C.screen(C.block)
        if scr then
          local ok,why=C.pin(scr,rec)
          if not ok then
            if A.pressed then C.kill("an approval by wait --approve-in in " .. C.block .. " was followed by " .. why .. ", so its option 1 was not one-time") end
            C.stop(why); finish("stopped",10)
          end
        end
      end
      state,upd=rec.state or "",rec.updated_at or ""
      if state=="working" then worked=true end
      if state~="idle" then idle_at=nil; if idle_timer then idle_timer:cancel(); idle_timer=nil end end
      local fresh=state~="" and (upd~=since or (held~="" and upd==held))
      local stale_prompt=not fresh and state=="blocked" and (rec.effective_app or rec.app)=="claude-code"
      if not stale_prompt and stale_timer then
        stale_timer:cancel()
        stale_timer=nil
      end
      if fresh then
        if state=="done" then
          if turn_over() then
            -- A screen timer can race a queued status event. Recheck before returning a cached result.
            if not refresh then return evaluate(true,true) end
            finish(state,0)
          end
        elseif state=="idle" then
          if not idle_at then
            idle_at=os.time()
            idle_timer=after(8,function() idle_timer=nil; evaluate(false,false) end)
          end
          if turn_over() and (worked or held~="" or os.time()-idle_at>=8) then
            if not refresh then return evaluate(true,true) end
            finish(state,0)
          end
        elseif state=="blocked" then
          if not refresh then return end -- Only a fresh snapshot can authorize a key press.
          local ar=1
          if approve~="" and rec.kind=="permission" then ar=A.once(rec,approve) end
          if ar==0 then
            since=upd
            since_at=os.time()
            if (rec.effective_app or rec.app)=="claude-code" then stale_check() end
          elseif ar==2 then later_retry()
          else finish("blocked " .. (rec.kind or "unknown") .. " " .. (rec.msg or ""),10) end
        elseif state=="error" then finish("error " .. (rec.msg or ""),11) end
      elseif stale_prompt then
        if os.time()-since_at>10 then
          if not refresh then return evaluate(true,true) end
          C.note("no new report since send/keys: the prompt is still up")
          finish("blocked " .. (rec.kind or "unknown") .. " " .. (rec.msg or ""),10)
        end
        stale_check()
      end
      save()
      -- Only screen-derived guards need sampling: Rex has no screen-damage event.
      visuals(approve~="" or (fresh and (state=="done" or state=="idle") and not ignore))
    end
    local function target(ctx,ev)
      return (ev.block_id or ctx.block_id)==C.block and (ev.session_id or ctx.session_id)==C.session
    end
    local function on_target(event,fn)
      R.on(event,guard(function(ctx,ev) if target(ctx,ev) then fn() end end))
    end
    local function refresh() evaluate(true,true) end
    local function exited() finish("exited",12) end
    on_target("terminal.program_status_changed",refresh)
    on_target("terminal.program_status_removed",refresh)
    on_target("terminal.process_changed",refresh)
    on_target("terminal.child_exited",exited)
    on_target("block_closed",exited)
    R.on("session_destroyed",guard(function(ctx,ev)
      if (ev.session_id or ctx.session_id)==C.session then exited() end
    end))
    after(timeout+1,function()
      evaluate(true,true)
      local why=""
      if state~="" and upd==since and upd~=held then why=", no new report since send/keys" end
      finish("timeout (state=" .. (state~="" and state or "none") .. (bg~="" and ", background: " .. bg or "") .. why .. ")",124)
    end)
    -- The first snapshot can precede stream attachment. Recover missed updates and detect a lost stream.
    after(0,refresh)
    after(1,refresh)
    every(5,refresh)
  end
  return commands
end
