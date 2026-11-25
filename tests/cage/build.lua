-- Local rex.exec shim for zero-token cage fixtures. No Rex session or socket is used.
local assets,script_dir,state,name,bin,dir,account,forced_leaf=unpack(arg)
local M=dofile(assets .. "/lua/core.lua")
local function quote(s) return "'" .. s:gsub("'","'\\''") .. "'" end
local function capture(argv,options)
  local quoted={}
  for _,value in ipairs(argv) do quoted[#quoted+1]=quote(value) end
  local input
  if options and options.stdin then
    local tmp=capture({"/usr/bin/mktemp",state .. "/build-input.XXXXXX"})
    if not tmp.ok then return {ok=false} end
    input=tmp.stdout:gsub("\n$","")
    local file=assert(io.open(input,"wb"))
    assert(file:write(options.stdin))
    assert(file:close())
  end
  local prefix="/usr/bin/env"
  for key,value in pairs(options and options.env or {}) do
    assert(value==false)
    prefix=prefix .. " -u " .. quote(key)
  end
  local redirect=input and (" <" .. quote(input)) or " </dev/null"
  local proc=assert(io.popen(prefix .. " " .. table.concat(quoted," ") .. redirect .. [[; printf '\n%s\n' "$?"]]))
  local output=assert(proc:read("*a"))
  proc:close()
  if input then assert(os.remove(input)) end
  local stdout,code=assert(output:match("^(.*)\n(%d+)\n$"))
  return {ok=code=="0",code=tonumber(code),stdout=stdout}
end
local rex={exec=capture,json={encode=function(object)
  local fields={}
  for key,value in pairs(object) do fields[#fields+1]=M.json_string(key) .. ":" .. M.json_string(value) end
  return "{" .. table.concat(fields,",") .. "}"
end,decode=function(text)
  -- The only input here is the synthetic agy login settings.
  local fixture=text:match('"model"%s*:%s*"([%w_-]+)"')
  return {model=fixture}
end}}
local F=dofile(assets .. "/lua/fs.lua")(rex)
if forced_leaf~="" then
  function F.private_temp(base)
    local path=base .. "/" .. forced_leaf
    return F.mkdir_new(path) and path or nil
  end
end
local C={rex=rex,fs=F,dir=state,script_dir=script_dir,git=F.git(),
  note=function(text) io.stderr:write(text,"\n") end,put=F.put}
local K=dofile(assets .. "/lua/launch_cage.lua")(C,M)
local cage,code=K.build(name,bin,{dir=dir,account=account,label=name},function() end)
if not cage then os.exit(code) end
print(cage.home)
