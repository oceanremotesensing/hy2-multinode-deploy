#!/usr/bin/env bash
# hy2-multinode-auto-unlock.sh
# 终极优化版：安全解锁apt + 内核UDP调优 + 伪装对齐 + 聚合二维码

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
HY_DIR="/etc/hysteria2"; HY_BIN="/usr/local/bin/hysteria"
CERT="${HY_DIR}/cert.pem"; KEY="${HY_DIR}/key.pem"; LINKS_FILE="${HY_DIR}/links.txt"
MASQ_DOMAIN="www.bing.com"

if [ "$(id -u)" -ne 0 ]; then echo -e "${RED}请以 root 用户运行${NC}"; exit 1; fi

# === 自动安全释放 apt 锁 ===
fix_apt_lock() {
    command -v apt-get >/dev/null 2>&1 || return 0
    if pgrep -f "unattended-upgr" >/dev/null; then
        echo -e "${YELLOW}检测到系统自动更新占用了锁，正在强制停止...${NC}"
        systemctl stop unattended-upgrades >/dev/null 2>&1
        pkill -9 -f "unattended-upgr" >/dev/null 2>&1
    fi
    
    if pgrep -x "apt|apt-get|dpkg" >/dev/null; then
        echo -e "${YELLOW}检测到 apt/dpkg 进程卡死，正在清理...${NC}"
        killall -9 apt apt-get dpkg >/dev/null 2>&1
    fi

    rm -f /var/lib/dpkg/lock* /var/lib/apt/lists/lock /var/cache/apt/archives/lock
    dpkg --configure -a >/dev/null 2>&1
}

ARCH=$(uname -m)
case $ARCH in 
    x86_64|amd64) HY_ARCH="amd64";; 
    aarch64|arm64) HY_ARCH="arm64";; 
    *) echo -e "${RED}不支持的架构: ${ARCH}${NC}"; exit 1;; 
esac

uninstall() {
  echo -e "${YELLOW}正在卸载 Hysteria 2 多节点...${NC}"
  systemctl stop "hy2-*.service" >/dev/null 2>&1 || true
  systemctl disable "hy2-*.service" >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/hy2-*.service "${HY_BIN}"
  rm -rf "${HY_DIR}"
  systemctl daemon-reload
  pkill -x "hysteria" >/dev/null 2>&1 || true
  echo -e "${GREEN}卸载完成${NC}"; exit 0
}
[ "$1" = "uninstall" ] && uninstall

install_dependencies() {
  fix_apt_lock
  echo -e "${BLUE}正在检查并安装依赖...${NC}"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1 && apt-get install -y curl openssl ca-certificates qrencode psmisc iproute2 >/dev/null 2>&1
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl openssl ca-certificates qrencode psmisc iproute >/dev/null 2>&1
  elif command -v yum >/dev/null 2>&1; then
    yum install -y epel-release >/dev/null 2>&1 && yum install -y curl openssl ca-certificates qrencode psmisc iproute >/dev/null 2>&1
  fi
}

optimize_udp() {
  # Hysteria2 官方推荐调优 UDP 缓冲区，防止高并发断流
  sysctl -w net.core.rmem_max=16777216 >/dev/null 2>&1
  sysctl -w net.core.wmem_max=16777216 >/dev/null 2>&1
}

mkdir -p "${HY_DIR}"
install_dependencies
optimize_udp

