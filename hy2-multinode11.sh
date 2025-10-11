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

check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}错误: 必须以 root 用户运行${NC}"
    exit 1
  fi
}

clean_old_hysteria() {
  echo -e "${YELLOW}清理旧节点和系统垃圾...${NC}"

  # 停止并禁用旧服务
  for service in $(systemctl list-unit-files | grep 'hy2-.*\.service' | awk '{print $1}'); do
    systemctl stop $service >/dev/null 2>&1
    systemctl disable $service >/dev/null 2>&1
  done

  # 删除旧服务文件和配置
  rm -f /etc/systemd/system/hy2-*.service
  rm -rf ${HY_DIR}

  # 删除二进制
  if [ -f ${HY_BIN} ]; then
    rm -f ${HY_BIN}
    echo -e "${GREEN}已删除旧 Hysteria 主程序${NC}"
  fi

  systemctl daemon-reload

  # 系统垃圾清理
  apt-get clean
  rm -rf /tmp/* /var/tmp/*
  journalctl --vacuum-time=3d >/dev/null 2>&1
  echo -e "${GREEN}系统垃圾已清理完成${NC}"
}

install_hysteria() {
  check_root

  read -p "您想安装多少个节点? [默认: $DEFAULT_NUM_INSTANCES]: " NUM_INSTANCES
  NUM_INSTANCES=${NUM_INSTANCES:-$DEFAULT_NUM_INSTANCES}

  read -p "起始端口号是多少? [默认: $DEFAULT_BASE_PORT]: " BASE_PORT
  BASE_PORT=${BASE_PORT:-$DEFAULT_BASE_PORT}

  echo -e "${YELLOW}安装必备组件...${NC}"
  apt-get update >/dev/null 2>&1
  apt-get install -y curl socat openssl qrencode >/dev/null 2>&1

  echo -e "${YELLOW}下载 Hysteria v2 ...${NC}"
  curl -Lo ${HY_BIN} https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-amd64
  chmod +x ${HY_BIN}

  mkdir -p ${HY_DIR}
  cd ${HY_DIR}

  echo -e "${YELLOW}生成自签名 TLS 证书...${NC}"
  openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes -subj "/CN=bing.com"

  echo -e "${YELLOW}生成节点配置和 systemd 服务...${NC}"
  for i in $(seq 1 $NUM_INSTANCES); do
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

  systemctl daemon-reload
  for i in $(seq 1 $NUM_INSTANCES); do
    systemctl enable --now hy2-${i} >/dev/null 2>&1
  done

  # 配置防火墙
  if command -v ufw &> /dev/null; then
    END_PORT=$((BASE_PORT + (NUM_INSTANCES - 1) * 1000))
    ufw allow ${BASE_PORT}-${END_PORT}/udp >/dev/null 2>&1
    echo -e "${GREEN}UFW 防火墙规则已添加 (UDP ${BASE_PORT}-${END_PORT})${NC}"
  fi

  echo -e "${GREEN}✅ 安装完成！${NC}"
}

show_links() {
  IP=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me)
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

# --- 脚本入口 ---
check_root
clean_old_hysteria
install_hysteria
show_links

echo -e "${GREEN}🎉 所有节点安装完成，系统垃圾清理完成！${NC}"
