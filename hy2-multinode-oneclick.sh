cat > real_fix.sh << 'EOF'
#!/usr/bin/env bash
set -e

SUB_PORT=25880
HY_BIN="/usr/local/bin/hysteria"
HY_DIR="/etc/hysteria2"
SUB_DIR="${HY_DIR}/sub"
CERT="${HY_DIR}/cert.pem"
KEY="${HY_DIR}/key.pem"
SNI="www.bing.com"

echo -e "\033[0;33m0. [DediRock 专属] 正在检查极简系统依赖并优化 UDP 缓冲区...\033[0m"
mkdir -p "${SUB_DIR}"

# 自动补齐 DediRock 极简镜像可能缺失的 python3 / curl / openssl / iptables
if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1 || ! command -v iptables >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1
    apt-get install -y curl openssl python3 iptables iproute2 ca-certificates >/dev/null 2>&1
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl openssl python3 iptables iproute ca-certificates >/dev/null 2>&1
  fi
fi

# 优化 KVM 架构下的 Hysteria2 UDP 收发缓冲区，防止高速下载断流
sysctl -w net.core.rmem_max=16777216 >/dev/null 2>&1 || true
sysctl -w net.core.wmem_max=16777216 >/dev/null 2>&1 || true

# 检查并安装 Hysteria2 核心
if [ ! -f "$HY_BIN" ]; then
  echo -e "\033[0;33m   正在下载安装 Hysteria2 核心...\033[0m"
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64|amd64) HY_ARCH="amd64" ;;
    aarch64|arm64) HY_ARCH="arm64" ;;
    *) echo "不支持的 CPU 架构: $ARCH" && exit 1 ;;
  esac
  curl -L -o "$HY_BIN" "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
  chmod +x "$HY_BIN"
fi

echo -e "\033[0;33m1. 正在同步时间并生成抗时间差自签名证书...\033[0m"
timedatectl set-ntp true 2>/dev/null || true

# 针对 DediRock 母鸡可能存在的时间偏快问题：生成证书前若支持则宽容处理
openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout "$KEY" -out "$CERT" -days 3650 \
  -subj "/CN=${SNI}" >/dev/null 2>&1

echo -e "\033[0;33m2. 正在生成 10 个【有效范围内 (15000~55000)】且【绝不连号】的端口...\033[0m"
PORTS=()
for i in $(seq 0 9); do
  BASE=$((15000 + i * 4000))
  while true; do
    OFFSET=$((RANDOM % 3300 + 100))
    CANDIDATE=$((BASE + OFFSET))
    if [ "$CANDIDATE" -ge 10000 ] && [ "$CANDIDATE" -le 60000 ] && [ "$CANDIDATE" -ne "$SUB_PORT" ]; then
      if ! ss -tuln 2>/dev/null | grep -q ":${CANDIDATE} "; then
        PORTS+=("$CANDIDATE")
        break
      fi
    fi
  done
done

echo -e "   已生成 10 个非连号端口: \033[0;36m${PORTS[*]}\033[0m"

echo -e "\033[0;33m3. 正在开启端口并配置系统防火墙...\033[0m"
iptables -t nat -F PREROUTING 2>/dev/null || true
iptables -P INPUT ACCEPT 2>/dev/null || true
iptables -F 2>/dev/null || true

iptables -I INPUT -p tcp --dport "${SUB_PORT}" -j ACCEPT 2>/dev/null || true
for p in "${PORTS[@]}"; do
  iptables -I INPUT -p udp --dport "${p}" -j ACCEPT 2>/dev/null || true
  iptables -I INPUT -p tcp --dport "${p}" -j ACCEPT 2>/dev/null || true
done

if command -v ufw >/dev/null 2>&1; then
  ufw allow "${SUB_PORT}/tcp" >/dev/null 2>&1 || true
  for p in "${PORTS[@]}"; do
    ufw allow "${p}/udp" >/dev/null 2>&1 || true
    ufw allow "${p}/tcp" >/dev/null 2>&1 || true
  done
fi

if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port="${SUB_PORT}/tcp" >/dev/null 2>&1 || true
  for p in "${PORTS[@]}"; do
    firewall-cmd --permanent --add-port="${p}/udp" >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1 || true
  done
  firewall-cmd --reload >/dev/null 2>&1 || true
fi

echo -e "\033[0;33m4. 正在启动 10 个独立真实端口监听 (已启用内存保护)...\033[0m"
systemctl stop hysteria2 2>/dev/null || true
systemctl disable hysteria2 2>/dev/null || true

for svc in $(systemctl list-units --type=service --all | grep -oE 'hy2@[0-9]+\.service'); do
  systemctl stop "$svc" 2>/dev/null || true
  systemctl disable "$svc" 2>/dev/null || true
done
rm -f "${HY_DIR}"/config-*.yaml

PASS=$(openssl rand -hex 8)
OBFS=$(openssl rand -hex 8)
SUB_TOKEN=$(openssl rand -hex 8)

