return function(C)
  local R,F=C.rex,C.fs
  local function git(args,diagnostics)
    table.insert(args,1,C.git)
    local result=R.exec(args)
    if diagnostics and result then
      for _,text in ipairs({result.stdout,result.stderr}) do
        if text~="" then C.raw(text:gsub("\n$","")) end
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
    repo=F.canonical(repo)
    if not repo then C.die("clone: no such REPO: ") end
    if not F.test("-d",repo .. "/.git") then C.die("clone: REPO must have its own .git directory") end
    if not git({"-C",repo,"rev-parse","--show-toplevel"}) then C.die("clone: not a git repository: " .. repo) end
    local function reserve_destination()
      if F.mkdir_new(dest) then return end
      if F.exists(dest) then C.die("clone: DEST already exists: " .. dest) end
      C.die("clone failed",1)
    end
    reserve_destination()
    local copy=R.exec({"/bin/cp","-c","-R",repo .. "/.",dest})
    if not copy or not copy.ok then
      C.note("clone: cp -c failed; falling back to git clone --local")
      if not F.remove_tree(dest) then C.die("clone failed",1) end
      reserve_destination()
      if not git({"clone","--local","--",repo,dest},true) then
        F.remove_tree(dest)
        C.die("clone failed",1)
      end
    end
    if branch and not git({"-C",dest,"switch","-c",branch},true) then
      F.remove_tree(dest)
      C.die("clone: cannot create branch " .. branch,1)
    end
    C.out(dest)
  end
end
