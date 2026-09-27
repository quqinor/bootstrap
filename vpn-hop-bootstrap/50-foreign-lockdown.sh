#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
[[ -s /root/.ssh/authorized_keys ]] || { echo 'Refusing: /root/.ssh/authorized_keys is empty. Install and test your key first.' >&2; exit 1; }
SSH_PORT="${FOREIGN_SSH_PORT:-$(/usr/sbin/sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}')}"
SSH_PORT="${SSH_PORT:-22}"
install -d -m 755 /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/90-vpn-foreign-local.conf <<CFG
Port ${SSH_PORT}
ListenAddress 127.0.0.1
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
LoginGraceTime 20
MaxStartups 100:30:200
UseDNS no
CFG
/usr/sbin/sshd -t
systemctl disable --now ssh.socket >/dev/null 2>&1 || true
systemctl unmask ssh.service >/dev/null 2>&1 || true
systemctl enable ssh.service >/dev/null 2>&1 || true
systemctl restart ssh.service
ss -lntp | grep -qE "127\\.0\\.0\\.1:${SSH_PORT}[[:space:]]" || { echo "ERROR: sshd is not listening on 127.0.0.1:${SSH_PORT}." >&2; exit 1; }
echo "OK: foreign SSH is key-only and loopback-only on 127.0.0.1:${SSH_PORT}."
