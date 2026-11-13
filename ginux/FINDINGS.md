# Ginux is not a replacement for the Claude Code LXC

**Keep `agentic.sh`.** A Ginux Rocky instance can boot, and Node can be forced to start inside it. That is not a Claude Code workbench, and it is not a stronger boundary than the LXC we already run.

Tested 2026-11-12 through 2026-11-13 on `ian-hpprodesk600g3mt` (EndeavourOS, kernel 7.2.11-arch1-1, x86_64), against Ginux commit `49b4230` (`https://github.com/gmkurtzer/ginux`). The Ginux tree was a separate clone at `/home/ianm/Development/ginux`. The supervisor changes below are local to that clone. They are not upstream. The diff is [`patches/49b4230-systemd-node.patch`](patches/49b4230-systemd-node.patch).

## What the LXC already is

`agentic.sh` builds a privileged Ubuntu 24.04 container on Proxmox: Claude Code, Node 22, Python 3.12, Go, Rust, Docker, optional code-server, SSH, `pct enter`, snapshots, and Proxmox backups. A first deploy is about 10–15 minutes, then a browser login to Anthropic.

The container is a workbench. It is privileged and AppArmor-unconfined so Docker can run. `docker compose build` does not work inside it. Host files are not the container root, and a privileged LXC is a known escape class. The thing it does provide is a normal Linux userspace: `apt`, `chmod`, a TTY, a LAN address, and a project disk that survives reboot.

That is the bar Ginux had to clear.

## What Ginux actually did

We did not use the documented QEMU path. `make doctor` fails on this host on purpose (it wants Darwin arm64, `hdiutil`, and a pinned qcow2). `make host-run` forces QEMU TCG even when KVM is present. The native backend builds and runs here:

```bash
cargo build -p ginux-init --target x86_64-unknown-linux-gnu --release
```

The release binary is the runtime (`launch`, `native`, `instance-validate`). `create`, `start`, and `attach` live in `scripts/ginux-host-controller.sh`, installed as `/usr/local/bin/ginux`, which calls `/usr/local/libexec/ginux-instance-helper` through sudo. Starting an instance needs real root for `mknod`, `chown 65534`, and `chroot`. `ginux start NAME --audit` does not attach. The console is a FIFO; `authorize-attach` chowns it to the operator. Detach is Ctrl-]. The recipe's development root password is `ginux`.

Two instances:

| Instance | Recipe | Result |
|---|---|---|
| `rocky` | Upstream wide Rocky systemd image | Did not boot until virtual `sysinfo` reported the recipe RAM. After that patch, login worked and a guest `/tmp` write stayed inside the instance overlay. |
| `claude` | [`contracts/claude-node.toml`](contracts/claude-node.toml) | Booted to multi-user. Host path probe returned `ENOENT`. Port 443 worked and port 80 was denied. Node ran only after two more supervisor patches and a loader workaround. |

`claude` reached multi-user with three failed units that the tighter contract causes and then ignores: `systemd-sysusers` (`/etc/.pwd.lock`), `ldconfig` (`/etc/ld.so.cache~`), and `systemd-update-done`. Root login still works. Creating users later will not. `dnf` cannot open its rpmdb under `/usr`.

## The Node result

Node.js v26.13.1 was unpacked from the official linux-x64 tarball into `/opt`. `tar` exited non-zero because `chmod` of mode `0755` returned `EPERM`. The files were on disk. The `node` binary was not executable. The image was also missing `libatomic.so.1`. `dnf` could not install it (`/usr` is on the write deny list, and this image has no `dnf download` command). The library was taken from the Rocky 10 BaseOS RPM and unpacked with `rpm2cpio` and a small Python cpio reader into `/opt/lib`.

The process that actually ran:

```bash
LD_LIBRARY_PATH=/opt/lib /lib64/ld-linux-x86-64.so.2 \
  /opt/node-v26.13.1-linux-x64/bin/node /tmp/node-check.js
```

On 2026-11-13 it printed `NODE_RESULT_END` and the instance stayed up:

```text
version v26.13.1
host ENOENT
tmp ok
etc EPERM
usr EPERM
root ok
http EPERM
https 200
```

