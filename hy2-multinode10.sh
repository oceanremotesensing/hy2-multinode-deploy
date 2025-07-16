#!/bin/bash
set -e

echo "🔧 安装必备组件..."
apt update && apt install -y curl socat openssl nginx

echo "🔧 安装 hysteria..."
pkill -f hysteria || true
rm -f /usr/local/bin/hysteria
curl -Lo /usr/local/bin/hysteria https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-amd64
chmod +x /usr/local/bin/hysteria

echo "🔧 安装 xray..."
pkill -f xray || true
rm -f /usr/local/bin/xray
curl -Lo /usr/local/bin/xray https://github.com/XTLS/Xray-core/releases/latest/download/xray-linux-64.zip
unzip -o xray-linux-64.zip xray -d /usr/local/bin/
chmod +x /usr/local/bin/xray

mkdir -p /etc/hysteria2 /etc/xray /etc/systemd/system

# 固定公网IP
IP="216.144.235.198"

# Hysteria2 5 节点配置
PORTS=(443 8443 9443 10443 11443)
PASSWORDS=("Hy2Pwd1" "Hy2Pwd2" "Hy2Pwd3" "Hy2Pwd4" "Hy2Pwd5")

openssl req -x509 -newkey rsa:2048 -keyout /etc/hysteria2/key.pem -out /etc/hysteria2/cert.pem -days 3650 -nodes -subj "/CN=localhost"

for i in {1..5}; do
  j=$((i-1))
  cat > /etc/hysteria2/config$i.yaml <<EOF
listen: ":${PORTS[$j]}"
auth:
  type: password
  password: ${PASSWORDS[$j]}
masquerade:
  type: proxy
  proxy:
    url: https://www.cloudflare.com
    rewriteHost: true
tls:
  cert: /etc/hysteria2/cert.pem
  key: /etc/hysteria2/key.pem
EOF

  cat > /etc/systemd/system/hy2-$i.service <<EOF
[Unit]
Description=Hysteria2 Node $i
After=network.target

[Service]
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria2/config$i.yaml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
done

# Reality 节点配置
REALITY_PORTS=(20443 21443 22443 23443 24443)
REALITY_TAGS=("reality1" "reality2" "reality3" "reality4" "reality5")
REALITY_SHORTIDS=("10000000000000000000000000000000" "20000000000000000000000000000000" "30000000000000000000000000000000" "40000000000000000000000000000000" "50000000000000000000000000000000")
REALITY_PRIVATE_KEYS=()
REALITY_PUBLIC_KEYS=()

for i in {1..5}; do
  keypair=$(xray x25519)
  PRIVATE=$(echo "$keypair" | grep 'Private key' | awk '{print $NF}')
  PUBLIC=$(echo "$keypair" | grep 'Public key' | awk '{print $NF}')
  REALITY_PRIVATE_KEYS+=("$PRIVATE")
  REALITY_PUBLIC_KEYS+=("$PUBLIC")

  cat > /etc/xray/reality_$i.json <<EOF
{
  "log": { "loglevel": "none" },
  "inbounds": [{
    "port": ${REALITY_PORTS[$((i-1))]},
    "protocol": "vless",
    "settings": {
      "clients": [{
        "id": "11111111-1111-1111-1111-11111111111$i",
        "flow": "xtls-rprx-vision"
      }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "www.cloudflare.com:443",
        "xver": 0,
        "serverNames": ["www.cloudflare.com"],
        "privateKey": "${PRIVATE}",
        "shortIds": ["${REALITY_SHORTIDS[$((i-1))]}"]
      }
    }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

  cat > /etc/systemd/system/xray-reality-$i.service <<EOF
[Unit]
Description=Xray Reality Node $i
After=network.target

[Service]
ExecStart=/usr/local/bin/xray -config /etc/xray/reality_$i.json
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
done

# 启动所有服务
systemctl daemon-reload
for i in {1..5}; do
  systemctl enable --now hy2-$i
  systemctl enable --now xray-reality-$i
done

# 打印所有节点链接
echo ""
echo "✅ Hy2 节点链接："
for j in {0..4}; do
  echo "hy2://${PASSWORDS[$j]}@$IP:${PORTS[$j]}?insecure=1&sni=www.cloudflare.com#Hy2节点$((j+1))"
done

echo ""
echo "✅ Reality 节点链接（vless+reality）："
for j in {0..4}; do
  echo "vless://11111111-1111-1111-1111-11111111111$((j+1))@$IP:${REALITY_PORTS[$j]}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.cloudflare.com&fp=chrome&pbk=${REALITY_PUBLIC_KEYS[$j]}&sid=${REALITY_SHORTIDS[$j]}#Reality节点$((j+1))"
done
