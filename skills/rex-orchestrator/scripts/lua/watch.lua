-- One orchestrator's orphan watcher: `rex do -s SESSION watch.lua --args JSON`, started detached by launch (or by a
-- sweep) through fs.daemon, which holds STATE_DIR/watch/<orchestrator>.lock for this process's whole life, so at most
-- one runs per orchestrator. It closes the orchestrator's orphans as their time comes and exits once the orchestrator
-- has no children left, once its pane has been gone longer than the grace period and the maximum wait, when the
-- session is destroyed, or when the connection to Rex is lost (a Rex restart); the sweep on every rex-orchestrator
-- call covers what it no longer sees.
local a=rex.args
local dir=a.script_dir .. "/lua/"
local M=dofile(dir .. "core.lua")
local fs=dofile(dir .. "fs.lua")(rex)
local function log(text)
  io.stdout:write(os.date("!%Y-%m-%dT%H:%M:%SZ ") .. text .. "\n")
  io.stdout:flush()
end
local C=M.new(rex,fs,{out=log,raw=log,note=function(text) log(M.terminal_text(text)) end,
  finish=function(code) rex.stop(code) end})
C.dir=a.state_dir
C.session=a.session
C.script_dir=a.script_dir
C.rex_bin=a.rex_bin
C.init_state()
local registry=dofile(dir .. "registry.lua")(C,M)
local close=dofile(dir .. "close.lua")(C,M,registry)
local W=dofile(dir .. "orphans.lua").new(C,M,close)
W.watcher=true
local orch=a.orchestrator
local base=W.path(orch)
log("watching the children of " .. orch .. " in " .. C.session)
if W.settings.keep then
  log("orphans are kept (REX_ORCHESTRATOR_ORPHANS=keep); exiting")
  rex.stop(0)
  return
end
local soon,gone,done
local function finish(why,clean)
  done=true
  log(why .. "; exiting")
  fs.unlink(base .. ".alive")
  if gone and clean then
    -- A block ID never comes back once its pane is gone: nothing here is needed again.
    fs.unlink(base .. ".gone")
    fs.unlink(base .. ".lock")
    fs.unlink(base .. ".log")
  end
  rex.stop(0)
end
local function tick()
  soon=nil
  if done then return end
  if not C.put(base .. ".alive",os.time()) then log("could not write the heartbeat") end
  local ok,r=pcall(W.sweep,orch)
  if not ok then log("sweep failed: " .. tostring(r)); return end
  gone=r.gone
  if r.remaining==0 then return finish("no children left to watch",not r.left) end
  if r.deadline and os.time()>r.deadline then return finish("past the grace period and the maximum wait") end
end
local function later()
  if not soon and not done then soon=rex.after(0.5,tick) end
end
rex.on("block_closed",function(ctx,ev)
  if (ev.block_id or ctx.block_id)==orch then later() end
end)
-- Once the pane is gone, a child's status change can end its wait.
rex.on("terminal.program_status_changed",function() if gone then later() end end)
rex.every(5,tick)
rex.after(0,tick)
