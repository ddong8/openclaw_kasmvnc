param(
  [ValidateSet("install", "uninstall", "restart", "upgrade", "status", "logs")]
  [string]$Command = "install",
  [string]$RepoUrl = "https://github.com/openclaw/openclaw.git",
  [string]$Branch = "",
  [string]$InstallDir = "$HOME\openclaw-kasmvnc",
  [string]$GatewayToken = "",
  [string]$KasmPassword = "",
  [string]$HttpsPort = "8443",
  [string]$GatewayPort = "18789",
  [int]$Tail = 200,
  [string]$Proxy = "",
  [switch]$Purge
)

$ErrorActionPreference = "Stop"

# Resolve the latest release tag from GitHub API; fall back to "main".
function Resolve-LatestTag {
  try {
    $resp = Invoke-RestMethod -Uri "https://api.github.com/repos/openclaw/openclaw/releases/latest" `
      -TimeoutSec 5 -ErrorAction Stop
    if ($resp.tag_name) { return $resp.tag_name }
  }
  catch {}
  return "main"
}

if (-not $Branch) { $Branch = Resolve-LatestTag }

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
  $lf = $Value -replace "`r`n", "`n"
  [System.IO.File]::WriteAllText($Path, $lf, [System.Text.UTF8Encoding]::new($false))
}

function New-RandomHex {
  param([int]$Bytes = 32)
  $buf = New-Object byte[] $Bytes
  [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buf)
  return ($buf | ForEach-Object { $_.ToString("x2") }) -join ""
}

function Ensure-BaseImage {
  & docker image inspect openclaw:local *> $null
  if ($LASTEXITCODE -eq 0) {
    Write-Host "Using existing base image: openclaw:local"
    return
  }
  Write-Host "Building base image: openclaw:local"
  & docker build -t openclaw:local .
  if ($LASTEXITCODE -ne 0) {
    throw "docker build failed: openclaw:local"
  }
}

function Upsert-EnvLine {
  param(
    [string]$FilePath,
    [string]$Key,
    [string]$Value
  )
  $line = "$Key=$Value"
  if (-not (Test-Path $FilePath)) {
    Set-Content -Path $FilePath -Value $line -Encoding UTF8
    return
  }
  $content = Get-Content -Path $FilePath -Raw -Encoding UTF8
  if ($content -match "(?m)^$([regex]::Escape($Key))=") {
    $updated = [regex]::Replace(
      $content,
      "(?m)^$([regex]::Escape($Key))=.*$",
      [System.Text.RegularExpressions.MatchEvaluator] { param($m) $line }
    )
    Set-Content -Path $FilePath -Value $updated -Encoding UTF8
  }
  else {
    Add-Content -Path $FilePath -Value "`r`n$line" -Encoding UTF8
  }
}

function Get-RepoDir {
  return (Join-Path $InstallDir "openclaw")
}

function Invoke-Compose {
  param([Parameter(Mandatory = $true)][string[]]$ComposeArgs)
  & docker compose -f docker-compose.yml -f docker-compose.kasmvnc.yml @ComposeArgs
  if ($LASTEXITCODE -ne 0) {
    throw "docker compose failed: $($ComposeArgs -join ' ')"
  }
}

function Ensure-KasmvncOverlay {
  $repoDir = Get-RepoDir
  New-Item -ItemType Directory -Force -Path (Join-Path $repoDir "scripts\docker") | Out-Null

  $dockerignorePath = Join-Path $repoDir ".dockerignore"
  if (-not (Test-Path $dockerignorePath)) {
    @'
.git
node_modules
.openclaw
*.log
'@ | ForEach-Object { Set-UnixContent -Path $dockerignorePath -Value $_ }
  }

  @'
services:
  openclaw-gateway:
    build:
      context: .
      dockerfile: Dockerfile.kasmvnc
      args:
        OPENCLAW_BASE_IMAGE: ${OPENCLAW_IMAGE:-openclaw:local}
        KASMVNC_VERSION: ${OPENCLAW_KASMVNC_VERSION:-1.3.0}
    image: ${OPENCLAW_KASMVNC_IMAGE:-openclaw:kasmvnc}
    command:
      [
        "node",
        "dist/index.js",
        "gateway",
        "--allow-unconfigured",
        "--bind",
        "${OPENCLAW_GATEWAY_BIND:-loopback}",
        "--port",
        "18789",
      ]
    environment:
      OPENCLAW_KASMVNC_USER: ${OPENCLAW_KASMVNC_USER:-node}
      OPENCLAW_KASMVNC_PASSWORD: ${OPENCLAW_KASMVNC_PASSWORD:-}
      OPENCLAW_KASMVNC_RESOLUTION: ${OPENCLAW_KASMVNC_RESOLUTION:-1920x1080}
      OPENCLAW_KASMVNC_DEPTH: ${OPENCLAW_KASMVNC_DEPTH:-24}
      TZ: ${TZ:-Asia/Shanghai}
      LANG: zh_CN.UTF-8
      LANGUAGE: zh_CN:zh
      LC_ALL: zh_CN.UTF-8
      HTTP_PROXY: ${OPENCLAW_HTTP_PROXY:-}
      HTTPS_PROXY: ${OPENCLAW_HTTP_PROXY:-}
      http_proxy: ${OPENCLAW_HTTP_PROXY:-}
      https_proxy: ${OPENCLAW_HTTP_PROXY:-}
      NO_PROXY: ${OPENCLAW_NO_PROXY:-localhost,127.0.0.1}
      no_proxy: ${OPENCLAW_NO_PROXY:-localhost,127.0.0.1}
      OPENCLAW_NO_RESPAWN: "1"
    ports:
      - "${OPENCLAW_KASMVNC_HTTPS_PORT:-8443}:8444"
    shm_size: '2gb'
'@ | ForEach-Object { Set-UnixContent -Path (Join-Path $repoDir "docker-compose.kasmvnc.yml") -Value $_ }

  @'
ARG OPENCLAW_BASE_IMAGE=openclaw:local
FROM ${OPENCLAW_BASE_IMAGE}

USER root
ENV PATH="/opt/KasmVNC/bin:${PATH}"
ENV TZ=Asia/Shanghai
ENV LANG=zh_CN.UTF-8
ENV LANGUAGE=zh_CN:zh
ENV LC_ALL=zh_CN.UTF-8
ENV GTK_IM_MODULE=ibus
ENV QT_IM_MODULE=ibus
ENV XMODIFIERS=@im=ibus

ARG KASMVNC_VERSION=1.3.0
ARG TARGETARCH

RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    chromium \
    curl \
    dbus-x11 \
    fonts-noto-cjk \
    gnupg \
    ibus \
    ibus-libpinyin \
    libdatetime-perl \
    libegl1 \
    libglu1-mesa \
    libglx-mesa0 \
    locales \
    tzdata \
    xfce4 \
    xfce4-terminal \
    xterm \
  && ln -snf /usr/share/zoneinfo/${TZ} /etc/localtime \
  && echo "${TZ}" > /etc/timezone \
  && sed -i 's/^# *zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' /etc/locale.gen \
  && locale-gen zh_CN.UTF-8 \
  && update-locale LANG=zh_CN.UTF-8 LC_ALL=zh_CN.UTF-8 \
  && rm -rf /var/lib/apt/lists/*

RUN printf '%s\n' \
  '#!/usr/bin/env bash' \
  'exec /usr/bin/chromium --no-sandbox --disable-gpu --disable-dev-shm-usage --disable-software-rasterizer --test-type --no-first-run --disable-background-networking --disable-sync --disable-default-apps --disable-component-update --disable-features=TranslateUI "$@"' \
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

# Default "Enable Local IME" to true in the KasmVNC web client
# KasmVNC 1.3.0 minifies index.html (no </head> or </body> tags), so we
# append the script tag at the end of the file instead of using sed.
RUN for f in /usr/share/kasmvnc/www/index.html /usr/share/kasmvnc/www/vnc.html; do \
      if [ -f "$f" ]; then \
        echo '<script>try{if(localStorage.getItem("enable_ime")===null){localStorage.setItem("enable_ime","true");}}catch(e){}</script>' >> "$f"; \
      fi; \
    done

COPY scripts/docker/systemctl-shim.sh /usr/local/bin/systemctl
COPY scripts/docker/openclaw-kasmvnc-entrypoint.sh /usr/local/bin/openclaw-kasmvnc-entrypoint
RUN sed -i 's/\r$//' /usr/local/bin/systemctl /usr/local/bin/openclaw-kasmvnc-entrypoint \
  && chmod +x /usr/local/bin/systemctl /usr/local/bin/openclaw-kasmvnc-entrypoint \
  && usermod -a -G ssl-cert node

USER node

EXPOSE 18789 18790 8443 8444

ENTRYPOINT ["openclaw-kasmvnc-entrypoint"]
CMD ["node", "dist/index.js", "gateway", "--bind", "lan", "--port", "18789"]
'@ | ForEach-Object { Set-UnixContent -Path (Join-Path $repoDir "Dockerfile.kasmvnc") -Value $_ }

  @'
#!/usr/bin/env bash
set -euo pipefail

export HOME="${HOME:-/home/node}"
export USER="${USER:-node}"
export DISPLAY="${OPENCLAW_KASMVNC_DISPLAY:-:1}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/xdg-runtime}"
export GTK_IM_MODULE="${GTK_IM_MODULE:-ibus}"
export QT_IM_MODULE="${QT_IM_MODULE:-ibus}"
export XMODIFIERS="${XMODIFIERS:-@im=ibus}"
export BROWSER="/usr/local/bin/chromium-kasm"

KASMVNC_USER="${OPENCLAW_KASMVNC_USER:-node}"
KASMVNC_PASSWORD="${OPENCLAW_KASMVNC_PASSWORD:-}"
RESOLUTION="${OPENCLAW_KASMVNC_RESOLUTION:-1920x1080}"
DEPTH="${OPENCLAW_KASMVNC_DEPTH:-24}"

mkdir -p "${HOME}/.vnc" "${XDG_RUNTIME_DIR}"
chmod 700 "${HOME}/.vnc" "${XDG_RUNTIME_DIR}"

# Make `openclaw` command available in interactive shells
if ! grep -q 'alias openclaw=' "${HOME}/.bashrc" 2>/dev/null; then
  cat >> "${HOME}/.bashrc" <<'EOALIAS'
alias openclaw='node /app/dist/index.js'
export PATH="/app/node_modules/.bin:${PATH}"
EOALIAS
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
mkdir -p "${HOME}/.config/autostart"
cat > "${HOME}/.config/autostart/ibus-daemon.desktop" <<'EOH'
[Desktop Entry]
Type=Application
Name=IBus Daemon
Exec=ibus-daemon -drx
Terminal=false
OnlyShowIn=XFCE;
X-GNOME-Autostart-enabled=true
EOH

if ! id -u "${KASMVNC_USER}" >/dev/null 2>&1; then
  KASMVNC_USER="node"
fi

cat > "${HOME}/.vnc/xstartup" <<'EOH'
#!/usr/bin/env bash
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
if command -v ibus-daemon >/dev/null 2>&1; then
  ibus-daemon -drx >/tmp/openclaw-ibus.log 2>&1 || true
fi
exec startxfce4
EOH
chmod +x "${HOME}/.vnc/xstartup"

if command -v /usr/lib/kasmvncserver/select-de.sh >/dev/null 2>&1; then
  /usr/lib/kasmvncserver/select-de.sh -y -s XFCE >/tmp/openclaw-kasmvnc-selectde.log 2>&1 || true
fi

if [[ -n "${KASMVNC_PASSWORD}" ]]; then
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

vncserver "${DISPLAY}" -geometry "${RESOLUTION}" -depth "${DEPTH}" -xstartup "${HOME}/.vnc/xstartup" >/tmp/openclaw-kasmvnc.log 2>&1 || true

if ! pgrep -u "$(id -u)" -f "xfce4-session" >/dev/null 2>&1; then
  DISPLAY="${DISPLAY}" nohup sh "${HOME}/.vnc/xstartup" >/tmp/openclaw-xfce-autostart.log 2>&1 &
fi

if command -v xdg-settings >/dev/null 2>&1; then
  DISPLAY="${DISPLAY}" xdg-settings set default-web-browser chromium-kasm.desktop >/dev/null 2>&1 || true
fi

if [[ "$#" -gt 0 ]]; then
  exec "$@"
fi

sleep infinity
'@ | ForEach-Object { Set-UnixContent -Path (Join-Path $repoDir "scripts\docker\openclaw-kasmvnc-entrypoint.sh") -Value $_ }

  @'
#!/usr/bin/env bash
# systemctl shim for Docker containers without systemd.
# Translates OpenClaw gateway systemctl calls into process signals.
set -euo pipefail
find_gateway_pid() { pgrep -f "node.*dist/index\.js" 2>/dev/null | head -1 || true; }
args=("$@"); action=""
for a in "${args[@]}"; do
  case "$a" in
    status|restart|stop|is-enabled|show|daemon-reload|enable|disable) [[ -z "$action" ]] && action="$a" ;;
  esac
done
case "$action" in
  status|daemon-reload|enable|disable) exit 0 ;;
  restart)
    pid=$(find_gateway_pid)
    [[ -z "$pid" ]] && { echo "systemctl shim: gateway process not found" >&2; exit 1; }
    kill -USR1 "$pid" 2>/dev/null; exit $? ;;
  stop)
    pid=$(find_gateway_pid)
    [[ -z "$pid" ]] && exit 0
    kill -TERM "$pid" 2>/dev/null; exit $? ;;
  is-enabled)
    pid=$(find_gateway_pid)
    [[ -n "$pid" ]] && exit 0 || exit 1 ;;
  show)
    pid=$(find_gateway_pid)
    if [[ -n "$pid" ]]; then
      printf 'ActiveState=active\nSubState=running\nMainPID=%s\nExecMainStatus=0\nExecMainCode=exited\n' "$pid"
    else
      printf 'ActiveState=inactive\nSubState=dead\nMainPID=0\nExecMainStatus=0\nExecMainCode=exited\n'
    fi; exit 0 ;;
  *) exit 0 ;;
esac
'@ | ForEach-Object { Set-UnixContent -Path (Join-Path $repoDir "scripts\docker\systemctl-shim.sh") -Value $_ }
}

function Assert-GatewayRunning {
  $cid = (& docker compose -f docker-compose.yml -f docker-compose.kasmvnc.yml ps -q openclaw-gateway | Select-Object -First 1)
  if ([string]::IsNullOrWhiteSpace($cid)) {
    throw "openclaw-gateway container not found after compose operation."
  }
  $running = (& docker inspect -f "{{.State.Running}}" $cid 2>$null)
  if ($LASTEXITCODE -ne 0 -or "$running".Trim() -ne "true") {
    throw "openclaw-gateway is not running (container: $cid)."
  }
}

function Require-Repo {
  $repoDir = Get-RepoDir
  if (-not (Test-Path $repoDir)) {
    throw "Repo not found: $repoDir"
  }
}

function Install-Command {
  Assert-Command -Name "git"
  Assert-Command -Name "docker"
  try {
    docker compose version | Out-Null
  }
  catch {
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

  $repoDir = Get-RepoDir
  if (-not (Test-Path (Join-Path $repoDir ".git"))) {
    git clone --branch $Branch --depth 1 $RepoUrl $repoDir
  }
  else {
    Write-Host "Repo exists, updating to ${Branch}: $repoDir"
    Push-Location $repoDir
    try {
      git fetch origin --tags
      git checkout $Branch 2>$null
      if ($LASTEXITCODE -ne 0) {
        git checkout "tags/$Branch" -b "release-$Branch" 2>$null
      }
      # Only pull if on a branch (tags are immutable)
      $symRef = git symbolic-ref -q HEAD 2>$null
      if ($symRef) {
        git pull --rebase origin $Branch 2>$null
      }
    }
    finally {
      Pop-Location
    }
  }

  Push-Location $repoDir
  try {
    Ensure-KasmvncOverlay
    Ensure-BaseImage
    if (-not (Test-Path ".env")) {
      Copy-Item ".env.example" ".env"
    }

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
    Upsert-EnvLine -FilePath ".env" -Key "TZ" -Value "Asia/Shanghai"
    Upsert-EnvLine -FilePath ".env" -Key "LANG" -Value "zh_CN.UTF-8"
    Upsert-EnvLine -FilePath ".env" -Key "LANGUAGE" -Value "zh_CN:zh"
    Upsert-EnvLine -FilePath ".env" -Key "LC_ALL" -Value "zh_CN.UTF-8"
    if ($Proxy -ne "") {
      Upsert-EnvLine -FilePath ".env" -Key "OPENCLAW_HTTP_PROXY" -Value $Proxy
    }

    Invoke-Compose -ComposeArgs @("up", "-d", "--build", "openclaw-gateway")
    Assert-GatewayRunning
  }
  finally {
    Pop-Location
  }

  Write-Host ""
  Write-Host "Install complete."
  Write-Host "Repo: $repoDir"
  Write-Host "WebChat: http://127.0.0.1:$GatewayPort/chat?session=main"
  Write-Host "Desktop: https://127.0.0.1:$HttpsPort"
  Write-Host "OPENCLAW_GATEWAY_TOKEN=$GatewayToken"
  Write-Host "OPENCLAW_KASMVNC_PASSWORD=$KasmPassword"
}

function Uninstall-Command {
  $repoDir = Get-RepoDir
  if (Test-Path $repoDir) {
    Push-Location $repoDir
    try {
      if (Get-Command docker -ErrorAction SilentlyContinue) {
        Invoke-Compose -ComposeArgs @("down")
      }
      Write-Host "Stopped services in: $repoDir"
    }
    finally {
      Pop-Location
    }
  }
  else {
    Write-Host "Repo directory not found: $repoDir"
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

function Restart-Command {
  Require-Repo
  Push-Location (Get-RepoDir)
  try {
    Ensure-KasmvncOverlay
    Invoke-Compose -ComposeArgs @("restart", "openclaw-gateway")
    Assert-GatewayRunning
  }
  finally {
    Pop-Location
  }
}

function Upgrade-Command {
  Require-Repo
  Push-Location (Get-RepoDir)
  try {
    git fetch origin --tags
    git checkout $Branch 2>$null
    if ($LASTEXITCODE -ne 0) {
      git checkout "tags/$Branch" -b "release-$Branch" 2>$null
    }
    $symRef = git symbolic-ref -q HEAD 2>$null
    if ($symRef) {
      git pull --rebase origin $Branch 2>$null
    }
    Ensure-KasmvncOverlay
    Ensure-BaseImage
    Invoke-Compose -ComposeArgs @("up", "-d", "--build", "openclaw-gateway")
    Assert-GatewayRunning
  }
  finally {
    Pop-Location
  }
}

function Status-Command {
  Require-Repo
  Push-Location (Get-RepoDir)
  try {
    Invoke-Compose -ComposeArgs @("ps")
  }
  finally {
    Pop-Location
  }
}

function Logs-Command {
  Require-Repo
  Push-Location (Get-RepoDir)
  try {
    Invoke-Compose -ComposeArgs @("logs", "--tail=$Tail", "openclaw-gateway")
  }
  finally {
    Pop-Location
  }
}

switch ($Command) {
  "install" { Install-Command; break }
  "uninstall" { Uninstall-Command; break }
  "restart" { Restart-Command; break }
  "upgrade" { Upgrade-Command; break }
  "status" { Status-Command; break }
  "logs" { Logs-Command; break }
  default { throw "Unknown command: $Command" }
}
