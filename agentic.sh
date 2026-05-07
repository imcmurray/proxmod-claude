#!/usr/bin/env bash
# ============================================================================
#  Claude Code LXC Deployer for Proxmox
#  Creates a fully provisioned Ubuntu 24.04 LXC container ready for Claude Code
#
#  Run on your Proxmox host:
#    curl -fsSL https://raw.githubusercontent.com/serversathome-personal/code/main/agentic.sh -o /tmp/agentic.sh && bash /tmp/agentic.sh
#
#  GitHub: https://github.com/serversathome-personal/code
# ============================================================================
set -euo pipefail

# ── Colors & Helpers ────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

header() {
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║        Claude Code LXC Deployer (Proxmox)       ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
  echo ""
}

# ── Pre-flight checks ──────────────────────────────────────────────────────
preflight() {
  [[ $(id -u) -eq 0 ]] || error "This script must be run as root on the Proxmox host."
  command -v pct &>/dev/null || error "pct not found. Are you running this on a Proxmox host?"
  command -v pveam &>/dev/null || error "pveam not found. Are you running this on a Proxmox host?"
}

# ── Configuration ───────────────────────────────────────────────────────────
get_config() {
  # Find next available CT ID
  local next_id
  next_id=$(pvesh get /cluster/nextid 2>/dev/null || echo "100")

  # Template
  TEMPLATE="ubuntu-24.04-standard_24.04-2_amd64.tar.zst"

  echo -e "${BOLD}Container Configuration${NC}"
  echo "─────────────────────────────────────────────────"

  read -rp "Container ID [$next_id]: " CT_ID
  CT_ID="${CT_ID:-$next_id}"
  [[ "$CT_ID" =~ ^[0-9]+$ ]] || error "Container ID must be a number."
  pct status "$CT_ID" &>/dev/null && error "Container ID $CT_ID already exists."

  read -rp "Hostname [claude-code]: " CT_HOSTNAME
  CT_HOSTNAME="${CT_HOSTNAME:-claude-code}"

  read -rsp "Root password: " CT_PASSWORD
  echo ""
  [[ -n "$CT_PASSWORD" ]] || error "Password cannot be empty."

  read -rp "CPU cores [4]: " CT_CORES
  CT_CORES="${CT_CORES:-4}"

  read -rp "RAM in MB [10240]: " CT_RAM
  CT_RAM="${CT_RAM:-10240}"

  read -rp "Swap in MB [2048]: " CT_SWAP
  CT_SWAP="${CT_SWAP:-2048}"

  read -rp "Disk size in GB [30]: " CT_DISK
  CT_DISK="${CT_DISK:-30}"

  # Default to local-lvm (standard Proxmox install). Run `pvesm status --content rootdir`
  # on the host to see what's actually available.
  read -rp "Storage [local-lvm]: " CT_STORAGE
  CT_STORAGE="${CT_STORAGE:-local-lvm}"

  # Network - default DHCP
  read -rp "IP address (DHCP or x.x.x.x/xx) [dhcp]: " CT_IP
  CT_IP="${CT_IP:-dhcp}"

  if [[ "$CT_IP" != "dhcp" ]]; then
    read -rp "Gateway: " CT_GW
    [[ -n "$CT_GW" ]] || error "Gateway is required for static IP."
  fi

  read -rp "DNS server [1.1.1.2]: " CT_DNS
  CT_DNS="${CT_DNS:-1.1.1.2}"

  # SSH key (optional)
  read -rp "Path to SSH public key (optional, press Enter to skip): " CT_SSH_KEY

  # Optional cloud/deploy CLIs — each adds size and an auth step, so opt-in
  echo ""
  echo -e "${BOLD}Optional cloud/deploy CLIs:${NC}"
  echo "  gh        GitHub CLI"
  echo "  railway   Railway"
  echo "  wrangler  Cloudflare Workers"
  echo "  aws       AWS CLI v2"
  echo "  flyctl    Fly.io"
  echo "  vercel    Vercel"
  echo "  doctl     DigitalOcean"
  read -rp "CLIs to install (space-separated, 'all', or 'none') [gh railway wrangler]: " CT_CLIS
  CT_CLIS="${CT_CLIS:-gh railway wrangler}"
  if [[ "$CT_CLIS" == "none" ]]; then
    CT_CLIS=""
  elif [[ "$CT_CLIS" == "all" ]]; then
    CT_CLIS="gh railway wrangler aws flyctl vercel doctl"
  fi
  for cli in $CT_CLIS; do
    case "$cli" in
      gh|railway|wrangler|aws|flyctl|vercel|doctl) ;;
      *) error "Unknown CLI: $cli (valid: gh railway wrangler aws flyctl vercel doctl)" ;;
    esac
  done

  # Optional: code-server (browser VS Code on :8443). Default yes — it's the
  # primary way most users interact with the LXC remotely. Skip with 'n' if you
  # only want SSH/pct-enter access (saves ~200MB and an open port).
  echo ""
  read -rp "Install code-server (browser VS Code on port 8443)? [Y/n]: " CT_CS_REPLY
  case "${CT_CS_REPLY:-Y}" in
    [Yy]|[Yy][Ee][Ss]|"") CT_CODE_SERVER="yes" ;;
    [Nn]|[Nn][Oo])        CT_CODE_SERVER="no"  ;;
    *) error "Invalid response: '$CT_CS_REPLY'. Use Y or n." ;;
  esac

  # Generate a random code-server web password only if installing.
  # Alphanumeric only — safe in shell expansion and sed.
  if [[ "$CT_CODE_SERVER" == "yes" ]]; then
    CT_CS_PWD=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-20)
  else
    CT_CS_PWD=""
  fi

  echo ""
  echo -e "${BOLD}Summary${NC}"
  echo "─────────────────────────────────────────────────"
  echo "  CT ID:      $CT_ID"
  echo "  Hostname:   $CT_HOSTNAME"
  echo "  Template:   $TEMPLATE"
  echo "  CPU:        $CT_CORES cores"
  echo "  RAM:        $CT_RAM MB ($(( CT_RAM / 1024 )) GB)"
  echo "  Swap:       $CT_SWAP MB"
  echo "  Disk:       ${CT_DISK}G on $CT_STORAGE"
  echo "  Network:    $CT_IP"
  echo "  DNS:        $CT_DNS"
  echo "  CLIs:       ${CT_CLIS:-(none)}"
  echo "  Code-server: $CT_CODE_SERVER (browser VS Code on :8443)"
  echo "  Extras:     lazygit, uv, direnv, httpie, rclone (always)"
  echo "─────────────────────────────────────────────────"
  echo ""
  read -rp "Proceed? (y/N): " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
}

