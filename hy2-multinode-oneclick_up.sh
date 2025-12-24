#!/usr/bin/env bash
# hy2-multinode-optimized-fix.sh
# Hysteria v2 多节点随机端口自动部署（修复 URL 字符问题版）

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

# 检查系统架构
ARCH=$(uname -m)
case $ARCH in
  x86_64|amd64) HY_ARCH="amd64" ;;
  aarch64|arm64) HY_ARCH="arm64" ;;
  *) echo -e "${RED}不支持的架构: $ARCH${NC}"; exit 1 ;;
esac

# 卸载功能
uninstall() {
  echo -e "${YELLOW}正在卸载 Hysteria 2...${NC}"
  # 停止并禁用所有相关服务
  systemctl list-units --type=service --all | grep 'hy2-.*\.service' | awk '{print $1}' | xargs -r systemctl stop
  systemctl list-units --type=service --all | grep 'hy2-.*\.service' | awk '{print $1}' | xargs -r systemctl disable
  
  # 清理文件
  rm -f /etc/systemd/system/hy2-*.service
  rm -f "${HY_BIN}"
  rm -rf "${HY_DIR}"
  
  systemctl daemon-reload
  pkill -f "${HY_BIN}" >/dev/null 2>&1 || true
  
  echo -e "${GREEN}✅ 卸载完成${NC}"
  exit 0
}

[ "$1" = "uninstall" ] && uninstall

# 依赖安装函数 (兼容 Debian/RHEL)
install_dependencies() {
  echo -e "${BLUE}安装必要的依赖...${NC}"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y curl jq openssl ca-certificates
  elif command -v yum >/dev/null 2>&1; then
    yum install -y epel-release
    yum install -y curl jq openssl ca-certificates
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl jq openssl ca-certificates
  else
    echo -e "${RED}未检测到支持的包管理器 (apt/yum/dnf)，请手动安装依赖。${NC}"
  fi
}

echo -e "${BLUE}==== Hysteria v2 多节点随机端口一键部署 (URL 修复版) ====${NC}"

# 1. 初始清理与准备
mkdir -p "${HY_DIR}" "${LOGDIR}"

# 2. 安装依赖
install_dependencies

# 3. 获取公网 IP
echo -e "${YELLOW}正在获取公网 IP...${NC}"
PUBLIC_IP=$(curl -s4m8 https://api.ipify.org || curl -s4m8 https://ifconfig.me || hostname -I | awk '{print $1}')
if [ -z "$PUBLIC_IP" ]; then
    echo -e "${RED}无法获取公网 IP，请检查网络连接${NC}"
    exit 1
fi

# 4. 下载 Hysteria (带重试机制)
if [ ! -f "${HY_BIN}" ]; then
  echo -e "${YELLOW}正在下载 Hysteria 2 核心...${NC}"
  # 优先尝试官方 release，失败则尝试加速镜像
  DOWNLOAD_URLS=(
    "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
    "https://ghproxy.net/https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
  )

  for url in "${DOWNLOAD_URLS[@]}"; do
    if curl -L -f -o "${HY_BIN}" "$url"; then
      chmod +x "${HY_BIN}"
      echo -e "${GREEN}下载成功${NC}"
      break
    fi
  done

  if [ ! -x "${HY_BIN}" ]; then
    echo -e "${RED}下载失败，请检查网络连接${NC}"
    exit 1
  fi
else
  echo -e "${GREEN}Hysteria 核心已存在，跳过下载${NC}"
fi

# 5. 生成自签名证书
if [ ! -f "${CERT}" ] || [ ! -f "${KEY}" ]; then
  echo -e "${YELLOW}生成自签名证书 (CN=${PUBLIC_IP})...${NC}"
  openssl req -x509 -newkey rsa:2048 -keyout "${KEY}" -out "${CERT}" -days 3650 -nodes -subj "/CN=${PUBLIC_IP}" >/dev/null 2>&1
  chmod 644 "${CERT}"
  chmod 600 "${KEY}"
fi

# 6. 用户配置
read -p "请输入要安装的节点数量 (默认 5): " USER_NUM
NUM_INSTANCES=${USER_NUM:-5}
[[ ! "$NUM_INSTANCES" =~ ^[0-9]+$ ]] && NUM_INSTANCES=5

echo -e "${BLUE}清理旧的服务配置...${NC}"
# 仅停止本脚本管理的 hy2 服务
systemctl list-units --type=service --all | grep 'hy2-.*\.service' | awk '{print $1}' | xargs -r systemctl stop
rm -f /etc/systemd/system/hy2-*.service
systemctl daemon-reload

# 7. 循环创建节点
declare -A NODE_INFO

echo -e "${BLUE}开始部署 $NUM_INSTANCES 个节点...${NC}"

for i in $(seq 1 "$NUM_INSTANCES"); do
  # 端口冲突检测与生成
  for ((r=0; r<MAX_RETRIES; r++)); do
    PORT=$((RANDOM % 40000 + 20000))
    if ! ss -tuln | grep -q ":${PORT} "; then
      break
    fi
    [ "$r" -eq $((MAX_RETRIES - 1)) ] && echo -e "${RED}警告: 节点 $i 无法找到空闲端口${NC}" && continue 2
  done

  # [修复点] 使用 hex 代替 base64，避免产生 "/" 或 "+" 符号
  PASSWORD=$(openssl rand -hex 16)
  OBFS_PASSWORD=$(openssl rand -hex 8)

  CFG_FILE="${HY_DIR}/config${i}.yaml"
  
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

  # 创建 Systemd 服务
  SERVICE_FILE="/etc/systemd/system/hy2-${i}.service"
  cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Hysteria v2 Node ${i}
After=network.target

[Service]
Type=simple
ExecStart=${HY_BIN} server -c ${CFG_FILE}
WorkingDirectory=${HY_DIR}
User=root
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

  # 启动服务
  if systemctl enable --now "hy2-${i}" >/dev/null 2>&1; then
    sleep 0.5
    if systemctl is-active --quiet "hy2-${i}"; then
       NODE_INFO[$i]="hy2://${PASSWORD}@${PUBLIC_IP}:${PORT}/?insecure=1&obfs=salamander&obfs-password=${OBFS_PASSWORD}&sni=${PUBLIC_IP}#Node-${i}"
       echo -e "节点 $i: ${GREEN}启动成功${NC} (端口: $PORT)"
    else
       echo -e "节点 $i: ${RED}启动失败${NC}"
    fi
  else
    nohup "${HY_BIN}" server -c "${CFG_FILE}" > "${LOGDIR}/hy2-${i}.log" 2>&1 &
    NODE_INFO[$i]="hy2://${PASSWORD}@${PUBLIC_IP}:${PORT}/?insecure=1&obfs=salamander&obfs-password=${OBFS_PASSWORD}&sni=${PUBLIC_IP}#Node-${i}"
    echo -e "节点 $i: ${GREEN}后台运行中${NC} (端口: $PORT)"
  fi
done

echo -e "\n${BLUE}================ 节点配置信息 ==============${NC}"
echo -e "${YELLOW}提示: 修复了密码包含特殊字符导致无法导入的问题。${NC}"
echo -e "${YELLOW}提示: 客户端请开启 'Allow Insecure' (跳过证书验证)${NC}\n"

for i in $(seq 1 "$NUM_INSTANCES"); do
  if [ -n "${NODE_INFO[$i]}" ]; then
    echo -e "${GREEN}节点 $i 链接:${NC}"
    echo -e "${NODE_INFO[$i]}"
    echo ""
  fi
done

echo -e "${BLUE}==========================================${NC}"
