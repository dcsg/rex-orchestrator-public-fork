-- Filesystem operations Lua 5.1 cannot express. Arguments never pass through shell text.
-- No helper in this module communicates with Rex.
return function(rex)
  local F = {}
  local function sh(code, ...)
    local a = {"/bin/bash", "--noprofile", "--norc", "-c", "unset CDPATH; " .. code, "rex-orchestrator"}
    for _, v in ipairs({...}) do a[#a + 1] = v end
    local r = rex.exec(a)
    return r and r.ok, r and r.stdout or ""
  end
  function F.init(dir)
    return sh('[ -e "$1" ] || [ -L "$1" ] || (umask 077; mkdir -p "$1") 2>/dev/null; [ -d "$1" ] && [ ! -L "$1" ] && [ -O "$1" ]', dir)
  end
  function F.read(path)
    local f,err = io.open(path, "r")
    if not f then return nil,err end
    local s,why = f:read("*a"); f:close(); return s,why
  end
  function F.read_file(path)
    if not sh('[ -f "$1" ]',path) then return nil,"not_file" end
    return F.read(path)
  end
  function F.exists(path)
    return sh('[ -e "$1" ] || [ -L "$1" ]', path)
  end
  function F.put(path, text)
    local r = rex.exec({"/usr/bin/mktemp", path .. ".tmp.XXXXXX"})
    if not r or not r.ok then return false end
    local tmp = r.stdout:gsub("\n$", "")
    local f = io.open(tmp, "w")
    if not f then os.remove(tmp); return false end
    local ok = f:write(text); local closed = f:close()
    if ok and closed and os.rename(tmp, path) then return true end
    os.remove(tmp); return false
  end
  function F.remove(path) os.remove(path) end
  function F.unlink(path) return sh('rm -f -- "$1"',path) end
  function F.remove_state(path) return sh('rm -rf -- "$1" "$1".*',path) end
  function F.remove_tree(path) return sh('rm -rf -- "$1"',path) end
  function F.mkdir(path) return sh('mkdir -p -- "$1"',path) end
  function F.mkdir_new(path) return sh('mkdir -- "$1"',path) end
  function F.test(predicate,path) return sh('test "$1" "$2"',predicate,path) end
  function F.git()
    return F.test("-x","/opt/homebrew/bin/git") and "/opt/homebrew/bin/git" or "/usr/bin/git"
  end
  function F.chmod(mode,path) return sh('chmod -- "$1" "$2"',mode,path) end
  function F.private_temp(base,name)
    local ok,out=sh('[ -O "$1" ] && mktemp -d "$1/$2.XXXXXX"',base,name)
    return ok and out:gsub("\n$","") or nil
  end
  function F.executable(name)
    local ok,out=sh('type -P -- "$1"',name)
    return ok and out:gsub("\n+$","") or nil
  end
  -- Every executable NAME on PATH, in PATH order, each listed once.
  function F.executables(name)
    local ok,out=sh('type -a -P -- "$1"',name)
    local paths,seen={},{}
    if not ok then return paths end
    for path in out:gmatch("[^\n]+") do
      if not seen[path] then seen[path]=true; paths[#paths+1]=path end
    end
    return paths
  end
  -- An existing path as the disk spells it: links resolved, and each name in its on-disk case and Unicode form
  -- (pwd -P keeps the case it was typed in). nil if it doesn't exist.
  function F.ondisk(path)
    local ok,out=sh('[ -e "$1" ] && /bin/realpath -- "$1"',path)
    return ok and out:gsub("\n$","") or nil
  end
  -- The physical path of a file, every symlink resolved, the last component too.
  function F.realpath(path)
    local ok,out=sh('[ -f "$1" ] && /bin/realpath -- "$1"',path)
    return ok and out:gsub("\n$","") or nil
  end
  -- Where each symlink met while resolving PATH sits (its own physical location, not its target), in order, link by
  -- link and component by component, as the kernel walks it. nil if the path doesn't resolve.
  function F.link_locations(path)
    local ok,out=sh([=[
      p=$1 cur= n=0
      case $p in /*) ;; *) p=$PWD/$p ;; esac
      rest=$p
      while :; do
        while [ "${rest#/}" != "$rest" ]; do rest=${rest#/}; done
        [ -n "$rest" ] || break
        comp=${rest%%/*}
        if [ "$comp" = "$rest" ]; then rest=; else rest=${rest#*/}; fi
        case $comp in
          .) continue ;;
          ..) cur=${cur%/*}; continue ;;
        esac
        next=$cur/$comp
        if [ -L "$next" ]; then
          n=$((n + 1)); [ "$n" -le 64 ] || exit 1
          printf '%s\0' "$next"
          target=$(/usr/bin/readlink -- "$next" && printf .) || exit 1
          target=${target%.}; target=${target%?}
          case $target in /*) cur= ;; esac
          rest=$target${rest:+/$rest}
        else
          [ -e "$next" ] || exit 1
          cur=$next
        fi
      done
    ]=],path)
    if not ok then return nil end
    local links={}
    for link in out:gmatch("([^%z]+)%z") do links[#links+1]=link end
    return links
  end
  function F.claim_paths(directory)
    local ok,out=sh('for path in "$1"/*.json; do [ ! -f "$path" ] || printf "%s\\0" "$path" || exit 1; done',directory)
    if not ok then return nil end
    local paths={}
    for path in out:gmatch("([^%z]+)%z") do paths[#paths+1]=path end
    return paths
  end
  -- Every ownership record (*.own) in the state dir, and every file in its watch folder, from one listing.
  function F.own_paths(directory)
    local ok,out=sh([=[
      for path in "$1"/*.own; do [ ! -f "$path" ] || printf "o%s\0" "$path" || exit 1; done
      for path in "$1"/watch/*; do [ ! -f "$path" ] || printf "w%s\0" "$path" || exit 1; done
    ]=],directory)
    if not ok then return nil end
    local paths,watch={},{}
    for kind,path in out:gmatch("([ow])([^%z]+)%z") do
      if kind=="o" then paths[#paths+1]=path else watch[#watch+1]=path end
    end
    return paths,watch
  end
  -- Start ARGV as a daemon that holds LOCK for its whole life, or do nothing when another process holds it.
  -- TRIES attempts 0.1s apart (a watcher that is just exiting releases it). The daemon has its own session, no
  -- terminal and SIGHUP ignored, so it outlives the shell and the pane that started it; its output is appended to LOG.
  -- It runs from / with only what rex needs to reach its server and the tool's own settings in its environment.
  function F.daemon(lock,log,tries,argv)
    local args={"/usr/bin/perl","-e",[=[
      use Fcntl qw(:flock F_GETFD F_SETFD FD_CLOEXEC);
      use POSIX ();
      my ($lock,$log,$tries)=splice(@ARGV,0,3);
      umask 077;
      open(my $f,">>",$lock) or exit 3;
      my $held=0;
      for my $n (1..$tries) {
        if (flock($f,LOCK_EX|LOCK_NB)) { $held=1; last }
        select(undef,undef,undef,0.1) if $n<$tries;
      }
      exit 0 unless $held;
      my $pid=fork();
      exit 3 unless defined $pid;
      exit 0 if $pid;
      POSIX::setsid();
      $SIG{HUP}="IGNORE";
      chdir("/") or exit 3;
      my %keep=map { $_ => 1 } qw(HOME USER LOGNAME PATH TMPDIR LANG LC_ALL LC_CTYPE REX_SERVER REX_CONFIG
        XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_RUNTIME_DIR REX_ORCHESTRATOR_STATE_DIR
        REX_ORCHESTRATOR_REX_BIN_DIR REX_ORCHESTRATOR_ORPHANS REX_ORCHESTRATOR_ORPHAN_GRACE
        REX_ORCHESTRATOR_ORPHAN_MAX_WAIT);
      for my $name (keys %ENV) { delete $ENV{$name} unless $keep{$name} }
      fcntl($f,F_SETFD,fcntl($f,F_GETFD,0) & ~FD_CLOEXEC) or exit 3;
      open(STDIN,"<","/dev/null") or exit 3;
      open(STDOUT,">>",$log) or exit 3;
      open(STDERR,">&",\*STDOUT) or exit 3;
      exec {$ARGV[0]} @ARGV;
      exit 4;
    ]=],"--",lock,log,tostring(tries)}
    for _,v in ipairs(argv) do args[#args+1]=v end
    local h=rex.exec.start(args,{detach=true,stdout=false,stderr=false})
    return h~=nil
  end
  function F.append(path, text)
    return sh('(umask 077; printf "%s" "$2" >> "$1")', path, text)
  end
  function F.canonical(path)
    local ok, out = sh('cd -- "$1" 2>/dev/null && pwd -P', path)
    return ok and out:gsub("\n$", "") or nil
  end
  function F.logical(path)
    local ok,out=sh('cd -L -- "$1" 2>/dev/null && pwd -L',path)
    return ok and out:gsub("\n$","") or nil
  end
  function F.accounts(secrets)
    local _,out=sh([=[
      for f in "$1"/claude-*.env; do
        a=${f##*/}; a=${a#claude-}; a=${a%.env}
        case "$a" in ''|*[!a-z0-9]*) continue ;; esac
        [ ! -f "$f" ] || [ ! -r "$f" ] || printf '%s\n' "$a"
      done
    ]=],secrets)
    local accounts={}
    for account in out:gmatch("[^\n]+") do accounts[#accounts+1]=account end
    return accounts
  end
  function F.reserve_command(directory,path,text)
    local result=rex.exec({"/bin/bash","-p","-c",[=[
      umask 077
      [ ! -L "$1" ] && /bin/mkdir -p "$1" && [ -O "$1" ] && /bin/chmod 700 "$1" || exit 1
      set -C
      { /bin/cat || { /bin/rm -f "$2"; exit 1; }; } > "$2"
    ]=],"rex-orchestrator",directory,path},
      {stdin=text,env={BASH_ENV=false,ENV=false,REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD=false}})
    return result and result.ok
  end
  function F.real(path)
    local ok, out = sh([=[
      p=$1 rest=""
      [ ! -L "$p" ] || exit 1
      while [ ! -e "$p" ]; do
        [ ! -L "$p" ] || exit 1
        rest="/${p##*/}$rest"; p=$(dirname "$p")
      done
      [ -d "$p" ] || { rest="/${p##*/}$rest"; p=$(dirname "$p"); }
      p=$(cd "$p" && pwd -P) || exit 1
      printf '%s%s' "${p%/}" "$rest"
    ]=], path)
    return ok and out or nil
  end
  function F.plain(path)
    return sh('[ ! -e "$1" ] || { [ -f "$1" ] && [ "$(stat -f %l "$1")" = 1 ]; }', path)
  end
  function F.prefix(path, dir)
    return sh([=[
      top=${1%/*}
      while [ ! -e "$top" ] && [ ! -L "$top" ]; do top=$(dirname "$top"); done
      [ -d "$top" ] && [ ! -L "$top" ] && [ "$(cd "$top" && pwd -P)" = "$top" ] || exit 1
      case "$top/" in "$2"/*) ;; *) exit 1 ;; esac
      link=$(find "$top" -type l -print -quit 2>/dev/null) && [ -z "$link" ]
    ]=], path, dir)
  end
  function F.pid_alive(pid)
    return sh('kill -0 "$1" 2>/dev/null', tostring(pid))
  end
  -- Keep the same flock inode/protocol as Bash. The helper holds its lock until stdin
  -- closes; Rex also reaps it if the enclosing callback or CLI is interrupted.
  function F.lock(path,blocking)
    local tmp = rex.exec({"/usr/bin/mktemp", path .. ".ready.XXXXXX"})
    if not tmp or not tmp.ok then return nil, 1 end
    local ready = tmp.stdout:gsub("\n$", "")
    local h = rex.exec.start({"/usr/bin/perl", "-e", [=[
      use Fcntl qw(:flock);
      open(my $f, ">>", $ARGV[0]) or exit 3;
      flock($f, LOCK_EX | ($ARGV[2] ? 0 : LOCK_NB)) or exit 2;
      open(my $ready, ">", $ARGV[1]) or exit 3;
      print $ready "locked\n"; close($ready) or exit 3;
      my $buf; sysread(STDIN, $buf, 1);
    ]=], path, ready, blocking and "1" or "0"}, {stdin=true, stdout=false, stderr=false})
    if not h then os.remove(ready); return nil, 1 end
    -- Streaming callbacks wait for the enclosing Lua callback to return. A private
    -- receipt lets us observe acquisition while retaining the helper and its fd.
    local answer
    for _=1,blocking and 3000 or 1000 do
      answer=F.read(ready)
      if answer=="locked\n" or not h:running() then break end
      rex.sleep(0.01)
    end
    os.remove(ready)
    if answer=="locked\n" then
      return function() h:close_stdin(); h:wait() end
    end
    if h:running() then h:kill() end
    local r = h:wait(); return nil, r and r.code == 2 and 2 or 1
  end
  return F
end
