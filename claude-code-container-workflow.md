# Claude Code Container — Daily Workflow

Quick reference for working in the Claude Code LXC container deployed by `agentic.sh`.

## Getting in

| Method | Command | Use when |
|--------|---------|----------|
| Proxmox console | `pct enter <CT_ID>` (run on Proxmox host) | Quick admin tasks, no SSH needed |
| SSH | `ssh root@<container-ip>` | Normal day-to-day work from laptop |
| Browser VS Code | `https://<container-ip>:8443` (self-signed cert) | Editing files in a GUI, password set during deploy |

## Where to put things

| Path | Purpose |
|------|---------|
| `/project/` | All your code projects — survives reboots, gets backed up |
| `/project/<name>/` | One subdirectory per project; run `claude` from inside |
| `/docker/<service>/docker-compose.yml` | Long-running Docker services; Watchtower auto-updates them |
| `/root/.claude/settings.json` | Claude Code config (auto-approve permissions, plugins, env vars) |
| `/root/.claude/skills/` | Custom skills directory |

## Plugins / slash commands available

These are pre-installed by `agentic.sh`. Type `/` inside Claude to see the full picker.

| Command | What it does |
|---------|--------------|
| `/code-review` | Multi-agent PR review with confidence scoring |
| `/commit` | Stage, write a sensible commit message, commit |
| `/push` | Push current branch to origin |
| `/pr` | Open a pull request from current branch |
| (optional) `/superpowers:*` | Brainstorm, plan, execute (install manually: `npx -y claude-plugins install @obra/superpowers-marketplace/superpowers`) |
| `/remote-control` | Show QR code to control this session from claude.ai or mobile |

## Backups (set this up once)

The QNAP CIFS share is fine for backups (the loop-mount issue only affects live LXC root disks).

In Proxmox UI:
**Datacenter → Backup → Add**
- Storage: `QNAP-NAS`
- Schedule: daily 02:00
- Selection mode: *Include selected*
- Pick your CT
- Mode: *Snapshot*
- Compression: *Zstandard (fast and good)*

Restoring takes ~2 minutes vs. re-running `agentic.sh` and re-authenticating Claude.

## Snapshots (cheap experiment safety)

Before risky changes:
```bash
pct snapshot <CT_ID> pre-experiment
```
Roll back:
```bash
pct rollback <CT_ID> pre-experiment
```
Delete when done:
```bash
pct delsnapshot <CT_ID> pre-experiment
```

## Useful one-liners

```bash
# How big is the container actually?
pct exec <CT_ID> -- df -h /

# What containers (Docker) are running inside?
pct exec <CT_ID> -- docker ps

# Tail Claude Code's logs
pct exec <CT_ID> -- tail -f /root/.claude/logs/*.log 2>/dev/null

# Update everything inside
pct exec <CT_ID> -- bash -c 'apt-get update && apt-get upgrade -y && npm update -g'
```

## Adding things later

| Need | How |
|------|-----|
| GitHub CLI | `apt-get install gh && gh auth login` |
| Python `python` symlink | `apt-get install python-is-python3` |
| Set git identity globally | `git config --global user.name "..." && git config --global user.email "..."` |
| Add a new MCP server | Edit `/root/.claude/settings.json`, add under `mcpServers` |
| Add a custom skill | Drop a directory under `/root/.claude/skills/<name>/` with a `SKILL.md` |

## Resetting Claude state

```bash
# Forget current auth (re-login next time)
rm /root/.claude/auth.json   # or wherever the token lives — check ls ~/.claude/

# Wipe a stuck session
rm -rf /root/.claude/projects/<project-hash>/
```

## When something breaks

1. **Claude command vanished from PATH** — `source ~/.bashrc` or check `ls -la /usr/local/bin/claude`
2. **Docker containers won't start** — check AppArmor: `cat /etc/pve/lxc/<CT_ID>.conf` should include `lxc.apparmor.profile: unconfined`
3. **Container won't start** — `lxc-start -F -n <CT_ID> -l DEBUG -o /tmp/lxc.log` then read the log
4. **Provisioning failed during deploy** — check `/tmp/provision-<CT_ID>.log` on the Proxmox host
