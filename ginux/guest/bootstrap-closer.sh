#!/bin/sh
# Run inside the claude guest as root: sh /root/bootstrap-closer.sh
# Brings the tested Node layout up, then attempts the same Claude Code
# installer agentic.sh uses. chmod is denied in this guest, so binaries are
# started through the dynamic linker. /usr and /etc stay read-only.
set -eu

node_version=v26.13.1
node_prefix=/opt/node-${node_version}-linux-x64
libatomic_url=https://dl.rockylinux.org/pub/rocky/10/BaseOS/x86_64/os/Packages/l/libatomic-14.3.1-4.4.el10.x86_64.rpm
claude_base=https://downloads.claude.ai/claude-code-releases

need() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'missing required command: %s\n' "$1" >&2
        exit 1
    }
}

run_elf() {
    binary=$1
    shift
    # tar often creates the file already mode 0755, then chmod is denied.
    # The binary is executable and still needs libatomic, which is not on
    # the default loader path because /usr is not writable.
    LD_LIBRARY_PATH="/opt/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export LD_LIBRARY_PATH
    if [ -x "$binary" ]; then
        "$binary" "$@"
        return
    fi
    /lib64/ld-linux-x86-64.so.2 "$binary" "$@"
}

need curl
need python3
need rpm2cpio
need tar

printf '%s\n' '>>> Node tarball'
mkdir -p /opt /tmp
curl -fsSL -o /tmp/node.tar.gz \
    "https://nodejs.org/dist/${node_version}/node-${node_version}-linux-x64.tar.gz"
# tar returns non-zero when chmod is denied. The files are still unpacked.
# The mode errors are expected and huge, so keep them out of the console.
tar -xf /tmp/node.tar.gz -C /opt >/tmp/tar-node.err 2>&1 || true
chmod_denied=$(grep -c "Cannot change mode" /tmp/tar-node.err || true)
printf 'tar chmod denials: %s\n' "$chmod_denied"
test -f "$node_prefix/bin/node"

printf '%s\n' '>>> libatomic'
curl -fsSL -o /tmp/libatomic.rpm "$libatomic_url"
python3 - << 'PY'
import subprocess, sys, os
data = subprocess.check_output(["rpm2cpio", "/tmp/libatomic.rpm"])
offset = 0
written = 0
os.makedirs("/opt/lib", exist_ok=True)
while offset + 110 <= len(data):
    if data[offset:offset + 6] not in (b"070701", b"070702"):
        break
    header = data[offset:offset + 110]
    def field(start):
        return int(header[start:start + 8], 16)
    namesize = field(94)
    filesize = field(54)
    name_end = (offset + 110 + namesize + 3) & ~3
    body_end = name_end + filesize
    name = data[offset + 110:offset + 110 + namesize].split(b"\0", 1)[0]
    if name == b"TRAILER!!!":
        break
    base = name.rsplit(b"/", 1)[-1]
    payload = data[name_end:body_end]
    if base.startswith(b"libatomic.so") and payload.startswith(b"\x7fELF"):
        destination = os.path.join("/opt/lib", base.decode())
        with open(destination, "wb") as handle:
            handle.write(payload)
        if destination != "/opt/lib/libatomic.so.1":
            with open("/opt/lib/libatomic.so.1", "wb") as handle:
                handle.write(payload)
        written += 1
    offset = (body_end + 3) & ~3
if written != 1:
    sys.exit(f"expected one libatomic ELF, wrote {written}")
print("libatomic ok")
PY

printf '%s\n' '>>> Node check'
run_elf "$node_prefix/bin/node" -e 'console.log("node", process.version)'

printf '%s\n' '>>> Claude Code installer'
version=$(curl -fsSL "$claude_base/latest" | tr -d '\r\n')
case $version in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) printf 'unexpected Claude version reply: %s\n' "$version" >&2; exit 1 ;;
esac
curl -fsSL -o /tmp/claude-manifest.json "$claude_base/$version/manifest.json"
python3 - << 'PY'
import json
manifest = json.load(open("/tmp/claude-manifest.json"))
checksum = manifest["platforms"]["linux-x64"]["checksum"]
with open("/tmp/claude-checksum.txt", "w") as handle:
    handle.write(checksum + "\n")
