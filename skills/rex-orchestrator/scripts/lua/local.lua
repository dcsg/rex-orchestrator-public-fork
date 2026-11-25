-- Entry point for work that must run even when there is no Rex connection.
local dir=arg[0]:match("^(.*)/")
local M=dofile(dir .. "/core.lua")
local J=dofile(dir .. "/json.lua")(M)
local N=dofile(dir .. "/standalone.lua")
local rex={json=J,exec=N.exec,stop=os.exit}
local F=dofile(dir .. "/fs.lua")(rex)
local C=M.new(rex,F)
local command=table.remove(arg,1)
if command=="clone" then
  C.git=F.git()
  dofile(dir .. "/clone.lua")(C,M)(arg)
elseif command=="harvest" then
  local ok,err=dofile(dir .. "/harvest.lua")(M,J,F,N)(arg[1],arg[2],arg[3])
  if not ok then C.die("harvest failed: " .. tostring(err),1) end
elseif command=="validate-agy" then
  local login=J.decode(N.read(nil,arg[1]))
  local function nonempty(value) return type(value)=="string" and value~="" end
  if not J.object(login) or
    not (nonempty(login.refresh_token) or (J.object(login.token) and nonempty(login.token.refresh_token))) then
    os.exit(1)
  end
elseif command=="offline" then
  local verb=table.remove(arg,1)
  if verb=="claims" then
    C.init_state()
    F.lock=N.lock
    C.resolve=function() return nil,1 end
    dofile(dir .. "/registry.lua")(C,M).claims(arg)
    return
  end
  local P=dofile(dir .. "/arguments.lua")(C,M)
  local target
  if verb=="launch" then
    local I=dofile(dir .. "/input.lua")(M)
    local D=dofile(dir .. "/launch_dialog.lua")(C,M,I)
    dofile(dir .. "/launch.lua")(C,M,D,I).parse(arg)
  elseif verb=="wait" then
    target=P.wait(arg)
  elseif verb=="send" or verb=="keys" or verb=="close" then
    target=P.mutation(verb,arg)
    if verb=="send" then P.prompt(arg) end
  elseif verb=="screen" then
    target=P.screen(arg)
  elseif verb=="status" then
    target=P.block(arg[1])
  end
  local session,caller=M.env("REX_SESSION"),M.env("REX_BLOCK")
  if not session then C.missing_context() end
  C.init_state()
  if caller then C.die("rex did not answer for REX_BLOCK " .. caller,1) end
  if verb=="ls" then C.die("rex could not list the blocks",1) end
  if verb=="launch" or verb=="send" or verb=="keys" or verb=="close" then C.need_me() end
  C.die("rex did not answer for block " .. target,1)
else
  C.die("unknown local operation",1)
end