# 针对 DediRock 1G/2G 机型加入 GOMEMLIMIT=40MiB，防止 10 个进程占用过多内存
cat > /etc/systemd/system/hy2@.service <<SERVICE_EOF
[Unit]
Description=Hysteria2 Real Port %i
After=network.target

[Service]
Environment="GOMEMLIMIT=40MiB"
ExecStart=${HY_BIN} server -c ${HY_DIR}/config-%i.yaml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SERVICE_EOF

systemctl daemon-reload

for PORT in "${PORTS[@]}"; do
  cat > "${HY_DIR}/config-${PORT}.yaml" <<CFG_EOF
listen: 0.0.0.0:${PORT}

tls:
  cert: ${CERT}
  key: ${KEY}

obfs:
  type: salamander
  salamander:
    password: "${OBFS}"

auth:
  type: password
  password: "${PASS}"
CFG_EOF
  systemctl enable "hy2@${PORT}" >/dev/null 2>&1
  systemctl restart "hy2@${PORT}"
done

echo -e "\033[0;33m5. 正在生成 v2rayN 与 Clash 订阅文件...\033[0m"
rm -rf "${SUB_DIR:?}"/*
IP=$(curl -s4m 5 https://api.ipify.org || curl -s4m 5 https://ifconfig.me)

RAW_LINKS_FILE="${SUB_DIR}/links.txt"
V2RAY_SUB_FILE="${SUB_DIR}/${SUB_TOKEN}_v2ray"
CLASH_SUB_FILE="${SUB_DIR}/${SUB_TOKEN}_clash.yaml"

cat > "$CLASH_SUB_FILE" <<CLASH_HEAD
port: 7890
socks-port: 7891
allow-lan: true
mode: rule
log-level: info
external-controller: 127.0.0.1:9090
proxies:
CLASH_HEAD

for idx in "${!PORTS[@]}"; do
  NODE_NUM=$((idx + 1))
  PORT="${PORTS[$idx]}"
  NODE_NAME="DediRock-Hy2-${NODE_NUM}-${PORT}"
  
  URI="hy2://${PASS}@${IP}:${PORT}/?insecure=1&sni=${SNI}&obfs=salamander&obfs-password=${OBFS}#${NODE_NAME}"
  echo "$URI" >> "$RAW_LINKS_FILE"

  cat >> "$CLASH_SUB_FILE" <<CLASH_NODE
  - name: "${NODE_NAME}"
    type: hysteria2
    server: ${IP}
    port: ${PORT}
    password: "${PASS}"
    obfs: salamander
    obfs-password: "${OBFS}"
    sni: ${SNI}
    skip-cert-verify: true
    udp: true
CLASH_NODE
done

base64 -w 0 "$RAW_LINKS_FILE" > "$V2RAY_SUB_FILE"

cat >> "$CLASH_SUB_FILE" <<CLASH_GROUP

proxy-groups:
  - name: "🚀 节点选择"
    type: select
    proxies:
      - "⚡ 自动选择"
CLASH_GROUP

for idx in "${!PORTS[@]}"; do
  NODE_NUM=$((idx + 1))
  PORT="${PORTS[$idx]}"
  echo "      - \"DediRock-Hy2-${NODE_NUM}-${PORT}\"" >> "$CLASH_SUB_FILE"
done

cat >> "$CLASH_SUB_FILE" <<CLASH_AUTO
  - name: "⚡ 自动选择"
    type: url-test
    url: http://www.gstatic.com/generate_204
    interval: 300
    tolerance: 50
    proxies:
CLASH_AUTO

for idx in "${!PORTS[@]}"; do
  NODE_NUM=$((idx + 1))
  PORT="${PORTS[$idx]}"
  echo "      - \"DediRock-Hy2-${NODE_NUM}-${PORT}\"" >> "$CLASH_SUB_FILE"
done

cat >> "$CLASH_SUB_FILE" <<CLASH_RULE

rules:
  - GEOIP,CN,DIRECT
  - MATCH,🚀 节点选择
CLASH_RULE

cat > /etc/systemd/system/hy2-sub.service <<SUB_EOF
[Unit]
Description=Hysteria2 Subscription HTTP Server
After=network.target

[Service]
Type=simple
WorkingDirectory=${SUB_DIR}
ExecStart=/usr/bin/env python3 -m http.server ${SUB_PORT}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SUB_EOF

systemctl daemon-reload
systemctl enable hy2-sub >/dev/null 2>&1
systemctl restart hy2-sub

echo -e "\n\033[0;32m✅ DediRock 10 个非连号真实端口已全部启动并放行！\033[0m"
echo -e "当前开启的节点端口: \033[0;36m${PORTS[*]}\033[0m"
echo "================================================================================"
cat "$RAW_LINKS_FILE"
echo "================================================================================"
echo -e "👉 \033[0;32mv2rayN 订阅链接：\033[0m http://${IP}:${SUB_PORT}/${SUB_TOKEN}_v2ray"
echo -e "👉 \033[0;32mClash 订阅链接：\033[0m  http://${IP}:${SUB_PORT}/${SUB_TOKEN}_clash.yaml"
echo "================================================================================"
EOF
bash real_fix.sh
