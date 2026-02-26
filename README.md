# openclaw_kasmvnc

一键部署 OpenClaw + KasmVNC（支持 Windows / macOS / Linux）。

## 3 行快速上手

Windows:
```powershell
irm https://raw.githubusercontent.com/ddong8/openclaw_kasmvnc/main/openclaw_kasmvnc.ps1 | iex
```

macOS / Linux:
```bash
curl -fsSL https://raw.githubusercontent.com/ddong8/openclaw_kasmvnc/main/openclaw_kasmvnc.sh | bash -s -- install
```

安装后访问：
- WebChat: `http://127.0.0.1:18789/chat?session=main`
- KasmVNC: `https://127.0.0.1:8443`

## 为什么用 KasmVNC + 容器化

- 浏览器直连桌面：无需本地安装 VNC 客户端，打开浏览器即可访问容器桌面。
- 环境隔离更干净：OpenClaw、桌面环境、依赖都在容器内，避免污染主机系统。
- 部署与迁移更简单：通过脚本和 Compose 一键安装/升级/重启，换机器也可快速复现。
- 跨平台一致性：Windows、macOS、Linux 使用同一套容器行为，排障路径统一。
- 安全与可控性更好：可通过端口、token、VNC 密码集中管理访问入口。

## 文件说明

- `openclaw_kasmvnc.sh`：macOS/Linux 统一管理脚本
- `openclaw_kasmvnc.ps1`：Windows 统一管理脚本

说明：脚本会自动生成 KasmVNC 所需的 `docker-compose.kasmvnc.yml`、`Dockerfile.kasmvnc` 和入口脚本，再执行容器构建与启动。
构建过程中会通过 `npm install -g openclaw@latest` 将 OpenClaw 全局安装到容器内。

两个脚本都支持以下子命令：
- `install` — 配置 + 构建/启动容器

- `uninstall` — 停止容器；加 `--purge` 删除安装目录
- `restart` — 重启 openclaw-gateway 容器
- `upgrade` — 拉取最新代码并重建/重启容器
- `status` — 查看 compose 服务状态
- `logs` — 查看 compose 日志

## 前置条件

- Git
- Docker（含 Docker Compose v2）
- Windows: PowerShell 5+ / 7+
- macOS/Linux: Bash

## 常用命令

### Windows

安装：
```powershell
powershell -ExecutionPolicy Bypass -File .\openclaw_kasmvnc.ps1 -Command install
```

卸载（仅停服务）：
```powershell
powershell -ExecutionPolicy Bypass -File .\openclaw_kasmvnc.ps1 -Command uninstall
```

卸载并删除安装目录：
```powershell
powershell -ExecutionPolicy Bypass -File .\openclaw_kasmvnc.ps1 -Command uninstall -Purge
```

重启：
```powershell
powershell -ExecutionPolicy Bypass -File .\openclaw_kasmvnc.ps1 -Command restart
```

升级：
```powershell
powershell -ExecutionPolicy Bypass -File .\openclaw_kasmvnc.ps1 -Command upgrade
```

状态：
```powershell
powershell -ExecutionPolicy Bypass -File .\openclaw_kasmvnc.ps1 -Command status
```

日志：
```powershell
powershell -ExecutionPolicy Bypass -File .\openclaw_kasmvnc.ps1 -Command logs -Tail 200
```

### macOS / Linux

```bash
chmod +x ./openclaw_kasmvnc.sh
```

安装：
```bash
./openclaw_kasmvnc.sh install
```

卸载（仅停服务）：
```bash
./openclaw_kasmvnc.sh uninstall
```

卸载并删除安装目录：
```bash
./openclaw_kasmvnc.sh uninstall --purge
```

重启：
```bash
./openclaw_kasmvnc.sh restart
```

升级（无缓存极速更新版本）：
```bash
./openclaw_kasmvnc.sh upgrade
```

状态：
```bash
./openclaw_kasmvnc.sh status
```

日志：
```bash
./openclaw_kasmvnc.sh logs --tail 200
```

## 安装后访问地址

- WebChat: `http://127.0.0.1:18789/chat?session=main`
- KasmVNC: `https://127.0.0.1:8443`

首次安装会自动生成并输出：
- `OPENCLAW_GATEWAY_TOKEN`
- `OPENCLAW_KASMVNC_PASSWORD`

