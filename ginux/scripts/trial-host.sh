#!/bin/sh
# Install the tested Ginux host layout on a normal Linux VM, then import the
# claude recipe. Do not run this on a Proxmox node. See ../PROXMOX.md.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
kit=$(CDPATH= cd -- "$here/.." && pwd -P)
recipe=$kit/contracts/claude-node.toml
bootstrap=$kit/guest/bootstrap-closer.sh
runtime_path=${GINUX_RUNTIME:-}
ginux_src=${GINUX_SRC:-}

usage() {
    printf '%s\n' 'usage: trial-host.sh install|import' >&2
    printf '%s\n' '  install   copy the runtime, controller, and image tools (needs root, GINUX_SRC, and a built or copied runtime)' >&2
    printf '%s\n' '  import    import the claude recipe and drop the guest bootstrap into its root' >&2
    exit 64
}

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        printf '%s\n' 'run this as root' >&2
        exit 1
    fi
}

install_host() {
    need_root
    if [ -z "$ginux_src" ] || [ ! -d "$ginux_src/scripts" ]; then
        printf '%s\n' 'set GINUX_SRC to a Ginux checkout at commit 49b4230' >&2
        exit 1
    fi
    if [ -z "$runtime_path" ]; then
        runtime_path=$ginux_src/target/x86_64-unknown-linux-gnu/release/ginux
    fi
    if [ ! -x "$runtime_path" ]; then
        printf 'runtime is missing or not executable: %s\n' "$runtime_path" >&2
        exit 1
    fi
    for command in curl jq gzip tar; do
        command -v "$command" >/dev/null 2>&1 || {
            printf 'missing required command: %s\n' "$command" >&2
            exit 1
        }
    done
    install -d -m 755 \
        /usr/local/libexec/ginux-image \
        /etc/ginux/examples \
        /var/lib/ginux/images \
        /var/lib/ginux/instances \
        /var/lib/ginux/work
    install -m 755 "$runtime_path" /usr/local/libexec/ginux-runtime
    install -m 755 "$ginux_src/scripts/ginux-host-controller.sh" /usr/local/bin/ginux
    install -m 755 "$ginux_src/scripts/ginux-host-instance-helper.sh" /usr/local/libexec/ginux-instance-helper
    # The helper opens descriptor 10 for the console control FIFO. Debian
    # /bin/sh is dash and rejects that with "exec: 10: not found", so the
    # supervisor exits before the guest boots. Bash accepts the descriptor.
    if ! /bin/sh -c 'exec 10>&-' >/dev/null 2>&1; then
        command -v bash >/dev/null 2>&1 || {
            printf '%s\n' 'bash is required: /bin/sh cannot open file descriptor 10' >&2
            exit 1
        }
        sed -i '1s|^#!/bin/sh|#!/bin/bash|' /usr/local/libexec/ginux-instance-helper
    fi
    for script in \
        fetch-rocky-oci.sh \
        verify-rocky-oci.sh \
        prepare-rocky-oci.sh \
        prepare-rocky-oci-rootfs.sh \
        ensure-rocky-oci.sh \
        ensure-oci-image.sh
    do
        install -m 755 "$ginux_src/scripts/$script" "/usr/local/libexec/ginux-image/$script"
    done
    install -m 644 "$ginux_src/scripts/oci-common.sh" /usr/local/libexec/ginux-image/oci-common.sh
    install -m 644 "$ginux_src/config/rocky-systemd-oci.env" /usr/local/libexec/ginux-image/rocky-systemd-oci.env
    install -m 644 "$ginux_src/config/instance-rocky-systemd.toml" /etc/ginux/examples/rocky-systemd.toml
    install -m 644 "$recipe" /etc/ginux/examples/claude-node.toml
    printf '%s\n' 'trial host installed'
    printf '%s\n' 'next: trial-host.sh import'
}

import_instance() {
    need_root
    command -v ginux >/dev/null 2>&1 || {
        printf '%s\n' 'ginux is not installed; run trial-host.sh install first' >&2
        exit 1
    }
    if [ -d /var/lib/ginux/instances/claude ]; then
        printf '%s\n' 'instance claude already exists; not replacing it' >&2
        exit 1
    fi
    ginux import claude /etc/ginux/examples/claude-node.toml
    install -m 644 "$bootstrap" /var/lib/ginux/instances/claude/root/root/bootstrap-closer.sh
    printf '%s\n' 'bootstrap copied to /root/bootstrap-closer.sh inside the guest'
    printf '%s\n' 'next, on this VM: ginux start claude && ginux attach claude'
    printf '%s\n' 'then, at the guest prompt (root / ginux): sh /root/bootstrap-closer.sh'
}

test "$#" -eq 1 || usage
case $1 in
    install) install_host ;;
    import) import_instance ;;
    *) usage ;;
esac
