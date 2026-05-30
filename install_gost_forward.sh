#!/usr/bin/env bash
set -Eeuo pipefail

# GOST TCP/UDP 端口转发一键安装脚本
# 默认规则：
#   SSH:       10002-10099  -> 10.0.0.2-10.0.0.99:22
#   TCP 业务:  20020-20999  -> 10.0.0.2-10.0.0.99:20020-20999
#   UDP 业务:  20020-20999  -> 10.0.0.2-10.0.0.99:20020-20999

GOST_DIR="${GOST_DIR:-/root/gost}"
GOST_BIN="${GOST_BIN:-$GOST_DIR/gost}"
START_SCRIPT="${START_SCRIPT:-$GOST_DIR/start.sh}"
SERVICE_FILE="${SERVICE_FILE:-/etc/systemd/system/gost-forward.service}"

IP_PREFIX="${IP_PREFIX:-10.0.0}"
IP_START="${IP_START:-2}"
IP_END="${IP_END:-99}"
SSH_BASE_PORT="${SSH_BASE_PORT:-10000}"
BUSINESS_BASE_PORT="${BUSINESS_BASE_PORT:-20000}"
PORTS_PER_IP="${PORTS_PER_IP:-10}"
ENABLE_UDP="${ENABLE_UDP:-1}"

LOG_RATE_INTERVAL="${LOG_RATE_INTERVAL:-30s}"
LOG_RATE_BURST="${LOG_RATE_BURST:-500}"

need_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "请用 root 运行：sudo $0" >&2
    exit 1
  fi
}

install_deps() {
  local packages=(curl tar gzip ca-certificates grep sed coreutils)
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y "${packages[@]}" findutils
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "${packages[@]}" findutils
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}" findutils
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache "${packages[@]}" findutils
  else
    echo "未识别包管理器，请先安装：curl tar gzip ca-certificates findutils grep sed coreutils" >&2
    exit 1
  fi
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7) echo "armv7" ;;
    *) echo "不支持的 CPU 架构：$(uname -m)" >&2; exit 1 ;;
  esac
}

download_gost() {
  local arch asset_url tmpdir found
  arch="$(detect_arch)"
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT

  echo "正在获取 GOST 最新版本下载地址（linux/$arch）..."
  asset_url="$(
    curl -fsSL https://api.github.com/repos/go-gost/gost/releases/latest \
      | grep -Eo '"browser_download_url": *"[^"]+"' \
      | sed -E 's/.*"(https:[^"]+)".*/\1/' \
      | grep -Ei 'linux.*'"$arch"'.*\.tar\.gz$' \
      | head -n 1
  )"

  if [ -z "$asset_url" ]; then
    echo "找不到匹配的 GOST linux/$arch tar.gz 发布包。" >&2
    exit 1
  fi

  echo "下载：$asset_url"
  curl -fL "$asset_url" -o "$tmpdir/gost.tar.gz"
  tar -xzf "$tmpdir/gost.tar.gz" -C "$tmpdir"
  mkdir -p "$GOST_DIR"

  found="$(find "$tmpdir" -type f -name gost -perm /111 | head -n 1 || true)"
  if [ -z "$found" ]; then
    found="$(find "$tmpdir" -type f -name gost | head -n 1 || true)"
  fi
  if [ -z "$found" ]; then
    echo "压缩包中没有找到 gost 二进制文件。" >&2
    exit 1
  fi

  install -m 0755 "$found" "$GOST_BIN"
  "$GOST_BIN" -V || true
}

validate_config() {
  if [ "$IP_START" -lt 1 ] || [ "$IP_END" -gt 254 ] || [ "$IP_START" -gt "$IP_END" ]; then
    echo "IP_START/IP_END 不合法：$IP_START-$IP_END" >&2
    exit 1
  fi

  local ip offset start_port end_port ssh_port
  for ip in $(seq "$IP_START" "$IP_END"); do
    offset=$((ip - IP_START))
    ssh_port=$((SSH_BASE_PORT + ip))
    start_port=$((BUSINESS_BASE_PORT + offset * PORTS_PER_IP + 20))
    end_port=$((start_port + PORTS_PER_IP - 1))
    if [ "$ssh_port" -gt 65535 ] || [ "$end_port" -gt 65535 ]; then
      echo "端口超过 65535：IP=$ip SSH=$ssh_port PORT=$start_port-$end_port" >&2
      exit 1
    fi
  done
}

write_start_script() {
  mkdir -p "$GOST_DIR"
  cat > "$START_SCRIPT" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

GOST_BIN="$GOST_BIN"
IP_PREFIX="$IP_PREFIX"
IP_START="$IP_START"
IP_END="$IP_END"
SSH_BASE_PORT="$SSH_BASE_PORT"
BUSINESS_BASE_PORT="$BUSINESS_BASE_PORT"
PORTS_PER_IP="$PORTS_PER_IP"
ENABLE_UDP="$ENABLE_UDP"

args=()

for ip in \$(seq "\$IP_START" "\$IP_END"); do
  target_ip="\$IP_PREFIX.\$ip"
  ssh_port=\$((SSH_BASE_PORT + ip))
  args+=("-L" "tcp://:\${ssh_port}/\${target_ip}:22")
done

for ip in \$(seq "\$IP_START" "\$IP_END"); do
  target_ip="\$IP_PREFIX.\$ip"
  offset=\$((ip - IP_START))
  start_port=\$((BUSINESS_BASE_PORT + offset * PORTS_PER_IP + 20))
  end_port=\$((start_port + PORTS_PER_IP - 1))

  for port in \$(seq "\$start_port" "\$end_port"); do
    args+=("-L" "tcp://:\${port}/\${target_ip}:\${port}")
    if [ "\$ENABLE_UDP" = "1" ]; then
      args+=("-L" "udp://:\${port}/\${target_ip}:\${port}")
    fi
  done
done

exec "\$GOST_BIN" "\${args[@]}"
EOF
  chmod +x "$START_SCRIPT"
}

write_service() {
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=GOST TCP/UDP Port Forwarder
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$START_SCRIPT
Restart=always
RestartSec=3
LimitNOFILE=1048576
LogRateLimitIntervalSec=$LOG_RATE_INTERVAL
LogRateLimitBurst=$LOG_RATE_BURST

[Install]
WantedBy=multi-user.target
EOF
}

print_summary() {
  echo
  echo "安装完成。转发规则："
  echo "- SSH: ${SSH_BASE_PORT}+IP末位，例如 10002 -> ${IP_PREFIX}.2:22，10099 -> ${IP_PREFIX}.99:22"
  echo "- 业务端口: 每个 IP 10 个端口，例如 20020-20029 -> ${IP_PREFIX}.2，20990-20999 -> ${IP_PREFIX}.99"
  echo "- UDP 转发: $([ "$ENABLE_UDP" = "1" ] && echo '已启用' || echo '未启用')"
  echo "- 日志限流: ${LOG_RATE_INTERVAL} / ${LOG_RATE_BURST} 条"
  echo
  echo "常用命令："
  echo "  systemctl status gost-forward --no-pager"
  echo "  journalctl -u gost-forward -n 100 --no-pager"
  echo "  systemctl restart gost-forward"
}

main() {
  need_root
  install_deps
  download_gost
  validate_config
  write_start_script
  write_service
  systemctl daemon-reload
  systemctl enable gost-forward
  systemctl restart gost-forward
  print_summary
}

main "$@"
