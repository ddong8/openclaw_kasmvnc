#!/usr/bin/env bash
# ============================================================================
# openclaw-kasmvnc.sh — OpenClaw + KasmVNC 一键部署管理脚本（macOS / Linux）
#
# 功能概述：
#   自动生成 Dockerfile、docker-compose.yml、KasmVNC 启动脚本和 systemctl shim，
#   然后通过 Docker Compose 构建并运行容器。容器内集成了 XFCE 桌面、Chromium 浏览器、
#   Fcitx5 中文输入法（雾凇拼音）以及 OpenClaw 网关服务。
#
# 支持的子命令：
#   install   — 初始化配置 + 构建镜像 + 启动容器
#   uninstall — 停止容器（可选 --purge 删除安装目录）
#   restart   — 重启 openclaw-gateway 容器
#   upgrade   — 在运行中的容器内升级 OpenClaw npm 包并热重启网关
#   status    — 查看 Compose 服务状态
#   logs      — 查看容器日志
# ============================================================================
set -euo pipefail

# ── 全局默认参数 ──────────────────────────────────────────────────────────────
COMMAND="${1:-install}"          # 子命令，默认 install
if [ $# -gt 0 ]; then
  shift
fi

INSTALL_DIR="${INSTALL_DIR:-$HOME/openclaw-kasmvnc}"  # 安装目录
GATEWAY_TOKEN="${GATEWAY_TOKEN:-}"                     # 网关访问令牌（留空则自动生成）
KASM_PASSWORD="${KASM_PASSWORD:-}"                      # KasmVNC 登录密码（留空则自动生成）
HTTPS_PORT="${HTTPS_PORT:-8443}"                        # KasmVNC HTTPS 宿主机端口
GATEWAY_PORT="${GATEWAY_PORT:-18789}"                   # OpenClaw 网关宿主机端口
PURGE=0                                                # 卸载时是否删除安装目录
TAIL_LINES="${TAIL_LINES:-200}"                        # logs 命令默认显示行数
HTTP_PROXY_URL="${HTTP_PROXY_URL:-}"                    # 容器内 HTTP 代理地址
NO_CACHE=0                                             # 是否禁用 Docker 构建缓存

# ── 帮助信息 ─────────────────────────────────────────────────────────────────
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

# ── 工具函数 ─────────────────────────────────────────────────────────────────

# 检查系统命令是否存在，不存在则报错退出
assert_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing command: $1" >&2
    exit 1
  fi
}


# 生成指定字节数的随机十六进制字符串（用于 token / 密码自动生成）
# 优先使用 openssl，不可用时回退到 /dev/urandom
random_hex() {
  local bytes="${1:-32}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$bytes"
  else
    od -An -N "$bytes" -tx1 /dev/urandom | tr -d ' \n'
  fi
}

# 在 .env 文件中插入或更新一行 KEY=VALUE
# 如果 key 已存在则原地替换，否则追加到文件末尾
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

# ── 命令行参数解析 ────────────────────────────────────────────────────────────
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

# 封装 docker compose 调用，统一指定 compose 文件
compose_cmd() {
  docker compose -f docker-compose.yml "$@"
}

