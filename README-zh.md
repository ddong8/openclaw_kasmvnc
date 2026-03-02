# openclaw-kasmvnc

🌐 English version: [README.md](README.md)

一键部署 OpenClaw + KasmVNC（支持 Windows / macOS / Linux）。

![OpenClaw 桌面环境](docs/screenshot-desktop.jpg)

## 核心优势

### 🔧 容器内完整生命周期管理

**解决官方 Docker 方案的核心痛点：**

官方 OpenClaw Docker 部署方案中，Gateway 运行在宿主机上，容器内无 systemd，导致：
- ❌ 无法在容器内执行 `openclaw gateway restart`
- ❌ 无法在容器内执行 `npm install -g openclaw@latest` 热更新
- ❌ 配置变更后需要手动重启容器

**本项目通过 systemctl shim 完美解决：**
- ✅ 容器内支持 `openclaw gateway restart` 重启网关
- ✅ 容器内支持 `upgrade` 命令热更新 OpenClaw（无需重建镜像）
- ✅ 完整的 `install / upgrade / restart / uninstall` 生命周期管理

### 👁️ 可视化桌面环境

**解决云厂商一键部署方案的可见性问题：**

各大云厂商提供的 OpenClaw 一键部署方案通常只有命令行界面，无法：
- ❌ 实时查看 OpenClaw 操作浏览器的过程
- ❌ 观察 Agent 执行任务的可视化反馈
- ❌ 调试桌面应用相关问题

**本项目提供完整桌面环境：**
- ✅ 浏览器直连 XFCE 桌面（KasmVNC）
- ✅ 实时观察 OpenClaw 操作 Chromium 浏览器
- ✅ 支持中文输入法（Fcitx5 + Rime Ice 雾凇拼音）
- ✅ 完整的 Linux 桌面体验

## 快速上手

Windows:
```powershell
irm https://raw.githubusercontent.com/ddong8/openclaw-kasmvnc/main/openclaw-kasmvnc-zh.ps1 | iex
```

macOS / Linux:
```bash
curl -fsSL https://raw.githubusercontent.com/ddong8/openclaw-kasmvnc/main/openclaw-kasmvnc-zh.sh | bash -s -- install
```

安装后访问：

| 服务 | 地址 | 凭证 |
|------|------|------|
| WebChat | `http://127.0.0.1:18789/chat?session=main` | `OPENCLAW_GATEWAY_TOKEN` |
| KasmVNC 桌面 | `https://127.0.0.1:8443` | 用户名 `node`，密码 `OPENCLAW_KASMVNC_PASSWORD` |

> 首次安装会自动生成并输出 Token 和密码，请妥善保存。

## 其他特性

- **环境隔离** — OpenClaw、桌面环境、依赖都在容器内，不污染主机系统
- **一键部署** — 通过脚本和 Compose 一键安装/升级/重启，换机器也可快速复现
- **跨平台一致** — Windows、macOS、Linux 使用同一套容器行为，排障路径统一
- **Docker-in-Docker** — 容器内内置 dockerd，OpenClaw 可直接创建和管理子容器
- **GPU 自动检测** — 安装时自动识别宿主机 NVIDIA GPU，有则启用 `nvidia` runtime
- **大规模部署** — 标准化容器方案使大规模部署龙虾成为可能

## 前置条件

- Docker（含 Docker Compose v2）
- Windows: PowerShell 5+ / 7+
- macOS/Linux: Bash

## 常用命令

<details>
<summary><b>Windows (PowerShell)</b></summary>

```powershell
# 安装
powershell -ExecutionPolicy Bypass -File .\openclaw-kasmvnc-zh.ps1 -Command install

# 卸载（仅停服务）
powershell -ExecutionPolicy Bypass -File .\openclaw-kasmvnc-zh.ps1 -Command uninstall

# 卸载并删除安装目录
powershell -ExecutionPolicy Bypass -File .\openclaw-kasmvnc-zh.ps1 -Command uninstall -Purge

# 重启
powershell -ExecutionPolicy Bypass -File .\openclaw-kasmvnc-zh.ps1 -Command restart

# 升级
powershell -ExecutionPolicy Bypass -File .\openclaw-kasmvnc-zh.ps1 -Command upgrade

# 状态 / 日志
powershell -ExecutionPolicy Bypass -File .\openclaw-kasmvnc-zh.ps1 -Command status
powershell -ExecutionPolicy Bypass -File .\openclaw-kasmvnc-zh.ps1 -Command logs -Tail 200
```

