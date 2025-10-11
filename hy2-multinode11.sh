#!/bin/bash
set -e

# --- 彩色输出 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- 默认配置 (全自动，无需输入) ---
# 如果您想自定义，请直接修改这里的数值
HY_DIR="/etc/hysteria2"
HY_BIN="/usr/local/bin/hysteria"
DEFAULT_NUM_INSTANCES=5  # 自动安装 5 个节点
DEFAULT_BASE_PORT=8443   # 起始端口为 8443

# --- 函数定义 ---

# 检查是否为 root 用户
check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}错误: 必须以 root 用户运行此脚本${NC}"
    exit 1
  fi
}

# 自动卸载/清理旧版本
uninstall_hysteria() {
  echo -e "${YELLOW}正在自动清理旧的 Hysteria 节点和配置...${NC}"
  # 查找并停止所有 hy2 服务
  systemctl list-units --type=service --all | grep 'hy2-.*\.service' | awk '{print $1}' | xargs -I {} systemctl stop {} >/dev/null 2>&1
  systemctl list-units --type=service --all | grep 'hy2-.*\.service' | awk '{print $1}' | xargs -I {} systemctl disable {} >/dev/null 2>&1
  # 删除服务文件和配置目录
  rm -f /etc/systemd/system/hy2-*.service
  rm -rf ${HY_DIR}
  # 删除主程序
  if [ -f ${HY_BIN} ]; then
    rm -f ${HY_BIN}
  fi
  systemctl daemon-reload
  echo -e "${GREEN}清理完成。${NC}"
}

# 自动安装 Hysteria
install_hysteria_auto() {
  echo -e "${YELLOW}将自动安装 ${DEFAULT_NUM_INSTANCES} 个节点，起始端口为 ${DEFAULT_BASE_PORT}...${NC}"

  echo -e "${BLUE}正在安装必要的组件 (curl, openssl, qrencode, jq)...${NC}"
  apt-get update >/dev/null 2>&1
  apt-get install -y curl socat openssl qrencode jq >/dev/null 2>&1

  echo -e "${BLUE}正在检测服务器架构...${NC}"
  ARCH=$(uname -m)
  case ${ARCH} in
    x86_64|amd64) HY_ARCH="amd64" ;;
    aarch64|arm64) HY_ARCH="arm64" ;;
    *) echo -e "${RED}不支持的架构: ${ARCH}${NC}"; exit 1 ;;
  esac
  echo -e "${GREEN}检测到架构: ${HY_ARCH}${NC}"

  echo -e "${BLUE}正在从 GitHub 获取最新 Hysteria v2...${NC}"
  LATEST_URL=$(curl -s "https://api.github.com/repos/apernet/hysteria/releases/latest" | jq -r ".assets[] | select(.name == \"hysteria-linux-${HY_ARCH}\") | .browser_download_url")
  if [ -z "$LATEST_URL" ]; then
    echo -e "${RED}错误: 无法获取 Hysteria 的下载链接!${NC}"; exit 1
  fi
  
  curl -Lo ${HY_BIN} "$LATEST_URL"
  chmod +x ${HY_BIN}

  mkdir -p ${HY_DIR}
  echo -e "${BLUE}正在生成 TLS 证书...${NC}"
  openssl req -x509 -newkey rsa:2048 -keyout ${HY_DIR}/key.pem -out ${HY_DIR}/cert.pem -days 3650 -nodes -subj "/CN=bing.com" >/dev/null 2>&1

  echo -e "${BLUE}正在生成节点配置和 systemd 服务...${NC}"
  for i in $(seq 1 $DEFAULT_NUM_INSTANCES); do
    PORT=$((DEFAULT_BASE_PORT + (i - 1) * 1000))
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
  for i in $(seq 1 $DEFAULT_NUM_INSTANCES); do
    systemctl enable --now hy2-${i} >/dev/null 2>&1
  done

  if command -v ufw &> /dev/null; then
    END_PORT=$((DEFAULT_BASE_PORT + (DEFAULT_NUM_INSTANCES - 1) * 1000))
    ufw allow ${DEFAULT_BASE_PORT}:${END_PORT}/udp >/dev/null 2>&1
  fi
  echo -e "${GREEN}✅ 所有节点已安装并启动！${NC}"
}

# 显示节点分享链接
show_links() {
  IP=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me || hostname -I | awk '{print $1}')
  echo "---"
  echo -e "${GREEN}所有节点分享链接如下:${NC}"
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

# --- 脚本主流程 (全自动) ---
check_root
uninstall_hysteria
install_hysteria_auto
show_links

echo -e "\n${GREEN}🎉 一键部署完成！${NC}"
