#!/usr/bin/env bash
# Xray-Reality-Clean-And-Deploy.sh
# 作用：1. 强力清除系统中残留的 VPN 内核 (Xray/V2Ray/Hysteria)
#      2. 在干净环境下全新安装 Xray Reality

# 颜色定义
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
XRAY_BIN="/usr/local/bin/xray"
CONF_DIR="/etc/xray"
CONF_FILE="${CONF_DIR}/config.json"

[ "$(id -u)" -ne 0 ] && echo -e "${RED}❌ 必须使用 root 权限运行！${NC}" && exit 1

# ==========================================
# 第一步：彻底清理旧环境 (The Cleaner)
# ==========================================
echo -e "${YELLOW}🧹 [1/4] 正在执行深度清理...${NC}"

# 1. 停止并禁用常见的 VPN 服务
SERVICES=("xray" "v2ray" "v2ray-server" "hysteria" "hysteria-server" "hy2" "tuic")
for SERVICE in "${SERVICES[@]}"; do
    if systemctl is-active --quiet "$SERVICE" || systemctl is-enabled --quiet "$SERVICE"; then
        echo -e "   - 停止服务: $SERVICE"
        systemctl stop "$SERVICE" >/dev/null 2>&1
        systemctl disable "$SERVICE" >/dev/null 2>&1
    fi
    # 删除服务文件
    rm -f "/etc/systemd/system/${SERVICE}.service"
    rm -f "/lib/systemd/system/${SERVICE}.service"
done

# 2. 删除残留的二进制文件
echo -e "   - 删除残留二进制文件..."
rm -rf /usr/local/bin/xray
rm -rf /usr/bin/xray
rm -rf /usr/local/bin/v2ray
rm -rf /usr/bin/v2ray
rm -rf /usr/local/bin/hysteria
rm -rf /root/hy2  # 之前 Hysteria 脚本常见的安装位置

# 3. 删除旧的配置文件目录
echo -e "   - 删除旧配置目录..."
rm -rf /etc/xray
rm -rf /usr/local/etc/xray
rm -rf /etc/v2ray
rm -rf /etc/hysteria

# 4. 刷新系统服务列表
systemctl daemon-reload
echo -e "${GREEN}✔ 清理完成！环境已重置。${NC}"

# ==========================================
# 第二步：准备新环境
# ==========================================
echo -e "${BLUE}🔨 [2/4] 正在准备新环境...${NC}"

# 时间同步 (Reality 强依赖时间)
if command -v date >/dev/null 2>&1; then
    date -s "$(curl -sI https://www.google.com | grep ^Date: | sed 's/Date: //g')" >/dev/null 2>&1
    echo -e "   - 时间已同步: $(date)"
fi

# 安装依赖
if command -v apt >/dev/null 2>&1; then
    apt update -y >/dev/null 2>&1
    apt install -y curl wget unzip jq uuid-runtime openssl coreutils >/dev/null 2>&1
elif command -v yum >/dev/null 2>&1; then
    yum install -y curl wget unzip jq util-linux openssl coreutils >/dev/null 2>&1
fi

# ==========================================
# 第三步：安装 Xray 核心
# ==========================================
echo -e "${BLUE}⬇️ [3/4] 正在安装最新版 Xray...${NC}"

ARCH=$(uname -m)
case $ARCH in
    x86_64) FILE_ARCH="64" ;;
    aarch64|arm64) FILE_ARCH="arm64-v8a" ;;
    *) echo -e "${RED}❌ 不支持的架构: $ARCH${NC}"; exit 1 ;;
esac

# 下载并安装
curl -L -o /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${FILE_ARCH}.zip"
unzip -o /tmp/xray.zip -d /tmp/xray_dist >/dev/null
install -m 755 /tmp/xray_dist/xray "$XRAY_BIN"
rm -rf /tmp/xray.zip /tmp/xray_dist

# 验证安装
if ! "$XRAY_BIN" version >/dev/null 2>&1; then
    echo -e "${RED}❌ Xray 安装失败，无法运行。${NC}"
    exit 1
fi
echo -e "${GREEN}✔ Xray 安装成功!${NC}"

# ==========================================
# 第四步：生成配置 & 启动
# ==========================================
echo -e "${BLUE}🔑 [4/4] 生成密钥与配置...${NC}"

# 生成密钥 (使用稳健提取法)
KEY_OUTPUT=$("$XRAY_BIN" x25519)
PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep "Private key" | awk '{print $NF}' | tr -d ' \r\n')
PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep "Public key" | awk '{print $NF}' | tr -d ' \r\n')

# 再次检查密钥
if [[ ${#PRIVATE_KEY} -lt 40 ]]; then
    echo -e "${RED}❌ 密钥生成异常。输出内容：${NC}"
    echo "$KEY_OUTPUT"
    exit 1
fi

# 准备参数
UUID=$(uuidgen)
PORT=$(shuf -i 20000-59999 -n 1)
SID=$(openssl rand -hex 4)
MY_IP=$(curl -s4 https://api.ipify.org || curl -s4 ip.sb)

# 写入配置
mkdir -p "$CONF_DIR"
cat > "$CONF_FILE" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "0.0.0.0", "port": $PORT, "protocol": "vless",
    "settings": {
      "clients": [{ "id": "$UUID", "flow": "xtls-rprx-vision" }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp", "security": "reality",
      "realitySettings": {
        "dest": "www.microsoft.com:443",
        "serverNames": ["www.microsoft.com"],
        "privateKey": "$PRIVATE_KEY",
        "shortIds": ["$SID"]
      }
    }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

# 写入服务文件
cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Reality
After=network.target
[Service]
ExecStart=$XRAY_BIN run -c $CONF_FILE
Restart=always
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
EOF

# 启动
systemctl daemon-reload
systemctl enable --now xray

# 生成链接
LINK="vless://${UUID}@${MY_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&type=tcp&sni=www.microsoft.com&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SID}#Reality-Clean-${PORT}"

echo -e "\n${GREEN}==============================================${NC}"
echo -e "${GREEN}✔ 清理并重装完成！${NC}"
echo -e "${GREEN}==============================================${NC}"
echo -e "端口: $PORT"
echo -e "密钥: $PRIVATE_KEY"
echo -e "${BLUE}复制下方链接到客户端：${NC}"
echo -e "\n${LINK}\n"
