# Try the tested Ginux guest on the Proxmox cluster

This reproduces the workstation result, then attempts the Claude Code installer that `agentic.sh` runs. It does not replace the LXC. The verdict in [`FINDINGS.md`](FINDINGS.md) still stands. The point of this trial is to see how far that installer gets on a kernel other than the workstation's.

## Do not install Ginux on pmve1, pmve2, or pmve3

Those nodes run Ceph and HA fencing. Ginux is a root process that ptraces its guest. Run it inside a normal VM. The VM's own kernel is what matters. The PVE host kernel is not involved once the VM has booted.

Use a new VM, not an existing guest:

- Debian 13, x86_64, systemd
- 2 cores, 4 GiB RAM, 20 GiB disk on `CephStorage`
- `vmbr0`, DHCP is enough
- tag `homelab`
- not HA, `onboot` off

On a cluster node, as root. The image belongs on `QNAP-NFS`, which this cluster already uses for ISOs. The guest disk and the cloud-init drive belong on `CephStorage`, the same place VM 100 keeps its cloud-init drive. `local:cloudinit` is the wrong storage here.

```bash
VMID=$(pvesh get /cluster/nextid)
curl -fL -o /mnt/pve/QNAP-NFS/template/iso/debian-13-generic-amd64.qcow2 \
  https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2
qm create "$VMID" --name ginux-trial --memory 4096 --cores 2 --cpu host \
  --net0 virtio,bridge=vmbr0,firewall=0 --scsihw virtio-scsi-single --ostype l26 \
  --agent enabled=1 --tags homelab --onboot 0 --serial0 socket --vga serial0 \
  --description "Experimental Ginux trial. Not production. Safe to destroy."
qm importdisk "$VMID" /mnt/pve/QNAP-NFS/template/iso/debian-13-generic-amd64.qcow2 CephStorage
qm set "$VMID" --scsi0 "CephStorage:vm-${VMID}-disk-0,discard=on,ssd=1" \
  --boot order=scsi0 --ide2 CephStorage:cloudinit --ciuser ianm \
  --ipconfig0 ip=dhcp --nameserver 192.168.1.1 --sshkeys /root/ginux-trial.pub
qm resize "$VMID" scsi0 20G
qm start "$VMID"
```

Put the SSH public key you will use at `/root/ginux-trial.pub` on the node before `qm set`. `qm importdisk` prints the volume id. If it is not `vm-${VMID}-disk-0`, use the printed id in `--scsi0`.

The generic Debian image does not contain `qemu-guest-agent`, so `qm guest cmd` never answers. Cloud-init on this image uses netplan and systemd-networkd, not `/etc/network/interfaces`. DHCP comes up a few seconds after boot. The 2026-11-13 run was VM 117 and got `192.168.1.146`. That address is a dynamic lease. SSH as `ianm` with the key from `ginux-trial.pub`. The user is in the `sudo` group with `NOPASSWD`.

Do not map the Ceph volume and mount it while the VM is running. If you stop the VM and map the disk to read the journal, unmount it and `rbd unmap` before `qm start`.

## On the VM

```bash
sudo apt-get update
sudo apt-get install -y curl ca-certificates jq gzip tar git bash
cat /proc/sys/kernel/yama/ptrace_scope   # 0 or 1. Both work. 3 does not.
```

`trial-host.sh` installs the helper, then rewrites its shebang to bash when `/bin/sh` cannot open file descriptor 10. Debian's `/bin/sh` is dash, and dash fails that open with `exec: 10: not found`. The supervisor then exits before the guest boots. The 2026-11-13 VM hit that on the first start.

Clone both trees:

```bash
git clone --branch ginux-experiment https://github.com/imcmurray/proxmod-claude.git
git clone https://github.com/gmkurtzer/ginux.git
cd ginux
git checkout 49b4230
```

The runtime we tested is a static x86-64 binary. Copy it from the workstation and skip the Rust build:

```bash
scp ian@ian-hpprodesk600g3mt:/home/ianm/Development/ginux/target/x86_64-unknown-linux-gnu/release/ginux /tmp/ginux-runtime
```

To rebuild instead, apply the patch and build. The patch is the whole difference between upstream `49b4230` and the runtime that ran Node:

```bash
git apply /path/to/proxmod-claude/ginux/patches/49b4230-systemd-node.patch
# rustup: rustup default stable && rustup target add x86_64-unknown-linux-gnu
cargo build -p ginux-init --target x86_64-unknown-linux-gnu --release
```

The changes in that patch:

