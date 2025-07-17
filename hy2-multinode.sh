#!/bin/bash
set -e

# ========= 配色 =========
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m'

info() { echo -e "${GREEN}[✔] $1${NC}"; }
warn() { echo -e "${YELLOW}[!] $1${NC}"; }
error() { echo -e "${RED}[✘] $1${NC}"; exit 1; }

# ========= 默认参数 =========
DEFAULT_NODE_COUNT=10
DEFAULT_REALITY_NODE_COUNT=5
DEFAULT_PORT_RANGE_START=20000
DEFAULT_PORT_RANGE_END=60000
DEFAULT_PASSWORD_PREFIX="PwdHy2_"
DEFAULT_HYSTERIA_BIN="/usr/local/bin/hysteria"
DEFAULT_WORK_DIR="/etc/hysteria2"
DEFAULT_REALITY_DOMAINS=("www.bing.com" "www.apple.com" "www.google.com" "www.cloudflare.com" "www.microsoft.com")
DEFAULT_OUTPUT_JSON="output.json"
CLEAN_MODE=0

# ========= 参数解析 =========
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -n) NODE_COUNT="$2"; shift ;;
    -r) REALITY_NODE_COUNT="$2"; shift ;;
    -s) PORT_RANGE_START="$2"; shift ;;
    -e) PORT_RANGE_END="$2"; shift ;;
    -p) PASSWORD_PREFIX="$2"; shift ;;
    --clean) CLEAN_MODE=1 ;;
    *) warn "未知参数: $1"; exit 1 ;;
  esac
  shift
done

# 使用默认值如果未提供
NODE_COUNT=${NODE_COUNT:-$DEFAULT_NODE_COUNT}
REALITY_NODE_COUNT=${REALITY_NODE_COUNT:-$DEFAULT_REALITY_NODE_COUNT}
PORT_RANGE_START=${PORT_RANGE_START:-$DEFAULT_PORT_RANGE_START}
PORT_RANGE_END=${PORT_RANGE_END:-$DEFAULT_PORT_RANGE_END}
PASSWORD_PREFIX=${PASSWORD_PREFIX:-$DEFAULT_PASSWORD_PREFIX}
HYSTERIA_BIN=${HYSTERIA_BIN:-$DEFAULT_HYSTERIA_BIN}
WORK_DIR=${WORK_DIR:-$DEFAULT_WORK_DIR}
REALITY_DOMAINS=("${REALITY_DOMAINS[@]:-${DEFAULT_REALITY_DOMAINS[@]}}")
OUTPUT_JSON=${OUTPUT_JSON:-$DEFAULT_OUTPUT_JSON}

# ========= 卸载模式 =========
cleanup() {
  info "🧹 开始清理 Hysteria..."
  systemctl disable --now $(systemctl list-units | grep hy2- | awk '{print $1}') 2>/dev/null || true
  rm -f /etc/systemd/system/hy2-*.service
  rm -rf "$WORK_DIR"
  rm -f "$HYSTERIA_BIN"
  systemctl daemon-reexec
  systemctl daemon-reload
  info "✅ 所有 Hysteria 节点及配置已清除"
}

# ========= 依赖检测 =========
install_deps() {
  info "🔧 安装依赖..."
  apt update
  apt install -y curl socat openssl jq > /dev/null
}

# ========= 安装 hysteria =========
install_hysteria() {
  info "📥 安装 hysteria..."
  pkill -f hysteria || true
  curl -Lo "$HYSTERIA_BIN" https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-amd64
  chmod +x "$HYSTERIA_BIN"
}

# ========= 初始化目录、证书、密钥 =========
init_dirs_and_keys() {
  mkdir -p "$WORK_DIR"
  cd "$WORK_DIR" || exit 1

  if (( NODE_COUNT > 0 )) && [[ ! -f cert.pem || ! -f key.pem ]]; then
    info "🔐 生成 TLS 证书..."
    openssl req -x509 -newkey rsa:2048 -days 3650 -nodes -keyout key.pem -out cert.pem -subj "/CN=localhost"
  fi

  if (( REALITY_NODE_COUNT > 0 )) && [[ ! -f reality.key || ! -f reality.pub ]]; then
    info "🔐 生成 Reality 密钥..."
    "$HYSTERIA_BIN" keygen --ecdsa > reality.key
    "$HYSTERIA_BIN" keygen --ecdsa --pub-only < reality.key > reality.pub
  fi
}

# ========= 生成端口 =========
declare -A USED_PORTS
get_random_port() {
  local p
  while true; do
    p=$((RANDOM % (PORT_RANGE_END - PORT_RANGE_START + 1) + PORT_RANGE_START))
    if ! (ss -tuln | grep -q ":$p ") || [[ -n "${USED_PORTS[$p]}" ]]; then
      USED_PORTS[$p]=1
      echo "$p"
      return
    fi
  done
}

