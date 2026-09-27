#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }

TOKEN="${HOP_TOKEN:-${1:-}}"
[[ -n "$TOKEN" ]] || { echo "Usage: HOP_TOKEN='<token>' $0  OR  $0 '<token>'" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo 'Docker not found. Install AmneziaWG 3.1 through AmneziaVPN first.' >&2; exit 1; }
command -v sing-box >/dev/null 2>&1 || { echo 'sing-box not found. Run 20-ru-prep.sh first.' >&2; exit 1; }

TOKEN_JSON="$(printf '%s' "$TOKEN" | base64 -d 2>/dev/null || true)"
printf '%s' "$TOKEN_JSON" | jq -e . >/dev/null 2>&1 || { echo 'Invalid hop token.' >&2; exit 1; }
FOREIGN_IP="$(printf '%s' "$TOKEN_JSON" | jq -r '.foreign_ip')"
VLESS_UUID="$(printf '%s' "$TOKEN_JSON" | jq -r '.uuid')"
REALITY_PUBLIC_KEY="$(printf '%s' "$TOKEN_JSON" | jq -r '.reality_public_key')"
REALITY_SHORT_ID="$(printf '%s' "$TOKEN_JSON" | jq -r '.short_id')"
REALITY_SERVER_NAME="$(printf '%s' "$TOKEN_JSON" | jq -r '.server_name')"
VLESS_PORT="$(printf '%s' "$TOKEN_JSON" | jq -r '.port')"
FOREIGN_SSH_PORT="$(printf '%s' "$TOKEN_JSON" | jq -r '.ssh_port // 22')"
for v in FOREIGN_IP VLESS_UUID REALITY_PUBLIC_KEY REALITY_SHORT_ID REALITY_SERVER_NAME VLESS_PORT FOREIGN_SSH_PORT; do [[ -n "${!v}" && "${!v}" != null ]] || { echo "Missing token field: $v" >&2; exit 1; }; done

AWG_CONTAINER="$(docker ps --format '{{.Names}}' | grep -E '^amnezia-awg2$|^amnezia-awg$' | head -n1 || true)"
[[ -n "$AWG_CONTAINER" ]] || { echo 'Running AmneziaWG container not found.' >&2; docker ps --format 'table {{.Names}}\t{{.Status}}' >&2 || true; exit 1; }
docker exec "$AWG_CONTAINER" awg show awg0 >/dev/null 2>&1 || { echo 'AmneziaWG container exists, but awg0 is not healthy.' >&2; docker exec "$AWG_CONTAINER" sh -lc 'ip -br link; awg show 2>&1' >&2 || true; exit 1; }

