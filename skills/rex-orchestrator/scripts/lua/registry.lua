-- The Bash launcher and Lua commands share the registry directory and flock inode.
return function(C, M)
  local G={}
  local directory=C.dir .. "/registry"

  local function locked(work)
    if not C.fs.mkdir(directory) then return nil,"cannot create write claims directory" end
    local release=C.fs.lock(C.dir .. "/registry.lock",true)
    if not release then return nil,"cannot lock write claims" end
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
        local _,code=C.resolve(claim.block,"block",claim.session)
        if code==1 then return nil,"cannot check write claim for " .. claim.block .. " in " .. claim.session end
        gone=code==3
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

  function G.remove(block)
    local removed,why=locked(function()
      if C.fs.unlink(directory .. "/" .. block:gsub("[^A-Za-z0-9_-]","_") .. ".json") then return true end
      return nil,"cannot remove claim for " .. block
    end)
    if not removed then C.die(why,1) end
  end

  return G
end
