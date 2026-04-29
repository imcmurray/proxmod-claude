# ProxModClaude

Self-contained walkthrough for deploying a fully-provisioned Claude Code LXC container on a Proxmox host using `agentic.sh`. Captures every gotcha hit during the first deploy so the next one is one shot.

## Credit & origin

`agentic.sh` started as a fork of [`serversathome-personal/code`](https://github.com/serversathome-personal/code) — full credit to the original author for the foundational template. This repo extends that work with hardening, observability, and documentation drawn from a real-world deploy, captured in [§7](#7-what-the-modified-agenticsh-does-differently-from-upstream).

> **License note:** the upstream repo has no LICENSE file at the time of this writing, so the original work is technically "all rights reserved" by its author. Our modifications and the documentation in this repo are licensed under [MIT](./LICENSE), but use of the underlying script depends on the upstream author's wishes — see [`NOTICE.md`](./NOTICE.md). If you are the upstream maintainer and want this repo handled differently, please open an issue.

## What you get

A privileged Ubuntu 24.04 LXC container with:

- Claude Code (native installer) — auto-approve permissions, agent teams, 64k output, extended thinking
- Pre-installed plugins: frontend-design, code-review, commit-commands, security-guidance, context7, webapp-testing, superpowers
- Languages: Node.js 22 LTS, Python 3.12 (with `uv`), Go (latest), Rust (latest)
- Docker + Compose running inside the LXC, with Watchtower auto-updating containers
- Code-server (browser VS Code) on port 8443 with a randomly-generated password
- **Always-installed extras** (no auth burden): `lazygit`, `uv`, `direnv` (with bash hook), `httpie`, `rclone`
- **Optional cloud/deploy CLIs** (chosen via prompt at deploy time): `gh`, `railway`, `wrangler`, `aws`, `flyctl`, `vercel`, `doctl` — defaults to `gh railway wrangler`, type `all` or `none` to override
- ripgrep / fd / fzf / bat / jq / postgres-client / redis-tools / sqlite3 / Playwright
- Auto-cd to `/project` on shell login, sensible aliases, git defaults, weekly system updates
- **Python policy:** every Python project gets its own `.venv/` — `pip install --break-system-packages` is **not** the convention here

## Files in this repo

| File | Purpose |
|------|---------|
| [`agentic.sh`](./agentic.sh) | The deployer. Run it on the Proxmox host. |
| [`README.md`](./README.md) | This file — the walkthrough. |
| [`claude-code-container-workflow.md`](./claude-code-container-workflow.md) | Day-to-day guide once the container exists. |
| [`proxmox-silent-freeze-guide.md`](./proxmox-silent-freeze-guide.md) | Diagnostic runbook if a Proxmox host randomly freezes. Reusable on other hosts. |

---

## 1. Prerequisites

You need:

- A Proxmox VE host (any 7.x or 8.x) with root access
- Internet access from the host (to download the LXC template and packages)
- Storage on the Proxmox host that can hold LXC root disks (NOT a CIFS/SMB or NFS share — see §6)
- Your laptop's SSH public key (optional but recommended)

Run `agentic.sh` directly on the Proxmox host, as root. It is **not** meant to run from the LXC or from your laptop.

---

## 2. Pre-deploy checklist (run on the Proxmox host)

Gather these before launching the script — they answer the prompts.

```bash
# 1. What container ID is free?  (script suggests one, just confirm)
pvesh get /cluster/nextid

# 2. What storage on the host can hold a container root disk?
pvesm status --content rootdir
# Common answers: local-lvm, local-zfs, local. AVOID anything of type cifs or nfs.

# 3. What network bridge does Proxmox use? (script defaults to vmbr0)
ip -br link show type bridge

# 4. Have a strong root password ready, plus your SSH public key path
cat ~/.ssh/id_*.pub        # if you have one to upload
```

If `pvesm status --content rootdir` returns nothing usable, enable `Container` on the `local` storage in the Proxmox UI: **Datacenter → Storage → Edit `local` → Content → check Container**. That makes `/var/lib/vz` (a directory store) usable.

---

## 3. Deploy

```bash
# On the Proxmox host, as root:
cd /root
# (or wherever — script doesn't care about cwd)

# Either pull from upstream:
curl -fsSL https://raw.githubusercontent.com/serversathome-personal/code/main/agentic.sh -o /tmp/agentic.sh

# Or use this repo's tweaked copy (DNS set to 1.1.1.2, local-lvm default,
# stricter network wait, provisioning log, end-of-run verification, random code-server pwd)
scp <your-laptop>:/home/ianm/Development/ProxModClaude/agentic.sh /tmp/agentic.sh

bash /tmp/agentic.sh
```

You'll be prompted for:

| Prompt | Default | Notes |
|--------|---------|-------|
| Container ID | next free | Just hit Enter |
| Hostname | `claude-code` | |
| Root password | *(none)* | For `pct enter` and `ssh` fallback |
| CPU cores | `4` | |
| RAM (MB) | `10240` | 8192 works fine for solo use |
| Swap (MB) | `2048` | |
| Disk size (GB) | `30` | 50 GB if you'll do real work |
| Storage | `local-lvm` | Use whatever §2 step 2 returned |
| IP | `dhcp` | Static if you want a stable IP |
| DNS | `1.1.1.2` | Cloudflare malware-blocking; plain `1.1.1.1` also fine |
| SSH key path | *(none)* | Paste `/root/.ssh/id_ed25519.pub` or similar |
| Cloud/deploy CLIs | `gh railway wrangler` | Space-separated. `all` or `none` accepted. Valid: `gh railway wrangler aws flyctl vercel doctl` |

Then it confirms with a summary, you type `y`, and the script:

1. Downloads the Ubuntu 24.04 template if missing
2. Creates the LXC, sets AppArmor unconfined (Docker-in-LXC requirement)
3. Starts it and waits for working network + DNS + apt mirrors
4. Pushes a provisioning script and runs it (logged to `/tmp/provision-<CT_ID>.log` on the host)
5. Verifies `claude`, `node`, `docker`, `/project`, and `~/.claude/settings.json` all exist
6. Sets a randomly-generated code-server password
7. Prints a summary with **the random code-server password you must save**

Total time: ~10–15 minutes depending on network.

### What the summary looks like

```
╔══════════════════════════════════════════════════╗
║       Claude Code LXC Ready!                    ║
╚══════════════════════════════════════════════════╝

  Container:  112 (claude-code)
  IP:         192.168.1.42
  ...

  Connect:
    Console:  pct enter 112
    SSH:      ssh root@192.168.1.42
    Code:     http://192.168.1.42:8443

  Code-server password (save now — randomly generated, only shown here):
    aB3xK9pL2mN7qR4tY8wZ
    (also retrievable later via: pct exec 112 -- grep PASSWORD /docker/code-server/docker-compose.yml)
```

**Copy that password somewhere safe before scrolling.**

---

## 4. Post-deploy (do all four)

### 4a. Authenticate Claude (and the deploy CLIs)

```bash
pct enter <CT_ID>     # drops into /project automatically
claude                # first run: opens auth URL
gh auth login         # GitHub
railway login         # Railway
wrangler login        # Cloudflare Workers
```

Each prints a URL — open on your laptop, complete the flow, paste the token back. Skip any CLI you don't use; tokens land in `~/.config/<cli>/` and survive restarts.

### 4b. Smoke-test it

```bash
mkdir -p /project/hello && cd /project/hello
claude
# > "write a python script that prints 10 random primes, run it, and show the output"
```

If Claude reads/writes/runs without permission prompts, the auto-approve config is correct.

### 4c. Harden SSH (replace password auth with your key)

If you didn't paste an SSH key during deploy:

```bash
mkdir -p /root/.ssh && chmod 700 /root/.ssh
# Paste your laptop's ~/.ssh/id_*.pub into:
nano /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart ssh
```

### 4d. Schedule a Proxmox backup

CIFS to your NAS is *fine* for backups (it's just file storage, no loop-mounting). In the Proxmox UI:

> **Datacenter → Backup → Add** → Storage: your NAS share → Schedule: daily 02:00 → Selection mode: *Include selected* → pick the CT → Mode: *Snapshot* → Compression: *Zstandard*

Restoring takes ~2 minutes vs. re-running the full deploy.

---

## 5. Day-to-day usage

See [`claude-code-container-workflow.md`](./claude-code-container-workflow.md) for:

- Connection methods (`pct enter`, SSH, browser code-server)
- Where to put projects (`/project/<name>/`)
- Available slash commands (`/code-review`, `/commit`, `/superpowers:*`)
- Snapshots before risky changes
- Adding things later (gh, git identity, MCP servers, custom skills)

---

## 6. Troubleshooting (issues we hit on the first deploy)

### "Container ID X already exists"
Pick a different ID, or destroy the existing one: `pct destroy <ID>`.

### LXC fails to start: `mount: can't read superblock on /dev/loop0`
Your storage is on a CIFS or NFS share. Loop-mounting raw rootfs images over CIFS doesn't work — it's a protocol limitation, not a bug. **Use local storage** (LVM-thin, ZFS, or directory). Verify with:

```bash
pvesm status
# Look at the Type column. cifs/nfs are bad for LXC root.
```

Fix: `pct destroy <ID>`, re-run `agentic.sh`, pick a local storage at the prompt.

### Provisioning "completed" but nothing got installed
The original upstream script could exit silently if early commands failed. The version in this repo:
- Waits for both ICMP and a successful `apt-get update` before provisioning starts
- Streams provisioning to `/tmp/provision-<CT_ID>.log` on the host
- Verifies `claude`, `node`, `docker`, `/project`, and `~/.claude/settings.json` exist before declaring success

If verification fails, the error message points at the log:

```bash
less /tmp/provision-<CT_ID>.log    # find the actual failure
```

### `python: command not found` inside the container
Older deploys missed the `python-is-python3` package. Already fixed in `agentic.sh`. For an existing container:

```bash
apt-get update && apt-get install -y python-is-python3
```

### Code-server forgot the password / want to rotate it
The deploy summary is the only place the original is shown. To recover or rotate:

```bash
# Recover existing
pct exec <CT_ID> -- grep PASSWORD /docker/code-server/docker-compose.yml

# Rotate to a new random one
NEW_PWD=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-20)
echo "New password: $NEW_PWD"
pct exec <CT_ID> -- sed -i "s|PASSWORD: .*|PASSWORD: ${NEW_PWD}|" /docker/code-server/docker-compose.yml
pct exec <CT_ID> -- bash -c "cd /docker/code-server && docker compose up -d --force-recreate"
```

### Proxmox host itself randomly freezes / drops off network
Different problem entirely — host-level instability. See [`proxmox-silent-freeze-guide.md`](./proxmox-silent-freeze-guide.md) for the diagnostic and fix path (typically deep CPU C-states or PCIe ASPM on a mini-PC). Apply on any host showing the symptom.

### Docker container inside the LXC won't start
LXC is privileged with `lxc.apparmor.profile: unconfined` — Docker containers also need `security_opt: [apparmor=unconfined]` in their compose files. The Watchtower and code-server stacks already include this; copy the pattern for any new service.

### `docker compose build` fails with `apparmor_parser: Access denied`
This happens when BuildKit (Docker's default builder) tries to load an AppArmor profile from inside the LXC. The host kernel's AppArmor refuses because the LXC is unconfined and has no privilege to load profiles.

`agentic.sh` now writes `/etc/docker/daemon.json` with `{"apparmor": false}` during provisioning to prevent this. If your container was deployed before that change, apply it once:

```bash
# On the Proxmox host:
pct exec <CT_ID> -- bash -c 'mkdir -p /etc/docker && echo "{\"apparmor\": false}" > /etc/docker/daemon.json && systemctl restart docker'
```

Verify with `pct exec <CT_ID> -- docker info | grep -i apparmor` — should show "AppArmor: false" or similar (or just no AppArmor line at all). Builds should now work.

If you still hit issues, the per-build escape hatch is `DOCKER_BUILDKIT=0 docker compose build` (uses the legacy builder, which doesn't trip on this).

### `apt install` fails with "Unable to locate package"
The provision script wipes the apt cache to save space. Refresh first:

```bash
apt-get update && apt-get install -y <package>
```

---

## 7. What the modified `agentic.sh` does differently from upstream

This repo's `agentic.sh` includes these patches over the upstream version:

| Change | Where | Why |
|--------|-------|-----|
| DNS default `1.1.1.2` | Line 92 | Cloudflare malware-blocking instead of plain `1.1.1.1` |
| Storage default `local-lvm` | Line 79 | Universal Proxmox default; upstream had `truenas-lvm` |
| Two-stage network readiness (ICMP + DNS + apt) | Lines 179-196 | Prevents silent provisioning failure when apt mirrors aren't ready |
| `python-is-python3` package | Line 240 | So `python` works as well as `python3` |
| Provisioning log to host | Lines 526-535 | `/tmp/provision-<CT_ID>.log` survives even on failure |
| Verification step | Lines 540-551 | Fails loudly if `claude`, `node`, `docker`, etc. didn't actually install |
| Random code-server password | Lines 97-98, 557-560 | No more hardcoded `admin` |
| Password shown in summary | Lines 586-588 | Visible once at deploy, recoverable from compose file |
| Optional cloud/deploy CLI prompt | `get_config` | Pick from `gh railway wrangler aws flyctl vercel doctl` at deploy time |
| Always-installed extras | Provisioning script | `lazygit`, `uv`, `direnv` (+ bash hook), `httpie`, `rclone` |
| Python policy: venv-required | `CLAUDE.md` heredoc | Replaces upstream's `--break-system-packages` guidance with mandatory venvs |
| Docker AppArmor disabled at daemon level | Provisioning script | `/etc/docker/daemon.json` set to `{"apparmor": false}` so `docker compose build` works inside the LXC |

---

## 8. Reset / start over

```bash
# Stop + destroy the container completely
pct stop <CT_ID> 2>/dev/null
pct destroy <CT_ID>

# Re-run the deployer
bash /tmp/agentic.sh
```

Snapshots and Proxmox backups (set up in §4d) make this much cheaper than a full redeploy.
