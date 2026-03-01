# GitHub Secrets 配置指南

## 需要添加的 GitHub Secrets

进入你的 GitHub 仓库：
https://github.com/ddong8/openclaw-kasmvnc/settings/secrets/actions

点击 "New repository secret"，依次添加以下 3 个 secrets：

---

### 1. ECS_HOST
**Name:** `ECS_HOST`
**Value:** 你的阿里云 ECS 服务器 IP 地址或域名

示例：
```
123.456.789.0
```
或
```
your-server.aliyuncs.com
```

---

### 2. ECS_USER
**Name:** `ECS_USER`
**Value:** SSH 登录用户名

常见值：
- Ubuntu 系统：`ubuntu`
- CentOS 系统：`root` 或 `centos`
- Debian 系统：`admin` 或 `root`

---

### 3. ECS_SSH_KEY
**Name:** `ECS_SSH_KEY`
**Value:** 下面的完整私钥内容（包括 BEGIN 和 END 行）

```
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAACFwAAAAdzc2gtcn
NhAAAAAwEAAQAAAgEA7hXP3/o2Wy2f4PXnDlctsbcogf++9nTM9GdOTfa+4VLKmG1uohlm
qygQG1JCkuNdTZLaFWwDEZIt1Iqoojeafm0nTC6O6d4rYv3/BonR2P5tNkgAKqfBgVMqPw
blnb21vL5m+VNvjf4DoVs15NsZtqO+kC3y9SvfbUYMSafrjIujmwjdsCV7CZoAIMPwkD25
ztb5YQppDo8j9hqMCSdYpB3w50Y7O0NfeDC+Nf84gAbaIgvJFE/ffOxhXysXYd8zietwiv
mNAGqCobcibr0KBwfWVGoqiKGYtRIU05reDTLZEoj6TefCPXko/p+CmPMUrKhwSaHx38oT
OG1zyAnmn+/kWoOZ8EJHEg8qez0l/7e7ZExflnQ+cOhxkpSDOYaqm251ZwtwMOQaF1IzM6
xw0zS4wYL+DvUheQq1G3PDMlEooHVnnCliYrjoTZvAI7kpPxtxr/Z8V8meyonB2oXLnGIQ
hQ6uQQ3OmdF00HbaYryI+vVMxiXuBlD1w6CR2t657OufJRrfswdYsD+vX81NLMej/OAtMb
GVGZM+jsKlAlgCNpomFYEXqNGr/NK2oKvOu5gIyMYJ+eJL4vIYiCU3dljCCQSNhcXdTzbu
GgiZwr4cJyTdYd4Dz4ncesK8PoVPQT4OkcxzV0LctAVXXnRJgf3sCu2U/BGuve8U2+AY23
EAAAdQ2CwjtNgsI7QAAAAHc3NoLXJzYQAAAgEA7hXP3/o2Wy2f4PXnDlctsbcogf++9nTM
9GdOTfa+4VLKmG1uohlmqygQG1JCkuNdTZLaFWwDEZIt1Iqoojeafm0nTC6O6d4rYv3/Bo
nR2P5tNkgAKqfBgVMqPwblnb21vL5m+VNvjf4DoVs15NsZtqO+kC3y9SvfbUYMSafrjIuj
mwjdsCV7CZoAIMPwkD25ztb5YQppDo8j9hqMCSdYpB3w50Y7O0NfeDC+Nf84gAbaIgvJFE
/ffOxhXysXYd8zietwivmNAGqCobcibr0KBwfWVGoqiKGYtRIU05reDTLZEoj6TefCPXko
/p+CmPMUrKhwSaHx38oTOG1zyAnmn+/kWoOZ8EJHEg8qez0l/7e7ZExflnQ+cOhxkpSDOY
aqm251ZwtwMOQaF1IzM6xw0zS4wYL+DvUheQq1G3PDMlEooHVnnCliYrjoTZvAI7kpPxtx
r/Z8V8meyonB2oXLnGIQhQ6uQQ3OmdF00HbaYryI+vVMxiXuBlD1w6CR2t657OufJRrfsw
dYsD+vX81NLMej/OAtMbGVGZM+jsKlAlgCNpomFYEXqNGr/NK2oKvOu5gIyMYJ+eJL4vIY
iCU3dljCCQSNhcXdTzbuGgiZwr4cJyTdYd4Dz4ncesK8PoVPQT4OkcxzV0LctAVXXnRJgf
3sCu2U/BGuve8U2+AY23EAAAADAQABAAACAQDrd0cQDTaVFpp4srrBxBa9HJhDedwzg3Dw
hvs6wD4oOumDtzcjuluACy9i1ghhndw5THPDm/+s8RXCjyAYz0VMpEepYKKXSdM/JFWE8e
lI4tjARpVjmmYWsVmm2/tb9rQ251iQXaSGmiKdAshafxb/OxLNJaSUNb/TIuQkNJ8RcUlt
m2clPuxgop5dyWuyPFn350TcZJ9ids7qJ3c31mIkbjhDg4IxKoDRLePxI2mNtTknUuCb5i
LyOhZTORr3APjH/sJfsE9zieOIbMbxHqU8LtQayKUoXCnbavaOESxrgU6OtkpXok7I3Xtd
2AQhoMdhu3TSXggJfKFlvVo1DRW4T9+RQ0hZnuBTQPISAa9j2BLY2iNaF1NSmeiXIBvSSU
EBh7635PQDUPaTiXYnHpvWH5gcyVFnoaQxvT1esdwt8vhJVegMXh3nrUGQboMMr1/d5+cJ
9yBj+tsxV/T1xO7Mk4vQ2lWwCebN8ht1zQ5b30aGCopqbNujqh1Bz8bjpcJ4NrmRUGkIcF
P+82V652iQe6e8PD+JcS/z4wAewKhzVdLkFxRysXYqNKb9MPMYf+SB7RqlOuHx1/5zMHca
NymmPCcIjTpNzN5GwHdWKqAf5FcCrSZ/6iX5US7UdZOgkrYBECL5A7PEXNHVy+h2zqAUZw
4QsOf1m6aaYQbH88YsAQAAAQEAiUYlWy76VmMaV72FP+uUDQXLNDsFmRFENFF1vIYTpQQj
BRw1dK+PQXVWqF6RtxLgfMyzZyj2/5SylKXeTt7Xlq0Bz5uiuB0GHdtMxJzXNeJH7Al7X9
tH3J2w70U6eFFI+ugDgvyFZ2OzaOFgHTq4H1T/LSMadXljk6oY1yBTSiHumr8Ne5tX+1hx
lDTIJle7/arAb1g8uvcVaQhZnnlhiartWLU9iwLyavuiwTvWC2J3HlPznSmDVmar2MR5eX
i2zjTEHUDVnk12m4ozp83z01WYgszaLVWEJYWFLgnsFUrjQtJkEk+AzFxo8Lleq3TrpF1d
6PgbQjv600I51cpNgAAAAQEA/NziGO4NfZX2kyxG63A0fMSKEp+PWytvz1DcePh4H+D8iE
o48TBaQ1CQ65jacdQLcFhPJE0miMk9ntiQEBQsCQSxGysvYhtytxbAEpnqoefOfMzyjLpm
It7RK52cYbUNfB8niyhzx8b64gttTqHOUewgWztVfqBYzx1EFzAF/BeB093h813yqxov7w
QZv7Xp4Z1+GPyP6rwc1r4Ze9ITgFGe+M5jHb07849FzjDjXqYmenrM4iz+5zkgPf2UHO1k
cjKlIc4rIzQR9YxEwOFBa9a0coXGJKMvsiAeIL+Ppmu7D2eDQQuESmOaaTzkL4HXAnqYa4
M+h+/UkD9al7gq2QAAAQEA8Qn+YJXoDFCZ7lqFAOEPYzFNsYSr7fxnnDYxfdxUbz4bvIXN
Vm0t4TTPpI7oeLiBAe9X4sYzXA6Y8XUsujeGYUReQ/x2nMUdFW98B9cPPyUTkSniAoU7zA
mscqeh8uepfmXAc6KT1OKO2UGri0sPdw1x8qopNxwRdTQFA8FN+o+YLVw/Ad2JqQoNhm4L
jCfBZZUHxH1DnUq3huWwO9zm4wpJ/QD0p9Ih4GHnxbTIKLUOYP8XrHoH9aMtshsJlqaYu/
pcCGZlac0+50ZRQnNkbIhoABke6bKjCZBbOZ8Rbb667Nn0i5ucjtnXEztDxGe6HuKpLNlo
lziZltHN5UvmWQAAABVnaXRodWItYWN0aW9ucy1kZXBsb3kBAgME
-----END OPENSSH PRIVATE KEY-----
```