mapfile -t NETWORKS < <(docker inspect "$AWG_CONTAINER" | jq -r '.[0].NetworkSettings.Networks | keys[]')
[[ ${#NETWORKS[@]} -gt 0 ]] || { echo 'No Docker networks found for Amnezia.' >&2; exit 1; }
IFACES=(); SUBNETS=()
for net in "${NETWORKS[@]}"; do
  driver="$(docker network inspect "$net" | jq -r '.[0].Driver')"
  [[ "$driver" == bridge ]] || continue
  opt_name="$(docker network inspect "$net" | jq -r '.[0].Options["com.docker.network.bridge.name"] // empty')"
  net_id="$(docker network inspect "$net" | jq -r '.[0].Id')"
  if [[ "$net" == bridge ]]; then iface=docker0; elif [[ -n "$opt_name" ]]; then iface="$opt_name"; else iface="br-${net_id:0:12}"; fi
  ip link show "$iface" >/dev/null 2>&1 && IFACES+=("$iface")
  while read -r subnet; do [[ -n "$subnet" && "$subnet" == *.*/* ]] && SUBNETS+=("$subnet"); done < <(docker network inspect "$net" | jq -r '.[0].IPAM.Config[]?.Subnet // empty')
done
[[ ${#IFACES[@]} -gt 0 && ${#SUBNETS[@]} -gt 0 ]] || { echo "Could not determine Amnezia Docker bridge interfaces/subnets. Networks: ${NETWORKS[*]}" >&2; exit 1; }
mapfile -t IFACES < <(printf '%s\n' "${IFACES[@]}" | awk 'NF && !seen[$0]++')
mapfile -t SUBNETS < <(printf '%s\n' "${SUBNETS[@]}" | awk 'NF && !seen[$0]++')
IFACES_JSON="$(printf '%s\n' "${IFACES[@]}" | jq -R . | jq -s .)"

install -d -m 700 /etc/vpn-hop /etc/sing-box
printf '%s\n' "${NETWORKS[@]}" >/etc/vpn-hop/docker-networks
printf '%s\n' "$TOKEN" >/etc/vpn-hop/hop-token
chmod 600 /etc/vpn-hop/docker-networks /etc/vpn-hop/hop-token
[[ ! -f /etc/sing-box/config.json ]] || cp -a /etc/sing-box/config.json "/etc/sing-box/config.json.bak.$(date +%s)"

jq -n \
  --arg foreign_ip "$FOREIGN_IP" \
  --arg uuid "$VLESS_UUID" \
  --arg public_key "$REALITY_PUBLIC_KEY" \
  --arg short_id "$REALITY_SHORT_ID" \
  --arg server_name "$REALITY_SERVER_NAME" \
  --argjson port "$VLESS_PORT" \
  --argjson ssh_port "$FOREIGN_SSH_PORT" \
  --argjson ifaces "$IFACES_JSON" \
'{
  log:{level:"info",timestamp:true},
  inbounds:[
    {
      type:"tun",tag:"clients-tun",interface_name:"sb-hop0",address:["172.31.255.1/30"],mtu:1400,
      auto_route:true,auto_redirect:true,strict_route:true,include_interface:$ifaces
    },
    {
      type:"direct",tag:"foreign-ssh",listen:"127.0.0.1",listen_port:2201,network:"tcp",
      override_address:"127.0.0.1",override_port:$ssh_port
    }
  ],
  outbounds:[{
    type:"vless",tag:"foreign",server:$foreign_ip,server_port:$port,uuid:$uuid,flow:"xtls-rprx-vision",
    tls:{enabled:true,server_name:$server_name,reality:{enabled:true,public_key:$public_key,short_id:$short_id}}
  }],
  route:{
    auto_detect_interface:true,
    rules:[
      {inbound:["foreign-ssh"],action:"route",outbound:"foreign"},
      {inbound:["clients-tun"],action:"route",outbound:"foreign"}
    ],
    final:"foreign"
  }
}' >/etc/sing-box/config.json
chmod 600 /etc/sing-box/config.json
sing-box check -c /etc/sing-box/config.json

cat >/usr/local/sbin/vpn-hop-guard-refresh <<'GUARD'
#!/usr/bin/env bash
set -Eeuo pipefail
TABLE=777; BASE=32760; MAX=32779
for p in $(seq "$BASE" "$MAX"); do while ip -4 rule del pref "$p" >/dev/null 2>&1; do :; done; done
ip -4 route replace blackhole default table "$TABLE"
i=0
while read -r net; do
  [[ -n "$net" ]] || continue
  docker network inspect "$net" >/dev/null 2>&1 || continue
  while read -r subnet; do
    [[ -n "$subnet" && "$subnet" == *.*/* ]] || continue
    pref=$((BASE+i)); (( pref <= MAX )) || exit 0
    ip -4 rule add pref "$pref" from "$subnet" table "$TABLE"
    i=$((i+1))
  done < <(docker network inspect "$net" | jq -r '.[0].IPAM.Config[]?.Subnet // empty')
done </etc/vpn-hop/docker-networks
GUARD
chmod 755 /usr/local/sbin/vpn-hop-guard-refresh

cat >/etc/systemd/system/vpn-hop-guard.service <<'UNIT'
[Unit]
Description=Fail-closed rules for Amnezia client egress
After=network-online.target docker.service
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vpn-hop-guard-refresh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
UNIT

cat >/etc/systemd/system/vpn-hop-guard-refresh.service <<'UNIT'
[Unit]
Description=Refresh fail-closed rules for Amnezia Docker networks
After=docker.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vpn-hop-guard-refresh
UNIT

cat >/etc/systemd/system/vpn-hop-guard-refresh.timer <<'UNIT'
[Unit]
Description=Periodically refresh VPN hop fail-closed rules
[Timer]
OnBootSec=45s
OnUnitActiveSec=60s
Unit=vpn-hop-guard-refresh.service
[Install]
WantedBy=timers.target
UNIT

install -d -m 755 /etc/systemd/system/sing-box.service.d
cat >/etc/systemd/system/sing-box.service.d/10-vpn-hop.conf <<'UNIT'
[Unit]
After=network-online.target docker.service
Wants=network-online.target
[Service]
Restart=always
RestartSec=3
UNIT

systemctl daemon-reload
systemctl enable --now vpn-hop-guard.service
systemctl enable --now vpn-hop-guard-refresh.timer
systemctl enable --now sing-box
sleep 2
if ! systemctl is-active --quiet sing-box; then echo 'sing-box failed; fail-closed guard remains active.' >&2; journalctl -u sing-box --no-pager -n 120 >&2; exit 1; fi
ss -lntp | grep -qE '127\.0\.0\.1:2201' || { echo 'Management listener 127.0.0.1:2201 is not up.' >&2; exit 1; }

echo
echo 'OK: second hop enabled.'
echo "Amnezia container: $AWG_CONTAINER"
echo "Captured bridge interfaces: ${IFACES[*]}"
echo "Fail-closed source networks: ${SUBNETS[*]}"
echo "Foreign: ${FOREIGN_IP}:${VLESS_PORT}"
echo "Foreign SSH tunnel endpoint on RU: 127.0.0.1:2201 -> VLESS/REALITY -> foreign 127.0.0.1:${FOREIGN_SSH_PORT}"
echo
echo 'Test from Windows:'
echo '  Terminal 1: ssh -N -L 2201:127.0.0.1:2201 -p 2222 root@138.16.186.130'
echo '  Terminal 2: ssh -p 2201 root@127.0.0.1'
