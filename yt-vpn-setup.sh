#!/bin/sh
# yt-vpn-setup.sh
# Rebuilds YouTube-over-VPN on Alta/OpenWrt-style routers.

set -eu
umask 077

### ===== CONFIG: EDIT THESE =====
WG_PRIVKEY=""
WG_PSK=""                      # leave empty if unused
WG_ADDR=""                     # e.g. 100.68.101.47/32
WG_SERVER_PUBKEY=""
WG_ENDPOINT_HOST=""
WG_ENDPOINT_PORT=""

TECHNITIUM_IP=""
LAN_BRIDGE="br-lan"
WG_IF="wg-yt"
ROUTER_DNS_IP=""               # router LAN DNS IP; auto-detected from LAN_BRIDGE if empty

WG_MTU="1380"
WG_KEEPALIVE="25"

RT_TABLE_NAME="wgroute"
RT_TABLE_ID="200"
RULE_PRIORITY="200"            # ip rule priority for the fwmark policy rule
FWMARK="0x200"

YT_SET="yt-vpn"
EXCLUDE_SET="yt-src-exclude"

YT_BACKUP_FILE="/cfg/yt-vpn.backup"
EXCLUDE_FILE="/cfg/yt-src-exclude.list"   # optional, one IPv4 per line

FWU_BEGIN="# --- YT_VPN_WG_YT_SETUP BEGIN ---"
FWU_END="# --- YT_VPN_WG_YT_SETUP END ---"
### ==============================

info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
err()  { echo "[ERROR] $*" >&2; }
die()  { err "$*"; exit 1; }

need_root() {
  [ "$(id -u)" = "0" ] || die "Run as root."
}

check_deps() {
  for cmd in ipset iptables wg uci awk; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
  done

  modprobe wireguard 2>/dev/null || true
  if [ ! -d /sys/module/wireguard ] && ! grep -qw wireguard /proc/modules 2>/dev/null; then
    if ip link add dev wgprobe$$ type wireguard 2>/dev/null; then
      ip link del wgprobe$$ 2>/dev/null || true
    else
      die "WireGuard kernel support not available (modprobe wireguard failed)."
    fi
  fi

  # dnsmasq must be built with ipset support (dnsmasq-full); plain dnsmasq
  # silently ignores the ipset= directive and yt-vpn never populates.
  if dnsmasq --version 2>/dev/null | grep -qi 'no-ipset'; then
    die "Installed dnsmasq lacks ipset support (need dnsmasq-full)."
  fi
}

detect_router_ip() {
  ip -4 addr show "$LAN_BRIDGE" 2>/dev/null | awk '/inet /{sub("/.*","",$2); print $2; exit}'
}

find_dnsmasq_section() {
  uci show dhcp 2>/dev/null | awk -F= '/=dnsmasq$/{print $1; exit}'
}

validate_ipv4() {
  echo "$1" | awk -F. '
    NF!=4 {exit 1}
    {
      for(i=1;i<=4;i++) {
        if($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1
      }
    }
    END{exit 0}'
}

validate_cidr() {
  local addr mask
  case "$1" in
    */*)
      addr=${1%/*}
      mask=${1#*/}
      ;;
    *)
      return 1
      ;;
  esac
  validate_ipv4 "$addr" || return 1
  echo "$mask" | awk 'BEGIN{ok=0} /^[0-9]+$/ && $1>=0 && $1<=32 {ok=1} END{exit ok?0:1}'
}

validate_port() {
  echo "$1" | awk 'BEGIN{ok=0} /^[0-9]+$/ && $1>=1 && $1<=65535 {ok=1} END{exit ok?0:1}'
}

status_dns() {
  local router_ip
  router_ip="${ROUTER_DNS_IP:-$(detect_router_ip)}"
  if [ -n "$router_ip" ] && nslookup youtubei.googleapis.com "$router_ip" >/dev/null 2>&1; then
    echo "YES (query to $router_ip succeeded)"
  elif nslookup youtubei.googleapis.com 127.0.0.1 >/dev/null 2>&1; then
    echo "YES (query to 127.0.0.1 succeeded)"
  else
    echo "NO (query failed)"
  fi
}

