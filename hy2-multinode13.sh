#!/bin/bash
set -euo pipefail

# --- 配置 ---
# 要开放的端口列表，可以自行修改
PORTS=(443 8443 9443 10443 11443 12443 13443 14443 15443 16443)
# 要创建的节点数量，应与上面的端口数量一致
NODES=10
# Hysteria 配置文件和证书的基础目录
BASE=/etc/hysteria2

# --- 脚本开始 ---

echo "🔧 [1/8] 安装依赖..."
apt update -qq
apt install -y curl socat openssl uuid-runtime

echo "🔧 [2/8] 安装 Hysteria..."
# 确保旧进程已停止
pkill -f hysteria || true
# 从 GitHub 下载最新版 Hysteria
curl -Lo /usr/local/bin/hysteria https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-amd64
# 添加执行权限
chmod +x /usr/local/bin/hysteria

echo "🔧 [3/8] 生成 TLS 证书..."
mkdir -p "$BASE"/{clients,export} /var/log/hysteria2
if [[ ! -f "$BASE/cert.pem" || ! -f "$BASE/key.pem" ]]; then
  echo "  正在生成新的自签名证书..."
  openssl req -x509 -newkey rsa:2048 -keyout "$BASE/key.pem" -out "$BASE/cert.pem" -days 3650 -nodes -subj "/CN=localhost"
else
  echo "  证书已存在，跳过生成。"
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

echo "🔧 [7/8] 生成并输出客户端配置链接..."
# 尝试获取公网 IP
IP=$(curl -s https://api.ipify.org)
if [[ -z "$IP" ]]; then
  echo "❌ 获取公网 IP 失败，请检查服务器网络！"
  exit 1
fi

LINKS_FILE="$BASE/export/hysteria_links.txt"
> "$LINKS_FILE" # 清空旧文件

echo ""
echo "🔗 Hysteria 多节点配置链接："
echo "=================================================="
for ((i=1; i<=NODES; i++)); do
  UUID=$(cat "$BASE/clients/uuid$i.txt")
  PORT=${PORTS[$((i-1))]}
  LINK="hy2://$UUID@$IP:$PORT?insecure=1&sni=localhost#MassiveGrid-Node$i"
  echo "$LINK"
  echo "$LINK" >> "$LINKS_FILE"
done
echo "=================================================="
echo ""
echo "✅ 部署完成！"
echo "✅ 所有配置链接已自动保存到文件: $LINKS_FILE"
