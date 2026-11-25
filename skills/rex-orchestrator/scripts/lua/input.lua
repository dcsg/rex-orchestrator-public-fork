-- Parse the visible dialog and composer with the same boundaries as the Bash commands.
return function(M)
  local I={}
  local phrases={"esc to cancel","enter to select","enter to confirm","enter confirm","do you want to",
    "would you like to","hook needs review","hooks need review","hook need review","hooks needs review",
    "do you trust","trust this folder"}
  local startup_options={"review hooks","trust all and continue","continue without trusting","trust and continue"}

  local function contains_any(text,terms)
    for _,term in ipairs(terms) do
      if text:find(term,1,true) then return true end
    end
    return false
  end

  function I.dialog(screen,typed)
    local lines={}
    local ruled,prompt=false,false
    for _,line in ipairs(M.lines(screen)) do
      if line:find("──────────",1,true) then
        lines,ruled,prompt={},true,false
      else
        local first=M.trim(line)
        if not ruled and (M.starts(first,"❯") or M.starts(first,"›") or M.starts(first,">")) then
          lines,prompt={},true
        end
        lines[#lines+1]=line
      end
    end
    local selected,option,phrase=false,false,false
    for n,line in ipairs(lines) do
      local cursor=M.cursor(line)
      if cursor and cursor:match("^%d+%.") then
        selected=true
        local joined=(cursor .. " " .. (lines[n+1] or "")):lower():gsub("%s+"," ")
        local text=joined:match("^%d+%. (.+)") or ""
        for _,label in ipairs(startup_options) do
          if M.starts(text,label) then return true end
        end
      elseif line:match("^%s*%d+%.") then
        option=true
      end
      if (n>1 or not prompt) and contains_any(line:lower(),phrases) then phrase=true end
    end
    return (selected and option) or (phrase and not typed)
  end

  local function numbered(line)
    return (M.cursor(line) or M.trim(line)):match("^(%d+)[.)]?%s+(.+)")
  end

  function I.picked(screen,key)
    local lines=M.region(screen)
    local hit,text,number
    for n,line in ipairs(lines) do
      local digit,body=numbered(line)
      local cursor=M.cursor(line)
      if (key=="enter" and cursor and cursor~="") or digit==key then
        hit,text,number=n,body or cursor,digit
      end
    end
    if not hit then return nil end
    for n=hit+1,#lines do
      local rest=lines[n]:match("^%s+(%S.*)")
      if not number or not rest or numbered(lines[n]) then break end
      text=text .. " " .. rest
    end
    return text
  end

  function I.one_time(text)
    local lower=(text or ""):lower()
    local answer=(lower .. " "):match("^yes[^a-z]") or (lower .. " "):match("^no[^a-z]") or
      (lower .. " "):match("^continue[^a-z]")
    return answer and not M.persistent(lower) and
      (not lower:find("trust",1,true) or lower:find("without trust",1,true))
  end

  local function composer(screen,app)
    local lines=M.lines(screen)
    local upper,lower,top,bottom,cursor
    for i,line in ipairs(lines) do
      if line:find("──────────",1,true) then upper,lower=lower,i end
      local text=M.trim(line)
      if M.starts(text,"╭") then top=i end
      if M.starts(text,"╰") then bottom=i end
      if M.starts(text,"›") then cursor=i end
    end
    if app=="grok-build" then
      if top and bottom and bottom>top then return table.concat(lines," ",top+1,bottom-1) end
    elseif app=="codex" then
      if not cursor then return nil end
      local last=cursor
      while lines[last+1] and lines[last+1]:match("^%s+%S") do last=last+1 end
      return table.concat(lines," ",cursor,last)
    elseif app=="claude-code" or app=="antigravity" or app=="muse" then
      if upper then return table.concat(lines," ",upper+1,lower-1) end
    end
  end

  function I.typed_shown(screen,text,app)
    local box=composer(screen,app)
    if not box then return true end
    local chars={}
    for char in text:gmatch(".[\128-\191]*") do chars[#chars+1]=char end
    local function printable(value) return (value:gsub("[^\33-\126]","")) end
    local lead=printable(table.concat(chars,"",1,math.min(#chars,400))):sub(1,20)
    local tail=printable(table.concat(chars,"",math.max(1,#chars-399),#chars)):sub(-20)
    return contains_any(printable(box),{lead,tail,"[PastedContent","[Pastedtext"})
  end

  return I
end