# ── Download Ubuntu 24.04 Template ─────────────────────────────────────────
get_template() {
  info "Checking for template: $TEMPLATE"

  # Download if not already present
  if ! pveam list local 2>/dev/null | grep -q "$TEMPLATE"; then
    info "Downloading $TEMPLATE ..."
    pveam download local "$TEMPLATE" || error "Failed to download template. Run 'pveam update' and try again."
  else
    success "Template already downloaded: $TEMPLATE"
  fi

  TEMPLATE_PATH="local:vztmpl/$TEMPLATE"
}

# ── Create Container ───────────────────────────────────────────────────────
create_container() {
  info "Creating LXC container $CT_ID..."

  # Build network string
  local net_str="name=eth0,bridge=vmbr0"
  if [[ "$CT_IP" == "dhcp" ]]; then
    net_str+=",ip=dhcp"
  else
    net_str+=",ip=$CT_IP,gw=$CT_GW"
  fi

  # Build pct create command
  local cmd=(
    pct create "$CT_ID" "$TEMPLATE_PATH"
    --hostname "$CT_HOSTNAME"
    --password "$CT_PASSWORD"
    --cores "$CT_CORES"
    --memory "$CT_RAM"
    --swap "$CT_SWAP"
    --rootfs "$CT_STORAGE:$CT_DISK"
    --net0 "$net_str"
    --nameserver "$CT_DNS"
    --ostype ubuntu
    --unprivileged 0
    --features nesting=1,keyctl=1
    --onboot 1
    --start 0
  )

  # Add SSH key if provided
  if [[ -n "${CT_SSH_KEY:-}" && -f "$CT_SSH_KEY" ]]; then
    cmd+=(--ssh-public-keys "$CT_SSH_KEY")
  fi

  "${cmd[@]}"
  success "Container $CT_ID created."

  # Disable AppArmor for Docker-in-LXC compatibility
  info "Setting AppArmor profile to unconfined (required for Docker)..."
  echo "lxc.apparmor.profile: unconfined" >> "/etc/pve/lxc/${CT_ID}.conf"
}

# ── Start & Wait for Network ──────────────────────────────────────────────
start_container() {
  info "Starting container $CT_ID..."
  pct start "$CT_ID"
  sleep 3

  # Wait for ICMP first (fast fail signal)
  info "Waiting for network..."
  local attempts=0
  while ! pct exec "$CT_ID" -- ping -c1 -W2 1.1.1.2 &>/dev/null; do
    attempts=$((attempts + 1))
    [[ $attempts -lt 30 ]] || error "Container failed to get network after 60s."
    sleep 2
  done

  # Then wait for DNS + apt mirror reachability — provisioning hits these immediately
  info "Waiting for DNS and apt mirrors..."
  attempts=0
  while ! pct exec "$CT_ID" -- bash -c "getent hosts archive.ubuntu.com >/dev/null && apt-get -qq update >/dev/null 2>&1" &>/dev/null; do
    attempts=$((attempts + 1))
    [[ $attempts -lt 30 ]] || error "Container DNS/apt not usable after 60s. Check --nameserver."
    sleep 2
  done
  success "Container is online with working DNS/apt."
}

