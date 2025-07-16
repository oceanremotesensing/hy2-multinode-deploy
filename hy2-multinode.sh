#!/bin/bash
set -e

IP="107.174.88.122"
PORT=443
HYSTERIA_PORT=7890
PASSWORD="YourStrongPassword123!"

echo "安装必要组件..."
apt update
apt install -y curl socat openssl nginx

echo "安装 hysteria..."
curl -Lo /usr/local/bin/hysteria https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-amd64
chmod +x /usr/local/bin/hysteria

echo "生成自签证书..."
mkdir -p /etc/hysteria2
cd /etc/hysteria2
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes -subj "/CN=$IP"
chmod 600 key.pem cert.pem

echo "生成 hysteria 配置..."
cat > config.yaml <<EOF
listen: ":$HYSTERIA_PORT"
auth:
  type: password
  password: "$PASSWORD"
masquerade:
  type: proxy
  proxy:
    url: https://www.cloudflare.com
    rewriteHost: true
tls:
  cert: /etc/hysteria2/cert.pem
  key: /etc/hysteria2/key.pem
EOF

echo "生成 systemd 服务..."
cat > /etc/systemd/system/hysteria.service <<EOF
[Unit]
Description=Hysteria Server with Nginx TLS Proxy
After=network.target

[Service]
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria2/config.yaml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "配置 Nginx 反向代理..."
cat > /etc/nginx/sites-available/hysteria <<EOF
server {
    listen 80;
    server_name $IP;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $IP;

    ssl_certificate /etc/hysteria2/cert.pem;
    ssl_certificate_key /etc/hysteria2/key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location / {
        proxy_pass https://127.0.0.1:$HYSTERIA_PORT;
        proxy_ssl_verify off;

        proxy_http_version 1.1;
        proxy_set_header Host www.cloudflare.com;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_set_header Accept-Encoding "";
    }
}
EOF

ln -sf /etc/nginx/sites-available/hysteria /etc/nginx/sites-enabled/hysteria
nginx -t && systemctl restart nginx

echo "启动 hysteria 服务..."
systemctl daemon-reload
systemctl enable --now hysteria

echo ""
echo "✅ 部署完成！"
echo "连接示例："
echo "hy2://$PASSWORD@$IP:$PORT?insecure=1&sni=www.cloudflare.com#hy2-nginx-obfuscation"
echo ""
echo "注意：因使用自签证书，客户端需启用 insecure=1 忽略证书验证"
