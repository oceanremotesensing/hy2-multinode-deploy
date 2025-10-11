#!/bin/bash
set -e

# --- 彩色输出 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- 配置 ---
HY_DIR="/etc/hysteria2"
HY_BIN="/usr/local/bin/hysteria"
DEFAULT_NUM_INSTANCES=5
DEFAULT_BASE_PORT=8443

# 检查是否为 root 用户
check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}错误: 必须以 root 用户运行此脚本${NC}"
    exit 1
  fi
}

# 卸载 Hysteria
uninstall_hysteria() {
  echo -e "${YELLOW}正在卸载 Hysteria 节点和相关配置...${NC}"

  # 查找并停止所有 hy2 服务
  for service in $(systemctl list-units --type=service --all | grep 'hy2-.*\.service' | awk '{print $1}'); do
    echo -e "${BLUE}正在停止并禁用服务: ${service}${NC}"
    systemctl stop "$service" >/dev/null 2>&1 || true
    systemctl disable "$service" >/dev/null 2>&1 || true
  done

  # 删除服务文件和配置目录
  rm -f /etc/systemd/system/hy2-*.service
  rm -rf ${HY_DIR}

  # 删除主程序
  if [ -f ${HY_BIN} ]; then
    rm -f ${HY_BIN}
    echo -e "${GREEN}已删除 Hysteria 主程序${NC}"
  fi

  systemctl daemon-reload
  echo -e "${GREEN}✅ 卸载完成！${NC}"
}


# 安装 Hysteria
install_hysteria() {
  check_root
  
  # --- 新增：询问用户是否执行全新安装 ---
  read -p "是否执行全新安装？这将清除所有旧节点配置。 [Y/n]: " CLEAN_INSTALL
  CLEAN_INSTALL=${CLEAN_INSTALL:-Y} # 默认值为 Y

  if [[ "$CLEAN_INSTALL" =~ ^[Yy]$ ]]; then
      echo -e "${YELLOW}执行全新安装，正在清理旧配置...${NC}"
      uninstall_hysteria
  else
      echo -e "${YELLOW}跳过清理步骤，将在现有基础上安装/覆盖节点...${NC}"
  fi
  # --- 新增结束 ---


  read -p "您想创建/覆盖多少个节点? [默认: $DEFAULT_NUM_INSTANCES]: " NUM_INSTANCES
  NUM_INSTANCES=${NUM_INSTANCES:-$DEFAULT_NUM_INSTANCES}

  read -p "起始端口号是多少? [默认: $DEFAULT_BASE_PORT]: " BASE_PORT
  BASE_PORT=${BASE_PORT:-$DEFAULT_BASE_PORT}

  echo -e "${YELLOW}正在安装必要的组件 (curl, openssl, qrencode, jq)...${NC}"
  apt-get update
  apt-get install -y curl socat openssl qrencode jq

  echo -e "${YELLOW}正在检测服务器架构...${NC}"
  ARCH=$(uname -m)
  case ${ARCH} in
    x86_64|amd64) HY_ARCH="amd64" ;;
    aarch64|arm64) HY_ARCH="arm64" ;;
    *) echo -e "${RED}不支持的架构: ${ARCH}${NC}"; exit 1 ;;
  esac
  echo -e "${GREEN}检测到架构: ${HY_ARCH}${NC}"

  echo -e "${YELLOW}正在从 GitHub 获取最新版本的 Hysteria v2...${NC}"
  LATEST_URL=$(curl -s "https://api.github.com/repos/apernet/hysteria/releases/latest" | jq -r ".assets[] | select(.name == \"hysteria-linux-${HY_ARCH}\") | .browser_download_url")

  if [ -z "$LATEST_URL" ]; then
    echo -e "${RED}错误: 无法获取 Hysteria 的下载链接，请检查网络或稍后再试${NC}"
    exit 1
  fi

  echo -e "${BLUE}正在下载: ${LATEST_URL}${NC}"
  curl -Lo ${HY_BIN} "$LATEST_URL"
  chmod +x ${HY_BIN}

  mkdir -p ${HY_DIR}
  
  # 只有在证书不存在时才生成，避免覆盖
  if [ ! -f "${HY_DIR}/key.pem" ] || [ ! -f "${HY_DIR}/cert.pem" ]; then
    echo -e "${YELLOW}正在生成自签名 TLS 证书...${NC}"
    openssl req -x509 -newkey rsa:2048 -keyout ${HY_DIR}/key.pem -out ${HY_DIR}/cert.pem -days 3650 -nodes -subj "/CN=bing.com"
  else
    echo -e "${YELLOW}证书文件已存在，跳过生成步骤。${NC}"
  fi

  echo -e "${YELLOW}正在生成节点配置和 systemd 服务...${NC}"
  for i in $(seq 1 $NUM_INSTANCES); do
    PORT=$((BASE_PORT + (i - 1) * 1000))
    PASSWORD=$(openssl rand -base64 16)

    cat > ${HY_DIR}/config${i}.yaml <<EOF
