FROM alpine:latest

# 安装基础工具
RUN apk add --no-cache curl unzip bash

WORKDIR /xray

# 自动匹配架构并下载官方最新 Xray 内核
RUN ARCH=$(uname -m) && \
    case "$ARCH" in \
        x86_64) XRAY_ARCH="64" ;; \
        aarch64) XRAY_ARCH="arm64-v8a" ;; \
        *) XRAY_ARCH="64" ;; \
    esac && \
    curl -L -o xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XRAY_ARCH}.zip && \
    unzip xray.zip && \
    chmod +x xray && \
    rm -f xray.zip

# 拷贝启动脚本
COPY entrypoint.sh /xray/entrypoint.sh
RUN chmod +x /xray/entrypoint.sh

CMD ["/xray/entrypoint.sh"]
