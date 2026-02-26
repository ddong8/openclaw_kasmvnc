#!/usr/bin/env bash
set -euo pipefail

COMMAND="${1:-install}"
if [[ $# -gt 0 ]]; then
  shift
fi

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
  docker compose -f docker-compose.yml "$@"
}

ensure_build_context() {
  local d="$INSTALL_DIR"
  mkdir -p "$d/scripts/docker"

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
    image: ${OPENCLAW_KASMVNC_IMAGE:-openclaw:kasmvnc}
    command:
      [
        "openclaw",
        "gateway",
        "--allow-unconfigured",
        "--bind",
        "${OPENCLAW_GATEWAY_BIND:-loopback}",
        "--port",
        "18789",
      ]
    environment:
      HOME: /home/node
      TERM: xterm-256color
      OPENCLAW_NO_RESPAWN: "1"
      OPENCLAW_GATEWAY_TOKEN: ${OPENCLAW_GATEWAY_TOKEN}
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
    volumes:
      - ${OPENCLAW_CONFIG_DIR:-./.openclaw}:/home/node/.openclaw
      - ${OPENCLAW_WORKSPACE_DIR:-./.openclaw/workspace}:/home/node/.openclaw/workspace
    ports:
      - "${OPENCLAW_GATEWAY_PORT:-18789}:18789"
      - "${OPENCLAW_GATEWAY_BRIDGE_PORT:-18790}:18790"
      - "${OPENCLAW_KASMVNC_HTTPS_PORT:-8443}:8444"
    shm_size: '2gb'
    privileged: true
    init: true
    restart: unless-stopped
EOF

  # 动态检测是否存在 nvidia-smi，如果存在则自动注入 GPU 支持配置
  if command -v nvidia-smi >/dev/null 2>&1 || [[ "${OPENCLAW_ENABLE_GPU:-0}" == "1" ]]; then
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

  cat >"$d/Dockerfile.kasmvnc" <<'EOF'
FROM node:22-bookworm

USER root

# Remove dpkg exclusions so translation files (locales) are installed for full UI localization
RUN rm -f /etc/dpkg/dpkg.cfg.d/docker && rm -f /etc/apt/apt.conf.d/docker-clean

# Configure apt to use Tsinghua mirror for faster downloads in China
RUN sed -i 's/deb.debian.org/mirrors.tuna.tsinghua.edu.cn/g' /etc/apt/sources.list.d/debian.sources 2>/dev/null || true \
 && sed -i 's/security.debian.org/mirrors.tuna.tsinghua.edu.cn/g' /etc/apt/sources.list.d/debian.sources 2>/dev/null || true \
 && sed -i 's/deb.debian.org/mirrors.tuna.tsinghua.edu.cn/g' /etc/apt/sources.list 2>/dev/null || true \
 && sed -i 's/security.debian.org/mirrors.tuna.tsinghua.edu.cn/g' /etc/apt/sources.list 2>/dev/null || true

# Install git and ssh client (required by some npm lifecycle scripts and git dependencies)
RUN apt-get update && apt-get install -y --no-install-recommends git openssh-client && rm -rf /var/lib/apt/lists/*

# Accept proxy build arguments
ARG HTTP_PROXY
ARG HTTPS_PROXY

# Install OpenClaw via npm (pre-built, includes correct version metadata)
# Configure npm registry and force git to use HTTPS, preserving optional dependencies
# Disable SSL verification for git to prevent issues with proxies
ARG OPENC_CACHE_BUST=1
RUN npm config set registry https://registry.npmmirror.com \
 && git config --global url."https://github.com/".insteadOf "git@github.com:" \
 && git config --global url."https://github.com/".insteadOf "ssh://git@github.com/" \
 && git config --global url."https://".insteadOf "git://" \
 && git config --global http.sslVerify false \
 && npm install -g openclaw@latest \
 && chown -R node:node /usr/local/lib/node_modules /usr/local/bin
ENV PATH="/opt/KasmVNC/bin:${PATH}"
ENV TZ=Asia/Shanghai
ENV LANG=zh_CN.UTF-8
ENV LANGUAGE=zh_CN:zh
ENV LC_ALL=zh_CN.UTF-8
ENV GTK_IM_MODULE=fcitx
ENV QT_IM_MODULE=fcitx
ENV XMODIFIERS=@im=fcitx

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
    fcitx5 \
    fcitx5-rime \
    fcitx5-frontend-gtk3 \
    fcitx5-frontend-qt5 \
    fcitx5-config-qt \
    im-config \
    libdatetime-perl \
    libegl1 \
    libglu1-mesa \
    libglx-mesa0 \
    locales \
    lsof \
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

# Install Docker CE for Docker-in-Docker support using Aliyun mirror
RUN curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://mirrors.aliyun.com/docker-ce/linux/debian bookworm stable" \
     > /etc/apt/sources.list.d/docker.list \
  && apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends --fix-missing \
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


# Install Rime Ice (雾凇拼音) dictionary and configuration
RUN git clone --depth 1 https://github.com/iDvel/rime-ice.git /tmp/rime-ice \
  && mkdir -p /home/node/.local/share/fcitx5/rime \
  && cp -r /tmp/rime-ice/* /home/node/.local/share/fcitx5/rime/ \
  && printf '%s\n' \
    'patch:' \
    '  "switches/@0/reset": 0' \
    > /home/node/.local/share/fcitx5/rime/default.custom.yaml \
  && chown -R node:node /home/node/.local \
  && rm -rf /tmp/rime-ice

COPY scripts/docker/systemctl-shim.sh /usr/local/bin/systemctl
COPY scripts/docker/kasmvnc-startup.sh /usr/local/bin/kasmvnc-startup
RUN sed -i 's/\r$//' /usr/local/bin/systemctl /usr/local/bin/kasmvnc-startup \
  && chmod +x /usr/local/bin/systemctl /usr/local/bin/kasmvnc-startup \
  && usermod -a -G ssl-cert,docker node \
  && echo "node ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Register Fcitx5 as the system default input method framework
RUN im-config -n fcitx5

USER node

EXPOSE 18789 18790 8443 8444

ENTRYPOINT ["kasmvnc-startup"]
CMD ["openclaw", "gateway", "--bind", "lan", "--port", "18789"]
EOF

  cat >"$d/scripts/docker/kasmvnc-startup.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

export HOME="${HOME:-/home/node}"
export USER="${USER:-node}"
export DISPLAY="${OPENCLAW_KASMVNC_DISPLAY:-:1}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/xdg-runtime}"
export GTK_IM_MODULE="${GTK_IM_MODULE:-fcitx}"
export QT_IM_MODULE="${QT_IM_MODULE:-fcitx}"
export XMODIFIERS="${XMODIFIERS:-@im=fcitx}"
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

# Ensure interactive shells call openclaw directly (no throttling alias)
sed -i '/^alias openclaw=/d' "${HOME}/.bashrc" 2>/dev/null || true

# Configure NPM registry
cat > "${HOME}/.npmrc" <<'EONPMRC'
registry=https://registry.npmmirror.com
EONPMRC

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

# Register Fcitx5 for this user's X session
cat > "${HOME}/.xinputrc" <<'EOH'
run_im fcitx5
EOH



# Autostart: force-activate fcitx5 rime AFTER XFCE desktop is fully loaded
cat > "${HOME}/.config/autostart/fcitx5-activate-rime.desktop" <<'EOH'
[Desktop Entry]
Type=Application
Name=Activate Fcitx5 Rime
Exec=bash -c "for i in {1..120}; do if pgrep -x xfdesktop >/dev/null 2>&1; then break; fi; sleep 1; done; sleep 5; fcitx5-remote -o; sleep 0.5; fcitx5-remote -s rime; fcitx5-remote -o"
Terminal=false
OnlyShowIn=XFCE;
X-GNOME-Autostart-enabled=true
EOH

# Configure Fcitx5 profile: set Rime as the default input method
mkdir -p "${HOME}/.config/fcitx5"
cat > "${HOME}/.config/fcitx5/profile" <<'EOH'
[Groups/0]
Name=Default
Default Layout=us
DefaultIM=rime

[Groups/0/Items/0]
Name=keyboard-us
Layout=

[Groups/0/Items/1]
Name=rime
Layout=

[GroupOrder]
0=Default
EOH

# Force active state behavior
cat > "${HOME}/.config/fcitx5/config" <<'EOH'
[Behavior]
ActiveByDefault=True
ShareInputState=All
PreeditEnabledByDefault=True
EOH

# Ensure Rime custom config handles ascii_mode and is owned by node
mkdir -p "${HOME}/.local/share/fcitx5/rime"
cat > "${HOME}/.local/share/fcitx5/rime/default.custom.yaml" <<'EOH'
patch:
  "switches/@0/reset": 0
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
if command -v fcitx5 >/dev/null 2>&1; then
  fcitx5 -d >/tmp/openclaw-fcitx5.log 2>&1 || true
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

# Override KasmVNC DLP clipboard config: remove "chromium/x-web-custom-data" MIME type
# so that Xvnc cmdline does not contain "chromium" (prevents pkill -f chromium from killing Xvnc)
sudo sh -c 'cat > /etc/kasmvnc/kasmvnc.yaml' <<'KASMCFG'
data_loss_prevention:
  clipboard:
    allow_mimetypes:
      - text/html
      - image/png
KASMCFG

vncserver "${DISPLAY}" -geometry "${RESOLUTION}" -depth "${DEPTH}" -xstartup "${HOME}/.vnc/xstartup" >/tmp/openclaw-kasmvnc.log 2>&1 || true

if ! pgrep -u "$(id -u)" -f "xfce4-session" >/dev/null 2>&1; then
  DISPLAY="${DISPLAY}" nohup sh "${HOME}/.vnc/xstartup" >/tmp/openclaw-xfce-autostart.log 2>&1 &
fi

if command -v xdg-settings >/dev/null 2>&1; then
  DISPLAY="${DISPLAY}" xdg-settings set default-web-browser chromium-kasm.desktop >/dev/null 2>&1 || true
fi

if [[ "$#" -gt 0 ]]; then
  "$@" &
fi

sleep infinity
EOF
  chmod +x "$d/scripts/docker/kasmvnc-startup.sh"

  cat >"$d/scripts/docker/systemctl-shim.sh" <<'SHIMEOF'
#!/usr/bin/env bash
# systemctl shim for Docker containers without systemd.
# Translates OpenClaw gateway systemctl calls into process signals.
set -euo pipefail

DISABLED_MARKER="/tmp/openclaw-gateway.disabled"

find_gateway_pid() {
  local pid
  # Find the process actually listening on the gateway port.
  # This is the only reliable method because Node.js process.title overwrites
  # the entire /proc/PID/cmdline, making server and CLI processes indistinguishable.
  pid="$(lsof -i :${OPENCLAW_GATEWAY_INTERNAL_PORT:-18789} -sTCP:LISTEN -t 2>/dev/null | head -1 || true)"
  if [[ -n "$pid" && "$pid" != "1" ]]; then
    echo "$pid"
    return 0
  fi
  return 1
}

start_gateway() {
  local pid internal_port
  internal_port="${OPENCLAW_GATEWAY_INTERNAL_PORT:-18789}"
  pid="$(find_gateway_pid || true)"
  if [[ -n "$pid" ]]; then return 0; fi
  if command -v openclaw >/dev/null 2>&1; then
    nohup openclaw gateway --allow-unconfigured --bind "${OPENCLAW_GATEWAY_BIND:-loopback}" --port "${internal_port}" >/tmp/openclaw-gateway.log 2>&1 &
  elif command -v openclaw-gateway >/dev/null 2>&1; then
    nohup openclaw-gateway --port "${internal_port}" >/tmp/openclaw-gateway.log 2>&1 &
  else
    echo "systemctl shim: cannot start gateway (openclaw CLI not found)" >&2
    return 1
  fi
  for _ in $(seq 1 60); do
    pid="$(find_gateway_pid || true)"
    [[ -n "$pid" ]] && return 0
    sleep 0.25
  done
  echo "systemctl shim: gateway failed to start" >&2
  return 1
}

args=("$@"); action=""
for a in "${args[@]}"; do
  case "$a" in
    --version) echo "systemd 252 (shim)"; exit 0 ;;
    status|restart|start|stop|is-enabled|is-active|show|daemon-reload|enable|disable) [[ -z "$action" ]] && action="$a" ;;
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
    [[ -f "$DISABLED_MARKER" ]] && exit 1
    exit 0 ;;
  is-active)
    pid=$(find_gateway_pid || true)
    [[ -n "$pid" ]] && { echo "active"; exit 0; } || { echo "inactive"; exit 3; } ;;
  start)
    rm -f "$DISABLED_MARKER"
    start_gateway; exit $? ;;
  restart)
    rm -f "$DISABLED_MARKER"
    pid=$(find_gateway_pid || true)
    if [[ -z "$pid" ]]; then
      start_gateway; exit $?
    fi
    # SIGUSR1 triggers in-place hot restart (same PID, no port drop)
    kill -USR1 "$pid" 2>/dev/null; exit $? ;;
  stop)
    pid=$(find_gateway_pid || true)
    [[ -z "$pid" ]] && exit 0
    kill -TERM "$pid" 2>/dev/null || exit $?
    for _ in $(seq 1 60); do
      if ! kill -0 "$pid" 2>/dev/null; then exit 0; fi
      sleep 0.25
    done
    kill -KILL "$pid" 2>/dev/null || true
    exit 0 ;;
  show)
    pid=$(find_gateway_pid || true)
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
  # Also verify the gateway process inside the container is alive
  local retries=0
  while [[ $retries -lt 15 ]]; do
    if docker exec "$cid" sh -c 'systemctl is-active openclaw-gateway' >/dev/null 2>&1; then
      return 0
    fi
    retries=$((retries + 1))
    sleep 2
  done
  echo "Container is running but gateway process is not responding (container: $cid)." >&2
  exit 1
}

require_install_dir() {
  if [[ ! -d "$INSTALL_DIR" ]]; then
    echo "Install directory not found: $INSTALL_DIR" >&2
    echo "Run './openclaw_kasmvnc.sh install' first." >&2
    exit 1
  fi
}

install_cmd() {
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
  ensure_build_context

  (
    cd "$INSTALL_DIR"
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
  echo "Directory: $INSTALL_DIR"
  echo "WebChat: http://127.0.0.1:${GATEWAY_PORT}/chat?session=main"
  echo "Desktop: https://127.0.0.1:${HTTPS_PORT}"
  echo "OPENCLAW_GATEWAY_TOKEN=${GATEWAY_TOKEN}"
  echo "OPENCLAW_KASMVNC_PASSWORD=${KASM_PASSWORD}"
}

uninstall_cmd() {
  if [[ -d "$INSTALL_DIR" ]]; then
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

  if [[ "$PURGE" -eq 1 ]]; then
    rm -rf "$INSTALL_DIR"
    echo "Removed install directory: $INSTALL_DIR"
  else
    echo "Uninstall completed without deleting files."
    echo "Use --purge to remove install directory."
  fi
}

restart_cmd() {
  require_install_dir
  (
    cd "$INSTALL_DIR"
    ensure_build_context
    compose_cmd restart openclaw-gateway
    assert_gateway_running
  )
}

upgrade_cmd() {
  require_install_dir
  (
    cd "$INSTALL_DIR"
    ensure_build_context
    compose_cmd up -d openclaw-gateway
    compose_cmd exec -T openclaw-gateway sh -lc '
      set -e
      echo "registry=https://registry.npmmirror.com" > "${HOME}/.npmrc"
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

status_cmd() {
  require_install_dir
  (
    cd "$INSTALL_DIR"
    compose_cmd ps
  )
}

logs_cmd() {
  require_install_dir
  (
    cd "$INSTALL_DIR"
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
