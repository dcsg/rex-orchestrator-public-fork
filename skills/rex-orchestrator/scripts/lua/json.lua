-- JSON for the standalone Lua commands. Rex commands use rex.json.
return function(M)
  local J={null={}}
  local array={}
  function J.array(t) return setmetatable(t or {},array) end
  local function utf8(n)
    local char=string.char
    if n<0x80 then return char(n) end
    local tail=0x80+n%64
    n=math.floor(n/64)
    if n<0x20 then return char(0xc0+n,tail) end
    local second=0x80+n%64
    n=math.floor(n/64)
    if n<0x10 then return char(0xe0+n,second,tail) end
    return char(0xf0+math.floor(n/64),0x80+n%64,second,tail)
  end
  local function valid_utf8(text)
    local i=1
    while i<=#text do
      local width=M.utf8_width(text,i)
      if not width then return false end
      i=i+width
    end
    return true
  end
  function J.object(value)
    return type(value)=="table" and value~=J.null and getmetatable(value)~=array
  end
  function J.decode(s)
    if type(s)~="string" then return nil end
    local i=1
    local escape={['"']='"',["\\"]="\\",["/"]="/",b="\b",f="\f",n="\n",r="\r",t="\t"}
    local function invalid() error("invalid JSON",0) end
    local function space()
      local _,last=s:find("^[ \t\r\n]*",i)
      i=last+1
    end
    local function unit(start)
      local n=s:sub(start,start+3)
      if not n:match("^%x%x%x%x$") then invalid() end
      return tonumber(n,16)
    end
    local function string_value()
      local pieces={}
      i=i+1
      while true do
        local stop=s:find('[%z\1-\31"\\]',i)
        if not stop then invalid() end
        pieces[#pieces+1]=s:sub(i,stop-1)
        local c=s:sub(stop,stop)
        i=stop+1
        if c=='"' then
          local text=table.concat(pieces)
          if not valid_utf8(text) then invalid() end
          return text
        end
        if c~="\\" then invalid() end
        c=s:sub(i,i)
        i=i+1
        if c=="u" then
          local n=unit(i)
          i=i+4
          if n>=0xd800 and n<=0xdbff then
            if s:sub(i,i+1)~="\\u" then invalid() end
            local low=unit(i+2)
            if low<0xdc00 or low>0xdfff then invalid() end
            n=0x10000+(n-0xd800)*0x400+(low-0xdc00)
            i=i+6
          elseif n>=0xdc00 and n<=0xdfff then invalid() end
          pieces[#pieces+1]=utf8(n)
        elseif escape[c] then pieces[#pieces+1]=escape[c]
        else invalid() end
      end
    end
    local function number_value()
      local start=i
      if s:sub(i,i)=="-" then i=i+1 end
      local first=s:sub(i,i)
      if first=="0" then i=i+1
      elseif first:match("[1-9]") then i=i+#s:match("^%d+",i)
      else invalid() end
      if s:sub(i,i)=="." then
        local fraction=s:match("^%.%d+",i)
        if not fraction then invalid() end
        i=i+#fraction
      end
      if s:sub(i,i):match("[Ee]") then
        local exponent=s:match("^[Ee][+-]?%d+",i)
        if not exponent then invalid() end
        i=i+#exponent
      end
      return tonumber(s:sub(start,i-1))
    end
    local value
    local function collection(object,depth)
      local result=object and {} or J.array()
      local ending=object and "}" or "]"
      i=i+1
      space()
      if s:sub(i,i)==ending then i=i+1; return result end
      while true do
        if object then
          if s:sub(i,i)~='"' then invalid() end
          local key=string_value()
          space()
          if s:sub(i,i)~=":" then invalid() end
          i=i+1
          result[key]=value(depth)
        else result[#result+1]=value(depth) end
        space()
        local separator=s:sub(i,i)
        i=i+1
        if separator==ending then return result end
        if separator~="," then invalid() end
        space()
      end
    end
    function value(depth)
      if depth>128 then invalid() end
      space()
      local c=s:sub(i,i)
      if c=='"' then return string_value() end
      if c=="{" or c=="[" then return collection(c=="{",depth+1) end
      if c=="-" or c:match("[0-9]") then return number_value() end
      for literal,result in pairs({["true"]=true,["false"]=false,["null"]=J.null}) do
        if s:sub(i,i+#literal-1)==literal then i=i+#literal; return result end
      end
      invalid()
    end
    local ok,result=pcall(value,0)
    if not ok then return nil end
    space()
    if i<=#s then return nil end
    return result
  end
  function J.encode(value)
    local kind=type(value)
    if value==J.null or kind=="nil" then return "null" end
    if kind=="string" then
      if not valid_utf8(value) then value=value:gsub("[\128-\255]","�") end
      return M.json_string(value)
    end
    if kind=="boolean" then return tostring(value) end
    if kind=="number" then return (value>-math.huge and value<math.huge) and tostring(value) or "null" end
    assert(kind=="table")
    local fields={}
    if getmetatable(value)==array then
      for i,v in ipairs(value) do fields[i]=J.encode(v) end
      return "[" .. table.concat(fields,",") .. "]"
    end
    for key,v in pairs(value) do fields[#fields+1]=J.encode(key) .. ":" .. J.encode(v) end
    table.sort(fields)
    return "{" .. table.concat(fields,",") .. "}"
  end
  return J
end
