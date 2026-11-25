return function(C,M)
  local R,F=C.rex,C.fs
  -- Every git here runs through M.git: REPO and the copy may hold hooks, an fsmonitor, filter drivers and the like that a
  -- caged worker wrote, and none of them may run on the host. WORKTREE names the folder whose drivers to switch off.
  local function git(args,diagnostics,worktree)
    local result,why=M.git(R.exec,C.git,args,worktree)
    if not result and why then C.note("clone: " .. why) end
    if diagnostics and result then
      for _,text in ipairs({result.stdout,result.stderr}) do
        if text~="" then C.lines((text:gsub("\n$",""))) end
      end
    end
    return result and result.ok
  end
  return function(argv)
    local repo,dest,flag,branch=unpack(argv)
    if #argv~=2 and (#argv~=4 or flag~="-b" or branch=="") then
      C.die("clone: expected REPO DEST [-b BRANCH]")
    end
    if F.exists(dest) then C.die("clone: DEST already exists: " .. dest) end
    local canonical=F.canonical(repo)
    if not canonical then C.die("clone: no such REPO: " .. repo) end
    repo=canonical
    if not F.test("-d",repo .. "/.git") then C.die("clone: REPO must have its own .git directory") end
    if not git({"-C",repo,"rev-parse","--show-toplevel"}) then C.die("clone: not a git repository: " .. repo) end
    local function reserve_destination()
      if F.mkdir_new(dest) then return end
      if F.exists(dest) then C.die("clone: DEST already exists: " .. dest) end
      C.die("clone failed",1)
    end
    if not F.mkdir(M.dirname(dest)) then C.die("clone failed",1) end
    reserve_destination()
    local copy=R.exec({"/bin/cp","-c","-R",repo .. "/.",dest})
    if not copy or not copy.ok then
      C.note("clone: cp -c failed; falling back to git clone --local")
      if not F.remove_tree(dest) then C.die("clone failed",1) end
      reserve_destination()
      if not git({"clone","--local","--",repo,dest},true,repo) then
        F.remove_tree(dest)
        C.die("clone failed",1)
      end
    end
    if branch and not git({"-C",dest,"switch","-c",branch},true,dest) then
      F.remove_tree(dest)
      C.die("clone: cannot create branch " .. branch,1)
    end
    C.out(dest)
  end
end
