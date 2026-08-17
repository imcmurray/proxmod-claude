# Proxmox Silent Freeze — Diagnostic & Fix Guide

A reusable runbook for Proxmox hosts (especially mini-PCs / SFF business desktops) that randomly freeze, drop off the network, and require a hard power cycle.

---

## 1. When to use this guide

Apply when a Proxmox host shows **all** of:

- Becomes unresponsive at random intervals (hours to weeks apart)
- Drops off the network during the freeze (web UI, SSH, ping all dead)
- Requires a hard power-button reset — orderly shutdown is impossible
- Elevated `Unsafe Shutdowns` count in NVMe SMART
- **No useful kernel log entries before the freeze** — the kernel goes dark with no panic, OOM, or hung-task trace

If logs *do* show panics, OOM kills, hung tasks, NVMe resets, or CIFS/NFS reconnect storms before the death, **this is the wrong guide** — you have a software/memory/storage issue, not a silent hardware-level hang.

Two common false positives to rule out before going further — both present as "the host stopped responding":

- **The host is still running** (console/SSH answer, journal keeps writing, it recovers on its own) → corosync quorum loss, not a freeze. See [§10](#10-not-a-freeze-corosync-quorum-loss).
- **Several nodes died at once** → site power event, not per-node hardware. Also §10.
- **A guest is unreachable but the host is fine** → if its disk lives on CIFS/SMB, see [§9a](#9a-what-will-fail-or-corrupt-actually-looks-like).

---

## 2. Confirm it is a silent hang

Run on the affected host:

```bash
# Clean shutdown vs. abrupt cutoff?
journalctl --list-boots

# For each suspicious boot (one that ended without a planned reboot):
journalctl -b <boot-id> --no-pager | tail -50
```

Interpretation:

| What you see at the end of a boot | Meaning |
|-----------------------------------|---------|
| `Reached target poweroff.target - System Power Off` | Clean shutdown — not a freeze |
| Service stop sequence (`Stopped target ...`) | Clean reboot — not a freeze |
| Routine log entries that just stop mid-sentence | **Silent freeze** |

Then sweep 30 days of kernel logs for software-side culprits:

```bash
journalctl --since "30 days ago" _TRANSPORT=kernel | grep -iE "panic|oops|out of memory|killed process|hung task|blocked for more than|nvme.*reset|nvme.*timeout|cifs.*reconnect|watchdog|soft lockup"
```

Empty result → silent hang confirmed. Continue with this guide.
Hits → diagnose the specific subsystem instead.

> ### ⚠️ `journalctl -k` silently means "this boot only"
>
> **`-k` implies `-b`.** So `journalctl -k --since "30 days ago"` does *not* search 30 days — it
> searches the current boot, then filters that by date. On a host that rebooted an hour ago it
> returns almost nothing, and the emptiness looks exactly like a clean bill of health.
>
> This is a nasty failure mode for *this* guide in particular, because you run these sweeps
> **right after a reboot** — precisely when the current boot is empty.
>
> ```bash
> journalctl -k --since "30 days ago"            # WRONG - current boot only
> journalctl --since "30 days ago" _TRANSPORT=kernel   # RIGHT - spans all boots
> ```
>
> Real cost of getting this wrong: on one cluster it produced "zero NIC hangs in 30 days on all
> three nodes", which ruled out §6a and misattributed a hang to a kernel upgrade. The correct
> query found **458,000 hangs going back two years**. `-k -b` is fine when you *mean* the current
> boot (see §4) — just never pair `-k` with `--since`.

Also confirm SMART is healthy (rule out a dying drive masquerading as a host hang):

```bash
smartctl -a /dev/nvme0 | grep -E "Critical Warning|Available Spare|Percentage Used|Media and Data Integrity Errors|Unsafe Shutdowns|Error Information Log Entries"
```

`Unsafe Shutdowns` ≫ `Power Cycles - 1` confirms repeated unclean halts.

---

## 3. Identify the hardware

```bash
dmidecode -s system-manufacturer
dmidecode -s system-product-name
lspci | grep -iE "ethernet|network"
lspci | grep -iE "nvme|sata"
uname -r
```

Note the model, the NIC chipset, and the storage controller. Different boxes need different escalation paths (see §7).

---

## 4. First-line fix — kernel boot parameters

This single change resolves the majority of silent-freeze cases on Intel mini-PCs and SFF desktops.

Edit `/etc/default/grub`. Find:

```
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
```

Change to:

```
GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_idle.max_cstate=1 processor.max_cstate=1 pcie_aspm=off nvme_core.default_ps_max_latency_us=0"
```

Apply and reboot:

```bash
update-grub
reboot
```

What each flag does:

| Flag | Effect |
|------|--------|
| `intel_idle.max_cstate=1` | Caps the Intel idle driver to C1. Prevents the CPU from entering deep sleep states it doesn't reliably wake from. |
| `processor.max_cstate=1` | Same cap for the generic ACPI idle driver (belt + suspenders). |
| `pcie_aspm=off` | Disables PCIe Active State Power Management globally. Prevents the NVMe / NIC PCIe link from entering low-power states the device doesn't recover from. |
| `nvme_core.default_ps_max_latency_us=0` | Disables NVMe Autonomous Power State Transitions (APST). Prevents the SSD from entering low-power states it can hang in — particularly relevant for OEM/laptop drives like WD SN740, Kingston OM8, SK hynix BC711. |

**Cost:** small idle power penalty (a few watts). Worth it.

Run for at least one week. If freezes stop, you're done.

### Measured effect

On a 3-node cluster of identical HP EliteDesk 800 G4 DM boxes (dual NVMe: WD PC SN740 + WD_BLACK SN770), only one node had these flags applied. Counting `AER:` lines in `journalctl -k -b`:

| Node | `pcie_aspm=off` | PCIe AER errors | Over | Rate |
|------|-----------------|-----------------|------|------|
| pmve1 | no | 64 | 22 days | ~3/day |
| pmve2 | **yes** | **0** | **39 days continuous** | **0** |
| pmve3 | no | 186 | 18 days | ~10/day |

The errors are *correctable* — they recover — but each one is a PCIe link retrain that stalls I/O. Zero across 39 continuous days on the patched node is the clearest signal available that the flag is doing the work. Use this as your before/after metric:

```bash
journalctl -k -b | grep -c "AER:"
```

---

## 5. Verify the parameters took effect

After reboot:

```bash
cat /proc/cmdline                          # should show all four flags
cat /sys/module/intel_idle/parameters/max_cstate   # should be 1
cat /sys/module/pcie_aspm/parameters/policy        # should be 'default' or absent
nvme get-feature /dev/nvme0 -f 0x0c -H | grep -i "Autonomous Power State Transition Enable"  # should be 0
```

---

## 6. If the host still freezes — escalation

### 6a. NIC offload (Intel I219 / e1000e specifically)

Some Intel I219 firmware revisions hang under load with TCP segmentation offload. Test:

```bash
# Find your interface
ip -br link

# Disable hardware offloads (replace eno1 with yours)
ethtool -K eno1 tso off gso off gro off lro off

# Persist via /etc/network/interfaces — append under the iface block
# (put it on the BRIDGE stanza if eno1 is `inet manual` and brought up by a bridge):
#     post-up /sbin/ethtool -K eno1 tso off gso off gro off lro off
```

#### What a hang actually looks like

The link reports **`UP,LOWER_UP` with its IP still bound** — it simply moves no packets. Link
state is not a liveness check, so this presents as "the host is down" even though the host is
fine. On a multi-homed box, the giveaway is that it still answers on its *other* NICs.

```
e1000e 0000:00:1f.6 eno1: Detected Hardware Unit Hang:      <- repeats every ~2s
```

Recovery is a NIC reset (`ip link set eno1 down; ip link set eno1 up`), but the fix is disabling
the offloads above.

#### Measured effect

Same 3-node EliteDesk 800 G4 DM cluster as §4. Counting hangs across **all** boots
(`journalctl _TRANSPORT=kernel | grep -c "Hardware Unit Hang"` — see the §2 warning about `-k`):

| Node | Hangs before fix | Worst period | Hangs since offloads disabled |
|------|------------------|--------------|-------------------------------|
| pmve1 | 55,879 | 39,758 in one month | **0** |
| pmve2 | 298,694 | 149 in a 5-minute storm | **0** |
| pmve3 | 103,736 | 94,180 in one month | **0** |

**~458,000 hangs across two years**, all three nodes, on stock settings. Zero on all three since
the offloads were disabled.

Two things that make this hard to spot:

- **It is episodic.** It storms during a particular boot, stops when that node reboots, then
  recurs months later on a *different* node. A quiet week proves nothing.
- **`dmesg` only covers the current boot.** Check the journal across boots or you will conclude
  a chronically affected host is clean — see the §2 warning.

#### Automatic recovery (optional but cheap)

Because a hang is silent and self-sustaining, a small watchdog turns a multi-hour outage into a
~1-minute one. Fire **only** when both conditions hold, so log noise alone never bounces the NIC:

```bash
#!/bin/bash
# /usr/local/sbin/eno1-hang-watchdog.sh   (systemd timer, every 60s)
journalctl -k --since "120 seconds ago" | grep -q "Hardware Unit Hang" || exit 0
ping -c2 -W2 <gateway> >/dev/null 2>&1 && exit 0     # hang logged but traffic flows -> no action
logger -t eno1-watchdog "hang + gateway unreachable - resetting eno1"
ethtool -K eno1 tso off gso off gro off lro off
ip link set eno1 down; sleep 3; ip link set eno1 up
```

(`-k` is correct *here* — you deliberately want the current boot.)

### 6b. i915 iGPU power management

Even on a headless server, the integrated GPU can hang the system. Add to the GRUB cmdline:

```
i915.enable_dc=0 i915.enable_psr=0
```

### 6c. BIOS / firmware (often the real fix)

In BIOS:

- **Update to the latest BIOS** — silent-freeze fixes ship in firmware all the time
- Disable **C-States** entirely (heavy hammer; small perf/idle-power cost)
- Disable **ASPM** in BIOS (in addition to the kernel flag)
- Disable **Intel ME / AMT** if not used
- Disable **ErP / Deep Sleep / Ultra Low Power** modes
- Disable **Wake-on-LAN** if you don't need it

For the HP EliteDesk 800 G4 DM specifically: settings live under *Advanced → Power Management Options* and *Advanced → System Options*. HP releases BIOS updates regularly via their support site.

### 6d. Replace the NVMe (last resort, but cheap)

OEM laptop drives (WD SN740, Kingston OM8, SK hynix BC711) are the most common cause of PCIe-link-related hangs. Swapping to a retail consumer drive (Samsung 970/980, WD Black SN770/850, Crucial P3 Plus) often fixes it outright. Cheap test if you have a spare.

---

## 7. Hardware-specific notes

### HP EliteDesk 800 G4 DM (Coffee Lake i5/i7, 35W)
- Intel I219-LM NIC (solid)
- Usually ships with OEM M.2 NVMe — common silent-freeze contributor
- BIOS power options are aggressive by default; tune them down

### Intel NUC (any 8th–11th gen)
- Same C-state/ASPM symptoms; same fix
- Watch for **firmware updates** — Intel was particularly active patching power-state bugs

### Beelink / Minisforum / other consumer mini-PCs
- Often Realtek NIC (r8125/r8168) — replace driver with `r8125-dkms` if you see periodic NIC drops
- Often cheaper NVMe — drive replacement is more frequently the fix

---

## 8. Capturing the next freeze (if it still happens)

A silent hang means the kernel can't write to local disk before going dark. To capture the cause:

### 8a. Netconsole (ship dying messages over UDP to another machine)

On a second host, listen:

```bash
nc -l -u -p 6666
```

On the freezing host, load netconsole pointing at it:

```bash
# Replace with your IPs and the freezing host's NIC name
modprobe netconsole netconsole=6666@<freezing-host-ip>/eno1,6666@<listener-ip>/<listener-mac>
```

Persist via `/etc/modules-load.d/netconsole.conf` and `/etc/modprobe.d/netconsole.conf`.

### 8b. Hardware watchdog with auto-reboot

Force the system to reboot on hang instead of staying dark forever:

```bash
apt-get install watchdog
# Edit /etc/watchdog.conf — uncomment:
#   watchdog-device = /dev/watchdog
#   max-load-1 = 24
systemctl enable --now watchdog
```

### 8c. Pstore (capture kernel oops to NVRAM if firmware supports it)

```bash
ls /sys/fs/pstore/
# After a crash, files appear here with the last kernel messages
```

---

## 9. Storage hygiene (independent but related)

- **Do not put LXC root disks on CIFS/SMB storage.** Loop-mounting raw filesystem images over CIFS will fail or corrupt — CIFS lacks the file semantics the loop driver needs. Use local LVM-thin, ZFS, or iSCSI/RBD.
- **NFS for LXC raw is also fragile** but works on some setups. Prefer block storage.
- Use the NAS for **ISOs, container templates, and backups only** (set those content types in *Datacenter → Storage*).

### 9a. What "will fail or corrupt" actually looks like

The failure is nastier than the one-liner suggests, and it presents as a **guest** problem rather than a storage one — which is why it gets misdiagnosed.

**Mechanism.** The LXC rootfs is a `.raw` file on the CIFS mount, attached via `/dev/loopN`. If the SMB session drops — even for a few seconds — the loop device's backing handle is invalidated. The container **keeps running** with a dead filesystem underneath it. It does not crash, does not stop, and does not recover on its own.

**Symptoms:**

```bash
pct status 111
# status: running          <-- looks fine

pct exec 111 -- ls /
# lxc-attach: Input/output error - Failed to exec "ls"    <-- filesystem is gone
```

In `dmesg` you'll see the session drop, then write failures against the loop device:

```
CIFS: VFS: \\<nas> sends on sock ... stuck for 15 seconds
CIFS: trying to dequeue a deleted mid
CIFS: VFS: \\<nas> Send error in SessSetup = -512
CIFS: VFS: No writable handle in writepages rc=-9        <-- EBADF: lost write handle
I/O error, dev loop0, sector 0 op 0x1:(WRITE)
EXT4-fs (loop0): I/O error while writing superblock
Aborting journal on device loop0-8
```

Note the asymmetry: **reads often still work while writes fail.** `fsck` can pass (read-only check) while `mount` still fails with `can't read superblock` — because mounting requires a superblock *write*.

**Recovery:**

```bash
pct stop <CTID>            # loop device releases
losetup -a                 # confirm it's gone
pct fsck <CTID>            # expect "recovering journal" + "errors, check forced"
pct fsck <CTID>            # re-run; must come back "clean"
pct start <CTID>
```

`pct fsck` exit code 1 means *errors were corrected* — that's success, not failure. Re-run until you get exit 0 / "clean" before starting.

**A stale mount lies about existence.** A transient `stat()` EIO makes PVE report:

```
volume 'NAS:111/vm-111-disk-0.raw' does not exist
```

when the file is present and readable seconds either side. Verify before concluding data loss:

```bash
ls -l /mnt/pve/<STORE>/images/<CTID>/
pvesm list <STORE> | grep <CTID>
for i in $(seq 1 10); do stat -c %s <path> >/dev/null 2>&1 && echo ok; done   # stability
```

A container stuck in the *permanent* version of this state (volume genuinely gone) is what an unrecoverable `pve8to9`/`pct` "volume does not exist" failure looks like.

### 9b. Backing up guests that live on CIFS

Backing up *from* CIFS is what most often triggers 9a — the backup is the sustained load that breaks the session.

- **vzdump LXC `suspend` mode is the dangerous one.** CIFS can't snapshot, so vzdump falls back to walking the live filesystem with `rsync`. On a container with ~1.7M files this reliably stalls the SMB session and kills the container mid-backup. Symptom: `rsync: ... Input/output error (5)` then `exit code 23`.
- **`snapshot` mode on real block storage is safe.** The same container, after migrating its rootfs to Ceph RBD: snapshot mode, 25 minutes, **zero downtime**, verified archive.
- **Throttle if you must read/write CIFS at volume** — `vzdump --bwlimit 60000` (KiB/s) keeps the session under the stall threshold. Unthrottled full-speed writes produce `zstd: /*stdout*\: Host is down` or `job failed with err -112 - Host is down` at 100% transfer.
- **Never `kill` a running vzdump** — it orphans an LVM thin snapshot (`snap_vm-<id>-disk-0_vzdump`). Stop it properly:
  ```bash
  pvesh delete /nodes/<node>/tasks/<UPID>
  lvs | grep vzdump          # verify nothing orphaned
  ```
- **Verify archives; don't trust exit 0.** On flaky storage a "successful" backup is not proof of a usable one:
  ```bash
  zstd -t /mnt/pve/<STORE>/dump/<archive>.tar.zst     # byte count must match vzdump's "Total bytes written"
  zstd -dc <archive>.tar.zst | tar -tf - | head       # must include ./etc/vzdump/pct.conf
  ```

**The durable fix is migration, not tuning.** Move guest disks to block storage and leave the NAS for backups/ISOs/templates:

```bash
pct move-volume <CTID> rootfs <BLOCKSTORE> --delete 0    # --delete 0 keeps the original as unused0
qm  move_disk   <VMID> scsi0 <BLOCKSTORE> --delete 0     # VMs can move online
```

Note LXC rootfs moves between different storage types are **file-level (rsync)**, not block clones — so the destination gets a fresh filesystem rather than inheriting any damage. Budget accordingly: ~39 GB / 1.74M files took ~15 min at 44 MB/s.

---

## 10. Not a freeze: corosync quorum loss

The most common false positive for this guide. The host is **still running** — it just stops answering the web UI, `pct`, `qm`, and anything touching `/etc/pve`.

**Tell them apart:**

| | Silent freeze | Quorum loss |
|---|---|---|
| Ping / SSH | dead | **responds** |
| Console | dead | **responds** |
| Recovery | hard power cycle | **recovers by itself** |
| Journal | stops mid-sentence | **continues throughout** |

If the journal keeps writing across the outage, it was never frozen. Check corosync instead:

```bash
journalctl -u corosync --since "30 days ago" | grep -cE "retransmit|token|link down|Sync members"
corosync-cfgtool -s          # how many links?
```

Tens of events per month means the token is timing out. `pmxcfs` goes read-only on quorum loss, which is what makes `/etc/pve` — and therefore the whole management plane — hang.

**Root cause, nearly always: corosync sharing a link with storage traffic.** Corosync needs sub-millisecond, jitter-free latency. Ceph OSD replication does not care about your latency.

```bash
grep -E "ring[0-9]_addr" /etc/pve/corosync.conf     # corosync's link(s)
grep -E "cluster_network|public_network" /etc/ceph/ceph.conf
ceph osd metadata | grep -E '"id"|back_addr'        # where replication ACTUALLY runs
```

`back_addr` is replication, `front_addr` is client traffic. If `back_addr` sits on the same subnet as a `ringN_addr`, that's the bug. A classic setup error is putting Ceph `public_network` on a fast dedicated fabric while leaving `cluster_network` — the *heavier* of the two — on the shared LAN.

**Fix — move replication off the corosync link:**

```bash
# Validate the target fabric FIRST, at the MTU you'll actually use:
ping -c1 -M do -s 8972 <each-other-node-on-target-net>

cp /etc/pve/ceph.conf /root/ceph.conf.bak-$(date +%Y%m%d-%H%M%S)
ceph osd set noout
# edit cluster_network -> the dedicated fabric, then restart OSDs ONE AT A TIME:
systemctl restart ceph-osd@<id>          # wait for active+clean between each
ceph osd unset noout
ceph osd metadata | grep back_addr       # confirm it moved
```

Two traps:

- **`/etc/pve` is pmxcfs and does not honour `sed -i`** (rename semantics). Edit via `/tmp` and `cp` back.
- **Get the CIDR right.** `192.168.3.251/28` is in **`192.168.3.240/28`**, not `192.168.3.0/28`. A wrong network means OSDs can't bind and won't start.

Also add a second corosync link for redundancy (`ring1_addr` on a different fabric) and remember to bump `config_version` in `corosync.conf` — PVE ignores the file otherwise.

**Related false positive:** several nodes dying *simultaneously* is a site power event, not per-node hardware. Check whether the down-times cluster within a couple of minutes and whether they all return together — and whether any node actually runs a UPS daemon (`nut`, `apcupsd`).

---

## 11. Verification checklist after the fix

- [ ] `cat /proc/cmdline` shows all four kernel flags
- [ ] No `Unsafe Shutdowns` increase in SMART over a week of uptime
- [ ] `journalctl --since "1 week ago" _TRANSPORT=kernel | grep -iE "AER|aspm|nvme.*reset"` is empty or stable
- [ ] `uptime` reflects actual continuous runtime
- [ ] Web UI / SSH responsive throughout

---

## Quick command reference

```bash
# Triage
journalctl --list-boots
journalctl -b -1 --no-pager | tail -50
journalctl --since "30 days ago" _TRANSPORT=kernel | grep -iE "panic|oops|out of memory|hung task|nvme.*reset|cifs.*reconnect|watchdog|soft lockup"
#   NB: never `journalctl -k --since ...` — -k implies -b (current boot only). See §2.
smartctl -a /dev/nvme0
free -h
ps auxf | awk '$8 ~ /D/'

# Identify
dmidecode -s system-manufacturer
dmidecode -s system-product-name
lspci | grep -iE "ethernet|network|nvme"
uname -r

# Apply fix (edit /etc/default/grub then:)
update-grub && reboot

# Verify
cat /proc/cmdline
cat /sys/module/intel_idle/parameters/max_cstate
nvme get-feature /dev/nvme0 -f 0x0c -H
journalctl -k -b | grep -c "AER:"          # before/after metric for pcie_aspm=off (§4)

# Rule out the false positives FIRST (§10)
journalctl -u corosync --since "30 days ago" | grep -cE "retransmit|token|link down"
ceph osd metadata | grep -E '"id"|back_addr'    # replication sharing corosync's link?
systemctl list-units --state=running | grep -iE "nut|apcups"   # UPS present?

# CIFS-backed LXC gone bad (§9a) — "running" but filesystem dead
pct status <CTID>; pct exec <CTID> -- ls /   # status running + EIO = stale loop device
dmesg -T | grep -iE "cifs|loop|superblock"
pct stop <CTID> && pct fsck <CTID> && pct fsck <CTID> && pct start <CTID>
```
