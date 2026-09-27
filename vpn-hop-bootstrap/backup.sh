#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
OUT="${1:-/root/vpn-backup-$(hostname)-$(date +%Y%m%d-%H%M%S).tar.gz}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
for p in /etc/sing-box /etc/vpn-hop /etc/ssh/sshd_config.d /etc/sysctl.d/99-vpn-hop.conf; do [[ -e "$p" ]] && cp -a --parents "$p" "$TMP" 2>/dev/null || true; done
if command -v docker >/dev/null 2>&1; then C="$(docker ps --format '{{.Names}}' | grep -E '^amnezia-awg2$|^amnezia-awg$' | head -n1 || true)"; if [[ -n "$C" ]]; then mkdir -p "$TMP/amnezia"; docker exec "$C" cat /opt/amnezia/awg/awg0.conf >"$TMP/amnezia/awg0.conf" 2>/dev/null || true; fi; fi
tar -C "$TMP" -czf "$OUT" .; chmod 600 "$OUT"; echo "$OUT"; echo 'Contains private VPN material; store securely and never upload to GitHub.'
