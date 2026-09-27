#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
SSH_PORT="${SSH_PORT:-2222}"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y openssh-server curl ca-certificates jq iproute2 nftables
install -d -m 755 /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/10-vpn-bootstrap.conf <<CFG
Port ${SSH_PORT}
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
LoginGraceTime 30
MaxStartups 100:30:200
MaxSessions 20
UseDNS no
CFG
/usr/sbin/sshd -t
systemctl disable --now ssh.socket >/dev/null 2>&1 || true
systemctl unmask ssh.service >/dev/null 2>&1 || true
systemctl enable ssh.service >/dev/null 2>&1 || true
systemctl restart ssh.service
echo
echo "SSH bootstrap complete. Port: ${SSH_PORT}"
ss -lntp | grep -E ":${SSH_PORT}[[:space:]]" || { echo "ERROR: sshd is not listening on ${SSH_PORT}" >&2; exit 1; }
echo "Connect with: ssh -p ${SSH_PORT} root@SERVER_IP"
echo "Password auth remains enabled until 40-lockdown-ssh.sh is run after key testing."
