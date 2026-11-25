return function(C,M)
  local R,F,env=C.rex,C.fs,M.env
  local K={}
  local home=env("HOME") or "/nonexistent"
  local assets=C.script_dir .. "/cage"
  local profile=env("REX_ORCHESTRATOR_CAGE_PROFILE") or C.script_dir .. "/cage.sb"
  local templates=env("REX_ORCHESTRATOR_CAGE_TPL") or assets
  local secrets=env("REX_ORCHESTRATOR_CAGE_SECRETS") or
    (env("XDG_CONFIG_HOME") or (env("HOME") or "") .. "/.config") .. "/rex-orchestrator/cage-secrets"
  local agy_home=env("REX_ORCHESTRATOR_CAGE_AGY_HOME") or secrets .. "/agy-home"
  K.secrets=secrets
  K.profile=profile

  local function ere(s) return (s:gsub("[%[%](){}.^$*+?|\\]",function(c) return "\\" .. c end)) end
  local function quote(s) return "'" .. s:gsub("'","'\\''") .. "'" end
  -- Path checks against the protected locations ignore ASCII case: the home volume is case-insensitive by default,
  -- and the cage's own path matching (literal, prefix, subpath and regex) ignores case there too, so ~/.CODEX/x is
  -- ~/.codex/x to the profile. A check that compared case would let a case-variant spelling past it.
  -- First line: every path compared is put in its on-disk spelling (disk), which also settles non-ASCII case and
  -- Unicode normalization; second line: the comparison itself ignores ASCII case, for a path that doesn't exist.
  local function starts_nocase(s,p) return M.starts(s:lower(),p:lower()) end
  local function disk(path) return F.ondisk(path) or F.canonical(path) or path end
  -- A path that may not exist (a link's own location): its folder on disk, its last name as given.
  local function disk_parent(path) return disk(M.dirname(path)):gsub("/$","") .. "/" .. M.basename(path) end
  local function below(path,dir)
    return starts_nocase(path:gsub("/$","") .. "/",dir:gsub("/$","") .. "/")
  end
  local agent_homes={".claude",".codex",".grok",".gemini"}
  -- The agent home prefix (HOME/.codex, ...) PATH sits under, by the profile's prefix rule (~/.codex-work counts), or nil.
  local function agent_home(path,h)
    for _,leaf in ipairs(agent_homes) do
      if starts_nocase(path,h .. "/" .. leaf) then return h .. "/" .. leaf end
    end
  end
  function K.overlap(dir)
    local h=disk(home)
    dir=disk(dir)
    for _,path in ipairs({"/","/Users",h,h .. "/Library",h .. "/Repos"}) do
      if dir:lower()==path:lower() then return path end
    end
    local prefix=agent_home(dir,h)
    if prefix then return prefix .. "*" end
    for _,path in ipairs({C.dir,secrets,h .. "/.ssh",h .. "/.local/bin",h .. "/.agents",h .. "/Library/LaunchAgents",
      M.dirname(M.dirname(M.dirname(C.script_dir))),"/opt/homebrew","/Applications",
      h .. "/.claude",h .. "/.codex",h .. "/.grok",h .. "/.gemini"}) do
      local physical=disk(path)
      if below(dir,physical) or below(dir,path) or below(physical,dir) then return path end
    end
  end

  local function lock_regex()
    local forms={}
    for _,path in ipairs({secrets,M.dirname(C.script_dir)}) do
      forms[#forms+1]=ere(path)
      local physical=F.canonical(path) or F.real(path)
      if physical and physical~=path then forms[#forms+1]=ere(physical) end
    end
    return "^(" .. table.concat(forms,"|") .. ")(/|$)"
  end

  local function git_value(dir,...)
    local r=R.exec({C.git,"-C",dir,...})
    return r and r.ok and r.stdout:gsub("\n+$","") or nil
  end

  local function hooks_path(dir)
    local top=git_value(dir,"rev-parse","--show-toplevel")
    local hooks=top and git_value(dir,"config","--path","--get","core.hooksPath")
    if not hooks or hooks=="" then return nil end
    if not M.starts(hooks,"/") then hooks=top .. "/" .. hooks end
    hooks=hooks:gsub("/+","/")
    if #hooks>1 then hooks=hooks:gsub("/$","") end
    local physical=F.canonical(hooks)
    if not physical then
      local parent=F.real(M.dirname(hooks))
      if parent then physical=parent:gsub("/$","") .. "/" .. M.basename(hooks) end
    end
    if physical and below(physical,dir) then
      C.note("cage: repo core.hooksPath points inside DIR (" .. physical .. "); write-locking it")
      return physical
    end
  end

  local function account(requested)
    if requested~="" then return requested,"chosen with --account" end
    local accounts=F.accounts(secrets)
    if #accounts==1 then return accounts[1],"its only cage credential" end
    if #accounts>1 then
      return accounts[1],"the alphabetically first of " .. #accounts .. " cage credentials (--account picks another)"
    end
  end

  local function recipe(name,bin,requested)
    local r={runtime=name,bin=bin,login=agy_home,config=".nolock",templates={}}
    if name=="codex" then
      r.auth=(env("CODEX_HOME") or (env("HOME") or "") .. "/.codex") .. "/auth.json"
      r.config="codex-home/config.toml"
      r.templates={"codex.toml"}
    elseif name=="grok" then
      r.auth=(env("HOME") or "") .. "/.grok/auth.json"
      r.templates={"grok.toml"}
    elseif name=="claude" then
      r.account,r.why=account(requested)
      if not r.account then return nil end
      r.config="claude-config/settings.json"
      r.templates={"claude.json","claude-settings.json"}
    elseif name=="agy" then
      if not F.test("-d",r.login) then return nil end
    elseif name:match("^agy%-[a-z0-9]+$") then
      r.runtime="agy"
      r.login=secrets .. "/" .. name
      r.bin=F.executable("agy")
      if not r.bin or not F.test("-d",r.login) then return nil end
    else
      return nil
    end
    return r
  end

  -- The cage runs codex, claude and grok as their own executables: a compiled one, or a Node script (an npm install
  -- of codex runs bin/codex.js through `#!/usr/bin/env node`). Any other file on PATH under the agent's name is a
  -- script (a shell, fish, Python, Perl or Ruby one, or text with no #! line that execvp hands to sh): a wrapper or
  -- shim, one that injects tokens and execs the real agent, say. The cage skips it, because its env -i and fixed PATH
  -- would break it, and what it adds is what the cage strips. An unreadable file can't be told apart, so it is
  -- skipped too.
  local direct={codex=true,claude=true,grok=true}
  local runnable={node=true,nodejs=true}
  local function head_of(path)
    local f=io.open(path,"rb")
    if not f then return nil end
    local head=f:read(512) or ""
    f:close()
    return head
  end
  -- The cage's fixed PATH (the runtime wrappers' env -i), where env finds a utility named without a slash.
  local cage_path="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  -- A program the cage will exec: an absolute path, or a name looked up in SEARCH (a colon list).
  local function program_path(word,search)
    if word:find("/",1,true) then return M.starts(word,"/") and word or nil end
    if search==nil then return nil end
    for dir in ((search or cage_path) .. ":"):gmatch("([^:]*):") do
      local path=(dir=="" and "." or dir) .. "/" .. word
      if M.starts(path,"/") and F.test("-f",path) and F.test("-x",path) then return path end
    end
  end
  local function agent_file(path)
    local head=head_of(path)
    if not head then return false end
    local interpreter,chain=M.script_interpreter(head)
    if interpreter==nil then return true end
    if not runnable[interpreter] then return false end
    -- A Node script runs only if each program on its #! line is compiled: the kernel won't start a script as an
    -- interpreter, and sandbox-exec then hands the file itself to /bin/sh. So the #! path and every utility env runs
    -- (found through -P or the cage's PATH) must be Mach-O.
    for _,step in ipairs(chain) do
      local program=program_path(step.program,step.search)
      local program_head=program and head_of(program)
      if not program_head or not M.compiled(program_head) then return false end
    end
    return true
  end
  function K.override(name)
    return direct[name] and env("REX_ORCHESTRATOR_CAGE_" .. name:upper() .. "_BIN") or nil
  end

  -- The executable a caged agent runs: --agent's path as given; for a bare name, REX_ORCHESTRATOR_CAGE_<AGENT>_BIN,
  -- else the first one on PATH that is compiled or a Node script.
  local function caged_binary(r,name,opts)
    if not direct[r.runtime] or (opts.agent or r.bin):find("/",1,true) then return r.bin end
    local variable="REX_ORCHESTRATOR_CAGE_" .. name:upper() .. "_BIN"
    local override=K.override(name)
    if override then
      if not M.starts(override,"/") then return nil,"cage: " .. variable .. " must be an absolute path" end
      if not F.test("-f",override) or not F.test("-x",override) then
        return nil,"cage: " .. variable .. " (" .. override .. ") is not an executable file"
      end
      return override
    end
    local skipped={}
    for _,path in ipairs(F.executables(opts.agent)) do
      if not M.starts(path,"/") then path=(env("PWD") or F.logical(".")) .. "/" .. path end
      if agent_file(path) then
        if #skipped>0 then
          C.note("cage: skipped " .. table.concat(skipped,", ") .. ": a script, not " .. name ..
            " itself (a wrapper or shim the cage would break); running " .. path .. " (" .. variable ..
            " picks another)")
        end
        return path
      end
      skipped[#skipped+1]=path
    end
    return nil,"cage: every " .. name .. " on PATH is a script that isn't Node (" .. table.concat(skipped,", ") ..
      "), a wrapper or shim the cage would break; set " .. variable .. " to the real " .. name .. " executable" ..
      " (or to that script, if it is " .. name .. "'s own launcher and runs without your environment)"
  end

  -- The cage denies reads and execution under every agent home by prefix, so an executable there can't start. The
  -- exceptions are a standalone codex release, CODEX_HOME/packages/standalone/releases/<version>/ (that folder,
  -- AGENT_BIN_DIR), and a grok download, GROK_HOME/downloads/<file> (that one file, AGENT_BIN_FILE): nothing else
  -- under the home is re-opened, for reading and execution, for this launch only. The agent runs by its physical
  -- path, since links inside the home (codex's current, grok's bin/grok) can't be followed in the cage.
  -- Returns the executable to run, the folder and the file to re-open (either may be nil), or nil and why.
  local function agent_bin_dir(r,name)
    local real=F.realpath(r.bin)
    if not real then return nil,"cage: cannot resolve " .. name .. "'s executable " .. r.bin end
    local h=disk(home)
    local prefix=agent_home(real,h)
    if prefix then
      if r.runtime=="codex" and not M.dir_control(real) then
        for _,codex_home in ipairs({env("CODEX_HOME") or "",h .. "/.codex"}) do
          local physical=codex_home~="" and disk(codex_home)
          local base=physical and physical .. "/packages/standalone/releases/"
          local version=base and starts_nocase(real,base) and real:sub(#base+1):match("^([^/]+)/.")
          -- The release folder as the physical path spells it (the on-disk case), not as CODEX_HOME does.
          if version and version~="." and version~=".." then return real,real:sub(1,#base) .. version end
        end
      end
      -- grok's installer keeps each version as one file, GROK_HOME/downloads/grok-<version>-<platform>, linked
      -- from ~/.grok/bin/grok: that file alone is re-opened (AGENT_BIN_FILE).
      if r.runtime=="grok" and not M.dir_control(real) then
        for _,grok_home in ipairs({env("GROK_HOME") or "",h .. "/.grok"}) do
          local physical=grok_home~="" and disk(grok_home)
          local base=physical and physical .. "/downloads/"
          local file=base and starts_nocase(real,base) and real:sub(#base+1)
          if file and file~="" and not file:find("/",1,true) and F.test("-f",real) then return real,nil,real end
        end
      end
      return nil,"cage: " .. name .. "'s executable " .. real .. " is under " .. prefix ..
        ", which the cage can't read" .. (r.runtime=="codex" and
        " (of a codex home it opens only a standalone release, packages/standalone/releases/<version>/)" or
        r.runtime=="grok" and " (of a grok home it opens only a download, downloads/<file>)" or "") ..
        "; install " .. name .. " elsewhere" .. (direct[r.runtime] and
        " or point REX_ORCHESTRATOR_CAGE_" .. name:upper() .. "_BIN at a copy outside it" or "")
    end
    -- The executable itself is outside the agent homes, but the cage can't follow a link that sits inside one on the
    -- way there (~/.local/bin/codex -> ~/.codex/bin/codex -> /opt/x/codex): run it by its physical path instead.
    local links=F.link_locations(r.bin)
    if not links then return nil,"cage: cannot resolve " .. name .. "'s executable " .. r.bin end
    for _,link in ipairs(links) do
      if agent_home(disk_parent(link),h) then
        C.note("cage: " .. r.bin .. " reaches " .. real .. " through the link " .. link ..
          ", which the cage can't follow; running " .. real)
        return real
      end
    end
    return r.bin
  end

  local function agy_settings(login)
    local source=F.read(login .. "/.gemini/antigravity-cli/settings.json")
    local config=source and R.json.decode(source)
    local model=type(config)=="table" and type(config.model)=="string" and ',\"model\":' .. M.json_string(config.model) or ""
    return '{"allowNonWorkspaceAccess":false,"permissions":{"allow":[]}' .. model .. "}"
  end

  local function render(name,r,dir,ct,physical_home,physical_secrets,hooks,command)
    local runtime=F.read(assets .. "/runtime-" .. r.runtime .. ".sh")
    -- The wrapper prints paths (claude's credential file) with the CLI's own escaping.
    local term_text=F.read(C.script_dir .. "/term-text.sh")
    if not runtime or not term_text then return nil end
    local header="#!/bin/bash\n"
    if r.runtime=="agy" then
      header="#!/bin/bash -p\n# Ignore startup hooks and project PATH before uncaged work.\n" ..
        "unset BASH_ENV ENV CDPATH\nPATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin\n"
    end
    local bindings={
      {"REAL",r.bin},{"DIR",dir},{"DRE",ere(dir)},{"CT",ct},{"RH",physical_home},
      {"AUTH",r.auth or ct},{"CFGRO",ct .. "/" .. r.config},{"HOOKS",hooks or ct .. "/.nohooks"},
      {"LRE",lock_regex()},{"SEC",physical_secrets},{"PROF",profile},{"TPL",templates},
      {"CRED",r.account and secrets .. "/claude-" .. r.account .. ".env" or ""},
      {"BINDIR",r.bindir or ct},{"BINFILE",r.binfile or ct .. "/.nobin"},{"RH_AGY",r.login},{"AGYSET",agy_settings(r.login)},{"LOCAL_LUA",C.script_dir .. "/local-lua.sh"}
    }
    local assignments={}
    for _,p in ipairs(bindings) do assignments[#assignments+1]=p[1] .. "=" .. quote(p[2]) end
    return header .. "# rex-orchestrator cage wrapper for " .. name .. " (generated each launch; do not edit).\n" ..
      term_text .. "set -e\n" ..
      table.concat(assignments," ") .. '\nTTY=$(/usr/bin/tty 2>/dev/null) || TTY=\n' ..
      'case "$TTY" in /dev/ttys[0-9]*) ;; *) TTY="$CT/.notty" ;; esac\n' ..
      (r.runtime=="agy" and "AGY_CMD_FILE=" .. quote(command or "") .. "\n" .. r.path_guard .. "\n" or "") .. runtime
  end

  function K.build(name,bin,opts,reserved)
    local r=recipe(name,bin,opts.account)
    if not r then return nil,1 end
    local function fail(why) C.note(why); return nil,2 end
    local physical_home=F.canonical(home)
    if not physical_home then return fail("cage: cannot resolve HOME") end
    if r.auth then
      local dir=F.canonical(M.dirname(r.auth))
      if not dir then return fail("cage: no " .. name .. " login dir for " .. r.auth) end
      r.auth=dir .. "/" .. M.basename(r.auth)
      if not F.test("-r",r.auth) then return fail("cage: no " .. name .. " login at " .. r.auth) end
    end
    for _,file in ipairs(r.templates) do
      local path=templates .. "/" .. file
      if not F.test("-r",path) then return fail("cage: missing template " .. path) end
    end
    if not F.test("-r",profile) then return fail("cage: profile not found: " .. profile .. " (set REX_ORCHESTRATOR_CAGE_PROFILE)") end
    local why
    r.bin,why=caged_binary(r,name,opts)
    if not r.bin then return fail(why) end
    r.bin,r.bindir,r.binfile=agent_bin_dir(r,name)
    if not r.bin then return fail(r.bindir) end
    local dir=opts.dir
    if M.dir_control(dir) then
      return fail("cage: " .. name .. "'s DIR path contains terminal controls, invalid UTF-8, or bidirectional overrides or isolates")
    end
    if r.runtime=="agy" then
      if not M.starts(r.login,"/") then
        local cwd=F.canonical(".")
        if not cwd then return fail("cage: cannot resolve the agy provisioned home") end
        r.login=cwd .. "/" .. r.login
      end
      r.path_guard=F.read(assets .. "/agy-paths.sh")
      if not r.path_guard then return fail("cage: cannot load the agy directory checks") end
      local result=R.exec({"/bin/bash","-p","-c",r.path_guard .. [[
        unset CDPATH
        agy_home_overlap "$@"; exit "$?"
      ]],"rex-orchestrator",r.login,dir,F.logical(r.login) or "",opts.logical or ""})
      if result and result.ok then return fail("cage: the agy provisioned home overlaps DIR") end
      if not result or result.code~=1 then return fail("cage: cannot check the agy provisioned home against DIR") end
    end
    local physical_secrets=F.canonical(secrets) or F.real(secrets)
    if not physical_secrets then return fail("cage: cannot resolve " .. secrets) end
    local hooks=hooks_path(dir)
    local root=C.dir .. "/cage"
    local base=F.mkdir(root) and F.canonical(root)
    local ct=base and F.private_temp(base,name)
    if not ct then return fail("cage: cannot set up a cage under " .. root) end
    reserved(ct)
    if not F.mkdir(ct .. "/bin") then return fail("cage: cannot set up a cage under " .. root) end
    local command
    local token_command=os.getenv("REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD")
    if r.runtime=="agy" and token_command~=nil then
      command=base .. "-commands/" .. M.basename(ct)
      if not F.reserve_command(base .. "-commands",command,token_command) then
        return fail("cage: cannot store REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD privately")
      end
    end
    local wrapper=ct .. "/bin/" .. name
    local body=render(name,r,dir,ct,physical_home,physical_secrets,hooks,command)
    if not body or not F.put(wrapper,body) or not F.chmod("700",wrapper) then
      if command then F.unlink(command) end
      return fail("cage: cannot write " .. name .. "'s cage wrapper")
    end
    if name=="codex" and opts.trust then
      local template=F.read(templates .. "/codex.toml")
      if not template or not F.mkdir(ct .. "/codex-home") or not F.put(ct .. "/codex-home/config.toml",
        template .. "\n[projects." .. M.json_string(dir) .. ']\ntrust_level = "trusted"\n') then
        C.note("cage: could not pre-trust " .. dir .. "; codex will show its trust dialog")
      end
    end
    local meta={kind=name,account=r.account or "unknown",label=opts.label,DIR=dir,
      start_time=os.date("!%Y-%m-%dT%H:%M:%SZ"),block="unknown"}
    if not C.put(ct .. "/run-meta.json",R.json.encode(meta)) then C.note("could not write cage run metadata") end
    return {home=ct,wrapper=wrapper,account=r.account,why=r.why,meta=meta,bin=r.bin}
  end
  return K
end