---

## ECS 服务器配置

### 1. 添加 SSH 公钥到 ECS

登录你的 ECS 服务器，执行：

```bash
# 创建 .ssh 目录（如果不存在）
mkdir -p ~/.ssh
chmod 700 ~/.ssh

# 添加公钥到 authorized_keys
cat >> ~/.ssh/authorized_keys << 'EOF'
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDuFc/f+jZbLZ/g9ecOVy2xtyiB/772dMz0Z05N9r7hUsqYbW6iGWarKBAbUkKS411NktoVbAMRki3UiqiiN5p+bSdMLo7p3iti/f8GidHY/m02SAAqp8GBUyo/BuWdvbW8vmb5U2+N/gOhWzXk2xm2o76QLfL1K99tRgxJp+uMi6ObCN2wJXsJmgAgw/CQPbnO1vlhCmkOjyP2GowJJ1ikHfDnRjs7Q194ML41/ziABtoiC8kUT9987GFfKxdh3zOJ63CK+Y0AaoKhtyJuvQoHB9ZUaiqIoZi1EhTTmt4NMtkSiPpN58I9eSj+n4KY8xSsqHBJofHfyhM4bXPICeaf7+Rag5nwQkcSDyp7PSX/t7tkTF+WdD5w6HGSlIM5hqqbbnVnC3Aw5BoXUjMzrHDTNLjBgv4O9SF5CrUbc8MyUSigdWecKWJiuOhNm8AjuSk/G3Gv9nxXyZ7KicHahcucYhCFDq5BDc6Z0XTQdtpivIj69UzGJe4GUPXDoJHa3rns658lGt+zB1iwP69fzU0sx6P84C0xsZUZkz6OwqUCWAI2miYVgReo0av80ragq867mAjIxgn54kvi8hiIJTd2WMIJBI2Fxd1PNu4aCJnCvhwnJN1h3gPPidx6wrw+hU9BPg6RzHNXQty0BVdedEmB/ewK7ZT8Ea697xTb4BjbcQ== github-actions-deploy
EOF

# 设置正确的权限
chmod 600 ~/.ssh/authorized_keys
```

