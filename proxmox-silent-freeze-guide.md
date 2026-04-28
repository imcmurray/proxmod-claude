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
journalctl -k --since "30 days ago" | grep -iE "panic|oops|out of memory|killed process|hung task|blocked for more than|nvme.*reset|nvme.*timeout|cifs.*reconnect|watchdog|soft lockup"
```

Empty result → silent hang confirmed. Continue with this guide.
Hits → diagnose the specific subsystem instead.

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

# Persist via /etc/network/interfaces — append under the iface block:
#     post-up /sbin/ethtool -K eno1 tso off gso off gro off lro off
```

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

---

## 10. Verification checklist after the fix

- [ ] `cat /proc/cmdline` shows all four kernel flags
- [ ] No `Unsafe Shutdowns` increase in SMART over a week of uptime
- [ ] `journalctl -k --since "1 week ago" | grep -iE "AER|aspm|nvme.*reset"` is empty or stable
- [ ] `uptime` reflects actual continuous runtime
- [ ] Web UI / SSH responsive throughout

---

## Quick command reference

```bash
# Triage
journalctl --list-boots
journalctl -b -1 --no-pager | tail -50
journalctl -k --since "30 days ago" | grep -iE "panic|oops|out of memory|hung task|nvme.*reset|cifs.*reconnect|watchdog|soft lockup"
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
```