# ── Provision Container ───────────────────────────────────────────────────
provision_container() {
  info "Provisioning container (this takes a few minutes)..."

  # Write provision script to host, then push into container
  cat > /tmp/provision-${CT_ID}.sh << 'PROVISION_EOF'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

echo ">>> Setting timezone to America/New_York..."
ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime
echo "America/New_York" > /etc/timezone
dpkg-reconfigure -f noninteractive tzdata

echo ">>> Generating locale..."
apt-get update -qq
apt-get install -y -qq locales
sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen
locale-gen en_US.UTF-8 > /dev/null 2>&1
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

echo ">>> Updating system..."
apt-get upgrade -y -qq

echo ">>> Installing core packages..."
apt-get install -y -qq \
  git curl wget unzip zip \
  ca-certificates gnupg lsb-release apt-transport-https software-properties-common \
  bash-completion locales \
  htop nano vim tmux screen \
  jq yq tree \
  net-tools iproute2 iputils-ping dnsutils \
  openssh-server \
  cron logrotate

echo ">>> Installing build tools & dev libraries..."
apt-get install -y -qq \
  build-essential make cmake pkg-config autoconf automake libtool \
  python3 python3-pip python3-venv python3-dev python-is-python3 \
  libssl-dev libffi-dev libsqlite3-dev zlib1g-dev \
  libreadline-dev libbz2-dev libncurses-dev liblzma-dev libxml2-dev libxslt-dev

echo ">>> Installing search & productivity tools..."
apt-get install -y -qq \
  ripgrep fd-find fzf bat \
  rsync \
  sqlite3

echo ">>> Installing database clients..."
apt-get install -y -qq \
  postgresql-client redis-tools

# Selected cloud/deploy CLIs (placeholder substituted by host script)
SELECTED_CLIS="@@SELECTED_CLIS@@"
cli_selected() {
  for c in $SELECTED_CLIS; do [[ "$c" == "$1" ]] && return 0; done
  return 1
}

echo ">>> Installing always-on extras (direnv, httpie)..."
apt-get install -y -qq direnv httpie

if cli_selected gh; then
  echo ">>> Installing GitHub CLI (gh)..."
  mkdir -p -m 755 /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
  chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list
  apt-get update -qq
  apt-get install -y -qq gh
  echo "    gh $(gh --version | head -1 | awk '{print $3}')"
fi

echo ">>> Installing Node.js 22.x LTS..."
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y -qq nodejs
echo "    Node.js $(node --version) / npm $(npm --version)"

echo ">>> Installing global npm packages..."
NPM_GLOBALS="typescript ts-node eslint prettier"
cli_selected railway  && NPM_GLOBALS="$NPM_GLOBALS @railway/cli"
cli_selected wrangler && NPM_GLOBALS="$NPM_GLOBALS wrangler"
cli_selected vercel   && NPM_GLOBALS="$NPM_GLOBALS vercel"
npm install -g $NPM_GLOBALS
cli_selected railway  && echo "    Railway $(railway --version 2>/dev/null | awk '{print $NF}')"
cli_selected wrangler && echo "    Wrangler $(wrangler --version 2>/dev/null | head -1 | awk '{print $NF}')"
cli_selected vercel   && echo "    Vercel $(vercel --version 2>/dev/null | head -1)"

echo ">>> Installing Go..."
GO_VERSION=$(curl -fsSL "https://go.dev/VERSION?m=text" | head -1)
curl -fsSL "https://go.dev/dl/${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tar.gz
rm -rf /usr/local/go
tar -C /usr/local -xzf /tmp/go.tar.gz
rm /tmp/go.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile.d/go.sh
echo "    Go $(/usr/local/go/bin/go version | awk '{print $3}')"

echo ">>> Installing Rust..."
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
echo "    Rust $(rustc --version | awk '{print $2}')"

echo ">>> Installing Docker..."
curl -fsSL https://get.docker.com | sh
systemctl enable docker
echo "    Docker $(docker --version | awk '{print $3}' | tr -d ',')"
# NOTE: `docker compose build` does NOT work inside this LXC — the host kernel
# reports AppArmor as enabled but doesn't expose /proc/<pid>/attr/apparmor/ to
# nested PID namespaces, so runc can't configure apparmor for intermediate
# build containers. There is no fix from inside the LXC. See the project README
# §6 troubleshooting for working strategies (build elsewhere and push, or use a
# separate Proxmox VM for builds). At-runtime `docker compose up` works fine
# because each service uses `security_opt: [apparmor=unconfined]`.

echo ">>> Installing Docker Compose plugin..."
apt-get install -y -qq docker-compose-plugin 2>/dev/null || true
echo "    Compose $(docker compose version --short 2>/dev/null || echo 'included with Docker')"

if cli_selected aws; then
  echo ">>> Installing AWS CLI v2..."
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -q /tmp/awscliv2.zip -d /tmp/
  /tmp/aws/install >/dev/null
  rm -rf /tmp/awscliv2.zip /tmp/aws
  echo "    aws $(aws --version 2>&1 | awk '{print $1}')"
fi

if cli_selected flyctl; then
  echo ">>> Installing flyctl (Fly.io)..."
  curl -fsSL https://fly.io/install.sh | sh >/dev/null
  ln -sf /root/.fly/bin/flyctl /usr/local/bin/flyctl
  ln -sf /root/.fly/bin/fly    /usr/local/bin/fly
  echo "    flyctl $(/root/.fly/bin/flyctl version 2>/dev/null | awk '{print $2}')"
fi

if cli_selected doctl; then
  echo ">>> Installing doctl (DigitalOcean)..."
  DOCTL_VERSION=$(curl -fsSL https://api.github.com/repos/digitalocean/doctl/releases/latest | grep -Po '"tag_name": "v\K[^"]*')
  curl -fsSL "https://github.com/digitalocean/doctl/releases/download/v${DOCTL_VERSION}/doctl-${DOCTL_VERSION}-linux-amd64.tar.gz" | tar xz -C /tmp/
  mv /tmp/doctl /usr/local/bin/
  echo "    doctl $(doctl version 2>/dev/null | head -1 | awk '{print $3}')"
fi

echo ">>> Installing always-on extras (lazygit, uv, rclone)..."
# lazygit — TUI git client
LG_VERSION=$(curl -fsSL "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" | grep -Po '"tag_name": "v\K[^"]*')
curl -fsSL "https://github.com/jesseduffield/lazygit/releases/download/v${LG_VERSION}/lazygit_${LG_VERSION}_Linux_x86_64.tar.gz" -o /tmp/lazygit.tar.gz
tar xzf /tmp/lazygit.tar.gz -C /tmp/ lazygit && mv /tmp/lazygit /usr/local/bin/ && rm /tmp/lazygit.tar.gz
echo "    lazygit $LG_VERSION"

# uv — fast Python package manager
curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null
[[ -f /root/.local/bin/uv ]] && ln -sf /root/.local/bin/uv /usr/local/bin/uv
echo "    uv $(/root/.local/bin/uv --version 2>/dev/null | awk '{print $2}')"

# rclone — official installer
curl -fsSL https://rclone.org/install.sh | bash >/dev/null 2>&1 || true
echo "    rclone $(rclone version 2>/dev/null | head -1 | awk '{print $2}')"

echo ">>> Installing Claude Code (native installer)..."
curl -fsSL https://claude.ai/install.sh | bash
# Ensure claude is on PATH for all sessions
if [[ -f "$HOME/.local/bin/claude" ]]; then
  ln -sf "$HOME/.local/bin/claude" /usr/local/bin/claude 2>/dev/null || true
elif [[ -f "$HOME/.claude/bin/claude" ]]; then
  ln -sf "$HOME/.claude/bin/claude" /usr/local/bin/claude 2>/dev/null || true
fi
echo "    Claude Code installed"

echo ">>> Configuring Claude Code permissions (full auto-approve)..."
mkdir -p /root/.claude

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
  "alwaysThinkingEnabled": true,
  "enableRemoteControl": true,
  "enabledPlugins": {
    "frontend-design@claude-code-plugins": true,
    "code-review@claude-code-plugins": true,
    "commit-commands@claude-code-plugins": true,
    "security-guidance@claude-code-plugins": true,
    "context7@claude-plugins-official": true
  }
}
SETTINGS

echo ">>> Setting up /project directory..."
mkdir -p /project

cat > /project/CLAUDE.md << 'CLAUDEMD'
# Claude Code Workspace

## Environment
- **OS**: Ubuntu 24.04 LXC container on Proxmox
- **Working directory**: /project
- **Timezone**: America/New_York
- **User**: root

## Available Tools
- **Languages**: Node.js 22 LTS, Python 3.12, Go (latest), Rust (latest)
- **Package managers**: npm, pip (use --break-system-packages), cargo, go install
- **Docker**: Docker Engine + Compose plugin, running and ready
- **Containers**: Watchtower (auto-updates), Code Server (port 8443)
- **Search tools**: ripgrep (rg), fd-find (fdfind), fzf, bat
- **Databases**: PostgreSQL client (psql), Redis client (redis-cli), SQLite3
- **TUI helpers**: lazygit (TUI git)
- **Python tooling**: uv (fast pip/venv replacement; prefer over pip+venv)
- **HTTP testing**: httpie (`http`, `https` commands — sane curl)
- **Cloud sync**: rclone (S3, R2, B2, Drive, Dropbox, etc.)
- **Per-dir env**: direnv (drop a `.envrc` in a project to auto-load env vars)
- **Deploy CLIs**: whichever you opted into at deploy time (gh, railway, wrangler, aws, flyctl, vercel, doctl). Run `<cli> auth login` (or `aws configure` / `doctl auth init`) to auth. Re-check what's installed with `which gh railway wrangler aws flyctl vercel doctl 2>/dev/null`.

## Permissions
All tools are pre-approved — no permission prompts. Bash, Read, Write, Edit, WebFetch, WebSearch, Task, and MCP tools all run without confirmation.

## Agent Teams
Agent teams are enabled. You can spawn parallel teammates for complex tasks:
- Use agent teams for work that benefits from parallel exploration
- Use subagents (Task tool) for quick focused work that reports back
- tmux is installed for split-pane team visualization

## Remote Control
Remote control is enabled for all sessions. Every interactive session is automatically controllable
from claude.ai/code or the Claude mobile app. Use /remote-control or press spacebar to show QR code.

## Docker Usage
Docker compose files should go in /docker/<service-name>/docker-compose.yml. 
Watchtower is already running and will auto-update any containers with `restart: unless-stopped`.
All Docker containers in this LXC need `security_opt: [apparmor=unconfined]`.

## Conventions
- Prefer creating files over printing long code blocks
- Use git for version control on all projects in /project/src/
- **Python work MUST use a virtual environment.** Never install packages globally,
  never use `pip install --break-system-packages`, never run `pip` outside a venv.
  Standard pattern in any Python project directory:
  ```
  uv venv                    # creates .venv/ (preferred — fast)
  source .venv/bin/activate
  uv pip install <package>   # or: pip install <package>
  ```
  If you don't have `uv`, `python -m venv .venv` works too. The point is: every
  Python project gets its own isolated `.venv/`. Add `.venv/` to `.gitignore`.
- Extended thinking is always on — use it for complex architectural decisions

## Installed Plugins
- **frontend-design**: Production-grade UI with distinctive aesthetics (auto-activates on frontend tasks)
- **code-review**: Multi-agent PR review with confidence scoring
- **commit-commands**: Git commit, push, and PR workflows (/commit, /push, /pr)
- **security-guidance**: Security warnings when editing sensitive files
- **context7**: Live, version-specific library docs lookup (reduces API hallucinations)
- **webapp-testing** (skill): Playwright-based browser testing for UI verification and debugging
CLAUDEMD

echo ">>> Installing Claude Code plugins (official marketplace)..."
npx -y claude-plugins install @anthropics/claude-code-plugins/frontend-design
npx -y claude-plugins install @anthropics/claude-code-plugins/code-review
npx -y claude-plugins install @anthropics/claude-code-plugins/commit-commands
npx -y claude-plugins install @anthropics/claude-code-plugins/security-guidance
npx -y claude-plugins install @anthropics/claude-plugins-official/context7
# NOTE: superpowers (@obra/superpowers-marketplace/superpowers) was previously
# installed here but the install was unreliable — `/plugins` showed it missing
# even when provisioning reported success, surfacing as a "not cached" error
# every Claude Code session. To add it manually after deploy, run inside the
# container:  npx -y claude-plugins install @obra/superpowers-marketplace/superpowers
# then edit /root/.claude/settings.json to add "superpowers@superpowers-marketplace": true
# under enabledPlugins.

echo ">>> Installing webapp-testing skill (from anthropics/skills)..."
git clone --depth 1 --filter=blob:none --sparse https://github.com/anthropics/skills.git /tmp/anthropic-skills
cd /tmp/anthropic-skills && git sparse-checkout set skills/webapp-testing
mkdir -p /root/.claude/skills/
cp -r /tmp/anthropic-skills/skills/webapp-testing /root/.claude/skills/webapp-testing
rm -rf /tmp/anthropic-skills
cd /root

echo ">>> Installing Playwright for webapp-testing skill..."
npx -y playwright install --with-deps chromium

echo ">>> Configuring SSH..."
sed -i "s/^#*PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config
sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication yes/" /etc/ssh/sshd_config
systemctl enable ssh
systemctl restart ssh

echo ">>> Setting up shell environment..."
cat >> /root/.bashrc << 'BASHRC'

# ── Claude Code Container ──────────────────────────────────
export EDITOR=nano
export LANG=en_US.UTF-8
export TZ=America/New_York
export PATH="$HOME/.local/bin:$HOME/.claude/bin:$HOME/.cargo/bin:/usr/local/go/bin:$PATH"

# Aliases
alias ll="ls -lah --color=auto"
alias cls="clear"
alias ..="cd .."
alias ...="cd ../.."
alias gs="git status"
alias gl="git log --oneline -20"
alias dc="docker compose"
alias dps="docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
alias lg="lazygit"

# direnv: per-directory env vars from .envrc
eval "$(direnv hook bash)"

# Always start in /project
cd /project 2>/dev/null || true
BASHRC

echo ">>> Setting up Git defaults..."
git config --global init.defaultBranch main
git config --global core.editor nano
git config --global pull.rebase false

echo ">>> Setting up Docker services..."
mkdir -p /docker/watchtower
cat > /docker/watchtower/docker-compose.yml << 'DCOMPOSE'
services:
  watchtower:
    image: nickfedor/watchtower:latest
    container_name: watchtower
    restart: unless-stopped
    environment:
      TZ: America/New_York
      WATCHTOWER_CLEANUP: "true"
      WATCHTOWER_INCLUDE_STOPPED: "true"
      WATCHTOWER_SCHEDULE: "0 0 4 * * *"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    security_opt:
      - apparmor=unconfined
DCOMPOSE

INSTALL_CODE_SERVER="@@INSTALL_CODE_SERVER@@"
if [[ "$INSTALL_CODE_SERVER" == "yes" ]]; then
  echo ">>> Installing code-server (native, runs as root via systemd)..."
  # Native install instead of Docker so the integrated terminal IS the LXC shell —
  # claude / gh / lazygit / docker / etc. are all on PATH with zero glue. Updates
  # arrive via the apt repo the installer adds, picked up by the weekly cron below.
  curl -fsSL https://code-server.dev/install.sh | sh

  mkdir -p /root/.config/code-server
  cat > /root/.config/code-server/config.yaml << 'CSCONFIG'
bind-addr: 0.0.0.0:8443
auth: password
password: PLACEHOLDER_CS_PWD
# Self-signed cert. Required for webviews (Claude Code panel, Markdown
# preview, image viewer, etc.) — browsers only expose `crypto.subtle` in
# secure contexts (HTTPS or localhost), and code-server's webviews depend
# on it. Browser will warn once per browser/profile; click through and
# the warning is remembered.
cert: true
CSCONFIG
  # Password is in clear text in this file — restrict to root only.
  chmod 600 /root/.config/code-server/config.yaml

  echo ">>> Installing Anthropic Claude Code IDE extension into code-server..."
  # Install before the service is enabled so the first session has it active
  # without needing a window reload. Extensions land in
  # /root/.local/share/code-server/extensions/ (persistent on the LXC disk).
  # Tolerant of failure — the extension is non-essential (Claude works in TUI
  # without it) and Open VSX availability for vendor-published extensions can
  # vary. When this auto-install fails, the IDE-integration error in
  # `claude /status` is the only user-visible consequence; sideload the VSIX
  # from the Microsoft Marketplace via code-server's Extensions panel to fix.
  if code-server --install-extension anthropic.claude-code >/tmp/cs-ext-install.log 2>&1; then
    echo "    Claude Code IDE extension installed"
  else
    echo "    ! Claude Code extension auto-install failed — see /tmp/cs-ext-install.log"
    echo "    ! Sideload manually from the code-server Extensions panel if needed."
  fi

  echo ">>> Installing /root/.local/bin/code wrapper (fixes Claude Code IDE attach)..."
  # When `claude` runs inside code-server's integrated terminal, it spawns
  # `code --force --install-extension anthropic.claude-code` as a subprocess
  # check. Code-server's session-injected `code` shim closes its IPC stream
  # prematurely for non-interactive callers, surfacing as
  # ERR_STREAM_PREMATURE_CLOSE — Claude marks the IDE as unavailable and
  # never attaches, leaving the extension panel blank.
  #
  # This wrapper sits in $HOME/.local/bin (which the bashrc puts ahead of
  # the session shim's path), intercepts the extension-management flags,
  # and routes them to `code-server`'s CLI — which handles them reliably
  # for subprocess callers. Anything else passes through to the real `code`
  # shim so `code .` etc. keep working in the integrated terminal.
  mkdir -p /root/.local/bin
  cat > /root/.local/bin/code << 'CODEWRAP'
#!/bin/bash
# Wrapper around code-server's `code` shim. See agentic.sh for the why.
SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"

# Intercept extension-management flags anywhere in args
for arg in "$@"; do
  case "$arg" in
    --install-extension|--list-extensions|--uninstall-extension|--locate-extension|--show-versions)
      # `--force` is a vscode-only flag; code-server's CLI rejects it. Strip it.
      args=()
      for a in "$@"; do
        [[ "$a" == "--force" ]] || args+=("$a")
      done
      exec /usr/bin/code-server "${args[@]}"
      ;;
  esac
