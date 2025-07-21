#!/bin/bash
set -e

BASE="/etc/hysteria2"
CLIENTS_DIR="$BASE/clients"
EXPORT_DIR="$BASE/export"
PORTS=(443 8443 9443 10443 11443 12443 13443 14443 15443 16443)

mkdir -p "$EXPORT_DIR"

IP=$(curl -s https://api.ipify.org)
if [[ -z "$IP" ]]; then
  echo "❌ 无法获取公网 IP，请检查网络"
  exit 1
fi

echo "🔗 生成 Hysteria 节点链接（共10个）："
> "$EXPORT_DIR/hysteria_links.txt"  # 清空文件

for i in {1..10}; do
  UUID_FILE="$CLIENTS_DIR/uuid$i.txt"
  if [[ ! -f "$UUID_FILE" ]]; then
    echo "⚠️ 找不到 UUID 文件：$UUID_FILE，跳过"
    continue
  fi
  UUID=$(cat "$UUID_FILE")
  PORT=${PORTS[$((i-1))]}
  LINK="hy2://$UUID@$IP:$PORT?insecure=1#节点$i"
  echo "$LINK" | tee -a "$EXPORT_DIR/hysteria_links.txt"
done

echo ""
echo "✅ 节点链接已保存到：$EXPORT_DIR/hysteria_links.txt"
