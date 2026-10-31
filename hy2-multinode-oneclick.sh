cat > real_fix.sh << 'EOF'
#!/usr/bin/env bash
set -e

SUB_PORT=25880
# 使用独立二进制路径，防止与之前一键脚本残留的同名菜单脚本冲突
HY_BIN="/usr/local/bin/hy2-core"
HY_DIR="/etc/hysteria2"
SUB_DIR="${HY_DIR}/sub"
CERT="${HY_DIR}/cert.pem"
KEY="${HY_DIR}/key.pem"
SNI="www.bing.com"

echo -e "\033[0;33m0. [Ubuntu 26 专属] 正在检查基础依赖与网络工具...\033[0m"
mkdir -p "${SUB_DIR}"

if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1; then
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y curl openssl python3 iproute2 ca-certificates >/dev/null 2>&1 || true
fi

# 优化 UDP 缓冲区
sysctl -w net.core.rmem_max=16777216 >/dev/null 2>&1 || true
sysctl -w net.core.wmem_max=16777216 >/dev/null 2>&1 || true

# 校验并下载官方正版 Hysteria2 核心
if ! "$HY_BIN" version 2>/dev/null | grep -q "v2\."; then
  echo -e "\033[0;33m   正在下载官方 Hysteria2 v2 核心到 ${HY_BIN}...\033[0m"
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64|amd64) HY_ARCH="amd64" ;;
    aarch64|arm64) HY_ARCH="arm64" ;;
    *) echo "不支持的 CPU 架构: $ARCH" && exit 1 ;;
  esac
  rm -f "$HY_BIN"
  curl -L -o "$HY_BIN" "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
  chmod +x "$HY_BIN"
fi

