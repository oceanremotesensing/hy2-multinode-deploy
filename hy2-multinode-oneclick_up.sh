#!/usr/bin/env bash
# hy2-multinode-merged-qr.sh
# Hysteria v2 部署：Hex密码 + 所有节点合并为一个二维码

# 颜色定义
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# 全局变量
HY_DIR="/etc/hysteria2"
HY_BIN="/usr/local/bin/hysteria"
LOGDIR="${HY_DIR}/logs"
CERT="${HY_DIR}/cert.pem"
KEY="${HY_DIR}/key.pem"
MAX_RETRIES=20

# 检查 Root
if [ "$(id -u)" -ne 0 ]; then echo -e "${RED}请以 root 用户运行${NC}"; exit 1; fi

# 架构检测
ARCH=$(uname -m)
case $ARCH in
  x86_64|amd64) HY_ARCH="amd64" ;;
  aarch64|arm64) HY_ARCH="arm64" ;;
  *) echo -e "${RED}不支持架构${NC}"; exit 1 ;;
esac

# 卸载功能
uninstall() {
  echo -e "${YELLOW}正在卸载...${NC}"
  systemctl list-units --type=service --all | grep 'hy2-.*\.service' | awk '{print $1}' | xargs -r systemctl stop
  systemctl list-units --type=service --all | grep 'hy2-.*\.service' | awk '{print $1}' | xargs -r systemctl disable
  rm -f /etc/systemd/system/hy2-*.service "${HY_BIN}"; rm -rf "${HY_DIR}"
  systemctl daemon-reload; pkill -f "${HY_BIN}" || true
  echo -e "${GREEN}卸载完成${NC}"; exit 0
}
[ "$1" = "uninstall" ] && uninstall

# 安装依赖 (必须包含 qrencode)
install_dependencies() {
  echo -e "${BLUE}安装依赖 (含 qrencode)...${NC}"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y curl jq openssl ca-certificates qrencode
  elif command -v yum >/dev/null 2>&1; then
    yum install -y epel-release && yum install -y curl jq openssl ca-certificates qrencode
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl jq openssl ca-certificates qrencode
  fi
  
  if ! command -v qrencode >/dev/null 2>&1; then
      echo -e "${RED}错误: qrencode 安装失败，无法生成二维码。${NC}"
      exit 1
  fi
}

mkdir -p "${HY_DIR}" "${LOGDIR}"; install_dependencies

# 获取 IP
PUBLIC_IP=$(curl -s4m8 https://api.ipify.org || curl -s4m8 https://ifconfig.me || hostname -I | awk '{print $1}')
[ -z "$PUBLIC_IP" ] && echo -e "${RED}无法获取 IP${NC}" && exit 1

# 下载 Hysteria
if [ ! -f "${HY_BIN}" ]; then
  echo -e "${YELLOW}下载 Hysteria 2...${NC}"
  curl -L -f -o "${HY_BIN}" "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}" || \
  curl -L -f -o "${HY_BIN}" "https://ghproxy.net/https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
  chmod +x "${HY_BIN}"
fi

# 生成证书
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
rm -f /etc/systemd/system/hy2-*.service; systemctl daemon-reload

echo -e "${BLUE}开始部署...${NC}"

# 用于存储所有链接的变量
ALL_LINKS_TEXT=""

for i in $(seq 1 "$NUM_INSTANCES"); do
  # 找端口
  for ((r=0; r<MAX_RETRIES; r++)); do
    PORT=$((RANDOM % 40000 + 20000))
    if ! ss -tuln | grep -q ":${PORT} "; then break; fi
  done

  # 生成 Hex 密码
  PASSWORD=$(openssl rand -hex 16)
  OBFS_PASSWORD=$(openssl rand -hex 8)
  
  # 写配置
  CFG_FILE="${HY_DIR}/config${i}.yaml"
  cat > "${CFG_FILE}" <<EOF
listen: :${PORT}
tls: { cert: ${CERT}, key: ${KEY} }
auth: { type: password, password: "${PASSWORD}" }
obfs: { type: salamander, salamander: { password: "${OBFS_PASSWORD}" } }
masquerade: { type: proxy, proxy: { url: https://www.bing.com/, rewriteHost: true } }
EOF

  # 写服务
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

  # 启动
  systemctl enable --now "hy2-${i}" >/dev/null 2>&1
  
  # 生成链接并追加到变量中
  CURRENT_LINK="hy2://${PASSWORD}@${PUBLIC_IP}:${PORT}/?insecure=1&obfs=salamander&obfs-password=${OBFS_PASSWORD}&sni=${PUBLIC_IP}#Node-${i}"
  ALL_LINKS_TEXT+="${CURRENT_LINK}\n"
  
  echo -e "节点 $i: ${GREEN}OK${NC} (端口 $PORT)"
done

# 去掉最后一个换行符
ALL_LINKS_TEXT=$(echo -e "$ALL_LINKS_TEXT" | sed '$d')

echo -e "\n${BLUE}================ 批量复制区域 (推荐) ==============${NC}"
echo -e "${YELLOW}请复制下方所有内容，在 v2rayN 中选择 '从剪贴板导入批量URL'${NC}"
echo -e "---------------------------------------------------"
echo -e "$ALL_LINKS_TEXT"
echo -e "---------------------------------------------------"

echo -e "\n${BLUE}================ 聚合二维码 (All-in-One) ==============${NC}"
echo -e "${YELLOW}注意：包含 $NUM_INSTANCES 个节点的二维码非常密集。${NC}"
echo -e "${YELLOW}如果终端显示不全，请缩小字体或最大化窗口，建议使用上面的文本导入。${NC}"
echo -e "${YELLOW}v2rayN 电脑端截图扫描成功率较高，手机端可能无法识别多行数据。${NC}"
echo ""

# 生成包含所有链接的二维码
qrencode -t ANSIUTF8 "$ALL_LINKS_TEXT"

echo ""
echo -e "${BLUE}======================================================${NC}"
