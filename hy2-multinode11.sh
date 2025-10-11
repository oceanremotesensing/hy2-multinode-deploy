install_hysteria() {
  check_root

  read -p "您想安装多少个节点? [默认: 5]: " NUM_INSTANCES
  NUM_INSTANCES=${NUM_INSTANCES:-5}

  read -p "起始端口号是多少? [默认: 8443]: " BASE_PORT
  BASE_PORT=${BASE_PORT:-8443}

  echo -e "${YELLOW}🔧 正在安装必备组件...${NC}"
  apt-get update >/dev/null 2>&1
  apt-get install -y curl socat openssl qrencode >/dev/null 2>&1

  echo -e "${YELLOW}🔧 正在下载 Hysteria ...${NC}"
  pkill -f hysteria || true
  rm -f ${HY_BIN}
  curl -Lo ${HY_BIN} https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-amd64
  chmod +x ${HY_BIN}

  mkdir -p ${HY_DIR}
  cd ${HY_DIR}

  if [[ ! -f cert.pem || ! -f key.pem ]]; then
    echo -e "${YELLOW}🔧 生成自签名证书...${NC}"
    openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes -subj "/CN=bing.com"
  fi

  echo -e "${YELLOW}🔧 生成节点配置与服务...${NC}"
  for i in $(seq 1 ${NUM_INSTANCES}); do
    PORT=$((BASE_PORT + (i - 1) * 1000))
    PASSWORD=$(openssl rand -base64 16)

    cat > config${i}.yaml <<EOF
listen: ":${PORT}"
auth:
  type: password
  password: ${PASSWORD}
tls:
  cert: ${HY_DIR}/cert.pem
  key: ${HY_DIR}/key.pem
obfuscate:
  type: srtp
disable-quic: true
EOF

    cat > /etc/systemd/system/hy2-${i}.service <<EOF
[Unit]
Description=Hysteria v2 Node ${i}
After=network.target

[Service]
ExecStart=${HY_BIN} server -c ${HY_DIR}/config${i}.yaml
Restart=always
RestartSec=5
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW
NoNewPrivileges=false

[Install]
WantedBy=multi-user.target
EOF
  done

  systemctl daemon-reload
  for i in $(seq 1 ${NUM_INSTANCES}); do
    systemctl enable --now hy2-${i} >/dev/null 2>&1
  done

  # 防火墙
  if command -v ufw &> /dev/null; then
    END_PORT=$((BASE_PORT + (NUM_INSTANCES - 1) * 1000))
    ufw allow ${BASE_PORT}-${END_PORT}/udp >/dev/null 2>&1
    echo -e "${GREEN}UFW 防火墙规则已添加 (UDP: ${BASE_PORT}-${END_PORT})${NC}"
  fi

  echo -e "${GREEN}✅ 安装完成！现在可以选择菜单 3 查看节点链接${NC}"
}

show_links() {
  if ! check_installed; then
    echo -e "${RED}未检测到节点配置，请先安装节点${NC}"
    return
  fi

  IP=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me)
  echo -e "${GREEN}节点链接:${NC}"
  for config_file in ${HY_DIR}/config*.yaml; do
    num=$(echo ${config_file} | grep -o -E '[0-9]+')
    port=$(grep -oP '":\K[0-9]+' ${config_file})
    password=$(grep -oP 'password: \K.*' ${config_file})
    link="hy2://${password}@${IP}:${port}?insecure=1#节点${num}"
    echo -e "${YELLOW}${link}${NC}"
    qrencode -o - -t UTF8 "${link}"
  done
}
