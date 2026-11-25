# shellcheck shell=bash disable=SC2154
# Each case owns its private server, socket, configuration and input markers.
export REX_LUA_BINDING_FIXTURE="$T/bindings" REX_ORCHESTRATOR_STATE_DIR="$T/mutation-disconnect-state"
mkdir -p "$REX_LUA_BINDING_FIXTURE" "$REX_ORCHESTRATOR_STATE_DIR"
cat > "$T/bindings.lua" <<'LUA'
local directory=os.getenv("REX_LUA_BINDING_FIXTURE")
rex.bind("tab",function()
  local f=assert(io.open(directory .. "/tab","a"))
  f:write("tab\n"); f:close()
  return true
end)
for _,key in ipairs({"enter","up"}) do
  rex.bind(key,function()
    local f=assert(io.open(directory .. "/" .. key,"w"))
    f:write(key .. "\n"); f:close()
    rex.exec({"/bin/sleep","3"})
    return true
  end)
end
LUA
for verb in keys send; do
  export REX_SERVER="unix://$T/$verb.sock" REX_CONFIG="$T/bindings.lua"
  "$REAL_REX" --autostart=false server run --listen "$REX_SERVER" --state-dir "$T/server-$verb" \
    --restore=false --config "$REX_CONFIG" > "$T/server-$verb.log" 2>&1 &
  server_pid=$!
  for ((n=0;n<100;n++)); do [ ! -S "$T/$verb.sock" ] || break; sleep 0.05; done
  [ -S "$T/$verb.sock" ]
  rex_test session new "test-$verb" --shell none --keep-open --json -- \
    /bin/bash "$ROOT/tests/lua/standin.sh" "$T/work" > "$T/session.json"
  REX_SESSION=$(jq -r .session_id "$T/session.json")
  B=$(jq -r '.initial_windows[0].block_ids[0]' "$T/session.json")
  pid=$(rex_test block call -s "$REX_SESSION" -b "$B" process | jq -r .child.pid)
  sf="$REX_ORCHESTRATOR_STATE_DIR/${B//[^A-Za-z0-9_-]/_}"
  printf '%s\n' "$REX_BLOCK" "$pid" '' claude "$T/work" '⏸ manual mode on' /bin/bash > "$sf.own"
  type_line composer; await_state idle
  if [ "$verb" = keys ]; then
    cli keys "$B" tab
    rex_test send-key -s "$REX_SESSION" -b "$B" tab
    check 'native and CLI keys both run the configured binding' "$(wc -l < "$REX_LUA_BINDING_FIXTURE/tab" | tr -d ' ')" 2
    args=(keys "$B" up)
    armed="$REX_LUA_BINDING_FIXTURE/up"
  else
    args=(send "$B" fixture-prompt)
    armed="$REX_LUA_BINDING_FIXTURE/enter"
  fi
  cli "${args[@]}" > "$T/wait.out" 2> "$T/wait.err" &
  # shellcheck disable=SC2034 # Read by prompt_wait in live.sh.
  wait_pid=$!
  for ((n=0;n<180;n++)); do [ ! -s "$armed" ] || break; sleep 0.03; done
  [ -s "$armed" ] || { cat "$T/wait.err" >&2; echo "$verb did not reach the binding" >&2; exit 1; }
  kill -KILL "$server_pid"; wait "$server_pid" 2>/dev/null || :
  server_pid=''
  code=0; prompt_wait || code=$?
  check "Rex disappears during $verb" "$code:$(cat "$T/wait.out")" '1:'
done