默认账户说明：
- KasmVNC 用户名：`node`（默认）
- KasmVNC 密码：`OPENCLAW_KASMVNC_PASSWORD`（安装时自动生成，或你手动传入）
- WebChat Token：`OPENCLAW_GATEWAY_TOKEN`

## 修改 OpenClaw 配置后如何重启生效

常见修改位置：
- `<安装目录>/openclaw/.env`
- `<安装目录>/openclaw/.openclaw/openclaw.json`

推荐流程：
1. 修改配置文件；
2. 执行 `restart`（先用轻量重启）；
3. 用 `status` 和 `logs --tail 200` 验证是否生效。

> **注意**：配置变更时 gateway 能够自动以分离态子进程热重启，
> 且由于主入口不退出，VNC 桌面会话不会意外中断。

如果你修改的是镜像配置（例如自定义了 Dockerfile、添加了新系统依赖）、或者是需要更新 `openclaw` 的 npm 版本，仅 `restart` 不够，需要执行 `upgrade` 触发重建（仅更新 npm 层，秒级完成）。

## 可选参数

两个脚本都支持以下参数（按平台写法不同）：

| 参数 | Windows (PS1) | macOS/Linux (sh) | 默认值 |
|------|---------------|-------------------|--------|
| 安装目录 | `-InstallDir` | `--install-dir` | `$HOME/openclaw-kasmvnc` |
| 网关端口 | `-GatewayPort` | `--gateway-port` | `18789` |
| VNC HTTPS 端口 | `-HttpsPort` | `--https-port` | `8443` |
| 网关 Token | `-GatewayToken` | `--gateway-token` | 自动生成 |
| VNC 密码 | `-KasmPassword` | `--kasm-password` | 自动生成 |
| 系统代理 | `-Proxy` | `--proxy` | 无 |
| 日志行数 | `-Tail` | `--tail` | `200` |
| 清除安装目录 | `-Purge` | `--purge` | 否 |

> **说明**：脚本默认会直接通过 npm 获取 `latest` 版本的 openclaw。升级时直接运行 `upgrade` 命令即可。

示例（Windows）：
```powershell
powershell -ExecutionPolicy Bypass -File .\openclaw_kasmvnc.ps1 `
  -Command install `
  -InstallDir "D:\openclaw-deploy" `
  -GatewayPort "18789" `
  -HttpsPort "8443"
```

示例（macOS/Linux）：
```bash
./openclaw_kasmvnc.sh install \
  --install-dir "$HOME/openclaw-deploy" \
  --gateway-port 18789 \
  --https-port 8443
```


### 使用系统代理

安装时指定 `--proxy` 参数即可，容器内的 HTTP/HTTPS 请求（包括 Node.js、curl、Chromium 等）都会走代理：

```bash
# Linux/macOS
./openclaw_kasmvnc.sh install --proxy http://192.168.1.131:10808

# Windows
powershell -ExecutionPolicy Bypass -File .\openclaw_kasmvnc.ps1 -Command install -Proxy "http://192.168.1.131:10808"
```

安装后也可以手动编辑 `.env` 文件开关代理：
```env
# 启用代理（取消注释并填写地址）
OPENCLAW_HTTP_PROXY=http://192.168.1.131:10808

# 关闭代理（注释掉或删除）
# OPENCLAW_HTTP_PROXY=
```

修改 `.env` 后执行 `restart` 重启容器生效。

### 选择 KasmVNC 版本

默认使用 KasmVNC **1.3.0**。可通过环境变量切换：

```bash
# Linux/macOS
OPENCLAW_KASMVNC_VERSION=1.4.0 ./openclaw_kasmvnc.sh install

# Windows
$env:OPENCLAW_KASMVNC_VERSION="1.4.0"
powershell -ExecutionPolicy Bypass -File .\openclaw_kasmvnc.ps1 -Command install
```

## 内置优化

