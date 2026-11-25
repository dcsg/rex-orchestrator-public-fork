return function(C,M,D,I,K,G)
  local R,F,env=C.rex,C.fs,M.env
  local L={}
  local directions={right={"horizontal","after"},left={"horizontal","before"},
    above={"vertical","before"},below={"vertical","after"}}
  local known={claude=true,codex=true,grok=true,agy=true,muse=true}
  local account_hint="an uncaged child runs on whatever account its --agent command uses"

  local function orchestrator_check()
    local config=env("REX_ORCHESTRATOR_CONFIG_DIR") or
      (env("XDG_CONFIG_HOME") or (env("HOME") or "/nonexistent") .. "/.config") .. "/rex-orchestrator"
    local allowed,ordered={},{}
    for _,line in ipairs(M.lines(F.read_file(config .. "/orchestrators"))) do
      local entry=line:gsub("#.*$",""):gsub("%s","")
      if entry=="agy" then entry="gemini" end
      entry=entry:gsub("^agy:","gemini:")
      if entry~="" then allowed[entry]=true; ordered[#ordered+1]=entry end
    end
    if #ordered==0 then return end
    local rec=C.root(C.me) or {}
    local kind=({["claude-code"]="claude",codex="codex",["grok-build"]="grok",antigravity="gemini",muse="muse"})[
      rec.effective_app or rec.app]
    kind=kind or (env("CLAUDECODE") and "claude")
    local shown=table.concat(ordered," ")
    if not kind then C.die("launch: can't tell which agent runs in your pane, and only " .. shown .. " may orchestrate (" .. config .. "/orchestrators)") end
    local path=kind=="claude" and env("CLAUDE_CONFIG_DIR") or kind=="codex" and env("CODEX_HOME")
    local account="default"
    if path and path~="/" then
      local leaf=path:gsub("/$",""):match("([^/]*)$"):gsub("^%.","")
      if leaf~=kind then account=leaf:gsub("^" .. kind .. "%-(.+)$","%1") end
    end
    local id=kind .. ":" .. account
    if not allowed[id] and not allowed[kind] then
      C.die("launch: " .. id .. " is not a designated orchestrator; only " .. shown .. " may launch children (" .. config .. "/orchestrators)")
    end
  end

  local function options(args)
    local opts={given=env("PWD") or F.logical("."),label="claude",ratio="50",agent="claude",timeout=90,
      cage=env("REX_ORCHESTRATOR_CAGE") or "auto",account="",focus=false,rules={},args={}}
    local values={["-d"]="given",["--dir"]="given",["-l"]="label",["--label"]="label",
      ["--split"]="split",["--ratio"]="ratio",["--tab"]="tab",["-b"]="anchor",["--anchor"]="anchor",
      ["--agent"]="agent",["--kind"]="kind",["--account"]="account"}
    local toggles={["--trust"]="trust",["--focus"]="focus",["--allow-edits"]="allow_edits"}
    local i=1
    while i<=#args do
      local flag=args[i]
      if flag=="--" then
        for j=i+1,#args do opts.args[#opts.args+1]=args[j] end
        break
      elseif toggles[flag] then
        opts[toggles[flag]]=true
        i=i+1
      elseif flag=="--cage" or flag=="--no-cage" then
        opts.cage=flag=="--cage" and "on" or "off"
        i=i+1
      elseif values[flag] or flag=="--timeout" or flag=="--allow" then
        local value=args[i+1]
        if not value or value=="" then
          if flag=="--account" then C.die("launch: --account needs a value of lowercase letters and digits; " .. account_hint) end
          C.die(flag .. " needs a value")
        end
        if flag=="--timeout" then opts.timeout=M.duration(flag,value,C.die)
        elseif flag=="--allow" then opts.rules[#opts.rules+1]=value
        else opts[values[flag]]=value end
        i=i+2
      else C.die("launch: unknown option " .. flag) end
    end
    if opts.cage~="auto" and opts.cage~="on" and opts.cage~="off" then
      C.die("launch: REX_ORCHESTRATOR_CAGE takes auto, on or off, not '" .. opts.cage .. "'")
    end
    if opts.split and not directions[opts.split] then
      C.die("launch: --split takes right, left, above or below, not '" .. opts.split .. "'")
    end
    if not opts.ratio:match("^%d+$") then C.die("launch: --ratio takes a whole percentage, not '" .. opts.ratio .. "'") end
    local size=tonumber(opts.ratio)
    if not opts.tab and (not size or size<1 or size>99) then C.die("launch: --ratio must be between 1 and 99") end
    if opts.kind=="gemini" then opts.kind="agy" end
    if opts.kind and not known[opts.kind] then
      C.die("launch: --kind takes claude, codex, grok, gemini (agy) or muse, not '" .. opts.kind .. "'")
    end
    opts.name=M.basename(opts.agent)
    opts.kind=opts.kind or (M.starts(opts.name,"claude-") and "claude") or (M.starts(opts.name,"agy-") and "agy") or opts.name
    if opts.account~="" then
      if not opts.account:match("^[a-z0-9]+$") then
        C.die("launch: --account takes lowercase letters and digits, not '" .. opts.account .. "'; " .. account_hint)
      end
      if opts.name~="claude" or opts.cage=="off" then C.die("launch: --account is for a caged claude only; " .. account_hint) end
    end
    local trust_error="launch: --trust refuses a directory name containing terminal controls, invalid UTF-8, bidirectional overrides or isolates, selection markers, or trust dialog text"
    if opts.trust and not D.safe_trust_dir(opts.given) then C.die(trust_error) end
    if opts.given=="-" then C.die("launch: no such directory: " .. opts.given) end
    opts.logical=F.logical(opts.given)
    opts.dir=F.canonical(opts.given)
    if not opts.dir or not opts.logical then C.die("launch: no such directory: " .. opts.given) end
    if opts.trust and (not D.safe_trust_dir(opts.dir) or not D.safe_trust_dir(opts.logical)) then C.die(trust_error) end
    return opts
  end

  local function scoped_permissions(opts)
    if not opts.allow_edits and #opts.rules==0 then return end
    if opts.kind~="claude" then C.die("launch: --allow-edits and --allow work with claude only") end
    for _,arg in ipairs(opts.args) do
      if arg=="--settings" or M.starts(arg,"--settings=") then
        C.die("launch: --allow-edits and --allow can't be combined with -- --settings (claude keeps only the last one); put the rules in that JSON's permissions.allow")
      end
    end
    if opts.allow_edits then
      if (opts.dir .. opts.logical):find("[%[%]*?{}!\\)]") then
        C.die("launch: --allow-edits can't scope " .. opts.dir .. " (its path holds one of [ ] * ? { } ! ) \\); use wait --approve-in DIR instead")
      end
      local function add(dir)
        opts.rules[#opts.rules+1]="Read(/" .. dir .. "/**)"
        opts.rules[#opts.rules+1]="Edit(/" .. dir .. "/**)"
      end
      add(opts.dir)
      if opts.logical~=opts.dir then add(opts.logical) end
    end
  end

  function L.parse(args)
    local opts=options(args)
    scoped_permissions(opts)
    return opts
  end

  local function executable(opts)
    local bin=F.executable(opts.agent)
    -- A caged agent can come from its cage override alone; the cage build checks it. The caller must not run it
    -- uncaged: the override is for caged launches only.
    local caged_only=false
    if not bin and opts.cage~="off" and not opts.agent:find("/",1,true) then
      bin=K.override(opts.name)
      caged_only=bin~=nil
    end
    if not bin then C.die("launch: no " .. opts.agent .. " on your PATH (give --agent a full path)") end
    if not M.starts(bin,"/") then bin=(env("PWD") or F.logical(".")) .. "/" .. bin end
    if opts.account~="" then
      local path=K.secrets .. "/claude-" .. opts.account .. ".env"
      if not F.test("-f",path) or not F.test("-r",path) then
        C.die("launch: --account " .. opts.account .. ": no readable " .. path .. "; " .. account_hint)
      end
    end
    return bin,caged_only
  end

  local function spawn_args(opts,bin,cage)
    local args={}
    if cage then args[1]=cage.wrapper
    else
      if C.killed(opts.kind) then
        C.die("launch: stopped: the kill switch " .. C.dir .. "/disabled." .. opts.kind ..
          " is set, so no uncaged " .. opts.kind .. " starts; report it, never remove it yourself")
      end
      if opts.kind=="claude" then
        local prev
        for _,arg in ipairs(opts.args) do
          if arg=="--dangerously-skip-permissions" or arg=="--allow-dangerously-skip-permissions" or
            arg=="--permission-mode=bypassPermissions" or (prev=="--permission-mode" and arg=="bypassPermissions") then
            C.die("launch: refusing an uncaged claude in bypass permissions mode (" .. arg ..
              "); use the cage, or --permission-mode default or auto")
          end
          prev=arg
        end
      end
      for _,key in ipairs({"CLAUDE_CONFIG_DIR","CODEX_HOME"}) do
        if env(key) then args[#args+1]=key .. "=" .. env(key) end
      end
      if opts.kind=="claude" then args[#args+1]="CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1" end
      if #args>0 then
        if bin:find("=",1,true) then
          C.die("launch: env can't run " .. bin .. ", whose path holds '='; run the agent from a path without one")
        end
        table.insert(args,1,"/usr/bin/env")
      end
      args[#args+1]=bin
    end
    for _,arg in ipairs(opts.args) do args[#args+1]=arg end
    return args
  end

  local function roomiest()
    local listed=R.session.list_blocks{session_id=C.session}
    local blocks=listed and listed.blocks or {}
    local win
    for _,pane in ipairs(blocks) do
      if pane.block_id==C.me then win=pane.window_id; break end
    end
    if not win then return nil end
    local best,anchor,direction=0
    for _,pane in ipairs(blocks) do
      if pane.window_id==win then
        local size=C.call(pane.block_id,"size")
        if size and size.columns and size.rows and size.columns*size.rows>best then
          best,anchor=size.columns*size.rows,pane.block_id
          direction=size.columns>=2*size.rows and "right" or "below"
        end
      end
    end
    return anchor,direction
  end

  local function place(opts,command,tag)
    local layout=R.layout.block{flavor="com.superlogical.terminal.shell",label=tag,
      options={command=command,cwd=opts.dir,shell="none",login=false,exit={on_completion=false}}}
    local spec={session_id=C.session,layout=layout,focus=opts.focus}
    if opts.tab then
      spec.window_label=tag
      return R.session.new_window(spec)
    end
    local anchor,direction=opts.anchor,opts.split
    if not anchor and not direction then anchor,direction=roomiest() end
    local id= C.resolve(anchor or C.me)
    if not id then return nil,"no such anchor in this session: " .. (anchor or C.me) end
    local size=tonumber(opts.ratio)
    local split=directions[direction or "right"]
    spec.anchor_id,spec.direction,spec.side=id,split[1],split[2]
    spec.ratio=(split[2]=="before" and size or 100-size)/100
    return R.session.new_split(spec)
  end

  local function tail(screen)
    local lines=M.lines(screen)
    return table.concat(lines,"\n",math.max(1,#lines-19))
  end

  local function startup(opts,cage,save_owner)
    local start=os.time()
    local answered,dialog_at,down_at,before=false,nil,nil,nil
    local ready,dialogs,poll=0,0,0
    local columns
    local function named(region)
      local size=not columns and C.call(C.block,"size")
      if size and size.columns and size.columns>0 then columns=size.columns end
      return D.dir_named(region,columns or 0,opts.dir,opts.logical)
    end
    local function snapshot()
      if not cage and not before then before=D.trusted_above(opts,true) end
    end
    local function press(key)
      snapshot()
      if key=="y" then
        return R.block.call("com.superlogical.terminal","write",{block_id=C.block,session_id=C.session,data="y"})
      end
      if key=="enter" then
        local sent,err,pressed=C.enter()
        if not sent and pressed then C.note("trust Enter was sent but the key release failed: " .. tostring(err)) end
        -- A delivered press may already have answered the dialog.
        return sent or pressed
      end
      return C.send_keys({key})
    end
    local untrusted="relaunch with --trust, or leave it to the user: report it; don't answer it by hand (the answer is remembered)"
    if cage and opts.name=="codex" then untrusted="relaunch with --trust (a caged codex can't save an answer)" end
    local no_dir=C.block .. ": left to the user: the trust dialog doesn't name " .. opts.dir .. "; report it, don't answer it"
    while true do
      local screen=C.screen(C.block)
      local region=table.concat(M.region(screen),"\n")
      local flat=D.flat(region)
      local rec=C.root(C.block)
      local trust=D.trust_shown(opts.kind,flat,rec)
      local previous_ready,previous_dialogs=ready,dialogs
      ready,dialogs=0,0
      if screen and opts.kind~="claude" and D.hooks(screen) then
        C.note(C.block .. " is waiting at a hooks review; left to the user: report it, don't answer it (trusting hooks is remembered)")
        return 3
      elseif screen and not answered and trust then
        if not opts.trust then
          C.note(C.block .. " is waiting at a " .. (opts.kind=="claude" and "workspace trust dialog; " or "trust dialog; ") .. untrusted)
          return 3
        end
        local confirmed=named(region)
        if confirmed and D.trust_selected(opts.kind,flat,region) then
          answered=not not press(opts.kind=="grok" and "y" or "enter")
        elseif confirmed and opts.kind=="claude" and (not down_at or poll-down_at>=8) then
          if press("down") then down_at=poll end
        end
        if opts.kind~="claude" or not confirmed then dialog_at=dialog_at or os.time() end
        if not answered and dialog_at and os.time()-dialog_at>=5 then
          if not confirmed then C.note(no_dir); return 3 end
          if opts.kind~="claude" then
            local size=C.call(C.block,"size")
            if size and size.columns and size.rows and (size.columns<80 or size.rows<24) then
              C.die("launch: " .. opts.kind .. "'s trust dialog shows no option to confirm in the " ..
                size.columns .. "x" .. size.rows .. " pane, which cuts it. Relaunch in a bigger pane (another -b or --split), or close idle panes; --tab (80x24) hides it from your view")
            end
            C.note(C.block .. " shows a trust dialog with no known answer for " .. opts.kind .. "; left to the user: report it, don't answer it")
            return 3
          end
        end
      elseif screen and D.ready(opts.kind,screen,region,rec) then
        ready=previous_ready+1
        if ready>=2 and C.exited(C.block)==false then
          if before then
            local post=D.trusted_above(opts,false)
            local parents={}
            for path in pairs(post) do parents[#parents+1]=path end
            table.sort(parents)
            for _,path in ipairs(parents) do
              if not before[path] then
                C.kill("launch --trust for " .. opts.dir .. " made " .. opts.kind .. " trust " .. path .. ", an ancestor of it",opts.kind)
                return 3
              end
            end
          end
          local pill=not cage and opts.kind=="claude" and M.mode(screen) or ""
          if pill:find("bypass",1,true) then
            C.die("launch: refusing an uncaged claude that started in bypass permissions mode (" ..
              pill .. ": a settings default?); use the cage, or -- --permission-mode default or auto")
          end
          local owner=""
          if opts.kind=="claude" or opts.kind=="codex" or opts.kind=="grok" or opts.kind=="agy" then
            owner=(rec.owner or {}).pid or ""
          end
          save_owner(owner,pill)
          if not C.mark(rec) then C.note("could not read the state of " .. C.block .. " yet") end
          return 0
        end
      elseif screen and not trust and I.dialog(screen) then
        dialogs=previous_dialogs+1
        if dialogs>=4 then
          C.note(C.block .. " shows a dialog at startup; left to the user: report it, and never answer it with a persistent option. Screen:")
          C.lines(tail(region))
          return 3
        end
      end
      if C.exited(C.block) then
        C.note(opts.name .. " exited during startup; screen:")
        C.lines(tail(C.screen(C.block)))
        return 12
      end
      if os.time()-start>opts.timeout then
        C.note("not ready after " .. opts.timeout .. "s; screen:")
        C.lines(tail(screen))
        return 124
      end
      poll=poll+1
      R.sleep(0.5)
    end
  end

  function L.launch(args)
    C.need_me()
    orchestrator_check()
    if C.killed() then
      C.die("launch: stopped: the kill switch " .. C.dir .. "/disabled is set; report it, never remove it yourself")
    end
    local opts=L.parse(args)
    if #opts.rules>0 then
      table.insert(opts.args,1,R.json.encode({permissions={allow=opts.rules}}))
      table.insert(opts.args,1,"--settings")
    end
    local bin,caged_only=executable(opts)
    local journal={session=C.session,owner=C.me}
    local function persist()
      if not C.journal or not C.put(C.journal,R.json.encode(journal)) then C.die("launch: cannot save recovery state",1) end
    end
    local cage
    if opts.cage~="off" then
      local code
      cage,code=K.build(opts.name,bin,opts,function(path) journal.cage=path; persist() end)
      if cage then
        bin=cage.bin or bin
        local overlap=K.overlap(opts.dir)
        if overlap then
          C.die("launch: refusing a caged " .. opts.name .. " in " .. opts.dir .. ": it is, holds or sits in " ..
            overlap .. ", which runs or is read outside the cage; give the task its own folder, or pass --no-cage")
        end
        if cage.account then C.note("caged " .. opts.name .. " on account " .. cage.account .. ": " .. cage.why)
        else C.note("caged " .. opts.name .. " (" .. M.basename(K.profile) .. ")") end
      elseif code==2 then
        local hint=opts.account~="" and
          "; fix the cage, or run the child uncaged through a wrapper for that account (--agent CMD) instead of --account" or
          "; pass --no-cage to run it uncaged"
        C.die("cage: setup for " .. opts.name .. " failed (see above)" .. hint)
      elseif opts.cage=="on" then
        C.die("cage: no cage recipe for " .. opts.name .. " (claude needs a " .. K.secrets ..
          "/claude-<name>.env, agy a cage home: see docs/cage.md); pass --no-cage to run it uncaged")
      elseif caged_only then
        C.die("launch: no " .. opts.agent .. " on your PATH to run uncaged (no cage recipe for it here), and " ..
          "REX_ORCHESTRATOR_CAGE_" .. opts.name:upper() .. "_BIN applies to caged launches only; give --agent a full path")
      else C.note("running " .. opts.name .. " uncaged: no cage recipe for it (pass --no-cage to silence)") end
    end
    local command=spawn_args(opts,bin,cage)
    local identity=G.identity(opts.dir,opts.given)
    if not identity then C.die("launch: cannot determine the write claim for " .. opts.dir,1) end
    local release,why=G.acquire()
    if not release then C.die(why,1) end
    local clear,conflict,code=G.check(identity)
    if not clear then release(); C.die(conflict,code) end
    local attached,attach_error=C.attach()
    if not attached then release(); C.die("launch: rex could not attach to " .. C.session .. ": " .. tostring(attach_error),1) end
    journal.tag=opts.label .. ".launch-" .. M.basename(M.dirname(C.journal))
    persist()
    local result,err=place(opts,command,journal.tag)
    if not result then
      release()
      if err then C.raw("Error: " .. err) end
      C.die("launch: rex could not open the " .. (opts.tab and "tab" or "pane") .. " (its error is above)",1)
    end
    C.block=(result.block_ids or {})[1]
    if type(C.block)~="string" then release(); C.die("launch: rex returned no block: " .. R.json.encode(result),1) end
    journal.block=C.block
    persist()
    if not R.session.set_block_label{session_id=C.session,block_id=C.block,label=opts.label} then
      C.note("could not label " .. C.block .. " " .. opts.label)
    end
    if opts.tab and not R.session.set_window_label{session_id=C.session,window_id=result.window_id,label=opts.tab} then
      C.note("could not name the tab " .. opts.tab)
    end
    local proc=C.call(C.block,"process") or {}
    local pid=(proc.child or {}).pid
    if not proc.last_exit then
      local saved,msg=G.add(identity,opts.kind,opts.label,pid)
      if not saved then release(); C.die(msg,1) end
    end
    release()
    local sf=C.sf(C.block)
    local function save_owner(owner,pill)
      if not C.put(sf .. ".own",C.me,pid or "",owner,opts.kind,opts.dir,pill,bin) then
        C.note("could not save the state of " .. C.block)
      end
    end
    save_owner("","")
    if cage then
      cage.meta.block=C.block
      if not C.put(cage.home .. "/run-meta.json",R.json.encode(cage.meta)) then C.note("could not save harvest block") end
      if not C.put(sf .. ".cage",M.basename(cage.home),cage.account or "") then C.note("could not save the cage marker of " .. C.block) end
    end
    C.note("launched " .. C.block .. " in " .. opts.dir)
    local result_code=startup(opts,cage,save_owner)
    C.out(C.block)
    C.finish(result_code)
  end

  function L.recover()
    local text=F.read(C.journal)
    local entry=text and R.json.decode(text)
    if type(entry)~="table" then C.die("launch: cannot read recovery state",1) end
    C.session=entry.session
    local block=entry.block
    if not block and entry.tag then
      for attempt=1,3 do
        local listed,err=R.session.list_blocks{session_id=C.session}
        if not listed then
          if tostring(err):find("session_not_found",1,true) then break end
          C.die("launch: could not look for the unreported pane",1)
        end
        -- Match only the temporary label written by this invocation.
        for _,pane in ipairs(listed.blocks or {}) do
          if pane.label==entry.tag then
            if block then C.die("launch: more than one pane has the recovery label",1) end
            block=pane.block_id
          end
        end
        if block then break end
        if attempt<3 then R.sleep(0.3) end
      end
    end
    if block then
      local sf=C.sf(block)
      if not C.close_pane(block) then
        C.note("launch stopped before the agent was ready and could not close " .. block .. "; run close " .. block)
        local own=F.read(sf .. ".own") or C.put(sf .. ".own",entry.owner,"","")
        local cage=not entry.cage or F.read(sf .. ".cage") or C.put(sf .. ".cage",M.basename(entry.cage))
        if not own or not cage then C.die("launch: cannot save recovery state for " .. block,1) end
        return
      end
      G.remove(block)
      if not F.remove_state(sf) then C.die("could not remove the state of " .. block,1) end
      C.note("launch stopped before the agent was ready; closed " .. block)
    end
    if entry.cage and not C.remove_cage(entry.cage) then C.die("could not remove " .. entry.cage,1) end
  end

  return L
end
