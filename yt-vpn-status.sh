#!/bin/sh
LAN_BRIDGE="br-lan"
WG_IF="wg-yt"
YT_SET="yt-vpn"
EXC_SET="yt-src-exclude"
RT_TABLE="wgroute"
FW_MARK="0x200"

hr() { echo "------------------------------------------------------------"; }
kv() { printf "%-32s %s\n" "$1" "$2"; }

echo
echo "YT-over-VPN Status (Router)"
hr
date
echo

# --- Router DNS listener ---
hr
echo "[DNS: Router listener]"
ROUTER_IP="$(ip -4 addr show "$LAN_BRIDGE" 2>/dev/null | awk '/inet /{sub("/.*","",$2); print $2; exit}')"
# Match the local listening socket regardless of ss column layout: the peer
# column is always 0.0.0.0:* so :53 only appears on the local address side.
DNS_LISTEN="$(ss -lunp 2>/dev/null | grep -E ':53([[:space:]]|$)' | head -n 5)"

# Functional test is authoritative; ss column layout varies by build.
if nslookup youtubei.googleapis.com "${ROUTER_IP:-127.0.0.1}" >/dev/null 2>&1; then
  kv "Router DNS resolves" "YES (via ${ROUTER_IP:-127.0.0.1})"
else
  kv "Router DNS resolves" "NO (query to ${ROUTER_IP:-127.0.0.1} failed)"
fi

if [ -n "$DNS_LISTEN" ]; then
  kv "Router UDP :53 listener" "YES"
  echo "$DNS_LISTEN" | sed 's/^/  /'
else
  kv "Router UDP :53 listener" "not detected via ss (functional test above is authoritative)"
fi

# --- dnsmasq UCI section name ---
DNSMASQ_SEC="$(uci show dhcp 2>/dev/null | awk -F= '/=dnsmasq$/{print $1; exit}')"
if [ -z "$DNSMASQ_SEC" ]; then
  hr
  echo "[dnsmasq]"
  echo "Could not find dnsmasq UCI section (dhcp.*=dnsmasq)."
  exit 1
fi

# --- dnsmasq upstreams + ipset rules ---
hr
echo "[dnsmasq config: $DNSMASQ_SEC]"
NORESOLV="$(uci -q get $DNSMASQ_SEC.noresolv)"
RESOLVFILE="$(uci -q get $DNSMASQ_SEC.resolvfile)"
SERVERS="$(uci show $DNSMASQ_SEC.server 2>/dev/null | sed -e "s/^$DNSMASQ_SEC.server=//")"
IPSET_RULES="$(uci show $DNSMASQ_SEC.ipset 2>/dev/null | sed -e "s/^$DNSMASQ_SEC.ipset=//")"

kv "noresolv" "${NORESOLV:-<unset>}"
kv "resolvfile" "${RESOLVFILE:-<unset>}"
kv "upstream server list" "${SERVERS:-<none>}"
kv "ipset domain rules" "${IPSET_RULES:-<none>}"

# --- ipset stats ---
hr
echo "[ipset]"
if ipset list "$YT_SET" >/dev/null 2>&1; then
  YT_CNT="$(ipset list "$YT_SET" | awk '/^Number of entries:/{print $4}')"
  kv "$YT_SET entries" "${YT_CNT:-0}"
  echo "Sample $YT_SET members:"
  ipset list "$YT_SET" | awk '/^Members:/{p=1;next} p{print "  "$0; c++; if(c>=10) exit}'
else
  kv "$YT_SET" "MISSING"
fi

if ipset list "$EXC_SET" >/dev/null 2>&1; then
  EXC_CNT="$(ipset list "$EXC_SET" | awk '/^Number of entries:/{print $4}')"
  kv "$EXC_SET entries" "${EXC_CNT:-0}"
  echo "Excluded IPs:"
  ipset list "$EXC_SET" | awk '/^Members:/{p=1;next} p{print "  "$0}'
else
  kv "$EXC_SET" "not present (ok if you don't use exclusions)"
fi

# --- PBR rules ---
hr
echo "[Policy routing]"
RULE_LINE="$(ip rule show | grep -E "fwmark $FW_MARK .*lookup $RT_TABLE" | head -n 1)"
if [ -n "$RULE_LINE" ]; then
  kv "ip rule fwmark -> $RT_TABLE" "PRESENT"
  echo "  $RULE_LINE"
else
  kv "ip rule fwmark -> $RT_TABLE" "MISSING"
fi

RT="$(ip route show table "$RT_TABLE" 2>/dev/null)"
if [ -n "$RT" ]; then
  kv "route table $RT_TABLE" "PRESENT"
  echo "$RT" | sed 's/^/  /'
else
  kv "route table $RT_TABLE" "MISSING/EMPTY"
fi

# --- iptables rules ---
hr
echo "[iptables]"
echo "Mangle PREROUTING:"
iptables -t mangle -L PREROUTING -n -v --line-numbers 2>/dev/null | sed 's/^/  /'

echo
echo "NAT POSTROUTING:"
iptables -t nat -L POSTROUTING -n -v --line-numbers 2>/dev/null | sed 's/^/  /'

echo
echo "FORWARD chain:"
iptables -L FORWARD -n -v --line-numbers 2>/dev/null | sed 's/^/  /'

# --- WireGuard status ---
hr
echo "[WireGuard: $WG_IF]"
if wg show "$WG_IF" >/dev/null 2>&1; then
  wg show "$WG_IF" | sed 's/^/  /'
  echo
  WG_HS="$(wg show "$WG_IF" 2>/dev/null | awk '/latest handshake:/{print "yes"}')"
  if [ -n "$WG_HS" ]; then
    kv "handshake" "YES"
  else
    kv "handshake" "NO (tunnel not up / wrong keys / server down)"
  fi
else
  kv "$WG_IF" "MISSING"
fi

# --- Quick hints ---
hr
echo "[Hints]"
# dnsmasq ipset present?
echo "$IPSET_RULES" | grep -q "$YT_SET" && kv "dnsmasq->ipset" "OK" || kv "dnsmasq->ipset" "WARN (ipset rules missing)"
# yt-vpn entries
if [ "${YT_CNT:-0}" -gt 0 ] 2>/dev/null; then
  kv "yt-vpn entries" "OK"
else
  kv "yt-vpn entries" "WARN (empty)"
fi
# pbr rule
[ -n "$RULE_LINE" ] && kv "fwmark routing" "OK" || kv "fwmark routing" "WARN (no ip rule)"
# wg handshake
[ -n "$WG_HS" ] && kv "wg handshake" "OK" || kv "wg handshake" "WARN"
echo
