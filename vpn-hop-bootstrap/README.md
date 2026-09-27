# Final two-hop VPN bootstrap

Topology:

```text
RU devices -- AmneziaWG 3.1 --> RU VPS 138.16.186.130
                                  |
                                  +-- only Amnezia client traffic --> sing-box VLESS+REALITY TCP/443 --> NL VPS 13.140.0.219 --> Internet

RU host SSH/apt/system traffic ---------------------------------------------------------------> RU uplink directly
```

Foreign SSH management is intentionally carried inside the same VLESS+REALITY hop instead of relying on raw international SSH. The foreign bootstrap detects whatever SSH port is currently configured (22, 48157, etc.) and puts it in the private hop token:

```text
Windows -> SSH to RU -> local forward -> RU 127.0.0.1:2201 -> VLESS+REALITY -> NL 127.0.0.1:22
```

## Files

- `00-ssh-bootstrap.sh` - temporary manageable SSH on RU, default TCP 2222.
- `10-foreign-vless.sh` - run from the NL provider VNC/web console; installs sing-box and creates VLESS+REALITY on TCP 443.
- `20-ru-prep.sh` - installs sing-box and forwarding prerequisites on RU.
- `30-ru-enable-hop.sh` - discovers the Amnezia Docker bridge, routes only its traffic through NL, installs fail-closed policy, and creates RU-local foreign SSH tunnel port 2201.
- `40-lockdown-ssh.sh` - switches RU SSH to key-only after testing your key.
- `50-foreign-lockdown.sh` - switches NL SSH to key-only and loopback-only after the VLESS management path is tested.
- `status.sh` - diagnostics.
- `backup.sh` - config backup; contains secrets, never commit the output.

## Required order

### A. RU bootstrap

Via RU VNC, once:

```bash
curl -fsSL https://raw.githubusercontent.com/quqinor/bootstrap/main/vpn-hop-bootstrap/00-ssh-bootstrap.sh | bash
```

Then Windows:

```powershell
ssh-keygen -R 138.16.186.130
ssh -p 2222 root@138.16.186.130
```

### B. NL VLESS bootstrap

Do not spend time fixing raw SSH from Russia to NL. From the NL VNC/web console run:

```bash
curl -fsSL https://raw.githubusercontent.com/quqinor/bootstrap/main/vpn-hop-bootstrap/10-foreign-vless.sh | bash
```

Copy the printed base64 hop token somewhere private. Do not commit it.

### C. Prepare RU

On RU over SSH:

```bash
curl -fsSL https://raw.githubusercontent.com/quqinor/bootstrap/main/vpn-hop-bootstrap/20-ru-prep.sh | bash
```

### D. Install AmneziaWG 3.1 on RU

Use a current AmneziaVPN app. Add self-hosted server `138.16.186.130`, SSH port `2222`, root credentials. Install only AmneziaWG 3.1. Use UDP port `585`.

Create one test user and verify it works before adding the second hop. At this moment its public IP should be `138.16.186.130`.

### E. Enable second hop

On RU:

```bash
HOP_TOKEN='PASTE_TOKEN_HERE' bash <(curl -fsSL https://raw.githubusercontent.com/quqinor/bootstrap/main/vpn-hop-bootstrap/30-ru-enable-hop.sh)
```

After success, the Amnezia client public IP should become `13.140.0.219`, while `curl -4 https://ifconfig.me/ip` run directly on RU should still return the RU public IP.

Fail-closed test:

```bash
systemctl stop sing-box
```

The connected Amnezia client must lose Internet, but RU SSH must stay alive. Restore:

```bash
systemctl start sing-box
```

### F. Access NL SSH through Reality

The hop token already contains the current NL SSH port, so it does not matter whether your NL server currently uses 22, 2222, 48157, etc. On Windows terminal 1:

```powershell
ssh -N -L 2201:127.0.0.1:2201 -p 2222 root@138.16.186.130
```

Keep it open. In terminal 2:

```powershell
ssh -p 2201 root@127.0.0.1
```

That second SSH connection is transported as:

`Windows -> RU SSH -> RU sing-box -> VLESS+REALITY -> NL localhost:<detected SSH port>`.

### G. Install SSH key and lock down

Generate a Windows key once if needed:

```powershell
ssh-keygen -t ed25519
```

RU key install:

```powershell
Get-Content $env:USERPROFILE\.ssh\id_ed25519.pub | ssh -p 2222 root@138.16.186.130 "umask 077; mkdir -p /root/.ssh; cat >> /root/.ssh/authorized_keys"
```

Verify a second key-only RU login, then on RU:

```bash
curl -fsSL https://raw.githubusercontent.com/quqinor/bootstrap/main/vpn-hop-bootstrap/40-lockdown-ssh.sh | bash
```

For NL, keep the RU forwarding terminal open, then:

```powershell
Get-Content $env:USERPROFILE\.ssh\id_ed25519.pub | ssh -p 2201 root@127.0.0.1 "umask 077; mkdir -p /root/.ssh; cat >> /root/.ssh/authorized_keys"
```

Verify a second tunneled NL login works without password. Then inside NL:

```bash
curl -fsSL https://raw.githubusercontent.com/quqinor/bootstrap/main/vpn-hop-bootstrap/50-foreign-lockdown.sh | bash
```

After this, NL sshd listens only on `127.0.0.1:22`, so public bot traffic cannot hit SSH at all. Provider VNC remains the emergency path.

## Recovery

- Foreign dies: Amnezia client traffic fails closed; RU SSH remains direct. Rebuild NL, rerun `10-foreign-vless.sh`, then rerun `30-ru-enable-hop.sh` with the new token. User Amnezia configs do not change.
- sing-box on RU dies: clients lose Internet instead of leaking through RU IP; RU management remains direct.
- RU dies: restore Amnezia server config/private keys from a secure backup if you want existing user profiles to survive; otherwise regenerate user profiles.

## Never commit

- hop token
- `/etc/sing-box/config.json`
- Amnezia server configs/keys
- `/root/vpn-hop/*`
- backup archives
