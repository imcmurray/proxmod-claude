# Proxmox Alerting — ntfy Push Notifications

How cluster alerts reach your phone, what each piece does, and how to test or change it.

Built for the `theMcMurrays` cluster (pmve1/2/3) but the pattern is reusable on any PVE cluster.

---

## 0. The short version

**Nothing ntfy-specific is installed.** ntfy.sh is just an HTTPS endpoint; every alert is a plain `POST` made at the moment there's something to say. There is no daemon, agent, or listener on any node.

Two **independent** senders push to the same topic:

| | What it is | Where it lives | Covers |
|---|---|---|---|
| **1. PVE notifications** | Cluster config — *not a process* | `/etc/pve/notifications.cfg` (pmxcfs, replicated) | backups, replication, HA fencing, package updates |
| **2. Health-check timer** | systemd timer on **each** node, every 5 min | `/usr/local/sbin/cluster-health-alert.sh` | node down, Ceph health, NIC hangs, stale backups, full disk |

They're independent on purpose: #1 covers what PVE knows about, #2 covers the (large) set of things PVE does **not** notify about.

Between events, nothing is running at all.

---

## 1. PVE's built-in notifications

### What it is

Config, not a process. When a PVE daemon generates an event, **that node** makes the HTTP POST inline and moves on. The sender is whichever node happened to do the work — no coordination, one event, one push.

Because the config lives on pmxcfs it is automatically identical on all nodes and survives rebuilding any single node.

### The pieces

```
# /etc/pve/notifications.cfg

webhook: ntfy                       <- the target (where to send)
    url https://ntfy.sh/<topic>
    method post
    body <base64 of "{{ message }}">
    header name=Title,value=<base64 of "Proxmox {{ severity }}: {{ title }}">
    header name=Tags,value=<base64 of "rotating_light">

matcher: ntfy-failures              <- the routing rule (what to send)
    match-severity warning,error
    mode all
    target ntfy

matcher: default-matcher            <- built-in, leave alone
    target mail-to-root
```

Matchers are additive: a notification goes to **every** matcher that matches it. `default-matcher` keeps a local mail copy of everything; `ntfy-failures` pushes only the bad news.

### Severity routing — deliberate

Only `warning` and `error` push to the phone. A successful nightly backup notifies `mail-to-root` only.

This is intentional. Routine success notifications are how alerting systems get ignored — within a fortnight you stop reading them, and then you miss the one that mattered.

### ⚠️ The matcher trap that cost us a night

Creating the matcher like this **silently matches nothing, ever**:

```bash
# WRONG
pvesh create /cluster/notifications/matchers --name ntfy-failures \
  --mode all --match-severity warning --match-severity error --target ntfy
```

Passing `--match-severity` twice creates **two separate rules**, and `mode all` requires *every* rule to match. A notification cannot be both `warning` **and** `error`, so nothing ever routes.

```bash
# RIGHT — one rule containing a list
pvesh create /cluster/notifications/matchers --name ntfy-failures \
  --mode all --match-severity "warning,error" --target ntfy
```

**And the reason it wasn't caught:** the built-in target test bypasses matchers entirely.

```bash
pvesh create /cluster/notifications/targets/ntfy/test    # tests DELIVERY only
```

That proves the webhook works. It does **not** prove routing. To test routing you must generate a real notification at the severity you care about:

```bash
vzdump <vmid> --storage does-not-exist     # produces a genuine error notification
# expect: INFO: notified via target `ntfy`
```

### What PVE does NOT notify about

This is the important limitation, and the whole reason section 2 exists:

- ❌ A node going offline
- ❌ Ceph `HEALTH_WARN` / `HEALTH_ERR`
- ❌ NIC hangs / link failure
- ❌ Disk filling up

PVE notifications cover backups, replication, HA fencing, and package updates. Node-down and storage-health are **not** among them.

---

## 2. The cluster health-check timer

### What it is

A systemd timer on **every** node, firing every 5 minutes. Each run executes a short script and exits — no resident process.