# ── 构建上下文生成 ────────────────────────────────────────────────────────────
# 在安装目录下生成所有 Docker 构建所需的文件：
#   - docker-compose.yml    — Compose 服务定义
#   - Dockerfile.kasmvnc    — 镜像构建指令
#   - scripts/docker/kasmvnc-startup.sh  — 容器入口脚本（启动 VNC + 桌面 + 输入法）
#   - scripts/docker/systemctl-shim.sh   — systemctl 模拟脚本（容器内无 systemd）
ensure_build_context() {
  local d="$INSTALL_DIR"
  mkdir -p "$d/scripts/docker"

  # ── 生成 docker-compose.yml ──
  # 定义 openclaw-gateway 服务：构建参数、环境变量、端口映射、卷挂载等
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
EOF

  # 如果未禁用 Docker-in-Docker，则添加 privileged: true
  if [ "${NO_DIND:-0}" != "1" ]; then
    cat >>"$d/docker-compose.yml" <<'EOF'
    privileged: true
EOF
  fi

  cat >>"$d/docker-compose.yml" <<'EOF'
    init: true
    restart: unless-stopped
EOF

  # 动态检测宿主机是否有 NVIDIA GPU，如果有则自动注入 GPU 支持配置
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

  # ── 生成 Dockerfile.kasmvnc ──
  # 基于 node:22-bookworm，安装 OpenClaw、KasmVNC、XFCE 桌面、Chromium、
  # Fcitx5 输入法、Docker CE（DinD 支持）等全部依赖
  cat >"$d/Dockerfile.kasmvnc" <<'EOF'
FROM node:22-bookworm

USER root

# 移除 dpkg 排除规则，确保翻译文件（locale）被完整安装，支持中文界面
RUN rm -f /etc/dpkg/dpkg.cfg.d/docker && rm -f /etc/apt/apt.conf.d/docker-clean

# 将 apt 源替换为清华镜像，加速国内下载
RUN sed -i 's/deb.debian.org/mirrors.tuna.tsinghua.edu.cn/g' /etc/apt/sources.list.d/debian.sources 2>/dev/null || true \
 && sed -i 's/security.debian.org/mirrors.tuna.tsinghua.edu.cn/g' /etc/apt/sources.list.d/debian.sources 2>/dev/null || true \
 && sed -i 's/deb.debian.org/mirrors.tuna.tsinghua.edu.cn/g' /etc/apt/sources.list 2>/dev/null || true \
 && sed -i 's/security.debian.org/mirrors.tuna.tsinghua.edu.cn/g' /etc/apt/sources.list 2>/dev/null || true

# 安装 git 和 ssh 客户端（部分 npm 包的生命周期脚本和 git 依赖需要）
RUN apt-get update && apt-get install -y --no-install-recommends git openssh-client && rm -rf /var/lib/apt/lists/*

# 接收构建时的代理参数
ARG HTTP_PROXY
ARG HTTPS_PROXY

# 通过 npm 全局安装 OpenClaw
# 配置 npm 使用淘宝镜像源，强制 git 使用 HTTPS 协议
ARG OPENC_CACHE_BUST=1
RUN npm config set registry https://registry.npmmirror.com \
 && git config --global url."https://github.com/".insteadOf "git@github.com:" \
 && git config --global url."https://github.com/".insteadOf "ssh://git@github.com/" \
 && git config --global url."https://".insteadOf "git://" \
 && npm install -g openclaw@latest --no-audit --no-fund \
 && chown -R node:node /usr/local/lib/node_modules /usr/local/bin

# 配置时区和语言环境（可通过构建参数覆盖）
ARG TZ=Asia/Shanghai
ARG LANG=zh_CN.UTF-8
# 将 KasmVNC 加入 PATH，设置中文环境变量和输入法框架
ENV PATH="/opt/KasmVNC/bin:${PATH}"
ENV TZ=\${TZ}
ENV LANG=\${LANG}
ENV LANGUAGE=\${LANG%.*}:\${LANG%%_*}
ENV LC_ALL=\${LANG}
# Fcitx5 输入法环境变量（GTK/Qt/X11 三端都需要设置）
ENV GTK_IM_MODULE=fcitx
ENV QT_IM_MODULE=fcitx
ENV XMODIFIERS=@im=fcitx

ARG KASMVNC_VERSION=1.3.0
ARG TARGETARCH

# 安装桌面环境及所有运行时依赖：
#   - chromium: 浏览器（OpenClaw 需要）
#   - xfce4: 轻量级桌面环境
#   - fcitx5 + fcitx5-rime: 中文输入法（雾凇拼音）
#   - fonts-noto-cjk: 中日韩字体
#   - lsof: systemctl shim 用于端口检测
#   - procps: ps/pgrep 等进程工具
#   - locales: 中文 locale 生成
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
    vim \
    wget \
    xfce4 \
    xfce4-terminal \
    xterm \
  && ln -snf /usr/share/zoneinfo/${TZ} /etc/localtime \
  && echo "${TZ}" > /etc/timezone \
  && sed -i 's/^# *zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' /etc/locale.gen \
  && locale-gen zh_CN.UTF-8 \
  && update-locale LANG=zh_CN.UTF-8 LC_ALL=zh_CN.UTF-8 \
  && rm -rf /var/lib/apt/lists/*
EOF

  # 如果未禁用 Docker-in-Docker，则安装 Docker CE
  if [ "${NO_DIND:-0}" != "1" ]; then
    cat >>"$d/Dockerfile.kasmvnc" <<'EOF'

# 安装 Docker CE 实现容器内 Docker（DinD），使用阿里云镜像源
RUN curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg \
  && echo "deb [arch=${TARGETARCH} signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://mirrors.aliyun.com/docker-ce/linux/debian bookworm stable" \
     > /etc/apt/sources.list.d/docker.list \
  && apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends --fix-missing \
     docker-ce docker-ce-cli containerd.io docker-compose-plugin \
  && rm -rf /var/lib/apt/lists/*
EOF
  fi

  cat >>"$d/Dockerfile.kasmvnc" <<'EOF'

# 创建 chromium-kasm 包装脚本：以无沙箱模式启动 Chromium 并开启远程调试端口
# 同时修改桌面快捷方式指向此包装脚本，并创建自定义 .desktop 文件
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

# 安装 VS Code
RUN set -eux; \
  case "${TARGETARCH}" in \
    amd64) vscode_arch="amd64" ;; \
    arm64) vscode_arch="arm64" ;; \
    *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
  esac; \
  wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /usr/share/keyrings/packages.microsoft.gpg; \
  echo "deb [arch=${vscode_arch} signed-by=/usr/share/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
    > /etc/apt/sources.list.d/vscode.list; \
  apt-get update; \
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends --fix-missing code; \
  rm -rf /var/lib/apt/lists/*

# 创建 Chromium 和 VS Code 的桌面图标
RUN mkdir -p /home/node/Desktop \
  && cp /usr/share/applications/chromium-kasm.desktop /home/node/Desktop/chromium.desktop \
  && cp /usr/share/applications/code.desktop /home/node/Desktop/vscode.desktop \
  && chmod +x /home/node/Desktop/chromium.desktop /home/node/Desktop/vscode.desktop \
  && chown -R node:node /home/node/Desktop

# 根据目标架构（amd64/arm64）下载并安装对应版本的 KasmVNC .deb 包
RUN set -eux; \
  case "${TARGETARCH}" in \
    amd64) pkg_arch="amd64" ;; \
    arm64) pkg_arch="arm64" ;; \
    *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
  esac; \
  pkg="kasmvncserver_bookworm_${KASMVNC_VERSION}_${pkg_arch}.deb"; \
  url="https://claw.ihasy.com/mirror/kasmvnc/${pkg}"; \
  curl -fsSL "${url}" -o "/tmp/${pkg}"; \
  apt-get update --allow-insecure-repositories || apt-get update -o Acquire::AllowInsecureRepositories=true || apt-get update; \
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends --allow-unauthenticated "/tmp/${pkg}"; \
  rm -f "/tmp/${pkg}"; \
  rm -rf /var/lib/apt/lists/*


# 安装雾凇拼音（Rime Ice）词库和配置，默认中文模式（ascii_mode reset=0）
RUN curl -fsSL https://claw.ihasy.com/mirror/rime-ice/rime-ice.tar.gz -o /tmp/rime-ice.tar.gz \
  && mkdir -p /home/node/.local/share/fcitx5/rime \
  && tar xzf /tmp/rime-ice.tar.gz -C /tmp/ \
  && cp -r /tmp/rime-ice-main/* /home/node/.local/share/fcitx5/rime/ \
  && rm -rf /tmp/rime-ice.tar.gz /tmp/rime-ice-main \
  && printf '%s\n' \
    'patch:' \
    '  "switches/@0/reset": 0' \
    > /home/node/.local/share/fcitx5/rime/default.custom.yaml \
  && chown -R node:node /home/node/.local

# 复制 systemctl shim 和 KasmVNC 启动脚本到容器内
# 清理 Windows 换行符，设置可执行权限
# 将 node 用户加入 ssl-cert 组（如果启用 DinD 则也加入 docker 组），配置免密 sudo
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

# Register Fcitx5 as the system default input method framework
RUN im-config -n fcitx5

USER node

# 配置 git 使用 HTTPS 替代 SSH（支持 npm 依赖和 openclaw update）
RUN git config --global url."https://github.com/".insteadOf "git@github.com:" \
 && git config --global url."https://github.com/".insteadOf "ssh://git@github.com/" \
 && git config --global url."https://".insteadOf "git://"

EXPOSE 18789 18790 8443 8444

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD curl -f http://localhost:18789/ || exit 1

ENTRYPOINT ["/usr/local/bin/kasmvnc-startup"]
CMD ["openclaw", "gateway", "--bind", "lan", "--port", "18789"]
EOF

  # ── 生成 kasmvnc-startup.sh（容器入口脚本）──
  # 容器启动时执行：初始化环境变量 → 启动 Docker 守护进程（DinD）→ 配置输入法 →
  # 清理残留 VNC 状态 → 覆写 KasmVNC 剪贴板配置 → 启动 VNC 服务器 + XFCE 桌面 →
  # 最后执行 CMD 传入的命令（通常是 openclaw gateway）并 sleep infinity 保持容器存活
  cat >"$d/scripts/docker/kasmvnc-startup.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# ── 环境变量初始化 ──
export HOME="${HOME:-/home/node}"
export USER="${USER:-node}"
export DISPLAY="${OPENCLAW_KASMVNC_DISPLAY:-:1}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/xdg-runtime}"
# Fcitx5 输入法环境变量（GTK/Qt/X11 三端）
export GTK_IM_MODULE="${GTK_IM_MODULE:-fcitx}"
export QT_IM_MODULE="${QT_IM_MODULE:-fcitx}"
export XMODIFIERS="${XMODIFIERS:-@im=fcitx}"
export BROWSER="/usr/local/bin/chromium-kasm"

# 获取 OpenClaw 版本号用于界面显示
if [ -z "${OPENCLAW_VERSION:-}" ]; then
  OPENCLAW_VERSION=$(openclaw --version 2>/dev/null | head -n1 || echo "dev")
  export OPENCLAW_VERSION
fi

# KasmVNC 配置参数
KASMVNC_USER="${OPENCLAW_KASMVNC_USER:-node}"
KASMVNC_PASSWORD="${OPENCLAW_KASMVNC_PASSWORD:-}"
RESOLUTION="${OPENCLAW_KASMVNC_RESOLUTION:-1920x1080}"
DEPTH="${OPENCLAW_KASMVNC_DEPTH:-24}"

# 创建 VNC 和 XDG 运行时目录
mkdir -p "${HOME}/.vnc" "${XDG_RUNTIME_DIR}" "${HOME}/.openclaw"
# 确保目录属于当前用户（处理挂载卷的情况）
if [ -w "${HOME}/.openclaw" ]; then
  chmod 700 "${HOME}/.vnc" "${XDG_RUNTIME_DIR}" "${HOME}/.openclaw" 2>/dev/null || true
else
  # 如果没有写权限，尝试用 sudo 修复
  sudo chown -R "$(id -u):$(id -g)" "${HOME}/.openclaw" 2>/dev/null || true
  chmod 700 "${HOME}/.openclaw" 2>/dev/null || true
fi

# 后台启动 Docker 守护进程（DinD 支持），等待 socket 就绪
if command -v dockerd >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1; then
  (sudo nohup dockerd >/tmp/openclaw-dockerd.log 2>&1 &) || true
  for i in $(seq 1 30); do
    [ -S /var/run/docker.sock ] && break
    sleep 1
  done
fi

# 清理可能残留的 openclaw 别名（历史版本遗留）
sed -i '/^alias openclaw=/d' "${HOME}/.bashrc" 2>/dev/null || true

# 配置 npm 使用淘宝镜像源
cat > "${HOME}/.npmrc" <<'EONPMRC'
registry=https://registry.npmmirror.com
EONPMRC

# ── 配置 XFCE 默认浏览器为 chromium-kasm ──
mkdir -p "${HOME}/.config" "${HOME}/.config/xfce4"
cat > "${HOME}/.config/xfce4/helpers.rc" <<'EOH'
WebBrowser=chromium-kasm
EOH
# 配置 MIME 类型关联，使 http/https 链接默认用 chromium-kasm 打开
cat > "${HOME}/.config/mimeapps.list" <<'EOH'
[Default Applications]
x-scheme-handler/http=chromium-kasm.desktop
x-scheme-handler/https=chromium-kasm.desktop
text/html=chromium-kasm.desktop
EOH
mkdir -p "${HOME}/.config/autostart"

# 注册 Fcitx5 为当前用户的 X 会话输入法
cat > "${HOME}/.xinputrc" <<'EOH'
run_im fcitx5
EOH

# ── Fcitx5 自动激活 ──
# 创建 XFCE 自启动项：等待桌面加载完成后，强制激活 Fcitx5 并切换到 Rime 输入法
cat > "${HOME}/.config/autostart/fcitx5-activate-rime.desktop" <<'EOH'
[Desktop Entry]
Type=Application
Name=Activate Fcitx5 Rime
Exec=bash -c "for i in {1..120}; do if pgrep -x xfdesktop >/dev/null 2>&1; then break; fi; sleep 1; done; sleep 5; fcitx5-remote -o; sleep 0.5; fcitx5-remote -s rime; fcitx5-remote -o"
Terminal=false
OnlyShowIn=XFCE;
X-GNOME-Autostart-enabled=true
EOH

# 配置 Fcitx5 输入法列表：keyboard-us（英文）+ rime（中文），默认使用 rime
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

# 强制 Fcitx5 默认激活中文输入，所有窗口共享输入状态
cat > "${HOME}/.config/fcitx5/config" <<'EOH'
[Behavior]
ActiveByDefault=True
ShareInputState=All
PreeditEnabledByDefault=True
EOH

# 确保 Rime 自定义配置存在：默认中文模式（ascii_mode reset=0）
mkdir -p "${HOME}/.local/share/fcitx5/rime"
cat > "${HOME}/.local/share/fcitx5/rime/default.custom.yaml" <<'EOH'
patch:
  "switches/@0/reset": 0
EOH

# 验证 VNC 用户是否存在，不存在则回退到 node
if ! id -u "${KASMVNC_USER}" >/dev/null 2>&1; then
  KASMVNC_USER="node"
fi

# ── 生成 VNC 桌面启动脚本 xstartup ──
# 启动 D-Bus 会话总线 → 启动 Fcitx5 输入法守护进程 → 启动 XFCE4 桌面
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

# 使用 KasmVNC 的桌面环境选择器注册 XFCE
if command -v /usr/lib/kasmvncserver/select-de.sh >/dev/null 2>&1; then
  /usr/lib/kasmvncserver/select-de.sh -y -s XFCE >/tmp/openclaw-kasmvnc-selectde.log 2>&1 || true
fi

# 设置 VNC 登录密码
if [ -n "${KASMVNC_PASSWORD}" ]; then
  printf '%s\n%s\n' "${KASMVNC_PASSWORD}" "${KASMVNC_PASSWORD}" \
    | vncpasswd -u "${KASMVNC_USER}" -w -r >/dev/null || true
fi

# ── 清理残留的 VNC/X11 状态（防止容器重启后黑屏）──
if vncserver -list 2>/dev/null | grep -Eq "^[[:space:]]*${DISPLAY}[[:space:]]"; then
  vncserver -kill "${DISPLAY}" >/dev/null 2>&1 || true
fi
pkill -9 -f "Xvnc.*${DISPLAY}" 2>/dev/null || true
DISPLAY_NUM="${DISPLAY#:}"
rm -f "/tmp/.X${DISPLAY_NUM}-lock" "/tmp/.X11-unix/X${DISPLAY_NUM}"
rm -f "${HOME}/.vnc/"*"${DISPLAY}"*.pid 2>/dev/null || true

# ── 覆写 KasmVNC 剪贴板配置 ──
# 移除默认的 chromium/x-web-custom-data MIME 类型，使 Xvnc 命令行不含 "chromium"
# 这样 pkill -f chromium 不会误杀 VNC 服务进程
sudo tee /etc/kasmvnc/kasmvnc.yaml >/dev/null <<'KASMCFG' || true
data_loss_prevention:
  clipboard:
    allow_mimetypes:
      - text/html
      - image/png
KASMCFG

# ── 启动 VNC 服务器 ──
vncserver "${DISPLAY}" -geometry "${RESOLUTION}" -depth "${DEPTH}" -xstartup "${HOME}/.vnc/xstartup" >/tmp/openclaw-kasmvnc.log 2>&1 || true

# 如果 XFCE 会话未自动启动，手动拉起（兜底机制）
if ! pgrep -u "$(id -u)" -f "xfce4-session" >/dev/null 2>&1; then
  DISPLAY="${DISPLAY}" nohup sh "${HOME}/.vnc/xstartup" >/tmp/openclaw-xfce-autostart.log 2>&1 &
fi

# 设置系统默认浏览器为 chromium-kasm
if command -v xdg-settings >/dev/null 2>&1; then
  DISPLAY="${DISPLAY}" xdg-settings set default-web-browser chromium-kasm.desktop >/dev/null 2>&1 || true
fi

# ── 清理配置文件中的平台指纹（保留 auth tokens）──
if [ -f "\${HOME}/.openclaw/openclaw.json" ]; then
  if command -v jq >/dev/null 2>&1; then
    # Use jq to surgically remove only platform fields
    jq 'del(.identity.pinnedPlatform, .identity.pinnedDeviceFamily)' \
      "\${HOME}/.openclaw/openclaw.json" > "\${HOME}/.openclaw/openclaw.json.tmp" 2>/dev/null \
      && mv "\${HOME}/.openclaw/openclaw.json.tmp" "\${HOME}/.openclaw/openclaw.json" || true
  else
    # Fallback: if non-Linux platform detected, backup entire config
    if grep -q '"pinnedPlatform".*"darwin"' "\${HOME}/.openclaw/openclaw.json" 2>/dev/null || \
       grep -q '"pinnedPlatform".*"win32"' "\${HOME}/.openclaw/openclaw.json" 2>/dev/null; then
      echo "Detected non-Linux platform config, backing up..." >&2
      mv "\${HOME}/.openclaw/openclaw.json" "\${HOME}/.openclaw/openclaw.json.bak" 2>/dev/null || true
    fi
  fi
fi

# ── 确保 systemd service 文件存在（支持 install/uninstall 命令）──
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

# 配置 gateway 允许非 loopback 绑定时的 Host-header 回退（远程访问必需）
openclaw config set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback true >/dev/null 2>&1 || true
# 强制设置 gateway bind 配置（覆盖可能的 loopback 配置）
openclaw config set gateway.bind "\${OPENCLAW_GATEWAY_BIND:-lan}" >/dev/null 2>&1 || true

# 直接前台运行 supervisor 循环（不走 systemctl，避免双重后台化）
# 设置环境变量让 gateway 知道有 supervisor 管理
export OPENCLAW_SERVICE_MARKER=1
unset OPENCLAW_NO_RESPAWN 2>/dev/null || true

# Supervisor 循环：gateway 退出后自动重启（带最新版本号）
# 注意：不会因为 STOP_MARKER 而退出循环，只是暂停启动
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

  # ── 生成 systemctl-shim.sh（systemctl 模拟脚本）──
  # 容器内没有 systemd，但 openclaw CLI 依赖 systemctl 管理网关服务。
  # 此 shim 拦截所有 systemctl 调用，将其转换为进程管理操作：
  #   - restart → 完整的 stop + start（杀旧进程 → 启新进程，确保加载最新代码）
  #   - stop    → 发送 SIGTERM 优雅停止
  #   - start   → 通过 nohup 后台启动网关进程
  #   - status  → 始终返回 0（openclaw 用此判断 systemd 是否可用）
  #   - is-enabled → 通过 marker 文件跟踪 install/uninstall 状态
  # 进程识别使用 lsof 端口检测，因为 Node.js process.title 会覆盖整个 cmdline
  cat >"$d/scripts/docker/systemctl-shim.sh" <<'SHIMEOF'
#!/usr/bin/env bash
# systemctl shim — 容器内 systemd 替代方案
# 将 openclaw CLI 发出的 systemctl 调用转换为进程信号操作
set -euo pipefail

# 服务禁用标记文件（用于跟踪 install/uninstall 状态）
DISABLED_MARKER="/tmp/openclaw-gateway.disabled"
STOP_MARKER="/tmp/openclaw-gateway.stopped"

# 查找网关进程 PID
# 使用 lsof 检测监听端口的进程，这是唯一可靠的方法：
# Node.js 的 process.title 会覆盖整个 /proc/PID/cmdline，
# 导致服务进程和 CLI 进程的命令行完全相同，无法通过 pgrep 区分
find_gateway_pid() {
  pid="$(lsof -i :${OPENCLAW_GATEWAY_INTERNAL_PORT:-18789} -sTCP:LISTEN -t 2>/dev/null | head -1 || true)"
  if [ -n "$pid" ] && [ "$pid" != "1" ]; then
    echo "$pid"
    return 0
  fi
  return 1
}

# 从 openclaw 的 package.json 解析版本号并导出为环境变量
# gateway 的 resolveRuntimeServiceVersion() 会读取 OPENCLAW_VERSION 环境变量，
# 通过 initSelfPresence() 推送给前端 webchat 显示
resolve_openclaw_version() {
  local ver
  ver="$(node -p "require('/usr/local/lib/node_modules/openclaw/package.json').version" 2>/dev/null || true)"
  if [ -n "$ver" ]; then export OPENCLAW_VERSION="$ver"; fi
}

# 等待网关进程启动就绪（检查端口监听）
# kasmvnc-startup.sh 中的主 supervisor 负责实际启动，这里只等待端口就绪
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

# ── 解析命令行参数，提取 systemctl 动作 ──
args=("$@"); action=""
for a in "${args[@]}"; do
  case "$a" in
    --version) echo "systemd 252 (shim)"; exit 0 ;;  # 伪装版本号
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
    kill -TERM "$pid" 2>/dev/null || exit $?
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

# ── 容器健康检查 ──────────────────────────────────────────────────────────────
# 验证 openclaw-gateway 容器正在运行，且容器内的网关进程已就绪
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
  # Also verify the gateway process inside the container is alive
  local retries=0
  while [ $retries -lt 60 ]; do
    if docker exec "$cid" sh -c 'systemctl is-active openclaw-gateway' >/dev/null 2>&1; then
      return 0
    fi
    retries=$((retries + 1))
    sleep 2
  done
  echo "Container is running but gateway process is not responding (container: $cid)." >&2
  exit 1
}

# 检查安装目录是否存在，不存在则提示用户先执行 install
require_install_dir() {
  if [ ! -d "$INSTALL_DIR" ]; then
    echo "Install directory not found: $INSTALL_DIR" >&2
    echo "Run './openclaw-kasmvnc.sh install' first." >&2
    exit 1
  fi
}

# ── install 命令 ──────────────────────────────────────────────────────────────
# 完整安装流程：检查依赖 → 生成 token/密码 → 创建安装目录 → 生成构建文件 →
# 写入 .env 配置 → docker compose up --build → 验证网关就绪
install_cmd() {
  assert_cmd docker
  if ! docker compose version >/dev/null 2>&1; then
    echo "Missing Docker Compose v2 plugin: 'docker compose'" >&2
    exit 1
  fi

  # 确保基础镜像可用：优先使用官方镜像，失败则从镜像站下载
  echo "Checking base image: node:22-bookworm"
  if ! docker image inspect node:22-bookworm >/dev/null 2>&1; then
    echo "Pulling node:22-bookworm from Docker Hub..."
    if ! docker pull node:22-bookworm 2>/dev/null; then
      echo "Failed to pull from Docker Hub, downloading from mirror..."
      # 检测系统架构
      arch="$(uname -m)"
      case "$arch" in
        x86_64|amd64) mirror_arch="amd64" ;;
        aarch64|arm64) mirror_arch="arm64" ;;
        *) echo "Unsupported architecture: $arch" >&2; exit 1 ;;
      esac

      # 镜像源列表（按优先级尝试）
      mirror_urls=(
        "https://claw.ihasy.com/mirror/node-22-bookworm-${mirror_arch}.tar.gz"
        "https://github.com/ddong8/openclaw-kasmvnc/releases/download/docker-images/node-22-bookworm-${mirror_arch}.tar.gz"
      )

      tmp_file="/tmp/node-22-bookworm-$$.tar.gz"
      download_success=0

      for mirror_url in "${mirror_urls[@]}"; do
        echo "Downloading ${mirror_arch} image from: $mirror_url"
        if curl -fsSL "$mirror_url" -o "$tmp_file"; then
          echo "Loading image from mirror..."
          if docker load < "$tmp_file"; then
            download_success=1
            rm -f "$tmp_file"
            break
          else
            echo "Failed to load image, trying next mirror..." >&2
            rm -f "$tmp_file"
          fi
        else
          echo "Failed to download, trying next mirror..." >&2
        fi
      done

      if [ $download_success -eq 0 ]; then
        echo "Failed to download image from all mirrors" >&2
        exit 1
      fi
    fi
  else
    echo "Base image already exists locally"
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
    upsert_env_line .env TZ "Asia/Shanghai"
    upsert_env_line .env LANG "zh_CN.UTF-8"
    upsert_env_line .env LANGUAGE "zh_CN:zh"
    upsert_env_line .env LC_ALL "zh_CN.UTF-8"
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

# ── uninstall 命令 ────────────────────────────────────────────────────────────
# 停止并移除容器；如果指定了 --purge 则同时删除安装目录
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

# ── restart 命令 ──────────────────────────────────────────────────────────────
# 重启 openclaw-gateway 容器（会触发入口脚本重新执行，VNC 桌面会短暂断连）
restart_cmd() {
  require_install_dir
  (
    cd "$INSTALL_DIR"
    ensure_build_context
    compose_cmd restart openclaw-gateway
    assert_gateway_running
  )
}

# ── upgrade 命令 ──────────────────────────────────────────────────────────────
# 在运行中的容器内执行 npm 升级 openclaw 包，然后热重启网关进程。
# 不重建镜像，不中断 VNC 桌面会话。升级失败最多重试 3 次。
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

# ── status 命令 ───────────────────────────────────────────────────────────────
# 显示 docker compose 服务状态
status_cmd() {
  require_install_dir
  (
    cd "$INSTALL_DIR"
    compose_cmd ps
  )
}

# ── logs 命令 ─────────────────────────────────────────────────────────────────
# 显示容器日志，默认最近 200 行
logs_cmd() {
  require_install_dir
  (
    cd "$INSTALL_DIR"
    compose_cmd logs --tail="$TAIL_LINES" openclaw-gateway
  )
}

# ── 主入口：解析参数并分发到对应的命令函数 ────────────────────────────────────
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
