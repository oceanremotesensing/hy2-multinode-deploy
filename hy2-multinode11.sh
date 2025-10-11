#!/bin/bash
set -e

# --- 彩色输出定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- 脚本配置 ---
HY_DIR="/etc/hysteria2"
HY_BIN="/usr/local/bin/hysteria"

# --- 函数定义 ---

# 检查是否为 root 用户
check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}错误: 此脚本必须以 root 用户权限运行。${NC}"
    exit 1
  fi
}

# 获取公网 IP（带备用）
get_public_ip() {
  IP=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me)
  if [ -z "$IP" ]; then
    echo -e "${RED}错误: 无法获取公网IP地址。${NC}"
    exit 1
  fi
  echo "$IP"
}

# 安装 Hysteria
install_hysteria() {
  check_root
  echo -e "${BLUE}--- Hysteria 2 安装程序 ---${NC}"

  # 参数化安装
  NUM_INSTANCES=${1:-10}
  BASE_PORT=${2:-8443}

  echo -e "${YELLOW}🔧 正在更新系统并安装必备组件...${NC}"
  apt-get update >/dev/null 2>&1
  apt-get install -y curl socat openssl qrencode >/dev/null 2>&1

  echo -e "${YELLOW}🔧 正在下载并安装 Hysteria v2...${NC}"
  pkill -f hysteria || true
  rm -f ${HY_BIN}
  curl -Lo ${HY_BIN} https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-amd64
  chmod +x ${HY_BIN}

  mkdir -p ${HY_DIR}
  cd ${HY_DIR}

  echo -e "${YELLOW}🔧 正在生成自签名证书...${NC}"
  if [[ ! -f cert.pem || ! -f key.pem ]]; then
    openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes -subj "/CN=bing.com"
  else
    echo "证书已存在，跳过生成。"
  fi

  echo -e "${YELLOW}🔧 正在为 ${NUM_INSTANCES} 个节点生成配置并创建服务...${NC}"
  for i in $(seq 1 ${NUM_INSTANCES}); do
    PORT=$((BASE_PORT + (i - 1) * 1000))
    PASSWORD=$(openssl rand -base64 16)

    cat > config${i}.yaml <<EOF
listen: ":${PORT}"
auth:
  type: password
  password: ${PASSWORD}
tls:
  cert: ${HY_DIR}/cert.pem
  key: ${HY_DIR}/key.pem
obfuscate:
  type: srtp
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

  echo -e "${YELLOW}🔧 重载并启动所有服务...${NC}"
  systemctl daemon-reload
  for i in $(seq 1 ${NUM_INSTANCES}); do
    systemctl enable --now hy2-${i} >/dev/null 2>&1
  done

  # 配置防火墙
  echo -e "${YELLOW}🔥 正在配置防火墙...${NC}"
  if command -v ufw &> /dev/null; then
    END_PORT=$((BASE_PORT + (NUM_INSTANCES - 1) * 1000))
    ufw allow ${BASE_PORT}-${END_PORT}/udp >/dev/null 2>&1
    echo -e "${GREEN}UFW防火墙规则已添加 (UDP: ${BASE_PORT}-${END_PORT})。${NC}"
  fi

  echo -e "\n${RED}🚨 重要提示 🚨${NC}"
  echo -e "${YELLOW}请务必在云服务商控制台放行以下 UDP 端口范围：${NC}"
  echo -e "${GREEN}${BASE_PORT}-${END_PORT}${NC}"

  show_links
}

# 卸载 Hysteria
uninstall_hysteria() {
  check_root
  echo -e "${RED}--- Hysteria 2 卸载程序 ---${NC}"
  read -p "确认卸载所有节点? [y/N]: " CONFIRM
  if [[ "${CONFIRM}" != "y" ]]; then
    echo "操作已取消。"
    exit 0
  fi

  echo -e "${YELLOW}🔧 停止并禁用所有服务...${NC}"
  for service in $(systemctl list-unit-files | grep 'hy2-.*\.service' | awk '{print $1}'); do
    systemctl stop ${service}
    systemctl disable ${service}
  done

  echo -e "${YELLOW}🔧 删除配置文件和服务文件...${NC}"
  rm -f /etc/systemd/system/hy2-*.service
  rm -rf ${HY_DIR}

  read -p "是否删除 Hysteria 主程序 (${HY_BIN})? [y/N]: " DEL_BINARY
  if [[ "${DEL_BINARY}" == "y" ]]; then
    rm -f ${HY_BIN}
    echo -e "${GREEN}Hysteria 主程序已删除。${NC}"
  fi

  systemctl daemon-reload
  echo -e "\n${GREEN}✅ Hysteria 2 已成功卸载。${NC}"
}

# 查看节点链接
show_links() {
  if [ ! -d "${HY_DIR}" ] || [ -z "$(ls -A ${HY_DIR}/config*.yaml 2>/dev/null)" ]; then
    echo -e "${RED}错误: 未找到任何 Hysteria 配置文件。请先安装。${NC}"
    return
  fi

  IP=$(get_public_ip)

  echo -e "\n${GREEN}✅ 节点链接如下:${NC}"
  for config_file in ${HY_DIR}/config*.yaml; do
    num=$(echo ${config_file} | grep -o -E '[0-9]+')
    port=$(grep -oP '":\K[0-9]+' ${config_file})
    password=$(grep -oP 'password: \K.*' ${config_file})
    link="hy2://${password}@${IP}:${port}?insecure=1#节点${num}"
    echo -e "${YELLOW}${link}${NC}"
    # 生成二维码
    qrencode -o - -t UTF8 "${link}"
  done
  echo ""
}

# 查看节点状态
check_status() {
  if [ ! -d "${HY_DIR}" ]; then
    echo -e "${RED}错误: 未找到 Hysteria 安装目录。请先安装。${NC}"
    return
  fi
  for service in $(systemctl list-unit-files | grep 'hy2-.*\.service' | awk '{print $1}'); do
    systemctl status ${service} --no-pager
    echo ""
  done
}

# --- 主菜单 ---
main_menu() {
  while true; do
    clear
    echo -e "${BLUE}===================================${NC}"
    echo -e "${GREEN}   Hysteria 2 多节点管理脚本   ${NC}"
    echo -e "${BLUE}===================================${NC}"
    echo "1. 安装 Hysteria 节点 (可参数化)"
    echo "2. 卸载 Hysteria"
    echo "3. 查看节点链接 (含 QR Code)"
    echo "4. 查看节点运行状态"
    echo "0. 退出脚本"
    echo ""
    read -p "请输入选择 [0-4]: " choice
    case ${choice} in
      1)
        read -p "请输入节点数量 [默认10]: " num
        read -p "请输入起始端口 [默认8443]: " port
        install_hysteria "${num:-10}" "${port:-8443}"
        read -p "按 Enter 返回菜单..."
        ;;
      2) uninstall_hysteria ; read -p "按 Enter 返回菜单..." ;;
      3) show_links ; read -p "按 Enter 返回菜单..." ;;
      4) check_status ; read -p "按 Enter 返回菜单..." ;;
      0) exit 0 ;;
      *) echo -e "${RED}无效输入，请重试。${NC}" ; sleep 2 ;;
    esac
  done
}

# --- 脚本入口 ---
main_menu