PUBLIC_IP=$(curl -s4m8 https://api.ipify.org || curl -s4m8 https://ifconfig.me || hostname -I | awk '{print $1}')
[ -z "$PUBLIC_IP" ] && echo -e "${RED}无法获取服务器公网 IP${NC}" && exit 1

if [ ! -s "${HY_BIN}" ]; then
  echo -e "${YELLOW}正在下载 Hysteria 2 核心...${NC}"
  curl -L -f --connect-timeout 15 -o "${HY_BIN}" "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}" || \
  curl -L -f --connect-timeout 15 -o "${HY_BIN}" "https://ghproxy.net/https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
  
  if [ ! -s "${HY_BIN}" ]; then
    echo -e "${RED}Hysteria 2 二进制文件下载失败，请检查网络！${NC}"
    rm -f "${HY_BIN}"; exit 1
  fi
  chmod +x "${HY_BIN}"
fi

if [ ! -f "${CERT}" ]; then
  openssl req -x509 -newkey rsa:2048 -keyout "${KEY}" -out "${CERT}" -days 3650 -nodes -subj "/CN=${MASQ_DOMAIN}" >/dev/null 2>&1
  chmod 644 "${CERT}" && chmod 600 "${KEY}"
fi

read -p "请输入要生成的节点数量 (默认 5): " USER_NUM
NUM_INSTANCES=${USER_NUM:-5}
[[ ! "$NUM_INSTANCES" =~ ^[1-9][0-9]*$ ]] && NUM_INSTANCES=5

# 清理旧服务
systemctl stop "hy2-*.service" >/dev/null 2>&1 || true
rm -f /etc/systemd/system/hy2-*.service
systemctl daemon-reload

echo -e "${BLUE}开始部署 ${NUM_INSTANCES} 个节点...${NC}"
ALL_LINKS=()
USED_PORTS=()

for i in $(seq 1 "$NUM_INSTANCES"); do
  # 使用 shuf 精确在 20000-60000 范围取端口，并避免冲突
  for ((r=0; r<50; r++)); do
    PORT=$(shuf -i 20000-60000 -n 1)
    if ! ss -tuln | grep -q ":${PORT} " && [[ ! " ${USED_PORTS[*]} " =~ " ${PORT} " ]]; then
      USED_PORTS+=("$PORT")
      break
    fi
  done

  PASSWORD=$(openssl rand -hex 16)
  OBFS_PASSWORD=$(openssl rand -hex 8)
  
  CFG_FILE="${HY_DIR}/config${i}.yaml"
  cat > "${CFG_FILE}" <<EOF
listen: :${PORT}
tls: { cert: ${CERT}, key: ${KEY} }
auth: { type: password, password: "${PASSWORD}" }
obfs: { type: salamander, salamander: { password: "${OBFS_PASSWORD}" } }
masquerade: { type: proxy, proxy: { url: https://${MASQ_DOMAIN}/, rewriteHost: true } }
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
  
  if systemctl is-active --quiet "hy2-${i}"; then
    echo -e "节点 $i: ${GREEN}启动成功${NC} (端口 $PORT)"
    CURRENT_LINK="hy2://${PASSWORD}@${PUBLIC_IP}:${PORT}/?insecure=1&obfs=salamander&obfs-password=${OBFS_PASSWORD}&sni=${MASQ_DOMAIN}#Node-${i}"
    ALL_LINKS+=("$CURRENT_LINK")
  else
    echo -e "节点 $i: ${RED}启动失败${NC} (端口 $PORT)，请使用 journalctl -u hy2-${i} 查看日志"
  fi
done

# 使用 printf 将数组元素用换行符连接，避免末尾多余空行，无需再用 sed 处理
ALL_LINKS_TEXT=$(printf "%s\n" "${ALL_LINKS[@]}")
echo "$ALL_LINKS_TEXT" > "${LINKS_FILE}"

echo -e "\n${BLUE}================ 批量链接文本 (已保存至 ${LINKS_FILE}) ==============${NC}"
echo "$ALL_LINKS_TEXT"

if command -v qrencode >/dev/null 2>&1 && [ -n "$ALL_LINKS_TEXT" ]; then
  echo -e "\n${BLUE}================ 聚合二维码 (All-in-One) ==============${NC}"
  echo -e "${YELLOW}提示: 如果节点过多导致二维码过大乱码，请缩小终端字体或直接复制上方文本。${NC}"
  qrencode -t ANSIUTF8 "$ALL_LINKS_TEXT"
else
  echo -e "\n${YELLOW}提示: 未安装 qrencode 或无可用节点，跳过二维码生成。${NC}"
fi
echo -e "${BLUE}======================================================================${NC}"
