#!/bin/bash
set -e

# 默认参数
NODE_COUNT=10
PORT_RANGE_START=20000
PORT_RANGE_END=60000
PASSWORD_PREFIX="PwdHy2_"
REALITY_NODE_COUNT=5 # 新增：Reality节点数量

usage() {
  echo "Usage: $0 [-n node_count] [-s port_range_start] [-e port_range_end] [-p password_prefix] [-r reality_node_count]"
  echo "  -n   密码认证节点数量，默认10"
  echo "  -s   端口起始，默认20000"
  echo "  -e   端口结束，默认60000"
  echo "  -p   密码前缀，默认PwdHy2_"
  echo "  -r   Reality节点数量，默认5"
  exit 1
}

while getopts "n:s:e:p:r:" opt; do
  case $opt in
    n) NODE_COUNT=$OPTARG ;;
    s) PORT_RANGE_START=$OPTARG ;;
    e) PORT_RANGE_END=$OPTARG ;;
    p) PASSWORD_PREFIX=$OPTARG ;;
    r) REALITY_NODE_COUNT=$OPTARG ;;
    *) usage ;;
  esac
done

if (( NODE_COUNT < 0 || NODE_COUNT > 100 )); then
  echo "密码认证节点数量建议0~100之间"
  exit 1
fi

if (( REALITY_NODE_COUNT < 0 || REALITY_NODE_COUNT > 100 )); then
  echo "Reality节点数量建议0~100之间"
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

# --- Hysteria 密码认证节点配置 ---
if (( NODE_COUNT > 0 )); then
    echo "🔧 为密码认证节点生成自签名证书..."
    if [[ ! -f cert.pem || ! -f key.pem ]]; then
      openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes -subj "/CN=localhost"
    else
      echo "证书已存在，跳过生成"
    fi
fi

# --- Reality 节点配置 ---
if (( REALITY_NODE_COUNT > 0 )); then
    echo "🔧 为Reality节点生成密钥对..."
    if [[ ! -f reality.key || ! -f reality.pub ]]; then
        /usr/local/bin/hysteria keygen --ecdsa > reality.key
        /usr/local/bin/hysteria keygen --ecdsa --pub-only < reality.key > reality.pub
    else
        echo "Reality密钥对已存在，跳过生成"
    fi
    REALITY_PUB_KEY=$(cat reality.pub)
fi

declare -a PORTS=()
declare -a REALITY_PORTS=()
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

TOTAL_NODES=$((NODE_COUNT + REALITY_NODE_COUNT))
echo "生成 $TOTAL_NODES 个随机端口..."
for ((i=0; i<NODE_COUNT; i++)); do
  PORTS+=($(generate_port))
done
for ((i=0; i<REALITY_NODE_COUNT; i++)); do
  REALITY_PORTS+=($(generate_port))
done

# 生成密码
PASSWORDS=()
if (( NODE_COUNT > 0 )); then
    echo "为 $NODE_COUNT 个密码认证节点生成密码..."
    for ((i=1; i<=NODE_COUNT; i++)); do
      # 12位随机密码（字母+数字）
      PASSWORDS+=("${PASSWORD_PREFIX}${i}_$(tr -dc A-Za-z0-9 </dev/urandom | head -c 12)")
    done
fi

IP=$(curl -s https://api.ipify.org)
echo "检测到公网IP: $IP"

echo "生成配置文件和 systemd 服务..."

# 生成密码认证节点配置
for ((i=1; i<=NODE_COUNT; i++)); do
  idx=$((i-1))
  cat > config-pwd-$i.yaml <<EOF
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

  cat > /etc/systemd/system/hy2-pwd-$i.service <<EOF
[Unit]
Description=Hysteria v2 Password Node $i
After=network.target

[Service]
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria2/config-pwd-$i.yaml
Restart=always
RestartSec=5
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=hy2-pwd-$i

[Install]
WantedBy=multi-user.target
EOF
done

# 生成Reality节点配置
REALITY_DOMAINS=("www.bing.com" "www.apple.com" "www.samsung.com" "www.amazon.com" "www.google.com")
for ((i=1; i<=REALITY_NODE_COUNT; i++)); do
  idx=$((i-1))
  RANDOM_DOMAIN=${REALITY_DOMAINS[$((RANDOM % ${#REALITY_DOMAINS[@]}))]}
  cat > config-reality-$i.yaml <<EOF
listen: ":${REALITY_PORTS[$idx]}"
reality:
  publicKey: /etc/hysteria2/reality.pub
  privateKey: /etc/hysteria2/reality.key
  underlying: ${RANDOM_DOMAIN}:443
EOF

  cat > /etc/systemd/system/hy2-reality-$i.service <<EOF
[Unit]
Description=Hysteria v2 Reality Node $i
After=network.target

[Service]
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria2/config-reality-$i.yaml
Restart=always
RestartSec=5
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=hy2-reality-$i

[Install]
WantedBy=multi-user.target
EOF
done


systemctl daemon-reload

echo "启动所有节点..."
for ((i=1; i<=NODE_COUNT; i++)); do
  systemctl enable --now hy2-pwd-$i
done
for ((i=1; i<=REALITY_NODE_COUNT; i++)); do
  systemctl enable --now hy2-reality-$i
done


echo ""
echo "节点启动状态："
for ((i=1; i<=NODE_COUNT; i++)); do
  systemctl is-active --quiet hy2-pwd-$i && echo "hy2-pwd-$i: active" || echo "hy2-pwd-$i: failed"
done
for ((i=1; i<=REALITY_NODE_COUNT; i++)); do
  systemctl is-active --quiet hy2-reality-$i && echo "hy2-reality-$i: active" || echo "hy2-reality-$i: failed"
done


echo ""
if (( NODE_COUNT > 0 )); then
    echo "✅ 密码认证节点链接："
    for ((i=0; i<NODE_COUNT; i++)); do
      num=$((i+1))
      echo "hy2://${PASSWORDS[$i]}@$IP:${PORTS[$i]}?insecure=1#PwdNode_$num"
    done
fi

echo ""
if (( REALITY_NODE_COUNT > 0 )); then
    echo "✅ Reality 节点链接："
    for ((i=0; i<REALITY_NODE_COUNT; i++)); do
        num=$((i+1))
        config_file="/etc/hysteria2/config-reality-$((i+1)).yaml"
        # 从配置文件中读取伪装域名
        underlying_domain=$(grep "underlying:" "$config_file" | awk '{print $2}' | cut -d':' -f1)
        echo "hy2://$IP:${REALITY_PORTS[$i]}?sni=${underlying_domain}&reality-key=${REALITY_PUB_KEY}#RealityNode_$num"
    done
fi
