# ============================================================================
# openclaw-kasmvnc.ps1 — OpenClaw + KasmVNC 一键部署管理脚本（Windows）
#
# 功能概述：
#   自动生成 Dockerfile、docker-compose.yml、KasmVNC 启动脚本和 systemctl shim，
#   然后通过 Docker Compose 构建并运行容器。容器内集成了 XFCE 桌面、Chromium 浏览器、
#   Fcitx5 中文输入法（雾凇拼音）以及 OpenClaw 网关服务。
#
# 支持的子命令：
#   install   — 初始化配置 + 构建镜像 + 启动容器
#   uninstall — 停止容器（可选 -Purge 删除安装目录）
#   restart   — 重启 openclaw-gateway 容器
#   upgrade   — 在运行中的容器内升级 OpenClaw npm 包并热重启网关
#   status    — 查看 Compose 服务状态
#   logs      — 查看容器日志
# ============================================================================

# ── 脚本参数定义 ──────────────────────────────────────────────────────────────
param(
  [ValidateSet("install", "uninstall", "restart", "upgrade", "status", "logs")]
  [string]$Command = "install",           # 子命令，默认 install
  [string]$InstallDir = "$HOME\openclaw-kasmvnc",  # 安装目录
  [string]$GatewayToken = "",             # 网关访问令牌（留空则自动生成）
  [string]$KasmPassword = "",             # KasmVNC 登录密码（留空则自动生成）
  [string]$HttpsPort = "8443",            # KasmVNC HTTPS 宿主机端口
  [string]$GatewayPort = "18789",         # OpenClaw 网关宿主机端口
  [int]$Tail = 200,                       # logs 命令默认显示行数
  [string]$Proxy = "",                    # 容器内 HTTP 代理地址
  [switch]$NoCache,                       # 禁用 Docker 构建缓存
  [switch]$Purge,                         # 卸载时是否删除安装目录
  [switch]$NoDinD                         # 禁用 Docker-in-Docker（不安装 Docker CE，不需要 privileged 模式）
)

# 遇到错误立即终止脚本执行
$ErrorActionPreference = "Stop"

# ── 工具函数 ─────────────────────────────────────────────────────────────────

# 检查系统命令是否存在，不存在则抛出异常
function Assert-Command {
  param([string]$Name)
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Missing command: $Name"
  }
}

# 以 Unix 换行符（LF）写入文件，避免 Windows 的 CRLF 导致容器内脚本出错
function Set-UnixContent {
  param(
    [string]$Path,
    [string]$Value
  )
  $lf = $Value -replace "`r`n", "`n"
  [System.IO.File]::WriteAllText($Path, $lf, [System.Text.UTF8Encoding]::new($false))
}

# 生成指定字节数的随机十六进制字符串（用于 token / 密码自动生成）
function New-RandomHex {
  param([int]$Bytes = 32)
  $buf = New-Object byte[] $Bytes
  [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buf)
  return ($buf | ForEach-Object { $_.ToString("x2") }) -join ""
}


# 在 .env 文件中插入或更新一行 KEY=VALUE
# 如果 key 已存在则原地替换，否则追加到文件末尾
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

# 封装 docker compose 调用，统一指定 compose 文件，失败时抛出异常
function Invoke-Compose {
  param([Parameter(Mandatory = $true)][string[]]$ComposeArgs)
  & docker compose -f docker-compose.yml @ComposeArgs
  if ($LASTEXITCODE -ne 0) {
    throw "docker compose failed: $($ComposeArgs -join ' ')"
  }
}

# ── 构建上下文生成 ────────────────────────────────────────────────────────────
# 在安装目录下生成所有 Docker 构建所需的文件：
#   - docker-compose.yml    — Compose 服务定义
#   - Dockerfile.kasmvnc    — 镜像构建指令
#   - scripts/docker/kasmvnc-startup.sh  — 容器入口脚本（启动 VNC + 桌面 + 输入法）
#   - scripts/docker/systemctl-shim.sh   — systemctl 模拟脚本（容器内无 systemd）
function Ensure-BuildContext {
  New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir "scripts\docker") | Out-Null

  # ── 生成 docker-compose.yml ──
  # 定义 openclaw-gateway 服务：构建参数、环境变量、端口映射、卷挂载等
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
'@

  # 仅在未禁用 DinD 时添加 privileged: true
  if (-not $NoDinD) {
    $composeYaml += "`n    privileged: true"
  }

  $composeYaml += @'

    init: true
    restart: unless-stopped
'@

  # 动态检测宿主机是否有 NVIDIA GPU，如果有则自动注入 GPU 支持配置
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

  # ── 生成 Dockerfile.kasmvnc ──
  # 基于 node:22-bookworm，安装 OpenClaw、KasmVNC、XFCE 桌面、Chromium、
  # Fcitx5 输入法、Docker CE（DinD 支持）等全部依赖
  # 注意：Dockerfile 内容与 .sh 版本完全一致，两个脚本需同步维护
  @'
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
 && git config --global url.\"https://github.com/\".insteadOf \"git@github.com:\" \
 && git config --global url.\"https://github.com/\".insteadOf \"ssh://git@github.com/\" \
 && git config --global url.\"https://\".insteadOf \"git://\" \
 && git config --global http.sslVerify false \
 && npm install -g openclaw@latest --no-audit --no-fund \
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

