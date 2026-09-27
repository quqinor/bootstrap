#!/usr/bin/env bash
set -u

echo '=== host ==='
hostname
ip -br a
echo

echo '=== ssh listeners ==='
ss -lntp 2>/dev/null | grep -E 'sshd|:2201|:2222|:22[[:space:]]' || true
echo

echo '=== sing-box ==='
systemctl --no-pager --full status sing-box 2>/dev/null | sed -n '1,20p' || true
[[ -f /etc/sing-box/config.json ]] && sing-box check -c /etc/sing-box/config.json 2>&1 || true
echo

echo '=== Amnezia ==='
if command -v docker >/dev/null 2>&1; then
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
  C="$(docker ps --format '{{.Names}}' | grep -E '^amnezia-awg2$|^amnezia-awg$' | head -n1 || true)"
  if [[ -n "$C" ]]; then
    echo
    docker exec "$C" awg show awg0 2>&1 || true
  fi
fi
echo

echo '=== fail-closed ==='
ip -4 rule show | grep -E '3276[0-9].*lookup 777' || true
ip -4 route show table 777 2>/dev/null || true
echo

echo '=== recent sing-box log ==='
journalctl -u sing-box --no-pager -n 50 2>/dev/null || true
