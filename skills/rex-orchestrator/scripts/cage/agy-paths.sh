# shellcheck shell=bash
# Shared by the launcher and the generated agy wrapper. 0 means overlap, 1 disjoint, 2 inspection failed.
agy_directory_id() { /usr/bin/stat -Lf '%d:%i' "$1"; }

agy_physical_ancestor() (
  local wanted=$1 current previous=
  cd -P -- "$2" || exit 2
  current=$(agy_directory_id .) || exit 2
  [ "$current" = "$3" ] || exit 2
  while :; do
    [ "$current" != "$wanted" ] || exit 0
    [ "$current" != "$previous" ] || exit 1
    previous=$current
    cd -P -- .. || exit 2
    current=$(agy_directory_id .) || exit 2
  done
)

agy_logical_ancestor() {
  local wanted=$1 path=$2 current
  # Check named parents because a symlink within one of them can lead out of that tree.
  while :; do
    current=$(agy_directory_id "$path") || return 2
    [ "$current" != "$wanted" ] || return 0
    [ "$path" != / ] || return 1
    path=${path%/*}
    path=${path:-/}
  done
}

agy_home_overlap() {
  local login_id task_id rc=0
  login_id=$(agy_directory_id "$1") && task_id=$(agy_directory_id "$2") || return 2
  agy_physical_ancestor "$login_id" "$2" "$task_id" || rc=$?
  [ "$rc" -eq 1 ] || return "$rc"
  rc=0; agy_physical_ancestor "$task_id" "$1" "$login_id" || rc=$?
  [ "$rc" -eq 1 ] || return "$rc"
  if [ -n "${3:-}" ]; then
    rc=0; agy_logical_ancestor "$task_id" "$3" || rc=$?
    [ "$rc" -eq 1 ] || return "$rc"
  fi
  [ -n "${4:-}" ] || return 1
  agy_logical_ancestor "$login_id" "$4"
}
