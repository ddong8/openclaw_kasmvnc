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
  *) exit 0 ;;
esac
