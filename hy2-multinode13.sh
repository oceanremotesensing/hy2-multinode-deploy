#!/bin/bash
set -euo pipefail

# 端口列表（可按需调整）
PORTS=(443 8443 9443 10443 11443 12443 13443 14443 15443 16443)
NODES=10
BASE=/etc/hysteria2

echo "🔧 [1/8] 安装依赖..."
apt update -qq
apt install -y curl socat openssl uuid-runtime

echo "🔧 [2/8] 安装 Hysteria..."
pkill -f hysteria || true
curl -Lo /usr/local/bin/hysteria https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-amd64
chmod +x /usr/local/bin/hysteria

echo "🔧 [3/8] 准备目录和证书..."
mkdir -p "$BASE"/{clients,export} /var/log/hysteria2

if [[ ! -f "$BASE/cert.pem" || ! -f "$BASE/key.pem" ]]; then
  openssl req -x509 -newkey rsa:2048 -keyout "$BASE/key.pem" -out "$BASE/cert.pem" -days 3650 -nodes -subj "/CN=localhost"
else
  echo " 证书已存在，跳过生成"
fi

echo "🔧 [4/8] 创建 systemd 模板..."
cat > /etc/systemd/system/hy2@.service <<'EOF'
[Unit]
Description=Hysteria v2 Instance %i
After=network.target

[Service]
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria2/config-%i.yaml
Restart=always
RestartSec=5s
StandardOutput=append:/var/log/hysteria2/hy2-%i.log
StandardError=append:/var/log/hysteria2/hy2-%i.err.log

[Install]
WantedBy=multi-user.target
EOF

echo "🔧 [5/8] 生成 $NODES 个节点配置..."
for ((i=1; i<=NODES; i++)); do
  idx=$((i-1))
  PORT=${PORTS[$idx]}
  UUID=$(uuidgen)

  echo "$UUID" > "$BASE/clients/uuid$i.txt"

  cat > "$BASE/config-$i.yaml" <<EOF
listen: ":$PORT"
auth:
  type: password
  password: $UUID
tls:
  cert: $BASE/cert.pem
  key: $BASE/key.pem
obfuscate:
  type: srtp
disable_udp: false
EOF
done

echo "🔧 [6/8] 启动 systemd 服务..."
systemctl daemon-reload
for ((i=1; i<=NODES; i++)); do
  systemctl enable --now hy2@"$i"
done

# 可选：安装 cloudflared 并启动隧道（如果你不需要隐藏IP可以注释掉此段）
echo "🔧 [7/8] 安装 Cloudflare Tunnel (可选)..."
if ! command -v cloudflared &>/dev/null; then
  curl -Lo /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
  chmod +x /usr/local/bin/cloudflared
fi

# 启动隧道指向第一个节点 443 端口，后台运行
nohup cloudflared tunnel --url http://localhost:443 > /var/log/cloudflared.log 2>&1 &
sleep 3

TUNNEL_URL=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' /var/log/cloudflared.log | head -1)

if [[ -z "$TUNNEL_URL" ]]; then
  echo "⚠️ 未检测到 Cloudflare Tunnel 地址，继续用公网IP"
fi

# 获取公网IP（如果有隧道则用隧道域名）
IP=${TUNNEL_URL#https://}
if [[ -z "$IP" ]]; then
  IP=$(curl -s https://api.ipify.org)
fi

echo "🔧 [8/8] 生成客户端链接并导出..."

LINKS_FILE="$BASE/export/hysteria_links.txt"
> "$LINKS_FILE"

echo "🔗 Hysteria 节点链接："
for ((i=1; i<=NODES; i++)); do
  UUID=$(cat "$BASE/clients/uuid$i.txt")
  PORT=${PORTS[$((i-1))]}
  LINK="hy2://$UUID@$IP:$PORT?insecure=1#节点$i"
  echo "$LINK" | tee -a "$LINKS_FILE"
done

echo ""
echo "✅ 部署完成！客户端配置文件和链接已保存至：$BASE/export/"
