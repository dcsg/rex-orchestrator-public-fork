# shellcheck shell=bash
# rex_term_text TEXT: print TEXT for a terminal exactly as core.lua's M.terminal_text does, so a byte sequence looks
# the same whichever side prints it. C0 controls, DEL and C1 bytes outside a valid UTF-8 character, and every byte of
# invalid UTF-8, show as \xNN; the UTF-8 C1 controls (U+0080-U+009F) and the bidi overrides and isolates
# (U+202A-U+202E, U+2066-U+2069) as \uNNNN; a backslash as \\.
# Pure Bash 3.2 in the byte locale, inside one subshell, with no further forks: bytes come from printf -v and output
# grows by appending, so a long line costs a scan, not a process per byte.
# shellcheck disable=SC2030 # The byte locale is meant to stay in this subshell.
rex_term_text() (
  export LC_ALL=C
  s=$1
  # Printable ASCII without a backslash needs no work.
  case $s in
    *[![:print:]]* | *\\*) ;;
    *) printf '%s' "$s"; exit 0 ;;
  esac
  # Work through the text 512 bytes at a time, with 3 bytes of lookahead for a UTF-8 sequence that crosses the
  # boundary: indexing one long string per byte would cost quadratic time, and so would keeping a variable or array
  # entry per byte in Bash 3.2. Output goes out in pieces of about 4 KB, so appending stays cheap.
  rest=$s out='' hex=''
  while [ -n "$rest" ]; do
    chunk=${rest:0:515} m=${#chunk} k=0 stop=512
    ((m > 512)) || stop=$m
    while ((k < stop)); do
      printf -v a '%d' "'${chunk:k:1}"; a=$((a & 255))
      width=1 code=-1 invalid=-1
      if ((a < 32 || (a >= 127 && a <= 159))); then
        code=$a
      elif ((a >= 128)); then
        # Read each lookahead byte only when the lead byte needs it.
        b=-1 c=-1 d=-1 width=0
        if ((k + 1 < m)); then printf -v b '%d' "'${chunk:k+1:1}"; b=$((b & 255)); fi
        if ((a >= 224 && b >= 128 && b <= 191 && k + 2 < m)); then printf -v c '%d' "'${chunk:k+2:1}"; c=$((c & 255)); fi
        if ((a >= 240 && c >= 128 && c <= 191 && k + 3 < m)); then printf -v d '%d' "'${chunk:k+3:1}"; d=$((d & 255)); fi
        if ((b >= 128 && b <= 191)); then
          if ((a >= 194 && a <= 223)); then width=2
          elif ((c >= 128 && c <= 191)); then
            if ((a >= 224 && a <= 239 && (a != 224 || b >= 160) && (a != 237 || b < 160))); then width=3
            elif ((a >= 240 && a <= 244 && d >= 128 && d <= 191 && (a != 240 || b >= 144) && (a != 244 || b <= 143)))
            then width=4
            fi
          fi
        fi
        if ((width == 0)); then width=1 invalid=$a
        elif ((a == 194 && b <= 159)); then code=$b
        elif ((width == 3 && a == 226 && b == 128 && c >= 170 && c <= 174)); then code=$((0x202a + c - 170))
        elif ((width == 3 && a == 226 && b == 129 && c >= 166 && c <= 169)); then code=$((0x2066 + c - 166))
        fi
      fi
      if ((code >= 0 || invalid >= 0)); then
        if ((width == 1)); then printf -v hex '\\x%02X' $((code >= 0 ? code : invalid))
        else printf -v hex '\\u%04X' "$code"; fi
        out=$out$hex
      elif ((a == 92)); then out="$out\\\\"
      else out=$out${chunk:k:width}
      fi
      k=$((k + width))
    done
    rest=${rest:k}
    if ((${#out} >= 4096)); then printf '%s' "$out"; out=''; fi
  done
  printf '%s' "$out"
)