status_mangle() {
  if iptables -t mangle -C PREROUTING -i "$LAN_BRIDGE" \
      -m set --match-set "$EXCLUDE_SET" src \
      -m set --match-set "$YT_SET" dst -j RETURN 2>/dev/null; then
    echo "PRESENT (RETURN+MARK mode)"
    return
  fi

  if iptables -t mangle -C PREROUTING -i "$LAN_BRIDGE" \
      -m set --match-set "$YT_SET" dst -j MARK --set-mark "$FWMARK" 2>/dev/null; then
    echo "PRESENT (MARK mode)"
    return
  fi

  echo "MISSING"
}

print_status() {
  DNS_STATUS="$(status_dns)"

  if ip link show "$WG_IF" >/dev/null 2>&1; then WG_IF_OK="PRESENT"; else WG_IF_OK="MISSING"; fi
  if wg show "$WG_IF" 2>/dev/null | grep -q 'latest handshake:'; then WG_HS_OK="OK (seen)"; else WG_HS_OK="NOT SEEN"; fi
  if ip rule show | grep -q "fwmark $FWMARK lookup $RT_TABLE_NAME"; then RULE_OK="PRESENT"; else RULE_OK="MISSING"; fi
  if ip route show table "$RT_TABLE_NAME" 2>/dev/null | grep -q "default dev $WG_IF"; then RT_OK="PRESENT"; else RT_OK="MISSING"; fi
  if uci show "$DNSMASQ_SECTION".ipset 2>/dev/null | grep -q "$YT_SET"; then DNS_IPSET_OK="PRESENT"; else DNS_IPSET_OK="MISSING"; fi
  if grep -q "$FWU_BEGIN" /etc/firewall.user 2>/dev/null; then FWU_OK="PRESENT"; else FWU_OK="MISSING"; fi

  if ipset list "$YT_SET" >/dev/null 2>&1; then
    YT_COUNT="$(ipset list "$YT_SET" | awk '/^Number of entries:/{print $4}')"
    [ -n "$YT_COUNT" ] || YT_COUNT=0
  else
    YT_COUNT="MISSING"
  fi

  echo "================ YT-over-VPN STATUS ================"
  printf "%-34s %s\n" "Router DNS listener:" "$DNS_STATUS"
  printf "%-34s %s\n" "WireGuard interface $WG_IF:" "$WG_IF_OK"
  printf "%-34s %s\n" "WireGuard handshake:" "$WG_HS_OK"
  printf "%-34s %s\n" "ip rule fwmark -> $RT_TABLE_NAME:" "$RULE_OK"
  printf "%-34s %s\n" "Routing table $RT_TABLE_NAME:" "$RT_OK"
  printf "%-34s %s\n" "Mangle PREROUTING:" "$(status_mangle)"
  printf "%-34s %s\n" "dnsmasq ipset config:" "$DNS_IPSET_OK"
  printf "%-34s %s\n" "$YT_SET entries:" "$YT_COUNT"
  printf "%-34s %s\n" "/etc/firewall.user block:" "$FWU_OK"
  echo "===================================================="
}

is_configured() {
  ip link show "$WG_IF" >/dev/null 2>&1 || return 1
  ip rule show | grep -q "fwmark $FWMARK lookup $RT_TABLE_NAME" || return 1
  ip route show table "$RT_TABLE_NAME" 2>/dev/null | grep -q "default dev $WG_IF" || return 1
  uci show "$DNSMASQ_SECTION".ipset 2>/dev/null | grep -q "$YT_SET" || return 1
  grep -q "$FWU_BEGIN" /etc/firewall.user 2>/dev/null || return 1
  return 0
}

save_current_cache() {
  local cnt
  ipset list "$YT_SET" >/dev/null 2>&1 || return 0
  cnt="$(ipset list "$YT_SET" | awk '/^Number of entries:/{print $4}')"
  # Don't overwrite a good backup with an empty/flushed set.
  [ "${cnt:-0}" -gt 0 ] 2>/dev/null || return 0
  ipset save "$YT_SET" > "$YT_BACKUP_FILE" || true
}

