-- The wait --approve-in safety checks. No caller may turn an unknown read into Yes.
return function(C, M)
  local A={}
  local protected={}
  for _,n in ipairs({"claude.md","claude.local.md","agents.md","gemini.md","lefthook.yml","lefthook.yaml","bunfig.toml","gradle-wrapper.properties","maven-wrapper.properties","pyrightconfig.json"}) do protected[n]=true end
  function A.names(path)
    if ("/" .. path):find("/.",1,true) then return false end
    local b=path:match("([^/]*)$") or ""
    return not b:find("[^ -~]") and not protected[b:lower()]
  end
  function A.msg_path(app,msg)
    if msg:find("%c") or msg:find("\194[\128-\159]") then return nil end
    local ell=msg:find("…",1,true)
    if ell and (ell+#"…"-1<#msg or app=="claude-code") then return nil end
    if app=="claude-code" then
      for _,verb in ipairs({"Write","Edit","Update","Create","MultiEdit","NotebookEdit"}) do
        local p="approve " .. verb .. ": "
        if M.starts(msg,p .. "/") then return msg:sub(#p+1) end
      end
    elseif app=="antigravity" then
      for _,verb in ipairs({"WriteFile","EditFile"}) do
        local p="Approve " .. verb .. ": Write: "
        if M.starts(msg,p .. "/") then return msg:sub(#p+1) end
      end
    end
  end
  local function option(l)
    local t=M.trim(l); local s=M.cursor(t)
    return (s or t):match("^(%d+)%.%s*(.*)$")
  end
  function A.dialog(screen,app,path,cut)
    local a=M.region(screen); local width=0
    for _,l in ipairs(M.lines(screen)) do
      if l:find("──────────",1,true) then local _,n=l:gsub("─",""); width=n end
    end
    local first,second,q,selected,num,text
    selected=0
    for i,l in ipairs(a) do
      local t=M.trim(l)
      if t~="" then if not first then first=i elseif not second then second=t end end
      if M.starts(t,"Do you want to ") then q=t end
      if M.cursor(t) and option(t) then
        selected=selected+1; num,text=option(t)
        local j=i+1
        while a[j] and a[j]:match("%S") and not option(a[j]) do
          text=text .. " " .. a[j]:gsub("^%s+",""); j=j+1
        end
      end
    end
    local ok,shown=false,""
    if app=="claude-code" then
      local b=path:match("([^/]*)$")
      for _,verb in ipairs({"create","overwrite","write to","make this edit to","insert this cell into","delete this cell from"}) do
        if q=="Do you want to " .. verb .. " " .. b .. "?" and text=="Yes" then ok=true end
      end
      shown=second or ""
    elseif first then
      local t=M.trim(a[first])
      if M.starts(t,path) then
        local rest=t:sub(#path+1)
        local stat=rest:match("  [+-]%d+$") or rest:match("  [+-]%d+ [+-]%d+$")
        if not cut then
          if stat and stat==rest then ok=true; shown=path end
        elseif #a[first]<width and stat then
          ok=true; shown=t:sub(1,#t-#stat)
        else ok=true end
      end
    end
    if width>0 and ok and selected==1 and num=="1" and text and
      (M.starts(text,"Yes") or M.starts(text,"Allow") or M.starts(text,"Approve")) and not M.persistent(text:lower()) then return shown end
  end
  local function clean(path)
    local a={}; for c in path:gmatch("[^/]+") do
      if c==".." then a[#a]=nil elseif c~="." then a[#a+1]=c end
    end; return "/" .. table.concat(a,"/")
  end
  function A.row_names(row,path,dir)
    if row=="" or dir=="" then return false end
    local pre,suf=row:match("^(.-)…(.*)$")
    if pre then
      if suf:find("…",1,true) or not suf:find("/",1,true) then return false end
      local forms={path}
      local home=M.env("HOME") or "/nonexistent"
      if M.starts(path,home) then forms[#forms+1]="~" .. path:sub(#home+1) end
      if M.below(path,dir) then forms[#forms+1]=path:sub(#dir+2) end
      for _,f in ipairs(forms) do
        if #f>#pre+#suf and M.starts(f,pre) and f:sub(-#suf)==suf then return true end
      end
      return false
    end
    local absolute
    if M.starts(row,"/") then absolute=row
    elseif M.starts(row,"~/") then absolute=(M.env("HOME") or "/nonexistent") .. row:sub(2)
    else absolute=dir .. "/" .. row end
    local a=C.fs.real(clean(absolute)); local b=C.fs.real(path)
    return a~=nil and a==b
  end
  local function dots(path) return ("/" .. path .. "/"):find("/%./") or ("/" .. path .. "/"):find("/%.%./") end
  function A.path_ok(path,dir)
    if dots(path) then return false end
    path=path:gsub("/+","/")
    local real=C.fs.real(path)
    if not real or not M.below(real,dir) or not C.fs.plain(real) then return false end
    local p,rest=path,""
    while C.fs.canonical(p)~=dir do
      if p=="/" or p=="" then return false end
      local leaf=p:match("([^/]+)$"); if not leaf then return false end
      rest=leaf .. (rest~="" and "/" .. rest or "")
      p=p:match("^(.*)/[^/]+$"); if p=="" then p="/" end
    end
    return A.names(rest) and A.names(real:sub(#dir+2))
  end
  function A.prefix_ok(path,dir)
    return not dots(path) and M.below(path,dir) and A.names(path:sub(#dir+2)) and C.fs.prefix(path,dir)
  end
  function A.verified()
    local p=C.call(C.block,"process"); local bin=p and p.child and p.child.path
    if not bin then return false end
    local r=C.rex.exec({"/usr/bin/stat","-f","%z %m %i %c",bin})
    if not r or not r.ok then return false end
    local st=r.stdout:gsub("\n$",""); local cache=C.fs.read(C.dir .. "/agy-sha256") or ""
    local meta,sha,cbin=cache:match("^(%d+ %d+ %d+ %d+) (%x+) (.-)\n?$")
    if meta~=st or cbin~=bin then
      r=C.rex.exec({"/usr/bin/shasum","-a","256",bin})
      if not r or not r.ok then return false end
      sha=r.stdout:match("^(%x+)")
      if not sha or not C.put(C.dir .. "/agy-sha256",st .. " " .. sha .. " " .. bin) then return false end
    end
    return sha=="34423fc9b0af3841e7646aa72a2d40ffeab8218b22d1cb99eac7355f9eba31e3"
  end
  local function same_record(a,b)
    -- Canonicalize keys rather than depending on JSON object insertion order.
    if type(a)~=type(b) then return false end
    if type(a)~="table" then return a==b end
    for k,v in pairs(a) do if not same_record(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
  end
  function A.locked(rec,dir)
    local function leave(why) C.note("--approve-in left this to you: " .. why); return 1 end
    local why=C.stopped()
    if why~="" then return leave(C.block .. " is stopped (" .. why .. ")") end
    if C.killed() then return leave("the kill switch " .. C.dir .. "/disabled is set") end
    local k=C.kind(rec)
    if C.killed(k) then return leave("the kill switch " .. C.dir .. "/disabled." .. k .. " is set") end
    local msg,app,upd=rec.msg or "",rec.effective_app or rec.app or "",rec.updated_at or ""
    local path=A.msg_path(app,msg)
    if upd=="" or not path then return leave("not a file write or edit prompt it knows") end
    local okfile=C.sf(C.block) .. ".ok"
    local old=M.lines(C.fs.read(okfile))
    for _,line in ipairs(old) do if line==upd then return 0 end end
    path=path:gsub("/+","/")
    local cut=path:sub(-#"…")=="…"
    if cut then path=path:sub(1,-#"…"-1) end
    if cut and not A.verified() then return leave("agy cut the path, and this agy build is not a verified one") end
    local shown
    for n=1,9 do
      shown=A.dialog(C.screen(C.block) or "",app,path,cut)
      if shown~=nil then break end
      if n<9 then C.rex.sleep(0.25) end
    end
    if shown==nil then return leave("the dialog on screen is not this prompt's one-time Yes") end
    if app=="claude-code" then
      if not A.row_names(shown,path,C.line(C.block,"own",5)) then return leave("the dialog's path row (" .. (shown~="" and shown or "none") .. ") doesn't name " .. path) end
      shown=""
    end
    if cut and shown=="" then
      if not A.prefix_ok(path,dir) then return leave("agy cut the path in its status and in its dialog (the pane is narrow), and the part shown can't keep it inside " .. dir) end
    elseif not A.path_ok(shown~="" and shown or path,dir) then
      return leave("not a plain file inside " .. dir .. ", or a protected one (dot files, agent instructions, a name with a non-ASCII character)")
    end
    if not same_record(C.root(C.block),rec) then return 2 end
    -- A lost reply may mean Enter already reached the pane.
    local result,err,pressed=C.enter()
    if not result and not pressed then C.note("--approve-in could not press Enter in " .. C.block); return 1 end
    if err then C.raw("Error: " .. err) end
    C.note("approved once: " .. msg)
    A.pressed=true
    local keep={}; for i=math.max(1,#old-18),#old do keep[#keep+1]=old[i] end
    keep[#keep+1]=upd
    if not C.put(okfile,unpack(keep)) then C.note("could not save the state of " .. C.block) end
    return 0
  end
  function A.once(rec,dir)
    local release,code=C.fs.lock(C.sf(C.block) .. ".lock")
    if not release then
      if code==2 then return 2 end
      C.note("--approve-in left this to you: cannot take the approval lock of " .. C.block); return 1
    end
    local ok,result=pcall(A.locked,rec,dir)
    release()
    if not ok then error(result,0) end
    return result
  end
  return A
end
