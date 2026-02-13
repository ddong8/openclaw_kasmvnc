#!/usr/bin/env bash
set -euo pipefail

COMMAND="${1:-install}"
if [[ $# -gt 0 ]]; then
  shift
fi

REPO_URL="${REPO_URL:-https://github.com/openclaw/openclaw.git}"
BRANCH="${BRANCH:-main}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/openclaw-kasmvnc}"
GATEWAY_TOKEN="${GATEWAY_TOKEN:-}"
KASM_PASSWORD="${KASM_PASSWORD:-}"
HTTPS_PORT="${HTTPS_PORT:-8443}"
GATEWAY_PORT="${GATEWAY_PORT:-18789}"
PURGE=0
TAIL_LINES="${TAIL_LINES:-200}"

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
  --branch <name>        Git branch (default: main)
  --install-dir <path>   Install directory (default: $HOME/openclaw-kasmvnc)
  --gateway-token <str>  OPENCLAW_GATEWAY_TOKEN (auto-generate on install if omitted)
  --kasm-password <str>  OPENCLAW_KASMVNC_PASSWORD (auto-generate on install if omitted)
  --https-port <port>    KasmVNC HTTPS host port (default: 8443)
  --gateway-port <port>  OpenClaw gateway host port (default: 18789)
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
        KASMVNC_VERSION: ${OPENCLAW_KASMVNC_VERSION:-1.4.0}
    image: ${OPENCLAW_KASMVNC_IMAGE:-openclaw:kasmvnc}
    command:
      [
        "node",
        "dist/index.js",
        "gateway",
        "--allow-unconfigured",
        "--bind",
        "${OPENCLAW_GATEWAY_BIND:-lan}",
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
    ports:
      - "${OPENCLAW_KASMVNC_HTTPS_PORT:-8443}:8444"
EOF

  cat >"$d/Dockerfile.kasmvnc" <<'EOF'
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

ARG KASMVNC_VERSION=1.4.0
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
  'exec /usr/bin/chromium --no-sandbox --disable-gpu "$@"' \
  > /usr/local/bin/chromium-kasm \
  && chmod +x /usr/local/bin/chromium-kasm \
  && sed -i 's|^Exec=/usr/bin/chromium %U|Exec=/usr/local/bin/chromium-kasm %U|' /usr/share/applications/chromium.desktop \
  && sed -i 's|^Exec=exo-open --launch WebBrowser %u|Exec=/usr/local/bin/chromium-kasm %u|' /usr/share/applications/xfce4-web-browser.desktop

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

COPY scripts/docker/openclaw-kasmvnc-entrypoint.sh /usr/local/bin/openclaw-kasmvnc-entrypoint
RUN chmod +x /usr/local/bin/openclaw-kasmvnc-entrypoint \
  && usermod -a -G ssl-cert node

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

KASMVNC_USER="${OPENCLAW_KASMVNC_USER:-node}"
KASMVNC_PASSWORD="${OPENCLAW_KASMVNC_PASSWORD:-}"
RESOLUTION="${OPENCLAW_KASMVNC_RESOLUTION:-1920x1080}"
DEPTH="${OPENCLAW_KASMVNC_DEPTH:-24}"

mkdir -p "${HOME}/.vnc" "${XDG_RUNTIME_DIR}"
chmod 700 "${HOME}/.vnc" "${XDG_RUNTIME_DIR}"

mkdir -p "${HOME}/.config" "${HOME}/.config/xfce4"
cat > "${HOME}/.config/xfce4/helpers.rc" <<'EOH'
[Default Applications]
WebBrowser=chromium.desktop
EOH
cat > "${HOME}/.config/mimeapps.list" <<'EOH'
[Default Applications]
x-scheme-handler/http=chromium.desktop
x-scheme-handler/https=chromium.desktop
text/html=chromium.desktop
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

if vncserver -list 2>/dev/null | grep -Eq "^[[:space:]]*${DISPLAY}[[:space:]]"; then
  vncserver -kill "${DISPLAY}" >/dev/null 2>&1 || true
fi

vncserver "${DISPLAY}" -geometry "${RESOLUTION}" -depth "${DEPTH}" -xstartup "${HOME}/.vnc/xstartup" >/tmp/openclaw-kasmvnc.log 2>&1 || true

if ! pgrep -u "$(id -u)" -f "xfce4-session" >/dev/null 2>&1; then
  DISPLAY="${DISPLAY}" nohup sh "${HOME}/.vnc/xstartup" >/tmp/openclaw-xfce-autostart.log 2>&1 &
fi

if command -v xdg-settings >/dev/null 2>&1; then
  DISPLAY="${DISPLAY}" xdg-settings set default-web-browser chromium.desktop >/dev/null 2>&1 || true
fi

if [[ "$#" -gt 0 ]]; then
  exec "$@"
fi

sleep infinity
EOF
  chmod +x "$d/scripts/docker/openclaw-kasmvnc-entrypoint.sh"
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
    echo "Repo exists, pulling latest: $d"
    (
      cd "$d"
      git fetch origin "$BRANCH"
      git checkout "$BRANCH"
      git pull --rebase origin "$BRANCH"
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
    git fetch origin "$BRANCH"
    git checkout "$BRANCH"
    git pull --rebase origin "$BRANCH"
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
