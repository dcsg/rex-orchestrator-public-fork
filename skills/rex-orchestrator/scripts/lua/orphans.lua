-- Orphans: children whose orchestrator's pane is gone from the session. Only a gone pane counts: an orchestrator agent
-- that quits and is resumed in the same pane (same block ID) still owns and drives its children. After a grace period,
-- an orphan whose turn is over is closed through the normal close path; one still working or blocked is closed when its
-- turn ends, and left open (and reported) once a maximum wait has passed. Never killed mid-turn.
--
-- An ownership record (STATE_DIR/<block>.own) names the orchestrator on line 1, the Rex session on line 8, and the
-- launch's orphan policy, grace period and maximum wait on lines 9 to 11: each child keeps the settings it was launched
-- with, whoever looks at it later. A record without a session (an older launch, or a recovery stub) is never an orphan.
local O={}
O.grace=600
O.max_wait=7200
O.closable={done=true,idle=true,error=true}

local function duration(value)
  local n,u=(value or ""):match("^(%d+)([smh]?)$")
  return n and tonumber(n)*({s=1,m=60,h=3600,[""]=1})[u] or nil
end

-- The orphan settings from the environment. bad names the first variable with a value it can't take.
function O.settings(env)
  local s={keep=false,grace=O.grace,max_wait=O.max_wait}
  local bad
  local policy=env("REX_ORCHESTRATOR_ORPHANS") or "close"
  if policy=="keep" then s.keep=true
  elseif policy~="close" then s.keep=true; bad="REX_ORCHESTRATOR_ORPHANS takes close or keep, not '" .. policy .. "'" end
  for key,name in pairs({grace="REX_ORCHESTRATOR_ORPHAN_GRACE",max_wait="REX_ORCHESTRATOR_ORPHAN_MAX_WAIT"}) do
    local value=env(name)
    if value then
      local seconds=duration(value)
      if seconds then s[key]=seconds
      else bad=bad or name .. " takes a duration such as 0, 90s, 10m or 2h, not '" .. value .. "'" end
    end
  end
  return s,bad
end

