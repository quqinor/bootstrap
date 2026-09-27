#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl ca-certificates jq iproute2 nftables
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
cat >/etc/sysctl.d/99-vpn-hop.conf <<'SYS'
net.ipv4.ip_forward=1
SYS
sysctl --system >/dev/null
systemctl disable --now sing-box >/dev/null 2>&1 || true
echo
echo 'RU preparation complete.'
echo 'Next: add RU to current AmneziaVPN as Self-hosted via SSH :2222; install ONLY AmneziaWG 3.1, preferably UDP 585; create and test one client; then run 30-ru-enable-hop.sh.'
echo 'Do not manually install an old host AmneziaWG kernel module.'
