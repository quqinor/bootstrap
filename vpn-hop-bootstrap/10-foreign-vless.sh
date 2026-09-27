#!/usr/bin/env bash
set -Eeuo pipefail
trap 'rc=$?; echo "ERROR: 10-foreign-vless.sh failed at line $LINENO (exit $rc)" >&2; exit $rc' ERR
echo "[1/7] Preflight"
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }

REALITY_SERVER_NAME="${REALITY_SERVER_NAME:-www.microsoft.com}"
VLESS_PORT="${VLESS_PORT:-443}"
FOREIGN_IP="${FOREIGN_IP:-13.140.0.219}"
FOREIGN_SSH_PORT="${FOREIGN_SSH_PORT:-$(/usr/sbin/sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}')}"
FOREIGN_SSH_PORT="${FOREIGN_SSH_PORT:-22}"

export DEBIAN_FRONTEND=noninteractive
echo "[2/7] Installing prerequisites"
apt-get update
apt-get install -y curl ca-certificates jq openssl uuid-runtime iproute2

echo "[3/7] Installing sing-box"
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

getent ahostsv4 "$REALITY_SERVER_NAME" >/dev/null 2>&1 || { echo "Reality handshake host does not resolve: $REALITY_SERVER_NAME" >&2; exit 1; }

echo "[4/7] Generating VLESS/REALITY credentials"
VLESS_UUID="${VLESS_UUID:-$(uuidgen)}"
PAIR="$(sing-box generate reality-keypair)"
REALITY_PRIVATE_KEY="$(printf '%s\n' "$PAIR" | sed -nE 's/^[Pp]rivate[Kk]ey:[[:space:]]*//p' | head -n1)"
REALITY_PUBLIC_KEY="$(printf '%s\n' "$PAIR" | sed -nE 's/^[Pp]ublic[Kk]ey:[[:space:]]*//p' | head -n1)"
[[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PUBLIC_KEY" ]] || { echo 'Could not parse REALITY keypair.' >&2; printf '%s\n' "$PAIR" >&2; exit 1; }
REALITY_SHORT_ID="${REALITY_SHORT_ID:-$(openssl rand -hex 4)}"

echo "[5/7] Writing sing-box config"
install -d -m 700 /etc/sing-box /root/vpn-hop
[[ ! -f /etc/sing-box/config.json ]] || cp -a /etc/sing-box/config.json "/etc/sing-box/config.json.bak.$(date +%s)"

jq -n \
  --arg uuid "$VLESS_UUID" \
  --arg priv "$REALITY_PRIVATE_KEY" \
  --arg short "$REALITY_SHORT_ID" \
  --arg sni "$REALITY_SERVER_NAME" \
  --argjson port "$VLESS_PORT" \
'{
  log:{level:"info",timestamp:true},
  inbounds:[{
    type:"vless",tag:"vless-in",listen:"0.0.0.0",listen_port:$port,
    users:[{name:"ru-hop",uuid:$uuid,flow:"xtls-rprx-vision"}],
    tls:{enabled:true,reality:{enabled:true,handshake:{server:$sni,server_port:443},private_key:$priv,short_id:[$short]}}
  }],
  outbounds:[{type:"direct",tag:"direct"}],
  route:{auto_detect_interface:true,final:"direct"}
}' >/etc/sing-box/config.json
chmod 600 /etc/sing-box/config.json
echo "[6/7] Validating config"
sing-box check -c /etc/sing-box/config.json

echo "[7/7] Starting sing-box"
install -d -m 755 /etc/systemd/system/sing-box.service.d
cat >/etc/systemd/system/sing-box.service.d/10-restart.conf <<'UNIT'
[Service]
Restart=always
RestartSec=3
UNIT
systemctl daemon-reload
systemctl enable --now sing-box
sleep 2
systemctl is-active --quiet sing-box || { journalctl -u sing-box --no-pager -n 100 >&2; exit 1; }
ss -lntp | grep -qE ":${VLESS_PORT}[[:space:]]" || { echo "sing-box is not listening on TCP ${VLESS_PORT}" >&2; exit 1; }

TOKEN_JSON="$(jq -nc --arg foreign_ip "$FOREIGN_IP" --arg uuid "$VLESS_UUID" --arg public_key "$REALITY_PUBLIC_KEY" --arg short_id "$REALITY_SHORT_ID" --arg server_name "$REALITY_SERVER_NAME" --argjson port "$VLESS_PORT" --argjson ssh_port "$FOREIGN_SSH_PORT" '{foreign_ip:$foreign_ip,uuid:$uuid,reality_public_key:$public_key,short_id:$short_id,server_name:$server_name,port:$port,ssh_port:$ssh_port}')"
TOKEN="$(printf '%s' "$TOKEN_JSON" | base64 -w0)"
printf '%s\n' "$TOKEN" >/root/vpn-hop/hop-token.txt
chmod 600 /root/vpn-hop/hop-token.txt

cat >/root/vpn-hop/foreign-info.txt <<INFO
foreign_ip=${FOREIGN_IP}
vless_port=${VLESS_PORT}
reality_server_name=${REALITY_SERVER_NAME}
reality_public_key=${REALITY_PUBLIC_KEY}
short_id=${REALITY_SHORT_ID}
uuid=${VLESS_UUID}
ssh_port=${FOREIGN_SSH_PORT}
INFO
chmod 600 /root/vpn-hop/foreign-info.txt

echo
echo "OK: foreign VLESS+REALITY is running on ${FOREIGN_IP}:${VLESS_PORT}"
echo "Reality handshake: ${REALITY_SERVER_NAME}"
echo "Detected foreign SSH port for tunneled management: ${FOREIGN_SSH_PORT}"
echo
echo 'COPY THIS TOKEN TO RU. It is a secret and must NOT be committed to GitHub:'
echo "$TOKEN"
echo
echo 'Token saved on foreign as /root/vpn-hop/hop-token.txt'
