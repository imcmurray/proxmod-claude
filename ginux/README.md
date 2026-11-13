# Ginux Experiment

This branch tested Ginux (userspace kernel) as an isolation boundary for Claude Code. It does not replace the Proxmox LXC.

## Goals
- Run Claude Code (or a minimal Node workload) inside a Ginux-managed Rocky Linux instance
- Confirm the instance cannot see or modify the host filesystem
- Compare practical isolation and usability against the existing Proxmox LXC approach

## Status

Closed as a replacement for the LXC. The writeup is [`FINDINGS.md`](FINDINGS.md). The recipe that was booted is [`contracts/claude-node.toml`](contracts/claude-node.toml). The cluster VM trial, including port reachability and the Claude installer, is [`PROXMOX.md`](PROXMOX.md).

## Notes

- Official `make doctor` / `make host-run` target macOS arm64 and QEMU TCG. On Linux the runtime is `cargo build -p ginux-init --target x86_64-unknown-linux-gnu --release`. That binary does not implement `create` or `start`; those commands are the host controller script.
- Isolation is contract-mediated (ptrace/seccomp), not VM-grade.
- Node v26.13.1 ran on the workstation. On VM 117, Claude Code 2.1.323 installed and `--version` printed. The supervisor diff is [`patches/49b4230-systemd-node.patch`](patches/49b4230-systemd-node.patch). That did not make Ginux a replacement for the LXC.