```
/usr/local/sbin/cluster-health-alert.sh      the script
/etc/cluster-health-alert.conf               NTFY_URL (mode 600 — treat as a secret)
/var/lib/cluster-health-alert/state          last-known state, for change detection
/etc/systemd/system/cluster-health-alert.{service,timer}
```

### What it checks

| Check | Scope | Priority |
|---|---|---|
| Cluster lost quorum | leader | urgent |
| Ceph not `HEALTH_OK` | leader | high |
| Peer node unreachable on LAN | leader | urgent |
| Newest backup older than 3 days | leader | high |
| `e1000e` Hardware Unit Hang | every node | high |
| `eno1` watchdog fired | every node | high |
| Root filesystem ≥ 90 % | every node | high |

### Three design choices

**Runs on every node.** If it only ran on one and that node died, nothing would tell you. Running everywhere means the survivors report the casualty.

**Leader election prevents triple-alerting.** Cluster-wide checks run only on the node with the **lowest online nodeid**; node-local checks always run locally. So a Ceph problem is one push, not three. If the leader dies, the next-lowest node inherits the role and reports it — leadership follows availability rather than being pinned to a host.

```bash
# who is leader right now
MYID=$(corosync-cfgtool -s | sed -n 's/^Local node ID \([0-9]*\).*/\1/p')
LOW=$(pvecm status | awk '/^ *0x/{print $1}' | sed 's/0x0*//' | sort -n | head -1)
[ "$MYID" = "$LOW" ] && echo LEADER || echo follower
```

**Alerts only on state *change*.** A persistent fault pushes once, and again when it recovers ("pmve2 NOT reachable" → later → "pmve2 reachable again"). Not every 5 minutes until you mute the topic. Recovery messages matter as much as failure ones — they tell you whether to get out of bed.

State lives in `/var/lib/cluster-health-alert/state`; deleting a line re-arms that alert.

---

## 3. Operations

### Subscribe

Install the **ntfy** app, subscribe to the topic in `/etc/cluster-health-alert.conf`.

The topic string is the only thing protecting it — anyone who knows it can read your alerts and post to them. Treat it as a secret. Alerts carry node names and health text, never credentials.

### Test delivery (does the webhook work?)

```bash
pvesh create /cluster/notifications/targets/ntfy/test
curl -s "https://ntfy.sh/<topic>/json?poll=1" | tail -1     # confirm it arrived
```

### Test routing (do failures actually reach it?)

```bash
vzdump <vmid> --storage does-not-exist
# look for: INFO: notified via target `ntfy`
```

### Test the health checker

Force a state change and watch it fire:

```bash
sed -i 's/^disk_<host>=OK/disk_<host>=FULL/' /var/lib/cluster-health-alert/state
/usr/local/sbin/cluster-health-alert.sh
journalctl -t cluster-health -n 5
```

### Rotate the topic

```bash
NEW="pmve-$(openssl rand -hex 8)"
# on every node:
sed -i "s|^NTFY_URL=.*|NTFY_URL=\"https://ntfy.sh/$NEW\"|" /etc/cluster-health-alert.conf
# once, cluster-wide:
pvesh set /cluster/notifications/endpoints/webhook/ntfy --url "https://ntfy.sh/$NEW"
```

### Nothing is arriving?

1. `systemctl status cluster-health-alert.timer` on each node
2. `journalctl -t cluster-health` — the script logs every state change and any push failure
3. `curl -d test https://ntfy.sh/<topic>` from a node — proves outbound HTTPS works
4. Check the matcher really has `match-severity warning,error` on **one** line (§1 trap)

---

## 4. Known limitations

- **Requires outbound HTTPS to ntfy.sh.** If the internet drops, alerts stop — and there is no alert about the alerting being down. This is inherent to any off-cluster notification service.
- **Deliberately off-cluster anyway.** Self-hosting ntfy on the cluster it monitors would go silent in exactly the scenarios that matter most. If you want self-hosted, run it somewhere else entirely (a Pi, a NAS, a different box).
- **5-minute granularity** on the health checks. A node that dies and recovers inside that window may be missed.
- **ntfy.sh is a public service.** The topic is bearer auth and nothing more. For anything sensitive, self-host elsewhere or use a topic with access tokens.
