# Ginux is not a replacement for the Claude Code LXC

**Keep `agentic.sh`.** A Ginux Rocky instance can boot, and Node can be forced to start inside it. That is not a Claude Code workbench, and it is not a stronger boundary than the LXC we already run.

Tested 2026-11-12 through 2026-11-13 on `ian-hpprodesk600g3mt` (EndeavourOS, kernel 7.2.11-arch1-1, x86_64), against Ginux commit `49b4230` (`https://github.com/gmkurtzer/ginux`). The Ginux tree was a separate clone at `/home/ianm/Development/ginux`. The three supervisor patches below are local to that clone. They are not upstream, and they are not in this repo.

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

`host` is a `stat` of this repo's README via its host path. `https` is `https://example.com/`. `http` is port 80 to the same site. Claude Code was never installed.

## Why this cannot host the workbench

1. **Three local supervisor patches were required before Node would stay up.** None of them are upstream.
   - systemd 257 asserts that physical memory is non-zero. Ginux's virtual `sysinfo` was all zeros, so the first `rocky` boot died in that assertion (`exit 255`, signal 11). `/proc/meminfo` already showed the recipe size. The patch reports `totalram`, `freeram`, and `mem_unit` from `memory_mib`.
   - On kernel 7.2, `pidfd_open` of a non-leader thread returns `ENOENT`, not `EINVAL`. Ginux treated that as a fatal lifetime-pin failure. Curl's threaded DNS resolver killed `claude` (`native child lifetime pin failed`). The patch accepts `ENOENT` for `PTRACE_EVENT_CLONE` and leaves that thread on the existing lifetime lane.
   - V8's `OS::SetPermissions` maps a JIT region writable and executable in one call, and it aborts unless a failed `mprotect` sets `errno` to `ENOMEM`. The balanced argument check returns `EPERM` for that mapping, which killed Node (`unexpected native trace stop`). The patch allows syscall 9 (`mmap`) and syscall 10 (`mprotect`) for every systemd-mode guest, before that check. The balanced function itself is unchanged and still rejects `PROT_WRITE|PROT_EXEC`. `rocky` and `claude` both run in systemd mode, so the check no longer applies to them.
2. **A normal install does not produce a runnable tree.** `chmod` during `tar` failed, `dnf` cannot write `/usr`, and the dynamic linker had to stand in for `exec`. Claude Code's installer, npm, git, and Python are the same class of problem, larger.
3. **The filesystem contract does not mean what the recipe table suggests.** On this build the `write` and `create` lists grant writes as a class. The enforced path rule is the deny list: `/boot`, `/etc`, and `/usr` after boot. `/root` is writable. Pre-boot hooks run with the write denies skipped, which is how the recipe still seeds `/etc`. Guest root's overlay writes show up on the host as uid 65534.
4. **There is no workbench console.** The lab console was a root-owned FIFO, usable after `authorize-attach`. That is enough to type a command. It is not SSH, not a LAN address, and not a terminal Claude Code's TUI was shown to survive. Snapshots and Proxmox backups have no equivalent here.
5. **The boundary is the supervisor.** Ginux's own security note says the native backend is not a VM or microVM. The host kernel still loads the ELF, handles page faults, and schedules the guest. The supervisor keeps ptrace and an open descriptor for the instance root; a defect in either one crosses the boundary. Allowing every `mmap` and `mprotect` so V8 can run spends the memory policy that was supposed to make this profile stricter than an ordinary container.

Network policy did what the recipe asked. Outbound TCP 443 and UDP 53 are allowed. Port 80 was denied from both curl and Node. Allowed connects are not logged. The guest did not see the host README, and a file written to `/tmp` inside `rocky` existed only under `/var/lib/ginux/instances/rocky/root/tmp`, as `nobody:nobody`.

## Recommendation

Stay on the Proxmox LXC for Claude Code. Ginux, as of `49b4230` plus the three local patches, is a mediated-process experiment that can boot a cut-down Rocky and can run one Node script if the operator unpacks it by hand. It does not install, update, or operate the toolchain `agentic.sh` exists to provide, and the patch required for V8 removes the W^X argument check from every systemd guest.

Look at Ginux again only if upstream ships all of the following, and only for a workload that is a single binary with an explicit network contract:

- `sysinfo` reports the configured memory, so systemd 257 boots without a local patch.
- Thread `pidfd_open` returning `ENOENT` does not kill the instance.
- JIT mappings have a scoped exception. "Allow every `mmap` and `mprotect` in systemd mode" is not that exception.
- A prebuilt tree can be installed without a guest `chmod` and without writes under `/usr`.
- The console is a real pty.

That would still be a different product from this LXC.

## Cluster trial

[`PROXMOX.md`](PROXMOX.md) is the way to try this on the Proxmox cluster without installing Ginux on pmve1, pmve2, or pmve3. It uses a Debian VM, the patch in [`patches/49b4230-systemd-node.patch`](patches/49b4230-systemd-node.patch), and a guest bootstrap that installs the same Node build and then runs the Claude Code installer from `agentic.sh`. The installer has not been proven inside Ginux. The VM is there to find out where it stops.
