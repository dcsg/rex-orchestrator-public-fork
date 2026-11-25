-- Local operations for commands that cannot depend on a live Rex server.
local ffi=require("ffi")
local bit=require("bit")
ffi.cdef[[
  int open(const char *, int, ...);
  int openat(int, const char *, int, ...);
  int close(int);
  int flock(int, int);
  int mkstemp(char *);
  int usleep(unsigned int);
  int umask(int);
  long read(int, void *, unsigned long);
  long write(int, const void *, unsigned long);
  char *strerror(int);
  void *dlsym(void *, const char *);
  struct rex_timeval { long sec; int usec; };
  int gettimeofday(struct rex_timeval *, void *);
  struct rex_stat {
    int dev; unsigned short mode, nlink; uint64_t inode;
    unsigned int uid, gid; int rdev;
    long times[8];
    int64_t size, blocks;
    int blksize; unsigned int flags, gen; int spare;
    int64_t quad_spare[2];
  };
]]
local libc=ffi.C
local native={}
local function os_error() return ffi.string(libc.strerror(ffi.errno())) end
local function quote(text) return "'" .. text:gsub("'","'\\''") .. "'" end
local O_WRONLY,O_NONBLOCK,O_NOFOLLOW,O_CREAT,O_EXCL=1,4,0x100,0x200,0x800
local O_DIRECTORY,O_CLOEXEC,O_NOFOLLOW_ANY=0x100000,0x1000000,0x20000000
local mode600=ffi.new("int",384)
local AT_FDCWD=-2

-- Darwin uses the separate INODE64 entry point on Intel.
local stat_symbol=ffi.arch=="x64" and "fstat$INODE64" or "fstat"
local stat_address=libc.dlsym(ffi.cast("void *",-2),stat_symbol)
local stat=ffi.cast("int (*)(int, struct rex_stat *)",stat_address)

function native.exec(argv)
  local command={}
  for i,value in ipairs(argv) do command[i]=quote(value) end
  local template=(os.getenv("TMPDIR") or "/tmp"):gsub("/$","") .. "/rex-orchestrator-stderr.XXXXXX"
  local tempfile=ffi.new("char[?]",#template+1,template)
  local fd=libc.mkstemp(tempfile)
  if fd<0 then return {ok=false,code=1,stdout="",stderr=os_error()} end
  libc.close(fd)
  local path=ffi.string(tempfile)
  local proc=io.popen(table.concat(command," ") .. " 2>" .. quote(path) .. [[; printf '\036%s\n' "$?"]])
  if not proc then os.remove(path); return {ok=false,code=1,stdout="",stderr=""} end
  local output=proc:read("*a") or ""
  proc:close()
  local errfile=io.open(path,"rb")
  os.remove(path)
  local stderr=""
  if errfile then stderr=errfile:read("*a") or ""; errfile:close() end
  local data,code=output:match("^(.*)\30(%d+)\n$")
  return {ok=code=="0",code=tonumber(code) or 1,stdout=data or output,stderr=stderr}
end

function native.lock(path)
  local fd=libc.open(path,O_WRONLY+O_CREAT+O_NOFOLLOW+O_NONBLOCK+O_CLOEXEC,mode600)
  if fd<0 then return nil end
  for _=1,3000 do
    if libc.flock(fd,2+4)==0 then return function() libc.close(fd) end end
    if ffi.errno()~=35 then break end
    libc.usleep(10000)
  end
  libc.close(fd)
end

function native.now()
  local time=ffi.new("struct rex_timeval[1]")
  assert(libc.gettimeofday(time,nil)==0)
  return tonumber(time[0].sec),tonumber(time[0].usec)
end

-- The cage root must be physical. Relative reads beneath its descriptor reject
-- all symlink components, including any swapped in since find listed the path.
function native.open_dir(path)
  if ffi.os~="OSX" then return nil,"secure archive reads require macOS" end
  local fd=libc.open(path,O_DIRECTORY+O_NOFOLLOW_ANY+O_CLOEXEC)
  if fd<0 then return nil,os_error() end
  return fd
end

function native.open_regular(dir,path)
  if ffi.os~="OSX" then return nil,"secure file reads require macOS" end
  local fd=libc.openat(dir or AT_FDCWD,path,O_NOFOLLOW_ANY+O_NONBLOCK+O_CLOEXEC)
  if fd<0 then return nil,os_error() end
  local info=ffi.new("struct rex_stat[1]")
  if stat_address==nil or stat(fd,info)<0 or bit.band(info[0].mode,0xf000)~=0x8000 or info[0].nlink~=1 then
    libc.close(fd)
    return nil,"expected a regular file with one link"
  end
  return fd
end

local function transfer(fd,sink)
  local buffer=ffi.new("uint8_t[65536]")
  local total=0
  while true do
    local size=tonumber(libc.read(fd,buffer,65536))
    if size==0 then return total end
    if size<0 then
      if ffi.errno()~=4 then return nil,os_error() end
    else
      local good,err=sink(buffer,size)
      if not good then return nil,err end
      total=total+size
    end
  end
end

function native.read(dir,path)
  local fd,err=native.open_regular(dir,path)
  if not fd then return nil,err end
  local pieces={}
  local size,why=transfer(fd,function(buf,n) pieces[#pieces+1]=ffi.string(buf,n); return true end)
  libc.close(fd)
  if not size then return nil,why end
  return table.concat(pieces)
end

function native.copy(dir,path,target)
  local source,err=native.open_regular(dir,path)
  if not source then return nil,err end
  local dest=libc.open(target,O_WRONLY+O_CREAT+O_EXCL+O_NOFOLLOW_ANY+O_CLOEXEC,mode600)
  if dest<0 then
    local why=os_error()
    libc.close(source)
    return nil,why
  end
  local size,why=transfer(source,function(buf,n)
    local offset=0
    repeat
      local written=tonumber(libc.write(dest,buf+offset,n-offset))
      if written>0 then offset=offset+written
      elseif written==0 or ffi.errno()~=4 then return nil,os_error() end
    until offset==n
    return true
  end)
  libc.close(source)
  if libc.close(dest)~=0 and size then size,why=nil,os_error() end
  if not size then os.remove(target) end
  return size,why
end

native.close=libc.close
function native.private_umask() libc.umask(63) end
return native
