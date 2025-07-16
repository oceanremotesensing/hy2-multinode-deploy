#!/bin/bash
set -e

IP="107.174.88.122"
PASSWORDS_HY2=("Hy2Pwd1" "Hy2Pwd2" "Hy2Pwd3" "Hy2Pwd4" "Hy2Pwd5")
PASSWORDS_REALITY=("RealPwd1" "RealPwd2" "RealPwd3" "RealPwd4" "RealPwd5")

# 端口配置
PORTS_HY2=(443 8443 9443 10443 11443)
PORTS_REALITY=(20443 21443 22443 23443 24443)

echo "🔧 安装必备组件..."
apt update
apt install -y curl socat openssl nginx

echo "🔧 安装 hysteria..."
curl -Lo /usr/local/bin/hysteria https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-amd64
chmod +x /usr/local/bin/hysteria

echo "🔧 安装 xray-core..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)"

echo "🔧 生成自签证书..."
mkdir -p /etc/hysteria2
cd /etc/hysteria2
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes -subj "/CN=$IP"
chmod 600 key.pem cert.pem

# ------------------------
# 生成 hysteria 配置和服务 (5个 hy2 节点)
for i in {1..5}; do
  idx=$((i-1))
  cat > /etc/hysteria2/hy2_config_$i.yaml <<EOF
listen: ":${PORTS_HY2[$idx]}"
auth:
  type: password
  password: "${PASSWORDS_HY2[$idx]}"
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
Description=Hysteria v2 Server Instance $i
After=network.target

[Service]
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria2/hy2_config_$i.yaml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
done

# ------------------------
# 生成 xray reality 配置和服务 (5个 hy2+Reality 节点的Reality部分)
for i in {1..5}; do
  idx=$((i-1))
  XRAY_PORT=${PORTS_REALITY[$idx]}
  XRAY_CONF="/etc/xray/reality_$i.json"

  mkdir -p /etc/xray

  # 生成简单 Reality 服务器配置（示例，实际根据需求调整）
  cat > $XRAY_CONF <<EOF
{
  "inbounds": [
    {
      "port": $XRAY_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "00000000-0000-0000-0000-00000000000$i",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": true,
          "dest": "$IP:$XRAY_PORT",
          "xver": 0,
          "serverNames": ["www.cloudflare.com"],
          "privateKey": "YOUR_PRIVATE_KEY_HERE_$i",
          "shortIds": ["shortid1"]
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "settings": {} }
  ]
}
EOF

  cat > /etc/systemd/system/xray-reality-$i.service <<EOF
[Unit]
Description=Xray Reality Server Instance $i
After=network.target

[Service]
ExecStart=/usr/local/bin/xray -config $XRAY_CONF
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
done

# ------------------------
# 启动所有服务
systemctl daemon-reload

for i in {1..5}; do
  systemctl enable --now hy2-$i
  systemctl enable --now xray-reality-$i
done

# ------------------------
# 配置 Nginx 反代（监听全部 hy2 端口及 Reality 端口）
cat > /etc/nginx/sites-available/hysteria_reality <<EOF
server {
    listen 80 default_server;
    server_name _;

    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name _;

    ssl_certificate /etc/hysteria2/cert.pem;
    ssl_certificate_key /etc/hysteria2/key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    # 反代 5 个 hy2 端口
    location /hy2_443/ {
        proxy_pass https://127.0.0.1:${PORTS_HY2[0]};
        proxy_ssl_verify off;
        proxy_set_header Host www.cloudflare.com;
    }
    # 你可以继续添加其他反代规则或监听其它端口...
}
EOF

ln -sf /etc/nginx/sites-available/hysteria_reality /etc/nginx/sites-enabled/hysteria_reality
nginx -t && systemctl restart nginx

# ------------------------
# 打印节点链接
echo ""
echo "====== Hy2 节点（5个） ======"
for i in {0..4}; do
  echo "hy2://${PASSWORDS_HY2[$i]}@$IP:${PORTS_HY2[$i]}?insecure=1&sni=www.cloudflare.com#Hy2-节点-$((i+1))"
done

echo ""
echo "====== Hy2 + Reality 节点（5个）Reality部分示例链接（请根据实际私钥及shortId修改）======"
for i in {0..4}; do
  XRAY_PORT=${PORTS_REALITY[$i]}
  echo "vless://00000000-0000-0000-0000-00000000000$((i+1))@$IP:$XRAY_PORT?security=reality&encryption=none&type=tcp&sni=www.cloudflare.com&fp=chrome#Reality-节点-$((i+1))"
done

echo ""
echo "部署完成！请根据实际需求修改Xray配置中的私钥等敏感参数。"
