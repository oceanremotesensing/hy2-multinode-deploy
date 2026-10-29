#!/bin/bash

# 优先使用平台注入的 PORT，没有则默认 3000
PORT=${PORT:-3000}
UUID=${UUID:-b7c8e9f0-2a3b-4c5d-8e9f-0a1b2c3d4e5f}
WSPATH=${WSPATH:-/vl}

# 动态生成 Xray 配置文件
cat <<EOF > /xray/config.json
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": $PORT,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "$WSPATH"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF

echo "Starting Xray on port $PORT with UUID $UUID and path $WSPATH..."
exec /xray/xray -config /xray/config.json
