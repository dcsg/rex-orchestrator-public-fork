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
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a"); f:close(); return s
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
  function F.append(path, text)
    return sh('(umask 077; printf "%s" "$2" >> "$1")', path, text)
  end
  function F.canonical(path)
    local ok, out = sh('cd -- "$1" 2>/dev/null && pwd -P', path)
    return ok and out:gsub("\n$", "") or nil
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