PY
checksum=$(tr -d '\r\n' < /tmp/claude-checksum.txt)
mkdir -p /root/.claude/downloads /root/.local/bin /project
binary=/root/.claude/downloads/claude-$version-linux-x64
curl -fsSL -o "$binary" "$claude_base/$version/linux-x64/claude"
# One read() of the whole binary returns EPERM inside this guest.
# Hashing in 1 MiB chunks succeeds.
python3 - "$binary" "$checksum" << 'PY'
import hashlib, sys
path, expected = sys.argv[1], sys.argv[2]
digest = hashlib.sha256()
with open(path, "rb") as handle:
    while True:
        chunk = handle.read(1024 * 1024)
        if not chunk:
            break
        digest.update(chunk)
actual = digest.hexdigest()
if actual != expected:
    sys.exit(f"checksum mismatch {actual} != {expected}")
print("checksum ok", actual)
PY
chmod +x "$binary" 2>/dev/null || printf '%s\n' 'chmod denied; launching through the dynamic linker'
# `install` with no channel matches agentic.sh. On the trial VM this returned
# 0 after the console-fd table was raised. A non-zero status is still reported
# and the rest of the layout is written.
if run_elf "$binary" install; then
    printf '%s\n' 'claude install returned 0'
else
    printf '%s\n' 'CLAUDE_INSTALL_FAILED'
fi

if [ -f /root/.local/bin/claude ]; then
    run_elf /root/.local/bin/claude --version || true
elif [ -f /root/.claude/bin/claude ]; then
    run_elf /root/.claude/bin/claude --version || true
fi

cat > /root/.claude/settings.json << 'SETTINGS'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "permissions": {
    "allow": [
      "Bash(*)",
      "Read(*)",
      "Write(*)",
      "Edit(*)",
      "MultiEdit(*)",
      "WebFetch(*)",
      "WebSearch(*)",
      "TodoRead(*)",
      "TodoWrite(*)",
      "Grep(*)",
      "Glob(*)",
      "LS(*)",
      "Task(*)",
      "mcp__*"
    ]
  },
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1",
    "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "64000",
    "MAX_THINKING_TOKENS": "31999"
  },
  "alwaysThinkingEnabled": true
}
SETTINGS

cat > /project/CLAUDE.md << 'CLAUDEMD'
# Claude Code workspace

This is a Ginux Rocky guest on a trial VM, not the Ubuntu LXC from agentic.sh.

- Working directory: /project
- User: root
- Node is the linux-x64 tarball under /opt, started through the dynamic linker
- Writes under /etc and /usr are denied
- HTTPS is allowed. HTTP is denied
- Docker, apt, dnf, code-server, and SSH into this guest are not set up
CLAUDEMD

marker='# ginux-trial-path'
block=$(cat << EOF
$marker
export PATH="/root/.local/bin:\$PATH"
node() {
  LD_LIBRARY_PATH="/opt/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}" \\
    /lib64/ld-linux-x86-64.so.2 $node_prefix/bin/node "\$@"
}
claude() {
  for candidate in /root/.local/bin/claude /root/.claude/bin/claude; do
    if [ -e "\$candidate" ]; then
      if [ -x "\$candidate" ]; then
        "\$candidate" "\$@"
      else
        LD_LIBRARY_PATH="/opt/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}" \\
          /lib64/ld-linux-x86-64.so.2 "\$candidate" "\$@"
      fi
      return
    fi
  done
  printf '%s\n' 'claude is not installed' >&2
  return 127
}
EOF
)
for rc in /root/.bashrc /root/.bash_profile; do
    if [ -f "$rc" ] && grep -q "$marker" "$rc"; then
        continue
    fi
    printf '\n%s\n' "$block" >> "$rc"
done

printf '%s\n' 'BOOTSTRAP_DONE'
printf '%s\n' 'Open a new login, or run: . /root/.bash_profile'
printf '%s\n' 'Then: node -e "console.log(process.version)"'
printf '%s\n' 'Then: claude'
