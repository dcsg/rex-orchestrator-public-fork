local dir=rex.args.script_dir .. "/lua/"
local M=dofile(dir .. "core.lua")
local fs=dofile(dir .. "fs.lua")(rex)
local C=M.new(rex,fs)
local A=dofile(dir .. "approval.lua")(C,M)
local commands=dofile(dir .. "commands.lua")(C,M,A)
local argv=rex.args.argv
local command=table.remove(argv,1)
C.init()
commands[command](argv)
