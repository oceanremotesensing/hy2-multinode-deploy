#!/usr/bin/env bash
# hy2-multinode-oneclick-fixed.sh
# 一键 Hysteria v2 多节点部署（交互版）——兼容 RackNerd / OpenVZ / LXC / KVM
# 特性：交互输入节点数与起始端口；自动清理；证书生成；多源下载；systemd/nohup 启动

# ---- 配色 ----
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

echo -e "${BLUE}==== Hysteria v2 多节点一键部署（兼容 RackNerd） ====${NC}"

# ---- 必须以 root 运行 ----
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}请以 root 用户运行此脚本（sudo bash ...）${NC}"
  exit 1
fi

read -p "请输入要安装的节点数量（默认 5）: " USER_NUM
NUM_INSTANCES=${USER_NUM:-5}
if ! [[ "$NUM_INSTANCES" =~ ^[0-9]+$ ]] || [ "$NUM_INSTANCES" -le 0 ]; then
  echo -e "${RED}节点数量无效，使用默认 5${NC}"
  NUM_INSTANCES=5
fi

read -p "请输入起始端口（默认 8443）: " USER_PORT
BASE_PORT=${USER_PORT:-8443}
if ! [[ "$BASE_PORT" =~ ^[0-9]+$ ]] || [ "$BASE_PORT" -lt 1024 ] || [ "$BASE_PORT" -gt 65535 ]; then
  echo -e "${YELLOW}端口不在 1024-65535 范围内，使用默认 8443${NC}"
  BASE_PORT=8443
fi

HY_DIR="/etc/hysteria2"
HY_BIN="/usr/local/bin/hysteria"
NGINX_SITE="/etc/nginx/sites-enabled/hysteria_reality"
LOGDIR="${HY_DIR}/logs"
CERT="${HY_DIR}/cert.pem"
KEY="${HY_DIR}/key.pem"

echo -e "${BLUE}将安装 ${NUM_INSTANCES} 个节点，起始端口 ${BASE_PORT}${NC}"

# ---- 小工具：重试函数 ----
retry_cmd() {
  local n=0
  local max=5
  local delay=3
  until [ $n -ge $max ]
  do
    "$@" && return 0
    n=$((n+1))
    echo -e "${YELLOW}命令失败，重试第 $n 次（最多 $max 次）...${NC}"
    sleep $delay
  done
  return 1
}

