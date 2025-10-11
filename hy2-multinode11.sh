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

# 清理旧版本 Hysteria 和系统缓存
clean_old_hysteria() {
  echo -e "${YELLOW}正在清理旧的 Hysteria 节点和系统缓存...${NC}"

  # 查找并停止旧服务
  for service in $(systemctl list-units --type=service --all | grep 'hy2-.*\.service' | awk '{print $1}'); do
    echo -e "${BLUE}正在停止并禁用旧服务: ${service}${NC}"
    systemctl stop $service >/dev/null 2>&1 || true
    systemctl disable $service >/dev/null 2>&1 || true
  done

  # 删除旧的服务文件和配置
  rm -f /etc/systemd/system/hy2-*.service
  rm -rf ${HY_DIR}

  # 删除旧的主程序
  if [ -f ${HY_BIN} ]; then
    rm -f ${HY_BIN}
    echo -e "${GREEN}已删除旧的 Hysteria 主程序${NC}"
  fi

  systemctl daemon-reload

  # 清理系统垃圾
  if command -v apt-get &> /dev/null; then
    apt-get clean
  fi
  rm -rf /tmp/* /var/tmp/*
  journalctl --vacuum-time=3d >/dev/null 2>&1
  echo -e "${GREEN}系统缓存清理完成${NC}"
}

# 安装 Hysteria
install_hysteria() {
  read -p "您想安装多少个节点? [默认: $DEFAULT_NUM_INSTANCES]: " NUM_INSTANCES
  NUM_INSTANCES=${NUM_INSTANCES:-$DEFAULT_NUM_INSTANCES}

  read -p "起始端口号是多少? [默认: $DEFAULT_BASE_PORT]: " BASE_PORT
  BASE_PORT=${BASE_PORT:-$DEFAULT_BASE_PORT}

  echo -e "${YELLOW}正在安装必要的组件 (curl, openssl, qrencode, jq)...${NC}"
  apt-get update
  apt-get install -y curl socat openssl qrencode jq

  # --- 自动检测架构并下载 ---
  echo -e "${YELLOW}正在检测服务器架构...${NC}"
  ARCH=$(uname -m)
  case ${ARCH} in
    x86_64|amd64)
      HY_ARCH="amd64"
      ;;
    aarch64|arm64)
      HY_ARCH="arm64"
      ;;
    *)
      echo -e "${RED}不支持的架构: ${ARCH}${NC}"
      exit 1
      ;;
  esac
  echo -e "${GREEN}检测到架构: ${HY_ARCH}${NC}"

  echo -e "${YELLOW}正在从 GitHub 获取最新版本的 Hysteria v2...${NC}"
  LATEST_URL=$(curl -s "https://api.github.com/repos/apernet/hysteria/releases/latest" | jq -r ".assets[] | select(.name == \"hysteria-linux-${HY_ARCH}\") | .browser_download_url")

  if [ -z "$LATEST_URL" ]; then
    echo -e "${RED}错误: 无法获取 Hysteria 的下载链接，请检查网络或稍后再试${NC}"
    exit 1
  fi

  echo -e "${BLUE}正在下载: ${LATEST_URL}${NC}"
  if ! curl -Lo ${HY_BIN} "$LATEST_URL"; then
    echo -e "${RED}Hysteria 下载失败!${NC}"
    exit 1
  fi
  chmod +x ${HY_BIN}

  # --- 创建配置目录和证书 ---
  mkdir -p ${HY_DIR}
  cd ${HY_DIR}

  echo -e "${YELLOW}正在生成自签名 TLS 证书...${NC}"
  openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes -subj "/CN=bing.com"

  echo -e "${YELLOW}正在生成节点配置和 systemd 服务...${NC}"
  for i in $(seq 1 $NUM_INSTANCES); do
    PORT=$((BASE_PORT + (i - 1) * 1000))
    PASSWORD=$(openssl rand -base64 16)

    # 创建配置文件
    cat > ${HY_DIR}/config${i}.yaml <<EOF
listen: ":${PORT}"
auth:
  type: password
  password: ${PASSWORD}
tls:
  cert: ${HY_DIR}/cert.pem
  key: ${HY_DIR}/key.pem
obfuscate:
  type: srtp
# 注意: disable-quic 会让 Hysteria 使用基于 TCP 的 'faketcp' 模式
disable-quic: true
EOF

    # 创建 systemd 服务文件
    cat > /etc/systemd/system/hy2-${i}.service <<EOF
[Unit]
Description=Hysteria v2 Node ${i}
After=network.target

[Service]
ExecStart=${HY_BIN} server -c ${HY_DIR}/config${i}.yaml
Restart=always
RestartSec=5
# Hysteria 需要这些权限来优化网络
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW
NoNewPrivileges=false

[Install]
WantedBy=multi-user.target
EOF
  done

  # --- 启动服务并配置防火墙 ---
  systemctl daemon-reload
  for i in $(seq 1 $NUM_INSTANCES); do
    echo -e "${BLUE}正在启动并启用节点 ${i}...${NC}"
    if systemctl enable --now hy2-${i}; then
        echo -e "${GREEN}节点 ${i} 启动成功!${NC}"
    else
        echo -e "${RED}节点 ${i} 启动失败! 请运行 'journalctl -u hy2-${i}' 查看错误日志${NC}"
    fi
  done

  if command -v ufw &> /dev/null; then
    END_PORT=$((BASE_PORT + (NUM_INSTANCES - 1) * 1000))
    echo -e "${YELLOW}正在为端口 ${BASE_PORT}-${END_PORT} 添加 UFW 防火墙规则...${NC}"
    ufw allow ${BASE_PORT}:${END_PORT}/udp
    echo -e "${GREEN}UFW 防火墙规则已添加 (UDP ${BASE_PORT}-${END_PORT})${NC}"
  fi

  echo -e "${GREEN}✅ 所有节点安装和启动流程已完成！${NC}"
}

# 显示节点分享链接
show_links() {
  # 尝试多种方式获取公网IP
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
    fi
  done
}

# --- 脚本主流程 ---
check_root
clean_old_hysteria
install_hysteria
show_links

echo -e "\n${GREEN}🎉 部署完成！${NC}"