- `sysinfo` reports the recipe RAM, so systemd 257 boots
- `pidfd_open` returning `ENOENT` for a non-leader thread does not kill the guest (kernel 6.9+, including 6.12 and 7.x)
- systemd mode allows `mmap` and `mprotect`, including writable-and-executable mappings, so Node's V8 can start
- the console file-descriptor table is 4096 entries instead of 512, so Claude's loader can dup the console without killing the guest

Install and import:

```bash
cd ~/proxmod-claude
sudo GINUX_SRC="$HOME/ginux" GINUX_RUNTIME=/tmp/ginux-runtime \
  ginux/scripts/trial-host.sh install
sudo ginux/scripts/trial-host.sh import
sudo ginux start claude
sudo ginux attach claude
```

Log in as `root` / `ginux`. Detach with Ctrl-].

## Inside the guest

```bash
sh /root/bootstrap-closer.sh
```

That script does four things:

1. Unpacks Node.js v26.13.1 into `/opt`, the same tarball that already ran.
2. Pulls Rocky's `libatomic` RPM, because the UBI image does not have it and `dnf` cannot write `/usr`.
3. Downloads the Claude Code native binary from `downloads.claude.ai` and runs `claude install`, which is the installer `agentic.sh` pipes into bash. `chmod` is denied here, so the binary is executed through `/lib64/ld-linux-x86-64.so.2`.
4. Writes `/root/.claude/settings.json` with the same auto-approve list as `agentic.sh`, and a `/project` directory. Plugin installs are left out. Those need `npx`, which this guest has not run.

`BOOTSTRAP_DONE` means the script finished. `CLAUDE_INSTALL_FAILED` means Node is fine and the Claude installer is the thing to read in the console above that line. A new login picks up shell functions named `node` and `claude`.

If a binary exists but will not exec, the guest `chmod` was denied and the file is still mode `0644`. The VM host can set the mode from outside the contract, because the overlay is an ordinary directory:

```bash
sudo chmod -R a+rX \
  /var/lib/ginux/instances/claude/root/opt \
  /var/lib/ginux/instances/claude/root/root/.local \
  /var/lib/ginux/instances/claude/root/root/.claude
```

Then retry inside the guest. The dynamic linker path only works for a dynamically linked ELF. A static Claude binary needs this mode bit. Node on the workstation was dynamic, which is why the linker was enough there.

## What matches the LXC, and what does not

| LXC from `agentic.sh` | This trial |
|---|---|
| Ubuntu 24.04, apt | Rocky 10 UBI. No package install under `/usr`. |
| `claude` on `/usr/local/bin` | Installer target is `/root/.local` or `/root/.claude`. Linking into `/usr` is denied. |
| Node 22 from apt | Node v26.13.1 from the tarball. Proven to print a version and to reach HTTPS. |
| Auto-approve `settings.json` | Same permission list, written by the bootstrap. |
| `/project` | Created by the bootstrap. |
| SSH, `pct enter` | `ginux attach` on the VM. |
| Docker, code-server, Go, Rust, plugins | Not part of this trial. |

## What the 2026-11-13 run did

VM 117, Debian 13, Ginux only inside the VM. The recipe's inbound list is `tcp:*` and `udp:*`. Ginux shares the VM's network namespace.

- `0.0.0.0:8877` inside the guest answered HTTP 200 at `http://192.168.1.146:8877/` from the workstation.
- `127.0.0.1:8878` did not answer on the LAN. `ssh -L` to the VM's localhost did. That is the path for a process bound to localhost.
- Port 80 was `EACCES`. The guest is host uid 65534 with no capabilities, so ports below 1024 do not open.
- Outbound HTTPS returned 200. Outbound port 80 was denied.
- Node v26.13.1 printed its version once `LD_LIBRARY_PATH=/opt/lib` was set. `chmod` during `tar` was denied 1085 times. The `node` binary was already mode `0755`.
- Claude Code 2.1.323's linux-x64 binary is 346 MiB. A single `read()` of it returns `EPERM`. Hashing in 1 MiB chunks matched the manifest. `chmod +x` on the download was denied, and the dynamic linker ran it.
- The first `claude install` returned 0. `~/.local/bin/claude --version` printed `2.1.323 (Claude Code)`.
- Launching that binary killed the guest until the console fd table was raised from 512 to 4096 (`native console descriptor table full`).
- A second `claude install` printed the success screen and then sat for more than five minutes on denied writes under `/usr/lib/sysimage/rpm`. Stopping it let the bootstrap finish: `CLAUDE_INSTALL_FAILED` for that invocation, the version printed again, settings and `/project/CLAUDE.md` were written, `BOOTSTRAP_DONE`.

Logs on the VM if it dies: `/var/lib/ginux/instances/claude/console.log` and `audit.log`. `exit.status` appears only after the instance stops. VM 117 was left running. The Ginux `claude` guest was left running inside it. Neither is in HA.
