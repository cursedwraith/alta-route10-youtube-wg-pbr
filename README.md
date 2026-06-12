# Alta Route10 YouTube WireGuard PBR

A helper script for Alta Route10 / OpenWrt-style routers that routes selected YouTube-related traffic through a WireGuard tunnel while leaving normal LAN traffic on the regular WAN.

This setup uses:

- `dnsmasq` + `ipset` to collect YouTube-related destination IPs
- `iptables` mangle rules to mark matching traffic
- Linux policy routing with `fwmark 0x200`
- a dedicated routing table named `wgroute`
- a WireGuard client interface named `wg-yt`
- optional client exclusions through `yt-src-exclude`

> Unofficial community script. Use at your own risk. Firmware updates, GUI firewall changes, or vendor changes may affect this setup.

---

## Goal

The goal is to route only selected YouTube-related traffic through a WireGuard VPN tunnel.

Normal traffic:

```text
LAN client -> Alta Route10 -> WAN
```

YouTube-related traffic:

```text
LAN client -> Alta Route10 -> wg-yt -> WireGuard server
```

Optional excluded clients:

```text
Excluded client -> Alta Route10 -> WAN
```

---

## Tested Environment

- Alta Route10
- SSH/root access enabled
- OpenWrt-style shell environment
- WireGuard kernel support available
- `dnsmasq`
- `ipset`
- `iptables`
- local DNS upstream such as Technitium

---

## How It Works

1. LAN clients use the router as DNS.
2. Router `dnsmasq` forwards DNS upstream, for example to Technitium.
3. `dnsmasq` adds IPs for selected YouTube domains into the `yt-vpn` ipset.
4. `iptables` marks packets whose destination IP is in `yt-vpn`.
5. `ip rule` sends fwmark `0x200` to table `wgroute`.
6. `wgroute` sends traffic through `wg-yt`.
7. Optional excluded client IPs are skipped before marking.

---

## Default YouTube Domains

The script populates `yt-vpn` from these domains (dnsmasq matches by suffix,
so each entry also covers its subdomains):

```text
googlevideo.com          # media streams (videoplayback)
youtubei.googleapis.com  # InnerTube player API (apps/TV/embeds)
youtube.com              # web front-end + player config (covers www. and m.)
youtube-nocookie.com     # privacy-enhanced embeds
ytimg.com                # thumbnails / static assets
ggpht.com                # avatars / static assets
```

`youtube.com` matters for more than convenience: on the desktop web client
the player request that **mints the IP-locked `videoplayback` URLs** goes to
`www.youtube.com/youtubei/v1/player`. If that request does not egress the
same VPN IP as the media, the signed `ip=` baked into the stream URLs won't
match the source address and Google throttles/redirects the stream
(`ipbypass=yes`, `cms_redirect=yes`), causing buffering.

Trade-off: routing `youtube.com` over the VPN sends all YouTube web traffic
(including sign-in) through the tunnel, so a flagged/datacenter VPN exit IP
may trigger "sign in to confirm you're not a bot" prompts. To revert to the
conservative media-only set, remove the `youtube.com`/`ytimg.com`/`ggpht.com`
lines from `ensure_dnsmasq_config`.

---

## Files

Recommended files:

```text
/cfg/yt-vpn-setup.sh
/cfg/yt-vpn.backup
/cfg/yt-src-exclude.list
```

### `/cfg/yt-vpn-setup.sh`

Main setup script.

### `/cfg/yt-vpn.backup`

Optional saved warm cache of the `yt-vpn` ipset.

Create it with:

```sh
ipset save yt-vpn > /cfg/yt-vpn.backup
```

### `/cfg/yt-src-exclude.list`

Optional list of client IPs that should not use the VPN for YouTube traffic.

Example:

```text
192.168.1.234
192.168.1.60
```

One IP per line.

---

## Installation

Copy the script to the router:

```sh
vi /cfg/yt-vpn-setup.sh
```

Paste the script, then make it executable:

```sh
chmod +x /cfg/yt-vpn-setup.sh
```

Run it:

```sh
/cfg/yt-vpn-setup.sh
```

---

## Required Configuration

Edit the config section at the top of the script:

```sh
WG_PRIVKEY=""
WG_PSK=""
WG_ADDR=""
WG_SERVER_PUBKEY=""
WG_ENDPOINT_HOST=""
WG_ENDPOINT_PORT="443"

TECHNITIUM_IP="192.168.1.19"
LAN_BRIDGE="br-lan"
WG_IF="wg-yt"
```

### WireGuard values

Use values from your WireGuard client configuration:

```ini
[Interface]
PrivateKey = WG_PRIVKEY
Address = WG_ADDR

[Peer]
PublicKey = WG_SERVER_PUBKEY
PresharedKey = WG_PSK
Endpoint = WG_ENDPOINT_HOST:WG_ENDPOINT_PORT
AllowedIPs = 0.0.0.0/0
```

Leave `WG_PSK=""` if the provider does not use a preshared key.

---

## DNS Requirements

For the routing logic to work, clients should use the router as DNS:

```text
192.168.1.1
```