echo -e "\033[0;33m1. 正在通过 HTTPS 强制校准 DediRock 服务器时间并生成 v3 证书...\033[0m"
# 直接从微软服务器获取标准 UTC 时间并校准系统时钟，解决极简系统 NTP 失效问题
HTTP_DATE=$(curl -sI --max-time 5 https://www.bing.com | grep -i '^date:' | sed 's/^[dD]ate: //;s/\r//')
if [ -n "$HTTP_DATE" ]; then
  date -s "$HTTP_DATE" >/dev/null 2>&1 || true
fi

rm -f "$KEY" "$CERT"
openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout "$KEY" -out "$CERT" -days 3650 \
  -subj "/CN=${SNI}" \
  -addext "subjectAltName = DNS:${SNI}" >/dev/null 2>&1 || \
openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout "$KEY" -out "$CERT" -days 3650 \
  -subj "/CN=${SNI}" >/dev/null 2>&1
chmod 644 "$KEY" "$CERT"

echo -e "\033[0;33m2. 正在生成 10 个【有效范围内 (15000~55000)】且【绝不连号】的端口...\033[0m"
# 先停掉所有旧服务，释放端口
systemctl stop hysteria2 2>/dev/null || true
systemctl disable hysteria2 2>/dev/null || true
systemctl stop hysteria-server 2>/dev/null || true
systemctl disable hysteria-server 2>/dev/null || true

for svc in $(systemctl list-units --type=service --all | grep -oE 'hy2@[0-9]+\.service'); do
  systemctl stop "$svc" 2>/dev/null || true
  systemctl disable "$svc" 2>/dev/null || true
done
rm -f "${HY_DIR}"/config-*.yaml

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

echo -e "\033[0;33m3. [关键步骤] 正在彻底清除 Ubuntu 26 的 nftables 转发劫持并开放所有端口...\033[0m"
# 1) 关闭 UFW 防止与底层规则冲突
if command -v ufw >/dev/null 2>&1; then
  ufw disable >/dev/null 2>&1 || true
fi

# 2) 彻底清空 Ubuntu 26 默认的 nftables 规则集（清除之前脚本残留的端口跳跃劫持！）
if command -v nft >/dev/null 2>&1; then
  nft flush ruleset 2>/dev/null || true
fi

# 3) 清空传统 iptables 的所有表并设为全部放行
if command -v iptables >/dev/null 2>&1; then
  iptables -t nat -F 2>/dev/null || true
  iptables -t nat -X 2>/dev/null || true
  iptables -t mangle -F 2>/dev/null || true
  iptables -F 2>/dev/null || true
  iptables -X 2>/dev/null || true
  iptables -P INPUT ACCEPT 2>/dev/null || true
  iptables -P FORWARD ACCEPT 2>/dev/null || true
  iptables -P OUTPUT ACCEPT 2>/dev/null || true
fi

echo -e "\033[0;33m4. 正在启动 10 个真实端口监听并验证 UDP 状态...\033[0m"
PASS=$(openssl rand -hex 8)
OBFS=$(openssl rand -hex 8)
SUB_TOKEN=$(openssl rand -hex 8)

cat > /etc/systemd/system/hy2@.service <<SERVICE_EOF
[Unit]
Description=Hysteria2 Real Port %i
After=network.target

[Service]
Type=simple
User=root
Environment="GOMEMLIMIT=45MiB"
ExecStart=${HY_BIN} server -c ${HY_DIR}/config-%i.yaml
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SERVICE_EOF

systemctl daemon-reload

for PORT in "${PORTS[@]}"; do
  cat > "${HY_DIR}/config-${PORT}.yaml" <<CFG_EOF
listen: :${PORT}

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

sleep 2
echo -e "   --- 正在自检服务器本地 UDP 端口监听状态 ---"
for PORT in "${PORTS[@]}"; do
  if ss -uln 2>/dev/null | grep -q ":${PORT} "; then
    echo -e "   ✅ 端口 \033[0;32m${PORT}/UDP\033[0m 监听成功！"
  else
    echo -e "   ❌ 端口 \033[0;31m${PORT}/UDP\033[0m 未能启动，请运行 journalctl -u hy2@${PORT} -n 20 查看原因"
  fi
done

echo -e "\033[0;33m5. 正在生成无死锁的 v2rayN 与 Clash 订阅文件...\033[0m"
rm -rf "${SUB_DIR:?}"/*
IP=$(curl -s4m 5 https://api.ipify.org || curl -s4m 5 https://ifconfig.me)

RAW_LINKS_FILE="${SUB_DIR}/links.txt"
V2RAY_SUB_FILE="${SUB_DIR}/${SUB_TOKEN}_v2ray"
CLASH_SUB_FILE="${SUB_DIR}/${SUB_TOKEN}_clash.yaml"

cat > "$CLASH_SUB_FILE" <<CLASH_HEAD
mixed-port: 7890
allow-lan: true
mode: rule
log-level: info
ipv6: false
external-controller: 127.0.0.1:9090
dns:
  enable: true
  ipv6: false
  enhanced-mode: fake-ip
  nameserver:
    - 223.5.5.5
    - 119.29.29.29
proxies:
CLASH_HEAD

for idx in "${!PORTS[@]}"; do
  NODE_NUM=$((idx + 1))
  PORT="${PORTS[$idx]}"
  NODE_NAME="DediRock-Hy2-${NODE_NUM}-${PORT}"
  
  URI="hysteria2://${PASS}@${IP}:${PORT}/?insecure=1&sni=${SNI}&obfs=salamander&obfs-password=${OBFS}#${NODE_NAME}"
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

# 移除 GEOIP,CN 规则，防止客户端因缺少 GeoIP 数据库而卡死测速
cat >> "$CLASH_SUB_FILE" <<CLASH_RULE

rules:
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - DOMAIN-SUFFIX,cn,DIRECT
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

echo -e "\n\033[0;32m✅ 全部配置完成！请重新复制下方的新订阅或节点进行测试：\033[0m"
echo "================================================================================"
cat "$RAW_LINKS_FILE"
echo "================================================================================"
echo -e "👉 \033[0;32mv2rayN 订阅链接：\033[0m http://${IP}:${SUB_PORT}/${SUB_TOKEN}_v2ray"
echo -e "👉 \033[0;32mClash 订阅链接：\033[0m  http://${IP}:${SUB_PORT}/${SUB_TOKEN}_clash.yaml"
echo "================================================================================"
EOF
bash real_fix.sh