- **本地输入法默认启用**：首次访问 KasmVNC 桌面时，"IME Input Mode（启用本地输入法）"默认开启，无需手动设置。
- **中文环境预配置**：容器内默认设置 `TZ=Asia/Shanghai`、`LANG=zh_CN.UTF-8`，已预装中文字体和 ibus-libpinyin 输入法。
- **子进程无损重启**：配置变更时 gateway 自动通过分离的子进程（spawn detached）热拉起新版本，不重建容器主进程，VNC 桌面会话保持且能完美加载更新。
- **X11 状态清理**：入口脚本自动清理残留的 X11 锁文件和 VNC 进程，避免容器重启后黑屏。
- **systemctl shim**：容器内没有 systemd，但内置了 `systemctl` shim 脚本，使 `openclaw gateway restart/stop/start/install/uninstall/update` 等全部命令在容器内正常工作。shim 通过 `lsof` 端口检测识别网关进程，避免 Node.js `process.title` 覆盖 cmdline 导致的误判。
- **KasmVNC 剪贴板安全**：已移除 KasmVNC 默认剪贴板策略中的 `chromium/x-web-custom-data` MIME 类型，使 Xvnc 进程命令行不再包含 "chromium" 关键字，`pkill -f chromium` 不会误杀 VNC 服务。

### 在容器内管理 Gateway

在 VNC 桌面的终端里，可以直接使用标准的 OpenClaw 命令：

```bash
# 重启 gateway（进程内热重启，VNC 不中断）
openclaw gateway restart

# 停止 gateway
openclaw gateway stop

# 查看 gateway 状态
openclaw gateway status --probe
```

> 这些命令通过内置的 `systemctl` shim 实现，将 systemd 调用转换为进程信号（SIGUSR1 / SIGTERM），无需真正的 systemd。

## 避坑指南与已知问题

### 1. `pkill -f chromium` 与 VNC 断线（已修复）
**历史问题：** KasmVNC 默认的 `DLP_ClipTypes` 参数包含 `chromium/x-web-custom-data`，导致 `Xvnc` 进程命令行含有 "chromium" 关键字，`pkill -f chromium` 会误杀 VNC 服务。
**当前状态：** 已通过覆写 `/etc/kasmvnc/kasmvnc.yaml` 移除该 MIME 类型，Xvnc 命令行不再包含 "chromium"。使用最新版本安装后，`pkill -f chromium` 不会影响 VNC。如果你仍在旧版本上遇到此问题，执行 `upgrade` 重建即可。

### 2. 执行 `openclaw update` 时 VNC 出现短暂闪断
**原因：** 并非进程被误杀。`npm install` 在抽取全球或解压庞大依赖树时，瞬间会爆发极高的 CPU 和磁盘 I/O 占用。KasmVNC 强依赖服务器实时响应以维持 WebSocket 的心跳侦测，若系统底层资源被 npm 短暂榨干（如宿主机性能不足持续 3-5 秒无响应），前端浏览器便会抛出超时断连，表现为网页刷新闪断。
**解决方案：** 这是系统资源被后台安装进程暂时“抢光”引发的心跳假死，只要底层完成 I/O 自然就会恢复。我们在最新版架构中加入了双重保险：
1. **并发削峰**：自动植入 `npm config set maxsockets 3` 操作，降低并发网络连接和解压风暴。
2. **底层优先级降级**：所有经入口或终端调用的 `openclaw` 更新后台任务，均被包装在 `nice -n 19 ionice -c 3` 环境运行。强制其在操作系统 CPU 与磁盘调度队列处于最低级。此时，KasmVNC 将能永远优先获得心跳包处理资源，彻底根治此类假死断线。
如果您使用的是旧环境，建议在宿主机使用 `./openclaw_kasmvnc.sh upgrade` 拉取最新的保护机制重建即可。

## 常见问题（FAQ）

### 1. 端口被占用怎么办

现象：启动失败，或无法访问 `18789/8443`。

处理：
- 安装时改端口：
  - Windows: `-GatewayPort 28789 -HttpsPort 9443`
  - macOS/Linux: `--gateway-port 28789 --https-port 9443`
- 改完后重新执行 `install`。

### 2. 打开 KasmVNC 提示 HTTPS 证书不安全

现象：浏览器提示证书风险，无法直接进入页面。

说明：默认使用容器自签名证书，属于正常现象。

处理：
- 在浏览器里选择继续访问；
- 或者自行反向代理并配置正式证书（如 Nginx/Caddy）。

### 3. Fcitx5 (雾凇拼音) 默认未激活中文或功能异常

现象：进入桌面后默认还是英文输入，或右下角键盘图标没有变成"拼"字，在新的浏览器/终端窗口中又会切回英文，甚至时好时坏。

