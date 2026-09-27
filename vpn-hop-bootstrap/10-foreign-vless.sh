#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
REALITY_SERVER_NAME="${REALITY_SERVER_NAME:-www.microsoft.com}"
VLESS_PORT="${VLESS_PORT:-443}"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl ca-certificates jq openssl uuid-runtime iproute2
install -d -m 755 /etc/apt/keyrings
curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
chmod a+r /etc/apt/keyrings/sagernet.asc
cat >/etc/apt/sources.list.d/sagernet.sources <<'SRC'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
SRC
apt-get update
apt-get install -y sing-box
FOREIGN_IP="${FOREIGN_IP:-$(ip -4 route get 1.1.1.1 2>/dev/null | sed -nE 's/.* src ([0-9.]+).*/\1/p' | head -n1)}"
[[ -n "$FOREIGN_IP" ]] || { echo 'Could not detect source IPv4. Set FOREIGN_IP=...' >&2; exit 1; }
getent ahostsv4 "$REALITY_SERVER_NAME" >/dev/null 2>&1 || { echo "Reality handshake host does not resolve: $REALITY_SERVER_NAME" >&2; exit 1; }
VLESS_UUID="${VLESS_UUID:-$(uuidgen)}"
PAIR="$(sing-box generate reality-keypair)"
REALITY_PRIVATE_KEY="$(printf '%s\n' "$PAIR" | sed -nE 's/^[Pp]rivate[Kk]ey:[[:space:]]*//p' | head -n1)"
REALITY_PUBLIC_KEY="$(printf '%s\n' "$PAIR" | sed -nE 's/^[Pp]ublic[Kk]ey:[[:space:]]*//p' | head -n1)"
if [[ -z "$REALITY_PRIVATE_KEY" || -z "$REALITY_PUBLIC_KEY" ]]; then echo "Could not parse reality keypair output:" >&2; printf '%s\n' "$PAIR" >&2; exit 1; fi
REALITY_SHORT_ID="${REALITY_SHORT_ID:-$(openssl rand -hex 8)}"
install -d -m 700 /etc/sing-box
[[ ! -f /etc/sing-box/config.json ]] || cp -a /etc/sing-box/config.json "/etc/sing-box/config.json.bak.$(date +%s)"
jq -n --arg uuid "$VLESS_UUID" --arg priv "$REALITY_PRIVATE_KEY" --arg short "$REALITY_SHORT_ID" --arg sni "$REALITY_SERVER_NAME" --argjson port "$VLESS_PORT" '{log:{level:"info",timestamp:true},inbounds:[{type:"vless",tag:"vless-in",listen:"0.0.0.0",listen_port:$port,users:[{name:"ru-hop",uuid:$uuid,flow:"xtls-rprx-vision"}],tls:{enabled:true,reality:{enabled:true,handshake:{server:$sni,server_port:443},private_key:$priv,short_id:[$short]}}}],outbounds:[{type:"direct",tag:"direct"}],route:{auto_detect_interface:true,final:"direct"}}' >/etc/sing-box/config.json
chmod 600 /etc/sing-box/config.json
sing-box check -c /etc/sing-box/config.json
install -d -m 755 /etc/systemd/system/sing-box.service.d
cat >/etc/systemd/system/sing-box.service.d/10-restart.conf <<'UNIT'
[Service]
Restart=always
RestartSec=3
UNIT
systemctl daemon-reload
systemctl enable --now sing-box
sleep 1
systemctl is-active --quiet sing-box || { journalctl -u sing-box --no-pager -n 80 >&2; exit 1; }
TOKEN_JSON="$(jq -nc --arg foreign_ip "$FOREIGN_IP" --arg uuid "$VLESS_UUID" --arg public_key "$REALITY_PUBLIC_KEY" --arg short_id "$REALITY_SHORT_ID" --arg server_name "$REALITY_SERVER_NAME" --argjson port "$VLESS_PORT" '{foreign_ip:$foreign_ip,uuid:$uuid,reality_public_key:$public_key,short_id:$short_id,server_name:$server_name,port:$port}')"
TOKEN="$(printf '%s' "$TOKEN_JSON" | base64 -w0)"
install -d -m 700 /root/vpn-hop
printf '%s\n' "$TOKEN" >/root/vpn-hop/hop-token.txt
chmod 600 /root/vpn-hop/hop-token.txt
echo
echo "Foreign VLESS+REALITY is running on ${FOREIGN_IP}:${VLESS_PORT}."
echo "Reality handshake: ${REALITY_SERVER_NAME}"
echo
echo 'COPY THIS TOKEN TO RU (it contains the VLESS credential; never commit it):'
echo "$TOKEN"
echo 'Saved as /root/vpn-hop/hop-token.txt'