done

# Pass-through: find the next `code` in PATH that isn't us
IFS=':' read -ra paths <<< "$PATH"
for p in "${paths[@]}"; do
  cand="$p/code"
  if [[ -x "$cand" ]]; then
    real_resolved="$(readlink -f "$cand" 2>/dev/null || echo "$cand")"
    [[ "$real_resolved" == "$SELF" ]] && continue
    exec "$cand" "$@"
  fi
done

# No real code shim found — probably an SSH session, not the integrated terminal.
echo "code: no shim available (not running inside code-server's integrated terminal)" >&2
exit 127
CODEWRAP
  chmod +x /root/.local/bin/code

  # Pre-seed VS Code user settings for code-server: prefer the Claude Code
  # terminal-mode panel over the new GUI mode. The GUI mode has webview
  # rendering issues under code-server (oversized icons, broken styles,
  # session-list fetch failures) — the webview sandbox / CSP differs subtly
  # from upstream VS Code's. Terminal mode embeds the Claude TUI inside the
  # side panel, which is rock-solid and behaves identically to running
  # `claude` in the integrated terminal.
  mkdir -p /root/.local/share/code-server/User
  cat > /root/.local/share/code-server/User/settings.json << 'CSSETTINGS'
{
  "claudeCode.useTerminal": true
}
CSSETTINGS

  systemctl enable --now code-server@root