# Install Docker CE for Docker-in-Docker support using Aliyun mirror (only if NO_DIND != 1)
ARG NO_DIND=0
RUN if [ "${NO_DIND}" != "1" ]; then \
  curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://mirrors.aliyun.com/docker-ce/linux/debian bookworm stable" \
     > /etc/apt/sources.list.d/docker.list \
  && apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends --fix-missing \
     docker-ce docker-ce-cli containerd.io docker-compose-plugin \
  && rm -rf /var/lib/apt/lists/*; \
fi

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
  url="https://claw.ihasy.com/mirror/kasmvnc/${pkg}"; \
  curl -fsSL "${url}" -o "/tmp/${pkg}"; \
  apt-get update --allow-insecure-repositories || apt-get update -o Acquire::AllowInsecureRepositories=true || apt-get update; \
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends --allow-unauthenticated "/tmp/${pkg}"; \
  rm -f "/tmp/${pkg}"; \
  rm -rf /var/lib/apt/lists/*

# Install Rime Ice (雾凇拼音) dictionary and configuration
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

COPY scripts/docker/systemctl-shim.sh /usr/local/bin/systemctl
COPY scripts/docker/kasmvnc-startup.sh /usr/local/bin/kasmvnc-startup
RUN sed -i 's/\r$//' /usr/local/bin/systemctl /usr/local/bin/kasmvnc-startup \
  && chmod +x /usr/local/bin/systemctl /usr/local/bin/kasmvnc-startup \
  && usermod -a -G ssl-cert node \
  && (getent group docker >/dev/null && usermod -a -G docker node || true) \
  && echo "node ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Register Fcitx5 as the system default input method framework
RUN im-config -n fcitx5

USER node

EXPOSE 18789 18790 8443 8444

ENTRYPOINT ["kasmvnc-startup"]
CMD ["openclaw", "gateway", "--bind", "lan", "--port", "18789"]
'@ | ForEach-Object { Set-UnixContent -Path (Join-Path $InstallDir "Dockerfile.kasmvnc") -Value $_ }

  # ── 生成 kasmvnc-startup.sh（容器入口脚本）──
  # 容器启动时执行：初始化环境变量 → 启动 Docker 守护进程（DinD）→ 配置输入法 →
  # 清理残留 VNC 状态 → 覆写 KasmVNC 剪贴板配置 → 启动 VNC 服务器 + XFCE 桌面 →
  # 最后执行 CMD 传入的命令（通常是 openclaw gateway）并 sleep infinity 保持容器存活
  @'

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

# Configure Fcitx5 profile: set keyboard-us as default layout, rime as the active input method
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

openclaw config set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback true >/dev/null 2>&1 || true

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
'@ | ForEach-Object { Set-UnixContent -Path (Join-Path $InstallDir "scripts\docker\kasmvnc-startup.sh") -Value $_ }

  # ── 生成 systemctl-shim.sh（systemctl 模拟脚本）──
  # 容器内没有 systemd，但 openclaw CLI 依赖 systemctl 管理网关服务。
  # 此 shim 拦截所有 systemctl 调用，将其转换为进程管理操作：
  #   - restart → 完整的 stop + start（杀旧进程 → 启新进程，确保加载最新代码）
  #   - stop    → 发送 SIGTERM 优雅停止
  #   - start   → 通过 nohup 后台启动网关进程
  #   - status  → 始终返回 0（openclaw 用此判断 systemd 是否可用）
  #   - is-enabled → 通过 marker 文件跟踪 install/uninstall 状态
  # 进程识别使用 lsof 端口检测，因为 Node.js process.title 会覆盖整个 cmdline
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

# 从 openclaw 的 package.json 解析版本号并导出为环境变量
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
    kill -TERM "$pid" 2>/dev/null || exit $?
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

# ── 容器健康检查 ──────────────────────────────────────────────────────────────
# 验证 openclaw-gateway 容器正在运行，且容器内的网关进程已就绪
function Assert-GatewayRunning {
  $cid = (& docker compose -f docker-compose.yml ps -q openclaw-gateway | Select-Object -First 1)
  if ([string]::IsNullOrWhiteSpace($cid)) {
    throw "openclaw-gateway container not found after compose operation."
  }
  $running = (& docker inspect -f "{{.State.Running}}" $cid 2>$null)
  if ($LASTEXITCODE -ne 0 -or "$running".Trim() -ne "true") {
    throw "openclaw-gateway is not running (container: $cid)."
  }
  # Also verify the gateway process inside the container is alive
  for ($i = 0; $i -lt 60; $i++) {
    $result = & docker exec $cid sh -c "systemctl is-active openclaw-gateway" 2>$null
    if ($LASTEXITCODE -eq 0) { return }
    Start-Sleep -Seconds 2
  }
  throw "Container is running but gateway process is not responding (container: $cid)."
}

# 检查安装目录是否存在，不存在则提示用户先执行 install
function Require-InstallDir {
  if (-not (Test-Path $InstallDir)) {
    throw "Install directory not found: $InstallDir. Run '.\openclaw-kasmvnc.ps1 -Command install' first."
  }
}

# ── install 命令 ──────────────────────────────────────────────────────────────
# 完整安装流程：检查依赖 → 生成 token/密码 → 创建安装目录 → 生成构建文件 →
# 写入 .env 配置 → docker compose up --build → 验证网关就绪
function Install-Command {
  Assert-Command -Name "docker"
  try {
    docker compose version | Out-Null
  }
  catch {
    throw "Missing Docker Compose v2 plugin: 'docker compose'"
  }

  # 确保基础镜像可用：优先使用官方镜像，失败则从镜像站下载
  Write-Host "Checking base image: node:22-bookworm"
  try {
    docker image inspect node:22-bookworm 2>$null | Out-Null
    Write-Host "Base image already exists locally"
  }
  catch {
    Write-Host "Pulling node:22-bookworm from Docker Hub..."
    try {
      docker pull node:22-bookworm 2>$null | Out-Null
    }
    catch {
      Write-Host "Failed to pull from Docker Hub, downloading from mirror..."
      # 检测系统架构
      $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
      $mirrorArch = switch ($arch) {
        "X64" { "amd64" }
        "Arm64" { "arm64" }
        default { throw "Unsupported architecture: $arch" }
      }

      # 镜像源列表（按优先级尝试）
      $mirrorUrls = @(
        "https://claw.ihasy.com/mirror/node-22-bookworm-$mirrorArch.tar.gz",
        "https://github.com/ddong8/openclaw-kasmvnc/releases/download/docker-images/node-22-bookworm-$mirrorArch.tar.gz"
      )

      $tmpFile = "$env:TEMP\node-22-bookworm-$PID.tar.gz"
      $downloadSuccess = $false

      foreach ($mirrorUrl in $mirrorUrls) {
        Write-Host "Downloading $mirrorArch image from: $mirrorUrl"
        try {
          Invoke-WebRequest -Uri $mirrorUrl -OutFile $tmpFile -UseBasicParsing
          Write-Host "Loading image from mirror..."
          Get-Content $tmpFile -Raw | docker load
          Remove-Item $tmpFile -Force
          $downloadSuccess = $true
          break
        }
        catch {
          Write-Host "Failed to download, trying next mirror..."
          if (Test-Path $tmpFile) {
            Remove-Item $tmpFile -Force
          }
        }
      }

      if (-not $downloadSuccess) {
        throw "Failed to download image from all mirrors"
      }
    }
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
    Upsert-EnvLine -FilePath ".env" -Key "TZ" -Value "Asia/Shanghai"
    Upsert-EnvLine -FilePath ".env" -Key "LANG" -Value "zh_CN.UTF-8"
    Upsert-EnvLine -FilePath ".env" -Key "LANGUAGE" -Value "zh_CN:zh"
    Upsert-EnvLine -FilePath ".env" -Key "LC_ALL" -Value "zh_CN.UTF-8"
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

# ── uninstall 命令 ────────────────────────────────────────────────────────────
# 停止并移除容器；如果指定了 -Purge 则同时删除安装目录
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

# ── restart 命令 ──────────────────────────────────────────────────────────────
# 重启 openclaw-gateway 容器
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

# ── upgrade 命令 ──────────────────────────────────────────────────────────────
# 在运行中的容器内执行 npm 升级 openclaw 包，然后热重启网关进程
function Upgrade-Command {
  Require-InstallDir
  Push-Location $InstallDir
  try {
    Ensure-BuildContext
    Invoke-Compose -ComposeArgs @("up", "-d", "openclaw-gateway")
    Invoke-Compose -ComposeArgs @(
      "exec", "-T", "openclaw-gateway",
      "sh", "-lc",
      'set -e; echo "registry=https://registry.npmmirror.com" > "${HOME}/.npmrc"; rm -rf /usr/local/lib/node_modules/.openclaw-* /usr/local/bin/.openclaw-* 2>/dev/null || true; timeout 30m npm i -g openclaw@latest --no-audit --no-fund --loglevel=info || (sleep 5 && timeout 30m npm i -g openclaw@latest --no-audit --no-fund --loglevel=info) || (sleep 5 && timeout 30m npm i -g openclaw@latest --no-audit --no-fund --loglevel=info)'
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

# ── status 命令 ───────────────────────────────────────────────────────────────
# 显示 docker compose 服务状态
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

# ── logs 命令 ─────────────────────────────────────────────────────────────────
# 显示容器日志，默认最近 200 行
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

# ── 主入口：根据子命令分发到对应的函数 ────────────────────────────────────────
switch ($Command) {
  "install" { Install-Command; break }
  "uninstall" { Uninstall-Command; break }
  "restart" { Restart-Command; break }
  "upgrade" { Upgrade-Command; break }
  "status" { Status-Command; break }
  "logs" { Logs-Command; break }
  default { throw "Unknown command: $Command" }
}
