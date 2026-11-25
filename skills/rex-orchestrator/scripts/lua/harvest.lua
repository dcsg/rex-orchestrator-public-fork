-- Archive only known transcript paths. Never open symlinks, hardlinks or special files.
return function(M,J,F,N)
  local patterns={
    claude={"^claude%-config/projects/.*%.jsonl$","^home/%.claude/projects/.*%.jsonl$"},
    codex={"^codex%-home/sessions/.*%.jsonl$"},
    grok={"^home/%.grok/sessions/.*/chat_history%.jsonl$","^home/%.grok/sessions/.*/updates%.jsonl$",
      "^home/%.grok/sessions/.*/prompt_history%.jsonl$","^home/%.grok/sessions/.*/terminal/.*%.log$",
      "^home/%.grok/logs/.*%.log$"},
    agy={"^home/%.gemini/antigravity%-cli/brain/.*/%.system_generated/logs/transcript.*%.jsonl$",
      "^home/%.gemini/antigravity%-cli/log/cli%-.*%.log$","^home/%.gemini/antigravity%-cli/history%.jsonl$"}
  }
  local excluded={"auth","credential","token","keychain","settings"}
  local function allowed(rel,globs)
    for segment in rel:lower():gmatch("[^/]+") do
      if segment=="." or segment==".." or segment:find("%.env%.") or segment:match("%.env$") then return false end
      for _,word in ipairs(excluded) do if segment:find(word,1,true) then return false end end
    end
    for _,pattern in ipairs(globs) do if rel:match(pattern) then return true end end
    return false
  end
  local function digest(path)
    local result=N.exec({"/bin/bash","-p","-c",'exec /usr/bin/shasum -a 256 < "$1"',"rex-orchestrator",path})
    local hash=result.ok and result.stdout:match("^(%x+)")
    return hash and #hash==64 and hash or nil
  end
  -- INSTR: launch's record of DIR's instruction files; the manifest lists what the run changed in instructions_changed.
  return function(home,state,instr)
    N.private_umask()
    home=home:gsub("/+$","")
    local root,err=N.open_dir(home)
    if not root then return nil,"cannot open cage home: " .. err end
    local function archive()
      local errors,files=J.array(),J.array()
      local text,meta_error=N.read(root,"run-meta.json")
      if not text then errors[#errors+1]="run metadata unavailable: " .. meta_error end
      local meta=text and J.decode(text)
      if text and meta==nil then errors[#errors+1]="run metadata unavailable: invalid JSON" end
      if meta==nil then meta={} end
      if not J.object(meta) then errors[#errors+1]="run metadata is not an object"; meta={} end
      local leaf=M.basename(home)
      local kind=type(meta.kind)=="string" and meta.kind or leaf:match("^[^.]+") or leaf
      local label=type(meta.label)=="string" and meta.label or leaf
      kind,label=tostring(kind),tostring(label)
      local family=M.starts(kind,"agy-") and "agy" or kind
      local globs=patterns[family]
      if not globs then errors[#errors+1]="unknown cage kind: " .. kind end
      local runs=state .. "/runs"
      if F.test("-L",runs) then return nil,"runs directory is a symlink" end
      if not F.mkdir(runs) or not F.chmod("700",runs) then return nil,"cannot set up runs directory" end
      runs=F.canonical(runs)
      if not runs then return nil,"cannot resolve runs directory" end
      local safe=label:gsub("[\128-\191]",""):gsub("[^a-zA-Z0-9_-]","_"):sub(1,100)
      if safe=="" then safe="run" end
      local secs,suffix,dest
      for _=1,3 do
        local now,usecs=N.now()
        local fraction=string.format(".%06d",usecs)
        local path=runs .. "/" .. safe .. "-" .. os.date("!%Y%m%dT%H%M%S",now) .. fraction .. "Z"
        if F.mkdir_new(path) then secs,suffix,dest=now,fraction,path; break end
        if not F.exists(path) then break end
      end
      if not dest then return nil,"cannot create archive directory" end
      if globs then
        local listed=N.exec({"/usr/bin/find","-P",home,"-type","f","-print0"})
        if not listed.ok then errors[#errors+1]=listed.stderr:gsub("\n$","") end
        for src in listed.stdout:gmatch("([^%z]+)%z") do
          local rel=M.starts(src,home .. "/") and src:sub(#home+2)
          if rel and allowed(rel,globs) then
            local target=dest .. "/" .. rel
            local bytes,why
            if F.mkdir(M.dirname(target)) then bytes,why=N.copy(root,rel,target)
            else why="cannot create archive subdirectory" end
            if bytes then
              local hash=digest(target)
              if hash then files[#files+1]={path=rel,sha256=hash,bytes=bytes}
              else os.remove(target); why="cannot compute SHA-256" end
            end
            if why then errors[#errors+1]=rel .. ": " .. why end
          end
        end
      end
      local manifest={kind=kind,label=label,files=files,errors=errors,
        end_time=os.date("!%Y-%m-%dT%H:%M:%S",secs) .. suffix .. "+00:00"}
      for _,key in ipairs({"account","block","DIR","start_time"}) do manifest[key]=meta[key] or "unknown" end
      if instr then
        local dir,before=M.instructions_read(F.read(instr))
        local after=dir and M.instructions(N.exec,dir)
        if after then
          local changed=J.array()
          for _,change in ipairs(M.instructions_changed(before,after)) do changed[#changed+1]=change end
          manifest.instructions_changed=changed
        else errors[#errors+1]="cannot check the instruction files" end
      end
      if not F.put(dest .. "/manifest.json",J.encode(manifest) .. "\n") then return nil,"cannot write archive manifest" end
      for _,message in ipairs(errors) do io.stderr:write("rex-orchestrator: harvest: ",M.terminal_text(message),"\n") end
      return true
    end
    local ok,result,why=pcall(archive)
    N.close(root)
    if not ok then return nil,result end
    return result,why
  end
end