else
  echo ">>> Skipping code-server (opted out at deploy time)."
fi

cd /docker/watchtower && docker compose up -d

echo ">>> Setting up auto-update cron..."
cat > /etc/cron.d/system-update << 'CRON'
# Weekly system update - Sunday 3:00 AM ET
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
0 3 * * 0 root apt-get update -qq && apt-get upgrade -y -qq && apt-get autoremove -y -qq && apt-get clean -qq >> /var/log/auto-update.log 2>&1
CRON
chmod 0644 /etc/cron.d/system-update

cat > /etc/logrotate.d/auto-update << 'LOGROTATE'
/var/log/auto-update.log {
    monthly
    rotate 3
    compress
    missingok
    notifempty
}
LOGROTATE

echo ">>> Cleaning up..."
apt-get autoremove -y -qq
apt-get clean -qq
rm -rf /var/lib/apt/lists/*

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║          Provisioning Complete!                  ║"
echo "╚══════════════════════════════════════════════════╝"
PROVISION_EOF

  # Substitute the selected-CLIs placeholder. CT_CLIS is validated to a known
  # alphanumeric set, so it's safe in sed without escaping.
  sed -i "s|@@SELECTED_CLIS@@|${CT_CLIS}|" /tmp/provision-${CT_ID}.sh
  # CT_CODE_SERVER is "yes" or "no" (validated above) — also safe in sed.
  sed -i "s|@@INSTALL_CODE_SERVER@@|${CT_CODE_SERVER}|" /tmp/provision-${CT_ID}.sh

  chmod +x /tmp/provision-${CT_ID}.sh
  pct push "$CT_ID" /tmp/provision-${CT_ID}.sh /tmp/provision.sh
  pct exec "$CT_ID" -- chmod +x /tmp/provision.sh

  # Stream output to terminal AND save full log on the host for post-mortem
  local provision_log="/tmp/provision-${CT_ID}.log"
  info "Provisioning log: $provision_log"
  set +e
  pct exec "$CT_ID" -- /tmp/provision.sh 2>&1 | tee "$provision_log"
  local provision_status=${PIPESTATUS[0]}
  set -e

  if [[ $provision_status -ne 0 ]]; then
    error "Provisioning failed (exit $provision_status). Full log: $provision_log"
  fi

  # Verify the things that matter actually got installed — a "success" exit code
  # from a long bash script doesn't guarantee every step worked
  info "Verifying provisioning..."
  local missing=()
  pct exec "$CT_ID" -- bash -lc "command -v claude" &>/dev/null || missing+=("claude")
  pct exec "$CT_ID" -- bash -lc "command -v node"   &>/dev/null || missing+=("node")
  pct exec "$CT_ID" -- bash -lc "command -v docker" &>/dev/null || missing+=("docker")
  pct exec "$CT_ID" -- test -d /project                          || missing+=("/project")
  pct exec "$CT_ID" -- test -f /root/.claude/settings.json       || missing+=("~/.claude/settings.json")
  if [[ "$CT_CODE_SERVER" == "yes" ]]; then
    pct exec "$CT_ID" -- bash -lc "command -v code-server" &>/dev/null || missing+=("code-server")
    pct exec "$CT_ID" -- systemctl is-active --quiet code-server@root || missing+=("code-server@root (service)")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Provisioning incomplete. Missing: ${missing[*]}. Full log: $provision_log"
  fi
  success "Provisioning verified."

  # Replace the placeholder code-server password with the random one we generated.
  # CT_CS_PWD is alphanumeric only, so sed delimiter and shell expansion are safe.
  if [[ "$CT_CODE_SERVER" == "yes" ]]; then
    info "Setting random code-server password..."
    pct exec "$CT_ID" -- sed -i "s|password: PLACEHOLDER_CS_PWD|password: ${CT_CS_PWD}|" /root/.config/code-server/config.yaml
    pct exec "$CT_ID" -- systemctl restart code-server@root >/dev/null 2>&1
    success "Code-server password set."
  fi

  rm -f /tmp/provision-${CT_ID}.sh
}

# ── Print Summary ─────────────────────────────────────────────────────────
print_summary() {
  # Get container IP
  local ct_ip
  ct_ip=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}')

  echo ""
  echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}${BOLD}║       Claude Code LXC Ready!                    ║${NC}"
  echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${BOLD}Container:${NC}  $CT_ID ($CT_HOSTNAME)"
  echo -e "  ${BOLD}IP:${NC}         ${ct_ip:-pending (DHCP)}"
  echo -e "  ${BOLD}Resources:${NC}  ${CT_CORES} CPU / $(( CT_RAM / 1024 )) GB RAM / ${CT_DISK} GB disk"
  echo -e "  ${BOLD}Storage:${NC}    $CT_STORAGE"
  echo -e "  ${BOLD}Timezone:${NC}   America/New_York"
  echo ""
  echo -e "  ${BOLD}Connect:${NC}"
  echo -e "    Console:  ${CYAN}pct enter $CT_ID${NC}"
  [[ -n "${ct_ip:-}" ]] && echo -e "    SSH:      ${CYAN}ssh root@${ct_ip}${NC}"
  if [[ "$CT_CODE_SERVER" == "yes" ]]; then
    [[ -n "${ct_ip:-}" ]] && echo -e "    Code:     ${CYAN}https://${ct_ip}:8443${NC}  ${YELLOW}(accept self-signed cert warning once per browser)${NC}"
    echo ""
    echo -e "  ${BOLD}${YELLOW}Code-server password (save now — randomly generated, only shown here):${NC}"
    echo -e "    ${BOLD}${CT_CS_PWD}${NC}"
    echo -e "    ${YELLOW}(also retrievable later via: pct exec $CT_ID -- grep '^password:' /root/.config/code-server/config.yaml)${NC}"
  fi
  echo ""
  echo -e "  ${BOLD}Start Claude Code:${NC}"
  echo -e "    ${CYAN}claude${NC}    (shell auto-cd's to /project on login)"
  echo ""
  echo -e "  ${BOLD}Installed:${NC}"
  echo "    • Claude Code (native)    • Node.js 22 LTS"
  echo "    • Python 3 + uv + venv    • Go (latest)"
  echo "    • Rust (via rustup)       • Docker + Compose"
  echo "    • Git, ripgrep, fzf, fd   • Build essentials"
  echo "    • PostgreSQL & Redis CLI  • Watchtower (auto-update containers)"
  if [[ "$CT_CODE_SERVER" == "yes" ]]; then
    echo "    • Code Server (port 8443) • lazygit, direnv, httpie, rclone"
  else
    echo "    • lazygit, direnv, httpie, rclone (code-server skipped)"
  fi
  [[ -n "$CT_CLIS" ]] && echo "    • CLIs selected: $CT_CLIS"

  if [[ -n "$CT_CLIS" ]]; then
    echo ""
    echo -e "  ${BOLD}Deploy-CLI auth (run once inside the container):${NC}"
    for cli in $CT_CLIS; do
      case "$cli" in
        gh)       echo "    gh auth login          # GitHub" ;;
        railway)  echo "    railway login          # Railway" ;;
        wrangler) echo "    wrangler login         # Cloudflare Workers" ;;
        aws)      echo "    aws configure          # AWS" ;;
        flyctl)   echo "    flyctl auth login      # Fly.io" ;;
        vercel)   echo "    vercel login           # Vercel" ;;
        doctl)    echo "    doctl auth init        # DigitalOcean" ;;
      esac
    done
  fi
  echo ""
  echo -e "  ${BOLD}Permissions:${NC}  All tools pre-approved (no prompts)"
  echo -e "  ${BOLD}Config:${NC}      ~/.claude/settings.json"
  echo -e "  ${BOLD}Features:${NC}    Agent teams, extended thinking, 64k output tokens, remote control"
  echo -e "  ${BOLD}Plugins:${NC}     frontend-design, code-review, commit-commands,"
  echo -e "               security-guidance, context7"
  echo -e "  ${BOLD}Skills:${NC}      webapp-testing (Playwright)"
  echo -e "  ${BOLD}Auto-updates:${NC} Sundays 3 AM ET (system) / Daily 4 AM ET (Docker)"
  echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────
main() {
  header
  preflight
  get_config
  get_template
  create_container
  start_container
  provision_container
  print_summary
}

main "$@"

