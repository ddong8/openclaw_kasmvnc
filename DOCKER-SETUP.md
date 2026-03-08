# Docker Hub 和 GitHub Actions 配置指南

## 1. Docker Hub 配置

### 创建仓库
1. 访问 https://hub.docker.com/
2. 点击 "Create Repository"
3. 填写信息：
   - Repository Name: `openclaw-kasmvnc`
   - Visibility: **Public**
   - Description: `One-click OpenClaw + KasmVNC deployment with full desktop environment`
4. 点击 "Create"

### 创建 Access Token
1. 点击右上角头像 → **Account Settings**
2. 左侧菜单选择 **Security**
3. 点击 **New Access Token**
4. 填写信息：
   - Description: `GitHub Actions`
   - Access permissions: **Read, Write, Delete**
5. 点击 **Generate**
6. **复制生成的 token**（只显示一次！）

## 2. GitHub Secrets 配置

### 添加 Secrets
1. 访问 https://github.com/ddong8/openclaw-kasmvnc/settings/secrets/actions
2. 点击 **New repository secret**
3. 添加第一个 secret：
   - Name: `DOCKERHUB_USERNAME`
   - Value: 你的 Docker Hub 用户名（例如：`ddong8`）
   - 点击 **Add secret**
4. 再次点击 **New repository secret**
5. 添加第二个 secret：
   - Name: `DOCKERHUB_TOKEN`
   - Value: 刚才复制的 Access Token
   - 点击 **Add secret**

## 3. 触发构建

配置完成后，有三种方式触发构建：

### 方式一：推送代码（自动触发）
```bash
git push origin main
```

### 方式二：创建 tag（推荐用于发布版本）
```bash
git tag v1.0.2
git push origin v1.0.2
```

这会构建并推送以下镜像：
- `ddong8/openclaw-kasmvnc:latest`
- `ddong8/openclaw-kasmvnc:latest-intl`
- `ddong8/openclaw-kasmvnc:latest-no-dind`
- `ddong8/openclaw-kasmvnc:latest-intl-no-dind`
- `ddong8/openclaw-kasmvnc:1.0.2-latest`
- `ddong8/openclaw-kasmvnc:1.0.2-latest-intl`
- `ddong8/openclaw-kasmvnc:1.0.2-latest-no-dind`
- `ddong8/openclaw-kasmvnc:1.0.2-latest-intl-no-dind`
- `ddong8/openclaw-kasmvnc:1.0-latest`
- `ddong8/openclaw-kasmvnc:1.0-latest-intl`
- `ddong8/openclaw-kasmvnc:1.0-latest-no-dind`
- `ddong8/openclaw-kasmvnc:1.0-latest-intl-no-dind`

### 方式三：手动触发
1. 访问 https://github.com/ddong8/openclaw-kasmvnc/actions
2. 选择 "Build and Push Docker Images" workflow
3. 点击 **Run workflow**
4. 选择分支（main）
5. 点击 **Run workflow**

## 4. 查看构建状态

1. 访问 https://github.com/ddong8/openclaw-kasmvnc/actions
2. 查看最新的 workflow 运行状态
3. 点击进入查看详细日志

构建时间：
- 首次构建：约 15-20 分钟（需要下载所有依赖）
- 后续构建：约 5-10 分钟（使用缓存）

## 5. 验证镜像

构建完成后，可以拉取并测试镜像：

```bash
# 拉取镜像
docker pull ddong8/openclaw-kasmvnc:latest

# 运行测试
docker run -d \
  --name openclaw-test \
  --privileged \
  --shm-size=2g \
  -p 18789:18789 \
  -p 8443:8444 \
  -e OPENCLAW_GATEWAY_TOKEN=test-token-123 \
  -e OPENCLAW_KASMVNC_PASSWORD=test-pass-456 \
  ddong8/openclaw-kasmvnc:latest

# 查看日志
docker logs -f openclaw-test

# 访问服务
# WebChat: http://localhost:18789/chat?session=main
# Desktop: https://localhost:8443

# 清理
docker rm -f openclaw-test
```

## 6. 镜像变体说明

| 镜像标签 | 说明 | 适用场景 |
|---------|------|---------|
| `latest` | 中文版 + 国内镜像 + DinD | 国内用户，需要 Docker-in-Docker |
| `latest-intl` | 国际版 + 官方源 + DinD | 国外用户，需要 Docker-in-Docker |
| `latest-no-dind` | 中文版 + 国内镜像 + 无 DinD | 国内用户，不需要子容器（更安全） |
| `latest-intl-no-dind` | 国际版 + 官方源 + 无 DinD | 国外用户，不需要子容器（更安全） |

## 7. 常见问题

### Q: 构建失败怎么办？
A: 检查以下几点：
1. Docker Hub token 是否正确
2. GitHub Secrets 是否正确配置
3. 查看 Actions 日志找到具体错误

### Q: 如何更新镜像？
A: 推送新代码或创建新 tag 即可自动触发构建

### Q: 如何删除旧镜像？
A: 在 Docker Hub 仓库页面的 Tags 标签页可以删除

### Q: 构建太慢怎么办？
A: GitHub Actions 使用缓存，后续构建会快很多。如果还是慢，可以考虑：
1. 减少构建变体
2. 使用 self-hosted runner
3. 使用其他 CI/CD 服务

## 8. 下一步

配置完成后，用户可以通过以下方式使用：

```bash
docker run -d \
  --name openclaw-kasmvnc \
  --privileged \
  --shm-size=2g \
  -p 18789:18789 \
  -p 8443:8444 \
  -e OPENCLAW_GATEWAY_TOKEN=your-token \
  -e OPENCLAW_KASMVNC_PASSWORD=your-password \
  -v ~/.openclaw:/home/node/.openclaw \
  ddong8/openclaw-kasmvnc:latest
```

更多使用说明请参考 [DOCKER.md](DOCKER.md)
