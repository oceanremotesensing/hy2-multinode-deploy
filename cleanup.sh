#!/bin/bash
set -e

echo "🔧 开始清理系统垃圾..."

# 更新 apt 缓存列表
apt update

# 清理 APT 缓存
apt autoremove -y
apt autoclean -y
apt clean

# 清理 journal 日志（仅保留最近 100M）
journalctl --vacuum-size=100M

# 清理已断开挂载点
rm -rf /mnt/*
rm -rf /media/*

# 清理 tmp 临时文件夹
rm -rf /tmp/*
rm -rf /var/tmp/*

# 清理废弃的 Docker 镜像、容器等（如安装了 Docker）
if command -v docker &> /dev/null; then
    docker system prune -a -f
fi

echo "✅ 清理完成。建议重启系统以释放缓存资源。"
