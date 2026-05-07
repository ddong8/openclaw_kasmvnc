# Docker 镜像使用指南

## 快速开始

### 中文版（国内镜像加速）

```bash
docker run -d \
  --name openclaw-kasmvnc \
  --privileged \
  --shm-size=2g \
  -p 18789:18789 \
  -p 8443:8444 \
  -e OPENCLAW_GATEWAY_TOKEN=your-token-here \
  -e OPENCLAW_KASMVNC_PASSWORD=your-password-here \
  -v ~/openclaw-data:/home/node \
  ddong8/openclaw-kasmvnc:latest
```

### 国际版（官方源）

```bash
docker run -d \
  --name openclaw-kasmvnc \
  --privileged \
  --shm-size=2g \
  -p 18789:18789 \
  -p 8443:8444 \
  -e OPENCLAW_GATEWAY_TOKEN=your-token-here \
  -e OPENCLAW_KASMVNC_PASSWORD=your-password-here \
  -e USE_CN_MIRROR=0 \
  -v ~/openclaw-data:/home/node \
  ddong8/openclaw-kasmvnc:latest-intl
```

## 环境变量配置

| 环境变量 | 默认值 | 说明 |
|---------|--------|------|
| `OPENCLAW_GATEWAY_TOKEN` | 无 | **必需**。网关访问令牌 |
| `OPENCLAW_KASMVNC_PASSWORD` | 无 | **必需**。VNC 登录密码 |
| `OPENCLAW_KASMVNC_RESOLUTION` | `1920x1080` | VNC 桌面分辨率 |
| `OPENCLAW_KASMVNC_DEPTH` | `24` | 色彩深度 |
| `OPENCLAW_GATEWAY_BIND` | `lan` | 网关绑定地址（`lan` / `localhost`） |
| `TZ` | `Asia/Shanghai` | 时区 |
| `LANG` | `zh_CN.UTF-8` | 语言环境 |
| `USE_CN_MIRROR` | `1` | 是否使用国内镜像（`1` = 是，`0` = 否） |
| `HTTP_PROXY` | 无 | HTTP 代理地址 |
| `HTTPS_PROXY` | 无 | HTTPS 代理地址 |

## 端口映射

| 容器端口 | 说明 |
|---------|------|
| `18789` | OpenClaw Gateway WebChat |
| `18790` | OpenClaw Gateway Bridge |
| `8444` | KasmVNC HTTPS 桌面 |

## 数据持久化

### 推荐方案：完整持久化

为了保留所有用户数据、配置和开发环境，推荐挂载整个用户主目录：

```bash
docker run -d \
  --name openclaw-kasmvnc \
  --privileged \
  --shm-size=2g \
  -p 18789:18789 \
  -p 8443:8444 \
  -e OPENCLAW_GATEWAY_TOKEN=your-token-here \
  -e OPENCLAW_KASMVNC_PASSWORD=your-password-here \
  -v ~/openclaw-data:/home/node \
  ddong8/openclaw-kasmvnc:latest
```

这样可以持久化：
- ✅ OpenClaw 配置和工作空间
- ✅ VS Code 配置、插件和扩展
- ✅ Git 配置和凭证
- ✅ Shell 历史记录
- ✅ 桌面文件和自定义设置
- ✅ SSH 密钥和配置
- ✅ 所有用户级配置文件

### 方案二：选择性持久化

如果只想持久化关键数据：

```bash
docker run -d \
  --name openclaw-kasmvnc \
  --privileged \
  --shm-size=2g \
  -p 18789:18789 \
  -p 8443:8444 \
  -e OPENCLAW_GATEWAY_TOKEN=your-token-here \
  -e OPENCLAW_KASMVNC_PASSWORD=your-password-here \
  -v ~/.openclaw:/home/node/.openclaw \
  -v ~/openclaw-vscode:/home/node/.vscode-server \
  -v ~/openclaw-config:/home/node/.config \
  -v ~/openclaw-local:/home/node/.local \
  -v ~/openclaw-ssh:/home/node/.ssh \
  ddong8/openclaw-kasmvnc:latest
```