# ---- 清理旧进程/文件 ----
echo -e "${YELLOW}清理旧 Hysteria 进程与配置...${NC}"
pkill -9 hysteria >/dev/null 2>&1 || true
mkdir -p ${HY_DIR}
rm -f ${HY_BIN}
# 移除旧配置与日志
rm -rf ${HY_DIR}/*
mkdir -p ${HY_DIR} ${LOGDIR}

# ---- 处理 nginx 冲突：移除重复 default_server 并删除引用的 hysteria_reality 配置（如果存在） ----
if command -v nginx >/dev/null 2>&1; then
  echo -e "${BLUE}检测到 nginx，修复可能的 default_server 冲突...${NC}"
  # 从 sites-available 和 sites-enabled 中移除任何含 hysteria_reality 名称的文件（谨慎）
  if [ -f "${NGINX_SITE}" ] || [ -f "/etc/nginx/sites-available/hysteria_reality" ]; then
    echo -e "${YELLOW}备份并移除现有 hysteria_reality nginx 配置...${NC}"
    mkdir -p /root/nginx-backup-$(date +%s)
    cp -af /etc/nginx/sites-enabled/hysteria_reality* /root/nginx-backup-$(date +%s)/ 2>/dev/null || true
    rm -f /etc/nginx/sites-enabled/hysteria_reality /etc/nginx/sites-available/hysteria_reality 2>/dev/null || true
  fi
  # 全局移除 duplicate default_server 字样（仅在 sites-enabled/ 下）
  grep -rl "default_server" /etc/nginx/sites-enabled/ 2>/dev/null | while read -r f; do
    echo -e "${YELLOW}移除 ${f} 中的 default_server 标志${NC}"
    sed -i 's/default_server//g' "$f" || true
  done
  # 测试 nginx 配置（若可执行）
  if nginx -t >/dev/null 2>&1; then
    echo -e "${GREEN}nginx 配置检测通过${NC}"
  else
    echo -e "${YELLOW}nginx 配置有问题或 nginx 未安装，继续安装 Hysteria（不会中断）${NC}"
  fi
fi

# ---- 安装必要依赖（curl jq qrencode openssl socat） ----
echo -e "${BLUE}安装依赖（curl jq qrencode openssl socat）...（若 apt 被占用或源慢会尝试多次）${NC}"
# 等待 apt 解锁（若被别的进程占用）
WAIT=0
while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
  echo -e "${YELLOW}检测到 apt 被占用，等待...${NC}"
  sleep 2
  WAIT=$((WAIT+1))
  if [ $WAIT -gt 20 ]; then
    echo -e "${RED}apt 长时间被占用，建议稍后再试或重启 VPS${NC}"
    break
  fi
done

# 优先尝试正常 apt-get
if ! retry_cmd apt-get update -y >/dev/null 2>&1; then
  echo -e "${YELLOW}apt-get update 失败，尝试替换为国内镜像（仅建议在不影响你的网络策略时使用）${NC}"
  # 备份 sources.list
  cp -af /etc/apt/sources.list /etc/apt/sources.list.bak.$(date +%s)
  sed -i 's|http://.*.ubuntu.com|http://mirrors.ustc.edu.cn|g' /etc/apt/sources.list 2>/dev/null || true
  apt-get clean
  apt-get update -y || true
fi

# 安装包（允许失败但会尝试）
retry_cmd apt-get install -y curl jq qrencode openssl socat ca-certificates >/dev/null 2>&1 || {
  echo -e "${YELLOW}apt 安装部分软件失败，请手动检查网络或 apt 源。脚本将继续尝试下载二进制文件（无需全部依赖）${NC}"
}

# ---- 检查架构并下载 hysteria（二进制多源尝试） ----
ARCH=$(uname -m)
case ${ARCH} in
  x86_64|amd64) HY_ARCH="amd64" ;;
  aarch64|arm64) HY_ARCH="arm64" ;;
  *) echo -e "${RED}不支持的架构: ${ARCH}${NC}"; exit 1 ;;
esac
echo -e "${GREEN}检测到架构: ${HY_ARCH}${NC}"

download_hysteria() {
  echo -e "${BLUE}尝试从官方 GitHub 下载 hysteria...${NC}"
  GURL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
  GHAPI="https://api.github.com/repos/apernet/hysteria/releases/latest"
  # 尝试直接下载 latest asset
  if curl -fsSL -o "${HY_BIN}" "$GURL"; then
    chmod +x "${HY_BIN}"; return 0
  fi
  # 尝试 ghproxy 获取
  echo -e "${YELLOW}直接下载失败，尝试 ghproxy 镜像...${NC}"
  if curl -fsSL -o "${HY_BIN}" "https://ghproxy.net/${GURL}"; then
    chmod +x "${HY_BIN}"; return 0
  fi
  # 尝试 jsdelivr（作为最后手段）
  echo -e "${YELLOW}ghproxy 失败，尝试 jsdelivr（可能不可用）...${NC}"
  if curl -fsSL -o "${HY_BIN}" "https://cdn.jsdelivr.net/gh/apernet/hysteria@master/build/hysteria-linux-${HY_ARCH}" ; then
    chmod +x "${HY_BIN}"; return 0
  fi
  return 1
}

if ! download_hysteria; then
  echo -e "${RED}无法下载 hysteria 二进制文件，请检查网络或手动安装 /usr/local/bin/hysteria${NC}"
  exit 1
fi
echo -e "${GREEN}hysteria 安装成功：${HY_BIN}${NC}"

# ---- 生成自签名证书（当证书不存在时） ----
if [ ! -f "${CERT}" ] || [ ! -f "${KEY}" ]; then
  echo -e "${BLUE}生成自签名证书（/etc/hysteria2/{cert.pem,key.pem}）...${NC}"
  mkdir -p "${HY_DIR}"
  openssl req -x509 -newkey rsa:2048 -keyout "${KEY}" -out "${CERT}" -days 3650 -nodes -subj "/CN=localhost" >/dev/null 2>&1 || {
    echo -e "${RED}生成证书失败，请检查 openssl 是否可用${NC}"
    exit 1
  }
  chmod 600 "${KEY}"
  echo -e "${GREEN}证书生成完成${NC}"
else
  echo -e "${GREEN}检测到已有证书，跳过生成${NC}"
fi

# ---- 生成节点配置与启动 ----
echo -e "${BLUE}生成 ${NUM_INSTANCES} 个节点的配置并启动（systemd 优先，否则 nohup）...${NC}"
IS_SYSTEMD=0
if [ "$(ps -p 1 -o comm=)" = "systemd" ]; then IS_SYSTEMD=1; fi

for i in $(seq 1 $NUM_INSTANCES); do
  PORT=$((BASE_PORT + (i - 1) * 1000))
  PASSWORD=$(openssl rand -base64 12)
  CFG="${HY_DIR}/config${i}.yaml"
  cat > "${CFG}" <<EOF
listen: ":${PORT}"
auth:
  type: password
  password: ${PASSWORD}
tls:
  cert: ${CERT}
  key: ${KEY}
obfuscate:
  type: srtp
disable-quic: true
EOF

  if [ $IS_SYSTEMD -eq 1 ]; then
    # 创建 systemd 服务文件
    SERVICE="/etc/systemd/system/hy2-${i}.service"
    cat > "${SERVICE}" <<EOF
[Unit]
Description=Hysteria v2 Node ${i}
After=network.target

[Service]
ExecStart=${HY_BIN} server -c ${CFG}
Restart=always
RestartSec=3
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW
NoNewPrivileges=false

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now hy2-${i} >/dev/null 2>&1 || echo -e "${YELLOW}启动 hy2-${i} 失败（systemd），将尝试 nohup 启动并记录日志${NC}" && \
      (nohup ${HY_BIN} server -c ${CFG} > ${LOGDIR}/hy2-${i}.log 2>&1 &)
  else
    nohup ${HY_BIN} server -c ${CFG} > ${LOGDIR}/hy2-${i}.log 2>&1 &
  fi
  sleep 0.3
done

# ---- 防火墙放行（若 ufw 可用） ----
if command -v ufw &>/dev/null; then
  END_PORT=$((BASE_PORT + (NUM_INSTANCES - 1) * 1000))
  ufw allow "${BASE_PORT}:${END_PORT}/udp" >/dev/null 2>&1 || true
fi

# ---- 等待短时间并检查进程 ----
sleep 1
echo -e "${BLUE}检查 hysteria 进程...${NC}"
ps aux | grep -E "hysteria server" | grep -v grep || echo -e "${YELLOW}未检测到正在运行的 hysteria 进程，请查看日志 ${LOGDIR}${NC}"

# ---- 输出节点链接与二维码（若有 qrencode） ----
IP=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me || hostname -I | awk '{print $1}')
echo -e "${GREEN}部署完成。节点信息如下：${NC}"
for cfg in ${HY_DIR}/config*.yaml; do
  num=$(basename "${cfg}" | grep -o -E '[0-9]+')
  port=$(grep -oP '":\K[0-9]+' "${cfg}")
  password=$(grep -oP 'password: \K.*' "${cfg}")
  link="hy2://${password}@${IP}:${port}?insecure=1#node${num}"
  echo -e "${YELLOW}节点 ${num}: ${link}${NC}"
  if command -v qrencode &>/dev/null; then
    qrencode -t UTF8 "${link}"
  fi
done

echo -e "${GREEN}日志目录：${LOGDIR}${NC}"
echo -e "${BLUE}若使用 systemd，可用：systemctl status hy2-<n>；若使用 nohup，请查看 ${LOGDIR}/hy2-<n>.log${NC}"
echo -e "${GREEN}完成 ✅${NC}"
