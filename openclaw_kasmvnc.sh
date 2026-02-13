#!/usr/bin/env bash
set -euo pipefail

COMMAND="${1:-install}"
if [[ $# -gt 0 ]]; then
  shift
fi

REPO_URL="${REPO_URL:-https://github.com/openclaw/openclaw.git}"
BRANCH="${BRANCH:-main}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/openclaw-kasmvnc}"
GATEWAY_TOKEN="${GATEWAY_TOKEN:-}"
KASM_PASSWORD="${KASM_PASSWORD:-}"
HTTPS_PORT="${HTTPS_PORT:-8443}"
GATEWAY_PORT="${GATEWAY_PORT:-18789}"
PURGE=0
TAIL_LINES="${TAIL_LINES:-200}"

usage() {
  cat <<'EOF'
Usage:
  ./openclaw_kasmvnc.sh <command> [options]

Commands:
  install      Clone/pull + configure + build/run container
  uninstall    Stop container; optional --purge removes install dir
  restart      Restart openclaw-gateway container
  upgrade      Pull latest repo and rebuild/restart container
  status       Show compose service status
  logs         Show compose logs (--tail <n>, default 200)

Options:
  --repo-url <url>       Git repo URL (default: https://github.com/openclaw/openclaw.git)
  --branch <name>        Git branch (default: main)
  --install-dir <path>   Install directory (default: $HOME/openclaw-kasmvnc)
  --gateway-token <str>  OPENCLAW_GATEWAY_TOKEN (auto-generate on install if omitted)
  --kasm-password <str>  OPENCLAW_KASMVNC_PASSWORD (auto-generate on install if omitted)
  --https-port <port>    KasmVNC HTTPS host port (default: 8443)
  --gateway-port <port>  OpenClaw gateway host port (default: 18789)
  --tail <n>             Log lines for logs command (default: 200)
  --purge                For uninstall: delete install dir
  -h, --help             Show this help
EOF
}

assert_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing command: $1" >&2
    exit 1
  fi
}

random_hex() {
  local bytes="${1:-32}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$bytes"
  else
    od -An -N "$bytes" -tx1 /dev/urandom | tr -d ' \n'
  fi
}

upsert_env_line() {
  local file="$1"
  local key="$2"
  local val="$3"
  if [[ ! -f "$file" ]]; then
    printf '%s=%s\n' "$key" "$val" >"$file"
    return
  fi
  if grep -qE "^${key}=" "$file"; then
    sed -i.bak "s|^${key}=.*$|${key}=${val}|g" "$file"
    rm -f "${file}.bak"
  else
    printf '\n%s=%s\n' "$key" "$val" >>"$file"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo-url)
        REPO_URL="${2:?missing value for --repo-url}"
        shift 2
        ;;
      --branch)
        BRANCH="${2:?missing value for --branch}"
        shift 2
        ;;
      --install-dir)
        INSTALL_DIR="${2:?missing value for --install-dir}"
        shift 2
        ;;
      --gateway-token)
        GATEWAY_TOKEN="${2:?missing value for --gateway-token}"
        shift 2
        ;;
      --kasm-password)
        KASM_PASSWORD="${2:?missing value for --kasm-password}"
        shift 2
        ;;
      --https-port)
        HTTPS_PORT="${2:?missing value for --https-port}"
        shift 2
        ;;
      --gateway-port)
        GATEWAY_PORT="${2:?missing value for --gateway-port}"
        shift 2
        ;;
      --tail)
        TAIL_LINES="${2:?missing value for --tail}"
        shift 2
        ;;
      --purge)
        PURGE=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage
        exit 1
        ;;
    esac
  done
}

compose_cmd() {
  docker compose -f docker-compose.yml -f docker-compose.kasmvnc.yml "$@"
}

repo_dir() {
  echo "$INSTALL_DIR/openclaw"
}

require_repo() {
  local d
  d="$(repo_dir)"
  if [[ ! -d "$d/.git" ]]; then
    echo "Repo not found: $d" >&2
    exit 1
  fi
}

