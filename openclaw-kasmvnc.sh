#!/usr/bin/env bash
# ============================================================================
# openclaw-kasmvnc.sh — OpenClaw + KasmVNC one-click deployment script (macOS / Linux)
#
# Overview:
#   Generates Dockerfile, docker-compose.yml, KasmVNC startup script and systemctl shim,
#   then builds and runs the container via Docker Compose. The container includes an XFCE
#   desktop, Chromium browser, and the OpenClaw gateway service.
#
# Commands:
#   install   — Configure + build image + start container
#   uninstall — Stop container (optional --purge removes install dir)
#   restart   — Restart openclaw-gateway container
#   upgrade   — Upgrade OpenClaw npm package in running container
#   status    — Show Compose service status
#   logs      — Show container logs
# ============================================================================
set -euo pipefail

# ── Global defaults ──────────────────────────────────────────────────────────
COMMAND="${1:-install}"
if [ $# -gt 0 ]; then
  shift
fi

INSTALL_DIR="${INSTALL_DIR:-$HOME/openclaw-kasmvnc}"
GATEWAY_TOKEN="${GATEWAY_TOKEN:-}"
KASM_PASSWORD="${KASM_PASSWORD:-}"
HTTPS_PORT="${HTTPS_PORT:-8443}"
GATEWAY_PORT="${GATEWAY_PORT:-18789}"
PURGE=0
NO_CACHE=0                                             # Disable Docker build cache
TAIL_LINES="${TAIL_LINES:-200}"
HTTP_PROXY_URL="${HTTP_PROXY_URL:-}"

# ── Help ─────────────────────────────────────────────────────────────────
usage() {
  cat <<'EOF'
Usage:
  ./openclaw-kasmvnc.sh <command> [options]

Commands:
  install      Configure + build/run container (no git required)
  uninstall    Stop container; optional --purge removes install dir
  restart      Restart openclaw-gateway container
  upgrade      Upgrade OpenClaw in running container (no image rebuild)
  status       Show compose service status
  logs         Show compose logs (--tail <n>, default 200)

Options:
  --install-dir <path>   Install directory (default: $HOME/openclaw-kasmvnc)
  --gateway-token <str>  OPENCLAW_GATEWAY_TOKEN (auto-generate on install if omitted)
  --kasm-password <str>  OPENCLAW_KASMVNC_PASSWORD (auto-generate on install if omitted)
  --https-port <port>    KasmVNC HTTPS host port (default: 8443)
  --gateway-port <port>  OpenClaw gateway host port (default: 18789)
  --proxy <url>          HTTP proxy for container (default: none)
  --tail <n>             Log lines for logs command (default: 200)
  --no-cache             Disable Docker build cache (useful for troubleshooting)
  --purge                For uninstall: delete install dir
  -h, --help             Show this help
EOF
}

# ── Utility functions ─────────────────────────────────────────────────────────

assert_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing command: $1" >&2
    exit 1
  fi
}


random_hex() {
  local bytes="${1:-32}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$bytes"
  else
    od -An -N "$bytes" -tx1 /dev/urandom | tr -d ' \n'
  fi
}

upsert_env_line() {
  local file="$1"
  local key="$2"
  local val="$3"
  if [ ! -f "$file" ]; then
    printf '%s=%s\n' "$key" "$val" >"$file"
    return
  fi
  if grep -qE "^${key}=" "$file"; then
    sed -i.bak "s|^${key}=.*$|${key}=${val}|g" "$file"
    rm -f "${file}.bak"
  else
    printf '\n%s=%s\n' "$key" "$val" >>"$file"
  fi
}

# ── Argument parsing ────────────────────────────────────────────────────────
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --install-dir)
        INSTALL_DIR="${2:?missing value for --install-dir}"
        shift 2
        ;;
      --gateway-token)
        GATEWAY_TOKEN="${2:?missing value for --gateway-token}"
        shift 2
        ;;
      --kasm-password)
        KASM_PASSWORD="${2:?missing value for --kasm-password}"
        shift 2
        ;;
      --https-port)
        HTTPS_PORT="${2:?missing value for --https-port}"
        shift 2
        ;;
      --gateway-port)
        GATEWAY_PORT="${2:?missing value for --gateway-port}"
        shift 2
        ;;
      --tail)
        TAIL_LINES="${2:?missing value for --tail}"
        shift 2
        ;;
      --proxy)
        HTTP_PROXY_URL="${2:?missing value for --proxy}"
        shift 2
        ;;
      --no-cache)
        NO_CACHE=1
        shift
        ;;
      --no-dind)
        NO_DIND=1
        shift
        ;;
      --purge)
        PURGE=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage
        exit 1
        ;;
    esac
  done
}

# Wrapper for docker compose calls
compose_cmd() {
  docker compose -f docker-compose.yml "$@"
}