`host` is a `stat` of this repo's README via its host path. `https` is `https://example.com/`. `http` is port 80 to the same site. Claude Code was not installed in that workstation run. The cluster VM below got the installer further.

## Why this cannot host the workbench

1. **Local supervisor patches were required before Node would stay up, and one more before Claude's loader would.** None of them are upstream.
   - systemd 257 asserts that physical memory is non-zero. Ginux's virtual `sysinfo` was all zeros, so the first `rocky` boot died in that assertion (`exit 255`, signal 11). `/proc/meminfo` already showed the recipe size. The patch reports `totalram`, `freeram`, and `mem_unit` from `memory_mib`.
   - On kernel 7.2, `pidfd_open` of a non-leader thread returns `ENOENT`, not `EINVAL`. Ginux treated that as a fatal lifetime-pin failure. Curl's threaded DNS resolver killed `claude` (`native child lifetime pin failed`). The patch accepts `ENOENT` for `PTRACE_EVENT_CLONE` and leaves that thread on the existing lifetime lane.
   - V8's `OS::SetPermissions` maps a JIT region writable and executable in one call, and it aborts unless a failed `mprotect` sets `errno` to `ENOMEM`. The balanced argument check returns `EPERM` for that mapping, which killed Node (`unexpected native trace stop`). The patch allows syscall 9 (`mmap`) and syscall 10 (`mprotect`) for every systemd-mode guest, before that check. The balanced function itself is unchanged and still rejects `PROT_WRITE|PROT_EXEC`. `rocky` and `claude` both run in systemd mode, so the check no longer applies to them.
   - The supervisor tracks console descriptors in a fixed bitmap. At 512 entries, a dup of the console onto a higher fd kills the whole guest (`native console descriptor table full`) instead of returning an error to the process. Claude's loader did that on the trial VM. The patch raises the table to 4096. It is still fixed.
2. **A normal install does not produce a runnable tree.** `chmod` during `tar` failed, `dnf` cannot write `/usr`, and the dynamic linker had to stand in for `exec`. Claude Code's installer, npm, git, and Python are the same class of problem, larger.
3. **The filesystem contract does not mean what the recipe table suggests.** On this build the `write` and `create` lists grant writes as a class. The enforced path rule is the deny list: `/boot`, `/etc`, and `/usr` after boot. `/root` is writable. Pre-boot hooks run with the write denies skipped, which is how the recipe still seeds `/etc`. Guest root's overlay writes show up on the host as uid 65534.
4. **There is no workbench console.** The lab console was a root-owned FIFO, usable after `authorize-attach`. That is enough to type a command. It is not SSH, not a LAN address, and not a terminal Claude Code's TUI was shown to survive. Snapshots and Proxmox backups have no equivalent here.
5. **The boundary is the supervisor.** Ginux's own security note says the native backend is not a VM or microVM. The host kernel still loads the ELF, handles page faults, and schedules the guest. The supervisor keeps ptrace and an open descriptor for the instance root; a defect in either one crosses the boundary. Allowing every `mmap` and `mprotect` so V8 can run spends the memory policy that was supposed to make this profile stricter than an ordinary container.

Network policy did what the recipe asked. Outbound TCP 443 and UDP 53 are allowed. Port 80 was denied from both curl and Node. Allowed connects are not logged. The guest did not see the host README, and a file written to `/tmp` inside `rocky` existed only under `/var/lib/ginux/instances/rocky/root/tmp`, as `nobody:nobody`.

## Recommendation

Stay on the Proxmox LXC for Claude Code. Ginux, as of `49b4230` plus the local patch, can boot a cut-down Rocky, run Node, and get `claude install` to return 0 once inside a Debian VM. It does not install, update, or operate the toolchain `agentic.sh` exists to provide. A second install hung on denied `/usr` writes. The patch required for V8 removes the W^X argument check from every systemd guest, and the console fd table is still a fixed bitmap.

Look at Ginux again only if upstream ships all of the following, and only for a workload that is a single binary with an explicit network contract:

- `sysinfo` reports the configured memory, so systemd 257 boots without a local patch.
- Thread `pidfd_open` returning `ENOENT` does not kill the instance.
- JIT mappings have a scoped exception. "Allow every `mmap` and `mprotect` in systemd mode" is not that exception.
- A prebuilt tree can be installed without a guest `chmod` and without writes under `/usr`.
- The console is a real pty.