### 2. 配置 sudo 免密（用于 nginx reload）

```bash
sudo visudo
```

在文件末尾添加（将 `your-username` 替换为实际用户名）：
```
your-username ALL=(ALL) NOPASSWD: /usr/sbin/nginx, /bin/systemctl reload nginx, /bin/systemctl restart nginx
```

保存并退出（Ctrl+X, Y, Enter）

### 3. 测试 SSH 连接

在本地测试连接：
```bash
ssh -i ~/.ssh/openclaw_deploy_rsa your-username@your-ecs-ip "echo 'Connection successful!'"
```

---

## 快速配置步骤

1. **在 GitHub 添加 Secrets**
   - 访问：https://github.com/ddong8/openclaw-kasmvnc/settings/secrets/actions
   - 添加上面的 3 个 secrets

2. **在 ECS 配置 SSH**
   - 复制上面的公钥添加命令，在 ECS 上执行
   - 配置 sudo 免密

3. **推送代码测试**
   ```bash
   git add .
   git commit -m "Add deployment workflow"
   git push origin main
   ```

4. **查看部署状态**
   - 访问：https://github.com/ddong8/openclaw-kasmvnc/actions
   - 查看 workflow 运行状态

---

## 注意事项

1. **安全组配置**：确保 ECS 安全组开放了 22 端口（SSH）
2. **防火墙**：如果 ECS 启用了防火墙，需要允许 22 端口
3. **私钥保密**：GitHub Secrets 中的私钥不会被泄露，但不要在其他地方公开
4. **备份密钥**：建议备份 `~/.ssh/openclaw_deploy_rsa` 和 `~/.ssh/openclaw_deploy_rsa.pub`

---

生成时间：2026-03-01
密钥位置：~/.ssh/openclaw_deploy_rsa
