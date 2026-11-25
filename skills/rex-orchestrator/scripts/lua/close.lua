-- Close a launched pane and remove everything launch left for it: the claim, the cage home and the state files.
-- Returns true, or nil and why; it never stops the script, so a sweep can close one pane and go on.
-- NOWAIT (for a pane already closed): when the claims lock is busy, change nothing and return nil, "busy", 0.
return function(C, M, registry)
  return function(block,missing,nowait)
    if not missing and not C.close_pane(block) then
      return nil,"rex could not close " .. block .. "; its state is kept: run close again",1
    end
    local released,why,busy=registry.release(block,nowait)
    if busy then return nil,why,0 end
    if not released then return nil,why,1 end
    local leaf=C.line(block,"cage",1)
    if leaf~="" and not M.starts(leaf,".") and not leaf:find("/",1,true) then
      local base=C.fs.canonical(C.dir .. "/cage")
      if base then
        local path=base .. "/" .. leaf
        if not C.remove_cage(path) then C.note("could not remove the cage home " .. path) end
      end
    end
    if not C.fs.remove_state(C.sf(block)) then return nil,"could not remove the state of " .. block,1 end
    return true
  end
end
