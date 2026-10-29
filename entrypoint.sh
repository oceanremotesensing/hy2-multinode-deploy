#!/bin/bash

PORT=${PORT:-3000}
UUID=${UUID:-b7c8e9f0-2a3b-4c5d-8e9f-0a1b2c3d4e5f}
WSPATH=${WSPATH:-/vl}

# 写入到所有人都有读写权限的 /tmp 目录
cat <<EOF > /tmp/config.json
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
# 从 /tmp/config.json 读取配置启动
exec /xray/xray -config /tmp/config.json
