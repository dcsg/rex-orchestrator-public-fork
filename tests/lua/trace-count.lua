-- Count external command launches, not Bash's command-substitution forks.
local n=1 -- invoking Bash itself
local external={dirname=true,readlink=true,mkdir=true,awk=true,tail=true,sed=true,rm=true,
  mv=true,grep=true,tr=true,date=true,sleep=true,stat=true,find=true,shasum=true}
for line in io.lines(arg[1]) do
  local command=line:match("^%++ ([^ ]+)")
  if command and (command:sub(1,1)=="/" or external[command]) then n=n+1 end
end
for line in io.lines(arg[2]) do
  if line:match("^LUA_EXEC ") then n=n+1 end
end
print(n)
