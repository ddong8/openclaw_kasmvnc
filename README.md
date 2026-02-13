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

说明：脚本会自动拉取官方 `openclaw` 源码，并自动写入 KasmVNC 所需的
`docker-compose.kasmvnc.yml`、`Dockerfile.kasmvnc` 和入口脚本，再执行容器构建与启动。

两个脚本都支持以下子命令：
- `install`
- `uninstall`
- `restart`
- `upgrade`
- `status`
- `logs`

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

升级：
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

如果你修改的是镜像层相关内容（例如 Dockerfile、系统依赖、桌面组件），仅 `restart` 不够，需要执行 `upgrade` 触发重建镜像。

## 可选参数

两个脚本都支持以下参数（按平台写法不同）：
- 安装目录：`InstallDir` / `--install-dir`
- 分支：`Branch` / `--branch`
- 仓库：`RepoUrl` / `--repo-url`
- 网关端口：`GatewayPort` / `--gateway-port`
- VNC HTTPS 端口：`HttpsPort` / `--https-port`
- 网关 Token：`GatewayToken` / `--gateway-token`
- VNC 密码：`KasmPassword` / `--kasm-password`

示例（Windows）：
```powershell
powershell -ExecutionPolicy Bypass -File .\openclaw_kasmvnc.ps1 `
  -Command install `
  -InstallDir "D:\openclaw-deploy" `
  -Branch "main" `
  -GatewayPort "18789" `
  -HttpsPort "8443"
```

示例（macOS/Linux）：
```bash
./openclaw_kasmvnc.sh install \
  --install-dir "$HOME/openclaw-deploy" \
  --branch main \
  --gateway-port 18789 \
  --https-port 8443
```

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

### 3. 进入桌面后黑屏

处理顺序：
1. 先重启服务：
   - `restart`
2. 查看状态：
   - `status`
3. 查看日志：
   - `logs`（建议先看最近 200 行）
4. 仍有问题时执行升级重建：
   - `upgrade`

### 4. 点击桌面浏览器图标打不开

处理：
- 先执行 `upgrade`，确保使用最新镜像与启动脚本；
- 再执行 `restart`；
- 如果仍异常，执行 `logs --tail 400` 并检查报错。

### 5. 容器反复重启

常见原因：
- `.env` 缺少关键参数；
- 本机目录权限异常；
- 端口冲突。

处理：
- 重新执行 `install`（会自动补全关键配置）；
- 检查目标安装目录是否可读写；
- 更换端口后再次安装。

### 6. 日志太多不好看

建议使用：
- `logs --tail 200`：只看最近日志
- `logs --tail 50`：快速看最后报错

不要直接全量拉取日志，排障效率会很低。
