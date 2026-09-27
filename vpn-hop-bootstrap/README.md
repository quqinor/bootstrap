# Two-hop VPN bootstrap

Topology: **user -> AmneziaWG 3.1 -> RU VPS -> sing-box VLESS+REALITY TCP/443 -> NL VPS -> Internet**.

Current hosts: RU `138.16.186.130`, NL `13.140.0.219`, Ubuntu 26.04. SSH is moved to TCP `2222`; use UDP `585` for the user-facing AmneziaWG ingress; the inter-server hop uses TCP `443`.

The RU host's own SSH/apt/system traffic stays on the RU uplink. Only traffic arriving from Amnezia's Docker bridge is captured by sing-box. A separate policy-routing blackhole provides **fail-closed** behavior: if sing-box disappears, client egress is blackholed before the normal RU default route instead of leaking through the RU public IP.

## Stage 0: make SSH usable

Upload this repo to GitHub. From each VPS VNC/web console run the raw GitHub script:

```bash
curl -fsSL https://raw.githubusercontent.com/YOU/REPO/main/00-ssh-bootstrap.sh | bash
```

On Windows after the server reinstall, clear old host keys:

```powershell
ssh-keygen -R 138.16.186.130
ssh-keygen -R 13.140.0.219
```

Then connect with `ssh -p 2222 root@IP`.

## Stage 1: foreign/NL

Clone the repo and run `bash 10-foreign-vless.sh`. It installs sing-box from the official SagerNet APT repo, creates VLESS+REALITY on TCP 443, and prints a base64 **hop token**. The token contains the VLESS credential; never commit it. A copy is stored at `/root/vpn-hop/hop-token.txt`.

## Stage 2: RU preparation and Amnezia ingress

Run `bash 20-ru-prep.sh`. Then use a current AmneziaVPN app to add `138.16.186.130:2222` as Self-hosted and install **only AmneziaWG 3.1**, preferably on UDP `585`. Create one test client and verify it works before adding the second hop. At this point it should exit via the RU public IP.

Do not preinstall an old host AmneziaWG kernel module: the privileged Amnezia container can select the host module, and an outdated module can reject AWG 3.1 parameters.

## Stage 3: RU -> NL hop

Copy the hop token from NL and on RU run:

```bash
HOP_TOKEN='PASTE_TOKEN_HERE' bash 30-ru-enable-hop.sh
```

The script verifies the Amnezia container/`awg0`, discovers its Docker bridges, creates a sing-box TUN using Linux `auto_route` + `auto_redirect`, and installs source-network blackhole rules that are refreshed every minute.

Test from a real Amnezia client. Its public IPv4 should be the NL IP, while `curl -4 https://ifconfig.me/ip` run directly on RU should still show the RU IP.

Fail-closed test: run `systemctl stop sing-box` on RU. The Amnezia client should lose Internet while SSH to RU remains reachable. Restore with `systemctl start sing-box`.

## Stage 4: SSH keys

Create a Windows key if needed: `ssh-keygen -t ed25519`. Install it on each VPS:

```powershell
Get-Content $env:USERPROFILE\.ssh\id_ed25519.pub | ssh -p 2222 root@SERVER_IP "umask 077; mkdir -p /root/.ssh; cat >> /root/.ssh/authorized_keys"
```

Verify a second key-based login, then run `bash 40-lockdown-ssh.sh`. Keep the original session open until the second login works.

## Diagnostics and backup

`bash status.sh` shows SSH, sing-box, Amnezia, current egress, fail-closed rules and recent logs. `bash backup.sh` creates a root-only archive containing VPN config/keys; **never upload that archive to GitHub**.

If the foreign VPS is replaced later, user Amnezia configs can stay unchanged: rebuild foreign, generate a new hop token, and rerun `30-ru-enable-hop.sh` on RU. If Amnezia/Docker itself is reinstalled, rerun `30-ru-enable-hop.sh` so current bridge interfaces are detected again.