# ========= 密码节点配置 =========
PASSWORDS=()
PWD_PORTS=()
generate_password_nodes() {
  for ((i=1; i<=NODE_COUNT; i++)); do
    pass="${PASSWORD_PREFIX}${i}_$(tr -dc A-Za-z0-9 </dev/urandom | head -c 8)"
    port=$(get_random_port)
    PASSWORDS+=("$pass")
    PWD_PORTS+=("$port")

    # Write configuration
    cat > "$WORK_DIR/config-pwd-$i.yaml" <<EOF
listen: ":${port}"
auth:
  type: password
  password: ${pass}
tls:
  cert: $WORK_DIR/cert.pem
  key: $WORK_DIR/key.pem
obfuscate:
  type: srtp
EOF

    # Create systemd service unit
    cat > /etc/systemd/system/hy2-pwd-$i.service <<EOF
[Unit]
Description=Hysteria Password Node $i
After=network.target
[Service]
ExecStart=$HYSTERIA_BIN server -c $WORK_DIR/config-pwd-$i.yaml
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
  done
}

# ========= Reality 节点 =========
REALITY_PORTS=()
REALITY_LINKS=()
generate_reality_nodes() {
  local pub_key_base64=$(cat "$WORK_DIR/reality.pub")
  for ((i=1; i<=REALITY_NODE_COUNT; i++)); do
    port=$(get_random_port)
    domain=${REALITY_DOMAINS[$RANDOM % ${#REALITY_DOMAINS[@]}]}
    REALITY_PORTS+=("$port")

    # Write configuration
    cat > "$WORK_DIR/config-reality-$i.yaml" <<EOF
listen: ":${port}"
reality:
  privateKey: $WORK_DIR/reality.key
  publicKey: $WORK_DIR/reality.pub
  underlying: ${domain}:443
EOF

    # Create systemd service unit
    cat > /etc/systemd/system/hy2-reality-$i.service <<EOF
[Unit]
Description=Hysteria Reality Node $i
After=network.target
[Service]
ExecStart=$HYSTERIA_BIN server -c $WORK_DIR/config-reality-$i.yaml
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
  done
}

# ========= 启动所有服务 =========
start_all_services() {
  systemctl daemon-reload
  for ((i=1; i<=NODE_COUNT; i++)); do
    systemctl enable --now hy2-pwd-$i
  done
  for ((i=1; i<=REALITY_NODE_COUNT; i++)); do
    systemctl enable --now hy2-reality-$i
  done
}

# ========= 输出链接 =========
generate_output() {
  local IP=$(curl -s https://api.ipify.org)
  echo -e "\n${BLUE}===== 📎 节点连接信息 =====${NC}"

  echo '{' > "$OUTPUT_JSON"
  echo '  "password_nodes": [' >> "$OUTPUT_JSON"
  for ((i=0; i<NODE_COUNT; i++)); do
    link="hy2://${PASSWORDS[$i]}@$IP:${PWD_PORTS[$i]}?insecure=1#PwdNode_$((i+1))"
    echo "$link"
    echo "    {\"port\": ${PWD_PORTS[$i]}, \"password\": \"${PASSWORDS[$i]}\", \"link\": \"$link\"}," >> "$OUTPUT_JSON"
  done
  echo '  ],' >> "$OUTPUT_JSON"

  local PUB=$(cat "$WORK_DIR/reality.pub")
  echo '  "reality_nodes": [' >> "$OUTPUT_JSON"
  for ((i=0; i<REALITY_NODE_COUNT; i++)); do
    domain=$(grep "underlying:" "$WORK_DIR/config-reality-$((i+1)).yaml" | awk -F ' ' '{print $2}' | cut -d':' -f1)
    link="hy2://${IP}:${REALITY_PORTS[$i]}?sni=${domain}&reality-key=${PUB}#RealityNode_$((i+1))"
    echo "$link"
    echo "    {\"port\": ${REALITY_PORTS[$i]}, \"sni\": \"$domain\", \"reality_key\": \"$PUB\", \"link\": \"$link\"}," >> "$OUTPUT_JSON"
  done
  echo '  ]' >> "$OUTPUT_JSON"
  echo '}' >> "$OUTPUT_JSON"
  echo -e "\n✅ 所有节点链接信息已保存在 ${YELLOW}${OUTPUT_JSON}${NC}"
}

# ========= 主程序 =========
main() {
  (( NODE_COUNT < 0 || NODE_COUNT > 100 )) && error "密码节点数量建议在 0~100 之间"
  (( REALITY_NODE_COUNT < 0 || REALITY_NODE_COUNT > 100 )) && error "Reality 节点数量建议在 0~100 之间"
  (( PORT_RANGE_START < 1024 || PORT_RANGE_END > 65535 || PORT_RANGE_START >= PORT_RANGE_END )) && \
    error "端口范围不合法，必须在 1024~65535 之间，并且起始小于结束"

  if [[ "$CLEAN_MODE" == 1 ]]; then
    cleanup
    exit 0
  fi

  install_deps
  install_hysteria
  init_dirs_and_keys
  generate_password_nodes
  generate_reality_nodes
  start_all_services
  generate_output
}

main
