#!/usr/bin/env bash
# hy2-multinode-final-fix.sh
# Hysteria v2 最终修复版：使用纯十六进制密码，彻底解决导入失败问题

# 颜色定义
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# 全局变量
HY_DIR="/etc/hysteria2"
HY_BIN="/usr/local/bin/hysteria"
LOGDIR="${HY_DIR}/logs"
CERT="${HY_DIR}/cert.pem"
KEY="${HY_DIR}/key.pem"
MAX_RETRIES=20

# 检查 Root 权限
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}错误: 请以 root 用户运行此脚本${NC}"
  exit 1
fi

# 架构检测
ARCH=$(uname -m)
case $ARCH in
  x86_64|amd64) HY_ARCH="amd64" ;;
  aarch64|arm64) HY_ARCH="arm64" ;;
  *) echo -e "${RED}不支持的架构: $ARCH${NC}"; exit 1 ;;
esac

# 卸载功能
uninstall() {
  echo -e "${YELLOW}正在卸载 Hysteria 2...${NC}"
  systemctl list-units --type=service --all | grep 'hy2-.*\.service' | awk '{print $1}' | xargs -r systemctl stop
  systemctl list-units --type=service --all | grep 'hy2-.*\.service' | awk '{print $1}' | xargs -r systemctl disable
  rm -f /etc/systemd/system/hy2-*.service
  rm -f "${HY_BIN}"
  rm -rf "${HY_DIR}"
  systemctl daemon-reload
  pkill -f "${HY_BIN}" >/dev/null 2>&1 || true
  echo -e "${GREEN}✅ 卸载完成${NC}"
  exit 0
}

[ "$1" = "uninstall" ] && uninstall

# 依赖安装
install_dependencies() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y curl jq openssl ca-certificates
  elif command -v yum >/dev/null 2>&1; then
    yum install -y epel-release && yum install -y curl jq openssl ca-certificates
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl jq openssl ca-certificates
  fi
}

echo -e "${BLUE}==== Hysteria v2 多节点部署 (Hex密码修复版) ====${NC}"

mkdir -p "${HY_DIR}" "${LOGDIR}"
install_dependencies

# 获取 IP
PUBLIC_IP=$(curl -s4m8 https://api.ipify.org || curl -s4m8 https://ifconfig.me || hostname -I | awk '{print $1}')
[ -z "$PUBLIC_IP" ] && echo -e "${RED}无法获取 IP${NC}" && exit 1

# 下载核心
if [ ! -f "${HY_BIN}" ]; then
  echo -e "${YELLOW}下载 Hysteria 2...${NC}"
  curl -L -f -o "${HY_BIN}" "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}" || \
  curl -L -f -o "${HY_BIN}" "https://ghproxy.net/https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
  chmod +x "${HY_BIN}"
fi
[ ! -x "${HY_BIN}" ] && echo -e "${RED}下载失败${NC}" && exit 1

# 证书
if [ ! -f "${CERT}" ]; then
  openssl req -x509 -newkey rsa:2048 -keyout "${KEY}" -out "${CERT}" -days 3650 -nodes -subj "/CN=${PUBLIC_IP}" >/dev/null 2>&1
  chmod 644 "${CERT}" && chmod 600 "${KEY}"
fi

# 输入数量
read -p "请输入节点数量 (默认 5): " USER_NUM
NUM_INSTANCES=${USER_NUM:-5}
[[ ! "$NUM_INSTANCES" =~ ^[0-9]+$ ]] && NUM_INSTANCES=5

# 清理旧服务
systemctl list-units --type=service --all | grep 'hy2-.*\.service' | awk '{print $1}' | xargs -r systemctl stop
rm -f /etc/systemd/system/hy2-*.service
systemctl daemon-reload

declare -A NODE_INFO
echo -e "${BLUE}正在生成节点 (使用纯 Hex 密码，确保 100% 导入成功)...${NC}"

for i in $(seq 1 "$NUM_INSTANCES"); do
  # 端口重试
  for ((r=0; r<MAX_RETRIES; r++)); do
    PORT=$((RANDOM % 40000 + 20000))
    if ! ss -tuln | grep -q ":${PORT} "; then break; fi
  done

  # 关键修改：使用 -hex 代替 -base64
  PASSWORD=$(openssl rand -hex 16)
  OBFS_PASSWORD=$(openssl rand -hex 8)
  CFG_FILE="${HY_DIR}/config${i}.yaml"
  
  # 配置文件
  cat > "${CFG_FILE}" <<EOF
listen: :${PORT}
tls:
  cert: ${CERT}
  key: ${KEY}
auth:
  type: password
  password: "${PASSWORD}"
obfs:
  type: salamander
  salamander:
    password: "${OBFS_PASSWORD}"
masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com/
    rewriteHost: true
EOF

  # Systemd 服务
  SERVICE_FILE="/etc/systemd/system/hy2-${i}.service"
  cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Hysteria v2 Node ${i}
After=network.target
[Service]
Type=simple
ExecStart=${HY_BIN} server -c ${CFG_FILE}
WorkingDirectory=${HY_DIR}
Restart=always
RestartSec=5
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
EOF

  systemctl enable --now "hy2-${i}" >/dev/null 2>&1
  sleep 0.5
  
  if systemctl is-active --quiet "hy2-${i}"; then
     # 生成链接
     NODE_INFO[$i]="hy2://${PASSWORD}@${PUBLIC_IP}:${PORT}/?insecure=1&obfs=salamander&obfs-password=${OBFS_PASSWORD}&sni=${PUBLIC_IP}#Node-${i}"
     echo -e "节点 $i: ${GREEN}成功${NC} (Port: $PORT)"
  else
     echo -e "节点 $i: ${RED}失败${NC}"
  fi
done

echo -e "\n${BLUE}================ 节点链接 (Hex 密码版) ==============${NC}"
for i in $(seq 1 "$NUM_INSTANCES"); do
  [ -n "${NODE_INFO[$i]}" ] && echo -e "${NODE_INFO[$i]}\n"
done
echo -e "${YELLOW}现在所有链接都可以直接复制到 v2rayN 了！${NC}"
