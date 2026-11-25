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
  local function below(path,dir)
    return M.starts(path:gsub("/$","") .. "/",dir:gsub("/$","") .. "/")
  end
  function K.overlap(dir)
    local h=F.canonical(home) or home
    for _,path in ipairs({"/","/Users",h,h .. "/Library",h .. "/Repos"}) do
      if dir==path then return path end
    end
    for _,leaf in ipairs({".claude",".codex",".grok",".gemini"}) do
      local prefix=h .. "/" .. leaf
      if M.starts(dir,prefix) then return prefix .. "*" end
    end
    for _,path in ipairs({C.dir,secrets,h .. "/.ssh",h .. "/.local/bin",h .. "/.agents",h .. "/Library/LaunchAgents",
      M.dirname(M.dirname(M.dirname(C.script_dir))),"/opt/homebrew","/Applications",
      h .. "/.claude",h .. "/.codex",h .. "/.grok",h .. "/.gemini"}) do
      local physical=F.canonical(path) or path
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

  local function agy_settings(login)
    local source=F.read(login .. "/.gemini/antigravity-cli/settings.json")
    local config=source and R.json.decode(source)
    local model=type(config)=="table" and type(config.model)=="string" and ',\"model\":' .. M.json_string(config.model) or ""
    return '{"allowNonWorkspaceAccess":false,"permissions":{"allow":[]}' .. model .. "}"
  end

  local function render(name,r,dir,ct,physical_home,physical_secrets,hooks,command)
    local runtime=F.read(assets .. "/runtime-" .. r.runtime .. ".sh")
    if not runtime then return nil end
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
      {"RH_AGY",r.login},{"AGYSET",agy_settings(r.login)},{"LOCAL_LUA",C.script_dir .. "/local-lua.sh"}
    }
    local assignments={}
    for _,p in ipairs(bindings) do assignments[#assignments+1]=p[1] .. "=" .. quote(p[2]) end
    return header .. "# rex-orchestrator cage wrapper for " .. name .. " (generated each launch; do not edit).\nset -e\n" ..
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
    return {home=ct,wrapper=wrapper,account=r.account,why=r.why,meta=meta}
  end
  return K
end
