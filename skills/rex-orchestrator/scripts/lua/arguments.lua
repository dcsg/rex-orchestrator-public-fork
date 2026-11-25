-- Validate arguments independently of Rex so errors are the same while offline.
return function(C,M)
  local P={}
  function P.block(query)
    if not query or query=="" then C.die("missing BLOCK") end
    if M.starts(query,"-") then C.die("no such block in this session: " .. query) end
    return query
  end
  function P.screen_lines(n)
    if not n or n=="" then return 60 end
    if not n:match("^%d+$") then C.die("screen: LINES takes a whole number, not '" .. n .. "'") end
    return tonumber(n)
  end
  function P.wait(args)
    local timeout,ignore,bgmax,approve=600,false,300,""
    if args[1]=="--force" then C.force=true; table.remove(args,1) end
    local query=P.block(args[1])
    local i=2
    local function value()
      local v=args[i+1]
      if not v or v=="" then C.die(args[i] .. " needs a value") end
      return v
    end
    while i<=#args do
      local k=args[i]
      if k=="--timeout" then timeout=M.duration(k,value(),C.die); i=i+2
      elseif k=="--bg-max" then bgmax=M.duration(k,value(),C.die); i=i+2
      elseif k=="--ignore-background" then ignore=true; i=i+1
      elseif k=="--force" then C.force=true; i=i+1
      elseif k=="--approve-in" then
        local v=value()
        approve=C.fs.canonical(v)
        if not approve then C.die("wait: no such directory: " .. v) end
        local home=M.env("HOME")
        for _,f in ipairs({"/","/Users",home or "/",(home or "") .. "/Library",(home or "") .. "/Repos"}) do
          if approve==(C.fs.canonical(f) or "") then C.die("wait: --approve-in " .. v .. " is too broad; give the task's own directory") end
        end
        i=i+2
      else C.die("wait: unknown option " .. k) end
    end
    return query,timeout,ignore,bgmax,approve
  end
  function P.mutation(verb,args)
    if args[1]=="--force" then C.force=true; table.remove(args,1) end
    local query=P.block(table.remove(args,1))
    if verb=="keys" and #args==0 then C.die("keys: no keys given") end
    return query
  end
  function P.prompt(args)
    local text
    if args[1]=="-f" then
      local path=args[2] or ""
      local err
      text,err=C.fs.read_file(path)
      if not text then
        if err=="not_file" then C.die("send: no such file: " .. path) end
        C.raw("cat: " .. (err or path))
        C.finish(1)
      end
      text=text:gsub("%z",""):gsub("\n+$","")
    else
      text=table.concat(args," ")
    end
    if M.prompt_control(text) then
      C.die("send: refusing a prompt containing a terminal control character, invalid UTF-8, or a bidirectional override or isolate")
    end
    text=text:gsub("[\r\n\t]"," ")
    if not text:find("[^ ]") then C.die("send: empty prompt") end
    if text:match("^%s*!") then
      C.die("send: refusing a prompt that starts with '!': the agent would run it as a shell command without asking; reword it")
    end
    return text
  end
  return P
end