### 卷挂载说明

| 容器路径 | 说明 | 推荐持久化 |
|---------|------|-----------|
| `/home/node` | 用户主目录（包含所有数据） | ⭐ 推荐 |
| `/home/node/.openclaw` | OpenClaw 配置和数据目录 | ✅ 必需 |
| `/home/node/.openclaw/workspace` | 工作空间目录 | ✅ 必需 |
| `/home/node/.vscode-server` | VS Code Server 数据 | ✅ 推荐 |
| `/home/node/.config` | 应用配置目录 | ✅ 推荐 |
| `/home/node/.local` | 本地数据和状态 | ✅ 推荐 |
| `/home/node/.ssh` | SSH 密钥和配置 | ⚠️ 可选 |
| `/home/node/Desktop` | 桌面文件 | ⚠️ 可选 |
| `/home/node/.gitconfig` | Git 全局配置 | ⚠️ 可选 |

### 注意事项

1. **首次运行**：如果挂载空目录到 `/home/node`，容器会自动初始化必要的配置文件
2. **权限问题**：确保宿主机目录权限正确（UID 1000）
3. **备份建议**：定期备份 `~/openclaw-data` 目录
4. **迁移容器**：只需复制持久化目录即可迁移到新机器

## 禁用 Docker-in-Docker（更安全）

如果不需要 OpenClaw 管理子容器，可以禁用 DinD 以提高安全性：

```bash
docker run -d \
  --name openclaw-kasmvnc \
  --security-opt seccomp=unconfined \
  --shm-size=2g \
  -p 18789:18789 \
  -p 8443:8444 \
  -e OPENCLAW_GATEWAY_TOKEN=your-token-here \
  -e OPENCLAW_KASMVNC_PASSWORD=your-password-here \
  -v ~/openclaw-data:/home/node \
  ddong8/openclaw-kasmvnc:latest-no-dind
```

注意：
- 禁用 DinD 后不需要 `--privileged` 参数。
- **Docker < 23.0 必须加 `--security-opt seccomp=unconfined`** —— 旧版 Docker 默认 seccomp 配置禁用了 XFCE/GLib spawn 子进程时用的 `close_range` 系统调用，会导致桌面黑屏（xfwm4/xfce4-panel 等组件起不来）。Docker 23.0+ 默认已允许此调用，可以省略此参数。DinD 版本因为带 `--privileged`，已经禁用所有 seccomp 限制，所以不受影响。

## GPU 支持

如果宿主机有 NVIDIA GPU，可以启用 GPU 加速：

```bash
docker run -d \
  --name openclaw-kasmvnc \
  --privileged \
  --gpus all \
  --shm-size=2g \
  -p 18789:18789 \
  -p 8443:8444 \
  -e OPENCLAW_GATEWAY_TOKEN=your-token-here \
  -e OPENCLAW_KASMVNC_PASSWORD=your-password-here \
  -v ~/openclaw-data:/home/node \
  ddong8/openclaw-kasmvnc:latest
```

## 使用 Docker Compose

创建 `docker-compose.yml`：

```yaml
services:
  openclaw-gateway:
    image: ddong8/openclaw-kasmvnc:latest
    container_name: openclaw-kasmvnc
    privileged: true
    shm_size: '2gb'
    init: true
    restart: unless-stopped
    environment:
      OPENCLAW_GATEWAY_TOKEN: ${OPENCLAW_GATEWAY_TOKEN}
      OPENCLAW_KASMVNC_PASSWORD: ${OPENCLAW_KASMVNC_PASSWORD}
      OPENCLAW_KASMVNC_RESOLUTION: 1920x1080
      OPENCLAW_KASMVNC_DEPTH: 24
      TZ: Asia/Shanghai
      LANG: zh_CN.UTF-8
      LANGUAGE: zh_CN:zh
      LC_ALL: zh_CN.UTF-8
    volumes:
      - ~/openclaw-data:/home/node
    ports:
      - "18789:18789"
      - "18790:18790"
      - "8443:8444"
```

