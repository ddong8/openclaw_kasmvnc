#!/bin/bash
# ECS 服务器快速配置脚本
# 用于配置 GitHub Actions 自动部署

set -e

echo "=========================================="
echo "  OpenClaw KasmVNC - ECS 部署配置脚本"
echo "=========================================="
echo ""

# 检查是否为 root
if [ "$EUID" -ne 0 ]; then
    echo "请使用 sudo 运行此脚本"
    exit 1
fi

# 获取实际用户
ACTUAL_USER=${SUDO_USER:-$USER}
USER_HOME=$(eval echo ~$ACTUAL_USER)

echo "当前用户: $ACTUAL_USER"
echo "用户目录: $USER_HOME"
echo ""

# 1. 安装 Nginx
echo "[1/6] 安装 Nginx..."
if command -v nginx &> /dev/null; then
    echo "✓ Nginx 已安装"
else
    apt update
    apt install nginx -y
    systemctl start nginx
    systemctl enable nginx
    echo "✓ Nginx 安装完成"
fi
echo ""

# 2. 创建目录
echo "[2/6] 创建网站目录..."
mkdir -p /var/www/claw.ihasy.com
mkdir -p /var/www/openclaw-kasmvnc
chown -R www-data:www-data /var/www/claw.ihasy.com
echo "✓ 目录创建完成"
echo ""

# 3. 配置 SSH
echo "[3/6] 配置 SSH 公钥..."
mkdir -p "$USER_HOME/.ssh"
chmod 700 "$USER_HOME/.ssh"

# 添加公钥
cat >> "$USER_HOME/.ssh/authorized_keys" << 'EOF'
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDuFc/f+jZbLZ/g9ecOVy2xtyiB/772dMz0Z05N9r7hUsqYbW6iGWarKBAbUkKS411NktoVbAMRki3UiqiiN5p+bSdMLo7p3iti/f8GidHY/m02SAAqp8GBUyo/BuWdvbW8vmb5U2+N/gOhWzXk2xm2o76QLfL1K99tRgxJp+uMi6ObCN2wJXsJmgAgw/CQPbnO1vlhCmkOjyP2GowJJ1ikHfDnRjs7Q194ML41/ziABtoiC8kUT9987GFfKxdh3zOJ63CK+Y0AaoKhtyJuvQoHB9ZUaiqIoZi1EhTTmt4NMtkSiPpN58I9eSj+n4KY8xSsqHBJofHfyhM4bXPICeaf7+Rag5nwQkcSDyp7PSX/t7tkTF+WdD5w6HGSlIM5hqqbbnVnC3Aw5BoXUjMzrHDTNLjBgv4O9SF5CrUbc8MyUSigdWecKWJiuOhNm8AjuSk/G3Gv9nxXyZ7KicHahcucYhCFDq5BDc6Z0XTQdtpivIj69UzGJe4GUPXDoJHa3rns658lGt+zB1iwP69fzU0sx6P84C0xsZUZkz6OwqUCWAI2miYVgReo0av80ragq867mAjIxgn54kvi8hiIJTd2WMIJBI2Fxd1PNu4aCJnCvhwnJN1h3gPPidx6wrw+hU9BPg6RzHNXQty0BVdedEmB/ewK7ZT8Ea697xTb4BjbcQ== github-actions-deploy
EOF

chmod 600 "$USER_HOME/.ssh/authorized_keys"
chown -R $ACTUAL_USER:$ACTUAL_USER "$USER_HOME/.ssh"
echo "✓ SSH 公钥配置完成"
echo ""

# 4. 配置 sudo 免密
echo "[4/6] 配置 sudo 免密..."
cat > /etc/sudoers.d/github-deploy << EOF
$ACTUAL_USER ALL=(ALL) NOPASSWD: /usr/sbin/nginx, /bin/systemctl reload nginx, /bin/systemctl restart nginx
EOF
chmod 440 /etc/sudoers.d/github-deploy
echo "✓ sudo 免密配置完成"
echo ""

