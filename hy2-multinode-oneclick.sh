#!/bin/bash

# ==========================================================
# RackNerd / 通用 VPS 兼容版 Hysteria2 多节点一键安装脚本
# ==========================================================

# --- 彩色输出 ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# --- 默认配置 ---
HY_DIR="/etc/hysteria2"
HY_BIN="/usr/local/bin/hysteria"
DEFAULT_NUM_INSTANCES=5
DEFAULT_BASE_PORT=8443

# --- 检查 root ---
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}❌ 必须以 root 用户运行${NC}"
  exit 1
fi

# --- 清理旧版本 ---
echo -e "${YELLOW}🧹 正在清理旧的 Hysteria 节点...${NC}"
pkill -9 hysteria >/dev/null 2>&1 || true
rm -rf ${HY_DIR}
rm -f ${HY_BIN}
mkdir -p ${HY_DIR}
echo -e "${GREEN}✅ 清理完成${NC}"

# --- 安装依赖 ---
echo -e "${BLUE}📦 安装必要依赖...${NC}"
apt update -y >/dev/null 2>&1
apt install -y curl jq qrencode openssl socat >/dev/null 2>&1

# --- 检查架构 ---
ARCH=$(uname -m)
case ${ARCH} in
  x86_64|amd64) HY_ARCH="amd64" ;;
  aarch64|arm64) HY_ARCH="arm64" ;;
  *) echo -e "${RED}不支持的架构: ${ARCH}${NC}"; exit 1 ;;
esac
echo -e "${GREEN}✅ 检测到架构: ${HY_ARCH}${NC}"

# --- 获取最新 Hysteria v2 ---
echo -e "${BLUE}🌐 获取最新 Hysteria v2 下载链接...${NC}"
LATEST_URL=$(curl -s "https://api.github.com/repos/apernet/hysteria/releases/latest" | jq -r ".assets[] | select(.name == \"hysteria-linux-${HY_ARCH}\") | .browser_download_url")

# 若 GitHub 无法访问，使用镜像
if [ -z "$LATEST_URL" ]; then
  echo -e "${YELLOW}⚠️  GitHub 获取失败，尝试使用镜像源...${NC}"
  LATEST_URL=$(curl -s "https://ghproxy.net/https://api.github.com/repos/apernet/hysteria/releases/latest" | jq -r ".assets[] | select(.name == \"hysteria-linux-${HY_ARCH}\") | .browser_download_url")
fi

if [ -z "$LATEST_URL" ]; then
  echo -e "${RED}❌ 无法获取 Hysteria 下载链接${NC}"
  exit 1
fi

# --- 下载并安装 ---
curl -L -o ${HY_BIN} "$LATEST_URL"
chmod +x ${HY_BIN}
echo -e "${GREEN}✅ Hysteria v2 安装成功${NC}"

# --- 生成 TLS 证书 ---
echo -e "${BLUE}🔐 生成自签名证书...${NC}"
openssl req -x509 -newkey rsa:2048 -keyout ${HY_DIR}/key.pem -out ${HY_DIR}/cert.pem -days 3650 -nodes -subj "/CN=bing.com" >/dev/null 2>&1
echo -e "${GREEN}✅ 证书生成完成${NC}"

# --- 生成节点配置 ---
echo -e "${BLUE}⚙️ 生成配置文件...${NC}"
for i in $(seq 1 $DEFAULT_NUM_INSTANCES); do
  PORT=$((DEFAULT_BASE_PORT + (i - 1) * 1000))
  PASSWORD=$(openssl rand -base64 12)
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
disable-quic: true
EOF
done
echo -e "${GREEN}✅ ${DEFAULT_NUM_INSTANCES} 个配置文件已生成${NC}"

# --- 启动节点 ---
echo -e "${BLUE}🚀 启动所有节点...${NC}"
for i in $(seq 1 $DEFAULT_NUM_INSTANCES); do
  PORT=$((DEFAULT_BASE_PORT + (i - 1) * 1000))
  nohup ${HY_BIN} server -c ${HY_DIR}/config${i}.yaml > ${HY_DIR}/hy2-${i}.log 2>&1 &
  sleep 0.5
done
echo -e "${GREEN}✅ 所有节点已启动${NC}"

# --- 防火墙放行 ---
if command -v ufw &>/dev/null; then
  END_PORT=$((DEFAULT_BASE_PORT + (DEFAULT_NUM_INSTANCES - 1) * 1000))
  ufw allow ${DEFAULT_BASE_PORT}:${END_PORT}/udp >/dev/null 2>&1
fi

# --- 显示节点信息 ---
IP=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me || hostname -I | awk '{print $1}')
echo -e "\n${GREEN}🎯 所有节点分享信息如下:${NC}"
for config_file in ${HY_DIR}/config*.yaml; do
  i=$(echo $config_file | grep -o -E '[0-9]+')
  port=$(grep -oP '":\K[0-9]+' ${config_file})
  password=$(grep -oP 'password: \K.*' ${config_file})
  link="hy2://${password}@${IP}:${port}?insecure=1#RackNerd节点${i}"
  echo -e "${YELLOW}节点${i}:${NC} ${link}"
  qrencode -t UTF8 "${link}"
  echo
done

echo -e "${GREEN}🎉 所有节点部署完成！配置位于 ${HY_DIR}${NC}"
