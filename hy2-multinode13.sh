#!/bin/bash
set -euo pipefail

NODES=10
PORTS=(443 8443 9443 10443 11443 12443 13443 14443 15443 16443)
BASE=/etc/hysteria2

# 1. 安装依赖
echo "🔧 [1/8] 安装依赖..."
apt update -qq
apt install -y curl socat openssl uuid-runtime

# 2. 安装 Hysteria
echo "🔧 [2/8] 安装 Hysteria..."
pkill -f hysteria || true
curl -Lo /usr/local/bin/hysteria https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-amd64
chmod +x /usr/local/bin/hysteria

# 3. 创建目录
mkdir -p "$BASE"/{clients,export} /var/log/hysteria2

# 4. 创建 TLS 证书
echo "🔧 [3/8] 生成 TLS 证书..."
if [[ ! -f "$BASE"/cert.pem || ! -f "$BASE"/key.pem ]]; then
  openssl req -x509 -newkey rsa:2048 -keyout "$BASE"/key.pem -out "$BASE"/cert.pem \
    -days 3650 -nodes -subj "/CN=localhost"
else
  echo " 证书已存在，跳过生成"
fi

# 5. 创建 systemd 模板
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

# 6. 部署多个实例
echo "🔧 [5/8] 生成节点配置..."
for ((i=1;i<=NODES;i++)); do
  idx=$((i-1))
  port=${PORTS[$idx]:-$(shuf -i20000-65000 -n1)}
  uuid=$(uuidgen)

  echo "$uuid" > "$BASE"/clients/uuid-"$i".txt

  cat > "$BASE"/config-"$i".yaml <<EOF
listen: ":${port}"
auth:
  type: password
  password: ${uuid}
tls:
  cert: ${BASE}/cert.pem
  key: ${BASE}/key.pem
obfuscate:
  type: srtp
disable_udp: false
EOF
done

# 7. 启动服务
echo "🔧 [6/8] 启动 systemd 服务..."
systemctl daemon-reload
for ((i=1;i<=NODES;i++)); do
  systemctl enable --now hy2@"$i"
done

# 8. 安装 cloudflared
echo "🔧 [7/8] 安装 Cloudflare Tunnel..."
if ! command -v cloudflared &>/dev/null; then
  curl -Lo /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
  chmod +x /usr/local/bin/cloudflared
fi

# 启动隧道（针对第一个节点 localhost:443）
nohup cloudflared tunnel --url http://localhost:443 > /var/log/cloudflared.log 2>&1 &
sleep 3

TUNNEL_URL=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' /var/log/cloudflared.log | head -1)

if [[ -z "$TUNNEL_URL" ]]; then
  echo "❌ 无法检测 Cloudflare Tunnel 地址，请检查 /var/log/cloudflared.log"
  exit 1
fi

echo "✅ Cloudflare Tunnel 地址: $TUNNEL_URL"

# 9. 导出客户端配置和链接
echo "🔧 [8/8] 导出客户端配置..."
mkdir -p "$BASE"/export
> "$BASE"/export/hysteria_links.txt

for ((i=1;i<=NODES;i++)); do
  idx=$((i-1))
  uuid=$(cat "$BASE"/clients/uuid-"$i".txt)
  port=${PORTS[$idx]}

  cat > "$BASE"/export/client-"$i".yaml <<EOF
server: ${TUNNEL_URL#https://}:$port
auth: "$uuid"
insecure: true
obfs:
  type: srtp
EOF

  echo "hy2://$uuid@${TUNNEL_URL#https://}:$port?insecure=1#节点$i" >> "$BASE"/export/hysteria_links.txt
done

# 10. 显示结果
echo ""
echo "✅ 所有部署完成！以下是节点链接（已隐藏真实 IP）："
cat "$BASE"/export/hysteria_links.txt
echo ""
echo "📁 客户端配置文件位于: $BASE/export/"
