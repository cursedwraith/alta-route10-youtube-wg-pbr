#!/bin/sh
IN="/cfg/yt-vpn.backup"

if [ ! -f "$IN" ]; then
  echo "[ERROR] Backup file not found: $IN"
  exit 1
fi

# Ensure set exists
ipset create yt-vpn hash:ip maxelem 65536 -exist

# Merge saved entries into current set
grep '^add yt-vpn ' "$IN" | while read -r _ _ ip; do
  ipset add yt-vpn "$ip" -exist
done

echo "[INFO] Restored yt-vpn entries from $IN"
ipset list yt-vpn | awk '/^Number of entries:/{print "[INFO] Entries now: " $4}'
