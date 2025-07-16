#!/bin/bash
set -e

echo "🔧 安装必备组件..."
apt update
apt install -y curl socat openssl

echo "🔧 安装 hysteria..."
pkill -f hysteria || true
rm -f /usr/local/bin/hysteria
curl -Lo /usr/local/bin/hysteria https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-amd64
chmod +x /usr/local/bin/hysteria

mkdir -p /etc/hysteria2
cd /etc/hysteria2

echo "🔧 生成自签名证书..."
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes -subj "/CN=localhost"

# 10个端口和密码
PORTS=(443 8443 9443 10443 11443 12443 13443 14443 15443 16443)
PASSWORDS=(
  "PwdHy2_1" "PwdHy2_2" "PwdHy2_3" "PwdHy2_4" "PwdHy2_5"
  "PwdHy2_6" "PwdHy2_7" "PwdHy2_8" "PwdHy2_9" "PwdHy2_10"
)

IP="107.174.88.122"

for i in {1..10}; do
  idx=$((i-1))
  cat > config$i.yaml <<EOF
listen: ":${PORTS[$idx]}"
auth:
  type: password
  password: ${PASSWORDS[$idx]}
masquerade:
  type: http
  http:
    host: www.cloudflare.com
    path: /
tls:
  cert: /etc/hysteria2/cert.pem
  key: /etc/hysteria2/key.pem
obfuscate:
  type: "srtp"  # 混淆方式，可换为 other 支持的类型
EOF

  cat > /etc/systemd/system/hy2-$i.service <<EOF
[Unit]
Description=Hysteria v2 Node $i
After=network.target

[Service]
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria2/config$i.yaml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
done

systemctl daemon-reload

for i in {1..10}; do
  systemctl enable --now hy2-$i
done

echo ""
echo "✅ 节点链接："
for idx in {0..9}; do
  num=$((idx+1))
  echo "hy2://${PASSWORDS[$idx]}@$IP:${PORTS[$idx]}?insecure=1&sni=www.cloudflare.com#节点$num"
done
