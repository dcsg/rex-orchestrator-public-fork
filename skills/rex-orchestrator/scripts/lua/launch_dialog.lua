return function(C,M,I)
  local D={}
  local env=M.env
  local home=env("HOME") or "/nonexistent"

  function D.safe_trust_dir(path)
    if M.dir_control(path) then return false end
    local lower=path:lower()
    for _,text in ipairs({"❯","›","⟩",">","trust and continue","yes, i trust this folder",
      "do you trust","yes, proceed","no, quit"}) do
      if lower:find(text,1,true) then return false end
    end
    return true
  end

  function D.flat(text)
    return (text:gsub("[ \n]+"," "))
  end

  function D.dir_named(region,width,physical,logical)
    local physical_home=C.fs.canonical(home) or home
    local forms={}
    for _,dir in ipairs({physical,logical}) do
      forms[#forms+1]=dir
      for _,h in ipairs({home,physical_home}) do
        if M.below(dir,h) then forms[#forms+1]="~" .. dir:sub(#h+1) end
      end
    end
    local function matches(row)
      local unlabelled=row:gsub("^[A-Za-z][A-Za-z ]*:%s+","")
      local prefix,suffix=row:match("^(.-)…(.*)$")
      for _,form in ipairs(forms) do
        if row==form or unlabelled==form then return true end
        if prefix and prefix~="" and suffix:find("/",1,true) and not suffix:find("…",1,true) and
          #prefix+#suffix<#form and M.starts(form,prefix) and form:sub(-#suffix)==suffix then return true end
      end
      return false
    end
    local raw=M.lines(region)
    local rows={}
    for i,line in ipairs(raw) do rows[i]=M.trim(line) end
    for i,row in ipairs(rows) do
      if row~="" then
        if matches(row) then return true end
        if width>0 and #raw[i]:gsub("[\128-\191]","")>=width and (M.starts(row,"/") or M.starts(row,"~/")) then
          for _,form in ipairs(forms) do if M.starts(form,row) then return true end end
        end
        local joined=row
        for j=i+1,#rows do
          if rows[j]=="" then break end
          joined=joined .. rows[j]
          if matches(joined) then return true end
        end
      end
    end
    return false
  end

  function D.hooks(screen)
    local flat=D.flat(screen):lower()
    return flat:find("hooks? needs? review") or flat:find("review hooks",1,true) or
      flat:find("trust all and continue",1,true) or flat:find("continue without trusting",1,true)
  end

  function D.trust_shown(kind,flat,rec)
    if kind=="claude" then
      return flat:find("Yes, I trust this folder",1,true) or flat:find("Accessing workspace.*No, exit")
    end
    local lower=flat:lower()
    return lower:find("do you trust",1,true) or lower:find("trust this folder?",1,true) or
      lower:find("trust this workspace?",1,true) or lower:find("1%.? trust and continue") or
      (rec and rec.state=="blocked" and (rec.msg or ""):lower():find("trust",1,true))
  end

  function D.trust_selected(kind,flat,region)
    if kind=="grok" then
      local yes,no=false,false
      for _,row in ipairs(M.lines(region)) do
        yes=yes or row:match("^%s*Yes, proceed%s+y%s*$")~=nil
        no=no or row:match("^%s*No, quit%s+n%s*$")~=nil
      end
      return yes and no
    end
    if kind=="claude" then return flat:find("❯ ?Yes, I trust this folder") end
    for _,marker in ipairs({">","⟩","›"}) do
      if flat:find(marker .. " ?Yes, I trust this folder") or flat:find(marker .. " ?1%.? Trust and continue") or
        flat:find(marker .. " ?1%. Yes, continue") then return true end
    end
    return false
  end

  function D.ready(kind,screen,region,rec)
    if not rec or I.dialog(screen) then return false end
    local state=rec.state or ""
    if state=="blocked" or (kind=="codex" and state=="") then return false end
    if state=="working" and (kind~="codex" or screen:lower():find("esc to interrupt",1,true)) then return false end
    if kind~="codex" and (state=="done" or state=="idle") then return true end
    for _,text in ipairs({"for shortcuts","mode on","accept edits on","bypass permissions on","⏵⏵","⏸"}) do
      if region:find(text,1,true) then return true end
    end
    for _,line in ipairs(M.lines(region)) do
      if (line .. " "):match("^ *%? for ") then return true end
    end
    return false
  end

  local function decode(path)
    local data=C.fs.read(path)
    local decoded=data and C.rex.json.decode(data)
    return type(decoded)=="table" and decoded or {}
  end

  local function read_toml(path,section,want,result)
    local current
    for _,line in ipairs(M.lines(C.fs.read(path))) do
      if M.starts(line,"[") then
        current=line:match("^%[" .. section .. '%.\"(.*)\"%]%s*$')
        if current and current:find('\\\"',1,true) then current=nil end
      elseif current and line:gsub("%s","")==want then
        result[current]=true
      end
    end
  end

  local function trusted_in(kind,before)
    local result={}
    if kind=="claude" or kind=="muse" then
      local config=env("CLAUDE_CONFIG_DIR")
      local paths=kind=="claude" and {(config or home) .. "/.claude.json"} or {home .. "/.config/muse/trust.json"}
      if kind=="claude" and before and config then paths[#paths+1]=home .. "/.claude.json" end
      for _,path in ipairs(paths) do
        local projects=decode(path).projects
        if type(projects)=="table" then
          for dir,project in pairs(projects) do
            if type(project)=="table" and
              ((kind=="claude" and project.hasTrustDialogAccepted==true) or (kind=="muse" and project.decision=="trusted")) then
              result[dir]=true
            end
          end
        end
      end
    elseif kind=="codex" then
      read_toml((env("CODEX_HOME") or home .. "/.codex") .. "/config.toml","projects",'trust_level="trusted"',result)
    elseif kind=="grok" then
      read_toml(home .. "/.grok/trusted_folders.toml","folders","trusted=true",result)
    elseif kind=="agy" then
      local workspaces=decode(home .. "/.gemini/antigravity-cli/settings.json").trustedWorkspaces
      if type(workspaces)=="table" then
        for _,dir in ipairs(workspaces) do if type(dir)=="string" then result[dir]=true end end
      end
    end
    return result
  end

  function D.trusted_above(opts,before)
    local top
    if opts.kind=="codex" then
      local r=M.git(C.rex.exec,C.git,{"-C",opts.dir,"rev-parse","--show-toplevel"})
      if r and r.ok then top=r.stdout:gsub("\n+$","") end
    end
    local trusted=trusted_in(opts.kind,before)
    local result={}
    for _,dir in ipairs({opts.dir,opts.logical}) do
      while dir~="" and dir~="/" do
        dir=M.dirname(dir)
        if dir~=top and trusted[dir] then result[dir]=true end
      end
    end
    return result
  end

  return D
end
