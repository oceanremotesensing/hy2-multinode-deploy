#!/bin/bash
set -e

echo "🔧 正在安装 Hysteria 2 多节点环境（含混淆伪装）..."

# 杀掉残留 hysteria 进程
pkill -f hysteria || true

# 下载 hysteria 可执行文件
rm -f /usr/local/bin/hysteria
curl -Lo /usr/local/bin/hysteria https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-amd64
chmod +x /usr/local/bin/hysteria

# 创建配置目录
mkdir -p /etc/hysteria2
cd /etc/hysteria2

# 生成自签证书 (10年有效期)
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes -subj "/CN=localhost"
chmod 600 key.pem cert.pem

# 端口和密码
PORTS=(443 8443 9443 10443 11443)
PASSWORDS=("gS7kR9fQ" "X9vL2bTm" "mW8hPaYo" "T3nFcQzB" "Lp7tZxVu")

# 生成配置和 systemd 服务，包含混淆伪装配置
for i in {1..5}; do
  j=$((i-1))
  cat > config$i.yaml <<EOF
listen: ":${PORTS[$j]}"
auth:
  type: password
  password: ${PASSWORDS[$j]}
masquerade:
  type: proxy
  proxy:
    url: https://www.cloudflare.com       # 伪装目标，可改成你想的域名
    rewriteHost: true
tls:
  cert: /etc/hysteria2/cert.pem
  key: /etc/hysteria2/key.pem
EOF

  cat > /etc/systemd/system/hy2-$i.service <<EOF
[Unit]
Description=Hysteria2 Server Instance $i (with Obfuscation)
After=network.target

[Service]
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria2/config$i.yaml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
done

# 重载 systemd 并启动服务
systemctl daemon-reload
for i in {1..5}; do
  systemctl enable --now hy2-$i
done

# 固定公网 IP
IP="107.174.88.122"

# 检查服务状态
sleep 3
echo ""
echo "🔍 服务状态检查："
for i in {1..5}; do
  systemctl is-active --quiet hy2-$i && echo "hy2-$i 服务正常" || echo "hy2-$i 服务未运行"
done

# 打印节点链接
echo ""
echo "✅ 节点链接（Hysteria v2 + 混淆）："
for j in {0..4}; do
  echo "hy2://${PASSWORDS[$j]}@$IP:${PORTS[$j]}?insecure=1&sni=www.cloudflare.com#节点$((j+1))"
done
