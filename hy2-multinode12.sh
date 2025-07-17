#!/bin/bash
set -e

echo "🔧 [1/8] 安装依赖..."
apt update
apt install -y curl socat openssl jq uuid-runtime

echo "🔧 [2/8] 下载 Hysteria v2..."
pkill -f hysteria || true
rm -f /usr/local/bin/hysteria
curl -Lo /usr/local/bin/hysteria https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-amd64
chmod +x /usr/local/bin/hysteria

mkdir -p /etc/hysteria2 /etc/hysteria2/clients /var/log/hysteria2
cd /etc/hysteria2

echo "🔧 [3/8] 生成自签名 TLS 证书..."
if [[ ! -f cert.pem || ! -f key.pem ]]; then
  openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes -subj "/CN=localhost"
else
  echo "证书已存在，跳过生成"
fi

echo "🔧 [4/8] 设置端口和 UUID..."
PORTS=(443 8443 9443 10443 11443 12443 13443 14443 15443 16443)

IP=$(curl -s https://api.ipify.org)
[[ -z "$IP" ]] && echo "无法获取公网 IP" && exit 1

for i in {1..10}; do
  idx=$((i-1))
  UUID=$(uuidgen)
  
  echo "$UUID" > /etc/hysteria2/clients/uuid$i.txt

  cat > config$i.yaml <<EOF
listen: ":${PORTS[$idx]}"
auth:
  type: password
  password: $UUID
tls:
  cert: /etc/hysteria2/cert.pem
  key: /etc/hysteria2/key.pem
obfuscate:
  type: srtp
disable_udp: false
EOF

  cat > /etc/systemd/system/hy2-$i.service <<EOF
[Unit]
Description=Hysteria v2 Node $i
After=network.target

[Service]
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria2/config$i.yaml
Restart=always
RestartSec=5
StandardOutput=append:/var/log/hysteria2/hy2-$i.log
StandardError=append:/var/log/hysteria2/hy2-$i.err.log

[Install]
WantedBy=multi-user.target
EOF
done

echo "🔧 [5/8] 重载 systemd 并启动服务..."
systemctl daemon-reload
for i in {1..10}; do
  systemctl enable --now hy2-$i
done

echo "🔧 [6/8] 导出客户端配置文件和链接..."
mkdir -p /etc/hysteria2/export

for i in {1..10}; do
  idx=$((i-1))
  UUID=$(cat /etc/hysteria2/clients/uuid$i.txt)
  PORT=${PORTS[$idx]}

  # 生成客户端配置文件
  cat > /etc/hysteria2/export/client$i.yaml <<EOF
server: $IP:$PORT
auth: "$UUID"
insecure: true
obfs: 
  type: srtp
EOF

  echo "hy2://$UUID@$IP:$PORT?insecure=1#节点$i" >> /etc/hysteria2/export/hysteria_links.txt
done

echo "🔧 [7/8] 可选：自动开放端口（UFW）"
if command -v ufw > /dev/null; then
  for port in "${PORTS[@]}"; do
    ufw allow $port/tcp || true
    ufw allow $port/udp || true
  done
  ufw reload
else
  echo "UFW 未安装，跳过防火墙开放"
fi

echo "✅ [8/8] 所有节点部署完成！以下是链接："
cat /etc/hysteria2/export/hysteria_links.txt
echo ""
echo "📁 客户端配置已导出到：/etc/hysteria2/export/"