创建 `.env` 文件：

```env
OPENCLAW_GATEWAY_TOKEN=your-token-here
OPENCLAW_KASMVNC_PASSWORD=your-password-here
```

启动：

```bash
docker compose up -d
```

## 访问服务

启动后访问：

| 服务 | 地址 | 凭证 |
|------|------|------|
| WebChat | `http://localhost:18789/chat?session=main` | `OPENCLAW_GATEWAY_TOKEN` |
| KasmVNC 桌面 | `https://localhost:8443` | 用户名 `node`，密码 `OPENCLAW_KASMVNC_PASSWORD` |

## 预装工具

桌面环境预装了以下开发工具：

- **Chromium** - 浏览器（桌面图标）
- **Visual Studio Code** - 代码编辑器（桌面图标）
- **vim** - 终端文本编辑器
- **Git** - 版本控制工具
- **Node.js 22** - JavaScript 运行时
- **npm** - 包管理器
- **Docker CE** - 容器引擎（仅 DinD 版本）

桌面图标位于 `/home/node/Desktop`，双击即可启动应用。

## 常用命令

```bash
# 查看日志
docker logs -f openclaw-kasmvnc

# 进入容器
docker exec -it openclaw-kasmvnc bash

# 重启容器
docker restart openclaw-kasmvnc

# 停止容器
docker stop openclaw-kasmvnc

# 删除容器
docker rm -f openclaw-kasmvnc

# 升级 OpenClaw（容器内热更新）
docker exec openclaw-kasmvnc bash -c "npm i -g openclaw@latest && openclaw gateway restart"
```

## 构建镜像

### 中文版（国内镜像）

```bash
docker build -t openclaw-kasmvnc:latest \
  --build-arg USE_CN_MIRROR=1 \
  --build-arg NO_DIND=0 \
  .
```

### 国际版（官方源）

```bash
docker build -t openclaw-kasmvnc:latest-intl \
  --build-arg USE_CN_MIRROR=0 \
  --build-arg TZ=UTC \
  --build-arg LANG=en_US.UTF-8 \
  --build-arg LANGUAGE=en_US:en \
  --build-arg NO_DIND=0 \
  .
```

### 禁用 DinD 版本

```bash
docker build -t openclaw-kasmvnc:latest-no-dind \
  --build-arg USE_CN_MIRROR=1 \
  --build-arg NO_DIND=1 \
  .
```

## 多架构支持

支持 `amd64` 和 `arm64` 架构：

```bash
docker buildx build --platform linux/amd64,linux/arm64 \
  -t ddong8/openclaw-kasmvnc:latest \
  --push \
  .
```

## 故障排查

### 查看容器日志

```bash
docker logs openclaw-kasmvnc
```

### 查看 OpenClaw Gateway 日志

```bash
docker exec openclaw-kasmvnc cat /tmp/openclaw-gateway.log
```

### 查看 KasmVNC 日志

```bash
docker exec openclaw-kasmvnc cat /tmp/openclaw-kasmvnc.log
```

### 查看 Docker 守护进程日志（DinD）

```bash
docker exec openclaw-kasmvnc cat /tmp/openclaw-dockerd.log
```

### 重启 Gateway

```bash
docker exec openclaw-kasmvnc openclaw gateway restart
```

## 安全建议

1. **使用强密码**：`OPENCLAW_GATEWAY_TOKEN` 和 `OPENCLAW_KASMVNC_PASSWORD` 应使用强随机密码
2. **限制网络访问**：生产环境建议使用防火墙限制访问来源
3. **禁用 DinD**：如果不需要子容器功能，使用 `latest-no-dind` 镜像
4. **定期更新**：定期拉取最新镜像并重建容器

## 许可证

MIT License