listen: ":${PORT}"
auth: {type: password, password: ${PASSWORD}}
tls: {cert: ${HY_DIR}/cert.pem, key: ${HY_DIR}/key.pem}
obfuscate: {type: srtp}
disable-quic: true
EOF

    cat > /etc/systemd/system/hy2-${i}.service <<EOF
[Unit]
Description=Hysteria v2 Node ${i}
After=network.target
[Service]
ExecStart=${HY_BIN} server -c ${HY_DIR}/config${i}.yaml
Restart=always
RestartSec=5
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW
NoNewPrivileges=false
[Install]
WantedBy=multi-user.target
EOF
  done

  systemctl daemon-reload
  for i in $(seq 1 $NUM_INSTANCES); do
    echo -e "${BLUE}正在启动并启用节点 ${i}...${NC}"
    if systemctl enable --now hy2-${i}; then
      echo -e "${GREEN}节点 ${i} 启动成功!${NC}"
    else
      echo -e "${RED}节点 ${i} 启动失败! 请运行 'journalctl -u hy2-${i}' 查看日志${NC}"
    fi
  done

  if command -v ufw &> /dev/null; then
    END_PORT=$((BASE_PORT + (NUM_INSTANCES - 1) * 1000))
    ufw allow ${BASE_PORT}:${END_PORT}/udp
    echo -e "${GREEN}UFW 防火墙规则已添加 (UDP ${BASE_PORT}:${END_PORT})${NC}"
  fi

  echo -e "${GREEN}✅ 安装/更新完成！${NC}"
}

# 显示节点分享链接
show_links() {
  check_root
  if [ ! -d "${HY_DIR}" ] || [ -z "$(ls -A ${HY_DIR} | grep '.yaml')" ]; then
    echo -e "${RED}错误: 未找到任何 Hysteria 配置文件。请先运行安装命令。${NC}"
    exit 1
  fi

  IP=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me || hostname -I | awk '{print $1}')
  echo "---"
  echo -e "${GREEN}节点分享链接:${NC}"
  for config_file in ${HY_DIR}/config*.yaml; do
    if [ -f "$config_file" ]; then
      num=$(echo ${config_file} | grep -o -E '[0-9]+')
      port=$(grep -oP '":\K[0-9]+' ${config_file})
      password=$(grep -oP 'password: \K.*' ${config_file})
      link="hy2://${password}@${IP}:${port}?insecure=1#节点${num}"
      echo -e "${YELLOW}分享链接 ${num}:${NC} ${link}"
      echo -e "${BLUE}二维码:${NC}"
      qrencode -o - -t UTF8 "${link}"
      echo "---"
    fi
  done
}

# --- 脚本主流程 ---
# 检查是否提供了操作参数
if [ -z "$1" ]; then
    echo "用法: $0 {install|links|uninstall}"
    exit 1
fi


case "$1" in
  install)
    install_hysteria
    show_links
    ;;
  links)
    show_links
    ;;
  uninstall)
    # 卸载前增加确认步骤
    read -p "您确定要卸载所有 Hysteria 节点和配置吗？此操作不可逆！ [y/N]: " CONFIRM_UNINSTALL
    if [[ "$CONFIRM_UNINSTALL" =~ ^[Yy]$ ]]; then
      uninstall_hysteria
    else
      echo "已取消卸载操作。"
    fi
    ;;
  *)
    echo "用法: $0 {install|links|uninstall}"
    exit 1
    ;;
esac
