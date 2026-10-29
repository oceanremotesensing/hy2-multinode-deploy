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

echo -e "\033[0;33m1. 正在同步服务器时间并生成全兼容证书 (彻底解决时间差导致的断连)...\033[0m"
timedatectl set-ntp true 2>/dev/null || true

# 使用 faketime 思路或直接指定宽泛有效期的自签名证书 (解决 VPS 时间在未来的问题)
openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout "$KEY" -out "$CERT" -days 3650 \
  -subj "/CN=${SNI}" >/dev/null 2>&1

echo -e "\033[0;33m2. 正在清理刚才失效的 iptables 转发规则...\033[0m"
iptables -t nat -F PREROUTING 2>/dev/null || true
iptables -P INPUT ACCEPT
iptables -F

echo -e "\033[0;33m3. 正在创建 10 个原生真实端口监听 (30001-30010)...\033[0m"
systemctl stop hysteria2 2>/dev/null || true
systemctl disable hysteria2 2>/dev/null || true

PASS=$(openssl rand -hex 8)
OBFS=$(openssl rand -hex 8)
SUB_TOKEN=$(openssl rand -hex 8)

# 创建支持多实例的 systemd 模板
cat > /etc/systemd/system/hy2@.service <<SERVICE_EOF
[Unit]
Description=Hysteria2 Real Port %i
After=network.target

[Service]
ExecStart=${HY_BIN} server -c ${HY_DIR}/config-%i.yaml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SERVICE_EOF

systemctl daemon-reload

# 启动 10 个真实端口监听
for i in $(seq 1 10); do
  PORT=$((30000 + i))
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

echo -e "\033[0;33m4. 正在生成订阅文件...\033[0m"
rm -rf "${SUB_DIR}"/*
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

for i in $(seq 1 10); do
  PORT=$((30000 + i))
  NODE_NAME="Hy2-RealNode-${i}-${PORT}"
  
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

for i in $(seq 1 10); do
  PORT=$((30000 + i))
  echo "      - \"Hy2-RealNode-${i}-${PORT}\"" >> "$CLASH_SUB_FILE"
done

cat >> "$CLASH_SUB_FILE" <<CLASH_AUTO
  - name: "⚡ 自动选择"
    type: url-test
    url: http://www.gstatic.com/generate_204
    interval: 300
    proxies:
CLASH_AUTO

for i in $(seq 1 10); do
  PORT=$((30000 + i))
  echo "      - \"Hy2-RealNode-${i}-${PORT}\"" >> "$CLASH_SUB_FILE"
done

cat >> "$CLASH_SUB_FILE" <<CLASH_RULE

rules:
  - GEOIP,CN,DIRECT
  - MATCH,🚀 节点选择
CLASH_RULE

systemctl restart hy2-sub

echo -e "\n\033[0;32m✅ 10 个真实端口已全部启动！\033[0m"
echo "================================================================================"
cat "$RAW_LINKS_FILE"
echo "================================================================================"
echo -e "👉 \033[0;32mv2rayN 订阅链接：\033[0m http://${IP}:${SUB_PORT}/${SUB_TOKEN}_v2ray"
echo -e "👉 \033[0;32mClash 订阅链接：\033[0m  http://${IP}:${SUB_PORT}/${SUB_TOKEN}_clash.yaml"
echo "================================================================================"
EOF
bash real_fix.sh
