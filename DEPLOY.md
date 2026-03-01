# 部署指南

本文档说明如何配置 GitHub Actions 自动部署到阿里云 ECS。

## 一、ECS 服务器配置

### 1. 安装 Nginx

```bash
# Ubuntu/Debian
sudo apt update
sudo apt install nginx -y

# 启动并设置开机自启
sudo systemctl start nginx
sudo systemctl enable nginx
```

### 2. 创建网站目录

```bash
sudo mkdir -p /var/www/claw.ihasy.com
sudo mkdir -p /var/www/openclaw-kasmvnc
sudo chown -R www-data:www-data /var/www/claw.ihasy.com
```

### 3. 配置 Nginx

将 `docs/nginx.conf` 的内容复制到 ECS：

```bash
sudo nano /etc/nginx/sites-available/claw.ihasy.com
```

修改 SSL 证书路径（如果证书在其他位置）：
```nginx
ssl_certificate /path/to/your/certificate.crt;
ssl_certificate_key /path/to/your/private.key;
```

启用站点：
```bash
sudo ln -s /etc/nginx/sites-available/claw.ihasy.com /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
```

### 4. 配置 SSH 密钥认证

在 ECS 上为部署用户配置 SSH 公钥：

```bash
# 在本地生成 SSH 密钥对（如果还没有）
ssh-keygen -t rsa -b 4096 -C "github-actions" -f ~/.ssh/github_actions_rsa

# 将公钥添加到 ECS 的 authorized_keys
# 方法 1：手动复制
cat ~/.ssh/github_actions_rsa.pub
# 然后在 ECS 上：
mkdir -p ~/.ssh
echo "公钥内容" >> ~/.ssh/authorized_keys
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys

# 方法 2：使用 ssh-copy-id
ssh-copy-id -i ~/.ssh/github_actions_rsa.pub user@your-ecs-ip
```

### 5. 配置 sudo 免密（用于 nginx reload）

```bash
sudo visudo
```

添加以下行（将 `username` 替换为实际用户名）：
```
username ALL=(ALL) NOPASSWD: /usr/sbin/nginx, /bin/systemctl reload nginx, /bin/systemctl restart nginx
```

## 二、GitHub 仓库配置

### 1. 添加 GitHub Secrets

进入 GitHub 仓库 → Settings → Secrets and variables → Actions → New repository secret

添加以下 secrets：

| Secret 名称 | 说明 | 示例值 |
|------------|------|--------|
| `ECS_HOST` | ECS 服务器 IP 或域名 | `123.456.789.0` |
| `ECS_USER` | SSH 登录用户名 | `ubuntu` 或 `root` |
| `ECS_SSH_KEY` | SSH 私钥内容 | 复制 `~/.ssh/github_actions_rsa` 的完整内容 |

**获取 SSH 私钥内容：**
```bash
cat ~/.ssh/github_actions_rsa
```

复制从 `-----BEGIN OPENSSH PRIVATE KEY-----` 到 `-----END OPENSSH PRIVATE KEY-----` 的全部内容（包括这两行）。

### 2. 测试 SSH 连接

在本地测试 SSH 连接是否正常：

```bash
ssh -i ~/.ssh/github_actions_rsa username@your-ecs-ip "echo 'SSH connection successful'"
```

## 三、部署流程

### 自动部署

推送到 `main` 分支时自动触发：

```bash
git add .
git commit -m "Update website"
git push origin main
```

### 手动触发

GitHub 仓库 → Actions → Deploy to Alibaba Cloud ECS → Run workflow

## 四、部署内容

GitHub Actions 会自动同步：

1. **网站文件** → `/var/www/claw.ihasy.com/`
   - `docs/index.html` - 产品介绍网站
   - `docs/nginx.conf` - Nginx 配置参考

2. **脚本文件** → `/var/www/openclaw-kasmvnc/`
   - `openclaw-kasmvnc.sh` - Linux/macOS 国际版
   - `openclaw-kasmvnc.ps1` - Windows 国际版
   - `openclaw-kasmvnc-zh.sh` - Linux/macOS 中文版
   - `openclaw-kasmvnc-zh.ps1` - Windows 中文版

## 五、验证部署

### 1. 检查文件

```bash
ssh username@your-ecs-ip
ls -la /var/www/claw.ihasy.com/
ls -la /var/www/openclaw-kasmvnc/
```

### 2. 检查 Nginx 状态

```bash
sudo nginx -t
sudo systemctl status nginx
```

### 3. 访问网站

浏览器打开：`https://claw.ihasy.com`

## 六、常见问题

### 1. SSH 连接失败

检查：
- ECS 安全组是否开放 22 端口
- SSH 密钥格式是否正确（包含完整的 BEGIN/END 行）
- ECS 用户的 `~/.ssh/authorized_keys` 权限是否正确（600）

### 2. Nginx reload 失败

检查：
- sudo 免密配置是否正确
- Nginx 配置文件语法是否正确：`sudo nginx -t`

### 3. 文件权限问题

```bash
sudo chown -R www-data:www-data /var/www/claw.ihasy.com
sudo chmod -R 755 /var/www/claw.ihasy.com
```

### 4. SSL 证书问题

确保证书路径正确，或使用 Let's Encrypt 自动获取：

```bash
sudo apt install certbot python3-certbot-nginx -y
sudo certbot --nginx -d claw.ihasy.com
```

## 七、目录结构

部署后 ECS 上的目录结构：

```
/var/www/
├── claw.ihasy.com/          # 网站根目录
│   ├── index.html           # 产品介绍页面
│   └── nginx.conf           # Nginx 配置参考
└── openclaw-kasmvnc/        # 脚本下载目录
    ├── openclaw-kasmvnc.sh
    ├── openclaw-kasmvnc.ps1
    ├── openclaw-kasmvnc-zh.sh
    └── openclaw-kasmvnc-zh.ps1
```

## 八、安全建议

1. **限制 SSH 访问**：只允许 GitHub Actions IP 访问（可选）
2. **使用专用部署用户**：不要使用 root，创建专门的部署用户
3. **定期更新密钥**：定期轮换 SSH 密钥
4. **启用防火墙**：只开放必要端口（80, 443, 22）
5. **监控日志**：定期检查 Nginx 访问日志和错误日志

```bash
# 查看最近的访问日志
sudo tail -f /var/log/nginx/claw.ihasy.com.access.log

# 查看错误日志
sudo tail -f /var/log/nginx/claw.ihasy.com.error.log
```