# 5. 配置 Nginx 站点
echo "[5/6] 配置 Nginx 站点..."
cat > /etc/nginx/sites-available/claw.ihasy.com << 'EOF'
server {
    listen 80;
    listen [::]:80;
    server_name claw.ihasy.com;

    # 如果有 SSL 证书，取消下面这行注释并注释掉下面的 root 配置
    # return 301 https://$server_name$request_uri;

    root /var/www/claw.ihasy.com;
    index index.html;

    access_log /var/log/nginx/claw.ihasy.com.access.log;
    error_log /var/log/nginx/claw.ihasy.com.error.log;

    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/xml text/javascript application/javascript application/xml+rss application/json;

    location / {
        try_files $uri $uri/ =404;
    }

    location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|woff|woff2|ttf|eot)$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
    }

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
}

# 如果有 SSL 证书，取消下面的注释并修改证书路径
# server {
#     listen 443 ssl http2;
#     listen [::]:443 ssl http2;
#     server_name claw.ihasy.com;
#
#     ssl_certificate /etc/nginx/ssl/claw.ihasy.com.crt;
#     ssl_certificate_key /etc/nginx/ssl/claw.ihasy.com.key;
#
#     ssl_protocols TLSv1.2 TLSv1.3;
#     ssl_ciphers HIGH:!aNULL:!MD5;
#     ssl_prefer_server_ciphers on;
#     ssl_session_cache shared:SSL:10m;
#     ssl_session_timeout 10m;
#
#     root /var/www/claw.ihasy.com;
#     index index.html;
#
#     access_log /var/log/nginx/claw.ihasy.com.access.log;
#     error_log /var/log/nginx/claw.ihasy.com.error.log;
#
#     gzip on;
#     gzip_vary on;
#     gzip_min_length 1024;
#     gzip_types text/plain text/css text/xml text/javascript application/javascript application/xml+rss application/json;
#
#     location / {
#         try_files $uri $uri/ =404;
#     }
#
#     location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|woff|woff2|ttf|eot)$ {
#         expires 30d;
#         add_header Cache-Control "public, immutable";
#     }
#
#     add_header X-Frame-Options "SAMEORIGIN" always;
#     add_header X-Content-Type-Options "nosniff" always;
#     add_header X-XSS-Protection "1; mode=block" always;
# }
EOF

ln -sf /etc/nginx/sites-available/claw.ihasy.com /etc/nginx/sites-enabled/
nginx -t
systemctl reload nginx
echo "✓ Nginx 站点配置完成"
echo ""

# 6. 检查防火墙
echo "[6/6] 检查防火墙配置..."
if command -v ufw &> /dev/null; then
    ufw allow 22/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp
    echo "✓ UFW 防火墙规则已添加"
elif command -v firewall-cmd &> /dev/null; then
    firewall-cmd --permanent --add-service=ssh
    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-service=https
    firewall-cmd --reload
    echo "✓ Firewalld 防火墙规则已添加"
else
    echo "⚠ 未检测到防火墙，请手动确保开放 22, 80, 443 端口"
fi
echo ""

echo "=========================================="
echo "  配置完成！"
echo "=========================================="
echo ""
echo "下一步："
echo "1. 在 GitHub 仓库添加 Secrets（参考 GITHUB_SECRETS.md）"
echo "2. 推送代码到 main 分支触发自动部署"
echo "3. 访问 http://claw.ihasy.com 查看网站"
echo ""
echo "如需配置 HTTPS，请编辑："
echo "  /etc/nginx/sites-available/claw.ihasy.com"
echo ""
echo "查看日志："
echo "  sudo tail -f /var/log/nginx/claw.ihasy.com.access.log"
echo "  sudo tail -f /var/log/nginx/claw.ihasy.com.error.log"
echo ""