</details>

<details>
<summary><b>macOS / Linux (Bash)</b></summary>

```bash
chmod +x ./openclaw-kasmvnc-zh.sh

./openclaw-kasmvnc-zh.sh install              # 安装
./openclaw-kasmvnc-zh.sh uninstall            # 卸载（仅停服务）
./openclaw-kasmvnc-zh.sh uninstall --purge    # 卸载并删除安装目录
./openclaw-kasmvnc-zh.sh restart              # 重启
./openclaw-kasmvnc-zh.sh upgrade              # 升级
./openclaw-kasmvnc-zh.sh status               # 状态
./openclaw-kasmvnc-zh.sh logs --tail 200      # 日志
```

</details>

## 可选参数

| 参数 | Windows (PS1) | macOS/Linux (sh) | 默认值 |
|------|---------------|-------------------|--------|
| 安装目录 | `-InstallDir` | `--install-dir` | `$HOME/openclaw-kasmvnc` |
| 网关端口 | `-GatewayPort` | `--gateway-port` | `18789` |
| VNC HTTPS 端口 | `-HttpsPort` | `--https-port` | `8443` |
| 网关 Token | `-GatewayToken` | `--gateway-token` | 自动生成 |
| VNC 密码 | `-KasmPassword` | `--kasm-password` | 自动生成 |
| 系统代理 | `-Proxy` | `--proxy` | 无 |
| 日志行数 | `-Tail` | `--tail` | `200` |
| 禁用构建缓存 | `-NoCache` | `--no-cache` | 否 |
| 清除安装目录 | `-Purge` | `--purge` | 否 |

> 脚本默认通过 npm 获取 `latest` 版本的 OpenClaw。升级时直接运行 `upgrade` 即可。

<details>
<summary>自定义安装示例</summary>

```powershell
# Windows
powershell -ExecutionPolicy Bypass -File .\openclaw-kasmvnc-zh.ps1 `
  -Command install `
  -InstallDir "D:\openclaw-deploy" `
  -GatewayPort "18789" `
  -HttpsPort "8443"
```

```bash
# macOS/Linux
./openclaw-kasmvnc-zh.sh install \
  --install-dir "$HOME/openclaw-deploy" \
  --gateway-port 18789 \
  --https-port 8443
```

</details>

<details>
<summary>使用系统代理</summary>

安装时指定 `--proxy`，容器内所有 HTTP/HTTPS 请求都会走代理：

```bash
# Linux/macOS
./openclaw-kasmvnc-zh.sh install --proxy http://192.168.1.131:10808

# Windows
powershell -ExecutionPolicy Bypass -File .\openclaw-kasmvnc-zh.ps1 -Command install -Proxy "http://192.168.1.131:10808"
```

安装后也可编辑 `.env` 开关代理，修改后执行 `restart` 生效：
```env
OPENCLAW_HTTP_PROXY=http://192.168.1.131:10808
```

</details>

<details>
<summary>选择 KasmVNC 版本</summary>

默认使用 KasmVNC **1.3.0**，可通过环境变量切换：

```bash
# Linux/macOS
OPENCLAW_KASMVNC_VERSION=1.4.0 ./openclaw-kasmvnc-zh.sh install

# Windows
$env:OPENCLAW_KASMVNC_VERSION="1.4.0"
powershell -ExecutionPolicy Bypass -File .\openclaw-kasmvnc-zh.ps1 -Command install
```

</details>

## 项目结构

- `openclaw-kasmvnc-zh.sh` — macOS/Linux 管理脚本（中文版，含国内镜像加速）
- `openclaw-kasmvnc-zh.ps1` — Windows 管理脚本（中文版，含国内镜像加速）
- `openclaw-kasmvnc.sh` — macOS/Linux 管理脚本（国际版）
- `openclaw-kasmvnc.ps1` — Windows 管理脚本（国际版）

脚本运行后在安装目录下生成：
```
<安装目录>/
├── .env                              # 环境变量配置（token、密码、端口等）
├── .openclaw/                        # OpenClaw 持久化配置和工作区（挂载到容器内）
├── docker-compose.yml                # Compose 服务定义
├── Dockerfile.kasmvnc                # 镜像构建指令（node:22 + KasmVNC + XFCE + Fcitx5）
└── scripts/docker/
    ├── kasmvnc-startup.sh            # 容器入口脚本（启动 VNC → 桌面 → 输入法 → 网关）
    └── systemctl-shim.sh             # systemctl 模拟（将 systemd 调用转为进程信号）
```

