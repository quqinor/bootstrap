#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
SSH_PORT="${SSH_PORT:-2222}"
[[ -s /root/.ssh/authorized_keys ]] || { echo 'Refusing: /root/.ssh/authorized_keys is missing or empty.' >&2; exit 1; }
cat >/etc/ssh/sshd_config.d/20-vpn-lockdown.conf <<CFG
Port ${SSH_PORT}
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
LoginGraceTime 20
MaxStartups 100:30:200
MaxSessions 20
UseDNS no
CFG
/usr/sbin/sshd -t
systemctl restart ssh.service
echo "Password SSH disabled; root now requires a key on port ${SSH_PORT}."
echo 'Keep this session open until a second key-based SSH login succeeds.'