install_cmd() {
  assert_cmd git
  assert_cmd docker
  if ! docker compose version >/dev/null 2>&1; then
    echo "Missing Docker Compose v2 plugin: 'docker compose'" >&2
    exit 1
  fi

  if [[ -z "$GATEWAY_TOKEN" ]]; then
    GATEWAY_TOKEN="$(random_hex 32)"
  fi
  if [[ -z "$KASM_PASSWORD" ]]; then
    KASM_PASSWORD="$(random_hex 16)"
  fi

  mkdir -p "$INSTALL_DIR"
  local d
  d="$(repo_dir)"
  if [[ ! -d "$d/.git" ]]; then
    git clone --branch "$BRANCH" --depth 1 "$REPO_URL" "$d"
  else
    echo "Repo exists, pulling latest: $d"
    (
      cd "$d"
      git fetch origin "$BRANCH"
      git checkout "$BRANCH"
      git pull --rebase origin "$BRANCH"
    )
  fi

  (
    cd "$d"
    if [[ ! -f .env ]]; then
      cp .env.example .env
    fi
    mkdir -p .openclaw .openclaw/workspace
    upsert_env_line .env OPENCLAW_CONFIG_DIR "./.openclaw"
    upsert_env_line .env OPENCLAW_WORKSPACE_DIR "./.openclaw/workspace"
    upsert_env_line .env OPENCLAW_GATEWAY_TOKEN "$GATEWAY_TOKEN"
    upsert_env_line .env OPENCLAW_GATEWAY_PORT "$GATEWAY_PORT"
    upsert_env_line .env OPENCLAW_KASMVNC_PASSWORD "$KASM_PASSWORD"
    upsert_env_line .env OPENCLAW_KASMVNC_HTTPS_PORT "$HTTPS_PORT"
    upsert_env_line .env TZ "Asia/Shanghai"
    upsert_env_line .env LANG "zh_CN.UTF-8"
    upsert_env_line .env LANGUAGE "zh_CN:zh"
    upsert_env_line .env LC_ALL "zh_CN.UTF-8"
    compose_cmd up -d --build openclaw-gateway
  )

  echo
  echo "Install complete."
  echo "Repo: $d"
  echo "WebChat: http://127.0.0.1:${GATEWAY_PORT}/chat?session=main"
  echo "Desktop: https://127.0.0.1:${HTTPS_PORT}"
  echo "OPENCLAW_GATEWAY_TOKEN=${GATEWAY_TOKEN}"
  echo "OPENCLAW_KASMVNC_PASSWORD=${KASM_PASSWORD}"
}

uninstall_cmd() {
  local d
  d="$(repo_dir)"
  if [[ -d "$d" ]]; then
    (
      cd "$d"
      if command -v docker >/dev/null 2>&1; then
        compose_cmd down || true
      fi
    )
    echo "Stopped services in: $d"
  else
    echo "Repo directory not found: $d"
  fi

  if [[ "$PURGE" -eq 1 ]]; then
    rm -rf "$INSTALL_DIR"
    echo "Removed install directory: $INSTALL_DIR"
  else
    echo "Uninstall completed without deleting files."
    echo "Use --purge to remove install directory."
  fi
}

restart_cmd() {
  require_repo
  (
    cd "$(repo_dir)"
    compose_cmd restart openclaw-gateway
  )
}

upgrade_cmd() {
  require_repo
  (
    cd "$(repo_dir)"
    git fetch origin "$BRANCH"
    git checkout "$BRANCH"
    git pull --rebase origin "$BRANCH"
    compose_cmd up -d --build openclaw-gateway
  )
}

status_cmd() {
  require_repo
  (
    cd "$(repo_dir)"
    compose_cmd ps
  )
}

logs_cmd() {
  require_repo
  (
    cd "$(repo_dir)"
    compose_cmd logs --tail="$TAIL_LINES" openclaw-gateway
  )
}

parse_args "$@"

case "$COMMAND" in
  install) install_cmd ;;
  uninstall) uninstall_cmd ;;
  restart) restart_cmd ;;
  upgrade) upgrade_cmd ;;
  status) status_cmd ;;
  logs) logs_cmd ;;
  -h|--help|help) usage ;;
  *)
    echo "Unknown command: $COMMAND" >&2
    usage
    exit 1
    ;;
esac
