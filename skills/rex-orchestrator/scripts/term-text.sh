# shellcheck shell=bash
# rex_term_text TEXT [keep]: print TEXT for a terminal exactly as core.lua's M.terminal_text does, so a byte sequence
# looks the same whichever side prints it. C0 controls, DEL and C1 bytes outside a valid UTF-8 character, and every
# byte of invalid UTF-8, show as \xNN; the UTF-8 C1 controls (U+0080-U+009F) and the bidi overrides and isolates
# (U+202A-U+202E, U+2066-U+2069) as \uNNNN; a backslash as \\. With "keep", backslashes stay single: for text Lua
# already escaped, such as the diagnostics the CLI forwards. Pure Bash 3.2, in the byte locale, inside a subshell.
# shellcheck disable=SC2030 # The byte locale is meant to stay in this subshell.
rex_term_text() (
  export LC_ALL=C
  s=$1 keep=${2:-}
  # Printable ASCII alone needs no work; a backslash does unless it is kept.
  case $s in
    *[![:print:]]*) ;;
    *\\*) [ "$keep" = keep ] && { printf '%s' "$s"; exit 0; } ;;
    *) printf '%s' "$s"; exit 0 ;;
  esac
  n=${#s} i=0
  while [ "$i" -lt "$n" ]; do
    printf -v b '%d' "'${s:i:1}"
    eval "b$i=$((b & 255))"
    i=$((i + 1))
  done
  at() { if [ "$1" -lt "$n" ]; then eval "printf '%s' \"\$b$1\""; else printf '%s' -1; fi; }
  cont() { [ "$1" -ge 128 ] && [ "$1" -le 191 ]; }
  out='' i=0
  while [ "$i" -lt "$n" ]; do
    a=$(at "$i") width=1 code='' invalid=''
    if [ "$a" -lt 32 ] || { [ "$a" -ge 127 ] && [ "$a" -le 159 ]; }; then
      code=$a
    elif [ "$a" -ge 128 ]; then
      b=$(at $((i + 1))) c=$(at $((i + 2))) d=$(at $((i + 3))) width=''
      if cont "$b"; then
        if [ "$a" -ge 194 ] && [ "$a" -le 223 ]; then width=2
        elif cont "$c"; then
          if [ "$a" -ge 224 ] && [ "$a" -le 239 ] && { [ "$a" -ne 224 ] || [ "$b" -ge 160 ]; } &&
            { [ "$a" -ne 237 ] || [ "$b" -lt 160 ]; }; then width=3
          elif [ "$a" -ge 240 ] && [ "$a" -le 244 ] && cont "$d" && { [ "$a" -ne 240 ] || [ "$b" -ge 144 ]; } &&
            { [ "$a" -ne 244 ] || [ "$b" -le 143 ]; }; then width=4
          fi
        fi
      fi
      if [ -z "$width" ]; then width=1 invalid=$a
      elif [ "$a" -eq 194 ] && [ "$b" -le 159 ]; then code=$b
      elif [ "$width" -eq 3 ] && [ "$a" -eq 226 ]; then
        if [ "$b" -eq 128 ] && [ "$c" -ge 170 ] && [ "$c" -le 174 ]; then code=$((0x202a + c - 170))
        elif [ "$b" -eq 129 ] && [ "$c" -ge 166 ] && [ "$c" -le 169 ]; then code=$((0x2066 + c - 166)); fi
      fi
    fi
    if [ -n "$code$invalid" ]; then
      if [ "$width" -eq 1 ]; then out=$out$(printf '\\x%02X' "${code:-$invalid}")
      else out=$out$(printf '\\u%04X' "$code"); fi
    elif [ "$a" -eq 92 ] && [ "$keep" != keep ]; then out="$out\\\\"
    else out=$out${s:i:width}
    fi
    i=$((i + width))
  done
  printf '%s' "$out"
)