restore_cache() {
  [ -f "$YT_BACKUP_FILE" ] || return 0
  ipset create "$YT_SET" hash:ip maxelem 65536 -exist
  # Fast path: ipset restore consumes the `ipset save` format directly.
  # -! tolerates the existing set/entries; fall back to a per-entry loop
  # if the dump format is rejected.
  if ! ipset restore -! < "$YT_BACKUP_FILE" 2>/dev/null; then
    grep '^add '"$YT_SET"' ' "$YT_BACKUP_FILE" | while read _ _ ip; do
      ipset add "$YT_SET" "$ip" -exist
    done
  fi
}

ensure_rt_table() {
  grep -q "^$RT_TABLE_ID[[:space:]]\+$RT_TABLE_NAME$" /etc/iproute2/rt_tables 2>/dev/null || \
    echo "$RT_TABLE_ID $RT_TABLE_NAME" >> /etc/iproute2/rt_tables
}

ensure_ipsets() {
  # Create the sets up front so dnsmasq has somewhere to add resolved IPs as
  # soon as it restarts; firewall.user re-creates them with -exist on boot.
  ipset create "$YT_SET" hash:ip maxelem 65536 -exist
  ipset create "$EXCLUDE_SET" hash:ip maxelem 128 -exist
}

ensure_wg() {
  [ -n "$WG_PRIVKEY" ] || die "WG_PRIVKEY is empty."
  [ -n "$WG_SERVER_PUBKEY" ] || die "WG_SERVER_PUBKEY is empty."
  [ -n "$WG_ENDPOINT_HOST" ] || die "WG_ENDPOINT_HOST is empty."
  validate_cidr "$WG_ADDR" || die "WG_ADDR is invalid: $WG_ADDR"
  validate_port "$WG_ENDPOINT_PORT" || die "WG_ENDPOINT_PORT is invalid: $WG_ENDPOINT_PORT"

  mkdir -p /cfg
  printf '%s\n' "$WG_PRIVKEY" > /cfg/wg-yt.key
  chmod 600 /cfg/wg-yt.key

  if [ -n "$WG_PSK" ]; then
    printf '%s\n' "$WG_PSK" > /cfg/wg-yt.psk
    chmod 600 /cfg/wg-yt.psk
  else
    rm -f /cfg/wg-yt.psk
  fi

  ip link del "$WG_IF" 2>/dev/null || true
  modprobe wireguard 2>/dev/null || true
  ip link add dev "$WG_IF" type wireguard

  if [ -n "$WG_PSK" ]; then
    wg set "$WG_IF" \
      private-key /cfg/wg-yt.key \
      peer "$WG_SERVER_PUBKEY" \
      preshared-key /cfg/wg-yt.psk \
      endpoint "$WG_ENDPOINT_HOST:$WG_ENDPOINT_PORT" \
      allowed-ips 0.0.0.0/0
  else
    wg set "$WG_IF" \
      private-key /cfg/wg-yt.key \
      peer "$WG_SERVER_PUBKEY" \
      endpoint "$WG_ENDPOINT_HOST:$WG_ENDPOINT_PORT" \
      allowed-ips 0.0.0.0/0
  fi

  ip addr flush dev "$WG_IF"
  ip addr add "$WG_ADDR" dev "$WG_IF"
  ip link set dev "$WG_IF" mtu "$WG_MTU"
  ip link set up dev "$WG_IF"
  wg set "$WG_IF" peer "$WG_SERVER_PUBKEY" persistent-keepalive "$WG_KEEPALIVE"
}

ensure_dnsmasq_config() {
  validate_ipv4 "$TECHNITIUM_IP" || die "TECHNITIUM_IP is invalid: $TECHNITIUM_IP"

  uci set "$DNSMASQ_SECTION".noresolv='1'
  uci del "$DNSMASQ_SECTION".server 2>/dev/null || true
  uci add_list "$DNSMASQ_SECTION".server="$TECHNITIUM_IP"

  uci del "$DNSMASQ_SECTION".ipset 2>/dev/null || true
  uci add_list "$DNSMASQ_SECTION".ipset='/googlevideo.com/yt-vpn'
  uci add_list "$DNSMASQ_SECTION".ipset='/youtubei.googleapis.com/yt-vpn'

  uci commit dhcp
  /etc/init.d/dnsmasq restart
}