That would still be a different product from this LXC.

## Cluster VM trial

[`PROXMOX.md`](PROXMOX.md) is the reproduction. Ginux ran inside Debian 13 VM 117, `ginux-trial`, on 2026-11-13. It was not installed on pmve1, pmve2, or pmve3. The VM is not in HA, `onboot` is off, and the description says it is safe to destroy. The guest disk and the cloud-init drive are on `CephStorage`. The image file is on `QNAP-NFS`. DHCP gave `192.168.1.146` for this boot. That lease can change. The generic Debian image has no qemu-guest-agent, so `qm guest cmd` does not answer. SSH as `ianm` did, after cloud-init.

The VM kernel is `6.12.116+deb13-amd64`. Inside the guest, `uname` is still `6.12.0-ginux-abi1`. Debian's `/bin/sh` is dash. The instance helper opens file descriptor 10, and dash exits with `exec: 10: not found` before the guest boots. `trial-host.sh` rewrites the installed helper to `#!/bin/bash`. After that, `claude` reached a login prompt (`root` / `ginux`).

### Ports

Ginux has no network namespace. A bind inside the guest is a bind on the VM. `127.0.0.1` is the VM's localhost. `0.0.0.0` is the VM's LAN address.

An empty inbound allow list allows every port. `default = "deny"` does not turn that into deny-all. The recipe now sets `inbound = ["tcp:*", "udp:*"]` so a reader can see that a process may bind a port when it wants to. Both the empty list and the wildcards allowed a high-port bind. Outbound is still TCP 443 and UDP 53.

Checked from the workstation, with the wildcard contract:

| Bind inside the guest | From the workstation |
|---|---|
| `0.0.0.0:8877` | `http://192.168.1.146:8877/` returned HTTP 200, a directory listing |
| `127.0.0.1:8878` | The LAN address refused the connection. `ssh -L` to the VM's localhost returned HTTP 200 |

Port 80 failed with `EACCES`. The guest process is host uid 65534 and has no `CAP_NET_BIND_SERVICE`, so ports below 1024 stay closed no matter what the contract says. Outbound `https://example.com/` returned 200. Outbound port 80 was denied. The audit also shows some TCP 443 denies for sockets the supervisor is not tracking as TCP. The request that was tracked still completed.

A user reaches a page in one of two ways. If the process listens on all interfaces, they open the VM's LAN address and that port. The VM nic was created with `firewall=0`. If the process listens on localhost, they SSH to the Debian VM and forward the port. They do not SSH into the Ginux guest. The guest has no SSH daemon and no address of its own.

### Node and Claude Code

Node v26.13.1 printed `node v26.13.1` after `LD_LIBRARY_PATH=/opt/lib`. The tarball created `node` mode `0755` already. `chmod` of other paths was denied, 1085 times, and the script keeps that noise out of the console. `libatomic.so.1` still comes from the Rocky RPM, because `/usr` is not writable.

Claude Code 2.1.323's linux-x64 binary is a 346 MiB dynamic ELF (`/lib64/ld-linux-x86-64.so.2`). One `read()` of the whole file returns `EPERM`. Hashing it in 1 MiB chunks matched the published checksum. `chmod +x` on that download was denied. The dynamic linker ran it.

The first `claude install` returned 0. `~/.local/bin/claude --version` printed `2.1.323 (Claude Code)`, and the guest stayed up. The launcher is a symlink to a mode `0755` copy under `~/.local/share/claude/versions/`.

That launch killed the guest until the console fd table was raised. With the 512-entry table, the message was `native console descriptor table full` and the instance stopped. The runtime that completed the install uses 4096.

A second `claude install`, started by the full bootstrap script, printed the success screen and then sat for more than five minutes on denied writes to `/usr/lib/sysimage/rpm`. Stopping that process let the script continue. It recorded `CLAUDE_INSTALL_FAILED` for that invocation, printed `2.1.323 (Claude Code)` again, wrote `/root/.claude/settings.json` and `/project/CLAUDE.md`, and printed `BOOTSTRAP_DONE`.

This is still not the LXC. There is no apt inside the guest, no browser login was attempted, the console is a FIFO, and the boundary is the supervisor. Keep `agentic.sh`.
