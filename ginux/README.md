# Ginux Experiment

This branch explores using Ginux (userspace kernel) as an isolation boundary for Claude Code instances.

## Goals
- Run Claude Code (or a minimal Node workload) inside a Ginux-managed Rocky Linux instance
- Confirm the instance cannot see or modify the host filesystem
- Compare practical isolation and usability against the existing Proxmox LXC approach

## Status
Research / experimental. Ginux is not production-ready.

## Quick start (on a Linux host with Rust + QEMU)
```bash
git clone https://github.com/gmkurtzer/ginux.git
cd ginux
make doctor || true
rustup target add x86_64-unknown-linux-gnu
make build
make instance-image-fetch
make systemd-image-fetch
```

Then try creating an instance:
```bash
./target/x86_64-unknown-linux-gnu/release/ginux create rocky
./target/x86_64-unknown-linux-gnu/release/ginux start rocky --attach
```

## Notes
- Official reference path is macOS arm64 + QEMU TCG; Linux works for the userspace kernel itself but some harness scripts assume Darwin.
- Isolation is contract-mediated (ptrace/seccomp), not VM-grade.
- Expect ABI gaps with the full Claude Code toolchain.
