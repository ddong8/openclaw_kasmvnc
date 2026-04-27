# ============================================================================
# openclaw-kasmvnc.ps1 — OpenClaw + KasmVNC one-click deployment script (Windows)
#
# Overview:
#   Generates Dockerfile, docker-compose.yml, KasmVNC startup script and systemctl shim,
#   then builds and runs the container via Docker Compose. The container includes an XFCE
#   desktop, Chromium browser, and the OpenClaw gateway service.
#
# Commands:
#   install   — Configure + build image + start container
#   uninstall — Stop container (optional -Purge removes install dir)
#   restart   — Restart openclaw-gateway container
#   upgrade   — Upgrade OpenClaw npm package in running container
#   status    — Show Compose service status
#   logs      — Show container logs
# ============================================================================

param(
  [ValidateSet("install", "uninstall", "restart", "upgrade", "status", "logs")]
  [string]$Command = "install",
  [string]$InstallDir = "$HOME\openclaw-kasmvnc",
  [string]$GatewayToken = "",
  [string]$KasmPassword = "",
  [string]$HttpsPort = "8443",
  [string]$GatewayPort = "18789",
  [int]$Tail = 200,
  [string]$Proxy = "",
  [switch]$NoCache,
  [switch]$Purge,
  [switch]$NoDinD
)

$ErrorActionPreference = "Stop"

# ── Utility Functions ──────────────────────────────────────────────────────────

function Assert-Command {
  param([string]$Name)
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Missing command: $Name"
  }
}

function Set-UnixContent {
  param(
    [string]$Path,
    [string]$Value
  )
  # Resolve relative paths against PowerShell's $PWD, not .NET's CurrentDirectory
  if (-not [System.IO.Path]::IsPathRooted($Path)) {
    $Path = Join-Path (Get-Location).Path $Path
  }
  $lf = $Value -replace "`r`n", "`n"
  [System.IO.File]::WriteAllText($Path, $lf, [System.Text.UTF8Encoding]::new($false))
}

function New-RandomHex {
  param([int]$Bytes = 32)
  $buf = New-Object byte[] $Bytes
  [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buf)
  return ($buf | ForEach-Object { $_.ToString("x2") }) -join ""
}


function Upsert-EnvLine {
  param(
    [string]$FilePath,
    [string]$Key,
    [string]$Value
  )
  # Resolve relative paths against PowerShell's $PWD, not .NET's CurrentDirectory
  if (-not [System.IO.Path]::IsPathRooted($FilePath)) {
    $FilePath = Join-Path (Get-Location).Path $FilePath
  }
  $line = "$Key=$Value"
  $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
  if (-not (Test-Path $FilePath)) {
    [System.IO.File]::WriteAllText($FilePath, "$line`n", $utf8NoBom)
    return
  }
  $content = [System.IO.File]::ReadAllText($FilePath, $utf8NoBom)
  if ($content -match "(?m)^$([regex]::Escape($Key))=") {
    $updated = [regex]::Replace(
      $content,
      "(?m)^$([regex]::Escape($Key))=.*$",
      [System.Text.RegularExpressions.MatchEvaluator] { param($m) $line }
    )
    [System.IO.File]::WriteAllText($FilePath, $updated, $utf8NoBom)
  }
  else {
    [System.IO.File]::AppendAllText($FilePath, "`n$line", $utf8NoBom)
  }
}

function Invoke-Compose {
  param([Parameter(Mandatory = $true)][string[]]$ComposeArgs)
  & docker compose -f docker-compose.yml @ComposeArgs
  if ($LASTEXITCODE -ne 0) {
    throw "docker compose failed: $($ComposeArgs -join ' ')"
  }
}

function Ensure-BuildContext {
  New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir "scripts\docker") | Out-Null

  # ── Generate docker-compose.yml ──
  $composeYaml = @'
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
'@

  # Only add privileged: true if DinD is not disabled
  if (-not $NoDinD) {
    $composeYaml += "`n    privileged: true"
  }

  $composeYaml += @'

    init: true
    restart: unless-stopped
