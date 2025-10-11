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

# --- 参数默认值 ---
DEFAULT_NUM_INSTANCES=5
DEFAULT_BASE_PORT=8443

# 检查 root
check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}错误: 必须以 root 用户运行${NC}"
    exit 1
  fi
}

# 获取公网 IP
get_public_ip() {
  IP=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me)
  if [ -z "$IP" ]; then
    echo -e "${RED}错误: 无法获取公网IP地址。${NC}"
    exit 1
  fi
  echo "$IP"
}

# 检查是否已安装节点
check_installed() {
  if [ ! -d "${HY_DIR}" ] || [ -z "$(ls -A ${HY_DIR}/config*.yaml 2>/dev/null)" ]; then
    return 1
  else
    return 0
  fi
}

# 安装 Hysteria
install_hysteria() {
  check_root
  NUM_INSTANCES=${1:-$DEFAULT_NUM_INSTANCES}
  BASE_PORT=${2:-$DEFAULT_BASE_PORT}

  echo -e "${BLUE}--- Hysteria 2 安装程序 ---${NC}"
  echo -e "${YELLOW}安装节点数量: ${NUM_INSTANCES}, 起始端口: ${BASE_PORT}${NC}"

  # 安装依赖
  apt-get update >/dev/null 2>&1
  apt-get install -y curl socat openssl qrencode >/dev/null 2>&1

  # 下载 Hysteria
  pkill -f hysteria || true
  rm -f ${HY_BIN}
  curl -Lo ${HY_BIN} https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-amd64
  chmod +x ${HY_BIN}

  mkdir -p ${HY_DIR}
  cd ${HY_DIR}

  # 生成证书
  if [[ ! -f cert.pem || ! -f key.pem ]]; then
    echo -e "${YELLOW}生成自签名证书...${NC}"
    openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes -subj "/CN=bing.com"
  else
    echo "证书已存在，跳过生成"
  fi

  # 生成配置与服务
  echo -e "${YELLOW}生成节点配置与 systemd 服务...${NC}"
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

  # 启动服务
  systemctl daemon-reload
  for i in $(seq 1 ${NUM_INSTANCES}); do
    systemctl enable --now hy2-${i} >/dev/null 2>&1
  done

  # 防火墙
  if command -v ufw &> /dev/null; then
    END_PORT=$((BASE_PORT + (NUM_INSTANCES - 1) * 1000))
    ufw allow ${BASE_PORT}-${END_PORT}/udp >/dev/null 2>&1
    echo -e "${GREEN}UFW 防火墙规则已添加 (UDP ${BASE_PORT}-${END_PORT})${NC}"
  fi

  echo -e "${GREEN}✅ 安装完成！${NC}"
}

# 卸载 Hysteria
uninstall_hysteria() {
  check_root
  echo -e "${RED}--- 卸载 Hysteria 2 ---${NC}"
  read -p "确认卸载所有节点? [y/N]: " CONFIRM
  if [[ "${CONFIRM}" != "y" ]]; then
    echo "操作已取消。"
    return
  fi

  for service in $(systemctl list-unit-files | grep 'hy2-.*\.service' | awk '{print $1}'); do
    systemctl stop ${service} >/dev/null 2>&1
    systemctl disable ${service} >/dev/null 2>&1
  done

  rm -f /etc/systemd/system/hy2-*.service
  rm -rf ${HY_DIR}
  rm -f ${HY_BIN}
  systemctl daemon-reload
  echo -e "${GREEN}✅ 卸载完成${NC}"
}

# 显示节点链接
show_links() {
  if ! check_installed; then
    echo -e "${YELLOW}未检测到节点配置，是否现在安装节点? [y/N]: ${NC}" 
    read -r ans
    if [[ "$ans" == "y" ]]; then
      read -p "节点数量 [默认 $DEFAULT_NUM_INSTANCES]: " num
      read -p "起始端口 [默认 $DEFAULT_BASE_PORT]: " port
      install_hysteria "${num:-$DEFAULT_NUM_INSTANCES}" "${port:-$DEFAULT_BASE_PORT}"
    else
      return
    fi
  fi

  IP=$(get_public_ip)
  echo -e "${GREEN}节点链接:${NC}"
  for config_file in ${HY_DIR}/config*.yaml; do
    num=$(echo ${config_file} | grep -o -E '[0-9]+')
    port=$(grep -oP '":\K[0-9]+' ${config_file})
    password=$(grep -oP 'password: \K.*' ${config_file})
    link="hy2://${password}@${IP}:${port}?insecure=1#节点${num}"
    echo -e "${YELLOW}${link}${NC}"
    qrencode -o - -t UTF8 "${link}"
  done
}

# 查看节点状态
check_status() {
  if ! check_installed; then
    echo -e "${RED}未检测到节点，请先安装${NC}"
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
        read -p "节点数量 [默认 $DEFAULT_NUM_INSTANCES]: " num
        read -p "起始端口 [默认 $DEFAULT_BASE_PORT]: " port
        install_hysteria "${num:-$DEFAULT_NUM_INSTANCES}" "${port:-$DEFAULT_BASE_PORT}"
        read -p "按 Enter 返回菜单..."
        ;;
      2) uninstall_hysteria ; read -p "按 Enter 返回菜单..." ;;
      3) show_links ; read -p "按 Enter 返回菜单..." ;;
      4) check_status ; read -p "按 Enter 返回菜单..." ;;
      0) exit 0 ;;
      *) echo -e "${RED}无效输入，请重试${NC}" ; sleep 2 ;;
    esac
  done
}

# --- 脚本入口 ---
main_menu
