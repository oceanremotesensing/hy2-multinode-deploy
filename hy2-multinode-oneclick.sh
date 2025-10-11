#!/usr/bin/env bash
# hy2-multinode-oneclick-randomport-fixed.sh
# Hysteria v2 多节点随机端口自动部署（端口冲突自动重试）

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

HY_DIR="/etc/hysteria2"
HY_BIN="/usr/local/bin/hysteria"
LOGDIR="${HY_DIR}/logs"
CERT="${HY_DIR}/cert.pem"
KEY="${HY_DIR}/key.pem"
MAX_RETRIES=20   # 每个节点端口重试次数

if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}请以 root 用户运行此脚本${NC}"
  exit 1
fi

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

[ "$1" = "uninstall" ] && uninstall

echo -e "${BLUE}==== Hysteria v2 多节点随机端口一键部署 ====${NC}"

# 用户输入
read -p "请输入要安装的节点数量（默认 5）: " USER_NUM
NUM_INSTANCES=${USER_NUM:-5}
[[ ! "$NUM_INSTANCES" =~ ^[0-9]+$ ]] && NUM_INSTANCES=5

get_random_port() {
  for ((i=0;i<$MAX_RETRIES;i++)); do
    PORT=$((RANDOM % 64512 + 1024))
    ss -tuln | grep -q ":${PORT} " || return $PORT
  done
  return 0
}

echo -e "${YELLOW}清理旧节点及配置...${NC}"
pkill -9 hysteria >/dev/null 2>&1 || true
mkdir -p ${HY_DIR} ${LOGDIR}
rm -f ${HY_BIN}
rm -rf ${HY_DIR}/*

# nginx 冲突
if command -v nginx >/dev/null 2>&1; then
  grep -rl "default_server" /etc/nginx/sites-enabled/ 2>/dev/null | while read -r f; do
    sed -i 's/default_server//g' "$f" || true
  done
  nginx -t >/dev/null 2>&1 && echo -e "${GREEN}nginx 配置检测通过${NC}" || echo -e "${YELLOW}nginx 检测失败，继续${NC}"
fi

# 安装依赖
apt-get update -y >/dev/null 2>&1
apt-get install -y curl jq openssl socat ca-certificates >/dev/null 2>&1

# 下载 hysteria
ARCH=$(uname -m)
case $ARCH in x86_64|amd64) HY_ARCH="amd64";; aarch64|arm64) HY_ARCH="arm64";; *) echo -e "${RED}不支持架构${NC}"; exit 1;; esac
URLS=(
  "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
  "https://ghproxy.net/https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
  "https://cdn.jsdelivr.net/gh/apernet/hysteria@master/build/hysteria-linux-${HY_ARCH}"
)
for u in "${URLS[@]}"; do
  if curl -fsSL -o "${HY_BIN}" "$u"; then chmod +x "${HY_BIN}"; break; fi
done
[ ! -f "${HY_BIN}" ] && echo -e "${RED}下载失败${NC}" && exit 1

# 证书
if [ ! -f "${CERT}" ] || [ ! -f "${KEY}" ]; then
  openssl req -x509 -newkey rsa:2048 -keyout "${KEY}" -out "${CERT}" -days 3650 -nodes -subj "/CN=localhost" >/dev/null 2>&1
  chmod 600 "${KEY}"
fi

IS_SYSTEMD=0
[ "$(ps -p 1 -o comm=)" = "systemd" ] && IS_SYSTEMD=1

declare -A NODE_PORTS NODE_PASSWORDS

echo -e "${BLUE}开始创建节点并启动...${NC}"

for i in $(seq 1 $NUM_INSTANCES); do
  for ((r=1;r<=$MAX_RETRIES;r++)); do
    PORT=$((RANDOM % 64512 + 1024))
    ss -tuln | grep -q ":${PORT} " && continue
    PASSWORD=$(openssl rand -base64 12)
    CFG="${HY_DIR}/config${i}.yaml"
    cat > "${CFG}" <<EOF
listen: ":${PORT}"
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

    sleep 0.3
    # 检测端口是否绑定成功
    if ss -tuln | grep -q ":${PORT} "; then
      NODE_PORTS[$i]=$PORT
      NODE_PASSWORDS[$i]=$PASSWORD
      break
    fi
  done
  [ -z "${NODE_PORTS[$i]}" ] && echo -e "${RED}节点 $i 创建失败，请重试${NC}"
done

IP=$(curl -s https://api.ipify.org || hostname -I | awk '{print $1}')
echo -e "${GREEN}安装完成，节点信息如下：${NC}"
for i in $(seq 1 $NUM_INSTANCES); do
  [ -n "${NODE_PORTS[$i]}" ] && echo -e "hy2://${NODE_PASSWORDS[$i]}@${IP}:${NODE_PORTS[$i]}?insecure=1#node${i}"
done

echo -e "${GREEN}日志目录：${LOGDIR}${NC}"
echo -e "${BLUE}若使用 systemd，可用：systemctl status hy2-<n>${NC}"
echo -e "${GREEN}🎉 一键部署完成！${NC}"
