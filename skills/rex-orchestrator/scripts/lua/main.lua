local dir=rex.args.script_dir .. "/lua/"
local M=dofile(dir .. "core.lua")
local fs=dofile(dir .. "fs.lua")(rex)
local diagnostic=rex.args.forward_errors and io.open("/dev/fd/4","w") or io.stderr
local C=M.new(rex,fs,{raw=function(text)
  diagnostic:write(text .. "\n")
  diagnostic:flush()
end})
local A=dofile(dir .. "approval.lua")(C,M)
local commands=dofile(dir .. "commands.lua")(C,M,A)
local argv=rex.args.argv
for i,arg in ipairs(argv) do
  argv[i]=arg:gsub("[\194\195][\128-\191]",function(c)
    return string.char(c:byte(2)+(c:byte(1)-194)*64)
  end)
end
local command=table.remove(argv,1)
C.init()
commands[command](argv)
