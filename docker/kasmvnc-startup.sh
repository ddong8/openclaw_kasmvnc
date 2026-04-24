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

# 修复挂载卷时 /home/node 可能归 root 所有的问题
if [ ! -w "${HOME}" ]; then
  sudo chown -R "$(id -u):$(id -g)" "${HOME}" 2>/dev/null || true
fi

# 创建 VNC 和 XDG 运行时目录
mkdir -p "${HOME}/.vnc" "${XDG_RUNTIME_DIR}" "${HOME}/.openclaw"
chmod 700 "${HOME}/.vnc" "${XDG_RUNTIME_DIR}" "${HOME}/.openclaw" 2>/dev/null || true

# 后台启动 Docker 守护进程（DinD 支持），等待 socket 就绪
# 只在 NO_DIND 不为 1 时启动
if [ "${NO_DIND:-0}" != "1" ] && command -v dockerd >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1; then
  (sudo nohup dockerd >/tmp/openclaw-dockerd.log 2>&1 &) || true
  for i in $(seq 1 30); do
    [ -S /var/run/docker.sock ] && break
    sleep 1
  done
fi

# 清理可能残留的 openclaw 别名（历史版本遗留）
sed -i '/^alias openclaw=/d' "${HOME}/.bashrc" 2>/dev/null || true

# 确保桌面图标存在（volume 挂载可能覆盖镜像中的图标）
mkdir -p "${HOME}/Desktop"
[ -f "${HOME}/Desktop/chromium.desktop" ] || cp /usr/share/applications/chromium-kasm.desktop "${HOME}/Desktop/chromium.desktop" 2>/dev/null || true
[ -f "${HOME}/Desktop/vscode.desktop" ] || cp /usr/share/applications/code.desktop "${HOME}/Desktop/vscode.desktop" 2>/dev/null || true
chmod +x "${HOME}/Desktop/chromium.desktop" "${HOME}/Desktop/vscode.desktop" 2>/dev/null || true
chmod +x "${HOME}/Desktop"/*.desktop 2>/dev/null || true

# 配置 npm 使用镜像源
if [ "${USE_CN_MIRROR:-1}" = "1" ]; then
  cat > "${HOME}/.npmrc" <<'EONPMRC'
registry=https://registry.npmmirror.com
EONPMRC
else
  cat > "${HOME}/.npmrc" <<'EONPMRC'
registry=https://registry.npmjs.org
EONPMRC
fi

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

# 清理停止标记（容器重启后应该自动启动）
rm -f /tmp/openclaw-gateway.stopped

# 配置 gateway 允许非 loopback 绑定时的 Host-header 回退（远程访问必需）
openclaw config set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback true >/dev/null 2>&1 || true
# 强制设置 gateway bind 配置（覆盖可能的 loopback 配置）
openclaw config set gateway.bind "${OPENCLAW_GATEWAY_BIND:-lan}" >/dev/null 2>&1 || true
# 启用 self-improvement hook
openclaw hooks enable self-improvement >/dev/null 2>&1 || true

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
