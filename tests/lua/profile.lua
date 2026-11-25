-- Test-only instrumentation: count the filesystem helpers started by Lua.
local original=rex.exec
local start=original.start
local function record(argv)
  local f=assert(io.open(os.getenv("REX_LUA_TRACE"),"a"))
  f:write("LUA_EXEC ",argv[1],"\n"); f:close()
end
rex.exec=setmetatable({start=function(argv,opts) record(argv); return start(argv,opts) end},
  {__call=function(_,argv,opts) record(argv); return original(argv,opts) end})
dofile(rex.args.script_dir .. "/lua/main.lua")
