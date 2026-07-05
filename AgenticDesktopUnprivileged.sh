#!/usr/bin/env bash
# ============================================================================
# Claude Desktop + Claude Code GUI LXC Deployer for Proxmox (UNPRIVILEGED) V2
# Creates a fully provisioned Debian 13 LXC with a full XFCE desktop,
# Claude Desktop (community Debian build), and Claude Code — same dev stack,
# plugins, and skills as V1 (AgenticUnprivileged.sh).
#
# V2 changes vs V1 (CLI-only):
#   1. FULL LINUX DESKTOP: XFCE4 desktop environment, reachable via RDP
#      (xrdp on port 3389). Proxmox's LXC console is text-only, so RDP is
#      how you get the GUI: connect with Remmina / Windows Remote Desktop /
#      Microsoft Remote Desktop (macOS) to <container-ip>:3389.
#   2. BASE SWITCHED Ubuntu 26.04 -> Debian 13 (trixie). Ubuntu ships
#      Firefox/Chromium as snaps, and snapd is broken/painful in unprivileged
#      LXCs. Debian's apt Firefox works out of the box, and the community
#      Claude Desktop package targets Debian.
#   3. DESKTOP USER: GUI sessions run as user "claude" (sudo + docker group),
#      not root. Claude Code, plugins, and skills are installed for this user.
#      Root SSH still works as in V1.
#   4. CLAUDE DESKTOP APP: built from aaddrick/claude-desktop-debian
#      (repackages the official app for Linux). Non-fatal — if the build
#      fails, a claude.ai web-app launcher (Firefox) is created instead.
#   5. Everything from V1 is retained: Node 22, Go, Rust, Docker + Compose,
#      Code Server (8443), Watchtower, plugins (frontend-design, code-review,
#      commit-commands, security-guidance, context7, superpowers),
#      webapp-testing skill, Playwright Chromium, auto-update cron.
#
# Electron/Chromium sandbox note: unprivileged LXCs restrict nested user
# namespaces, so Claude Desktop and Playwright Chromium launch with
# --no-sandbox where needed (wired into the .desktop launcher already).
#
# Resource note: a desktop adds ~1 GB RAM overhead and the Claude Desktop
# build needs headroom — defaults are 4 cores / 10 GB RAM / 40 GB disk.
#
# Run on your Proxmox host:
#   bash AgenticDesktopUnprivileged.sh
#     OR
# curl -fsSl https://raw.githubusercontent.com/ssandall/Proxmox_ClaudeCodeLXC/refs/heads/main/AgenticDesktopUnprivileged.sh -o /tmp/AgenticDesktopUnprivileged.sh && bash /tmp/AgenticDesktopUnprivileged.sh
#
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
  echo -e "${BOLD}║  Claude Desktop GUI LXC Deployer (Unprivileged)  ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
  echo ""
}

# ── Pre-flight checks ──────────────────────────────────────────────────────
preflight() {
  [[ $(id -u) -eq 0 ]] || error "This script must be run as root on the Proxmox host."
  command -v pct   &>/dev/null || error "pct not found. Are you running this on a Proxmox host?"
  command -v pveam &>/dev/null || error "pveam not found. Are you running this on a Proxmox host?"
}

# ── Template Resolution ─────────────────────────────────────────────────────
resolve_template() {
  info "Resolving latest Debian 13 LXC template from catalog..."
  pveam update >/dev/null 2>&1 || true
  local found
  found=$(pveam available --section system 2>/dev/null \
            | awk '{print $NF}' \
            | grep -E '^debian-13-standard' \
            | sort -V | tail -n1)
  if [[ -n "$found" ]]; then
    TEMPLATE="$found"
    success "Using template: $TEMPLATE"
  else
    TEMPLATE="debian-13-standard_13.1-1_amd64.tar.zst"
    warn "No Debian 13 template found in catalog; using fallback name: $TEMPLATE"
    warn "Verify with: pveam available --section system | grep debian-13"
  fi
}

