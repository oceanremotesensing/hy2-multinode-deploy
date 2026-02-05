#!/usr/bin/env bash
# hy2-multinode-auto-unlock.sh
# 终极版：自带解锁apt + Hex密码 + 聚合二维码

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
HY_DIR="/etc/hysteria2"; HY_BIN="/usr/local/bin/hysteria"
LOGDIR="${HY_DIR}/logs"; CERT="${HY_DIR}/cert.pem"; KEY="${HY_DIR}/key.pem"
MAX_RETRIES=20

if [ "$(id -u)" -ne 0 ]; then echo -e "${RED}请以 root 用户运行${NC}"; exit 1; fi

# === 关键新增：自动释放 apt 锁 ===
fix_apt_lock() {
    # 杀掉后台自动更新进程
    if pgrep -f "unattended-upgr" >/dev/null; then
        echo -e "${YELLOW}检测到系统自动更新占用了锁，正在强制停止...${NC}"
        systemctl stop unattended-upgrades >/dev/null 2>&1
        pkill -9 -f "unattended-upgr"
    fi
    
    # 杀掉apt进程
    if pgrep -f "apt" >/dev/null || pgrep -f "dpkg" >/dev/null; then
        echo -e "${YELLOW}检测到 apt/dpkg 进程卡死，正在清理...${NC}"
        pkill -9 -f "apt"
        pkill -9 -f "dpkg"
    fi

    # 删除锁文件
    rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock
    dpkg --configure -a >/dev/null 2>&1
    echo -e "${GREEN}锁已释放，继续安装...${NC}"
    sleep 1
}

ARCH=$(uname -m)
case $ARCH in x86_64|amd64) HY_ARCH="amd64";; aarch64|arm64) HY_ARCH="arm64";; *) echo -e "${RED}不支持架构${NC}"; exit 1;; esac

uninstall() {
  echo -e "${YELLOW}正在卸载...${NC}"
  systemctl list-units --type=service --all | grep 'hy2-.*\.service' | awk '{print $1}' | xargs -r systemctl stop
  systemctl list-units --type=service --all | grep 'hy2-.*\.service' | awk '{print $1}' | xargs -r systemctl disable
  rm -f /etc/systemd/system/hy2-*.service "${HY_BIN}"; rm -rf "${HY_DIR}"
  systemctl daemon-reload; pkill -f "${HY_BIN}" || true
  echo -e "${GREEN}卸载完成${NC}"; exit 0
}
[ "$1" = "uninstall" ] && uninstall

install_dependencies() {
  fix_apt_lock # 先尝试解锁
  
  echo -e "${BLUE}安装依赖 (含 qrencode)...${NC}"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y curl jq openssl ca-certificates qrencode
  elif command -v yum >/dev/null 2>&1; then
    yum install -y epel-release && yum install -y curl jq openssl ca-certificates qrencode
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl jq openssl ca-certificates qrencode
  fi

  if ! command -v qrencode >/dev/null 2>&1; then
      echo -e "${RED}qrencode 安装失败，将跳过二维码生成，仅显示文本链接。${NC}"
  fi
}

mkdir -p "${HY_DIR}" "${LOGDIR}"; install_dependencies

PUBLIC_IP=$(curl -s4m8 https://api.ipify.org || curl -s4m8 https://ifconfig.me || hostname -I | awk '{print $1}')
[ -z "$PUBLIC_IP" ] && echo -e "${RED}无法获取 IP${NC}" && exit 1

if [ ! -f "${HY_BIN}" ]; then
  echo -e "${YELLOW}下载 Hysteria 2...${NC}"
  curl -L -f -o "${HY_BIN}" "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}" || \
  curl -L -f -o "${HY_BIN}" "https://ghproxy.net/https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
  chmod +x "${HY_BIN}"
fi

if [ ! -f "${CERT}" ]; then
  openssl req -x509 -newkey rsa:2048 -keyout "${KEY}" -out "${CERT}" -days 3650 -nodes -subj "/CN=${PUBLIC_IP}" >/dev/null 2>&1
  chmod 644 "${CERT}" && chmod 600 "${KEY}"
fi

read -p "请输入节点数量 (默认 5): " USER_NUM
NUM_INSTANCES=${USER_NUM:-5}
[[ ! "$NUM_INSTANCES" =~ ^[0-9]+$ ]] && NUM_INSTANCES=5

systemctl list-units --type=service --all | grep 'hy2-.*\.service' | awk '{print $1}' | xargs -r systemctl stop
rm -f /etc/systemd/system/hy2-*.service; systemctl daemon-reload

echo -e "${BLUE}开始部署...${NC}"
ALL_LINKS_TEXT=""

for i in $(seq 1 "$NUM_INSTANCES"); do
  for ((r=0; r<MAX_RETRIES; r++)); do
    PORT=$((RANDOM % 40000 + 20000))
    if ! ss -tuln | grep -q ":${PORT} "; then break; fi
  done

  PASSWORD=$(openssl rand -hex 16)
  OBFS_PASSWORD=$(openssl rand -hex 8)
  
  CFG_FILE="${HY_DIR}/config${i}.yaml"
  cat > "${CFG_FILE}" <<EOF
listen: :${PORT}
tls: { cert: ${CERT}, key: ${KEY} }
auth: { type: password, password: "${PASSWORD}" }
obfs: { type: salamander, salamander: { password: "${OBFS_PASSWORD}" } }
masquerade: { type: proxy, proxy: { url: https://www.bing.com/, rewriteHost: true } }
EOF

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
  
  CURRENT_LINK="hy2://${PASSWORD}@${PUBLIC_IP}:${PORT}/?insecure=1&obfs=salamander&obfs-password=${OBFS_PASSWORD}&sni=${PUBLIC_IP}#Node-${i}"
  ALL_LINKS_TEXT+="${CURRENT_LINK}\n"
  
  echo -e "节点 $i: ${GREEN}OK${NC} (端口 $PORT)"
done

ALL_LINKS_TEXT=$(echo -e "$ALL_LINKS_TEXT" | sed '$d')

echo -e "\n${BLUE}================ 批量链接文本 (推荐) ==============${NC}"
echo -e "$ALL_LINKS_TEXT"

if command -v qrencode >/dev/null 2>&1; then
  echo -e "\n${BLUE}================ 聚合二维码 (All-in-One) ==============${NC}"
  echo -e "${YELLOW}提示: 如果二维码过大导致乱码，请缩小终端字体或使用上方文本。${NC}"
  qrencode -t ANSIUTF8 "$ALL_LINKS_TEXT"
else
  echo -e "\n${RED}警告: qrencode 未安装，无法显示二维码，请使用上方文本。${NC}"
fi
echo -e "${BLUE}======================================================${NC}"
