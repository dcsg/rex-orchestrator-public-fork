-- Report execution separately from the CLI's own transport exit status.
local control=rex.args.forward_errors and io.open("/dev/fd/4","w")
if control then control:write("\30rex-orchestrator:started\n"); control:flush() end
local dir=rex.args.script_dir .. "/lua/"
local M=dofile(dir .. "core.lua")
local fs=dofile(dir .. "fs.lua")(rex)
local diagnostic=rex.args.forward_errors and io.open("/dev/fd/5","w") or io.stderr
local C=M.new(rex,fs,{raw=function(text)
  diagnostic:write(text .. "\n")
  diagnostic:flush()
end,finish=function(code)
  if code==4 and control then control:write("\30rex-orchestrator:rejected\n"); control:flush() end
  rex.stop(code)
end})
local A=dofile(dir .. "approval.lua")(C,M)
local commands=dofile(dir .. "commands.lua")(C,M,A)
C.script_dir=rex.args.script_dir
C.rex_bin=rex.args.rex_bin
local registry=dofile(dir .. "registry.lua")(C,M)
local input=dofile(dir .. "input.lua")(M)
for name,fn in pairs(dofile(dir .. "mutations.lua")(C,M,input,registry)) do commands[name]=fn end
local function decode(arg)
  return (arg:gsub("[\194\195][\128-\191]",function(c)
    return string.char(c:byte(2)+(c:byte(1)-194)*64)
  end))
end
local argv=rex.args.argv
for i,arg in ipairs(argv) do argv[i]=decode(arg) end
C.context={session=decode(rex.args.session),block=decode(rex.args.block)}
local command=table.remove(argv,1)
if command=="claims" then C.init_state() else C.init() end
commands[command](argv)