# ── Configuration ───────────────────────────────────────────────────────────
get_config() {
  local next_id
  next_id=$(pvesh get /cluster/nextid 2>/dev/null || echo "100")

  resolve_template

  echo -e "${BOLD}Container Configuration${NC}"
  echo "─────────────────────────────────────────────────"

  read -rp "Container ID [$next_id]: " CT_ID
  CT_ID="${CT_ID:-$next_id}"
  [[ "$CT_ID" =~ ^[0-9]+$ ]] || error "Container ID must be a number."
  pct status "$CT_ID" &>/dev/null && error "Container ID $CT_ID already exists."

  read -rp "Hostname [claude-desktop]: " CT_HOSTNAME
  CT_HOSTNAME="${CT_HOSTNAME:-claude-desktop}"

  read -rsp "Root password: " CT_PASSWORD
  echo ""
  [[ -n "$CT_PASSWORD" ]] || error "Password cannot be empty."

  read -rsp "Desktop user 'claude' password (RDP login): " DT_PASSWORD
  echo ""
  [[ -n "$DT_PASSWORD" ]] || error "Desktop password cannot be empty."

  read -rsp "Code Server web password: " CS_PASSWORD
  echo ""
  [[ -n "$CS_PASSWORD" ]] || error "Code Server password cannot be empty."

  read -rp "CPU cores [4]: " CT_CORES
  CT_CORES="${CT_CORES:-4}"

  read -rp "RAM in MB [10240]: " CT_RAM
  CT_RAM="${CT_RAM:-10240}"

  read -rp "Swap in MB [2048]: " CT_SWAP
  CT_SWAP="${CT_SWAP:-2048}"

  read -rp "Disk size in GB [40]: " CT_DISK
  CT_DISK="${CT_DISK:-40}"

  read -rp "Storage [local-lvm]: " CT_STORAGE
  CT_STORAGE="${CT_STORAGE:-local-lvm}"

  read -rp "IP address (DHCP or x.x.x.x/xx) [dhcp]: " CT_IP
  CT_IP="${CT_IP:-dhcp}"
  if [[ "$CT_IP" != "dhcp" ]]; then
    read -rp "Gateway: " CT_GW
    [[ -n "$CT_GW" ]] || error "Gateway is required for static IP."
  fi

  read -rp "DNS server [1.1.1.1]: " CT_DNS
  CT_DNS="${CT_DNS:-1.1.1.1}"

  read -rp "Path to SSH public key (optional, press Enter to skip): " CT_SSH_KEY

  echo ""
  echo -e "${BOLD}Summary${NC}"
  echo "─────────────────────────────────────────────────"
  echo "  CT ID:     $CT_ID"
  echo "  Hostname:  $CT_HOSTNAME"
  echo "  Template:  $TEMPLATE"
  echo "  Mode:      UNPRIVILEGED (nesting + keyctl enabled)"
  echo "  Desktop:   XFCE4 via xrdp (RDP, port 3389), user: claude"
  echo "  CPU:       $CT_CORES cores"
  echo "  RAM:       $CT_RAM MB ($(( CT_RAM / 1024 )) GB)"
  echo "  Swap:      $CT_SWAP MB"
  echo "  Disk:      ${CT_DISK}G on $CT_STORAGE"
  echo "  Network:   $CT_IP"
  echo "  DNS:       $CT_DNS"
  echo "─────────────────────────────────────────────────"
  echo ""
  read -rp "Proceed? (y/N): " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
}

# ── Download Debian 13 Template ─────────────────────────────────────────────
get_template() {
  info "Checking for template: $TEMPLATE"
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
  info "Creating UNPRIVILEGED LXC container $CT_ID..."

  local net_str="name=eth0,bridge=vmbr0"
  if [[ "$CT_IP" == "dhcp" ]]; then
    net_str+=",ip=dhcp"
  else
    net_str+=",ip=$CT_IP,gw=$CT_GW"
  fi

  # --unprivileged 1: container root maps to an unprivileged host UID.
  # nesting=1: required for Docker AND for systemd user sessions / xrdp.
  # keyctl=1: required for Docker in unprivileged LXC.
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
    --ostype debian
    --unprivileged 1
    --features nesting=1,keyctl=1
    --onboot 1
    --start 0
  )

  if [[ -n "${CT_SSH_KEY:-}" && -f "$CT_SSH_KEY" ]]; then
    cmd+=(--ssh-public-keys "$CT_SSH_KEY")
  fi

  "${cmd[@]}"
  success "Container $CT_ID created (unprivileged)."
}