render_firewall_block() {
  cat <<EOF
$FWU_BEGIN
ipset create $YT_SET hash:ip maxelem 65536 -exist
ipset create $EXCLUDE_SET hash:ip maxelem 128 -exist

if [ -f "$EXCLUDE_FILE" ]; then
  while IFS= read -r ip; do
    [ -n "\$ip" ] || continue
    case "\$ip" in \#*) continue ;; esac
    ipset add $EXCLUDE_SET "\$ip" -exist
  done < "$EXCLUDE_FILE"
fi

iptables -t nat -D POSTROUTING -o $WG_IF -j MASQUERADE 2>/dev/null || true
iptables -t nat -A POSTROUTING -o $WG_IF -j MASQUERADE

iptables -D FORWARD -o $WG_IF -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i $WG_IF -j ACCEPT 2>/dev/null || true
iptables -I FORWARD -o $WG_IF -j ACCEPT
iptables -I FORWARD -i $WG_IF -j ACCEPT

# Append our two mangle rules after any existing PREROUTING rules so the
# router's own firewall rules keep their precedence. The RETURN (exclude)
# rule must sit immediately above the MARK rule, so append RETURN first.
iptables -t mangle -D PREROUTING -i $LAN_BRIDGE -m set --match-set $EXCLUDE_SET src -m set --match-set $YT_SET dst -j RETURN 2>/dev/null || true
iptables -t mangle -D PREROUTING -i $LAN_BRIDGE -m set --match-set $YT_SET dst -j MARK --set-mark $FWMARK 2>/dev/null || true
iptables -t mangle -A PREROUTING -i $LAN_BRIDGE -m set --match-set $EXCLUDE_SET src -m set --match-set $YT_SET dst -j RETURN
iptables -t mangle -A PREROUTING -i $LAN_BRIDGE -m set --match-set $YT_SET dst -j MARK --set-mark $FWMARK

while ip rule del fwmark $FWMARK table $RT_TABLE_NAME 2>/dev/null; do :; done
ip rule add fwmark $FWMARK table $RT_TABLE_NAME priority $RULE_PRIORITY

ip route flush table $RT_TABLE_NAME 2>/dev/null || true
ip route replace default dev $WG_IF table $RT_TABLE_NAME
$FWU_END
EOF
}

ensure_firewall_user() {
  local tmp
  tmp="$(mktemp)"
  if [ -f /etc/firewall.user ]; then
    awk -v begin="$FWU_BEGIN" -v end="$FWU_END" '
      $0==begin {skip=1; next}
      $0==end   {skip=0; next}
      !skip     {print}
    ' /etc/firewall.user > "$tmp"
  fi

  render_firewall_block >> "$tmp"
  cp "$tmp" /etc/firewall.user
  rm -f "$tmp"

  /etc/init.d/firewall restart
}

full_setup() {
  check_deps
  save_current_cache
  ensure_wg
  ensure_rt_table
  ensure_ipsets
  ensure_dnsmasq_config
  ensure_firewall_user
  restore_cache
  info "Setup complete."
  info "Server peer must allow router address $WG_ADDR and router public key from: wg show $WG_IF"
}

main() {
  local ans
  need_root
  DNSMASQ_SECTION="$(find_dnsmasq_section)"
  [ -n "$DNSMASQ_SECTION" ] || die "Could not find dnsmasq UCI section."

  print_status

  if is_configured; then
    printf "Do you want to reconfigure it now? [y/N] "
  else
    printf "Do you want to configure it now? [y/N] "
  fi

  read ans || ans=""
  case "$ans" in
    y|Y|yes|YES) full_setup ;;
    *) info "No changes made." ;;
  esac
}

main "$@"
