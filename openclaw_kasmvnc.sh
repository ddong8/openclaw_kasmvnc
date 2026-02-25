#!/usr/bin/env bash
set -euo pipefail

COMMAND="${1:-install}"
if [[ $# -gt 0 ]]; then
  shift
fi

REPO_URL="${REPO_URL:-https://github.com/openclaw/openclaw.git}"

# Resolve the latest release tag from GitHub API; fall back to "main".
resolve_latest_tag() {
  local tag
  tag=$(curl -sf --connect-timeout 5 \
    "https://api.github.com/repos/openclaw/openclaw/releases/latest" \
    | sed -n 's/.*"tag_name" *: *"\([^"]*\)".*/\1/p' | head -1) 2>/dev/null || true
  if [[ -n "$tag" ]]; then
    echo "$tag"
  else
    echo "main"
  fi
}

BRANCH="${BRANCH:-$(resolve_latest_tag)}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/openclaw-kasmvnc}"
GATEWAY_TOKEN="${GATEWAY_TOKEN:-}"
KASM_PASSWORD="${KASM_PASSWORD:-}"
HTTPS_PORT="${HTTPS_PORT:-8443}"
GATEWAY_PORT="${GATEWAY_PORT:-18789}"
PURGE=0
TAIL_LINES="${TAIL_LINES:-200}"
HTTP_PROXY_URL="${HTTP_PROXY_URL:-}"

usage() {
  cat <<'EOF'
Usage:
  ./openclaw_kasmvnc.sh <command> [options]

Commands:
  install      Clone/pull + configure + build/run container
  uninstall    Stop container; optional --purge removes install dir
  restart      Restart openclaw-gateway container
  upgrade      Pull latest repo and rebuild/restart container
  status       Show compose service status
  logs         Show compose logs (--tail <n>, default 200)

Options:
  --repo-url <url>       Git repo URL (default: https://github.com/openclaw/openclaw.git)
  --branch <name>        Git branch/tag (default: latest release, fallback: main)
  --install-dir <path>   Install directory (default: $HOME/openclaw-kasmvnc)
  --gateway-token <str>  OPENCLAW_GATEWAY_TOKEN (auto-generate on install if omitted)
  --kasm-password <str>  OPENCLAW_KASMVNC_PASSWORD (auto-generate on install if omitted)
  --https-port <port>    KasmVNC HTTPS host port (default: 8443)
  --gateway-port <port>  OpenClaw gateway host port (default: 18789)
  --proxy <url>           HTTP proxy for container (default: none, e.g. http://192.168.1.131:10808)
  --tail <n>             Log lines for logs command (default: 200)
  --purge                For uninstall: delete install dir
  -h, --help             Show this help
EOF
}

assert_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing command: $1" >&2
    exit 1
  fi
}

ensure_base_image() {
  if docker image inspect openclaw:local >/dev/null 2>&1; then
    echo "Using existing base image: openclaw:local"
    return
  fi
  echo "Building base image: openclaw:local"
  docker build -t openclaw:local .
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
  if [[ ! -f "$file" ]]; then
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

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo-url)
        REPO_URL="${2:?missing value for --repo-url}"
        shift 2
        ;;
      --branch)
        BRANCH="${2:?missing value for --branch}"
        shift 2
        ;;
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

compose_cmd() {
  docker compose -f docker-compose.yml -f docker-compose.kasmvnc.yml "$@"
}

ensure_kasmvnc_overlay() {
  local d
  d="$(repo_dir)"
  mkdir -p "$d/scripts/docker"

  if [[ ! -f "$d/.dockerignore" ]]; then
    cat >"$d/.dockerignore" <<'EOF'
.git
node_modules
.openclaw
*.log
EOF
  fi

  cat >"$d/docker-compose.kasmvnc.yml" <<'EOF'
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
    privileged: true
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
EOF

  cat >"$d/Dockerfile.kasmvnc" <<'EOF'
ARG OPENCLAW_BASE_IMAGE=openclaw:local
FROM ${OPENCLAW_BASE_IMAGE}

USER root
RUN rm -rf /app/.git
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
    dconf-cli \
    fonts-noto-cjk \
    gnupg \
    ibus \
    ibus-libpinyin \
    libdatetime-perl \
    libegl1 \
    libglu1-mesa \
    libglx-mesa0 \
    locales \
    procps \
    sudo \
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

# Install Docker CE for Docker-in-Docker support
RUN curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian bookworm stable" \
     > /etc/apt/sources.list.d/docker.list \
  && apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
     docker-ce docker-ce-cli containerd.io docker-compose-plugin \
  && rm -rf /var/lib/apt/lists/*

RUN printf '%s\n' \
  '#!/usr/bin/env bash' \
  'exec /usr/bin/chromium --no-sandbox --disable-gpu --disable-dev-shm-usage --disable-software-rasterizer --test-type --no-first-run --disable-background-networking --disable-sync --disable-default-apps --disable-component-update --disable-features=TranslateUI --remote-debugging-port=9222 --remote-debugging-address=127.0.0.1 "$@"' \
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


COPY scripts/docker/systemctl-shim.sh /usr/local/bin/systemctl
COPY scripts/docker/openclaw-kasmvnc-entrypoint.sh /usr/local/bin/openclaw-kasmvnc-entrypoint
RUN sed -i 's/\r$//' /usr/local/bin/systemctl /usr/local/bin/openclaw-kasmvnc-entrypoint \
  && chmod +x /usr/local/bin/systemctl /usr/local/bin/openclaw-kasmvnc-entrypoint \
  && usermod -a -G ssl-cert,docker node \
  && echo "node ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

USER node

EXPOSE 18789 18790 8443 8444

ENTRYPOINT ["openclaw-kasmvnc-entrypoint"]
CMD ["node", "dist/index.js", "gateway", "--bind", "lan", "--port", "18789"]
EOF

  cat >"$d/scripts/docker/openclaw-kasmvnc-entrypoint.sh" <<'EOF'
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

# Resolve OpenClaw version from package.json for UI display
if [ -z "${OPENCLAW_VERSION:-}" ]; then
  OPENCLAW_VERSION=$(node -p "try{require('/app/package.json').version}catch(e){'dev'}" 2>/dev/null || echo "dev")
  export OPENCLAW_VERSION
fi

KASMVNC_USER="${OPENCLAW_KASMVNC_USER:-node}"
KASMVNC_PASSWORD="${OPENCLAW_KASMVNC_PASSWORD:-}"
RESOLUTION="${OPENCLAW_KASMVNC_RESOLUTION:-1920x1080}"
DEPTH="${OPENCLAW_KASMVNC_DEPTH:-24}"

mkdir -p "${HOME}/.vnc" "${XDG_RUNTIME_DIR}"
chmod 700 "${HOME}/.vnc" "${XDG_RUNTIME_DIR}"

# Start Docker daemon in background for DinD support
if command -v dockerd >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1; then
  sudo nohup dockerd >/tmp/openclaw-dockerd.log 2>&1 &
  for i in $(seq 1 10); do
    [ -S /var/run/docker.sock ] && break
    sleep 1
  done
fi

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

# Pre-configure IBus to use libpinyin as default input engine.
mkdir -p "${HOME}/.config/dconf"
cat > /tmp/ibus-dconf-dump <<'EODCONF'
[desktop/ibus/general]
preload-engines=['xkb:us::eng','libpinyin']
use-system-keyboard-layout=false

[desktop/ibus/general/hotkey]
triggers=['<Control>space']
EODCONF
if command -v dconf >/dev/null 2>&1; then
  dconf load / < /tmp/ibus-dconf-dump 2>/dev/null || true
fi

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
if command -v dconf >/dev/null 2>&1 && [ -f /tmp/ibus-dconf-dump ]; then
  dconf load / < /tmp/ibus-dconf-dump 2>/dev/null || true
fi
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
EOF
  chmod +x "$d/scripts/docker/openclaw-kasmvnc-entrypoint.sh"

  cat >"$d/scripts/docker/systemctl-shim.sh" <<'SHIMEOF'
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
SHIMEOF
  chmod +x "$d/scripts/docker/systemctl-shim.sh"
}

assert_gateway_running() {
  local cid
  cid="$(compose_cmd ps -q openclaw-gateway | head -n 1)"
  if [[ -z "$cid" ]]; then
    echo "openclaw-gateway container not found after compose operation." >&2
    exit 1
  fi
  if [[ "$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null || echo false)" != "true" ]]; then
    echo "openclaw-gateway is not running (container: $cid)." >&2
    exit 1
  fi
}

repo_dir() {
  echo "$INSTALL_DIR/openclaw"
}

require_repo() {
  local d
  d="$(repo_dir)"
  if [[ ! -d "$d/.git" ]]; then
    echo "Repo not found: $d" >&2
    exit 1
  fi
}

install_cmd() {
  assert_cmd git
  assert_cmd docker
  if ! docker compose version >/dev/null 2>&1; then
    echo "Missing Docker Compose v2 plugin: 'docker compose'" >&2
    exit 1
  fi

  if [[ -z "$GATEWAY_TOKEN" ]]; then
    GATEWAY_TOKEN="$(random_hex 32)"
  fi
  if [[ -z "$KASM_PASSWORD" ]]; then
    KASM_PASSWORD="$(random_hex 16)"
  fi

  mkdir -p "$INSTALL_DIR"
  local d
  d="$(repo_dir)"
  if [[ ! -d "$d/.git" ]]; then
    git clone --branch "$BRANCH" --depth 1 "$REPO_URL" "$d"
  else
    echo "Repo exists, updating to $BRANCH: $d"
    (
      cd "$d"
      git fetch origin --tags
      git checkout "$BRANCH" 2>/dev/null || git checkout "tags/$BRANCH" -b "release-$BRANCH" 2>/dev/null || true
      # Only pull if on a branch (tags are immutable)
      if git symbolic-ref -q HEAD >/dev/null 2>&1; then
        git pull --rebase origin "$BRANCH" 2>/dev/null || true
      fi
    )
  fi

  (
    cd "$d"
    ensure_kasmvnc_overlay
    ensure_base_image
    if [[ ! -f .env ]]; then
      cp .env.example .env
    fi
    mkdir -p .openclaw .openclaw/workspace
    if [[ "$(uname -s)" == "Linux" ]]; then
      chown -R 1000:1000 .openclaw 2>/dev/null || true
    fi
    upsert_env_line .env OPENCLAW_CONFIG_DIR "./.openclaw"
    upsert_env_line .env OPENCLAW_WORKSPACE_DIR "./.openclaw/workspace"
    upsert_env_line .env OPENCLAW_GATEWAY_TOKEN "$GATEWAY_TOKEN"
    upsert_env_line .env OPENCLAW_GATEWAY_PORT "$GATEWAY_PORT"
    upsert_env_line .env OPENCLAW_KASMVNC_PASSWORD "$KASM_PASSWORD"
    upsert_env_line .env OPENCLAW_KASMVNC_HTTPS_PORT "$HTTPS_PORT"
    upsert_env_line .env TZ "Asia/Shanghai"
    upsert_env_line .env LANG "zh_CN.UTF-8"
    upsert_env_line .env LANGUAGE "zh_CN:zh"
    upsert_env_line .env LC_ALL "zh_CN.UTF-8"
    if [[ -n "$HTTP_PROXY_URL" ]]; then
      upsert_env_line .env OPENCLAW_HTTP_PROXY "$HTTP_PROXY_URL"
    fi
    compose_cmd up -d --build openclaw-gateway
    assert_gateway_running
  )

  echo
  echo "Install complete."
  echo "Repo: $d"
  echo "WebChat: http://127.0.0.1:${GATEWAY_PORT}/chat?session=main"
  echo "Desktop: https://127.0.0.1:${HTTPS_PORT}"
  echo "OPENCLAW_GATEWAY_TOKEN=${GATEWAY_TOKEN}"
  echo "OPENCLAW_KASMVNC_PASSWORD=${KASM_PASSWORD}"
}

uninstall_cmd() {
  local d
  d="$(repo_dir)"
  if [[ -d "$d" ]]; then
    (
      cd "$d"
      if command -v docker >/dev/null 2>&1; then
        compose_cmd down || true
      fi
    )
    echo "Stopped services in: $d"
  else
    echo "Repo directory not found: $d"
  fi

  if [[ "$PURGE" -eq 1 ]]; then
    rm -rf "$INSTALL_DIR"
    echo "Removed install directory: $INSTALL_DIR"
  else
    echo "Uninstall completed without deleting files."
    echo "Use --purge to remove install directory."
  fi
}

restart_cmd() {
  require_repo
  (
    cd "$(repo_dir)"
    ensure_kasmvnc_overlay
    compose_cmd restart openclaw-gateway
    assert_gateway_running
  )
}

upgrade_cmd() {
  require_repo
  (
    cd "$(repo_dir)"
    git fetch origin --tags
    git checkout "$BRANCH" 2>/dev/null || git checkout "tags/$BRANCH" -b "release-$BRANCH" 2>/dev/null || true
    if git symbolic-ref -q HEAD >/dev/null 2>&1; then
      git pull --rebase origin "$BRANCH" 2>/dev/null || true
    fi
    ensure_kasmvnc_overlay
    ensure_base_image
    compose_cmd up -d --build openclaw-gateway
    assert_gateway_running
  )
}

status_cmd() {
  require_repo
  (
    cd "$(repo_dir)"
    compose_cmd ps
  )
}

logs_cmd() {
  require_repo
  (
    cd "$(repo_dir)"
    compose_cmd logs --tail="$TAIL_LINES" openclaw-gateway
  )
}

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