# ── Start & Wait for Network ──────────────────────────────────────────────
start_container() {
  info "Starting container $CT_ID..."
  pct start "$CT_ID"
  sleep 3

  info "Waiting for network..."
  local attempts=0
  while ! pct exec "$CT_ID" -- ping -c1 -W2 1.1.1.1 &>/dev/null; do
    ((attempts++))
    [[ $attempts -lt 30 ]] || error "Container failed to get network after 60s."
    sleep 2
  done
  success "Container is online."
}

# ── Provision Container ───────────────────────────────────────────────────
# Two stages:
#   Stage 1 (root):   OS, desktop, xrdp, dev stack, Docker, user, services
#   Stage 2 (claude): Claude Code, settings, plugins, skills, Playwright
provision_container() {
  info "Provisioning container (this takes a while — desktop + app builds)..."

  # ── STAGE 1: root provisioning ─────────────────────────────────────────
  cat > /tmp/provision-root-${CT_ID}.sh << 'PROVISION_EOF'
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
  bash-completion locales sudo \
  htop nano vim tmux screen \
  jq tree \
  net-tools iproute2 iputils-ping dnsutils \
  openssh-server \
  cron logrotate

echo ">>> Installing build tools & dev libraries..."
apt-get install -y -qq \
  build-essential make cmake pkg-config autoconf automake libtool \
  python3 python3-pip python3-venv python3-dev \
  libssl-dev libffi-dev libsqlite3-dev zlib1g-dev \
  libreadline-dev libbz2-dev libncurses-dev liblzma-dev libxml2-dev libxslt1-dev

echo ">>> Installing search & productivity tools..."
apt-get install -y -qq \
  ripgrep fd-find fzf bat \
  rsync \
  sqlite3

echo ">>> Installing database clients..."
apt-get install -y -qq \
  postgresql-client redis-tools

echo ">>> Installing XFCE4 desktop environment..."
# xfce4 + goodies gives a complete desktop; no display manager is installed
# because xrdp starts the session itself (LXC console is text-only anyway).
apt-get install -y -qq \
  xfce4 xfce4-goodies xfce4-terminal \
  dbus-x11 xdg-utils desktop-file-utils \
  fonts-dejavu fonts-liberation \
  mousepad ristretto \
  firefox-esr

echo ">>> Installing xrdp (RDP server for the GUI)..."
apt-get install -y -qq xrdp xorgxrdp
adduser xrdp ssl-cert
# Make xrdp sessions start XFCE (system-wide default).
sed -i 's|^test -x /etc/X11/Xsession && exec /etc/X11/Xsession|startxfce4|' /etc/xrdp/startwm.sh 2>/dev/null || true
if ! grep -q startxfce4 /etc/xrdp/startwm.sh; then
  cat >> /etc/xrdp/startwm.sh << 'XRDPWM'
startxfce4
XRDPWM
fi
systemctl enable xrdp

echo ">>> Suppressing polkit auth popups in RDP sessions (colord/network)..."
mkdir -p /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/45-lxc-desktop.rules << 'POLKIT'
// Allow desktop users to manage color profiles & refresh system sources
// without an auth popup (common xrdp annoyance).
polkit.addRule(function(action, subject) {
  if ((action.id.indexOf("org.freedesktop.color-manager") === 0 ||
       action.id.indexOf("org.freedesktop.packagekit") === 0) &&
      subject.isInGroup("sudo")) {
    return polkit.Result.YES;
  }
});
POLKIT

echo ">>> Creating desktop user 'claude'..."
useradd -m -s /bin/bash -G sudo claude
echo "claude:__DT_PASSWORD__" | chpasswd
# XFCE session for xrdp logins as claude
echo "startxfce4" > /home/claude/.xsession
chown claude:claude /home/claude/.xsession

echo ">>> Installing Node.js 22.x LTS..."
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y -qq nodejs
echo "    Node.js $(node --version) / npm $(npm --version)"

echo ">>> Installing global npm packages..."
npm install -g typescript ts-node eslint prettier

echo ">>> Installing Go..."
GO_VERSION=$(curl -fsSL "https://go.dev/VERSION?m=text" | head -1)
curl -fsSL "https://go.dev/dl/${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tar.gz
rm -rf /usr/local/go
tar -C /usr/local -xzf /tmp/go.tar.gz
rm /tmp/go.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile.d/go.sh
echo "    Go $(/usr/local/go/bin/go version | awk '{print $3}')"

echo ">>> Installing Docker..."
curl -fsSL https://get.docker.com | sh
systemctl enable docker
usermod -aG docker claude
echo "    Docker $(docker --version | awk '{print $3}' | tr -d ',')"
echo "    Storage driver: $(docker info --format '{{.Driver}}' 2>/dev/null || echo unknown)"

echo ">>> Installing Docker Compose plugin..."
apt-get install -y -qq docker-compose-plugin 2>/dev/null || true
echo "    Compose $(docker compose version --short 2>/dev/null || echo 'included with Docker')"

echo ">>> Building Claude Desktop (community Debian package)..."
# aaddrick/claude-desktop-debian repackages the official Claude Desktop app
# for Debian. NON-FATAL: if the build breaks (upstream changes), we fall back
# to a claude.ai web-app launcher below. The build needs p7zip, icoutils, etc.
set +e
CLAUDE_DESKTOP_OK=0
apt-get install -y -qq p7zip-full icoutils imagemagick
git clone --depth 1 https://github.com/aaddrick/claude-desktop-debian.git /tmp/claude-desktop-debian
if [ -d /tmp/claude-desktop-debian ]; then
  cd /tmp/claude-desktop-debian
  if ./build.sh --build deb --clean yes; then
    DEB_FILE=$(find /tmp/claude-desktop-debian -name 'claude-desktop*.deb' | head -1)
    if [ -n "$DEB_FILE" ] && apt-get install -y "$DEB_FILE"; then
      CLAUDE_DESKTOP_OK=1
      echo "    Claude Desktop installed: $DEB_FILE"
    fi
  fi
  cd /
  rm -rf /tmp/claude-desktop-debian
fi
if [ "$CLAUDE_DESKTOP_OK" -ne 1 ]; then
  echo "    [WARN] Claude Desktop build failed — creating claude.ai web launcher instead."
fi
set -e

echo ">>> Creating desktop launchers..."
mkdir -p /home/claude/Desktop

if [ "$CLAUDE_DESKTOP_OK" -eq 1 ]; then
  # Electron sandbox can't start in an unprivileged LXC (nested userns
  # restrictions) — launch with --no-sandbox.
  cat > /home/claude/Desktop/claude-desktop.desktop << 'DESK1'
[Desktop Entry]
Type=Application
Name=Claude
Comment=Claude Desktop
Exec=claude-desktop --no-sandbox %u
Icon=claude-desktop
Terminal=false
Categories=Network;Utility;
DESK1
  # Also patch the system launcher so menu launches work too.
  if [ -f /usr/share/applications/claude-desktop.desktop ]; then
    sed -i 's|^Exec=claude-desktop|Exec=claude-desktop --no-sandbox|' /usr/share/applications/claude-desktop.desktop
  fi
else
  cat > /home/claude/Desktop/claude-desktop.desktop << 'DESK1'
[Desktop Entry]
Type=Application
Name=Claude (web)
Comment=Claude in Firefox
Exec=firefox-esr --new-window https://claude.ai
Icon=firefox-esr
Terminal=false
Categories=Network;Utility;
DESK1
fi

cat > /home/claude/Desktop/claude-code.desktop << 'DESK2'
[Desktop Entry]
Type=Application
Name=Claude Code
Comment=Claude Code in a terminal (starts in /project)
Exec=xfce4-terminal --title="Claude Code" --working-directory=/project -e claude
Icon=utilities-terminal
Terminal=false
Categories=Development;
DESK2

cat > /home/claude/Desktop/project.desktop << 'DESK3'
[Desktop Entry]
Type=Link
Name=Project Folder
Icon=folder
URL=file:///project
DESK3

chmod +x /home/claude/Desktop/*.desktop
chown -R claude:claude /home/claude/Desktop
# XFCE marks unknown launchers untrusted; pre-trust them for the claude user.
su - claude -c 'for f in ~/Desktop/*.desktop; do gio set "$f" metadata::xfce-exe-checksum "$(sha256sum "$f" | awk "{print \$1}")" 2>/dev/null || true; done' || true

echo ">>> Setting up /project directory..."
mkdir -p /project
cat > /project/CLAUDE.md << 'CLAUDEMD'
# Claude Code Workspace (Desktop LXC)

## Environment
- **OS**: Debian 13 unprivileged LXC container on Proxmox, XFCE4 desktop via xrdp
- **Working directory**: /project
- **Timezone**: America/New_York
- **User**: claude (sudo + docker groups; container root maps to an unprivileged host UID)

## Available Tools
- **Desktop**: XFCE4 over RDP (port 3389); Firefox ESR; Claude Desktop app (or claude.ai web launcher)
- **Languages**: Node.js 22 LTS, Python 3 (system default), Go (latest), Rust (latest)
- **Package managers**: npm, pip (use --break-system-packages), cargo, go install
- **Docker**: Docker Engine + Compose plugin, running and ready
- **Containers**: Watchtower (auto-updates), Code Server (port 8443)
- **Search tools**: ripgrep (rg), fd-find (fdfind), fzf
- **Databases**: PostgreSQL client (psql), Redis client (redis-cli), SQLite3

## Permissions
All tools are pre-approved — no permission prompts. Bash, Read, Write, Edit,
WebFetch, WebSearch, Task, and MCP tools all run without confirmation.

## Agent Teams
Agent teams are enabled. You can spawn parallel teammates for complex tasks:
- Use agent teams for work that benefits from parallel exploration
- Use subagents (Task tool) for quick focused work that reports back
- tmux is installed for split-pane team visualization

## Remote Control
Remote Control lets you steer a live local session from the Claude mobile app or
web. Turn it on per session with `/rc` (or `claude remote-control`), or for all
sessions via `/config` → "Enable Remote Control for all sessions". Requires a
Pro/Max login (research preview).

## Docker Usage
Docker compose files should go in /docker/<service-name>/docker-compose.yml.
Watchtower is already running and will auto-update any containers with
`restart: unless-stopped`.
This is an UNPRIVILEGED LXC — no AppArmor overrides are used or needed.

## GUI / Browser Notes
This is an unprivileged LXC: nested user namespaces are restricted, so
Chromium-based apps need --no-sandbox. This applies to:
- Claude Desktop (launcher already passes --no-sandbox)
- Playwright Chromium (use --no-sandbox or chromiumSandbox: false)
Firefox ESR works normally. GUI rendering is software (no GPU passthrough).

## Conventions
- Prefer creating files over printing long code blocks
- Use git for version control on all projects in /project/src/
- When installing Python packages, use: pip install --break-system-packages <package>
- Extended thinking is always on — use it for complex architectural decisions

## Installed Plugins / Skills
Plugins are installed via the `claude plugin` CLI at provision time. Run
`claude plugin list` to confirm what's active.
- **frontend-design**: Production-grade UI with distinctive aesthetics
- **code-review**: Multi-agent PR review with confidence scoring
- **commit-commands**: Git commit, push, and PR workflows (/commit, /push, /pr)
- **security-guidance**: Security warnings when editing sensitive files
- **context7**: Live, version-specific library docs lookup
- **superpowers**: brainstorm → plan → implement workflow framework
- **webapp-testing** (local skill): Playwright-based browser testing
CLAUDEMD
chown -R claude:claude /project

echo ">>> Configuring SSH..."
sed -i "s/^#*PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config
sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication yes/" /etc/ssh/sshd_config
systemctl enable ssh
systemctl restart ssh

echo ">>> Setting up Git defaults (claude user)..."
su - claude -c 'git config --global init.defaultBranch main && git config --global core.editor nano && git config --global pull.rebase false'

echo ">>> Setting up Docker services..."
mkdir -p /docker/watchtower
cat > /docker/watchtower/docker-compose.yml << 'DCOMPOSE'
services:
  watchtower:
    image: containrrr/watchtower
    container_name: watchtower
    restart: unless-stopped
    environment:
      TZ: America/New_York
      WATCHTOWER_CLEANUP: "true"
      WATCHTOWER_INCLUDE_STOPPED: "true"
      WATCHTOWER_SCHEDULE: "0 0 4 * * *"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
DCOMPOSE

mkdir -p /docker/code-server
cat > /docker/code-server/docker-compose.yml << 'DCOMPOSE2'
services:
  code-server:
    image: lscr.io/linuxserver/code-server:latest
    container_name: code-server
    restart: unless-stopped
    environment:
      PUID: "0"
      PGID: "0"
      TZ: America/New_York
      PASSWORD: __CS_PASSWORD__
    volumes:
      - ./config:/config
      - /:/config/workspace
    ports:
      - 8443:8443
DCOMPOSE2

cd /docker/watchtower && docker compose up -d
cd /docker/code-server && docker compose up -d
cd /

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

echo ">>> Stage 1 (root) complete."
PROVISION_EOF

  # ── STAGE 2: claude-user provisioning ──────────────────────────────────
  cat > /tmp/provision-user-${CT_ID}.sh << 'USER_EOF'
#!/bin/bash
# Runs as user 'claude'. Non-fatal where sensible.
set -e
export PATH="$HOME/.local/bin:$HOME/.claude/bin:$PATH"

echo ">>> Installing Rust (claude user)..."
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
echo "    Rust $(rustc --version | awk '{print $2}')"

echo ">>> Installing Claude Code (native installer, claude user)..."
curl -fsSL https://claude.ai/install.sh | bash
CLAUDE_BIN="$(command -v claude || echo "$HOME/.local/bin/claude")"
echo "    Claude Code installed: $("$CLAUDE_BIN" --version 2>/dev/null || echo 'version unknown')"

echo ">>> Configuring Claude Code settings (permissions + env)..."
# Same rationale as V1: no enabledPlugins block (ignored non-interactively);
# plugins installed explicitly via CLI below.
mkdir -p "$HOME/.claude"
cat > "$HOME/.claude/settings.json" << 'SETTINGS'
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

echo ">>> Adding plugin marketplaces..."
"$CLAUDE_BIN" plugin marketplace add anthropics/claude-plugins-official \
  || echo "    [WARN] could not add claude-plugins-official"
"$CLAUDE_BIN" plugin marketplace add anthropics/claude-code \
  || echo "    [WARN] could not add claude-code (demo) marketplace"
"$CLAUDE_BIN" plugin marketplace add obra/superpowers-marketplace \
  || echo "    [WARN] could not add superpowers-marketplace"

echo ">>> Installing Claude Code plugins..."
install_plugin() {
  local name="$1"
  local mkt
  for mkt in claude-plugins-official claude-code-plugins; do
    if "$CLAUDE_BIN" plugin install "${name}@${mkt}" 2>/dev/null; then
      echo "    installed ${name}@${mkt}"
      return 0
    fi
  done
  echo "    [WARN] could not install plugin: ${name}"
  return 0
}

install_plugin frontend-design
install_plugin code-review
install_plugin commit-commands
install_plugin security-guidance
install_plugin context7

"$CLAUDE_BIN" plugin install superpowers@superpowers-marketplace 2>/dev/null \
  && echo "    installed superpowers@superpowers-marketplace" \
  || echo "    [WARN] could not install superpowers"

echo ">>> Installed plugins:"
"$CLAUDE_BIN" plugin list 2>/dev/null || echo "    (plugin list unavailable)"

echo ">>> Installing webapp-testing skill (from anthropics/skills)..."
git clone --depth 1 --filter=blob:none --sparse https://github.com/anthropics/skills.git /tmp/anthropic-skills
cd /tmp/anthropic-skills && git sparse-checkout set skills/webapp-testing
mkdir -p "$HOME/.claude/skills/"
cp -r /tmp/anthropic-skills/skills/webapp-testing "$HOME/.claude/skills/webapp-testing"
rm -rf /tmp/anthropic-skills
cd "$HOME"

echo ">>> Installing Playwright browser for webapp-testing skill..."
# Debian 13 may not be a recognized Playwright platform yet; force the
# ubuntu24.04-x64 build if the native install fails. NON-FATAL.
set +e
if npx -y playwright install --with-deps chromium; then
  echo "    Playwright chromium installed"
else
  export PLAYWRIGHT_HOST_PLATFORM_OVERRIDE="ubuntu24.04-x64"
  if npx -y playwright install --with-deps chromium; then
    echo "    Playwright chromium installed (ubuntu24.04-x64 build override)"
  elif npx -y playwright install chromium; then
    echo "    Playwright chromium installed (browser only; some OS deps may be missing)"
  else
    echo "    [WARN] Playwright browser install failed. Retry later with:"
    echo "      PLAYWRIGHT_HOST_PLATFORM_OVERRIDE=ubuntu24.04-x64 npx playwright install --with-deps chromium"
  fi
  unset PLAYWRIGHT_HOST_PLATFORM_OVERRIDE
fi
set -e

echo ">>> Setting up shell environment (claude user)..."
cat >> "$HOME/.bashrc" << 'BASHRC'

# ── Claude Desktop Container ───────────────────────────────
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

# Always start in /project (interactive shells only)
[[ $- == *i* ]] && cd /project 2>/dev/null || true
BASHRC

echo ">>> Stage 2 (claude user) complete."
USER_EOF

  # Inject passwords chosen at config time (placeholder swap — heredocs are
  # quoted to prevent host-side expansion). Escape sed specials.
  local cs_pw_escaped dt_pw_escaped
  cs_pw_escaped=$(printf '%s' "$CS_PASSWORD" | sed -e 's/[\\|&]/\\&/g')
  dt_pw_escaped=$(printf '%s' "$DT_PASSWORD" | sed -e 's/[\\|&]/\\&/g')
  sed -i "s|__CS_PASSWORD__|${cs_pw_escaped}|" /tmp/provision-root-${CT_ID}.sh
  sed -i "s|__DT_PASSWORD__|${dt_pw_escaped}|" /tmp/provision-root-${CT_ID}.sh

  chmod +x /tmp/provision-root-${CT_ID}.sh /tmp/provision-user-${CT_ID}.sh

  pct push "$CT_ID" /tmp/provision-root-${CT_ID}.sh /tmp/provision-root.sh
  pct push "$CT_ID" /tmp/provision-user-${CT_ID}.sh /tmp/provision-user.sh
  pct exec "$CT_ID" -- chmod +x /tmp/provision-root.sh /tmp/provision-user.sh

  pct exec "$CT_ID" -- /tmp/provision-root.sh
  pct exec "$CT_ID" -- su - claude /tmp/provision-user.sh

  # Cleanup inside container + on host
  pct exec "$CT_ID" -- bash -c 'apt-get autoremove -y -qq; apt-get clean -qq; rm -rf /var/lib/apt/lists/* /tmp/provision-root.sh /tmp/provision-user.sh'
  rm -f /tmp/provision-root-${CT_ID}.sh /tmp/provision-user-${CT_ID}.sh

  success "Provisioning complete."
}

# ── Print Summary ─────────────────────────────────────────────────────────
print_summary() {
  local ct_ip
  ct_ip=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}')

  echo ""
  echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}${BOLD}║   Claude Desktop GUI LXC Ready! (Unprivileged)   ║${NC}"
  echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${BOLD}Container:${NC} $CT_ID ($CT_HOSTNAME) — unprivileged, Debian 13 + XFCE4"
  echo -e "  ${BOLD}IP:${NC}        ${ct_ip:-pending (DHCP)}"
  echo -e "  ${BOLD}Resources:${NC} ${CT_CORES} CPU / $(( CT_RAM / 1024 )) GB RAM / ${CT_DISK} GB disk"
  echo -e "  ${BOLD}Timezone:${NC}  America/New_York"
  echo ""
  echo -e "  ${BOLD}Desktop (RDP):${NC}"
  [[ -n "${ct_ip:-}" ]] && echo -e "    Connect any RDP client to ${CYAN}${ct_ip}:3389${NC}"
  echo -e "    Login: ${CYAN}claude${NC} / password set at config time"
  echo -e "    (Windows: mstsc.exe • macOS: Windows App • Linux: Remmina)"
  echo ""
  echo -e "  ${BOLD}Other access:${NC}"
  echo -e "    Console: ${CYAN}pct enter $CT_ID${NC}"
  [[ -n "${ct_ip:-}" ]] && echo -e "    SSH:     ${CYAN}ssh root@${ct_ip}${NC} or ${CYAN}ssh claude@${ct_ip}${NC}"
  [[ -n "${ct_ip:-}" ]] && echo -e "    Code:    ${CYAN}http://${ct_ip}:8443${NC}"
  echo ""
  echo -e "  ${BOLD}On the desktop:${NC}"
  echo "    • Claude — Claude Desktop app (or claude.ai web launcher if build failed)"
  echo "    • Claude Code — terminal session starting in /project"
  echo "    • Project Folder — shortcut to /project"
  echo ""
  echo -e "  ${BOLD}First run:${NC} open ${CYAN}Claude Code${NC} on the desktop (or run ${CYAN}claude${NC} as"
  echo -e "  the claude user) and sign in; sign in to the Claude app separately."
  echo ""
  echo -e "  ${BOLD}Installed:${NC}"
  echo "    • XFCE4 + xrdp (RDP :3389)  • Claude Desktop (community build)"
  echo "    • Claude Code (native)      • Node.js 22 LTS"
  echo "    • Python 3 + pip + venv     • Go (latest)"
  echo "    • Rust (via rustup)         • Docker + Compose"
  echo "    • Firefox ESR               • Git, ripgrep, fzf, fd"
  echo "    • PostgreSQL & Redis CLI    • Watchtower + Code Server (:8443)"
  echo ""
  echo -e "  ${BOLD}Permissions:${NC} All Claude Code tools pre-approved (no prompts)"
  echo -e "  ${BOLD}Config:${NC}      /home/claude/.claude/settings.json"
  echo -e "  ${BOLD}Plugins:${NC}     frontend-design, code-review, commit-commands,"
  echo -e "               security-guidance, context7, superpowers"
  echo -e "  ${BOLD}Skills:${NC}      webapp-testing (local, Playwright)"
  echo -e "  ${BOLD}Auto-updates:${NC} Sundays 3 AM ET (system) / Daily 4 AM ET (Docker)"
  echo ""
  echo -e "  ${YELLOW}Notes:${NC}"
  echo -e "  • Chromium/Electron sandboxes can't start in unprivileged LXCs —"
  echo -e "    the Claude launcher already passes ${CYAN}--no-sandbox${NC}; do the same for"
  echo -e "    Playwright (${CYAN}chromiumSandbox: false${NC})."
  echo -e "  • Rendering is software-only (no GPU passthrough in this config)."
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