-- What to do with one child. Pure: everything it needs is in t.
--   owner, session, policy        lines 1, 8 and 9 of the child's ownership record
--   grace, max_wait               lines 10 and 11, the child's own limits
--   here, me, block               the session swept, the calling pane (if any), the child
--   presence                      "present", "gone" (absent on consecutive checks) or nil (couldn't tell)
--   gone_for                      seconds since the orchestrator's pane was first seen gone
--   keep, disabled, expired       this call's opt-out, kill switch, already left open
--   checked, exited, state, background   the child's own state, once action "check" asked for it; background is nil
--                                 when its screen couldn't be read, and then a finished turn still waits
-- Actions: skip (not an orphan), grace, keep, expired, check, close, wait, expire.
function O.decide(t)
  if type(t.owner)~="string" or not t.owner:match("^block:[%w%-]+$") then return "skip","no ownership record" end
  if type(t.session)~="string" or t.session=="" or t.session~=t.here then return "skip","not in this session" end
  if t.block==t.owner or t.block==t.me or t.owner==t.me then
    -- The caller's own children have a live orchestrator: the caller.
    return "skip",t.block==t.owner and "not a child" or t.block==t.me and "the calling pane" or "the caller's child"
  end
  if t.presence~="gone" then
    return "skip",t.presence=="present" and "its orchestrator's pane is open" or "its orchestrator's pane can't be checked"
  end
  if t.keep or t.policy=="keep" then return "keep","orphans are kept (REX_ORCHESTRATOR_ORPHANS=keep)" end
  if t.disabled then return "keep","the kill switch is set" end
  if t.expired then return "expired","left open" end
  local gone_for,grace=t.gone_for or 0,t.grace or O.grace
  if gone_for<grace then return "grace","closing after " .. grace .. "s" end
  if not t.checked then return "check" end
  if t.exited then return "close","exited" end
  local state=t.state or ""
  local background=t.background
  if O.closable[state] and background=="" then return "close",state end
  local busy=(state~="" and state or "no status") ..
    (background==nil and O.closable[state] and " (its screen can't be read)" or
     (background or "")~="" and " with background work (" .. background .. ")" or "")
  if gone_for-grace>=(t.max_wait or O.max_wait) then
    return "expire",busy .. " after " .. (t.max_wait or O.max_wait) .. "s"
  end
  return "wait",busy
end

function O.new(C,M,close_block)
  local R=C.rex
  local W={}
  W.settings,W.bad=O.settings(M.env)
  function W.path(block) return C.dir .. "/watch/" .. block:gsub("[^A-Za-z0-9_-]","_") end

  -- Every ownership record, with the block ID read back from its file name.
  function W.records()
    local list={}
    for _,path in ipairs(C.fs.own_paths(C.dir) or {}) do
      local id=path:match("/block_([%w%-]+)%.own$")
      local block=id and "block:" .. id
      local text=block and C.sf(block) .. ".own"==path and C.fs.read(path)
      if text then
        local l=M.lines(text)
        list[#list+1]={block=block,owner=l[1] or "",session=l[8] or "",policy=l[9] or "",
          grace=tonumber(l[10]) or O.grace,max_wait=tonumber(l[11]) or O.max_wait}
      end
    end
    return list
  end

  function W.blocks()
    if not C.attach() then return nil end
    local r=R.session.list_blocks{session_id=C.session}
    if not r or type(r.blocks)~="table" then return nil end
    local set={}
    for _,b in ipairs(r.blocks) do if b.block_id then set[b.block_id]=true end end
    return set
  end

  -- "present", or "gone" with the seconds since it was first seen gone, or nil.
  -- Gone means absent from the session's block list on two checks; the first sighting is saved, so the grace
  -- period runs across processes. A pane that comes back cancels it.
  function W.presence(orch,blocks)
    if not blocks then return nil end
    local path=W.path(orch) .. ".gone"
    if blocks[orch] then
      if C.fs.read(path) then
        C.fs.unlink(path)
        C.note(orch .. " is in the session again: its children are not orphans")
      end
      return "present"
    end
    local mark=M.lines(C.fs.read(path) or "")
    local first=tonumber(mark[1])
    if not first then
      first=os.time()
      R.sleep(1)
      local again=W.blocks()
      if not again then return nil end
      if again[orch] then return "present" end
      if not (C.fs.mkdir(C.dir .. "/watch") and C.put(path,first)) then
        C.note("could not save when " .. orch .. " was first seen gone")
      end
    end
    return "gone",math.max(0,os.time()-first)
  end

  -- Start ORCH's watcher unless one runs. TRIES>1 waits up to TRIES/10 s for a watcher that is just exiting.
  function W.ensure(orch,tries)
    if W.settings.keep or W.watcher then return end
    local base=W.path(orch)
    if tries<=1 then
      local beat=(C.fs.read(base .. ".alive") or ""):match("^(%d+)")
      if beat and os.time()-tonumber(beat)<20 then return end
    end
    if not C.fs.mkdir(C.dir .. "/watch") then C.note("could not create " .. C.dir .. "/watch"); return end
    local args=R.json.encode({script_dir=C.script_dir,rex_bin=C.rex_bin,orchestrator=orch,session=C.session,
      state_dir=C.dir})
    if not C.fs.daemon(base .. ".lock",base .. ".log",tries,
      {C.rex_bin,"--autostart=false","do","-s",C.session,C.script_dir .. "/lua/watch.lua","--args",args}) then
      C.note("could not start the orphan watcher for " .. orch)
    end
  end

  -- Look at every child in this session (or ONLY's), close the orphans whose time has come and report the rest.
  -- Returns remaining (children still to watch: not left open, not launched with keep), left (children left open),
  -- status (block -> grace|waiting|kept|expired), and for ONLY whether its pane is gone and when a watcher may stop.
  function W.sweep(only)
    local result={remaining=0,status={},owners={}}
    if C.dir=="" or not C.session then return result end
    local here=C.session
    local children={}
    for _,r in ipairs(W.records()) do
      if r.session==here and r.owner:match("^block:[%w%-]+$") and (not only or r.owner==only) then
        children[#children+1]=r
      end
    end
    if #children==0 then return result end
    local blocks=W.blocks()
    local seen={}
    local disabled=C.killed()
    for _,r in ipairs(children) do
      if not seen[r.owner] then seen[r.owner]={W.presence(r.owner,blocks)} end
      local presence,gone_for=unpack(seen[r.owner])
      local t={owner=r.owner,session=r.session,policy=r.policy,here=here,me=C.me,block=r.block,presence=presence,
        gone_for=gone_for,grace=r.grace,max_wait=r.max_wait,keep=W.settings.keep,disabled=disabled,
        expired=C.line(r.block,"orphan",1)=="expired"}
      if presence=="present" and t.expired then C.fs.unlink(C.sf(r.block) .. ".orphan"); t.expired=false end
      local action,why=O.decide(t)
      if action=="check" then
        t.checked=true
        t.exited=C.exited(r.block)==true
        local rec=not t.exited and C.root(r.block)
        t.state=rec and rec.state or nil
        if O.closable[t.state or ""] then
          local screen=C.screen(r.block)
          t.background=screen and M.background(screen) or nil
        end
        action,why=O.decide(t)
      end
      local status
      if action=="close" then
        local closed,err=close_block(r.block,blocks~=nil and not blocks[r.block])
        if closed then
          C.note("closed " .. r.block .. ", an orphan (its orchestrator " .. r.owner .. "'s pane is gone): " .. why)
        else
          C.note("could not close the orphan " .. r.block .. ": " .. tostring(err))
          status="waiting"
        end
      elseif action=="expire" then
        if not C.put(C.sf(r.block) .. ".orphan","expired") then C.note("could not mark " .. r.block .. " as left open") end
        C.note("left " .. r.block .. " open: its orchestrator " .. r.owner .. "'s pane is gone, but it is still " ..
          why .. "; close it yourself")
        status="expired"
      elseif action=="expired" then status="expired"
      elseif action=="wait" then status="waiting"
      elseif action=="grace" then status="grace"
      elseif action=="keep" then status="kept"
      elseif action=="skip" and presence~="gone" then status=false end
      if status~=nil then
        if status then result.status[r.block]=status end
        if r.policy=="keep" then
          -- Never watched: nothing will close it, so nothing needs to look at it again.
        elseif status~="expired" then
          result.remaining=result.remaining+1
          result.owners[r.owner]=true
        else result.left=(result.left or 0)+1 end
      end
      if only and r.owner==only and presence=="gone" then
        result.gone=true
        result.deadline=math.max(result.deadline or 0,os.time()-gone_for+r.grace+r.max_wait+60)
      end
    end
    -- Under the kill switch nothing closes: this call's look is enough, no watcher is started for it.
    if not only and not disabled then
      for owner in pairs(result.owners) do W.ensure(owner,1) end
    end
    return result
  end

  return W
end

return O
