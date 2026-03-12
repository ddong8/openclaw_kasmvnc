FROM node:22-bookworm

USER root

# Remove dpkg exclusions so translation files (locales) are installed for full UI localization
RUN rm -f /etc/dpkg/dpkg.cfg.d/docker && rm -f /etc/apt/apt.conf.d/docker-clean

# Accept build arguments early
ARG USE_CN_MIRROR=1

# Configure apt to use Tsinghua mirror for faster downloads in China (only if USE_CN_MIRROR=1)
RUN if [ "${USE_CN_MIRROR}" = "1" ]; then \
      sed -i 's/deb.debian.org/mirrors.tuna.tsinghua.edu.cn/g' /etc/apt/sources.list.d/debian.sources 2>/dev/null || true; \
      sed -i 's/security.debian.org/mirrors.tuna.tsinghua.edu.cn/g' /etc/apt/sources.list.d/debian.sources 2>/dev/null || true; \
      sed -i 's/deb.debian.org/mirrors.tuna.tsinghua.edu.cn/g' /etc/apt/sources.list 2>/dev/null || true; \
      sed -i 's/security.debian.org/mirrors.tuna.tsinghua.edu.cn/g' /etc/apt/sources.list 2>/dev/null || true; \
    fi

# Install git and ssh client (required by some npm lifecycle scripts and git dependencies)
RUN apt-get update && apt-get install -y --no-install-recommends git openssh-client && rm -rf /var/lib/apt/lists/*

# Accept proxy build arguments
ARG HTTP_PROXY
ARG HTTPS_PROXY

# Install OpenClaw via npm (pre-built, includes correct version metadata)
# Configure npm registry and force git to use HTTPS, preserving optional dependencies
ARG OPENC_CACHE_BUST=1
RUN if [ "${USE_CN_MIRROR}" = "1" ]; then \
      npm config set registry https://registry.npmmirror.com; \
    else \
      npm config set registry https://registry.npmjs.org; \
    fi \
 && git config --global url."https://github.com/".insteadOf "git@github.com:" \
 && git config --global url."https://github.com/".insteadOf "ssh://git@github.com/" \
 && git config --global url."https://".insteadOf "git://" \
 && npm install -g openclaw@latest --no-audit --no-fund \
 && chown -R node:node /usr/local/lib/node_modules /usr/local/bin

# Configure timezone and locale (can be overridden via build args)
ARG TZ=Asia/Shanghai
ARG LANG=zh_CN.UTF-8
ENV PATH="/opt/KasmVNC/bin:${PATH}"
ENV TZ=${TZ}
ENV LANG=${LANG}
ENV LANGUAGE=${LANG%.*}:${LANG%%_*}
ENV LC_ALL=${LANG}
ENV GTK_IM_MODULE=fcitx
ENV QT_IM_MODULE=fcitx
ENV XMODIFIERS=@im=fcitx

ARG KASMVNC_VERSION=1.3.0
ARG TARGETARCH

RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    chromium \
    curl \
    dbus-x11 \
    fonts-noto-cjk \
    gnupg \
    fcitx5 \
    fcitx5-rime \
    fcitx5-frontend-gtk3 \
    fcitx5-frontend-qt5 \
    fcitx5-config-qt \
    im-config \
    jq \
    libdatetime-perl \
    libegl1 \
    libglu1-mesa \
    libglx-mesa0 \
    locales \
    lsof \
    procps \
    sudo \
    tzdata \
    vim \
    wget \
    xfce4 \
    xfce4-terminal \
    xterm \
  && ln -snf /usr/share/zoneinfo/${TZ} /etc/localtime \
  && echo "${TZ}" > /etc/timezone \
  && sed -i 's/^# *zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' /etc/locale.gen \
  && locale-gen zh_CN.UTF-8 \
  && update-locale LANG=zh_CN.UTF-8 LC_ALL=zh_CN.UTF-8 \
  && rm -rf /var/lib/apt/lists/*

# Install Docker CE for Docker-in-Docker support using Aliyun mirror (only if NO_DIND != 1)
ARG NO_DIND=0
RUN if [ "${NO_DIND}" != "1" ]; then \
  if [ "${USE_CN_MIRROR}" = "1" ]; then \
    curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg \
    && echo "deb [arch=${TARGETARCH} signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://mirrors.aliyun.com/docker-ce/linux/debian bookworm stable" \
       > /etc/apt/sources.list.d/docker.list; \
  else \
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg \
    && echo "deb [arch=${TARGETARCH} signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian bookworm stable" \
       > /etc/apt/sources.list.d/docker.list; \
  fi \
  && apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends --fix-missing \
     docker-ce docker-ce-cli containerd.io docker-compose-plugin \
  && rm -rf /var/lib/apt/lists/*; \
fi

RUN printf '%s\n' \
  '#!/usr/bin/env bash' \
  'exec /usr/bin/chromium --no-sandbox --disable-gpu --disable-dev-shm-usage --disable-software-rasterizer --test-type --no-first-run --disable-background-networking --disable-sync --disable-default-apps --disable-component-update --disable-features=TranslateUI --remote-debugging-port=9222 --remote-debugging-address=127.0.0.1 "$@"' \
  > /usr/local/bin/chromium-kasm \
  && chmod +x /usr/local/bin/chromium-kasm \
  && sed -i 's|^Exec=/usr/bin/chromium %U|Exec=/usr/local/bin/chromium-kasm %U|' /usr/share/applications/chromium.desktop \
  && echo 'NoDisplay=true' >> /usr/share/applications/chromium.desktop \
  && sed -i 's|^Exec=exo-open --launch WebBrowser %u|Exec=/usr/local/bin/chromium-kasm %u|' /usr/share/applications/xfce4-web-browser.desktop \
  && printf '%s\n' \
    '[Desktop Entry]' \
    'Version=1.0' \
    'Name=Chromium' \
    'GenericName=Web Browser' \
    'Exec=/usr/local/bin/chromium-kasm %U' \
    'Terminal=false' \
    'Type=Application' \
    'Icon=chromium' \
    'Categories=Network;WebBrowser;' \
    'MimeType=text/html;text/xml;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;' \
    > /usr/share/applications/chromium-kasm.desktop \
  && printf '%s\n' \
    '[Desktop Entry]' \
    'Type=X-XFCE-Helper' \
    'X-XFCE-Category=WebBrowser' \
    'X-XFCE-Commands=/usr/local/bin/chromium-kasm' \
    'X-XFCE-CommandsWithParameter=/usr/local/bin/chromium-kasm "%s"' \
    'Name=Chromium' \
    'Icon=chromium' \
    > /usr/share/xfce4/helpers/chromium-kasm.desktop

RUN set -eux; \
  case "${TARGETARCH}" in \
    amd64) pkg_arch="amd64" ;; \
    arm64) pkg_arch="arm64" ;; \
    *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
  esac; \
  pkg="kasmvncserver_bookworm_${KASMVNC_VERSION}_${pkg_arch}.deb"; \
  if [ "${USE_CN_MIRROR}" = "1" ]; then \
    url="https://claw.ihasy.com/mirror/kasmvnc/${pkg}"; \
  else \
    url="https://github.com/kasmtech/KasmVNC/releases/download/v${KASMVNC_VERSION}/${pkg}"; \
  fi; \
  curl -fsSL "${url}" -o "/tmp/${pkg}"; \
  apt-get update --allow-insecure-repositories || apt-get update -o Acquire::AllowInsecureRepositories=true || apt-get update; \
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends --allow-unauthenticated "/tmp/${pkg}"; \
  rm -f "/tmp/${pkg}"; \
  rm -rf /var/lib/apt/lists/*

# Install Rime Ice (雾凇拼音) dictionary and configuration
RUN if [ "${USE_CN_MIRROR}" = "1" ]; then \
      curl -fsSL https://claw.ihasy.com/mirror/rime-ice/rime-ice.tar.gz -o /tmp/rime-ice.tar.gz; \
    else \
      curl -fsSL https://github.com/iDvel/rime-ice/archive/refs/heads/main.tar.gz -o /tmp/rime-ice.tar.gz; \
    fi \
  && mkdir -p /home/node/.local/share/fcitx5/rime \
  && tar xzf /tmp/rime-ice.tar.gz -C /tmp/ \
  && cp -r /tmp/rime-ice-main/* /home/node/.local/share/fcitx5/rime/ \
  && rm -rf /tmp/rime-ice.tar.gz /tmp/rime-ice-main \
  && printf '%s\n' \
    'patch:' \
    '  "switches/@0/reset": 0' \
    > /home/node/.local/share/fcitx5/rime/default.custom.yaml \
  && chown -R node:node /home/node/.local

# Install VS Code
RUN set -eux; \
  case "${TARGETARCH}" in \
    amd64) vscode_arch="amd64" ;; \
    arm64) vscode_arch="arm64" ;; \
    *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
  esac; \
  if [ "${USE_CN_MIRROR}" = "1" ]; then \
    wget -qO- https://mirrors.tuna.tsinghua.edu.cn/microsoft/keys/microsoft.asc | gpg --dearmor > /usr/share/keyrings/packages.microsoft.gpg; \
    echo "deb [arch=${vscode_arch} signed-by=/usr/share/keyrings/packages.microsoft.gpg] https://mirrors.tuna.tsinghua.edu.cn/microsoft/repos/code stable main" \
      > /etc/apt/sources.list.d/vscode.list; \
  else \
    wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /usr/share/keyrings/packages.microsoft.gpg; \
    echo "deb [arch=${vscode_arch} signed-by=/usr/share/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
      > /etc/apt/sources.list.d/vscode.list; \
  fi; \
  apt-get update; \
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends code; \
  rm -rf /var/lib/apt/lists/*

# Create desktop icons for Chromium and VS Code
RUN mkdir -p /home/node/Desktop \
  && cp /usr/share/applications/chromium-kasm.desktop /home/node/Desktop/chromium.desktop \
  && cp /usr/share/applications/code.desktop /home/node/Desktop/vscode.desktop \
  && chmod +x /home/node/Desktop/chromium.desktop /home/node/Desktop/vscode.desktop \
  && chown -R node:node /home/node/Desktop

COPY docker/systemctl-shim.sh /usr/local/bin/systemctl
COPY docker/kasmvnc-startup.sh /usr/local/bin/kasmvnc-startup
RUN sed -i 's/\r$//' /usr/local/bin/systemctl /usr/local/bin/kasmvnc-startup \
  && chmod +x /usr/local/bin/systemctl /usr/local/bin/kasmvnc-startup \
  && usermod -a -G ssl-cert node \
  && (getent group docker >/dev/null && usermod -a -G docker node || true) \
  && echo "node ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers \
  && mkdir -p /home/node/.openclaw /home/node/.vnc \
  && chown -R node:node /home/node/.openclaw /home/node/.vnc \
  && chmod 700 /home/node/.openclaw /home/node/.vnc

# Create systemd service file for openclaw CLI compatibility
RUN mkdir -p /home/node/.config/systemd/user \
  && printf '%s\n' \
    '[Unit]' \
    'Description=OpenClaw Gateway (managed by supervisor)' \
    'After=network-online.target' \
    'Wants=network-online.target' \
    '' \
    '[Service]' \
    'Type=notify' \
    'ExecStart=/bin/true' \
    'RemainAfterExit=yes' \
    '' \
    '[Install]' \
    'WantedBy=default.target' \
    > /home/node/.config/systemd/user/openclaw-gateway.service \
  && chown -R node:node /home/node/.config

# Register Fcitx5 as the system default input method framework
RUN im-config -n fcitx5

USER node

# Configure git to use HTTPS instead of SSH (supports npm dependencies and openclaw update)
RUN git config --global url."https://github.com/".insteadOf "git@github.com:" \
 && git config --global url."https://github.com/".insteadOf "ssh://git@github.com/" \
 && git config --global url."https://".insteadOf "git://"

EXPOSE 18789 18790 8443 8444

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD curl -f http://localhost:18789/ || exit 1

ENTRYPOINT ["/usr/local/bin/kasmvnc-startup"]
CMD ["openclaw", "gateway", "--allow-unconfigured", "--bind", "lan", "--port", "18789"]
