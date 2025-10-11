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

# --- 参数 (可修改) ---
NUM_INSTANCES=${1:-5}    # 节点数量，默认5
BASE_PORT=${2:-8443}     # 起始端口，默认8443

# 检查 root
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}错误: 必须以 root 用户运行${NC}"
  exit 1
fi

# 安装依赖
echo -e "${YELLOW}安装必备组件...${NC}"
apt-get update >/dev/null 2>&1
apt-get install -y curl socat openssl qrencode >/dev/null 2>&1

# 下载 Hysteria
echo -e "${YELLOW}下载并安装 Hysteria...${NC}"
pkill -f hysteria || true
rm -f ${HY_BIN}
curl -Lo ${HY_BIN} https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-amd64
chmod +x ${HY_BIN}

# 创建目录
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

  # 配置文件
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

  # systemd 服务
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

# 配置 UFW 防火墙
if command -v ufw &> /dev/null; then
  END_PORT=$((BASE_PORT + (NUM_INSTANCES - 1) * 1000))
  ufw allow ${BASE_PORT}-${END_PORT}/udp >/dev/null 2>&1
  echo -e "${GREEN}UFW 防火墙规则已添加 (UDP ${BASE_PORT}-${END_PORT})${NC}"
fi

# 获取公网 IP
IP=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me)
echo -e "${GREEN}安装完成！节点链接如下:${NC}"

# 输出链接与 QR Code
for i in $(seq 1 ${NUM_INSTANCES}); do
  port=$(grep -oP '":\K[0-9]+' ${HY_DIR}/config${i}.yaml)
  password=$(grep -oP 'password: \K.*' ${HY_DIR}/config${i}.yaml)
  link="hy2://${password}@${IP}:${port}?insecure=1#节点${i}"
  echo -e "${YELLOW}${link}${NC}"
  qrencode -o - -t UTF8 "${link}"
done

echo -e "${GREEN}所有节点已启动并配置完成！${NC}"