The router then forwards DNS to the configured upstream, for example Technitium:

```text
192.168.1.19
```

Correct flow:

```text
Client -> Router dnsmasq -> Technitium -> Internet
```

Avoid pointing clients directly to Technitium if you want the router to populate `yt-vpn`.

---

## Server-Side WireGuard Requirements

The WireGuard server must have a matching peer for the router.

Example server peer:

```ini
[Peer]
PublicKey = ROUTER_PUBLIC_KEY
PresharedKey = SAME_PSK_IF_USED
AllowedIPs = ROUTER_WG_ADDRESS/32
```

Example:

```ini
[Peer]
PublicKey = abcdef...
AllowedIPs = 100.68.101.47/32
```

The server must also have:

- IP forwarding enabled
- NAT/MASQUERADE from the WireGuard subnet out to the server WAN
- UDP port open for the WireGuard listener

---

## Verification

Check WireGuard:

```sh
wg show wg-yt
```

Expected:

```text
latest handshake: X seconds ago
transfer: ... received, ... sent
```

Check policy rule:

```sh
ip rule show
```

Expected:

```text
200: from all fwmark 0x200 lookup wgroute
```

Check route table:

```sh
ip route show table wgroute
```

Expected:

```text
default dev wg-yt scope link
```

Check mangle rules:

```sh
iptables -t mangle -L PREROUTING -n -v --line-numbers
```

Expected:

```text
RETURN ... match-set yt-src-exclude src match-set yt-vpn dst
MARK   ... match-set yt-vpn dst MARK set 0x200
```

Check ipset count:

```sh
ipset list yt-vpn | awk '/^Number of entries:/{print $4}'
```

Check dnsmasq upstream:

```sh
uci show $(uci show dhcp | awk -F= '/=dnsmasq$/{print $1; exit}').server
```

Expected example:

```text
dhcp.cfg01411c.server='192.168.1.19'
```

---

## Excluding a Client

Add the client IP to:

```text
/cfg/yt-src-exclude.list
```

Example:

```sh
printf '%s\n' 192.168.1.234 >> /cfg/yt-src-exclude.list
sort -u /cfg/yt-src-exclude.list -o /cfg/yt-src-exclude.list
/etc/init.d/firewall restart
```

Verify:

```sh
ipset list yt-src-exclude
iptables -t mangle -L PREROUTING -n -v --line-numbers
```

Excluded clients should hit the `RETURN` rule instead of the `MARK` rule.

---

## Saving the Warm IP Cache

Save current `yt-vpn` entries:

```sh
ipset save yt-vpn > /cfg/yt-vpn.backup
```

Check backup count:

```sh
grep -c '^add yt-vpn ' /cfg/yt-vpn.backup
```

The setup script can restore this cache after rebuilds.

---

## Troubleshooting

### Tunnel handshakes but YouTube does not route

Check:

```sh
iptables -t mangle -L PREROUTING -n -v --line-numbers
ip rule show
ip route show table wgroute
wg show wg-yt
```

The `MARK` counter and WireGuard transfer counters should increase while playing YouTube from a non-excluded client.

### `yt-vpn` is empty

Check dnsmasq ipset config:

```sh
uci show $(uci show dhcp | awk -F= '/=dnsmasq$/{print $1; exit}').ipset
```

Force a lookup:

```sh
nslookup youtubei.googleapis.com 192.168.1.1
nslookup r5---sn-ab5sznzs.googlevideo.com 192.168.1.1
ipset list yt-vpn | head
```

### Client shows DNS as `127.0.0.53`

On Linux this is often normal because of `systemd-resolved`.

Check the real upstream:

```sh
resolvectl status
```

The active DNS server should be:

```text
192.168.1.1
```

### `Flush terminated`

Some firmware versions return a non-zero result when flushing an empty routing table. The script uses:

```sh
ip route flush table wgroute 2>/dev/null || true
```

to avoid stopping on that harmless case.

---

## Useful Commands

Live status:

```sh
wg show wg-yt
ipset list yt-vpn | awk '/^Number of entries:/{print $4}'
iptables -t mangle -L PREROUTING -n -v --line-numbers
ip rule show
ip route show table wgroute
```

Watch YouTube traffic through the tunnel:

```sh
tcpdump -ni wg-yt
```

Watch DNS:

```sh
tcpdump -ni br-lan port 53
```

Stream capture to Wireshark:

```sh
ssh -n -T root@192.168.1.1 "tcpdump -i br-lan -U -s0 -w - host 192.168.1.234" | wireshark -k -i -
```

---

## Limitations

This method is IP-based after DNS resolution.

That means if Google reuses the same IPs for different services, some non-YouTube Google traffic may also be routed through the tunnel.

This method does not inspect full HTTPS URLs.

It can usually identify or route by:

- DNS hostname
- destination IP
- TLS SNI in packet captures, where visible

It cannot reliably identify full encrypted URLs without TLS interception.

---

## Disclaimer

This is an unofficial community script.

It is not supported by Alta Labs.

Use carefully, keep backups, and expect to re-check the setup after firmware updates.