## 内置优化

- **中文环境预配置** — `TZ=Asia/Shanghai`、`LANG=zh_CN.UTF-8`，预装中文字体（Noto CJK）和 Fcitx5 + Rime（雾凇拼音）输入法，本地输入法默认启用
- **网关无损重启** — gateway 重启期间 VNC 桌面会话保持连接不中断
- **X11 状态清理** — 入口脚本自动清理残留的 X11 锁文件和 VNC 进程，避免容器重启后黑屏
- **systemctl shim** — 容器内无 systemd，通过 shim 使 `openclaw gateway restart/stop/start` 等命令正常工作
- **剪贴板安全** — 移除 KasmVNC 默认的 `chromium/x-web-custom-data` MIME 类型，`pkill -f chromium` 不会误杀 VNC

<details>
<summary>在容器内管理 Gateway</summary>

在 VNC 桌面的终端里，可以直接使用标准的 OpenClaw 命令：

```bash
openclaw gateway restart          # 重启（加载最新代码）
openclaw gateway stop             # 停止
openclaw gateway status --probe   # 查看状态
```

> 这些命令通过内置的 systemctl shim 实现，无需真正的 systemd。

</details>

## 修改配置后如何生效

常见配置位置：`<安装目录>/openclaw/.env`、`<安装目录>/openclaw/.openclaw/openclaw.json`

1. 修改配置文件
2. 执行 `restart`
3. 用 `status` 和 `logs --tail 200` 验证

> 如果修改的是镜像配置（如 Dockerfile、系统依赖），需执行 `upgrade` 而非 `restart`。

## 已知问题

### 执行 `openclaw update` 时 VNC 短暂闪断

`npm install` 解压依赖时 CPU/IO 占用极高，可能导致 KasmVNC WebSocket 心跳超时。这是资源抢占引起的假死，完成后自动恢复。建议在宿主机资源充裕时执行 `upgrade`。

## 常见问题（FAQ）

### 1. 构建失败或需要清除缓存

如果安装过程中遇到构建错误，可以使用 `--no-cache` 参数禁用 Docker 构建缓存：

```bash
# macOS/Linux
./openclaw-kasmvnc-zh.sh install --no-cache

# Windows
powershell -ExecutionPolicy Bypass -File .\openclaw-kasmvnc-zh.ps1 -Command install -NoCache
```

### 3. 端口被占用

安装时改端口：Windows `-GatewayPort 28789 -HttpsPort 9443`，macOS/Linux `--gateway-port 28789 --https-port 9443`，然后重新 `install`。

### 4. KasmVNC 提示 HTTPS 证书不安全

默认使用容器自签名证书，属于正常现象。在浏览器选择继续访问，或自行配置反向代理（Nginx/Caddy）。

### 5. Fcitx5 默认未激活中文

旧卷配置冲突导致。处理：
1. 宿主机执行 `upgrade`
2. VNC 终端执行 `rm -rf ~/.config/fcitx5 ~/.local/share/fcitx5/rime/default.custom.yaml ~/.config/autostart/fcitx5.desktop`
3. 桌面菜单 → Log Out → 刷新页面重新进入

### 6. 进入桌面后黑屏

依次尝试：`restart` → `status` → `logs --tail 200` → `upgrade`。

### 7. 容器反复重启

常见原因：`.env` 缺参数、目录权限异常、端口冲突。重新 `install` 或更换端口。

### 8. macOS 上 `chown: Operation not permitted`

macOS M 系列部分挂载路径会出现此提示，容器运行正常则可安全忽略。

### 9. 为什么用 Chromium 而不是 Chrome？

1. **多架构兼容** — Google 未提供 ARM64 Chrome，Chromium 是唯一同时适配 x86_64 和 arm64 的方案
2. **版权合规** — Chrome 含闭源插件（DRM 等），不适合打包到公有镜像
3. **依赖纯净** — `apt install` 的 Chromium 与系统库无缝兼容，无需第三方源

### 10. 升级后中文输入法不是默认首选

旧版配置持久化导致。VNC 终端执行后断开重连：
```bash
rm -rf ~/.config/fcitx5 ~/.local/share/fcitx5/rime/default.custom.yaml ~/.config/dconf
```

### 11. 日志太多

用 `logs --tail 200` 看最近日志，`logs --tail 50` 快速定位报错。

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=ddong8/openclaw-kasmvnc&type=Date)](https://star-history.com/#ddong8/openclaw-kasmvnc&Date)

## License

[MIT](LICENSE)