'@

  # Auto-detect NVIDIA GPU and inject GPU support if available
  if ((Get-Command nvidia-smi -ErrorAction SilentlyContinue) -or ($env:OPENCLAW_ENABLE_GPU -eq "1")) {
    $composeYaml += "`n" + @'
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
'@
  }

  $composeYaml | ForEach-Object { Set-UnixContent -Path (Join-Path $InstallDir "docker-compose.yml") -Value $_ }

  # ── Generate Dockerfile.kasmvnc ──
  @'
FROM node:22-bookworm

USER root

# Remove dpkg exclusions so translation files (locales) are installed for full UI localization
RUN rm -f /etc/dpkg/dpkg.cfg.d/docker && rm -f /etc/apt/apt.conf.d/docker-clean

# Install git and ssh client (required by some npm lifecycle scripts and git dependencies)
RUN apt-get update && apt-get install -y --no-install-recommends git openssh-client && rm -rf /var/lib/apt/lists/*

# Accept proxy build arguments
ARG HTTP_PROXY
ARG HTTPS_PROXY

# Install OpenClaw via npm (pre-built, includes correct version metadata)
# Configure npm registry and force git to use HTTPS, preserving optional dependencies
# Install OpenClaw via npm
ARG OPENC_CACHE_BUST=1
RUN npm config set registry https://registry.npmjs.org \
 && git config --global url.\"https://github.com/\".insteadOf \"git@github.com:\" \
 && git config --global url.\"https://github.com/\".insteadOf \"ssh://git@github.com/\" \
 && git config --global url.\"https://\".insteadOf \"git://\" \
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

# Install Docker CE for Docker-in-Docker support (only if NO_DIND != 1)
ARG NO_DIND=0
RUN if [ "${NO_DIND}" != "1" ]; then \
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg \
  && echo "deb [arch=${TARGETARCH} signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian bookworm stable" \
     > /etc/apt/sources.list.d/docker.list \
  && apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends --fix-missing \
     docker-ce docker-ce-cli containerd.io docker-compose-plugin \
  && rm -rf /var/lib/apt/lists/*; \
fi

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
'@ | ForEach-Object { Set-UnixContent -Path (Join-Path $InstallDir "Dockerfile.kasmvnc") -Value $_ }

  # ── Generate kasmvnc-startup.sh ──
  @'
#!/usr/bin/env bash
set -euo pipefail

export HOME="${HOME:-/home/node}"
export USER="${USER:-node}"
export DISPLAY="${OPENCLAW_KASMVNC_DISPLAY:-:1}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/xdg-runtime}"
export BROWSER="/usr/local/bin/chromium-kasm"

# Resolve OpenClaw version for UI display (npm global install)
if [ -z "${OPENCLAW_VERSION:-}" ]; then
  OPENCLAW_VERSION=$(openclaw --version 2>/dev/null | head -n1 || echo "dev")
  export OPENCLAW_VERSION
fi

KASMVNC_USER="${OPENCLAW_KASMVNC_USER:-node}"
KASMVNC_PASSWORD="${OPENCLAW_KASMVNC_PASSWORD:-}"
RESOLUTION="${OPENCLAW_KASMVNC_RESOLUTION:-1920x1080}"
DEPTH="${OPENCLAW_KASMVNC_DEPTH:-24}"

# Fix /home/node ownership when mounted as a volume (may be root-owned)
if [ ! -w "${HOME}" ]; then
  sudo chown -R "$(id -u):$(id -g)" "${HOME}" 2>/dev/null || true
fi

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

# Ensure interactive shells call openclaw directly (no throttling alias)
sed -i '/^alias openclaw=/d' "${HOME}/.bashrc" 2>/dev/null || true

# Ensure desktop icons exist (volume mount may hide image-baked icons on re-install)
mkdir -p "${HOME}/Desktop"
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

if command -v /usr/lib/kasmvncserver/select-de.sh >/dev/null 2>&1; then
  /usr/lib/kasmvncserver/select-de.sh -y -s XFCE >/tmp/openclaw-kasmvnc-selectde.log 2>&1 || true
fi

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

# Override KasmVNC DLP clipboard config: remove "chromium/x-web-custom-data" MIME type
# so that Xvnc cmdline does not contain "chromium" (prevents pkill -f chromium from killing Xvnc)
sudo tee /etc/kasmvnc/kasmvnc.yaml >/dev/null <<'KASMCFG' || true
data_loss_prevention:
  clipboard:
    allow_mimetypes:
      - text/html
      - image/png
KASMCFG

vncserver "${DISPLAY}" -geometry "${RESOLUTION}" -depth "${DEPTH}" -xstartup "${HOME}/.vnc/xstartup" -publicIP 127.0.0.1 >/tmp/openclaw-kasmvnc.log 2>&1 || true

if ! pgrep -u "$(id -u)" -f "xfce4-session" >/dev/null 2>&1; then
  DISPLAY="${DISPLAY}" nohup sh "${HOME}/.vnc/xstartup" >/tmp/openclaw-xfce-autostart.log 2>&1 &
fi

if command -v xdg-settings >/dev/null 2>&1; then
  DISPLAY="${DISPLAY}" xdg-settings set default-web-browser chromium-kasm.desktop >/dev/null 2>&1 || true
fi

# Clean up platform fingerprints in config (preserve auth tokens)
if [ -f "${HOME}/.openclaw/openclaw.json" ]; then
  if command -v jq >/dev/null 2>&1; then
    jq 'del(.identity.pinnedPlatform, .identity.pinnedDeviceFamily)' \
      "${HOME}/.openclaw/openclaw.json" > "${HOME}/.openclaw/openclaw.json.tmp" 2>/dev/null \
      && mv "${HOME}/.openclaw/openclaw.json.tmp" "${HOME}/.openclaw/openclaw.json" || true
  else
    if grep -q '\"pinnedPlatform\".*\"darwin\"' "${HOME}/.openclaw/openclaw.json" 2>/dev/null || \
       grep -q '\"pinnedPlatform\".*\"win32\"' "${HOME}/.openclaw/openclaw.json" 2>/dev/null; then
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

openclaw config set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback true >/dev/null 2>&1 || true
openclaw config set gateway.bind "${OPENCLAW_GATEWAY_BIND:-lan}" >/dev/null 2>&1 || true
# Enable self-improvement hook
openclaw hooks enable self-improvement >/dev/null 2>&1 || true

# Run supervisor loop in foreground (bypass systemctl to avoid double-backgrounding)
export OPENCLAW_SERVICE_MARKER=1
unset OPENCLAW_NO_RESPAWN 2>/dev/null || true

# Supervisor loop: auto-restart gateway on exit (with latest version)
while true; do
  # Wait while stop marker is present
  while [ -f /tmp/openclaw-gateway.stopped ]; do
    sleep 1
  done

  # Read version from package.json and export
  ver="$(node -p "require('/usr/local/lib/node_modules/openclaw/package.json').version" 2>/dev/null || true)"
  if [ -n "$ver" ]; then export OPENCLAW_VERSION="$ver"; fi

  # Start gateway (foreground)
  # Temporarily disable set -e to capture exit code
  set +e
  if command -v openclaw >/dev/null 2>&1; then
    # Add --token parameter if OPENCLAW_GATEWAY_TOKEN is set
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

  # exit 0 = supervised restart (SIGUSR1), brief wait before restart
  # non-zero = crash, longer wait before retry
  if [ $rc -eq 0 ]; then
    echo "kasmvnc-startup: gateway exited (supervised restart), restarting..." >&2
    sleep 1
  else
    echo "kasmvnc-startup: gateway crashed (exit $rc), restarting in 3s..." >&2
    sleep 3
  fi
done
'@ | ForEach-Object { Set-UnixContent -Path (Join-Path $InstallDir "scripts\docker\kasmvnc-startup.sh") -Value $_ }

  # ── Generate systemctl-shim.sh ──
  @'
#!/usr/bin/env bash
# systemctl shim for Docker containers without systemd.
# Translates OpenClaw gateway systemctl calls into process signals.
set -euo pipefail

DISABLED_MARKER="/tmp/openclaw-gateway.disabled"
STOP_MARKER="/tmp/openclaw-gateway.stopped"

find_gateway_pid() {
  local pid
  # Find the process actually listening on the gateway port.
  # This is the only reliable method because Node.js process.title overwrites
  # the entire /proc/PID/cmdline, making server and CLI processes indistinguishable.
  pid="$(lsof -i :${OPENCLAW_GATEWAY_INTERNAL_PORT:-18789} -sTCP:LISTEN -t 2>/dev/null | head -1 || true)"
  if [ -n "$pid" ] && [ "$pid" != "1" ]; then
    echo "$pid"
    return 0
  fi
  return 1
}

# Resolve OpenClaw version from package.json and export
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

case "$action" in
  daemon-reload|status)
    # Always return 0: openclaw CLI calls "systemctl --user status" to check
    # if systemd is available. Non-zero = "systemctl unavailable" = all commands fail.
    exit 0 ;;
  enable)
    rm -f "$DISABLED_MARKER"; exit 0 ;;
  disable)
    touch "$DISABLED_MARKER"; exit 0 ;;
  is-enabled)
    # Tracks install/uninstall state via marker file.
    # Default (no marker) = enabled, so entrypoint-started gateway works without "openclaw gateway install".
    [ -f "$DISABLED_MARKER" ] && exit 1
    exit 0 ;;
  is-active)
    pid=$(find_gateway_pid || true)
    [ -n "$pid" ] && { echo "active"; exit 0; } || { echo "inactive"; exit 3; } ;;
  start)
    rm -f "$DISABLED_MARKER" "$STOP_MARKER"
    wait_gateway_ready; exit $? ;;
  restart)
    pid=$(find_gateway_pid || true)
    if [ -z "$pid" ]; then
      rm -f "$DISABLED_MARKER" "$STOP_MARKER"
      wait_gateway_ready; exit $?
    fi
    rm -f "$DISABLED_MARKER" "$STOP_MARKER"
    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 60); do
      if ! kill -0 "$pid" 2>/dev/null; then break; fi
      sleep 0.25
    done
    kill -KILL "$pid" 2>/dev/null || true
    sleep 0.5
    wait_gateway_ready; exit $? ;;
  stop)
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
    pid=$(find_gateway_pid || true)
    if [ -n "$pid" ]; then
      printf 'ActiveState=active\nSubState=running\nMainPID=%s\nExecMainStatus=0\nExecMainCode=exited\n' "$pid"
    else
      printf 'ActiveState=inactive\nSubState=dead\nMainPID=0\nExecMainStatus=0\nExecMainCode=exited\n'
    fi; exit 0 ;;
  *) exit 0 ;;
esac
'@ | ForEach-Object { Set-UnixContent -Path (Join-Path $InstallDir "scripts\docker\systemctl-shim.sh") -Value $_ }
}

# ── Health Check ──────────────────────────────────────────────────────────────
function Assert-GatewayRunning {
  $cid = (& docker compose -f docker-compose.yml ps -q openclaw-gateway | Select-Object -First 1)
  if ([string]::IsNullOrWhiteSpace($cid)) {
    throw "openclaw-gateway container not found after compose operation."
  }
  $running = (& docker inspect -f "{{.State.Running}}" $cid 2>$null)
  if ($LASTEXITCODE -ne 0 -or "$running".Trim() -ne "true") {
    throw "openclaw-gateway is not running (container: $cid)."
  }
  # Also verify the gateway process inside the container is alive (up to 600s)
  # First-time install on Windows + Docker Desktop is slow due to volume mount IO
  Write-Host "Waiting for gateway to be ready (up to 10 minutes on first Windows install)..." -ForegroundColor Cyan
  for ($i = 0; $i -lt 300; $i++) {
    $result = & docker exec $cid sh -c "systemctl is-active openclaw-gateway" 2>$null
    if ($LASTEXITCODE -eq 0) { return }
    if ($i -gt 0 -and ($i % 30) -eq 0) {
      Write-Host "  ...still waiting ($([int]($i*2))s elapsed)" -ForegroundColor DarkGray
    }
    Start-Sleep -Seconds 2
  }
  Write-Host "=== Last 80 lines of container log ===" -ForegroundColor Yellow
  & docker logs --tail 80 $cid
  Write-Host "=== Last 60 lines of gateway log ===" -ForegroundColor Yellow
  & docker exec $cid sh -c "tail -n 60 /tmp/openclaw-gateway.log 2>/dev/null"
  Write-Host ""
  Write-Host "Gateway not ready after 10 minutes. On Windows first install this may take longer; check status with:" -ForegroundColor Yellow
  Write-Host "  docker exec $cid systemctl is-active openclaw-gateway" -ForegroundColor Yellow
  Write-Host "  curl http://127.0.0.1:18789/ -UseBasicParsing" -ForegroundColor Yellow
  throw "Container is running but gateway process is not responding (container: $cid)."
}

function Require-InstallDir {
  if (-not (Test-Path $InstallDir)) {
    throw "Install directory not found: $InstallDir. Run '.\openclaw-kasmvnc.ps1 -Command install' first."
  }
}

# ── install ───────────────────────────────────────────────────────────────────
function Install-Command {
  Assert-Command -Name "docker"
  docker compose version 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Missing Docker Compose v2 plugin: 'docker compose'"
  }

  if ([string]::IsNullOrWhiteSpace($GatewayToken)) {
    $GatewayToken = New-RandomHex -Bytes 32
  }
  if ([string]::IsNullOrWhiteSpace($KasmPassword)) {
    $KasmPassword = New-RandomHex -Bytes 16
  }

  if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir | Out-Null
  }

  Ensure-BuildContext

  Push-Location $InstallDir
  try {
    if (-not (Test-Path ".openclaw")) {
      New-Item -ItemType Directory -Path ".openclaw" | Out-Null
    }
    if (-not (Test-Path ".openclaw\workspace")) {
      New-Item -ItemType Directory -Path ".openclaw\workspace" | Out-Null
    }

    Upsert-EnvLine -FilePath ".env" -Key "OPENCLAW_CONFIG_DIR" -Value "./.openclaw"
    Upsert-EnvLine -FilePath ".env" -Key "OPENCLAW_WORKSPACE_DIR" -Value "./.openclaw/workspace"
    Upsert-EnvLine -FilePath ".env" -Key "OPENCLAW_GATEWAY_TOKEN" -Value $GatewayToken
    Upsert-EnvLine -FilePath ".env" -Key "OPENCLAW_GATEWAY_PORT" -Value $GatewayPort
    Upsert-EnvLine -FilePath ".env" -Key "OPENCLAW_KASMVNC_PASSWORD" -Value $KasmPassword
    Upsert-EnvLine -FilePath ".env" -Key "OPENCLAW_KASMVNC_HTTPS_PORT" -Value $HttpsPort
    Upsert-EnvLine -FilePath ".env" -Key "TZ" -Value "UTC"
    Upsert-EnvLine -FilePath ".env" -Key "LANG" -Value "en_US.UTF-8"
    Upsert-EnvLine -FilePath ".env" -Key "LANGUAGE" -Value "en_US:en"
    Upsert-EnvLine -FilePath ".env" -Key "LC_ALL" -Value "en_US.UTF-8"
    if ($NoDinD) {
      Upsert-EnvLine -FilePath ".env" -Key "NO_DIND" -Value "1"
    }
    if ($Proxy -ne "") {
      Upsert-EnvLine -FilePath ".env" -Key "OPENCLAW_HTTP_PROXY" -Value $Proxy
    }

    if ($NoCache) {
      Invoke-Compose -ComposeArgs @("build", "--no-cache", "openclaw-gateway")
      Invoke-Compose -ComposeArgs @("up", "-d", "openclaw-gateway")
    } else {
      Invoke-Compose -ComposeArgs @("up", "-d", "--build", "openclaw-gateway")
    }
    Assert-GatewayRunning
  }
  finally {
    Pop-Location
  }

  Write-Host ""
  Write-Host "Install complete."
  Write-Host "Directory: $InstallDir"
  Write-Host "WebChat: http://127.0.0.1:$GatewayPort/chat?session=main"
  Write-Host "Desktop: https://127.0.0.1:$HttpsPort"
  Write-Host "OPENCLAW_GATEWAY_TOKEN=$GatewayToken"
  Write-Host "OPENCLAW_KASMVNC_PASSWORD=$KasmPassword"
}

# ── uninstall ─────────────────────────────────────────────────────────────────
function Uninstall-Command {
  if (Test-Path $InstallDir) {
    Push-Location $InstallDir
    try {
      if (Get-Command docker -ErrorAction SilentlyContinue) {
        try {
          Invoke-Compose -ComposeArgs @("down")
        }
        catch {
          Write-Host "Ignoring compose down error: $_"
        }
      }
      Write-Host "Stopped services in: $InstallDir"
    }
    finally {
      Pop-Location
    }
  }
  else {
    Write-Host "Install directory not found: $InstallDir"
  }

  if ($Purge) {
    if (Test-Path $InstallDir) {
      Remove-Item -Recurse -Force $InstallDir
      Write-Host "Removed install directory: $InstallDir"
    }
  }
  else {
    Write-Host "Uninstall completed without deleting files."
    Write-Host "Use -Purge to remove install directory."
  }
}

# ── restart ───────────────────────────────────────────────────────────────────
function Restart-Command {
  Require-InstallDir
  Push-Location $InstallDir
  try {
    Ensure-BuildContext
    Invoke-Compose -ComposeArgs @("restart", "openclaw-gateway")
    Assert-GatewayRunning
  }
  finally {
    Pop-Location
  }
}

# ── upgrade ───────────────────────────────────────────────────────────────────
function Upgrade-Command {
  Require-InstallDir
  Push-Location $InstallDir
  try {
    Ensure-BuildContext
    Invoke-Compose -ComposeArgs @("up", "-d", "openclaw-gateway")
    Invoke-Compose -ComposeArgs @(
      "exec", "-T", "openclaw-gateway",
      "sh", "-lc",
      'set -e; echo "registry=https://registry.npmjs.org" > "${HOME}/.npmrc"; rm -rf /usr/local/lib/node_modules/.openclaw-* /usr/local/bin/.openclaw-* 2>/dev/null || true; timeout 30m npm i -g openclaw@latest --no-audit --no-fund --loglevel=info || (sleep 5 && timeout 30m npm i -g openclaw@latest --no-audit --no-fund --loglevel=info) || (sleep 5 && timeout 30m npm i -g openclaw@latest --no-audit --no-fund --loglevel=info)'
    )
    Invoke-Compose -ComposeArgs @(
      "exec", "-T", "openclaw-gateway",
      "sh", "-lc",
      "set -e; openclaw gateway restart >/tmp/openclaw-upgrade-restart.log 2>&1 || openclaw gateway start; for i in `$(seq 1 30)`; do systemctl is-active openclaw-gateway >/dev/null 2>&1 && exit 0; sleep 1; done; echo 'Gateway process failed to start after upgrade' >&2; exit 1"
    )
    Assert-GatewayRunning
  }
  finally {
    Pop-Location
  }
}

# ── status ────────────────────────────────────────────────────────────────────
function Status-Command {
  Require-InstallDir
  Push-Location $InstallDir
  try {
    Invoke-Compose -ComposeArgs @("ps")
  }
  finally {
    Pop-Location
  }
}

# ── logs ──────────────────────────────────────────────────────────────────────
function Logs-Command {
  Require-InstallDir
  Push-Location $InstallDir
  try {
    Invoke-Compose -ComposeArgs @("logs", "--tail=$Tail", "openclaw-gateway")
  }
  finally {
    Pop-Location
  }
}

# ── Main entry point ──────────────────────────────────────────────────────────
switch ($Command) {
  "install" { Install-Command; break }
  "uninstall" { Uninstall-Command; break }
  "restart" { Restart-Command; break }
  "upgrade" { Upgrade-Command; break }
  "status" { Status-Command; break }
  "logs" { Logs-Command; break }
  default { throw "Unknown command: $Command" }
}
