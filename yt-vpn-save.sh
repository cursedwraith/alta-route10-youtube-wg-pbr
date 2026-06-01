#!/bin/sh
OUT="/cfg/yt-vpn.backup"

if ! ipset list yt-vpn >/dev/null 2>&1; then
  echo "[ERROR] yt-vpn does not exist."
  exit 1
fi

ipset save yt-vpn > "$OUT"
echo "[INFO] Saved yt-vpn to $OUT"
ipset list yt-vpn | awk '/^Number of entries:/{print "[INFO] Entries: " $4}'
