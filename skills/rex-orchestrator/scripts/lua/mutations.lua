return function(C, M, I, registry)
  local R=C.rex
  local commands={}
  local interrupts={escape=true,esc=true,["ctrl+c"]=true}
  local mode_keys={["shift+tab"]=true,btab=true,backtab=true,["s-tab"]=true}
  local restricted={"/permissions","/allowed-tools","/config","/settings","/add-dir","/hooks","/plugin","/mcp"}

  local function target(verb,args,gone)
    if args[1]=="--force" then C.force=true; table.remove(args,1) end
    C.need_me()
    C.target(table.remove(args,1),gone)
    if verb=="keys" and #args==0 then C.die("keys: no keys given") end
    C.owned(verb)
  end

  local function alive(verb)
    local exited=C.exited(C.block)
    if exited then C.die(verb .. ": the agent in " .. C.block .. " has exited",12) end
    if exited==nil then C.die(verb .. ": cannot read " .. C.block .. "'s process; nothing was sent",1) end
  end

  local function kill_switch(verb,rec)
    if C.killed() then
      C.die(verb .. ": stopped: the kill switch " .. C.dir .. "/disabled is set; report it, never remove it yourself")
    end
    local kind=C.kind(rec)
    if kind~="" and not C.caged() and C.killed(kind) then
      C.die(verb .. ": stopped: the kill switch " .. C.dir .. "/disabled." .. kind ..
        " is set, so nothing is typed into an uncaged " .. kind .. "; report it, never remove it yourself")
    end
    return kind
  end

  local function pin(screen,rec)
    local ok,why=C.pin(screen,rec)
    if not ok then C.stop(why); R.stop(2) end
  end

  local function input_ready(typed)
    local left=typed and "the text is typed but not submitted" or "nothing was sent"
    local rec=C.root(C.block)
    if not rec then C.die("send: cannot read the state of " .. C.block .. "; " .. left,1) end
    local screen=C.screen(C.block)
    if not screen then C.die("send: cannot read the screen of " .. C.block .. "; " .. left,1) end
    local why
    if rec.state=="blocked" then
      why="blocked " .. (rec.kind or "unknown") .. " " .. (rec.msg or "")
    elseif rec.state=="working" and not typed and
      ((rec.effective_app or rec.app)~="codex" or screen:lower():find("esc to interrupt",1,true)) then
      why="working"
    elseif I.dialog(screen,typed) then
      why="a dialog is on screen"
    end
    if why then
      C.die("send: " .. C.block .. " is not ready for input (" .. why .. "); " .. left ..
        ". Look with screen; answer a dialog with keys",4)
    end
    return rec,screen
  end

  local function claude_prompt(text)
    if text:match("^%s*[0-9]") then
      C.die("send: refusing a prompt that starts with a digit: claude's session survey would take it as a rating; reword it")
    end
    if C.caged() then return end
    local word=(text:sub(1,200):match("^%s*(%S+)") or ""):lower()
    if not M.starts(word,"/") then return end
    for _,command in ipairs(restricted) do
      if M.starts(command,word) then
        C.die("send: refusing " .. word .. " for an uncaged claude: " .. command ..
          " would change what it may do for the whole session; scope permissions at launch (--allow, --allow-edits) or leave it to the user")
      end
    end
  end

  function commands.send(args)
    target("send",args)
    kill_switch("send")
    local text
    if args[1]=="-f" then
      local path=args[2] or ""
      text=C.fs.read_file(path)
      if not text then C.die("send: no such file: " .. path) end
      text=text:gsub("\n+$",""):gsub("%z","")
    else
      text=table.concat(args," ")
    end
    text=text:gsub("[\r\n\t]"," ")
    if not text:find("[^ ]") then C.die("send: empty prompt") end
    if text:match("^%s*!") then
      C.die("send: refusing a prompt that starts with '!': the agent would run it as a shell command without asking; reword it")
    end
    alive("send")
    local rec,screen=input_ready(false)
    local why=C.stopped()
    if why~="" then C.die("send: " .. C.block .. " is stopped (" .. why .. "); report it") end
    pin(screen,rec)
    if C.kind(rec)=="claude" then claude_prompt(text) end
    if not C.mark(rec) then C.die("send: cannot read or save the state of " .. C.block .. "; nothing was sent",1) end
    local attached,err=C.attach()
    local typed
    if attached then
      typed,err=R.block.call("com.superlogical.terminal","write",{session_id=C.session,block_id=C.block,data=text})
    end
    if not typed then
      if err then C.raw("Error: " .. err) end
      C.die("send: rex could not type into " .. C.block,1)
    end
    R.sleep(0.5)
    local updated=rec.updated_at
    rec,screen=input_ready(true)
    if rec.updated_at~=updated and not C.mark_since(rec) then C.note("could not save the state of " .. C.block) end

    local app=rec.effective_app or rec.app
    for attempt=0,6 do
      if not I.dialog(screen,true) and I.typed_shown(screen,text,app) then
        local entered=C.enter()
        if not entered then R.sleep(0.3); entered=C.enter() end
        if not entered then
          C.die("send: the prompt is typed but not submitted (Return failed twice); check screen " ..
            C.block .. ", then keys " .. C.block .. " enter",1)
        end
        return
      end
      if attempt<6 then
        R.sleep(0.5)
        screen=C.screen(C.block)
        if not screen then C.die("send: cannot read the screen of " .. C.block .. "; the text is typed but not submitted",1) end
      end
    end
    C.die("send: " .. C.block .. "'s input box doesn't show the prompt; the text is typed but not submitted. Look with screen",4)
  end

  local function guard_keys(args,rec)
    local kind=kill_switch("keys",rec)
    local why=C.stopped()
    if why~="" then C.die("keys: " .. C.block .. " is stopped (" .. why .. "): only escape and ctrl+c; report it") end
    if kind=="claude" then
      for _,key in ipairs(args) do
        if mode_keys[key:lower()] then
          C.die("keys: refusing " .. key .. " for claude: it switches the session's permission mode; leave that to the user")
        end
      end
    end
    local screen=C.screen(C.block)
    if not screen then C.die("keys: cannot read the screen of " .. C.block .. "; no key was pressed",1) end
    pin(screen,rec)
    local blocked=rec.state=="blocked" and (rec.kind=="permission" or rec.kind=="auth")
    if C.caged() or rec.kind=="question" or not (I.dialog(screen,false) or blocked) then return end
    for _,key in ipairs(args) do
      if not interrupts[key] and key~="up" and key~="down" then
        if key~="enter" and not key:match("^%d$") then
          C.die("keys: refusing " .. key .. " at the dialog in " .. C.block ..
            ": only escape, ctrl+c, up, down, and enter or a digit on a one-time answer; leave it to the user")
        end
        if #args~=1 then C.die("keys: at a dialog, press " .. key .. " in a call of its own, after looking at the screen") end
        local choice=I.picked(screen,key)
        if not I.one_time(choice) then
          C.die("keys: refusing " .. key .. " at the dialog in " .. C.block .. ": it would pick '" ..
            (choice or "no option it can read") .. "', not a one-time Yes, No or Continue; leave it to the user")
        end
      end
    end
  end

  function commands.keys(args)
    target("keys",args)
    alive("keys")
    local rec=C.root(C.block)
    if not rec then C.die("keys: cannot read the state of " .. C.block .. "; no key was pressed",1) end
    for _,key in ipairs(args) do
      if not interrupts[key] then guard_keys(args,rec); break end
    end
    if not C.mark_since(rec) then C.die("keys: cannot save the state of " .. C.block .. "; no key was pressed",1) end
    if not C.send_keys(args) then C.die("keys: rex could not press the keys in " .. C.block,1) end
  end

  local function close_pane()
    if C.target_missing then return true end
    for attempt=1,2 do
      local attached,err=C.attach()
      local closed
      if attached then closed,err=R.call("block.close",{session_id=C.session,block_id=C.block}) end
      if closed or tostring(err):find("not_found",1,true) then return true end
      if attempt==1 then R.sleep(0.3) end
    end
    return C.gone(C.block)
  end

  function commands.close(args)
    target("close",args,true)
    if not close_pane() then C.die("rex could not close " .. C.block .. "; its state is kept: run close again",1) end
    registry.remove(C.block)
    local leaf=C.line(C.block,"cage",1)
    if leaf~="" and not M.starts(leaf,".") and not leaf:find("/",1,true) then
      local base=C.fs.canonical(C.dir .. "/cage")
      if base then
        local path=base .. "/" .. leaf
        local result=R.exec({"/bin/bash",C.script_dir .. "/cage-cleanup.sh",C.dir,path})
        if result and result.stderr~="" then C.raw(result.stderr:gsub("\n$","")) end
        if not result or not result.ok then C.note("could not remove the cage home " .. path) end
      end
    end
    if not C.fs.remove_state(C.sf(C.block)) then C.die("could not remove the state of " .. C.block,1) end
  end

  commands.claims=registry.claims
  return commands
end
