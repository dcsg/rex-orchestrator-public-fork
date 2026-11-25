-- Keep Bash's registry format and flock inode across launcher versions.
return function(C, M)
  local G={}
  local directory=C.dir .. "/registry"

  function G.acquire()
    if not C.fs.mkdir(directory) then return nil,"cannot create write claims directory" end
    local release=C.fs.lock(C.dir .. "/registry.lock",true)
    if not release then return nil,"cannot lock write claims" end
    return release
  end

  local function locked(work)
    local release,err=G.acquire()
    if not release then return nil,err end
    local ok,value,why=pcall(work)
    release()
    if not ok then error(value,0) end
    return value,why
  end

  local function compact_json(text)
    -- Preserve the field order of Bash launch records while removing whitespace outside strings.
    local parts={}
    local quoted,escaped=false,false
    for i=1,#text do
      local char=text:sub(i,i)
      if quoted or not char:match("%s") then parts[#parts+1]=char end
      if escaped then escaped=false
      elseif quoted and char=="\\" then escaped=true
      elseif char=='"' then quoted=not quoted end
    end
    return table.concat(parts)
  end

  local function live_claims()
    local paths=C.fs.claim_paths(directory)
    if not paths then return nil,"cannot list write claims" end
    local live={}
    for _,path in ipairs(paths) do
      local text=C.fs.read(path)
      local claim=text and C.rex.json.decode(text)
      local pid=type(claim)=="table" and tostring(claim.pid) or ""
      if not pid:match("^[1-9]%d*$") then return nil,"invalid claim: " .. path end
      local gone=not C.fs.pid_alive(pid)
      if not gone then
        if type(claim.block)~="string" or not M.starts(claim.block,"block:") or
          type(claim.session)~="string" or claim.session=="" then return nil,"invalid claim: " .. path end
        local _,code,err=C.resolve(claim.block,"block",claim.session)
        gone=code==3 or type(err)=="string" and err:find("session_not_found",1,true)~=nil
        if code==1 and not gone then return nil,"cannot check write claim for " .. claim.block .. " in " .. claim.session end
      end
      if gone then
        if not C.fs.unlink(path) then return nil,"cannot remove claim: " .. path end
      else
        live[#live+1]={claim=claim,json=compact_json(text)}
      end
    end
    return live
  end

  function G.claims(args)
    if #args>1 or (#args==1 and args[1]~="--json") then C.die("claims: expected [--json]") end
    local rows,why=locked(live_claims)
    if not rows then C.die(why,1) end
    for _,row in ipairs(rows) do
      if args[1]=="--json" then
        C.out(row.json)
      else
        local c=row.claim
        local values={c.block,c.label or "",c.session,c.kind or "",tostring(c.pid),c.canonical_dir or ""}
        for i,value in ipairs(values) do values[i]=M.tsv(value) end
        C.out(table.concat(values,"\t"))
      end
    end
  end

  -- NOWAIT: try the lock once; when another process holds it, return nil, "busy", true.
  function G.release(block,nowait)
    local release,err
    if nowait then
      if not C.fs.mkdir(directory) then return nil,"cannot create write claims directory" end
      release=C.fs.lock(C.dir .. "/registry.lock",false)
      if not release then return nil,"busy",true end
    else
      release,err=G.acquire()
    end
    if not release then return nil,err end
    local ok,removed=pcall(C.fs.unlink,directory .. "/" .. block:gsub("[^A-Za-z0-9_-]","_") .. ".json")
    release()
    if not ok then error(removed,0) end
    if removed then return true end
    return nil,"cannot remove claim for " .. block
  end

  function G.remove(block)
    local removed,why=G.release(block)
    if not removed then C.die(why,1) end
  end

  function G.identity(dir,given)
    local function git(...)
      local r=M.git(C.rex.exec,C.git,{"-C",dir,...})
      return r and r.ok and r.stdout:gsub("\n+$","") or nil
    end
    local top=git("rev-parse","--show-toplevel")
    if not top then
      return {dir=given,canonical_dir=dir,toplevel="",common_dir="",branch="",key={dir}}
    end
    top=C.fs.canonical(top)
    local common=git("rev-parse","--git-common-dir")
    if common and not M.starts(common,"/") then common=dir .. "/" .. common end
    common=common and C.fs.canonical(common)
    if not top or not common then return nil end
    local branch=git("symbolic-ref","--short","HEAD") or ""
    return {dir=given,canonical_dir=dir,toplevel=top,common_dir=common,branch=branch,key={top,common,branch}}
  end

  function G.check(identity)
    local rows,why=live_claims()
    if not rows then return nil,why,1 end
    local function contains(a,b)
      return a==b or M.starts(b,a:gsub("/$","") .. "/")
    end
    for _,row in ipairs(rows) do
      local old=row.claim
      if type(old.canonical_dir)~="string" or type(old.toplevel)~="string" or
        type(old.common_dir)~="string" or type(old.branch)~="string" then
        return nil,"invalid identity for claim " .. old.block,1
      end
      local same
      if old.toplevel~="" and identity.toplevel~="" then
        same=old.toplevel==identity.toplevel or
          (old.common_dir==identity.common_dir and old.branch~="" and old.branch==identity.branch)
      else
        same=contains(old.canonical_dir,identity.canonical_dir) or contains(identity.canonical_dir,old.canonical_dir)
      end
      if same then
        return nil,"launch: DIR already has a live write claim (label " .. (old.label or "") .. ", block " ..
          old.block .. ", session " .. old.session .. "); use rex-orchestrator clone for a separate checkout",2
      end
    end
    return true
  end

  function G.add(identity,kind,label,pid)
    if type(pid)~="number" or pid<=0 or pid%1~=0 then
      return nil,"launch: cannot record agent pid for " .. C.block
    end
    identity.block,identity.session,identity.kind=C.block,C.session,kind
    identity.pid,identity.label,identity.created=pid,label,os.date("!%Y-%m-%dT%H:%M:%SZ")
    local path=directory .. "/" .. C.block:gsub("[^A-Za-z0-9_-]","_") .. ".json"
    if not C.put(path,C.rex.json.encode(identity)) then return nil,"cannot write claim for " .. C.block end
    return true
  end

  return G
end
