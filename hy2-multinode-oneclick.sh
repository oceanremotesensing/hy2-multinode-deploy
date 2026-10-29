cat > fix_hy2.sh << 'EOF'
#!/usr/bin/env bash
set -e

SUB_PORT=25880
HY_DIR="/etc/hysteria2"
SUB_DIR="${HY_DIR}/sub"
CFG="${HY_DIR}/config.yaml"
SNI="www.bing.com"

echo -e "\033[0;33m1. 正在彻底清空服务器内部防火墙拦截规则...\033[0m"
ufw disable 2>/dev/null || true
systemctl stop firewalld 2>/dev/null || true
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT
iptables -F

echo -e "\033[0;33m2. 正在将端口修改为 30001-30010 并开启单密码高兼容模式...\033[0m"
PASS=$(openssl rand -hex 8)
OBFS=$(openssl rand -hex 8)
SUB_TOKEN=$(openssl rand -hex 8)

# 监听 30000 端口作为主端口
cat > "$CFG" <<CFG_EOF
listen: :30000

tls:
  cert: ${HY_DIR}/cert.pem
  key: ${HY_DIR}/key.pem

obfs:
  type: salamander
  salamander:
    password: "${OBFS}"

auth:
  type: password
  password: "${PASS}"
CFG_EOF

# 使用 iptables 将 30001~30010 这 10 个端口全部转发到 30000
iptables -t nat -F PREROUTING 2>/dev/null || true
iptables -t nat -I PREROUTING -p udp --dport 30001:30010 -j REDIRECT --to-ports 30000

echo -e "\033[0;33m3. 正在重新生成 10 个独立端口节点及订阅...\033[0m"
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

# 生成 30001 到 30010 的 10 个节点
for i in $(seq 1 10); do
  PORT=$((30000 + i))
  NODE_NAME="Hy2-Node-${i}-${PORT}"
  
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
  echo "      - \"Hy2-Node-${i}-${PORT}\"" >> "$CLASH_SUB_FILE"
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
  echo "      - \"Hy2-Node-${i}-${PORT}\"" >> "$CLASH_SUB_FILE"
done

cat >> "$CLASH_SUB_FILE" <<CLASH_RULE

rules:
  - GEOIP,CN,DIRECT
  - MATCH,🚀 节点选择
CLASH_RULE

systemctl restart hysteria2 hy2-sub

echo -e "\n\033[0;32m✅ 修复完成！已更换为 30001-30010 端口，并清除了所有防火墙限制！\033[0m"
echo "================================================================================"
echo -e "\033[0;36m【全新的 10 个独立端口节点 (直接复制导入 v2rayN)】\033[0m"
cat "$RAW_LINKS_FILE"
echo "================================================================================"
echo -e "👉 \033[0;32mv2rayN 新订阅链接：\033[0m http://${IP}:${SUB_PORT}/${SUB_TOKEN}_v2ray"
echo -e "👉 \033[0;32mClash 新订阅链接：\033[0m  http://${IP}:${SUB_PORT}/${SUB_TOKEN}_clash.yaml"
echo "================================================================================"
EOF
bash fix_hy2.sh