# ── Build context generation ────────────────────────────────────────────────
ensure_build_context() {
  local d="$INSTALL_DIR"
  mkdir -p "$d/scripts/docker"

  # ── Generate docker-compose.yml ──
  cat >"$d/docker-compose.yml" <<'EOF'
services:
  openclaw-gateway:
    build:
      context: .
      dockerfile: Dockerfile.kasmvnc
      args:
        KASMVNC_VERSION: ${OPENCLAW_KASMVNC_VERSION:-1.3.0}
        HTTP_PROXY: ${OPENCLAW_HTTP_PROXY:-}
        HTTPS_PROXY: ${OPENCLAW_HTTP_PROXY:-}
        OPENC_CACHE_BUST: ${OPENC_CACHE_BUST:-1}
        NO_DIND: ${NO_DIND:-0}
    image: ${OPENCLAW_KASMVNC_IMAGE:-openclaw:kasmvnc}
    command:
      [
        "openclaw",
        "gateway",
        "--allow-unconfigured",
        "--bind",
        "${OPENCLAW_GATEWAY_BIND:-lan}",
        "--port",
        "18789",
      ]
    environment:
      HOME: /home/node
      TERM: xterm-256color
      OPENCLAW_GATEWAY_TOKEN: ${OPENCLAW_GATEWAY_TOKEN}
      OPENCLAW_KASMVNC_USER: ${OPENCLAW_KASMVNC_USER:-node}
      OPENCLAW_KASMVNC_PASSWORD: ${OPENCLAW_KASMVNC_PASSWORD:-}
      OPENCLAW_KASMVNC_RESOLUTION: ${OPENCLAW_KASMVNC_RESOLUTION:-1920x1080}
      OPENCLAW_KASMVNC_DEPTH: ${OPENCLAW_KASMVNC_DEPTH:-24}
      TZ: ${TZ:-UTC}
      LANG: en_US.UTF-8
      LANGUAGE: en_US:en
      LC_ALL: en_US.UTF-8
      HTTP_PROXY: ${OPENCLAW_HTTP_PROXY:-}
      HTTPS_PROXY: ${OPENCLAW_HTTP_PROXY:-}
      http_proxy: ${OPENCLAW_HTTP_PROXY:-}
      https_proxy: ${OPENCLAW_HTTP_PROXY:-}
      NO_PROXY: ${OPENCLAW_NO_PROXY:-localhost,127.0.0.1}
      no_proxy: ${OPENCLAW_NO_PROXY:-localhost,127.0.0.1}
    volumes:
      - ${OPENCLAW_DATA_DIR:-./openclaw-data}:/home/node
    ports:
      - "${OPENCLAW_GATEWAY_PORT:-18789}:18789"
      - "${OPENCLAW_GATEWAY_BRIDGE_PORT:-18790}:18790"
      - "${OPENCLAW_KASMVNC_HTTPS_PORT:-8443}:8444"
    shm_size: '2gb'
EOF

  # If Docker-in-Docker is not disabled, add privileged: true
  # Otherwise, add security_opt to allow close_range syscall (needed by GLib/XFCE)
  # On Docker < 23, default seccomp blocks close_range and XFCE components fail to spawn (black screen).
  # privileged mode bypasses seccomp entirely so the DinD path doesn't need this.
  if [ "${NO_DIND:-0}" != "1" ]; then
    cat >>"$d/docker-compose.yml" <<'EOF'
    privileged: true
EOF
  else
    cat >>"$d/docker-compose.yml" <<'EOF'
    security_opt:
      - seccomp:unconfined
EOF
  fi

  cat >>"$d/docker-compose.yml" <<'EOF'
    init: true
    restart: unless-stopped
EOF

  # Auto-detect NVIDIA GPU and inject GPU support
  if command -v nvidia-smi >/dev/null 2>&1 || [ "${OPENCLAW_ENABLE_GPU:-0}" == "1" ]; then
    cat >>"$d/docker-compose.yml" <<'EOF'
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
EOF
  fi

  # ── Generate Dockerfile.kasmvnc ──
  cat >"$d/Dockerfile.kasmvnc" <<'EOF'
FROM node:22-bookworm

USER root

# Remove dpkg exclusions so locale files are installed
RUN rm -f /etc/dpkg/dpkg.cfg.d/docker && rm -f /etc/apt/apt.conf.d/docker-clean

# Install git and ssh client (required by some npm lifecycle scripts and git dependencies)
RUN apt-get update && apt-get install -y --no-install-recommends git openssh-client && rm -rf /var/lib/apt/lists/*

# Accept proxy build arguments
ARG HTTP_PROXY
ARG HTTPS_PROXY

# Install OpenClaw via npm
ARG OPENC_CACHE_BUST=1
RUN npm config set registry https://registry.npmjs.org \
 && git config --global url."https://github.com/".insteadOf "git@github.com:" \
 && git config --global url."https://github.com/".insteadOf "ssh://git@github.com/" \
 && git config --global url."https://".insteadOf "git://" \
 && npm install -g openclaw@latest --no-audit --no-fund \
 && chown -R node:node /usr/local/lib/node_modules /usr/local/bin

# Configure timezone and locale (can be overridden via build args)
ARG TZ=UTC
ARG LANG=en_US.UTF-8
ENV PATH="/opt/KasmVNC/bin:${PATH}"
ENV TZ=${TZ}
ENV LANG=${LANG}
ENV LANGUAGE=en_US:en
ENV LC_ALL=${LANG}

ARG KASMVNC_VERSION=1.3.0
ARG TARGETARCH

# Install desktop environment and runtime dependencies
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    chromium \
    curl \
    dbus-x11 \
    fonts-noto-core \
    gnupg \
    jq \
    libdatetime-perl \
    libegl1 \
    libglu1-mesa \
    libglx-mesa0 \
    locales \
    lsof \
    procps \
    sudo \
    tzdata \
    vim \
    wget \
    xfce4 \
    xfce4-terminal \
    xterm \
  && ln -snf /usr/share/zoneinfo/${TZ} /etc/localtime \
  && echo "${TZ}" > /etc/timezone \
  && sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen \
  && locale-gen en_US.UTF-8 \
  && update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
  && rm -rf /var/lib/apt/lists/*
EOF

  # If Docker-in-Docker is not disabled, install Docker CE
  if [ "${NO_DIND:-0}" != "1" ]; then
    cat >>"$d/Dockerfile.kasmvnc" <<'EOF'

# Install Docker CE for Docker-in-Docker support
RUN curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg \
  && echo "deb [arch=${TARGETARCH} signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian bookworm stable" \
     > /etc/apt/sources.list.d/docker.list \
  && apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends --fix-missing \
     docker-ce docker-ce-cli containerd.io docker-compose-plugin \
  && rm -rf /var/lib/apt/lists/*
EOF
  fi

  cat >>"$d/Dockerfile.kasmvnc" <<'EOF'

# Create chromium-kasm wrapper script and update desktop shortcuts
RUN printf '%s\n' \
  '#!/usr/bin/env bash' \
  'exec /usr/bin/chromium --no-sandbox --disable-gpu --disable-dev-shm-usage --disable-software-rasterizer --test-type --no-first-run --disable-background-networking --disable-sync --disable-default-apps --disable-component-update --disable-features=TranslateUI --user-data-dir="${HOME}/.config/chromium-user" --remote-debugging-port=9222 --remote-debugging-address=127.0.0.1 "$@"' \
  > /usr/local/bin/chromium-kasm \
  && chmod +x /usr/local/bin/chromium-kasm \
  && sed -i 's|^Exec=/usr/bin/chromium %U|Exec=/usr/local/bin/chromium-kasm %U|' /usr/share/applications/chromium.desktop \
  && echo 'NoDisplay=true' >> /usr/share/applications/chromium.desktop \
  && sed -i 's|^Exec=exo-open --launch WebBrowser %u|Exec=/usr/local/bin/chromium-kasm %u|' /usr/share/applications/xfce4-web-browser.desktop \
  && printf '%s\n' \
    '[Desktop Entry]' \
    'Version=1.0' \
    'Name=Chromium' \
    'GenericName=Web Browser' \
    'Exec=/usr/local/bin/chromium-kasm %U' \
    'Terminal=false' \
    'Type=Application' \
    'Icon=chromium' \
    'Categories=Network;WebBrowser;' \
    'MimeType=text/html;text/xml;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;' \
    > /usr/share/applications/chromium-kasm.desktop \
  && printf '%s\n' \
    '[Desktop Entry]' \
    'Type=X-XFCE-Helper' \
    'X-XFCE-Category=WebBrowser' \
    'X-XFCE-Commands=/usr/local/bin/chromium-kasm' \
    'X-XFCE-CommandsWithParameter=/usr/local/bin/chromium-kasm "%s"' \
    'Name=Chromium' \
    'Icon=chromium' \
    > /usr/share/xfce4/helpers/chromium-kasm.desktop

# Install VS Code
RUN set -eux; \
  mkdir -p /etc/apt/keyrings; \
  wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /etc/apt/keyrings/microsoft-archive-keyring.gpg; \
  echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/microsoft-archive-keyring.gpg] https://packages.microsoft.com/repos/code stable main" \
    > /etc/apt/sources.list.d/vscode.list; \
  apt-get update; \
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends code; \
  rm -rf /var/lib/apt/lists/*

# Create desktop icons for Chromium and VS Code
RUN mkdir -p /home/node/Desktop \
  && cp /usr/share/applications/chromium-kasm.desktop /home/node/Desktop/chromium.desktop \
  && cp /usr/share/applications/code.desktop /home/node/Desktop/vscode.desktop \
  && chmod +x /home/node/Desktop/chromium.desktop /home/node/Desktop/vscode.desktop \
  && chown -R node:node /home/node/Desktop

# Install Hermes Agent (Nous Research) — runs as root, FHS layout puts binary at /usr/local/bin/hermes (survives /home/node volume mount)
ARG INSTALL_HERMES=1
RUN if [ "${INSTALL_HERMES}" = "1" ]; then \
      curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh \
        | bash -s -- --skip-setup \
      || echo "[hermes-agent] install.sh failed; container will lack hermes binary"; \
      [ -d /usr/local/lib/hermes-agent ] && chown -R node:node /usr/local/lib/hermes-agent || true; \
    fi

# Download and install KasmVNC .deb for the target architecture
RUN set -eux; \
  case "${TARGETARCH}" in \
    amd64) pkg_arch="amd64" ;; \
    arm64) pkg_arch="arm64" ;; \
    *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
  esac; \
  pkg="kasmvncserver_bookworm_${KASMVNC_VERSION}_${pkg_arch}.deb"; \
  url="https://github.com/kasmtech/KasmVNC/releases/download/v${KASMVNC_VERSION}/${pkg}"; \
  curl -fsSL "${url}" -o "/tmp/${pkg}"; \
  apt-get update; \
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "/tmp/${pkg}"; \
  rm -f "/tmp/${pkg}"; \
  rm -rf /var/lib/apt/lists/*

COPY scripts/docker/systemctl-shim.sh /usr/local/bin/systemctl
COPY scripts/docker/kasmvnc-startup.sh /usr/local/bin/kasmvnc-startup
RUN sed -i 's/\r$//' /usr/local/bin/systemctl /usr/local/bin/kasmvnc-startup \
  && chmod +x /usr/local/bin/systemctl /usr/local/bin/kasmvnc-startup \
  && usermod -a -G ssl-cert node \
  && (getent group docker >/dev/null && usermod -a -G docker node || true) \
  && echo "node ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers \
  && mkdir -p /home/node/.openclaw /home/node/.vnc \
  && chown -R node:node /home/node/.openclaw /home/node/.vnc \
  && chmod 700 /home/node/.openclaw /home/node/.vnc

USER node

# Configure git to use HTTPS instead of SSH (supports npm dependencies and openclaw update)
RUN git config --global url."https://github.com/".insteadOf "git@github.com:" \
 && git config --global url."https://github.com/".insteadOf "ssh://git@github.com/" \
 && git config --global url."https://".insteadOf "git://"

EXPOSE 18789 18790 8443 8444

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD curl -f http://localhost:18789/ || exit 1

ENTRYPOINT ["/usr/local/bin/kasmvnc-startup"]
CMD ["openclaw", "gateway", "--bind", "lan", "--port", "18789"]
EOF

  # ── Generate kasmvnc-startup.sh (container entrypoint) ──
  cat >"$d/scripts/docker/kasmvnc-startup.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

export HOME="${HOME:-/home/node}"
export USER="${USER:-node}"
export DISPLAY="${OPENCLAW_KASMVNC_DISPLAY:-:1}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/xdg-runtime}"
export BROWSER="/usr/local/bin/chromium-kasm"

# Resolve OpenClaw version for UI display
if [ -z "${OPENCLAW_VERSION:-}" ]; then
  OPENCLAW_VERSION=$(openclaw --version 2>/dev/null | head -n1 || echo "dev")
  export OPENCLAW_VERSION
fi

KASMVNC_USER="${OPENCLAW_KASMVNC_USER:-node}"
KASMVNC_PASSWORD="${OPENCLAW_KASMVNC_PASSWORD:-}"
RESOLUTION="${OPENCLAW_KASMVNC_RESOLUTION:-1920x1080}"
DEPTH="${OPENCLAW_KASMVNC_DEPTH:-24}"

# Fix /home/node + critical subdirs ownership on every start (idempotent)
# Volume mount may have root-owned paths even when $HOME itself is writable.
sudo chown "$(id -u):$(id -g)" "${HOME}" 2>/dev/null || true
[ -e "${HOME}/.openclaw" ] && sudo chown -R "$(id -u):$(id -g)" "${HOME}/.openclaw" 2>/dev/null || true
[ -e "${HOME}/.vnc" ] && sudo chown -R "$(id -u):$(id -g)" "${HOME}/.vnc" 2>/dev/null || true
[ -e "${HOME}/.config" ] && sudo chown -R "$(id -u):$(id -g)" "${HOME}/.config" 2>/dev/null || true
[ -e "${HOME}/Desktop" ] && sudo chown -R "$(id -u):$(id -g)" "${HOME}/Desktop" 2>/dev/null || true

mkdir -p "${HOME}/.vnc" "${XDG_RUNTIME_DIR}" "${HOME}/.openclaw"
chmod 700 "${HOME}/.vnc" "${XDG_RUNTIME_DIR}" "${HOME}/.openclaw" 2>/dev/null || true

# Start Docker daemon in background for DinD support (only if NO_DIND != 1)
if [ "${NO_DIND:-0}" != "1" ] && command -v dockerd >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1; then
  (sudo nohup dockerd >/tmp/openclaw-dockerd.log 2>&1 &) || true
  for i in $(seq 1 30); do
    [ -S /var/run/docker.sock ] && break
    sleep 1
  done
fi

sed -i '/^alias openclaw=/d' "${HOME}/.bashrc" 2>/dev/null || true

# Ensure desktop icons exist (volume mount may hide image-baked icons on re-install)
mkdir -p "${HOME}/Desktop"
# Clean up stale desktop icons from earlier image versions
rm -f "${HOME}/Desktop/hermes-agent.desktop" 2>/dev/null || true
[ -f "${HOME}/Desktop/chromium.desktop" ] || cp /usr/share/applications/chromium-kasm.desktop "${HOME}/Desktop/chromium.desktop" 2>/dev/null || true
[ -f "${HOME}/Desktop/vscode.desktop" ] || cp /usr/share/applications/code.desktop "${HOME}/Desktop/vscode.desktop" 2>/dev/null || true
chmod +x "${HOME}/Desktop/chromium.desktop" "${HOME}/Desktop/vscode.desktop" 2>/dev/null || true
chmod +x "${HOME}/Desktop"/*.desktop 2>/dev/null || true

# Configure NPM registry based on USE_CN_MIRROR
if [ "${USE_CN_MIRROR:-0}" = "1" ]; then
  cat > "${HOME}/.npmrc" <<'EONPMRC'
registry=https://registry.npmmirror.com
EONPMRC
else
  cat > "${HOME}/.npmrc" <<'EONPMRC'
registry=https://registry.npmjs.org
EONPMRC
fi

mkdir -p "${HOME}/.config" "${HOME}/.config/xfce4"
cat > "${HOME}/.config/xfce4/helpers.rc" <<'EOH'
WebBrowser=chromium-kasm
EOH
cat > "${HOME}/.config/mimeapps.list" <<'EOH'
[Default Applications]
x-scheme-handler/http=chromium-kasm.desktop
x-scheme-handler/https=chromium-kasm.desktop
text/html=chromium-kasm.desktop
EOH

if ! id -u "${KASMVNC_USER}" >/dev/null 2>&1; then
  KASMVNC_USER="node"
fi

# Generate VNC xstartup script
cat > "${HOME}/.vnc/xstartup" <<'EOH'
#!/usr/bin/env bash
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
  eval "$(dbus-launch --sh-syntax 2>/dev/null)" || true
  export DBUS_SESSION_BUS_ADDRESS
fi
exec startxfce4
EOH
chmod +x "${HOME}/.vnc/xstartup"

# Use KasmVNC desktop environment selector to register XFCE
if command -v /usr/lib/kasmvncserver/select-de.sh >/dev/null 2>&1; then
  /usr/lib/kasmvncserver/select-de.sh -y -s XFCE >/tmp/openclaw-kasmvnc-selectde.log 2>&1 || true
fi

# Set VNC login password
if [ -n "${KASMVNC_PASSWORD}" ]; then
  printf '%s\n%s\n' "${KASMVNC_PASSWORD}" "${KASMVNC_PASSWORD}" \
    | vncpasswd -u "${KASMVNC_USER}" -w -r >/dev/null || true
fi

# Clean up stale VNC/X11 state from previous container runs
if vncserver -list 2>/dev/null | grep -Eq "^[[:space:]]*${DISPLAY}[[:space:]]"; then
  vncserver -kill "${DISPLAY}" >/dev/null 2>&1 || true
fi
pkill -9 -f "Xvnc.*${DISPLAY}" 2>/dev/null || true
DISPLAY_NUM="${DISPLAY#:}"
rm -f "/tmp/.X${DISPLAY_NUM}-lock" "/tmp/.X11-unix/X${DISPLAY_NUM}"
rm -f "${HOME}/.vnc/"*"${DISPLAY}"*.pid 2>/dev/null || true

# Override KasmVNC DLP clipboard config
sudo tee /etc/kasmvnc/kasmvnc.yaml >/dev/null <<'KASMCFG' || true
data_loss_prevention:
  clipboard:
    allow_mimetypes:
      - text/html
      - image/png
KASMCFG

# Start VNC server
vncserver "${DISPLAY}" -geometry "${RESOLUTION}" -depth "${DEPTH}" -xstartup "${HOME}/.vnc/xstartup" -publicIP 127.0.0.1 >/tmp/openclaw-kasmvnc.log 2>&1 || true

# Fallback: start XFCE if not already running
if ! pgrep -u "$(id -u)" -f "xfce4-session" >/dev/null 2>&1; then
  DISPLAY="${DISPLAY}" nohup sh "${HOME}/.vnc/xstartup" >/tmp/openclaw-xfce-autostart.log 2>&1 &
fi

# Set default browser to chromium-kasm
if command -v xdg-settings >/dev/null 2>&1; then
  DISPLAY="${DISPLAY}" xdg-settings set default-web-browser chromium-kasm.desktop >/dev/null 2>&1 || true
fi

# Clean up platform fingerprints in config (preserve auth tokens)
if [ -f "${HOME}/.openclaw/openclaw.json" ]; then
  if command -v jq >/dev/null 2>&1; then
    # Use jq to surgically remove only platform fields
    jq 'del(.identity.pinnedPlatform, .identity.pinnedDeviceFamily)' \
      "${HOME}/.openclaw/openclaw.json" > "${HOME}/.openclaw/openclaw.json.tmp" 2>/dev/null \
      && mv "${HOME}/.openclaw/openclaw.json.tmp" "${HOME}/.openclaw/openclaw.json" || true
  else
    # Fallback: if non-Linux platform detected, backup entire config
    if grep -q '"pinnedPlatform".*"darwin"' "${HOME}/.openclaw/openclaw.json" 2>/dev/null || \
       grep -q '"pinnedPlatform".*"win32"' "${HOME}/.openclaw/openclaw.json" 2>/dev/null; then
      echo "Detected non-Linux platform config, backing up..." >&2
      mv "${HOME}/.openclaw/openclaw.json" "${HOME}/.openclaw/openclaw.json.bak" 2>/dev/null || true
    fi
  fi
fi

# Ensure systemd service file exists (support install/uninstall commands)
if [ ! -f "${HOME}/.config/systemd/user/openclaw-gateway.service" ]; then
  mkdir -p "${HOME}/.config/systemd/user"
  cat > "${HOME}/.config/systemd/user/openclaw-gateway.service" <<'EOSVC'
[Unit]
Description=OpenClaw Gateway (managed by supervisor)
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/bin/true
RemainAfterExit=yes

[Install]
WantedBy=default.target
EOSVC
fi

# Clear stop marker (auto-start after container restart)
rm -f /tmp/openclaw-gateway.stopped

# Repair/stamp the local gateway config before startup. Recent OpenClaw
# releases treat an existing config without gateway.mode as damaged and refuse
# to start, even when runtime callers still pass --allow-unconfigured.
mkdir -p "${HOME}/.openclaw/workspace"
openclaw config set gateway.mode local >/dev/null 2>&1 || true
openclaw config set agents.defaults.workspace "${HOME}/.openclaw/workspace" >/dev/null 2>&1 || true

# Allow Host-header origin fallback for remote access
openclaw config set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback true >/dev/null 2>&1 || true
# Force set gateway bind config (override possible loopback config)
openclaw config set gateway.bind "${OPENCLAW_GATEWAY_BIND:-lan}" >/dev/null 2>&1 || true
# Enable self-improvement hook
openclaw hooks enable self-improvement >/dev/null 2>&1 || true

# Run supervisor loop in foreground (bypass systemctl to avoid double-backgrounding)
export OPENCLAW_SERVICE_MARKER=1
unset OPENCLAW_NO_RESPAWN 2>/dev/null || true

# Supervisor loop: auto-restart gateway on exit
while true; do
  # 检查停止标记：如果存在则等待它被清除
  while [ -f /tmp/openclaw-gateway.stopped ]; do
    sleep 1
  done

  # 从 package.json 读取版本号并导出
  ver="$(node -p "require('/usr/local/lib/node_modules/openclaw/package.json').version" 2>/dev/null || true)"
  if [ -n "$ver" ]; then export OPENCLAW_VERSION="$ver"; fi

  # 启动 gateway（前台运行）
  # 临时关闭 set -e 以便捕获退出码
  set +e
  if command -v openclaw >/dev/null 2>&1; then
    # 如果设置了 OPENCLAW_GATEWAY_TOKEN 则添加 --token 参数
    if [ -n "${OPENCLAW_GATEWAY_TOKEN:-}" ]; then
      openclaw gateway --allow-unconfigured --bind "${OPENCLAW_GATEWAY_BIND:-lan}" --port 18789 --token "${OPENCLAW_GATEWAY_TOKEN}" >>/tmp/openclaw-gateway.log 2>&1
    else
      openclaw gateway --allow-unconfigured --bind "${OPENCLAW_GATEWAY_BIND:-lan}" --port 18789 >>/tmp/openclaw-gateway.log 2>&1
    fi
  elif command -v openclaw-gateway >/dev/null 2>&1; then
    openclaw-gateway --port 18789 >>/tmp/openclaw-gateway.log 2>&1
  else
    echo "kasmvnc-startup: cannot start gateway (openclaw CLI not found)" >&2
    sleep infinity
  fi

  rc=$?
  set -e

  # exit 0 = 正常重启（SIGUSR1 supervised），短暂等待后重启
  # 非零退出 = 异常崩溃，等待更长时间后重试
  if [ $rc -eq 0 ]; then
    echo "kasmvnc-startup: gateway exited (supervised restart), restarting..." >&2
    sleep 1
  else
    echo "kasmvnc-startup: gateway crashed (exit $rc), restarting in 3s..." >&2
    sleep 3
  fi
done
EOF
  chmod +x "$d/scripts/docker/kasmvnc-startup.sh"

  # ── Generate systemctl-shim.sh ──
  cat >"$d/scripts/docker/systemctl-shim.sh" <<'SHIMEOF'
#!/usr/bin/env bash
# systemctl shim for Docker containers without systemd
set -euo pipefail

DISABLED_MARKER="/tmp/openclaw-gateway.disabled"
STOP_MARKER="/tmp/openclaw-gateway.stopped"

find_gateway_pid() {
  local pid
  pid="$(lsof -i :${OPENCLAW_GATEWAY_INTERNAL_PORT:-18789} -sTCP:LISTEN -t 2>/dev/null | head -1 || true)"
  if [ -n "$pid" ] && [ "$pid" != "1" ]; then
    echo "$pid"
    return 0
  fi
  return 1
}

resolve_openclaw_version() {
  local ver
  ver="$(node -p "require('/usr/local/lib/node_modules/openclaw/package.json').version" 2>/dev/null || true)"
  if [ -n "$ver" ]; then export OPENCLAW_VERSION="$ver"; fi
}

wait_gateway_ready() {
  local pid
  for _ in $(seq 1 120); do
    pid="$(find_gateway_pid || true)"
    [ -n "$pid" ] && return 0
    sleep 0.5
  done
  echo "systemctl shim: gateway failed to start (timeout waiting for port)" >&2
  return 1
}

args=("$@"); action=""
for a in "${args[@]}"; do
  case "$a" in
    --version) echo "systemd 252 (shim)"; exit 0 ;;
    status|restart|start|stop|is-enabled|is-active|show|daemon-reload|enable|disable) [ -z "$action" ] && action="$a" ;;
  esac
done

# ── 根据动作执行对应操作 ──
case "$action" in
  daemon-reload|status)
    # 始终返回 0：openclaw CLI 调用 "systemctl --user status" 检测 systemd 是否可用
    # 返回非零 = "systemctl 不可用" = 所有命令都会失败
    exit 0 ;;
  enable)
    # 启用服务：删除禁用标记
    rm -f "$DISABLED_MARKER"; exit 0 ;;
  disable)
    # 禁用服务：创建禁用标记
    touch "$DISABLED_MARKER"; exit 0 ;;
  is-enabled)
    # 通过 marker 文件跟踪 install/uninstall 状态
    # 默认（无 marker）= 已启用，这样入口脚本启动的网关无需额外 "openclaw gateway install"
    [ -f "$DISABLED_MARKER" ] && exit 1
    exit 0 ;;
  is-active)
    # 检查网关进程是否在运行
    pid=$(find_gateway_pid || true)
    [ -n "$pid" ] && { echo "active"; exit 0; } || { echo "inactive"; exit 3; } ;;
  start)
    # 启动网关：清除停止和禁用标记，让主 supervisor 继续运行
    # 注意：主 supervisor 由 kasmvnc-startup.sh 启动，这里只是解除停止状态
    rm -f "$DISABLED_MARKER" "$STOP_MARKER"
    wait_gateway_ready; exit $? ;;
  restart)
    # 重启网关：杀掉当前 gateway，主 supervisor 会自动重启
    pid=$(find_gateway_pid || true)
    if [ -z "$pid" ]; then
      # 如果没有运行，清除标记让主 supervisor 启动
      rm -f "$DISABLED_MARKER" "$STOP_MARKER"
      wait_gateway_ready; exit $?
    fi
    # 确保没有 STOP_MARKER（让主 supervisor 能自动重启）
    rm -f "$DISABLED_MARKER" "$STOP_MARKER"
    # 杀掉当前 gateway 进程
    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 60); do
      if ! kill -0 "$pid" 2>/dev/null; then break; fi
      sleep 0.25
    done
    kill -KILL "$pid" 2>/dev/null || true
    sleep 0.5
    # 主 supervisor 会自动重启 gateway
    wait_gateway_ready; exit $? ;;
  stop)
    # 停止网关和 supervisor 循环（不影响 is-enabled 状态）
    touch "$STOP_MARKER"
    pid=$(find_gateway_pid || true)
    [ -z "$pid" ] && exit 0
    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 60); do
      if ! kill -0 "$pid" 2>/dev/null; then exit 0; fi
      sleep 0.25
    done
    kill -KILL "$pid" 2>/dev/null || true
    exit 0 ;;
  show)
    # 输出 systemd 风格的属性信息（openclaw CLI 解析用）
    pid=$(find_gateway_pid || true)
    if [ -n "$pid" ]; then
      printf 'ActiveState=active\nSubState=running\nMainPID=%s\nExecMainStatus=0\nExecMainCode=exited\n' "$pid"
    else
      printf 'ActiveState=inactive\nSubState=dead\nMainPID=0\nExecMainStatus=0\nExecMainCode=exited\n'
    fi; exit 0 ;;
  *) exit 0 ;;  # 未识别的动作静默忽略
esac
SHIMEOF
  chmod +x "$d/scripts/docker/systemctl-shim.sh"
}

# ── Health check ──────────────────────────────────────────────────────────────
assert_gateway_running() {
  local cid
  cid="$(compose_cmd ps -q openclaw-gateway | head -n 1)"
  if [ -z "$cid" ]; then
    echo "openclaw-gateway container not found after compose operation." >&2
    exit 1
  fi
  if [ "$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null || echo false)" != "true" ]; then
    echo "openclaw-gateway is not running (container: $cid)." >&2
    exit 1
  fi
  # Also verify the gateway process inside the container is alive (up to 600s)
  # First-time install on slow filesystems may need 5-10 minutes
  echo "Waiting for gateway to be ready (up to 10 minutes)..." >&2
  local retries=0
  while [ $retries -lt 300 ]; do
    if docker exec "$cid" sh -c 'systemctl is-active openclaw-gateway' >/dev/null 2>&1; then
      return 0
    fi
    if [ $retries -gt 0 ] && [ $((retries % 30)) -eq 0 ]; then
      echo "  ...still waiting ($((retries * 2))s elapsed)" >&2
    fi
    retries=$((retries + 1))
    sleep 2
  done
  echo "=== Last 80 lines of container log ===" >&2
  docker logs --tail 80 "$cid" >&2 2>&1 || true
  echo "=== Last 60 lines of gateway log ===" >&2
  docker exec "$cid" sh -c 'tail -n 60 /tmp/openclaw-gateway.log 2>/dev/null' >&2 || true
  echo "" >&2
  echo "Gateway not ready after 10 minutes. Check status with:" >&2
  echo "  docker exec $cid systemctl is-active openclaw-gateway" >&2
  echo "  curl http://127.0.0.1:18789/" >&2
  echo "Container is running but gateway process is not responding (container: $cid)." >&2
  exit 1
}

require_install_dir() {
  if [ ! -d "$INSTALL_DIR" ]; then
    echo "Install directory not found: $INSTALL_DIR" >&2
    echo "Run './openclaw-kasmvnc.sh install' first." >&2
    exit 1
  fi
}

# ── install ──────────────────────────────────────────────────────────────
install_cmd() {
  assert_cmd docker
  if ! docker compose version >/dev/null 2>&1; then
    echo "Missing Docker Compose v2 plugin: 'docker compose'" >&2
    exit 1
  fi

  if [ -z "$GATEWAY_TOKEN" ]; then
    GATEWAY_TOKEN="$(random_hex 32)"
  fi
  if [ -z "$KASM_PASSWORD" ]; then
    KASM_PASSWORD="$(random_hex 16)"
  fi

  mkdir -p "$INSTALL_DIR"
  ensure_build_context

  (
    cd "$INSTALL_DIR"
    mkdir -p .openclaw .openclaw/workspace
    if [ "$(uname -s)" == "Linux" ]; then
      chown -R 1000:1000 .openclaw 2>/dev/null || true
    fi
    upsert_env_line .env OPENCLAW_CONFIG_DIR "./.openclaw"
    upsert_env_line .env OPENCLAW_WORKSPACE_DIR "./.openclaw/workspace"
    upsert_env_line .env OPENCLAW_GATEWAY_TOKEN "$GATEWAY_TOKEN"
    upsert_env_line .env OPENCLAW_GATEWAY_PORT "$GATEWAY_PORT"
    upsert_env_line .env OPENCLAW_KASMVNC_PASSWORD "$KASM_PASSWORD"
    upsert_env_line .env OPENCLAW_KASMVNC_HTTPS_PORT "$HTTPS_PORT"
    upsert_env_line .env TZ "UTC"
    upsert_env_line .env LANG "en_US.UTF-8"
    upsert_env_line .env LANGUAGE "en_US:en"
    upsert_env_line .env LC_ALL "en_US.UTF-8"
    if [ "${NO_DIND:-0}" = "1" ]; then
      upsert_env_line .env NO_DIND "1"
    fi
    if [ -n "$HTTP_PROXY_URL" ]; then
      upsert_env_line .env OPENCLAW_HTTP_PROXY "$HTTP_PROXY_URL"
    fi
    if [ "$NO_CACHE" -eq 1 ]; then
      compose_cmd build --no-cache openclaw-gateway
      compose_cmd up -d openclaw-gateway
    else
      compose_cmd up -d --build openclaw-gateway
    fi
    assert_gateway_running
  )

  echo
  echo "Install complete."
  echo "Directory: $INSTALL_DIR"
  echo "WebChat: http://127.0.0.1:${GATEWAY_PORT}/chat?session=main"
  echo "Desktop: https://127.0.0.1:${HTTPS_PORT}"
  echo "OPENCLAW_GATEWAY_TOKEN=${GATEWAY_TOKEN}"
  echo "OPENCLAW_KASMVNC_PASSWORD=${KASM_PASSWORD}"
}

# ── uninstall ────────────────────────────────────────────────────────────
uninstall_cmd() {
  if [ -d "$INSTALL_DIR" ]; then
    (
      cd "$INSTALL_DIR"
      if command -v docker >/dev/null 2>&1; then
        compose_cmd down || true
      fi
    )
    echo "Stopped services in: $INSTALL_DIR"
  else
    echo "Install directory not found: $INSTALL_DIR"
  fi

  if [ "$PURGE" -eq 1 ]; then
    rm -rf "$INSTALL_DIR"
    echo "Removed install directory: $INSTALL_DIR"
  else
    echo "Uninstall completed without deleting files."
    echo "Use --purge to remove install directory."
  fi
}

# ── restart ──────────────────────────────────────────────────────────────
restart_cmd() {
  require_install_dir
  (
    cd "$INSTALL_DIR"
    ensure_build_context
    compose_cmd restart openclaw-gateway
    assert_gateway_running
  )
}

# ── upgrade ──────────────────────────────────────────────────────────────
upgrade_cmd() {
  require_install_dir
  (
    cd "$INSTALL_DIR"
    ensure_build_context
    compose_cmd up -d openclaw-gateway
    compose_cmd exec -T openclaw-gateway sh -lc '
      set -e
      echo "registry=https://registry.npmjs.org" > "${HOME}/.npmrc"
      rm -rf /usr/local/lib/node_modules/.openclaw-* /usr/local/bin/.openclaw-* 2>/dev/null || true
      attempt=1
      until timeout 30m npm i -g openclaw@latest --no-audit --no-fund --loglevel=info; do
        if [ "${attempt}" -ge 3 ]; then
          echo "openclaw upgrade failed after ${attempt} attempts" >&2
          exit 1
        fi
        attempt=$((attempt + 1))
        sleep 5
      done
    '
    compose_cmd exec -T openclaw-gateway sh -lc '
      set -e
      openclaw gateway restart >/tmp/openclaw-upgrade-restart.log 2>&1 || openclaw gateway start
      # Verify gateway process is actually running
      for i in $(seq 1 30); do
        if systemctl is-active openclaw-gateway >/dev/null 2>&1; then
          exit 0
        fi
        sleep 1
      done
      echo "Gateway process failed to start after upgrade" >&2
      exit 1
    '
    assert_gateway_running
  )
}

# ── status ───────────────────────────────────────────────────────────────
status_cmd() {
  require_install_dir
  (
    cd "$INSTALL_DIR"
    compose_cmd ps
  )
}

# ── logs ─────────────────────────────────────────────────────────────────
logs_cmd() {
  require_install_dir
  (
    cd "$INSTALL_DIR"
    compose_cmd logs --tail="$TAIL_LINES" openclaw-gateway
  )
}

# ── Main entry ────────────────────────────────────────────────────────────
parse_args "$@"

case "$COMMAND" in
  install) install_cmd ;;
  uninstall) uninstall_cmd ;;
  restart) restart_cmd ;;
  upgrade) upgrade_cmd ;;
  status) status_cmd ;;
  logs) logs_cmd ;;
  -h|--help|help) usage ;;
  *)
    echo "Unknown command: $COMMAND" >&2
    usage
    exit 1
    ;;
esac
