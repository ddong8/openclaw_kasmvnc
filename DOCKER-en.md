# Docker Image Usage Guide

## Quick Start

### Chinese Version (China Mirror Acceleration)

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

### International Version (Official Sources)

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

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENCLAW_GATEWAY_TOKEN` | None | **Required**. Gateway access token |
| `OPENCLAW_KASMVNC_PASSWORD` | None | **Required**. VNC login password |
| `OPENCLAW_KASMVNC_RESOLUTION` | `1920x1080` | VNC desktop resolution |
| `OPENCLAW_KASMVNC_DEPTH` | `24` | Color depth |
| `OPENCLAW_GATEWAY_BIND` | `lan` | Gateway bind address (`lan` / `localhost`) |
| `TZ` | `Asia/Shanghai` | Timezone |
| `LANG` | `zh_CN.UTF-8` | Locale |
| `USE_CN_MIRROR` | `1` | Use China mirrors (`1` = yes, `0` = no) |
| `HTTP_PROXY` | None | HTTP proxy address |
| `HTTPS_PROXY` | None | HTTPS proxy address |

## Port Mapping

| Container Port | Description |
|----------------|-------------|
| `18789` | OpenClaw Gateway WebChat |
| `18790` | OpenClaw Gateway Bridge |
| `8444` | KasmVNC HTTPS Desktop |

## Volume Mounts

| Container Path | Description |
|----------------|-------------|
| `/home/node` | Home directory (configuration, workspace, and all user data) |

## Disable Docker-in-Docker (More Secure)

If you don't need OpenClaw to manage sub-containers, disable DinD for better security:

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

Notes:
- The `--privileged` flag is not needed when DinD is disabled.
- **`--security-opt seccomp=unconfined` is required on Docker < 23.0** — older Docker default seccomp profile blocks the `close_range` syscall that XFCE/GLib uses to spawn child processes, causing the desktop to render as a black screen. Docker 23.0+ allows this syscall by default and the flag becomes unnecessary. The DinD variants don't need it because `--privileged` already disables seccomp.

## GPU Support

If your host has an NVIDIA GPU, enable GPU acceleration:

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

## Using Docker Compose

Create `docker-compose.yml`:

```yaml
services:
  openclaw-gateway:
    image: ddong8/openclaw-kasmvnc:latest-intl
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
      USE_CN_MIRROR: "0"
      TZ: UTC
      LANG: en_US.UTF-8
      LANGUAGE: en_US:en
      LC_ALL: en_US.UTF-8
    volumes:
      - ~/openclaw-data:/home/node
    ports:
      - "18789:18789"
      - "18790:18790"
      - "8443:8444"
```

Create `.env` file:

```env
OPENCLAW_GATEWAY_TOKEN=your-token-here
OPENCLAW_KASMVNC_PASSWORD=your-password-here
```

Start:

```bash
docker compose up -d
```

## Accessing Services

After starting, access:

| Service | URL | Credentials |
|---------|-----|-------------|
| WebChat | `http://localhost:18789/chat?session=main` | `OPENCLAW_GATEWAY_TOKEN` |
| KasmVNC Desktop | `https://localhost:8443` | Username `node`, Password `OPENCLAW_KASMVNC_PASSWORD` |

## Common Commands

```bash
# View logs
docker logs -f openclaw-kasmvnc

# Enter container
docker exec -it openclaw-kasmvnc bash

# Restart container
docker restart openclaw-kasmvnc

# Stop container
docker stop openclaw-kasmvnc

# Remove container
docker rm -f openclaw-kasmvnc

# Upgrade OpenClaw (hot update inside container)
docker exec openclaw-kasmvnc bash -c "npm i -g openclaw@latest && openclaw gateway restart"
```

## Building Images

### Chinese Version (China Mirrors)

```bash
docker build -t openclaw-kasmvnc:latest \
  --build-arg USE_CN_MIRROR=1 \
  --build-arg NO_DIND=0 \
  .
```

### International Version (Official Sources)

```bash
docker build -t openclaw-kasmvnc:latest-intl \
  --build-arg USE_CN_MIRROR=0 \
  --build-arg TZ=UTC \
  --build-arg LANG=en_US.UTF-8 \
  --build-arg LANGUAGE=en_US:en \
  --build-arg NO_DIND=0 \
  .
```

### No-DinD Version

```bash
docker build -t openclaw-kasmvnc:latest-no-dind \
  --build-arg USE_CN_MIRROR=1 \
  --build-arg NO_DIND=1 \
  .
```

## Multi-Architecture Support

Supports `amd64` and `arm64` architectures:

```bash
docker buildx build --platform linux/amd64,linux/arm64 \
  -t ddong8/openclaw-kasmvnc:latest \
  --push \
  .
```

## Troubleshooting

### View Container Logs

```bash
docker logs openclaw-kasmvnc
```

### View OpenClaw Gateway Logs

```bash
docker exec openclaw-kasmvnc cat /tmp/openclaw-gateway.log
```

### View KasmVNC Logs

```bash
docker exec openclaw-kasmvnc cat /tmp/openclaw-kasmvnc.log
```

### View Docker Daemon Logs (DinD)

```bash
docker exec openclaw-kasmvnc cat /tmp/openclaw-dockerd.log
```

### Restart Gateway

```bash
docker exec openclaw-kasmvnc openclaw gateway restart
```

## Security Recommendations

1. **Use Strong Passwords**: `OPENCLAW_GATEWAY_TOKEN` and `OPENCLAW_KASMVNC_PASSWORD` should use strong random passwords
2. **Restrict Network Access**: In production, use firewall rules to limit access sources
3. **Disable DinD**: If sub-container functionality is not needed, use the `latest-no-dind` image
4. **Regular Updates**: Regularly pull the latest image and rebuild containers

## License

MIT License