原因：
这通常有两个原因：
1. Linux 桌面启动时自带键盘防重置安全机制，且原本 Fcitx5 默认各窗口状态独立（ShareInputState=No）。
2. 被挂载的旧卷（`.openclaw`）中的旧版配置文件或缓存存在冲突。

处理：
OpenClaw KasmVNC 已经内置了终极侦听切换机制。如遇此问题，请强制重置并应用最新机制：
1. 在宿主机上执行 `upgrade` 使用最新脚本重建。
2. 在 VNC 桌面的终端执行以下命令清除历史残留配置和冲突项：
   ```bash
   rm -rf ~/.config/fcitx5 ~/.local/share/fcitx5/rime/default.custom.yaml ~/.config/autostart/fcitx5.desktop
   ```
3. **必须彻底注销桌面**：点击桌面左下角菜单 -> Log Out -> 再次确认 Log Out。
4. 页面刷新后重新进入，脚本将等待桌面引擎 (`xfdesktop`) 稳定，然后强制切换并启用全窗口共享（`ShareInputState=All`）的中文打字状态。

### 3. 进入桌面后黑屏

处理顺序：
1. 先重启服务：`restart`
2. 查看状态：`status`
3. 查看日志：`logs`（建议先看最近 200 行）
4. 仍有问题时执行升级重建：`upgrade`

### 4. 点击桌面浏览器图标打不开

处理：
- 先执行 `upgrade`，确保使用最新镜像与启动脚本；
- 再执行 `restart`；
- 如果仍异常，执行 `logs --tail 400` 并检查报错。

### 5. 容器反复重启

常见原因：
- `.env` 缺少关键参数；
- 本机目录权限异常（macOS 上无需 `chown`，脚本已自动处理）；
- 端口冲突。

处理：
- 重新执行 `install`（会自动补全关键配置）；
- 检查目标安装目录是否可读写；
- 更换端口后再次安装。

> 注意：正常的配置变更（如 `openclaw gateway restart`）只会通过子进程热重启后台网关，不会触发系统级容器重启，因此 VNC 不会断连。
> 如果仍出现容器反复重启，多为镜像构建或依赖问题，建议 `upgrade` 重建。

### 6. macOS 上安装出现 `chown: Operation not permitted`

处理：
> 说明：在 macOS M 系列等机器上，部分挂载路径可能会出现该提示。如果容器运行正常，该提示可安全忽略。安装脚本已经为您处理了目录权限初始化。

### 7. `pkill -f chromium` 误杀 VNC（已修复）

此问题已在最新版本中修复。详见上方「避坑指南 #1」。

如果你仍在使用旧版镜像，可通过 `upgrade` 重建来获取修复。旧版的临时规避方式是使用 `killall chromium` 或 `pkill -x chromium`。

### 8. 为什么镜像使用 Chromium 而不是 Google Chrome？

原因如下，这关乎于开源工具的健壮性：
1. **多架构兼容（最关键）**：Google 官方**并未提供 Linux ARM64 原生架构（如 M1/M2 Mac、派、AWS Graviton）的 Chrome 二进制包**。为了让该镜像能够"一处构建，到处运行"，各大开源发行版的包管理器中内置的 Chromium 是唯一完美适配 x86_64 和 arm64 的方案。
2. **版权洁癖**：Chrome 带有私有闭源版权相关的插件（DRM等），直接预配置打包到公有基础镜像不符合纯净开源的分发最佳实践。
3. **依赖纯净度**：使用自带 `apt install` 装出来的 Chromium 能最好地和所处系统的环境库无缝兼容，免去了引入额外不可控第三方源引发网络阻断的问题。

### 9. 升级部署后中文输入法依然不是默认首选？

说明：系统预设桌面环境配置持久化存储在你的 `~/.config` 目录中。如果你是从旧版本升级，那么旧的输入法优先级可能已被强行写死，不会自动刷新。
**解决方案**：
进入 KasmVNC 桌面，打开终端模拟器直接执行以下清理命令，然后断开重连：
```bash
rm -rf ~/.config/dconf && rm -f /tmp/ibus-dconf-dump
```

### 10. 日志太多不好看

建议使用：
- `logs --tail 200`：只看最近日志
- `logs --tail 50`：快速看最后报错

不要直接全量拉取日志，排障效率会很低。
