#!/bin/bash
set -e

# 默认参数
NODE_COUNT=10
PORT_RANGE_START=20000
PORT_RANGE_END=60000
PASSWORD_PREFIX="PwdHy2_"

usage() {
  echo "Usage: $0 [-n node_count] [-s port_range_start] [-e port_range_end] [-p password_prefix]"
  echo "  -n   节点数量，默认10"
  echo "  -s   端口起始，默认20000"
  echo "  -e   端口结束，默认60000"
  echo "  -p   密码前缀，默认PwdHy2_"
  exit 1
}

while getopts "n:s:e:p:" opt; do
  case $opt in
    n) NODE_COUNT=$OPTARG ;;
    s) PORT_RANGE_START=$OPTARG ;;
    e) PORT_RANGE_END=$OPTARG ;;
    p) PASSWORD_PREFIX=$OPTARG ;;
    *) usage ;;
  esac
done

if (( NODE_COUNT < 1 || NODE_COUNT > 100 )); then
  echo "节点数量建议1~100之间"
  exit 1
fi

if (( PORT_RANGE_START < 1024 || PORT_RANGE_END > 65535 || PORT_RANGE_START >= PORT_RANGE_END )); then
  echo "端口范围必须在1024~65535且起始小于结束"
  exit 1
fi

echo "🔧 更新系统并安装必备组件..."
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
if [[ ! -f cert.pem || ! -f key.pem ]]; then
  openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes -subj "/CN=localhost"
else
  echo "证书已存在，跳过生成"
fi

declare -a PORTS=()
declare -A USED_PORTS=()

# 生成不冲突的端口
generate_port() {
  while true; do
    p=$(( RANDOM % (PORT_RANGE_END - PORT_RANGE_START + 1) + PORT_RANGE_START ))
    # 检查端口是否被占用
    if ss -tuln | grep -q ":$p "; then
      continue
    fi
    if [[ -z "${USED_PORTS[$p]}" ]]; then
      USED_PORTS[$p]=1
      echo $p
      return
    fi
  done
}

echo "生成 $NODE_COUNT 个随机端口..."
for ((i=0; i<NODE_COUNT; i++)); do
  PORTS+=($(generate_port))
done

# 生成密码
generate_password() {
  # 12位随机密码（字母+数字）
  tr -dc A-Za-z0-9 </dev/urandom | head -c 12
}

PASSWORDS=()
echo "生成密码..."
for ((i=1; i<=NODE_COUNT; i++)); do
  PASSWORDS+=("${PASSWORD_PREFIX}${i}_$(generate_password)")
done

IP=$(curl -s https://api.ipify.org)
echo "检测到公网IP: $IP"

echo "生成配置文件和 systemd 服务..."

for ((i=1; i<=NODE_COUNT; i++)); do
  idx=$((i-1))
  cat > config$i.yaml <<EOF
listen: ":${PORTS[$idx]}"
auth:
  type: password
  password: ${PASSWORDS[$idx]}
tls:
  cert: /etc/hysteria2/cert.pem
  key: /etc/hysteria2/key.pem
obfuscate:
  type: srtp
EOF

   cat > /etc/systemd/system/hy2-$i.service <<EOF
[Unit]
Description=Hysteria v2 Node $i
After=network.target

[Service]
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria2/config$i.yaml
Restart=always
RestartSec=5
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=hy2-$i
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
done

systemctl daemon-reload

echo "启动所有节点..."
for ((i=1; i<=NODE_COUNT; i++)); do
  systemctl enable --now hy2-$i
done

echo ""
echo "节点启动状态："
for ((i=1; i<=NODE_COUNT; i++)); do
  systemctl is-active --quiet hy2-$i && echo "hy2-$i: active" || echo "hy2-$i: failed"
done

echo ""
echo "✅ 节点链接："
for ((i=0; i<NODE_COUNT; i++)); do
  num=$((i+1))
  echo "hy2://${PASSWORDS[$i]}@$IP:${PORTS[$i]}?insecure=1#节点$num"
done
