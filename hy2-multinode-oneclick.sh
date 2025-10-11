#!/usr/bin/env bash
# hy2-multinode-oneclick.sh
# 自动连续找空闲端口 + 无二维码 + 可卸载 + systemd启动

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

HY_DIR="/etc/hysteria2"
HY_BIN="/usr/local/bin/hysteria"
LOGDIR="${HY_DIR}/logs"
CERT="${HY_DIR}/cert.pem"
KEY="${HY_DIR}/key.pem"

if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}请以 root 用户运行此脚本${NC}"
  exit 1
fi

# 卸载函数
uninstall() {
  echo -e "${YELLOW}开始卸载 Hysteria 节点...${NC}"
  pkill -9 hysteria >/dev/null 2>&1 || true
  rm -f ${HY_BIN}
  rm -rf ${HY_DIR}
  systemctl list-units --type=service --all | grep 'hy2-.*\.service' | awk '{print $1}' | xargs -r systemctl stop
  systemctl list-units --type=service --all | grep 'hy2-.*\.service' | awk '{print $1}' | xargs -r systemctl disable
  rm -f /etc/systemd/system/hy2-*.service
  systemctl daemon-reload
  echo -e "${GREEN}✅ 卸载完成${NC}"
  exit 0
}

# 支持参数 uninstall
if [ "$1" = "uninstall" ]; then
  uninstall
fi

echo -e "${BLUE}==== Hysteria v2 多节点一键部署（自动找空闲端口） ====${NC}"

# 用户输入
read -p "请输入要安装的节点数量（默认 5）: " USER_NUM
NUM_INSTANCES=${USER_NUM:-5}
if ! [[ "$NUM_INSTANCES" =~ ^[0-9]+$ ]] || [ "$NUM_INSTANCES" -le 0 ]; then
  echo -e "${RED}节点数量无效，使用默认 5${NC}"
  NUM_INSTANCES=5
fi

read -p "请输入起始端口（默认 8443）: " USER_PORT
BASE_PORT=${USER_PORT:-8443}
if ! [[ "$BASE_PORT" =~ ^[0-9]+$ ]] || [ "$BASE_PORT" -lt 1024 ] || [ "$BASE_PORT" -gt 65535 ]; then
  echo -e "${YELLOW}端口不在 1024-65535 范围内，使用默认 8443${NC}"
  BASE_PORT=8443
fi

# 端口检测函数
check_port() {
  local PORT=$1
  if ss -tuln | grep -q ":${PORT} "; then
    return 1
  else
    return 0
  fi
}

# 清理旧节点
echo -e "${YELLOW}清理旧节点及配置...${NC}"
pkill -9 hysteria >/dev/null 2>&1 || true
mkdir -p ${HY_DIR} ${LOGDIR}
rm -f ${HY_BIN}
rm -rf ${HY_DIR}/*

# 修复 nginx 冲突
if command -v nginx >/dev/null 2>&1; then
  echo -e "${BLUE}检测到 nginx，修复 default_server 冲突...${NC}"
  grep -rl "default_server" /etc/nginx/sites-enabled/ 2>/dev/null | while read -r f; do
    sed -i 's/default_server//g' "$f" || true
  done
  nginx -t >/dev/null 2>&1 && echo -e "${GREEN}nginx 配置检测通过${NC}" || echo -e "${YELLOW}nginx 检测失败，继续${NC}"
fi

# 安装依赖
echo -e "${BLUE}安装依赖（curl jq openssl socat ca-certificates）...${NC}"
apt-get update -y >/dev/null 2>&1
apt-get install -y curl jq openssl socat ca-certificates >/dev/null 2>&1

# 下载 hysteria
ARCH=$(uname -m)
case ${ARCH} in
  x86_64|amd64) HY_ARCH="amd64" ;;
  aarch64|arm64) HY_ARCH="arm64" ;;
  *) echo -e "${RED}不支持的架构: ${ARCH}${NC}"; exit 1 ;;
esac

echo -e "${BLUE}下载 hysteria 二进制文件...${NC}"
URLS=(
  "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
  "https://ghproxy.net/https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
  "https://cdn.jsdelivr.net/gh/apernet/hysteria@master/build/hysteria-linux-${HY_ARCH}"
)
for u in "${URLS[@]}"; do
  if curl -fsSL -o "${HY_BIN}" "$u"; then
    chmod +x "${HY_BIN}"
    echo -e "${GREEN}hysteria 下载成功${NC}"
    break
  fi
done
[ ! -f "${HY_BIN}" ] && echo -e "${RED}下载失败，请检查网络${NC}" && exit 1

# 自签名证书
if [ ! -f "${CERT}" ] || [ ! -f "${KEY}" ]; then
  echo -e "${BLUE}生成自签名证书...${NC}"
  openssl req -x509 -newkey rsa:2048 -keyout "${KEY}" -out "${CERT}" -days 3650 -nodes -subj "/CN=localhost" >/dev/null 2>&1
  chmod 600 "${KEY}"
  echo -e "${GREEN}证书生成完成${NC}"
else
  echo -e "${GREEN}检测到已有证书，跳过生成${NC}"
fi

IS_SYSTEMD=0
if [ "$(ps -p 1 -o comm=)" = "systemd" ]; then IS_SYSTEMD=1; fi

echo -e "${BLUE}开始创建节点并启动...${NC}"

CURRENT_PORT=$BASE_PORT
for i in $(seq 1 $NUM_INSTANCES); do
  # 自动找空闲端口
  while ! check_port $CURRENT_PORT; do
    ((CURRENT_PORT++))
    if [ $CURRENT_PORT -gt 65535 ]; then
      echo -e "${RED}没有足够端口分配给节点${NC}"
      exit 1
    fi
  done

  PASSWORD=$(openssl rand -base64 12)
  CFG="${HY_DIR}/config${i}.yaml"

  cat > "${CFG}" <<EOF
listen: ":${CURRENT_PORT}"
auth:
  type: password
  password: ${PASSWORD}
tls:
  cert: ${CERT}
  key: ${KEY}
obfuscate:
  type: srtp
disable-quic: true
EOF

  if [ $IS_SYSTEMD -eq 1 ]; then
    SERVICE="/etc/systemd/system/hy2-${i}.service"
    cat > "${SERVICE}" <<EOF
[Unit]
Description=Hysteria v2 Node ${i}
After=network.target

[Service]
ExecStart=${HY_BIN} server -c ${CFG}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now hy2-${i} >/dev/null 2>&1
  else
    nohup ${HY_BIN} server -c ${CFG} > ${LOGDIR}/hy2-${i}.log 2>&1 &
  fi

  NODE_PORTS[$i]=$CURRENT_PORT
  NODE_PASSWORDS[$i]=$PASSWORD
  ((CURRENT_PORT++))
done

sleep 1
IP=$(curl -s https://api.ipify.org || hostname -I | awk '{print $1}')
echo -e "${GREEN}安装完成，节点信息如下：${NC}"

for i in $(seq 1 $NUM_INSTANCES); do
  link="hy2://${NODE_PASSWORDS[$i]}@${IP}:${NODE_PORTS[$i]}?insecure=1#node${i}"
  echo -e "${link}${NC}"
done

echo -e "${GREEN}日志目录：${LOGDIR}${NC}"
echo -e "${BLUE}若使用 systemd，可用：systemctl status hy2-<n>${NC}"
